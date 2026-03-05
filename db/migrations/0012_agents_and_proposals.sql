CREATE TABLE IF NOT EXISTS agents (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  purpose TEXT NOT NULL,
  business_context TEXT NOT NULL,
  priority_level TEXT NOT NULL DEFAULT 'medium',
  owner_goals_json TEXT NOT NULL DEFAULT '[]',
  tone TEXT NOT NULL DEFAULT 'professional',
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS agent_accounts (
  id TEXT PRIMARY KEY,
  agent_id TEXT NOT NULL REFERENCES agents(id),
  account_id TEXT NOT NULL REFERENCES accounts(id),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_agent_accounts_unique
  ON agent_accounts(agent_id, account_id);

CREATE TABLE IF NOT EXISTS agent_integrations (
  id TEXT PRIMARY KEY,
  agent_id TEXT NOT NULL REFERENCES agents(id),
  provider TEXT NOT NULL,
  credentials_encrypted TEXT,
  config_json TEXT NOT NULL DEFAULT '{}',
  status TEXT NOT NULL DEFAULT 'active',
  last_synced_at TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_agent_integrations_agent_provider
  ON agent_integrations(agent_id, provider, status);

CREATE TABLE IF NOT EXISTS proposals (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id),
  account_id TEXT NOT NULL REFERENCES accounts(id),
  agent_id TEXT REFERENCES agents(id),
  type TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'proposed',
  draft_payload_json TEXT NOT NULL DEFAULT '{}',
  required_inputs_json TEXT NOT NULL DEFAULT '{}',
  risk_level TEXT NOT NULL DEFAULT 'low',
  created_from_ref TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_proposals_scope
  ON proposals(workspace_id, account_id, status, created_at DESC);

CREATE TABLE IF NOT EXISTS proposal_citations (
  id TEXT PRIMARY KEY,
  proposal_id TEXT NOT NULL REFERENCES proposals(id),
  message_id TEXT,
  thread_id TEXT,
  quote_text TEXT,
  chunk_id TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_proposal_citations_proposal
  ON proposal_citations(proposal_id);

CREATE TABLE IF NOT EXISTS approvals_audit (
  id TEXT PRIMARY KEY,
  proposal_id TEXT NOT NULL REFERENCES proposals(id),
  actor TEXT NOT NULL,
  action TEXT NOT NULL,
  before_json TEXT,
  after_json TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_approvals_audit_proposal
  ON approvals_audit(proposal_id, created_at DESC);

ALTER TABLE tasks ADD COLUMN agent_id TEXT REFERENCES agents(id);
ALTER TABLE tasks ADD COLUMN source_type TEXT;
ALTER TABLE tasks ADD COLUMN source_ref TEXT;
ALTER TABLE tasks ADD COLUMN created_by TEXT NOT NULL DEFAULT 'system';
