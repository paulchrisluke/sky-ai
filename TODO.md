# Launch TODO

- [ ] Protect Railway `chatkit` endpoint with server-side auth (for example `X-API-Key` validated in `railway-chatkit`) before public launch to prevent unauthenticated abuse/cost exposure.
- [ ] Install and validate Swift `agent-mac` on Skyler's Mac Mini (current production blocker).
- [ ] Apply all unapplied D1 migrations to `sky-ai-prod` and verify migration parity with `sky-ai-dev`.
- [ ] Archive legacy Node `agent/` after Swift-only stability window (do not delete yet).
- [ ] Delete legacy Node `agent/` only after explicit production sign-off.
