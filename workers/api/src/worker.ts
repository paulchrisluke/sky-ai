import { routeAgentRequest } from 'agents';
import {
  extractBearerToken,
  principalFromAccessClaims,
  verifyAccessJwtClaims,
  type AccessAuthEnv,
  type AccessPrincipal
} from '../../shared/auth';
import { enforceCitationContract } from '../../shared/citation';
import { RUN_EVENT_TYPES } from '../../shared/events';
import { extractProviderErrorCode } from '../../shared/providerErrors';
import {
  disableProviderTemporarily,
  getProviderHealthState,
  isProviderTemporarilyDisabled,
  markProviderHealthy
} from '../../shared/providerHealth';
import { BlawbyAgent } from './agents/blawby';

export interface Env extends AccessAuthEnv {
  SKY_DB: D1Database;
  SKY_VECTORIZE: VectorizeIndex;
  AI?: {
    run(model: string, input: Record<string, unknown>, options?: Record<string, unknown>): Promise<unknown>;
  };
  CHAT_COORDINATOR: DurableObjectNamespace;
  BLAWBY_AGENT: DurableObjectNamespace;
  WORKER_API_KEY?: string;
  ACCESS_AUTH_ENABLED?: string;
  ALLOW_API_KEY_BYPASS?: string;
  OPENAI_API_KEY?: string;
  CF_AIG_AUTH_TOKEN?: string;
  AIG_ACCOUNT_ID?: string;
  AIG_GATEWAY_ID?: string;
  OPENAI_EMBEDDING_MODEL?: string;
  OPENAI_MODEL?: string;
  WORKERS_AI_EMBEDDING_MODEL?: string;
  WORKERS_AI_CHAT_MODEL?: string;
  VECTOR_DIMENSIONS?: string;
  ENVIRONMENT?: string;
  WORKERS_AI_INPUT_COST_PER_1M?: string;
  WORKERS_AI_OUTPUT_COST_PER_1M?: string;
  OPENAI_QUOTA_COOLDOWN_MINUTES?: string;
  OPENAI_RATE_LIMIT_COOLDOWN_MINUTES?: string;
}

type JsonRecord = Record<string, unknown>;

type Citation = {
  messageId: string;
  date: string | null;
  from: string;
  subject: string;
  score: number;
};

type QueryIntent = 'find_email' | 'thread_summary' | 'financial_query' | 'calendar_query' | 'attention_query';

type QueryResult = {
  intent: QueryIntent;
  answer: string;
  citations: Citation[];
  citationStatus: 'sufficient' | 'insufficient';
  searched: JsonRecord;
};

type SearchResult = {
  message_id: string;
  thread_id: string | null;
  date: string | null;
  from: string;
  subject: string;
  excerpt: string;
  score: number;
  chunk_id: string;
};

const MIN_SEMANTIC_CITATION_SCORE = 0.65;
const DEFAULT_OPENAI_QUOTA_COOLDOWN_MINUTES = 1440;
const DEFAULT_OPENAI_RATE_LIMIT_COOLDOWN_MINUTES = 5;

type UsageContext = {
  workspaceId?: string;
  accountId?: string;
  runId?: string;
  endpoint?: string;
  operation: string;
};

type UsageEntry = {
  provider: string;
  model: string;
  operation: string;
  endpoint?: string;
  requestUnits?: number | null;
  responseUnits?: number | null;
  estimatedCostUsd?: number | null;
  status?: 'ok' | 'error';
  errorCode?: string | null;
  metadata?: JsonRecord;
};

type AuthPrincipal = {
  type: 'access' | 'service' | 'anonymous';
  subject: string;
  email: string | null;
};

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname.startsWith('/agents/')) {
      const auth = await authorizeHttpRequest(request, env);
      if (!auth.ok) return auth.response;
      const response = await routeAgentRequest(request, env);
      if (response) return response;
      return json({ ok: false, error: 'Not found' }, 404);
    }

    if (request.method === 'GET' && url.pathname === '/health') {
      return json({ ok: true, service: 'sky-ai-api', env: env.ENVIRONMENT || 'unknown' });
    }

    if (request.method === 'GET' && url.pathname === '/ws/chat') {
      return routeWebSocketToCoordinator(request, env);
    }

    if (request.method === 'POST' && url.pathname === '/chat/query') {
      return runHttpChatQuery(request, env);
    }

    if (request.method === 'POST' && url.pathname === '/chat') {
      return runAgentChat(request, env);
    }

    if (request.method === 'POST' && url.pathname === '/search') {
      return runSearch(request, env);
    }

    if (request.method === 'GET' && url.pathname === '/auth/whoami') {
      return getAuthWhoami(request, env);
    }

    if (request.method === 'GET' && /^\/sessions\/[^/]+\/events$/.test(url.pathname)) {
      return getSessionEvents(request, env);
    }

    if (request.method === 'POST' && url.pathname === '/extraction/run') {
      return runExtraction(request, env);
    }

    if (request.method === 'GET' && url.pathname === '/briefing/today') {
      return getTodayBriefing(request, env);
    }

    if (request.method === 'POST' && url.pathname === '/actions/propose') {
      return proposeAction(request, env);
    }

    if (request.method === 'POST' && url.pathname === '/actions/approve') {
      return approveAction(request, env);
    }

    if (request.method === 'POST' && url.pathname === '/actions/reject') {
      return rejectAction(request, env);
    }

    if (request.method === 'POST' && url.pathname === '/actions/execute') {
      return executeAction(request, env);
    }

    if (request.method === 'GET' && url.pathname === '/ops/account/status') {
      return getAccountOpsStatus(request, env);
    }

    if (request.method === 'GET' && url.pathname === '/ops/ingest-stats') {
      return getIngestStats(request, env);
    }

    if (request.method === 'GET' && url.pathname === '/ops/queue-stats') {
      return getQueueStats(request, env);
    }

    if (request.method === 'GET' && url.pathname === '/ops/extraction-stats') {
      return getExtractionStats(request, env);
    }

    if (request.method === 'GET' && url.pathname === '/ops/usage-stats') {
      return getUsageStats(request, env);
    }

    if (request.method === 'GET' && url.pathname === '/ops/provider-health') {
      return getProviderHealth(request, env);
    }

    if (request.method === 'GET' && url.pathname === '/ops/triage-stats') {
      return getTriageStats(request, env);
    }

    return json({ ok: false, error: 'Not found' }, 404);
  }
};

export { BlawbyAgent };

export class ChatCoordinator {
  private state: DurableObjectState;
  private env: Env;
  private sockets: Set<WebSocket>;
  private sessionLocks: Map<string, string>;
  private socketContexts: Map<WebSocket, { workspaceId: string; accountId: string; userId: string }>;

  constructor(state: DurableObjectState, env: Env) {
    this.state = state;
    this.env = env;
    this.sockets = new Set();
    this.sessionLocks = new Map();
    this.socketContexts = new Map();
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === 'GET' && url.pathname === '/connect') {
      if (request.headers.get('Upgrade') !== 'websocket') {
        return json({ ok: false, error: 'Expected websocket upgrade' }, 426);
      }

      const pair = new WebSocketPair();
      const client = pair[0];
      const server = pair[1];
      server.accept();
      this.sockets.add(server);
      const workspaceId = url.searchParams.get('workspaceId') || 'default';
      const accountId = url.searchParams.get('accountId') || 'unknown';
      const userId = url.searchParams.get('userId') || 'anonymous';
      this.socketContexts.set(server, { workspaceId, accountId, userId });

      const sessionId = url.searchParams.get('sessionId');
      const since = url.searchParams.get('since');
      const lastEventId = url.searchParams.get('lastEventId');
      if (sessionId) {
        const replay = await loadRunEvents(this.env, sessionId, since, lastEventId, 200);
        for (const event of replay) {
          this.send(server, { type: 'replay.event', event });
        }
      }

      server.addEventListener('message', async (event: MessageEvent) => {
        await this.handleSocketMessage(server, event.data);
      });
      server.addEventListener('close', () => {
        this.sockets.delete(server);
        this.socketContexts.delete(server);
      });

      return new Response(null, { status: 101, webSocket: client });
    }

    return json({ ok: false, error: 'Not found' }, 404);
  }

  private async handleSocketMessage(socket: WebSocket, rawData: unknown): Promise<void> {
    let payload: JsonRecord;
    try {
      payload = JSON.parse(typeof rawData === 'string' ? rawData : String(rawData)) as JsonRecord;
    } catch {
      this.send(socket, { type: 'run.failed', error: 'invalid_json' });
      return;
    }

    const msgType = stringOr(payload.type);
    if (msgType === 'run.cancel') {
      const sessionId = stringOr(payload.sessionId);
      if (!sessionId) {
        this.send(socket, { type: 'run.failed', error: 'sessionId is required for cancel' });
        return;
      }
      const runId = this.sessionLocks.get(sessionId);
      if (!runId) {
        this.send(socket, { type: 'run.cancelled', sessionId, runId: null, reason: 'no_active_run' });
        return;
      }
      this.sessionLocks.delete(sessionId);
      await this.state.storage.delete(`active:${sessionId}`);
      await clearSessionActiveRun(this.env, sessionId);
      const cancelledEvent = await appendRunEvent(this.env, {
        sessionId,
        workspaceId: context?.workspaceId || 'default',
        accountId: context?.accountId || 'unknown',
        runId,
        eventType: RUN_EVENT_TYPES.CANCELLED,
        payload: { reason: 'user_cancelled' }
      });
      this.broadcast({
        type: RUN_EVENT_TYPES.CANCELLED,
        sessionId,
        runId,
        reason: 'user_cancelled',
        eventId: cancelledEvent.id,
        lastEventId: cancelledEvent.cursor
      });
      return;
    }

    if (msgType !== 'run.query') {
      this.send(socket, { type: 'run.failed', error: 'unsupported_message_type' });
      return;
    }

    const context = this.socketContexts.get(socket);
    const workspaceId = context?.workspaceId || 'default';
    const accountId = context?.accountId;
    const userId = context?.userId || 'anonymous';
    const sessionId = stringOr(payload.sessionId) || crypto.randomUUID();
    const query = stringOr(payload.query);

    if (!accountId || !query) {
      this.send(socket, { type: 'run.failed', error: 'accountId and query are required' });
      return;
    }

    await ensureSession(this.env, { sessionId, workspaceId, accountId, userId });

    if (!(await this.checkRateLimit(sessionId))) {
      this.send(socket, { type: 'run.rejected', reason: 'rate_limited', sessionId });
      return;
    }

    if (this.sessionLocks.has(sessionId)) {
      this.send(socket, { type: 'run.rejected', reason: 'session_locked', sessionId });
      return;
    }

    const runId = crypto.randomUUID();
    this.sessionLocks.set(sessionId, runId);
    await this.state.storage.put(`active:${sessionId}`, {
      runId,
      workspaceId,
      accountId,
      startedAt: Date.now()
    });
    await this.state.storage.setAlarm(Date.now() + 60_000);
    await setSessionActiveRun(this.env, sessionId, runId);

    try {
      const startedEvent = await appendRunEvent(this.env, {
        sessionId,
        workspaceId,
        accountId,
        runId,
        eventType: RUN_EVENT_TYPES.STARTED,
        payload: { query }
      });
      this.broadcast({ type: RUN_EVENT_TYPES.STARTED, sessionId, runId, eventId: startedEvent.id, lastEventId: startedEvent.cursor });

      const intent = detectIntent(query);
      await this.broadcastProgress(workspaceId, accountId, sessionId, runId, 'intent.detected', { intent });

      const userTurnId = await insertTurn(this.env, {
        sessionId,
        workspaceId,
        accountId,
        runId,
        role: 'user',
        content: query,
        citationRequired: true,
        citationStatus: 'not_applicable'
      });

      const rawResult = await executeIntent(this.env, { workspaceId, accountId }, query, intent, runId);
      const result = enforceCitationContract(query, rawResult);

      const assistantTurnId = await insertTurn(this.env, {
        sessionId,
        workspaceId,
        accountId,
        runId,
        role: 'assistant',
        content: result.answer,
        citationRequired: true,
        citationStatus: result.citationStatus
      });

      if (result.citations.length > 0) {
        await insertCitations(this.env, {
          sessionId,
          workspaceId,
          accountId,
          turnId: assistantTurnId,
          citations: result.citations
        });
      }

      await insertRunSearchAudit(this.env, {
        sessionId,
        runId,
        workspaceId,
        accountId,
        query,
        intent: result.intent,
        citationStatus: result.citationStatus,
        citationsCount: result.citations.length,
        searched: result.searched
      });

      const completedEvent = await appendRunEvent(this.env, {
        sessionId,
        workspaceId,
        accountId,
        runId,
        turnId: assistantTurnId,
        eventType: RUN_EVENT_TYPES.COMPLETED,
        payload: {
          intent: result.intent,
          citationStatus: result.citationStatus,
          citations: result.citations,
          searched: result.searched,
          userTurnId
        }
      });

      this.broadcast({
        type: RUN_EVENT_TYPES.COMPLETED,
        sessionId,
        runId,
        eventId: completedEvent.id,
        lastEventId: completedEvent.cursor,
        turnId: assistantTurnId,
        intent: result.intent,
        answer: result.answer,
        citations: result.citations,
        citationStatus: result.citationStatus,
        searched: result.searched
      });
    } catch (error) {
      const message = error instanceof Error ? error.message : 'unknown_error';
      const failedEvent = await appendRunEvent(this.env, {
        sessionId,
        workspaceId,
        accountId,
        runId,
        eventType: RUN_EVENT_TYPES.FAILED,
        payload: { error: message }
      });
      this.broadcast({ type: RUN_EVENT_TYPES.FAILED, sessionId, runId, error: message, eventId: failedEvent.id, lastEventId: failedEvent.cursor });
    } finally {
      this.sessionLocks.delete(sessionId);
      await this.state.storage.delete(`active:${sessionId}`);
      await clearSessionActiveRun(this.env, sessionId);
    }
  }

  async alarm(): Promise<void> {
    const now = Date.now();
    const timeoutMs = 2 * 60 * 1000;
    const active = await this.state.storage.list<{ runId: string; workspaceId: string; accountId: string; startedAt: number }>({
      prefix: 'active:'
    });

    for (const [key, value] of active) {
      if (!value) continue;
      const elapsed = now - Number(value.startedAt || 0);
      if (elapsed < timeoutMs) continue;
      const sessionId = key.replace('active:', '');
      const failedEvent = await appendRunEvent(this.env, {
        sessionId,
        workspaceId: value.workspaceId,
        accountId: value.accountId,
        runId: value.runId,
        eventType: RUN_EVENT_TYPES.FAILED,
        payload: { error: 'run_timeout_watchdog' }
      }).catch(() => {});
      this.broadcast({
        type: RUN_EVENT_TYPES.FAILED,
        sessionId,
        runId: value.runId,
        error: 'run_timeout_watchdog',
        eventId: failedEvent?.id,
        lastEventId: failedEvent?.cursor
      });
      this.sessionLocks.delete(sessionId);
      await this.state.storage.delete(key);
      await clearSessionActiveRun(this.env, sessionId).catch(() => {});
    }
    if (active.size > 0) {
      await this.state.storage.setAlarm(Date.now() + 60_000);
    }
  }

  private async broadcastProgress(
    workspaceId: string,
    accountId: string,
    sessionId: string,
    runId: string,
    stage: string,
    detail?: JsonRecord
  ): Promise<void> {
    const progressEvent = await appendRunEvent(this.env, {
      sessionId,
      workspaceId,
      accountId,
      runId,
      eventType: RUN_EVENT_TYPES.TOOL_PROGRESS,
      payload: { stage, detail: detail || null }
    }).catch(() => {});
    this.broadcast({
      type: RUN_EVENT_TYPES.TOOL_PROGRESS,
      sessionId,
      runId,
      stage,
      detail: detail || null,
      eventId: progressEvent?.id,
      lastEventId: progressEvent?.cursor
    });
  }

  private send(socket: WebSocket, payload: JsonRecord): void {
    try {
      socket.send(JSON.stringify(payload));
    } catch {
      this.sockets.delete(socket);
    }
  }

  private broadcast(payload: JsonRecord): void {
    const encoded = JSON.stringify(payload);
    for (const socket of this.sockets) {
      try {
        socket.send(encoded);
      } catch {
        this.sockets.delete(socket);
      }
    }
  }

  private async checkRateLimit(sessionId: string): Promise<boolean> {
    const key = `ratelimit:${sessionId}`;
    const now = Date.now();
    const windowMs = 5 * 60 * 1000;
    const maxRequests = 20;

    const current = (await this.state.storage.get<{ count: number; windowStart: number }>(key)) || {
      count: 0,
      windowStart: now
    };

    if (now - current.windowStart > windowMs) {
      await this.state.storage.put(key, { count: 1, windowStart: now });
      return true;
    }

    if (current.count >= maxRequests) {
      return false;
    }

    await this.state.storage.put(key, { count: current.count + 1, windowStart: current.windowStart });
    return true;
  }
}

async function routeWebSocketToCoordinator(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  const workspaceId = url.searchParams.get('workspaceId') || 'default';
  const accountId = url.searchParams.get('accountId');
  const sessionId = url.searchParams.get('sessionId');
  const since = url.searchParams.get('since');
  const lastEventId = url.searchParams.get('lastEventId');
  const auth = await authorizeHttpRequest(request, env);
  if (!auth.ok) return auth.response;

  if (!accountId) {
    return json({ ok: false, error: 'accountId query parameter is required' }, 400);
  }

  const canonicalAccountId = await ensureWorkspaceAndAccount(env, workspaceId, accountId);
  const permission = await assertPermission(env, auth.principal, workspaceId, canonicalAccountId);
  if (!permission.ok) return permission.response;
  const id = env.CHAT_COORDINATOR.idFromName(`${workspaceId}:${canonicalAccountId}`);
  const stub = env.CHAT_COORDINATOR.get(id);
  const connectUrl = new URL(request.url);
  connectUrl.pathname = '/connect';
  connectUrl.searchParams.set('workspaceId', workspaceId);
  connectUrl.searchParams.set('accountId', canonicalAccountId);
  connectUrl.searchParams.set('userId', auth.principal.email || auth.principal.subject);
  if (sessionId) connectUrl.searchParams.set('sessionId', sessionId);
  if (since) connectUrl.searchParams.set('since', since);
  if (lastEventId) connectUrl.searchParams.set('lastEventId', lastEventId);
  return stub.fetch(new Request(connectUrl.toString(), request));
}

async function getSessionEvents(request: Request, env: Env): Promise<Response> {
  const auth = await authorizeHttpRequest(request, env);
  if (!auth.ok) return auth.response;
  const url = new URL(request.url);
  const parts = url.pathname.split('/');
  const sessionId = parts[2];
  if (!sessionId) return json({ ok: false, error: 'sessionId missing' }, 400);
  const scope = await env.SKY_DB
    .prepare(`SELECT workspace_id, account_id FROM chat_sessions WHERE id = ? LIMIT 1`)
    .bind(sessionId)
    .first<{ workspace_id: string; account_id: string }>();
  if (!scope) return json({ ok: false, error: 'session_not_found' }, 404);
  const permission = await assertPermission(env, auth.principal, scope.workspace_id, scope.account_id);
  if (!permission.ok) return permission.response;
  const since = url.searchParams.get('since');
  const lastEventId = url.searchParams.get('lastEventId');
  const limit = numberOr(url.searchParams.get('limit')) || 200;
  const events = await loadRunEvents(env, sessionId, since, lastEventId, Math.min(Math.max(limit, 1), 1000));
  return json({ ok: true, sessionId, events });
}

