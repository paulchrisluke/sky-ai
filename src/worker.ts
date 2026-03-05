interface Env {
  SKY_DB: D1Database;
  SKY_ARTIFACTS: R2Bucket;
  SKY_VECTORIZE: VectorizeIndex;
  EMBEDDING_QUEUE?: QueueBinding;
  WORKER_API_KEY?: string;
  ACCESS_AUTH_ENABLED?: string;
  ACCESS_AUD?: string;
  ACCESS_ISSUER?: string;
  ACCESS_JWKS_URL?: string;
  ALLOW_API_KEY_BYPASS?: string;
  OPENAI_API_KEY?: string;
  CF_AIG_AUTH_TOKEN?: string;
  AIG_ACCOUNT_ID?: string;
  AIG_GATEWAY_ID?: string;
  OPENAI_MODEL?: string;
  OPENAI_EMBEDDING_MODEL?: string;
  MAILBOX_SKYLERBAIRD_ME_COM?: string;
  ENVIRONMENT: string;
}

type JsonRecord = Record<string, unknown>;

type NormalizedAddress = {
  email: string;
  name: string | null;
};

type EmbeddingQueueMessage = {
  sourceRecordId: string;
};

const MAX_CHUNK_SOURCE_CHARS = 24000;
const CHUNK_SIZE = 1200;
const CHUNK_OVERLAP = 200;
const MAX_CHUNKS_PER_MESSAGE = 24;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === 'GET' && url.pathname === '/health') {
      return json({ ok: true, service: 'sky-ai-worker', env: env.ENVIRONMENT || 'unknown' });
    }

    if (request.method === 'POST' && url.pathname === '/ingest/mail-thread') {
      if (!(await authorizeHttpRequest(request, env)).ok) return unauthorized();
      return ingestMailThread(request, env);
    }

    if (request.method === 'POST' && url.pathname === '/mail/backfill') {
      if (!(await authorizeHttpRequest(request, env)).ok) return unauthorized();
      return queueBackfillRun(request, env);
    }

    if (request.method === 'POST' && url.pathname === '/mail/send') {
      if (!(await authorizeHttpRequest(request, env)).ok) return unauthorized();
      return queueOutboundMail(request, env);
    }

    if (request.method === 'GET' && url.pathname === '/mail/outbound/next') {
      if (!(await authorizeHttpRequest(request, env)).ok) return unauthorized();
      return claimNextOutboundMail(env);
    }

    if (request.method === 'POST' && url.pathname === '/mail/outbound/result') {
      if (!(await authorizeHttpRequest(request, env)).ok) return unauthorized();
      return markOutboundMailResult(request, env);
    }

    return json({ ok: false, error: 'Not found' }, 404);
  }
};

