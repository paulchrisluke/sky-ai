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
- `scripts/bootstrap-cloudflare.sh`
- `scripts/set-cloudflare-secrets.sh`
- `docs/cloudflare-setup.md`

## Quickstart

1. Install dependencies:
   - `npm install`
2. Authenticate:
   - `npx wrangler login`
3. Provision dev infra:
   - `./scripts/bootstrap-cloudflare.sh`
4. Set dev secrets:
   - `./scripts/set-cloudflare-secrets.sh dev`
5. Deploy:
   - `npx wrangler deploy`
6. Validate:
   - `curl "https://<worker-subdomain>.workers.dev/health"`

## Status While Waiting On Skyler OAuth/Claude Key

- Cloudflare backend can be deployed now.
- `/tasks/triage` and `/briefings/daily` are safe no-op if `CLAUDE_API_KEY` is missing.
- Next implementation step: Google OAuth + sync pipeline directly in Worker.
