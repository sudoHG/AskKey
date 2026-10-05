#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd -P)"
MODE="${1:-required}"
case "$MODE" in
  required) TEST_SELECTION=(-skip-testing:AskKeyE2ETests/ScreenshotE2ETests) ;;
  screenshots) TEST_SELECTION=(-only-testing:AskKeyE2ETests/ScreenshotE2ETests) ;;
  *) echo 'Usage: run-e2e.sh [required|screenshots]' >&2; exit 2 ;;
esac
if [[ "$MODE" == required ]]; then python3 scripts/e2e-gate.py invalidate; fi
AVAILABLE_KIB="$(df -k /System/Volumes/Data | awk 'NR==2 {print $4}')"
[[ "${AVAILABLE_KIB:-0}" -ge 83886080 ]] || { echo 'E2E requires at least 80 GiB free.' >&2; exit 1; }
command -v xcodegen >/dev/null || { echo 'Install xcodegen before running UI tests.' >&2; exit 1; }
OUTPUT="$ROOT/Tests/UI/output/$(date +%Y%m%d-%H%M%S)-$$-$MODE"
mkdir -p "$OUTPUT"
chmod 700 "$OUTPUT"
RUN_ROOT="$(mktemp -d /private/tmp/ak-e2e-XXXXXXXX)"
chmod 700 "$RUN_ROOT"
printf '%s\n' "$RUN_ROOT" > "$OUTPUT/run-root.txt"
# Ad-hoc signatures have no stable signer identity. A fresh runner identifier
# avoids asking macOS to grant a new binary access to an older test container.
RUNNER_BUNDLE_ID="com.sudohg.askkey.e2e.tests.run-$(uuidgen | tr '[:upper:]' '[:lower:]')"
printf 'test bundle: %s\nrunner: %s.xctrunner\n' "$RUNNER_BUNDLE_ID" "$RUNNER_BUNDLE_ID" > "$OUTPUT/runner-identifiers.txt"
cleanup() {
  local original_exit=$?
  trap - EXIT INT TERM
  local cleanup_exit=0
  python3 - "$RUN_ROOT" "$OUTPUT" "$ROOT/.build/AskKeyApp.app" <<'PY' || cleanup_exit=$?
import hashlib, json, os, pathlib, shutil, signal, stat, subprocess, sys, time
root, output, app = map(pathlib.Path, sys.argv[1:])
info = root.lstat()
if (root.parent != pathlib.Path('/private/tmp') or not root.name.startswith('ak-e2e-')
        or root.resolve() != root or not stat.S_ISDIR(info.st_mode)
        or stat.S_IMODE(info.st_mode) != 0o700 or info.st_uid != os.geteuid()):
    raise SystemExit('Refusing cleanup: runtime root failed isolation validation')
evidence = output / 'isolation-diagnostics'
evidence.mkdir(mode=0o700)
records, cases = [], []
for case in root.iterdir():
    if not case.is_symlink() and case.is_file() and case.suffix == '.json' and case.stat().st_size <= 1048576:
        shutil.copyfile(case, evidence / case.name)
    if case.is_symlink() or not case.is_dir():
        continue
    cases.append(case)
    destination = evidence / case.name
    destination.mkdir(mode=0o700)
    for source in case.iterdir():
        if (not source.is_symlink() and source.is_file() and source.stat().st_size <= 1048576
                and source.suffix in {'.json', '.txt', '.log', '.pid', '.ndjson'}):
            shutil.copyfile(source, destination / source.name)
    manifest = case / 'process-identities.json'
    if manifest.exists():
        records.extend(json.loads(manifest.read_text()))

def identity(pid):
    result = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'uid=', '-o', 'lstart=', '-o', 'command='],
                            capture_output=True, text=True, env={'PATH': '/usr/bin:/bin', 'LANG': 'C'})
    return result.stdout.strip() if result.returncode == 0 else None

def owned(record):
    pid, role = record['pid'], record['role']
    if not isinstance(pid, int) or pid <= 1:
        return False
    current = identity(pid)
    if not current or current != record['identity'] or current.split()[0] != str(os.geteuid()):
        return False
    required = {'app': str(app / 'Contents/MacOS/AskKeyApp'),
                'helper': str(app / 'Contents/Helpers/askkey'), 'target': str(root),
                'child': '/bin/sleep 30'}.get(role)
    if role in {'target', 'child'}:
        group = record.get('processGroup', 0)
        try:
            if group <= 1 or os.getpgid(pid) != group:
                return False
        except ProcessLookupError:
            return False
    return required is not None and required in current

