CREATE TABLE IF NOT EXISTS ai_provider_health (
  provider TEXT PRIMARY KEY,
  status TEXT NOT NULL DEFAULT 'healthy' CHECK (status IN ('healthy', 'disabled')),
  disabled_until TEXT,
  reason_code TEXT,
  last_error TEXT,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_ai_provider_health_status_until
  ON ai_provider_health(status, disabled_until);
