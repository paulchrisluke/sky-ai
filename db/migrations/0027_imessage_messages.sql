CREATE TABLE IF NOT EXISTS imessage_messages (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  source_row_id INTEGER NOT NULL,
  sender TEXT,
  body_text TEXT NOT NULL,
  sent_at TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (workspace_id) REFERENCES workspaces(id),
  UNIQUE(workspace_id, account_id, source_row_id)
);

CREATE INDEX IF NOT EXISTS idx_imessage_messages_account_sent
  ON imessage_messages(workspace_id, account_id, sent_at DESC);

CREATE TRIGGER IF NOT EXISTS check_imessage_messages_account_id_lowercase_insert
BEFORE INSERT ON imessage_messages
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'imessage_messages.account_id must be lowercase');
END;

CREATE TRIGGER IF NOT EXISTS check_imessage_messages_account_id_lowercase_update
BEFORE UPDATE OF account_id ON imessage_messages
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'imessage_messages.account_id must be lowercase');
END;
