#!/usr/bin/env bash
set -euo pipefail

RELEASE_DIR="${RELEASE_DIR:?RELEASE_DIR is required (example: dist/macos/1.0+1)}"
DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:?DOWNLOAD_URL_PREFIX is required (example: https://downloads.blawby.com/releases)}"
SPARKLE_PRIVATE_KEY="${SPARKLE_PRIVATE_KEY:?SPARKLE_PRIVATE_KEY is required (path to Sparkle EdDSA private key file)}"
OUTPUT_APPCAST="${OUTPUT_APPCAST:-$RELEASE_DIR/appcast.xml}"

if ! command -v generate_appcast >/dev/null 2>&1; then
  echo "generate_appcast not found. Install Sparkle tooling first."
  exit 1
fi

if [[ ! -d "$RELEASE_DIR" ]]; then
  echo "Release directory not found: $RELEASE_DIR"
  exit 1
fi

echo "==> Generating Sparkle appcast from $RELEASE_DIR"
generate_appcast \
  --ed-key-file "$SPARKLE_PRIVATE_KEY" \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
  "$RELEASE_DIR"

if [[ "$OUTPUT_APPCAST" != "$RELEASE_DIR/appcast.xml" ]]; then
  cp "$RELEASE_DIR/appcast.xml" "$OUTPUT_APPCAST"
fi

echo "Appcast generated at: $OUTPUT_APPCAST"
