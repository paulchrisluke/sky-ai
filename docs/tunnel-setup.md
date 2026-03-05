# Cloudflare Tunnel Setup (Your Account)

Tunnel is optional for this project when using `*.workers.dev`.
Only use this if you need inbound access to a local service behind your firewall.

This repo tracks the tunnel config template, while tunnel identity/token remain account-side secrets.

## 1) Authenticate cloudflared

```bash
cloudflared tunnel login
```

## 2) Create tunnel

```bash
cloudflared tunnel create sky-ai-mail-agent
```

## 3) Route DNS

```bash
cloudflared tunnel route dns sky-ai-mail-agent mail-agent.sky-ai.example.com
```

## 4) Install on Mac as service

```bash
sudo cloudflared service install <TUNNEL_TOKEN>
```

## 5) Verify

```bash
cloudflared tunnel list
cloudflared tunnel info sky-ai-mail-agent
```

## Notes

- Keep tunnel token out of git.
- Keep credentials JSON only on the Mac host.
- You can rotate token in Cloudflare Zero Trust if needed.