def stop(record):
    if not owned(record):
        return
    pid = record['pid']
    group = record.get('processGroup') if record['role'] in {'target', 'child'} else None
    for sig in [signal.SIGTERM, signal.SIGKILL]:
        if not owned(record):
            break
        try:
            os.kill(-group if group else pid, sig)
        except ProcessLookupError:
            break
        deadline = time.monotonic() + 2
        while owned(record) and time.monotonic() < deadline:
            time.sleep(0.05)

# Helpers close their real broker connection first, allowing production runtime
# cancellation to reap target groups while the App is still alive.
for role in ['helper', 'target', 'child', 'app']:
    for record in records:
        if record.get('role') == role:
            stop(record)
survivors = [r for r in records if owned(r)]
remaining_groups = []
for group in {r.get('processGroup', 0) for r in records if r.get('role') in {'target', 'child'}}:
    if group > 1:
        try:
            os.kill(-group, 0)
            remaining_groups.append(group)
        except ProcessLookupError:
            pass
(evidence / 'cleanup.json').write_text(json.dumps({'survivors': survivors, 'remainingGroups': remaining_groups}, indent=2))
if survivors or remaining_groups:
    raise SystemExit('Owned processes survived cleanup; preserving private runtime root')
for case in cases:
    suite = 'com.sudohg.askkey.debug.' + hashlib.sha256(str(case).encode()).hexdigest()
    subprocess.run(['/usr/bin/defaults', 'delete', suite], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
shutil.rmtree(root)
PY
  if [[ "$original_exit" == 0 && "$cleanup_exit" != 0 ]]; then original_exit=$cleanup_exit; fi
  if [[ "$original_exit" != 0 && "$MODE" == required ]]; then python3 scripts/e2e-gate.py invalidate; fi
  exit "$original_exit"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export ASKKEY_DERIVED_DATA="$ROOT/.derivedData/e2e-app"
echo "E2E evidence: $OUTPUT"
python3 scripts/e2e-gate.py fingerprint > "$OUTPUT/source-fingerprint.txt"
bash scripts/build-app.sh E2E > "$OUTPUT/app-build.log" 2>&1
xcodegen generate --spec Tests/UI/project.yml > "$OUTPUT/project-generation.log"
test_exit=0
xcodebuild test -project Tests/UI/AskKeyE2E.xcodeproj -scheme AskKeyE2E \
  "${TEST_SELECTION[@]}" \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -derivedDataPath "$ROOT/.derivedData/e2e-runner" \
  -resultBundlePath "$OUTPUT/basic-flows.xcresult" \
  CODE_SIGNING_ALLOWED=YES "CODE_SIGN_IDENTITY=${ASKKEY_E2E_SIGNING_IDENTITY:--}" CODE_SIGN_STYLE=Manual \
  "ASKKEY_E2E_APP=$ROOT/.build/AskKeyApp.app" \
  "ASKKEY_E2E_ROOT=$RUN_ROOT" \
  "ASKKEY_E2E_RUNNER_BUNDLE_ID=$RUNNER_BUNDLE_ID" \
  > "$OUTPUT/ui-tests.log" 2>&1 || test_exit=$?
if [[ -d "$OUTPUT/basic-flows.xcresult" ]]; then
  xcrun xcresulttool get test-results summary --path "$OUTPUT/basic-flows.xcresult" \
    > "$OUTPUT/summary.json"
  xcrun xcresulttool get test-results tests --path "$OUTPUT/basic-flows.xcresult" \
    > "$OUTPUT/tests.json"
fi
if [[ "$MODE" == screenshots ]]; then
  python3 scripts/e2e-report.py --export-screenshots "$OUTPUT/basic-flows.xcresult" "$ROOT/Tests/UI/output/screenshots"
  exit "$test_exit"
fi
if [[ "$test_exit" != 0 ]]; then
  echo "E2E FAILED (exit $test_exit). See $OUTPUT/ui-tests.log" >&2
  exit "$test_exit"
fi
python3 scripts/e2e-report.py "$OUTPUT"