async function getAuthWhoami(request: Request, env: Env): Promise<Response> {
  const auth = await authorizeHttpRequest(request, env);
  if (!auth.ok) return auth.response;

  const workspaceId = (new URL(request.url)).searchParams.get('workspaceId');
  if (!workspaceId) {
    const permissions = await listPermissions(env, auth.principal);
    return json({
      ok: true,
      principal: auth.principal,
      permissions
    });
  }

  const accountId = (new URL(request.url)).searchParams.get('accountId');
  if (!accountId) {
    const permissions = await listPermissions(env, auth.principal, workspaceId);
    return json({
      ok: true,
      principal: auth.principal,
      permissions
    });
  }

  const canonicalAccountId = await ensureWorkspaceAndAccount(env, workspaceId, accountId);
  const permission = await assertPermission(env, auth.principal, workspaceId, canonicalAccountId);
  return json({
    ok: true,
    principal: auth.principal,
    authorized: permission.ok,
    workspaceId,
    accountId: canonicalAccountId
  }, permission.ok ? 200 : 403);
}

async function runHttpChatQuery(request: Request, env: Env): Promise<Response> {
  const auth = await authorizeHttpRequest(request, env);
  if (!auth.ok) return auth.response;
  const payload = (await request.json()) as JsonRecord;
  const workspaceId = stringOr(payload.workspaceId) || 'default';
  let accountId = stringOr(payload.accountId);
  const userId = stringOr(payload.userId) || 'anonymous';
  const sessionId = stringOr(payload.sessionId) || crypto.randomUUID();
  const query = stringOr(payload.query);

  if (!accountId || !query) {
    return json({ ok: false, error: 'accountId and query are required' }, 400);
  }

  accountId = await ensureWorkspaceAndAccount(env, workspaceId, accountId);
  const permission = await assertPermission(env, auth.principal, workspaceId, accountId);
  if (!permission.ok) return permission.response;
  await ensureSession(env, { sessionId, workspaceId, accountId, userId });

  const runId = crypto.randomUUID();
  const intent = detectIntent(query);

  const userTurnId = await insertTurn(env, {
    sessionId,
    workspaceId,
    accountId,
    runId,
    role: 'user',
    content: query,
    citationRequired: true,
    citationStatus: 'not_applicable'
  });

  let result: QueryResult;
  let proposals: Array<{ id: string; type: string; title: string; draft_payload_json: JsonRecord; risk_level: string }> = [];
  if (intent === 'find_email') {
    const unified = await executeUnifiedFindEmailQuery(env, {
      workspaceId,
      accountId,
      query,
      runId,
      includeProposals: true
    });
    result = enforceCitationContract(query, {
      intent,
      answer: unified.answer,
      citations: unified.citations,
      searched: unified.searched
    });
    proposals = unified.proposals;
  } else {
    const rawResult = await executeIntent(env, { workspaceId, accountId }, query, intent, runId);
    result = enforceCitationContract(query, rawResult);
  }

  const assistantTurnId = await insertTurn(env, {
    sessionId,
    workspaceId,
    accountId,
    runId,
    role: 'assistant',
    content: result.answer,
    citationRequired: true,
    citationStatus: result.citationStatus
  });

  if (result.citations.length > 0) {
    await insertCitations(env, {
      sessionId,
      workspaceId,
      accountId,
      turnId: assistantTurnId,
      citations: result.citations
    });
  }

  await insertRunSearchAudit(env, {
    sessionId,
    runId,
    workspaceId,
    accountId,
    query,
    intent: result.intent,
    citationStatus: result.citationStatus,
    citationsCount: result.citations.length,
    searched: result.searched
  });

  await appendRunEvent(env, {
    sessionId,
    workspaceId,
    accountId,
    runId,
    turnId: assistantTurnId,
    eventType: RUN_EVENT_TYPES.COMPLETED,
    payload: {
      intent,
      citations: result.citations,
      citationStatus: result.citationStatus,
      searched: result.searched,
      userTurnId
    }
  });

  if (intent !== 'find_email') {
    proposals = [];
  }

  return json({
    ok: true,
    sessionId,
    runId,
    turnId: assistantTurnId,
    intent,
    answer: result.answer,
    citations: result.citations,
    proposals,
    citationStatus: result.citationStatus,
    searched: result.searched
  });
}

async function runSearch(request: Request, env: Env): Promise<Response> {
  const auth = await authorizeHttpRequest(request, env);
  if (!auth.ok) return auth.response;
  const payload = (await request.json()) as JsonRecord;
  const workspaceId = stringOr(payload.workspaceId) || 'default';
  let accountId = stringOr(payload.accountId) || stringOr(payload.account_id);
  const query = stringOr(payload.query);
  const kRaw = numberOr(payload.k);
  const k = Math.min(25, Math.max(1, kRaw || 10));

  if (!accountId || !query) {
    return json({ ok: false, error: 'accountId/account_id and query are required' }, 400);
  }

  accountId = await ensureWorkspaceAndAccount(env, workspaceId, accountId);
  const permission = await assertPermission(env, auth.principal, workspaceId, accountId);
  if (!permission.ok) return permission.response;

  let results: SearchResult[] = [];
  try {
    results = await performSemanticSearch(env, workspaceId, accountId, query, k, {
      workspaceId,
      accountId,
      operation: 'search_query',
      endpoint: '/search'
    });
  } catch (error) {
    return json({ ok: false, error: 'search_failed', detail: error instanceof Error ? error.message : 'unknown' }, 500);
  }

  return json({
    ok: true,
    workspaceId,
    accountId,
    query,
    results
  });
}

async function runAgentChat(request: Request, env: Env): Promise<Response> {
  const auth = await authorizeHttpRequest(request, env);
  if (!auth.ok) return auth.response;
  const payload = (await request.json()) as JsonRecord;
  const workspaceId = stringOr(payload.workspaceId) || 'default';
  let accountId = stringOr(payload.accountId) || stringOr(payload.account_id);
  const query = stringOr(payload.query);
  const agentId = stringOr(payload.agentId) || stringOr(payload.agent_id);
  const userId = stringOr(payload.userId) || auth.principal.email || auth.principal.subject || 'anonymous';
  const sessionId = stringOr(payload.sessionId) || crypto.randomUUID();

  if (!accountId || !query) {
    return json({ ok: false, error: 'accountId/account_id and query are required' }, 400);
  }

  accountId = await ensureWorkspaceAndAccount(env, workspaceId, accountId);
  const permission = await assertPermission(env, auth.principal, workspaceId, accountId);
  if (!permission.ok) return permission.response;
  await ensureSession(env, { sessionId, workspaceId, accountId, userId });

  const runId = crypto.randomUUID();
  const userTurnId = await insertTurn(env, {
    sessionId,
    workspaceId,
    accountId,
    runId,
    role: 'user',
    content: query,
    citationRequired: true,
    citationStatus: 'not_applicable'
  });

  let hits: SearchResult[] = [];
  try {
    hits = await performSemanticSearch(env, workspaceId, accountId, query, 10, {
      workspaceId,
      accountId,
      runId,
      operation: 'chat_retrieval',
      endpoint: '/chat'
    });
  } catch {
    hits = [];
  }
  if (hits.length === 0) {
    const answer = 'insufficient sources';
    const assistantTurnId = await insertTurn(env, {
      sessionId,
      workspaceId,
      accountId,
      runId,
      role: 'assistant',
      content: answer,
      citationRequired: true,
      citationStatus: 'insufficient'
    });
    await insertRunSearchAudit(env, {
      sessionId,
      runId,
      workspaceId,
      accountId,
      query,
      intent: 'find_email',
      citationStatus: 'insufficient',
      citationsCount: 0,
      searched: { strategy: 'vector_search', k: 10 }
    });
    await appendRunEvent(env, {
      sessionId,
      workspaceId,
      accountId,
      runId,
      turnId: assistantTurnId,
      eventType: RUN_EVENT_TYPES.COMPLETED,
      payload: { citations: [], citationStatus: 'insufficient', userTurnId }
    });
    return json({ ok: true, answer, citations: [], proposals: [], thread_id: hits[0]?.thread_id || null, runId, sessionId });
  }

  const agent = agentId ? await loadAgentProfile(env, agentId) : null;
  const context = hits
    .map((h, idx) => `${idx + 1}. FROM: ${h.from} | DATE: ${h.date || 'unknown'} | SUBJECT: ${h.subject}\nEXCERPT: ${h.excerpt}`)
    .join('\n\n');

  const systemPrompt = [
    agent ? `You are an AI chief of staff for ${agent.name}.` : 'You are an AI chief of staff.',
    agent ? `Purpose: ${agent.purpose}` : '',
    agent ? `Context: ${agent.business_context}` : '',
    agent ? `Goals: ${agent.owner_goals.join('; ')}` : '',
    'Answer using only provided email context.',
    'If context is insufficient, say exactly: insufficient sources.',
    'Keep concise and practical.'
  ]
    .filter(Boolean)
    .join('\n');

  let answer = 'insufficient sources';
  try {
    answer = await callOpenAiChatViaGateway(
      env,
      [
        { role: 'system', content: systemPrompt },
        { role: 'user', content: `Retrieved email context:\n${context}\n\nQuestion: ${query}` }
      ],
      undefined,
      { workspaceId, accountId, runId, operation: 'chat_completion', endpoint: '/chat' }
    );
  } catch {
    answer = 'insufficient sources';
  }

  const citations: Citation[] = hits.slice(0, 6).map((h) => ({
    messageId: h.message_id,
    date: h.date,
    from: h.from,
    subject: h.subject,
    score: h.score
  }));
  const citationStatus: 'sufficient' | 'insufficient' = answer.trim().toLowerCase() === 'insufficient sources' ? 'insufficient' : 'sufficient';

  const assistantTurnId = await insertTurn(env, {
    sessionId,
    workspaceId,
    accountId,
    runId,
    role: 'assistant',
    content: answer,
    citationRequired: true,
    citationStatus
  });
  await insertCitations(env, { sessionId, workspaceId, accountId, turnId: assistantTurnId, citations });
  await insertRunSearchAudit(env, {
    sessionId,
    runId,
    workspaceId,
    accountId,
    query,
    intent: 'find_email',
    citationStatus,
    citationsCount: citations.length,
    searched: { strategy: 'vector_search', k: 10 }
  });
  await appendRunEvent(env, {
    sessionId,
    workspaceId,
    accountId,
    runId,
    turnId: assistantTurnId,
    eventType: RUN_EVENT_TYPES.COMPLETED,
    payload: { citations, citationStatus, userTurnId }
  });

  const proposals = await extractAndPersistProposals(env, {
    workspaceId,
    accountId,
    agentId,
    query,
    answer,
    hits
  });

  return json({
    ok: true,
    answer,
    citations: hits.slice(0, 6).map((h) => ({
      message_id: h.message_id,
      thread_id: h.thread_id,
      date: h.date,
      from: h.from,
      subject: h.subject,
      excerpt: h.excerpt
    })),
    proposals,
    thread_id: hits[0]?.thread_id || null,
    runId,
    sessionId
  });
}

async function runExtraction(request: Request, env: Env): Promise<Response> {
  const auth = await authorizeHttpRequest(request, env);
  if (!auth.ok) return auth.response;
  const payload = (await request.json()) as JsonRecord;
  const workspaceId = stringOr(payload.workspaceId) || 'default';
  let accountId = stringOr(payload.accountId);
  const limit = numberOr(payload.limit) || 100;

  if (!accountId) {
    return json({ ok: false, error: 'accountId is required' }, 400);
  }

  accountId = await ensureWorkspaceAndAccount(env, workspaceId, accountId);
  const permission = await assertPermission(env, auth.principal, workspaceId, accountId);
  if (!permission.ok) return permission.response;
  const accountEmail = await resolveAccountEmail(env, workspaceId, accountId);
  if (!accountEmail) {
    return json({ ok: false, error: 'account email could not be resolved for accountId' }, 400);
  }

  const rows = await env.SKY_DB
    .prepare(
      `SELECT em.id, em.thread_id, em.subject, em.snippet, em.sent_at,
              COALESCE(
                json_extract(em.from_json, '$[0].email'),
                json_extract(em.from_json, '$[0].address'),
                ''
              ) AS sender
       FROM email_messages em
       LEFT JOIN message_extractions mx
         ON mx.workspace_id = em.workspace_id
        AND mx.account_id = em.account_id
        AND mx.source_message_id = em.id
       WHERE em.workspace_id = ?
         AND (em.account_id = ? OR lower(em.account_email) = ?)
         AND mx.id IS NULL
       ORDER BY datetime(COALESCE(em.sent_at, em.created_at)) DESC
       LIMIT ?`
    )
    .bind(workspaceId, accountId, accountEmail, Math.min(Math.max(limit, 1), 500))
    .all<{
      id: string;
      thread_id: string | null;
      subject: string | null;
      snippet: string | null;
      sent_at: string | null;
      sender: string | null;
    }>();

  let tasksCreated = 0;
  let decisionsCreated = 0;
  let followupsCreated = 0;

  for (const row of rows.results || []) {
    const text = `${row.subject || ''}\n${row.snippet || ''}`;
    const extracted = extractActionSignals(text, row.sent_at, row.sender || '', accountId);

    for (const task of extracted.tasks) {
      await env.SKY_DB
        .prepare(
          `INSERT INTO tasks
           (id, workspace_id, account_id, title, status, priority, due_at, source_record_id, source_message_id, confidence_score, review_state, owner, metadata_json, created_at, updated_at)
           VALUES (?, ?, ?, ?, 'open', ?, ?, NULL, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)`
        )
        .bind(
          crypto.randomUUID(),
          workspaceId,
          accountId,
          task.text,
          task.priority,
          task.dueAt,
          row.id,
          task.confidence,
          task.reviewState,
          task.owner,
          JSON.stringify({ extractor: 'heuristic-v1', threadId: row.thread_id })
        )
        .run();
      tasksCreated += 1;
    }

    for (const decision of extracted.decisions) {
      await env.SKY_DB
        .prepare(
          `INSERT INTO decisions
           (id, workspace_id, account_id, source_message_id, thread_id, decision_text, owner, confidence_score, review_state, status, metadata_json, created_at, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'open', ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)`
        )
        .bind(
          crypto.randomUUID(),
          workspaceId,
          accountId,
          row.id,
          row.thread_id,
          decision.text,
          decision.owner,
          decision.confidence,
          decision.reviewState,
          JSON.stringify({ extractor: 'heuristic-v1' })
        )
        .run();
      decisionsCreated += 1;
    }

    for (const followup of extracted.followups) {
      await env.SKY_DB
        .prepare(
          `INSERT INTO followups
           (id, workspace_id, account_id, source_message_id, thread_id, followup_text, owner, due_at, confidence_score, review_state, status, metadata_json, created_at, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'open', ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)`
        )
        .bind(
          crypto.randomUUID(),
          workspaceId,
          accountId,
          row.id,
          row.thread_id,
          followup.text,
          followup.owner,
          followup.dueAt,
          followup.confidence,
          followup.reviewState,
          JSON.stringify({ extractor: 'heuristic-v1' })
        )
        .run();
      followupsCreated += 1;
    }

    await env.SKY_DB
      .prepare(
        `INSERT INTO message_extractions
         (id, workspace_id, account_id, source_message_id, extractor_version, status, summary_json, created_at, updated_at)
         VALUES (?, ?, ?, ?, 'heuristic-v1', 'processed', ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)`
      )
      .bind(
        crypto.randomUUID(),
        workspaceId,
        accountId,
        row.id,
        JSON.stringify({
          tasks: extracted.tasks.length,
          decisions: extracted.decisions.length,
          followups: extracted.followups.length
        })
      )
      .run();

    await env.SKY_DB
      .prepare(
        `INSERT INTO model_audit_logs
         (id, workspace_id, account_id, source, model_name, input_json, output_json, success, created_at)
         VALUES (?, ?, ?, 'action_extraction', 'heuristic-v1', ?, ?, 1, CURRENT_TIMESTAMP)`
      )
      .bind(
        crypto.randomUUID(),
        workspaceId,
        accountId,
        JSON.stringify({ messageId: row.id, textSample: text.slice(0, 500) }),
        JSON.stringify(extracted)
      )
      .run();
  }

  return json({
    ok: true,
    processedMessages: (rows.results || []).length,
    tasksCreated,
    decisionsCreated,
    followupsCreated
  });
}

async function getTodayBriefing(request: Request, env: Env): Promise<Response> {
  const auth = await authorizeHttpRequest(request, env);
  if (!auth.ok) return auth.response;
  const url = new URL(request.url);
  const workspaceId = url.searchParams.get('workspaceId') || 'default';
  let accountId = url.searchParams.get('accountId');

  if (!accountId) {
    return json({ ok: false, error: 'accountId query parameter is required' }, 400);
  }

  accountId = await ensureWorkspaceAndAccount(env, workspaceId, accountId);
  const permission = await assertPermission(env, auth.principal, workspaceId, accountId);
  if (!permission.ok) return permission.response;

  const briefingTimezone = await getWorkspaceTimezone(env, workspaceId);
  const today = localDateInTimezone(briefingTimezone);
  const generated = await env.SKY_DB
    .prepare(
      `SELECT id, briefing_date, narrative, payload_json, content_json, created_at
       FROM briefings
       WHERE workspace_id = ?
         AND account_id = ?
         AND briefing_date = ?
         AND (status = 'ready' OR delivery_status = 'ready')
       ORDER BY datetime(created_at) DESC
       LIMIT 1`
    )
    .bind(workspaceId, accountId, today)
    .first<{
      id: string;
      briefing_date: string;
      narrative: string | null;
      payload_json: string | null;
      content_json: string | null;
      created_at: string;
    }>();

  if (generated?.id) {
    const rawPayload = generated.payload_json || generated.content_json || '{}';
    let payload: JsonRecord = {};
    try {
      payload = JSON.parse(rawPayload) as JsonRecord;
    } catch {
      payload = {};
    }

    return json({
      ok: true,
      briefing_id: generated.id,
      date: generated.briefing_date,
      narrative: generated.narrative || null,
      payload,
      source: 'generated',
      generated_at: generated.created_at
    });
  }

  return json({
    ok: true,
    date: today,
    source: 'pending',
    narrative: null,
    message: `Briefing not yet generated for ${today} (${briefingTimezone}). Check back after 7am local time.`
  });
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
  const tz = (row?.timezone || '').trim();
  return tz || 'America/Chicago';
}

function localDateInTimezone(timezone: string): string {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: timezone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit'
  }).formatToParts(new Date());

  const get = (type: string): string => parts.find((x) => x.type === type)?.value || '';
  return `${get('year')}-${get('month')}-${get('day')}`;
}

