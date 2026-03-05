# Mac Agent Setup (Friend-Proof)

This is the operational setup for a non-technical user Mac that must auto-recover after reboot/crash.

## 1) Install dependencies on Mac

```bash
brew install node
npm install -g pm2
```

## 2) Get the project

```bash
git clone https://github.com/paulchrisluke/sky-ai.git
cd sky-ai
```

## 3) Configure local agent

```bash
cd agent
cp .env.example .env
npm install
```

Fill `agent/.env` with:

- `APPLE_ID` / `APPLE_APP_PASSWORD`
- `WORKER_INGEST_URL`
- `WORKER_OUTBOUND_NEXT_URL`
- `WORKER_OUTBOUND_RESULT_URL`
- `WORKER_API_KEY` (required; must match Worker secret)
- `MAILBOXES` (default: `INBOX,Sent Messages`)
- `POLL_INTERVAL_MS` (recommended: `60000`)
- `STATE_FILE` (default: `../data/mailbox-state.json`)
- SMTP defaults for iCloud are already in `.env.example` (`smtp.mail.me.com:587`)

Use Apple app-specific passwords only.

## 4) Start as persistent service

```bash
cd agent
npm run pm2:start
pm2 save
pm2 startup
```

Run the command printed by `pm2 startup` (it usually needs `sudo`).

## 5) Remote support safety net

Enable macOS Screen Sharing:

- System Settings -> General -> Sharing -> Screen Sharing: ON

## 6) Health checks

```bash
pm2 status
pm2 logs email-sync --lines 100
```

## 7) Optional historical backfill

Run this one-off command to ingest older mail in a controlled, checkpointed way.

```bash
cd ~/sky-ai/agent
npm run backfill -- --since=2024-01-01 --mailboxes=INBOX
```

Optional flags:

- `--until=2024-12-31`
- `--batchSize=25`
- `--delayMs=250`

Checkpoint state is written to `~/sky-ai/data/backfill-state.json`.

## Suggested sync interval

Start with `POLL_INTERVAL_MS=60000` (60s). If rate-limited, move to `120000`-`300000`.

## Notes

- Cloudflare Tunnel is not used in the current architecture.
- Agent now does both:
  - IMAP ingest (`INBOX`, `Sent Messages`) -> Worker `/ingest/mail-thread`
  - SMTP send on behalf of `APPLE_ID` by polling Worker `/mail/outbound/next`
