#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$ROOT_DIR/.env"

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <release-artifacts-dir>"
  exit 1
fi

ARCHIVE_DIR="$1"
if [[ ! -d "$ARCHIVE_DIR" ]]; then
  echo "Release artifacts directory not found: $ARCHIVE_DIR"
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing $ENV_FILE"
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

if [[ -z "${SPARKLE_FEED_URL:-}" ]]; then
  echo "Missing SPARKLE_FEED_URL in $ENV_FILE"
  exit 1
fi

if [[ "$SPARKLE_FEED_URL" != */appcast.xml ]]; then
  echo "SPARKLE_FEED_URL must end with /appcast.xml"
  exit 1
fi

DOWNLOAD_PREFIX="${SPARKLE_FEED_URL%/appcast.xml}"

source "$SCRIPT_DIR/sparkle-tools-path.sh"

GENERATE_APPCAST_BIN="$SPARKLE_TOOLS_DIR/generate_appcast"
if [[ ! -x "$GENERATE_APPCAST_BIN" ]]; then
  echo "Missing executable: $GENERATE_APPCAST_BIN"
  exit 1
fi

"$GENERATE_APPCAST_BIN" \
  --download-url-prefix "$DOWNLOAD_PREFIX/" \
  --release-notes-url-prefix "$DOWNLOAD_PREFIX/" \
  "$ARCHIVE_DIR"

echo "Generated Sparkle appcast at: $ARCHIVE_DIR/appcast.xml"