async function loadTodayBriefingData(
  env: Env,
  workspaceId: string,
  accountId: string
): Promise<{ date: string; workspaceId: string; accountId: string; actions: JsonRecord[]; citations: Citation[]; note: string }> {
  const tasks = await env.SKY_DB
    .prepare(
      `SELECT id, title, priority, due_at, source_message_id, confidence_score, review_state
       FROM tasks
       WHERE workspace_id = ?
         AND account_id = ?
         AND status = 'open'
       ORDER BY datetime(COALESCE(due_at, '2999-12-31')) ASC, created_at DESC
       LIMIT 30`
    )
    .bind(workspaceId, accountId)
    .all<{
      id: string;
      title: string;
      priority: string | null;
      due_at: string | null;
      source_message_id: string | null;
      confidence_score: number;
      review_state: string;
    }>();

  const followups = await env.SKY_DB
    .prepare(
      `SELECT id, followup_text, due_at, source_message_id, confidence_score, review_state
       FROM followups
       WHERE workspace_id = ?
         AND account_id = ?
         AND status = 'open'
       ORDER BY datetime(COALESCE(due_at, '2999-12-31')) ASC, created_at DESC
       LIMIT 30`
    )
    .bind(workspaceId, accountId)
    .all<{
      id: string;
      followup_text: string;
      due_at: string | null;
      source_message_id: string | null;
      confidence_score: number;
      review_state: string;
    }>();

  const today = new Date();
  const ranked = [
    ...(tasks.results || []).map((t) => ({
      type: 'task' as const,
      id: t.id,
      text: t.title,
      dueAt: t.due_at,
      sourceMessageId: t.source_message_id,
      reviewState: t.review_state,
      confidence: t.confidence_score,
      score: computePriorityScore(t.priority, t.due_at, today)
    })),
    ...(followups.results || []).map((f) => ({
      type: 'followup' as const,
      id: f.id,
      text: f.followup_text,
      dueAt: f.due_at,
      sourceMessageId: f.source_message_id,
      reviewState: f.review_state,
      confidence: f.confidence_score,
      score: computePriorityScore('medium', f.due_at, today)
    }))
  ]
    .sort((a, b) => b.score - a.score)
    .slice(0, 12);

  const messageIds = ranked.map((x) => x.sourceMessageId).filter((x): x is string => Boolean(x));
  const citationMap = await loadCitationsForMessages(env, workspaceId, accountId, messageIds);

  const citations: Citation[] = [];
  const seenCitationIds = new Set<string>();
  for (const item of ranked) {
    if (!item.sourceMessageId) continue;
    if (seenCitationIds.has(item.sourceMessageId)) continue;
    const c = citationMap.get(item.sourceMessageId);
    if (!c) continue;
    seenCitationIds.add(item.sourceMessageId);
    citations.push(c);
  }

  return {
    date: toDateOnly(today),
    workspaceId,
    accountId,
    actions: ranked as unknown as JsonRecord[],
    citations,
    note:
      ranked.length === 0
        ? 'No open extracted actions yet. Run POST /extraction/run first.'
        : 'Prioritized by urgency, due date, and confidence.'
  };
}

async function proposeAction(request: Request, env: Env): Promise<Response> {
  const auth = await authorizeHttpRequest(request, env);
  if (!auth.ok) return auth.response;
  const payload = (await request.json()) as JsonRecord;
  const workspaceId = stringOr(payload.workspaceId) || 'default';
  let accountId = stringOr(payload.accountId);
  const sessionId = stringOr(payload.sessionId);
  const turnId = stringOr(payload.turnId);
  const actionType = stringOr(payload.actionType);
  const actionPayload = objectOr(payload.payload) || {};

  if (!accountId || !actionType) {
    return json({ ok: false, error: 'accountId and actionType are required' }, 400);
  }

  accountId = await ensureWorkspaceAndAccount(env, workspaceId, accountId);
  const permission = await assertPermission(env, auth.principal, workspaceId, accountId);
  if (!permission.ok) return permission.response;

  const actionId = crypto.randomUUID();
  const approvalToken = crypto.randomUUID();
  const expiresAt = new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString();

  await env.SKY_DB
    .prepare(
      `INSERT INTO proposed_actions
       (id, workspace_id, account_id, session_id, turn_id, action_type, payload_json, status, approval_token, expires_at, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, 'proposed', ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)`
    )
    .bind(
      actionId,
      workspaceId,
      accountId,
      sessionId,
      turnId,
      actionType,
      JSON.stringify(actionPayload),
      approvalToken,
      expiresAt
    )
    .run();

  await appendActionEvent(env, {
    actionId,
    workspaceId,
    accountId,
    eventType: 'proposed',
    actor: auth.principal.email || auth.principal.subject,
    payload: { actionType, sessionId, turnId }
  });

  return json({
    ok: true,
    action: {
      id: actionId,
      status: 'proposed',
      approvalToken,
      expiresAt,
      policy: 'draft_or_approval_only'
    }
  });
}

async function approveAction(request: Request, env: Env): Promise<Response> {
  const auth = await authorizeHttpRequest(request, env);
  if (!auth.ok) return auth.response;
  const payload = (await request.json()) as JsonRecord;
  const approvedBy = stringOr(payload.userId) || 'unknown';
  const confirm = payload.confirm === true;
  const actionId = stringOr(payload.actionId);
  const approvalToken = stringOr(payload.approvalToken);

  if (!confirm) {
    return json({ ok: false, error: 'confirm=true is required to approve action' }, 400);
  }

  if (!actionId && !approvalToken) {
    return json({ ok: false, error: 'actionId or approvalToken is required' }, 400);
  }

  const row = actionId
    ? await env.SKY_DB
        .prepare(`SELECT id, status, expires_at FROM proposed_actions WHERE id = ? LIMIT 1`)
        .bind(actionId)
        .first<{ id: string; status: string; expires_at: string | null }>()
    : await env.SKY_DB
        .prepare(`SELECT id, status, expires_at FROM proposed_actions WHERE approval_token = ? LIMIT 1`)
        .bind(approvalToken)
        .first<{ id: string; status: string; expires_at: string | null }>();

  if (!row) return json({ ok: false, error: 'action_not_found' }, 404);
  const actionScope = await env.SKY_DB
    .prepare(`SELECT workspace_id, account_id FROM proposed_actions WHERE id = ? LIMIT 1`)
    .bind(row.id)
    .first<{ workspace_id: string; account_id: string }>();
  if (!actionScope) return json({ ok: false, error: 'action_scope_missing' }, 404);
  const permission = await assertPermission(env, auth.principal, actionScope.workspace_id, actionScope.account_id);
  if (!permission.ok) return permission.response;
  if (row.status !== 'proposed') return json({ ok: false, error: `action_not_approvable:${row.status}` }, 409);
  if (row.expires_at && new Date(row.expires_at).getTime() < Date.now()) {
    return json({ ok: false, error: 'approval_token_expired' }, 409);
  }

  await env.SKY_DB
    .prepare(
      `UPDATE proposed_actions
       SET status = 'approved', approved_by = ?, approved_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
       WHERE id = ?`
    )
    .bind(approvedBy, row.id)
    .run();

  await appendActionEvent(env, {
    actionId: row.id,
    workspaceId: actionScope.workspace_id,
    accountId: actionScope.account_id,
    eventType: 'approved',
    actor: approvedBy,
    payload: { approvedAt: new Date().toISOString() }
  });

  return json({ ok: true, action: { id: row.id, status: 'approved', nextStep: 'manual_or_separate_executor_required' } });
}

async function rejectAction(request: Request, env: Env): Promise<Response> {
  const auth = await authorizeHttpRequest(request, env);
  if (!auth.ok) return auth.response;
  const payload = (await request.json()) as JsonRecord;
  const rejectedBy = stringOr(payload.userId) || auth.principal.email || auth.principal.subject;
  const actionId = stringOr(payload.actionId);
  const approvalToken = stringOr(payload.approvalToken);
  const reason = stringOr(payload.reason) || 'rejected_by_user';

  if (!actionId && !approvalToken) {
    return json({ ok: false, error: 'actionId or approvalToken is required' }, 400);
  }

  const row = actionId
    ? await env.SKY_DB
        .prepare(`SELECT id, status FROM proposed_actions WHERE id = ? LIMIT 1`)
        .bind(actionId)
        .first<{ id: string; status: string }>()
    : await env.SKY_DB
        .prepare(`SELECT id, status FROM proposed_actions WHERE approval_token = ? LIMIT 1`)
        .bind(approvalToken)
        .first<{ id: string; status: string }>();

  if (!row) return json({ ok: false, error: 'action_not_found' }, 404);
  const actionScope = await env.SKY_DB
    .prepare(`SELECT workspace_id, account_id FROM proposed_actions WHERE id = ? LIMIT 1`)
    .bind(row.id)
    .first<{ workspace_id: string; account_id: string }>();
  if (!actionScope) return json({ ok: false, error: 'action_scope_missing' }, 404);
  const permission = await assertPermission(env, auth.principal, actionScope.workspace_id, actionScope.account_id);
  if (!permission.ok) return permission.response;

  if (!['proposed', 'approved'].includes(row.status)) {
    return json({ ok: false, error: `action_not_rejectable:${row.status}` }, 409);
  }

  await env.SKY_DB
    .prepare(
      `UPDATE proposed_actions
       SET status = 'rejected',
           rejected_by = ?,
           rejected_at = CURRENT_TIMESTAMP,
           rejection_reason = ?,
           updated_at = CURRENT_TIMESTAMP
       WHERE id = ?`
    )
    .bind(rejectedBy, reason, row.id)
    .run();

  await appendActionEvent(env, {
    actionId: row.id,
    workspaceId: actionScope.workspace_id,
    accountId: actionScope.account_id,
    eventType: 'rejected',
    actor: rejectedBy,
    payload: { reason }
  });

  return json({ ok: true, action: { id: row.id, status: 'rejected', reason } });
}

async function executeAction(request: Request, env: Env): Promise<Response> {
  const auth = await authorizeHttpRequest(request, env);
  if (!auth.ok) return auth.response;
  const payload = (await request.json()) as JsonRecord;
  const executedBy = stringOr(payload.userId) || auth.principal.email || auth.principal.subject;
  const actionId = stringOr(payload.actionId);
  const result = objectOr(payload.result) || {};

  if (!actionId) return json({ ok: false, error: 'actionId is required' }, 400);

  const row = await env.SKY_DB
    .prepare(`SELECT id, status, workspace_id, account_id FROM proposed_actions WHERE id = ? LIMIT 1`)
    .bind(actionId)
    .first<{ id: string; status: string; workspace_id: string; account_id: string }>();

  if (!row) return json({ ok: false, error: 'action_not_found' }, 404);
  const permission = await assertPermission(env, auth.principal, row.workspace_id, row.account_id);
  if (!permission.ok) return permission.response;

  if (row.status !== 'approved') {
    return json({ ok: false, error: `action_not_executable:${row.status}` }, 409);
  }

  await env.SKY_DB
    .prepare(
      `UPDATE proposed_actions
       SET status = 'executed',
           executed_by = ?,
           executed_at = CURRENT_TIMESTAMP,
           execution_result_json = ?,
           updated_at = CURRENT_TIMESTAMP
       WHERE id = ?`
    )
    .bind(executedBy, JSON.stringify(result), row.id)
    .run();

  await appendActionEvent(env, {
    actionId: row.id,
    workspaceId: row.workspace_id,
    accountId: row.account_id,
    eventType: 'executed',
    actor: executedBy,
    payload: result
  });

  return json({ ok: true, action: { id: row.id, status: 'executed' } });
}

async function getAccountOpsStatus(request: Request, env: Env): Promise<Response> {
  const auth = await authorizeHttpRequest(request, env);
  if (!auth.ok) return auth.response;

  const url = new URL(request.url);
  const workspaceId = url.searchParams.get('workspaceId') || 'default';
  let accountId = url.searchParams.get('accountId');
  if (!accountId) return json({ ok: false, error: 'accountId is required' }, 400);
  accountId = await ensureWorkspaceAndAccount(env, workspaceId, accountId);

  const permission = await assertPermission(env, auth.principal, workspaceId, accountId);
  if (!permission.ok) return permission.response;

  const [messages, threads, chunks, embeddings, tasksOpen, followupsOpen, decisionsRecent] = await Promise.all([
    env.SKY_DB
      .prepare('SELECT COUNT(*) AS c FROM email_messages WHERE workspace_id = ? AND account_id = ?')
      .bind(workspaceId, accountId)
      .first<{ c: number }>(),
    env.SKY_DB
      .prepare('SELECT COUNT(*) AS c FROM email_threads WHERE workspace_id = ? AND account_id = ?')
      .bind(workspaceId, accountId)
      .first<{ c: number }>(),
    env.SKY_DB
      .prepare('SELECT COUNT(*) AS c FROM memory_chunks WHERE workspace_id = ? AND account_id = ?')
      .bind(workspaceId, accountId)
      .first<{ c: number }>(),
    env.SKY_DB
      .prepare(
        `SELECT
            SUM(CASE WHEN status = 'queued' THEN 1 ELSE 0 END) AS queued,
            SUM(CASE WHEN status = 'retry' THEN 1 ELSE 0 END) AS retry,
            SUM(CASE WHEN status = 'indexed' THEN 1 ELSE 0 END) AS indexed
         FROM embedding_jobs
         WHERE workspace_id = ? AND account_id = ?`
      )
      .bind(workspaceId, accountId)
      .first<{ queued: number | null; retry: number | null; indexed: number | null }>(),
    env.SKY_DB
      .prepare("SELECT COUNT(*) AS c FROM tasks WHERE workspace_id = ? AND account_id = ? AND status IN ('ready','needs_review')")
      .bind(workspaceId, accountId)
      .first<{ c: number }>(),
    env.SKY_DB
      .prepare("SELECT COUNT(*) AS c FROM followups WHERE workspace_id = ? AND account_id = ? AND status IN ('ready','needs_review')")
      .bind(workspaceId, accountId)
      .first<{ c: number }>(),
    env.SKY_DB
      .prepare("SELECT COUNT(*) AS c FROM decisions WHERE workspace_id = ? AND account_id = ? AND date(created_at) >= date('now','utc','-7 days')")
      .bind(workspaceId, accountId)
      .first<{ c: number }>()
  ]);

  return json({
    ok: true,
    workspaceId,
    accountId,
    counts: {
      messages: Number(messages?.c || 0),
      threads: Number(threads?.c || 0),
      memoryChunks: Number(chunks?.c || 0),
      tasksOpen: Number(tasksOpen?.c || 0),
      followupsOpen: Number(followupsOpen?.c || 0),
      decisionsLast7d: Number(decisionsRecent?.c || 0)
    },
    embeddings: {
      queued: Number(embeddings?.queued || 0),
      retry: Number(embeddings?.retry || 0),
      indexed: Number(embeddings?.indexed || 0)
    },
    generatedAt: new Date().toISOString()
  });
}

async function resolveOpsScope(
  request: Request,
  env: Env
): Promise<{ ok: true; workspaceId: string; accountId: string } | { ok: false; response: Response }> {
  const auth = await authorizeHttpRequest(request, env);
  if (!auth.ok) return { ok: false, response: auth.response };

  const url = new URL(request.url);
  const workspaceId = url.searchParams.get('workspaceId') || 'default';
  let accountId = url.searchParams.get('accountId');
  if (!accountId) return { ok: false, response: json({ ok: false, error: 'accountId is required' }, 400) };
  accountId = await ensureWorkspaceAndAccount(env, workspaceId, accountId);

  const permission = await assertPermission(env, auth.principal, workspaceId, accountId);
  if (!permission.ok) return { ok: false, response: permission.response };

  return { ok: true, workspaceId, accountId };
}

async function getIngestStats(request: Request, env: Env): Promise<Response> {
  const scope = await resolveOpsScope(request, env);
  if (!scope.ok) return scope.response;
  const { workspaceId, accountId } = scope;

  const [total, last24h, latest] = await Promise.all([
    env.SKY_DB
      .prepare(`SELECT COUNT(*) AS c FROM email_messages WHERE workspace_id = ? AND account_id = ?`)
      .bind(workspaceId, accountId)
      .first<{ c: number }>(),
    env.SKY_DB
      .prepare(
        `SELECT COUNT(*) AS c
         FROM email_messages
         WHERE workspace_id = ?
           AND account_id = ?
           AND datetime(created_at) >= datetime(CURRENT_TIMESTAMP, '-24 hours')`
      )
      .bind(workspaceId, accountId)
      .first<{ c: number }>(),
    env.SKY_DB
      .prepare(
        `SELECT MAX(created_at) AS last_ingested_at, MAX(sent_at) AS last_sent_at
         FROM email_messages
         WHERE workspace_id = ?
           AND account_id = ?`
      )
      .bind(workspaceId, accountId)
      .first<{ last_ingested_at: string | null; last_sent_at: string | null }>()
  ]);

  return json({
    ok: true,
    workspaceId,
    accountId,
    totals: {
      messages: Number(total?.c || 0),
      messagesLast24h: Number(last24h?.c || 0)
    },
    freshness: {
      lastIngestedAt: latest?.last_ingested_at || null,
      lastSentAt: latest?.last_sent_at || null,
      ingestLagMinutes: minutesSince(latest?.last_ingested_at || null)
    },
    generatedAt: new Date().toISOString()
  });
}

async function getQueueStats(request: Request, env: Env): Promise<Response> {
  const scope = await resolveOpsScope(request, env);
  if (!scope.ok) return scope.response;
  const { workspaceId, accountId } = scope;

  const row = await env.SKY_DB
    .prepare(
      `SELECT
          SUM(CASE WHEN status = 'queued' THEN 1 ELSE 0 END) AS queued,
          SUM(CASE WHEN status = 'retry' THEN 1 ELSE 0 END) AS retry,
          SUM(CASE WHEN status = 'indexed' THEN 1 ELSE 0 END) AS indexed,
          MIN(CASE WHEN status IN ('queued','retry') THEN next_attempt_at END) AS oldest_next_attempt_at
       FROM embedding_jobs
       WHERE workspace_id = ?
         AND account_id = ?`
    )
    .bind(workspaceId, accountId)
    .first<{ queued: number | null; retry: number | null; indexed: number | null; oldest_next_attempt_at: string | null }>();

  return json({
    ok: true,
    workspaceId,
    accountId,
    embeddingQueue: {
      queued: Number(row?.queued || 0),
      retry: Number(row?.retry || 0),
      indexed: Number(row?.indexed || 0),
      oldestNextAttemptAt: row?.oldest_next_attempt_at || null,
      oldestPendingLagMinutes: minutesSince(row?.oldest_next_attempt_at || null)
    },
    generatedAt: new Date().toISOString()
  });
}

