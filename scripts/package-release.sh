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
trap 'exit 130' INT
trap 'exit 143' TERM
STAGING="$WORK_DIR/contents"
mkdir "$STAGING"
STAGED_APP="$STAGING/Ask Key.app"
ditto "$APP" "$STAGED_APP" || fail "Cannot stage the app"

notarize() {
  local artifact="$1" response="$WORK_DIR/notary-result.json" fields submitted=true
  # Tool diagnostics can contain signing or credential values; never echo them.
  if [[ -n "$NOTARY_CREDENTIAL" ]]; then
    local operation_id
    operation_id="$(uuidgen)"
    # PRIVATE_KEY_FILE, KEY_ID, and ISSUER_ID are Ask Key delivery mappings.
    # Expand them only inside the helper's target shell; never print their values.
    "$ASKKEY_RELEASE_HELPER" run --wait-for-approval --credential "$NOTARY_CREDENTIAL" \
      --operation-id "$operation_id" --caller-name "AskKey release" \
      --caller-purpose "Notarize AskKey $VERSION" -- \
      /bin/bash -c 'xcrun notarytool submit "$1" --key "$PRIVATE_KEY_FILE" --key-id "$KEY_ID" --issuer "$ISSUER_ID" --wait --output-format json' \
      bash "$artifact" >"$response" 2>/dev/null || submitted=false
  else
    xcrun notarytool submit "$artifact" --keychain-profile "$ASKKEY_NOTARY_PROFILE" \
      --wait --output-format json >"$response" 2>/dev/null || submitted=false
  fi
  fields="$(python3 - "$response" <<'PY'
import json
import re
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as response:
        result = json.load(response)
    status, submission_id = result["status"], result["id"]
    if not isinstance(status, str) or not status or "\n" in status or "\r" in status:
        raise ValueError()
    if not isinstance(submission_id, str) or not re.fullmatch(
        r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", submission_id
    ):
        raise ValueError()
    print(status)
    print(submission_id)
except (OSError, ValueError, KeyError, TypeError):
    sys.exit(1)
PY
)" || fail "Notarization failed or returned an invalid JSON result"
  local status="${fields%%$'\n'*}" submission_id="${fields#*$'\n'}"
  if [[ "$submitted" != true || "$status" != Accepted ]]; then
    printf 'Notarization was not accepted. Inspect the submission with:\n' >&2
    if [[ -n "$NOTARY_CREDENTIAL" ]]; then
      printf 'xcrun notarytool log %s --key ... --key-id ... --issuer ...\n' "$submission_id" >&2
    else
      printf 'xcrun notarytool log %s --keychain-profile ...\n' "$submission_id" >&2
    fi
    fail "Notarization must report Accepted"
  fi
}

if [[ "$NOTARIZE" == true ]]; then
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
[[ ! -e "$OUTPUT/$DMG_NAME" && ! -L "$OUTPUT/$DMG_NAME" && \
   ! -e "$OUTPUT/$DMG_NAME.sha256" && ! -L "$OUTPUT/$DMG_NAME.sha256" ]] \
  || fail "Output artifacts already exist; choose an empty output directory"
mkdir -p "$OUTPUT"
OUTPUT="$(CDPATH= cd -- "$OUTPUT" && pwd -P)"
ditto "$DMG" "$OUTPUT/$DMG_NAME" || fail "Cannot write the DMG to the output directory"
(cd "$OUTPUT" && shasum -a 256 "$DMG_NAME" >"$DMG_NAME.sha256")
SHA256="$(awk '{print $1}' "$OUTPUT/$DMG_NAME.sha256")"
printf 'DMG: %s\nSHA-256: %s\nNotarized: %s\n' "$OUTPUT/$DMG_NAME" "$SHA256" "$NOTARIZE"
