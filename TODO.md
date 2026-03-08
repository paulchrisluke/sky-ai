# Launch TODO

- [ ] Protect Railway `chatkit` endpoint with server-side auth (for example `X-API-Key` validated in `railway-chatkit`) before public launch to prevent unauthenticated abuse/cost exposure.
- [ ] On Mac Mini: `git pull` in this repo, then restart the PM2 process so the new `agent/calendar.js` module loads. IMAP sync will resume immediately with calendar polling enabled.