async function getExtractionStats(request: Request, env: Env): Promise<Response> {
  const scope = await resolveOpsScope(request, env);
  if (!scope.ok) return scope.response;
  const { workspaceId, accountId } = scope;

  const [taskQueue, followupQueue, decisionQueue, extractionRows, citationRows] = await Promise.all([
    env.SKY_DB
      .prepare(
        `SELECT SUM(CASE WHEN review_state = 'needs_review' THEN 1 ELSE 0 END) AS c
         FROM tasks
         WHERE workspace_id = ? AND account_id = ?`
      )
      .bind(workspaceId, accountId)
      .first<{ c: number | null }>(),
    env.SKY_DB
      .prepare(
        `SELECT SUM(CASE WHEN review_state = 'needs_review' THEN 1 ELSE 0 END) AS c
         FROM followups
         WHERE workspace_id = ? AND account_id = ?`
      )
      .bind(workspaceId, accountId)
      .first<{ c: number | null }>(),
    env.SKY_DB
      .prepare(
        `SELECT SUM(CASE WHEN review_state = 'needs_review' THEN 1 ELSE 0 END) AS c
         FROM decisions
         WHERE workspace_id = ? AND account_id = ?`
      )
      .bind(workspaceId, accountId)
      .first<{ c: number | null }>(),
    env.SKY_DB
      .prepare(
        `SELECT
            SUM(CASE WHEN status = 'needs_review' THEN 1 ELSE 0 END) AS extractions_needs_review,
            COUNT(*) AS extractions_total
         FROM message_extractions
         WHERE workspace_id = ? AND account_id = ?`
      )
      .bind(workspaceId, accountId)
      .first<{ extractions_needs_review: number | null; extractions_total: number | null }>(),
    env.SKY_DB
      .prepare(
        `SELECT
            SUM(CASE WHEN citation_status = 'sufficient' THEN 1 ELSE 0 END) AS sufficient_runs,
            COUNT(*) AS total_runs
         FROM run_search_audits
         WHERE workspace_id = ?
           AND account_id = ?
           AND datetime(created_at) >= datetime(CURRENT_TIMESTAMP, '-7 days')`
      )
      .bind(workspaceId, accountId)
      .first<{ sufficient_runs: number | null; total_runs: number | null }>()
  ]);

  const sufficient = Number(citationRows?.sufficient_runs || 0);
  const totalRuns = Number(citationRows?.total_runs || 0);
  const citationHitRate = totalRuns > 0 ? Number((sufficient / totalRuns).toFixed(4)) : null;

  return json({
    ok: true,
    workspaceId,
    accountId,
    reviewQueue: {
      tasksNeedsReview: Number(taskQueue?.c || 0),
      followupsNeedsReview: Number(followupQueue?.c || 0),
      decisionsNeedsReview: Number(decisionQueue?.c || 0),
      extractionsNeedsReview: Number(extractionRows?.extractions_needs_review || 0),
      extractionsTotal: Number(extractionRows?.extractions_total || 0)
    },
    citationQuality7d: {
      sufficientRuns: sufficient,
      totalRuns,
      hitRate: citationHitRate
    },
    generatedAt: new Date().toISOString()
  });
}

async function getUsageStats(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  const auth = await authorizeHttpRequest(request, env);
  if (!auth.ok) return auth.response;
  const workspaceId = url.searchParams.get('workspaceId') || 'default';
  const accountId = (url.searchParams.get('accountId') || '').trim() || null;
  if (accountId) {
    const permission = await assertPermission(env, auth.principal, workspaceId, accountId);
    if (!permission.ok) return permission.response;
  } else {
    const permission = await assertWorkspacePermission(env, auth.principal, workspaceId);
    if (!permission.ok) return permission.response;
  }

  const daysRaw = Number(url.searchParams.get('days') || '7');
  const days = Number.isFinite(daysRaw) && daysRaw > 0 ? Math.min(90, Math.trunc(daysRaw)) : 7;
  const includeErrors = (url.searchParams.get('includeErrors') || '').toLowerCase() === 'true';

  const rows = await env.SKY_DB
    .prepare(
      `SELECT provider,
              model,
              operation,
              status,
              COUNT(*) AS calls,
              COALESCE(SUM(request_units), 0) AS request_units,
              COALESCE(SUM(response_units), 0) AS response_units,
              COALESCE(SUM(estimated_cost_usd), 0) AS estimated_cost_usd,
              SUM(CASE WHEN estimated_cost_usd IS NOT NULL THEN 1 ELSE 0 END) AS cost_known_calls
       FROM model_usage_events
       WHERE workspace_id = ?
         AND (? IS NULL OR COALESCE(account_id, '') = ?)
         AND (? = 1 OR status = 'ok')
         AND datetime(created_at) >= datetime(CURRENT_TIMESTAMP, '-' || ? || ' days')
       GROUP BY provider, model, operation, status
       ORDER BY estimated_cost_usd DESC, calls DESC`
    )
    .bind(workspaceId, accountId, accountId, includeErrors ? 1 : 0, String(days))
    .all<{
      provider: string;
      model: string;
      operation: string;
      status: string;
      calls: number | string;
      request_units: number | string;
      response_units: number | string;
      estimated_cost_usd: number | string;
      cost_known_calls: number | string;
    }>();

  const totals = (rows.results || []).reduce(
    (acc, row) => {
      acc.calls += Number(row.calls || 0);
      acc.requestUnits += Number(row.request_units || 0);
      acc.responseUnits += Number(row.response_units || 0);
      acc.estimatedCostUsd += Number(row.estimated_cost_usd || 0);
      acc.costKnownCalls += Number(row.cost_known_calls || 0);
      if ((row.status || 'ok') === 'error') acc.errorCalls += Number(row.calls || 0);
      return acc;
    },
    { calls: 0, requestUnits: 0, responseUnits: 0, estimatedCostUsd: 0, costKnownCalls: 0, errorCalls: 0 }
  );

  return json({
    ok: true,
    workspaceId,
    accountId,
    windowDays: days,
    includeErrors,
    totals: {
      calls: totals.calls,
      requestUnits: totals.requestUnits,
      responseUnits: totals.responseUnits,
      estimatedCostUsd: Number(totals.estimatedCostUsd.toFixed(6)),
      costKnownCalls: totals.costKnownCalls,
      errorCalls: totals.errorCalls
    },
    breakdown: (rows.results || []).map((row) => ({
      provider: row.provider,
      model: row.model,
      operation: row.operation,
      status: row.status || 'ok',
      calls: Number(row.calls || 0),
      requestUnits: Number(row.request_units || 0),
      responseUnits: Number(row.response_units || 0),
      estimatedCostUsd: Number(Number(row.estimated_cost_usd || 0).toFixed(6)),
      costKnownCalls: Number(row.cost_known_calls || 0)
    })),
    generatedAt: new Date().toISOString()
  });
}

async function getProviderHealth(request: Request, env: Env): Promise<Response> {
  const auth = await authorizeHttpRequest(request, env);
  if (!auth.ok) return auth.response;

  const openai = await getProviderHealthState(env.SKY_DB, 'openai');
  const disabled = await isProviderTemporarilyDisabled(env.SKY_DB, 'openai');

  const recentErrors = await env.SKY_DB
    .prepare(
      `SELECT
         COUNT(*) AS total_errors,
         SUM(CASE WHEN error_code = 'insufficient_quota' THEN 1 ELSE 0 END) AS insufficient_quota_errors
       FROM model_usage_events
       WHERE provider = 'openai'
         AND status = 'error'
         AND created_at >= datetime('now', 'utc', '-24 hours')`
    )
    .first<{ total_errors: number | null; insufficient_quota_errors: number | null }>();

  return json({
    ok: true,
    provider: 'openai',
    disabled,
    state: openai,
    last24h: {
      totalErrors: Number(recentErrors?.total_errors || 0),
      insufficientQuotaErrors: Number(recentErrors?.insufficient_quota_errors || 0)
    },
    generatedAt: new Date().toISOString()
  });
}

async function assertWorkspacePermission(
  env: Env,
  principal: AuthPrincipal,
  workspaceId: string
): Promise<{ ok: true } | { ok: false; response: Response }> {
  if (principal.type === 'service' || principal.type === 'anonymous') return { ok: true };

  const row = await env.SKY_DB
    .prepare(
      `SELECT id
       FROM access_subject_permissions
       WHERE subject = ?
         AND workspace_id = ?
         AND status = 'active'
       LIMIT 1`
    )
    .bind(principal.subject, workspaceId)
    .first<{ id: string }>();

  if (!row) return { ok: false, response: json({ ok: false, error: 'forbidden' }, 403) };
  return { ok: true };
}

async function getTriageStats(request: Request, env: Env): Promise<Response> {
  const scope = await resolveOpsScope(request, env);
  if (!scope.ok) return scope.response;
  const { workspaceId, accountId } = scope;

  const [priorityRows, categoryRows, replyRows, sentimentRows] = await Promise.all([
    env.SKY_DB
      .prepare(
        `SELECT COALESCE(json_extract(classification_json, '$.priority'), 'unknown') AS key, COUNT(*) AS c
         FROM email_threads
         WHERE workspace_id = ?
           AND account_id = ?
           AND classification_json IS NOT NULL
         GROUP BY key
         ORDER BY c DESC`
      )
      .bind(workspaceId, accountId)
      .all<{ key: string; c: number }>(),
    env.SKY_DB
      .prepare(
        `SELECT COALESCE(json_extract(classification_json, '$.category'), 'unknown') AS key, COUNT(*) AS c
         FROM email_threads
         WHERE workspace_id = ?
           AND account_id = ?
           AND classification_json IS NOT NULL
         GROUP BY key
         ORDER BY c DESC`
      )
      .bind(workspaceId, accountId)
      .all<{ key: string; c: number }>(),
    env.SKY_DB
      .prepare(
        `SELECT COALESCE(CAST(json_extract(classification_json, '$.needs_reply') AS INTEGER), 0) AS key, COUNT(*) AS c
         FROM email_threads
         WHERE workspace_id = ?
           AND account_id = ?
           AND classification_json IS NOT NULL
         GROUP BY key
         ORDER BY c DESC`
      )
      .bind(workspaceId, accountId)
      .all<{ key: number; c: number }>(),
    env.SKY_DB
      .prepare(
        `SELECT COALESCE(json_extract(classification_json, '$.sentiment'), 'unknown') AS key, COUNT(*) AS c
         FROM email_threads
         WHERE workspace_id = ?
           AND account_id = ?
           AND classification_json IS NOT NULL
         GROUP BY key
         ORDER BY c DESC`
      )
      .bind(workspaceId, accountId)
      .all<{ key: string; c: number }>()
  ]);

  const toMap = (rows: Array<{ key: string | number; c: number }>): Record<string, number> => {
    const out: Record<string, number> = {};
    for (const row of rows) out[String(row.key)] = Number(row.c || 0);
    return out;
  };

  return json({
    ok: true,
    workspaceId,
    accountId,
    triage: {
      byPriority: toMap(priorityRows.results || []),
      byCategory: toMap(categoryRows.results || []),
      bySentiment: toMap(sentimentRows.results || []),
      needsReply: {
        true: Number((replyRows.results || []).find((x) => Number(x.key) === 1)?.c || 0),
        false: Number((replyRows.results || []).find((x) => Number(x.key) === 0)?.c || 0)
      }
    },
    generatedAt: new Date().toISOString()
  });
}

async function executeIntent(
  env: Env,
  ctx: { workspaceId: string; accountId: string },
  query: string,
  intent: QueryIntent,
  runId: string
): Promise<QueryResult> {
  if (intent === 'financial_query' || intent === 'attention_query') {
    const result = await executeEntityQuery(env, ctx, intent);
    return {
      intent,
      answer: result.answer,
      citations: result.citations,
      citationStatus: result.citations.length > 0 ? 'sufficient' : 'insufficient',
      searched: result.searched
    };
  }

  if (intent === 'calendar_query') {
    const result = await executeCalendarQuery(env, ctx, query);
    return {
      intent,
      answer: result.answer,
      citations: result.citations,
      citationStatus: result.citations.length > 0 ? 'sufficient' : 'insufficient',
      searched: result.searched
    };
  }

  if (intent === 'thread_summary') {
    const summary = await buildThreadSummaryIntent(env, ctx.workspaceId, ctx.accountId, query);
    return {
      intent,
      answer: summary.answer,
      citations: summary.citations,
      citationStatus: summary.citations.length > 0 ? 'sufficient' : 'insufficient',
      searched: summary.searched
    };
  }

  const unified = await executeUnifiedFindEmailQuery(env, {
    workspaceId: ctx.workspaceId,
    accountId: ctx.accountId,
    query,
    runId,
    includeProposals: false
  });
  return {
    intent,
    answer: unified.answer,
    citations: unified.citations,
    citationStatus: unified.citations.length > 0 ? 'sufficient' : 'insufficient',
    searched: unified.searched
  };
}

async function executeEntityQuery(
  env: Env,
  ctx: { workspaceId: string; accountId: string },
  intent: 'financial_query' | 'attention_query'
): Promise<{ answer: string; citations: Citation[]; searched: JsonRecord }> {
  const rowResult = intent === 'financial_query'
    ? await env.SKY_DB
        .prepare(
          `SELECT ee.entity_type, ee.direction, ee.counterparty_name, ee.amount_cents, ee.currency,
                  ee.due_date, ee.reference_number, ee.status, ee.action_required,
                  ee.action_description, ee.risk_level, ee.message_id,
                  em.subject, em.sent_at
           FROM email_entities ee
           LEFT JOIN email_messages em ON em.id = ee.message_id
           WHERE ee.workspace_id = ? AND ee.account_id = ?
             AND ee.entity_type IN ('invoice', 'payment', 'contract')
             AND (
               ee.resolved_group_id IS NULL
               OR ee.id = (SELECT MIN(e2.id) FROM email_entities e2 WHERE e2.resolved_group_id = ee.resolved_group_id)
             )
           ORDER BY
             CASE ee.risk_level WHEN 'critical' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 ELSE 3 END ASC,
             ee.action_required DESC,
             datetime(COALESCE(ee.due_date, '2999-12-31')) ASC
           LIMIT 20`
        )
        .bind(ctx.workspaceId, ctx.accountId)
        .all<{
          entity_type: string;
          direction: string;
          counterparty_name: string | null;
          amount_cents: number | null;
          currency: string | null;
          due_date: string | null;
          reference_number: string | null;
          status: string;
          action_required: number;
          action_description: string | null;
          risk_level: string;
          subject: string | null;
          message_id: string;
          sent_at: string | null;
        }>()
    : await env.SKY_DB
        .prepare(
          `SELECT ee.entity_type, ee.direction, ee.counterparty_name, ee.amount_cents, ee.currency,
                  ee.due_date, ee.reference_number, ee.status, ee.action_required,
                  ee.action_description, ee.risk_level, ee.message_id,
                  em.subject, em.sent_at
           FROM email_entities ee
           LEFT JOIN email_messages em ON em.id = ee.message_id
           WHERE ee.workspace_id = ? AND ee.account_id = ?
             AND ee.action_required = 1
             AND (
               ee.resolved_group_id IS NULL
               OR ee.id = (SELECT MIN(e2.id) FROM email_entities e2 WHERE e2.resolved_group_id = ee.resolved_group_id)
             )
           ORDER BY
             CASE ee.risk_level WHEN 'critical' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 ELSE 3 END ASC,
             datetime(COALESCE(ee.due_date, '2999-12-31')) ASC
           LIMIT 15`
        )
        .bind(ctx.workspaceId, ctx.accountId)
        .all<{
          entity_type: string;
          direction: string;
          counterparty_name: string | null;
          amount_cents: number | null;
          currency: string | null;
          due_date: string | null;
          reference_number: string | null;
          status: string;
          action_required: number;
          action_description: string | null;
          risk_level: string;
          subject: string | null;
          message_id: string;
          sent_at: string | null;
        }>();

  const rows = rowResult.results || [];

  if (rows.length === 0) {
    return {
      answer: intent === 'financial_query'
        ? 'No invoices, payments, or contracts found in your email history.'
        : 'Nothing requiring your attention was found.',
      citations: [],
      searched: { intent, source: 'email_entities' }
    };
  }

  const formatCents = (cents: number | null, currency: string | null): string => {
    if (!Number.isFinite(Number(cents)) || Number(cents) <= 0) return '';
    return ` - ${currency || 'USD'} $${(Number(cents) / 100).toFixed(2)}`;
  };

  const contextLines = rows.map((e) =>
    `[${String(e.risk_level || 'low').toUpperCase()}] ${e.entity_type} | ${e.direction} | ${e.counterparty_name || 'unknown'}${formatCents(e.amount_cents, e.currency)} | status: ${e.status} | action_required: ${e.action_required ? 'yes' : 'no'} | ${e.action_description || e.subject || ''} | message_id: ${e.message_id}`
  ).join('\n');

  const systemPrompt = intent === 'financial_query'
    ? 'You are Blawby, an AI chief-of-staff. Summarize the user\'s financial position from these structured email entity facts. Be specific with names and amounts. Distinguish clearly between money they are OWED (AR, direction=ar) and money they OWE (AP, direction=ap). Flag anything overdue or high risk. End with the single most important financial action they should take right now. Be concise.'
    : 'You are Blawby, an AI chief-of-staff. The user wants to know what needs their attention. Here are structured facts extracted from their emails, ranked by risk. For each item requiring action, state who it involves, what is needed, and why it matters. Be specific. End with the single highest-leverage action they should take first. No filler.';

  const answer = await callOpenAiChatViaGateway(
    env,
    [
      { role: 'system', content: systemPrompt },
      { role: 'user', content: contextLines }
    ],
    undefined,
    { workspaceId: ctx.workspaceId, accountId: ctx.accountId, operation: 'entity_query', endpoint: '/chat/query' }
  );

  const citations: Citation[] = rows
    .filter((e) => Boolean(e.message_id))
    .slice(0, 5)
    .map((e) => ({
      messageId: e.message_id,
      date: e.sent_at,
      from: e.counterparty_name || '',
      subject: e.subject || e.entity_type,
      score: e.risk_level === 'critical' ? 1.0 : e.risk_level === 'high' ? 0.9 : e.risk_level === 'medium' ? 0.75 : 0.6
    }));

  return { answer, citations, searched: { intent, source: 'email_entities', rows_found: rows.length } };
}

async function executeCalendarQuery(
  env: Env,
  ctx: { workspaceId: string; accountId: string },
  query: string
): Promise<{ answer: string; citations: Citation[]; searched: JsonRecord }> {
  const rowsResult = await env.SKY_DB
    .prepare(
      `SELECT id,
              title,
              location,
              start_at,
              end_at,
              all_day,
              calendar_name,
              attendees_json
       FROM calendar_events
       WHERE workspace_id = ?
         AND account_id = ?
         AND datetime(start_at) >= datetime(CURRENT_TIMESTAMP)
         AND datetime(start_at) < datetime(CURRENT_TIMESTAMP, '+7 days')
       ORDER BY datetime(start_at) ASC
       LIMIT 50`
    )
    .bind(ctx.workspaceId, ctx.accountId)
    .all<{
      id: string;
      title: string | null;
      location: string | null;
      start_at: string;
      end_at: string;
      all_day: number;
      calendar_name: string | null;
      attendees_json: string | null;
    }>();

  const rows = rowsResult.results || [];
  if (rows.length === 0) {
    return {
      answer: 'No calendar events found for the next 7 days.',
      citations: [],
      searched: { intent: 'calendar_query', source: 'calendar_events', rows_found: 0 }
    };
  }

  const contextLines = rows.map((e) => {
    const attendees = (() => {
      try {
        const parsed = JSON.parse(e.attendees_json || '[]') as Array<Record<string, unknown>>;
        return parsed
          .map((a) => String(a.name || a.email || '').trim())
          .filter(Boolean)
          .slice(0, 4)
          .join(', ');
      } catch {
        return '';
      }
    })();
    return `[${e.start_at}] ${(e.title || '(untitled)')} | location: ${e.location || 'none'} | calendar: ${e.calendar_name || 'default'} | attendees: ${attendees || 'none'} | all_day: ${e.all_day ? 'yes' : 'no'} | event_id: ${e.id}`;
  }).join('\n');

  const answer = await callOpenAiChatViaGateway(
    env,
    [
      {
        role: 'system',
        content: 'You are Blawby, an AI chief-of-staff. Answer schedule and calendar questions using the provided event facts only. Be concise, chronological, and explicit about times.'
      },
      {
        role: 'user',
        content: `User question: ${query}\n\nCalendar events (next 7 days):\n${contextLines}`
      }
    ],
    undefined,
    { workspaceId: ctx.workspaceId, accountId: ctx.accountId, operation: 'calendar_query', endpoint: '/chat/query' }
  );

  const citations: Citation[] = rows.slice(0, 8).map((e, idx) => ({
    messageId: e.id,
    date: e.start_at,
    from: e.calendar_name || 'calendar',
    subject: e.title || '(untitled)',
    score: Math.max(0.6, 1 - idx * 0.05)
  }));

  return {
    answer,
    citations,
    searched: { intent: 'calendar_query', source: 'calendar_events', rows_found: rows.length }
  };
}

