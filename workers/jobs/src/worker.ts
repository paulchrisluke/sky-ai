import { extractBearerToken, verifyAccessJwtClaims, type AccessAuthEnv } from '../../shared/auth';

interface Env extends AccessAuthEnv {
  SKY_DB: D1Database;
  SKY_VECTORIZE: VectorizeIndex;
  AI?: {
    run(model: string, input: Record<string, unknown>): Promise<unknown>;
  };
  WORKER_API_KEY?: string;
  ACCESS_AUTH_ENABLED?: string;
  OPENAI_API_KEY?: string;
  CF_AIG_AUTH_TOKEN?: string;
  AIG_ACCOUNT_ID?: string;
  AIG_GATEWAY_ID?: string;
  OPENAI_MODEL?: string;
  OPENAI_EMBEDDING_MODEL?: string;
  WORKERS_AI_EMBEDDING_MODEL?: string;
  VECTOR_DIMENSIONS?: string;
  ENVIRONMENT?: string;
}

type JsonRecord = Record<string, unknown>;

type SyncJobRow = {
  id: string;
  job_type: string;
  metadata_json: string | null;
};

type BriefingPayload = {
  date: string;
  account_id: string;
  workspace_id: string;
  sections: {
    urgent_threads: Array<Record<string, unknown>>;
    sla_breaches: Array<Record<string, unknown>>;
    sla_fallback_count: number;
    due_tasks: Array<Record<string, unknown>>;
    open_proposals: Array<Record<string, unknown>>;
    triage_stats: Array<Record<string, unknown>>;
  };
  generated_at: string;
};

type ThreadClassification = {
  priority: 'P0' | 'P1' | 'P2' | 'P3';
  category: 'customer_support' | 'vendor' | 'legal' | 'financial' | 'personal';
  needs_reply: boolean;
  sentiment: 'urgent' | 'neutral' | 'positive';
  suggested_action: 'reply' | 'archive' | 'forward' | 'escalate';
  confidence: number;
  classifier_version: string;
  reasons: string[];
};

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === 'GET' && url.pathname === '/health') {
      return json({ ok: true, service: 'sky-ai-jobs', env: env.ENVIRONMENT || 'unknown' });
    }

    if (request.method === 'POST' && url.pathname === '/jobs/embeddings/process') {
      if (!(await authorizeHttpRequest(request, env)).ok) return unauthorized();
      const processed = await processEmbeddingJobs(env, 200);
      return json({ ok: true, processed });
    }

    if (request.method === 'POST' && url.pathname === '/jobs/embeddings/reclean-noisy') {
      if (!(await authorizeHttpRequest(request, env)).ok) return unauthorized();
      const body = (await request.json().catch(() => ({}))) as JsonRecord;
      const limit = Math.max(1, Math.min(numberOr(body.limit) || 500, 5000));
      const dryRun = body.dryRun === true;
      const processNow = body.processNow === true;
      const result = await recleanNoisyChunksAndQueue(env, { limit, dryRun, processNow });
      return json({ ok: true, ...result });
    }

    if (request.method === 'POST' && url.pathname === '/jobs/triage/reclassify') {
      if (!(await authorizeHttpRequest(request, env)).ok) return unauthorized();
      const body = (await request.json().catch(() => ({}))) as JsonRecord;
      const limit = Math.max(1, Math.min(numberOr(body.limit) || 500, 5000));
      const dryRun = body.dryRun === true;
      const result = await reclassifyThreads(env, { limit, dryRun });
      return json({ ok: true, ...result });
    }

    if (request.method === 'POST' && url.pathname === '/jobs/briefing/generate-now') {
      if (!(await authorizeHttpRequest(request, env)).ok) return unauthorized();
      const body = (await request.json().catch(() => ({}))) as JsonRecord;
      const workspaceId = stringOr(body.workspaceId) || 'default';
      const accountId = stringOr(body.accountId) || '';
      if (!accountId) return json({ ok: false, error: 'accountId is required' }, 400);

      const workspaceTimezone = await getWorkspaceTimezone(env, workspaceId);
      const localDate = getLocalDateHour(workspaceTimezone).date;
      const fakeJob: SyncJobRow = {
        id: crypto.randomUUID(),
        job_type: 'daily_briefing',
        metadata_json: JSON.stringify({
          source: 'manual',
          workspaceId,
          accountId,
          localDate,
          timezone: workspaceTimezone
        })
      };
      const briefingId = await processDailyBriefing(fakeJob, env);
      return json({ ok: true, briefing_id: briefingId, message: 'Briefing generated successfully' });
    }

    if (request.method === 'POST' && url.pathname === '/jobs/sync/process') {
      if (!(await authorizeHttpRequest(request, env)).ok) return unauthorized();
      const body = (await request.json().catch(() => ({}))) as JsonRecord;
      const limit = Math.max(1, Math.min(numberOr(body.limit) || 20, 200));
      const processed = await processSyncJobs(env, limit);
      return json({ ok: true, processed });
    }

    return json({ ok: false, error: 'Not found' }, 404);
  },

  async scheduled(controller: ScheduledController, env: Env): Promise<void> {
    if (controller.cron === '*/15 * * * *') {
      await enqueueSyncJob(env, 'mailbox_incremental_sync', { source: 'jobs_cron' });
      await processEmbeddingJobs(env, 200);
      await processSyncJobs(env, 20);
      return;
    }

    if (controller.cron === '0 * * * *') {
      await maybeEnqueueMorningBriefing(env);
      await processEmbeddingJobs(env, 200);
      await processSyncJobs(env, 20);
    }
  },

  async queue(batch: { messages?: Array<{ body?: unknown }> }, env: Env): Promise<void> {
    const messages = batch.messages || [];
    for (const message of messages) {
      const body = (message.body || {}) as Record<string, unknown>;
      const sourceRecordId = stringOr(body.sourceRecordId);
      if (!sourceRecordId) continue;
      await processSingleEmbeddingJob(env, sourceRecordId);
    }
  }
};

