#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/.build"
BLAWBY_HOME="$HOME/.blawby"
BIN_DIR="$BLAWBY_HOME/bin"
LOG_DIR="$BLAWBY_HOME/logs"
PLIST_SRC="$SCRIPT_DIR/BlawbyAgent.plist"
PLIST_DST="$HOME/Library/LaunchAgents/com.blawby.agent.plist"

mkdir -p "$BIN_DIR" "$LOG_DIR" "$HOME/Library/LaunchAgents"

cd "$SCRIPT_DIR"
swift build -c release

cp "$BUILD_DIR/release/BlawbyAgent" "$BIN_DIR/BlawbyAgent"
chmod +x "$BIN_DIR/BlawbyAgent"

sed \
  -e "s#__BINARY_PATH__#$BIN_DIR/BlawbyAgent#g" \
  -e "s#__HOME__#$HOME#g" \
  "$PLIST_SRC" > "$PLIST_DST"

launchctl load "$PLIST_DST"

echo "Installed BlawbyAgent to $BIN_DIR/BlawbyAgent"
