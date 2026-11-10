#!/bin/bash
# Builds the small fixture package the media-tools UI tests install (a tiny ad-hoc signed program pinned by tree digest), into the folder given. The UI test runner is sandboxed and cannot compile,
# so this runs first:   scripts/make-mediatools-ui-fixture.sh OUT && TEST_RUNNER_BS_MEDIATOOLS_FIXTURE=OUT xcodebuild test … -only-testing:BrowserSetuMacUITests/MediaToolsUITests
set -euo pipefail
# Xcode's scheme actions carry build-setting variables (deployment targets, SDK names) that make clang refuse to compile; run again with a clean environment.
if [ -z "${BS_CLEAN_ENV:-}" ]; then exec /usr/bin/env -i BS_CLEAN_ENV=1 PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" ${DEVELOPER_DIR:+DEVELOPER_DIR="$DEVELOPER_DIR"} /bin/bash "$0" "$@"; fi
here="$(cd "$(dirname "$0")" && pwd)"; out="${1:?output folder}"
arch=$(uname -m); [ "$arch" = "arm64" ] || arch=x86_64
rm -rf "$out"; mkdir -p "$out/tree/_internal"
printf '#include <stdio.h>\nint main(void){puts("1");return 0;}\n' > "$out/mini.c"
clang -arch "$arch" -o "$out/tree/mini" "$out/mini.c"; codesign --force -s - "$out/tree/mini"
printf lib > "$out/tree/_internal/lib.dat"
digest=$(python3 -I "$here/tree_digest.py" "$out/tree" | cut -d' ' -f1)
(cd "$out/tree" && zip -qry "$out/mini-1.zip" .)
sha=$(shasum -a 256 "$out/mini-1.zip" | cut -d' ' -f1); size=$(stat -f %z "$out/mini-1.zip")
python3 - "$out/manifest-fragment.json" "$sha" "$digest" "$size" "$arch" <<'PY'
import json,sys
o,sha,tree,size,arch=sys.argv[1:]
json.dump({"name":"mini","version":"1","executable":"mini","layout":"onedir","sha256":sha,"treeSHA256":tree,"size":int(size),"unpackedBytes":100000,"architectures":[arch],"signaturePolicy":"adhoc"},open(o,"w"))
PY
echo "$out"
