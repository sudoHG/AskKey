#!/usr/bin/env bash
# The iPhone app (#289, ADR 0013 → iPhone app) and its notification extension (#315,
# ADR 0014 → Notification Service Extension).
#
#   bash scripts/build-ios.sh build    Simulator build, unsigned; checks that the extension is
#                                      embedded and links no SwiftUI or kit code, and that both
#                                      bundles carry what TestFlight needs (#318).
#   bash scripts/build-ios.sh test     AskKeyiOSKitTests and AskKeyiOSNotificationServiceTests on a
#                                      simulator, unsigned, without an app host; writes the rendered
#                                      screens and notifications to .build/ios/screens.
#   ASKKEY_APPLE_TEAM_ID=<team> bash scripts/build-ios.sh export
#                                      Ad Hoc export for the maintainer's iPhone: automatic signing
#                                      for that team, the CloudKit container in both Info.plists, and
#                                      the Production container environment; then reads back the
#                                      signed entitlements of the app and the extension.
#   ASKKEY_APPLE_TEAM_ID=<team> ASKKEY_IOS_BUILD_NUMBER=<n> ASKKEY_ASC_CREDENTIAL=<name> \
#     bash scripts/build-ios.sh upload
#                                      TestFlight upload (ADR 0006 → iPhone distribution) from a clean
#                                      checkout: archives build <n> as export does, exports it for App
#                                      Store Connect with the Production container environment, reads
#                                      back both targets as export does plus their App Store profiles,
#                                      then uploads that .ipa with altool after an Ask Key approval for
#                                      the App Store Connect API key credential <name>. Deny the card to
#                                      stop after the read-back. ASKKEY_RELEASE_HELPER overrides the
#                                      helper path, as for package-release.sh.
#
# The Xcode project is generated from iOS/project.yml with XcodeGen and never committed. No team,
# signing identity, profile or App Store Connect key is stored in the repository. Agents never run
# export or upload.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd -P)"
MODE="${1:-build}"
case "$MODE" in
  build|test|export|upload) ;;
  *) echo 'Usage: build-ios.sh [build|test|export|upload]' >&2; exit 2 ;;
esac

PROJECT="$ROOT/iOS/AskKeyiOS.xcodeproj"
OUTPUT="$ROOT/.build/ios"
DERIVED="$OUTPUT/DerivedData"
CONTAINER="iCloud.com.sudohg.askkey"
BUNDLE_ID="com.sudohg.askkey.ios"
EXTENSION="AskKeyiOSNotificationService"
EXTENSION_BUNDLE_ID="com.sudohg.askkey.ios.notification-service"
ACCESS_GROUP_SUFFIX="com.sudohg.askkey.ios.shared"

# The upload's inputs are checked before anything is built.
if [[ "$MODE" == upload ]]; then
  BUILD_NUMBER="${ASKKEY_IOS_BUILD_NUMBER:-}"
  [[ "$BUILD_NUMBER" =~ ^[1-9][0-9]{0,8}$ ]] \
    || { echo 'Set ASKKEY_IOS_BUILD_NUMBER to a build number higher than every build uploaded for this version.' >&2; exit 1; }
  CREDENTIAL="${ASKKEY_ASC_CREDENTIAL:-}"
  [[ -n "$CREDENTIAL" ]] || { echo 'Set ASKKEY_ASC_CREDENTIAL to the Ask Key credential with the App Store Connect API key.' >&2; exit 1; }
  HELPER="${ASKKEY_RELEASE_HELPER:-/Applications/Ask Key.app/Contents/Helpers/askkey}"
  [[ -x "$HELPER" ]] || { echo "No Ask Key helper at $HELPER." >&2; exit 1; }
  STATUS="$(git status --porcelain)" || { echo 'Cannot read the checkout status.' >&2; exit 1; }
  [[ -z "$STATUS" ]] || { echo 'Upload from a clean checkout of the commit to ship.' >&2; exit 1; }
fi

AVAILABLE_KIB="$(df -k /System/Volumes/Data | awk 'NR==2 {print $4}')"
[[ "${AVAILABLE_KIB:-0}" -ge 83886080 ]] || { echo 'The iPhone build requires at least 80 GiB free.' >&2; exit 1; }
command -v xcodegen >/dev/null || { echo 'Install XcodeGen (brew install xcodegen) before building the iPhone app.' >&2; exit 1; }
mkdir -p "$OUTPUT"

