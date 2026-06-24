import { sql } from 'drizzle-orm';
import { sqliteTable, integer, text } from 'drizzle-orm/sqlite-core';

// better-auth core + plugin tables. Column names mirror krabiclaw's schema so the
// drizzle adapter and the @better-auth/oauth-provider plugin resolve the same fields.
// Only the auth surface lives here; the rest of sky-ai stays on raw SQL.

export const user = sqliteTable('user', {
  id: text().primaryKey(),
  name: text().notNull(),
  email: text().notNull().unique(),
  emailVerified: integer({ mode: 'boolean' }).default(false).notNull(),
  image: text(),
  phoneNumber: text().unique(),
  phoneNumberVerified: integer({ mode: 'boolean' }).default(false).notNull(),
  role: text().default('user'),
  banned: integer({ mode: 'boolean' }).default(false),
  banReason: text(),
  banExpires: integer({ mode: 'timestamp' }),
  createdAt: integer({ mode: 'timestamp' }).default(sql`(unixepoch())`).notNull(),
  updatedAt: integer({ mode: 'timestamp' }).default(sql`(unixepoch())`).notNull(),
});

export const session = sqliteTable('session', {
  id: text().primaryKey(),
  expiresAt: integer({ mode: 'timestamp' }).notNull(),
  token: text().notNull().unique(),
  createdAt: integer({ mode: 'timestamp' }).default(sql`(unixepoch())`).notNull(),
  updatedAt: integer({ mode: 'timestamp' }).default(sql`(unixepoch())`).notNull(),
  ipAddress: text(),
  userAgent: text(),
  activeOrganizationId: text(),
  activeTeamId: text(),
  impersonatedBy: text(),
  userId: text().notNull().references(() => user.id, { onDelete: 'cascade' }),
});

export const account = sqliteTable('account', {
  id: text().primaryKey(),
  accountId: text().notNull(),
  providerId: text().notNull(),
  userId: text().notNull().references(() => user.id, { onDelete: 'cascade' }),
  accessToken: text(),
  refreshToken: text(),
  idToken: text(),
  expiresAt: integer({ mode: 'timestamp' }),
  accessTokenExpiresAt: integer({ mode: 'timestamp' }),
  refreshTokenExpiresAt: integer({ mode: 'timestamp' }),
  scope: text(),
  password: text(),
  createdAt: integer({ mode: 'timestamp' }).default(sql`(unixepoch())`).notNull(),
  updatedAt: integer({ mode: 'timestamp' }).default(sql`(unixepoch())`).notNull(),
});

export const verification = sqliteTable('verification', {
  id: text().primaryKey(),
  identifier: text().notNull(),
  value: text().notNull(),
  expiresAt: integer({ mode: 'timestamp' }).notNull(),
  createdAt: integer({ mode: 'timestamp' }).default(sql`(unixepoch())`).notNull(),
  updatedAt: integer({ mode: 'timestamp' }).default(sql`(unixepoch())`).notNull(),
});

export const jwks = sqliteTable('jwks', {
  id: text().primaryKey(),
  publicKey: text().notNull(),
  privateKey: text().notNull(),
  alg: text(),
  crv: text(),
  createdAt: integer({ mode: 'timestamp' }).notNull(),
  expiresAt: integer({ mode: 'timestamp' }),
});

export const organization = sqliteTable('organization', {
  id: text().primaryKey(),
  name: text().notNull(),
  slug: text().unique(),
  logo: text(),
  metadata: text(),
  createdAt: integer({ mode: 'timestamp' }).default(sql`(unixepoch())`).notNull(),
});

export const member = sqliteTable('member', {
  id: text().primaryKey(),
  organizationId: text().notNull().references(() => organization.id, { onDelete: 'cascade' }),
  userId: text().notNull().references(() => user.id, { onDelete: 'cascade' }),
  role: text().default('member').notNull(),
  createdAt: integer({ mode: 'timestamp' }).default(sql`(unixepoch())`).notNull(),
});

export const invitation = sqliteTable('invitation', {
  id: text().primaryKey(),
  organizationId: text().notNull().references(() => organization.id, { onDelete: 'cascade' }),
  email: text().notNull(),
  role: text(),
  status: text().default('pending').notNull(),
  expiresAt: integer({ mode: 'timestamp' }).notNull(),
  inviterId: text().notNull().references(() => user.id, { onDelete: 'cascade' }),
  createdAt: integer({ mode: 'timestamp' }).default(sql`(unixepoch())`).notNull(),
});

export const oauthClient = sqliteTable('oauthClient', {
  id: text().primaryKey(),
  clientId: text().notNull().unique(),
  clientSecret: text(),
  name: text().notNull(),
  redirectUris: text().notNull(),
  scopes: text().default('').notNull(),
  public: integer({ mode: 'boolean' }).default(false).notNull(),
  requirePkce: integer({ mode: 'boolean' }).default(true).notNull(),
  skipConsent: integer({ mode: 'boolean' }).default(false).notNull(),
  userId: text(),
  metadata: text(),
  disabled: integer({ mode: 'boolean' }).default(false).notNull(),
  createdAt: integer({ mode: 'timestamp' }).notNull(),
  updatedAt: integer({ mode: 'timestamp' }).notNull(),
  enableEndSession: integer({ mode: 'boolean' }),
  subjectType: text(),
  uri: text(),
  icon: text(),
  contacts: text(),
  tos: text(),
  policy: text(),
  softwareId: text(),
  softwareVersion: text(),
  softwareStatement: text(),
  postLogoutRedirectUris: text(),
  tokenEndpointAuthMethod: text(),
  grantTypes: text(),
  responseTypes: text(),
  type: text(),
  referenceId: text(),
});

export const oauthAccessToken = sqliteTable('oauthAccessToken', {
  id: text().primaryKey(),
  clientId: text().notNull(),
  userId: text(),
  token: text().notNull().unique(),
  scopes: text().default('').notNull(),
  expiresAt: integer({ mode: 'timestamp' }).notNull(),
  createdAt: integer({ mode: 'timestamp' }).notNull(),
  sessionId: text(),
  referenceId: text(),
  refreshId: text(),
});

export const oauthConsent = sqliteTable('oauthConsent', {
  id: text().primaryKey(),
  clientId: text().notNull(),
  userId: text().notNull(),
  scopes: text().default('').notNull(),
  createdAt: integer({ mode: 'timestamp' }).notNull(),
  updatedAt: integer({ mode: 'timestamp' }).notNull(),
  referenceId: text(),
});

export const oauthRefreshToken = sqliteTable('oauthRefreshToken', {
  id: text().primaryKey(),
  clientId: text().notNull(),
  userId: text(),
  token: text().notNull().unique(),
  scopes: text().default('').notNull(),
  accessTokenId: text(),
  expiresAt: integer({ mode: 'timestamp' }).notNull(),
  createdAt: integer({ mode: 'timestamp' }).notNull(),
  sessionId: text(),
  referenceId: text(),
  revoked: integer({ mode: 'boolean' }),
  authTime: integer({ mode: 'timestamp' }),
});

export const authSchema = {
  user,
  session,
  account,
  verification,
  jwks,
  organization,
  member,
  invitation,
  oauthClient,
  oauthAccessToken,
  oauthConsent,
  oauthRefreshToken,
};
