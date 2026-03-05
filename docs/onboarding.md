# Sky AI Onboarding Checklist

## What Skyler must provide

- Workspace account email to operate this automation
- Confirmation that all business mail is forwarded/aliased into the target mailbox
- Claude API key

## One-time setup steps (Skyler)

1. Open the target standalone Apps Script project (no spreadsheet setup needed).
2. Go to `Project Settings` -> `Script properties`.
3. Add Script Property:
   - key: `CLAUDE_API_KEY`
   - value: real Claude API key
4. Run `bootstrap()` once.
5. Complete the OAuth authorization prompts.
6. Run `listTriggers()` and confirm `triageInbox` and `sendDailyBriefing` exist.
7. Run `triageInbox()` and `sendDailyBriefing()` once to confirm successful no-error execution.

## Secrets Policy

- Store secrets only in Script Properties.
- Never store secrets in code constants, README, clasp templates, logs, or Sheets.
- If keys rotate, update only Script Properties; no code changes required.

## Notes

- Current phase intentionally does not call Gmail APIs or Claude APIs.
- Triggers are installed even if key is missing (Policy A); handlers remain safe stubs.
