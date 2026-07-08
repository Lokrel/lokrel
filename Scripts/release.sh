#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/lokrel.app"
DIST="$ROOT/dist"
ENTITLEMENTS="$ROOT/Scripts/lokrel.entitlements"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Scripts/Info.plist")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ROOT/Scripts/Info.plist")"
ARCH="$(uname -m)"
NAME="lokrel-$VERSION-macOS-$ARCH"
ARCHIVE_DIR="$DIST/archive/$NAME"
ARCHIVE_APP="$ARCHIVE_DIR/lokrel.app"
DMG="$DIST/$NAME.dmg"

require_env() {
    local name="$1"
    if [[ -z "${(P)name:-}" ]]; then
        echo "Missing required environment variable: $name" >&2
        exit 1
    fi
}

require_env LOKREL_DEVELOPER_ID_APPLICATION
require_env LOKREL_NOTARY_APPLE_ID
require_env LOKREL_NOTARY_TEAM_ID
require_env LOKREL_NOTARY_PASSWORD

if [[ "$BUNDLE_ID" != "com.lokrel.app" ]]; then
    echo "Unexpected CFBundleIdentifier: $BUNDLE_ID" >&2
    exit 1
fi

if ! plutil -lint "$ENTITLEMENTS" >/dev/null; then
    echo "Invalid entitlements file: $ENTITLEMENTS" >&2
    exit 1
fi

"$ROOT/Scripts/build-app.sh"

rm -rf "$ARCHIVE_DIR" "$DMG" "$DMG.sha256"
mkdir -p "$ARCHIVE_DIR"
ditto "$APP" "$ARCHIVE_APP"

codesign --force --timestamp --options runtime --entitlements "$ENTITLEMENTS" --sign "$LOKREL_DEVELOPER_ID_APPLICATION" "$ARCHIVE_APP"
codesign --verify --deep --strict --verbose=2 "$ARCHIVE_APP"

SIGNATURE_DETAILS="$(codesign -dv --verbose=4 "$ARCHIVE_APP" 2>&1)"
if [[ "$SIGNATURE_DETAILS" != *"runtime"* ]]; then
    echo "Hardened Runtime was not enabled on $ARCHIVE_APP" >&2
    exit 1
fi
if [[ "$SIGNATURE_DETAILS" != *"Authority=Developer ID Application:"* ]]; then
    echo "$ARCHIVE_APP is not signed with a Developer ID Application certificate" >&2
    exit 1
fi

SIGNED_ENTITLEMENTS="$(codesign -d --entitlements - "$ARCHIVE_APP" 2>/dev/null || true)"
if [[ "$SIGNED_ENTITLEMENTS" == *"com.apple.security.get-task-allow"* ]]; then
    echo "Release entitlements must not include com.apple.security.get-task-allow" >&2
    exit 1
fi

DMG_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lokrel-dmg.XXXXXX")"
trap 'rm -rf "$DMG_ROOT"' EXIT
ditto "$ARCHIVE_APP" "$DMG_ROOT/lokrel.app"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create -volname "lokrel" -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG"

codesign --force --timestamp --sign "$LOKREL_DEVELOPER_ID_APPLICATION" "$DMG"
codesign --verify --verbose=2 "$DMG"

xcrun notarytool submit "$DMG" \
    --apple-id "$LOKREL_NOTARY_APPLE_ID" \
    --team-id "$LOKREL_NOTARY_TEAM_ID" \
    --password "$LOKREL_NOTARY_PASSWORD" \
    --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl -a -t open --context context:primary-signature -vv "$DMG"

shasum -a 256 "$DMG" | tee "$DMG.sha256"

echo "Archived $ARCHIVE_APP"
echo "Packaged $DMG"
