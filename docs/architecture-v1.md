# Architecture V1 (Build-Once Foundation)

This document maps the locked decisions to implemented code.

## 1) Transport

- Browser <-> API Worker: WebSocket endpoint `/ws/chat`.
- Durable Object `ChatCoordinator` receives socket messages (`run.query`) and emits run lifecycle events.
- Event protocol now includes:
  - `run.started`
  - `tool.progress`
  - `run.completed`
  - `run.failed`
  - `run.cancelled`
- HTTP fallback exists at `POST /chat/query`.
- Replay endpoint for reconnect:
  - `GET /sessions/:session_id/events?since=<timestamp>&limit=<n>`
  - `GET /sessions/:session_id/events?lastEventId=<cursor>&limit=<n>`
  - `lastEventId` is the persisted `run_events` row cursor for lossless replay.

## 2) State and Concurrency

- DO run lock: one active run per `session_id`.
- DO rate limit: 20 requests / 5 minutes per session.
- DO alarm watchdog marks stale active runs as failed (`run_timeout_watchdog`).
- Persistent state in D1:
  - `chat_sessions`
  - `chat_turns`
  - `run_events`
  - `chat_citations`
  - `tool_calls`

## 3) Permanent Data Model

- Existing permanent core remains:
  - D1 canonical records
  - R2 raw artifacts
  - Vectorize retrieval memory
- Added permanent chat/action model:
  - `accounts`
  - `chat_sessions`
  - `chat_turns`
  - `chat_citations`
  - `run_events`
  - `proposed_actions`

## 4) Multi-mailbox from day one

- `account_id` is now first-class in:
  - chat tables
  - canonical email/memory tables (`email_threads`, `email_messages`, `memory_chunks`)
- Ingest worker now accepts/stores `accountId` (defaults to `accountEmail` when omitted).

## 5) Citation-required RAG from day one

- `POST /chat/query` and WS runs enforce citation grounding.
- If no citations are found, assistant responds with insufficient sources and searched strategy.
- Citations are persisted in `chat_citations`.

## 6) Action Extraction + Briefing (implemented)

- `POST /extraction/run` extracts:
  - tasks
  - decisions
  - followups
- Each extracted item has confidence + review state (`ready` or `needs_review`).
- Extraction audit is persisted in:
  - `message_extractions`
  - `model_audit_logs`
- `GET /briefing/today` returns prioritized actions + citations.

## 7) Chat intents (implemented)

- `today_actions` -> reads prioritized tasks/followups
- `find_email` -> citation-based message retrieval
- `thread_summary` -> thread-focused summary with citations

## Action Policy (from decision 6, included now)

- No auto-execution.
- `POST /actions/propose` creates `proposed` records with approval token.
- `POST /actions/approve` transitions `proposed -> approved`.
- `POST /actions/reject` transitions `proposed|approved -> rejected`.
- `POST /actions/execute` transitions `approved -> executed`.
- Immutable lifecycle audit events are written to `action_events`.

## Current Worker Split

- `ingest` worker (`wrangler.toml`): external ingest + outbound queue endpoints.
- `api` worker (`wrangler.api.toml`): chat, briefing, actions, extraction orchestration.
- `jobs` worker (`wrangler.jobs.toml`): queue consumers + cron-driven background jobs.

## Auth + Authorization

- Cloudflare Access JWT verification is implemented for HTTP endpoints across:
  - ingest worker
  - api worker
  - jobs worker
- Strict mode is enabled for `api` routes by default.
- D1 table `access_subject_permissions` defines explicit access grants:
  - `subject -> workspace_id/account_id` (+ role/status)
- API data routes check permission before returning account-scoped data.
- Auth introspection endpoint:
  - `GET /auth/whoami` (principal + grants)
  - `GET /auth/whoami?workspaceId=...&accountId=...` (explicit authorization check)

## Citation Contract Validation

- Final chat responses are validated centrally by `citation_contract_v1`.
- Factual response with zero citations is auto-converted to `insufficient_sources`.
- Every run persists audit metadata in `run_search_audits`:
  - intent
  - query
  - searched filters metadata
  - citation status/count
