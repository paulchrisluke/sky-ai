-- better-auth core + @better-auth/oauth-provider tables for ChatGPT MCP OAuth.
-- Ported from krabiclaw migrations/0001_initial.sql. These power the OAuth
-- authorization server (DCR, authorize, token, consent) and user sessions.

CREATE TABLE IF NOT EXISTS "user" (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  email TEXT NOT NULL UNIQUE,
  emailVerified INTEGER NOT NULL DEFAULT 0,
  image TEXT,
  phoneNumber TEXT UNIQUE,
  phoneNumberVerified INTEGER NOT NULL DEFAULT 0,
  role TEXT DEFAULT 'user',
  banned INTEGER DEFAULT 0,
  banReason TEXT,
  banExpires INTEGER,
  createdAt INTEGER NOT NULL DEFAULT (unixepoch()),
  updatedAt INTEGER NOT NULL DEFAULT (unixepoch())
);

CREATE TABLE IF NOT EXISTS "organization" (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  slug TEXT UNIQUE,
  logo TEXT,
  metadata TEXT,
  createdAt INTEGER NOT NULL DEFAULT (unixepoch())
);

CREATE TABLE IF NOT EXISTS "account" (
  id TEXT PRIMARY KEY,
  accountId TEXT NOT NULL,
  providerId TEXT NOT NULL,
  userId TEXT NOT NULL,
  accessToken TEXT,
  refreshToken TEXT,
  idToken TEXT,
  expiresAt INTEGER,
  accessTokenExpiresAt INTEGER,
  refreshTokenExpiresAt INTEGER,
  scope TEXT,
  password TEXT,
  createdAt INTEGER NOT NULL DEFAULT (unixepoch()),
  updatedAt INTEGER NOT NULL DEFAULT (unixepoch()),
  FOREIGN KEY (userId) REFERENCES user(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS "invitation" (
  id TEXT PRIMARY KEY,
  organizationId TEXT NOT NULL,
  email TEXT NOT NULL,
  role TEXT,
  status TEXT NOT NULL DEFAULT 'pending',
  expiresAt INTEGER NOT NULL,
  inviterId TEXT NOT NULL,
  createdAt INTEGER NOT NULL DEFAULT (unixepoch()),
  FOREIGN KEY (organizationId) REFERENCES organization(id) ON DELETE CASCADE,
  FOREIGN KEY (inviterId) REFERENCES user(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS "jwks" (
  id TEXT PRIMARY KEY,
  publicKey TEXT NOT NULL,
  privateKey TEXT NOT NULL,
  alg TEXT,
  crv TEXT,
  createdAt INTEGER NOT NULL,
  expiresAt INTEGER
);

CREATE TABLE IF NOT EXISTS "member" (
  id TEXT PRIMARY KEY,
  organizationId TEXT NOT NULL,
  userId TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'member',
  createdAt INTEGER NOT NULL DEFAULT (unixepoch()),
  FOREIGN KEY (organizationId) REFERENCES organization(id) ON DELETE CASCADE,
  FOREIGN KEY (userId) REFERENCES user(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS "session" (
  id TEXT PRIMARY KEY,
  expiresAt INTEGER NOT NULL,
  token TEXT NOT NULL UNIQUE,
  createdAt INTEGER NOT NULL DEFAULT (unixepoch()),
  updatedAt INTEGER NOT NULL DEFAULT (unixepoch()),
  ipAddress TEXT,
  userAgent TEXT,
  activeOrganizationId TEXT,
  activeTeamId TEXT,
  impersonatedBy TEXT,
  userId TEXT NOT NULL,
  FOREIGN KEY (userId) REFERENCES user(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS "verification" (
  id TEXT PRIMARY KEY,
  identifier TEXT NOT NULL,
  value TEXT NOT NULL,
  expiresAt INTEGER NOT NULL,
  createdAt INTEGER NOT NULL DEFAULT (unixepoch()),
  updatedAt INTEGER NOT NULL DEFAULT (unixepoch())
);

CREATE TABLE IF NOT EXISTS "oauthClient" (
  id TEXT PRIMARY KEY,
  clientId TEXT NOT NULL UNIQUE,
  clientSecret TEXT,
  name TEXT NOT NULL,
  redirectUris TEXT NOT NULL,
  scopes TEXT NOT NULL DEFAULT '',
  public INTEGER NOT NULL DEFAULT 0,
  requirePkce INTEGER NOT NULL DEFAULT 1,
  skipConsent INTEGER NOT NULL DEFAULT 0,
  userId TEXT,
  metadata TEXT,
  disabled INTEGER NOT NULL DEFAULT 0,
  createdAt INTEGER NOT NULL,
  updatedAt INTEGER NOT NULL,
  enableEndSession INTEGER,
  subjectType TEXT,
  uri TEXT,
  icon TEXT,
  contacts TEXT,
  tos TEXT,
  policy TEXT,
  softwareId TEXT,
  softwareVersion TEXT,
  softwareStatement TEXT,
  postLogoutRedirectUris TEXT,
  tokenEndpointAuthMethod TEXT,
  grantTypes TEXT,
  responseTypes TEXT,
  type TEXT,
  referenceId TEXT
);

CREATE TABLE IF NOT EXISTS "oauthAccessToken" (
  id TEXT PRIMARY KEY,
  clientId TEXT NOT NULL,
  userId TEXT,
  token TEXT NOT NULL UNIQUE,
  scopes TEXT NOT NULL DEFAULT '',
  expiresAt INTEGER NOT NULL,
  createdAt INTEGER NOT NULL,
  sessionId TEXT,
  referenceId TEXT,
  refreshId TEXT
);

CREATE TABLE IF NOT EXISTS "oauthConsent" (
  id TEXT PRIMARY KEY,
  clientId TEXT NOT NULL,
  userId TEXT NOT NULL,
  scopes TEXT NOT NULL DEFAULT '',
  createdAt INTEGER NOT NULL,
  updatedAt INTEGER NOT NULL,
  referenceId TEXT,
  UNIQUE(clientId, userId)
);

CREATE TABLE IF NOT EXISTS "oauthRefreshToken" (
  id TEXT PRIMARY KEY,
  clientId TEXT NOT NULL,
  userId TEXT,
  token TEXT NOT NULL UNIQUE,
  scopes TEXT NOT NULL DEFAULT '',
  accessTokenId TEXT,
  expiresAt INTEGER NOT NULL,
  createdAt INTEGER NOT NULL,
  sessionId TEXT,
  referenceId TEXT,
  revoked INTEGER,
  authTime INTEGER
);

-- Idempotency cache so ChatGPT's duplicate authorization_code token requests
-- both receive the same successful response.
CREATE TABLE IF NOT EXISTS token_exchange_cache (
  code TEXT PRIMARY KEY,
  state TEXT NOT NULL DEFAULT 'pending',
  response_body TEXT NOT NULL DEFAULT '',
  http_status INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL
);
