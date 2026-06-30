#!/usr/bin/env node
/**
 * MCP OAuth smoke test for sky-ai-api.
 *
 * Verifies the discovery -> unauthenticated 401 challenge -> Dynamic Client
 * Registration chain that ChatGPT walks when adding the connector. If a Bearer
 * token is supplied (the one ChatGPT received), it also exercises initialize +
 * tools/list.
 *
 * Usage:
 *   node scripts/test-mcp-oauth.mjs --base-url http://127.0.0.1:8787
 *   MCP_BASE_URL=https://sky-ai-api.<sub>.workers.dev node scripts/test-mcp-oauth.mjs
 *   MCP_BEARER_TOKEN=eyJ... node scripts/test-mcp-oauth.mjs --base-url https://...
 */

const argv = process.argv.slice(2);
const baseFromArg = argv.includes('--base-url') ? argv[argv.indexOf('--base-url') + 1] : null;
const BASE_URL = (baseFromArg ?? process.env.MCP_BASE_URL ?? 'http://127.0.0.1:8787').replace(/\/$/, '');

const MCP_URL = `${BASE_URL}/mcp`;
const REGISTER_URL = `${BASE_URL}/api/auth/oauth2/register`;
const MCP_VERSION = process.env.MCP_PROTOCOL_VERSION ?? '2025-11-25';

function pass(label) {
  console.log(`  \u2705 ${label}`);
}
function fail(label, detail) {
  console.error(`  \u274c ${label}`);
  if (detail !== undefined) console.error('     ', typeof detail === 'object' ? JSON.stringify(detail) : detail);
  process.exitCode = 1;
}
function section(label) {
  console.log(`\n\u2500\u2500 ${label} \u2500\u2500`);
}

async function getJson(url, headers = {}) {
  const res = await fetch(url, { headers });
  let body = null;
  try {
    body = await res.json();
  } catch {
    body = null;
  }
  return { status: res.status, headers: res.headers, body };
}

async function postJson(url, payload, headers = {}) {
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...headers },
    body: JSON.stringify(payload),
  });
  let body = null;
  try {
    body = await res.json();
  } catch {
    body = null;
  }
  return { status: res.status, headers: res.headers, body };
}

async function main() {
  console.log(`Testing MCP OAuth flow against ${BASE_URL}`);

  // 1. Discovery
  section('Discovery');
  const pr = await getJson(`${BASE_URL}/.well-known/oauth-protected-resource`);
  if (pr.body?.authorization_servers?.[0] === BASE_URL) pass('oauth-protected-resource issuer matches');
  else fail('oauth-protected-resource issuer mismatch', pr.body);
  if (pr.body?.resource === MCP_URL) pass(`resource = ${pr.body.resource}`);
  else fail('protected-resource.resource mismatch', pr.body?.resource);

  const as = await getJson(`${BASE_URL}/.well-known/oauth-authorization-server`);
  if (as.body?.issuer === BASE_URL) pass(`authorization-server issuer = ${as.body.issuer}`);
  else fail('authorization-server issuer mismatch', as.body?.issuer);
  if (as.body?.code_challenge_methods_supported?.includes('S256')) pass('S256 PKCE advertised');
  else fail('S256 PKCE missing', as.body?.code_challenge_methods_supported);

  // 2. Unauthenticated 401 + challenge
  section('Unauthenticated request');
  const unauth = await postJson(MCP_URL, { jsonrpc: '2.0', id: 1, method: 'tools/list', params: {} });
  if (unauth.status === 401) pass('401 without Bearer token');
  else fail('Expected 401 without token', unauth.status);
  const wwwAuth = unauth.headers.get('www-authenticate') ?? '';
  if (wwwAuth.includes('resource_metadata')) pass('WWW-Authenticate has resource_metadata');
  else fail('WWW-Authenticate missing resource_metadata', wwwAuth);

  // 3. Dynamic Client Registration
  section('Dynamic Client Registration');
  const reg = await postJson(REGISTER_URL, {
    client_name: 'sky-ai-mcp-test',
    redirect_uris: [`${BASE_URL}/callback`],
    token_endpoint_auth_method: 'none',
    grant_types: ['authorization_code', 'refresh_token'],
    response_types: ['code'],
    scope: 'openid offline_access sky',
  });
  if ((reg.status === 200 || reg.status === 201) && reg.body?.client_id) pass(`Registered client: ${reg.body.client_id}`);
  else fail('DCR failed', reg.body);

  // 4. Optional authenticated calls
  const token = process.env.MCP_BEARER_TOKEN;
  if (token) {
    section('Authenticated MCP (MCP_BEARER_TOKEN)');
    const init = await postJson(
      MCP_URL,
      { jsonrpc: '2.0', id: 2, method: 'initialize', params: { protocolVersion: MCP_VERSION } },
      { authorization: `Bearer ${token}` },
    );
    if (init.body?.result?.serverInfo?.name) pass(`initialize -> ${init.body.result.serverInfo.name}`);
    else fail('initialize failed', init.body);

    const list = await postJson(
      MCP_URL,
      { jsonrpc: '2.0', id: 3, method: 'tools/list', params: {} },
      { authorization: `Bearer ${token}`, 'mcp-protocol-version': MCP_VERSION },
    );
    const tools = list.body?.result?.tools;
    if (Array.isArray(tools) && tools.length) pass(`tools/list -> ${tools.map((t) => t.name).join(', ')}`);
    else fail('tools/list returned no tools', list.body);
  } else {
    section('Authenticated MCP');
    console.log('  \u23ed  Skipped (set MCP_BEARER_TOKEN to exercise initialize + tools/list)');
  }

  console.log(`\nDone${process.exitCode ? ' with failures' : ''}.`);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
