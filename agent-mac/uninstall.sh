#!/usr/bin/env bash
set -euo pipefail

PLIST="$HOME/Library/LaunchAgents/com.blawby.agent.plist"
BIN="$HOME/.blawby/bin/BlawbyAgent"

launchctl unload "$PLIST"
rm "$PLIST"
rm "$BIN"

echo "Uninstalled BlawbyAgent"
