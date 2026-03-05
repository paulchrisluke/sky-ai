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
- `src/Secrets.gs`
- `src/appsscript.json`
- `.clasp.dev.json.template`
- `.clasp.prod.json.template`
- `.secrets.local.example`
- `scripts/load-secrets.mjs`
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
- `setSecret(name, value)` / `setSecretsFromLocal(secretMap)` / `validateSecrets()`
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

## Secrets Policy (3.3)

- Secrets are stored only in Apps Script Script Properties.
- No secret values are committed in source, manifest, README, or clasp templates.
- Logs must never include raw credentials; logging uses redaction for bearer/auth/api-key patterns.
- Do not place secrets in Sheets, constants, or local committed files.

### Local File -> Script Properties (Recommended)

Use a gitignored local file for convenience, then push to Script Properties with `clasp run`.

1. Copy local template:
   - `cp .secrets.local.example .secrets.local`
2. Edit `.secrets.local` and set real values.
3. Ensure `.clasp.json` points to the target environment (DEV or PROD).
4. Load secrets:
   - `npm run secrets:load`
5. Validate (masked output only):
   - `npm run secrets:validate`

`secrets:load` calls Apps Script function `setSecretsFromLocal`, which writes to Script Properties.
No secret value is logged.

## Skyler Onboarding (No Sheets/UI Required)

When Skyler's Workspace account and Claude key are available:

1. Run `npx clasp login` for Skyler's Google account.
2. Point `.clasp.json` at target script ID.
3. Run `npm run secrets:load` (reads `.secrets.local`, writes Script Properties).
4. Run `npm run secrets:validate`.
5. Run `clasp run bootstrap`.
6. Run `clasp run listTriggers` to confirm `triageInbox` and `sendDailyBriefing`.

First-time authorization is still required once by Google before property writes/triggers can execute.

## Definition of Done (Current Phase)

- Clean public repo skeleton exists.
- `clasp push` works to DEV.
- `bootstrap()` installs triggers and persists properties.
- `triageInbox()` and `sendDailyBriefing()` run safely without credentials.
