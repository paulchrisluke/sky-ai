#!/usr/bin/env bash
set -euo pipefail

ENV_NAME="${1:-}"
if [[ -z "$ENV_NAME" ]]; then
  echo "Usage: scripts/set-cloudflare-secrets.sh <dev|prod>" >&2
  exit 1
fi

npx wrangler secret put GOOGLE_CLIENT_ID --env "$ENV_NAME"
npx wrangler secret put GOOGLE_CLIENT_SECRET --env "$ENV_NAME"
npx wrangler secret put GOOGLE_REDIRECT_URI --env "$ENV_NAME"
npx wrangler secret put TOKEN_ENCRYPTION_KEY --env "$ENV_NAME"
npx wrangler secret put CLAUDE_API_KEY --env "$ENV_NAME"

echo "Secrets updated for env: $ENV_NAME"
