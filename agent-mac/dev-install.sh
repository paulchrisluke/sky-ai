#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

xcodegen generate
xcodebuild -project BlawbyAgent.xcodeproj -scheme BlawbyAgent -configuration Debug build

APP="$(find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/Debug/BlawbyAgent.app" -type d | tail -n 1)"
if [[ -z "${APP}" || ! -d "${APP}" ]]; then
  echo "Could not find built BlawbyAgent.app in DerivedData"
  exit 1
fi

pkill -x BlawbyAgent || true
rm -rf /Applications/BlawbyAgent.app
cp -R "$APP" /Applications/BlawbyAgent.app
open -a /Applications/BlawbyAgent.app

echo "Installed and launched: /Applications/BlawbyAgent.app"
