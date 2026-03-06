ALTER TABLE workspaces ADD COLUMN timezone TEXT NOT NULL DEFAULT 'America/Chicago';

UPDATE workspaces
SET timezone = COALESCE(NULLIF(trim(timezone), ''), 'America/Chicago');

-- Keep FK graph stable: only normalize non-key email values in-place.
UPDATE accounts
SET email = lower(email)
WHERE email IS NOT NULL AND email != lower(email);

CREATE TRIGGER IF NOT EXISTS check_accounts_id_lowercase_insert
BEFORE INSERT ON accounts
FOR EACH ROW
WHEN NEW.id IS NOT NULL AND NEW.id != lower(NEW.id)
BEGIN
  SELECT RAISE(ABORT, 'accounts.id must be lowercase');
END;

CREATE TRIGGER IF NOT EXISTS check_accounts_id_lowercase_update
BEFORE UPDATE OF id ON accounts
FOR EACH ROW
WHEN NEW.id IS NOT NULL AND NEW.id != lower(NEW.id)
BEGIN
  SELECT RAISE(ABORT, 'accounts.id must be lowercase');
END;

CREATE TRIGGER IF NOT EXISTS check_accounts_email_lowercase_insert
BEFORE INSERT ON accounts
FOR EACH ROW
WHEN NEW.email IS NOT NULL AND NEW.email != lower(NEW.email)
BEGIN
  SELECT RAISE(ABORT, 'accounts.email must be lowercase');
END;

CREATE TRIGGER IF NOT EXISTS check_accounts_email_lowercase_update
BEFORE UPDATE OF email ON accounts
FOR EACH ROW
WHEN NEW.email IS NOT NULL AND NEW.email != lower(NEW.email)
BEGIN
  SELECT RAISE(ABORT, 'accounts.email must be lowercase');
END;

CREATE TRIGGER IF NOT EXISTS check_email_threads_account_id_lowercase_insert
BEFORE INSERT ON email_threads
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'email_threads.account_id must be lowercase');
END;

CREATE TRIGGER IF NOT EXISTS check_email_threads_account_id_lowercase_update
BEFORE UPDATE OF account_id ON email_threads
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'email_threads.account_id must be lowercase');
END;

CREATE TRIGGER IF NOT EXISTS check_email_messages_account_id_lowercase_insert
BEFORE INSERT ON email_messages
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'email_messages.account_id must be lowercase');
END;

CREATE TRIGGER IF NOT EXISTS check_email_messages_account_id_lowercase_update
BEFORE UPDATE OF account_id ON email_messages
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'email_messages.account_id must be lowercase');
END;

CREATE TRIGGER IF NOT EXISTS check_memory_chunks_account_id_lowercase_insert
BEFORE INSERT ON memory_chunks
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'memory_chunks.account_id must be lowercase');
END;

CREATE TRIGGER IF NOT EXISTS check_memory_chunks_account_id_lowercase_update
BEFORE UPDATE OF account_id ON memory_chunks
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'memory_chunks.account_id must be lowercase');
END;

CREATE TRIGGER IF NOT EXISTS check_embedding_jobs_account_id_lowercase_insert
BEFORE INSERT ON embedding_jobs
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'embedding_jobs.account_id must be lowercase');
END;

CREATE TRIGGER IF NOT EXISTS check_embedding_jobs_account_id_lowercase_update
BEFORE UPDATE OF account_id ON embedding_jobs
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'embedding_jobs.account_id must be lowercase');
END;

CREATE TRIGGER IF NOT EXISTS check_tasks_account_id_lowercase_insert
BEFORE INSERT ON tasks
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'tasks.account_id must be lowercase');
END;

CREATE TRIGGER IF NOT EXISTS check_tasks_account_id_lowercase_update
BEFORE UPDATE OF account_id ON tasks
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'tasks.account_id must be lowercase');
END;

CREATE TRIGGER IF NOT EXISTS check_decisions_account_id_lowercase_insert
BEFORE INSERT ON decisions
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'decisions.account_id must be lowercase');
END;

CREATE TRIGGER IF NOT EXISTS check_decisions_account_id_lowercase_update
BEFORE UPDATE OF account_id ON decisions
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'decisions.account_id must be lowercase');
END;

CREATE TRIGGER IF NOT EXISTS check_followups_account_id_lowercase_insert
BEFORE INSERT ON followups
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'followups.account_id must be lowercase');
END;

CREATE TRIGGER IF NOT EXISTS check_followups_account_id_lowercase_update
BEFORE UPDATE OF account_id ON followups
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'followups.account_id must be lowercase');
END;