# Every catalog entry has English and Simplified Chinese with the same
# placeholders, every key the kit's and the extension's Swift sources use is
# in their catalog, and the app's and the extension's catalogs hold the alert
# keys the AlertMessage subscription names.
python3 - "$ROOT/iOS" <<'PY'
import json, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
kit = root / 'AskKeyiOSKit/Resources/Localizable.xcstrings'
app = root / 'AskKeyiOS/Resources/Localizable.xcstrings'
extension = root / 'AskKeyiOSNotificationService/Resources/Localizable.xcstrings'
placeholder = re.compile(r'%(?:\d+\$)?(?:@|lld|d)')
problems = []
catalogs = {}
for catalog in (kit, app, extension):
    strings = json.loads(catalog.read_text(encoding='utf-8'))['strings']
    catalogs[catalog] = strings
    for key, entry in strings.items():
        units = [entry.get('localizations', {}).get(language, {}).get('stringUnit', {}) for language in ('en', 'zh-Hans')]
        if any(unit.get('state') != 'translated' or not unit.get('value') for unit in units):
            problems.append(f'{catalog.relative_to(root)}: "{key}" needs English and Simplified Chinese')
        elif len({tuple(sorted(placeholder.findall(unit['value']))) for unit in units} | {tuple(sorted(placeholder.findall(key)))}) != 1:
            problems.append(f'{catalog.relative_to(root)}: "{key}" has mismatched placeholders')
literal = re.compile(r'"((?:common|welcome|scanner|pairing|list|unusable|request|approver|mac)\.[A-Za-z0-9.]+)((?: \\\([^"]*?\))*)"')
for source in sorted((root / 'AskKeyiOSKit').rglob('*.swift')):
    for match in literal.finditer(source.read_text(encoding='utf-8')):
        key = match.group(1) + ' %@' * match.group(2).count('\\(')
        if key not in catalogs[kit]:
            problems.append(f'{source.relative_to(root)}: "{key}" is not in the kit catalog')
# The extension names its keys as literals, placeholders included.
extension_literal = re.compile(r'"(push\.[A-Za-z0-9.]+(?: %@)*)"')
for source in sorted((root / 'AskKeyiOSNotificationService/Sources').rglob('*.swift')):
    for match in extension_literal.finditer(source.read_text(encoding='utf-8')):
        if match.group(1) not in catalogs[extension]:
            problems.append(f'{source.relative_to(root)}: "{match.group(1)}" is not in the extension catalog')
for catalog in (app, extension):
    for key in ('push.message.title', 'push.message.body'):
        if key not in catalogs[catalog]:
            problems.append(f'{catalog.relative_to(root)}: "{key}" is missing')
for problem in problems:
    print(problem, file=sys.stderr)
sys.exit(1 if problems else 0)
PY

xcodegen generate --spec "$ROOT/iOS/project.yml" --quiet

# The newest iPhone simulator whose runtime's major version the selected Xcode's SDK supports.
pick_simulator() {
  local sdk
  sdk="$(xcrun --sdk iphonesimulator --show-sdk-version)"
  xcrun simctl list devices available -j | python3 -c '
import json, re, sys
devices = json.load(sys.stdin)["devices"]
sdk_major = int(sys.argv[1].split(".")[0])
def version(runtime):
    match = re.search(r"iOS-(\d+)-(\d+)", runtime)
    return tuple(map(int, match.groups())) if match else None
runtimes = sorted((r for r in devices if version(r) and version(r)[0] <= sdk_major), key=version, reverse=True)
for runtime in runtimes:
    for device in devices[runtime]:
        if device["name"].startswith("iPhone"):
            print(device["udid"], device["state"])
            sys.exit(0)
sys.exit("No available iPhone simulator for this Xcode.")' "$sdk"
}

