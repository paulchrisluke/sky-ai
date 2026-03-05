ALTER TABLE email_threads ADD COLUMN account_id TEXT;
ALTER TABLE email_messages ADD COLUMN account_id TEXT;
ALTER TABLE memory_chunks ADD COLUMN account_id TEXT;

UPDATE email_threads SET account_id = account_email WHERE account_id IS NULL;
UPDATE email_messages SET account_id = account_email WHERE account_id IS NULL;
UPDATE memory_chunks
SET account_id = COALESCE(
  json_extract(metadata_json, '$.accountId'),
  json_extract(metadata_json, '$.accountEmail')
)
WHERE account_id IS NULL;

CREATE INDEX IF NOT EXISTS idx_email_threads_workspace_account
  ON email_threads(workspace_id, account_id, last_message_at DESC);

CREATE INDEX IF NOT EXISTS idx_email_messages_workspace_account_sent
  ON email_messages(workspace_id, account_id, sent_at DESC);

CREATE INDEX IF NOT EXISTS idx_memory_chunks_workspace_account
  ON memory_chunks(workspace_id, account_id, created_at DESC);
