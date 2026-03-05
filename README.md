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
- `db/migrations/0001_init.sql`
- `db/migrations/0002_outbound_messages.sql`
- `db/migrations/0003_email_canonical_schema.sql`
- `wrangler.toml`
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
   - update `wrangler.toml` with the returned DEV D1 `database_id`
4. Set dev secrets:
   - `npx wrangler secret put OPENAI_API_KEY`
   - `npx wrangler secret put CF_AIG_AUTH_TOKEN` (optional)
   - `npx wrangler secret put WORKER_API_KEY` (required)
5. Apply all migrations:
   - `npx wrangler d1 migrations apply sky-ai-dev`
6. Deploy:
   - `npx wrangler deploy`
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
  - Chunking + embedding + Vectorize indexing when AI Gateway credentials are set

## Historical Backfill (Controlled)

Use the Mac agent one-off backfill command. This is checkpointed and dedupe-safe.

1. In `agent/.env`, set optional backfill vars (`BACKFILL_*`) or pass args.
2. Run from `agent/`:
   - `npm run backfill -- --since=2024-01-01 --mailboxes=INBOX`
   - optional: `--until=2024-12-31 --batchSize=25 --delayMs=250`
3. Progress checkpoint is written to `data/backfill-state.json`.
