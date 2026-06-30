import { createLocalJWKSet, jwtVerify } from 'jose';
import type { D1Database } from '../pipelineEvents';
import {
  authBaseUrl,
  mcpAudience,
  SKY_MCP_SCOPE,
  getAuthSession,
  type CloudflareAuthEnv,
} from '../betterAuth';

export class McpAuthError extends Error {
  statusCode: number;
  challenge: boolean;
  constructor(message: string, statusCode = 401, challenge = true) {
    super(message);
    this.name = 'McpAuthError';
    this.statusCode = statusCode;
    this.challenge = challenge;
  }
}

export interface McpAuthContext {
  userId: string;
  email: string;
  workspaceId: string;
  // Canonical connected_accounts.id (scopes calendar/iMessage/entities/memory).
  accountId: string;
  // Mailbox address (scopes email_threads/email_messages by account_email).
  accountEmail: string;
  scopes: string[];
}

/**
 * Authenticate an MCP request and resolve the caller's data scope.
 * Accepts a better-auth Bearer access token (JWT or opaque) or a cookie session,
 * then maps the user's email to a workspace via access_subject_permissions.
 */
export async function requireMcpUser(request: Request, env: CloudflareAuthEnv): Promise<McpAuthContext> {
  const db = env.SKY_DB;
  const baseUrl = authBaseUrl(env);
  const audiences = [mcpAudience(env)];

  let userId: string | null = null;
  let scopes: string[] = [];

  const authHeader = request.headers.get('authorization');
  if (authHeader?.startsWith('Bearer ')) {
    const token = authHeader.slice(7).trim();
    const verified = await verifyBearerToken(token, baseUrl, db, audiences);
    if (!verified) throw new McpAuthError('Invalid or expired token', 401, true);
    userId = verified.userId;
    scopes = verified.scopes;
  } else if (request.headers.get('cookie')) {
    const session = await getAuthSession(request, env);
    if (!session?.user?.id) throw new McpAuthError('Authentication required', 401, true);
    userId = session.user.id;
    scopes = [SKY_MCP_SCOPE];
  } else {
    throw new McpAuthError('Authentication required', 401, true);
  }

  if (!scopes.includes(SKY_MCP_SCOPE)) {
    throw new McpAuthError(`Token is missing the required '${SKY_MCP_SCOPE}' scope`, 403, false);
  }

  const userRow = await db
    .prepare('SELECT email FROM "user" WHERE id = ? LIMIT 1')
    .bind(userId)
    .first<{ email: string | null }>();
  if (!userRow?.email) throw new McpAuthError('User not found', 401, true);
  const email = userRow.email.toLowerCase();

  const scope = await resolveWorkspaceScope(db, email);
  if (!scope) {
    throw new McpAuthError(
      `No workspace access for ${email}. Ask an admin to grant access in access_subject_permissions.`,
      403,
      false,
    );
  }

  return {
    userId: userId as string,
    email,
    workspaceId: scope.workspaceId,
    accountId: scope.accountId,
    accountEmail: scope.accountEmail,
    scopes,
  };
}

async function resolveWorkspaceScope(
  db: D1Database,
  email: string,
): Promise<{ workspaceId: string; accountId: string; accountEmail: string } | null> {
  const perm = await db
    .prepare(
      `SELECT workspace_id, account_id
       FROM access_subject_permissions
       WHERE subject = ? AND status = 'active'
       ORDER BY (account_id = '*') ASC
       LIMIT 1`,
    )
    .bind(email)
    .first<{ workspace_id: string; account_id: string }>();

  if (!perm) return null;

  if (perm.account_id && perm.account_id !== '*') {
    const account = await db
      .prepare(`SELECT email FROM connected_accounts WHERE workspace_id = ? AND id = ? LIMIT 1`)
      .bind(perm.workspace_id, perm.account_id)
      .first<{ email: string | null }>();
    return {
      workspaceId: perm.workspace_id,
      accountId: perm.account_id,
      accountEmail: (account?.email ?? perm.account_id).toLowerCase(),
    };
  }

  // Wildcard grant — pick the first active connected account in the workspace.
  const account = await db
    .prepare(
      `SELECT id, email FROM connected_accounts WHERE workspace_id = ? AND status = 'active' ORDER BY created_at ASC LIMIT 1`,
    )
    .bind(perm.workspace_id)
    .first<{ id: string; email: string | null }>();

  if (!account?.id) return null;
  return {
    workspaceId: perm.workspace_id,
    accountId: account.id,
    accountEmail: (account.email ?? account.id).toLowerCase(),
  };
}

async function verifyBearerToken(
  token: string,
  baseUrl: string,
  db: D1Database,
  audiences: string[],
): Promise<{ userId: string; scopes: string[] } | null> {
  const jwtResult = await verifyJwtAccessToken(token, baseUrl, db, audiences);
  if (jwtResult) return jwtResult;
  return verifyOpaqueAccessToken(token, db);
}

async function verifyJwtAccessToken(
  token: string,
  baseUrl: string,
  db: D1Database,
  audiences: string[],
): Promise<{ userId: string; scopes: string[] } | null> {
  const keysResult = await db
    .prepare('SELECT id, publicKey, alg FROM jwks ORDER BY createdAt DESC')
    .bind()
    .all<{ id: string; publicKey: string; alg: string | null }>();
  const keys = keysResult.results ?? [];
  if (!keys.length) return null;

  const jwks = createLocalJWKSet({
    keys: keys.map((k) => ({
      ...(JSON.parse(k.publicKey) as Record<string, unknown>),
      kid: k.id,
      alg: k.alg ?? 'EdDSA',
    })),
  });

  try {
    const { payload } = await jwtVerify(token, jwks, { issuer: baseUrl, audience: audiences });
    if (typeof payload.sub !== 'string') return null;
    return { userId: payload.sub, scopes: parseScopeClaim(payload.scope) };
  } catch {
    return null;
  }
}

async function verifyOpaqueAccessToken(
  token: string,
  db: D1Database,
): Promise<{ userId: string; scopes: string[] } | null> {
  const hashed = await sha256Base64Url(token);
  const row = await db
    .prepare(
      `SELECT oat.userId, oat.expiresAt, oat.scopes, oc.disabled AS client_disabled
       FROM oauthAccessToken oat
       LEFT JOIN oauthClient oc ON oc.clientId = oat.clientId
       WHERE oat.token = ?
       LIMIT 1`,
    )
    .bind(hashed)
    .first<{ userId: string | null; expiresAt: number | null; scopes: string | null; client_disabled: number | null }>();

  if (!row?.userId || !row.expiresAt) return null;
  if (row.client_disabled) return null;
  const expiresAtMs = row.expiresAt * 1000;
  if (Number.isNaN(expiresAtMs) || expiresAtMs <= Date.now()) return null;

  return { userId: row.userId, scopes: parseTokenScopes(row.scopes) };
}

function parseScopeClaim(scopeClaim: unknown): string[] {
  if (typeof scopeClaim !== 'string') return [];
  return scopeClaim.split(' ').filter(Boolean);
}

function parseTokenScopes(scopes: string | null): string[] {
  if (!scopes) return [];
  try {
    const parsed = JSON.parse(scopes);
    return Array.isArray(parsed) ? parsed.filter((s): s is string => typeof s === 'string') : [];
  } catch {
    return scopes.split(' ').filter(Boolean);
  }
}

async function sha256Base64Url(value: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
  const bytes = new Uint8Array(digest);
  let bin = '';
  for (let i = 0; i < bytes.length; i += 1) bin += String.fromCharCode(bytes[i]);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
