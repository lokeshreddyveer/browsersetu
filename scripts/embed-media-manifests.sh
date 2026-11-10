#!/bin/bash
# THE one place that puts the media-tool MANIFESTS (not the tools) into a built Browser Setu.app. yt-dlp, ffmpeg and ffprobe are optional downloads: the app carries no copy of them, only the
# pinned description of each signed + notarized package (Resources/BundledTools.json, BundledFFmpeg.json), the licence notices and source offers (Resources/Notices), and, separately, the
# JavaScript challenge helper (scripts/embed-js-provider.sh). Run it BEFORE the app's final signature; it signs nothing itself.
#
#   scripts/embed-media-manifests.sh "<Browser Setu.app>" --team TEAMID [--cache DIR] [--hosted]
#
# Each manifest is GENERATED from the content-addressed cache entry (scripts/release-media-tools.sh --ensure fills it), and only after that package re-verifies from its bytes (digests, every
# signature, Team ID, hardened runtime, chain, architecture, an Accepted notarization record). The download address stays EMPTY unless --hosted is given (release.sh gives it only after the
# packages are uploaded and the bytes at the address were checked), so the app never offers an install that could fail. Any copy of a tool already in the app is removed.
set -euo pipefail
APP="${1:?usage: embed-media-manifests.sh <app> --team TEAMID [--cache DIR] [--hosted]}"; shift
TEAM=""; CACHE="${MEDIA_TOOLS_CACHE:-$HOME/Library/Caches/BrowserSetu/media-tools}"; ARCH=""; HOSTED=""
while [ $# -gt 0 ]; do case "$1" in --team) TEAM="$2"; shift 2;; --cache) CACHE="$2"; shift 2;; --arch) ARCH="$2"; shift 2;; --hosted) HOSTED=1; shift;; *) echo "unknown option $1" >&2; exit 2;; esac; done
[ -n "$TEAM" ] || { echo "✘ --team is required" >&2; exit 2; }
here="$(cd "$(dirname "$0")" && pwd)"; RES="$APP/Contents/Resources"; py="$here/media_tools_cache.py"
[ -d "$RES" ] || { echo "✘ $RES not found" >&2; exit 1; }
if [ -z "$ARCH" ]; then   # the packages must run wherever the app runs: take the app's own architecture
  main="$(ls "$APP/Contents/MacOS" | head -1)"; ARCH="$(lipo -archs "$APP/Contents/MacOS/$main")"
  [ "$(echo "$ARCH" | wc -w | tr -d ' ')" = 1 ] || { echo "✘ the app is a universal build ($ARCH); the media tools are packaged per architecture (build them for each)" >&2; exit 1; }
fi
manifest_for() { case "$1" in yt-dlp) echo BundledTools.json;; ffmpeg) echo BundledFFmpeg.json;; esac; }
rm -rf "$RES/Tools" "$APP/Contents/Helpers/yt-dlp"; mkdir -p "$RES/Notices"
for t in yt-dlp ffmpeg; do
  entry="$(python3 -I "$py" lookup --tool "$t" --arch "$ARCH" --team "$TEAM" --cache "$CACHE")" || { echo "✘ no valid signed + notarized $t package in the cache for these inputs. Run: scripts/release-media-tools.sh --ensure --identity <SHA-1> --team $TEAM --notary-profile <profile> --tool $t" >&2; exit 1; }
  python3 -I "$py" manifest --tool "$t" --entry "$entry" --out "$RES/$(manifest_for "$t")" ${HOSTED:+--hosted} >/dev/null
  echo "  manifest $t: $(python3 -c "import json,sys;m=json.load(open(sys.argv[1]));print(m['version'], 'tree', m['treeSHA256'][:12], 'address', m['sourceURL'] or '(none yet)')" "$RES/$(manifest_for "$t")")"
done
cp "$here"/../docs/compliance/media-tools-release-assets/*.txt "$RES/Notices/"
[ -f "$here/../apps/apple/ThirdParty/yt-dlp/THIRD_PARTY_LICENSES.txt" ] && cp "$here/../apps/apple/ThirdParty/yt-dlp/THIRD_PARTY_LICENSES.txt" "$RES/Notices/YT-DLP-THIRD_PARTY_LICENSES.txt"
[ -f "$here/../apps/apple/ThirdParty/yt-dlp/LICENSE" ] && cp "$here/../apps/apple/ThirdParty/yt-dlp/LICENSE" "$RES/Notices/YT-DLP-LICENSE-Unlicense.txt"
echo "  notices: $(ls "$RES/Notices" | tr '\n' ' ')"
echo "  no tool is bundled: the app offers them as optional downloads (Setup, Settings > Media)"