async function buildThreadSummaryIntent(
  env: Env,
  workspaceId: string,
  accountId: string,
  query: string
): Promise<{ answer: string; citations: Citation[]; searched: JsonRecord }> {
  const hits = await queryCitations(env, workspaceId, accountId, query);
  if (hits.length === 0) {
    return {
      answer: 'Insufficient sources for thread_summary. No matching thread evidence found.',
      citations: [],
      searched: { intent: 'thread_summary', query, strategy: 'message match -> thread lookup' }
    };
  }

  const first = hits[0];
  const msg = await env.SKY_DB
    .prepare(`SELECT thread_id FROM email_messages WHERE id = ? LIMIT 1`)
    .bind(first.messageId)
    .first<{ thread_id: string | null }>();

  if (!msg?.thread_id) {
    return {
      answer: 'Insufficient sources for thread_summary. Matched email had no thread identifier.',
      citations: [],
      searched: { intent: 'thread_summary', query, strategy: 'thread_id missing' }
    };
  }

  const rows = await env.SKY_DB
    .prepare(
      `SELECT id, sent_at, subject, snippet,
              COALESCE(
                json_extract(from_json, '$[0].email'),
                json_extract(from_json, '$[0].address'),
                ''
              ) AS sender
       FROM email_messages
       WHERE workspace_id = ?
         AND (account_id = ? OR lower(account_email) = ?)
         AND thread_id = ?
       ORDER BY datetime(COALESCE(sent_at, created_at)) DESC
       LIMIT 8`
    )
    .bind(workspaceId, accountId, accountId.toLowerCase(), msg.thread_id)
    .all<{ id: string; sent_at: string | null; subject: string | null; snippet: string | null; sender: string | null }>();

  const citations = (rows.results || []).map((r, idx) => ({
    messageId: r.id,
    date: r.sent_at,
    from: r.sender || 'unknown',
    subject: r.subject || '(no subject)',
    score: Math.max(0, 1 - idx * 0.08)
  }));

  if (citations.length === 0) {
    return {
      answer: 'Insufficient sources for thread_summary. Thread had no retrievable messages.',
      citations: [],
      searched: { intent: 'thread_summary', query, threadId: msg.thread_id }
    };
  }

  const subjects = citations.slice(0, 5).map((c, i) => `${i + 1}. ${c.subject} (${c.from})`);
  return {
    answer: `Thread summary (latest first):\n${subjects.join('\n')}`,
    citations,
    searched: { intent: 'thread_summary', query, threadId: msg.thread_id }
  };
}

