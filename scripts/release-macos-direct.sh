#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/agent-mac/BlawbyAgent.xcodeproj"
INFO_PLIST="$ROOT_DIR/agent-mac/BlawbyAgent/Info.plist"

APP_NAME="${APP_NAME:-BlawbyAgent}"
SCHEME="${SCHEME:-BlawbyAgent}"
CONFIGURATION="${CONFIGURATION:-Release}"

APPLE_ID="${APPLE_ID:?APPLE_ID is required}"
APPLE_APP_SPECIFIC_PASSWORD="${APPLE_APP_SPECIFIC_PASSWORD:?APPLE_APP_SPECIFIC_PASSWORD is required}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:?APPLE_TEAM_ID is required}"

VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST")}"
BUILD_NUMBER="${BUILD_NUMBER:-$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST")}"
RELEASE_ID="${VERSION}+${BUILD_NUMBER}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/dist/macos/$RELEASE_ID}"

ARCHIVE_PATH="$OUTPUT_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$OUTPUT_DIR/export"
APP_PATH="$EXPORT_DIR/$APP_NAME.app"
ZIP_PATH="$OUTPUT_DIR/$APP_NAME-$RELEASE_ID.zip"
DMG_PATH="$OUTPUT_DIR/$APP_NAME-$RELEASE_ID.dmg"
STAGING_DIR="$OUTPUT_DIR/dmg-staging"
EXPORT_OPTIONS_PLIST="$OUTPUT_DIR/ExportOptions.plist"

mkdir -p "$OUTPUT_DIR"

cat >"$EXPORT_OPTIONS_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>teamID</key>
  <string>$APPLE_TEAM_ID</string>
</dict>
</plist>
PLIST

echo "==> Cleaning output directory: $OUTPUT_DIR"
rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR" "$ZIP_PATH" "$DMG_PATH" "$STAGING_DIR"
mkdir -p "$EXPORT_DIR"

echo "==> Building and archiving $APP_NAME"
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -archivePath "$ARCHIVE_PATH" \
  archive \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID"

echo "==> Exporting Developer ID signed app"
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Expected app at $APP_PATH but it was not found."
  exit 1
fi

echo "==> Verifying code signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl --assess --type execute --verbose "$APP_PATH"

echo "==> Packaging zip artifact"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> Notarizing zip artifact"
xcrun notarytool submit "$ZIP_PATH" \
  --apple-id "$APPLE_ID" \
  --password "$APPLE_APP_SPECIFIC_PASSWORD" \
  --team-id "$APPLE_TEAM_ID" \
  --wait

echo "==> Stapling notarization ticket to app"
xcrun stapler staple "$APP_PATH"
spctl --assess --type execute --verbose "$APP_PATH"

echo "==> Building dmg artifact"
mkdir -p "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "==> Notarizing dmg artifact"
xcrun notarytool submit "$DMG_PATH" \
  --apple-id "$APPLE_ID" \
  --password "$APPLE_APP_SPECIFIC_PASSWORD" \
  --team-id "$APPLE_TEAM_ID" \
  --wait

echo "==> Stapling notarization ticket to dmg"
xcrun stapler staple "$DMG_PATH"

echo "==> Writing checksums"
(
  cd "$OUTPUT_DIR"
  shasum -a 256 "$(basename "$ZIP_PATH")" "$(basename "$DMG_PATH")" > SHA256SUMS.txt
)

echo
echo "Release artifacts ready:"
echo "  App: $APP_PATH"
echo "  Zip: $ZIP_PATH"
echo "  Dmg: $DMG_PATH"
echo "  Sums: $OUTPUT_DIR/SHA256SUMS.txt"
