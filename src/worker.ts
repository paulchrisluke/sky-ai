interface Env {
  SKY_DB: D1Database;
  SKY_ARTIFACTS: R2Bucket;
  SKY_VECTORIZE: VectorizeIndex;
  GOOGLE_CLIENT_ID?: string;
  GOOGLE_CLIENT_SECRET?: string;
  GOOGLE_REDIRECT_URI?: string;
  TOKEN_ENCRYPTION_KEY?: string;
  CLAUDE_API_KEY?: string;
  ENVIRONMENT: string;
}

type JsonRecord = Record<string, unknown>;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === 'GET' && url.pathname === '/health') {
      return json({ ok: true, service: 'sky-ai-worker', env: env.ENVIRONMENT || 'unknown' });
    }

    if (request.method === 'POST' && url.pathname === '/ingest/gmail-thread') {
      return ingestGmailThread(request, env);
    }

    if (request.method === 'POST' && url.pathname === '/tasks/triage') {
      return runTriage(env);
    }

    if (request.method === 'POST' && url.pathname === '/briefings/daily') {
      return runDailyBriefing(env);
    }

    return json({ ok: false, error: 'Not found' }, 404);
  },

  async scheduled(controller: ScheduledController, env: Env): Promise<void> {
    if (controller.cron === '*/15 * * * *') {
      await enqueueSyncJob(env, 'gmail_incremental_sync', { source: 'cron' });
      return;
    }

    if (controller.cron === '0 13 * * *') {
      await enqueueSyncJob(env, 'daily_briefing', { source: 'cron' });
    }
  }
};

async function ingestGmailThread(request: Request, env: Env): Promise<Response> {
  const payload = (await request.json()) as JsonRecord;
  const workspaceId = stringOr(payload.workspaceId) || 'default';
  const threadId = stringOr(payload.threadId);

  if (!threadId) {
    return json({ ok: false, error: 'threadId is required' }, 400);
  }

  const artifactKey = `gmail/${workspaceId}/threads/${threadId}/${Date.now()}.json`;
  await env.SKY_ARTIFACTS.put(artifactKey, JSON.stringify(payload), {
    httpMetadata: { contentType: 'application/json' }
  });

  await env.SKY_DB
    .prepare(
      `INSERT INTO artifacts (id, workspace_id, source, source_id, r2_key, metadata_json, created_at)
       VALUES (?, ?, 'gmail_thread', ?, ?, ?, CURRENT_TIMESTAMP)`
    )
    .bind(crypto.randomUUID(), workspaceId, threadId, artifactKey, JSON.stringify({ ingestedBy: 'api' }))
    .run();

  return json({ ok: true, artifactKey });
}

async function runTriage(env: Env): Promise<Response> {
  if (!env.CLAUDE_API_KEY) {
    return json({ ok: true, noop: true, reason: 'missing_claude_api_key' });
  }

  await enqueueSyncJob(env, 'triage_inbox', { source: 'api' });
  return json({ ok: true, queued: 'triage_inbox' });
}

async function runDailyBriefing(env: Env): Promise<Response> {
  if (!env.CLAUDE_API_KEY) {
    return json({ ok: true, noop: true, reason: 'missing_claude_api_key' });
  }

  await enqueueSyncJob(env, 'daily_briefing', { source: 'api' });
  return json({ ok: true, queued: 'daily_briefing' });
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

function stringOr(input: unknown): string | null {
  return typeof input === 'string' && input.trim() ? input.trim() : null;
}

function json(payload: JsonRecord, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8' }
  });
}
