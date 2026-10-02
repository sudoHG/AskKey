#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
LAUNCHER="$ROOT_DIR/scripts/run-dev-app.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "$LAUNCHER" ]] || fail "missing development launcher: $LAUNCHER"
bash -n "$LAUNCHER"

run_plan="$(make -C "$ROOT_DIR" -n run)"
grep -Fq 'scripts/run-dev-app.sh' <<<"$run_plan" || fail "make run does not use the development launcher"

install_plan="$(make -C "$ROOT_DIR" -n install)"
grep -Fq 'Ask Key Dev.app' <<<"$install_plan" || fail "make install has no isolated development destination"
grep -Fq 'AskKeyDevLauncher' <<<"$install_plan" || fail "make install has no normal-entry launcher"
grep -Fq 'PlistBuddy' <<<"$install_plan" || fail "make install does not set CFBundleExecutable"
grep -Fq 'codesign --force --deep --sign -' <<<"$install_plan" || fail "make install does not re-sign the local Dev.app"
if grep -Fq '/Applications/Ask Key.app' <<<"$install_plan"; then
  fail "make install references the production application path"
fi

# This is a no-side-effect check of the default expansion. Launch tests below
# always use a task-scoped explicit directory and never modify HOME.
default_run_directory="$("$LAUNCHER" --print-default-run-directory)"
[[ "$default_run_directory" == /* ]] || fail "default run directory is not absolute"
[[ "$default_run_directory" == */Library/Application\ Support/AskKey\ Dev ]] \
  || fail "default run directory does not use the stable development suffix"

dev_test_root="$(/bin/realpath "$(mktemp -d "${TMPDIR:-/tmp}/askkey-dev-launch.XXXXXX")")"
trap 'rm -rf "$dev_test_root"' EXIT
dev_test_app="$dev_test_root/bundle with spaces/Ask Key Dev.app"
dev_test_runtime="$dev_test_root/run directory with spaces"
mkdir -p "$dev_test_app/Contents/MacOS" "$dev_test_app/Contents/Resources" "$dev_test_runtime"
chmod 700 "$dev_test_root" "$dev_test_app" "$dev_test_app/Contents" \
  "$dev_test_app/Contents/MacOS" "$dev_test_app/Contents/Resources" "$dev_test_runtime"
expected_runtime="$(/bin/realpath "$dev_test_runtime")"

cat > "$dev_test_app/Contents/MacOS/AskKeyApp" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${ASKKEY_DEBUG_RUN_DIRECTORY-}" > "${ASKKEY_CAPTURE:?}"
printf '%s\n' "$0" >> "${ASKKEY_CAPTURE:?}"
STUB
chmod 700 "$dev_test_app/Contents/MacOS/AskKeyApp"
expected_app="$(CDPATH= cd -- "$dev_test_app" && pwd -P)/Contents/MacOS/AskKeyApp"

for index in 1 2; do
  capture="$dev_test_root/capture-$index"
  ASKKEY_DEBUG_RUN_DIRECTORY="$dev_test_runtime" ASKKEY_CAPTURE="$capture" \
    "$LAUNCHER" "$dev_test_app"
  [[ "$(sed -n '1p' "$capture")" == "$expected_runtime" ]] \
    || fail "launcher did not pass the normalized explicit run directory"
  [[ "$(sed -n '2p' "$capture")" == "$expected_app" ]] \
    || fail "launcher did not preserve an app path containing spaces"
done
cmp "$dev_test_root/capture-1" "$dev_test_root/capture-2" \
  || fail "explicit run directory was not persistent across launches"
[[ "$(stat -f '%Lp' "$expected_runtime")" == 700 ]] \
  || fail "explicit run directory is not mode 0700"

cp "$LAUNCHER" "$dev_test_app/Contents/MacOS/AskKeyDevLauncher"
chmod 700 "$dev_test_app/Contents/MacOS/AskKeyDevLauncher"
cat > "$dev_test_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>AskKeyDevLauncher</string>
  <key>CFBundleIdentifier</key><string>com.sudohg.askkey.app.dev</string>
  <key>AskKeyRequiresDebugRunDirectory</key><true/>
</dict>
</plist>
PLIST
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable AskKeyDevLauncher' "$dev_test_app/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$dev_test_app/Contents/Info.plist")" == AskKeyDevLauncher ]] \
  || fail "fixture Info.plist does not name the development launcher"

dev_test_open="$dev_test_root/open-stub"
cat > "$dev_test_open" <<'OPEN_STUB'
#!/usr/bin/env bash
set -euo pipefail
app_path="$1"
entry="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_path/Contents/Info.plist")"
exec "$app_path/Contents/MacOS/$entry"
OPEN_STUB
chmod 700 "$dev_test_open"
normal_entry_capture="$dev_test_root/normal-entry-capture"
ASKKEY_DEBUG_RUN_DIRECTORY="$dev_test_runtime" ASKKEY_CAPTURE="$normal_entry_capture" \
  "$dev_test_open" "$dev_test_app"
