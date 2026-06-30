-- Idempotent fixture data for MCP E2E tests (no Mac agent required).
-- Workspace + connected account + sample mail/calendar/iMessage rows.

INSERT OR IGNORE INTO workspaces (id, name, status, timezone, created_at, updated_at)
VALUES ('default', 'Sky AI Dev', 'active', 'America/Chicago', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP);

INSERT OR IGNORE INTO connected_accounts (
  id, workspace_id, label, email, status, created_at, updated_at,
  provider, identifier, display_name, config_json, onboarding_complete
) VALUES (
  'skylerbaird@me.com',
  'default',
  'Skyler Baird',
  'skylerbaird@me.com',
  'active',
  CURRENT_TIMESTAMP,
  CURRENT_TIMESTAMP,
  'email_icloud',
  'skylerbaird@me.com',
  'Skyler Baird',
  '{}',
  1
);

INSERT OR IGNORE INTO email_threads (
  id, workspace_id, account_email, account_id, mailbox, thread_external_id,
  subject, first_message_at, last_message_at, created_at, updated_at
) VALUES (
  'fixture-thread-1',
  'default',
  'skylerbaird@me.com',
  'skylerbaird@me.com',
  'INBOX',
  'fixture-thread-ext-1',
  'Call tomorrow about Q3 planning',
  datetime('now', '-2 hours'),
  datetime('now', '-1 hours'),
  CURRENT_TIMESTAMP,
  CURRENT_TIMESTAMP
);

INSERT OR IGNORE INTO email_messages (
  id, workspace_id, thread_id, account_email, account_id, mailbox,
  source_message_key, subject, sent_at, from_json, to_json, snippet,
  created_at, updated_at
) VALUES (
  'fixture-msg-1',
  'default',
  'fixture-thread-1',
  'skylerbaird@me.com',
  'skylerbaird@me.com',
  'INBOX',
  'fixture:msg:1',
  'Call tomorrow about Q3 planning',
  datetime('now', '-1 hours'),
  '[{"email":"alice@example.com","name":"Alice Chen"}]',
  '[{"email":"skylerbaird@me.com","name":"Skyler Baird"}]',
  'Can we talk tomorrow at 2pm about the Q3 roadmap?',
  CURRENT_TIMESTAMP,
  CURRENT_TIMESTAMP
);

INSERT OR IGNORE INTO calendar_events (
  id, workspace_id, account_id, calendar_id, calendar_name, event_uid,
  title, description, location, start_at, end_at, all_day, status,
  organizer_email, organizer_name, attendees_json, created_at, updated_at
) VALUES (
  'fixture-cal-1',
  'default',
  'skylerbaird@me.com',
  'primary',
  'Personal',
  'fixture-cal-uid-1',
  'Call with Alice — Q3 planning',
  'Follow up from email thread',
  'Zoom',
  datetime('now', '+1 day', 'start of day', '+14 hours'),
  datetime('now', '+1 day', 'start of day', '+15 hours'),
  0,
  'confirmed',
  'alice@example.com',
  'Alice Chen',
  '[{"email":"skylerbaird@me.com","name":"Skyler Baird"}]',
  CURRENT_TIMESTAMP,
  CURRENT_TIMESTAMP
);

INSERT OR IGNORE INTO imessage_messages (
  id, workspace_id, account_id, source_row_id, sender, body_text, sent_at,
  created_at, updated_at
) VALUES (
  'fixture-im-1',
  'default',
  'skylerbaird@me.com',
  900001,
  'Alice Chen',
  'Still good for our call tomorrow?',
  datetime('now', '-30 minutes'),
  CURRENT_TIMESTAMP,
  CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS email_entities (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  message_id TEXT NOT NULL,
  thread_id TEXT,
  entity_type TEXT NOT NULL,
  direction TEXT NOT NULL DEFAULT 'unknown',
  counterparty_name TEXT,
  counterparty_email TEXT,
  amount_cents INTEGER,
  currency TEXT,
  due_date TEXT,
  reference_number TEXT,
  status TEXT DEFAULT 'unknown',
  action_required INTEGER NOT NULL DEFAULT 0,
  action_description TEXT,
  risk_level TEXT DEFAULT 'low',
  confidence REAL DEFAULT 0.5,
  raw_json TEXT,
  extracted_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT OR IGNORE INTO email_entities (
  id, workspace_id, account_id, message_id, thread_id, entity_type,
  direction, counterparty_name, counterparty_email, action_required,
  action_description, risk_level, extracted_at, created_at, updated_at
) VALUES (
  'fixture-entity-1',
  'default',
  'skylerbaird@me.com',
  'fixture-msg-1',
  'fixture-thread-1',
  'request',
  'inbound',
  'Alice Chen',
  'alice@example.com',
  1,
  'Reply to confirm Q3 planning call',
  'medium',
  CURRENT_TIMESTAMP,
  CURRENT_TIMESTAMP,
  CURRENT_TIMESTAMP
);