async function maybeEnqueueMorningBriefing(env: Env): Promise<void> {
  const targetHour = 7;
  const scopes = await getBriefingScopes(env);
  for (const scope of scopes) {
    const local = getLocalDateHour(scope.timezone);
    if (local.hour !== targetHour) continue;

    const existing = await env.SKY_DB
      .prepare(
        `SELECT id
         FROM sync_jobs
         WHERE job_type = 'daily_briefing'
           AND status IN ('queued', 'running', 'complete')
           AND json_extract(metadata_json, '$.source') = 'jobs_cron'
           AND json_extract(metadata_json, '$.timezone') = ?
           AND json_extract(metadata_json, '$.localDate') = ?
           AND lower(json_extract(metadata_json, '$.workspaceId')) = lower(?)
           AND json_extract(metadata_json, '$.accountId') = ?
         LIMIT 1`
      )
      .bind(scope.timezone, local.date, scope.workspaceId, scope.accountId)
      .first<{ id: string }>();

    if (existing?.id) continue;

    await enqueueSyncJob(env, 'daily_briefing', {
      source: 'jobs_cron',
      timezone: scope.timezone,
      localDate: local.date,
      localHour: local.hour,
      workspaceId: scope.workspaceId,
      accountId: scope.accountId
    });
  }
}

function getLocalDateHour(timezone: string): { date: string; hour: number } {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: timezone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    hour12: false
  }).formatToParts(new Date());

  const get = (t: Intl.DateTimeFormatPartTypes): string => parts.find((x) => x.type === t)?.value || '';
  const year = get('year');
  const month = get('month');
  const day = get('day');
  const hour = Number(get('hour') || '0');
  return { date: `${year}-${month}-${day}`, hour: Number.isFinite(hour) ? hour : 0 };
}

async function getBriefingScopes(env: Env): Promise<Array<{ workspaceId: string; accountId: string; timezone: string }>> {
  try {
    const rows = await env.SKY_DB
      .prepare(
        `SELECT a.workspace_id, a.id AS account_id, w.timezone
         FROM accounts a
         JOIN workspaces w ON w.id = a.workspace_id
         WHERE a.status = 'active'`
      )
      .all<{ workspace_id: string; account_id: string; timezone: string | null }>();
    const out = (rows.results || [])
      .map((r) => ({
        workspaceId: r.workspace_id,
        accountId: r.account_id,
        timezone: normalizeTimezone(r.timezone)
      }))
      .filter((x) => x.workspaceId && x.accountId && x.timezone);
    if (out.length > 0) return out;
  } catch {
    // fall through to email_threads fallback
  }

  const rows = await env.SKY_DB
    .prepare(
      `SELECT DISTINCT t.workspace_id, t.account_id, w.timezone
       FROM email_threads t
       JOIN workspaces w ON w.id = t.workspace_id
       WHERE account_id IS NOT NULL
       LIMIT 500`
    )
    .all<{ workspace_id: string; account_id: string; timezone: string | null }>();
  return (rows.results || [])
    .map((r) => ({
      workspaceId: r.workspace_id,
      accountId: r.account_id,
      timezone: normalizeTimezone(r.timezone)
    }))
    .filter((x) => x.workspaceId && x.accountId && x.timezone);
}

async function getWorkspaceTimezone(env: Env, workspaceId: string): Promise<string> {
  const row = await env.SKY_DB
    .prepare(
      `SELECT timezone
       FROM workspaces
       WHERE id = ?
       LIMIT 1`
    )
    .bind(workspaceId)
    .first<{ timezone: string | null }>();
  return normalizeTimezone(row?.timezone);
}

function normalizeTimezone(value: string | null | undefined): string {
  const tz = (value || '').trim();
  return tz || 'America/Chicago';
}

