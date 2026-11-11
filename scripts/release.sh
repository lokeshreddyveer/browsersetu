#!/bin/bash
# Builds Browser Setu, signs it with your Developer ID, has Apple notarize it, staples the ticket and packs a DMG that
# opens with no Gatekeeper warning.
#
#   scripts/release.sh --check              only checks that the certificate and notary login are usable
#   scripts/release.sh <version> <build>    full release, e.g. scripts/release.sh 0.2.0 7
#   scripts/release.sh <version> <build> --verify-only
#                                           the same pipeline up to and including the final signature and the media-tools preflight, into isolated folders
#                                           (RELEASE_DERIVED / RELEASE_DIST, default a temp folder). Nothing is notarized, no DMG is made, dist/ is not touched; the result is NOT releasable.
#
# Media tools (yt-dlp, ffmpeg/ffprobe) are OPTIONAL DOWNLOADS, not part of the app: scripts/release-media-tools.sh --ensure reuses the cached signed + notarized packages when their inputs are unchanged
# and re-verify, and builds, signs, notarizes and caches them otherwise; scripts/embed-media-manifests.sh puts only their manifests in the app; scripts/check-media-tools.sh refuses to continue unless
# the built app carries no tool and its manifests match the verified packages. The packages are hosted separately (MEDIA_PACKAGES_HOSTED=1 once uploaded and verified).
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
# With a provisioning profile given, the certificate is the Developer ID one the profile was made for (a team can have several); otherwise the first one found.
if [ -z "${SIGN_IDENTITY:-}" ] && [ -n "${DEVELOPERID_PROFILE:-}" ] && [ -f "$DEVELOPERID_PROFILE" ]; then
  PROFILE_CERTS="$(security cms -D -i "$DEVELOPERID_PROFILE" 2>/dev/null | python3 -c 'import sys,plistlib,hashlib; print(" ".join(hashlib.sha1(c).hexdigest().upper() for c in plistlib.loads(sys.stdin.buffer.read()).get("DeveloperCertificates", [])))' 2>/dev/null || true)"
  for h in $(security find-identity -v -p codesigning | grep "Developer ID Application" | awk '{print $2}'); do
    case " $PROFILE_CERTS " in *" $h "*) SIGN_IDENTITY="$h"; break ;; esac
  done
fi
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | awk '{print $2}')}"

