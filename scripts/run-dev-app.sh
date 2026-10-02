#!/usr/bin/env bash
# Launch a Debug AskKey app with a persistent, isolated runtime directory.
#
# The app reads ASKKEY_DEBUG_RUN_DIRECTORY at process startup. LaunchServices
# does not provide a reliable way to attach that environment to `open`, so the
# launcher executes the app binary directly and preserves the app-bundle path.
# With no argument this script resolves .build/AskKeyApp.app next to itself;
# when copied under Contents/MacOS or Contents/Resources it resolves the
# containing app bundle.
set -euo pipefail

die() {
  echo "run-dev-app.sh: $*" >&2
  exit 2
}

if [[ "$#" -gt 1 ]]; then
  die "usage: $0 [AskKeyApp.app]"
fi

if [[ "$#" == 1 && "$1" == "--print-default-run-directory" ]]; then
  : "${HOME:?HOME must be set to print the development run directory}"
  [[ "$HOME" == /* ]] || die "HOME must be an absolute path"
  printf '%s/Library/Application Support/AskKey Dev\n' "$HOME"
  exit 0
fi

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT_NAME="$(basename -- "$SCRIPT_DIR")"
PARENT_NAME="$(basename -- "$(dirname -- "$SCRIPT_DIR")")"

if [[ "$#" == 1 ]]; then
  APP_PATH="$1"
elif [[ "$PARENT_NAME" == Contents && ( "$SCRIPT_NAME" == Resources || "$SCRIPT_NAME" == MacOS ) ]]; then
  APP_PATH="$SCRIPT_DIR/../.."
else
  APP_PATH="$SCRIPT_DIR/../.build/AskKeyApp.app"
fi

if [[ "$APP_PATH" != /* ]]; then
  APP_PATH="$(CDPATH= cd -- "$(dirname -- "$APP_PATH")" && printf '%s/%s' "$PWD" "$(basename -- "$APP_PATH")")"
fi
APP_PATH="$(CDPATH= cd -- "$APP_PATH" && pwd -P)"

[[ "$APP_PATH" != "/Applications/Ask Key.app" && "$APP_PATH" != "/Applications/AskKey.app" ]] \
  || die "the production application path cannot be launched by the development launcher"

APP_EXECUTABLE="$APP_PATH/Contents/MacOS/AskKeyApp"
[[ -x "$APP_EXECUTABLE" ]] || die "missing executable: $APP_EXECUTABLE"

: "${HOME:?HOME must be set to launch the development app}"
[[ "$HOME" == /* ]] || die "HOME must be an absolute path"

DEFAULT_RUN_DIRECTORY="$HOME/Library/Application Support/AskKey Dev"
RUN_DIRECTORY="${ASKKEY_DEBUG_RUN_DIRECTORY:-$DEFAULT_RUN_DIRECTORY}"
[[ "$RUN_DIRECTORY" == /* && "$RUN_DIRECTORY" != "/" ]] \
  || die "ASKKEY_DEBUG_RUN_DIRECTORY must be a non-root absolute path"

IFS='/' read -r -a RUN_COMPONENTS <<< "$RUN_DIRECTORY"
for component in "${RUN_COMPONENTS[@]}"; do
  [[ "$component" != "." && "$component" != ".." ]] \
    || die "ASKKEY_DEBUG_RUN_DIRECTORY cannot contain . or .. components"
done

# Resolve the existing part before creating or chmod'ing anything. This makes
# the protected-path check immune to duplicate slashes and symlink aliases.
# Pass the physical path to DebugRunDirectory, which verifies every component
# before the app opens its isolated store.
canonicalize_for_check() {
  local candidate="$1"
  local -a missing_components=()
  local parent component resolved

  while [[ ! -e "$candidate" ]]; do
    [[ ! -L "$candidate" ]] || return 1
    [[ "$candidate" != "/" ]] || return 1
    component="$(basename -- "$candidate")"
    if ((${#missing_components[@]} == 0)); then
      missing_components=("$component")
    else
      missing_components=("$component" "${missing_components[@]}")
    fi
    parent="$(dirname -- "$candidate")"
    [[ "$parent" != "$candidate" ]] || return 1
    candidate="$parent"
  done
  [[ -d "$candidate" && ! -L "$candidate" ]] || return 1
  resolved="$(/bin/realpath "$candidate")" || return 1
  if ((${#missing_components[@]} > 0)); then
    for component in "${missing_components[@]}"; do
      resolved="$resolved/$component"
    done
  fi
  printf '%s\n' "$resolved"
}

CANONICAL_RUN_DIRECTORY="$(canonicalize_for_check "$RUN_DIRECTORY")" \
  || die "ASKKEY_DEBUG_RUN_DIRECTORY has an invalid parent or symlink: $RUN_DIRECTORY"
[[ "$CANONICAL_RUN_DIRECTORY" != "/" ]] \
  || die "ASKKEY_DEBUG_RUN_DIRECTORY cannot resolve to the filesystem root"

PROTECTED_SUPPORT="$HOME/Library/Application Support"
PROTECTED_PATHS=(
  "$PROTECTED_SUPPORT/AskKey"
  "$PROTECTED_SUPPORT/com.sudohg.askkey.lifecycle"
)
path_overlaps() {
  local first="$1"
  local second="$2"
  [[ "$first" == "$second" || "$first" == "$second/"* \
     || "$second" == "$first/"* ]]
}
for protected in "${PROTECTED_PATHS[@]}"; do
  canonical_protected="$(canonicalize_for_check "$protected")" \
    || die "cannot resolve protected data path: $protected"
  if path_overlaps "$CANONICAL_RUN_DIRECTORY" "$canonical_protected"; then
    die "ASKKEY_DEBUG_RUN_DIRECTORY overlaps protected data: $canonical_protected"
  fi
done

RUN_DIRECTORY="$CANONICAL_RUN_DIRECTORY"
if [[ ! -e "$RUN_DIRECTORY" ]]; then
  (umask 077 && mkdir -p -- "$RUN_DIRECTORY")
fi
[[ -d "$RUN_DIRECTORY" && ! -L "$RUN_DIRECTORY" ]] \
  || die "ASKKEY_DEBUG_RUN_DIRECTORY must be a real directory: $RUN_DIRECTORY"
chmod 700 "$RUN_DIRECTORY"

export ASKKEY_DEBUG_RUN_DIRECTORY="$RUN_DIRECTORY"
exec "$APP_EXECUTABLE"
