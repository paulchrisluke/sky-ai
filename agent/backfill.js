import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import dotenv from 'dotenv';
import { ImapFlow } from 'imapflow';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
dotenv.config({ path: path.join(__dirname, '.env') });

const REQUIRED = ['WORKER_INGEST_URL', 'APPLE_ID', 'APPLE_APP_PASSWORD'];
for (const key of REQUIRED) {
  if (!process.env[key]) {
    throw new Error(`Missing required env var: ${key}`);
  }
}

const args = parseArgs(process.argv.slice(2));
const since = args.since || process.env.BACKFILL_SINCE;
const until = args.until || process.env.BACKFILL_UNTIL || null;
const mailboxArg = args.mailboxes || process.env.BACKFILL_MAILBOXES || process.env.MAILBOXES || 'INBOX';
const batchSize = Number(args.batchSize || process.env.BACKFILL_BATCH_SIZE || '25');
const delayMs = Number(args.delayMs || process.env.BACKFILL_DELAY_MS || '250');
const workspaceId = process.env.WORKSPACE_ID || 'default';
const stateFile = path.resolve(__dirname, process.env.BACKFILL_STATE_FILE || '../data/backfill-state.json');

if (!since) {
  throw new Error('Missing --since=YYYY-MM-DD (or BACKFILL_SINCE in .env)');
}

const sinceDate = parseDateStrict(since, 'since');
const untilDate = until ? parseDateStrict(until, 'until') : null;
if (untilDate && untilDate < sinceDate) {
  throw new Error('--until must be on or after --since');
}

const mailboxes = mailboxArg
  .split(',')
  .map((x) => x.trim())
  .filter(Boolean);

const stateKey = `${since}${until ? `_${until}` : '_open'}`;
const state = loadState(stateFile);
state.runs ||= {};
state.runs[stateKey] ||= {};

const client = new ImapFlow({
  host: process.env.IMAP_HOST || 'imap.mail.me.com',
  port: Number(process.env.IMAP_PORT || '993'),
  secure: (process.env.IMAP_SECURE || 'true') === 'true',
  auth: {
    user: process.env.APPLE_ID,
    pass: process.env.APPLE_APP_PASSWORD
  },
  logger: false
});

async function main() {
  await client.connect();
  console.log('[backfill] IMAP connect OK');

  try {
    for (const mailbox of mailboxes) {
      await backfillMailbox(mailbox);
    }
  } finally {
    await client.logout().catch(() => {});
  }

  console.log('[backfill] complete');
}

async function backfillMailbox(mailbox) {
  await client.mailboxOpen(mailbox, { readOnly: true });
  console.log(`[backfill] mailboxOpen OK: ${mailbox}`);

  const criteria = untilDate
    ? { since: sinceDate, before: addDays(untilDate, 1) }
    : { since: sinceDate };

  const uids = await client.search(criteria, { uid: true });
  const sorted = [...uids].sort((a, b) => a - b);

  const mailboxState = (state.runs[stateKey][mailbox] ||= { lastUid: 0, processed: 0 });
  const remaining = sorted.filter((uid) => uid > Number(mailboxState.lastUid || 0));

  console.log(`[backfill] ${mailbox}: ${remaining.length} messages to process`);

  for (let i = 0; i < remaining.length; i += batchSize) {
    const batch = remaining.slice(i, i + batchSize);

    for (const uid of batch) {
      const msg = await client.fetchOne(
        String(uid),
        {
          uid: true,
          envelope: true,
          source: true,
          internalDate: true
        },
        { uid: true }
      );

      if (!msg) {
        mailboxState.lastUid = uid;
        continue;
      }

      await postToWorker({
        workspaceId,
        source: 'imap_backfill',
        mailbox,
        accountEmail: process.env.APPLE_ID,
        threadId: String(msg.envelope?.messageId || msg.uid),
        messageId: String(msg.envelope?.messageId || ''),
        uid: msg.uid,
        subject: msg.envelope?.subject || '',
        from: msg.envelope?.from || [],
        to: msg.envelope?.to || [],
        date: msg.internalDate ? new Date(msg.internalDate).toISOString() : null,
        rawRfc822: msg.source?.toString('utf8') || ''
      });

      mailboxState.lastUid = uid;
      mailboxState.processed = Number(mailboxState.processed || 0) + 1;
    }

    saveState(stateFile, state);
    console.log(`[backfill] ${mailbox}: processed ${mailboxState.processed}, lastUid=${mailboxState.lastUid}`);
    if (delayMs > 0) {
      await sleep(delayMs);
    }
  }
}

async function postToWorker(payload) {
  const headers = { 'content-type': 'application/json' };
  if (process.env.WORKER_API_KEY) {
    headers.authorization = `Bearer ${process.env.WORKER_API_KEY}`;
  }

  const res = await fetch(process.env.WORKER_INGEST_URL, {
    method: 'POST',
    headers,
    body: JSON.stringify(payload)
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Ingest failed (${res.status}): ${text.slice(0, 500)}`);
  }
}

function parseArgs(argv) {
  const out = {};
  for (const arg of argv) {
    if (!arg.startsWith('--')) continue;
    const [key, value] = arg.slice(2).split('=');
    if (!key) continue;
    out[key] = value ?? 'true';
  }
  return out;
}

function parseDateStrict(value, label) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    throw new Error(`Invalid ${label} date format, expected YYYY-MM-DD`);
  }
  const d = new Date(`${value}T00:00:00Z`);
  if (Number.isNaN(d.getTime())) {
    throw new Error(`Invalid ${label} date: ${value}`);
  }
  return d;
}

function addDays(date, days) {
  const d = new Date(date);
  d.setUTCDate(d.getUTCDate() + days);
  return d;
}

function loadState(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return {};
  }
}

function saveState(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(value, null, 2));
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

main().catch((error) => {
  console.error('[backfill] failed:', error instanceof Error ? error.message : String(error));
  process.exit(1);
});
