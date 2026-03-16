#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/setup-macos-ci-signing.sh --p12-password '<password>' [--repo owner/name]

What it does:
  1) Exports your local "Developer ID Application" certificate + private key to a temporary .p12
  2) Base64-encodes that .p12
  3) Sets GitHub repository secrets:
     - APPLE_CERTIFICATE_P12_BASE64
     - APPLE_CERTIFICATE_PASSWORD

Notes:
  - Requires `gh` CLI auth for the target repo.
  - Fails if no Developer ID Application identity exists in your keychain.
USAGE
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

P12_PASSWORD=""
REPO="paulchrisluke/sky-ai"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --p12-password)
      P12_PASSWORD="${2:-}"
      shift 2
      ;;
    --repo)
      REPO="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$P12_PASSWORD" ]]; then
  echo "--p12-password is required" >&2
  usage
  exit 1
fi

require_cmd security
require_cmd gh
require_cmd openssl

IDENTITY_LINE="$(security find-identity -v -p codesigning | rg "Developer ID Application" | head -n 1 || true)"
if [[ -z "$IDENTITY_LINE" ]]; then
  echo "No 'Developer ID Application' signing identity found in keychain." >&2
  echo "Install your Developer ID Application certificate first, then rerun." >&2
  exit 1
fi

SHA1="$(printf '%s\n' "$IDENTITY_LINE" | awk '{print $2}')"
if [[ -z "$SHA1" ]]; then
  echo "Could not parse signing identity SHA-1." >&2
  exit 1
fi

WORK_DIR="$(mktemp -d)"
P12_FILE="$WORK_DIR/apple-signing.p12"
trap 'rm -rf "$WORK_DIR"' EXIT

# Export certificate + private key by SHA-1. This will fail if private key is not present.
security export \
  -k "$HOME/Library/Keychains/login.keychain-db" \
  -t identities \
  -f pkcs12 \
  -Z "$SHA1" \
  -P "$P12_PASSWORD" \
  -o "$P12_FILE" >/dev/null

if [[ ! -s "$P12_FILE" ]]; then
  echo "Failed to export .p12 from keychain." >&2
  exit 1
fi

P12_BASE64="$(openssl base64 -A -in "$P12_FILE")"
if [[ -z "$P12_BASE64" ]]; then
  echo "Failed to base64-encode exported .p12." >&2
  exit 1
fi

printf '%s' "$P12_BASE64" | gh secret set APPLE_CERTIFICATE_P12_BASE64 -R "$REPO"
printf '%s' "$P12_PASSWORD" | gh secret set APPLE_CERTIFICATE_PASSWORD -R "$REPO"

echo "Updated GitHub secrets on $REPO:"
echo "  - APPLE_CERTIFICATE_P12_BASE64"
echo "  - APPLE_CERTIFICATE_PASSWORD"
