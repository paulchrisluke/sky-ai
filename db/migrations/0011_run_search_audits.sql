CREATE TABLE IF NOT EXISTS run_search_audits (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL,
  run_id TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  intent TEXT NOT NULL,
  query_text TEXT NOT NULL,
  citation_required INTEGER NOT NULL DEFAULT 1,
  citation_status TEXT NOT NULL,
  citations_count INTEGER NOT NULL DEFAULT 0,
  searched_json TEXT,
  validator_version TEXT NOT NULL DEFAULT 'v1',
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (workspace_id) REFERENCES workspaces(id)
);

CREATE INDEX IF NOT EXISTS idx_run_search_audits_session_run
  ON run_search_audits(session_id, run_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_run_search_audits_scope_created
  ON run_search_audits(workspace_id, account_id, created_at DESC);
