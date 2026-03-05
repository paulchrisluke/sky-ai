# sky-ai

`sky-ai` is a clean Apps Script skeleton with a `clasp` DEV/PROD workflow and safe trigger stubs that run even before credentials are configured.

## Status

- Public repo: `https://github.com/paulchrisluke/sky-ai`
- Baseline scaffolding is in place.
- This phase intentionally has no Gmail reads and no Claude API calls.

## Project Layout

- `src/Logging.gs`
- `src/Config.gs`
- `src/Triggers.gs`
- `src/Main.gs`
- `src/appsscript.json`
- `.clasp.dev.json.template`
- `.clasp.prod.json.template`
- `docs/onboarding.md`

## Prerequisites

- Node.js 20+
- npm
- Google account for Apps Script (DEV first)

## clasp Workflow

1. Install deps:
   - `npm install`
2. Login:
   - `npx clasp login`
3. Create/select DEV Apps Script project and copy script ID.
4. Link local to DEV:
   - `cp .clasp.dev.json.template .clasp.json`
   - edit `.clasp.json` and set `scriptId`
5. Push:
   - `npx clasp push`
6. Verify drift:
   - `npx clasp status`

For PROD later:

1. `cp .clasp.prod.json.template .clasp.json`
2. set PROD `scriptId`
3. `npx clasp push`
4. `npx clasp status`

## Runtime Functions

- `bootstrap()`
  - writes defaults
  - installs managed triggers
  - logs clear warning if `CLAUDE_API_KEY` is missing (does not throw)
- `installTriggers()` / `uninstallTriggers()` / `listTriggers()`
- `triageInbox()` stub
  - logs
  - writes `last_run_at`
  - no-ops safely if key missing
- `sendDailyBriefing()` stub
  - logs
  - writes `last_briefing_at`
  - no-ops safely if key missing

## Blocked Behavior Policy

Policy A is active:

- Triggers install immediately.
- If key/account is missing, handlers no-op and log why.

## Definition of Done (Current Phase)

- Clean public repo skeleton exists.
- `clasp push` works to DEV.
- `bootstrap()` installs triggers and persists properties.
- `triageInbox()` and `sendDailyBriefing()` run safely without credentials.
