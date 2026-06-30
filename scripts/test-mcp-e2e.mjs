#!/usr/bin/env node
/**
 * Full MCP E2E test — no ChatGPT, no Mac app.
 *
 * 1. (optional) seed fixture data in D1
 * 2. Dynamic client registration + PKCE OAuth (better-auth)
 * 3. Grant MCP workspace permission for the test user email
 * 4. initialize + tools/list + tools/call against /mcp
 *
 * Usage:
 *   MCP_BASE_URL=https://sky-ai-api.<sub>.workers.dev node scripts/test-mcp-e2e.mjs
 *   MCP_BASE_URL=... node scripts/test-mcp-e2e.mjs --seed
 *   MCP_BASE_URL=... node scripts/test-mcp-e2e.mjs --skip-seed   # default if already seeded
 */

import { spawnSync } from 'node:child_process';
import { randomBytes, createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const argv = process.argv.slice(2);
const shouldSeed = argv.includes('--seed');
const rootDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

const BASE_URL = (
  argv.includes('--base-url') ? argv[argv.indexOf('--base-url') + 1] : process.env.MCP_BASE_URL ?? 'http://127.0.0.1:8787'
).replace(/\/$/, '');

const JOBS_BASE_URL = (
  process.env.JOBS_BASE_URL ?? BASE_URL.replace('sky-ai-api', 'sky-ai-jobs')
).replace(/\/$/, '');

const MCP_URL = `${BASE_URL}/mcp`;
const MCP_VERSION = process.env.MCP_PROTOCOL_VERSION ?? '2025-11-25';
const WORKSPACE_ID = process.env.MCP_WORKSPACE_ID ?? 'default';
const ACCOUNT_ID = (process.env.MCP_ACCOUNT_ID ?? 'skylerbaird@me.com').toLowerCase();
const D1_DB = process.env.D1_DB ?? 'sky-ai-dev';
const WRANGLER_CONFIG = process.env.WRANGLER_CONFIG ?? 'wrangler.api.toml';
const REDIRECT_URI = process.env.MCP_REDIRECT_URI ?? 'http://127.0.0.1:9999/callback';

let exitCode = 0;
function pass(label) {
  console.log(`  ✅ ${label}`);
}
function fail(label, detail) {
  console.error(`  ❌ ${label}`);
  if (detail !== undefined) {
    console.error('     ', typeof detail === 'object' ? JSON.stringify(detail, null, 2) : detail);
  }
  exitCode = 1;
}
function section(label) {
  console.log(`\n── ${label} ──`);
}

/** Fixture scenario: Alice Q3 planning call tomorrow (~2pm). */
const FIXTURE = {
  callTitle: 'Call with Alice — Q3 planning',
  emailSubject: 'Call tomorrow about Q3 planning',
  imessageSnippet: 'Still good for our call tomorrow?',
  counterparty: 'Alice Chen',
  counterpartyEmail: 'alice@example.com',
};

function assertTomorrowCallFromBriefing(briefingData) {
  const events = briefingData.upcoming_events ?? [];
  const match = events.find(
    (e) =>
      typeof e.title === 'string' &&
      e.title.includes('Alice') &&
      e.title.toLowerCase().includes('q3'),
  );
  if (!match) {
    fail('Briefing lists tomorrow call with Alice / Q3', { upcoming_events: events });
    return null;
  }

  const startAt = Date.parse(String(match.start_at));
  const now = Date.now();
  const horizon = now + 48 * 3600 * 1000;
  if (!Number.isFinite(startAt) || startAt <= now || startAt > horizon) {
    fail('Tomorrow call start_at is within the next 48 hours', match);
    return null;
  }

  pass(`Briefing upcoming event: "${match.title}" at ${match.start_at}`);
  return match;
}

function assertTomorrowCallContext(briefingData) {
  const emails = briefingData.recent_emails ?? [];
  const emailHit = emails.find(
    (m) => typeof m.subject === 'string' && m.subject.toLowerCase().includes('q3'),
  );
  if (emailHit) pass(`Briefing email context: "${emailHit.subject}" from ${emailHit.from ?? 'unknown'}`);
  else fail('Briefing includes Q3 planning email thread', { recent_emails: emails });

  const messages = briefingData.recent_imessages ?? [];
  const imHit = messages.find(
    (m) => typeof m.body_text === 'string' && m.body_text.toLowerCase().includes('call tomorrow'),
  );
  if (imHit) pass(`Briefing iMessage context: "${imHit.body_text}" from ${imHit.sender ?? 'unknown'}`);
  else fail('Briefing includes iMessage about call tomorrow', { recent_imessages: messages });

  const actions = briefingData.open_action_items ?? [];
  const actionHit = actions.find(
    (a) =>
      typeof a.action_description === 'string' &&
      a.action_description.toLowerCase().includes('q3'),
  );
  if (actionHit) pass(`Briefing action item: "${actionHit.action_description}"`);
  else fail('Briefing includes open action about Q3 call', { open_action_items: actions });
}

function printTomorrowCallAnswer(event, briefingData) {
  if (!event) return;
  const who =
    event.organizer_name ||
    event.organizer_email ||
    FIXTURE.counterparty;
  console.log('\n  📋 MCP answer (what ChatGPT would see):');
  console.log(`     Tomorrow's call: ${event.title}`);
  console.log(`     When: ${event.start_at}`);
  console.log(`     With: ${who}`);
  const email = (briefingData.recent_emails ?? [])[0];
  if (email?.subject) console.log(`     Related email: ${email.subject}`);
  const im = (briefingData.recent_imessages ?? [])[0];
  if (im?.body_text) console.log(`     Related text: ${im.body_text}`);
}

function pkcePair() {
  const verifier = randomBytes(32).toString('base64url');
  const challenge = createHash('sha256').update(verifier).digest('base64url');
  return { verifier, challenge };
}

function escapeSql(value) {
  return String(value).replace(/'/g, "''");
}

function grantMcpPermission(email) {
  const permId = `perm_${WORKSPACE_ID}_${ACCOUNT_ID}_${email.replace(/[^a-zA-Z0-9]/g, '').slice(0, 24)}`;
  const sql = `
INSERT INTO access_subject_permissions
  (id, subject, email, workspace_id, account_id, role, status, created_at, updated_at)
VALUES
  ('${escapeSql(permId)}', '${escapeSql(email)}', '${escapeSql(email)}', '${escapeSql(WORKSPACE_ID)}', '${escapeSql(ACCOUNT_ID)}', 'admin', 'active', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
ON CONFLICT(subject, workspace_id, account_id)
DO UPDATE SET
  email = excluded.email,
  role = excluded.role,
  status = excluded.status,
  updated_at = CURRENT_TIMESTAMP;
`;
  const result = spawnSync(
    'npx',
    ['wrangler', 'd1', 'execute', D1_DB, '--config', WRANGLER_CONFIG, '--remote', '--command', sql],
    { cwd: rootDir, encoding: 'utf8' },
  );
  if (result.status !== 0) {
    throw new Error(result.stderr || result.stdout || 'wrangler d1 execute failed');
  }
}

function seedFixture() {
  const result = spawnSync(path.join(rootDir, 'scripts/seed-mcp-fixture.sh'), [], {
    cwd: rootDir,
    encoding: 'utf8',
    stdio: 'inherit',
  });
  if (result.status !== 0) {
    throw new Error('seed-mcp-fixture.sh failed');
  }
}

async function processEmbeddingJobs() {
  const apiKey = process.env.WORKER_API_KEY;
  if (!apiKey) {
    fail('WORKER_API_KEY required for vector search test (set in env or .dev.vars)');
    return false;
  }

  const res = await fetch(`${JOBS_BASE_URL}/jobs/embeddings/process`, {
    method: 'POST',
    headers: { authorization: `Bearer ${apiKey}` },
  });
  const body = await res.json().catch(() => ({}));
  if (res.status !== 200 || !body.ok) {
    fail('jobs/embeddings/process', body);
    return false;
  }
  if (Number(body.processed) < 1) {
    fail('jobs/embeddings/process indexed at least one fixture chunk', body);
    return false;
  }
  pass(`jobs/embeddings/process -> processed=${body.processed}`);
  return true;
}

class CookieJar {
  #cookies = new Map();

  store(response) {
    for (const header of response.headers.getSetCookie?.() ?? []) {
      const [pair] = header.split(';');
      const idx = pair.indexOf('=');
      if (idx === -1) continue;
      this.#cookies.set(pair.slice(0, idx).trim(), pair.slice(idx + 1).trim());
    }
  }

  header() {
    if (!this.#cookies.size) return '';
    return Array.from(this.#cookies.entries())
      .map(([k, v]) => `${k}=${v}`)
      .join('; ');
  }
}

async function apiFetch(jar, pathname, { method = 'GET', json, headers = {} } = {}) {
  const res = await fetch(`${BASE_URL}${pathname}`, {
    method,
    headers: {
      origin: BASE_URL,
      ...(json ? { 'content-type': 'application/json' } : {}),
      ...(jar.header() ? { cookie: jar.header() } : {}),
      ...headers,
    },
    body: json ? JSON.stringify(json) : undefined,
    redirect: 'manual',
  });
  jar.store(res);
  let body = null;
  const text = await res.text();
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    body = text;
  }
  return { status: res.status, body, headers: res.headers, location: res.headers.get('location') };
}

async function mcpCall(token, payload, extraHeaders = {}) {
  const res = await fetch(MCP_URL, {
    method: 'POST',
    headers: {
      authorization: `Bearer ${token}`,
      'content-type': 'application/json',
      ...extraHeaders,
    },
    body: JSON.stringify(payload),
  });
  const body = await res.json();
  return { status: res.status, body };
}

async function main() {
  console.log(`MCP E2E against ${BASE_URL}`);
  console.log(`workspace=${WORKSPACE_ID} account=${ACCOUNT_ID}`);

  if (shouldSeed) {
    section('Seed fixture data');
    seedFixture();
    pass('Fixture rows inserted (workspace, mail, calendar, iMessage, memory chunks)');

    section('Vectorize fixture chunks (jobs worker)');
    await processEmbeddingJobs();
  } else {
    section('Seed fixture data');
    console.log('  ⏭  Skipped (pass --seed to load mock data + vectorize)');
  }

  section('OAuth client registration');
  const reg = await fetch(`${BASE_URL}/api/auth/oauth2/register`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      client_name: 'sky-ai-mcp-e2e',
      redirect_uris: [REDIRECT_URI],
      token_endpoint_auth_method: 'none',
      grant_types: ['authorization_code', 'refresh_token'],
      response_types: ['code'],
      scope: 'openid offline_access sky',
    }),
  }).then((r) => r.json());

  if (!reg.client_id) fail('Dynamic client registration', reg);
  else pass(`Registered client ${reg.client_id}`);

  const { verifier, challenge } = pkcePair();
  const baseQuery = new URLSearchParams({
    response_type: 'code',
    client_id: reg.client_id,
    redirect_uri: REDIRECT_URI,
    scope: 'openid offline_access sky',
    code_challenge: challenge,
    code_challenge_method: 'S256',
  }).toString();

  section('Sign up test user');
  const jar = new CookieJar();
  const testEmail = `mcp-e2e-${Date.now()}@example.com`;
  const testPassword = `E2E-${randomBytes(12).toString('base64url')}!aA1`;

  const signup = await apiFetch(jar, '/api/auth/sign-up/email', {
    method: 'POST',
    json: { email: testEmail, password: testPassword, name: 'MCP E2E Test' },
  });
  if (signup.status !== 200 || !signup.body?.user?.id) fail('Sign up test user', signup.body);
  else pass(`Signed up ${testEmail}`);

  section('Grant MCP workspace permission');
  try {
    grantMcpPermission(testEmail);
    pass(`Granted access_subject_permissions for ${testEmail}`);
  } catch (error) {
    fail('Grant MCP workspace permission', error instanceof Error ? error.message : error);
    process.exit(1);
  }

  section('OAuth authorize + consent');
  const authorize = await apiFetch(jar, `/api/auth/oauth2/authorize?${baseQuery}`);
  const consentPath = authorize.body?.url;
  if (!consentPath) fail('Authorize returned signed consent URL', authorize.body);
  else pass('Authorize returned signed consent URL');

  const signedQuery = consentPath.split('?')[1];
  const consent = await apiFetch(jar, '/api/auth/oauth2/consent', {
    method: 'POST',
    json: { accept: true, oauth_query: signedQuery },
  });
  const callbackUrl = consent.body?.url;
  if (!callbackUrl) fail('Consent did not return callback URL', consent.body);
  else pass('Consent accepted');

  const code = new URL(callbackUrl).searchParams.get('code');
  if (!code) {
    fail('Authorization code missing from callback URL', callbackUrl);
    process.exit(exitCode || 1);
  }

  const tokenRes = await fetch(`${BASE_URL}/api/auth/oauth2/token`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'authorization_code',
      code,
      redirect_uri: REDIRECT_URI,
      client_id: reg.client_id,
      code_verifier: verifier,
    }),
  });
  const tokenBody = await tokenRes.json();
  const accessToken = tokenBody.access_token;
  if (!accessToken) fail('Token exchange', tokenBody);
  else pass('Received access_token');

  section('MCP initialize + tools/list');
  const init = await mcpCall(
    accessToken,
    { jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: MCP_VERSION } },
  );
  if (init.body?.result?.serverInfo?.name === 'sky-ai-mcp') pass(`initialize -> ${init.body.result.serverInfo.name}`);
  else fail('initialize', init.body);

  const tools = await mcpCall(
    accessToken,
    { jsonrpc: '2.0', id: 2, method: 'tools/list', params: {} },
    { 'mcp-protocol-version': MCP_VERSION },
  );
  const toolNames = tools.body?.result?.tools?.map((t) => t.name) ?? [];
  if (toolNames.length >= 5) pass(`tools/list -> ${toolNames.join(', ')}`);
  else fail('tools/list', tools.body);

  section('MCP tools/call — tomorrow call scenario');
  const briefing = await mcpCall(
    accessToken,
    {
      jsonrpc: '2.0',
      id: 3,
      method: 'tools/call',
      params: { name: 'get_briefing_data', arguments: { hours_ahead: 48 } },
    },
    { 'mcp-protocol-version': MCP_VERSION },
  );
  const briefingData = briefing.body?.result?.structuredContent;
  if (briefing.status !== 200 || !briefingData?.generated_at) {
    fail('get_briefing_data', briefing.body);
  } else {
    pass(
      `get_briefing_data -> events=${briefingData.upcoming_events?.length ?? 0}, emails=${briefingData.recent_emails?.length ?? 0}, imessages=${briefingData.recent_imessages?.length ?? 0}, actions=${briefingData.open_action_items?.length ?? 0}`,
    );

    if (shouldSeed) {
      const tomorrowCall = assertTomorrowCallFromBriefing(briefingData);
      assertTomorrowCallContext(briefingData);
      printTomorrowCallAnswer(tomorrowCall, briefingData);
    } else {
      console.log('  ⏭  Content assertions skipped (pass --seed for tomorrow-call checks)');
    }
  }

  const calendar = await mcpCall(
    accessToken,
    {
      jsonrpc: '2.0',
      id: 4,
      method: 'tools/call',
      params: {
        name: 'list_calendar_events',
        arguments: { limit: 10 },
      },
    },
    { 'mcp-protocol-version': MCP_VERSION },
  );
  const calendarData = calendar.body?.result?.structuredContent;
  if (calendar.status === 200 && Array.isArray(calendarData?.events)) {
    if (shouldSeed) {
      const calMatch = calendarData.events.find((e) => e.title === FIXTURE.callTitle);
      if (calMatch) pass(`list_calendar_events -> "${calMatch.title}" at ${calMatch.start_at}`);
      else fail(`list_calendar_events includes "${FIXTURE.callTitle}"`, calendarData.events);
    } else {
      pass(`list_calendar_events -> count=${calendarData.events.length}`);
    }
  } else {
    fail('list_calendar_events', calendar.body);
  }

  const threads = await mcpCall(
    accessToken,
    {
      jsonrpc: '2.0',
      id: 5,
      method: 'tools/call',
      params: { name: 'list_threads', arguments: { limit: 5 } },
    },
    { 'mcp-protocol-version': MCP_VERSION },
  );
  const threadPayload = threads.body?.result?.structuredContent;
  if (threads.status === 200 && threadPayload) {
    if (shouldSeed) {
      const threadHit = (threadPayload.threads ?? []).find((t) => t.subject === FIXTURE.emailSubject);
      if (threadHit) pass(`list_threads -> "${threadHit.subject}"`);
      else fail(`list_threads includes "${FIXTURE.emailSubject}"`, threadPayload.threads);
    } else if (typeof threadPayload.count === 'number') {
      pass(`list_threads -> count=${threadPayload.count}`);
    } else {
      fail('list_threads', threads.body);
    }
  } else {
    fail('list_threads', threads.body);
  }

  const search = await mcpCall(
    accessToken,
    {
      jsonrpc: '2.0',
      id: 6,
      method: 'tools/call',
      params: {
        name: 'search_messages',
        arguments: { query: 'call tomorrow Q3 planning with Alice', limit: 5 },
      },
    },
    { 'mcp-protocol-version': MCP_VERSION },
  );
  const searchPayload = search.body?.result?.structuredContent;
  if (search.status === 200 && searchPayload) {
    if (shouldSeed) {
      const hit = (searchPayload.results ?? []).find(
        (r) =>
          r.message_id === 'fixture-msg-1' ||
          (typeof r.subject === 'string' && r.subject.includes('Q3 planning')),
      );
      if (hit) {
        pass(
          `search_messages -> "${hit.subject ?? hit.excerpt?.slice(0, 40)}" (score=${Number(hit.score ?? 0).toFixed(3)})`,
        );
      } else {
        fail('search_messages finds Alice Q3 tomorrow email', searchPayload);
      }
    } else if (typeof searchPayload.count === 'number') {
      pass(`search_messages -> count=${searchPayload.count}`);
    } else {
      fail('search_messages', search.body);
    }
  } else {
    fail('search_messages', search.body);
  }

  console.log(`\nDone${exitCode ? ' with failures' : ''}.`);
  if (!shouldSeed && exitCode === 0) {
    console.log('Tip: re-run with --seed if briefing/tools returned empty counts.');
  }
  process.exit(exitCode);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
