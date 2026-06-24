import type { CloudflareAuthEnv } from '../betterAuth';
import type { McpAuthContext } from './auth';

export interface SearchResultLike {
  message_id: string;
  thread_id: string | null;
  date: string | null;
  from: string;
  subject: string;
  excerpt: string;
  score: number;
  chunk_id: string;
}

/** Worker-provided capabilities the MCP tools depend on (avoids importing the worker). */
export interface McpToolDeps {
  semanticSearch(
    workspaceId: string,
    accountId: string,
    query: string,
    k: number,
  ): Promise<SearchResultLike[]>;
}

export interface McpToolContext extends McpAuthContext {
  env: CloudflareAuthEnv;
  deps: McpToolDeps;
}

export interface McpJsonSchema {
  type: 'object';
  properties?: Record<string, unknown>;
  required?: string[];
  additionalProperties?: boolean;
}

export interface McpTool {
  name: string;
  description: string;
  inputSchema: McpJsonSchema;
  handler(ctx: McpToolContext, args: Record<string, unknown>): Promise<unknown>;
}

function clampLimit(value: unknown, fallback: number, max: number): number {
  const n = typeof value === 'number' ? value : Number(value);
  if (!Number.isFinite(n) || n <= 0) return fallback;
  return Math.min(max, Math.trunc(n));
}

function str(value: unknown): string {
  return typeof value === 'string' ? value.trim() : '';
}

function safeJson<T>(value: string | null): T | null {
  if (!value) return null;
  try {
    return JSON.parse(value) as T;
  } catch {
    return null;
  }
}

type Addr = { email?: string; address?: string; name?: string };

function formatAddresses(json: string | null): string {
  const parsed = safeJson<Addr[]>(json);
  if (!Array.isArray(parsed)) return '';
  return parsed
    .map((a) => a.email || a.address || a.name || '')
    .filter(Boolean)
    .join(', ');
}

