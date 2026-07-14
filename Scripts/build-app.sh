#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/lokrel.app"

cd "$ROOT"
"$ROOT/Scripts/build-icon.sh"
ARM_SCRATCH="$ROOT/.build/arm64"
INTEL_SCRATCH="$ROOT/.build/x86_64"
swift build -c release --triple arm64-apple-macosx14.0 --scratch-path "$ARM_SCRATCH"
swift build -c release --triple x86_64-apple-macosx14.0 --scratch-path "$INTEL_SCRATCH"
ARM_BIN_DIR="$(swift build -c release --triple arm64-apple-macosx14.0 --scratch-path "$ARM_SCRATCH" --show-bin-path)"
INTEL_BIN_DIR="$(swift build -c release --triple x86_64-apple-macosx14.0 --scratch-path "$INTEL_SCRATCH" --show-bin-path)"
ARM_BIN="$ARM_BIN_DIR/lokrel"
INTEL_BIN="$INTEL_BIN_DIR/lokrel"
SPARKLE_FRAMEWORK="$ARM_BIN_DIR/Sparkle.framework"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
lipo -create "$ARM_BIN" "$INTEL_BIN" -output "$APP/Contents/MacOS/lokrel"
ditto "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
cp "$ROOT/Scripts/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

SIGN_IDENTITY="${LOKREL_CODE_SIGN_IDENTITY:-${LOKREL_DEVELOPER_ID_APPLICATION:-}}"
if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning \
        | awk -F'"' '/Developer ID Application/ { print $2; exit }')"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="-"
fi
codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" \
    "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --options runtime --entitlements "$ROOT/Scripts/lokrel.entitlements" \
    --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

ARCHS="$(lipo -archs "$APP/Contents/MacOS/lokrel")"
if [[ "$ARCHS" != *"arm64"* || "$ARCHS" != *"x86_64"* ]]; then
    echo "Expected a Universal 2 binary, got: $ARCHS" >&2
    exit 1
fi
SPARKLE_ARCHS="$(lipo -archs "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle")"
if [[ "$SPARKLE_ARCHS" != *"arm64"* || "$SPARKLE_ARCHS" != *"x86_64"* ]]; then
    echo "Expected a Universal 2 Sparkle framework, got: $SPARKLE_ARCHS" >&2
    exit 1
fi

echo "Built $APP ($ARCHS, signed by $SIGN_IDENTITY)"
