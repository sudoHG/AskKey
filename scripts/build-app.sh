#!/usr/bin/env bash
# Build a local AskKeyApp.app bundle from the current checkout, mirroring the
# release workflow (xcodebuild + manual bundle assembly + local sign). Useful
# for testing the daemon / auto-launch without cutting a real release.
#
# Usage: scripts/build-app.sh [Release|Debug|Local]   (default: Debug)
#   Release -> prod vault/keychain/socket (com.sudohg.askkey.vault)
#   Debug   -> dev  vault/keychain/socket (com.sudohg.askkey.vault.dev)
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-Debug}"
CONFIG="$MODE"
case "$MODE" in Debug|Release|Local|E2E) ;; *) echo "Usage: $0 [Debug|Release|Local|E2E]" >&2; exit 1;; esac
if [ "$MODE" = Local ]; then CONFIG=Release; fi
if [ "$MODE" = E2E ]; then CONFIG=Debug; fi
if [ "$MODE" = Local ] || [ "$MODE" = Release ]; then
  python3 scripts/e2e-gate.py
fi
SIGN_IDENTITY="-"
if [ "$MODE" = E2E ]; then SIGN_IDENTITY="${ASKKEY_E2E_SIGNING_IDENTITY:--}"; fi
BUNDLE_ID="com.sudohg.askkey.app.dev"
if [ "$MODE" = E2E ]; then BUNDLE_ID="com.sudohg.askkey.app.e2e"; fi
if [ "$MODE" = Release ]; then
  : "${ASKKEY_RELEASES_ENABLED:?Release builds are disabled}"
  [ "$ASKKEY_RELEASES_ENABLED" = true ] || exit 1
  : "${ASKKEY_CODESIGN_IDENTITY:?AskKey Developer ID is required}"
  : "${ASKKEY_APPLE_TEAM_ID:?AskKey Apple Team is required}"
  [ "$ASKKEY_CODESIGN_IDENTITY" != - ] || exit 1
  SIGN_IDENTITY="$ASKKEY_CODESIGN_IDENTITY"
  BUNDLE_ID="com.sudohg.askkey.app"
fi
# Explicit on-machine testing uses the real local vault namespace, signed by
# the owner's Developer ID. It does not enable software updates.
if [ "$MODE" = Local ]; then
  : "${ASKKEY_CODESIGN_IDENTITY:?Local testing requires the owner signing identity}"
  : "${ASKKEY_APPLE_TEAM_ID:?Local testing requires the owner Apple Team}"
  [ "$ASKKEY_CODESIGN_IDENTITY" != - ] || exit 1
  SIGN_IDENTITY="$ASKKEY_CODESIGN_IDENTITY"
  BUNDLE_ID="com.sudohg.askkey.app"
fi
AVAILABLE_KIB="$(df -k /System/Volumes/Data | awk 'NR==2 {print $4}')"
[ "${AVAILABLE_KIB:-0}" -ge 83886080 ] || { echo "At least 80 GiB free is required before building." >&2; exit 1; }
VERSION="$(git describe --tags --abbrev=0 2>/dev/null || echo 0.0.0)"
SHORT_VERSION="${VERSION#v}-local"
if [ "$MODE" = Local ]; then SHORT_VERSION="0.1.0"; fi
DD="${ASKKEY_DERIVED_DATA:-.derivedData/local-app}"
PRODUCTS="$DD/Build/Products/$CONFIG"
APP=".build/AskKeyApp.app"
CLI=".build/$([ "$CONFIG" = Release ] && echo release || echo debug)/askkey"

echo "==> Building CLI ($CONFIG)…"
if [ "$CONFIG" = "Release" ]; then swift build -c release --product askkey >/dev/null
else swift build --product askkey >/dev/null; fi

echo "==> Building app with xcodebuild ($CONFIG)…"
APP_BUILD_SETTINGS=("CODE_SIGNING_ALLOWED=NO")
if [ "$MODE" = E2E ]; then
  APP_BUILD_SETTINGS+=("SWIFT_OPTIMIZATION_LEVEL=-O" 'OTHER_SWIFT_FLAGS=$(inherited) -DASKKEY_E2E_TESTING')
fi
xcodebuild build -scheme AskKeyApp -configuration "$CONFIG" \
  -derivedDataPath "$DD" -destination "platform=macOS" \
  "${APP_BUILD_SETTINGS[@]}"

echo "==> Assembling $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$PRODUCTS/AskKeyApp" "$APP/Contents/MacOS/AskKeyApp"
cp "$CLI" "$APP/Contents/Helpers/askkey"
cp -R "$PRODUCTS"/*.bundle "$APP/Contents/Resources/" 2>/dev/null || true
# SwiftUI's literal localization lookup uses the main app bundle. SwiftPM keeps
# target resources in a nested bundle, so expose its language directories at
# the app root as well. The menu bar icon also loads from the main bundle so a
# missing SwiftPM resource bundle can never abort application launch.
ASKKEY_RESOURCES="$PRODUCTS/AskKey_AskKeyApp.bundle/Contents/Resources"
if [ ! -f "$ASKKEY_RESOURCES/MenuBarIcon.png" ]; then
  echo "AskKey app resources not found" >&2
  exit 1
fi
cp "$ASKKEY_RESOURCES/MenuBarIcon.png" "$APP/Contents/Resources/MenuBarIcon.png"
find "$ASKKEY_RESOURCES" -maxdepth 1 -type d -name '*.lproj' -exec cp -R {} "$APP/Contents/Resources/" \;

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>AskKey</string>
  <key>CFBundleDisplayName</key><string>AskKey</string>
  <key>CFBundleExecutable</key><string>AskKeyApp</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleVersion</key><string>${SHORT_VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${SHORT_VERSION}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
scripts/compile-app-icon.sh "$APP"
if [ "$MODE" = E2E ]; then
  /usr/libexec/PlistBuddy -c "Add :AskKeyE2ETesting bool true" "$APP/Contents/Info.plist"
fi
if [ "$MODE" = Local ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-parse --short HEAD)" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :AskKeyLocalTesting bool true" "$APP/Contents/Info.plist"
fi
if [ "$CONFIG" = Debug ]; then
  /usr/libexec/PlistBuddy -c "Add :AskKeyRequiresDebugRunDirectory bool true" "$APP/Contents/Info.plist"
fi
cp LICENSE "$APP/Contents/Resources/LICENSE"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Signing with $SIGN_IDENTITY …"
SIGN_OPTIONS=(--force)
if [ "$CONFIG" = Release ]; then SIGN_OPTIONS=(--force --options runtime --timestamp); fi
codesign "${SIGN_OPTIONS[@]}" --sign "$SIGN_IDENTITY" "$CLI"
codesign "${SIGN_OPTIONS[@]}" --sign "$SIGN_IDENTITY" "$APP/Contents/Helpers/askkey"
codesign --force --deep "${SIGN_OPTIONS[@]}" --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --deep "$APP"
if [ "$CONFIG" = Release ]; then
  ACTUAL_TEAM="$(codesign -dv --verbose=4 "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  [ "$ACTUAL_TEAM" = "$ASKKEY_APPLE_TEAM_ID" ] || { echo "AskKey signing team mismatch" >&2; exit 1; }
  codesign --verify --strict -R '=anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$APP"
fi

echo "==> Done."
echo "App: $(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")   (config: $CONFIG, version: $SHORT_VERSION)"
echo "CLI: $(pwd)/$CLI"
