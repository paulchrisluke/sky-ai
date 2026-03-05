# sky-ai

Cloudflare backend + Mac-hosted mailbox connector for Sky AI.

## Architecture

- Cloudflare Workers API: ingestion, task orchestration, briefings
- D1: normalized state + sync jobs
- R2: raw artifacts
- Vectorize: memory retrieval index
- Workers Cron: scheduled sync/briefing jobs
- Mac Mailbox Agent (`agent/`): IMAP sync from iCloud mailboxes to Worker ingest endpoint
- PM2 on Mac: process persistence and always-on connectivity

## Project Layout

- `src/worker.ts`
- `src/types.d.ts`
- `workers/api/src/worker.ts`
- `workers/jobs/src/worker.ts`
- `db/migrations/0001_init.sql`
- `db/migrations/0002_outbound_messages.sql`
- `db/migrations/0003_email_canonical_schema.sql`
- `db/migrations/0004_embedding_jobs.sql`
- `db/migrations/0005_chat_sessions_and_actions.sql`
- `db/migrations/0006_account_id_on_email_memory.sql`
- `db/migrations/0007_action_extraction_and_briefing.sql`
- `db/migrations/0008_access_subject_permissions.sql`
- `wrangler.toml`
- `wrangler.api.toml`
- `wrangler.jobs.toml`
- `docs/cloudflare-setup.md`
- `agent/index.js`
- `agent/.env.example`
- `agent/ecosystem.config.cjs`
- `docs/mac-agent-setup.md`

## Quickstart

1. Install dependencies:
   - `npm install`
2. Authenticate:
   - `npx wrangler login`
3. Provision dev infra:
   - `npx wrangler d1 create sky-ai-dev`
   - `npx wrangler r2 bucket create sky-ai-artifacts-dev`
   - `npx wrangler vectorize create sky-ai-memory-dev --dimensions=1536 --metric=cosine`
   - `npx wrangler queues create sky-ai-embeddings-dev`
   - update `wrangler.toml` with the returned DEV D1 `database_id`
4. Set dev secrets:
   - `npx wrangler secret put OPENAI_API_KEY`
   - `npx wrangler secret put CF_AIG_AUTH_TOKEN` (optional)
   - `npx wrangler secret put WORKER_API_KEY` (required)
5. Apply all migrations:
   - `npx wrangler d1 migrations apply sky-ai-dev`
6. Deploy:
   - `npx wrangler deploy`
   - `npx wrangler deploy --config wrangler.api.toml`
   - `npx wrangler deploy --config wrangler.jobs.toml`
7. Validate:
   - `curl "https://<worker-subdomain>.workers.dev/health"`

Use the auto-generated Worker domain by default:

- `https://sky-ai.paulchrisluke.workers.dev`
- No custom DNS hostname is required for normal API use.

## Local Dev Secrets

- Use `.dev.vars` for local-only values with `wrangler dev`.
- Start from template:
  - `cp .dev.vars.example .dev.vars`
- `.dev.vars` is gitignored; `.dev.vars.example` is committed.
- For deployed environments, use `wrangler secret put ...` (not `.dev.vars`).
- OpenAI calls are routed via Cloudflare AI Gateway using:
  - `AIG_ACCOUNT_ID`
  - `AIG_GATEWAY_ID`
  - `OPENAI_MODEL`
  - `OPENAI_EMBEDDING_MODEL`
  - `OPENAI_API_KEY`
  - optional `CF_AIG_AUTH_TOKEN`
- To switch models, change `OPENAI_MODEL` and redeploy.
- Mailbox identity vars:
  - `MAILBOX_SKYLERBAIRD_ME_COM` (`SkylerBaird@me.com`)

## Secrets Clarification

- `wrangler secret put` is encrypted at rest by Cloudflare.
- In the current setup, iCloud app-specific password is used only by the Mac agent (`agent/.env`).
- Worker secret `WORKER_API_KEY` is required for agent <-> Worker auth.
- `OPENAI_API_KEY` is required for AI Gateway OpenAI-based triage/briefing and `/ai/test`.

## Status While Waiting On Skyler OAuth/Claude Key

- Cloudflare backend can be deployed now.
- `/tasks/triage` and `/briefings/daily` are safe no-op if `OPENAI_API_KEY` is missing.
- `/ai/test` verifies OpenAI via Cloudflare AI Gateway.
- iCloud mailbox sync can run now via the local Mac agent (`agent/`) with app-specific passwords.
- Email capabilities now include:
  - Sync of `INBOX` (or configured mailboxes) via IMAP
  - SMTP send on behalf of the mailbox via outbound queue (`/mail/send`)
  - Canonical persistence in D1 (`email_threads`, `email_messages`, participants)
  - Idempotent ingest keys (`source_message_key`) to prevent duplicates
  - Async chunking + embedding + Vectorize indexing via Cloudflare Queue
  - Embedding retry queue state (`embedding_jobs`) with exponential backoff on quota/rate errors

