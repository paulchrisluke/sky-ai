export type JsonRecord = Record<string, unknown>;

export type IngestCoreEnv = {
  SKY_DB: D1Database;
};

type NormalizedAddress = {
  email: string;
  name: string | null;
};

type MailIngestCoreResult = {
  deduped: boolean;
  workspaceId: string;
  accountId: string;
  accountEmail: string;
  mailbox: string;
  threadId: string;
  messageId: string;
  sourceMessageKey: string;
  subject: string;
  snippet: string;
  sentAt: string | null;
  fromAddresses: NormalizedAddress[];
  toAddresses: NormalizedAddress[];
  direction: 'inbound' | 'outbound' | 'unknown';
};

export async function ingestCalendarEventsCore(
  env: IngestCoreEnv,
  payload: JsonRecord
): Promise<{ upserted: number; skipped: number }> {
  const workspaceId = stringOr(payload.workspaceId) || 'default';
  const accountId = stringOr(payload.accountId);
  const calendarId = stringOr(payload.calendarId);
  const calendarName = stringOr(payload.calendarName);
  const sourceProvider = stringOr(payload.sourceProvider) || 'calendar_icloud';
  const events = Array.isArray(payload.events) ? (payload.events as JsonRecord[]) : [];

  if (!accountId) throw new Error('accountId is required');
  if (!calendarId) throw new Error('calendarId is required');
  if (events.length === 0) return { upserted: 0, skipped: 0 };

  await ensureWorkspace(env, workspaceId);

  let upserted = 0;
  let skipped = 0;
  for (const event of events.slice(0, 500)) {
    const eventUid = stringOr(event.uid);
    const startAt = stringOr(event.startAt);
    const endAt = stringOr(event.endAt);
    if (!eventUid || !startAt || !endAt) {
      skipped += 1;
      continue;
    }

    await env.SKY_DB
      .prepare(
        `INSERT INTO calendar_events
         (id, workspace_id, account_id, calendar_id, calendar_name, event_uid,
          title, description, location, start_at, end_at, all_day, recurrence_rule,
          status, organizer_email, organizer_name, attendees_json, source_provider,
          raw_ical, synced_at, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
         ON CONFLICT(workspace_id, account_id, calendar_id, event_uid)
         DO UPDATE SET
           title = excluded.title,
           description = excluded.description,
           location = excluded.location,
           start_at = excluded.start_at,
           end_at = excluded.end_at,
           all_day = excluded.all_day,
           recurrence_rule = excluded.recurrence_rule,
           status = excluded.status,
           organizer_email = excluded.organizer_email,
           organizer_name = excluded.organizer_name,
           attendees_json = excluded.attendees_json,
           raw_ical = excluded.raw_ical,
           synced_at = CURRENT_TIMESTAMP,
           updated_at = CURRENT_TIMESTAMP`
      )
      .bind(
        crypto.randomUUID(),
        workspaceId,
        accountId,
        calendarId,
        calendarName,
        eventUid,
        stringOr(event.title),
        stringOr(event.description),
        stringOr(event.location),
        startAt,
        endAt,
        event.allDay === true ? 1 : 0,
        stringOr(event.recurrenceRule),
        stringOr(event.status) || 'confirmed',
        stringOr(event.organizerEmail),
        stringOr(event.organizerName),
        JSON.stringify(Array.isArray(event.attendees) ? event.attendees : []),
        sourceProvider,
        stringOr(event.rawIcal)
      )
      .run();

    upserted += 1;
  }

  return { upserted, skipped };
}

