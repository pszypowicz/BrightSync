#!/usr/bin/env bash
# Installs BrightSync.app and starts it.
set -euo pipefail

usage() {
  cat <<'EOF'
Install BrightSync.app and start it.

Builds the app (unless --skip-build), quits any running copy, replaces it,
and launches the new one in the background. The app registers launch at
login itself on its first run; manage it later in Settings.

Usage: scripts/install-app.sh [--app-dir <dir>] [--sign <identity>] [--skip-build] [-h|--help]

Options:
  --app-dir <dir>    Install destination (default: /Applications)
  --sign <identity>  Code-signing identity passed to build-app.sh
  --skip-build       Use the existing dist/BrightSync.app instead of rebuilding
  -h, --help         Show this help.

Example:
  scripts/install-app.sh
EOF
}

app_dir="/Applications"
skip_build=0
sign=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-dir)
      [[ $# -ge 2 ]] || { echo "error: --app-dir needs a value" >&2; exit 2; }
      app_dir="$2"; shift 2 ;;
    --sign)
      [[ $# -ge 2 ]] || { echo "error: --sign needs a value" >&2; exit 2; }
      sign="$2"; shift 2 ;;
    --skip-build) skip_build=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"

if [[ $skip_build -eq 0 ]]; then
  build_args=(--output dist)
  [[ -n "$sign" ]] && build_args+=(--sign "$sign")
  scripts/build-app.sh "${build_args[@]}"
elif [[ ! -d dist/BrightSync.app ]]; then
  echo "error: dist/BrightSync.app not found; run without --skip-build first" >&2
  exit 1
fi

app="$app_dir/BrightSync.app"
pkill -x BrightSync 2> /dev/null || true
rm -rf "$app"
cp -R dist/BrightSync.app "$app"
open -g "$app"

echo "installed $app"
echo "logs: log stream --predicate 'subsystem == \"cz.szypowi.brightsync\"'"