## Embedding Recovery

- `POST /ingest/mail-thread` never fails due to embedding quota; it stores mail and enqueues embedding work.
- Cron drains embedding retries every 15 minutes.
- You can manually trigger processing:
  - `curl -X POST "https://<worker>.workers.dev/embeddings/process" -H "authorization: Bearer <WORKER_API_KEY>"`

## API Worker (Chat/Actions)

- API worker health: `GET /health`
- Citation-required chat:
  - `GET /ws/chat?workspaceId=default&accountId=<account_id>` (websocket)
  - WS events: `run.started`, `tool.progress`, `run.completed`, `run.failed`, `run.cancelled`
  - `POST /chat/query`
  - Intents supported now:
    - `today_actions`
    - `find_email`
    - `thread_summary`
- Action extraction + briefing:
  - `POST /extraction/run`
  - `GET /briefing/today?workspaceId=...&accountId=...`
- Approval-only actions:
  - `POST /actions/propose`
  - `POST /actions/approve`
- Durable Object coordinator class: `ChatCoordinator`
- Event replay:
  - `GET /sessions/:sessionId/events?since=<timestamp>&limit=...`
  - `GET /sessions/:sessionId/events?lastEventId=<rowid_cursor>&limit=...`
  - WS reconnect supports `lastEventId` query param on `/ws/chat`.

## Access Auth (Step 3)

- Implemented in all HTTP workers (`ingest`, `api`, `jobs`):
  - Cloudflare Access JWT verification (RS256 via JWKS)
  - Optional API key bypass for service traffic
- Authorization mapping table:
  - `access_subject_permissions` (migration `0008`)
  - `subject -> workspace_id/account_id` with active status

Current strict policy:

- `api` worker requires Access JWT (`ACCESS_AUTH_ENABLED="true"` in `wrangler.api.toml`)
- `ingest` and `jobs` also run with `ACCESS_AUTH_ENABLED="true"`; machine traffic uses API key bypass (`ALLOW_API_KEY_BYPASS="true"`)

Set Worker vars for `api` (dev and prod):

- `ACCESS_AUTH_ENABLED="true"`
- `ACCESS_ISSUER="https://<your-team>.cloudflareaccess.com"`
- `ACCESS_AUD="<access-audience-tag>"`
- optional `ACCESS_JWKS_URL` (defaults to `${ACCESS_ISSUER}/cdn-cgi/access/certs`)

Set vars with Wrangler:

- `npx wrangler secret put ACCESS_ISSUER --config wrangler.api.toml`
- `npx wrangler secret put ACCESS_AUD --config wrangler.api.toml`
- `npx wrangler secret put ACCESS_ISSUER --config wrangler.api.toml --env prod`
- `npx wrangler secret put ACCESS_AUD --config wrangler.api.toml --env prod`

Grant an Access subject permission (example):

```sql
INSERT INTO access_subject_permissions
  (id, subject, email, workspace_id, account_id, role, status, created_at, updated_at)
VALUES
  ('perm-1', 'access-sub-uuid', 'user@example.com', 'default', 'skylerbaird@me.com', 'admin', 'active', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP);
```

Or use helper script:

- `./scripts/grant-access-subject.sh sky-ai-dev <access-subject> default <account_id> <email> admin active`

Validation endpoint:

- `GET /auth/whoami`
- `GET /auth/whoami?workspaceId=default`
- `GET /auth/whoami?workspaceId=default&accountId=<account_id>`

## Jobs Worker

- Worker URL: `https://sky-ai-jobs.paulchrisluke.workers.dev`
- Owns queue consumer + cron processing:
  - embedding queue consumption
  - embedding retry draining
  - scheduled sync/briefing job enqueue
- Manual embedding drain:
  - `POST /jobs/embeddings/process`

## Historical Backfill (Controlled)

Use the Mac agent one-off backfill command. This is checkpointed and dedupe-safe.

1. In `agent/.env`, set optional backfill vars (`BACKFILL_*`) or pass args.
2. Run from `agent/`:
   - `npm run backfill -- --since=2024-01-01 --mailboxes=INBOX`
   - optional: `--until=2024-12-31 --batchSize=25 --delayMs=250`
3. Progress checkpoint is written to `data/backfill-state.json`.
