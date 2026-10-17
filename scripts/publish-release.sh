#!/bin/bash
# Publishes a built, notarized DMG: uploads it to a GitHub release and adds it to the update feed (appcast.xml) that installed copies check.
# The DMG is signed with the update key in this Mac's Keychain (account "browsersetu", made by Sparkle's generate_keys). Without that key no update can be offered.
#
#   scripts/publish-release.sh <version> <build> ["release notes"]      (run scripts/release.sh first; it leaves dist/BrowserSetu-<version>.dmg)
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: publish-release.sh <version> <build> [notes]}"; BUILD="${2:?usage: publish-release.sh <version> <build> [notes]}"; NOTES="${3:-Browser Setu $VERSION}"
REPO="${RELEASES_REPO:-lokeshreddyveer/browsersetu}"
DMG="dist/BrowserSetu-$VERSION.dmg"
[ -f "$DMG" ] || { echo "✘ $DMG not found; run scripts/release.sh $VERSION $BUILD first"; exit 1; }
SPARKLE_BIN="$(find apps/apple/build ~/Documents/iptv/macos/.build -type d -path '*artifacts/sparkle/Sparkle/bin' 2>/dev/null | head -1)"
[ -n "$SPARKLE_BIN" ] || { echo "✘ Sparkle's tools were not found (build the Direct scheme once so the package is fetched)"; exit 1; }
SIGN="$("$SPARKLE_BIN/sign_update" --account browsersetu "$DMG")"        # sparkle:edSignature="…" length="…"
TAG="v$VERSION"

echo "▸ Creating release $TAG"
gh release create "$TAG" "$DMG" --repo "$REPO" --title "Browser Setu $VERSION" --notes "$NOTES"

echo "▸ Updating the update feed"
URL="https://github.com/$REPO/releases/download/$TAG/BrowserSetu-$VERSION.dmg"
python3 - appcast.xml "$VERSION" "$BUILD" "$URL" "$SIGN" "$NOTES" <<'PY'
import sys, os, email.utils, html
path, version, build, url, sign, notes = sys.argv[1:7]
item = f"""    <item>
      <title>Browser Setu {version}</title>
      <pubDate>{email.utils.formatdate(localtime=False)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[{html.escape(notes)}]]></description>
      <enclosure url="{url}" type="application/octet-stream" {sign}/>
    </item>
"""
head = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Browser Setu</title>
"""
items = ""
if os.path.exists(path):
    old = open(path).read()
    items = old[old.index("<item>") - 4: old.rindex("</channel>")] if "<item>" in old else ""
open(path, "w").write(head + item + items + "  </channel>\n</rss>\n")
PY
git add appcast.xml && git commit -qm "Update feed for Browser Setu $VERSION" && git push -q origin HEAD
echo "✔ $TAG is published and the update feed offers it"
