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

Set these local values in `.dev.vars`:

- `AIG_ACCOUNT_ID`
- `AIG_GATEWAY_ID`
- `CLAUDE_MODEL` (optional, for Claude path)
- `CLAUDE_API_KEY` (optional, for Claude path)
- `WORKER_API_KEY` (required)
- `MAILBOX_SKYLERBAIRD_ME_COM` (`SkylerBaird@me.com`)
- optional: `CF_AIG_AUTH_TOKEN`

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
npx wrangler secret put CF_AIG_AUTH_TOKEN
npx wrangler secret put WORKER_API_KEY
```

`CLAUDE_API_KEY` is optional for now because `/ai/test` uses Workers AI binding.

Set non-secret AI Gateway vars in `wrangler.toml`:

- `AIG_ACCOUNT_ID`
- `AIG_GATEWAY_ID`
- `CLAUDE_MODEL`

Model switching:

- Update `CLAUDE_MODEL` to the model you want to target (or switch routing in AI Gateway policy).
- Redeploy Worker: `npx wrangler deploy`

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
- Mail sync runs via Mac IMAP agent (`agent/`) for now.
- Test Workers AI wiring with `POST /ai/test`.
- Outbound mail queue endpoints are:
  - `POST /mail/send` (enqueue)
  - `GET /mail/outbound/next` (agent claim)
  - `POST /mail/outbound/result` (sent/failed ack)

## Secret storage clarification

- `wrangler secret put` stores Worker secrets encrypted at rest by Cloudflare.
- Those secrets are available to your Worker at runtime as plaintext environment values.
- iCloud app-specific password is stored only in the local Mac agent `.env` file.