function detectIntent(query: string): QueryIntent {
  const q = query.toLowerCase();
  if (q.includes('thread summary') || q.includes('summarize thread')) {
    return 'thread_summary';
  }

  if (
    /\b(owe|owed|invoice|invoices|unpaid|payment|payments|ar|ap|receivable|payable|outstanding|balance due|collect|collections)\b/.test(q)
  ) {
    return 'financial_query';
  }

  if (
    /\b(calendar|schedule|meeting|on my agenda|today'?s events|what do i have)\b/.test(q)
  ) {
    return 'calendar_query';
  }

  if (
    isDailyBriefingQuery(query) ||
    /\b(attention|priorit|action|urgent|today|this week|need to do|focus on|catch me up)\b/.test(q)
  ) {
    return 'attention_query';
  }

  return 'find_email';
}

function isDailyBriefingQuery(query: string): boolean {
  const q = query.toLowerCase();
  const hasToday = /\btoday\b/.test(q);
  const hasBriefingCue =
    /\bdaily\s+briefing\b/.test(q) ||
    /\bgood\s+morning\b/.test(q) ||
    /\btop\s+priorit/.test(q) ||
    /\btake\s+care\b/.test(q) ||
    /\btoday\s+actions?\b/.test(q);
  const hasUrgencyCue = /\b(attention|priorit|urgent|need)\b/.test(q);
  return (
    (hasToday && hasUrgencyCue) ||
    hasBriefingCue
  );
}

function extractActionSignals(text: string, sentAt: string | null, sender: string, accountId: string): {
  tasks: Array<{ text: string; priority: string; dueAt: string | null; confidence: number; reviewState: string; owner: string }>;
  decisions: Array<{ text: string; confidence: number; reviewState: string; owner: string }>;
  followups: Array<{ text: string; dueAt: string | null; confidence: number; reviewState: string; owner: string }>;
} {
  const t = text.trim();
  const lower = t.toLowerCase();
  const taskPatterns = [/\bplease\b/, /\bneed to\b/, /\bcan you\b/, /\btodo\b/, /\baction item\b/, /\bby\s+\w+/];
  const decisionPatterns = [/\bdecided\b/, /\bapproved\b/, /\bwe will\b/, /\blet'?s\b/, /\bfinal decision\b/];
  const followupPatterns = [/\bfollow up\b/, /\bchecking in\b/, /\bremind\b/, /\bcircle back\b/];

  const taskHits = taskPatterns.filter((r) => r.test(lower)).length;
  const decisionHits = decisionPatterns.filter((r) => r.test(lower)).length;
  const followupHits = followupPatterns.filter((r) => r.test(lower)).length;

  const dueAt = parseDueAt(lower, sentAt);
  const owner = lower.includes('you') ? accountId : sender || accountId;

  const tasks = taskHits > 0
    ? [
        {
          text: truncateText(t, 180),
          priority: taskHits >= 2 || /\burgent|asap|today\b/.test(lower) ? 'high' : 'medium',
          dueAt,
          confidence: Math.min(0.95, 0.55 + taskHits * 0.15),
          reviewState: taskHits >= 2 ? 'ready' : 'needs_review',
          owner
        }
      ]
    : [];

  const decisions = decisionHits > 0
    ? [
        {
          text: truncateText(t, 220),
          confidence: Math.min(0.95, 0.55 + decisionHits * 0.15),
          reviewState: decisionHits >= 2 ? 'ready' : 'needs_review',
          owner
        }
      ]
    : [];

  const followups = followupHits > 0
    ? [
        {
          text: truncateText(t, 180),
          dueAt,
          confidence: Math.min(0.9, 0.5 + followupHits * 0.2),
          reviewState: followupHits >= 2 ? 'ready' : 'needs_review',
          owner
        }
      ]
    : [];

  return { tasks, decisions, followups };
}

function parseDueAt(lower: string, sentAt: string | null): string | null {
  const iso = lower.match(/\b(20\d{2}-\d{2}-\d{2})\b/);
  if (iso) return `${iso[1]}T00:00:00.000Z`;

  const base = sentAt ? new Date(sentAt) : new Date();
  if (lower.includes('tomorrow')) {
    const d = new Date(base);
    d.setUTCDate(d.getUTCDate() + 1);
    return d.toISOString();
  }
  if (lower.includes('next week')) {
    const d = new Date(base);
    d.setUTCDate(d.getUTCDate() + 7);
    return d.toISOString();
  }
  if (lower.includes('today')) {
    return base.toISOString();
  }

  return null;
}

function computePriorityScore(priority: string | null, dueAt: string | null, now: Date): number {
  const p = (priority || 'medium').toLowerCase();
  let score = p === 'high' ? 3 : p === 'low' ? 1 : 2;
  if (dueAt) {
    const dueTs = new Date(dueAt).getTime();
    const nowTs = now.getTime();
    if (!Number.isNaN(dueTs)) {
      if (dueTs < nowTs) score += 3;
      else if (dueTs - nowTs < 24 * 60 * 60 * 1000) score += 2;
      else if (dueTs - nowTs < 3 * 24 * 60 * 60 * 1000) score += 1;
    }
  }
  return score;
}

async function loadCitationsForMessages(
  env: Env,
  workspaceId: string,
  accountId: string,
  messageIds: string[]
): Promise<Map<string, Citation>> {
  if (messageIds.length === 0) return new Map();

  const placeholders = messageIds.map(() => '?').join(',');
  const rows = await env.SKY_DB
    .prepare(
      `SELECT id, sent_at, subject,
              COALESCE(
                json_extract(from_json, '$[0].email'),
                json_extract(from_json, '$[0].address'),
                ''
              ) AS sender
       FROM email_messages
       WHERE workspace_id = ?
         AND id IN (${placeholders})`
    )
    .bind(workspaceId, ...messageIds)
    .all<{ id: string; sent_at: string | null; subject: string | null; sender: string | null }>();

  const map = new Map<string, Citation>();
  for (const row of rows.results || []) {
    map.set(row.id, {
      messageId: row.id,
      date: row.sent_at,
      from: row.sender || 'unknown',
      subject: row.subject || '(no subject)',
      score: 0.8
    });
  }
  return map;
}

async function ensureWorkspaceAndAccount(env: Env, workspaceId: string, accountId: string): Promise<string> {
  await env.SKY_DB
    .prepare(
      `INSERT OR IGNORE INTO workspaces (id, name, status, created_at, updated_at)
       VALUES (?, ?, 'active', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)`
    )
    .bind(workspaceId, workspaceId)
    .run();

  if (accountId.includes('@')) {
    const accountEmail = accountId.trim();

    const existing = await env.SKY_DB
      .prepare(
        `SELECT id
         FROM connected_accounts
         WHERE workspace_id = ?
           AND email = ?
         LIMIT 1`
      )
      .bind(workspaceId, accountEmail)
      .first<{ id: string }>();
    if (existing?.id) return existing.id;

    await env.SKY_DB
      .prepare(
        `INSERT OR IGNORE INTO connected_accounts
           (id, workspace_id, label, email, status, provider, identifier, display_name, config_json, onboarding_complete, created_at, updated_at)
         VALUES
           (?, ?, ?, ?, 'active', 'email_icloud', ?, ?, '{}', 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)`
      )
      .bind(accountEmail, workspaceId, accountEmail, accountEmail, accountEmail.toLowerCase(), accountEmail)
      .run();

    return accountEmail;
  }

  const canonicalId = accountId.trim();
  const existing = await env.SKY_DB
    .prepare(
      `SELECT id
       FROM connected_accounts
       WHERE workspace_id = ?
         AND id = ?
       LIMIT 1`
    )
    .bind(workspaceId, canonicalId)
    .first<{ id: string }>();
  if (existing?.id) return existing.id;

  await env.SKY_DB
    .prepare(
      `INSERT OR IGNORE INTO connected_accounts
         (id, workspace_id, label, email, status, provider, identifier, display_name, config_json, onboarding_complete, created_at, updated_at)
       VALUES
         (?, ?, ?, NULL, 'active', 'email_icloud', ?, ?, '{}', 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)`
    )
    .bind(canonicalId, workspaceId, canonicalId, canonicalId, canonicalId)
    .run();
  return canonicalId;
}

async function ensureSession(
  env: Env,
  input: { sessionId: string; workspaceId: string; accountId: string; userId: string }
): Promise<void> {
  await env.SKY_DB
    .prepare(
      `INSERT OR IGNORE INTO chat_sessions
       (id, workspace_id, account_id, user_id, status, last_event_at, created_at, updated_at)
       VALUES (?, ?, ?, ?, 'active', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)`
    )
    .bind(input.sessionId, input.workspaceId, input.accountId, input.userId)
    .run();

  await env.SKY_DB
    .prepare(`UPDATE chat_sessions SET updated_at = CURRENT_TIMESTAMP WHERE id = ?`)
    .bind(input.sessionId)
    .run();
}

async function setSessionActiveRun(env: Env, sessionId: string, runId: string): Promise<void> {
  await env.SKY_DB
    .prepare(
      `UPDATE chat_sessions
       SET active_run_id = ?, last_event_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
       WHERE id = ?`
    )
    .bind(runId, sessionId)
    .run();
}

async function clearSessionActiveRun(env: Env, sessionId: string): Promise<void> {
  await env.SKY_DB
    .prepare(
      `UPDATE chat_sessions
       SET active_run_id = NULL, last_event_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
       WHERE id = ?`
    )
    .bind(sessionId)
    .run();
}

async function loadRunEvents(
  env: Env,
  sessionId: string,
  since: string | null,
  lastEventId: string | null,
  limit: number
): Promise<Array<{ event_cursor: number; id: string; run_id: string | null; turn_id: string | null; event_type: string; payload_json: string | null; created_at: string }>> {
  const normalizedLimit = Math.min(Math.max(limit, 1), 1000);

  if (lastEventId) {
    const cursor = numberOr(lastEventId);
    if (cursor) {
      const result = await env.SKY_DB
        .prepare(
          `SELECT rowid AS event_cursor, id, run_id, turn_id, event_type, payload_json, created_at
           FROM run_events
           WHERE session_id = ?
             AND rowid > ?
           ORDER BY rowid ASC
           LIMIT ?`
        )
        .bind(sessionId, cursor, normalizedLimit)
        .all<{ event_cursor: number; id: string; run_id: string | null; turn_id: string | null; event_type: string; payload_json: string | null; created_at: string }>();
      return result.results || [];
    }
  }

  if (since) {
    const result = await env.SKY_DB
      .prepare(
        `SELECT rowid AS event_cursor, id, run_id, turn_id, event_type, payload_json, created_at
         FROM run_events
         WHERE session_id = ?
           AND datetime(created_at) > datetime(?)
         ORDER BY datetime(created_at) ASC, id ASC
         LIMIT ?`
      )
      .bind(sessionId, since, normalizedLimit)
      .all<{ event_cursor: number; id: string; run_id: string | null; turn_id: string | null; event_type: string; payload_json: string | null; created_at: string }>();
    return result.results || [];
  }

  const result = await env.SKY_DB
    .prepare(
      `SELECT rowid AS event_cursor, id, run_id, turn_id, event_type, payload_json, created_at
       FROM run_events
       WHERE session_id = ?
       ORDER BY rowid DESC
       LIMIT ?`
    )
    .bind(sessionId, normalizedLimit)
    .all<{ event_cursor: number; id: string; run_id: string | null; turn_id: string | null; event_type: string; payload_json: string | null; created_at: string }>();

  return (result.results || []).reverse();
}

async function insertTurn(
  env: Env,
  input: {
    sessionId: string;
    workspaceId: string;
    accountId: string;
    runId: string;
    role: 'user' | 'assistant';
    content: string;
    citationRequired: boolean;
    citationStatus: string;
  }
): Promise<string> {
  const id = crypto.randomUUID();
  await env.SKY_DB
    .prepare(
      `INSERT INTO chat_turns
       (id, session_id, workspace_id, account_id, run_id, role, content, citation_required, citation_status, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)`
    )
    .bind(
      id,
      input.sessionId,
      input.workspaceId,
      input.accountId,
      input.runId,
      input.role,
      input.content,
      input.citationRequired ? 1 : 0,
      input.citationStatus
    )
    .run();
  return id;
}

async function appendRunEvent(
  env: Env,
  input: {
    sessionId: string;
    workspaceId: string;
    accountId: string;
    runId: string;
    turnId?: string;
    eventType: string;
    payload: JsonRecord;
  }
): Promise<{ id: string; cursor: number }> {
  const eventId = crypto.randomUUID();
  const insert = await env.SKY_DB
    .prepare(
      `INSERT INTO run_events
       (id, session_id, workspace_id, account_id, run_id, turn_id, event_type, payload_json, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)`
    )
    .bind(
      eventId,
      input.sessionId,
      input.workspaceId,
      input.accountId,
      input.runId,
      input.turnId || null,
      input.eventType,
      JSON.stringify(input.payload)
    )
    .run();

  await env.SKY_DB
    .prepare(
      `UPDATE chat_sessions
       SET last_event_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
       WHERE id = ?`
    )
    .bind(input.sessionId)
    .run();
  return { id: eventId, cursor: Number(insert.meta?.last_row_id || 0) };
}

async function appendActionEvent(
  env: Env,
  input: {
    actionId: string;
    workspaceId: string;
    accountId: string;
    eventType: 'proposed' | 'approved' | 'rejected' | 'executed';
    actor: string | null;
    payload: JsonRecord;
  }
): Promise<void> {
  await env.SKY_DB
    .prepare(
      `INSERT INTO action_events
       (id, action_id, workspace_id, account_id, event_type, actor, payload_json, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)`
    )
    .bind(
      crypto.randomUUID(),
      input.actionId,
      input.workspaceId,
      input.accountId,
      input.eventType,
      input.actor,
      JSON.stringify(input.payload || {})
    )
    .run();
}

async function insertRunSearchAudit(
  env: Env,
  input: {
    sessionId: string;
    runId: string;
    workspaceId: string;
    accountId: string;
    intent: QueryIntent;
    query: string;
    citationStatus: 'sufficient' | 'insufficient';
    citationsCount: number;
    searched: JsonRecord;
  }
): Promise<void> {
  await env.SKY_DB
    .prepare(
      `INSERT INTO run_search_audits
       (id, session_id, run_id, workspace_id, account_id, intent, query_text, citation_required, citation_status, citations_count, searched_json, validator_version, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, 'v1', CURRENT_TIMESTAMP)`
    )
    .bind(
      crypto.randomUUID(),
      input.sessionId,
      input.runId,
      input.workspaceId,
      input.accountId,
      input.intent,
      input.query,
      input.citationStatus,
      Math.max(0, Math.trunc(input.citationsCount)),
      JSON.stringify(input.searched || {})
    )
    .run();
}

async function insertCitations(
  env: Env,
  input: {
    sessionId: string;
    workspaceId: string;
    accountId: string;
    turnId: string;
    citations: Citation[];
  }
): Promise<void> {
  for (const citation of input.citations) {
    await env.SKY_DB
      .prepare(
        `INSERT INTO chat_citations
         (id, turn_id, session_id, workspace_id, account_id, message_id, message_date, sender, subject, score, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)`
      )
      .bind(
        crypto.randomUUID(),
        input.turnId,
        input.sessionId,
        input.workspaceId,
        input.accountId,
        citation.messageId,
        citation.date,
        citation.from,
        citation.subject,
        citation.score
      )
      .run();
  }
}

async function queryCitations(env: Env, workspaceId: string, accountId: string, query: string): Promise<Citation[]> {
  // Semantic-first retrieval for natural language queries.
  const semanticHits = await performSemanticSearch(env, workspaceId, accountId, query, 6, {
    workspaceId,
    accountId,
    operation: 'chat_find_email_retrieval',
    endpoint: '/chat/query'
  });
  const seen = new Set<string>();
  const semanticCitations: Citation[] = [];
  for (const hit of semanticHits) {
    if (Number(hit.score || 0) < MIN_SEMANTIC_CITATION_SCORE) continue;
    if (seen.has(hit.message_id)) continue;
    seen.add(hit.message_id);
    semanticCitations.push({
      messageId: hit.message_id,
      date: hit.date,
      from: hit.from || 'unknown',
      subject: hit.subject || '(no subject)',
      score: hit.score
    });
  }
  if (semanticCitations.length > 0) return semanticCitations;

  // SQL LIKE fallback for structured/exact lookup misses.
  const accountEmail = await resolveAccountEmail(env, workspaceId, accountId);
  if (!accountEmail) return [];

  const like = `%${query.replace(/[%_]/g, ' ').trim()}%`;
  const rows = await env.SKY_DB
    .prepare(
      `SELECT id, sent_at, subject, snippet,
              COALESCE(
                json_extract(from_json, '$[0].email'),
                json_extract(from_json, '$[0].address'),
                ''
              ) AS sender
       FROM email_messages
       WHERE workspace_id = ?
         AND account_email = ?
         AND (subject LIKE ? OR snippet LIKE ?)
       ORDER BY datetime(COALESCE(sent_at, created_at)) DESC
       LIMIT 6`
    )
    .bind(workspaceId, accountEmail, like, like)
    .all<{ id: string; sent_at: string | null; subject: string | null; snippet: string | null; sender: string | null }>();

  return (rows.results || []).map((row, idx) => ({
    messageId: row.id,
    date: row.sent_at,
    from: row.sender || 'unknown',
    subject: row.subject || '(no subject)',
    score: Math.max(0, 1 - idx * 0.1)
  }));
}

async function resolveAccountEmail(env: Env, workspaceId: string, accountId: string): Promise<string | null> {
  if (accountId.includes('@')) return accountId.toLowerCase();

  const row = await env.SKY_DB
    .prepare(`SELECT email, identifier FROM connected_accounts WHERE workspace_id = ? AND id = ? LIMIT 1`)
    .bind(workspaceId, accountId)
    .first<{ email: string | null; identifier: string | null }>();
  const candidate = row?.email || row?.identifier || null;
  return candidate ? candidate.toLowerCase() : null;
}

function buildCitationEnforcedAnswer(
  query: string,
  citations: Citation[]
): { answer: string; citationStatus: 'sufficient' | 'insufficient'; searched: JsonRecord } {
  const searched = {
    query,
    filters: ['workspace_id', 'account_id', 'subject/snippet like match'],
    maxResults: 6
  };

  if (citations.length === 0) {
    return {
      answer:
        'Insufficient sources for a factual answer. I searched indexed email subject/snippet for your query and did not find high-confidence matches.',
      citationStatus: 'insufficient',
      searched
    };
  }

  const top = citations.slice(0, 3);
  const lines = top.map((c, i) => `${i + 1}. ${c.subject} (${c.from}, ${c.date || 'unknown date'})`);
  return {
    answer: `Found relevant sources for: "${query}". Top references:\n${lines.join('\n')}`,
    citationStatus: 'sufficient',
    searched
  };
}

function truncateText(text: string, max: number): string {
  const normalized = text.replace(/\s+/g, ' ').trim();
  if (normalized.length <= max) return normalized;
  return `${normalized.slice(0, max - 3)}...`;
}

function toDateOnly(d: Date): string {
  return d.toISOString().slice(0, 10);
}

function numberOr(input: unknown): number | null {
  if (typeof input === 'number' && Number.isFinite(input)) return input;
  if (typeof input === 'string' && input.trim()) {
    const n = Number(input);
    if (Number.isFinite(n)) return n;
  }
  return null;
}

function arrayOr(input: unknown): unknown[] | null {
  return Array.isArray(input) ? input : null;
}

async function authorizeHttpRequest(
  request: Request,
  env: Env
): Promise<{ ok: true; principal: AuthPrincipal } | { ok: false; response: Response }> {
  const apiKey = extractBearerToken(request);
  if (env.WORKER_API_KEY && apiKey === env.WORKER_API_KEY && env.ALLOW_API_KEY_BYPASS === 'true') {
    return { ok: true, principal: { type: 'service', subject: 'service:worker_api_key', email: null } };
  }

  if (env.ACCESS_AUTH_ENABLED !== 'true') {
    if (env.WORKER_API_KEY) {
      return { ok: false, response: json({ ok: false, error: 'unauthorized' }, 401) };
    }
    return { ok: true, principal: { type: 'anonymous', subject: 'anonymous', email: null } };
  }

  const jwt = request.headers.get('cf-access-jwt-assertion') || extractBearerToken(request);
  if (!jwt) {
    return { ok: false, response: json({ ok: false, error: 'missing_access_jwt' }, 401) };
  }

  try {
    const claims = await verifyAccessJwtClaims(jwt, env);
    const principal: AccessPrincipal = principalFromAccessClaims(claims);
    return {
      ok: true,
      principal
    };
  } catch (error) {
    return {
      ok: false,
      response: json({ ok: false, error: 'invalid_access_jwt', detail: error instanceof Error ? error.message : 'invalid' }, 401)
    };
  }
}

async function assertPermission(
  env: Env,
  principal: AuthPrincipal,
  workspaceId: string,
  accountId: string
): Promise<{ ok: true } | { ok: false; response: Response }> {
  if (principal.type === 'service' || principal.type === 'anonymous') return { ok: true };

  const row = await env.SKY_DB
    .prepare(
      `SELECT id
       FROM access_subject_permissions
       WHERE subject = ?
         AND workspace_id = ?
         AND status = 'active'
         AND (account_id = ? OR account_id = '*')
       LIMIT 1`
    )
    .bind(principal.subject, workspaceId, accountId)
    .first<{ id: string }>();

  if (!row) {
    return { ok: false, response: json({ ok: false, error: 'forbidden' }, 403) };
  }

  return { ok: true };
}

async function listPermissions(
  env: Env,
  principal: AuthPrincipal,
  workspaceId?: string
): Promise<Array<{ workspaceId: string; accountId: string; role: string; status: string }>> {
  if (principal.type !== 'access') return [];

  const rows = workspaceId
    ? await env.SKY_DB
        .prepare(
          `SELECT workspace_id, account_id, role, status
           FROM access_subject_permissions
           WHERE subject = ?
             AND workspace_id = ?
           ORDER BY workspace_id, account_id`
        )
        .bind(principal.subject, workspaceId)
        .all<{ workspace_id: string; account_id: string; role: string; status: string }>()
    : await env.SKY_DB
        .prepare(
          `SELECT workspace_id, account_id, role, status
           FROM access_subject_permissions
           WHERE subject = ?
           ORDER BY workspace_id, account_id`
        )
        .bind(principal.subject)
        .all<{ workspace_id: string; account_id: string; role: string; status: string }>();

  return (rows.results || []).map((r) => ({
    workspaceId: r.workspace_id,
    accountId: r.account_id,
    role: r.role,
    status: r.status
  }));
}

async function recordUsageEvent(env: Env, entry: UsageEntry & { workspaceId?: string; accountId?: string; runId?: string }): Promise<void> {
  try {
    const id = crypto.randomUUID();
    await env.SKY_DB
      .prepare(
        `INSERT INTO model_usage_events
           (id, workspace_id, account_id, run_id, provider, model, operation, endpoint, request_units, response_units, estimated_cost_usd, status, error_code, metadata_json, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)`
      )
      .bind(
        id,
        entry.workspaceId || 'default',
        entry.accountId || null,
        entry.runId || null,
        entry.provider,
        entry.model,
        entry.operation,
        entry.endpoint || null,
        entry.requestUnits ?? null,
        entry.responseUnits ?? null,
        entry.estimatedCostUsd ?? null,
        entry.status || 'ok',
        entry.errorCode || null,
        entry.metadata ? JSON.stringify(entry.metadata) : null
      )
      .run();
  } catch {
    // usage telemetry must never break primary request paths
  }
}

function estimateTextUnits(text: string): number {
  return Math.max(1, Math.ceil(text.length / 4));
}

function estimateUsageCostUsd(
  provider: string,
  model: string,
  requestUnits: number,
  responseUnits: number,
  env: Env
): number | null {
  const pricing = getModelPricing(provider, model, env);
  if (!pricing) return null;
  const input = (Math.max(0, requestUnits) / 1_000_000) * pricing.inputPer1m;
  const output = (Math.max(0, responseUnits) / 1_000_000) * pricing.outputPer1m;
  return Number((input + output).toFixed(8));
}

function getModelPricing(
  provider: string,
  model: string,
  env: Env
): { inputPer1m: number; outputPer1m: number } | null {
  const p = provider.toLowerCase();
  const m = model.toLowerCase();
  if (p === 'openai') {
    if (m === 'text-embedding-3-small') return { inputPer1m: 0.02, outputPer1m: 0 };
    if (m === 'gpt-4o-mini') return { inputPer1m: 0.15, outputPer1m: 0.6 };
    if (m === 'gpt-4o') return { inputPer1m: 2.5, outputPer1m: 10.0 };
    return null;
  }

  if (p === 'workers_ai') {
    if (m === '@cf/meta/llama-3.3-70b-instruct-fp8-fast') return { inputPer1m: 0.29, outputPer1m: 2.25 };
    const inCost = Number(env.WORKERS_AI_INPUT_COST_PER_1M || '');
    const outCost = Number(env.WORKERS_AI_OUTPUT_COST_PER_1M || '');
    if (Number.isFinite(inCost) && Number.isFinite(outCost) && (inCost > 0 || outCost > 0)) {
      return { inputPer1m: Math.max(0, inCost), outputPer1m: Math.max(0, outCost) };
    }
    return null;
  }

  return null;
}

function stringOr(input: unknown): string | null {
  return typeof input === 'string' && input.trim() ? input.trim() : null;
}

function objectOr(input: unknown): JsonRecord | null {
  if (input && typeof input === 'object' && !Array.isArray(input)) {
    return input as JsonRecord;
  }
  return null;
}

function minutesSince(isoDateTime: string | null): number | null {
  if (!isoDateTime) return null;
  const parsed = Date.parse(isoDateTime.endsWith('Z') ? isoDateTime : `${isoDateTime}Z`);
  if (!Number.isFinite(parsed)) return null;
  return Number(Math.max(0, (Date.now() - parsed) / 60000).toFixed(2));
}

function getOpenAiQuotaCooldownMinutes(env: Env): number {
  const raw = Number(env.OPENAI_QUOTA_COOLDOWN_MINUTES || DEFAULT_OPENAI_QUOTA_COOLDOWN_MINUTES);
  if (!Number.isFinite(raw) || raw <= 0) return DEFAULT_OPENAI_QUOTA_COOLDOWN_MINUTES;
  return Math.min(24 * 60, Math.trunc(raw));
}

function getOpenAiRateLimitCooldownMinutes(env: Env): number {
  const raw = Number(env.OPENAI_RATE_LIMIT_COOLDOWN_MINUTES || DEFAULT_OPENAI_RATE_LIMIT_COOLDOWN_MINUTES);
  if (!Number.isFinite(raw) || raw <= 0) return DEFAULT_OPENAI_RATE_LIMIT_COOLDOWN_MINUTES;
  return Math.min(60, Math.trunc(raw));
}

function classifyGatewayError(
  responseStatus: number,
  responseText: string
): {
  classificationCode: string;
  providerErrorCode: string | null;
  disableReason: 'insufficient_quota' | 'rate_limited' | null;
} {
  const lower = responseText.toLowerCase();
  const providerErrorCode = extractProviderErrorCode('openai', responseText);
  if (lower.includes('insufficient_quota') || lower.includes('exceeded your current quota')) {
    return { classificationCode: 'insufficient_quota', providerErrorCode, disableReason: 'insufficient_quota' };
  }
  if (responseStatus === 401 || lower.includes('invalid_api_key') || lower.includes('unauthorized')) {
    return { classificationCode: 'unauthorized', providerErrorCode, disableReason: null };
  }
  if (responseStatus === 429 || lower.includes('rate limit')) {
    return { classificationCode: 'rate_limited', providerErrorCode, disableReason: 'rate_limited' };
  }
  return { classificationCode: `http_${responseStatus}`, providerErrorCode, disableReason: null };
}

function shouldFallbackToWorkersAi(errorMessage: string): boolean {
  const msg = errorMessage.toLowerCase();
  return (
    msg.includes('429') ||
    msg.includes('401') ||
    msg.includes('quota') ||
    msg.includes('insufficient_quota') ||
    msg.includes('unauthorized') ||
    msg.includes('openai_provider_temporarily_disabled')
  );
}

function workersAiGatewayOptions(env: Env): Record<string, unknown> | undefined {
  if (!env.AIG_GATEWAY_ID) return undefined;
  return { gateway: { id: env.AIG_GATEWAY_ID } };
}

function hasSearchEmbeddingConfig(env: Env): boolean {
  return Boolean(env.OPENAI_API_KEY && env.AIG_ACCOUNT_ID && env.AIG_GATEWAY_ID);
}

async function embedSearchQuery(env: Env, query: string, usageContext?: UsageContext): Promise<number[]> {
  const target = parseVectorDimensions(env);
  if (hasSearchEmbeddingConfig(env)) {
    const openAiDisabled = await isProviderTemporarilyDisabled(env.SKY_DB, 'openai');
    if (openAiDisabled) {
      await recordUsageEvent(env, {
        workspaceId: usageContext?.workspaceId,
        accountId: usageContext?.accountId,
        runId: usageContext?.runId,
        provider: 'openai',
        model: env.OPENAI_EMBEDDING_MODEL || 'text-embedding-3-small',
        operation: usageContext?.operation || 'embedding_query',
        endpoint: usageContext?.endpoint || '/search',
        status: 'error',
        errorCode: 'skipped_quota_cooldown'
      });
    } else {
    try {
      return normalizeVectorDimensions(await embedQueryViaGateway(env, query, usageContext), target);
    } catch (error) {
      const msg = error instanceof Error ? error.message.toLowerCase() : String(error).toLowerCase();
      if (!env.AI || !shouldFallbackToWorkersAi(msg)) {
        throw error;
      }
    }
    }
  }
  if (!env.AI) throw new Error('search_embedding_not_configured');
  return normalizeVectorDimensions(await embedQueryViaWorkersAi(env, query, usageContext), target);
}

async function embedQueryViaGateway(env: Env, query: string, usageContext?: UsageContext): Promise<number[]> {
  const gatewayUrl = `https://gateway.ai.cloudflare.com/v1/${env.AIG_ACCOUNT_ID}/${env.AIG_GATEWAY_ID}/openai/v1/embeddings`;
  const headers: Record<string, string> = {
    'content-type': 'application/json',
    authorization: `Bearer ${env.OPENAI_API_KEY as string}`
  };
  if (env.CF_AIG_AUTH_TOKEN) headers['cf-aig-authorization'] = `Bearer ${env.CF_AIG_AUTH_TOKEN}`;

  const response = await fetch(gatewayUrl, {
    method: 'POST',
    headers,
    body: JSON.stringify({
      model: env.OPENAI_EMBEDDING_MODEL || 'text-embedding-3-small',
      input: query
    })
  });
  if (!response.ok) {
    const text = await response.text();
    const gatewayError = classifyGatewayError(response.status, text);
    await recordUsageEvent(env, {
      workspaceId: usageContext?.workspaceId,
      accountId: usageContext?.accountId,
      runId: usageContext?.runId,
      provider: 'openai',
      model: env.OPENAI_EMBEDDING_MODEL || 'text-embedding-3-small',
      operation: usageContext?.operation || 'embedding_query',
      endpoint: usageContext?.endpoint || '/search',
      status: 'error',
      errorCode: gatewayError.providerErrorCode || gatewayError.classificationCode,
      metadata: { preview: text.slice(0, 200) }
    });
    if (gatewayError.disableReason) {
      await disableProviderTemporarily(env.SKY_DB, 'openai', {
        minutes:
          gatewayError.disableReason === 'insufficient_quota'
            ? getOpenAiQuotaCooldownMinutes(env)
            : getOpenAiRateLimitCooldownMinutes(env),
        classificationCode: gatewayError.classificationCode,
        providerErrorCode: gatewayError.providerErrorCode,
        lastError: text.slice(0, 1000)
      });
    }
    throw new Error(`search_embedding_failed_${response.status}:${text.slice(0, 300)}`);
  }
  const body = (await response.json()) as {
    data?: Array<{ embedding?: number[] }>;
    usage?: { prompt_tokens?: number; total_tokens?: number };
  };
  const vector = body.data?.[0]?.embedding || [];
  if (!Array.isArray(vector) || vector.length === 0) throw new Error('search_embedding_invalid_response');
  const requestUnits = Number(body.usage?.prompt_tokens ?? body.usage?.total_tokens ?? 0);
  await recordUsageEvent(env, {
    workspaceId: usageContext?.workspaceId,
    accountId: usageContext?.accountId,
    runId: usageContext?.runId,
    provider: 'openai',
    model: env.OPENAI_EMBEDDING_MODEL || 'text-embedding-3-small',
    operation: usageContext?.operation || 'embedding_query',
    endpoint: usageContext?.endpoint || '/search',
    requestUnits,
    responseUnits: 0,
    estimatedCostUsd: estimateUsageCostUsd('openai', env.OPENAI_EMBEDDING_MODEL || 'text-embedding-3-small', requestUnits, 0, env),
    status: 'ok'
  });
  await markProviderHealthy(env.SKY_DB, 'openai');
  return vector;
}

async function embedQueryViaWorkersAi(env: Env, query: string, usageContext?: UsageContext): Promise<number[]> {
  const model = env.WORKERS_AI_EMBEDDING_MODEL || '@cf/baai/bge-base-en-v1.5';
  const result = (await env.AI!.run(model, { text: [query] }, workersAiGatewayOptions(env))) as {
    data?: number[] | number[][];
    shape?: number[];
  };
  const approxUnits = estimateTextUnits(query);
  await recordUsageEvent(env, {
    workspaceId: usageContext?.workspaceId,
    accountId: usageContext?.accountId,
    runId: usageContext?.runId,
    provider: 'workers_ai',
    model,
    operation: usageContext?.operation || 'embedding_query',
    endpoint: usageContext?.endpoint || '/search',
    requestUnits: approxUnits,
    responseUnits: 0,
    estimatedCostUsd: estimateUsageCostUsd('workers_ai', model, approxUnits, 0, env),
    status: 'ok'
  });

  if (Array.isArray(result?.shape) && result.shape.length === 2 && Array.isArray(result.data) && typeof result.data[0] === 'number') {
    const dims = Number(result.shape[1] || 0);
    const flat = result.data as number[];
    if (dims > 0 && flat.length >= dims) return flat.slice(0, dims);
  }
  if (Array.isArray(result?.data) && Array.isArray(result.data[0])) {
    return (result.data as number[][])[0] || [];
  }
  throw new Error('workers_ai_search_embedding_invalid_response');
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

async function performSemanticSearch(
  env: Env,
  workspaceId: string,
  accountId: string,
  query: string,
  k: number,
  usageContext?: UsageContext
): Promise<SearchResult[]> {
  const queryVector = await embedSearchQuery(env, query, usageContext);
  const vectorRes = await env.SKY_VECTORIZE.query(queryVector, { topK: k });
  const matches = vectorRes.matches || [];
  const vectorIds = matches.map((m) => m.id).filter(Boolean);
  if (vectorIds.length === 0) return [];

  const placeholders = vectorIds.map(() => '?').join(',');
  const rows = await env.SKY_DB
    .prepare(
      `SELECT
          mc.vector_id,
          json_extract(mc.metadata_json, '$.messageId') AS message_id,
          json_extract(mc.metadata_json, '$.threadId') AS thread_id,
          em.sent_at AS sent_at,
          COALESCE(
            json_extract(em.from_json, '$[0].email'),
            json_extract(em.from_json, '$[0].address'),
            ''
          ) AS sender,
          em.subject AS subject,
          mc.chunk_text AS excerpt
       FROM memory_chunks mc
       JOIN email_messages em
         ON em.id = json_extract(mc.metadata_json, '$.messageId')
        AND em.workspace_id = mc.workspace_id
       WHERE mc.workspace_id = ?
         AND mc.account_id = ?
         AND mc.vector_id IN (${placeholders})
         AND NOT (
           lower(mc.chunk_text) LIKE '%return-path:%'
           OR lower(mc.chunk_text) LIKE '%received:%'
           OR lower(mc.chunk_text) LIKE '%mime-version:%'
           OR lower(mc.chunk_text) LIKE '%content-type:%'
           OR lower(mc.chunk_text) LIKE '%content-transfer-encoding:%'
         )
       LIMIT ?`
    )
    .bind(workspaceId, accountId, ...vectorIds, k * 3)
    .all<{
      vector_id: string;
      message_id: string | null;
      thread_id: string | null;
      sent_at: string | null;
      sender: string | null;
      subject: string | null;
      excerpt: string | null;
    }>();

  const byVectorId = new Map((rows.results || []).map((r) => [r.vector_id, r]));
  return matches
    .map((m) => {
      const row = byVectorId.get(m.id);
      if (!row || !row.message_id) return null;
      return {
        message_id: row.message_id,
        thread_id: row.thread_id,
        date: row.sent_at,
        from: row.sender || '',
        subject: row.subject || '(no subject)',
        excerpt: (row.excerpt || '').replace(/\s+/g, ' ').trim().slice(0, 200),
        score: Number(m.score || 0),
        chunk_id: m.id
      };
    })
    .filter((x): x is SearchResult => Boolean(x))
    .slice(0, k);
}

async function buildDailyBriefingHitSet(
  env: Env,
  workspaceId: string,
  accountId: string,
  semanticHits: SearchResult[]
): Promise<SearchResult[]> {
  const rows = await env.SKY_DB
    .prepare(
      `SELECT
         em.id AS message_id,
         em.thread_id AS thread_id,
         em.sent_at AS sent_at,
         COALESCE(
           json_extract(em.from_json, '$[0].email'),
           json_extract(em.from_json, '$[0].address'),
           ''
         ) AS sender,
         em.subject AS subject,
         em.snippet AS snippet
       FROM email_messages em
       WHERE em.workspace_id = ?
         AND em.account_id = ?
       ORDER BY datetime(COALESCE(em.sent_at, em.created_at)) DESC
       LIMIT 80`
    )
    .bind(workspaceId, accountId)
    .all<{
      message_id: string;
      thread_id: string | null;
      sent_at: string | null;
      sender: string | null;
      subject: string | null;
      snippet: string | null;
    }>();

  const synthetic: SearchResult[] = (rows.results || [])
    .map((row) => {
      const subject = row.subject || '(no subject)';
      const excerpt = (row.snippet || '').replace(/\s+/g, ' ').trim().slice(0, 200);
      const priority = computeBriefingPriorityScore(`${subject}\n${excerpt}`, row.sent_at);
      return {
        message_id: row.message_id,
        thread_id: row.thread_id,
        date: row.sent_at,
        from: row.sender || 'unknown',
        subject,
        excerpt,
        score: priority,
        chunk_id: `msg:${row.message_id}`
      };
    })
    .filter((row) => row.score >= 0.35);

  const byMessageId = new Map<string, SearchResult>();
  for (const hit of synthetic) {
    byMessageId.set(hit.message_id, hit);
  }
  for (const hit of semanticHits) {
    const briefScore = computeBriefingPriorityScore(`${hit.subject}\n${hit.excerpt}`, hit.date);
    const merged: SearchResult = {
      ...hit,
      score: Number((briefScore * 0.7 + Number(hit.score || 0) * 0.3).toFixed(6))
    };
    const existing = byMessageId.get(hit.message_id);
    if (!existing || merged.score > existing.score) {
      byMessageId.set(hit.message_id, merged);
    }
  }

  return Array.from(byMessageId.values())
    .sort((a, b) => b.score - a.score)
    .slice(0, 12);
}

function computeBriefingPriorityScore(text: string, sentAt: string | null): number {
  const lower = text.toLowerCase();
  let score = 0.1;

  const highRiskPhrases = [
    'listing removal',
    'appeal',
    'account suspended',
    'compliance',
    'legal',
    'contract breach',
    'overdue invoice',
    'payment overdue',
    'final notice'
  ];
  const mediumRiskPhrases = [
    'invoice',
    'payment',
    'additional information needed',
    'please reply',
    'can you',
    'could you',
    'needs your response',
    'question'
  ];
  const lowValuePhrases = ['newsletter', 'marketing automations', "we'd love your feedback", 'new feature', 'announcement'];

  for (const phrase of highRiskPhrases) {
    if (lower.includes(phrase)) score += 0.45;
  }
  for (const phrase of mediumRiskPhrases) {
    if (lower.includes(phrase)) score += 0.2;
  }
  for (const phrase of lowValuePhrases) {
    if (lower.includes(phrase)) score -= 0.2;
  }
  if (/\bwithin the next\s+\d+\s+days\b/.test(lower) || /\bdue\b/.test(lower) || /\boverdue\b/.test(lower)) {
    score += 0.2;
  }

  const recencyBoost = computeRecencyBoost(sentAt);
  score += recencyBoost;
  return Math.max(0, Math.min(1, Number(score.toFixed(6))));
}

function computeRecencyBoost(sentAt: string | null): number {
  if (!sentAt) return 0;
  const ts = Date.parse(sentAt);
  if (!Number.isFinite(ts)) return 0;
  const ageHours = (Date.now() - ts) / (1000 * 60 * 60);
  if (ageHours <= 24) return 0.12;
  if (ageHours <= 72) return 0.06;
  if (ageHours <= 168) return 0.03;
  return 0;
}

function computeBriefingPriorityReason(text: string): string {
  const lower = text.toLowerCase();
  if (lower.includes('listing removal') || lower.includes('appeal')) return 'account risk';
  if (lower.includes('overdue') || lower.includes('invoice') || lower.includes('payment')) return 'financial risk';
  if (lower.includes('additional information needed') || lower.includes('please reply') || lower.includes('question')) return 'requires response';
  if (lower.includes('marketing automations') || lower.includes('announcement')) return 'informational notice';
  return 'general priority';
}

function buildDeterministicDailyBriefing(hits: SearchResult[]): { answer: string; citations: Citation[] } {
  const ranked = hits
    .slice()
    .sort((a, b) => b.score - a.score)
    .filter((h) => h.score >= 0.4)
    .slice(0, 5);
  const selected = ranked.length > 0 ? ranked.slice(0, 3) : hits.slice(0, 3);
  const citations: Citation[] = selected.map((h) => ({
    messageId: h.message_id,
    date: h.date,
    from: h.from || 'unknown',
    subject: h.subject || '(no subject)',
    score: h.score
  }));
  if (selected.length === 0) {
    return {
      answer: 'No priority items were found for today from indexed email context. Next action: review inbox for new urgent requests.',
      citations: []
    };
  }

  const lines = selected.map((hit, index) => {
    const priority = classifyBriefingPriority(hit.score);
    const requested = extractRequestedActionFromText(`${hit.subject}\n${hit.excerpt}`);
    return `${index + 1}. [${priority}] ${hit.subject} (${hit.from || 'unknown'}) - ${requested}`;
  });
  const nextAction = extractRequestedActionFromText(`${selected[0].subject}\n${selected[0].excerpt}`);
  const answer = [
    'Top priorities today:',
    ...lines,
    `Next action: ${nextAction}`
  ].join('\n');
  return { answer, citations };
}

function classifyBriefingPriority(score: number): 'Critical' | 'High' | 'Medium' {
  if (score >= 0.8) return 'Critical';
  if (score >= 0.6) return 'High';
  return 'Medium';
}

function extractRequestedActionFromText(text: string): string {
  const normalized = text.replace(/\s+/g, ' ').trim();
  const lower = normalized.toLowerCase();
  if (lower.includes('additional information needed') || lower.includes('listing removal appeal')) {
    return 'Provide the requested additional appeal details within 7 days.';
  }
  if (lower.includes('overdue invoice')) {
    return 'Resolve the overdue invoice immediately.';
  }
  if (lower.includes('invoice')) {
    return 'Review and pay the invoice if approved.';
  }
  if (lower.includes('can you') || lower.includes('could you') || lower.includes('?')) {
    const q = normalized.match(/([^.!?]*\?)/);
    if (q?.[1]) return q[1].trim();
    return 'Respond to the sender with the requested details.';
  }
  if (lower.includes('due ') || lower.includes('deadline')) {
    return 'Complete the requested task before the stated deadline.';
  }
  return 'Review and respond with a concrete decision.';
}

async function loadAgentProfile(
  env: Env,
  agentId: string
): Promise<{ id: string; name: string; purpose: string; business_context: string; owner_goals: string[] } | null> {
  const row = await env.SKY_DB
    .prepare(
      `SELECT id, name, purpose, business_context, owner_goals_json
       FROM agents
       WHERE id = ?
       LIMIT 1`
    )
    .bind(agentId)
    .first<{ id: string; name: string; purpose: string; business_context: string; owner_goals_json: string | null }>();
  if (!row) return null;
  let goals: string[] = [];
  try {
    const parsed = JSON.parse(row.owner_goals_json || '[]');
    if (Array.isArray(parsed)) goals = parsed.map((x) => String(x));
  } catch {
    goals = [];
  }
  return { ...row, owner_goals: goals };
}

async function callOpenAiChatViaGateway(
  env: Env,
  messages: Array<{ role: 'system' | 'user' | 'assistant'; content: string }>,
  responseFormat?: { type: 'json_object' },
  usageContext?: UsageContext
): Promise<string> {
  if (!env.OPENAI_API_KEY || !env.AIG_ACCOUNT_ID || !env.AIG_GATEWAY_ID) {
    throw new Error('chat_not_configured');
  }
  if (await isProviderTemporarilyDisabled(env.SKY_DB, 'openai')) {
    await recordUsageEvent(env, {
      workspaceId: usageContext?.workspaceId,
      accountId: usageContext?.accountId,
      runId: usageContext?.runId,
      provider: 'openai',
      model: env.OPENAI_MODEL || 'gpt-4o-mini',
      operation: usageContext?.operation || 'chat_completion',
      endpoint: usageContext?.endpoint || '/chat',
      status: 'error',
      errorCode: 'skipped_quota_cooldown'
    });
    if (env.AI) {
      return await callWorkersAiChat(env, messages, responseFormat, usageContext);
    }
    throw new Error('openai_provider_temporarily_disabled');
  }

  const gatewayUrl = `https://gateway.ai.cloudflare.com/v1/${env.AIG_ACCOUNT_ID}/${env.AIG_GATEWAY_ID}/openai/v1/chat/completions`;
  const headers: Record<string, string> = {
    'content-type': 'application/json',
    authorization: `Bearer ${env.OPENAI_API_KEY}`
  };
  if (env.CF_AIG_AUTH_TOKEN) headers['cf-aig-authorization'] = `Bearer ${env.CF_AIG_AUTH_TOKEN}`;

  const response = await fetch(gatewayUrl, {
    method: 'POST',
    headers,
    body: JSON.stringify({
      model: env.OPENAI_MODEL || 'gpt-4o-mini',
      messages,
      temperature: responseFormat?.type === 'json_object' ? 0 : 0.2,
      ...(responseFormat ? { response_format: responseFormat } : {})
    })
  });
  if (!response.ok) {
    const text = await response.text();
    const gatewayError = classifyGatewayError(response.status, text);
    await recordUsageEvent(env, {
      workspaceId: usageContext?.workspaceId,
      accountId: usageContext?.accountId,
      runId: usageContext?.runId,
      provider: 'openai',
      model: env.OPENAI_MODEL || 'gpt-4o-mini',
      operation: usageContext?.operation || 'chat_completion',
      endpoint: usageContext?.endpoint || '/chat',
      status: 'error',
      errorCode: gatewayError.providerErrorCode || gatewayError.classificationCode,
      metadata: { preview: text.slice(0, 200) }
    });
    if (gatewayError.disableReason) {
      await disableProviderTemporarily(env.SKY_DB, 'openai', {
        minutes:
          gatewayError.disableReason === 'insufficient_quota'
            ? getOpenAiQuotaCooldownMinutes(env)
            : getOpenAiRateLimitCooldownMinutes(env),
        classificationCode: gatewayError.classificationCode,
        providerErrorCode: gatewayError.providerErrorCode,
        lastError: text.slice(0, 1000)
      });
    }
    const msg = `chat_gateway_failed_${response.status}:${text.slice(0, 500)}`;
    if (env.AI && response.status >= 400) {
      try {
        return await callWorkersAiChat(env, messages, responseFormat, usageContext);
      } catch {
        throw new Error(msg);
      }
    }
    throw new Error(msg);
  }
  const body = (await response.json()) as {
    choices?: Array<{ message?: { content?: string } }>;
    usage?: { prompt_tokens?: number; completion_tokens?: number };
  };
  const text = body.choices?.[0]?.message?.content?.trim() || '';
  if (!text) throw new Error('chat_empty_response');
  const reqUnits = Number(body.usage?.prompt_tokens || 0);
  const respUnits = Number(body.usage?.completion_tokens || 0);
  await recordUsageEvent(env, {
    workspaceId: usageContext?.workspaceId,
    accountId: usageContext?.accountId,
    runId: usageContext?.runId,
    provider: 'openai',
    model: env.OPENAI_MODEL || 'gpt-4o-mini',
    operation: usageContext?.operation || 'chat_completion',
    endpoint: usageContext?.endpoint || '/chat',
    requestUnits: reqUnits,
    responseUnits: respUnits,
    estimatedCostUsd: estimateUsageCostUsd('openai', env.OPENAI_MODEL || 'gpt-4o-mini', reqUnits, respUnits, env),
    status: 'ok'
  });
  await markProviderHealthy(env.SKY_DB, 'openai');
  return text;
}

async function callWorkersAiChat(
  env: Env,
  messages: Array<{ role: 'system' | 'user' | 'assistant'; content: string }>,
  responseFormat?: { type: 'json_object' },
  usageContext?: UsageContext
): Promise<string> {
  if (!env.AI) throw new Error('workers_ai_chat_not_bound');
  const model = env.WORKERS_AI_CHAT_MODEL || '@cf/meta/llama-3.3-70b-instruct-fp8-fast';
  const modelMessages =
    responseFormat?.type === 'json_object'
      ? [
          ...messages,
          {
            role: 'system' as const,
            content: 'Return valid JSON only. Do not include any text before or after the JSON object.'
          }
        ]
      : messages;
  const usagePrompt = modelMessages.map((m) => `${m.role.toUpperCase()}: ${m.content}`).join('\n\n');
  const out = (await env.AI.run(model, {
    messages: modelMessages,
    max_tokens: 1500,
    ...(responseFormat ? { response_format: responseFormat } : {})
  }, workersAiGatewayOptions(env))) as { response?: string; result?: { response?: string } };
  const text = out.response || out.result?.response || '';
  if (!text.trim()) throw new Error('workers_ai_chat_empty_response');
  const reqUnits = estimateTextUnits(usagePrompt);
  const respUnits = estimateTextUnits(text);
  await recordUsageEvent(env, {
    workspaceId: usageContext?.workspaceId,
    accountId: usageContext?.accountId,
    runId: usageContext?.runId,
    provider: 'workers_ai',
    model,
    operation: usageContext?.operation || 'chat_completion',
    endpoint: usageContext?.endpoint || '/chat',
    requestUnits: reqUnits,
    responseUnits: respUnits,
    estimatedCostUsd: estimateUsageCostUsd('workers_ai', model, reqUnits, respUnits, env),
    status: 'ok'
  });
  return text.trim();
}

type ExtractedProposal = {
  action_type?: string;
  title?: string;
  recommendation?: string;
  reply_body?: string;
  risk_level?: string;
  citations?: string[];
};

async function executeUnifiedFindEmailQuery(
  env: Env,
  input: {
    workspaceId: string;
    accountId: string;
    query: string;
    runId: string;
    includeProposals?: boolean;
  }
): Promise<{
  answer: string;
  citations: Citation[];
  searched: JsonRecord;
  proposals: Array<{ id: string; type: string; title: string; draft_payload_json: JsonRecord; risk_level: string }>;
}> {
  const includeProposals = input.includeProposals === true;
  const isDailyBriefing = isDailyBriefingQuery(input.query);
  let hits = await performSemanticSearch(env, input.workspaceId, input.accountId, input.query, 10, {
    workspaceId: input.workspaceId,
    accountId: input.accountId,
    runId: input.runId,
    operation: 'chat_query_unified_retrieval',
    endpoint: '/chat/query'
  });
  if (isDailyBriefing) {
    hits = await buildDailyBriefingHitSet(env, input.workspaceId, input.accountId, hits);
  }
  if (hits.length === 0) {
    return {
      answer: 'Insufficient sources for a factual answer. I searched indexed email content and did not find high-confidence matches.',
      citations: [],
      searched: { intent: 'find_email', mode: isDailyBriefing ? 'daily_briefing' : 'default', strategy: 'vector_search+llm_unified', k: 10, hits: 0 },
      proposals: []
    };
  }
  if (isDailyBriefing) {
    const briefing = buildDeterministicDailyBriefing(hits);
    return {
      answer: briefing.answer,
      citations: briefing.citations,
      searched: {
        intent: 'find_email',
        mode: 'daily_briefing',
        strategy: 'daily_priority_heuristic',
        k: 10,
        hits: hits.length
      },
      proposals: []
    };
  }

  const ownerRow = await env.SKY_DB
    .prepare(
      `SELECT display_name, label, email
       FROM connected_accounts
       WHERE workspace_id = ? AND id = ?
       LIMIT 1`
    )
    .bind(input.workspaceId, input.accountId)
    .first<{ display_name: string | null; label: string | null; email: string | null }>();
  const accountOwnerName = deriveAccountOwnerName(ownerRow);

  const fullChunkByVectorId = await loadChunkTextByVectorIds(
    env,
    input.workspaceId,
    input.accountId,
    hits.map((h) => h.chunk_id)
  );
  const context = hits.slice(0, 8).map((h) => ({
    message_id: h.message_id,
    thread_id: h.thread_id,
    date: h.date,
    from: h.from,
    subject: h.subject,
    excerpt: h.excerpt,
    body_text: truncateText(fullChunkByVectorId.get(h.chunk_id) || h.excerpt || '', 3000),
    priority_score: h.score,
    priority_reason: computeBriefingPriorityReason(`${h.subject}\n${h.excerpt}`)
  }));

  const raw = await callOpenAiChatViaGateway(
    env,
    [
      {
        role: 'system',
        content:
          `You are Blawby, an AI chief-of-staff. Use the provided email context to answer the user naturally and practically.

Return exactly one JSON object with this exact shape and field names:
{
  "answer": "short, useful narrative answer in plain English",
  "citation_ids": ["message_id_1"],
  "missing_info": ["specific missing detail required to complete task"],
  "next_action": "single concrete next action",
  "proposals": [
    {
      "title": "one line describing the situation",
      "recommendation": "what to do and why",
      "action_type": "what kind of action this is",
      "reply_body": "full email body if action_type involves sending a message",
      "citations": ["message_id_1"],
      "risk_level": "low | medium | high"
    }
  ]
}

Rules:
- Output must be raw JSON only with no prose before or after the JSON object.
- "answer" must directly answer the user question and sound conversational, not like metadata output.
- Keep "answer" concise and action-oriented.
- Never end your answer with a question. State what you found, what needs to happen, and what you have prepared. The user will decide what to do next.
- Use only information present in context.
- "citation_ids" must reference message_id values from context.
- "missing_info" must list concrete gaps that block a complete answer/draft.
- "next_action" must be a concrete, executable next step.
- If no valid evidence exists, set "answer" to: "insufficient sources" and use empty citation_ids/proposals.
- Only generate a proposal if you can populate a complete executable payload from the email content. If you cannot identify a specific recipient, action target, or required fields, include the item in the answer text instead of creating a proposal.
- If context says additional information is needed but does not specify the exact items, explicitly say that the exact requested items are not visible in email context and ask the user to share them from the source system page.
- If the user asks what needs attention today, what is urgent, or what to focus on: answer as a daily briefing ranked by real-world impact. State who each item involves, what they want, and why it matters. End with the single most important next action.
- If proposing a response to an email, action_type MUST be exactly "reply_email" (never "send_email").
- For every "reply_email" proposal, include at least one valid message_id in "citations" and provide a complete "reply_body".
- For reply_email proposals, reply_body must contain only greeting, body, and closing, and be signed with "${accountOwnerName}".
- Never include placeholders like [Client Name].
- Never mention attachments/documents/files unless explicitly present in context.`
      },
      {
        role: 'user',
        content: JSON.stringify({
          query: input.query,
          account_owner_name: accountOwnerName,
          context
        })
      }
    ],
    { type: 'json_object' },
    {
      workspaceId: input.workspaceId,
      accountId: input.accountId,
      runId: input.runId,
      operation: 'chat_query_unified_answer_and_proposals',
      endpoint: '/chat/query'
    }
  );
  console.log(`[chat.query] unified_response runId=${input.runId} raw=${raw.slice(0, 500)}`);

  const parsed = JSON.parse(stripJsonCodeFence(raw)) as {
    answer?: unknown;
    citation_ids?: unknown;
    missing_info?: unknown;
    next_action?: unknown;
    proposals?: unknown;
  };
  const answer = stringOr(parsed.answer);
  if (!answer) {
    throw new Error('chat_query_unified_missing_answer');
  }

  const citationIds = Array.isArray(parsed.citation_ids) ? parsed.citation_ids.map((x) => String(x)) : [];
  const byMessageId = new Map(hits.map((h) => [h.message_id, h]));
  const deduped = new Set<string>();
  const citations: Citation[] = [];
  for (const id of citationIds) {
    if (deduped.has(id)) continue;
    const hit = byMessageId.get(id);
    if (!hit) continue;
    deduped.add(id);
    citations.push({
      messageId: hit.message_id,
      date: hit.date,
      from: hit.from || 'unknown',
      subject: hit.subject || '(no subject)',
      score: hit.score
    });
    if (citations.length >= 6) break;
  }
  const missingInfo = collectMissingInfo(parsed.missing_info, context);
  const nextAction = stringOr(parsed.next_action);
  const finalAnswer = normalizeBlawbyAnswer(answer, missingInfo, nextAction);

  let proposals: Array<{ id: string; type: string; title: string; draft_payload_json: JsonRecord; risk_level: string }> = [];
  if (includeProposals) {
    const proposalsIn = Array.isArray(parsed.proposals) ? (parsed.proposals as ExtractedProposal[]) : [];
    proposals = await persistExtractedProposals(env, {
      workspaceId: input.workspaceId,
      accountId: input.accountId,
      agentId: null,
      query: input.query,
      hits,
      accountOwnerName,
      proposals: proposalsIn
    });
  }

  return {
    answer: finalAnswer,
    citations,
    searched: {
      intent: 'find_email',
      mode: isDailyBriefing ? 'daily_briefing' : 'default',
      strategy: 'vector_search+llm_unified',
      k: 10,
      hits: hits.length,
      citationIds: citationIds.slice(0, 8)
    },
    proposals
  };
}

async function persistExtractedProposals(
  env: Env,
  input: {
    workspaceId: string;
    accountId: string;
    agentId: string | null;
    query: string;
    hits: SearchResult[];
    accountOwnerName: string;
    proposals: ExtractedProposal[];
  }
): Promise<Array<{ id: string; type: string; title: string; draft_payload_json: JsonRecord; risk_level: string }>> {
  const out: Array<{ id: string; type: string; title: string; draft_payload_json: JsonRecord; risk_level: string }> = [];
  for (const p of input.proposals.slice(0, 10)) {
    const type = stringOr(p.action_type);
    if (!type) continue;
    if (type !== 'reply_email') continue;
    const title = stringOr(p.title) || 'Untitled proposal';
    const riskLevel = stringOr(p.risk_level) || 'low';
    const proposalId = crypto.randomUUID();
    const citationsRaw = Array.isArray(p.citations) ? p.citations.map((x) => String(x)) : [];
    const payload = buildReplyEmailPayload({
      hits: input.hits,
      citationIds: citationsRaw,
      generatedBody: stringOr(p.reply_body),
      accountOwnerName: input.accountOwnerName
    });
    if (!isExecutableReplyPayload(payload)) continue;
    payload.needs_draft = false;

    await env.SKY_DB
      .prepare(
        `INSERT INTO proposals
         (id, workspace_id, account_id, agent_id, type, status, draft_payload_json, required_inputs_json, risk_level, created_from_ref, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, 'proposed', ?, '{}', ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)`
      )
      .bind(
        proposalId,
        input.workspaceId,
        input.accountId,
        input.agentId,
        type,
        JSON.stringify(payload),
        riskLevel,
        `chat:${input.query.slice(0, 120)}`
      )
      .run();

    for (const citationId of citationsRaw.slice(0, 8)) {
      const hit = input.hits.find((h) => h.message_id === citationId);
      await env.SKY_DB
        .prepare(
          `INSERT INTO proposal_citations
           (id, proposal_id, message_id, thread_id, quote_text, chunk_id, created_at)
           VALUES (?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)`
        )
        .bind(
          crypto.randomUUID(),
          proposalId,
          citationId,
          hit?.thread_id || null,
          hit?.excerpt || null,
          hit?.chunk_id || null
        )
        .run();
    }

    await env.SKY_DB
      .prepare(
        `INSERT INTO approvals_audit
         (id, proposal_id, actor, action, before_json, after_json, created_at)
         VALUES (?, ?, ?, 'proposed', NULL, ?, CURRENT_TIMESTAMP)`
      )
      .bind(crypto.randomUUID(), proposalId, 'system', JSON.stringify({ type, title, riskLevel }))
      .run();

    out.push({ id: proposalId, type, title, draft_payload_json: payload, risk_level: riskLevel });
  }
  return out;
}

async function extractAndPersistProposals(
  env: Env,
  input: {
    workspaceId: string;
    accountId: string;
    agentId: string | null;
    query: string;
    answer: string;
    hits: SearchResult[];
  }
): Promise<
  Array<{ id: string; type: string; title: string; draft_payload_json: JsonRecord; risk_level: string; _source?: 'llm' | 'fallback' }>
> {
  const ownerRow = await env.SKY_DB
    .prepare(
      `SELECT display_name, label, email
       FROM connected_accounts
       WHERE workspace_id = ? AND id = ?
       LIMIT 1`
    )
    .bind(input.workspaceId, input.accountId)
    .first<{ display_name: string | null; label: string | null; email: string | null }>();
  const accountOwnerName = deriveAccountOwnerName(ownerRow);

  const fullChunkByVectorId = await loadChunkTextByVectorIds(
    env,
    input.workspaceId,
    input.accountId,
    input.hits.map((h) => h.chunk_id)
  );
  const compactContext = input.hits
    .slice(0, 8)
    .map((h) => ({
      message_id: h.message_id,
      thread_id: h.thread_id,
      date: h.date,
      from: h.from,
      recipient_name: extractContactName(h.from),
      recipient_email: extractEmailAddress(h.from),
      subject: h.subject,
      excerpt: h.excerpt,
      body_text: truncateText(fullChunkByVectorId.get(h.chunk_id) || h.excerpt || '', 3000)
    }));

  let raw = '{"proposals":[]}';
  try {
    raw = await callOpenAiChatViaGateway(
      env,
      [
        {
          role: 'system',
          content:
            `You are an expert chief-of-staff assistant. Review every email snippet in context and surface the concrete actions the account owner should take now. ALWAYS emit a reply_email proposal when the email sounds like someone is waiting for a response, asks a question, requests follow-up, or raises an open issue, even if the user did not explicitly ask for a reply.

Return exactly one JSON object with this exact shape and field names:
{
  "proposals": [
    {
      "title": "one line describing the situation",
      "recommendation": "what to do and why",
      "action_type": "what kind of action this is",
      "reply_body": "full email body if action_type involves sending a message",
      "citations": ["message_id_1"],
      "risk_level": "low | medium | high"
    }
  ]
}

Output must be raw JSON only with no prose before or after the JSON object.
If no action is needed, return {"proposals":[]}. For reply_email items, reply_body must contain ONLY greeting, body, and closing, with no headers like To or Subject. Sign every reply with the exact account owner name "${accountOwnerName}". Never output placeholder text like [Client's Name] or [Your Name]. Never reference attachments, documents, or files unless they are explicitly present in the email context.
If the user should respond to an email, action_type MUST be exactly "reply_email" (never "send_email"), citations must include the source message_id being replied to, and reply_body must be complete.
Only generate a proposal if you can populate a complete executable payload from the email content. If you cannot identify a specific recipient, action target, or required fields, include the item in the answer text instead of creating a proposal.`
        },
        {
          role: 'user',
          content: JSON.stringify({
            query: input.query,
            answer: input.answer,
            account_owner_name: accountOwnerName,
            context: compactContext
          })
        }
      ],
      { type: 'json_object' },
      {
        workspaceId: input.workspaceId,
        accountId: input.accountId,
        operation: 'proposal_extraction',
        endpoint: '/chat'
      }
    );
  } catch {
    raw = '{"proposals":[]}';
  }

  console.log(`[proposals] raw_response=${raw.slice(0, 500)}`);

  const sanitizedRaw = stripJsonCodeFence(raw);
  let proposalsIn: ExtractedProposal[] = [];
  try {
    const parsed = JSON.parse(sanitizedRaw) as unknown;
    if (parsed && typeof parsed === 'object' && Array.isArray((parsed as { proposals?: unknown[] }).proposals)) {
      proposalsIn = (parsed as { proposals: typeof proposalsIn }).proposals;
    }
  } catch {
    proposalsIn = [];
  }
  return await persistExtractedProposals(env, {
    workspaceId: input.workspaceId,
    accountId: input.accountId,
    agentId: input.agentId,
    query: input.query,
    hits: input.hits,
    accountOwnerName,
    proposals: proposalsIn
  });
}

async function loadChunkTextByVectorIds(
  env: Env,
  workspaceId: string,
  accountId: string,
  vectorIds: string[]
): Promise<Map<string, string>> {
  const ids = vectorIds.filter(Boolean);
  if (ids.length === 0) return new Map();
  const placeholders = ids.map(() => '?').join(',');
  const rows = await env.SKY_DB
    .prepare(
      `SELECT vector_id, chunk_text
       FROM memory_chunks
       WHERE workspace_id = ?
         AND account_id = ?
         AND vector_id IN (${placeholders})`
    )
    .bind(workspaceId, accountId, ...ids)
    .all<{ vector_id: string; chunk_text: string | null }>();
  return new Map((rows.results || []).map((r) => [r.vector_id, r.chunk_text || '']));
}

function isSummaryLikeDraft(text: string): boolean {
  const t = text.trim();
  if (!t) return true;
  const lower = t.toLowerCase();
  const wordCount = t.split(/\s+/).length;
  const hasGreeting = /\b(hi|hello|dear)\b/i.test(t);
  const hasSignOff = /\b(best|thanks|regards|sincerely)\b/i.test(t);
  const summaryPhrases = ['found relevant sources', 'top references', 'insufficient sources', 'i searched', 'citation'];
  const containsSummary = summaryPhrases.some((phrase) => lower.includes(phrase));
  if (wordCount < 25 && !hasGreeting) return true;
  if (containsSummary && !(hasGreeting && hasSignOff)) return true;
  return false;
}

function containsTemplatePlaceholder(text: string): boolean {
  const placeholderPatterns = [/\[[^\]]{1,120}\]/i, /{{[^}]{1,120}}/i, /\binsert\b/i, /\bplaceholder\b/i, /\btbd\b/i];
  return placeholderPatterns.some((pattern) => pattern.test(text));
}

function collectMissingInfo(rawMissingInfo: unknown, context: Array<{ body_text: string }>): string[] {
  const missing: string[] = [];
  if (Array.isArray(rawMissingInfo)) {
    for (const item of rawMissingInfo) {
      const value = stringOr(item);
      if (!value) continue;
      if (!missing.includes(value)) missing.push(value);
    }
  }

  const fullContext = context.map((c) => c.body_text.toLowerCase()).join('\n');
  const hasAdditionalNeeded = fullContext.includes('additional information needed');
  const pointsToListingIssuesPage = fullContext.includes('listing issues page');
  const hasSpecificChecklist =
    /provide (the )?following/i.test(fullContext) ||
    /required documents/i.test(fullContext) ||
    /please include/i.test(fullContext);
  if (hasAdditionalNeeded && pointsToListingIssuesPage && !hasSpecificChecklist) {
    const inferred = 'Exact requested items from the Airbnb Listing Issues page are not present in the email context.';
    if (!missing.includes(inferred)) missing.push(inferred);
  }

  return missing.slice(0, 4);
}

function normalizeBlawbyAnswer(answer: string, missingInfo: string[], nextAction: string | null): string {
  const base = answer.trim().replace(/\?+\s*$/, '.');
  if (missingInfo.length === 0 && !nextAction) return base;
  const gaps = missingInfo.length > 0 ? `Missing information: ${missingInfo.join(' ')}` : null;
  const action = nextAction ? `Next action: ${nextAction.replace(/\?+\s*$/, '.')}` : null;
  return [base, gaps, action].filter((part): part is string => Boolean(part)).join('\n');
}

function deriveAccountOwnerName(row?: { display_name: string | null; label: string | null; email: string | null }): string {
  const pick = (value?: string | null): string | null => {
    if (!value) return null;
    const trimmed = value.trim();
    return trimmed.length > 0 ? trimmed : null;
  };
  const ordered = [pick(row?.display_name), pick(row?.label), normalizeEmailLocalPart(row?.email)];
  return ordered.find((value): value is string => Boolean(value)) || 'Skyler Baird';
}

function normalizeEmailLocalPart(email?: string | null): string | null {
  if (!email) return null;
  const local = email.split('@')[0]?.trim();
  if (!local) return null;
  return local
    .split(/[._-]/)
    .map((segment) => segment.charAt(0).toUpperCase() + segment.slice(1))
    .join(' ');
}

function extractContactName(contact?: string | null): string | null {
  if (!contact) return null;
  const trimmed = contact.trim();
  if (!trimmed) return null;
  const quoted = trimmed.match(/"([^\"]+)"/);
  if (quoted) return quoted[1].trim();
  const angle = trimmed.match(/([^<]+)</);
  if (angle) return angle[1].trim();
  if (trimmed.includes('@')) {
    return normalizeEmailLocalPart(trimmed) || trimmed.split('@')[0];
  }
  return trimmed;
}

function extractEmailAddress(contact?: string | null): string | null {
  if (!contact) return null;
  const match = contact.match(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i);
  return match ? match[0].toLowerCase() : null;
}

function findAutoReplyCandidate(hits: SearchResult[]): SearchResult | null {
  for (const hit of hits) {
    if (isLikelyActionable(hit)) return hit;
  }
  return null;
}

function isLikelyActionable(hit: SearchResult): boolean {
  const combined = `${hit.subject} ${hit.excerpt}`.toLowerCase();
  const keywords = ['follow up', 'contract', 'invoice', 'please', 'could you', 'can you', 'urgent', 'question', '?', 'update', 'waiting'];
  return keywords.some((token) =>
    token === '?' ? combined.includes('?') : combined.includes(token)
  );
}

function buildReplyEmailPayload(opts: {
  hits: SearchResult[];
  citationIds: string[];
  generatedBody?: string | null;
  accountOwnerName: string;
}): JsonRecord {
  const source = findPrimaryHit(opts.hits, opts.citationIds);
  const to = extractEmailAddress(source?.from) || source?.from || null;
  const subject = formatReplySubject(source?.subject);
  const body = sanitizeReplyBody(opts.generatedBody, opts.accountOwnerName);
  const payload: JsonRecord = {
    to,
    subject,
    thread_id: source?.thread_id || null,
    message_id: source?.message_id || null,
    needs_draft: !body || !to || !subject
  };
  if (body) payload.body = body;
  return payload;
}

function isExecutableReplyPayload(payload: JsonRecord): boolean {
  return Boolean(
    stringOr(payload.to) &&
      stringOr(payload.subject) &&
      stringOr(payload.message_id) &&
      stringOr(payload.body) &&
      payload.needs_draft !== true
  );
}

function findPrimaryHit(hits: SearchResult[], citationIds: string[]): SearchResult | null {
  for (const id of citationIds) {
    const found = hits.find((h) => h.message_id === id);
    if (found) return found;
  }
  return hits.length > 0 ? hits[0] : null;
}

function formatReplySubject(original?: string | null): string | null {
  if (!original) return 'Re: follow-up';
  const trimmed = original.trim();
  if (!trimmed) return 'Re: follow-up';
  return /^re:/i.test(trimmed) ? trimmed : `Re: ${trimmed}`;
}

function sanitizeReplyBody(body: string | null | undefined, ownerName: string): string | null {
  if (!body) return null;
  const trimmed = body.trim();
  if (!trimmed) return null;
  if (isSummaryLikeDraft(trimmed) || containsTemplatePlaceholder(trimmed)) return null;
  const ownerLower = ownerName.toLowerCase();
  const hasOwner = trimmed.toLowerCase().includes(ownerLower);
  const signOff = `Best,\n${ownerName}`;
  return hasOwner ? trimmed : `${trimmed.trimEnd()}\n\n${signOff}`;
}

function stripJsonCodeFence(raw: string): string {
  const trimmed = raw.trim();
  if (trimmed.startsWith('```')) {
    const withoutFence = trimmed.replace(/^```(?:json)?/i, '').replace(/```$/i, '');
    return withoutFence.trim();
  }
  return raw;
}

function json(payload: JsonRecord, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8' }
  });
}