async function processSyncJobs(env: Env, limit: number): Promise<number> {
  const rows = await env.SKY_DB
    .prepare(
      `SELECT id, job_type, metadata_json
       FROM sync_jobs
       WHERE status IN ('queued', 'retry')
         AND job_type = 'daily_briefing'
       ORDER BY created_at ASC
       LIMIT ?`
    )
    .bind(limit)
    .all<SyncJobRow>();

  let processed = 0;
  for (const row of rows.results || []) {
    await env.SKY_DB
      .prepare(`UPDATE sync_jobs SET status = 'running', updated_at = CURRENT_TIMESTAMP WHERE id = ?`)
      .bind(row.id)
      .run();

    try {
      const briefingId = await processDailyBriefing(row, env);
      await env.SKY_DB
        .prepare(
          `UPDATE sync_jobs
           SET status = 'complete',
               metadata_json = json_set(COALESCE(metadata_json, '{}'), '$.briefingId', ?),
               updated_at = CURRENT_TIMESTAMP
           WHERE id = ?`
        )
        .bind(briefingId, row.id)
        .run();
      processed += 1;
    } catch (error) {
      const message = error instanceof Error ? error.message : 'daily_briefing_failed';
      await env.SKY_DB
        .prepare(
          `UPDATE sync_jobs
           SET status = 'retry',
               error_message = ?,
               updated_at = CURRENT_TIMESTAMP
           WHERE id = ?`
        )
        .bind(message.slice(0, 1500), row.id)
        .run();
    }
  }

  return processed;
}

async function processDailyBriefing(job: SyncJobRow, env: Env): Promise<string> {
  const metadata = parseJsonObject(job.metadata_json);
  const workspaceId = stringOr(metadata.workspaceId) || 'default';
  const accountId = stringOr(metadata.accountId) || '';
  if (!accountId) throw new Error('daily_briefing_missing_account_id');

  const timezone = await getWorkspaceTimezone(env, workspaceId);
  const localDate = stringOr(metadata.localDate) || getLocalDateHour(timezone).date;

  const [urgentThreads, slaBreaches, dueTasks, openProposals, triageStats] = await Promise.all([
    env.SKY_DB
      .prepare(
        `SELECT t.id, t.subject, t.last_message_at, t.classification_json
         FROM email_threads t
         WHERE t.workspace_id = ?
           AND t.account_id = ?
           AND CAST(COALESCE(json_extract(t.classification_json, '$.needs_reply'), 0) AS INTEGER) = 1
           AND json_extract(t.classification_json, '$.priority') IN ('P0', 'P1')
         ORDER BY datetime(COALESCE(t.last_message_at, t.updated_at)) DESC
         LIMIT 10`
      )
      .bind(workspaceId, accountId)
      .all<Record<string, unknown>>(),
    env.SKY_DB
      .prepare(
        `WITH agent_sla AS (
           SELECT aa.account_id, MIN(a.response_sla_hours) AS response_sla_hours
           FROM agent_accounts aa
           JOIN agents a ON a.id = aa.agent_id
           GROUP BY aa.account_id
         ),
         thread_scope AS (
           SELECT
             t.id,
             t.subject,
             t.last_message_at,
             t.classification_json,
             t.last_inbound_at,
             t.last_outbound_at,
             CASE
               WHEN COALESCE(agent_sla.response_sla_hours, 48) > 0 THEN COALESCE(agent_sla.response_sla_hours, 48)
               ELSE 48
             END AS response_sla_hours,
             CASE
               WHEN agent_sla.response_sla_hours IS NULL OR agent_sla.response_sla_hours <= 0 THEN 1
               ELSE 0
             END AS used_fallback_sla,
             CASE
               WHEN t.last_inbound_at IS NULL THEN NULL
               WHEN t.last_outbound_at IS NULL THEN t.last_inbound_at
               WHEN datetime(t.last_outbound_at) < datetime(t.last_inbound_at) THEN t.last_inbound_at
               ELSE NULL
             END AS pending_reply_since
           FROM email_threads t
           LEFT JOIN agent_sla ON agent_sla.account_id = t.account_id
           WHERE t.workspace_id = ?
             AND t.account_id = ?
             AND CAST(COALESCE(json_extract(t.classification_json, '$.needs_reply'), 0) AS INTEGER) = 1
         )
         SELECT
           id,
           subject,
           last_message_at,
           classification_json,
           last_inbound_at,
           last_outbound_at,
           response_sla_hours,
           used_fallback_sla,
           pending_reply_since
         FROM thread_scope
         WHERE pending_reply_since IS NOT NULL
           AND datetime(pending_reply_since) < datetime(CURRENT_TIMESTAMP, '-' || response_sla_hours || ' hours')
         ORDER BY datetime(pending_reply_since) ASC
         LIMIT 10`
      )
      .bind(workspaceId, accountId)
      .all<Record<string, unknown>>(),
    env.SKY_DB
      .prepare(
        `SELECT id, title, priority, due_at, source_type
         FROM tasks
         WHERE workspace_id = ?
           AND account_id = ?
           AND status = 'open'
           AND (due_at IS NULL OR datetime(due_at) <= datetime(CURRENT_TIMESTAMP, '+24 hours'))
         ORDER BY
           CASE lower(COALESCE(priority, 'p2'))
             WHEN 'p0' THEN 0
             WHEN 'p1' THEN 1
             WHEN 'high' THEN 1
             WHEN 'p2' THEN 2
             WHEN 'medium' THEN 2
             WHEN 'p3' THEN 3
             ELSE 4
           END ASC,
           datetime(COALESCE(due_at, '2999-12-31')) ASC
         LIMIT 10`
      )
      .bind(workspaceId, accountId)
      .all<Record<string, unknown>>(),
    env.SKY_DB
      .prepare(
        `SELECT id,
                type,
                COALESCE(
                  json_extract(draft_payload_json, '$.title'),
                  json_extract(draft_payload_json, '$.subject'),
                  type
                ) AS title,
                risk_level,
                created_at
         FROM proposals
         WHERE workspace_id = ?
           AND account_id = ?
           AND status = 'proposed'
         ORDER BY datetime(created_at) DESC
         LIMIT 10`
      )
      .bind(workspaceId, accountId)
      .all<Record<string, unknown>>(),
    env.SKY_DB
      .prepare(
        `SELECT json_extract(classification_json, '$.priority') AS priority, COUNT(*) AS count
         FROM email_threads
         WHERE workspace_id = ?
           AND account_id = ?
           AND date(COALESCE(last_message_at, updated_at)) = date('now', 'utc')
         GROUP BY priority`
      )
      .bind(workspaceId, accountId)
      .all<Record<string, unknown>>()
  ]);

  const payload: BriefingPayload = {
    date: localDate,
    account_id: accountId,
    workspace_id: workspaceId,
    sections: {
      urgent_threads: urgentThreads.results || [],
      sla_breaches: slaBreaches.results || [],
      sla_fallback_count: (slaBreaches.results || []).reduce((sum, row) => {
        const v = Number(row.used_fallback_sla || 0);
        return sum + (Number.isFinite(v) ? v : 0);
      }, 0),
      due_tasks: dueTasks.results || [],
      open_proposals: openProposals.results || [],
      triage_stats: triageStats.results || []
    },
    generated_at: new Date().toISOString()
  };

  const narrative = await generateBriefingNarrative(payload, env);

  const existing = await env.SKY_DB
    .prepare(
      `SELECT id
       FROM briefings
       WHERE workspace_id = ?
         AND account_id = ?
         AND briefing_date = ?
         AND status = 'ready'
       ORDER BY datetime(created_at) DESC
       LIMIT 1`
    )
    .bind(workspaceId, accountId, localDate)
    .first<{ id: string }>();

  const briefingId = existing?.id || crypto.randomUUID();
  if (existing?.id) {
    await env.SKY_DB
      .prepare(
        `UPDATE briefings
         SET narrative = ?,
             payload_json = ?,
             content_json = ?,
             status = 'ready',
             delivery_status = 'ready',
             generated_at = ?,
             updated_at = CURRENT_TIMESTAMP
         WHERE id = ?`
      )
      .bind(narrative, JSON.stringify(payload), JSON.stringify(payload), payload.generated_at, briefingId)
      .run();
  } else {
    await env.SKY_DB
      .prepare(
        `INSERT INTO briefings
         (id, workspace_id, account_id, briefing_date, channel, content_json, payload_json, narrative, delivery_status, status, generated_at, created_at, updated_at)
         VALUES (?, ?, ?, ?, 'morning', ?, ?, ?, 'ready', 'ready', ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)`
      )
      .bind(
        briefingId,
        workspaceId,
        accountId,
        localDate,
        JSON.stringify(payload),
        JSON.stringify(payload),
        narrative,
        payload.generated_at
      )
      .run();
  }

  return briefingId;
}

