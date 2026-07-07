#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/lokrel.app"

cd "$ROOT"
"$ROOT/Scripts/build-icon.sh"
swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/lokrel" "$APP/Contents/MacOS/lokrel"
cp "$ROOT/Scripts/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "Built $APP"
