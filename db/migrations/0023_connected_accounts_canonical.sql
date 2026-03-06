-- Canonicalize connected_accounts table and repoint FK tables without disabling foreign keys.

DROP VIEW IF EXISTS connected_accounts;

CREATE TABLE connected_accounts (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL,
  label TEXT,
  email TEXT,
  status TEXT NOT NULL DEFAULT 'active',
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  provider TEXT NOT NULL DEFAULT 'email_icloud',
  identifier TEXT,
  display_name TEXT,
  credentials_encrypted TEXT,
  config_json TEXT NOT NULL DEFAULT '{}',
  onboarding_complete INTEGER NOT NULL DEFAULT 0,
  last_synced_at TEXT,
  FOREIGN KEY (workspace_id) REFERENCES workspaces(id)
);

INSERT INTO connected_accounts (
  id,
  workspace_id,
  label,
  email,
  status,
  created_at,
  updated_at,
  provider,
  identifier,
  display_name,
  credentials_encrypted,
  config_json,
  onboarding_complete,
  last_synced_at
)
SELECT
  id,
  workspace_id,
  label,
  email,
  status,
  created_at,
  updated_at,
  provider,
  identifier,
  display_name,
  credentials_encrypted,
  config_json,
  onboarding_complete,
  last_synced_at
FROM accounts;

