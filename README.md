# sky-ai

Cloudflare backend + native macOS agent (`agent-mac`) for Sky AI.

## Development Mode

- This repo is currently run in dev-only mode.
- Use only root/default environments in Wrangler configs for active work.
- Production deploy/migration npm scripts are intentionally blocked.
- Do not use `--env prod` unless this policy is explicitly changed.

## Architecture

- Cloudflare Workers API: ingestion, task orchestration, briefings
- D1: normalized state + sync jobs
- R2: raw artifacts
- Vectorize: memory retrieval index
- Workers Cron: scheduled sync/briefing jobs
- Native Mac Agent (`agent-mac/`): event-driven Mail/Calendar/Messages ingestion + local processing + WebSocket publish
- Local persistence: SQLite via GRDB (`~/.blawby/blawby.db`)

## Native macOS UI Architecture (Scene-driven SwiftUI)

- Entry point is scene-driven SwiftUI (`@main App`), not a web shell.
- Menu bar is a lightweight status + quick-action hub (`MenuBarExtra`):
  - overall sync progress
  - connection/last-sync status
  - pause/resume sync
  - open dashboard
- Deep workflows live in standard macOS windows via `Window` scenes:
  - `DashboardView` for active source detail and longer-lived interaction
  - `PreferencesView` for configuration
- UI state is shared through controller/view-model style objects (MVC/MVVM blend), with SwiftUI scenes owning lifecycle and AppKit used only for platform integration points.
- UI updates run on main actor/thread (`@MainActor`), with async/background sync work off the UI path.

## Apple-Native Alignment Status (March 15, 2026)

Current alignment:

- Menu bar is lightweight and action-oriented (status + pause/resume + open windows).
- Deep interaction moved into a standard macOS dashboard window (`DashboardWindowController` + `DashboardView`).
- Preferences and dashboard are normal `NSWindow` flows, not popover-only workflows.
- AppDelegate UI responsibilities were split into `AppUIController` to reduce lifecycle coupling.
- Runtime/watcher lifecycle was split into `SyncRuntimeController` to reduce AppDelegate orchestration load.
- Startup dependency composition was split into `AppStartupComposer`.
- Native app commands/shortcuts are wired via SwiftUI `Commands` (Dashboard, Preferences, Pause/Resume, Quit).
- Dashboard now uses a split-view desktop layout with selectable source detail.
- Preferences now run as a SwiftUI scene (`PreferencesView`) with source + connection tabs.

Not yet aligned (next targets):

- `MenuBarPopoverView` still contains minor legacy close-control behavior from earlier popover flow that can be simplified for pure `MenuBarExtra`.
- README-level architecture is now documented, but automated architecture checks (lint/test assertions around thread confinement and UI boundaries) are not in place yet.

## Structure (Living)

- `workers/api`: request-time APIs, query execution, WebSocket coordination, Blawby memory injection
- `workers/jobs`: async/background processing (queue consumers, cron job execution)
- `workers/shared`: shared contracts/utilities (citation contract, run events)
- `workers/api/src/agents/blawby.ts`: Cloudflare Agents SDK memory agent (`BlawbyAgent`)
- `db/migrations`: D1 schema evolution
- `agent-mac/`: native macOS app/agent (Swift) for local ingestion and sync
- `agent/`: legacy Node agent (archive-only after Skyler Mac Mini Swift cutover; do not delete yet)

## Tools

- Runtime: Cloudflare Workers + Durable Objects + Cloudflare Agents SDK (`agents`)
- Data: D1 (`SKY_DB`) + Vectorize (`SKY_VECTORIZE`) + R2 artifacts
- AI: OpenAI models through Cloudflare AI Gateway
- Scheduling: jobs worker cron/queue for platform jobs
- Scheduling: `BlawbyAgent` internal schedules for memory layers
- Auth: Cloudflare Access JWT + optional service API key bypass

## Blawby Skills (Track 2)

- `skillImmediateContext` (every 15m): next-4h calendar + last-2h urgent entities
- `skillShortTermMemory` (hourly): 48h synthesis from entities + upcoming calendar
- `skillLongTermMemory` (daily 3am): recurring counterparty/meeting pattern synthesis
- `skillKnowledgeProfile` (weekly Sun 4am): profile synthesis for prompt-time memory injection
- `getContext()`: returns all memory layers with headers for prompt injection

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

