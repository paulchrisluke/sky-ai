-- Extend accounts in place to represent connected account profiles.
ALTER TABLE accounts ADD COLUMN provider TEXT NOT NULL DEFAULT 'email_icloud';
ALTER TABLE accounts ADD COLUMN identifier TEXT;
ALTER TABLE accounts ADD COLUMN display_name TEXT;
ALTER TABLE accounts ADD COLUMN credentials_encrypted TEXT;
ALTER TABLE accounts ADD COLUMN config_json TEXT NOT NULL DEFAULT '{}';
ALTER TABLE accounts ADD COLUMN onboarding_complete INTEGER NOT NULL DEFAULT 0;
ALTER TABLE accounts ADD COLUMN last_synced_at TEXT;

-- Backfill new profile fields from existing columns.
UPDATE accounts
SET identifier = COALESCE(identifier, CASE WHEN email IS NOT NULL AND trim(email) != '' THEN lower(email) ELSE id END),
    display_name = COALESCE(display_name, label)
WHERE identifier IS NULL OR display_name IS NULL;

-- Compatibility alias for newer code paths.
DROP VIEW IF EXISTS connected_accounts;
CREATE VIEW connected_accounts AS
SELECT
  id,
  workspace_id,
  label,
  email,
  status,
  created_at,
  updated_at,
  provider,
  identifier,
  display_name,
  credentials_encrypted,
  config_json,
  onboarding_complete,
  last_synced_at
FROM accounts;

-- Ensure prod has a default workspace row before mailbox onboarding.
INSERT OR IGNORE INTO workspaces (id, name, status, timezone, created_at, updated_at)
VALUES ('default', 'Skyler Baird', 'active', 'America/Chicago', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP);
