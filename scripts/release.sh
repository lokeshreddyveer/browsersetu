#!/bin/bash
# Builds Browser Setu, signs it with your Developer ID, has Apple notarize it, staples the ticket and packs a DMG that
# opens with no Gatekeeper warning.
#
#   scripts/release.sh --check              only checks that the certificate and notary login are usable
#   scripts/release.sh <version> <build>    full release, e.g. scripts/release.sh 0.2.0 7
#
# One-time setup (the same login works for every app on your team):
#   xcrun notarytool store-credentials BrowserSetu-NOTARY --apple-id <Apple ID email> --team-id <TEAM ID>
# Environment:
#   NOTARY_PROFILE  keychain profile name (default BrowserSetu-NOTARY; StreamSetu-NOTARY works if you have it)
#   SIGN_IDENTITY   certificate hash to use (default: the first "Developer ID Application" certificate found)
#
# Nothing is uploaded except the notarization submission itself, which Apple requires.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export PATH="$HOME/.cargo/bin:$PATH"

# The same Apple ID and team as StreamSetu, so its stored notary login works when a BrowserSetu-NOTARY one has not been made.
NOTARY_PROFILE="${NOTARY_PROFILE:-BrowserSetu-NOTARY}"
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 && xcrun notarytool history --keychain-profile StreamSetu-NOTARY >/dev/null 2>&1; then
  NOTARY_PROFILE=StreamSetu-NOTARY
fi
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | awk '{print $2}')}"

fail() { echo "✘ $*" >&2; exit 1; }
[ -n "$SIGN_IDENTITY" ] || fail "no 'Developer ID Application' certificate found. Create one in Xcode > Settings > Accounts > Manage Certificates."
IDENTITY_NAME=$(security find-identity -v -p codesigning | grep "$SIGN_IDENTITY" | head -1 | sed 's/.*"\(.*\)"/\1/')
TEAM_ID=$(echo "$IDENTITY_NAME" | sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p')
[ -n "$TEAM_ID" ] || fail "could not read the team ID from '$IDENTITY_NAME'."
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || fail "notary profile '$NOTARY_PROFILE' is not set up. Run the one-time setup at the top of this script."
echo "▸ Signing as: $IDENTITY_NAME"
echo "▸ Notary profile: $NOTARY_PROFILE"

[ "${1:-}" = "--check" ] && { echo "✔ certificate and notary login are usable"; exit 0; }

VERSION="${1:?usage: scripts/release.sh <version> <build>  (or --check)}"
BUILD="${2:?usage: scripts/release.sh <version> <build>  (or --check)}"
APP_NAME="Browser Setu"
DERIVED="build/release"
DIST="dist"
rm -rf "$DIST" "$DERIVED"; mkdir -p "$DIST"

# Always rebuilt, from the locked dependencies and the pinned toolchain: a framework left from earlier would link older Rust code.
echo "▸ Building the Rust core"; scripts/build-xcframework.sh
mkdir -p "$DIST"; cp apps/apple/Generated/CORE_SOURCE_HASH "$DIST/core-build-identity.txt"
(cd apps/apple && xcodegen generate --spec project.yml >/dev/null)

echo "▸ Building $VERSION ($BUILD)"
# The downloadable build (with the Sparkle updater), not the App Store one.
xcodebuild -project apps/apple/BrowserSetu.xcodeproj -scheme BrowserSetuMacDirect -configuration Release \
  -derivedDataPath "$DERIVED" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_IDENTITY" DEVELOPMENT_TEAM="$TEAM_ID" \
  ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS="--timestamp" build | tail -3

BUILT="$DERIVED/Build/Products/Release/$APP_NAME Direct.app"
[ -d "$BUILT" ] || fail "the build did not produce $BUILT"
APP="$DERIVED/Build/Products/Release/$APP_NAME.app"
mv "$BUILT" "$APP"     # the shipped app is called Browser Setu; the build target is named apart only so both builds can share a folder
# Sparkle's helpers are signed innermost first with the same identity, hardened runtime and a timestamp, as notarization requires.
SP="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
if [ -d "$SP" ]; then
  for part in "$SP/XPCServices/Installer.xpc" "$SP/XPCServices/Downloader.xpc" "$SP/Autoupdate" "$SP/Updater.app" "$APP/Contents/Frameworks/Sparkle.framework"; do
    [ -e "$part" ] && codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$part"
  done
  codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" --entitlements "$DERIVED/Build/Intermediates.noindex/BrowserSetu.build/Release/BrowserSetuMacDirect.build/Browser Setu Direct.app.xcent" "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2
SANDBOX="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | python3 -c 'import sys,plistlib; d=sys.stdin.buffer.read(); print(str(plistlib.loads(d[d.index(b"<?xml"):]).get("com.apple.security.app-sandbox", "missing")).lower())' 2>/dev/null || echo missing)"
[ "$SANDBOX" = "true" ] || fail "the app's sandbox entitlement is '$SANDBOX', not true; refusing to release it."

echo "▸ Notarizing the app (this waits for Apple)"
ZIP="$DIST/$APP_NAME.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"

echo "▸ Making the disk image"
STAGE="$DIST/stage"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$DIST/BrowserSetu-$VERSION.dmg"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG" 2>&1 | tail -2
python3 scripts/generate-sbom.py "$DIST" >/dev/null && echo "▸ SBOM and build metadata written to $DIST"
echo "✔ $DMG is signed, notarized and stapled"
shasum -a 256 "$DMG"
