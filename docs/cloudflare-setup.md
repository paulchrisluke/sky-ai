# Cloudflare-First Setup

This project now uses Cloudflare as the long-term system of record.

## What this stack owns

- Ingest Worker (`src/worker.ts`): ingestion + outbound mail queue API
- API Worker (`workers/api/src/worker.ts`): chat, briefing, extraction, action approvals
- Jobs Worker (`workers/jobs/src/worker.ts`): queue consumer + cron background processing
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
- `OPENAI_MODEL` (default `gpt-4o-mini`)
- `OPENAI_EMBEDDING_MODEL` (default `text-embedding-3-small`)
- `OPENAI_API_KEY`
- `WORKER_API_KEY` (required)
- `MAILBOX_SKYLERBAIRD_ME_COM` (`SkylerBaird@me.com`)
- optional: `CF_AIG_AUTH_TOKEN`

## 2) Provision DEV infrastructure

```bash
npx wrangler d1 create sky-ai-dev
npx wrangler r2 bucket create sky-ai-artifacts-dev
npx wrangler vectorize create sky-ai-memory-dev --dimensions=1536 --metric=cosine
npx wrangler queues create sky-ai-embeddings-dev
```

Then update `wrangler.toml` with the returned DEV D1 `database_id`.

Apply schema:

```bash
npx wrangler d1 migrations apply sky-ai-dev
```

## 3) Push secrets (DEV)

```bash
npx wrangler secret put OPENAI_API_KEY
npx wrangler secret put CF_AIG_AUTH_TOKEN
npx wrangler secret put WORKER_API_KEY
```

Set non-secret AI Gateway vars in `wrangler.toml`:

- `AIG_ACCOUNT_ID`
- `AIG_GATEWAY_ID`
- `OPENAI_MODEL`
- `OPENAI_EMBEDDING_MODEL`

Model switching:

- Update `OPENAI_MODEL` to the model you want to target (or switch routing in AI Gateway policy).
- Redeploy Worker: `npx wrangler deploy`

## 4) Deploy DEV worker

```bash
npx wrangler deploy
npx wrangler deploy --config wrangler.api.toml
npx wrangler deploy --config wrangler.jobs.toml
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

### D1 schema parity (`sky-ai-prod`)

Goal: prod must have the same applied migration set as dev before full cutover.

Check pending migrations:

```bash
npx wrangler d1 migrations list sky-ai-dev
npx wrangler d1 migrations list sky-ai-prod
```

Apply any unapplied migrations to prod:

```bash
npx wrangler d1 migrations apply sky-ai-prod
```

Recommended verification:

```bash
npx wrangler d1 migrations list sky-ai-prod
```

Expected result: no unapplied migration files remaining.

## 7) Cloudflare Access (API auth)

No custom keypair generation is needed. Cloudflare Access issues and signs JWTs.

1. In Zero Trust, create a Self-hosted Access application for:
- `sky-ai-api.<your-domain>` or your `workers.dev` API hostname
2. Create an allow policy for your user(s).
3. Copy:
- Issuer: `https://<team>.cloudflareaccess.com`
- Audience tag (`aud`) from the Access app.
4. Set API worker secrets:

```bash
npx wrangler secret put ACCESS_ISSUER --config wrangler.api.toml
npx wrangler secret put ACCESS_AUD --config wrangler.api.toml
npx wrangler secret put ACCESS_ISSUER --config wrangler.api.toml --env prod
npx wrangler secret put ACCESS_AUD --config wrangler.api.toml --env prod
```

5. Grant D1 permissions for each Access subject:

```bash
./scripts/grant-access-subject.sh sky-ai-dev <access-subject> default <account_id> <email> admin active
```

6. Verify auth:
- `GET /auth/whoami`
- `GET /auth/whoami?workspaceId=default&accountId=<account_id>`

### Pending Follow-up (Skyler)

- Waiting on Skyler to open: `https://sky-ai-api.paulchrisluke.workers.dev/auth/whoami`
- Capture Skyler `principal.subject` from response JSON.
- Grant Skyler subject access to mailbox account `SkylerBaird@me.com`.
- Optional admin wildcard grant: set Paul subject access with `account_id='*'` for super-admin scope.

Example commands (dev):

```bash
# Grant one mailbox to a user subject
./scripts/grant-access-subject.sh sky-ai-dev <subject> default SkylerBaird@me.com <email> admin active wrangler.api.toml

# Grant super-admin wildcard across all mailbox accounts in workspace
./scripts/grant-access-subject.sh sky-ai-dev <subject> default '*' <email> admin active wrangler.api.toml
```

## Notes while waiting for Skyler OAuth/Claude key

- `POST /tasks/triage` and `POST /briefings/daily` return safe no-op if `OPENAI_API_KEY` is missing.
- Mail sync is handled by the native macOS agent (`agent-mac`).
- Test AI Gateway OpenAI wiring with `POST /ai/test`.
- Outbound mail queue endpoints are:
  - `POST /mail/send` (enqueue)
  - `GET /mail/outbound/next` (agent claim)
  - `POST /mail/outbound/result` (sent/failed ack)
- Backfill queue endpoint:
  - `POST /mail/backfill` (queues checkpointed historical ingest job metadata)
- Embedding queue endpoint:
  - `POST /jobs/embeddings/process` on the jobs worker (manual drain for queued/retry embeddings)
  - `POST /jobs/embeddings/reclean-noisy` (manual reclean + requeue for noisy chunks)
- Triage backfill endpoint:
  - `POST /jobs/triage/reclassify` (classify existing threads with latest heuristic version)
- Briefing generation endpoints:
  - `POST /jobs/briefing/generate-now` (manual immediate generation for one account)
  - `POST /jobs/sync/process` (drain queued sync jobs including `daily_briefing`)
- Daily briefing is cron-evaluated hourly and enqueued once at 7am local time using each workspace's `workspaces.timezone`.

## Secret storage clarification

- `wrangler secret put` stores Worker secrets encrypted at rest by Cloudflare.
- Those secrets are available to your Worker at runtime as plaintext environment values.
- Native macOS agent secrets are stored in Keychain (with `.env` only as a local dev fallback).
- Embeddings are processed asynchronously through Cloudflare Queue (`EMBEDDING_QUEUE`).
- Embedding quota/rate failures are tracked/retried via D1 `embedding_jobs` and do not block mail ingest.
