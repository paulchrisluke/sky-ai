# Mac Agent Setup (Friend-Proof)

This is the operational setup for a non-technical user Mac that must auto-recover after reboot/crash.

## 1) Install dependencies on Mac

```bash
brew install node
npm install -g pm2
brew install cloudflared
```

## 2) Configure local agent

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
- optional `WORKER_API_KEY`
- SMTP defaults for iCloud are already in `.env.example` (`smtp.mail.me.com:587`)

Use Apple app-specific passwords only.

## 3) Start as persistent service

```bash
cd agent
npm run pm2:start
pm2 save
pm2 startup
```

Run the command printed by `pm2 startup` (it usually needs `sudo`).

## 4) (Optional) Install Cloudflare Tunnel as service

1. Create tunnel in Cloudflare Zero Trust.
2. Copy tunnel token.
3. Install service:

```bash
sudo cloudflared service install <TUNNEL_TOKEN>
```

## 5) Remote support safety net

Enable macOS Screen Sharing:

- System Settings -> General -> Sharing -> Screen Sharing: ON

## 6) Health checks

```bash
pm2 status
pm2 logs email-sync --lines 100
launchctl list | rg -i cloudflared
```

## Suggested sync interval

Start with `POLL_INTERVAL_MS=60000` (60s). If rate-limited, move to 120000-300000.

## Notes

- If your Mac agent only needs outbound calls to `workers.dev`, tunnel is not required.
- Agent now does both:
  - IMAP ingest (`INBOX`, `Sent Messages`) -> Worker `/ingest/mail-thread`
  - SMTP send on behalf of `APPLE_ID` by polling Worker `/mail/outbound/next`
