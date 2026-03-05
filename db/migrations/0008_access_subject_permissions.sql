CREATE TABLE IF NOT EXISTS access_subject_permissions (
  id TEXT PRIMARY KEY,
  subject TEXT NOT NULL,
  email TEXT,
  workspace_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'user',
  status TEXT NOT NULL DEFAULT 'active',
  metadata_json TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (workspace_id) REFERENCES workspaces(id)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_access_subject_permissions_unique
  ON access_subject_permissions(subject, workspace_id, account_id);

CREATE INDEX IF NOT EXISTS idx_access_subject_permissions_lookup
  ON access_subject_permissions(subject, workspace_id, status);
