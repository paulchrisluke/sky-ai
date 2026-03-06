-- Message direction + thread inbound/outbound timestamps + agent SLA hours.

ALTER TABLE email_messages
  ADD COLUMN direction TEXT NOT NULL DEFAULT 'inbound'
  CHECK (direction IN ('inbound', 'outbound', 'unknown'));

ALTER TABLE email_threads ADD COLUMN last_inbound_at TEXT;
ALTER TABLE email_threads ADD COLUMN last_outbound_at TEXT;

ALTER TABLE agents ADD COLUMN response_sla_hours INTEGER NOT NULL DEFAULT 24;

-- Backfill direction with heuristic priority:
-- 1) mailbox = Sent Messages -> outbound
-- 2) sender matches account email -> outbound
-- 3) everything else we can reasonably classify -> inbound
-- 4) cannot determine -> unknown
UPDATE email_messages
SET direction = 'unknown';

UPDATE email_messages
SET direction = 'outbound'
WHERE lower(COALESCE(mailbox, '')) IN ('sent', 'sent messages');

UPDATE email_messages
SET direction = 'outbound'
WHERE direction != 'outbound'
  AND EXISTS (
    SELECT 1
    FROM accounts a
    WHERE a.workspace_id = email_messages.workspace_id
      AND a.id = email_messages.account_id
      AND lower(
            COALESCE(
              json_extract(email_messages.from_json, '$[0].email'),
              json_extract(email_messages.from_json, '$[0].address'),
              ''
            )
          ) = lower(COALESCE(a.email, a.id, ''))
  );

UPDATE email_messages
SET direction = 'inbound'
WHERE direction = 'unknown'
  AND (
    trim(COALESCE(mailbox, '')) != ''
    OR trim(
         COALESCE(
           json_extract(from_json, '$[0].email'),
           json_extract(from_json, '$[0].address'),
           ''
         )
       ) != ''
  );

-- Backfill thread-level inbound/outbound markers.
UPDATE email_threads
SET last_inbound_at = (
  SELECT MAX(datetime(COALESCE(m.sent_at, m.created_at)))
  FROM email_messages m
  WHERE m.thread_id = email_threads.id
    AND m.direction = 'inbound'
);

UPDATE email_threads
SET last_outbound_at = (
  SELECT MAX(datetime(COALESCE(m.sent_at, m.created_at)))
  FROM email_messages m
  WHERE m.thread_id = email_threads.id
    AND m.direction = 'outbound'
);

-- Keep thread SLA markers current for new writes.
CREATE TRIGGER IF NOT EXISTS update_thread_direction_markers_on_email_insert
AFTER INSERT ON email_messages
FOR EACH ROW
BEGIN
  UPDATE email_threads
  SET
    last_inbound_at = CASE
      WHEN NEW.direction = 'inbound'
        AND (
          last_inbound_at IS NULL
          OR datetime(COALESCE(NEW.sent_at, NEW.created_at)) > datetime(last_inbound_at)
        )
      THEN datetime(COALESCE(NEW.sent_at, NEW.created_at))
      ELSE last_inbound_at
    END,
    last_outbound_at = CASE
      WHEN NEW.direction = 'outbound'
        AND (
          last_outbound_at IS NULL
          OR datetime(COALESCE(NEW.sent_at, NEW.created_at)) > datetime(last_outbound_at)
        )
      THEN datetime(COALESCE(NEW.sent_at, NEW.created_at))
      ELSE last_outbound_at
    END,
    updated_at = CURRENT_TIMESTAMP
  WHERE id = NEW.thread_id;
END;

-- Optional safety: if direction/sent_at is corrected later, recalculate markers.
CREATE TRIGGER IF NOT EXISTS update_thread_direction_markers_on_email_update
AFTER UPDATE OF direction, sent_at ON email_messages
FOR EACH ROW
BEGIN
  UPDATE email_threads
  SET
    last_inbound_at = (
      SELECT MAX(datetime(COALESCE(m.sent_at, m.created_at)))
      FROM email_messages m
      WHERE m.thread_id = NEW.thread_id
        AND m.direction = 'inbound'
    ),
    last_outbound_at = (
      SELECT MAX(datetime(COALESCE(m.sent_at, m.created_at)))
      FROM email_messages m
      WHERE m.thread_id = NEW.thread_id
        AND m.direction = 'outbound'
    ),
    updated_at = CURRENT_TIMESTAMP
  WHERE id = NEW.thread_id;
END;

CREATE INDEX IF NOT EXISTS idx_email_messages_thread_direction_time
  ON email_messages(thread_id, direction, sent_at DESC);

CREATE INDEX IF NOT EXISTS idx_email_threads_account_inbound_outbound
  ON email_threads(workspace_id, account_id, last_inbound_at DESC, last_outbound_at DESC);
