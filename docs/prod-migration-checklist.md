# Production Migration Checklist

Date: March 15, 2026

## Scope

Finalize migration to Swift-first ingestion and prepare legacy Node agent removal with a controlled archive/delete process.

## 1) Skyler Mac Mini Swift App Cutover (Blocking)

1. Install and run `agent-mac` on Skyler Mac Mini.
2. Verify launch agent:
   - `launchctl list | grep com.blawby.agent`
3. Verify logs:
   - `tail -n 100 ~/.blawby/logs/agent.log`
   - Confirm websocket connected, mail/calendar observers started, sync publishes succeeding.
4. Verify ingest endpoints from Mac Mini traffic:
   - `POST /ingest/entities`
   - `POST /ingest/message-chunks`
5. Keep this as the only active publisher path for production.

## 2) Retire Legacy Node Agent (`agent/`)

Current policy:
- Do not delete `agent/` yet.
- No new development in `agent/`.
- Keep for rollback-only during transition.

Archive and delete sequence:

1. Archive step:
   - Move `agent/` to a clearly marked archive path or tag it as deprecated in release notes.
2. Stability window:
   - Run Swift-only production for at least 7 days with no rollback.
3. Delete step:
   - Remove `agent/` only after explicit production sign-off.

## 3) D1 Migration Parity (Dev -> `sky-ai-prod`)

Ensure `sky-ai-prod` has the same migration state as dev before final cutover.

Commands:

```bash
npx wrangler d1 migrations list sky-ai-dev
npx wrangler d1 migrations list sky-ai-prod
npx wrangler d1 migrations apply sky-ai-prod
npx wrangler d1 migrations list sky-ai-prod
```

Success criteria:
- `sky-ai-prod` shows no unapplied migration files.
- API worker + jobs worker operate without schema errors in prod.

## 4) Legacy Backfill Path

- `agent/backfill.js` is retired.
- `/ingest/mail-thread` is deprecated and returns `410`.
- Historical imports should use current ingestion architecture only.
