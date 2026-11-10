#!/bin/bash
# Builds the small fixture package the media processing tool's UI tests install (two tiny ad-hoc signed stand-in programs named ffmpeg and ffprobe, pinned by tree digest), into the folder given.
# The stand-ins are not started by the installer in those tests (-FFmpegToolsFixtureSkipLaunch); real FFmpeg processing is covered by the unit tests and by the -FFmpegDevTool UI test. Run it with bash:
#   bash scripts/make-ffmpegtools-ui-fixture.sh OUT
set -euo pipefail
# Xcode's scheme actions carry build-setting variables that make clang refuse to compile; run again with a clean environment.
if [ -z "${BS_CLEAN_ENV:-}" ]; then exec /usr/bin/env -i BS_CLEAN_ENV=1 PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" ${DEVELOPER_DIR:+DEVELOPER_DIR="$DEVELOPER_DIR"} /bin/bash "$0" "$@"; fi
here="$(cd "$(dirname "$0")" && pwd)"; out="${1:?output folder}"
arch=$(uname -m); [ "$arch" = "arm64" ] || arch=x86_64
# Only ever replaces its own earlier output: a folder that is not empty and was not made by this script is refused.
if [ -e "$out" ] && [ -n "$(ls -A "$out" 2>/dev/null)" ] && [ ! -f "$out/manifest-fragment.json" ]; then echo "refusing to replace $out: it is not a fixture folder" >&2; exit 1; fi
rm -rf "$out"; mkdir -p "$out/tree"
printf '#include <stdio.h>\nint main(void){puts("ffmpeg version 9.0.2");return 0;}\n' > "$out/mini.c"
clang -arch "$arch" -o "$out/tree/ffmpeg" "$out/mini.c"; codesign --force -s - "$out/tree/ffmpeg"
cp "$out/tree/ffmpeg" "$out/tree/ffprobe"; codesign --force -s - "$out/tree/ffprobe"
digest=$(python3 -I "$here/tree_digest.py" "$out/tree" | cut -d' ' -f1)
(cd "$out/tree" && zip -qry "$out/ffmpeg-9.0.2.zip" .)
sha=$(shasum -a 256 "$out/ffmpeg-9.0.2.zip" | cut -d' ' -f1); size=$(stat -f %z "$out/ffmpeg-9.0.2.zip")
python3 - "$out/manifest-fragment.json" "$sha" "$digest" "$size" "$arch" <<'PY'
import json,sys
o,sha,tree,size,arch=sys.argv[1:]
json.dump({"name":"ffmpeg","version":"9.0.2","executable":"ffmpeg","layout":"flat","sourceURL":"https://github.com/browsersetu/fixture/releases/download/9.0.2/ffmpeg-9.0.2.zip","sha256":sha,"treeSHA256":tree,"size":int(size),"unpackedBytes":100000,"architectures":[arch],"signaturePolicy":"adhoc"},open(o,"w"))
PY
echo "$out"
