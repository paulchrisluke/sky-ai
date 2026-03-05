CREATE TABLE IF NOT EXISTS email_threads (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL,
  account_email TEXT NOT NULL,
  mailbox TEXT NOT NULL,
  thread_external_id TEXT NOT NULL,
  subject TEXT,
  first_message_at TEXT,
  last_message_at TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (workspace_id) REFERENCES workspaces(id)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_email_threads_unique_external
  ON email_threads(workspace_id, account_email, mailbox, thread_external_id);

CREATE INDEX IF NOT EXISTS idx_email_threads_last_message
  ON email_threads(workspace_id, last_message_at DESC);

CREATE TABLE IF NOT EXISTS email_messages (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL,
  thread_id TEXT NOT NULL,
  account_email TEXT NOT NULL,
  mailbox TEXT NOT NULL,
  provider_uid INTEGER,
  provider_message_id TEXT,
  source_message_key TEXT NOT NULL,
  subject TEXT,
  sent_at TEXT,
  from_json TEXT,
  to_json TEXT,
  snippet TEXT,
  artifact_id TEXT,
  raw_sha256 TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (workspace_id) REFERENCES workspaces(id),
  FOREIGN KEY (thread_id) REFERENCES email_threads(id),
  FOREIGN KEY (artifact_id) REFERENCES artifacts(id)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_email_messages_source_key
  ON email_messages(source_message_key);

CREATE UNIQUE INDEX IF NOT EXISTS idx_email_messages_uid_dedupe
  ON email_messages(workspace_id, account_email, mailbox, provider_uid);

CREATE INDEX IF NOT EXISTS idx_email_messages_thread_sent
  ON email_messages(thread_id, sent_at DESC);

CREATE TABLE IF NOT EXISTS email_participants (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL,
  email TEXT NOT NULL,
  display_name TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (workspace_id) REFERENCES workspaces(id)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_email_participants_unique
  ON email_participants(workspace_id, email);

CREATE TABLE IF NOT EXISTS email_message_participants (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL,
  message_id TEXT NOT NULL,
  participant_id TEXT NOT NULL,
  role TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (workspace_id) REFERENCES workspaces(id),
  FOREIGN KEY (message_id) REFERENCES email_messages(id),
  FOREIGN KEY (participant_id) REFERENCES email_participants(id)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_email_message_participants_unique
  ON email_message_participants(message_id, participant_id, role);

CREATE TABLE IF NOT EXISTS backfill_runs (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL,
  account_email TEXT NOT NULL,
  mailbox TEXT NOT NULL,
  since_date TEXT NOT NULL,
  until_date TEXT,
  status TEXT NOT NULL,
  checkpoint_json TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (workspace_id) REFERENCES workspaces(id)
);

CREATE INDEX IF NOT EXISTS idx_backfill_runs_lookup
  ON backfill_runs(workspace_id, account_email, mailbox, status, updated_at DESC);
