ALTER TABLE briefings ADD COLUMN account_id TEXT;
ALTER TABLE briefings ADD COLUMN narrative TEXT;
ALTER TABLE briefings ADD COLUMN status TEXT NOT NULL DEFAULT 'pending';
ALTER TABLE briefings ADD COLUMN payload_json TEXT;
ALTER TABLE briefings ADD COLUMN generated_at TEXT;

CREATE INDEX IF NOT EXISTS idx_briefings_scope_ready_date
  ON briefings(workspace_id, account_id, briefing_date, status, created_at DESC);
