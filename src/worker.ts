interface Env {
  SKY_DB: D1Database;
  SKY_ARTIFACTS: R2Bucket;
  SKY_VECTORIZE: VectorizeIndex;
  WORKER_API_KEY?: string;
  OPENAI_API_KEY?: string;
  CF_AIG_AUTH_TOKEN?: string;
  AIG_ACCOUNT_ID?: string;
  AIG_GATEWAY_ID?: string;
  OPENAI_MODEL?: string;
  MAILBOX_SKYLERBAIRD_ME_COM?: string;
  ENVIRONMENT: string;
}

type JsonRecord = Record<string, unknown>;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === 'GET' && url.pathname === '/health') {
      return json({ ok: true, service: 'sky-ai-worker', env: env.ENVIRONMENT || 'unknown' });
    }

    if (request.method === 'POST' && url.pathname === '/ingest/mail-thread') {
      if (!isAuthorized(request, env)) return unauthorized();
      return ingestMailThread(request, env);
    }

    if (request.method === 'POST' && url.pathname === '/mail/send') {
      if (!isAuthorized(request, env)) return unauthorized();
      return queueOutboundMail(request, env);
    }

    if (request.method === 'GET' && url.pathname === '/mail/outbound/next') {
      if (!isAuthorized(request, env)) return unauthorized();
      return claimNextOutboundMail(env);
    }

    if (request.method === 'POST' && url.pathname === '/mail/outbound/result') {
      if (!isAuthorized(request, env)) return unauthorized();
      return markOutboundMailResult(request, env);
    }

    if (request.method === 'POST' && url.pathname === '/tasks/triage') {
      return runTriage(env);
    }

    if (request.method === 'POST' && url.pathname === '/briefings/daily') {
      return runDailyBriefing(env);
    }

    if (request.method === 'POST' && url.pathname === '/ai/test') {
      return runAiGatewayTest(env);
    }

    return json({ ok: false, error: 'Not found' }, 404);
  },

  async scheduled(controller: ScheduledController, env: Env): Promise<void> {
    if (controller.cron === '*/15 * * * *') {
      await enqueueSyncJob(env, 'mailbox_incremental_sync', { source: 'cron' });
      return;
    }

    if (controller.cron === '0 13 * * *') {
      await enqueueSyncJob(env, 'daily_briefing', { source: 'cron' });
    }
  }
};

async function ingestMailThread(request: Request, env: Env): Promise<Response> {
  const payload = (await request.json()) as JsonRecord;
  const workspaceId = stringOr(payload.workspaceId) || 'default';
  const threadId = stringOr(payload.threadId);

  if (!threadId) {
    return json({ ok: false, error: 'threadId is required' }, 400);
  }

  const artifactKey = `mail/${workspaceId}/threads/${threadId}/${Date.now()}.json`;
  await env.SKY_ARTIFACTS.put(artifactKey, JSON.stringify(payload), {
    httpMetadata: { contentType: 'application/json' }
  });

  await ensureWorkspace(env, workspaceId);

  await env.SKY_DB
    .prepare(
      `INSERT INTO artifacts (id, workspace_id, source, source_id, r2_key, metadata_json, created_at)
       VALUES (?, ?, 'mail_thread', ?, ?, ?, CURRENT_TIMESTAMP)`
    )
    .bind(crypto.randomUUID(), workspaceId, threadId, artifactKey, JSON.stringify({ ingestedBy: 'api' }))
    .run();

  return json({ ok: true, artifactKey });
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
    const completion = await callOpenAiViaGateway(env, [
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

function stringOr(input: unknown): string | null {
  return typeof input === 'string' && input.trim() ? input.trim() : null;
}

function isAuthorized(request: Request, env: Env): boolean {
  if (!env.WORKER_API_KEY) return true;
  const auth = request.headers.get('authorization') || '';
  return auth === `Bearer ${env.WORKER_API_KEY}`;
}

function unauthorized(): Response {
  return json({ ok: false, error: 'unauthorized' }, 401);
}

function hasAiGatewayConfig(env: Env): boolean {
  return Boolean(env.OPENAI_API_KEY && env.AIG_ACCOUNT_ID && env.AIG_GATEWAY_ID);
}

async function callOpenAiViaGateway(
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

function json(payload: JsonRecord, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8' }
  });
}
