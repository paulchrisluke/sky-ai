#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/agent-mac/BlawbyAgent.xcodeproj"
INFO_PLIST="$ROOT_DIR/agent-mac/BlawbyAgent/Info.plist"

APP_NAME="${APP_NAME:-BlawbyAgent}"
SCHEME="${SCHEME:-BlawbyAgent}"

usage() {
  cat <<'USAGE'
Usage:
  scripts/macos-app.sh dev-install
  scripts/macos-app.sh release
  scripts/macos-app.sh appcast

Commands:
  dev-install   Deterministic local install to /Applications from a fixed DerivedData path.
  release       Build/sign/notarize/staple/package release artifacts (zip + dmg).
  appcast       Generate Sparkle appcast.xml for a release directory.

Environment (dev-install):
  DERIVED_DATA_PATH   Optional; defaults to ~/Library/Developer/Xcode/DerivedData/BlawbyAgent-CleanInstall
  INSTALL_PATH        Optional; defaults to /Applications/BlawbyAgent.app

Environment (release):
  APPLE_ID
  APPLE_APP_SPECIFIC_PASSWORD
  APPLE_TEAM_ID
  OUTPUT_DIR          Optional; defaults to dist/macos/<version+build>

Environment (appcast):
  RELEASE_DIR
  DOWNLOAD_URL_PREFIX
  SPARKLE_PRIVATE_KEY
  OUTPUT_APPCAST      Optional; defaults to <RELEASE_DIR>/appcast.xml
USAGE
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1"
    exit 1
  fi
}

dev_install() {
  local dd="${DERIVED_DATA_PATH:-$HOME/Library/Developer/Xcode/DerivedData/BlawbyAgent-CleanInstall}"
  local install_path="${INSTALL_PATH:-/Applications/$APP_NAME.app}"

  require_cmd xcodebuild
  require_cmd plutil
  require_cmd cp
  require_cmd rg

  echo "==> Building debug app with fixed DerivedData path"
  rm -rf "$dd"
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -sdk macosx \
    -derivedDataPath "$dd" \
    build

  local app="$dd/Build/Products/Debug/$APP_NAME.app"
  if [[ ! -d "$app" ]]; then
    echo "Expected built app not found: $app"
    exit 1
  fi

  echo "==> Replacing installed app at $install_path"
  pkill -x "$APP_NAME" || true
  rm -rf "$install_path"
  cp -R "$app" "$install_path"

  echo "==> Verifying installed bundle metadata"
  plutil -p "$install_path/Contents/Info.plist" | rg "CFBundleIdentifier|LSUIElement|CFBundleShortVersionString"

  echo "==> Launching app"
  open -n "$install_path"
}

release() {
  require_cmd xcodebuild
  require_cmd xcrun
  require_cmd codesign
  require_cmd spctl
  require_cmd hdiutil

  local apple_id="${APPLE_ID:?APPLE_ID is required}"
  local apple_pw="${APPLE_APP_SPECIFIC_PASSWORD:?APPLE_APP_SPECIFIC_PASSWORD is required}"
  local apple_team="${APPLE_TEAM_ID:?APPLE_TEAM_ID is required}"

  local version="${VERSION:-$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST")}"
  local build_number="${BUILD_NUMBER:-$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST")}"
  local release_id="${version}+${build_number}"
  local output_dir="${OUTPUT_DIR:-$ROOT_DIR/dist/macos/$release_id}"

  local archive_path="$output_dir/$APP_NAME.xcarchive"
  local export_dir="$output_dir/export"
  local app_path="$export_dir/$APP_NAME.app"
  local zip_path="$output_dir/$APP_NAME-$release_id.zip"
  local dmg_path="$output_dir/$APP_NAME-$release_id.dmg"
  local staging_dir="$output_dir/dmg-staging"
  local export_options_plist="$output_dir/ExportOptions.plist"

  mkdir -p "$output_dir"

  cat >"$export_options_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>teamID</key>
  <string>$apple_team</string>
</dict>
</plist>
PLIST

  echo "==> Cleaning output directory: $output_dir"
  rm -rf "$archive_path" "$export_dir" "$zip_path" "$dmg_path" "$staging_dir"
  mkdir -p "$export_dir"

  echo "==> Building and archiving"
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$archive_path" \
    archive \
    DEVELOPMENT_TEAM="$apple_team"

  echo "==> Exporting signed app"
  xcodebuild \
    -exportArchive \
    -archivePath "$archive_path" \
    -exportPath "$export_dir" \
    -exportOptionsPlist "$export_options_plist"

  if [[ ! -d "$app_path" ]]; then
    echo "Expected app at $app_path but it was not found."
    exit 1
  fi

  echo "==> Verifying code signature"
  codesign --verify --deep --strict --verbose=2 "$app_path"
  spctl --assess --type execute --verbose "$app_path"

  echo "==> Packaging zip artifact"
  ditto -c -k --sequesterRsrc --keepParent "$app_path" "$zip_path"

  echo "==> Notarizing zip artifact"
  xcrun notarytool submit "$zip_path" \
    --apple-id "$apple_id" \
    --password "$apple_pw" \
    --team-id "$apple_team" \
    --wait

  echo "==> Stapling ticket to app"
  xcrun stapler staple "$app_path"
  spctl --assess --type execute --verbose "$app_path"

  echo "==> Building dmg artifact"
  mkdir -p "$staging_dir"
  cp -R "$app_path" "$staging_dir/"
  ln -s /Applications "$staging_dir/Applications"
  hdiutil create -volname "$APP_NAME" -srcfolder "$staging_dir" -ov -format UDZO "$dmg_path"

  echo "==> Notarizing dmg artifact"
  xcrun notarytool submit "$dmg_path" \
    --apple-id "$apple_id" \
    --password "$apple_pw" \
    --team-id "$apple_team" \
    --wait

  echo "==> Stapling ticket to dmg"
  xcrun stapler staple "$dmg_path"

  echo "==> Writing checksums"
  (
    cd "$output_dir"
    shasum -a 256 "$(basename "$zip_path")" "$(basename "$dmg_path")" > SHA256SUMS.txt
  )

  echo "Release artifacts ready in: $output_dir"
}

appcast() {
  require_cmd generate_appcast

  local release_dir="${RELEASE_DIR:?RELEASE_DIR is required (example: dist/macos/1.0+1)}"
  local download_url_prefix="${DOWNLOAD_URL_PREFIX:?DOWNLOAD_URL_PREFIX is required}"
  local sparkle_private_key="${SPARKLE_PRIVATE_KEY:?SPARKLE_PRIVATE_KEY is required}"
  local output_appcast="${OUTPUT_APPCAST:-$release_dir/appcast.xml}"

  if [[ ! -d "$release_dir" ]]; then
    echo "Release directory not found: $release_dir"
    exit 1
  fi

  echo "==> Generating Sparkle appcast from $release_dir"
  generate_appcast \
    --ed-key-file "$sparkle_private_key" \
    --download-url-prefix "$download_url_prefix" \
    "$release_dir"

  if [[ "$output_appcast" != "$release_dir/appcast.xml" ]]; then
    cp "$release_dir/appcast.xml" "$output_appcast"
  fi

  echo "Appcast generated at: $output_appcast"
}

cmd="${1:-}"
case "$cmd" in
  dev-install) dev_install ;;
  release) release ;;
  appcast) appcast ;;
  ""|-h|--help|help) usage ;;
  *)
    echo "Unknown command: $cmd"
    usage
    exit 1
    ;;
esac
