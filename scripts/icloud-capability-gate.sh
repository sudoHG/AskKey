#!/usr/bin/env bash
# Fail-closed iCloud capability checks. Never invents a production container ID.
set -euo pipefail

usage() {
  echo "Usage: $0 identifier <iCloud.container.id>" >&2
  echo "       $0 app <App.app> <iCloud.container.id>" >&2
  echo "       $0 entitlements <file.plist> <iCloud.container.id>" >&2
  exit 2
}

validate_identifier() {
  local identifier="${1:-}"
  [[ "$identifier" =~ ^iCloud\.[A-Za-z0-9][A-Za-z0-9.-]+$ ]] || {
    echo "AskKey iCloud container identifier is missing or malformed." >&2
    exit 1
  }
  case "$(printf '%s' "$identifier" | tr '[:upper:]' '[:lower:]')" in
    *lokalite*)
      echo "AskKey must not reuse a Lokalite iCloud container." >&2
      exit 1
      ;;
  esac
}

require_exact_string_array() {
  local file="${1:?}"
  local key="${2:?}"
  local expected="${3:?}"
  local first second
  first="$(/usr/libexec/PlistBuddy -c "Print :${key}:0" "$file" 2>/dev/null || true)"
  second="$(/usr/libexec/PlistBuddy -c "Print :${key}:1" "$file" 2>/dev/null || true)"
  if [ "$first" != "$expected" ] || [ -n "$second" ]; then
    echo "Signed entitlements must contain exactly ${expected} under ${key}." >&2
    exit 1
  fi
}

validate_signed_entitlements() {
  local raw="${1:?}"
  local identifier="${2:?}"
  local xml
  xml="$(mktemp)"
  if ! plutil -convert xml1 -o "$xml" "$raw" 2>/dev/null; then
    echo "Signed entitlements are not a readable plist." >&2
    exit 1
  fi
  require_exact_string_array "$xml" "com.apple.developer.icloud-container-identifiers" "$identifier"
  require_exact_string_array "$xml" "com.apple.developer.ubiquity-container-identifiers" "$identifier"
  require_exact_string_array "$xml" "com.apple.developer.icloud-services" "CloudDocuments"
  rm -f "$xml"
}

write_release_entitlements() {
  local destination="${1:?}"
  local identifier="${2:?}"
  validate_identifier "$identifier"
  cat > "$destination" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.developer.icloud-container-identifiers</key>
  <array>
    <string>${identifier}</string>
  </array>
  <key>com.apple.developer.icloud-services</key>
  <array>
    <string>CloudDocuments</string>
  </array>
  <key>com.apple.developer.ubiquity-container-identifiers</key>
  <array>
    <string>${identifier}</string>
  </array>
</dict>
</plist>
PLIST
}

command="${1:-}"
case "$command" in
  identifier)
    validate_identifier "${2:-}"
    ;;
  app)
    app="${2:-}"
    identifier="${3:-}"
    validate_identifier "$identifier"
    test -d "$app"
    actual="$(/usr/libexec/PlistBuddy -c 'Print :AskKeyICloudContainerIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)"
    if [ "$actual" != "$identifier" ]; then
      echo "Release Info.plist is missing AskKeyICloudContainerIdentifier=$identifier." >&2
      exit 1
    fi
    entitlements="$(mktemp)"
    trap 'rm -f "$entitlements"' EXIT
    if ! codesign -d --entitlements :- "$app" > "$entitlements" 2>/dev/null; then
      echo "Release signing metadata has no readable entitlements." >&2
      exit 1
    fi
    validate_signed_entitlements "$entitlements" "$identifier"
    echo "iCloud capability present in Info.plist and signed entitlements. Fixture or unofficial signing cannot prove production readiness."
    ;;
  entitlements)
    write_release_entitlements "${2:-}" "${3:-}"
    ;;
  *)
    usage
    ;;
esac