// Read-only tools exposing the synced personal data.
export const MCP_TOOLS: McpTool[] = [
  {
    name: 'search_messages',
    description:
      'Semantic search across the user\'s synced emails and messages. Use for natural-language questions like "invoices from Acme" or "what did Sarah say about the contract".',
    inputSchema: {
      type: 'object',
      properties: {
        query: { type: 'string', description: 'Natural-language search query.' },
        limit: { type: 'number', description: 'Max results (1-25, default 10).' },
      },
      required: ['query'],
      additionalProperties: false,
    },
    async handler(ctx, args) {
      const query = str(args.query);
      if (!query) throw new Error('query is required');
      const limit = clampLimit(args.limit, 10, 25);
      const results = await ctx.deps.semanticSearch(ctx.workspaceId, ctx.accountId, query, limit);
      return { query, count: results.length, results };
    },
  },
  {
    name: 'get_email_message',
    description: 'Fetch a single email message by its id (as returned by search_messages.message_id).',
    inputSchema: {
      type: 'object',
      properties: {
        message_id: { type: 'string', description: 'The email message id.' },
      },
      required: ['message_id'],
      additionalProperties: false,
    },
    async handler(ctx, args) {
      const messageId = str(args.message_id);
      if (!messageId) throw new Error('message_id is required');
      const row = await ctx.env.SKY_DB.prepare(
        `SELECT id, thread_id, mailbox, subject, sent_at, from_json, to_json, snippet
         FROM email_messages
         WHERE workspace_id = ? AND account_email = ? AND id = ?
         LIMIT 1`,
      )
        .bind(ctx.workspaceId, ctx.accountEmail, messageId)
        .first<{
          id: string;
          thread_id: string | null;
          mailbox: string | null;
          subject: string | null;
          sent_at: string | null;
          from_json: string | null;
          to_json: string | null;
          snippet: string | null;
        }>();
      if (!row) throw new Error('Message not found');
      return {
        id: row.id,
        thread_id: row.thread_id,
        mailbox: row.mailbox,
        subject: row.subject ?? '(no subject)',
        sent_at: row.sent_at,
        from: formatAddresses(row.from_json),
        to: formatAddresses(row.to_json),
        snippet: row.snippet ?? '',
      };
    },
  },
  {
    name: 'list_threads',
    description: 'List the most recent email threads, newest first.',
    inputSchema: {
      type: 'object',
      properties: {
        limit: { type: 'number', description: 'Max threads (1-50, default 20).' },
      },
      additionalProperties: false,
    },
    async handler(ctx, args) {
      const limit = clampLimit(args.limit, 20, 50);
      const rows = await ctx.env.SKY_DB.prepare(
        `SELECT id, subject, mailbox, first_message_at, last_message_at
         FROM email_threads
         WHERE workspace_id = ? AND account_email = ?
         ORDER BY last_message_at DESC
         LIMIT ?`,
      )
        .bind(ctx.workspaceId, ctx.accountEmail, limit)
        .all<{
          id: string;
          subject: string | null;
          mailbox: string | null;
          first_message_at: string | null;
          last_message_at: string | null;
        }>();
      return { count: rows.results.length, threads: rows.results };
    },
  },
  {
    name: 'list_entities',
    description:
      'List structured items extracted from emails (invoices, payments, requests, etc.). Filter by action_required to find things needing a response.',
    inputSchema: {
      type: 'object',
      properties: {
        limit: { type: 'number', description: 'Max items (1-100, default 25).' },
        action_required: { type: 'boolean', description: 'Only items that need an action.' },
        entity_type: { type: 'string', description: 'Filter by entity_type (e.g. invoice, payment, request).' },
      },
      additionalProperties: false,
    },
    async handler(ctx, args) {
      const limit = clampLimit(args.limit, 25, 100);
      const conditions = ['workspace_id = ?', 'account_id = ?'];
      const binds: unknown[] = [ctx.workspaceId, ctx.accountId];
      if (args.action_required === true) {
        conditions.push('action_required = 1');
      }
      const entityType = str(args.entity_type);
      if (entityType) {
        conditions.push('entity_type = ?');
        binds.push(entityType);
      }
      binds.push(limit);
      const rows = await ctx.env.SKY_DB.prepare(
        `SELECT id, message_id, thread_id, entity_type, direction, counterparty_name, counterparty_email,
                amount_cents, currency, due_date, status, action_required, action_description, risk_level, extracted_at
         FROM email_entities
         WHERE ${conditions.join(' AND ')}
         ORDER BY extracted_at DESC
         LIMIT ?`,
      )
        .bind(...binds)
        .all<Record<string, unknown>>();
      return { count: rows.results.length, entities: rows.results };
    },
  },
  {
    name: 'list_calendar_events',
    description:
      'List calendar events ordered by start time. Defaults to upcoming events (from now). Useful for "what\'s on my calendar tomorrow".',
    inputSchema: {
      type: 'object',
      properties: {
        from: { type: 'string', description: 'ISO start bound (default: now).' },
        to: { type: 'string', description: 'ISO end bound (optional).' },
        limit: { type: 'number', description: 'Max events (1-100, default 25).' },
      },
      additionalProperties: false,
    },
    async handler(ctx, args) {
      const limit = clampLimit(args.limit, 25, 100);
      const from = str(args.from) || new Date().toISOString();
      const to = str(args.to);
      const conditions = ['workspace_id = ?', 'account_id = ?', 'start_at >= ?'];
      const binds: unknown[] = [ctx.workspaceId, ctx.accountId, from];
      if (to) {
        conditions.push('start_at <= ?');
        binds.push(to);
      }
      binds.push(limit);
      const rows = await ctx.env.SKY_DB.prepare(
        `SELECT id, title, description, location, start_at, end_at, all_day, status,
                organizer_email, organizer_name, attendees_json, calendar_name
         FROM calendar_events
         WHERE ${conditions.join(' AND ')}
         ORDER BY start_at ASC
         LIMIT ?`,
      )
        .bind(...binds)
        .all<Record<string, unknown>>();
      const events = rows.results.map((e) => ({
        ...e,
        attendees: safeJson<unknown[]>(e.attendees_json as string | null) ?? [],
        attendees_json: undefined,
      }));
      return { count: events.length, events };
    },
  },
  {
    name: 'list_imessages',
    description: 'List the most recent iMessage/SMS texts, newest first.',
    inputSchema: {
      type: 'object',
      properties: {
        limit: { type: 'number', description: 'Max messages (1-100, default 30).' },
        since: { type: 'string', description: 'ISO lower bound on sent_at (optional).' },
      },
      additionalProperties: false,
    },
    async handler(ctx, args) {
      const limit = clampLimit(args.limit, 30, 100);
      const since = str(args.since);
      const conditions = ['workspace_id = ?', 'account_id = ?'];
      const binds: unknown[] = [ctx.workspaceId, ctx.accountId];
      if (since) {
        conditions.push('sent_at >= ?');
        binds.push(since);
      }
      binds.push(limit);
      const rows = await ctx.env.SKY_DB.prepare(
        `SELECT id, sender, body_text, sent_at
         FROM imessage_messages
         WHERE ${conditions.join(' AND ')}
         ORDER BY sent_at DESC
         LIMIT ?`,
      )
        .bind(...binds)
        .all<{ id: string; sender: string | null; body_text: string; sent_at: string }>();
      return { count: rows.results.length, messages: rows.results };
    },
  },
  {
    name: 'get_briefing_data',
    description:
      'Combined snapshot for planning: upcoming calendar events, recent emails, recent iMessages, and open action items. Ideal for questions like "who should I call tomorrow" or "what needs my attention".',
    inputSchema: {
      type: 'object',
      properties: {
        hours_ahead: { type: 'number', description: 'Calendar look-ahead window in hours (default 48).' },
      },
      additionalProperties: false,
    },
    async handler(ctx, args) {
      const db = ctx.env.SKY_DB;
      const now = new Date();
      const hoursAhead = clampLimit(args.hours_ahead, 48, 24 * 14);
      const until = new Date(now.getTime() + hoursAhead * 3600 * 1000).toISOString();
      const nowIso = now.toISOString();

      const [events, recentEmails, recentMessages, openItems] = await Promise.all([
        db
          .prepare(
            `SELECT id, title, location, start_at, end_at, organizer_email, attendees_json
             FROM calendar_events
             WHERE workspace_id = ? AND account_id = ? AND start_at >= ? AND start_at <= ?
             ORDER BY start_at ASC LIMIT 25`,
          )
          .bind(ctx.workspaceId, ctx.accountId, nowIso, until)
          .all<Record<string, unknown>>(),
        db
          .prepare(
            `SELECT id, subject, sent_at, from_json
             FROM email_messages
             WHERE workspace_id = ? AND account_email = ?
             ORDER BY sent_at DESC LIMIT 15`,
          )
          .bind(ctx.workspaceId, ctx.accountEmail)
          .all<{ id: string; subject: string | null; sent_at: string | null; from_json: string | null }>(),
        db
          .prepare(
            `SELECT id, sender, body_text, sent_at
             FROM imessage_messages
             WHERE workspace_id = ? AND account_id = ?
             ORDER BY sent_at DESC LIMIT 15`,
          )
          .bind(ctx.workspaceId, ctx.accountId)
          .all<{ id: string; sender: string | null; body_text: string; sent_at: string }>(),
        db
          .prepare(
            `SELECT id, message_id, entity_type, counterparty_name, amount_cents, currency, due_date, action_description, risk_level
             FROM email_entities
             WHERE workspace_id = ? AND account_id = ? AND action_required = 1
             ORDER BY due_date IS NULL, due_date ASC, extracted_at DESC LIMIT 25`,
          )
          .bind(ctx.workspaceId, ctx.accountId)
          .all<Record<string, unknown>>(),
      ]);

      return {
        generated_at: nowIso,
        window_hours: hoursAhead,
        upcoming_events: events.results.map((e) => ({
          ...e,
          attendees: safeJson<unknown[]>(e.attendees_json as string | null) ?? [],
          attendees_json: undefined,
        })),
        recent_emails: recentEmails.results.map((m) => ({
          id: m.id,
          subject: m.subject ?? '(no subject)',
          sent_at: m.sent_at,
          from: formatAddresses(m.from_json),
        })),
        recent_imessages: recentMessages.results,
        open_action_items: openItems.results,
      };
    },
  },
];
