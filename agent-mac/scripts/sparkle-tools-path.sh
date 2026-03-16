#!/usr/bin/env bash
set -euo pipefail

find_sparkle_tools_dir() {
  local derived_data
  derived_data="$HOME/Library/Developer/Xcode/DerivedData"
  find "$derived_data" -path "*/SourcePackages/artifacts/sparkle/Sparkle/bin" -type d 2>/dev/null | head -n 1
}

SPARKLE_TOOLS_DIR="${SPARKLE_TOOLS_DIR:-$(find_sparkle_tools_dir || true)}"
if [[ -z "${SPARKLE_TOOLS_DIR}" || ! -d "${SPARKLE_TOOLS_DIR}" ]]; then
  echo "Sparkle tools not found in DerivedData."
  echo "Run ./dev-install.sh once to resolve Sparkle artifacts, then retry."
  exit 1
fi