async function generateBriefingNarrative(payload: BriefingPayload, env: Env): Promise<string> {
  const urgent = payload.sections.urgent_threads;
  const breaches = payload.sections.sla_breaches;
  const tasks = payload.sections.due_tasks;
  const proposals = payload.sections.open_proposals;

  const prompt = [
    'You are a chief of staff preparing a morning briefing.',
    'Be concise, direct, and prioritized. No filler.',
    `Today is ${payload.date}.`,
    '',
    'DATA:',
    'Urgent emails needing reply (P0/P1):',
    formatLines(urgent, (t) => `- ${(t.subject as string) || '(no subject)'} | last: ${(t.last_message_at as string) || 'unknown'}`),
    '',
    'SLA breaches (pending reply older than configured SLA):',
    formatLines(
      breaches,
      (t) =>
        `- ${(t.subject as string) || '(no subject)'} | pending since: ${(t.pending_reply_since as string) || 'unknown'} | SLA: ${String(t.response_sla_hours || 48)}h`
    ),
    '',
    'Tasks due today or overdue:',
    formatLines(tasks, (t) => `- [${(t.priority as string) || 'P2'}] ${(t.title as string) || '(untitled)'} | due: ${(t.due_at as string) || 'unspecified'}`),
    '',
    'Open proposals awaiting approval:',
    formatLines(proposals, (p) => `- ${(p.title as string) || '(untitled)'} | risk: ${(p.risk_level as string) || 'low'}`),
    '',
    'Write a morning briefing with sections:',
    '1. URGENT',
    '2. OVERDUE',
    '3. TODAY',
    '4. PENDING',
    '',
    'Keep each section to 2-4 bullet points maximum.'
  ].join('\n');

  if (!hasAiGatewayConfig(env)) {
    return [
      'URGENT',
      ...toSimpleBullets(urgent, (t) => `${(t.subject as string) || '(no subject)'} — reply needed`),
      '',
      'OVERDUE',
      ...toSimpleBullets(breaches, (t) => `${(t.subject as string) || '(no subject)'} — SLA breach`),
      '',
      'TODAY',
      ...toSimpleBullets(tasks, (t) => `${(t.title as string) || '(untitled task)'}`),
      '',
      'PENDING',
      ...toSimpleBullets(proposals, (p) => `${(p.title as string) || '(untitled proposal)'}`)
    ].join('\n');
  }

  try {
    return await callOpenAiChatViaGateway(env, [{ role: 'user', content: prompt }]);
  } catch {
    return [
      'URGENT',
      ...toSimpleBullets(urgent, (t) => `${(t.subject as string) || '(no subject)'} — reply needed`),
      '',
      'OVERDUE',
      ...toSimpleBullets(breaches, (t) => `${(t.subject as string) || '(no subject)'} — SLA breach`),
      '',
      'TODAY',
      ...toSimpleBullets(tasks, (t) => `${(t.title as string) || '(untitled task)'}`),
      '',
      'PENDING',
      ...toSimpleBullets(proposals, (p) => `${(p.title as string) || '(untitled proposal)'}`)
    ].join('\n');
  }
}

