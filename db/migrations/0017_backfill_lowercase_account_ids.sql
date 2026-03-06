-- D1-safe backfill for legacy mixed-case account ids.
-- 1) Ensure lowercase parent rows exist
-- 2) Repoint account_id references to lowercase ids
-- 3) Delete legacy mixed-case account rows

INSERT OR IGNORE INTO accounts (id, workspace_id, label, email, status, created_at, updated_at)
SELECT
  lower(id),
  workspace_id,
  label,
  NULL,
  status,
  created_at,
  CURRENT_TIMESTAMP
FROM accounts
WHERE id IS NOT NULL
  AND id != lower(id);

-- Repoint FK-backed tables.
UPDATE chat_sessions
SET account_id = lower(account_id)
WHERE account_id IN (SELECT id FROM accounts WHERE id != lower(id));

UPDATE chat_turns
SET account_id = lower(account_id)
WHERE account_id IN (SELECT id FROM accounts WHERE id != lower(id));

UPDATE chat_citations
SET account_id = lower(account_id)
WHERE account_id IN (SELECT id FROM accounts WHERE id != lower(id));

UPDATE tool_calls
SET account_id = lower(account_id)
WHERE account_id IN (SELECT id FROM accounts WHERE id != lower(id));

UPDATE run_events
SET account_id = lower(account_id)
WHERE account_id IN (SELECT id FROM accounts WHERE id != lower(id));

UPDATE proposed_actions
SET account_id = lower(account_id)
WHERE account_id IN (SELECT id FROM accounts WHERE id != lower(id));

UPDATE access_subject_permissions
SET account_id = lower(account_id)
WHERE account_id IN (SELECT id FROM accounts WHERE id != lower(id));

UPDATE proposals
SET account_id = lower(account_id)
WHERE account_id IN (SELECT id FROM accounts WHERE id != lower(id));

UPDATE agent_accounts
SET account_id = lower(account_id)
WHERE account_id IN (SELECT id FROM accounts WHERE id != lower(id));

-- Repoint non-FK account_id columns.
UPDATE email_threads
SET account_id = lower(account_id)
WHERE account_id IN (SELECT id FROM accounts WHERE id != lower(id));

UPDATE email_messages
SET account_id = lower(account_id)
WHERE account_id IN (SELECT id FROM accounts WHERE id != lower(id));

UPDATE memory_chunks
SET account_id = lower(account_id)
WHERE account_id IN (SELECT id FROM accounts WHERE id != lower(id));

UPDATE embedding_jobs
SET account_id = lower(account_id)
WHERE account_id IN (SELECT id FROM accounts WHERE id != lower(id));

UPDATE tasks
SET account_id = lower(account_id)
WHERE account_id IN (SELECT id FROM accounts WHERE id != lower(id));

UPDATE decisions
SET account_id = lower(account_id)
WHERE account_id IN (SELECT id FROM accounts WHERE id != lower(id));

UPDATE followups
SET account_id = lower(account_id)
WHERE account_id IN (SELECT id FROM accounts WHERE id != lower(id));

UPDATE message_extractions
SET account_id = lower(account_id)
WHERE account_id IN (SELECT id FROM accounts WHERE id != lower(id));

UPDATE run_search_audits
SET account_id = lower(account_id)
WHERE account_id IN (SELECT id FROM accounts WHERE id != lower(id));

UPDATE action_events
SET account_id = lower(account_id)
WHERE account_id IN (SELECT id FROM accounts WHERE id != lower(id));

UPDATE briefings
SET account_id = lower(account_id)
WHERE account_id IN (SELECT id FROM accounts WHERE id != lower(id));

UPDATE model_usage_events
SET account_id = lower(account_id)
WHERE account_id IN (SELECT id FROM accounts WHERE id != lower(id));

-- Normalize account_email soft-reference column.
UPDATE email_messages
SET account_email = lower(account_email)
WHERE account_email IS NOT NULL
  AND account_email != lower(account_email);

-- Delete mixed-case legacy account rows after repoint.
DELETE FROM accounts
WHERE id IS NOT NULL
  AND id != lower(id);

UPDATE accounts
SET email = lower(email)
WHERE email IS NOT NULL
  AND email != lower(email);

UPDATE accounts
SET email = lower(id)
WHERE email IS NULL
  AND id LIKE '%@%';