## macOS Direct Distribution (Signed + Notarized)

Use this when shipping `BlawbyAgent.app` outside the Mac App Store.

Use a single script for all macOS app workflows:
- `./scripts/macos-app.sh dev-install`
- `./scripts/macos-app.sh release`
- `./scripts/macos-app.sh appcast`

Requirements:

- Apple Developer Program membership with Developer ID capability
- Xcode command line tools
- `xcrun notarytool` authentication values:
  - `APPLE_ID`
  - `APPLE_APP_SPECIFIC_PASSWORD`
  - `APPLE_TEAM_ID`

Release command (from repo root):

```bash
APPLE_ID="you@example.com" \
APPLE_APP_SPECIFIC_PASSWORD="<app-specific-password>" \
APPLE_TEAM_ID="<team-id>" \
./scripts/macos-app.sh release
```

What the script does:

- archives and exports a Developer ID signed `BlawbyAgent.app` (Release config)
- verifies signing with `codesign` and Gatekeeper assessment
- packages `.zip` and `.dmg` artifacts
- notarizes both artifacts and staples tickets
- writes SHA256 checksums in `dist/macos/<version+build>/SHA256SUMS.txt`

Default output location:

- `dist/macos/<CFBundleShortVersionString>+<CFBundleVersion>/`

### Sparkle Auto-Updates (Direct Distribution)

`agent-mac` now includes Sparkle and exposes `Check for Updates…` in the `Blawby` command menu.

Before shipping auto-updates:

1. Host release artifacts (`.zip`/`.dmg`) at a stable downloads URL.
2. Generate Sparkle appcast from your release folder:

```bash
RELEASE_DIR="dist/macos/1.0+1" \
DOWNLOAD_URL_PREFIX="https://downloads.blawby.com/releases" \
SPARKLE_PRIVATE_KEY="$HOME/.config/blawby/sparkle_private_ed25519.pem" \
./scripts/macos-app.sh appcast
```

3. Publish generated `appcast.xml` to your feed URL (default in app plist):
   - `https://downloads.blawby.com/appcast.xml`
4. Keep `SUFeedURL` in `agent-mac/BlawbyAgent/Info.plist` aligned with your hosted appcast URL.

## Secrets Clarification

- `wrangler secret put` is encrypted at rest by Cloudflare.
- In the native setup, API secrets are stored in macOS Keychain and non-secret settings in `UserDefaults` (with `.env` fallback for local dev runs).
- Worker secret `WORKER_API_KEY` is required for agent <-> Worker auth.
- `OPENAI_API_KEY` is required for AI Gateway OpenAI-based triage/briefing and `/ai/test`.
- Jobs worker daily briefing schedule policy:
  - Runs at 7am local time per workspace.
  - Timezone source of truth is `workspaces.timezone` (DB), not Wrangler vars.
  - To set a workspace timezone:
    - `UPDATE workspaces SET timezone = 'America/New_York' WHERE id = 'default';`

## Status While Waiting On Skyler OAuth/Claude Key

- Cloudflare backend can be deployed now.
- `/tasks/triage` and `/briefings/daily` are safe no-op if `OPENAI_API_KEY` is missing.
- `/ai/test` verifies OpenAI via Cloudflare AI Gateway.
- iCloud mailbox sync runs via the native local Mac agent (`agent-mac/`).
- Email capabilities now include:
  - Event-driven mail polling/observation from macOS Mail integration
  - Local entity extraction on Mac (`EntityExtractor`) before publish
  - SMTP send on behalf of the mailbox via outbound queue (`/mail/send`)
  - Canonical persistence in D1 (`email_threads`, `email_messages`, participants)
  - Idempotent ingest keys (`source_message_key`) to prevent duplicates
  - Async chunking + embedding + Vectorize indexing via Cloudflare Queue
  - Embedding retry queue state (`embedding_jobs`) with exponential backoff on quota/rate errors

## Embedding Recovery

- Native flow uses `POST /ingest/entities` for structured ingest from `agent-mac`.
- Cron drains embedding retries every 15 minutes.
- Cron evaluates local-time daily briefing every hour and enqueues exactly once per local day at 7am workspace-local time.
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
  - `POST /actions/reject`
  - `POST /actions/execute`