export async function ingestMailThreadCore(
  env: IngestCoreEnv,
  payload: JsonRecord
): Promise<MailIngestCoreResult> {
  const workspaceId = stringOr(payload.workspaceId) || 'default';
  const accountEmail = stringOr(payload.accountEmail) || 'unknown';
  const accountId = stringOr(payload.accountId) || accountEmail;
  const mailbox = stringOr(payload.mailbox) || 'INBOX';
  const threadExternalId = stringOr(payload.threadId);
  const providerUid = numberOr(payload.uid);
  const providerMessageId = stringOr(payload.messageId);
  const subject = decodeMimeHeaderWords(stringOr(payload.subject) || '');
  const sentAt = stringOr(payload.date);

  if (!threadExternalId) throw new Error('threadId is required');

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
    .prepare(`SELECT id FROM email_messages WHERE source_message_key = ? LIMIT 1`)
    .bind(sourceMessageKey)
    .first<{ id: string }>();

  if (existingMessage?.id) {
    const existingRow = await env.SKY_DB
      .prepare(
        `SELECT id, thread_id, subject, snippet, sent_at, from_json, to_json, direction
         FROM email_messages
         WHERE id = ?
         LIMIT 1`
      )
      .bind(existingMessage.id)
      .first<{
        id: string;
        thread_id: string;
        subject: string | null;
        snippet: string | null;
        sent_at: string | null;
        from_json: string | null;
        to_json: string | null;
        direction: string | null;
      }>();

    if (!existingRow) {
      throw new Error('deduped_message_missing');
    }

    return {
      deduped: true,
      workspaceId,
      accountId,
      accountEmail,
      mailbox,
      threadId: existingRow.thread_id,
      messageId: existingRow.id,
      sourceMessageKey,
      subject: existingRow.subject || '',
      snippet: existingRow.snippet || '',
      sentAt: existingRow.sent_at,
      fromAddresses: parseAddressJson(existingRow.from_json),
      toAddresses: parseAddressJson(existingRow.to_json),
      direction: validateDirection(existingRow.direction)
    };
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

  const messageId = crypto.randomUUID();
  const fromAddresses = normalizeAddresses(payload.from);
  const toAddresses = normalizeAddresses(payload.to);
  const direction = deriveMessageDirection(mailbox, fromAddresses, accountEmail);
  const snippet = buildSnippet(payload, subject);
  const rawSource = stringOr(payload.rawRfc822) || '';
  const rawSha256 = rawSource ? await sha256Hex(rawSource) : null;

  await env.SKY_DB
    .prepare(
      `INSERT INTO email_messages
       (id, workspace_id, thread_id, account_id, account_email, mailbox, provider_uid, provider_message_id, source_message_key, subject,
        sent_at, from_json, to_json, snippet, artifact_id, raw_sha256, direction, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)`
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
      null,
      rawSha256,
      direction
    )
    .run();

  await upsertParticipants(env, workspaceId, messageId, fromAddresses, 'from');
  await upsertParticipants(env, workspaceId, messageId, toAddresses, 'to');
  await updateThreadLastMessage(env, threadId, subject, sentAt);

  return {
    deduped: false,
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
  };
}

async function upsertEmailThread(
  env: IngestCoreEnv,
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
  if (!row?.id) throw new Error('Failed to upsert thread');
  return row.id;
}

async function updateThreadLastMessage(
  env: IngestCoreEnv,
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
  env: IngestCoreEnv,
  workspaceId: string,
  messageId: string,
  addresses: NormalizedAddress[],
  role: 'from' | 'to'
): Promise<void> {
  for (const addr of addresses) {
    await env.SKY_DB
      .prepare(
        `INSERT OR IGNORE INTO email_participants (id, workspace_id, email, display_name, created_at, updated_at)
         VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)`
      )
      .bind(crypto.randomUUID(), workspaceId, addr.email, addr.name)
      .run();

    const participant = await env.SKY_DB
      .prepare(`SELECT id FROM email_participants WHERE workspace_id = ? AND email = ? LIMIT 1`)
      .bind(workspaceId, addr.email)
      .first<{ id: string }>();

    if (!participant?.id) continue;

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

function parseAddressJson(value: string | null): NormalizedAddress[] {
  if (!value) return [];
  try {
    const parsed = JSON.parse(value) as unknown;
    if (!Array.isArray(parsed)) return [];
    return parsed
      .map((row) => {
        if (!row || typeof row !== 'object') return null;
        const email = String((row as Record<string, unknown>).email || '').trim().toLowerCase();
        if (!email) return null;
        const nameRaw = (row as Record<string, unknown>).name;
        const name = typeof nameRaw === 'string' && nameRaw.trim() ? nameRaw.trim() : null;
        return { email, name };
      })
      .filter((row): row is NormalizedAddress => row !== null);
  } catch {
    return [];
  }
}

function deriveMessageDirection(
  mailbox: string,
  fromAddresses: NormalizedAddress[],
  accountEmail: string
): 'inbound' | 'outbound' | 'unknown' {
  const mailboxLower = mailbox.toLowerCase();
  if (mailboxLower.includes('sent')) return 'outbound';

  const accountLower = accountEmail.toLowerCase();
  const fromMatch = fromAddresses.some((x) => x.email.toLowerCase() === accountLower);
  return fromMatch ? 'outbound' : 'inbound';
}

function normalizeAddresses(raw: unknown): NormalizedAddress[] {
  if (!Array.isArray(raw)) return [];
  return raw
    .map((entry) => {
      if (!entry || typeof entry !== 'object') return null;
      const value = entry as Record<string, unknown>;
      const email = String(value.address || value.email || '').trim().toLowerCase();
      if (!email) return null;
      const nameRaw = value.name;
      const name = typeof nameRaw === 'string' && nameRaw.trim() ? nameRaw.trim() : null;
      return { email, name };
    })
    .filter((entry): entry is NormalizedAddress => entry !== null);
}

function buildSnippet(payload: JsonRecord, subject: string): string {
  const fallback = stringOr(payload.snippet) || '';
  const raw = stringOr(payload.rawRfc822) || '';
  if (!raw) return `${subject}\n\n${fallback}`.trim().slice(0, 500);

  const lines = raw.split(/\r?\n/);
  const bodyStart = lines.findIndex((line) => line.trim() === '');
  const body = bodyStart >= 0 ? lines.slice(bodyStart + 1).join('\n') : raw;
  const plain = body
    .replace(/<[^>]+>/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();

  return `${subject}\n\n${plain || fallback}`.trim().slice(0, 500);
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
  const providerMessageId = (input.providerMessageId || '').trim().toLowerCase();
  if (providerMessageId) {
    return `${input.workspaceId}:${input.accountId}:${input.mailbox}:mid:${providerMessageId}`;
  }

  if (Number.isFinite(input.providerUid)) {
    return `${input.workspaceId}:${input.accountId}:${input.mailbox}:uid:${input.providerUid}`;
  }

  const sentAt = input.sentAt || 'unknown';
  const subject = (input.subject || '').trim().toLowerCase().slice(0, 120);
  return `${input.workspaceId}:${input.accountId}:${input.mailbox}:thread:${input.threadExternalId}:sent:${sentAt}:sub:${subject}`;
}

async function ensureWorkspace(env: IngestCoreEnv, workspaceId: string): Promise<void> {
  await env.SKY_DB
    .prepare(
      `INSERT OR IGNORE INTO workspaces (id, name, owner_user_id, created_at, updated_at)
       VALUES (?, ?, 'system', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)`
    )
    .bind(workspaceId, workspaceId)
    .run();
}

async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(input));
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, '0'))
    .join('');
}

function decodeMimeHeaderWords(value: string): string {
  return value.replace(/=\?([^?]+)\?([bBqQ])\?([^?]*)\?=/g, (_match, charset, encoding, encodedText) => {
    try {
      if (encoding.toLowerCase() === 'b') {
        const bytes = Uint8Array.from(atob(encodedText), (char) => char.charCodeAt(0));
        return new TextDecoder(charset).decode(bytes);
      }
      const qp = encodedText.replace(/_/g, ' ').replace(/=([0-9A-Fa-f]{2})/g, (_m: string, hex: string) => String.fromCharCode(Number.parseInt(hex, 16)));
      return new TextDecoder(charset).decode(Uint8Array.from(qp, (char) => char.charCodeAt(0)));
    } catch {
      return encodedText;
    }
  });
}

function stringOr(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function numberOr(value: unknown): number | null {
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (typeof value === 'string' && value.trim()) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
}

function validateDirection(value: unknown): 'inbound' | 'outbound' | 'unknown' {
  if (value === 'inbound' || value === 'outbound') return value;
  return 'unknown';
}
