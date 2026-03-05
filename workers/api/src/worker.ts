interface Env {
  SKY_DB: D1Database;
  CHAT_COORDINATOR: DurableObjectNamespace;
  WORKER_API_KEY?: string;
  ENVIRONMENT?: string;
}

type JsonRecord = Record<string, unknown>;

type Citation = {
  messageId: string;
  date: string | null;
  from: string;
  subject: string;
  score: number;
};

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === 'GET' && url.pathname === '/health') {
      return json({ ok: true, service: 'sky-ai-api', env: env.ENVIRONMENT || 'unknown' });
    }

    if (request.method === 'GET' && url.pathname === '/ws/chat') {
      if (!isAuthorized(request, env)) return unauthorized();
      return routeWebSocketToCoordinator(request, env);
    }

    if (request.method === 'POST' && url.pathname === '/chat/query') {
      if (!isAuthorized(request, env)) return unauthorized();
      return runHttpChatQuery(request, env);
    }

    if (request.method === 'POST' && url.pathname === '/actions/propose') {
      if (!isAuthorized(request, env)) return unauthorized();
      return proposeAction(request, env);
    }

    if (request.method === 'POST' && url.pathname === '/actions/approve') {
      if (!isAuthorized(request, env)) return unauthorized();
      return approveAction(request, env);
    }

    return json({ ok: false, error: 'Not found' }, 404);
  }
};

export class ChatCoordinator {
  private state: DurableObjectState;
  private env: Env;
  private sockets: Set<WebSocket>;
  private sessionLocks: Map<string, string>;

