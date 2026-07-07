#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/lokrel.app"
DIST="$ROOT/dist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Scripts/Info.plist")"
ARCH="$(uname -m)"
NAME="lokrel-$VERSION-macOS-$ARCH"
ZIP="$DIST/$NAME.zip"

"$ROOT/Scripts/build-app.sh"

mkdir -p "$DIST"
rm -f "$ZIP" "$ZIP.sha256"

codesign --force --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"

echo "Packaged $ZIP"
