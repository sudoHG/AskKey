#!/usr/bin/env bash
# Compile the approved Icon Composer document before signing the app bundle.
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
APP="${1:?usage: compile-app-icon.sh path/to/App.app}"
[[ "$APP" == /* ]] || APP="$PWD/$APP"
test -f "$APP/Contents/Info.plist"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/askkey-icon.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/output"
cp -R "$ROOT/assets/AppIcon.icon" "$WORK/AppIcon.icon"
xcrun actool "$WORK/AppIcon.icon" --compile "$WORK/output" \
  --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon \
  --output-partial-info-plist "$WORK/icon-info.plist"
test -f "$WORK/output/Assets.car"
test -f "$WORK/output/AppIcon.icns"
mkdir -p "$APP/Contents/Resources"
cp "$WORK/output/Assets.car" "$WORK/output/AppIcon.icns" "$APP/Contents/Resources/"
python3 - "$APP/Contents/Info.plist" "$WORK/icon-info.plist" <<'PY'
import plistlib
import sys
from pathlib import Path

destination, generated = map(Path, sys.argv[1:])
info = plistlib.loads(destination.read_bytes())
info.update(plistlib.loads(generated.read_bytes()))
destination.write_bytes(plistlib.dumps(info, sort_keys=False))
PY
