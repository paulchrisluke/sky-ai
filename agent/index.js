import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import dotenv from 'dotenv';
import { ImapFlow } from 'imapflow';
import nodemailer from 'nodemailer';
import WebSocket from 'ws';
import { syncCalendars } from './calendar.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
dotenv.config({ path: path.join(__dirname, '.env') });

const REQUIRED = ['WORKER_WS_URL', 'WORKER_API_KEY', 'APPLE_ID', 'APPLE_APP_PASSWORD'];
for (const key of REQUIRED) {
  if (!process.env[key]) {
    throw new Error(`Missing required env var: ${key}`);
  }
}

const MAILBOXES = (process.env.MAILBOXES || 'INBOX,Sent Messages')
  .split(',')
  .map((x) => x.trim())
  .filter(Boolean);

const WORKSPACE_ID = process.env.WORKSPACE_ID || 'default';
const STATE_FILE = path.resolve(__dirname, process.env.STATE_FILE || '../data/mailbox-state.json');
const WS_PING_INTERVAL_MS = 30_000;
const CALENDAR_SYNC_INTERVAL_MS = 15 * 60 * 1000;
const RECONNECT_MIN_MS = 5_000;
const RECONNECT_MAX_MS = 60_000;
const OUTBOUND_POLL_INTERVAL_MS = 15_000;

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

function redact(value) {
  if (!value) return value;
  let text = String(value);
  const secrets = [process.env.APPLE_APP_PASSWORD, process.env.WORKER_API_KEY].filter(Boolean);
  for (const secret of secrets) {
    if (!secret) continue;
    text = text.split(secret).join('[REDACTED]');
  }
  return text;
}

function describeError(error) {
  if (!(error instanceof Error)) return redact(String(error));
  const parts = [`message=${redact(error.message)}`];
  if (error.code) parts.push(`code=${redact(error.code)}`);
  if (error.responseStatus) parts.push(`responseStatus=${redact(error.responseStatus)}`);
  if (error.responseText) parts.push(`responseText=${redact(error.responseText)}`);
  if (error.executedCommand) parts.push(`executedCommand=${redact(error.executedCommand)}`);
  if (error.serverResponseCode) parts.push(`serverResponseCode=${redact(error.serverResponseCode)}`);
  if (error.status) parts.push(`status=${redact(error.status)}`);
  return parts.join(' | ');
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

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function buildWsUrl() {
  const base = process.env.WORKER_WS_URL.replace(/\/+$/, '');
  const url = new URL(`${base}/agents/blawby-agent/primary`);
  url.searchParams.set('token', process.env.WORKER_API_KEY);
  return url.toString();
}

function connectWebSocket() {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(buildWsUrl());
    const onError = (error) => {
      ws.removeAllListeners('open');
      reject(error);
    };
    ws.once('error', onError);
    ws.once('open', () => {
      ws.removeListener('error', onError);
      resolve(ws);
    });
  });
}

function sendWs(ws, payload) {
  if (ws.readyState !== WebSocket.OPEN) {
    throw new Error('websocket_not_open');
  }
  ws.send(JSON.stringify(payload));
}

