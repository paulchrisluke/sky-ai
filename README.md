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

## Status While Waiting On Skyler OAuth/Claude Key

- Cloudflare backend can be deployed now.
- `/tasks/triage` and `/briefings/daily` are safe no-op if `CLAUDE_API_KEY` is missing.
- Next implementation step: Google OAuth + sync pipeline directly in Worker.