async function ingestMailThread(request: Request, env: Env): Promise<Response> {
  const payload = (await request.json()) as JsonRecord;
  const workspaceId = stringOr(payload.workspaceId) || 'default';
  const accountEmail = (stringOr(payload.accountEmail) || 'unknown').toLowerCase();
  const accountId = (stringOr(payload.accountId) || accountEmail).toLowerCase();
  const mailbox = stringOr(payload.mailbox) || 'INBOX';
  const threadExternalId = stringOr(payload.threadId);
  const providerUid = numberOr(payload.uid);
  const providerMessageId = stringOr(payload.messageId);
  const subject = stringOr(payload.subject) || '';
  const sentAt = stringOr(payload.date);

  if (!threadExternalId) {
    return json({ ok: false, error: 'threadId is required' }, 400);
  }

  const sourceMessageKey = buildSourceMessageKey({
    workspaceId,
    accountId,
    mailbox,
    providerUid,
    providerMessageId,
    threadExternalId,
    sentAt,
    subject
  });

  await ensureWorkspace(env, workspaceId);

  const existingMessage = await env.SKY_DB
    .prepare(
      `SELECT id FROM email_messages WHERE source_message_key = ? LIMIT 1`
    )
    .bind(sourceMessageKey)
    .first<{ id: string }>();

  if (existingMessage) {
    return json({ ok: true, deduped: true, messageId: existingMessage.id, sourceMessageKey });
  }

  const threadId = await upsertEmailThread(env, {
    workspaceId,
    accountId,
    accountEmail,
    mailbox,
    threadExternalId,
    subject,
    sentAt
  });

  const artifactKey = `mail/${workspaceId}/threads/${threadExternalId}/${Date.now()}-${safeForKey(sourceMessageKey)}.json`;
  await env.SKY_ARTIFACTS.put(artifactKey, JSON.stringify(payload), {
    httpMetadata: { contentType: 'application/json' }
  });

  const artifactId = crypto.randomUUID();
  await env.SKY_DB
    .prepare(
      `INSERT INTO artifacts (id, workspace_id, source, source_id, r2_key, metadata_json, created_at)
       VALUES (?, ?, 'mail_thread', ?, ?, ?, CURRENT_TIMESTAMP)`
    )
    .bind(
      artifactId,
      workspaceId,
      threadExternalId,
      artifactKey,
      JSON.stringify({ ingestedBy: 'imap-agent', sourceMessageKey, accountId, accountEmail, mailbox })
    )
    .run();

  const recordId = crypto.randomUUID();
  const snippet = buildSnippet(payload, subject);
  await env.SKY_DB
    .prepare(
      `INSERT INTO normalized_records (id, workspace_id, record_type, source_artifact_id, body_json, created_at, updated_at)
       VALUES (?, ?, 'email_message', ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)`
    )
    .bind(
      recordId,
      workspaceId,
      artifactId,
      JSON.stringify({
        accountId,
        accountEmail,
        mailbox,
        threadExternalId,
        providerUid,
        providerMessageId,
        subject,
        sentAt,
        snippet
      })
    )
    .run();

  const messageId = crypto.randomUUID();
  const fromAddresses = normalizeAddresses(payload.from);
  const toAddresses = normalizeAddresses(payload.to);
  const rawSource = stringOr(payload.rawRfc822) || '';
  const rawSha256 = rawSource ? await sha256Hex(rawSource) : null;

  await env.SKY_DB
    .prepare(
      `INSERT INTO email_messages
       (id, workspace_id, thread_id, account_id, account_email, mailbox, provider_uid, provider_message_id, source_message_key, subject,
        sent_at, from_json, to_json, snippet, artifact_id, raw_sha256, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)`
    )
    .bind(
      messageId,
      workspaceId,
      threadId,
      accountId,
      accountEmail,
      mailbox,
      providerUid,
      providerMessageId,
      sourceMessageKey,
      subject || null,
      sentAt,
      JSON.stringify(fromAddresses),
      JSON.stringify(toAddresses),
      snippet,
      artifactId,
      rawSha256
    )
    .run();

  await upsertParticipants(env, workspaceId, messageId, fromAddresses, 'from');
  await upsertParticipants(env, workspaceId, messageId, toAddresses, 'to');
  await updateThreadLastMessage(env, threadId, subject, sentAt);

  const chunkSource = buildChunkSource(payload, subject, snippet);
  const chunks = chunkText(chunkSource, CHUNK_SIZE, CHUNK_OVERLAP, MAX_CHUNKS_PER_MESSAGE);
  let embeddingWarning: string | null = null;
  let embeddingStatus: 'not_requested' | 'queued' | 'indexed' | 'retry' = 'not_requested';

  if (chunks.length > 0) {
    for (let i = 0; i < chunks.length; i += 1) {
      await env.SKY_DB
        .prepare(
          `INSERT INTO memory_chunks (id, workspace_id, account_id, source_record_id, vector_id, chunk_text, metadata_json, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)`
        )
        .bind(
          crypto.randomUUID(),
          workspaceId,
          accountId,
          recordId,
          `${messageId}:${i}`,
          chunks[i],
          JSON.stringify({ messageId, threadId, mailbox, accountId, accountEmail, sentAt, chunkIndex: i })
        )
        .run();
    }

    await enqueueEmbeddingJob(env, workspaceId, recordId);
    embeddingStatus = 'queued';
    if (!hasAiGatewayConfig(env)) embeddingWarning = 'embedding_not_configured';
  }

  return json({
    ok: true,
    deduped: false,
    messageId,
    artifactKey,
    sourceMessageKey,
    chunksIndexed: 0,
    embeddingStatus,
    warning: embeddingWarning
  });
}

