#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/askkey-cancellation-probe.XXXXXX")"
trap 'rm -rf "$probe_dir"' EXIT
for optimization in -Onone -O; do
  swiftc "$optimization" -swift-version 5 -parse-as-library \
    Sources/AskKeySystem/RestrictedProcessCancellation.swift \
    Tests/RuntimeProbes/RestrictedProcessCancellationProbe.swift \
    -o "$probe_dir/cancellation-probe"
  "$probe_dir/cancellation-probe"
done