[[ "$(sed -n '1p' "$normal_entry_capture")" == "$expected_runtime" ]] \
  || fail "Info.plist normal entry did not start the isolated launcher"

override_runtime="$dev_test_root/override run directory"
mkdir -p "$override_runtime"
chmod 700 "$override_runtime"
override_capture="$dev_test_root/override-capture"
ASKKEY_DEBUG_RUN_DIRECTORY="$override_runtime" ASKKEY_CAPTURE="$override_capture" \
  "$LAUNCHER" "$dev_test_app"
[[ "$(sed -n '1p' "$override_capture")" == "$(/bin/realpath "$override_runtime")" ]] \
  || fail "explicit override directory was not normalized and passed"

duplicate_runtime="$dev_test_root//normalized run directory"
mkdir -p "$duplicate_runtime"
chmod 700 "$duplicate_runtime"
duplicate_capture="$dev_test_root/duplicate-capture"
ASKKEY_DEBUG_RUN_DIRECTORY="$duplicate_runtime" ASKKEY_CAPTURE="$duplicate_capture" \
  "$LAUNCHER" "$dev_test_app"
[[ "$(sed -n '1p' "$duplicate_capture")" == "$(/bin/realpath "$duplicate_runtime")" ]] \
  || fail "duplicate-slash run directory was not normalized before launch"

protected_support_path="${default_run_directory%/AskKey Dev}"
protected_data_path="$protected_support_path/AskKey"
rejection_log="$dev_test_root/production-rejection.log"
if ASKKEY_DEBUG_RUN_DIRECTORY="$protected_data_path" ASKKEY_CAPTURE="$dev_test_root/should-not-run" \
  "$LAUNCHER" "$dev_test_app" > /dev/null 2> "$rejection_log"; then
  fail "launcher accepted the production data directory"
fi
grep -Fq 'overlaps protected data' "$rejection_log" \
  || fail "production-path rejection was not explicit"
[[ ! -e "$dev_test_root/should-not-run" ]] \
  || fail "launcher ran the app after rejecting the production directory"

ancestor_rejection_log="$dev_test_root/ancestor-rejection.log"
if ASKKEY_DEBUG_RUN_DIRECTORY="$protected_support_path" ASKKEY_CAPTURE="$dev_test_root/should-not-run-ancestor" \
  "$LAUNCHER" "$dev_test_app" > /dev/null 2> "$ancestor_rejection_log"; then
  fail "launcher accepted an ancestor of the production data directory"
fi
grep -Fq 'overlaps protected data' "$ancestor_rejection_log" \
  || fail "production-ancestor rejection was not explicit"
[[ ! -e "$dev_test_root/should-not-run-ancestor" ]] \
  || fail "launcher ran the app after rejecting a production ancestor"

double_slash_path="$protected_support_path//AskKey"
if ASKKEY_DEBUG_RUN_DIRECTORY="$double_slash_path" ASKKEY_CAPTURE="$dev_test_root/should-not-run-twice" \
  "$LAUNCHER" "$dev_test_app" > /dev/null 2> "$dev_test_root/double-slash.log"; then
  fail "launcher accepted a duplicate-slash production alias"
fi
[[ ! -e "$dev_test_root/should-not-run-twice" ]] \
  || fail "launcher ran the app after rejecting a duplicate-slash alias"

if ASKKEY_DEBUG_RUN_DIRECTORY="//" ASKKEY_CAPTURE="$dev_test_root/should-not-run-root" \
  "$LAUNCHER" "$dev_test_app" > /dev/null 2> "$dev_test_root/root.log"; then
  fail "launcher accepted a duplicate-slash filesystem root"
fi
[[ ! -e "$dev_test_root/should-not-run-root" ]] \
  || fail "launcher ran the app after rejecting the filesystem root"

symlink_parent="$dev_test_root/protected parent alias"
ln -s "$protected_support_path" "$symlink_parent"
if ASKKEY_DEBUG_RUN_DIRECTORY="$symlink_parent/AskKey" ASKKEY_CAPTURE="$dev_test_root/should-not-run-symlink" \
  "$LAUNCHER" "$dev_test_app" > /dev/null 2> "$dev_test_root/symlink.log"; then
  fail "launcher accepted a symlink-parent production alias"
fi
[[ ! -e "$dev_test_root/should-not-run-symlink" ]] \
  || fail "launcher ran the app after rejecting a symlink-parent alias"

echo "PASS: dry-run Makefile routing, syntax, explicit normalized 0700 run directory, Info.plist normal entry, spaces-safe paths, stable default print, and protected-path aliases"