async function upsertEmailThread(
  env: Env,
  input: {
    workspaceId: string;
    accountId: string;
    accountEmail: string;
    mailbox: string;
    threadExternalId: string;
    subject: string;
    sentAt: string | null;
  }
): Promise<string> {
  await env.SKY_DB
    .prepare(
      `INSERT OR IGNORE INTO email_threads
       (id, workspace_id, account_id, account_email, mailbox, thread_external_id, subject, first_message_at, last_message_at, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)`
    )
    .bind(
      crypto.randomUUID(),
      input.workspaceId,
      input.accountId,
      input.accountEmail,
      input.mailbox,
      input.threadExternalId,
      input.subject || null,
      input.sentAt,
      input.sentAt
    )
    .run();

  const row = await env.SKY_DB
    .prepare(
      `SELECT id FROM email_threads
       WHERE workspace_id = ? AND account_id = ? AND mailbox = ? AND thread_external_id = ?
       LIMIT 1`
    )
    .bind(input.workspaceId, input.accountId, input.mailbox, input.threadExternalId)
    .first<{ id: string }>();

  if (!row) {
    throw new Error('Failed to upsert thread');
  }

  return row.id;
}

async function updateThreadLastMessage(
  env: Env,
  threadId: string,
  subject: string,
  sentAt: string | null
): Promise<void> {
  await env.SKY_DB
    .prepare(
      `UPDATE email_threads
       SET subject = COALESCE(?, subject),
           last_message_at = COALESCE(?, last_message_at),
           updated_at = CURRENT_TIMESTAMP
       WHERE id = ?`
    )
    .bind(subject || null, sentAt, threadId)
    .run();
}

async function upsertParticipants(
  env: Env,
  workspaceId: string,
  messageId: string,
  addresses: NormalizedAddress[],
  role: 'from' | 'to'
): Promise<void> {
  for (const addr of addresses) {
    const participantId = crypto.randomUUID();
    await env.SKY_DB
      .prepare(
        `INSERT OR IGNORE INTO email_participants (id, workspace_id, email, display_name, created_at, updated_at)
         VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)`
      )
      .bind(participantId, workspaceId, addr.email, addr.name)
      .run();

    const participant = await env.SKY_DB
      .prepare(`SELECT id FROM email_participants WHERE workspace_id = ? AND email = ? LIMIT 1`)
      .bind(workspaceId, addr.email)
      .first<{ id: string }>();

    if (!participant) continue;

    await env.SKY_DB
      .prepare(
        `INSERT OR IGNORE INTO email_message_participants
         (id, workspace_id, message_id, participant_id, role, created_at)
         VALUES (?, ?, ?, ?, ?, CURRENT_TIMESTAMP)`
      )
      .bind(crypto.randomUUID(), workspaceId, messageId, participant.id, role)
      .run();
  }
}

async function queueBackfillRun(request: Request, env: Env): Promise<Response> {
  const payload = (await request.json()) as JsonRecord;
  const workspaceId = stringOr(payload.workspaceId) || 'default';
  const accountEmail = (stringOr(payload.accountEmail) || 'unknown').toLowerCase();
  const mailbox = stringOr(payload.mailbox) || 'INBOX';
  const sinceDate = stringOr(payload.sinceDate);
  const untilDate = stringOr(payload.untilDate);

  if (!sinceDate) {
    return json({ ok: false, error: 'sinceDate is required (YYYY-MM-DD)' }, 400);
  }

  await ensureWorkspace(env, workspaceId);

  const id = crypto.randomUUID();
  await env.SKY_DB
    .prepare(
      `INSERT INTO backfill_runs
       (id, workspace_id, account_email, mailbox, since_date, until_date, status, checkpoint_json, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, 'queued', ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)`
    )
    .bind(id, workspaceId, accountEmail, mailbox, sinceDate, untilDate, JSON.stringify({ stagedBy: 'api' }))
    .run();

  await enqueueSyncJob(env, 'mailbox_backfill', {
    backfillRunId: id,
    workspaceId,
    accountEmail,
    mailbox,
    sinceDate,
    untilDate
  });

  return json({ ok: true, backfillRunId: id, status: 'queued' });
}

async function enqueueEmbeddingJob(env: Env, workspaceId: string, sourceRecordId: string): Promise<void> {
  await env.SKY_DB
    .prepare(
      `INSERT OR IGNORE INTO embedding_jobs
       (id, workspace_id, source_record_id, status, attempts, next_attempt_at, last_error, created_at, updated_at)
       VALUES (?, ?, ?, 'queued', 0, CURRENT_TIMESTAMP, NULL, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)`
    )
    .bind(crypto.randomUUID(), workspaceId, sourceRecordId)
    .run();

  await enqueueEmbeddingQueueMessage(env, { sourceRecordId });
}

