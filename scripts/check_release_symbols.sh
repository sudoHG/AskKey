#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT_DIR"

swift build -c release --product AskKeyApp --jobs 1
BIN_DIR="$(swift build -c release --show-bin-path)"
[[ -n "$BIN_DIR" ]] || { echo "FAIL: SwiftPM returned an empty release bin path" >&2; exit 1; }

APP_BINARY="$BIN_DIR/AskKeyApp"
[[ -s "$APP_BINARY" ]] || { echo "FAIL: release app binary is missing or empty: $APP_BINARY" >&2; exit 1; }

inspection_dir="$(mktemp -d "${TMPDIR:-/tmp}/askkey-release-symbols.XXXXXX")"
trap 'rm -rf "$inspection_dir"' EXIT

nm "$APP_BINARY" > "$inspection_dir/nm.txt"
strings "$APP_BINARY" > "$inspection_dir/strings.txt"

for forbidden in \
  AskKeyTestSupport \
  AskKeyE2E \
  E2EAppRuntime \
  E2EBrokerScenario \
  VaultE2EFixture \
  E2EProcessFixture \
  DebugClientE2E \
  AskKeyE2ETesting \
  ASKKEY_CLIENT_E2E \
  ASKKEY_E2E_ROOT \
  ASKKEY_E2E_SCENARIO \
  ASKKEY_E2E_ \
  synthetic-e2e-value \
  'E2E Broker Credential' \
  configureE2EAuthentication
do
  if grep -Fq -- "$forbidden" "$inspection_dir/nm.txt" \
    || grep -Fq -- "$forbidden" "$inspection_dir/strings.txt"; then
    echo "FAIL: release app binary contains forbidden E2E symbol or string: $forbidden" >&2
    exit 1
  fi
done

echo "PASS: release app binary contains no forbidden E2E symbols or strings"
