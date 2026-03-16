#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$ROOT_DIR/.env"
ACCOUNT_NAME="${SPARKLE_KEY_ACCOUNT:-ed25519}"

source "$SCRIPT_DIR/sparkle-tools-path.sh"

GENERATE_KEYS_BIN="$SPARKLE_TOOLS_DIR/generate_keys"
if [[ ! -x "$GENERATE_KEYS_BIN" ]]; then
  echo "Missing executable: $GENERATE_KEYS_BIN"
  exit 1
fi

output="$("$GENERATE_KEYS_BIN" --account "$ACCOUNT_NAME")"
echo "$output"

public_key="$(printf '%s\n' "$output" | sed -n 's|.*<string>\(.*\)</string>.*|\1|p' | head -n 1)"
if [[ -z "$public_key" ]]; then
  echo "Could not parse SUPublicEDKey from generate_keys output."
  exit 1
fi

touch "$ENV_FILE"
if rg -q '^SPARKLE_PUBLIC_ED_KEY=' "$ENV_FILE"; then
  awk -v value="$public_key" '
    BEGIN { updated=0 }
    /^SPARKLE_PUBLIC_ED_KEY=/ { print "SPARKLE_PUBLIC_ED_KEY=\"" value "\""; updated=1; next }
    { print }
    END { if (!updated) print "SPARKLE_PUBLIC_ED_KEY=\"" value "\"" }
  ' "$ENV_FILE" > "$ENV_FILE.tmp"
  mv "$ENV_FILE.tmp" "$ENV_FILE"
else
  printf '\nSPARKLE_PUBLIC_ED_KEY="%s"\n' "$public_key" >> "$ENV_FILE"
fi

echo "Wrote SPARKLE_PUBLIC_ED_KEY to $ENV_FILE"
