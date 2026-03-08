CREATE TABLE IF NOT EXISTS calendar_events (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  calendar_id TEXT NOT NULL,
  calendar_name TEXT,
  event_uid TEXT NOT NULL,
  title TEXT,
  description TEXT,
  location TEXT,
  start_at TEXT NOT NULL,
  end_at TEXT NOT NULL,
  all_day INTEGER NOT NULL DEFAULT 0,
  recurrence_rule TEXT,
  status TEXT NOT NULL DEFAULT 'confirmed',
  organizer_email TEXT,
  organizer_name TEXT,
  attendees_json TEXT NOT NULL DEFAULT '[]',
  source_provider TEXT NOT NULL DEFAULT 'calendar_icloud',
  raw_ical TEXT,
  synced_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (workspace_id) REFERENCES workspaces(id),
  UNIQUE(workspace_id, account_id, calendar_id, event_uid)
);

CREATE INDEX IF NOT EXISTS idx_calendar_events_account_start 
  ON calendar_events(workspace_id, account_id, start_at);

CREATE INDEX IF NOT EXISTS idx_calendar_events_uid 
  ON calendar_events(workspace_id, account_id, event_uid);
