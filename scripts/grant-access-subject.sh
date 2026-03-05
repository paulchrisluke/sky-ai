#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 4 ]]; then
  echo "Usage: $0 <d1_db_name> <subject> <workspace_id> <account_id> [email] [role] [status] [wrangler_config]"
  echo "Example: $0 sky-ai-dev 123e4567-e89b-12d3-a456-426614174000 default skylerbaird_me_com user@example.com admin active wrangler.api.toml"
  exit 1
fi

DB_NAME="$1"
SUBJECT="$2"
WORKSPACE_ID="$3"
ACCOUNT_ID="$4"
EMAIL="${5:-}"
ROLE="${6:-admin}"
STATUS="${7:-active}"
WRANGLER_CONFIG="${8:-wrangler.api.toml}"

escape_sql() {
  printf "%s" "$1" | sed "s/'/''/g"
}

ID_RAW="perm_${WORKSPACE_ID}_${ACCOUNT_ID}_$(printf '%s' "$SUBJECT" | tr -cd '[:alnum:]' | cut -c1-24)"
PERM_ID="$(escape_sql "$ID_RAW")"
SUBJECT_ESC="$(escape_sql "$SUBJECT")"
WORKSPACE_ESC="$(escape_sql "$WORKSPACE_ID")"
ACCOUNT_ESC="$(escape_sql "$ACCOUNT_ID")"
EMAIL_ESC="$(escape_sql "$EMAIL")"
ROLE_ESC="$(escape_sql "$ROLE")"
STATUS_ESC="$(escape_sql "$STATUS")"

SQL="
INSERT INTO access_subject_permissions
  (id, subject, email, workspace_id, account_id, role, status, created_at, updated_at)
VALUES
  ('$PERM_ID', '$SUBJECT_ESC', '$EMAIL_ESC', '$WORKSPACE_ESC', '$ACCOUNT_ESC', '$ROLE_ESC', '$STATUS_ESC', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
ON CONFLICT(subject, workspace_id, account_id)
DO UPDATE SET
  email = excluded.email,
  role = excluded.role,
  status = excluded.status,
  updated_at = CURRENT_TIMESTAMP;
"

echo "Granting subject permission in D1 database '$DB_NAME' using config '$WRANGLER_CONFIG'..."
npx wrangler d1 execute "$DB_NAME" --config "$WRANGLER_CONFIG" --command "$SQL"
echo "Done."