async function enqueueEmbeddingQueueMessage(env: Env, payload: EmbeddingQueueMessage): Promise<void> {
  if (!env.EMBEDDING_QUEUE) return;
  await env.EMBEDDING_QUEUE.send(payload);
}

async function processEmbeddingJobs(env: Env, limit: number): Promise<number> {
  const jobs = await env.SKY_DB
    .prepare(
      `SELECT id, source_record_id
       FROM embedding_jobs
       WHERE status IN ('queued', 'retry')
         AND datetime(next_attempt_at) <= datetime(CURRENT_TIMESTAMP)
       ORDER BY datetime(next_attempt_at) ASC
       LIMIT ?`
    )
    .bind(Math.max(1, Math.min(limit, 100)))
    .all<{ id: string; source_record_id: string }>();

  const rows = jobs.results || [];
  let processed = 0;
  for (const job of rows) {
    const result = await processSingleEmbeddingJob(env, job.source_record_id);
    if (result.status === 'indexed') {
      processed += 1;
    }
  }
  return processed;
}

async function processSingleEmbeddingJob(
  env: Env,
  sourceRecordId: string
): Promise<{ status: 'indexed' | 'retry'; warning: string | null }> {
  const job = await env.SKY_DB
    .prepare(
      `SELECT id, workspace_id, attempts
       FROM embedding_jobs
       WHERE source_record_id = ?
       LIMIT 1`
    )
    .bind(sourceRecordId)
    .first<{ id: string; workspace_id: string; attempts: number }>();

  if (!job) {
    return { status: 'retry', warning: 'embedding_job_missing' };
  }

  if (!hasAiGatewayConfig(env)) {
    const backoffMinutes = computeBackoffMinutes(Number(job.attempts || 0) + 1);
    await markEmbeddingJobRetry(env, job.id, Number(job.attempts || 0) + 1, 'embedding_not_configured', backoffMinutes);
    return { status: 'retry', warning: 'embedding_not_configured' };
  }

  const chunkRows = await env.SKY_DB
    .prepare(
      `SELECT vector_id, chunk_text, metadata_json
       FROM memory_chunks
       WHERE source_record_id = ?
       ORDER BY CAST(COALESCE(json_extract(metadata_json, '$.chunkIndex'), 0) AS INTEGER) ASC`
    )
    .bind(sourceRecordId)
    .all<{ vector_id: string | null; chunk_text: string; metadata_json: string | null }>();

  const chunks = (chunkRows.results || []).filter((x) => x.chunk_text).map((x) => x.chunk_text);
  if (chunks.length === 0) {
    await markEmbeddingJobIndexed(env, job.id, Number(job.attempts || 0) + 1);
    return { status: 'indexed', warning: null };
  }

  try {
    const embeddings = await callOpenAiEmbeddingsViaGateway(env, chunks);
    await env.SKY_VECTORIZE.upsert(
      embeddings.map((values, index) => ({
        id: chunkRows.results?.[index]?.vector_id || `${sourceRecordId}:${index}`,
        values,
        metadata: parseJsonObject(chunkRows.results?.[index]?.metadata_json)
      }))
    );

    await markEmbeddingJobIndexed(env, job.id, Number(job.attempts || 0) + 1);
    return { status: 'indexed', warning: null };
  } catch (error) {
    const message = error instanceof Error ? error.message : 'embedding_failed';
    const nextAttempts = Number(job.attempts || 0) + 1;
    const backoffMinutes = computeBackoffMinutes(nextAttempts);
    await markEmbeddingJobRetry(env, job.id, nextAttempts, message.slice(0, 1500), backoffMinutes);
    return { status: 'retry', warning: message };
  }
}

async function markEmbeddingJobIndexed(env: Env, jobId: string, attempts: number): Promise<void> {
  await env.SKY_DB
    .prepare(
      `UPDATE embedding_jobs
       SET status = 'indexed',
           attempts = ?,
           last_error = NULL,
           next_attempt_at = datetime(CURRENT_TIMESTAMP, '+3650 days'),
           updated_at = CURRENT_TIMESTAMP
       WHERE id = ?`
    )
    .bind(attempts, jobId)
    .run();
}