- Durable Object coordinator class: `ChatCoordinator`
- Event replay:
  - `GET /sessions/:sessionId/events?since=<timestamp>&limit=...`
  - `GET /sessions/:sessionId/events?lastEventId=<rowid_cursor>&limit=...`
  - WS reconnect supports `lastEventId` query param on `/ws/chat`.
- Search audit persistence:
  - Every chat run writes `run_search_audits` with intent/query/searched filters + citation status/count.
- Ops endpoints:
  - `GET /ops/account/status?workspaceId=...&accountId=...`
  - `GET /ops/ingest-stats?workspaceId=...&accountId=...`
  - `GET /ops/queue-stats?workspaceId=...&accountId=...`
  - `GET /ops/extraction-stats?workspaceId=...&accountId=...`
  - `GET /ops/usage-stats?workspaceId=...&days=7` (workspace aggregate)
  - `GET /ops/usage-stats?workspaceId=...&accountId=...&days=7` (single inbox)
  - Add `&includeErrors=true` to include failed fallback attempts in usage rows.
  - `GET /ops/triage-stats?workspaceId=...&accountId=...`
  - Triage data is persisted per thread in `email_threads.classification_json`

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

Optional Worker vars for Workers AI cost estimation:

- `WORKERS_AI_INPUT_COST_PER_1M`
- `WORKERS_AI_OUTPUT_COST_PER_1M`

If unset, Workers AI usage still records call/unit counts but estimated cost is left unknown (`NULL`), while OpenAI model pricing is computed at write-time from built-in registry.

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
  - scheduled sync/briefing job enqueue + daily briefing generation consumption
- Manual embedding drain:
  - `POST /jobs/embeddings/process`
  - `POST /jobs/embeddings/reclean-noisy`
- Manual triage backfill for existing threads:
  - `POST /jobs/triage/reclassify`
- Manual briefing generation:
  - `POST /jobs/briefing/generate-now`
- Manual sync job processing:
  - `POST /jobs/sync/process`

## Shared Core Modules

- `workers/shared/citation.ts`: centralized citation contract validator.
- `workers/shared/events.ts`: run lifecycle event constants.

## Access Service-Token Validation (CLI)

Run end-to-end protected API validation with a Cloudflare Access service token:

```bash
export CF_ACCESS_CLIENT_ID="..."
export CF_ACCESS_CLIENT_SECRET="..."
./scripts/validate-api-e2e.sh
```

The script will:
- resolve service principal via `/auth/whoami`
- grant D1 permission for that principal
- run `propose -> approve -> execute` and `propose -> reject`
- run `POST /chat/query`
- verify `action_events` and `run_search_audits` rows in D1

## Historical Backfill (Controlled)

Legacy Node backfill (`agent/backfill.js`) has been retired because `/ingest/mail-thread` now returns `410 deprecated_endpoint`.
Use `agent-mac` + modern ingest paths only (`/ingest/entities`, `/ingest/message-chunks`).

## Production Migration Checklist

Primary blocker for production migration is Skyler Mac Mini running the Swift app (`agent-mac`) as the active publisher.

Use [docs/prod-migration-checklist.md](/Users/paulchrisluke/Repos 2026/sky-ai/docs/prod-migration-checklist.md) for:
- Skyler Mac Mini install/verification
- Node `agent/` retirement staging (archive first, delete later)
- `sky-ai-prod` D1 migration parity with dev

## Railway ChatKit Skeleton

A starter FastAPI service for Railway is included at `railway-chatkit/`.

Deploy steps:

1. Create Railway service from this repo.
2. Set Railway service `Root Directory` to `railway-chatkit`.
2. Railway will use:
   - `Procfile`
   - `requirements.txt`
   - `main.py`
3. Set Railway variables:
   - `CLOUDFLARE_API_URL=https://sky-ai-api.paulchrisluke.workers.dev`
   - `CF_ACCESS_CLIENT_ID=<access_service_token_client_id>`
   - `CF_ACCESS_CLIENT_SECRET=<access_service_token_client_secret>`
   - optional `WORKER_API_KEY=<worker_api_key>` (only if API key bypass is enabled)
   - optional `DEFAULT_ACCOUNT_ID` and `DEFAULT_WORKSPACE_ID`
3. Verify after deploy:
   - `GET /health` returns `{"status":"healthy"}`
   - `POST /chatkit` returns answer/citations/proposals from `POST /chat/query`