# What TestFlight needs in both targets (#318): the app icon compiled from the Mac's Icon Composer
# document, a privacy manifest in the app, the kit framework and the extension that declares no
# tracking and no collected data and a reason for each required-reason API (the kit keeps the app's
# local state in UserDefaults; the extension uses none), the export compliance answer in the app's
# Info.plist, and one version and build number for the app and the extension. A third argument is
# the build number both must carry.
check_packaging() {
  python3 - "$1" "$2" "${3:-}" <<'PY'
import pathlib, plistlib, sys
app, appex, build = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
problems = []

def load(path):
    try:
        return plistlib.loads(path.read_bytes())
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        problems.append(f'{path.parent.name}/{path.name} cannot be read: {error}')
        return {}

infos = {}
# Each bundle whose code calls a required-reason API declares it in its own manifest: the kit's
# binary holds the UserDefaults code, and the app declares what its embedded code does.
user_defaults = {'NSPrivacyAccessedAPICategoryUserDefaults'}
for name, bundle, required in (('app', app, user_defaults), ('kit', app / 'Frameworks/AskKeyiOSKit.framework', user_defaults),
                               ('extension', appex, set())):
    infos[name] = load(bundle / 'Info.plist')
    manifest = load(bundle / 'PrivacyInfo.xcprivacy')
    if manifest.get('NSPrivacyTracking') is not False or manifest.get('NSPrivacyTrackingDomains', []) \
            or manifest.get('NSPrivacyCollectedDataTypes') != []:
        problems.append(f'{name}: the privacy manifest must declare no tracking and no collected data')
    declared = {entry.get('NSPrivacyAccessedAPIType'): entry.get('NSPrivacyAccessedAPITypeReasons') or []
                for entry in manifest.get('NSPrivacyAccessedAPITypes', [])}
    problems += [f'{name}: the privacy manifest gives no reason for {category}'
                 for category, reasons in sorted(declared.items()) if not reasons]
    problems += [f'{name}: the privacy manifest does not declare {category}'
                 for category in sorted(required - declared.keys())]
app_info, extension_info = infos['app'], infos['extension']
if not isinstance(app_info.get('ITSAppUsesNonExemptEncryption'), bool):
    problems.append('app: Info.plist has no ITSAppUsesNonExemptEncryption answer')
icon = app_info.get('CFBundleIcons', {}).get('CFBundlePrimaryIcon', {})
if icon.get('CFBundleIconName') != 'AppIcon' or not (app / 'Assets.car').is_file():
    problems.append('app: the AppIcon asset catalog is missing')
for key in ('CFBundleShortVersionString', 'CFBundleVersion'):
    if app_info.get(key) != extension_info.get(key):
        problems.append(f'{key} is {app_info.get(key)!r} in the app and {extension_info.get(key)!r} in the extension')
if build and app_info.get('CFBundleVersion') != build:
    problems.append(f'CFBundleVersion is {app_info.get("CFBundleVersion")!r}, expected {build!r}')
for problem in problems:
    print(problem, file=sys.stderr)
if not problems:
    print(f'Version {app_info["CFBundleShortVersionString"]} ({app_info["CFBundleVersion"]}), AppIcon, '
          f'privacy manifests, ITSAppUsesNonExemptEncryption = {app_info["ITSAppUsesNonExemptEncryption"]}')
sys.exit(1 if problems else 0)
PY
}

case "$MODE" in
build)
  xcodebuild build -project "$PROJECT" -scheme AskKeyiOS -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO -quiet
  APP="$DERIVED/Build/Products/Debug-iphonesimulator/AskKey.app"
  APPEX="$APP/PlugIns/$EXTENSION.appex"
  test -x "$APP/AskKey"
  test -d "$APP/Frameworks/AskKeyiOSKit.framework"
  test -x "$APPEX/$EXTENSION"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APPEX/Info.plist")" == "$EXTENSION_BUNDLE_ID" ]]
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$APPEX/Info.plist")" \
    == com.apple.usernotifications.service ]]
  # The extension links AskKeyDevices and the keychain code, never the kit or SwiftUI.
  if otool -L "$APPEX/$EXTENSION" | grep -E 'SwiftUI|AskKeyiOSKit'; then
    echo 'The notification extension must not link SwiftUI or AskKeyiOSKit.' >&2
    exit 1
  fi
  check_packaging "$APP" "$APPEX"
  echo "Built $(basename "$APP") with $EXTENSION.appex for the iOS Simulator"
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
  NOTIFICATIONS="$(find "$SCREENS" -name '*-notification-*.png' | wc -l | tr -d ' ')"
  [[ "$NOTIFICATIONS" -ge 6 ]] || { echo "Expected at least 6 rendered notifications, found $NOTIFICATIONS." >&2; exit 1; }
  echo "Rendered $COUNT screens into ${SCREENS#"$ROOT"/}"
  ;;
