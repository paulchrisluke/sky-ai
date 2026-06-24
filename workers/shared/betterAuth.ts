import { betterAuth } from 'better-auth';
import { drizzleAdapter } from 'better-auth/adapters/drizzle';
import { admin, jwt, organization } from 'better-auth/plugins';
import { oauthProvider } from '@better-auth/oauth-provider';
import { drizzle } from 'drizzle-orm/d1';
import type { D1Database } from '../shared/pipelineEvents';
import { authSchema, organization as organizationTable, member as memberTable } from './authSchema';

export interface CloudflareAuthEnv {
  SKY_DB: D1Database;
  BETTER_AUTH_SECRET: string;
  BETTER_AUTH_URL?: string;
  GOOGLE_CLIENT_ID?: string;
  GOOGLE_CLIENT_SECRET?: string;
  [key: string]: unknown;
}

/** Scope that grants access to the sky-ai MCP surface. */
export const SKY_MCP_SCOPE = 'sky';

/** Public URL ChatGPT uses for OAuth + MCP discovery, normalized without trailing slash. */
export function authBaseUrl(env: CloudflareAuthEnv): string {
  const url = env.BETTER_AUTH_URL?.replace(/\/$/, '');
  if (!url) throw new Error('BETTER_AUTH_URL is not configured');
  return url;
}

/** Canonical MCP resource audience for issued access tokens. */
export function mcpAudience(env: CloudflareAuthEnv): string {
  return `${authBaseUrl(env)}/mcp`;
}

// Cache the auth instance per D1 binding — safe for the Worker lifecycle.
const authCache = new WeakMap<D1Database, unknown>();

export function createAuth(env: CloudflareAuthEnv) {
  const d1 = env.SKY_DB;

  const cached = authCache.get(d1);
  if (cached) return cached as ReturnType<typeof betterAuth>;

  const db = drizzle(d1 as unknown as Parameters<typeof drizzle>[0], { schema: authSchema });
  const baseUrl = authBaseUrl(env);

  const instance = betterAuth({
    baseURL: baseUrl,
    basePath: '/api/auth',
    secret: env.BETTER_AUTH_SECRET,
    database: drizzleAdapter(db, {
      provider: 'sqlite',
      schema: authSchema,
    }),
    databaseHooks: {
      user: {
        create: {
          after: async (createdUser) => {
            // Give every signup a personal organization so the organization/admin
            // plugins have an owning org. Data scoping for MCP is handled separately
            // via the access_subject_permissions table (mapped by email).
            const now = new Date();
            const orgId = `org-${createdUser.id}`;
            try {
              await db.batch([
                db.insert(organizationTable).values({
                  id: orgId,
                  name: createdUser.name ?? createdUser.email ?? 'My Workspace',
                  slug: orgId,
                  createdAt: now,
                }).onConflictDoNothing(),
                db.insert(memberTable).values({
                  id: `member-${orgId}`,
                  organizationId: orgId,
                  userId: createdUser.id,
                  role: 'owner',
                  createdAt: now,
                }).onConflictDoNothing(),
              ]);
            } catch (err) {
              console.error('auth_create_org_failed', orgId, err);
              throw err;
            }
          },
        },
      },
    },
    emailAndPassword: {
      enabled: true,
      // No email provider wired in sky-ai yet; keep verification off so the
      // email/password fallback works without an SMTP/Resend dependency.
      requireEmailVerification: false,
      minPasswordLength: 8,
      maxPasswordLength: 128,
      autoSignIn: true,
    },
    plugins: [
      jwt({
        jwt: {
          // Must match authorization_servers advertised in oauth-protected-resource.
          issuer: baseUrl,
        },
      }),
      oauthProvider({
        loginPage: '/oauth/login',
        consentPage: '/oauth/consent',
        selectAccount: {
          page: '/oauth/login',
          shouldRedirect: async () => false,
        },
        allowDynamicClientRegistration: true,
        allowUnauthenticatedClientRegistration: true,
        scopes: ['openid', 'offline_access', SKY_MCP_SCOPE],
        clientRegistrationDefaultScopes: ['openid', 'offline_access', SKY_MCP_SCOPE],
        validAudiences: [mcpAudience(env)],
        silenceWarnings: {
          oauthAuthServerConfig: true,
          openidConfig: true,
        },
      }),
      organization(),
      admin({
        adminRoles: ['admin'],
        defaultRole: 'user',
      }),
    ],
    socialProviders:
      env.GOOGLE_CLIENT_ID && env.GOOGLE_CLIENT_SECRET
        ? {
            google: {
              clientId: env.GOOGLE_CLIENT_ID,
              clientSecret: env.GOOGLE_CLIENT_SECRET,
              prompt: 'select_account',
            },
          }
        : undefined,
    session: {
      expiresIn: 60 * 60 * 24 * 7,
      updateAge: 60 * 60 * 24,
    },
    account: {
      accountLinking: {
        enabled: true,
        trustedProviders: ['google'],
      },
    },
  });

  authCache.set(d1, instance);
  return instance;
}

export type SkyAuth = ReturnType<typeof createAuth>;

/** Resolve the current cookie session (used by the consent page + MCP cookie fallback). */
export async function getAuthSession(request: Request, env: CloudflareAuthEnv) {
  return createAuth(env).api.getSession({ headers: request.headers });
}
