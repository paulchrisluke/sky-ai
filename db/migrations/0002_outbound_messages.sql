CREATE TABLE IF NOT EXISTS outbound_messages (
  id TEXT PRIMARY KEY,
  status TEXT NOT NULL,
  to_email TEXT NOT NULL,
  subject TEXT NOT NULL,
  text_body TEXT,
  html_body TEXT,
  error_message TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  sent_at TEXT
);

CREATE INDEX IF NOT EXISTS idx_outbound_messages_status_created
  ON outbound_messages(status, created_at);
