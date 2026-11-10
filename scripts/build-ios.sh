#!/usr/bin/env bash
# The pairing-only iPhone app (#289, ADR 0013 → iPhone app).
#
#   bash scripts/build-ios.sh build    Simulator build, unsigned.
#   bash scripts/build-ios.sh test     AskKeyiOSKitTests on a simulator, unsigned, without an
#                                      app host; writes the rendered screens to .build/ios/screens.
#   ASKKEY_APPLE_TEAM_ID=<team> bash scripts/build-ios.sh export
#                                      Ad Hoc export for the maintainer's iPhone: automatic signing
#                                      for that team, the CloudKit container in the Info.plist, and
#                                      the Production container environment; then reads back the
#                                      signed entitlements.
#
# The Xcode project is generated from iOS/project.yml with XcodeGen and never committed. No team,
# signing identity or profile is stored in the repository.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd -P)"
MODE="${1:-build}"
case "$MODE" in
  build|test|export) ;;
  *) echo 'Usage: build-ios.sh [build|test|export]' >&2; exit 2 ;;
esac

PROJECT="$ROOT/iOS/AskKeyiOS.xcodeproj"
OUTPUT="$ROOT/.build/ios"
DERIVED="$OUTPUT/DerivedData"
CONTAINER="iCloud.com.sudohg.askkey"
BUNDLE_ID="com.sudohg.askkey.ios"
ACCESS_GROUP_SUFFIX="com.sudohg.askkey.ios.shared"

AVAILABLE_KIB="$(df -k /System/Volumes/Data | awk 'NR==2 {print $4}')"
[[ "${AVAILABLE_KIB:-0}" -ge 83886080 ]] || { echo 'The iPhone build requires at least 80 GiB free.' >&2; exit 1; }
command -v xcodegen >/dev/null || { echo 'Install XcodeGen (brew install xcodegen) before building the iPhone app.' >&2; exit 1; }
mkdir -p "$OUTPUT"

# Every catalog entry has English and Simplified Chinese with the same
# placeholders, every key the kit's Swift sources use is in its catalog, and
# the app's catalog holds the alert keys the AlertMessage subscription names.
python3 - "$ROOT/iOS" <<'PY'
import json, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
kit = root / 'AskKeyiOSKit/Resources/Localizable.xcstrings'
app = root / 'AskKeyiOS/Resources/Localizable.xcstrings'
placeholder = re.compile(r'%(?:\d+\$)?(?:@|lld|d)')
problems = []
catalogs = {}
for catalog in (kit, app):
    strings = json.loads(catalog.read_text(encoding='utf-8'))['strings']
    catalogs[catalog] = strings
    for key, entry in strings.items():
        units = [entry.get('localizations', {}).get(language, {}).get('stringUnit', {}) for language in ('en', 'zh-Hans')]
        if any(unit.get('state') != 'translated' or not unit.get('value') for unit in units):
            problems.append(f'{catalog.relative_to(root)}: "{key}" needs English and Simplified Chinese')
        elif len({tuple(sorted(placeholder.findall(unit['value']))) for unit in units} | {tuple(sorted(placeholder.findall(key)))}) != 1:
            problems.append(f'{catalog.relative_to(root)}: "{key}" has mismatched placeholders')
literal = re.compile(r'"((?:common|welcome|scanner|pairing|list|unusable)\.[A-Za-z0-9.]+)((?: \\\([^"]*?\))*)"')
for source in sorted((root / 'AskKeyiOSKit').rglob('*.swift')):
    for match in literal.finditer(source.read_text(encoding='utf-8')):
        key = match.group(1) + ' %@' * match.group(2).count('\\(')
        if key not in catalogs[kit]:
            problems.append(f'{source.relative_to(root)}: "{key}" is not in the kit catalog')
for key in ('push.message.title', 'push.message.body'):
    if key not in catalogs[app]:
        problems.append(f'{app.relative_to(root)}: "{key}" is missing')
for problem in problems:
    print(problem, file=sys.stderr)
sys.exit(1 if problems else 0)
PY

xcodegen generate --spec "$ROOT/iOS/project.yml" --quiet

pick_simulator() {
  xcrun simctl list devices available -j | python3 -c '
import json, re, sys
devices = json.load(sys.stdin)["devices"]
def version(runtime):
    match = re.search(r"iOS-(\d+)-(\d+)", runtime)
    return tuple(map(int, match.groups())) if match else None
runtimes = sorted((r for r in devices if version(r)), key=version, reverse=True)
for runtime in runtimes:
    for device in devices[runtime]:
        if device["name"].startswith("iPhone"):
            print(device["udid"], device["state"])
            sys.exit(0)
sys.exit("No available iPhone simulator.")'
}

