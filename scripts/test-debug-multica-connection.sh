#!/bin/sh
set -eu

available_kib=$(df -Pk /System/Volumes/Data | awk 'NR == 2 { print $4 }')
minimum_kib=$((80 * 1024 * 1024))
if [ "$available_kib" -lt "$minimum_kib" ]; then
  echo "Need at least 80 GiB free on /System/Volumes/Data" >&2
  exit 1
fi

root=$(mktemp -d "${TMPDIR:-/tmp}/askkey-multica-e2e.XXXXXX")
trap 'status=$?; if [ "$status" -ne 0 ]; then find "$root" -type f \( -name "result.json" -o -name "calls.log" -o -name "update.json" -o -name "mcp.jsonl" \) -print -exec sed -n "1,120p" {} \;; fi; rm -rf "$root"' EXIT HUP INT TERM
ASKKEY_DERIVED_DATA="$root/derived-data" scripts/build-app.sh Debug >/dev/null
app="$(pwd)/.build/AskKeyApp.app/Contents/MacOS/AskKeyApp"
helper="$(pwd)/.build/AskKeyApp.app/Contents/Helpers/askkey"

run_case() {
  mode=$1
  home="$root/$mode"
  state="$home/state"
  log="$home/calls.log"
  config="$home/update.json"
  evidence="$home/mcp.jsonl"
  result="$home/result.json"
  stub="$home/.local/bin/multica"
  server_name="askkey-debug-$mode"
  mkdir -p "$home/.local/bin" "$state"
  chmod 700 "$home" "$home/.local" "$home/.local/bin" "$state"
  printf '%s\n' '/wrong/helper wrong-mode' > "$state/identity-before"

  sed \
    -e "s|@STATE@|$state|g" \
    -e "s|@LOG@|$log|g" \
    -e "s|@CONFIG@|$config|g" \
    -e "s|@EVIDENCE@|$evidence|g" \
    -e "s|@HELPER@|$helper|g" \
    -e "s|@MODE@|$mode|g" \
    -e "s|@SERVER_NAME@|$server_name|g" \
    scripts/debug-multica-stub.sh > "$stub"
  chmod 700 "$stub"

  ASKKEY_CLIENT_E2E=multica \
    ASKKEY_CLIENT_E2E_HOME="$home" \
    ASKKEY_CLIENT_E2E_OUTPUT="$result" \
    ASKKEY_MULTICA_E2E_SERVER_NAME="$server_name" \
    "$app"

  [ "$(stat -f %Lp "$result")" = "600" ]
  [ "$(plutil -extract command raw -o - "$config")" = "$helper" ]
  [ "$(plutil -extract args.0 raw -o - "$config")" = "mcp" ]
  ! grep -q 'agent mcp add agent-existing' "$log"
  grep -q 'workspace mcp update server-1 workspace-1 --server-config-stdin' "$log"
  grep -q '^/wrong/helper wrong-mode$' "$state/identity-before"
  [ -f "$state/identity-updated" ]

  if [ "$mode" = "success" ]; then
    [ "$(plutil -extract connected raw -o - "$result")" = "true" ]
    [ -f "$state/new-assigned" ]
    grep -q '"id":"initialize"' "$evidence"
    grep -q '"id":"tools"' "$evidence"
    grep -q 'connection_status' "$evidence"
    grep -q 'connected' "$evidence"
  else
    [ "$(plutil -extract connected raw -o - "$result")" = "false" ]
    [ ! -f "$state/new-assigned" ]
    grep -q 'agent mcp remove agent-new server-1' "$log"
  fi
}

run_case success
run_case failure
echo "Multica Debug isolation passed: identity update, MCP/Broker check, and assignment rollback"

if [ "${ASKKEY_MULTICA_LIVE_E2E:-0}" = "1" ]; then
  real_cli=$(command -v multica)
  workspace_id=$($real_cli workspace list --output json | jq -er 'if length == 1 then .[0].id else error("select one Multica workspace") end')
  live_home="$root/live"
  live_result="$live_home/result.json"
  live_name="askkey-debug-$(uuidgen | tr '[:upper:]' '[:lower:]')"
  mkdir -p "$live_home/.local/bin"
  chmod 700 "$live_home" "$live_home/.local" "$live_home/.local/bin"
  ln -s "$real_cli" "$live_home/.local/bin/multica"
  ASKKEY_CLIENT_E2E=multica \
    ASKKEY_CLIENT_E2E_HOME="$live_home" \
    ASKKEY_CLIENT_E2E_OUTPUT="$live_result" \
    ASKKEY_MULTICA_E2E_SERVER_NAME="$live_name" \
    "$app"
  [ "$(plutil -extract connected raw -o - "$live_result")" = "true" ]
  ! $real_cli workspace mcp list "$workspace_id" --output json \
    | jq -e --arg name "$live_name" '.[] | select(.name == $name)' >/dev/null
  echo "Multica live E2E passed: temporary server reached a real Agent task and was removed"
fi
