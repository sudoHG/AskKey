#!/usr/bin/env bash
# Package a signed Release app. --no-notarize is for synthetic packaging checks.
set +x
set -euo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
APP="$ROOT_DIR/.build/AskKeyApp.app"
OUTPUT="$ROOT_DIR/.build/release-artifacts"
NOTARIZE=true
NOTARY_CREDENTIAL=""
SPARKLE_KEY_CREDENTIAL=""
RELEASE_NOTES=""
CRITICAL=false
ASKKEY_RELEASE_HELPER="${ASKKEY_RELEASE_HELPER:-/Applications/Ask Key.app/Contents/Helpers/askkey}"
# The delivered key file path expands only in the helper's target shell.
APPCAST_TARGET='set +x; set -eu; exec python3 "$@" --ed-key-file "$SPARKLE_ED_KEY_FILE"'

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

usage() {
  echo "Usage: $0 [--app PATH] [--output DIR] [--notary-credential NAME]"
  echo "       [--sparkle-key-credential NAME --release-notes PATH [--critical]] [--no-notarize]"
  echo "Notarized runs need --sparkle-key-credential and --release-notes and also write appcast.xml."
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --app|--output|--release-notes)
      [[ "$#" -ge 2 && -n "$2" && "$2" != --* ]] || fail "$1 requires a path"
      case "$1" in
        --app) APP="$2" ;;
        --output) OUTPUT="$2" ;;
        *) RELEASE_NOTES="$2" ;;
      esac
      shift 2
      ;;
    --notary-credential|--sparkle-key-credential)
      [[ "$#" -ge 2 && -n "$2" && "$2" != --* ]] || fail "$1 requires a name"
      if [[ "$1" == --notary-credential ]]; then NOTARY_CREDENTIAL="$2"; else SPARKLE_KEY_CREDENTIAL="$2"; fi
      shift 2
      ;;
    --critical) CRITICAL=true; shift ;;
    --no-notarize) NOTARIZE=false; shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; fail "Unknown argument" ;;
  esac
done

if [[ -n "$NOTARY_CREDENTIAL" && "$NOTARIZE" == false ]]; then
  fail "Notary credential and --no-notarize modes conflict"
fi
if [[ "$NOTARIZE" == false && ( -n "$SPARKLE_KEY_CREDENTIAL" || -n "$RELEASE_NOTES" || "$CRITICAL" == true ) ]]; then
  fail "Appcast options and --no-notarize modes conflict"
fi
if [[ -n "$NOTARY_CREDENTIAL" && -n "${ASKKEY_NOTARY_PROFILE:-}" ]]; then
  fail "Notary credential and ASKKEY_NOTARY_PROFILE modes conflict"
fi
if [[ "$NOTARIZE" == true ]]; then
  [[ -n "${ASKKEY_CODESIGN_IDENTITY:-}" ]] || fail "ASKKEY_CODESIGN_IDENTITY is required"
  [[ -n "${ASKKEY_APPLE_TEAM_ID:-}" ]] || fail "ASKKEY_APPLE_TEAM_ID is required"
  if [[ -z "$NOTARY_CREDENTIAL" && -z "${ASKKEY_NOTARY_PROFILE:-}" ]]; then
    fail "Exactly one of --notary-credential or ASKKEY_NOTARY_PROFILE is required"
  fi
  [[ "$ASKKEY_CODESIGN_IDENTITY" != - ]] || fail "A Developer ID signing identity is required"
  [[ -n "$SPARKLE_KEY_CREDENTIAL" ]] || fail "--sparkle-key-credential is required when notarizing"
  [[ -n "$RELEASE_NOTES" ]] || fail "--release-notes is required when notarizing"
  [[ -f "$RELEASE_NOTES" ]] || fail "Release notes not found: $RELEASE_NOTES"
  RELEASE_NOTES="$(CDPATH= cd -- "$(dirname -- "$RELEASE_NOTES")" && pwd -P)/$(basename -- "$RELEASE_NOTES")"
  python3 "$ROOT_DIR/scripts/generate-appcast.py" --check-release-notes "$RELEASE_NOTES" || exit 1
fi

[[ -d "$APP" ]] || fail "App bundle not found: $APP"
APP="$(CDPATH= cd -- "$APP" && pwd -P)"
VERSION="$(bash "$ROOT_DIR/scripts/product-version.sh")"
PLIST="$APP/Contents/Info.plist"
[[ -f "$PLIST" ]] || fail "App Info.plist not found"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null)" \
  || fail "App version is missing or invalid"