fail() { echo "✘ $*" >&2; exit 1; }
[ -n "$SIGN_IDENTITY" ] || fail "no 'Developer ID Application' certificate found. Create one in Xcode > Settings > Accounts > Manage Certificates."
IDENTITY_NAME=$(security find-identity -v -p codesigning | grep "$SIGN_IDENTITY" | head -1 | sed 's/.*"\(.*\)"/\1/')
TEAM_ID=$(echo "$IDENTITY_NAME" | sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p')
[ -n "$TEAM_ID" ] || fail "could not read the team ID from '$IDENTITY_NAME'."
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || fail "notary profile '$NOTARY_PROFILE' is not set up. Run the one-time setup at the top of this script."
# The app carries the iCloud key-value entitlement (restricted), so it needs a Developer ID provisioning profile for com.browsersetu.mac:
# a Mac profile of the "Developer ID" distribution type (applies to all devices), made for this team and certificate, with iCloud key-value storage enabled.
# A development profile (limited to registered devices) is refused here on purpose.
#   DEVELOPERID_PROFILE  path to that .provisionprofile
PROFILE_PLIST=""
if [ "${1:-}" != "--check" ] || [ -n "${DEVELOPERID_PROFILE:-}" ]; then
  [ -n "${DEVELOPERID_PROFILE:-}" ] && [ -f "$DEVELOPERID_PROFILE" ] || fail "set DEVELOPERID_PROFILE to the Developer ID provisioning profile for com.browsersetu.mac (Apple Developer > Certificates, IDs & Profiles > Profiles > + > Developer ID > Mac)."
  PROFILE_PLIST="$(mktemp)"; trap 'rm -f "$PROFILE_PLIST"' EXIT
  security cms -D -i "$DEVELOPERID_PROFILE" > "$PROFILE_PLIST" 2>/dev/null || fail "could not read $DEVELOPERID_PROFILE."
  CERT_SHA1="$SIGN_IDENTITY" python3 - "$PROFILE_PLIST" "$TEAM_ID" <<'PY' || exit 1
import sys, plistlib, hashlib, os, datetime
d = plistlib.load(open(sys.argv[1], "rb")); team = sys.argv[2]; e = d.get("Entitlements", {}); bad = []
if "OSX" not in d.get("Platform", []): bad.append("it is not a Mac profile")
if not d.get("ProvisionsAllDevices"): bad.append("it is limited to registered devices (a development profile); a Developer ID profile applies to all devices")
if d.get("ExpirationDate") and d["ExpirationDate"] < datetime.datetime.utcnow(): bad.append("it has expired")
if e.get("com.apple.application-identifier") != team + ".com.browsersetu.mac": bad.append("its application identifier is %r, not %s.com.browsersetu.mac" % (e.get("com.apple.application-identifier"), team))
if e.get("com.apple.developer.team-identifier") != team: bad.append("its team does not match the signing certificate's team")
kvs = e.get("com.apple.developer.ubiquity-kvstore-identifier")
if not kvs: bad.append("it does not include iCloud key-value storage")
elif kvs != team + ".*" and kvs != team + ".com.browsersetu.sync": bad.append("its key-value identifier %r does not cover %s.com.browsersetu.sync" % (kvs, team))
sha = os.environ.get("CERT_SHA1", "").upper()
if sha and sha not in [hashlib.sha1(c).hexdigest().upper() for c in d.get("DeveloperCertificates", [])]: bad.append("it was not made for the signing certificate in use")
if bad:
    print("✘ the provisioning profile is not usable: " + "; ".join(bad), file=sys.stderr); sys.exit(1)
PY
fi
echo "▸ Signing as: $IDENTITY_NAME"
echo "▸ Notary profile: $NOTARY_PROFILE"

[ "${1:-}" = "--check" ] && { echo "✔ certificate and notary login are usable"; exit 0; }

VERSION="${1:?usage: scripts/release.sh <version> <build> [--verify-only]  (or --check)}"
BUILD="${2:?usage: scripts/release.sh <version> <build> [--verify-only]  (or --check)}"
VERIFY_ONLY=0; [ "${3:-}" = "--verify-only" ] && VERIFY_ONLY=1
[ -z "${3:-}" ] || [ "$VERIFY_ONLY" = 1 ] || fail "unknown option '${3:-}'"
APP_NAME="Browser Setu"
if [ "$VERIFY_ONLY" = 1 ]; then
  VROOT="${RELEASE_VERIFY_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/browsersetu-verify.XXXXXX")}"
  DERIVED="${RELEASE_DERIVED:-$VROOT/derived}"; DIST="${RELEASE_DIST:-$VROOT/dist}"
  case "$DERIVED $DIST" in *" dist"|"build/release "*) fail "--verify-only must not use the real build/release or dist folders" ;; esac
  echo "▸ VERIFY ONLY: building into $VROOT (not releasable; nothing is notarized or published)"
else
  DERIVED="build/release"
  DIST="dist"
fi
rm -rf "$DIST" "$DERIVED"; mkdir -p "$DIST"

# The permanent architecture decision (docs/decisions/0001): documents, manifests, build files and scripts must not contradict it.
python3 -I scripts/check-architecture.py || fail "the repository contradicts docs/decisions/0001-media-tools-optional-downloads.md (see above)."

# The signed + notarized media-tool packages come first: reused from the cache when unchanged and still valid, otherwise built, signed, notarized and cached. Fails the release before any app build.
echo "▸ Media tools: ensuring signed + notarized packages (yt-dlp, ffmpeg)"
scripts/release-media-tools.sh --ensure --identity "$SIGN_IDENTITY" --team "$TEAM_ID" --notary-profile "$NOTARY_PROFILE" --tool all --online || fail "the media-tool packages are not ready (see above)."

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
echo "▸ Media-tool manifests (no tool is bundled; they are optional downloads)"
HOSTED_FLAG=""; HOSTED_VERIFIED_FLAG=""
if [ "${MEDIA_PACKAGES_HOSTED:-}" = "1" ]; then
  # Only when the packages are really uploaded: the bytes at each address must be exactly the verified package, or the app would offer an install that fails.
  for t in yt-dlp ffmpeg; do
    ENTRY="$(python3 -I scripts/media_tools_cache.py lookup --tool "$t" --arch arm64 --team "$TEAM_ID")" || fail "no verified $t package in the cache to check the hosted copy against."
    python3 -I scripts/media_tools_cache.py verify-hosted --tool "$t" --entry "$ENTRY" || fail "the hosted $t package is missing or is not the verified one (MEDIA_PACKAGES_HOSTED=1 requires it to be uploaded first)."
  done
  HOSTED_FLAG="--hosted"; HOSTED_VERIFIED_FLAG="--hosted-verified"