CREATE TRIGGER IF NOT EXISTS check_chat_sessions_account_id_lowercase_insert
BEFORE INSERT ON chat_sessions
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'chat_sessions.account_id must be lowercase');
END;

CREATE TRIGGER IF NOT EXISTS check_chat_sessions_account_id_lowercase_update
BEFORE UPDATE OF account_id ON chat_sessions
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'chat_sessions.account_id must be lowercase');
END;

CREATE TRIGGER IF NOT EXISTS check_chat_turns_account_id_lowercase_insert
BEFORE INSERT ON chat_turns
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'chat_turns.account_id must be lowercase');
END;

CREATE TRIGGER IF NOT EXISTS check_chat_turns_account_id_lowercase_update
BEFORE UPDATE OF account_id ON chat_turns
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'chat_turns.account_id must be lowercase');
END;

CREATE TRIGGER IF NOT EXISTS check_proposed_actions_account_id_lowercase_insert
BEFORE INSERT ON proposed_actions
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'proposed_actions.account_id must be lowercase');
END;

CREATE TRIGGER IF NOT EXISTS check_proposed_actions_account_id_lowercase_update
BEFORE UPDATE OF account_id ON proposed_actions
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'proposed_actions.account_id must be lowercase');
END;

CREATE TRIGGER IF NOT EXISTS check_run_events_account_id_lowercase_insert
BEFORE INSERT ON run_events
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'run_events.account_id must be lowercase');
END;

CREATE TRIGGER IF NOT EXISTS check_run_events_account_id_lowercase_update
BEFORE UPDATE OF account_id ON run_events
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'run_events.account_id must be lowercase');
END;

CREATE TRIGGER IF NOT EXISTS check_run_search_audits_account_id_lowercase_insert
BEFORE INSERT ON run_search_audits
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'run_search_audits.account_id must be lowercase');
END;

CREATE TRIGGER IF NOT EXISTS check_run_search_audits_account_id_lowercase_update
BEFORE UPDATE OF account_id ON run_search_audits
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'run_search_audits.account_id must be lowercase');
END;

CREATE TRIGGER IF NOT EXISTS check_access_subject_permissions_account_id_lowercase_insert
BEFORE INSERT ON access_subject_permissions
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'access_subject_permissions.account_id must be lowercase');
END;

CREATE TRIGGER IF NOT EXISTS check_access_subject_permissions_account_id_lowercase_update
BEFORE UPDATE OF account_id ON access_subject_permissions
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'access_subject_permissions.account_id must be lowercase');
END;

CREATE TRIGGER IF NOT EXISTS check_action_events_account_id_lowercase_insert
BEFORE INSERT ON action_events
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'action_events.account_id must be lowercase');
END;

CREATE TRIGGER IF NOT EXISTS check_action_events_account_id_lowercase_update
BEFORE UPDATE OF account_id ON action_events
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'action_events.account_id must be lowercase');
END;

CREATE TRIGGER IF NOT EXISTS check_proposals_account_id_lowercase_insert
BEFORE INSERT ON proposals
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'proposals.account_id must be lowercase');
END;

CREATE TRIGGER IF NOT EXISTS check_proposals_account_id_lowercase_update
BEFORE UPDATE OF account_id ON proposals
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'proposals.account_id must be lowercase');
END;

CREATE TRIGGER IF NOT EXISTS check_briefings_account_id_lowercase_insert
BEFORE INSERT ON briefings
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'briefings.account_id must be lowercase');
END;

CREATE TRIGGER IF NOT EXISTS check_briefings_account_id_lowercase_update
BEFORE UPDATE OF account_id ON briefings
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'briefings.account_id must be lowercase');
END;

CREATE TRIGGER IF NOT EXISTS check_model_usage_events_account_id_lowercase_insert
BEFORE INSERT ON model_usage_events
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'model_usage_events.account_id must be lowercase');
END;

CREATE TRIGGER IF NOT EXISTS check_model_usage_events_account_id_lowercase_update
BEFORE UPDATE OF account_id ON model_usage_events
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'model_usage_events.account_id must be lowercase');
END;

CREATE TRIGGER IF NOT EXISTS check_agent_accounts_account_id_lowercase_insert
BEFORE INSERT ON agent_accounts
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'agent_accounts.account_id must be lowercase');
END;

CREATE TRIGGER IF NOT EXISTS check_agent_accounts_account_id_lowercase_update
BEFORE UPDATE OF account_id ON agent_accounts
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'agent_accounts.account_id must be lowercase');
END;
