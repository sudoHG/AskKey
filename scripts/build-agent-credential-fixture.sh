#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
AVAILABLE_KIB="$(df -k /System/Volumes/Data | awk 'NR==2 {print $4}')"
[[ "${AVAILABLE_KIB:-0}" -ge 83886080 ]] || { echo 'Fixture build requires at least 80 GiB free.' >&2; exit 1; }
swift build --product askkey
TASK_BIN_PATH="$(swift build --show-bin-path)"
TASK_ARCH="$(uname -m)"
swiftc -parse-as-library -swift-version 5 -target "$TASK_ARCH-apple-macosx14.0" \
  -I "$TASK_BIN_PATH/Modules" \
  -Xcc "-fmodule-map-file=$TASK_BIN_PATH/AskKeyBrokerC.build/module.modulemap" \
  -Xcc -I -Xcc Sources/AskKeyBrokerC/include \
  Tests/UI/Fixtures/CredentialDiscoveryBroker.swift \
  "$TASK_BIN_PATH"/AskKeyBroker.build/*.swift.o \
  "$TASK_BIN_PATH/AskKeyBrokerC.build/AskKeyBrokerC.c.o" \
  -o .build/credential-discovery-broker
echo 'Fixture: .build/credential-discovery-broker'