[[ "$APP_VERSION" == "$VERSION" ]] || fail "App version does not match the product version"
if [[ "$NOTARIZE" == true ]]; then
  # The appcast's sparkle:version is the product version, so it must be CFBundleVersion.
  BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST" 2>/dev/null)" \
    || fail "App bundle version is missing or invalid"
  [[ "$BUNDLE_VERSION" == "$VERSION" ]] || fail "App bundle version does not match the product version"
fi
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST" 2>/dev/null)" \
  || fail "App bundle identifier is missing or invalid"
[[ "$BUNDLE_ID" == com.sudohg.askkey.app ]] || fail "App bundle identifier must be com.sudohg.askkey.app"
codesign --verify --strict --deep "$APP" >/dev/null 2>&1 || fail "App code signature verification failed"
if [[ "$NOTARIZE" == true ]]; then
  SIGNATURE="$(codesign -dv --verbose=4 "$APP" 2>&1)" || fail "Cannot inspect the app signing team"
  ACTUAL_TEAM="$(printf '%s\n' "$SIGNATURE" | sed -n 's/^TeamIdentifier=//p')"
  [[ "$ACTUAL_TEAM" == "$ASKKEY_APPLE_TEAM_ID" ]] || fail "App signing team mismatch"
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/askkey-package-release.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
report_notary_ids() {
  if [[ -f "$WORK_DIR/notary-result.json" ]]; then
    python3 "$ROOT_DIR/scripts/notarize-release.py" --report-ids "$WORK_DIR/notary-result.json" >&2 || true
  fi
}
trap 'report_notary_ids; exit 130' INT
trap 'report_notary_ids; exit 143' TERM
STAGING="$WORK_DIR/contents"
mkdir "$STAGING"
STAGED_APP="$STAGING/Ask Key.app"
ditto "$APP" "$STAGED_APP" || fail "Cannot stage the app"
# A CloudKit build (ADR 0013) keeps its embedded profile. Before notarizing,
# check that the profile is still valid and is the one the signature sealed,
# and that the signed entitlements are the CloudKit ones.
STAGED_PROFILE="$STAGED_APP/Contents/embedded.provisionprofile"
if [[ -e "$STAGED_PROFILE" || -L "$STAGED_PROFILE" ]]; then
  [[ -n "${ASKKEY_APPLE_TEAM_ID:-}" ]] || fail "ASKKEY_APPLE_TEAM_ID is required to check the embedded provisioning profile"
  python3 "$ROOT_DIR/scripts/cloudkit-signing.py" check-app --app "$STAGED_APP" --team "$ASKKEY_APPLE_TEAM_ID" \
    || fail "The embedded provisioning profile or the signed entitlements are not valid"
fi

notarize() {
  local artifact="$1" response="$WORK_DIR/notary-result.json" completed=true
  local runner="$ROOT_DIR/scripts/notarize-release.py"
  # Tool diagnostics can contain signing or credential values; never echo them.
  if [[ -n "$NOTARY_CREDENTIAL" ]]; then
    # The runner never receives credential values; each request gets a fresh
    # delivery, expanded only inside that helper run's target shell.
    python3 "$runner" "$artifact" --credential "$NOTARY_CREDENTIAL" \
      --helper "$ASKKEY_RELEASE_HELPER" --version "$VERSION" \
      >"$response" 2>/dev/null || completed=false
  else
    python3 "$runner" "$artifact" --keychain-profile "$ASKKEY_NOTARY_PROFILE" \
      >"$response" 2>/dev/null || completed=false
  fi
  python3 "$runner" --summarize "$response" "$completed" || return 1
}

if [[ "$NOTARIZE" == true ]]; then
  if [[ -n "$NOTARY_CREDENTIAL" ]]; then
    printf 'Approve the first Ask Key card with a timed allowance (Allow for N Minutes); later requests may ask again if needed.\n'
  fi
  APP_ZIP="$WORK_DIR/AskKey.zip"
  ditto -c -k --keepParent "$STAGED_APP" "$APP_ZIP" || fail "Cannot archive the app"
  notarize "$APP_ZIP"
  xcrun stapler staple "$STAGED_APP" >/dev/null 2>&1 || fail "Cannot staple the app"
  xcrun stapler validate "$STAGED_APP" >/dev/null 2>&1 || fail "App staple validation failed"
  spctl -a -vv -t exec "$STAGED_APP" >"$WORK_DIR/app-assessment" 2>&1 \
    || fail "Gatekeeper did not accept the app"
  grep -Fq 'source=Notarized Developer ID' "$WORK_DIR/app-assessment" \
    || fail "Gatekeeper did not report Notarized Developer ID for the app"