export|upload)
  TEAM="${ASKKEY_APPLE_TEAM_ID:-}"
  [[ "$TEAM" =~ ^[A-Z0-9]{10}$ ]] || { echo 'Set ASKKEY_APPLE_TEAM_ID to the ten-character Apple Developer team ID.' >&2; exit 1; }
  ARCHIVE="$OUTPUT/AskKeyiOS.xcarchive"
  EXPORT="$OUTPUT/export"
  OPTIONS="$OUTPUT/ExportOptions.plist"
  rm -rf "$ARCHIVE" "$EXPORT" "$OPTIONS"
  SETTINGS=(DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic CLOUDKIT_CONTAINER_IDENTIFIER="$CONTAINER")
  # A setting on the command line applies to every target, so the app and the extension carry the same build number.
  [[ "$MODE" == export ]] || SETTINGS+=(CURRENT_PROJECT_VERSION="$BUILD_NUMBER")
  xcodebuild archive -project "$PROJECT" -scheme AskKeyiOS -configuration Release -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" -derivedDataPath "$DERIVED" -allowProvisioningUpdates "${SETTINGS[@]}"
  if [[ "$MODE" == export ]]; then
    /usr/libexec/PlistBuddy -c 'Add :method string release-testing' -c "Add :teamID string $TEAM" \
      -c 'Add :signingStyle string automatic' -c 'Add :iCloudContainerEnvironment string Production' \
      -c 'Add :thinning string <none>' "$OPTIONS" >/dev/null
  else
    # Exported to disk, so the .ipa that is read back is the one uploaded; Xcode keeps the build
    # number, and the build stays eligible for external testing.
    /usr/libexec/PlistBuddy -c 'Add :method string app-store-connect' -c 'Add :destination string export' \
      -c "Add :teamID string $TEAM" -c 'Add :signingStyle string automatic' \
      -c 'Add :iCloudContainerEnvironment string Production' -c 'Add :manageAppVersionAndBuildNumber bool false' \
      -c 'Add :testFlightInternalTestingOnly bool false' -c 'Add :uploadSymbols bool true' "$OPTIONS" >/dev/null
  fi
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" -exportOptionsPlist "$OPTIONS" \
    -allowProvisioningUpdates
  IPA="$(find "$EXPORT" -maxdepth 1 -name '*.ipa' | head -n 1)"
  [[ -n "$IPA" ]] || { echo 'The export produced no .ipa.' >&2; exit 1; }
  CHECK="$(mktemp -d)"
  trap 'rm -rf "$CHECK"' EXIT
  ditto -x -k "$IPA" "$CHECK"
  APP="$(find "$CHECK/Payload" -maxdepth 1 -name '*.app' | head -n 1)"
  APPEX="$APP/PlugIns/$EXTENSION.appex"
  codesign --verify --strict "$APPEX"
  codesign --verify --strict "$APP"
  for target in app extension; do
    bundle="$APP"; [[ "$target" == app ]] || bundle="$APPEX"
    codesign -d --entitlements - --xml "$bundle" > "$CHECK/$target.plist" 2>/dev/null \
      || { echo "Cannot read the $target's signed entitlements." >&2; exit 1; }
    security cms -D -i "$bundle/embedded.mobileprovision" > "$CHECK/$target-profile.plist" 2>/dev/null \
      || { echo "Cannot read the $target's embedded profile." >&2; exit 1; }
  done
  check_packaging "$APP" "$APPEX" "${BUILD_NUMBER:-}"
  python3 - "$MODE" "$CHECK" "$APP" "$APPEX" "$TEAM" "$BUNDLE_ID" "$EXTENSION_BUNDLE_ID" "$CONTAINER" "$ACCESS_GROUP_SUFFIX" <<'PY'
