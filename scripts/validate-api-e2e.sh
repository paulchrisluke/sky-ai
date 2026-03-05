#!/usr/bin/env bash
set -euo pipefail

# Required env vars:
#   CF_ACCESS_CLIENT_ID
#   CF_ACCESS_CLIENT_SECRET
#
# Optional env vars:
#   API_BASE (default: https://sky-ai-api.paulchrisluke.workers.dev)
#   WORKSPACE_ID (default: default)
#   ACCOUNT_ID (default: skylerbaird@me.com)
#   D1_DB (default: sky-ai-dev)
#   WRANGLER_CONFIG (default: wrangler.api.toml)
#   GRANT_SCOPE (default: account)  # account|wildcard

API_BASE="${API_BASE:-https://sky-ai-api.paulchrisluke.workers.dev}"
WORKSPACE_ID="${WORKSPACE_ID:-default}"
ACCOUNT_ID="${ACCOUNT_ID:-skylerbaird@me.com}"
D1_DB="${D1_DB:-sky-ai-dev}"
WRANGLER_CONFIG="${WRANGLER_CONFIG:-wrangler.api.toml}"
GRANT_SCOPE="${GRANT_SCOPE:-account}"

if [[ -z "${CF_ACCESS_CLIENT_ID:-}" || -z "${CF_ACCESS_CLIENT_SECRET:-}" ]]; then
  echo "Missing CF_ACCESS_CLIENT_ID / CF_ACCESS_CLIENT_SECRET env vars."
  exit 1
fi

api_get() {
  local path="$1"
  curl -sS "${API_BASE}${path}" \
    -H "CF-Access-Client-Id: ${CF_ACCESS_CLIENT_ID}" \
    -H "CF-Access-Client-Secret: ${CF_ACCESS_CLIENT_SECRET}"
}

api_post() {
  local path="$1"
  local body="$2"
  curl -sS -X POST "${API_BASE}${path}" \
    -H "content-type: application/json" \
    -H "CF-Access-Client-Id: ${CF_ACCESS_CLIENT_ID}" \
    -H "CF-Access-Client-Secret: ${CF_ACCESS_CLIENT_SECRET}" \
    -d "${body}"
}

json_get() {
  local key="$1"
  node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{const j=JSON.parse(s);const v='${key}'.split('.').reduce((a,k)=>a&&a[k],j);process.stdout.write(v==null?'':String(v));})"
}

echo "1) Resolve Access principal via /auth/whoami"
whoami_json="$(api_get "/auth/whoami")"
echo "${whoami_json}"
principal_subject="$(printf '%s' "${whoami_json}" | json_get "principal.subject")"
principal_email="$(printf '%s' "${whoami_json}" | json_get "principal.email")"

if [[ -z "${principal_subject}" ]]; then
  echo "Failed to resolve principal subject from /auth/whoami"
  exit 1
fi

echo "2) Grant D1 permission for service principal"
grant_account="${ACCOUNT_ID}"
if [[ "${GRANT_SCOPE}" == "wildcard" ]]; then
  grant_account="*"
fi

./scripts/grant-access-subject.sh \
  "${D1_DB}" \
  "${principal_subject}" \
  "${WORKSPACE_ID}" \
  "${grant_account}" \
  "${principal_email:-service-token}" \
  "admin" \
  "active" \
  "${WRANGLER_CONFIG}"

echo "3) Propose -> approve -> execute"
propose1="$(api_post "/actions/propose" "{\"workspaceId\":\"${WORKSPACE_ID}\",\"accountId\":\"${ACCOUNT_ID}\",\"actionType\":\"send_email_draft\",\"payload\":{\"to\":\"test@example.com\",\"subject\":\"E2E Draft\"}}")"
action1_id="$(printf '%s' "${propose1}" | json_get "action.id")"
approve1="$(api_post "/actions/approve" "{\"actionId\":\"${action1_id}\",\"confirm\":true,\"userId\":\"service-token\"}")"
execute1="$(api_post "/actions/execute" "{\"actionId\":\"${action1_id}\",\"userId\":\"service-token\",\"result\":{\"provider\":\"manual\",\"status\":\"done\"}}")"

echo "4) Propose -> reject"
propose2="$(api_post "/actions/propose" "{\"workspaceId\":\"${WORKSPACE_ID}\",\"accountId\":\"${ACCOUNT_ID}\",\"actionType\":\"calendar_followup\",\"payload\":{\"title\":\"E2E followup\"}}")"
action2_id="$(printf '%s' "${propose2}" | json_get "action.id")"
reject2="$(api_post "/actions/reject" "{\"actionId\":\"${action2_id}\",\"userId\":\"service-token\",\"reason\":\"not_needed\"}")"

echo "5) POST /chat/query -> verify run_search_audits"
chat_json="$(api_post "/chat/query" "{\"workspaceId\":\"${WORKSPACE_ID}\",\"accountId\":\"${ACCOUNT_ID}\",\"query\":\"find email about overdue invoice\"}")"
run_id="$(printf '%s' "${chat_json}" | json_get "runId")"

echo "6) Query D1 evidence"
npx wrangler d1 execute "${D1_DB}" --config "${WRANGLER_CONFIG}" --remote --command \
  "SELECT id,status,approved_by,rejected_by,executed_by FROM proposed_actions WHERE id IN ('${action1_id}','${action2_id}') ORDER BY created_at DESC;"

npx wrangler d1 execute "${D1_DB}" --config "${WRANGLER_CONFIG}" --remote --command \
  "SELECT action_id,event_type,actor,created_at FROM action_events WHERE action_id IN ('${action1_id}','${action2_id}') ORDER BY created_at ASC;"

npx wrangler d1 execute "${D1_DB}" --config "${WRANGLER_CONFIG}" --remote --command \
  "SELECT run_id,intent,citation_status,citations_count,created_at FROM run_search_audits WHERE run_id = '${run_id}' ORDER BY created_at DESC LIMIT 3;"

echo "=== SUMMARY ==="
echo "principal.subject=${principal_subject}"
echo "action1.id=${action1_id}"
echo "action2.id=${action2_id}"
echo "run.id=${run_id}"
echo "propose1=${propose1}"
echo "approve1=${approve1}"
echo "execute1=${execute1}"
echo "propose2=${propose2}"
echo "reject2=${reject2}"
echo "chat=${chat_json}"
