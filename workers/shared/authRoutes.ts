import {
  createAuth,
  authBaseUrl,
  mcpAudience,
  SKY_MCP_SCOPE,
  type CloudflareAuthEnv,
} from './betterAuth';
import { renderLoginPage, renderConsentPage } from './oauthPages';

const JSON_HEADERS: Record<string, string> = {
  'content-type': 'application/json',
  'access-control-allow-origin': '*',
};

// Security headers for the OAuth UI pages — match krabiclaw's /oauth/** rules.
const OAUTH_PAGE_HEADERS: Record<string, string> = {
  'content-type': 'text/html; charset=utf-8',
  'cache-control': 'no-store',
  'content-security-policy': "frame-ancestors 'none'",
  'x-frame-options': 'DENY',
};

/**
 * Handles all better-auth OAuth-provider surfaces:
 *   - /.well-known/oauth-protected-resource  (RFC 9728 discovery for the MCP resource)
 *   - /.well-known/oauth-authorization-server
 *   - /.well-known/openid-configuration
 *   - /api/auth/oauth2/token  (idempotent authorization_code exchange for ChatGPT)
 *   - /api/auth/*             (DCR, authorize, consent, session, social callback, ...)
 *
 * Returns null when the request is not an auth/discovery route so the caller can
 * continue its own routing.
 */
export async function handleAuthRoutes(
  request: Request,
  env: CloudflareAuthEnv,
): Promise<Response | null> {
  const url = new URL(request.url);
  const path = url.pathname;

  if (request.method === 'GET' && path === '/.well-known/oauth-protected-resource') {
    return jsonResponse(
      {
        resource: mcpAudience(env),
        authorization_servers: [authBaseUrl(env)],
        bearer_methods_supported: ['header'],
        scopes_supported: ['openid', 'offline_access', SKY_MCP_SCOPE],
      },
      { 'cache-control': 'public, max-age=3600' },
    );
  }

  if (request.method === 'GET' && path === '/.well-known/oauth-authorization-server') {
    const auth = createAuth(env);
    // Call the plugin endpoint directly — HTTP self-subrequests time out in Workers.
    const metadata = await (auth.api as unknown as {
      getOAuthServerConfig(args: { request: Request; asResponse: boolean }): Promise<unknown>;
    }).getOAuthServerConfig({
      request: new Request(`${authBaseUrl(env)}/.well-known/oauth-authorization-server`),
      asResponse: false,
    });
    return jsonResponse(metadata, { 'cache-control': 'public, max-age=3600' });
  }

  if (request.method === 'GET' && path === '/.well-known/openid-configuration') {
    const auth = createAuth(env);
    const metadata = await (auth.api as unknown as {
      getOpenIdConfig(args: { request: Request; asResponse: boolean }): Promise<unknown>;
    }).getOpenIdConfig({
      request: new Request(`${authBaseUrl(env)}/.well-known/openid-configuration`),
      asResponse: false,
    });
    return jsonResponse(metadata, { 'cache-control': 'public, max-age=3600' });
  }

  if (request.method === 'GET' && path === '/oauth/login') {
    return new Response(
      renderLoginPage({ googleEnabled: Boolean(env.GOOGLE_CLIENT_ID && env.GOOGLE_CLIENT_SECRET) }),
      { headers: OAUTH_PAGE_HEADERS },
    );
  }

  if (request.method === 'GET' && path === '/oauth/consent') {
    return new Response(renderConsentPage(), { headers: OAUTH_PAGE_HEADERS });
  }

  if (request.method === 'POST' && path === '/api/auth/oauth2/token') {
    return handleTokenExchange(request, env);
  }

  if (path === '/api/auth' || path.startsWith('/api/auth/')) {
    return createAuth(env).handler(request);
  }

  return null;
}

/**
 * Wraps authorization_code exchanges so ChatGPT's two concurrent token requests
 * both succeed: the first claims the code, the rest poll for the cached response.
 */
async function handleTokenExchange(request: Request, env: CloudflareAuthEnv): Promise<Response> {
  const auth = createAuth(env);
  const rawBody = await request.text();
  const params = new URLSearchParams(rawBody);
  const code = params.get('code');
  const grantType = params.get('grant_type');

  const buildRequest = () =>
    new Request(request.url, { method: 'POST', headers: request.headers, body: rawBody });

  if (grantType !== 'authorization_code' || !code) {
    return auth.handler(buildRequest());
  }

  const db = env.SKY_DB;
  const now = new Date().toISOString();
  const expiresAt = new Date(Date.now() + 90_000).toISOString();

  // Best-effort prune of expired entries.
  db.prepare('DELETE FROM token_exchange_cache WHERE expires_at < ?').bind(now).run().catch(() => null);

  // Atomic claim — first concurrent request wins (changes === 1).
  const insertResult = await db
    .prepare(
      `INSERT OR IGNORE INTO token_exchange_cache (code, state, response_body, http_status, created_at, expires_at)
       VALUES (?, 'pending', '', 0, ?, ?)`,
    )
    .bind(code, now, expiresAt)
    .run();

  const claimed = Number(insertResult.meta?.changes ?? 0) === 1;

  if (!claimed) {
    for (let i = 0; i < 12; i += 1) {
      await new Promise((resolve) => setTimeout(resolve, 250));
      const cached = await db
        .prepare(`SELECT response_body, http_status FROM token_exchange_cache WHERE code = ? AND state = 'done'`)
        .bind(code)
        .first<{ response_body: string; http_status: number }>();
      if (cached) {
        return new Response(cached.response_body, {
          status: cached.http_status,
          headers: { 'content-type': 'application/json' },
        });
      }
    }
    console.error('[oauth_token] idempotency wait timed out, attempting direct exchange');
  }

  const res = await auth.handler(buildRequest());
  const responseBody = await res.text();

  await db
    .prepare(`UPDATE token_exchange_cache SET state = 'done', response_body = ?, http_status = ? WHERE code = ?`)
    .bind(responseBody, res.status, code)
    .run()
    .catch((err: unknown) => console.error('[oauth_token] failed to store exchange result', err));

  return new Response(responseBody, { status: res.status, headers: res.headers });
}

function jsonResponse(payload: unknown, extraHeaders: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(payload), {
    headers: { ...JSON_HEADERS, ...extraHeaders },
  });
}
