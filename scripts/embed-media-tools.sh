#!/bin/bash
# THE one place that puts yt-dlp and ffmpeg/ffprobe inside a built Browser Setu.app (the Xcode project embeds nothing; release.sh calls this). Run it BEFORE the app's final signature; it signs nothing itself.
#
#   scripts/embed-media-tools.sh "<Browser Setu.app>" --team TEAMID [--cache DIR]
#
# Each tool comes from the content-addressed cache (scripts/release-media-tools.sh --ensure fills it) and only after the cached package re-verifies from its bytes (digests, every
# signature, Team ID, hardened runtime, chain, architecture, an Accepted notarization record). The package is unpacked unchanged (so signatures and the tree digest stay as made) into
# Contents/Resources/Tools/<name>; the app's manifest (Resources/BundledTools.json, BundledFFmpeg.json) is GENERATED from the verified package, never copied from a template;
# licence notices and source offers go to Resources/Notices. The manifest's download address stays empty until a package is really hosted and verified, so the app offers no install
# that could fail. Debug builds and the App Store / iOS targets do not run this and therefore carry no tools (they show "not available in this build").
set -euo pipefail
APP="${1:?usage: embed-media-tools.sh <app> --team TEAMID [--cache DIR]}"; shift
TEAM=""; CACHE="${MEDIA_TOOLS_CACHE:-$HOME/Library/Caches/BrowserSetu/media-tools}"; ARCH=""
while [ $# -gt 0 ]; do case "$1" in --team) TEAM="$2"; shift 2;; --cache) CACHE="$2"; shift 2;; --arch) ARCH="$2"; shift 2;; *) echo "unknown option $1" >&2; exit 2;; esac; done
[ -n "$TEAM" ] || { echo "✘ --team is required" >&2; exit 2; }
here="$(cd "$(dirname "$0")" && pwd)"; RES="$APP/Contents/Resources"; py="$here/media_tools_cache.py"
[ -d "$RES" ] || { echo "✘ $RES not found" >&2; exit 1; }
if [ -z "$ARCH" ]; then   # the tools must run wherever the app runs: take the app's own architecture
  main="$(ls "$APP/Contents/MacOS" | head -1)"; ARCH="$(lipo -archs "$APP/Contents/MacOS/$main")"
  [ "$(echo "$ARCH" | wc -w | tr -d ' ')" = 1 ] || { echo "✘ the app is a universal build ($ARCH); the media tools are packaged per architecture (build them for each)" >&2; exit 1; }
fi
manifest_for() { case "$1" in yt-dlp) echo BundledTools.json;; ffmpeg) echo BundledFFmpeg.json;; esac; }
rm -rf "$RES/Tools"; mkdir -p "$RES/Tools" "$RES/Notices"
for t in yt-dlp ffmpeg; do
  entry="$(python3 -I "$py" lookup --tool "$t" --arch "$ARCH" --team "$TEAM" --cache "$CACHE")" || { echo "✘ no valid signed + notarized $t package in the cache for these inputs. Run: scripts/release-media-tools.sh --ensure --identity <SHA-1> --team $TEAM --notary-profile <profile> --tool $t" >&2; exit 1; }
  mkdir -p "$RES/Tools/$t"; /usr/bin/unzip -q "$entry/package.zip" -d "$RES/Tools/$t"
  python3 -I "$py" manifest --tool "$t" --entry "$entry" --out "$RES/$(manifest_for "$t")" >/dev/null
  want="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['treeSHA256'])" "$RES/$(manifest_for "$t")")"
  got="$(python3 "$here/tree_digest.py" "$RES/Tools/$t" | cut -d' ' -f1)"
  [ "$want" = "$got" ] || { echo "✘ the embedded $t tree ($got) is not the verified package ($want)" >&2; exit 1; }
  echo "  embedded $t: $(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['version'])" "$RES/$(manifest_for "$t")") tree $got"
done
cp "$here"/../docs/compliance/media-tools-release-assets/*.txt "$RES/Notices/"
[ -f "$here/../apps/apple/ThirdParty/yt-dlp/THIRD_PARTY_LICENSES.txt" ] && cp "$here/../apps/apple/ThirdParty/yt-dlp/THIRD_PARTY_LICENSES.txt" "$RES/Notices/YT-DLP-THIRD_PARTY_LICENSES.txt"
[ -f "$here/../apps/apple/ThirdParty/yt-dlp/LICENSE" ] && cp "$here/../apps/apple/ThirdParty/yt-dlp/LICENSE" "$RES/Notices/YT-DLP-LICENSE-Unlicense.txt"
echo "  notices: $(ls "$RES/Notices" | tr '\n' ' ')"
