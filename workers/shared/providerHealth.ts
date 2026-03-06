export type ProviderHealthState = {
  provider: string;
  status: 'healthy' | 'disabled';
  disabledUntil: string | null;
  reasonCode: string | null;
  lastError: string | null;
  updatedAt: string | null;
};

export async function getProviderHealthState(db: D1Database, provider: string): Promise<ProviderHealthState | null> {
  const row = await db
    .prepare(
      `SELECT
         provider,
         status,
         disabled_until,
         reason_code,
         last_error,
         updated_at
       FROM ai_provider_health
       WHERE provider = ?
       LIMIT 1`
    )
    .bind(provider)
    .first<{
      provider: string;
      status: string;
      disabled_until: string | null;
      reason_code: string | null;
      last_error: string | null;
      updated_at: string | null;
    }>();

  if (!row) return null;
  return {
    provider: row.provider,
    status: row.status === 'disabled' ? 'disabled' : 'healthy',
    disabledUntil: row.disabled_until,
    reasonCode: row.reason_code,
    lastError: row.last_error,
    updatedAt: row.updated_at
  };
}

export async function isProviderTemporarilyDisabled(db: D1Database, provider: string): Promise<boolean> {
  const row = await db
    .prepare(
      `SELECT
         CASE
           WHEN status = 'disabled'
             AND disabled_until IS NOT NULL
             AND disabled_until > datetime('now', 'utc')
           THEN 1
           ELSE 0
         END AS is_disabled
       FROM ai_provider_health
       WHERE provider = ?
       LIMIT 1`
    )
    .bind(provider)
    .first<{ is_disabled: number | null }>();

  return Number(row?.is_disabled || 0) === 1;
}

export async function disableProviderTemporarily(
  db: D1Database,
  provider: string,
  opts: { minutes: number; reasonCode: string; lastError: string }
): Promise<void> {
  const minutes = Math.max(1, Math.min(24 * 60, Math.trunc(opts.minutes)));
  await db
    .prepare(
      `INSERT INTO ai_provider_health (
         provider,
         status,
         disabled_until,
         reason_code,
         last_error,
         updated_at
       ) VALUES (
         ?,
         'disabled',
         datetime('now', 'utc', ?),
         ?,
         ?,
         CURRENT_TIMESTAMP
       )
       ON CONFLICT(provider) DO UPDATE SET
         status = 'disabled',
         disabled_until = datetime('now', 'utc', excluded.disabled_until),
         reason_code = excluded.reason_code,
         last_error = excluded.last_error,
         updated_at = CURRENT_TIMESTAMP`
    )
    .bind(provider, `+${minutes} minutes`, opts.reasonCode, opts.lastError)
    .run();
}

export async function markProviderHealthy(db: D1Database, provider: string): Promise<void> {
  await db
    .prepare(
      `INSERT INTO ai_provider_health (
         provider,
         status,
         disabled_until,
         reason_code,
         last_error,
         updated_at
       ) VALUES (?, 'healthy', NULL, NULL, NULL, CURRENT_TIMESTAMP)
       ON CONFLICT(provider) DO UPDATE SET
         status = 'healthy',
         disabled_until = NULL,
         reason_code = NULL,
         last_error = NULL,
         updated_at = CURRENT_TIMESTAMP`
    )
    .bind(provider)
    .run();
}
