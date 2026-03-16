#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$HOME/Library/Developer/Xcode/DerivedData/BlawbyAgent-Fixed}"

if [[ ! -f ./.env ]]; then
  echo "Missing ./agent-mac/.env"
  echo "Copy .env.example to .env."
  exit 1
fi

set -a
# shellcheck disable=SC1091
source ./.env
set +a

xcodegen generate
xcodebuild \
  -project BlawbyAgent.xcodeproj \
  -scheme BlawbyAgent \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build

APP="$DERIVED_DATA_PATH/Build/Products/Debug/BlawbyAgent.app"
if [[ -z "${APP}" || ! -d "${APP}" ]]; then
  echo "Could not find built BlawbyAgent.app in DerivedData"
  exit 1
fi

pkill -x BlawbyAgent || true
rm -rf /Applications/BlawbyAgent.app
cp -R "$APP" /Applications/BlawbyAgent.app
open -a /Applications/BlawbyAgent.app

echo "Installed and launched: /Applications/BlawbyAgent.app"
