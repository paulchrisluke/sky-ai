# Sky AI Onboarding Checklist

## What Skyler must provide

- Workspace account email to operate this automation
- Confirmation that all business mail is forwarded/aliased into the target mailbox
- Claude API key

## One-time setup steps (Skyler)

1. Clone repo and run `npm install`.
2. Run `npx clasp login` using Skyler's Google account.
3. Set target script ID in `.clasp.json` (DEV first).
4. Create local secret file:
   - `cp .secrets.local.example .secrets.local`
   - set `CLAUDE_API_KEY=<real value>`
5. Run `npm run secrets:load` to write secret(s) into Script Properties.
6. Run `npm run secrets:validate` and confirm masked output.
7. Run `npx clasp run bootstrap`.
8. Complete first-time OAuth authorization prompts.
9. Run `npx clasp run listTriggers` and confirm `triageInbox` + `sendDailyBriefing`.
10. Run `npx clasp run triageInbox` and `npx clasp run sendDailyBriefing`.

## Secrets Policy

- Store secrets only in Script Properties.
- Never store secrets in code constants, README, clasp templates, logs, or Sheets.
- If keys rotate, update only Script Properties; no code changes required.

## Notes

- Current phase intentionally does not call Gmail APIs or Claude APIs.
- Triggers are installed even if key is missing (Policy A); handlers remain safe stubs.