CREATE TABLE agent_accounts_new (
  id TEXT PRIMARY KEY,
  agent_id TEXT NOT NULL REFERENCES agents(id),
  account_id TEXT NOT NULL REFERENCES connected_accounts(id),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE chat_sessions_new (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  user_id TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active',
  active_run_id TEXT,
  last_event_at TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (workspace_id) REFERENCES workspaces(id),
  FOREIGN KEY (account_id) REFERENCES connected_accounts(id)
);

CREATE TABLE chat_turns_new (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  run_id TEXT,
  role TEXT NOT NULL,
  content TEXT NOT NULL,
  citation_required INTEGER NOT NULL DEFAULT 1,
  citation_status TEXT NOT NULL DEFAULT 'pending',
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (session_id) REFERENCES chat_sessions_new(id),
  FOREIGN KEY (workspace_id) REFERENCES workspaces(id),
  FOREIGN KEY (account_id) REFERENCES connected_accounts(id)
);

CREATE TABLE chat_citations_new (
  id TEXT PRIMARY KEY,
  turn_id TEXT NOT NULL,
  session_id TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  message_id TEXT NOT NULL,
  message_date TEXT,
  sender TEXT,
  subject TEXT,
  score REAL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (turn_id) REFERENCES chat_turns_new(id),
  FOREIGN KEY (session_id) REFERENCES chat_sessions_new(id),
  FOREIGN KEY (workspace_id) REFERENCES workspaces(id),
  FOREIGN KEY (account_id) REFERENCES connected_accounts(id)
);

CREATE TABLE proposals_new (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id),
  account_id TEXT NOT NULL REFERENCES connected_accounts(id),
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

CREATE TABLE proposal_citations_new (
  id TEXT PRIMARY KEY,
  proposal_id TEXT NOT NULL REFERENCES proposals_new(id),
  message_id TEXT,
  thread_id TEXT,
  quote_text TEXT,
  chunk_id TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE approvals_audit_new (
  id TEXT PRIMARY KEY,
  proposal_id TEXT NOT NULL REFERENCES proposals_new(id),
  actor TEXT NOT NULL,
  action TEXT NOT NULL,
  before_json TEXT,
  after_json TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE proposed_actions_new (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  session_id TEXT,
  turn_id TEXT,
  action_type TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'proposed',
  approval_token TEXT NOT NULL,
  approved_by TEXT,
  approved_at TEXT,
  expires_at TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  rejected_by TEXT,
  rejected_at TEXT,
  rejection_reason TEXT,
  executed_by TEXT,
  executed_at TEXT,
  execution_result_json TEXT,
  FOREIGN KEY (workspace_id) REFERENCES workspaces(id),
  FOREIGN KEY (account_id) REFERENCES connected_accounts(id),
  FOREIGN KEY (session_id) REFERENCES chat_sessions_new(id),
  FOREIGN KEY (turn_id) REFERENCES chat_turns_new(id)
);

CREATE TABLE action_events_new (
  id TEXT PRIMARY KEY,
  action_id TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  event_type TEXT NOT NULL,
  actor TEXT,
  payload_json TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (action_id) REFERENCES proposed_actions_new(id),
  FOREIGN KEY (workspace_id) REFERENCES workspaces(id)
);

CREATE TABLE run_events_new (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  run_id TEXT,
  turn_id TEXT,
  event_type TEXT NOT NULL,
  payload_json TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (session_id) REFERENCES chat_sessions_new(id),
  FOREIGN KEY (workspace_id) REFERENCES workspaces(id),
  FOREIGN KEY (account_id) REFERENCES connected_accounts(id),
  FOREIGN KEY (turn_id) REFERENCES chat_turns_new(id)
);

CREATE TABLE tool_calls_new (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL,
  turn_id TEXT,
  workspace_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  run_id TEXT,
  tool_name TEXT NOT NULL,
  input_json TEXT,
  output_json TEXT,
  status TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (session_id) REFERENCES chat_sessions_new(id),
  FOREIGN KEY (turn_id) REFERENCES chat_turns_new(id),
  FOREIGN KEY (workspace_id) REFERENCES workspaces(id),
  FOREIGN KEY (account_id) REFERENCES connected_accounts(id)
);

INSERT INTO agent_accounts_new (id, agent_id, account_id, created_at)
SELECT id, agent_id, account_id, created_at FROM agent_accounts;

INSERT INTO chat_sessions_new (
  id, workspace_id, account_id, user_id, status, active_run_id, last_event_at, created_at, updated_at
)
SELECT
  id, workspace_id, account_id, user_id, status, active_run_id, last_event_at, created_at, updated_at
FROM chat_sessions;

INSERT INTO chat_turns_new (
  id, session_id, workspace_id, account_id, run_id, role, content, citation_required, citation_status, created_at
)
SELECT
  id, session_id, workspace_id, account_id, run_id, role, content, citation_required, citation_status, created_at
FROM chat_turns;

INSERT INTO chat_citations_new (
  id, turn_id, session_id, workspace_id, account_id, message_id, message_date, sender, subject, score, created_at
)
SELECT
  id, turn_id, session_id, workspace_id, account_id, message_id, message_date, sender, subject, score, created_at
FROM chat_citations;

INSERT INTO proposals_new (
  id, workspace_id, account_id, agent_id, type, status, draft_payload_json, required_inputs_json, risk_level, created_from_ref, created_at, updated_at
)
SELECT
  id, workspace_id, account_id, agent_id, type, status, draft_payload_json, required_inputs_json, risk_level, created_from_ref, created_at, updated_at
FROM proposals;

INSERT INTO proposal_citations_new (
  id, proposal_id, message_id, thread_id, quote_text, chunk_id, created_at
)
SELECT
  id, proposal_id, message_id, thread_id, quote_text, chunk_id, created_at
FROM proposal_citations;

INSERT INTO approvals_audit_new (
  id, proposal_id, actor, action, before_json, after_json, created_at
)
SELECT
  id, proposal_id, actor, action, before_json, after_json, created_at
FROM approvals_audit;

INSERT INTO proposed_actions_new (
  id, workspace_id, account_id, session_id, turn_id, action_type, payload_json, status, approval_token, approved_by, approved_at, expires_at, created_at, updated_at,
  rejected_by, rejected_at, rejection_reason, executed_by, executed_at, execution_result_json
)
SELECT
  id, workspace_id, account_id, session_id, turn_id, action_type, payload_json, status, approval_token, approved_by, approved_at, expires_at, created_at, updated_at,
  rejected_by, rejected_at, rejection_reason, executed_by, executed_at, execution_result_json
FROM proposed_actions;

INSERT INTO action_events_new (
  id, action_id, workspace_id, account_id, event_type, actor, payload_json, created_at
)
SELECT
  id, action_id, workspace_id, account_id, event_type, actor, payload_json, created_at
FROM action_events;

INSERT INTO run_events_new (
  id, session_id, workspace_id, account_id, run_id, turn_id, event_type, payload_json, created_at
)
SELECT
  id, session_id, workspace_id, account_id, run_id, turn_id, event_type, payload_json, created_at
FROM run_events;

INSERT INTO tool_calls_new (
  id, session_id, turn_id, workspace_id, account_id, run_id, tool_name, input_json, output_json, status, created_at, updated_at
)
SELECT
  id, session_id, turn_id, workspace_id, account_id, run_id, tool_name, input_json, output_json, status, created_at, updated_at
FROM tool_calls;

DROP TABLE action_events;
DROP TABLE chat_citations;
DROP TABLE tool_calls;
DROP TABLE run_events;
DROP TABLE proposed_actions;
DROP TABLE chat_turns;
DROP TABLE chat_sessions;
DROP TABLE proposal_citations;
DROP TABLE approvals_audit;
DROP TABLE proposals;
DROP TABLE agent_accounts;
DROP TABLE accounts;

ALTER TABLE agent_accounts_new RENAME TO agent_accounts;
ALTER TABLE chat_sessions_new RENAME TO chat_sessions;
ALTER TABLE chat_turns_new RENAME TO chat_turns;
ALTER TABLE chat_citations_new RENAME TO chat_citations;
ALTER TABLE proposals_new RENAME TO proposals;
ALTER TABLE proposal_citations_new RENAME TO proposal_citations;
ALTER TABLE approvals_audit_new RENAME TO approvals_audit;
ALTER TABLE proposed_actions_new RENAME TO proposed_actions;
ALTER TABLE action_events_new RENAME TO action_events;
ALTER TABLE run_events_new RENAME TO run_events;
ALTER TABLE tool_calls_new RENAME TO tool_calls;

CREATE VIEW accounts AS
SELECT
  id,
  workspace_id,
  label,
  email,
  status,
  created_at,
  updated_at,
  provider,
  identifier,
  display_name,
  credentials_encrypted,
  config_json,
  onboarding_complete,
  last_synced_at
FROM connected_accounts;

CREATE INDEX idx_connected_accounts_workspace_email
  ON connected_accounts(workspace_id, email);

CREATE UNIQUE INDEX idx_agent_accounts_unique
  ON agent_accounts(agent_id, account_id);

CREATE INDEX idx_chat_sessions_lookup
  ON chat_sessions(workspace_id, account_id, user_id, updated_at DESC);
CREATE INDEX idx_chat_turns_session_created
  ON chat_turns(session_id, created_at DESC);
CREATE INDEX idx_chat_citations_turn
  ON chat_citations(turn_id);
CREATE INDEX idx_proposals_scope
  ON proposals(workspace_id, account_id, status, created_at DESC);
CREATE INDEX idx_proposal_citations_proposal
  ON proposal_citations(proposal_id);
CREATE INDEX idx_approvals_audit_proposal
  ON approvals_audit(proposal_id, created_at DESC);
CREATE UNIQUE INDEX idx_proposed_actions_approval_token
  ON proposed_actions(approval_token);
CREATE INDEX idx_proposed_actions_status
  ON proposed_actions(workspace_id, account_id, status, created_at DESC);
CREATE INDEX idx_action_events_action_created
  ON action_events(action_id, created_at ASC);
CREATE INDEX idx_action_events_scope_created
  ON action_events(workspace_id, account_id, created_at DESC);
CREATE INDEX idx_run_events_session_created
  ON run_events(session_id, created_at DESC);
CREATE INDEX idx_tool_calls_session
  ON tool_calls(session_id, created_at DESC);

CREATE TRIGGER check_connected_accounts_id_lowercase_insert
BEFORE INSERT ON connected_accounts
FOR EACH ROW
WHEN NEW.id IS NOT NULL AND NEW.id != lower(NEW.id)
BEGIN
  SELECT RAISE(ABORT, 'connected_accounts.id must be lowercase');
END;

CREATE TRIGGER check_connected_accounts_id_lowercase_update
BEFORE UPDATE OF id ON connected_accounts
FOR EACH ROW
WHEN NEW.id IS NOT NULL AND NEW.id != lower(NEW.id)
BEGIN
  SELECT RAISE(ABORT, 'connected_accounts.id must be lowercase');
END;

CREATE TRIGGER check_connected_accounts_email_lowercase_insert
BEFORE INSERT ON connected_accounts
FOR EACH ROW
WHEN NEW.email IS NOT NULL AND NEW.email != lower(NEW.email)
BEGIN
  SELECT RAISE(ABORT, 'connected_accounts.email must be lowercase');
END;

CREATE TRIGGER check_connected_accounts_email_lowercase_update
BEFORE UPDATE OF email ON connected_accounts
FOR EACH ROW
WHEN NEW.email IS NOT NULL AND NEW.email != lower(NEW.email)
BEGIN
  SELECT RAISE(ABORT, 'connected_accounts.email must be lowercase');
END;

CREATE TRIGGER check_agent_accounts_account_id_lowercase_insert
BEFORE INSERT ON agent_accounts
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'agent_accounts.account_id must be lowercase');
END;

CREATE TRIGGER check_agent_accounts_account_id_lowercase_update
BEFORE UPDATE OF account_id ON agent_accounts
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'agent_accounts.account_id must be lowercase');
END;

CREATE TRIGGER check_chat_sessions_account_id_lowercase_insert
BEFORE INSERT ON chat_sessions
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'chat_sessions.account_id must be lowercase');
END;

