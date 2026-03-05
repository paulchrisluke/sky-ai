# Architecture V1 (Build-Once Foundation)

This document maps the locked decisions to implemented code.

## 1) Transport

- Browser <-> API Worker: WebSocket endpoint `/ws/chat`.
- Durable Object `ChatCoordinator` receives socket messages (`run.query`) and emits run lifecycle events.
- HTTP fallback exists at `POST /chat/query`.

## 2) State and Concurrency

- DO run lock: one active run per `session_id`.
- DO rate limit: 20 requests / 5 minutes per session.
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
- `POST /actions/approve` only changes status to `approved`.
- Execution is intentionally separate.

## Current Worker Split

- `ingest` path is still the existing root worker (`wrangler.toml`).
- New `api` worker is introduced (`wrangler.api.toml`).
- `jobs` worker split is pending next phase.
