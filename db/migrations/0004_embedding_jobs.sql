CREATE TABLE IF NOT EXISTS embedding_jobs (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL,
  source_record_id TEXT NOT NULL,
  status TEXT NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  next_attempt_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_error TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (workspace_id) REFERENCES workspaces(id),
  FOREIGN KEY (source_record_id) REFERENCES normalized_records(id)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_embedding_jobs_source_record
  ON embedding_jobs(source_record_id);

CREATE INDEX IF NOT EXISTS idx_embedding_jobs_status_next_attempt
  ON embedding_jobs(status, next_attempt_at);

CREATE INDEX IF NOT EXISTS idx_memory_chunks_source_record
  ON memory_chunks(source_record_id);
