ALTER TABLE tasks ADD COLUMN account_id TEXT;
ALTER TABLE tasks ADD COLUMN source_message_id TEXT;
ALTER TABLE tasks ADD COLUMN confidence_score REAL NOT NULL DEFAULT 0.5;
ALTER TABLE tasks ADD COLUMN review_state TEXT NOT NULL DEFAULT 'needs_review';
ALTER TABLE tasks ADD COLUMN owner TEXT;

CREATE INDEX IF NOT EXISTS idx_tasks_workspace_account_status_due
  ON tasks(workspace_id, account_id, status, due_at);

CREATE TABLE IF NOT EXISTS decisions (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  source_message_id TEXT,
  thread_id TEXT,
  decision_text TEXT NOT NULL,
  owner TEXT,
  confidence_score REAL NOT NULL DEFAULT 0.5,
  review_state TEXT NOT NULL DEFAULT 'needs_review',
  status TEXT NOT NULL DEFAULT 'open',
  metadata_json TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (workspace_id) REFERENCES workspaces(id)
);

CREATE INDEX IF NOT EXISTS idx_decisions_workspace_account_status
  ON decisions(workspace_id, account_id, status, created_at DESC);

CREATE TABLE IF NOT EXISTS followups (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  source_message_id TEXT,
  thread_id TEXT,
  followup_text TEXT NOT NULL,
  owner TEXT,
  due_at TEXT,
  confidence_score REAL NOT NULL DEFAULT 0.5,
  review_state TEXT NOT NULL DEFAULT 'needs_review',
  status TEXT NOT NULL DEFAULT 'open',
  metadata_json TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (workspace_id) REFERENCES workspaces(id)
);

CREATE INDEX IF NOT EXISTS idx_followups_workspace_account_status_due
  ON followups(workspace_id, account_id, status, due_at);

CREATE TABLE IF NOT EXISTS message_extractions (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  source_message_id TEXT NOT NULL,
  extractor_version TEXT NOT NULL,
  status TEXT NOT NULL,
  summary_json TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (workspace_id) REFERENCES workspaces(id)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_message_extractions_unique
  ON message_extractions(workspace_id, account_id, source_message_id);

CREATE TABLE IF NOT EXISTS model_audit_logs (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  source TEXT NOT NULL,
  model_name TEXT NOT NULL,
  input_json TEXT,
  output_json TEXT,
  success INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (workspace_id) REFERENCES workspaces(id)
);

CREATE INDEX IF NOT EXISTS idx_model_audit_workspace_account_created
  ON model_audit_logs(workspace_id, account_id, created_at DESC);