async function syncAllMailboxes(client, account, accountState, ws, state) {
  for (const mailbox of MAILBOXES) {
    await client.mailboxOpen(mailbox, { readOnly: true });

    const lastUid = Number(accountState.mailboxes[mailbox]?.lastUid || 0);
    const uidNext = Number(client.mailbox?.uidNext || 1);
    let maxSeenUid = lastUid;
    const startUid = Math.max(1, lastUid + 1);

    if (startUid >= uidNext) {
      accountState.mailboxes[mailbox] = { lastUid, syncedAt: new Date().toISOString() };
      continue;
    }

    const range = `${startUid}:*`;
    try {
      for await (const msg of client.fetch(
        range,
        {
          uid: true,
          envelope: true,
          source: true,
          internalDate: true
        },
        { uid: true }
      )) {
        maxSeenUid = Math.max(maxSeenUid, msg.uid);
        sendWs(ws, {
          type: 'email',
          workspaceId: WORKSPACE_ID,
          source: 'imap',
          mailbox,
          accountId: account.id,
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
      if (!/Invalid message number/i.test(text)) throw error;
    }

    accountState.mailboxes[mailbox] = { lastUid: maxSeenUid, syncedAt: new Date().toISOString() };
    saveState(state);
  }
}

async function runImapIdleLoop(account, state, ws, stopSignal) {
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
  console.log(`[email-sync] imap connected for ${account.email}`);
  try {
    while (!stopSignal.stopped && ws.readyState === WebSocket.OPEN) {
      await syncAllMailboxes(client, account, accountState, ws, state);
      await client.mailboxOpen('INBOX', { readOnly: true });
      console.log(`[email-sync] entering idle for ${account.email}`);
      await Promise.race([
        client.idle(),
        stopSignal.closed
      ]);
    }
  } finally {
    await client.logout().catch(() => {});
  }
}

async function watchAccount(account, state) {
  let backoffMs = RECONNECT_MIN_MS;

  while (true) {
    const stopSignal = {
      stopped: false,
      closeResolve: () => {}
    };
    stopSignal.closed = new Promise((resolve) => {
      stopSignal.closeResolve = resolve;
    });

    let ws;
    let pingTimer;
    let calendarTimer;
    try {
      ws = await connectWebSocket();
      backoffMs = RECONNECT_MIN_MS;
      console.log('[email-sync] websocket connected');

      ws.on('message', (raw) => {
        try {
          const payload = JSON.parse(String(raw));
          if (payload.type === 'pong') return;
        } catch {
          // ignore non-json payloads
        }
      });

      ws.on('close', () => {
        stopSignal.stopped = true;
        stopSignal.closeResolve();
      });
      ws.on('error', () => {
        stopSignal.stopped = true;
        stopSignal.closeResolve();
      });

      pingTimer = setInterval(() => {
        if (ws.readyState !== WebSocket.OPEN) return;
        ws.send(JSON.stringify({ type: 'ping' }));
      }, WS_PING_INTERVAL_MS);

      const emitCalendarPayload = async (payload) => {
        sendWs(ws, payload);
      };

      await syncCalendars(account, WORKSPACE_ID, emitCalendarPayload);
      calendarTimer = setInterval(() => {
        syncCalendars(account, WORKSPACE_ID, emitCalendarPayload).catch((error) => {
          console.error(`[calendar-sync] periodic sync failed: ${describeError(error)}`);
        });
      }, CALENDAR_SYNC_INTERVAL_MS);

      await runImapIdleLoop(account, state, ws, stopSignal);
    } catch (error) {
      console.error(`[email-sync] watch loop error: ${describeError(error)}`);
    } finally {
      stopSignal.stopped = true;
      stopSignal.closeResolve();
      if (pingTimer) clearInterval(pingTimer);
      if (calendarTimer) clearInterval(calendarTimer);
      if (ws && ws.readyState === WebSocket.OPEN) {
        ws.close();
      }
      saveState(state);
    }

    await sleep(backoffMs);
    backoffMs = Math.min(backoffMs * 2, RECONNECT_MAX_MS);
  }
}

function workerHeaders() {
  const headers = { 'content-type': 'application/json' };
  if (process.env.WORKER_API_KEY) headers.authorization = `Bearer ${process.env.WORKER_API_KEY}`;
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

let outboundRunning = false;
async function processOutboundQueue() {
  if (outboundRunning) return;
  outboundRunning = true;
  try {
    const nextUrl = process.env.WORKER_OUTBOUND_NEXT_URL || '';
    const resultUrl = process.env.WORKER_OUTBOUND_RESULT_URL || '';
    if (!nextUrl || !resultUrl) return;

    while (true) {
      const nextRes = await fetch(nextUrl, { method: 'GET', headers: workerHeaders() });
      if (!nextRes.ok) throw new Error(`Failed to poll outbound queue (${nextRes.status})`);

      const nextJson = await nextRes.json();
      const item = nextJson?.item;
      if (!item) return;

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
  } finally {
    outboundRunning = false;
  }
}

async function main() {
  const state = loadState();
  setInterval(() => {
    processOutboundQueue().catch((error) => {
      console.error(`[email-sync] outbound queue error: ${describeError(error)}`);
    });
  }, OUTBOUND_POLL_INTERVAL_MS);

  await watchAccount(ACCOUNTS[0], state);
}

main().catch((error) => {
  console.error(`[email-sync] fatal error: ${describeError(error)}`);
  process.exit(1);
});
