#!/bin/bash
# Release preflight for the media tools, run on the BUILT app (not on source folders):
#
#   scripts/check-media-tools.sh "<Browser Setu.app>" --team TEAMID [--readme README.md] [--cache DIR] [--hosted-verified] [--sources-published | --allow-unpublished-sources]
#
# yt-dlp and ffmpeg/ffprobe are optional downloads, so exits non-zero if the app carries ANY of them (a tool tree, a Helpers/yt-dlp folder, an executable named like one) or any other JavaScript
# runtime. It also requires: both manifests valid, free of stale text, and identical to what the verified signed + notarized cached packages generate (empty download address, or the hosted one
# with --hosted-verified); licence texts and source offers present; the yt-dlp JavaScript-runtime statement; the JavaScript challenge helper and plugin exactly as pinned, signed and sandbox-only,
# and paired with the verified yt-dlp package (unpacked from the cache); and a README "New in <version>" section that does not claim the tools are inside the app. All logic lives in
# media_tools_cache.py (check-app); this is only the entry point.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
APP="${1:?usage: check-media-tools.sh <app> --team TEAMID [--readme FILE] [--hosted-verified]}"; shift
exec python3 -I "$here/media_tools_cache.py" check-app "$APP" "$@"