fi
scripts/embed-media-manifests.sh "$APP" --team "$TEAM_ID" $HOSTED_FLAG || fail "the media-tool manifests could not be written."
echo "▸ Embedding the JavaScript challenge runner (setu-jsc + yt-dlp plugin)"
scripts/embed-js-provider.sh "$APP" --identity "$SIGN_IDENTITY" --team "$TEAM_ID" || fail "the JavaScript provider could not be embedded."
# Sparkle's helpers are signed innermost first with the same identity, hardened runtime and a timestamp, as notarization requires.
SP="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
[ -d "$SP" ] || fail "Sparkle.framework is missing from the built app; the final signature (which seals the embedded tools) would be skipped."
if [ -d "$SP" ]; then
  for part in "$SP/XPCServices/Installer.xpc" "$SP/XPCServices/Downloader.xpc" "$SP/Autoupdate" "$SP/Updater.app" "$APP/Contents/Frameworks/Sparkle.framework"; do
    [ -e "$part" ] && codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$part"
  done
  # The profile goes in before the final signature, and its two identifier entitlements are added to the ones the build made, so the signature and the profile agree.
  cp "$DEVELOPERID_PROFILE" "$APP/Contents/embedded.provisionprofile"
  FINAL_ENTS="$(mktemp)"
  python3 - "$DERIVED/Build/Intermediates.noindex/BrowserSetu.build/Release/BrowserSetuMacDirect.build/Browser Setu Direct.app.xcent" "$PROFILE_PLIST" "$FINAL_ENTS" <<'PY'
import sys, plistlib
ents = plistlib.load(open(sys.argv[1], "rb")); e = plistlib.load(open(sys.argv[2], "rb"))["Entitlements"]
for k in ("com.apple.application-identifier", "com.apple.developer.team-identifier"): ents[k] = e[k]
plistlib.dump(ents, open(sys.argv[3], "wb"))
PY
  codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" --entitlements "$FINAL_ENTS" "$APP"
  rm -f "$FINAL_ENTS"
fi
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2
# The downloadable build is deliberately not sandboxed (apps/apple/project.yml, BrowserSetuMacDirect); it relies on the Hardened Runtime and notarization instead.
# What must hold for it: Hardened Runtime on, no sandbox entitlement, and, because it carries the iCloud key-value entitlement (a restricted entitlement), a Developer ID
# provisioning profile embedded in the app. Without that profile macOS refuses to launch the app.
ENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | python3 -c 'import sys,plistlib; d=sys.stdin.buffer.read(); e=plistlib.loads(d[d.index(b"<?xml"):]); print("sandbox=" + str(e.get("com.apple.security.app-sandbox", False)).lower() + " kvs=" + str("com.apple.developer.ubiquity-kvstore-identifier" in e).lower())' 2>/dev/null || echo "unreadable")"
case "$ENTS" in *"sandbox=false"*) ;; *) fail "the app's entitlements read '$ENTS'; the downloadable build must not be sandboxed. Refusing to release it." ;; esac
# Read the output first: piping codesign into grep -q under pipefail reports failure when grep exits at the first match (SIGPIPE), even though the flag is there.
SIGNING_INFO="$(codesign -dvv "$APP" 2>&1 || true)"
case "$SIGNING_INFO" in *"flags="*"runtime"*) ;; *) fail "the Hardened Runtime flag is missing; notarization would refuse it." ;; esac
case "$ENTS" in *"kvs=true"*) [ -f "$APP/Contents/embedded.provisionprofile" ] || fail "the app carries the iCloud key-value entitlement but has no embedded Developer ID provisioning profile, so macOS would not launch it. Create a Developer ID profile for com.browsersetu.mac with iCloud key-value storage and embed it (see apps/apple/project.yml)." ;; esac

echo "▸ Checking the built app (no bundled tools; manifests match the verified packages)"
SRC_FLAG=""
if [ "${MEDIA_SOURCES_PUBLISHED:-}" = "1" ]; then SRC_FLAG="--sources-published"; elif [ "$VERIFY_ONLY" = 1 ]; then SRC_FLAG="--allow-unpublished-sources"; fi
scripts/check-media-tools.sh "$APP" --team "$TEAM_ID" --readme README.md $SRC_FLAG $HOSTED_VERIFIED_FLAG || fail "the media tools in the built app are not release-ready (see above)."
if [ "$VERIFY_ONLY" = 1 ]; then
  echo "✔ VERIFY ONLY complete: $APP is built, signed and passes the media-tools preflight (no bundled tools). It was NOT notarized and is NOT releasable."
  exit 0
fi

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
python3 scripts/generate-sbom.py "$DIST" --version "$VERSION" >/dev/null
echo "▸ SBOM and build metadata written to $DIST"
echo "✔ $DMG is signed, notarized and stapled"
shasum -a 256 "$DMG"
