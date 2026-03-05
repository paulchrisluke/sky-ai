# sky-ai

Cloudflare-native backend for Sky AI.

## Architecture

- Cloudflare Workers API: ingestion, task orchestration, briefings
- D1: normalized state + sync jobs
- R2: raw artifacts
- Vectorize: memory retrieval index
- Workers Cron: scheduled sync/briefing jobs

## Project Layout

- `src/worker.ts`
- `src/types.d.ts`
- `db/migrations/0001_init.sql`
- `wrangler.toml`
- `docs/cloudflare-setup.md`

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
   - `npx wrangler d1 migrations apply sky-ai-dev`
4. Set dev secrets:
   - `npx wrangler secret put GOOGLE_CLIENT_ID`
   - `npx wrangler secret put GOOGLE_CLIENT_SECRET`
   - `npx wrangler secret put GOOGLE_REDIRECT_URI`
   - `npx wrangler secret put TOKEN_ENCRYPTION_KEY`
   - `npx wrangler secret put CLAUDE_API_KEY`
5. Deploy:
   - `npx wrangler deploy`
6. Validate:
   - `curl "https://<worker-subdomain>.workers.dev/health"`

## Local Dev Secrets

- Use `.dev.vars` for local-only values with `wrangler dev`.
- Start from template:
  - `cp .dev.vars.example .dev.vars`
- `.dev.vars` is gitignored; `.dev.vars.example` is committed.
- For deployed environments, use `wrangler secret put ...` (not `.dev.vars`).
- Claude calls are routed via Cloudflare AI Gateway using:
  - `AIG_ACCOUNT_ID`
  - `AIG_GATEWAY_ID`
  - `CLAUDE_MODEL`
  - `CLAUDE_API_KEY`
  - optional `CF_AIG_AUTH_TOKEN`

## Secrets Clarification

- `wrangler secret put` is encrypted at rest by Cloudflare.
- If you store OAuth tokens in D1, encrypt them yourself before DB write.
- `TOKEN_ENCRYPTION_KEY` is used for that application-level encryption.

## Status While Waiting On Skyler OAuth/Claude Key

- Cloudflare backend can be deployed now.
- `/tasks/triage` and `/briefings/daily` are safe no-op if `CLAUDE_API_KEY` is missing.
- `/ai/test` verifies Claude routing through AI Gateway once configured.
- Next implementation step: Google OAuth + sync pipeline directly in Worker.
