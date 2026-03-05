ALTER TABLE proposed_actions ADD COLUMN rejected_by TEXT;
ALTER TABLE proposed_actions ADD COLUMN rejected_at TEXT;
ALTER TABLE proposed_actions ADD COLUMN rejection_reason TEXT;
ALTER TABLE proposed_actions ADD COLUMN executed_by TEXT;
ALTER TABLE proposed_actions ADD COLUMN executed_at TEXT;
ALTER TABLE proposed_actions ADD COLUMN execution_result_json TEXT;

CREATE TABLE IF NOT EXISTS action_events (
  id TEXT PRIMARY KEY,
  action_id TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  event_type TEXT NOT NULL,
  actor TEXT,
  payload_json TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (action_id) REFERENCES proposed_actions(id),
  FOREIGN KEY (workspace_id) REFERENCES workspaces(id)
);

CREATE INDEX IF NOT EXISTS idx_action_events_action_created
  ON action_events(action_id, created_at ASC);

CREATE INDEX IF NOT EXISTS idx_action_events_scope_created
  ON action_events(workspace_id, account_id, created_at DESC);
