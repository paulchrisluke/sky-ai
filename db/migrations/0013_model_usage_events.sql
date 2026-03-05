CREATE TABLE IF NOT EXISTS model_usage_events (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL,
  account_id TEXT,
  run_id TEXT,
  provider TEXT NOT NULL,
  model TEXT NOT NULL,
  operation TEXT NOT NULL,
  endpoint TEXT,
  request_units INTEGER,
  response_units INTEGER,
  estimated_cost_usd REAL,
  status TEXT NOT NULL DEFAULT 'ok',
  error_code TEXT,
  metadata_json TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_model_usage_events_scope_time
  ON model_usage_events(workspace_id, account_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_model_usage_events_provider_model
  ON model_usage_events(provider, model, created_at DESC);
