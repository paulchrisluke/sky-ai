-- Enhanced chunking and embedding metrics tracking
CREATE TABLE IF NOT EXISTS chunking_metrics (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL,
  account_id TEXT,
  source_record_id TEXT NOT NULL,
  document_type TEXT,
  original_length INTEGER NOT NULL,
  chunk_count INTEGER NOT NULL,
  avg_chunk_length REAL NOT NULL,
  min_chunk_length INTEGER NOT NULL,
  max_chunk_length INTEGER NOT NULL,
  overlap_ratio REAL DEFAULT 0,
  chunking_strategy TEXT DEFAULT 'default',
  processing_time_ms INTEGER,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (workspace_id) REFERENCES workspaces(id),
  FOREIGN KEY (account_id) REFERENCES oauth_accounts(id),
  FOREIGN KEY (source_record_id) REFERENCES normalized_records(id)
);

CREATE TABLE IF NOT EXISTS embedding_metrics (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL,
  account_id TEXT,
  chunk_id TEXT NOT NULL,
  provider TEXT NOT NULL,
  model TEXT NOT NULL,
  embedding_latency_ms INTEGER,
  vector_dimensions INTEGER,
  batch_size INTEGER DEFAULT 1,
  token_count INTEGER,
  embedding_cost_usd REAL,
  status TEXT NOT NULL DEFAULT 'success',
  error_code TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (workspace_id) REFERENCES workspaces(id),
  FOREIGN KEY (account_id) REFERENCES oauth_accounts(id),
  FOREIGN KEY (chunk_id) REFERENCES memory_chunks(id)
);

-- Indexes for performance
CREATE INDEX IF NOT EXISTS idx_chunking_metrics_workspace_account 
  ON chunking_metrics(workspace_id, account_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_chunking_metrics_source_record 
  ON chunking_metrics(source_record_id);

CREATE INDEX IF NOT EXISTS idx_embedding_metrics_workspace_account 
  ON embedding_metrics(workspace_id, account_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_embedding_metrics_chunk 
  ON embedding_metrics(chunk_id);

CREATE INDEX IF NOT EXISTS idx_embedding_metrics_provider_model 
  ON embedding_metrics(provider, model, created_at DESC);
