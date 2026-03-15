import { extractBearerToken, verifyAccessJwtClaims, type AccessAuthEnv } from '../workers/shared/auth';
import { enqueueEmbeddingJob, ingestCalendarEventsCore, ingestMessageChunksCore } from '../workers/shared/ingestCore';
import { chunkText, cleanEmailBody, htmlToText } from '../workers/shared/textUtils';
import { routeAgentRequest } from 'agents';
import { BlawbyAgent as BlawbyAgentBase } from '../workers/agents/blawby';

interface Env extends AccessAuthEnv {
  SKY_DB: D1Database;
  SKY_ARTIFACTS: R2Bucket;
  SKY_VECTORIZE: VectorizeIndex;
  BLAWBY_AGENT: DurableObjectNamespace;
  AI?: {
    run(model: string, input: Record<string, unknown>): Promise<unknown>;
  };
  EMBEDDING_QUEUE?: QueueBinding;
  WORKER_API_KEY?: string;
  ACCESS_AUTH_ENABLED?: string;
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

export class BlawbyAgent extends BlawbyAgentBase {}

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

type EmailEntity = {
  entity_type: 'invoice' | 'contract' | 'payment' | 'appointment' | 'alert' | 'request' | 'correspondence';
  direction: 'ar' | 'ap' | 'inbound' | 'outbound' | 'unknown';
  counterparty_name: string | null;
  counterparty_email: string | null;
  amount_cents: number | null;
  currency: string | null;
  due_date: string | null;
  reference_number: string | null;
  status: 'open' | 'paid' | 'overdue' | 'pending' | 'requires_action' | 'unknown';
  action_required: boolean;
  action_description: string | null;
  risk_level: 'low' | 'medium' | 'high' | 'critical';
  confidence: number;
};

const MAX_CHUNK_SOURCE_CHARS = 24000;
const CHUNK_SIZE = 1200;
const CHUNK_OVERLAP = 200;
const MAX_CHUNKS_PER_MESSAGE = 24;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname.startsWith('/agents/')) {
      const response = await routeAgentRequest(request, env);
      if (response) return response;
      return json({ ok: false, error: 'Not found' }, 404);
    }

    if (request.method === 'GET' && url.pathname === '/health') {
      return json({ ok: true, service: 'sky-ai-worker', env: env.ENVIRONMENT || 'unknown' });
    }

    if (request.method === 'POST' && url.pathname === '/ingest/mail-thread') {
      if (!(await authorizeHttpRequest(request, env)).ok) return unauthorized();
      return json({
        ok: false,
        error: 'deprecated_endpoint',
        message: 'Raw mail-thread ingest is deprecated. Use /ingest/entities from the native Mac agent.'
      }, 410);
    }

    if (request.method === 'POST' && url.pathname === '/mail/backfill') {
      if (!(await authorizeHttpRequest(request, env)).ok) return unauthorized();
      return queueBackfillRun(request, env);
    }

    if (request.method === 'POST' && url.pathname === '/ingest/rehydrate-chunks') {
      if (!(await authorizeHttpRequest(request, env)).ok) return unauthorized();
      return rehydrateChunksFromArtifacts(request, env);
    }

    // New: backfill entity extraction for existing messages
    if (request.method === 'POST' && url.pathname === '/ingest/extract-entities') {
      if (!(await authorizeHttpRequest(request, env)).ok) return unauthorized();
      return backfillEntityExtraction(request, env);
    }

    if (request.method === 'POST' && url.pathname === '/ingest/resolve-entities') {
      if (!(await authorizeHttpRequest(request, env)).ok) return unauthorized();
      return resolveEntityDuplicates(request, env);
    }

    if (request.method === 'POST' && url.pathname === '/ingest/calendar-events') {
      if (!(await authorizeHttpRequest(request, env)).ok) return unauthorized();
      return ingestCalendarEvents(request, env);
    }

    if (request.method === 'POST' && url.pathname === '/ingest/entities') {
      if (!(await authorizeHttpRequest(request, env)).ok) return unauthorized();
      return ingestEntities(request, env);
    }

    if (request.method === 'POST' && url.pathname === '/ingest/message-chunks') {
      if (!(await authorizeHttpRequest(request, env)).ok) return unauthorized();
      const payload = (await request.json()) as JsonRecord;
      const result = await ingestMessageChunksCore(env, payload);
      return json({ ok: true, ...result });
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

// ─── Entity Extraction ────────────────────────────────────────────────────────

async function extractEmailEntities(
  env: Env,
  input: {
    messageId: string;
    threadId: string | null;
    workspaceId: string;
    accountId: string;
    accountEmail: string;
    subject: string;
    bodyText: string;
    fromAddresses: NormalizedAddress[];
    toAddresses: NormalizedAddress[];
    sentAt: string | null;
    direction: 'inbound' | 'outbound' | 'unknown';
  }
): Promise<EmailEntity | null> {
  if (!hasAiGatewayConfig(env) && !env.AI) return null;
  if (!input.bodyText.trim() && !input.subject.trim()) return null;

  const prompt = `You are a precise email entity extractor. Extract structured facts from this email for the account owner: ${input.accountEmail}

EMAIL:
Subject: ${input.subject}
From: ${input.fromAddresses.map(a => a.name ? `${a.name} <${a.email}>` : a.email).join(', ')}
To: ${input.toAddresses.map(a => a.name ? `${a.name} <${a.email}>` : a.email).join(', ')}
Date: ${input.sentAt || 'unknown'}
Direction: ${input.direction}
Body: ${input.bodyText.slice(0, 3000)}

Respond with ONLY a JSON object. No explanation, no markdown, no code fences.

{
  "entity_type": "invoice|contract|payment|appointment|alert|request|correspondence",
  "direction": "ar|ap|inbound|outbound|unknown",
  "counterparty_name": "string or null",
  "counterparty_email": "string or null",
  "amount_cents": integer_or_null,
  "currency": "USD|GBP|EUR or null",
  "due_date": "YYYY-MM-DD or null",
  "reference_number": "string or null",
  "status": "open|paid|overdue|pending|requires_action|unknown",
  "action_required": true_or_false,
  "action_description": "one sentence describing exactly what action the account owner needs to take, or null",
  "risk_level": "low|medium|high|critical",
  "confidence": 0.0_to_1.0
}

Rules:
- The account owner is ${input.accountEmail}. Reason about ALL directions from THEIR perspective.
- direction "ar" = someone owes the account owner money, or the account owner expects to be paid.
- direction "ap" = the account owner owes someone else money, or needs to make a payment.
- direction "inbound" = non-financial inbound mail where no money changes hands.
- direction "outbound" = mail sent by the account owner with no financial obligation.
- If the email discusses an ongoing payment arrangement where the account owner receives money, that is "ar".
- If the subject contains "Re:" check the snippet carefully — the account owner may be the one being paid.
- amount_cents: integer cents ($50,000 = 5000000). Extract even if informal ("we've been doing 50K").
- action_required: true if the account owner needs to respond, follow up, confirm, or take any step.
- For negotiation or agreement threads, action_required is almost always true.
- risk_level "high" if money is at stake and no response has been confirmed.
- Marketing, newsletters, automated notifications with no money and no required response: entity_type correspondence, action_required false.`;

  let raw: string;
  try {
    raw = await callOpenAiChatViaGateway(env, [{ role: 'user', content: prompt }], 400);
  } catch (openAiError) {
    const msg = openAiError instanceof Error ? openAiError.message : String(openAiError);
    const lower = msg.toLowerCase();
    const isQuotaOrRate =
      lower.includes('429') ||
      lower.includes('insufficient_quota') ||
      lower.includes('rate_limited') ||
      lower.includes('temporarily_disabled');
    if (isQuotaOrRate && env.AI) {
      const result = (await env.AI.run('@cf/meta/llama-3.3-70b-instruct-fp8-fast', {
        messages: [{ role: 'user', content: prompt }],
        max_tokens: 400,
        response_format: { type: 'json_object' }
      })) as { response?: string; result?: { response?: string } };
      raw = (result.response || result.result?.response || '').trim();
      if (!raw) throw new Error('workers_ai_entity_extraction_empty_response');
    } else if (env.AI) {
      const result = (await env.AI.run('@cf/meta/llama-3.3-70b-instruct-fp8-fast', {
        messages: [{ role: 'user', content: prompt }],
        max_tokens: 400,
        response_format: { type: 'json_object' }
      })) as { response?: string; result?: { response?: string } };
      raw = (result.response || result.result?.response || '').trim();
      if (!raw) throw openAiError;
    } else {
      throw openAiError;
    }
  }

  const parsed = JSON.parse(stripJsonCodeFence(raw)) as Partial<EmailEntity>;
  const counterpartyAddresses = input.direction === 'inbound' ? input.fromAddresses : input.toAddresses;

  return {
    entity_type: validateEntityType(parsed.entity_type) ?? 'correspondence',
    direction: validateDirection(parsed.direction) ?? (input.direction === 'inbound' ? 'inbound' : 'outbound'),
    counterparty_name: stringOrNull(parsed.counterparty_name) ?? counterpartyAddresses[0]?.name ?? null,
    counterparty_email: stringOrNull(parsed.counterparty_email) ?? counterpartyAddresses[0]?.email ?? null,
    amount_cents: numberOrNull(parsed.amount_cents),
    currency: stringOrNull(parsed.currency),
    due_date: stringOrNull(parsed.due_date),
    reference_number: stringOrNull(parsed.reference_number),
    status: validateStatus(parsed.status) ?? 'unknown',
    action_required: Boolean(parsed.action_required),
    action_description: stringOrNull(parsed.action_description),
    risk_level: validateRiskLevel(parsed.risk_level) ?? 'low',
    confidence: Math.min(1, Math.max(0, Number(parsed.confidence || 0.5)))
  };
}

async function persistEmailEntity(
  env: Env,
  input: {
    messageId: string;
    threadId: string | null;
    workspaceId: string;
    accountId: string;
    sentAt?: string | null;
    entity: EmailEntity;
  }
): Promise<void> {
  // Lifecycle merge: a paid payment/receipt can close an existing open invoice/contract.
  if ((input.entity.entity_type === 'payment' || input.entity.status === 'paid') && input.entity.amount_cents) {
    const normalizedName = normalizeName(input.entity.counterparty_name);
    const normalizedEmail = normalizeEmail(input.entity.counterparty_email);
    const normalizedReference = normalizeReference(input.entity.reference_number);
    const invoiceMatch = await env.SKY_DB
      .prepare(
        `SELECT id
         FROM email_entities
         WHERE workspace_id = ?
           AND account_id = ?
           AND amount_cents = ?
           AND entity_type IN ('invoice', 'contract')
           AND status != 'paid'
           AND (
             (? IS NOT NULL AND (
               lower(COALESCE(counterparty_name, '')) = ?
               OR lower(COALESCE(counterparty_name, '')) LIKE '%' || ? || '%'
               OR ? LIKE '%' || lower(COALESCE(counterparty_name, '')) || '%'
             ))
             OR (? IS NOT NULL AND lower(COALESCE(counterparty_email, '')) = ?)
             OR (? IS NOT NULL AND lower(trim(COALESCE(reference_number, ''))) = ?)
           )
         ORDER BY datetime(created_at) DESC
         LIMIT 1`
      )
      .bind(
        input.workspaceId,
        input.accountId,
        input.entity.amount_cents,
        normalizedName,
        normalizedName,
        normalizedName,
        normalizedName,
        normalizedEmail,
        normalizedEmail,
        normalizedReference,
        normalizedReference
      )
      .first<{ id: string }>();

    if (invoiceMatch?.id) {
      await env.SKY_DB
        .prepare(
          `UPDATE email_entities
           SET status = 'paid',
               action_required = 0,
               action_description = NULL,
               resolution_note = 'Closed by payment confirmation',
               updated_at = CURRENT_TIMESTAMP
           WHERE id = ?`
        )
        .bind(invoiceMatch.id)
        .run();
      return;
    }
  }

  const existing = await findEntityForMerge(env, input);
  if (existing) {
    const merged = mergeEmailEntities(existing, input.entity);
    await env.SKY_DB
      .prepare(
        `UPDATE email_entities
         SET thread_id = COALESCE(thread_id, ?),
             entity_type = ?,
             direction = ?,
             counterparty_name = ?,
             counterparty_email = ?,
             amount_cents = ?,
             currency = ?,
             due_date = ?,
             reference_number = ?,
             status = ?,
             action_required = ?,
             action_description = ?,
             risk_level = ?,
             confidence = ?,
             raw_json = ?,
             extracted_at = ?,
             updated_at = CURRENT_TIMESTAMP
         WHERE id = ?`
      )
      .bind(
        input.threadId,
        merged.entity_type,
        merged.direction,
        merged.counterparty_name,
        merged.counterparty_email,
        merged.amount_cents,
        merged.currency,
        merged.due_date,
        merged.reference_number,
        merged.status,
        merged.action_required ? 1 : 0,
        merged.action_description,
        merged.risk_level,
        merged.confidence,
        JSON.stringify(merged),
        input.sentAt || new Date().toISOString(),
        existing.id
      )
      .run();
    return;
  }

  await env.SKY_DB
    .prepare(
      `INSERT OR REPLACE INTO email_entities
       (id, workspace_id, account_id, message_id, thread_id, entity_type, direction,
        counterparty_name, counterparty_email, amount_cents, currency, due_date,
        reference_number, status, action_required, action_description, risk_level,
        confidence, raw_json, extracted_at, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)`
    )
    .bind(
      crypto.randomUUID(),
      input.workspaceId,
      input.accountId,
      input.messageId,
      input.threadId,
      input.entity.entity_type,
      input.entity.direction,
      input.entity.counterparty_name,
      input.entity.counterparty_email,
      input.entity.amount_cents,
      input.entity.currency,
      input.entity.due_date,
      input.entity.reference_number,
      input.entity.status,
      input.entity.action_required ? 1 : 0,
      input.entity.action_description,
      input.entity.risk_level,
      input.entity.confidence,
      JSON.stringify(input.entity),
      input.sentAt || new Date().toISOString()
    )
    .run();
}

async function backfillEntityExtraction(request: Request, env: Env): Promise<Response> {
  const payload = (await request.json()) as JsonRecord;
  const workspaceId = stringOr(payload.workspaceId) || 'default';
  const accountId = stringOr(payload.accountId);
  const limit = Math.max(1, Math.min(numberOr(payload.limit) || 100, 500));
  const dryRun = payload.dryRun === true;

  if (!accountId) return json({ ok: false, error: 'accountId is required' }, 400);

  // Find messages that don't yet have extracted entities
  const rows = await env.SKY_DB
    .prepare(
      `SELECT
         em.id AS message_id,
         em.thread_id,
         em.workspace_id,
         em.account_id,
         em.account_email,
         em.subject,
         em.snippet,
         em.direction,
         em.sent_at,
         em.from_json,
         em.to_json,
         a.r2_key
       FROM email_messages em
       LEFT JOIN email_entities ee ON ee.message_id = em.id
       LEFT JOIN artifacts a ON a.id = em.artifact_id
       WHERE em.workspace_id = ?
         AND em.account_id = ?
         AND ee.id IS NULL
       ORDER BY datetime(COALESCE(em.sent_at, em.created_at)) DESC
       LIMIT ?`
    )
    .bind(workspaceId, accountId, limit)
    .all<{
      message_id: string;
      thread_id: string | null;
      workspace_id: string;
      account_id: string;
      account_email: string | null;
      subject: string | null;
      snippet: string | null;
      direction: string | null;
      sent_at: string | null;
      from_json: string | null;
      to_json: string | null;
      r2_key: string | null;
    }>();

  let extracted = 0;
  let skipped = 0;
  const errors: Array<{ messageId: string; error: string }> = [];

  for (const row of rows.results || []) {
    let bodyText = row.snippet || '';

    // Try to get richer body text from the artifact
    if (row.r2_key) {
      try {
        const obj = await env.SKY_ARTIFACTS.get(row.r2_key);
        if (obj) {
          const artifactPayload = JSON.parse(await obj.text()) as JsonRecord;
          const resolved = resolveBestMessageText(artifactPayload, row.subject || '');
          if (resolved) bodyText = resolved;
        }
      } catch {
        // fall through to snippet
      }
    }

    if (!bodyText.trim() && !row.subject?.trim()) {
      skipped += 1;
      continue;
    }

    if (!dryRun) {
      try {
        const fromAddresses = parseAddressJson(row.from_json);
        const toAddresses = parseAddressJson(row.to_json);
        const direction = (row.direction as 'inbound' | 'outbound' | 'unknown') || 'unknown';

        const entity = await extractEmailEntities(env, {
          messageId: row.message_id,
          threadId: row.thread_id,
          workspaceId: row.workspace_id,
          accountId: row.account_id,
          accountEmail: row.account_email || row.account_id,
          subject: row.subject || '',
          bodyText,
          fromAddresses,
          toAddresses,
          sentAt: row.sent_at,
          direction
        });

        if (entity) {
          await persistEmailEntity(env, {
            messageId: row.message_id,
            threadId: row.thread_id,
            workspaceId: row.workspace_id,
            accountId: row.account_id,
            sentAt: row.sent_at,
            entity
          });
          extracted += 1;
        } else {
          skipped += 1;
        }
      } catch (error) {
        skipped += 1;
        const message = error instanceof Error ? error.message : String(error);
        errors.push({ messageId: row.message_id, error: message.slice(0, 400) });
      }
    } else {
      extracted += 1; // dry run counts as would-extract
    }
  }

  return json({
    ok: true,
    scanned: (rows.results || []).length,
    extracted,
    skipped,
    dryRun,
    errors: errors.slice(0, 20)
  });
}

async function resolveEntityDuplicates(request: Request, env: Env): Promise<Response> {
  const payload = (await request.json()) as JsonRecord;
  const workspaceId = stringOr(payload.workspaceId) || 'default';
  const accountId = stringOr(payload.accountId);
  const dryRun = payload.dryRun === true;
  const limit = Math.max(1, Math.min(numberOr(payload.limit) || 100, 500));
  const amountCents = numberOr(payload.amountCents);

  if (!accountId) return json({ ok: false, error: 'accountId is required' }, 400);

  const result = await runEntityResolution(env, {
    workspaceId,
    accountId,
    dryRun,
    limit,
    amountCents
  });

  return json({
    ok: true,
    scanned: result.scanned,
    grouped: result.grouped,
    dryRun
  });
}

async function ingestCalendarEvents(request: Request, env: Env): Promise<Response> {
  try {
    const payload = (await request.json()) as JsonRecord;
    const result = await ingestCalendarEventsCore(env, payload);
    return json({ ok: true, upserted: result.upserted, skipped: result.skipped });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return json({ ok: false, error: message }, 400);
  }
}

async function ingestEntities(request: Request, env: Env): Promise<Response> {
  try {
    const payload = (await request.json()) as JsonRecord;
    const workspaceId = stringOr(payload.workspaceId) || 'default';
    const accountId = stringOr(payload.accountId);
    const entities = Array.isArray(payload.entities) ? payload.entities as JsonRecord[] : [];

    if (!accountId) return json({ ok: false, error: 'accountId is required' }, 400);
    if (entities.length === 0) return json({ ok: true, upserted: 0, skipped: 0 });

    await env.SKY_DB
      .prepare(
        `CREATE UNIQUE INDEX IF NOT EXISTS idx_email_entities_upsert_key
         ON email_entities(workspace_id, account_id, message_id, entity_type)`
      )
      .run();

    let upserted = 0;
    let skipped = 0;

    for (const item of entities) {
      const messageId = stringOr(item.messageId) || stringOr(item.message_id);
      const entityType = stringOr(item.entityType) || stringOr(item.entity_type);
      const direction = stringOr(item.direction) || 'unknown';
      const status = stringOr(item.status) || 'unknown';
      const riskLevel = stringOr(item.riskLevel) || stringOr(item.risk_level) || 'low';
      const confidence = Number(item.confidence ?? 0.5);

      if (!messageId || !entityType) {
        skipped += 1;
        continue;
      }

      await env.SKY_DB
        .prepare(
          `INSERT INTO email_entities
           (id, workspace_id, account_id, message_id, thread_id, entity_type, direction,
            counterparty_name, counterparty_email, amount_cents, currency, due_date,
            reference_number, status, action_required, action_description, risk_level,
            confidence, raw_json, extracted_at, created_at, updated_at)
           VALUES (?, ?, ?, ?, NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
           ON CONFLICT(workspace_id, account_id, message_id, entity_type)
           DO UPDATE SET
             direction = excluded.direction,
             counterparty_name = excluded.counterparty_name,
             counterparty_email = excluded.counterparty_email,
             amount_cents = excluded.amount_cents,
             currency = excluded.currency,
             due_date = excluded.due_date,
             reference_number = excluded.reference_number,
             status = excluded.status,
             action_required = excluded.action_required,
             action_description = excluded.action_description,
             risk_level = excluded.risk_level,
             confidence = excluded.confidence,
             raw_json = excluded.raw_json,
             extracted_at = CURRENT_TIMESTAMP,
             updated_at = CURRENT_TIMESTAMP`
        )
        .bind(
          stringOr(item.id) || crypto.randomUUID(),
          workspaceId,
          accountId,
          messageId,
          entityType,
          direction,
          stringOr(item.counterpartyName) || stringOr(item.counterparty_name),
          stringOr(item.counterpartyEmail) || stringOr(item.counterparty_email),
          numberOr(item.amountCents ?? item.amount_cents),
          stringOr(item.currency),
          stringOr(item.dueDate) || stringOr(item.due_date),
          stringOr(item.referenceNumber) || stringOr(item.reference_number),
          status,
          item.actionRequired === true || item.action_required === true ? 1 : 0,
          stringOr(item.actionDescription) || stringOr(item.action_description),
          riskLevel,
          Number.isFinite(confidence) ? confidence : 0.5,
          JSON.stringify(item)
        )
        .run();
      upserted += 1;
    }

    return json({ ok: true, upserted, skipped });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return json({ ok: false, error: message }, 400);
  }
}

async function findEntityForMerge(
  env: Env,
  input: { workspaceId: string; accountId: string; sentAt?: string | null; entity: EmailEntity }
): Promise<{
  id: string;
  entity_type: EmailEntity['entity_type'];
  direction: EmailEntity['direction'];
  counterparty_name: string | null;
  counterparty_email: string | null;
  amount_cents: number | null;
  currency: string | null;
  due_date: string | null;
  reference_number: string | null;
  status: EmailEntity['status'];
  action_required: number;
  action_description: string | null;
  risk_level: EmailEntity['risk_level'];
  confidence: number;
} | null> {
  const normalizedRef = normalizeReference(input.entity.reference_number);
  if (normalizedRef) {
    const byRef = await env.SKY_DB
      .prepare(
        `SELECT id, entity_type, direction, counterparty_name, counterparty_email, amount_cents, currency,
                due_date, reference_number, status, action_required, action_description, risk_level, confidence
         FROM email_entities
         WHERE workspace_id = ?
           AND account_id = ?
           AND lower(trim(reference_number)) = ?
           AND NOT ((direction = 'ar' AND ? = 'ap') OR (direction = 'ap' AND ? = 'ar'))
         ORDER BY datetime(updated_at) DESC
         LIMIT 1`
      )
      .bind(input.workspaceId, input.accountId, normalizedRef, input.entity.direction, input.entity.direction)
      .first<{
        id: string;
        entity_type: EmailEntity['entity_type'];
        direction: EmailEntity['direction'];
        counterparty_name: string | null;
        counterparty_email: string | null;
        amount_cents: number | null;
        currency: string | null;
        due_date: string | null;
        reference_number: string | null;
        status: EmailEntity['status'];
        action_required: number;
        action_description: string | null;
        risk_level: EmailEntity['risk_level'];
        confidence: number;
      }>();
    if (byRef) return byRef;
  }

  const amount = input.entity.amount_cents;
  const name = normalizeName(input.entity.counterparty_name);
  const email = normalizeEmail(input.entity.counterparty_email);
  if (!Number.isFinite(Number(amount)) || Number(amount) <= 0 || (!name && !email)) return null;

  const targetDate = input.sentAt || new Date().toISOString();
  const byAmountCounterparty = await env.SKY_DB
    .prepare(
      `SELECT id, entity_type, direction, counterparty_name, counterparty_email, amount_cents, currency,
              due_date, reference_number, status, action_required, action_description, risk_level, confidence
       FROM email_entities
       WHERE workspace_id = ?
         AND account_id = ?
         AND amount_cents = ?
         AND abs(julianday(extracted_at) - julianday(?)) <= 30
         AND NOT ((direction = 'ar' AND ? = 'ap') OR (direction = 'ap' AND ? = 'ar'))
         AND (
           (? IS NOT NULL AND lower(COALESCE(counterparty_email, '')) = ?)
           OR (
             ? IS NOT NULL
             AND (
               lower(COALESCE(counterparty_name, '')) LIKE '%' || ? || '%'
               OR ? LIKE '%' || lower(COALESCE(counterparty_name, '')) || '%'
             )
           )
         )
       ORDER BY datetime(updated_at) DESC
       LIMIT 1`
    )
    .bind(
      input.workspaceId,
      input.accountId,
      amount,
      targetDate,
      input.entity.direction,
      input.entity.direction,
      email,
      email,
      name,
      name,
      name
    )
    .first<{
      id: string;
      entity_type: EmailEntity['entity_type'];
      direction: EmailEntity['direction'];
      counterparty_name: string | null;
      counterparty_email: string | null;
      amount_cents: number | null;
      currency: string | null;
      due_date: string | null;
      reference_number: string | null;
      status: EmailEntity['status'];
      action_required: number;
      action_description: string | null;
      risk_level: EmailEntity['risk_level'];
      confidence: number;
    }>();
  return byAmountCounterparty || null;
}

function mergeEmailEntities(
  existing: {
    entity_type: EmailEntity['entity_type'];
    direction: EmailEntity['direction'];
    counterparty_name: string | null;
    counterparty_email: string | null;
    amount_cents: number | null;
    currency: string | null;
    due_date: string | null;
    reference_number: string | null;
    status: EmailEntity['status'];
    action_required: number;
    action_description: string | null;
    risk_level: EmailEntity['risk_level'];
    confidence: number;
  },
  incoming: EmailEntity
): EmailEntity {
  const mergedStatus = mergeEntityStatus(existing.status, incoming.status);
  const mergedActionRequired = mergedStatus === 'paid'
    ? false
    : Boolean(existing.action_required) || incoming.action_required;
  const mergedRisk = mergedStatus === 'paid'
    ? 'low'
    : chooseHigherRisk(existing.risk_level, incoming.risk_level);

  return {
    entity_type: chooseEntityType(existing.entity_type, incoming.entity_type),
    direction: chooseDirection(existing.direction, incoming.direction),
    counterparty_name: incoming.counterparty_name || existing.counterparty_name || null,
    counterparty_email: incoming.counterparty_email || existing.counterparty_email || null,
    amount_cents: incoming.amount_cents ?? existing.amount_cents ?? null,
    currency: incoming.currency || existing.currency || null,
    due_date: incoming.due_date || existing.due_date || null,
    reference_number: incoming.reference_number || existing.reference_number || null,
    status: mergedStatus,
    action_required: mergedActionRequired,
    action_description: mergedActionRequired
      ? (incoming.action_description || existing.action_description || null)
      : null,
    risk_level: mergedRisk,
    confidence: Math.max(Number(existing.confidence || 0), Number(incoming.confidence || 0))
  };
}

function chooseEntityType(a: EmailEntity['entity_type'], b: EmailEntity['entity_type']): EmailEntity['entity_type'] {
  const rank: Record<EmailEntity['entity_type'], number> = {
    invoice: 7,
    contract: 6,
    payment: 5,
    alert: 4,
    request: 3,
    correspondence: 2,
    appointment: 1
  };
  return (rank[b] > rank[a] ? b : a);
}

function chooseDirection(a: EmailEntity['direction'], b: EmailEntity['direction']): EmailEntity['direction'] {
  if (b === 'ar' || b === 'ap') return b;
  if (a === 'ar' || a === 'ap') return a;
  if (b === 'inbound' || b === 'outbound') return b;
  return a || b || 'unknown';
}

function mergeEntityStatus(a: EmailEntity['status'], b: EmailEntity['status']): EmailEntity['status'] {
  if (a === 'paid' || b === 'paid') return 'paid';
  if (a === 'overdue' || b === 'overdue') return 'overdue';
  if (a === 'requires_action' || b === 'requires_action') return 'requires_action';
  if (a === 'open' || b === 'open') return 'open';
  if (a === 'pending' || b === 'pending') return 'pending';
  return 'unknown';
}

function chooseHigherRisk(a: EmailEntity['risk_level'], b: EmailEntity['risk_level']): EmailEntity['risk_level'] {
  const rank: Record<EmailEntity['risk_level'], number> = {
    low: 1,
    medium: 2,
    high: 3,
    critical: 4
  };
  return rank[b] > rank[a] ? b : a;
}

function normalizeReference(v: string | null): string | null {
  if (!v) return null;
  const t = v.trim().toLowerCase();
  return t.length > 0 ? t : null;
}

function normalizeEmail(v: string | null): string | null {
  if (!v) return null;
  const t = v.trim().toLowerCase();
  return t.length > 0 ? t : null;
}

function normalizeName(v: string | null): string | null {
  if (!v) return null;
  const t = v.trim().toLowerCase();
  return t.length > 0 ? t : null;
}

async function runEntityResolution(
  env: Env,
  input: { workspaceId: string; accountId: string; dryRun?: boolean; limit?: number; amountCents?: number | null }
): Promise<{ scanned: number; grouped: number }> {
  const dryRun = input.dryRun === true;
  const limit = Math.max(1, Math.min(input.limit || 100, 500));

  const rows = await env.SKY_DB
    .prepare(
      `SELECT
         a.id AS id_a,
         b.id AS id_b,
         a.entity_type AS type_a,
         b.entity_type AS type_b,
         a.direction AS dir_a,
         b.direction AS dir_b,
         a.counterparty_name AS name_a,
         b.counterparty_name AS name_b,
         a.amount_cents,
         a.reference_number AS ref_a,
         b.reference_number AS ref_b,
         a.status AS status_a,
         b.status AS status_b,
         a.risk_level AS risk_a,
         b.risk_level AS risk_b,
         a.action_required AS action_a,
         b.action_required AS action_b,
         a.action_description AS action_desc_a,
         b.action_description AS action_desc_b,
         a.resolved_group_id AS group_a,
         b.resolved_group_id AS group_b
       FROM email_entities a
       JOIN email_entities b
         ON a.account_id = b.account_id
         AND a.workspace_id = b.workspace_id
         AND a.amount_cents = b.amount_cents
         AND a.amount_cents IS NOT NULL
         AND a.id < b.id
         AND a.resolved_group_id IS NULL
         AND b.resolved_group_id IS NULL
         AND abs(julianday(a.extracted_at) - julianday(b.extracted_at)) <= 30
       WHERE a.workspace_id = ?
         AND a.account_id = ?
         AND (? IS NULL OR a.amount_cents = ?)
       LIMIT 100`
    )
    .bind(input.workspaceId, input.accountId, input.amountCents ?? null, input.amountCents ?? null)
    .all<{
      id_a: string; id_b: string;
      type_a: string; type_b: string;
      dir_a: string; dir_b: string;
      name_a: string | null; name_b: string | null;
      amount_cents: number;
      ref_a: string | null; ref_b: string | null;
      status_a: string; status_b: string;
      risk_a: string; risk_b: string;
      action_a: number; action_b: number;
      action_desc_a: string | null; action_desc_b: string | null;
      group_a: string | null; group_b: string | null;
    }>();

  let grouped = 0;
  const riskRank = (risk: string): number => {
    const r = (risk || '').toLowerCase();
    if (r === 'critical') return 4;
    if (r === 'high') return 3;
    if (r === 'medium') return 2;
    return 1;
  };

  for (const pair of (rows.results || []).slice(0, limit)) {
    const financialTypes = ['invoice', 'payment', 'alert', 'contract'];
    if (!financialTypes.includes(pair.type_a) && !financialTypes.includes(pair.type_b)) continue;

    if (
      (pair.dir_a === 'ar' && pair.dir_b === 'ap') ||
      (pair.dir_a === 'ap' && pair.dir_b === 'ar')
    ) continue;

    const lo = pair.id_a < pair.id_b ? pair.id_a : pair.id_b;
    const hi = pair.id_a < pair.id_b ? pair.id_b : pair.id_a;
    const groupId = await sha256Hex(`${lo}:${hi}`);
    const canonicalId = pair.type_a === 'invoice' ? pair.id_a
      : pair.type_b === 'invoice' ? pair.id_b
      : riskRank(pair.risk_a) >= riskRank(pair.risk_b) ? pair.id_a : pair.id_b;
    const note = `Grouped with ${pair.amount_cents / 100} ${pair.type_a}+${pair.type_b} pair; canonical=${canonicalId}`;

    if (!dryRun) {
      await env.SKY_DB
        .prepare(
          `UPDATE email_entities
           SET resolved_group_id = ?,
               resolution_note = ?,
               updated_at = CURRENT_TIMESTAMP
           WHERE id IN (?, ?)`
        )
        .bind(groupId, note, pair.id_a, pair.id_b)
        .run();
    }

    grouped += 1;
  }

  return {
    scanned: (rows.results || []).length,
    grouped
  };
}

// ─── Ingest ───────────────────────────────────────────────────────────────────

async function ingestMailThread(request: Request, env: Env): Promise<Response> {
  const payload = (await request.json()) as JsonRecord;
  const providerUid = numberOr(payload.uid);
  const providerMessageId = stringOr(payload.messageId);
  let ingested;
  try {
    ingested = await ingestMailThreadCore(env, payload);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return json({ ok: false, error: message }, 400);
  }

  const {
    deduped,
    workspaceId,
    accountId,
    accountEmail,
    mailbox,
    threadId,
    messageId,
    sourceMessageKey,
    subject,
    snippet,
    sentAt,
    fromAddresses,
    toAddresses,
    direction
  } = ingested;
  const threadExternalId = stringOr(payload.threadId) || threadId;

  if (deduped) {
    return json({ ok: true, deduped: true, messageId, sourceMessageKey });
  }

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

  const rawSource = stringOr(payload.rawRfc822) || '';
  const rawSha256 = rawSource ? await sha256Hex(rawSource) : null;
  await env.SKY_DB
    .prepare(
      `UPDATE email_messages
       SET artifact_id = ?,
           raw_sha256 = COALESCE(?, raw_sha256),
           updated_at = CURRENT_TIMESTAMP
       WHERE id = ?`
    )
    .bind(
      artifactId,
      rawSha256,
      messageId
    )
    .run();

  const chunkSource = buildChunkSource(payload, subject, snippet);
  const classification = classifyEmailThread({
    subject,
    snippet,
    bodyText: chunkSource,
    from: fromAddresses.map((x) => x.email),
    mailbox
  });
  await upsertThreadClassification(env, threadId, classification);

  // Fire-and-forget entity extraction — never blocks ingest
  if (hasAiGatewayConfig(env) || env.AI) {
    const bodyText = resolveBestMessageText(payload, `${subject}\n\n${snippet}`);
    extractEmailEntities(env, {
      messageId,
      threadId,
      workspaceId,
      accountId,
      accountEmail,
      subject,
      bodyText,
      fromAddresses,
      toAddresses,
      sentAt,
      direction
    }).then((entity) => {
      if (entity) {
        return persistEmailEntity(env, { messageId, threadId, workspaceId, accountId, sentAt, entity }).then(() => {
          if (!Number.isFinite(Number(entity.amount_cents)) || Number(entity.amount_cents) <= 0) return;
          return runEntityResolution(env, {
            workspaceId,
            accountId,
            amountCents: entity.amount_cents,
            limit: 50
          });
        });
      }
    }).catch((error) => {
      const message = error instanceof Error ? error.message : String(error);
      console.error(`entity_extraction_failed messageId=${messageId} error=${message}`);
    });
  }

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

    await enqueueEmbeddingJob(env, workspaceId, accountId, recordId);
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

// ─── Thread Helpers ───────────────────────────────────────────────────────────

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

async function upsertThreadClassification(
  env: Env,
  threadId: string,
  classification: ThreadClassification
): Promise<void> {
  try {
    await env.SKY_DB
      .prepare(
        `UPDATE email_threads
         SET classification_json = ?,
             classification_updated_at = CURRENT_TIMESTAMP,
             updated_at = CURRENT_TIMESTAMP
         WHERE id = ?`
      )
      .bind(JSON.stringify(classification), threadId)
      .run();
  } catch (error) {
    const message = error instanceof Error ? error.message : 'unknown';
    if (!/no such column/i.test(message)) {
      throw error;
    }
  }
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

// ─── Backfill & Rehydration ───────────────────────────────────────────────────

async function queueBackfillRun(request: Request, env: Env): Promise<Response> {
  const payload = (await request.json()) as JsonRecord;
  const workspaceId = stringOr(payload.workspaceId) || 'default';
  const accountEmail = stringOr(payload.accountEmail) || 'unknown';
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

async function rehydrateChunksFromArtifacts(request: Request, env: Env): Promise<Response> {
  const payload = (await request.json()) as JsonRecord;
  const workspaceId = stringOr(payload.workspaceId) || 'default';
  const accountId = stringOr(payload.accountId);
  const messageId = stringOr(payload.messageId);
  const noisyOnly = payload.noisyOnly !== false;
  const processNow = payload.processNow === true;
  const dryRun = payload.dryRun === true;
  const limit = Math.max(1, Math.min(numberOr(payload.limit) || 100, 1000));
  const beforeCreatedAt = stringOr(payload.beforeCreatedAt);

  const rows = await env.SKY_DB
    .prepare(
      `SELECT
          nr.id AS source_record_id,
          nr.workspace_id,
          em.id AS message_id,
          em.thread_id,
          em.mailbox,
          em.account_id,
          em.account_email,
          em.sent_at,
          em.subject,
          em.direction,
          em.created_at,
          a.r2_key
       FROM normalized_records nr
       JOIN artifacts a ON a.id = nr.source_artifact_id
       JOIN email_messages em ON em.artifact_id = a.id
       WHERE nr.record_type = 'email_message'
         AND nr.workspace_id = ?
         AND (? IS NULL OR em.account_id = ?)
         AND (? IS NULL OR em.id = ?)
         AND (? IS NULL OR datetime(em.created_at) < datetime(?))
         AND (
           ? = 0
           OR EXISTS (
             SELECT 1
             FROM memory_chunks mc
             WHERE mc.source_record_id = nr.id
               AND (
                 lower(mc.chunk_text) LIKE '%return-path:%'
                 OR lower(mc.chunk_text) LIKE '%received:%'
                 OR lower(mc.chunk_text) LIKE '%mime-version:%'
                 OR lower(mc.chunk_text) LIKE '%content-type:%'
                 OR lower(mc.chunk_text) LIKE '%content-transfer-encoding:%'
                 OR lower(mc.chunk_text) LIKE '%dkim-signature:%'
                 OR lower(mc.chunk_text) LIKE '%x-icl-info:%'
               )
           )
         )
       ORDER BY datetime(em.created_at) DESC
       LIMIT ?`
    )
    .bind(
      workspaceId,
      accountId,
      accountId,
      messageId,
      messageId,
      beforeCreatedAt,
      beforeCreatedAt,
      noisyOnly ? 1 : 0,
      limit
    )
    .all<{
      source_record_id: string;
      workspace_id: string;
      message_id: string;
      thread_id: string | null;
      mailbox: string | null;
      account_id: string | null;
      account_email: string | null;
      sent_at: string | null;
      subject: string | null;
      direction: string | null;
      created_at: string;
      r2_key: string;
    }>();

  let rebuilt = 0;
  let reembeddedNow = 0;
  let totalChunksDeleted = 0;
  let totalChunksInserted = 0;

  for (const row of rows.results || []) {
    const obj = await env.SKY_ARTIFACTS.get(row.r2_key);
    if (!obj) {
      throw new Error(`artifact_missing:${row.r2_key}`);
    }
    const artifactPayload = JSON.parse(await obj.text()) as JsonRecord;

    const subject = row.subject || '';
    const snippet = buildSnippet(artifactPayload, subject);
    const chunkSource = buildChunkSource(artifactPayload, subject, snippet);
    const chunks = chunkText(chunkSource, CHUNK_SIZE, CHUNK_OVERLAP, MAX_CHUNKS_PER_MESSAGE);

    if (!dryRun) {
      const deleted = await env.SKY_DB
        .prepare(`DELETE FROM memory_chunks WHERE source_record_id = ?`)
        .bind(row.source_record_id)
        .run();
      totalChunksDeleted += Number((deleted as unknown as { meta?: { changes?: number } }).meta?.changes || 0);

      for (let i = 0; i < chunks.length; i += 1) {
        await env.SKY_DB
          .prepare(
            `INSERT INTO memory_chunks
             (id, workspace_id, account_id, source_record_id, vector_id, chunk_text, metadata_json, created_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)`
          )
          .bind(
            crypto.randomUUID(),
            row.workspace_id,
            row.account_id || row.account_email || 'unknown',
            row.source_record_id,
            `${row.message_id}:${i}`,
            chunks[i],
            JSON.stringify({
              messageId: row.message_id,
              threadId: row.thread_id,
              mailbox: row.mailbox,
              accountId: row.account_id || row.account_email || 'unknown',
              accountEmail: row.account_email,
              sentAt: row.sent_at,
              chunkIndex: i
            })
          )
          .run();
      }
      totalChunksInserted += chunks.length;

      await env.SKY_DB
        .prepare(`UPDATE email_messages SET snippet = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?`)
        .bind(snippet || null, row.message_id)
        .run();

      await env.SKY_DB
        .prepare(
          `UPDATE normalized_records
           SET body_json = json_set(COALESCE(body_json, '{}'), '$.snippet', ?),
               updated_at = CURRENT_TIMESTAMP
           WHERE id = ?`
        )
        .bind(snippet, row.source_record_id)
        .run();

      const targetAccountId = row.account_id || row.account_email || 'unknown';
      await enqueueEmbeddingJob(env, row.workspace_id, targetAccountId, row.source_record_id);

      // Also re-extract entities for rehydrated messages
      if (hasAiGatewayConfig(env) || env.AI) {
        const bodyText = resolveBestMessageText(artifactPayload, `${subject}\n\n${snippet}`);
        const fromAddresses = parseAddressJson(artifactPayload.from);
        const toAddresses = parseAddressJson(artifactPayload.to);
        const direction = (row.direction as 'inbound' | 'outbound' | 'unknown') || 'unknown';
        const entity = await extractEmailEntities(env, {
          messageId: row.message_id,
          threadId: row.thread_id,
          workspaceId: row.workspace_id,
          accountId: targetAccountId,
          accountEmail: row.account_email || targetAccountId,
          subject,
          bodyText,
          fromAddresses,
          toAddresses,
          sentAt: row.sent_at,
          direction
        });
        if (entity) {
          await persistEmailEntity(env, {
            messageId: row.message_id,
            threadId: row.thread_id,
            workspaceId: row.workspace_id,
            accountId: targetAccountId,
            sentAt: row.sent_at,
            entity
          });
          if (Number.isFinite(Number(entity.amount_cents)) && Number(entity.amount_cents) > 0) {
            await runEntityResolution(env, {
              workspaceId: row.workspace_id,
              accountId: targetAccountId,
              amountCents: entity.amount_cents,
              limit: 50
            });
          }
        }
      }

      if (processNow) {
        const res = await processSingleEmbeddingJob(env, row.source_record_id);
        if (res.status === 'indexed') reembeddedNow += 1;
      }
    }

    rebuilt += 1;
  }

  return json({
    ok: true,
    workspaceId,
    accountId: accountId || null,
    messageId: messageId || null,
    noisyOnly,
    dryRun,
    processNow,
    beforeCreatedAt: beforeCreatedAt || null,
    nextBeforeCreatedAt: (rows.results || []).length > 0 ? rows.results?.[rows.results.length - 1]?.created_at || null : null,
    scanned: (rows.results || []).length,
    rebuilt,
    chunksDeleted: totalChunksDeleted,
    chunksInserted: totalChunksInserted,
    reembeddedNow
  });
}

// ─── Embedding ────────────────────────────────────────────────────────────────


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

// ─── Outbound Mail ────────────────────────────────────────────────────────────

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

// ─── Classification ───────────────────────────────────────────────────────────

function classifyEmailThread(input: {
  subject: string;
  snippet: string;
  bodyText: string;
  from: string[];
  mailbox: string;
}): ThreadClassification {
  const text = `${input.subject}\n${input.snippet}\n${input.bodyText}`.toLowerCase();
  const senderText = input.from.join(' ').toLowerCase();
  const reasons: string[] = [];

  const has = (patterns: RegExp[]): boolean => patterns.some((p) => p.test(text));

  const urgentPatterns = [/\burgent\b/, /\basap\b/, /\bimmediately\b/, /\bcritical\b/, /\baction required\b/, /\boverdue\b/];
  const positivePatterns = [/\bthank(s| you)?\b/, /\bappreciate\b/, /\bgreat\b/, /\bawesome\b/, /\bexcited\b/, /\blove\b/];
  const replyPatterns = [/\?/, /\bplease (reply|respond|confirm|review)\b/, /\bcan you\b/, /\blet me know\b/, /\bfollow up\b/];
  const customerSupportPatterns = [/\bcustomer\b/, /\bsupport\b/, /\bhelp\b/, /\bissue\b/, /\bproblem\b/, /\breturn\b/, /\bwarranty\b/, /\btracking\b/, /\border\b/];
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

// ─── Text Processing ──────────────────────────────────────────────────────────


function resolveBestMessageText(payload: JsonRecord, fallback: string): string {
  const raw = stringOr(payload.rawRfc822);
  if (raw) {
    const parsed = cleanEmailBody(extractTextFromMimeMessage(raw));
    if (parsed) return parsed;
  }

  const bodyText = stringOr(payload.bodyText);
  if (bodyText) {
    const cleaned = cleanEmailBody(bodyText);
    if (cleaned) return cleaned;
  }

  return cleanEmailBody(fallback);
}

function buildSnippet(payload: JsonRecord, subject: string): string {
  return resolveBestMessageText(payload, subject).slice(0, 500);
}

function buildChunkSource(payload: JsonRecord, subject: string, fallbackSnippet: string): string {
  const resolved = resolveBestMessageText(payload, `${subject}\n\n${fallbackSnippet}`);
  const parts = [
    subject ? `Subject: ${subject}` : '',
    fallbackSnippet ? `Snippet: ${fallbackSnippet}` : '',
    resolved
  ].filter(Boolean);
  return parts.join('\n\n').slice(0, MAX_CHUNK_SOURCE_CHARS);
}

// ─── MIME Parsing ─────────────────────────────────────────────────────────────

function extractTextFromMimeMessage(raw: string): string {
  const normalized = raw.replace(/\r\n/g, '\n');
  const extracted = extractTextFromMimeEntity(normalized);
  const preferred = extracted.plainParts.filter(Boolean).join('\n\n').trim();
  if (preferred) return preferred;
  const html = extracted.htmlParts.filter(Boolean).join('\n\n').trim();
  if (html) return html;
  return extractBodyFallback(normalized);
}

function extractTextFromMimeEntity(entity: string): { plainParts: string[]; htmlParts: string[] } {
  const splitAt = entity.indexOf('\n\n');
  const rawHeaders = splitAt >= 0 ? entity.slice(0, splitAt) : '';
  const rawBody = splitAt >= 0 ? entity.slice(splitAt + 2) : entity;
  const headers = parseMimeHeaders(rawHeaders);
  const contentType = (headers['content-type'] || 'text/plain').toLowerCase();
  const transferEncoding = (headers['content-transfer-encoding'] || '7bit').toLowerCase();
  const charset = parseMimeCharset(contentType);

  if (contentType.includes('multipart/alternative')) {
    const boundary = parseMimeBoundary(contentType);
    if (!boundary) return { plainParts: [], htmlParts: [] };
    const parts = splitMimeMultipartBody(rawBody, boundary);
    const plainCandidates: string[] = [];
    const htmlCandidates: string[] = [];
    for (const part of parts) {
      const nested = extractTextFromMimeEntity(part);
      if (nested.plainParts.length > 0) plainCandidates.push(...nested.plainParts);
      if (nested.htmlParts.length > 0) htmlCandidates.push(...nested.htmlParts);
    }
    if (plainCandidates.length > 0) return { plainParts: [plainCandidates[0]], htmlParts: [] };
    if (htmlCandidates.length > 0) return { plainParts: [], htmlParts: [htmlCandidates[0]] };
    return { plainParts: [], htmlParts: [] };
  }

  if (contentType.includes('multipart/')) {
    const boundary = parseMimeBoundary(contentType);
    if (!boundary) return { plainParts: [], htmlParts: [] };
    const parts = splitMimeMultipartBody(rawBody, boundary);
    const plainParts: string[] = [];
    const htmlParts: string[] = [];
    for (const part of parts) {
      const nested = extractTextFromMimeEntity(part);
      plainParts.push(...nested.plainParts);
      htmlParts.push(...nested.htmlParts);
    }
    return { plainParts, htmlParts };
  }

  if (contentType.includes('message/rfc822')) {
    return extractTextFromMimeEntity(rawBody);
  }

  const decoded = decodeMimeTransferEncoding(rawBody, transferEncoding, charset);
  if (contentType.includes('text/plain')) {
    return { plainParts: [decoded], htmlParts: [] };
  }
  if (contentType.includes('text/html')) {
    return { plainParts: [], htmlParts: [htmlToText(decoded)] };
  }

  return { plainParts: [], htmlParts: [] };
}

function parseMimeHeaders(rawHeaders: string): Record<string, string> {
  const lines = rawHeaders.split('\n');
  const unfolded: string[] = [];
  for (const line of lines) {
    if ((line.startsWith(' ') || line.startsWith('\t')) && unfolded.length > 0) {
      unfolded[unfolded.length - 1] += ` ${line.trim()}`;
      continue;
    }
    if (line.trim()) unfolded.push(line.trim());
  }

  const headers: Record<string, string> = {};
  for (const line of unfolded) {
    const idx = line.indexOf(':');
    if (idx <= 0) continue;
    const key = line.slice(0, idx).trim().toLowerCase();
    const value = line.slice(idx + 1).trim();
    const decodedValue = decodeMimeHeaderWords(value);
    headers[key] = headers[key] ? `${headers[key]}, ${decodedValue}` : decodedValue;
  }
  return headers;
}

function parseMimeCharset(contentType: string): string {
  const match = contentType.match(/charset=(?:"([^"]+)"|([^;]+))/i);
  const charset = (match?.[1] || match?.[2] || 'utf-8').trim().toLowerCase();
  return normalizeCharsetLabel(charset);
}

function parseMimeBoundary(contentType: string): string | null {
  const match = contentType.match(/boundary=(?:"([^"]+)"|([^;]+))/i);
  if (!match) return null;
  return (match[1] || match[2] || '').trim();
}

function splitMimeMultipartBody(body: string, boundary: string): string[] {
  const marker = `--${boundary}`;
  const endMarker = `--${boundary}--`;
  const lines = body.split('\n');
  const parts: string[] = [];
  let collecting = false;
  let current: string[] = [];

  for (const line of lines) {
    if (line.startsWith(endMarker)) {
      if (collecting && current.length > 0) parts.push(current.join('\n'));
      break;
    }
    if (line.startsWith(marker)) {
      if (collecting && current.length > 0) parts.push(current.join('\n'));
      collecting = true;
      current = [];
      continue;
    }
    if (collecting) current.push(line);
  }

  return parts.map((part) => part.trim()).filter(Boolean);
}

function decodeMimeTransferEncoding(body: string, transferEncoding: string, charset: string): string {
  if (transferEncoding.includes('quoted-printable')) {
    return decodeBytesWithCharset(decodeQuotedPrintableToBytes(body), charset);
  }
  if (transferEncoding.includes('base64')) {
    return decodeBytesWithCharset(decodeBase64ToBytes(body), charset);
  }
  return decodeBytesWithCharset(stringToByteArray(body), charset);
}

function decodeQuotedPrintableToBytes(input: string): Uint8Array {
  const softWrapped = input.replace(/=\n/g, '');
  const bytes: number[] = [];
  for (let i = 0; i < softWrapped.length; i += 1) {
    const ch = softWrapped[i];
    if (ch === '=' && i + 2 < softWrapped.length) {
      const hex = softWrapped.slice(i + 1, i + 3);
      if (/^[0-9A-Fa-f]{2}$/.test(hex)) {
        bytes.push(Number.parseInt(hex, 16));
        i += 2;
        continue;
      }
    }
    bytes.push(ch.charCodeAt(0));
  }
  return new Uint8Array(bytes);
}

function decodeBase64ToBytes(input: string): Uint8Array {
  const compact = input.replace(/\s+/g, '');
  const binary = atob(compact);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

function stringToByteArray(input: string): Uint8Array {
  const bytes = new Uint8Array(input.length);
  for (let i = 0; i < input.length; i += 1) {
    bytes[i] = input.charCodeAt(i) & 0xff;
  }
  return bytes;
}

function decodeBytesWithCharset(bytes: Uint8Array, charset: string): string {
  return new TextDecoder(charset, { fatal: false }).decode(bytes);
}

function normalizeCharsetLabel(charset: string): string {
  const c = charset.trim().toLowerCase();
  if (c === 'utf8') return 'utf-8';
  if (c === 'latin1' || c === 'iso8859-1') return 'iso-8859-1';
  if (c === 'win-1252') return 'windows-1252';
  return c || 'utf-8';
}

function decodeMimeHeaderWords(input: string): string {
  return input.replace(/=\?([^?]+)\?([bBqQ])\?([^?]+)\?=/g, (_m, rawCharset: string, enc: string, data: string) => {
    const charset = normalizeCharsetLabel(String(rawCharset || 'utf-8'));
    if (String(enc).toLowerCase() === 'b') {
      return decodeBytesWithCharset(decodeBase64ToBytes(data), charset);
    }
    const q = data.replace(/_/g, ' ');
    return decodeBytesWithCharset(decodeQuotedPrintableToBytes(q), charset);
  });
}


function extractBodyFallback(normalizedRaw: string): string {
  const splitAt = normalizedRaw.indexOf('\n\n');
  if (splitAt >= 0) return normalizedRaw.slice(splitAt + 2);
  return normalizedRaw;
}

// ─── Address Helpers ──────────────────────────────────────────────────────────

function normalizeAddresses(input: unknown): NormalizedAddress[] {
  if (!Array.isArray(input)) return [];

  const out: NormalizedAddress[] = [];
  for (const item of input) {
    if (!item || typeof item !== 'object') continue;
    const record = item as Record<string, unknown>;
    const email = stringOr(record.address) || stringOr(record.email);
    if (!email) continue;
    const rawName = stringOr(record.name);
    out.push({ email, name: rawName ? decodeMimeHeaderWords(rawName) : null });
  }
  return out;
}

function parseAddressJson(input: unknown): NormalizedAddress[] {
  if (typeof input === 'string') {
    try { return normalizeAddresses(JSON.parse(input)); } catch { return []; }
  }
  return normalizeAddresses(input);
}

function deriveMessageDirection(
  mailbox: string,
  fromAddresses: NormalizedAddress[],
  accountEmail: string
): 'inbound' | 'outbound' | 'unknown' {
  const mailboxLower = mailbox.trim().toLowerCase();
  if (mailboxLower === 'sent' || mailboxLower === 'sent messages') {
    return 'outbound';
  }

  const account = accountEmail.trim().toLowerCase();
  if (account && account !== 'unknown') {
    const fromMatch = fromAddresses.some((x) => x.email.toLowerCase() === account);
    if (fromMatch) return 'outbound';
  }

  const hasSender = fromAddresses.length > 0;
  const hasMailboxSignal = mailboxLower.length > 0;
  if (!hasSender && !hasMailboxSignal) return 'unknown';
  return 'inbound';
}

// ─── Utility ──────────────────────────────────────────────────────────────────

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

async function ensureWorkspace(env: Env, workspaceId: string): Promise<void> {
  await env.SKY_DB
    .prepare(
      `INSERT OR IGNORE INTO workspaces (id, name, status, created_at, updated_at)
       VALUES (?, ?, 'active', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)`
    )
    .bind(workspaceId, workspaceId)
    .run();
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

function computeBackoffMinutes(attempts: number): number {
  return Math.min(240, Math.max(1, 2 ** Math.min(attempts, 8)));
}

function validateEntityType(v: unknown): EmailEntity['entity_type'] | null {
  const valid = ['invoice', 'contract', 'payment', 'appointment', 'alert', 'request', 'correspondence'];
  return valid.includes(v as string) ? (v as EmailEntity['entity_type']) : null;
}

function validateDirection(v: unknown): EmailEntity['direction'] | null {
  const valid = ['ar', 'ap', 'inbound', 'outbound', 'unknown'];
  return valid.includes(v as string) ? (v as EmailEntity['direction']) : null;
}

function validateStatus(v: unknown): EmailEntity['status'] | null {
  const valid = ['open', 'paid', 'overdue', 'pending', 'requires_action', 'unknown'];
  return valid.includes(v as string) ? (v as EmailEntity['status']) : null;
}

function validateRiskLevel(v: unknown): EmailEntity['risk_level'] | null {
  const valid = ['low', 'medium', 'high', 'critical'];
  return valid.includes(v as string) ? (v as EmailEntity['risk_level']) : null;
}

function stringOrNull(v: unknown): string | null {
  return typeof v === 'string' && v.trim() ? v.trim() : null;
}

function numberOrNull(v: unknown): number | null {
  if (typeof v === 'number' && Number.isFinite(v)) return Math.round(v);
  if (typeof v === 'string' && v.trim()) {
    const n = Number(v);
    if (Number.isFinite(n)) return Math.round(n);
  }
  return null;
}

function stripJsonCodeFence(raw: string): string {
  const trimmed = raw.trim();
  if (trimmed.startsWith('```')) {
    return trimmed.replace(/^```(?:json)?/i, '').replace(/```$/i, '').trim();
  }
  return raw;
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

function unauthorized(): Response {
  return json({ ok: false, error: 'unauthorized' }, 401);
}

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
    await verifyAccessJwtClaims(jwt, env);
    return { ok: true };
  } catch {
    return { ok: false };
  }
}

function hasAiGatewayConfig(env: Env): boolean {
  return Boolean(env.OPENAI_API_KEY && env.AIG_ACCOUNT_ID && env.AIG_GATEWAY_ID);
}

async function callOpenAiChatViaGateway(
  env: Env,
  messages: Array<{ role: 'user' | 'assistant'; content: string }>,
  maxTokens = 400
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
      max_tokens: maxTokens,
      temperature: 0,
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
