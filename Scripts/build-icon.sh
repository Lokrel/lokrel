#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/Resources/Appicon_.png"
NORMALIZED="$ROOT/Resources/AppIcon.png"
ICONSET="$ROOT/.build/AppIcon.iconset"
OUTPUT="$ROOT/Resources/AppIcon.icns"

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

WIDTH="$(sips -g pixelWidth "$SOURCE" | awk '/pixelWidth/ {print $2}')"
HEIGHT="$(sips -g pixelHeight "$SOURCE" | awk '/pixelHeight/ {print $2}')"
if (( WIDTH > HEIGHT )); then
    SIZE="$WIDTH"
else
    SIZE="$HEIGHT"
fi
sips --padToHeightWidth "$SIZE" "$SIZE" "$SOURCE" --out "$NORMALIZED" >/dev/null

sips -z 16 16 "$NORMALIZED" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32 "$NORMALIZED" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$NORMALIZED" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64 "$NORMALIZED" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$NORMALIZED" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256 "$NORMALIZED" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$NORMALIZED" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512 "$NORMALIZED" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$NORMALIZED" --out "$ICONSET/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$NORMALIZED" --out "$ICONSET/icon_512x512@2x.png" >/dev/null

iconutil -c icns "$ICONSET" -o "$OUTPUT"
