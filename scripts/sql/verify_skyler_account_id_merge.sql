-- Pre/post verification for migration 0026_merge_skyler_connected_account_ids.sql

-- 1) Connected account rows should end with only canonical id present.
SELECT id, workspace_id, email, identifier, created_at, updated_at
FROM connected_accounts
WHERE id IN ('skylerbaird@me.com', 'skylerbaird_me_com')
ORDER BY id;

-- 2) Remaining source-id references (all should be 0 after migration).
SELECT 'agent_accounts' AS table_name, COUNT(*) AS remaining FROM agent_accounts WHERE account_id = 'skylerbaird_me_com';
SELECT 'chat_sessions' AS table_name, COUNT(*) AS remaining FROM chat_sessions WHERE account_id = 'skylerbaird_me_com';
SELECT 'chat_turns' AS table_name, COUNT(*) AS remaining FROM chat_turns WHERE account_id = 'skylerbaird_me_com';
SELECT 'chat_citations' AS table_name, COUNT(*) AS remaining FROM chat_citations WHERE account_id = 'skylerbaird_me_com';
SELECT 'proposals' AS table_name, COUNT(*) AS remaining FROM proposals WHERE account_id = 'skylerbaird_me_com';
SELECT 'proposed_actions' AS table_name, COUNT(*) AS remaining FROM proposed_actions WHERE account_id = 'skylerbaird_me_com';
SELECT 'run_events' AS table_name, COUNT(*) AS remaining FROM run_events WHERE account_id = 'skylerbaird_me_com';
SELECT 'tool_calls' AS table_name, COUNT(*) AS remaining FROM tool_calls WHERE account_id = 'skylerbaird_me_com';
SELECT 'access_subject_permissions' AS table_name, COUNT(*) AS remaining FROM access_subject_permissions WHERE account_id = 'skylerbaird_me_com';
SELECT 'email_threads' AS table_name, COUNT(*) AS remaining FROM email_threads WHERE account_id = 'skylerbaird_me_com';
SELECT 'email_messages' AS table_name, COUNT(*) AS remaining FROM email_messages WHERE account_id = 'skylerbaird_me_com';
SELECT 'memory_chunks' AS table_name, COUNT(*) AS remaining FROM memory_chunks WHERE account_id = 'skylerbaird_me_com';
SELECT 'embedding_jobs' AS table_name, COUNT(*) AS remaining FROM embedding_jobs WHERE account_id = 'skylerbaird_me_com';
SELECT 'tasks' AS table_name, COUNT(*) AS remaining FROM tasks WHERE account_id = 'skylerbaird_me_com';
SELECT 'decisions' AS table_name, COUNT(*) AS remaining FROM decisions WHERE account_id = 'skylerbaird_me_com';
SELECT 'followups' AS table_name, COUNT(*) AS remaining FROM followups WHERE account_id = 'skylerbaird_me_com';
SELECT 'message_extractions' AS table_name, COUNT(*) AS remaining FROM message_extractions WHERE account_id = 'skylerbaird_me_com';
SELECT 'run_search_audits' AS table_name, COUNT(*) AS remaining FROM run_search_audits WHERE account_id = 'skylerbaird_me_com';
SELECT 'action_events' AS table_name, COUNT(*) AS remaining FROM action_events WHERE account_id = 'skylerbaird_me_com';
SELECT 'briefings' AS table_name, COUNT(*) AS remaining FROM briefings WHERE account_id = 'skylerbaird_me_com';
SELECT 'model_usage_events' AS table_name, COUNT(*) AS remaining FROM model_usage_events WHERE account_id = 'skylerbaird_me_com';
SELECT 'model_audit_logs' AS table_name, COUNT(*) AS remaining FROM model_audit_logs WHERE account_id = 'skylerbaird_me_com';
SELECT 'calendar_events' AS table_name, COUNT(*) AS remaining FROM calendar_events WHERE account_id = 'skylerbaird_me_com';

-- 3) Canonical-id row counts after merge.
SELECT 'agent_accounts' AS table_name, COUNT(*) AS canonical_rows FROM agent_accounts WHERE account_id = 'skylerbaird@me.com';
SELECT 'chat_sessions' AS table_name, COUNT(*) AS canonical_rows FROM chat_sessions WHERE account_id = 'skylerbaird@me.com';
SELECT 'chat_turns' AS table_name, COUNT(*) AS canonical_rows FROM chat_turns WHERE account_id = 'skylerbaird@me.com';
SELECT 'chat_citations' AS table_name, COUNT(*) AS canonical_rows FROM chat_citations WHERE account_id = 'skylerbaird@me.com';
SELECT 'proposals' AS table_name, COUNT(*) AS canonical_rows FROM proposals WHERE account_id = 'skylerbaird@me.com';
SELECT 'proposed_actions' AS table_name, COUNT(*) AS canonical_rows FROM proposed_actions WHERE account_id = 'skylerbaird@me.com';
SELECT 'run_events' AS table_name, COUNT(*) AS canonical_rows FROM run_events WHERE account_id = 'skylerbaird@me.com';
SELECT 'tool_calls' AS table_name, COUNT(*) AS canonical_rows FROM tool_calls WHERE account_id = 'skylerbaird@me.com';
SELECT 'access_subject_permissions' AS table_name, COUNT(*) AS canonical_rows FROM access_subject_permissions WHERE account_id = 'skylerbaird@me.com';
SELECT 'email_threads' AS table_name, COUNT(*) AS canonical_rows FROM email_threads WHERE account_id = 'skylerbaird@me.com';
SELECT 'email_messages' AS table_name, COUNT(*) AS canonical_rows FROM email_messages WHERE account_id = 'skylerbaird@me.com';
SELECT 'memory_chunks' AS table_name, COUNT(*) AS canonical_rows FROM memory_chunks WHERE account_id = 'skylerbaird@me.com';
SELECT 'embedding_jobs' AS table_name, COUNT(*) AS canonical_rows FROM embedding_jobs WHERE account_id = 'skylerbaird@me.com';
SELECT 'tasks' AS table_name, COUNT(*) AS canonical_rows FROM tasks WHERE account_id = 'skylerbaird@me.com';
SELECT 'decisions' AS table_name, COUNT(*) AS canonical_rows FROM decisions WHERE account_id = 'skylerbaird@me.com';
SELECT 'followups' AS table_name, COUNT(*) AS canonical_rows FROM followups WHERE account_id = 'skylerbaird@me.com';
SELECT 'message_extractions' AS table_name, COUNT(*) AS canonical_rows FROM message_extractions WHERE account_id = 'skylerbaird@me.com';
SELECT 'run_search_audits' AS table_name, COUNT(*) AS canonical_rows FROM run_search_audits WHERE account_id = 'skylerbaird@me.com';
SELECT 'action_events' AS table_name, COUNT(*) AS canonical_rows FROM action_events WHERE account_id = 'skylerbaird@me.com';
SELECT 'briefings' AS table_name, COUNT(*) AS canonical_rows FROM briefings WHERE account_id = 'skylerbaird@me.com';
SELECT 'model_usage_events' AS table_name, COUNT(*) AS canonical_rows FROM model_usage_events WHERE account_id = 'skylerbaird@me.com';
SELECT 'model_audit_logs' AS table_name, COUNT(*) AS canonical_rows FROM model_audit_logs WHERE account_id = 'skylerbaird@me.com';
SELECT 'calendar_events' AS table_name, COUNT(*) AS canonical_rows FROM calendar_events WHERE account_id = 'skylerbaird@me.com';
