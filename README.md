# sky-ai

`sky-ai` is a standalone Google Apps Script project with a clean DEV/PROD `clasp` workflow and Script Properties-based secret management.

## Prerequisites

- Node.js 20+
- npm
- Google account access to your Apps Script projects

## Setup

1. Clone repo and install dependencies:
   - `npm install`
2. Authenticate clasp:
   - `npx clasp login`
3. Create two standalone Apps Script projects:
   - DEV project
   - PROD project
4. Copy each project `scriptId` from Apps Script project settings.

## Link DEV/PROD script IDs

DEV mapping:

1. `cp .clasp.dev.json.template .clasp.json`
2. Edit `.clasp.json` and set DEV `scriptId`

PROD mapping:

1. `cp .clasp.prod.json.template .clasp.json`
2. Edit `.clasp.json` and set PROD `scriptId`

`rootDir` is fixed to `src`, so pushes always use files in `/src`.

## Push workflow

DEV:

1. `cp .clasp.dev.json.template .clasp.json`
2. Set DEV `scriptId`
3. `npx clasp push`
4. `npx clasp status`

PROD:

1. `cp .clasp.prod.json.template .clasp.json`
2. Set PROD `scriptId`
3. `npx clasp push`
4. `npx clasp status`

Use `npx clasp pull` only when you intentionally want to sync remote changes into local source.

## Verify in Apps Script

After pushing to DEV:

1. Run `bootstrapProject` once from Apps Script editor (or `npx clasp run bootstrapProject`).
2. Approve OAuth scopes when prompted.
3. Confirm a time-based trigger exists for `runAutomationCycle`.
4. Run `runAutomationCycle` once and check Executions.
5. Run `npx clasp status` locally to ensure no drift.

After DEV is stable, repeat on PROD.

## Secrets (Script Properties)

Store secrets only in Script Properties; never in code, sheets, or committed files.

Set Claude key:

1. Open Apps Script project settings.
2. Add script property:
   - key: `CLAUDE_API_KEY`
   - value: your real key
3. Run `validateSecrets`.
4. Confirm it returns masked preview (`first4...last4`).

Optional CLI update flow (if Apps Script API execution is enabled):

- `npx clasp run setClaudeApiKey --params '["YOUR_KEY"]'`

Key rotation:

1. Set new key in DEV and run `validateSecrets`.
2. Set new key in PROD and run `validateSecrets`.

No code changes are required for key rotation.

## Logging and redaction

- Logs redact bearer authorization tokens.
- Logs redact values associated with `CLAUDE_API_KEY` and generic `api_key` patterns.
- Never log full secret values.

## Trigger management

- Install or reset baseline trigger: run `installDefaultTriggers`
- Remove baseline trigger: run `clearDefaultTriggers`

`bootstrapProject` installs the default time-based trigger and validates secret configuration.