async function markEmbeddingJobRetry(
  env: Env,
  jobId: string,
  attempts: number,
  message: string,
  backoffMinutes: number
): Promise<void> {
  await env.SKY_DB
    .prepare(
      `UPDATE embedding_jobs
       SET status = 'retry',
           attempts = ?,
           last_error = ?,
           next_attempt_at = datetime(CURRENT_TIMESTAMP, ?),
           updated_at = CURRENT_TIMESTAMP
       WHERE id = ?`
    )
    .bind(attempts, message, `+${backoffMinutes} minutes`, jobId)
    .run();
}

function computeBackoffMinutes(attempts: number): number {
  return Math.min(240, Math.max(1, 2 ** Math.min(attempts, 8)));
}

async function ensureWorkspace(env: Env, workspaceId: string): Promise<void> {
  await env.SKY_DB
    .prepare(
      `INSERT OR IGNORE INTO workspaces (id, name, status, created_at, updated_at)
       VALUES (?, ?, 'active', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)`
    )
    .bind(workspaceId, workspaceId)
    .run();
}

async function runTriage(env: Env): Promise<Response> {
  if (!hasAiGatewayConfig(env)) {
    return json({ ok: true, noop: true, reason: 'missing_openai_api_key' });
  }

  await enqueueSyncJob(env, 'triage_inbox', { source: 'api' });
  return json({ ok: true, queued: 'triage_inbox' });
}

async function runDailyBriefing(env: Env): Promise<Response> {
  if (!hasAiGatewayConfig(env)) {
    return json({ ok: true, noop: true, reason: 'missing_openai_api_key' });
  }

  await enqueueSyncJob(env, 'daily_briefing', { source: 'api' });
  return json({ ok: true, queued: 'daily_briefing' });
}

async function runAiGatewayTest(env: Env): Promise<Response> {
  if (!hasAiGatewayConfig(env)) {
    return json({
      ok: false,
      error: 'Missing AI Gateway OpenAI configuration (OPENAI_API_KEY, AIG_ACCOUNT_ID, AIG_GATEWAY_ID).'
    }, 400);
  }

  try {
    const completion = await callOpenAiChatViaGateway(env, [
      { role: 'user', content: 'Respond with exactly: AI Gateway OpenAI ready.' }
    ]);
    return json({ ok: true, provider: 'openai-via-aigateway', completion });
  } catch (error) {
    return json(
      {
        ok: false,
        error: 'AI Gateway OpenAI test failed',
        details: error instanceof Error ? error.message : 'Unknown error'
      },
      500
    );
  }
}

async function enqueueSyncJob(env: Env, jobType: string, metadata: JsonRecord): Promise<void> {
  await env.SKY_DB
    .prepare(
      `INSERT INTO sync_jobs (id, job_type, status, metadata_json, created_at, updated_at)
       VALUES (?, ?, 'queued', ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)`
    )
    .bind(crypto.randomUUID(), jobType, JSON.stringify(metadata))
    .run();
}

async function queueOutboundMail(request: Request, env: Env): Promise<Response> {
  const payload = (await request.json()) as JsonRecord;
  const to = stringOr(payload.to);
  const subject = stringOr(payload.subject);
  const text = stringOr(payload.text);
  const html = stringOr(payload.html);

  if (!to || !subject || (!text && !html)) {
    return json({ ok: false, error: 'to, subject, and at least one of text/html are required' }, 400);
  }

  const id = crypto.randomUUID();
  await env.SKY_DB
    .prepare(
      `INSERT INTO outbound_messages
       (id, status, to_email, subject, text_body, html_body, error_message, created_at, updated_at, sent_at)
       VALUES (?, 'queued', ?, ?, ?, ?, NULL, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, NULL)`
    )
    .bind(id, to, subject, text || null, html || null)
    .run();

  return json({ ok: true, id, status: 'queued' });
}