  constructor(state: DurableObjectState, env: Env) {
    this.state = state;
    this.env = env;
    this.sockets = new Set();
    this.sessionLocks = new Map();
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === 'GET' && url.pathname === '/connect') {
      const upgrade = request.headers.get('Upgrade');
      if (upgrade !== 'websocket') {
        return json({ ok: false, error: 'Expected websocket upgrade' }, 426);
      }

      const pair = new WebSocketPair();
      const client = pair[0];
      const server = pair[1];
      server.accept();
      this.sockets.add(server);

      server.addEventListener('message', async (event: MessageEvent) => {
        await this.handleSocketMessage(server, event.data);
      });

      server.addEventListener('close', () => {
        this.sockets.delete(server);
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

    if (stringOr(payload.type) !== 'run.query') {
      this.send(socket, { type: 'run.failed', error: 'unsupported_message_type' });
      return;
    }

    const workspaceId = stringOr(payload.workspaceId) || 'default';
    const accountId = stringOr(payload.accountId);
    const userId = stringOr(payload.userId) || 'anonymous';
    const sessionId = stringOr(payload.sessionId) || crypto.randomUUID();
    const query = stringOr(payload.query);

    if (!accountId || !query) {
      this.send(socket, { type: 'run.failed', error: 'accountId and query are required' });
      return;
    }

    await ensureWorkspaceAndAccount(this.env, workspaceId, accountId);
    await ensureSession(this.env, { sessionId, workspaceId, accountId, userId });

    const rateOk = await this.checkRateLimit(sessionId);
    if (!rateOk) {
      this.send(socket, { type: 'run.rejected', reason: 'rate_limited', sessionId });
      return;
    }

    if (this.sessionLocks.has(sessionId)) {
      this.send(socket, { type: 'run.rejected', reason: 'session_locked', sessionId });
      return;
    }

    const runId = crypto.randomUUID();
    this.sessionLocks.set(sessionId, runId);

    try {
      await appendRunEvent(this.env, {
        sessionId,
        workspaceId,
        accountId,
        runId,
        eventType: 'run.started',
        payload: { query }
      });
      this.broadcast({ type: 'run.started', sessionId, runId });

      await this.broadcastProgress(workspaceId, accountId, sessionId, runId, 'retrieval.started');
      const citations = await queryCitations(this.env, workspaceId, accountId, query);
      await this.broadcastProgress(workspaceId, accountId, sessionId, runId, 'retrieval.completed', { hits: citations.length });

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

      const { answer, citationStatus, searched } = buildCitationEnforcedAnswer(query, citations);

      const assistantTurnId = await insertTurn(this.env, {
        sessionId,
        workspaceId,
        accountId,
        runId,
        role: 'assistant',
        content: answer,
        citationRequired: true,
        citationStatus
      });

      if (citations.length > 0) {
        await insertCitations(this.env, {
          sessionId,
          workspaceId,
          accountId,
          turnId: assistantTurnId,
          citations
        });
      }

      await appendRunEvent(this.env, {
        sessionId,
        workspaceId,
        accountId,
        runId,
        turnId: assistantTurnId,
        eventType: 'run.completed',
        payload: { citationStatus, citations, searched, userTurnId }
      });

      this.broadcast({
        type: 'run.completed',
        sessionId,
        runId,
        turnId: assistantTurnId,
        answer,
        citations,
        citationStatus,
        searched
      });
    } catch (error) {
      const message = error instanceof Error ? error.message : 'unknown_error';
      await appendRunEvent(this.env, {
        sessionId,
        workspaceId,
        accountId,
        runId,
        eventType: 'run.failed',
        payload: { error: message }
      });
      this.broadcast({ type: 'run.failed', sessionId, runId, error: message });
    } finally {
      this.sessionLocks.delete(sessionId);
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
    await appendRunEvent(this.env, {
      sessionId,
      workspaceId,
      accountId,
      runId,
      eventType: 'tool.progress',
      payload: { stage, detail: detail || null }
    }).catch(() => {});
    this.broadcast({ type: 'tool.progress', sessionId, runId, stage, detail: detail || null });
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

  if (!accountId) {
    return json({ ok: false, error: 'accountId query parameter is required' }, 400);
  }

  const id = env.CHAT_COORDINATOR.idFromName(`${workspaceId}:${accountId}`);
  const stub = env.CHAT_COORDINATOR.get(id);
  const connectUrl = new URL(request.url);
  connectUrl.pathname = '/connect';
  return stub.fetch(new Request(connectUrl.toString(), request));
}

async function runHttpChatQuery(request: Request, env: Env): Promise<Response> {
  const payload = (await request.json()) as JsonRecord;
  const workspaceId = stringOr(payload.workspaceId) || 'default';
  const accountId = stringOr(payload.accountId);
  const userId = stringOr(payload.userId) || 'anonymous';
  const sessionId = stringOr(payload.sessionId) || crypto.randomUUID();
  const query = stringOr(payload.query);

  if (!accountId || !query) {
    return json({ ok: false, error: 'accountId and query are required' }, 400);
  }

  await ensureWorkspaceAndAccount(env, workspaceId, accountId);
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

  const citations = await queryCitations(env, workspaceId, accountId, query);
  const { answer, citationStatus, searched } = buildCitationEnforcedAnswer(query, citations);

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

  if (citations.length > 0) {
    await insertCitations(env, {
      sessionId,
      workspaceId,
      accountId,
      turnId: assistantTurnId,
      citations
    });
  }

  await appendRunEvent(env, {
    sessionId,
    workspaceId,
    accountId,
    runId,
    turnId: assistantTurnId,
    eventType: 'run.completed',
    payload: { citations, citationStatus, searched, userTurnId }
  });

  return json({
    ok: true,
    sessionId,
    runId,
    answer,
    citations,
    citationStatus,
    searched
  });
}

async function proposeAction(request: Request, env: Env): Promise<Response> {
  const payload = (await request.json()) as JsonRecord;
  const workspaceId = stringOr(payload.workspaceId) || 'default';
  const accountId = stringOr(payload.accountId);
  const sessionId = stringOr(payload.sessionId);
  const turnId = stringOr(payload.turnId);
  const actionType = stringOr(payload.actionType);
  const actionPayload = objectOr(payload.payload) || {};

  if (!accountId || !actionType) {
    return json({ ok: false, error: 'accountId and actionType are required' }, 400);
  }

  await ensureWorkspaceAndAccount(env, workspaceId, accountId);

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
        .prepare(
          `SELECT id, status, expires_at FROM proposed_actions WHERE id = ? LIMIT 1`
        )
        .bind(actionId)
        .first<{ id: string; status: string; expires_at: string | null }>()
    : await env.SKY_DB
        .prepare(
          `SELECT id, status, expires_at FROM proposed_actions WHERE approval_token = ? LIMIT 1`
        )
        .bind(approvalToken)
        .first<{ id: string; status: string; expires_at: string | null }>();

  if (!row) {
    return json({ ok: false, error: 'action_not_found' }, 404);
  }

  if (row.status !== 'proposed') {
    return json({ ok: false, error: `action_not_approvable:${row.status}` }, 409);
  }

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

  return json({
    ok: true,
    action: {
      id: row.id,
      status: 'approved',
      nextStep: 'manual_or_separate_executor_required'
    }
  });
}

async function ensureWorkspaceAndAccount(env: Env, workspaceId: string, accountId: string): Promise<void> {
  await env.SKY_DB
    .prepare(
      `INSERT OR IGNORE INTO workspaces (id, name, status, created_at, updated_at)
       VALUES (?, ?, 'active', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)`
    )
    .bind(workspaceId, workspaceId)
    .run();

  const accountEmail = accountId.includes('@') ? accountId.toLowerCase() : null;
  await env.SKY_DB
    .prepare(
      `INSERT OR IGNORE INTO accounts (id, workspace_id, label, email, status, created_at, updated_at)
       VALUES (?, ?, ?, ?, 'active', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)`
    )
    .bind(accountId, workspaceId, accountId, accountEmail)
    .run();
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
    .prepare(
      `UPDATE chat_sessions SET updated_at = CURRENT_TIMESTAMP WHERE id = ?`
    )
    .bind(input.sessionId)
    .run();
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
): Promise<void> {
  await env.SKY_DB
    .prepare(
      `INSERT INTO run_events
       (id, session_id, workspace_id, account_id, run_id, turn_id, event_type, payload_json, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)`
    )
    .bind(
      crypto.randomUUID(),
      input.sessionId,
      input.workspaceId,
      input.accountId,
      input.runId,
      input.turnId || null,
      input.eventType,
      JSON.stringify(input.payload)
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

async function queryCitations(
  env: Env,
  workspaceId: string,
  accountId: string,
  query: string
): Promise<Citation[]> {
  const accountEmail = await resolveAccountEmail(env, workspaceId, accountId);
  if (!accountEmail) return [];

  const like = `%${query.replace(/[%_]/g, ' ').trim()}%`;
  const rows = await env.SKY_DB
    .prepare(
      `SELECT id, sent_at, subject, snippet,
              COALESCE(json_extract(from_json, '$[0].address'), '') AS sender
       FROM email_messages
       WHERE workspace_id = ?
         AND account_email = ?
         AND (subject LIKE ? OR snippet LIKE ?)
       ORDER BY datetime(COALESCE(sent_at, created_at)) DESC
       LIMIT 6`
    )
    .bind(workspaceId, accountEmail, like, like)
    .all<{
      id: string;
      sent_at: string | null;
      subject: string | null;
      snippet: string | null;
      sender: string | null;
    }>();

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
    .prepare(`SELECT email FROM accounts WHERE workspace_id = ? AND id = ? LIMIT 1`)
    .bind(workspaceId, accountId)
    .first<{ email: string | null }>();
  return row?.email ? row.email.toLowerCase() : null;
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

function isAuthorized(request: Request, env: Env): boolean {
  if (!env.WORKER_API_KEY) return true;
  const auth = request.headers.get('authorization') || '';
  return auth === `Bearer ${env.WORKER_API_KEY}`;
}

function unauthorized(): Response {
  return json({ ok: false, error: 'unauthorized' }, 401);
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

function json(payload: JsonRecord, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8' }
  });
}
