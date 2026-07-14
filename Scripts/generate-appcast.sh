#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCHIVE="${1:-}"

if [[ -z "$ARCHIVE" || ! -f "$ARCHIVE" ]]; then
    echo "Usage: $0 /path/to/lokrel-version.dmg" >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Scripts/Info.plist")"
GENERATE_APPCAST="$(find "$ROOT/.build/artifacts" -type f \
    -path '*/Sparkle/bin/generate_appcast' -print -quit)"
if [[ -z "$GENERATE_APPCAST" ]]; then
    echo "Sparkle generate_appcast tool was not found. Run swift package resolve first." >&2
    exit 1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lokrel-appcast.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

ditto "$ARCHIVE" "$WORK_DIR/$(basename "$ARCHIVE")"
if [[ -f "$ROOT/docs/appcast.xml" ]]; then
    cp "$ROOT/docs/appcast.xml" "$WORK_DIR/appcast.xml"
fi

"$GENERATE_APPCAST" \
    --download-url-prefix "https://github.com/Lokrel/lokrel/releases/download/v$VERSION/" \
    --link "https://github.com/Lokrel/lokrel/releases/latest" \
    --maximum-versions 5 \
    -o "$WORK_DIR/appcast.xml" \
    "$WORK_DIR"

cp "$WORK_DIR/appcast.xml" "$ROOT/docs/appcast.xml"
echo "Updated $ROOT/docs/appcast.xml"
