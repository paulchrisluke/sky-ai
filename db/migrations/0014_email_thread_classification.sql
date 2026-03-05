ALTER TABLE email_threads ADD COLUMN classification_json TEXT;
ALTER TABLE email_threads ADD COLUMN classification_updated_at TEXT;

CREATE INDEX IF NOT EXISTS idx_email_threads_scope_classified
  ON email_threads(workspace_id, account_id, classification_updated_at DESC);

CREATE INDEX IF NOT EXISTS idx_email_threads_scope_priority
  ON email_threads(workspace_id, account_id, json_extract(classification_json, '$.priority'));

CREATE INDEX IF NOT EXISTS idx_email_threads_scope_category
  ON email_threads(workspace_id, account_id, json_extract(classification_json, '$.category'));
