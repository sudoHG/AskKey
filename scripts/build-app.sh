#!/usr/bin/env bash
# Build a local AskKeyApp.app bundle from the current checkout, mirroring the
# release workflow (xcodebuild + manual bundle assembly + local sign). Useful
# for testing the daemon / auto-launch without cutting a real release.
#
# Usage: scripts/build-app.sh [Release|Debug|Local|E2E]   (default: Debug)
#   Release -> prod vault/keychain/socket (com.sudohg.askkey.vault)
#   Debug   -> dev  vault/keychain/socket (com.sudohg.askkey.vault.dev)
# ASKKEY_PROVISIONING_PROFILE=<Developer ID .provisionprofile> adds CloudKit and
# push to a Local build (ADR 0013); every other mode refuses it. Setting it,
# even to an empty value, turns the option on.
set -euo pipefail
# Resolve a relative profile path against the caller's directory before cd.
case "${ASKKEY_PROVISIONING_PROFILE-/}" in /*) ;; *) ASKKEY_PROVISIONING_PROFILE="$PWD/$ASKKEY_PROVISIONING_PROFILE" ;; esac
cd "$(dirname "$0")/.."

MODE="${1:-Debug}"
CONFIG="$MODE"
case "$MODE" in Debug|Release|Local|E2E) ;; *) echo "Usage: $0 [Debug|Release|Local|E2E]" >&2; exit 1;; esac
if [ "$MODE" = Local ]; then CONFIG=Release; fi
if [ "$MODE" = E2E ]; then CONFIG=Debug; fi
# The CloudKit option embeds the profile, declares the container in Info.plist
# and signs only the App with entitlements generated from ASKKEY_APPLE_TEAM_ID.
CLOUDKIT_CONTAINER="iCloud.com.sudohg.askkey"
CLOUDKIT_DIR=""
if [ -n "${ASKKEY_PROVISIONING_PROFILE+set}" ]; then
  case "$MODE" in
    Release) echo "ASKKEY_PROVISIONING_PROFILE is refused in Release builds: they get no CloudKit entitlement until #269 stage 4 ships the iPhone app." >&2; exit 1 ;;
    Debug|E2E) echo "ASKKEY_PROVISIONING_PROFILE is refused in $MODE builds: they are signed ad hoc, which cannot carry the CloudKit and push entitlements. Use Local." >&2; exit 1 ;;
  esac
  CLOUDKIT_DIR=".build/cloudkit-signing"
fi
if [ "$MODE" = Local ]; then
  python3 scripts/release-gate.py
fi
if [ "$MODE" = Release ]; then
  python3 scripts/release-gate.py --require-tag
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
# the owner's Developer ID. It does not enable software updates: only Release
# writes Sparkle keys (ADR 0011).
if [ "$MODE" = Local ]; then
  : "${ASKKEY_CODESIGN_IDENTITY:?Local testing requires the owner signing identity}"
  : "${ASKKEY_APPLE_TEAM_ID:?Local testing requires the owner Apple Team}"
  [ "$ASKKEY_CODESIGN_IDENTITY" != - ] || exit 1
  SIGN_IDENTITY="$ASKKEY_CODESIGN_IDENTITY"
  BUNDLE_ID="com.sudohg.askkey.app"
fi
# Check the profile before building: a Developer ID profile for this App ID and
# team, not expired, listing the signing certificate and granting every
# entitlement. Signing then uses that certificate's hash.
if [ -n "$CLOUDKIT_DIR" ]; then
  echo "==> Checking the provisioning profile…"
  rm -rf "$CLOUDKIT_DIR"
  mkdir -p "$CLOUDKIT_DIR"
  python3 scripts/cloudkit-signing.py prepare --profile "$ASKKEY_PROVISIONING_PROFILE" \
    --identity "$SIGN_IDENTITY" --team "$ASKKEY_APPLE_TEAM_ID" --output "$CLOUDKIT_DIR"
  SIGN_IDENTITY="$(cat "$CLOUDKIT_DIR/signing-certificate")"
fi
# Release builds ship the updater, which needs the committed EdDSA public key.
# Without it they fail closed, so no release ships an updater without a key.
SPARKLE_FEED_URL="https://askkey.sudohg.com/appcast.xml"
SPARKLE_PUBLIC_KEY_FILE="scripts/sparkle-public-key.txt"
if [ "$MODE" = Release ]; then
  [ -f "$SPARKLE_PUBLIC_KEY_FILE" ] || { echo "Release builds require $SPARKLE_PUBLIC_KEY_FILE." >&2; exit 1; }
  SPARKLE_PUBLIC_KEY="$(tr -d '[:space:]' < "$SPARKLE_PUBLIC_KEY_FILE")"
  [[ "$SPARKLE_PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] \
    && [ "$(printf '%s' "$SPARKLE_PUBLIC_KEY" | base64 -D 2>/dev/null | wc -c | tr -d ' ')" = 32 ] \
    || { echo "$SPARKLE_PUBLIC_KEY_FILE must hold one base64-encoded 32-byte EdDSA public key." >&2; exit 1; }
fi
AVAILABLE_KIB="$(df -k /System/Volumes/Data | awk 'NR==2 {print $4}')"
[ "${AVAILABLE_KIB:-0}" -ge 83886080 ] || { echo "At least 80 GiB free is required before building." >&2; exit 1; }
VERSION="$(bash scripts/product-version.sh)"
SHORT_VERSION="$VERSION"
if [ "$CONFIG" = Debug ]; then SHORT_VERSION="$VERSION-dev"; fi
DD="${ASKKEY_DERIVED_DATA:-.derivedData/local-app}"
PRODUCTS="$DD/Build/Products/$CONFIG"
APP=".build/AskKeyApp.app"
APP_PRODUCT="AskKeyApp"
if [ "$MODE" = E2E ]; then APP_PRODUCT="AskKeyE2EApp"; fi
CLI=".build/$([ "$CONFIG" = Release ] && echo release || echo debug)/askkey"

echo "==> Building CLI ($CONFIG)…"
if [ "$CONFIG" = "Release" ]; then swift build -c release --product askkey >/dev/null
else swift build --product askkey >/dev/null; fi

echo "==> Building app with xcodebuild ($CONFIG)…"
APP_BUILD_SETTINGS=("CODE_SIGNING_ALLOWED=NO")
if [ "$MODE" = E2E ]; then
  APP_BUILD_SETTINGS+=("SWIFT_OPTIMIZATION_LEVEL=-O")
fi
xcodebuild build -scheme "$APP_PRODUCT" -configuration "$CONFIG" \
  -derivedDataPath "$DD" -destination "platform=macOS" \
  "${APP_BUILD_SETTINGS[@]}"
python3 scripts/check_sdk_markers.py "$PRODUCTS/$APP_PRODUCT" "$CLI"

echo "==> Assembling $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$PRODUCTS/$APP_PRODUCT" "$APP/Contents/MacOS/AskKeyApp"
cp "$CLI" "$APP/Contents/Helpers/askkey"
cp -R "$(dirname "$CLI")/AskKey_AskKeyHelper.bundle" "$APP/Contents/Helpers/"
cp -R "$PRODUCTS"/*.bundle "$APP/Contents/Resources/" 2>/dev/null || true
# SwiftUI's literal localization lookup uses the main app bundle. SwiftPM keeps
# target resources in a nested bundle, so expose its language directories at
# the app root as well. The menu bar icon also loads from the main bundle so a
# missing SwiftPM resource bundle can never abort application launch.
ASKKEY_RESOURCES="$PRODUCTS/AskKey_AskKeyAppKit.bundle/Contents/Resources"
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
  <key>CFBundleName</key><string>Ask Key</string>
  <key>CFBundleDisplayName</key><string>Ask Key</string>
  <key>LSHasLocalizedDisplayName</key><true/>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
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
# Only Release enables the updater. Every install needs the user's click, and
# feeds and archives must carry EdDSA signatures from the committed key.
if [ "$MODE" = Release ]; then
  for entry in \
    "SUFeedURL string $SPARKLE_FEED_URL" \
    "SUPublicEDKey string $SPARKLE_PUBLIC_KEY" \
    "SURequireSignedFeed bool true" \
    "SUSignedFeedFailureExpirationInterval real 0" \
    "SUVerifyUpdateBeforeExtraction bool true" \
    "SUAllowsAutomaticUpdates bool false" \
    "SUAutomaticallyUpdate bool false" \
    "SUEnableSystemProfiling bool false"
  do
    /usr/libexec/PlistBuddy -c "Add :$entry" "$APP/Contents/Info.plist"
  done
fi
cp LICENSE "$APP/Contents/Resources/LICENSE"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# Declare the container and embed the checked profile before any signing.
if [ -n "$CLOUDKIT_DIR" ]; then
  /usr/libexec/PlistBuddy -c "Add :AskKeyCloudKitContainer string $CLOUDKIT_CONTAINER" "$APP/Contents/Info.plist"
  cp "$CLOUDKIT_DIR/embedded.provisionprofile" "$APP/Contents/embedded.provisionprofile"
fi

# Embed Sparkle in every mode so the executable always finds the framework it
# links. The app is not sandboxed, so Sparkle's XPC services are not needed.
SPARKLE_FRAMEWORK=""
for candidate in "$PRODUCTS/Sparkle.framework" "$PRODUCTS/PackageFrameworks/Sparkle.framework" \
  "$DD/SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"; do
  if [ -d "$candidate" ]; then SPARKLE_FRAMEWORK="$candidate"; break; fi
done
[ -n "$SPARKLE_FRAMEWORK" ] || { echo "Sparkle.framework not found in the build products" >&2; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
EMBEDDED_SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$EMBEDDED_SPARKLE/XPCServices" "$EMBEDDED_SPARKLE/Versions/B/XPCServices"
# Xcode also links an absolute rpath into its build products. Drop every rpath
# into this checkout or the derived data, so dyld loads only the embedded
# framework and no local path ships in the binary.
EXECUTABLE="$APP/Contents/MacOS/AskKeyApp"
list_rpaths() {
  otool -l "$1" | awk '/cmd LC_RPATH/ { rpath = 1; next }
    rpath && $1 == "path" { sub(/^ *path /, ""); sub(/ \(offset [0-9]+\)$/, ""); print; rpath = 0 }'
}
CHECKOUT_ROOT="$(pwd -P)"
DD_ROOT="$(cd "$DD" && pwd -P)"
LINKED_RPATHS="$(list_rpaths "$EXECUTABLE")"
while IFS= read -r rpath; do
  case "$rpath" in
    "$CHECKOUT_ROOT"/*|"$DD_ROOT"/*) install_name_tool -delete_rpath "$rpath" "$EXECUTABLE" ;;
  esac
done <<< "$LINKED_RPATHS"
if ! list_rpaths "$EXECUTABLE" | grep -Fxq '@executable_path/../Frameworks'; then
  install_name_tool -add_rpath @executable_path/../Frameworks "$EXECUTABLE"
fi

if [ -n "$CLOUDKIT_DIR" ]; then echo "==> Signing with the certificate the provisioning profile lists…"
else echo "==> Signing with $SIGN_IDENTITY …"; fi
SIGN_OPTIONS=(--force)
if [ "$CONFIG" = Release ]; then SIGN_OPTIONS=(--force --options runtime --timestamp); fi
# Only the App itself carries entitlements; nested code gets none.
APP_SIGN_OPTIONS=("${SIGN_OPTIONS[@]}")
if [ -n "$CLOUDKIT_DIR" ]; then
  python3 scripts/cloudkit-signing.py entitlements --team "$ASKKEY_APPLE_TEAM_ID" \
    --output "$CLOUDKIT_DIR/AskKeyApp.entitlements"
  APP_SIGN_OPTIONS+=(--entitlements "$CLOUDKIT_DIR/AskKeyApp.entitlements")
fi
codesign "${SIGN_OPTIONS[@]}" --sign "$SIGN_IDENTITY" "$CLI"
# Sign nested code inside out; --deep is used only for verification.
codesign "${SIGN_OPTIONS[@]}" --sign "$SIGN_IDENTITY" "$EMBEDDED_SPARKLE/Versions/B/Autoupdate"
codesign "${SIGN_OPTIONS[@]}" --sign "$SIGN_IDENTITY" "$EMBEDDED_SPARKLE/Versions/B/Updater.app"
codesign "${SIGN_OPTIONS[@]}" --sign "$SIGN_IDENTITY" "$EMBEDDED_SPARKLE"
codesign "${SIGN_OPTIONS[@]}" --sign "$SIGN_IDENTITY" "$APP/Contents/Helpers/askkey"
codesign "${SIGN_OPTIONS[@]}" --sign "$SIGN_IDENTITY" "$APP/Contents/Helpers/AskKey_AskKeyHelper.bundle"
codesign "${APP_SIGN_OPTIONS[@]}" --sign "$SIGN_IDENTITY" "$APP"
if [ -n "$CLOUDKIT_DIR" ]; then
  python3 scripts/cloudkit-signing.py verify --app "$APP" --team "$ASKKEY_APPLE_TEAM_ID" --work "$CLOUDKIT_DIR"
fi
codesign --verify --strict --deep "$APP"
if [ "$CONFIG" = Release ]; then
  ACTUAL_TEAM="$(codesign -dv --verbose=4 "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  [ "$ACTUAL_TEAM" = "$ASKKEY_APPLE_TEAM_ID" ] || { echo "AskKey signing team mismatch" >&2; exit 1; }
  codesign --verify --strict -R '=anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$APP"
fi

echo "==> Done."
echo "App: $(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")   (config: $CONFIG, version: $SHORT_VERSION)"
echo "CLI: $(pwd)/$CLI"