async function claimNextOutboundMail(env: Env): Promise<Response> {
  const row = await env.SKY_DB
    .prepare(
      `SELECT id, to_email, subject, text_body, html_body
       FROM outbound_messages
       WHERE status = 'queued'
       ORDER BY created_at ASC
       LIMIT 1`
    )
    .first<{
      id: string;
      to_email: string;
      subject: string;
      text_body: string | null;
      html_body: string | null;
    }>();

  if (!row) {
    return json({ ok: true, item: null });
  }

  await env.SKY_DB
    .prepare(
      `UPDATE outbound_messages
       SET status = 'sending', updated_at = CURRENT_TIMESTAMP
       WHERE id = ?`
    )
    .bind(row.id)
    .run();

  return json({
    ok: true,
    item: {
      id: row.id,
      to: row.to_email,
      subject: row.subject,
      text: row.text_body,
      html: row.html_body
    }
  });
}

async function markOutboundMailResult(request: Request, env: Env): Promise<Response> {
  const payload = (await request.json()) as JsonRecord;
  const id = stringOr(payload.id);
  const status = stringOr(payload.status);
  const error = stringOr(payload.error);

  if (!id || (status !== 'sent' && status !== 'failed')) {
    return json({ ok: false, error: 'id and status(sent|failed) are required' }, 400);
  }

  if (status === 'sent') {
    await env.SKY_DB
      .prepare(
        `UPDATE outbound_messages
         SET status = 'sent', sent_at = CURRENT_TIMESTAMP, error_message = NULL, updated_at = CURRENT_TIMESTAMP
         WHERE id = ?`
      )
      .bind(id)
      .run();
    return json({ ok: true, id, status: 'sent' });
  }

  await env.SKY_DB
    .prepare(
      `UPDATE outbound_messages
       SET status = 'failed', error_message = ?, updated_at = CURRENT_TIMESTAMP
       WHERE id = ?`
    )
    .bind(error || 'unknown_error', id)
    .run();
  return json({ ok: true, id, status: 'failed' });
}

function normalizeAddresses(input: unknown): NormalizedAddress[] {
  if (!Array.isArray(input)) return [];

  const out: NormalizedAddress[] = [];
  for (const item of input) {
    if (!item || typeof item !== 'object') continue;
    const record = item as Record<string, unknown>;
    const email = stringOr(record.address) || stringOr(record.email);
    if (!email) continue;
    out.push({ email: email.toLowerCase(), name: stringOr(record.name) });
  }
  return out;
}

function buildSnippet(payload: JsonRecord, subject: string): string {
  const bodyText = stringOr(payload.bodyText);
  const raw = stringOr(payload.rawRfc822);
  const candidate = bodyText || raw || subject;
  return candidate.slice(0, 500);
}

function buildChunkSource(payload: JsonRecord, subject: string, fallbackSnippet: string): string {
  const bodyText = stringOr(payload.bodyText);
  if (bodyText) return bodyText.slice(0, MAX_CHUNK_SOURCE_CHARS);

  const raw = stringOr(payload.rawRfc822);
  if (raw) return raw.slice(0, MAX_CHUNK_SOURCE_CHARS);

  return `${subject}\n\n${fallbackSnippet}`.slice(0, MAX_CHUNK_SOURCE_CHARS);
}

function chunkText(text: string, size: number, overlap: number, maxChunks: number): string[] {
  const normalized = text.replace(/\s+/g, ' ').trim();
  if (!normalized) return [];

  const chunks: string[] = [];
  let start = 0;
  while (start < normalized.length && chunks.length < maxChunks) {
    const end = Math.min(normalized.length, start + size);
    chunks.push(normalized.slice(start, end));
    if (end >= normalized.length) break;
    start = Math.max(0, end - overlap);
  }

  return chunks;
}

function buildSourceMessageKey(input: {
  workspaceId: string;
  accountId: string;
  mailbox: string;
  providerUid: number | null;
  providerMessageId: string | null;
  threadExternalId: string;
  sentAt: string | null;
  subject: string;
}): string {
  if (input.providerUid !== null) {
    return `${input.workspaceId}:${input.accountId}:${input.mailbox}:uid:${input.providerUid}`;
  }

  if (input.providerMessageId) {
    return `${input.workspaceId}:${input.accountId}:mid:${input.providerMessageId}`;
  }

  return `${input.workspaceId}:${input.accountId}:${input.mailbox}:thread:${input.threadExternalId}:${input.sentAt || ''}:${input.subject}`;
}

function safeForKey(input: string): string {
  return input.replace(/[^a-zA-Z0-9._-]/g, '_').slice(0, 120);
}