function formatLines<T>(items: T[], toLine: (item: T) => string): string {
  if (items.length === 0) return 'None';
  return items.slice(0, 10).map(toLine).join('\n');
}

function toSimpleBullets<T>(items: T[], toText: (item: T) => string): string[] {
  if (items.length === 0) return ['- None'];
  return items.slice(0, 4).map((x) => `- ${toText(x)}`);
}

async function reclassifyThreads(
  env: Env,
  input: { limit: number; dryRun: boolean }
): Promise<{ scanned: number; updated: number; dryRun: boolean }> {
  const rows = await env.SKY_DB
    .prepare(
      `SELECT
          t.id AS thread_id,
          t.mailbox AS mailbox,
          COALESCE(m.subject, t.subject, '') AS subject,
          COALESCE(m.snippet, '') AS snippet,
          COALESCE(m.from_json, '[]') AS from_json
       FROM email_threads t
       LEFT JOIN email_messages m
         ON m.id = (
           SELECT mm.id
           FROM email_messages mm
           WHERE mm.thread_id = t.id
           ORDER BY datetime(COALESCE(mm.sent_at, mm.created_at)) DESC, mm.created_at DESC
           LIMIT 1
         )
       WHERE t.classification_json IS NULL
          OR json_extract(t.classification_json, '$.classifier_version') IS NULL
          OR json_extract(t.classification_json, '$.classifier_version') != 'triage-heuristic-v1'
       LIMIT ?`
    )
    .bind(input.limit)
    .all<{ thread_id: string; mailbox: string; subject: string; snippet: string; from_json: string }>();

  let updated = 0;
  for (const row of rows.results || []) {
    const from = parseFromJson(row.from_json);
    const classification = classifyEmailThread({
      subject: row.subject,
      snippet: row.snippet,
      from,
      mailbox: row.mailbox
    });

    if (!input.dryRun) {
      await env.SKY_DB
        .prepare(
          `UPDATE email_threads
           SET classification_json = ?,
               classification_updated_at = CURRENT_TIMESTAMP,
               updated_at = CURRENT_TIMESTAMP
           WHERE id = ?`
        )
        .bind(JSON.stringify(classification), row.thread_id)
        .run();
    }
    updated += 1;
  }

  return { scanned: Number(rows.results?.length || 0), updated, dryRun: input.dryRun };
}

function parseFromJson(raw: string): string[] {
  try {
    const parsed = JSON.parse(raw) as Array<Record<string, unknown>>;
    if (!Array.isArray(parsed)) return [];
    return parsed
      .map((x) => stringOr(x.email) || stringOr(x.address))
      .filter((x): x is string => Boolean(x))
      .map((x) => x.trim());
  } catch {
    return [];
  }
}

