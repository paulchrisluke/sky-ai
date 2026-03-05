import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import dotenv from 'dotenv';
import { ImapFlow } from 'imapflow';
import nodemailer from 'nodemailer';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
dotenv.config({ path: path.join(__dirname, '.env') });

const REQUIRED = ['WORKER_INGEST_URL', 'APPLE_ID', 'APPLE_APP_PASSWORD'];
for (const key of REQUIRED) {
  if (!process.env[key]) {
    throw new Error(`Missing required env var: ${key}`);
  }
}

const POLL_INTERVAL_MS = Number(process.env.POLL_INTERVAL_MS || '30000');
const MAILBOXES = (process.env.MAILBOXES || 'INBOX,Sent Messages')
  .split(',')
  .map((x) => x.trim())
  .filter(Boolean);

const STATE_FILE = path.resolve(__dirname, process.env.STATE_FILE || '../data/mailbox-state.json');
const ACCOUNTS = [
  {
    id: sanitizeAccountId(process.env.APPLE_ID),
    email: process.env.APPLE_ID,
    password: process.env.APPLE_APP_PASSWORD
  }
];

function sanitizeAccountId(email) {
  return email.toLowerCase().replace(/[^a-z0-9]/g, '_');
}

function loadState() {
  try {
    return JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
  } catch {
    return { accounts: {} };
  }
}

function saveState(state) {
  const dir = path.dirname(STATE_FILE);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));
}

async function postToWorker(payload) {
  const headers = { 'content-type': 'application/json' };
  if (process.env.WORKER_API_KEY) {
    headers['authorization'] = `Bearer ${process.env.WORKER_API_KEY}`;
  }

  const res = await fetch(process.env.WORKER_INGEST_URL, {
    method: 'POST',
    headers,
    body: JSON.stringify(payload)
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Worker ingest failed (${res.status}): ${text.slice(0, 400)}`);
  }
}

function workerHeaders() {
  const headers = { 'content-type': 'application/json' };
  if (process.env.WORKER_API_KEY) {
    headers['authorization'] = `Bearer ${process.env.WORKER_API_KEY}`;
  }
  return headers;
}

const smtpTransport = nodemailer.createTransport({
  host: process.env.SMTP_HOST || 'smtp.mail.me.com',
  port: Number(process.env.SMTP_PORT || '587'),
  secure: (process.env.SMTP_SECURE || 'false') === 'true',
  auth: {
    user: process.env.APPLE_ID,
    pass: process.env.APPLE_APP_PASSWORD
  }
});

async function syncAccount(account, state) {
  const client = new ImapFlow({
    host: process.env.IMAP_HOST || 'imap.mail.me.com',
    port: Number(process.env.IMAP_PORT || '993'),
    secure: (process.env.IMAP_SECURE || 'true') === 'true',
    auth: {
      user: account.email,
      pass: account.password
    },
    logger: false
  });

  const accountState = (state.accounts[account.id] ||= { mailboxes: {} });

  await client.connect();
  try {
    for (const mailbox of MAILBOXES) {
      await client.mailboxOpen(mailbox, { readOnly: true });

      const lastUid = Number(accountState.mailboxes[mailbox]?.lastUid || 0);
      const uidNext = Number(client.mailbox?.uidNext || 1);
      let maxSeenUid = lastUid;
      const startUid = Math.max(1, lastUid + 1);

      // iCloud IMAP returns "Invalid message number" if FETCH range starts past uidNext.
      if (startUid >= uidNext) {
        accountState.mailboxes[mailbox] = { lastUid, syncedAt: new Date().toISOString() };
        continue;
      }

      const range = `${startUid}:*`;

      try {
        for await (const msg of client.fetch(range, {
          uid: true,
          envelope: true,
          source: true,
          internalDate: true
        })) {
          maxSeenUid = Math.max(maxSeenUid, msg.uid);
          await postToWorker({
            source: 'imap',
            mailbox,
            accountEmail: account.email,
            threadId: String(msg.envelope?.messageId || msg.uid),
            uid: msg.uid,
            subject: msg.envelope?.subject || '',
            from: msg.envelope?.from || [],
            to: msg.envelope?.to || [],
            date: msg.internalDate ? new Date(msg.internalDate).toISOString() : null,
            rawRfc822: msg.source?.toString('utf8') || ''
          });
        }
      } catch (error) {
        const text = error instanceof Error ? error.message : String(error);
        if (!/Invalid message number/i.test(text)) {
          throw error;
        }
      }

      accountState.mailboxes[mailbox] = { lastUid: maxSeenUid, syncedAt: new Date().toISOString() };
    }
  } finally {
    await client.logout().catch(() => {});
  }
}

async function run() {
  const state = loadState();

  for (const account of ACCOUNTS) {
    await syncAccount(account, state);
  }

  await processOutboundQueue();
  saveState(state);
  console.log(`[email-sync] sync complete at ${new Date().toISOString()}`);
}

async function processOutboundQueue() {
  const nextUrl = process.env.WORKER_OUTBOUND_NEXT_URL || process.env.WORKER_INGEST_URL.replace('/ingest/mail-thread', '/mail/outbound/next');
  const resultUrl =
    process.env.WORKER_OUTBOUND_RESULT_URL || process.env.WORKER_INGEST_URL.replace('/ingest/mail-thread', '/mail/outbound/result');

  while (true) {
    const nextRes = await fetch(nextUrl, { method: 'GET', headers: workerHeaders() });
    if (!nextRes.ok) {
      throw new Error(`Failed to poll outbound queue (${nextRes.status})`);
    }

    const nextJson = await nextRes.json();
    const item = nextJson?.item;
    if (!item) {
      return;
    }

    try {
      await smtpTransport.sendMail({
        from: process.env.APPLE_ID,
        to: item.to,
        subject: item.subject,
        text: item.text || undefined,
        html: item.html || undefined
      });

      await fetch(resultUrl, {
        method: 'POST',
        headers: workerHeaders(),
        body: JSON.stringify({ id: item.id, status: 'sent' })
      });
    } catch (error) {
      await fetch(resultUrl, {
        method: 'POST',
        headers: workerHeaders(),
        body: JSON.stringify({
          id: item.id,
          status: 'failed',
          error: error instanceof Error ? error.message : String(error)
        })
      });
    }
  }
}

async function loop() {
  while (true) {
    try {
      await run();
    } catch (error) {
      console.error('[email-sync] sync error', error instanceof Error ? error.message : String(error));
    }

    await new Promise((resolve) => setTimeout(resolve, POLL_INTERVAL_MS));
  }
}

loop();
