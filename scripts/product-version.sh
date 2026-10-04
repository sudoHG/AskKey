#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
[[ "$#" -le 1 ]] || { echo "Usage: $0 [path]" >&2; exit 1; }
VERSION_FILE="${1:-$ROOT_DIR/Sources/AskKeyBroker/AskKeyVersion.swift}"
[[ -f "$VERSION_FILE" ]] || { echo "Product version file not found: $VERSION_FILE" >&2; exit 1; }

VERSION="$(sed -nE 's/^[[:space:]]*public[[:space:]]+static[[:space:]]+let[[:space:]]+current[[:space:]]*=[[:space:]]*"([^"]*)"[[:space:]]*$/\1/p' "$VERSION_FILE")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "Product version must match X.Y.Z with numeric components" >&2
  exit 1
}
printf '%s\n' "$VERSION"
