#!/usr/bin/env bash
# Package a signed Release app. --no-notarize is for synthetic packaging checks.
set +x
set -euo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
APP="$ROOT_DIR/.build/AskKeyApp.app"
OUTPUT="$ROOT_DIR/.build/release-artifacts"
NOTARIZE=true
NOTARY_CREDENTIAL=""
ASKKEY_RELEASE_HELPER="${ASKKEY_RELEASE_HELPER:-/Applications/Ask Key.app/Contents/Helpers/askkey}"

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

usage() {
  echo "Usage: $0 [--app PATH] [--output DIR] [--notary-credential NAME] [--no-notarize]"
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --app|--output)
      [[ "$#" -ge 2 && -n "$2" && "$2" != --* ]] || fail "$1 requires a path"
      if [[ "$1" == --app ]]; then APP="$2"; else OUTPUT="$2"; fi
      shift 2
      ;;
    --notary-credential)
      [[ "$#" -ge 2 && -n "$2" && "$2" != --* ]] || fail "$1 requires a name"
      NOTARY_CREDENTIAL="$2"
      shift 2
      ;;
    --no-notarize) NOTARIZE=false; shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; fail "Unknown argument" ;;
  esac
done

if [[ -n "$NOTARY_CREDENTIAL" && "$NOTARIZE" == false ]]; then
  fail "Notary credential and --no-notarize modes conflict"
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
fi

[[ -d "$APP" ]] || fail "App bundle not found: $APP"
APP="$(CDPATH= cd -- "$APP" && pwd -P)"
VERSION="$(bash "$ROOT_DIR/scripts/product-version.sh")"
PLIST="$APP/Contents/Info.plist"
[[ -f "$PLIST" ]] || fail "App Info.plist not found"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null)" \
  || fail "App version is missing or invalid"
[[ "$APP_VERSION" == "$VERSION" ]] || fail "App version does not match the product version"
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
if [[ "$NOTARIZE" == true ]]; then OUTPUT_NAMES+=("AskKey.dmg" "AskKey.dmg.sha256"); fi
for name in "${OUTPUT_NAMES[@]}"; do
  [[ ! -e "$OUTPUT/$name" && ! -L "$OUTPUT/$name" ]] \
    || fail "Output artifacts already exist; choose an empty output directory"
done
mkdir -p "$OUTPUT"
OUTPUT="$(CDPATH= cd -- "$OUTPUT" && pwd -P)"
ditto "$DMG" "$OUTPUT/$DMG_NAME" || fail "Cannot write the DMG to the output directory"
(cd "$OUTPUT" && shasum -a 256 "$DMG_NAME" >"$DMG_NAME.sha256")
if [[ "$NOTARIZE" == true ]]; then
  ditto "$OUTPUT/$DMG_NAME" "$OUTPUT/AskKey.dmg" || fail "Cannot write the stable-named DMG"
  (cd "$OUTPUT" && shasum -a 256 AskKey.dmg >AskKey.dmg.sha256)
fi
SHA256="$(awk '{print $1}' "$OUTPUT/$DMG_NAME.sha256")"
printf 'DMG: %s\nSHA-256: %s\nNotarized: %s\n' "$OUTPUT/$DMG_NAME" "$SHA256" "$NOTARIZE"
