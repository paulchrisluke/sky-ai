# Cloudflare-First Setup

This project now uses Cloudflare as the long-term system of record.

## What this stack owns

- Worker API (`src/worker.ts`): ingestion, triage queueing, briefing queueing
- D1 (`SKY_DB`): normalized entities and job state
- R2 (`SKY_ARTIFACTS`): raw source artifacts
- Vectorize (`SKY_VECTORIZE`): memory index
- Cron triggers: background scheduling

## 1) Authenticate Cloudflare CLI

```bash
npx wrangler login
```

## Local development secrets

Use `.dev.vars` for local `wrangler dev` runs:

```bash
cp .dev.vars.example .dev.vars
```

For deployed envs, always use `wrangler secret put`.

## 2) Provision DEV infrastructure

```bash
npx wrangler d1 create sky-ai-dev
npx wrangler r2 bucket create sky-ai-artifacts-dev
npx wrangler vectorize create sky-ai-memory-dev --dimensions=1536 --metric=cosine
```

Then update `wrangler.toml` with the returned DEV D1 `database_id`.

Apply schema:

```bash
npx wrangler d1 migrations apply sky-ai-dev
```

## 3) Push secrets (DEV)

```bash
npx wrangler secret put GOOGLE_CLIENT_ID
npx wrangler secret put GOOGLE_CLIENT_SECRET
npx wrangler secret put GOOGLE_REDIRECT_URI
npx wrangler secret put TOKEN_ENCRYPTION_KEY
npx wrangler secret put CLAUDE_API_KEY
```

## 4) Deploy DEV worker

```bash
npx wrangler deploy
```

## 5) Validate

```bash
curl "https://<your-worker-subdomain>.workers.dev/health"
```

## 6) PROD provisioning

Repeat D1/R2/Vectorize creation for prod resources, then:

- set PROD IDs in `wrangler.toml`
- set route in `wrangler.toml`
- set PROD secrets using `npx wrangler secret put <NAME> --env prod`
- deploy with `npx wrangler deploy --env prod`

## Notes while waiting for Skyler OAuth/Claude key

- `POST /tasks/triage` and `POST /briefings/daily` return safe no-op if `CLAUDE_API_KEY` is missing.
- Gmail/Calendar OAuth sync wiring should be built directly in Cloudflare next.