CREATE TRIGGER check_chat_sessions_account_id_lowercase_update
BEFORE UPDATE OF account_id ON chat_sessions
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'chat_sessions.account_id must be lowercase');
END;

CREATE TRIGGER check_chat_turns_account_id_lowercase_insert
BEFORE INSERT ON chat_turns
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'chat_turns.account_id must be lowercase');
END;

CREATE TRIGGER check_chat_turns_account_id_lowercase_update
BEFORE UPDATE OF account_id ON chat_turns
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'chat_turns.account_id must be lowercase');
END;

CREATE TRIGGER check_chat_citations_account_id_lowercase_insert
BEFORE INSERT ON chat_citations
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'chat_citations.account_id must be lowercase');
END;

CREATE TRIGGER check_chat_citations_account_id_lowercase_update
BEFORE UPDATE OF account_id ON chat_citations
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'chat_citations.account_id must be lowercase');
END;

CREATE TRIGGER check_proposals_account_id_lowercase_insert
BEFORE INSERT ON proposals
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'proposals.account_id must be lowercase');
END;

CREATE TRIGGER check_proposals_account_id_lowercase_update
BEFORE UPDATE OF account_id ON proposals
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'proposals.account_id must be lowercase');
END;

CREATE TRIGGER check_proposed_actions_account_id_lowercase_insert
BEFORE INSERT ON proposed_actions
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'proposed_actions.account_id must be lowercase');
END;

CREATE TRIGGER check_proposed_actions_account_id_lowercase_update
BEFORE UPDATE OF account_id ON proposed_actions
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'proposed_actions.account_id must be lowercase');
END;

CREATE TRIGGER check_run_events_account_id_lowercase_insert
BEFORE INSERT ON run_events
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'run_events.account_id must be lowercase');
END;

CREATE TRIGGER check_run_events_account_id_lowercase_update
BEFORE UPDATE OF account_id ON run_events
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'run_events.account_id must be lowercase');
END;

CREATE TRIGGER check_tool_calls_account_id_lowercase_insert
BEFORE INSERT ON tool_calls
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'tool_calls.account_id must be lowercase');
END;

CREATE TRIGGER check_tool_calls_account_id_lowercase_update
BEFORE UPDATE OF account_id ON tool_calls
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'tool_calls.account_id must be lowercase');
END;

CREATE TRIGGER check_action_events_account_id_lowercase_insert
BEFORE INSERT ON action_events
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'action_events.account_id must be lowercase');
END;

CREATE TRIGGER check_action_events_account_id_lowercase_update
BEFORE UPDATE OF account_id ON action_events
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'action_events.account_id must be lowercase');
END;