async function sha256Hex(input: string): Promise<string> {
  const data = new TextEncoder().encode(input);
  const digest = await crypto.subtle.digest('SHA-256', data);
  return [...new Uint8Array(digest)].map((x) => x.toString(16).padStart(2, '0')).join('');
}

function numberOr(input: unknown): number | null {
  if (typeof input === 'number' && Number.isFinite(input)) {
    return Math.trunc(input);
  }

  if (typeof input === 'string' && input.trim()) {
    const n = Number(input);
    if (Number.isFinite(n)) {
      return Math.trunc(n);
    }
  }

  return null;
}

function parseJsonObject(input: string | null | undefined): Record<string, unknown> {
  if (!input) return {};
  try {
    const parsed = JSON.parse(input) as unknown;
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
      return parsed as Record<string, unknown>;
    }
    return {};
  } catch {
    return {};
  }
}

function stringOr(input: unknown): string | null {
  return typeof input === 'string' && input.trim() ? input.trim() : null;
}

function unauthorized(): Response {
  return json({ ok: false, error: 'unauthorized' }, 401);
}

const INGEST_AUTH_CACHE: {
  jwksUrl?: string;
  expiresAt?: number;
  keysByKid?: Record<string, JsonWebKey>;
} = {};

async function authorizeHttpRequest(
  request: Request,
  env: Env
): Promise<{ ok: true } | { ok: false }> {
  const apiKey = extractBearerToken(request);
  if (env.WORKER_API_KEY && apiKey === env.WORKER_API_KEY) {
    return { ok: true };
  }

  if (env.ACCESS_AUTH_ENABLED !== 'true') {
    return env.WORKER_API_KEY ? { ok: false } : { ok: true };
  }

  const jwt = request.headers.get('cf-access-jwt-assertion') || apiKey;
  if (!jwt) return { ok: false };

  try {
    await verifyAccessJwt(jwt, env);
    return { ok: true };
  } catch {
    return { ok: false };
  }
}

async function verifyAccessJwt(token: string, env: Env): Promise<void> {
  const [encodedHeader, encodedPayload, encodedSig] = token.split('.');
  if (!encodedHeader || !encodedPayload || !encodedSig) throw new Error('malformed_jwt');

  const header = JSON.parse(decodeBase64Url(encodedHeader)) as { kid?: string; alg?: string };
  if (header.alg !== 'RS256' || !header.kid) throw new Error('unsupported_alg_or_missing_kid');

  const jwks = await getJwks(env);
  const jwk = jwks[header.kid];
  if (!jwk) throw new Error('jwks_kid_not_found');

  const key = await crypto.subtle.importKey(
    'jwk',
    jwk,
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['verify']
  );

  const signed = new TextEncoder().encode(`${encodedHeader}.${encodedPayload}`);
  const signature = decodeBase64UrlToBytes(encodedSig);
  const valid = await crypto.subtle.verify('RSASSA-PKCS1-v1_5', key, signature, signed);
  if (!valid) throw new Error('invalid_signature');

  const claims = JSON.parse(decodeBase64Url(encodedPayload)) as Record<string, unknown>;
  const now = Math.floor(Date.now() / 1000);
  if (typeof claims.exp !== 'number' || claims.exp <= now) throw new Error('expired');
  if (typeof claims.nbf === 'number' && claims.nbf > now) throw new Error('not_yet_valid');

  if (env.ACCESS_ISSUER && typeof claims.iss === 'string') {
    if (claims.iss.replace(/\/+$/, '') !== env.ACCESS_ISSUER.replace(/\/+$/, '')) {
      throw new Error('issuer_mismatch');
    }
  }

  if (env.ACCESS_AUD) {
    const aud = claims.aud;
    const ok = typeof aud === 'string' ? aud === env.ACCESS_AUD : Array.isArray(aud) && aud.includes(env.ACCESS_AUD);
    if (!ok) throw new Error('audience_mismatch');
  }
}

