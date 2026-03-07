CREATE TABLE IF NOT EXISTS email_entities (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  message_id TEXT NOT NULL,
  thread_id TEXT,
  entity_type TEXT NOT NULL,
  direction TEXT NOT NULL DEFAULT 'unknown',
  counterparty_name TEXT,
  counterparty_email TEXT,
  amount_cents INTEGER,
  currency TEXT,
  due_date TEXT,
  reference_number TEXT,
  status TEXT DEFAULT 'unknown',
  action_required INTEGER NOT NULL DEFAULT 0,
  action_description TEXT,
  risk_level TEXT DEFAULT 'low',
  confidence REAL DEFAULT 0.5,
  raw_json TEXT,
  extracted_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_email_entities_workspace_account ON email_entities(workspace_id, account_id);
CREATE INDEX IF NOT EXISTS idx_email_entities_message ON email_entities(message_id);
CREATE INDEX IF NOT EXISTS idx_email_entities_action_required ON email_entities(workspace_id, account_id, action_required);
CREATE INDEX IF NOT EXISTS idx_email_entities_entity_type ON email_entities(workspace_id, account_id, entity_type);
