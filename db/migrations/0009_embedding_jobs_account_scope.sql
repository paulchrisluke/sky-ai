ALTER TABLE embedding_jobs ADD COLUMN account_id TEXT;

UPDATE embedding_jobs
SET account_id = (
  SELECT lower(
    COALESCE(
      json_extract(n.body_json, '$.accountId'),
      json_extract(n.body_json, '$.accountEmail')
    )
  )
  FROM normalized_records n
  WHERE n.id = embedding_jobs.source_record_id
)
WHERE account_id IS NULL;

CREATE INDEX IF NOT EXISTS idx_embedding_jobs_scope_status_next
  ON embedding_jobs(workspace_id, account_id, status, next_attempt_at);
