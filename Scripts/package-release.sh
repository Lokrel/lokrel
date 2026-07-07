#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/lokrel.app"
DIST="$ROOT/dist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Scripts/Info.plist")"
ARCH="$(uname -m)"
NAME="lokrel-$VERSION-macOS-$ARCH"
ZIP="$DIST/$NAME.zip"
DMG="$DIST/$NAME.dmg"
SIGN_IDENTITY="${LOKREL_DEVELOPER_ID_APPLICATION:-}"
NOTARY_PROFILE="${LOKREL_NOTARY_PROFILE:-}"

"$ROOT/Scripts/build-app.sh"

mkdir -p "$DIST"
rm -f "$ZIP" "$ZIP.sha256" "$DMG" "$DMG.sha256"

if [[ -n "$NOTARY_PROFILE" && -z "$SIGN_IDENTITY" ]]; then
    echo "LOKREL_NOTARY_PROFILE requires LOKREL_DEVELOPER_ID_APPLICATION" >&2
    exit 1
fi

if [[ -n "$SIGN_IDENTITY" ]]; then
    codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$APP"
else
    echo "LOKREL_DEVELOPER_ID_APPLICATION is not set; using ad-hoc signing."
    codesign --force --sign - "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"

ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"

DMG_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lokrel-dmg.XXXXXX")"
trap 'rm -rf "$DMG_ROOT"' EXIT
cp -R "$APP" "$DMG_ROOT/"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create -volname "lokrel" -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG"

if [[ -n "$SIGN_IDENTITY" ]]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
    codesign --verify --verbose=2 "$DMG"
fi

if [[ -n "$NOTARY_PROFILE" ]]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl -a -t open --context context:primary-signature -vv "$DMG"
else
    echo "LOKREL_NOTARY_PROFILE is not set; skipping notarization."
fi

shasum -a 256 "$DMG" | tee "$DMG.sha256"

echo "Packaged $ZIP"
echo "Packaged $DMG"
