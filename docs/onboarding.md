# Sky AI Onboarding Checklist

## What Skyler must provide

- Workspace account email to operate this automation
- Confirmation that all business mail is forwarded/aliased into the target mailbox
- Claude API key

## One-time setup steps (Skyler)

1. Open the target Apps Script project.
2. Add Script Property:
   - `CLAUDE_API_KEY` = real Claude API key
3. Run `bootstrap()` once.
4. Complete the OAuth authorization prompts.
5. Run `listTriggers()` and confirm `triageInbox` and `sendDailyBriefing` exist.
6. Run `triageInbox()` and `sendDailyBriefing()` once to confirm successful no-error execution.

## Notes

- Current phase intentionally does not call Gmail APIs or Claude APIs.
- Triggers are installed even if key is missing (Policy A); handlers remain safe stubs.
