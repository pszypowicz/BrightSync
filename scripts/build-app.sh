#!/usr/bin/env bash
# Assembles BrightSync.app from the SwiftPM release build: binary, Info.plist
# (version taken from the binary itself), icon, hardened-runtime signature.
set -euo pipefail

usage() {
  cat <<'EOF'
Build BrightSync.app from the SwiftPM release build.

Usage: scripts/build-app.sh [--output <dir>] [--sign <identity>] [-h|--help]

Options:
  --output <dir>     Directory to place BrightSync.app in (default: dist)
  --sign <identity>  Codesign identity, matched as a substring against
                     'security find-identity' output (default: "Developer ID
                     Application", the release identity - dev builds too, so
                     TCC grants like Accessibility survive rebuilds). No
                     fallback: a missing match is a hard error, never a
                     silently different signature. Pass "adhoc" for an
                     unsigned local build.
  -h, --help         Show this help.

Example:
  scripts/build-app.sh
EOF
}

output="dist"
sign="Developer ID Application"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      [[ $# -ge 2 ]] || { echo "error: --output needs a value" >&2; exit 2; }
      output="$2"; shift 2 ;;
    --sign)
      [[ $# -ge 2 ]] || { echo "error: --sign needs a value" >&2; exit 2; }
      sign="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"

swift build -c release
binary=".build/release/BrightSync"
version="$("$binary" --version)"

app="$output/BrightSync.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/BrightSync"
sed "s/__VERSION__/$version/g" Packaging/Info.plist > "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist" > /dev/null
cp Packaging/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
if [[ "$sign" == "adhoc" ]]; then
  codesign --force --sign - --options runtime --identifier cz.szypowi.brightsync "$app"
else
  # || true: with set -e, a failing security query (locked/absent keychain)
  # would abort before the explicit error below.
  identity="$(security find-identity -v -p codesigning | awk -v id="$sign" '$0 ~ id {print $2; exit}' || true)"
  if [[ -z "$identity" ]]; then
    echo "error: no codesigning identity matching '$sign'" >&2
    echo "List identities with: security find-identity -v -p codesigning" >&2
    echo "Pick one with --sign <substring>, or --sign adhoc for an unsigned dev build." >&2
    exit 1
  fi
  # --timestamp: notarization requires a secure timestamp.
  codesign --force --sign "$identity" --options runtime --timestamp \
    --identifier cz.szypowi.brightsync "$app"
fi
echo "built $app (version $version)"
