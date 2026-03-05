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
  OPENAI_EMBEDDING_MODEL?: string;
  WORKERS_AI_EMBEDDING_MODEL?: string;
  VECTOR_DIMENSIONS?: string;
  ENVIRONMENT?: string;
}

type JsonRecord = Record<string, unknown>;

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

    return json({ ok: false, error: 'Not found' }, 404);
  },

  async scheduled(controller: ScheduledController, env: Env): Promise<void> {
    if (controller.cron === '*/15 * * * *') {
      await enqueueSyncJob(env, 'mailbox_incremental_sync', { source: 'jobs_cron' });
      await processEmbeddingJobs(env, 200);
      return;
    }

    if (controller.cron === '0 13 * * *') {
      await enqueueSyncJob(env, 'daily_briefing', { source: 'jobs_cron' });
      await processEmbeddingJobs(env, 200);
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
    const targetDims = parseVectorDimensions(env);
    const embeddings = (await embedChunks(env, chunks)).map((v) => normalizeVectorDimensions(v, targetDims));
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

function json(payload: JsonRecord, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8' }
  });
}