import plistlib, sys
mode, check, app, appex, team, bundle_id, extension_id, container, group_suffix = sys.argv[1:]
group = f'{team}.{group_suffix}'
shared = {
    'com.apple.developer.team-identifier': team,
    'com.apple.developer.icloud-container-environment': 'Production',
    'com.apple.developer.icloud-container-identifiers': [container],
    'com.apple.developer.icloud-services': ['CloudKit'],
    'com.apple.developer.usernotifications.time-sensitive': True,
    'keychain-access-groups': [group],
}
# The app receives the pushes; the extension has no push entitlement, and
# neither asks for notification filtering (ADR 0014, decision 7).
targets = [
    ('app', 'app', app, bundle_id, {**shared, 'aps-environment': 'production'}, set()),
    ('extension', 'extension', appex, extension_id, shared, {'aps-environment'}),
]
problems = []
for name, prefix, bundle, identifier, expected, absent in targets:
    entitlements = plistlib.load(open(f'{check}/{prefix}.plist', 'rb'))
    info = plistlib.load(open(f'{bundle}/Info.plist', 'rb'))
    expected = {'application-identifier': f'{team}.{identifier}', **expected}
    problems += [f'{name}: entitlement {key} is {entitlements.get(key)!r}, expected {value!r}'
                 for key, value in expected.items() if entitlements.get(key) != value]
    for key in absent | {'get-task-allow', 'com.apple.developer.usernotifications.filtering'}:
        if key in entitlements and entitlements[key] is not False:
            problems.append(f'{name}: entitlement {key} is set')
    for key, value in {'CFBundleIdentifier': identifier, 'CloudKitContainerIdentifier': container,
                       'KeychainAccessGroup': group}.items():
        if info.get(key) != value:
            problems.append(f'{name}: Info.plist {key} is {info.get(key)!r}, expected {value!r}')
    if name == 'extension' and info.get('NSExtension', {}).get('NSExtensionPointIdentifier') != 'com.apple.usernotifications.service':
        problems.append('extension: Info.plist is not a notification service extension')
    if mode == 'upload':
        # TestFlight needs App Store profiles: they name no devices and carry beta-reports-active
        # (TN2415); Ad Hoc and development profiles name devices.
        profile = plistlib.load(open(f'{check}/{prefix}-profile.plist', 'rb'))
        profile_entitlements = profile.get('Entitlements', {})
        if profile.get('TeamIdentifier') != [team] or 'ProvisionedDevices' in profile \
                or profile.get('ProvisionsAllDevices') or profile_entitlements.get('beta-reports-active') is not True:
            problems.append(f'{name}: the embedded profile is not an App Store profile for the team')
        elif profile_entitlements.get('application-identifier') != f'{team}.{identifier}':
            problems.append(f'{name}: the embedded profile is for another App ID')
    if not problems:
        for key in sorted(expected):
            print(f'{name}: {key} = {entitlements[key]}')
for problem in problems:
    print(problem, file=sys.stderr)
sys.exit(1 if problems else 0)
PY
  if [[ "$MODE" == export ]]; then
    echo "Exported ${IPA#"$ROOT"/}"
    exit 0
  fi
  # The key file path and IDs expand only in the helper's target shell; altool reads the key itself.
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist")"
  printf 'Read back %s. Approve the Ask Key card to upload version %s (%s) to App Store Connect, or deny it to stop here.\n' \
    "${IPA#"$ROOT"/}" "$VERSION" "$BUILD_NUMBER"
  UPLOAD_TARGET='set +x; set -eu; [[ -f "$PRIVATE_KEY_FILE" && -r "$PRIVATE_KEY_FILE" ]] || exit 1; '
  UPLOAD_TARGET+='exec xcrun altool --upload-package "$1" --api-key "$KEY_ID" --api-issuer "$ISSUER_ID" --p8-file-path "$PRIVATE_KEY_FILE"'
  if ! "$HELPER" run --wait-for-approval --credential "$CREDENTIAL" --operation-id "$(uuidgen)" \
      --caller-name "AskKey iPhone upload" --caller-purpose "Upload AskKey for iPhone $VERSION ($BUILD_NUMBER) to App Store Connect" -- \
      /bin/bash -c "$UPLOAD_TARGET" bash "$IPA"; then
    echo "The upload did not finish. If altool started, check TestFlight for build $BUILD_NUMBER before uploading again." >&2
    exit 1
  fi
  echo "Uploaded version $VERSION ($BUILD_NUMBER); App Store Connect processes it before it appears in TestFlight."
  ;;
esac
