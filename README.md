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
3. Create two Apps Script projects in Google Apps Script:
   - DEV project
   - PROD project
4. Get each project `scriptId` from Apps Script project settings.

## Link DEV/PROD script IDs

1. DEV mapping:
   - `cp .clasp.dev.json.template .clasp.json`
   - Edit `.clasp.json` and set DEV `scriptId`
2. PROD mapping:
   - `cp .clasp.prod.json.template .clasp.json`
   - Edit `.clasp.json` and set PROD `scriptId`

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

1. Run `bootstrapProject` once from the Apps Script editor.
2. Approve OAuth scopes when prompted.
3. Confirm `runAutomationCycle` exists and can be run.
4. Check Executions for logs and errors.
5. Run `npx clasp status` locally to ensure no drift.

After DEV is stable, repeat on PROD.

## Secrets (Script Properties)

Store secrets only in Script Properties; never in code or sheets.

Set Claude key (DEV or PROD):

1. In Apps Script editor, run `setClaudeApiKey` with key string argument.
2. Run `validateSecrets`.
3. Confirm it returns masked preview (`first4...last4`).

Key rotation:

1. Set new key in DEV with `setClaudeApiKey`.
2. Validate with `validateSecrets`.
3. Repeat in PROD.

No code changes are required for key rotation.

## Logging and redaction

- Logs redact bearer authorization tokens.
- Logs redact values associated with `CLAUDE_API_KEY` and generic `api_key` patterns.
- Never log full secret values.

## Trigger management

- Install baseline trigger: run `installDefaultTriggers`
- Remove baseline trigger: run `clearDefaultTriggers`

`bootstrapProject` installs the default time-based trigger and validates secret configuration.
