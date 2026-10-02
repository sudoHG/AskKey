#!/bin/sh
set -eu

available_kib=$(df -Pk /System/Volumes/Data | awk 'NR == 2 { print $4 }')
minimum_kib=$((80 * 1024 * 1024))
if [ "$available_kib" -lt "$minimum_kib" ]; then
  echo "Need at least 80 GiB free on /System/Volumes/Data" >&2
  exit 1
fi

swift test --filter CodexUserMCPAdapterTests
swift test --filter CursorUserMCPAdapterTests
swift test --filter GrokCLIAdapterTests
swift test --filter AgentClientConnectorTests
scripts/test-debug-multica-connection.sh
