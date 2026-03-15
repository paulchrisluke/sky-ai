-- Merge legacy normalized account id into canonical email-form account id.
-- Source: skylerbaird_me_com
-- Target: skylerbaird@me.com

INSERT OR IGNORE INTO connected_accounts (
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
  'skylerbaird@me.com',
  workspace_id,
  label,
  'skylerbaird@me.com',
  status,
  created_at,
  CURRENT_TIMESTAMP,
  provider,
  identifier,
  display_name,
  credentials_encrypted,
  config_json,
  onboarding_complete,
  last_synced_at
FROM connected_accounts
WHERE id = 'skylerbaird_me_com';

-- If both rows exist, keep target id and enrich missing fields from source.
UPDATE connected_accounts
SET
  label = COALESCE(label, (SELECT label FROM connected_accounts WHERE id = 'skylerbaird_me_com')),
  email = 'skylerbaird@me.com',
  identifier = COALESCE(identifier, (SELECT identifier FROM connected_accounts WHERE id = 'skylerbaird_me_com')),
  display_name = COALESCE(display_name, (SELECT display_name FROM connected_accounts WHERE id = 'skylerbaird_me_com')),
  credentials_encrypted = COALESCE(credentials_encrypted, (SELECT credentials_encrypted FROM connected_accounts WHERE id = 'skylerbaird_me_com')),
  config_json = COALESCE(config_json, (SELECT config_json FROM connected_accounts WHERE id = 'skylerbaird_me_com')),
  onboarding_complete = MAX(
    onboarding_complete,
    COALESCE((SELECT onboarding_complete FROM connected_accounts WHERE id = 'skylerbaird_me_com'), onboarding_complete)
  ),
  last_synced_at = COALESCE(last_synced_at, (SELECT last_synced_at FROM connected_accounts WHERE id = 'skylerbaird_me_com')),
  created_at = COALESCE(
    MIN(
      created_at,
      COALESCE((SELECT created_at FROM connected_accounts WHERE id = 'skylerbaird_me_com'), created_at)
    ),
    created_at
  ),
  updated_at = CURRENT_TIMESTAMP
WHERE id = 'skylerbaird@me.com';

-- Pre-dedupe rows that would violate unique constraints after account_id repoint.
DELETE FROM agent_accounts
WHERE account_id = 'skylerbaird_me_com'
  AND EXISTS (
    SELECT 1
    FROM agent_accounts AS keep
    WHERE keep.account_id = 'skylerbaird@me.com'
      AND keep.agent_id = agent_accounts.agent_id
  );

DELETE FROM access_subject_permissions
WHERE account_id = 'skylerbaird_me_com'
  AND EXISTS (
    SELECT 1
    FROM access_subject_permissions AS keep
    WHERE keep.account_id = 'skylerbaird@me.com'
      AND keep.subject = access_subject_permissions.subject
      AND keep.workspace_id = access_subject_permissions.workspace_id
  );

DELETE FROM message_extractions
WHERE account_id = 'skylerbaird_me_com'
  AND EXISTS (
    SELECT 1
    FROM message_extractions AS keep
    WHERE keep.account_id = 'skylerbaird@me.com'
      AND keep.workspace_id = message_extractions.workspace_id
      AND keep.source_message_id = message_extractions.source_message_id
  );

DELETE FROM calendar_events
WHERE account_id = 'skylerbaird_me_com'
  AND EXISTS (
    SELECT 1
    FROM calendar_events AS keep
    WHERE keep.account_id = 'skylerbaird@me.com'
      AND keep.workspace_id = calendar_events.workspace_id
      AND keep.calendar_id = calendar_events.calendar_id
      AND keep.event_uid = calendar_events.event_uid
  );

-- Repoint FK-backed account_id columns.
UPDATE agent_accounts
SET account_id = 'skylerbaird@me.com'
WHERE account_id = 'skylerbaird_me_com';

UPDATE chat_sessions
SET account_id = 'skylerbaird@me.com'
WHERE account_id = 'skylerbaird_me_com';

UPDATE chat_turns
SET account_id = 'skylerbaird@me.com'
WHERE account_id = 'skylerbaird_me_com';

UPDATE chat_citations
SET account_id = 'skylerbaird@me.com'
WHERE account_id = 'skylerbaird_me_com';

UPDATE proposals
SET account_id = 'skylerbaird@me.com'
WHERE account_id = 'skylerbaird_me_com';

UPDATE proposed_actions
SET account_id = 'skylerbaird@me.com'
WHERE account_id = 'skylerbaird_me_com';

UPDATE run_events
SET account_id = 'skylerbaird@me.com'
WHERE account_id = 'skylerbaird_me_com';

UPDATE tool_calls
SET account_id = 'skylerbaird@me.com'
WHERE account_id = 'skylerbaird_me_com';

-- Repoint non-FK account_id columns.
UPDATE access_subject_permissions
SET account_id = 'skylerbaird@me.com'
WHERE account_id = 'skylerbaird_me_com';

UPDATE email_threads
SET account_id = 'skylerbaird@me.com'
WHERE account_id = 'skylerbaird_me_com';

UPDATE email_messages
SET account_id = 'skylerbaird@me.com'
WHERE account_id = 'skylerbaird_me_com';

UPDATE memory_chunks
SET account_id = 'skylerbaird@me.com'
WHERE account_id = 'skylerbaird_me_com';

UPDATE embedding_jobs
SET account_id = 'skylerbaird@me.com'
WHERE account_id = 'skylerbaird_me_com';

UPDATE tasks
SET account_id = 'skylerbaird@me.com'
WHERE account_id = 'skylerbaird_me_com';

UPDATE decisions
SET account_id = 'skylerbaird@me.com'
WHERE account_id = 'skylerbaird_me_com';

UPDATE followups
SET account_id = 'skylerbaird@me.com'
WHERE account_id = 'skylerbaird_me_com';

UPDATE message_extractions
SET account_id = 'skylerbaird@me.com'
WHERE account_id = 'skylerbaird_me_com';

UPDATE run_search_audits
SET account_id = 'skylerbaird@me.com'
WHERE account_id = 'skylerbaird_me_com';

UPDATE action_events
SET account_id = 'skylerbaird@me.com'
WHERE account_id = 'skylerbaird_me_com';

UPDATE briefings
SET account_id = 'skylerbaird@me.com'
WHERE account_id = 'skylerbaird_me_com';

UPDATE model_usage_events
SET account_id = 'skylerbaird@me.com'
WHERE account_id = 'skylerbaird_me_com';

UPDATE model_audit_logs
SET account_id = 'skylerbaird@me.com'
WHERE account_id = 'skylerbaird_me_com';

UPDATE calendar_events
SET account_id = 'skylerbaird@me.com'
WHERE account_id = 'skylerbaird_me_com';

DELETE FROM connected_accounts
WHERE id = 'skylerbaird_me_com';