case "$MODE" in
build)
  xcodebuild build -project "$PROJECT" -scheme AskKeyiOS -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO -quiet
  APP="$DERIVED/Build/Products/Debug-iphonesimulator/AskKey.app"
  test -x "$APP/AskKey" && test -d "$APP/Frameworks/AskKeyiOSKit.framework"
  echo "Built $(basename "$APP") for the iOS Simulator"
  ;;
test)
  read -r UDID STATE < <(pick_simulator)
  SCREENS="$OUTPUT/screens"
  rm -rf "$SCREENS"
  mkdir -p "$SCREENS"
  status=0
  # TEST_RUNNER_ variables reach the test process without the prefix.
  TEST_RUNNER_SCREEN_RENDER_DIRECTORY="$SCREENS" xcodebuild test -project "$PROJECT" -scheme AskKeyiOSKitTests \
    -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO || status=$?
  [[ "$STATE" == Booted ]] || xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
  [[ "$status" -eq 0 ]] || exit "$status"
  COUNT="$(find "$SCREENS" -name '*.png' | wc -l | tr -d ' ')"
  [[ "$COUNT" -ge 8 ]] || { echo "Expected at least 8 rendered screens, found $COUNT." >&2; exit 1; }
  echo "Rendered $COUNT screens into ${SCREENS#"$ROOT"/}"
  ;;
export)
  TEAM="${ASKKEY_APPLE_TEAM_ID:-}"
  [[ "$TEAM" =~ ^[A-Z0-9]{10}$ ]] || { echo 'Set ASKKEY_APPLE_TEAM_ID to the ten-character Apple Developer team ID.' >&2; exit 1; }
  ARCHIVE="$OUTPUT/AskKeyiOS.xcarchive"
  EXPORT="$OUTPUT/export"
  OPTIONS="$OUTPUT/ExportOptions.plist"
  rm -rf "$ARCHIVE" "$EXPORT" "$OPTIONS"
  xcodebuild archive -project "$PROJECT" -scheme AskKeyiOS -configuration Release -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" -derivedDataPath "$DERIVED" -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic CLOUDKIT_CONTAINER_IDENTIFIER="$CONTAINER"
  /usr/libexec/PlistBuddy -c 'Add :method string release-testing' -c "Add :teamID string $TEAM" \
    -c 'Add :signingStyle string automatic' -c 'Add :iCloudContainerEnvironment string Production' \
    -c 'Add :thinning string <none>' "$OPTIONS" >/dev/null
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" -exportOptionsPlist "$OPTIONS" \
    -allowProvisioningUpdates
  IPA="$(find "$EXPORT" -maxdepth 1 -name '*.ipa' | head -n 1)"
  [[ -n "$IPA" ]] || { echo 'The export produced no .ipa.' >&2; exit 1; }
  CHECK="$(mktemp -d)"
  trap 'rm -rf "$CHECK"' EXIT
  ditto -x -k "$IPA" "$CHECK"
  APP="$(find "$CHECK/Payload" -maxdepth 1 -name '*.app' | head -n 1)"
  codesign --verify --strict "$APP"
  codesign -d --entitlements - --xml "$APP" > "$CHECK/entitlements.plist" 2>/dev/null
  python3 - "$CHECK/entitlements.plist" "$APP/Info.plist" "$TEAM" "$BUNDLE_ID" "$CONTAINER" "$ACCESS_GROUP_SUFFIX" <<'PY'
import plistlib, sys
entitlements_path, info_path, team, bundle_id, container, group_suffix = sys.argv[1:]
entitlements = plistlib.load(open(entitlements_path, 'rb'))
info = plistlib.load(open(info_path, 'rb'))
group = f'{team}.{group_suffix}'
expected = {
    'application-identifier': f'{team}.{bundle_id}',
    'com.apple.developer.team-identifier': team,
    'aps-environment': 'production',
    'com.apple.developer.icloud-container-environment': 'Production',
    'com.apple.developer.icloud-container-identifiers': [container],
    'com.apple.developer.icloud-services': ['CloudKit'],
    'keychain-access-groups': [group],
}
problems = [f'entitlement {key} is {entitlements.get(key)!r}, expected {value!r}'
            for key, value in expected.items() if entitlements.get(key) != value]
if entitlements.get('get-task-allow'):
    problems.append('entitlement get-task-allow is set')
for key, value in {'CFBundleIdentifier': bundle_id, 'CloudKitContainerIdentifier': container,
                   'KeychainAccessGroup': group}.items():
    if info.get(key) != value:
        problems.append(f'Info.plist {key} is {info.get(key)!r}, expected {value!r}')
for problem in problems:
    print(problem, file=sys.stderr)
if problems:
    sys.exit(1)
for key in sorted(expected):
    print(f'{key} = {entitlements[key]}')
PY
  echo "Exported ${IPA#"$ROOT"/}"
  ;;
esac