function classifyEmailThread(input: {
  subject: string;
  snippet: string;
  from: string[];
  mailbox: string;
}): ThreadClassification {
  const text = `${input.subject}\n${input.snippet}`.toLowerCase();
  const senderText = input.from.join(' ').toLowerCase();
  const reasons: string[] = [];

  const has = (patterns: RegExp[]): boolean => patterns.some((p) => p.test(text));

  const urgentPatterns = [/\burgent\b/, /\basap\b/, /\bimmediately\b/, /\bcritical\b/, /\baction required\b/, /\boverdue\b/];
  const positivePatterns = [/\bthank(s| you)?\b/, /\bappreciate\b/, /\bgreat\b/, /\bawesome\b/, /\bexcited\b/, /\blove\b/];
  const replyPatterns = [/\?/, /\bplease (reply|respond|confirm|review)\b/, /\bcan you\b/, /\blet me know\b/, /\bfollow up\b/];

  const customerSupportPatterns = [
    /\bcustomer\b/,
    /\bsupport\b/,
    /\bhelp\b/,
    /\bissue\b/,
    /\bproblem\b/,
    /\breturn\b/,
    /\bwarranty\b/,
    /\btracking\b/,
    /\border\b/
  ];
  const vendorPatterns = [/\bvendor\b/, /\bsupplier\b/, /\bmanufacturer\b/, /\bpo\b/, /\bpurchase order\b/, /\bshipment\b/, /\binventory\b/];
  const legalPatterns = [/\bcontract\b/, /\bagreement\b/, /\bnda\b/, /\blegal\b/, /\battorney\b/, /\bcounsel\b/, /\bcompliance\b/];
  const financialPatterns = [/\binvoice\b/, /\bpayment\b/, /\brefund\b/, /\bchargeback\b/, /\bbilling\b/, /\btax\b/, /\breceipt\b/];
  const personalPatterns = [/\bwife\b/, /\bfamily\b/, /\bdad\b/, /\bmom\b/, /\bkid(s)?\b/, /\bbirthday\b/, /\bvalentine\b/, /\bdoctor\b/, /\bdinner\b/];

  let category: ThreadClassification['category'] = 'customer_support';
  if (has(legalPatterns)) category = 'legal';
  else if (has(financialPatterns)) category = 'financial';
  else if (has(vendorPatterns)) category = 'vendor';
  else if (has(personalPatterns) || /\bme\.com\b/.test(senderText)) category = 'personal';
  else if (has(customerSupportPatterns)) category = 'customer_support';
  reasons.push(`category:${category}`);

  const urgent = has(urgentPatterns);
  const needsReply = has(replyPatterns) || /inbox/i.test(input.mailbox);
  const positive = !urgent && has(positivePatterns);

  let sentiment: ThreadClassification['sentiment'] = 'neutral';
  if (urgent) sentiment = 'urgent';
  else if (positive) sentiment = 'positive';
  reasons.push(`sentiment:${sentiment}`);

  let priority: ThreadClassification['priority'] = 'P3';
  if (urgent) priority = 'P0';
  else if (needsReply && (category === 'legal' || category === 'financial')) priority = 'P1';
  else if (needsReply || category === 'customer_support') priority = 'P2';
  reasons.push(`priority:${priority}`);

  let suggestedAction: ThreadClassification['suggested_action'] = 'archive';
  if (urgent) suggestedAction = 'escalate';
  else if (needsReply) suggestedAction = 'reply';
  else if (category === 'financial' || category === 'legal') suggestedAction = 'forward';
  reasons.push(`suggested_action:${suggestedAction}`);

  let confidence = 0.55;
  if (urgent) confidence += 0.2;
  if (needsReply) confidence += 0.1;
  if (category !== 'customer_support') confidence += 0.1;

  return {
    priority,
    category,
    needs_reply: needsReply,
    sentiment,
    suggested_action: suggestedAction,
    confidence: Math.min(0.95, Number(confidence.toFixed(2))),
    classifier_version: 'triage-heuristic-v1',
    reasons
  };
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
    .bind(Math.max(1, Math.min(limit, 500)))
    .all<{ id: string; source_record_id: string }>();

  let processed = 0;
  for (const job of jobs.results || []) {
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
      `SELECT id, attempts
       FROM embedding_jobs
       WHERE source_record_id = ?
       LIMIT 1`
    )
    .bind(sourceRecordId)
    .first<{ id: string; attempts: number }>();

  if (!job) {
    return { status: 'retry', warning: 'embedding_job_missing' };
  }

  if (!hasEmbeddingProviderConfig(env)) {
    const nextAttempts = Number(job.attempts || 0) + 1;
    const backoffMinutes = computeBackoffMinutes(nextAttempts);
    await markEmbeddingJobRetry(env, job.id, nextAttempts, 'embedding_not_configured', backoffMinutes);
    return { status: 'retry', warning: 'embedding_not_configured' };
  }

  const chunkRows = await env.SKY_DB
    .prepare(
      `SELECT id, vector_id, chunk_text, metadata_json
       FROM memory_chunks
       WHERE source_record_id = ?
       ORDER BY CAST(COALESCE(json_extract(metadata_json, '$.chunkIndex'), 0) AS INTEGER) ASC`
    )
    .bind(sourceRecordId)
    .all<{ id: string; vector_id: string | null; chunk_text: string; metadata_json: string | null }>();

  try {
    const prepared = (chunkRows.results || []).map((row) => {
      const cleaned = cleanEmailBody(row.chunk_text || '').replace(/\s+/g, ' ').trim();
      return { ...row, cleaned };
    });

    for (const row of prepared) {
      const original = (row.chunk_text || '').replace(/\s+/g, ' ').trim();
      if (row.cleaned !== original) {
        await env.SKY_DB
          .prepare(`UPDATE memory_chunks SET chunk_text = ? WHERE id = ?`)
          .bind(row.cleaned, row.id)
          .run();
      }
    }

    const vectorIds = prepared.map((x) => x.vector_id).filter((x): x is string => Boolean(x));
    if (vectorIds.length > 0) {
      await env.SKY_VECTORIZE.delete(vectorIds);
    }

    const validRows = prepared.filter((x) => Boolean(x.cleaned));
    const chunks = validRows.map((x) => x.cleaned);
    if (chunks.length === 0) {
      await markEmbeddingJobIndexed(env, job.id, Number(job.attempts || 0) + 1);
      return { status: 'indexed', warning: null };
    }

    const targetDims = parseVectorDimensions(env);
    const embeddings = (await embedChunks(env, chunks)).map((v) => normalizeVectorDimensions(v, targetDims));
    await env.SKY_VECTORIZE.upsert(
      embeddings.map((values, index) => ({
        id: validRows[index]?.vector_id || `${sourceRecordId}:${index}`,
        values,
        metadata: parseJsonObject(validRows[index]?.metadata_json)
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

async function recleanNoisyChunksAndQueue(
  env: Env,
  input: { limit: number; dryRun: boolean; processNow: boolean }
): Promise<{
  scanned: number;
  changedChunks: number;
  queuedSourceRecords: number;
  processedNow: number;
  dryRun: boolean;
}> {
  const rows = await env.SKY_DB
    .prepare(
      `SELECT id, source_record_id, workspace_id, account_id, chunk_text
       FROM memory_chunks
       WHERE lower(chunk_text) LIKE '%return-path:%'
          OR lower(chunk_text) LIKE '%received:%'
          OR lower(chunk_text) LIKE '%mime-version:%'
          OR lower(chunk_text) LIKE '%content-type:%'
          OR lower(chunk_text) LIKE '%content-transfer-encoding:%'
       LIMIT ?`
    )
    .bind(input.limit)
    .all<{
      id: string;
      source_record_id: string;
      workspace_id: string;
      account_id: string | null;
      chunk_text: string;
    }>();

  const affected = new Map<string, { workspaceId: string; accountId: string | null }>();
  let changedChunks = 0;

  for (const row of rows.results || []) {
    const cleaned = cleanEmailBody(row.chunk_text).replace(/\s+/g, ' ').trim();
    const original = row.chunk_text.replace(/\s+/g, ' ').trim();
    if (!cleaned || cleaned === original) continue;

    changedChunks += 1;
    if (!input.dryRun) {
      await env.SKY_DB
        .prepare(`UPDATE memory_chunks SET chunk_text = ? WHERE id = ?`)
        .bind(cleaned, row.id)
        .run();
      affected.set(row.source_record_id, { workspaceId: row.workspace_id, accountId: row.account_id });
    }
  }

  let processedNow = 0;
  if (!input.dryRun) {
    for (const [sourceRecordId, scope] of affected.entries()) {
      const updated = await env.SKY_DB
        .prepare(
          `UPDATE embedding_jobs
           SET status = 'queued',
               last_error = NULL,
               next_attempt_at = CURRENT_TIMESTAMP,
               updated_at = CURRENT_TIMESTAMP
           WHERE source_record_id = ?`
        )
        .bind(sourceRecordId)
        .run();

      const changes = Number((updated as unknown as { meta?: { changes?: number } }).meta?.changes || 0);
      if (changes === 0) {
        await env.SKY_DB
          .prepare(
            `INSERT INTO embedding_jobs
             (id, workspace_id, account_id, source_record_id, status, attempts, next_attempt_at, last_error, created_at, updated_at)
             VALUES (?, ?, ?, ?, 'queued', 0, CURRENT_TIMESTAMP, NULL, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)`
          )
          .bind(
            crypto.randomUUID(),
            scope.workspaceId,
            scope.accountId,
            sourceRecordId
          )
          .run();
      }

      if (input.processNow) {
        const res = await processSingleEmbeddingJob(env, sourceRecordId);
        if (res.status === 'indexed') processedNow += 1;
      }
    }
  }

  return {
    scanned: Number((rows.results || []).length),
    changedChunks,
    queuedSourceRecords: input.dryRun ? 0 : affected.size,
    processedNow,
    dryRun: input.dryRun
  };
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

function hasAiGatewayConfig(env: Env): boolean {
  return Boolean(env.OPENAI_API_KEY && env.AIG_ACCOUNT_ID && env.AIG_GATEWAY_ID);
}

function hasWorkersAiConfig(env: Env): boolean {
  return Boolean(env.AI);
}

function hasEmbeddingProviderConfig(env: Env): boolean {
  return hasAiGatewayConfig(env) || hasWorkersAiConfig(env);
}

function computeBackoffMinutes(attempts: number): number {
  return Math.min(240, Math.max(1, 2 ** Math.min(attempts, 8)));
}

function cleanEmailBody(raw: string): string {
  const headerNames =
    '(Return-Path|Received|MIME-Version|Content-Type|Content-Transfer-Encoding|X-[\\w-]+|Message-ID|Date|From|To|Cc|Bcc|Subject|Reply-To|Delivered-To|Authentication-Results|DKIM-Signature|ARC-[\\w-]+)';

  let cleaned = raw
    .replace(
      /^(Return-Path|Received|MIME-Version|Content-Type|Content-Transfer-Encoding|X-[\w-]+|Message-ID|Date|From|To|Cc|Bcc|Subject|Reply-To|Delivered-To|Authentication-Results|DKIM-Signature|ARC-[\w-]+):.*$/gim,
      ''
    )
    .replace(/^>.*$/gm, '')
    .replace(/^-{3,}.*Forwarded.*-{3,}$/gim, '')
    .replace(/^(unsubscribe|this email was sent|you are receiving|view in browser|privacy policy).*/gim, '')
    .replace(/^(sent from my|get outlook for|this email and any attachments).*/gim, '')
    .replace(/^(begin:vcalendar|end:vcalendar|begin:vevent|dtstart|dtend|organizer).*/gim, '')
    .replace(/^(confidentiality notice|this message is intended only for).*/gim, '')
    .replace(/\n{3,}/g, '\n\n')
    .trim();

  cleaned = cleaned.replace(
    new RegExp(`(?:^|\\s)${headerNames}:\\s*[^\\n]*?(?=(?:\\s${headerNames}:)|$)`, 'gi'),
    ' '
  );

  return cleaned
    .replace(/<[^>]*>/g, ' ')
    .replace(/[A-Za-z0-9+/]{100,}={0,2}/g, '')
    .replace(/https?:\/\/[^\s]+/g, '')
    .replace(/[\w.-]+@[\w.-]+\.\w+/g, '')
    .replace(/\s{2,}/g, ' ')
    .trim();
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

  const body = (await response.json()) as { data?: Array<{ embedding?: number[] }> };
  const vectors = (body.data || []).map((x) => x.embedding || []);
  if (vectors.length !== chunks.length || vectors.some((v) => v.length === 0)) {
    throw new Error('Embedding response did not match requested chunk count');
  }
  return vectors;
}

async function callOpenAiChatViaGateway(
  env: Env,
  messages: Array<{ role: 'user' | 'assistant' | 'system'; content: string }>
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
      max_tokens: 700,
      messages
    })
  });

  if (!response.ok) {
    const text = await response.text();
    throw new Error(`Briefing chat request failed (${response.status}): ${text.slice(0, 500)}`);
  }

  const body = (await response.json()) as {
    choices?: Array<{ message?: { content?: string } }>;
  };
  return body.choices?.[0]?.message?.content || '';
}

async function callWorkersAiEmbeddings(env: Env, chunks: string[]): Promise<number[][]> {
  if (!env.AI) throw new Error('workers_ai_not_bound');
  const model = env.WORKERS_AI_EMBEDDING_MODEL || '@cf/baai/bge-base-en-v1.5';
  const result = (await env.AI.run(model, { text: chunks })) as {
    data?: number[] | number[][];
    shape?: number[];
  };

  // Workers AI embeddings commonly return a flattened `data` with `shape: [n, d]`.
  if (Array.isArray(result?.shape) && result.shape.length === 2 && Array.isArray(result?.data) && typeof result.data[0] === 'number') {
    const rows = Number(result.shape[0] || 0);
    const dims = Number(result.shape[1] || 0);
    const flat = result.data as number[];
    if (rows <= 0 || dims <= 0 || flat.length !== rows * dims) {
      throw new Error('workers_ai_embedding_shape_mismatch');
    }
    const out: number[][] = [];
    for (let i = 0; i < rows; i += 1) {
      out.push(flat.slice(i * dims, (i + 1) * dims));
    }
    return out;
  }

  if (Array.isArray(result?.data) && Array.isArray(result.data[0])) {
    return result.data as number[][];
  }

  throw new Error('workers_ai_embedding_response_invalid');
}

function shouldFallbackToWorkersAi(errorMessage: string): boolean {
  const msg = errorMessage.toLowerCase();
  return (
    msg.includes('insufficient_quota') ||
    msg.includes('embedding request failed (429)') ||
    msg.includes('embedding request failed (401)') ||
    msg.includes('unauthorized')
  );
}

async function embedChunks(env: Env, chunks: string[]): Promise<number[][]> {
  if (hasAiGatewayConfig(env)) {
    try {
      return await callOpenAiEmbeddingsViaGateway(env, chunks);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      if (hasWorkersAiConfig(env) && shouldFallbackToWorkersAi(message)) {
        return callWorkersAiEmbeddings(env, chunks);
      }
      throw error;
    }
  }

  if (hasWorkersAiConfig(env)) {
    return callWorkersAiEmbeddings(env, chunks);
  }

  throw new Error('embedding_not_configured');
}

function parseVectorDimensions(env: Env): number {
  const raw = Number(env.VECTOR_DIMENSIONS || '1536');
  if (!Number.isFinite(raw) || raw <= 0) return 1536;
  return Math.trunc(raw);
}

function normalizeVectorDimensions(vector: number[], target: number): number[] {
  if (vector.length === target) return vector;
  if (vector.length > target) return vector.slice(0, target);
  return vector.concat(new Array(target - vector.length).fill(0));
}

function unauthorized(): Response {
  return json({ ok: false, error: 'unauthorized' }, 401);
}

async function authorizeHttpRequest(
  request: Request,
  env: Env
): Promise<{ ok: true } | { ok: false }> {
  const apiKey = extractBearerToken(request);
  if (env.WORKER_API_KEY && apiKey === env.WORKER_API_KEY) return { ok: true };

  if (env.ACCESS_AUTH_ENABLED !== 'true') {
    return env.WORKER_API_KEY ? { ok: false } : { ok: true };
  }

  const jwt = request.headers.get('cf-access-jwt-assertion') || apiKey;
  if (!jwt) return { ok: false };

  try {
    await verifyAccessJwtClaims(jwt, env);
    return { ok: true };
  } catch {
    return { ok: false };
  }
}

function stringOr(input: unknown): string | null {
  return typeof input === 'string' && input.trim() ? input.trim() : null;
}

function numberOr(input: unknown): number | null {
  if (typeof input === 'number' && Number.isFinite(input)) return Math.trunc(input);
  if (typeof input === 'string' && input.trim()) {
    const n = Number(input);
    if (Number.isFinite(n)) return Math.trunc(n);
  }
  return null;
}

function json(payload: JsonRecord, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8' }
  });
}
