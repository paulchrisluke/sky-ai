#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB_NAME="${D1_DB:-sky-ai-dev}"
WRANGLER_CONFIG="${WRANGLER_CONFIG:-wrangler.api.toml}"
SQL_FILE="$ROOT_DIR/scripts/sql/seed-mcp-fixture.sql"

echo "Seeding MCP fixture data into remote D1 database '$DB_NAME'..."
npx wrangler d1 execute "$DB_NAME" --config "$WRANGLER_CONFIG" --remote --file "$SQL_FILE"
echo "Done."
