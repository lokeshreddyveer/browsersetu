#!/bin/bash
# Archives the iPhone/iPad app and uploads it to App Store Connect (TestFlight).
#
#   scripts/testflight.sh [build-number] [--archive-only]
#
# One-time setup in a browser: appstoreconnect.apple.com > Apps > + > New App > iOS, name "Browser Setu", bundle ID com.browsersetu.ios, any SKU.
# Xcode must be signed in to the Apple ID that owns team X4MH29QNRS. Every upload needs a build number higher than the last.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
TEAM="${TEAM:-X4MH29QNRS}"
OUT="$HOME/Library/Application Support/BrowserSetuRelease/testflight"; mkdir -p "$OUT"
ARG1="${1:-}"; [ "$ARG1" = "--archive-only" ] && ARG1=""
LAST=$(cat "$OUT/last-build" 2>/dev/null || echo 1)
BUILD="${ARG1:-$((LAST + 1))}"
case "$BUILD" in ''|*[!0-9]*) echo "build number must be a whole number"; exit 1;; esac
ARCHIVE="$OUT/BrowserSetu-$BUILD.xcarchive"
scripts/build-xcframework.sh >/dev/null
(cd apps/apple && xcodegen generate --spec project.yml >/dev/null)
echo "▸ Archiving build $BUILD…"
xcodebuild archive -project apps/apple/BrowserSetu.xcodeproj -scheme BrowserSetuiOS -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" CURRENT_PROJECT_VERSION="$BUILD" 2>&1 | grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)"
[ -d "$ARCHIVE" ] || { echo "✘ archive failed"; exit 1; }
case " $* " in *" --archive-only "*) echo "✔ archived: $ARCHIVE"; exit 0;; esac
cat > "$OUT/ExportOptions.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
</dict></plist>
PL
echo "▸ Uploading to App Store Connect…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates 2>&1 | grep -E "error:|Upload|EXPORT (SUCCEEDED|FAILED)|Uploaded|There is no|Cloud signing"
echo "$BUILD" > "$OUT/last-build"
echo "Done. Build $BUILD is uploaded; it appears in TestFlight after Apple finishes processing it (usually 5-15 minutes)."
