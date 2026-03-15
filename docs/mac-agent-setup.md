# Mac Agent Setup (Native `agent-mac`)

This is the default Mac setup for Blawby. The app is native Swift/macOS and runs as a background agent.

## 1) Prerequisites

```bash
xcode-select --install
brew install xcodegen
```

## 2) Get the project

```bash
git clone https://github.com/paulchrisluke/sky-ai.git
cd sky-ai/agent-mac
```

## 3) Configure local env (dev fallback)

```bash
cp .env.example .env
```

Set values in `agent-mac/.env`:

- `WORKER_WS_URL`
- `WORKER_API_KEY`
- `WORKSPACE_ID`
- `ACCOUNT_ID`
- `OPENAI_API_KEY`

Notes:
- In-app Preferences + Keychain are the source of truth for production.
- `.env` is for local/dev launch convenience.

## 4) Build and run

```bash
swift build
.build/debug/BlawbyAgent
```

## 5) Install as login/background service

```bash
./install.sh
```

This installs the binary under `~/.blawby/bin` and loads launch agent `com.blawby.agent`.

## 6) Verify

```bash
tail -n 100 ~/.blawby/logs/agent.log
launchctl list | grep com.blawby.agent
```

You should see:
- websocket connected
- observer startup logs (mail/calendar/messages)
- sync logs (`[sync] ...`)

## 7) Uninstall

```bash
./uninstall.sh
```

## Xcode workflow (optional)

From `agent-mac/`:

```bash
xcodegen generate
open BlawbyAgent.xcodeproj
```

## Legacy Node agent

The old Node/PM2 flow in `/agent` is legacy compatibility only and is not the target architecture.
