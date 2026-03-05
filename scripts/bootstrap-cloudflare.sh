#!/usr/bin/env bash
set -euo pipefail

if ! command -v npx >/dev/null 2>&1; then
  echo "npx is required" >&2
  exit 1
fi

echo "==> Creating D1 database (dev)"
DEV_D1_OUTPUT=$(npx wrangler d1 create sky-ai-dev)
echo "$DEV_D1_OUTPUT"

echo "==> Creating R2 bucket (dev)"
npx wrangler r2 bucket create sky-ai-artifacts-dev

echo "==> Creating Vectorize index (dev)"
npx wrangler vectorize create sky-ai-memory-dev --dimensions=1536 --metric=cosine

echo "==> Apply migrations (dev)"
npx wrangler d1 migrations apply sky-ai-dev

echo "Bootstrap completed. Copy returned D1 database_id into wrangler.toml."
