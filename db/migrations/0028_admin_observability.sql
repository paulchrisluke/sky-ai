-- Admin observability foundation tables
-- Migration 0028

-- Pipeline events table for tracking all pipeline operations
CREATE TABLE pipeline_events (
    id TEXT PRIMARY KEY,
    workspace_id TEXT NOT NULL,
    account_id TEXT,
    source_id TEXT,
    source_type TEXT NOT NULL,
    entity_id TEXT,
    entity_type TEXT NOT NULL,
    pipeline_stage TEXT NOT NULL,
    status TEXT NOT NULL,
    request_id TEXT,
    job_id TEXT,
    parent_event_id TEXT,
    attempt INTEGER NOT NULL DEFAULT 1,
    provider TEXT,
    model TEXT,
    input_count INTEGER,
    output_count INTEGER,
    token_count INTEGER,
    cost_usd REAL,
    latency_ms INTEGER,
    error_code TEXT,
    error_message TEXT,
    metadata_json TEXT,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Indexes for pipeline_events
CREATE INDEX pipeline_events_workspace_created ON pipeline_events (workspace_id, created_at);
CREATE INDEX pipeline_events_account_stage_created ON pipeline_events (account_id, pipeline_stage, created_at);
CREATE INDEX pipeline_events_status_created ON pipeline_events (status, created_at);

-- Extraction runs table for tracking extraction operations
CREATE TABLE extraction_runs (
    id TEXT PRIMARY KEY,
    workspace_id TEXT NOT NULL,
    account_id TEXT,
    source_record_id TEXT,
    source_message_id TEXT,
    provider TEXT NOT NULL,
    model TEXT NOT NULL,
    status TEXT NOT NULL,
    latency_ms INTEGER,
    token_input INTEGER,
    token_output INTEGER,
    cost_usd REAL,
    confidence_avg REAL,
    entity_count INTEGER NOT NULL DEFAULT 0,
    error_code TEXT,
    error_message TEXT,
    raw_response_artifact_id TEXT,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Indexes for extraction_runs
CREATE INDEX extraction_runs_workspace_created ON extraction_runs (workspace_id, created_at);
CREATE INDEX extraction_runs_account_created ON extraction_runs (account_id, created_at);

-- Extracted entities table for storing extracted entities
CREATE TABLE extracted_entities (
    id TEXT PRIMARY KEY,
    extraction_run_id TEXT NOT NULL,
    workspace_id TEXT NOT NULL,
    account_id TEXT,
    source_record_id TEXT,
    source_message_id TEXT,
    entity_type TEXT NOT NULL,
    direction TEXT,
    counterparty TEXT,
    amount REAL,
    currency TEXT,
    status TEXT,
    risk_level TEXT,
    confidence REAL,
    normalized_value_json TEXT,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Indexes for extracted_entities
CREATE INDEX extracted_entities_workspace_type_created ON extracted_entities (workspace_id, entity_type, created_at);
CREATE INDEX extracted_entities_confidence_created ON extracted_entities (confidence, created_at);

-- Delivery events table for tracking delivery operations
CREATE TABLE delivery_events (
    id TEXT PRIMARY KEY,
    workspace_id TEXT NOT NULL,
    account_id TEXT,
    source_record_id TEXT,
    destination TEXT NOT NULL,
    status TEXT NOT NULL,
    payload_artifact_id TEXT,
    response_code TEXT,
    response_body_preview TEXT,
    latency_ms INTEGER,
    error_code TEXT,
    error_message TEXT,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Account usage ledger for tracking usage metrics
CREATE TABLE account_usage_ledger (
    id TEXT PRIMARY KEY,
    workspace_id TEXT NOT NULL,
    account_id TEXT NOT NULL,
    usage_type TEXT NOT NULL,
    quantity REAL NOT NULL,
    unit TEXT NOT NULL,
    source_event_id TEXT,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Indexes for account_usage_ledger
CREATE INDEX account_usage_ledger_account_type_created ON account_usage_ledger (account_id, usage_type, created_at);

-- Account daily rollups for aggregated metrics
CREATE TABLE account_daily_rollups (
    day TEXT NOT NULL,
    workspace_id TEXT NOT NULL,
    account_id TEXT NOT NULL,
    source_type TEXT NOT NULL,
    ingested_count INTEGER NOT NULL DEFAULT 0,
    normalized_count INTEGER NOT NULL DEFAULT 0,
    chunked_docs INTEGER NOT NULL DEFAULT 0,
    chunk_count INTEGER NOT NULL DEFAULT 0,
    embedded_count INTEGER NOT NULL DEFAULT 0,
    extracted_count INTEGER NOT NULL DEFAULT 0,
    delivered_count INTEGER NOT NULL DEFAULT 0,
    failed_count INTEGER NOT NULL DEFAULT 0,
    retry_count INTEGER NOT NULL DEFAULT 0,
    token_count INTEGER NOT NULL DEFAULT 0,
    cost_usd REAL NOT NULL DEFAULT 0,
    avg_extract_confidence REAL,
    PRIMARY KEY (day, workspace_id, account_id, source_type)
);

-- Admin audit events for tracking admin actions
CREATE TABLE admin_audit_events (
    id TEXT PRIMARY KEY,
    actor_email TEXT NOT NULL,
    action TEXT NOT NULL,
    resource_type TEXT NOT NULL,
    resource_id TEXT,
    request_path TEXT,
    request_method TEXT,
    request_id TEXT,
    metadata_json TEXT,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Indexes for admin_audit_events
CREATE INDEX admin_audit_events_actor_created ON admin_audit_events (actor_email, created_at);
