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

## 2) Provision DEV infrastructure

```bash
./scripts/bootstrap-cloudflare.sh
```

Then update `wrangler.toml` with the returned DEV D1 `database_id`.

## 3) Push secrets (DEV)

```bash
./scripts/set-cloudflare-secrets.sh dev
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
- run `./scripts/set-cloudflare-secrets.sh prod`
- deploy with `npx wrangler deploy --env prod`

## Notes while waiting for Skyler OAuth/Claude key

- `POST /tasks/triage` and `POST /briefings/daily` return safe no-op if `CLAUDE_API_KEY` is missing.
- Gmail/Calendar OAuth sync wiring should be built directly in Cloudflare next.