fi

ln -s /Applications "$STAGING/Applications"
DMG_NAME="AskKey-$VERSION.dmg"
if [[ "$NOTARIZE" == false ]]; then DMG_NAME="AskKey-$VERSION-unnotarized.dmg"; fi
DMG="$WORK_DIR/$DMG_NAME"
hdiutil create -volname "Ask Key $VERSION" -srcfolder "$STAGING" -format UDZO \
  -fs HFS+ -ov "$DMG" >/dev/null 2>&1 || fail "Cannot create the DMG"

if [[ "$NOTARIZE" == true ]]; then
  codesign --sign "$ASKKEY_CODESIGN_IDENTITY" --timestamp "$DMG" >/dev/null 2>&1 \
    || fail "Cannot sign the DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG" >/dev/null 2>&1 || fail "Cannot staple the DMG"
  xcrun stapler validate "$DMG" >/dev/null 2>&1 || fail "DMG staple validation failed"
  spctl -a -vv -t open --context context:primary-signature "$DMG" \
    >"$WORK_DIR/dmg-assessment" 2>&1 || fail "Gatekeeper did not accept the DMG"
  grep -Eq '(^|: )accepted$' "$WORK_DIR/dmg-assessment" || fail "Gatekeeper did not accept the DMG"
fi

# Do not expose a release-named image until every requested check succeeds.
OUTPUT_NAMES=("$DMG_NAME" "$DMG_NAME.sha256")
if [[ "$NOTARIZE" == true ]]; then OUTPUT_NAMES+=("AskKey.dmg" "AskKey.dmg.sha256" "appcast.xml"); fi
for name in "${OUTPUT_NAMES[@]}"; do
  [[ ! -e "$OUTPUT/$name" && ! -L "$OUTPUT/$name" ]] \
    || fail "Output artifacts already exist; choose an empty output directory"
done

if [[ "$NOTARIZE" == true ]]; then
  # Sign the final, stapled DMG. The generator signs and verifies the DMG and the
  # feed, and never prints sign_update output, which can echo key material.
  APPCAST_ARGUMENTS=("$ROOT_DIR/scripts/generate-appcast.py" "$DMG" --version "$VERSION"
    --release-notes "$RELEASE_NOTES" --output "$WORK_DIR/appcast.xml")
  if [[ "$CRITICAL" == true ]]; then APPCAST_ARGUMENTS+=(--critical); fi
  printf 'Approve the Ask Key card to sign the update feed.\n'
  "$ASKKEY_RELEASE_HELPER" run --wait-for-approval --credential "$SPARKLE_KEY_CREDENTIAL" \
    --operation-id "$(uuidgen)" --caller-name "AskKey release" \
    --caller-purpose "Sign the AskKey $VERSION update feed" -- \
    /bin/bash -c "$APPCAST_TARGET" bash "${APPCAST_ARGUMENTS[@]}" >/dev/null \
    || fail "Cannot write the signed appcast; check Ask Key approval, credential delivery and sign_update"
  [[ -f "$WORK_DIR/appcast.xml" ]] || fail "The signed appcast was not written"
fi

mkdir -p "$OUTPUT"
OUTPUT="$(CDPATH= cd -- "$OUTPUT" && pwd -P)"
ditto "$DMG" "$OUTPUT/$DMG_NAME" || fail "Cannot write the DMG to the output directory"
(cd "$OUTPUT" && shasum -a 256 "$DMG_NAME" >"$DMG_NAME.sha256")
if [[ "$NOTARIZE" == true ]]; then
  ditto "$OUTPUT/$DMG_NAME" "$OUTPUT/AskKey.dmg" || fail "Cannot write the stable-named DMG"
  (cd "$OUTPUT" && shasum -a 256 AskKey.dmg >AskKey.dmg.sha256)
  ditto "$WORK_DIR/appcast.xml" "$OUTPUT/appcast.xml" || fail "Cannot write the appcast"
fi
SHA256="$(awk '{print $1}' "$OUTPUT/$DMG_NAME.sha256")"
printf 'DMG: %s\nSHA-256: %s\nNotarized: %s\n' "$OUTPUT/$DMG_NAME" "$SHA256" "$NOTARIZE"
if [[ "$NOTARIZE" == true ]]; then printf 'Appcast: %s\n' "$OUTPUT/appcast.xml"; fi
