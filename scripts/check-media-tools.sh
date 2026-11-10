#!/bin/bash
# Release preflight for the media tools, run on the BUILT app (not on source folders):
#
#   scripts/check-media-tools.sh "<Browser Setu.app>" --team TEAMID [--readme README.md] [--hosted-verified]
#
# Exits non-zero unless both yt-dlp and ffmpeg/ffprobe are embedded and every claim about them is true of these bytes: manifests valid and free of stale text, the embedded files
# equal the manifests' tree digests, every Mach-O is Developer ID signed by the right Team with hardened runtime and a timestamp and the app's exact architecture, an Accepted
# notarization record is named, licence texts and source offers are present, the yt-dlp JavaScript-runtime limitation is stated, no unhosted download address is advertised, and the
# README's "New in <version>" section does not claim more than the app contains. All logic lives in media_tools_cache.py (check-app); this is only the entry point.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
APP="${1:?usage: check-media-tools.sh <app> --team TEAMID [--readme FILE] [--hosted-verified]}"; shift
exec python3 -I "$here/media_tools_cache.py" check-app "$APP" "$@"