async function getJwks(env: Env): Promise<Record<string, JsonWebKey>> {
  const jwksUrl = env.ACCESS_JWKS_URL || (env.ACCESS_ISSUER ? `${env.ACCESS_ISSUER.replace(/\/+$/, '')}/cdn-cgi/access/certs` : null);
  if (!jwksUrl) throw new Error('missing_jwks_url');

  const now = Date.now();
  if (INGEST_AUTH_CACHE.jwksUrl === jwksUrl && INGEST_AUTH_CACHE.expiresAt && INGEST_AUTH_CACHE.expiresAt > now && INGEST_AUTH_CACHE.keysByKid) {
    return INGEST_AUTH_CACHE.keysByKid;
  }

  const res = await fetch(jwksUrl, { method: 'GET' });
  if (!res.ok) throw new Error('jwks_fetch_failed');
  const body = (await res.json()) as { keys?: JsonWebKey[] };
  const out: Record<string, JsonWebKey> = {};
  for (const key of body.keys || []) {
    if (key.kid) out[key.kid] = key;
  }

  INGEST_AUTH_CACHE.jwksUrl = jwksUrl;
  INGEST_AUTH_CACHE.keysByKid = out;
  INGEST_AUTH_CACHE.expiresAt = now + 10 * 60 * 1000;
  return out;
}

function extractBearerToken(request: Request): string | null {
  const auth = request.headers.get('authorization') || '';
  const match = auth.match(/^Bearer\s+(.+)$/i);
  return match ? match[1].trim() : null;
}

function decodeBase64Url(input: string): string {
  const bytes = decodeBase64UrlToBytes(input);
  return new TextDecoder().decode(bytes);
}

function decodeBase64UrlToBytes(input: string): Uint8Array {
  const normalized = input.replace(/-/g, '+').replace(/_/g, '/');
  const padded = normalized + '='.repeat((4 - (normalized.length % 4)) % 4);
  const bin = atob(padded);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i += 1) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

function hasAiGatewayConfig(env: Env): boolean {
  return Boolean(env.OPENAI_API_KEY && env.AIG_ACCOUNT_ID && env.AIG_GATEWAY_ID);
}

async function callOpenAiChatViaGateway(
  env: Env,
  messages: Array<{ role: 'user' | 'assistant'; content: string }>
): Promise<string> {
  const gatewayUrl =
    `https://gateway.ai.cloudflare.com/v1/${env.AIG_ACCOUNT_ID}/${env.AIG_GATEWAY_ID}/openai/v1/chat/completions`;

  const headers: Record<string, string> = {
    'content-type': 'application/json',
    authorization: `Bearer ${env.OPENAI_API_KEY as string}`
  };

  if (env.CF_AIG_AUTH_TOKEN) {
    headers['cf-aig-authorization'] = `Bearer ${env.CF_AIG_AUTH_TOKEN}`;
  }

  const response = await fetch(gatewayUrl, {
    method: 'POST',
    headers,
    body: JSON.stringify({
      model: env.OPENAI_MODEL || 'gpt-4o-mini',
      max_tokens: 120,
      messages
    })
  });

  if (!response.ok) {
    const text = await response.text();
    throw new Error(`Gateway request failed (${response.status}): ${text.slice(0, 500)}`);
  }

  const body = (await response.json()) as {
    choices?: Array<{ message?: { content?: string } }>;
  };
  return body.choices?.[0]?.message?.content || '';
}

async function callOpenAiEmbeddingsViaGateway(env: Env, chunks: string[]): Promise<number[][]> {
  const gatewayUrl =
    `https://gateway.ai.cloudflare.com/v1/${env.AIG_ACCOUNT_ID}/${env.AIG_GATEWAY_ID}/openai/v1/embeddings`;

  const headers: Record<string, string> = {
    'content-type': 'application/json',
    authorization: `Bearer ${env.OPENAI_API_KEY as string}`
  };

  if (env.CF_AIG_AUTH_TOKEN) {
    headers['cf-aig-authorization'] = `Bearer ${env.CF_AIG_AUTH_TOKEN}`;
  }

  const response = await fetch(gatewayUrl, {
    method: 'POST',
    headers,
    body: JSON.stringify({
      model: env.OPENAI_EMBEDDING_MODEL || 'text-embedding-3-small',
      input: chunks
    })
  });

  if (!response.ok) {
    const text = await response.text();
    throw new Error(`Embedding request failed (${response.status}): ${text.slice(0, 500)}`);
  }

  const body = (await response.json()) as {
    data?: Array<{ embedding?: number[] }>;
  };

  const vectors = (body.data || []).map((x) => x.embedding || []);
  if (vectors.length !== chunks.length || vectors.some((v) => v.length === 0)) {
    throw new Error('Embedding response did not match requested chunk count');
  }

  return vectors;
}

function json(payload: JsonRecord, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8' }
  });
}
