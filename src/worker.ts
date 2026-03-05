interface Env {
  SKY_DB: D1Database;
  SKY_ARTIFACTS: R2Bucket;
  SKY_VECTORIZE: VectorizeIndex;
  GOOGLE_CLIENT_ID?: string;
  GOOGLE_CLIENT_SECRET?: string;
  GOOGLE_REDIRECT_URI?: string;
  TOKEN_ENCRYPTION_KEY?: string;
  CLAUDE_API_KEY?: string;
  CF_AIG_AUTH_TOKEN?: string;
  AIG_ACCOUNT_ID?: string;
  AIG_GATEWAY_ID?: string;
  CLAUDE_MODEL?: string;
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

    if (request.method === 'POST' && url.pathname === '/ai/test') {
      return runAiGatewayTest(env);
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
  if (!hasAiGatewayConfig(env)) {
    return json({ ok: true, noop: true, reason: 'missing_claude_api_key' });
  }

  await enqueueSyncJob(env, 'triage_inbox', { source: 'api' });
  return json({ ok: true, queued: 'triage_inbox' });
}

async function runDailyBriefing(env: Env): Promise<Response> {
  if (!hasAiGatewayConfig(env)) {
    return json({ ok: true, noop: true, reason: 'missing_claude_api_key' });
  }

  await enqueueSyncJob(env, 'daily_briefing', { source: 'api' });
  return json({ ok: true, queued: 'daily_briefing' });
}

async function runAiGatewayTest(env: Env): Promise<Response> {
  if (!hasAiGatewayConfig(env)) {
    return json({
      ok: false,
      error: 'Missing AI Gateway configuration (CLAUDE_API_KEY, AIG_ACCOUNT_ID, AIG_GATEWAY_ID).'
    }, 400);
  }

  try {
    const completion = await callClaudeViaGateway(env, [
      { role: 'user', content: 'Respond with: AI gateway ready.' }
    ]);
    return json({ ok: true, completion });
  } catch (error) {
    return json(
      {
        ok: false,
        error: 'AI Gateway test failed',
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

function stringOr(input: unknown): string | null {
  return typeof input === 'string' && input.trim() ? input.trim() : null;
}

function hasAiGatewayConfig(env: Env): boolean {
  return Boolean(env.CLAUDE_API_KEY && env.AIG_ACCOUNT_ID && env.AIG_GATEWAY_ID);
}

async function callClaudeViaGateway(
  env: Env,
  messages: Array<{ role: 'user' | 'assistant'; content: string }>
): Promise<string> {
  const gatewayUrl =
    `https://gateway.ai.cloudflare.com/v1/${env.AIG_ACCOUNT_ID}/${env.AIG_GATEWAY_ID}/anthropic/v1/messages`;

  const headers: Record<string, string> = {
    'content-type': 'application/json',
    'x-api-key': env.CLAUDE_API_KEY as string,
    'anthropic-version': '2023-06-01'
  };

  if (env.CF_AIG_AUTH_TOKEN) {
    headers['cf-aig-authorization'] = `Bearer ${env.CF_AIG_AUTH_TOKEN}`;
  }

  const response = await fetch(gatewayUrl, {
    method: 'POST',
    headers,
    body: JSON.stringify({
      model: env.CLAUDE_MODEL || 'claude-sonnet-4-5',
      max_tokens: 120,
      messages
    })
  });

  if (!response.ok) {
    const text = await response.text();
    throw new Error(`Gateway request failed (${response.status}): ${text.slice(0, 500)}`);
  }

  const body = (await response.json()) as {
    content?: Array<{ type?: string; text?: string }>;
  };
  const textBlock = body.content?.find((part) => part.type === 'text' && part.text);
  return textBlock?.text || '';
}

function json(payload: JsonRecord, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8' }
  });
}
