#!/bin/bash
# Builds the publisher's media-tools package from the pinned upstream tree: thin, sign every Mach-O inside-out, verify, zip, then compute the integrity values AFTER signing.
# It signs only when you give it an identity and never touches the app, the installed Browser Setu or ThirdParty/*/MANIFEST.json unless --write-manifest is given.
#
#   scripts/release-media-tools.sh --identity "Developer ID Application: NAME (TEAMID)" --team TEAMID --out DIR [--arch arm64] [--tool yt-dlp|ffmpeg] [--write-manifest]
#
# Notarization is a separate, manual step (xcrun notarytool submit DIR/<zip> --wait); this script prints the command.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
identity=""; team=""; out=""; arch="arm64"; write=0; tool="yt-dlp"
while [ $# -gt 0 ]; do case "$1" in
  --identity) identity="$2"; shift 2;; --team) team="$2"; shift 2;; --out) out="$2"; shift 2;; --arch) arch="$2"; shift 2;; --tool) tool="$2"; shift 2;; --write-manifest) write=1; shift;;
  *) echo "unknown option $1" >&2; exit 2;; esac; done
[ -n "$identity" ] && [ -n "$team" ] && [ -n "$out" ] || { echo "need --identity, --team and --out" >&2; exit 2; }
case "$tool" in yt-dlp|ffmpeg) ;; *) echo "unknown tool $tool" >&2; exit 2;; esac
tp="$here/../apps/apple/ThirdParty/$tool"
[ -d "$tp/bin/$tool" ] || { echo "build or fetch the tool first (scripts/fetch-bundled-tools.sh for yt-dlp, scripts/build-ffmpeg-minimal.sh $tp/bin/ffmpeg for ffmpeg)" >&2; exit 1; }
name=$(python3 -c "import json;print(json.load(open('$tp/MANIFEST.json'))['name'])"); ver=$(python3 -c "import json;print(json.load(open('$tp/MANIFEST.json'))['version'])")
exe=$(python3 -c "import json;print(json.load(open('$tp/MANIFEST.json'))['executable'])")
rm -rf "$out"; mkdir -p "$out/tree"; ditto "$tp/bin/$tool" "$out/tree"
# 1. thin each universal Mach-O to one architecture
find "$out/tree" -type f | while read -r f; do
  if file -b "$f" | grep -q "universal binary"; then lipo -thin "$arch" "$f" -output "$f.thin" && mv "$f.thin" "$f"; fi
done
# 1b. upstream flattens Python.framework into plain copies (Versions/Current is a folder, Python and Resources are files), which no signature can cover. Restore the standard layout
#     (Versions/Current -> <version>, Python and Resources as links) so the framework can be signed and verified as one bundle.
find "$out/tree" -type d -name "*.framework" | while read -r fw; do
  ver=$(ls "$fw/Versions" | grep -v '^Current$' | head -1); [ -n "$ver" ] || continue
  rm -rf "$fw/Versions/Current" "$fw/Python" "$fw/Resources" "$fw/Versions/$ver/_CodeSignature"
  ln -s "$ver" "$fw/Versions/Current"; ln -s Versions/Current/Python "$fw/Python"; ln -s Versions/Current/Resources "$fw/Resources"
done
# 2. sign inside-out: deepest paths first, the main program last; one file at a time (Python.framework cannot be signed as one bundle)
find "$out/tree" -type f ! -path "*.framework/*" | while read -r f; do if file -b "$f" | grep -q "Mach-O"; then echo "$f"; fi; done | awk '{print length($0) " " $0}' | sort -rn | cut -d' ' -f2- > "$out/macho.txt"
while read -r f; do [ "$f" = "$out/tree/$exe" ] && continue; codesign --force --timestamp --options runtime -s "$identity" "$f"; done < "$out/macho.txt"
find "$out/tree" -type d -name "*.framework" | awk '{print length($0) " " $0}' | sort -rn | cut -d' ' -f2- | while read -r fw; do codesign --force --timestamp --options runtime -s "$identity" "$fw"; done
codesign --force --timestamp --options runtime -s "$identity" "$out/tree/$exe"
# the framework bundles' own Mach-O files are checked too
find "$out/tree" -type f -path "*.framework/Versions/*" | while read -r f; do if file -b "$f" | grep -q "Mach-O"; then echo "$f"; fi; done >> "$out/macho.txt"
find "$out/tree" -type d -name "*.framework" >> "$out/macho.txt"
# 3. verify every file and its Team ID before anything is packaged
bad=0; while read -r f; do
  codesign --verify --strict "$f" || { echo "FAILED verify: $f" >&2; bad=1; }
  info=$(codesign -dv --verbose=2 "$f" 2>&1 || true)          # captured first: grep -q ending early would make codesign fail with SIGPIPE under pipefail
  printf '%s\n' "$info" | grep -qx "TeamIdentifier=$team" || { echo "WRONG TEAM: $f" >&2; bad=1; }
  printf '%s\n' "$info" | grep -q "(runtime)" || { echo "NO HARDENED RUNTIME: $f" >&2; bad=1; }
done < "$out/macho.txt"
[ $bad -eq 0 ] || { echo "verification failed; no package made" >&2; exit 1; }
# 4. package the tree's contents, then compute the integrity values from the SIGNED tree and the zip
zipfile="$out/$name-$ver-$arch.zip"; (cd "$out/tree" && zip -qry "$zipfile" .)
tree=$(python3 "$here/tree_digest.py" "$out/tree" | cut -d' ' -f1); sha=$(shasum -a 256 "$zipfile" | cut -d' ' -f1)
size=$(stat -f %z "$zipfile"); unpacked=$(find "$out/tree" -type f -exec stat -f %z {} + | awk '{s+=$1} END {print s}')
python3 - "$out/manifest-fragment.json" "$sha" "$tree" "$size" "$unpacked" "$arch" "$team" <<'PY'
import json,sys
o,sha,tree,size,unpacked,arch,team=sys.argv[1:]
json.dump({"sha256":sha,"treeSHA256":tree,"size":int(size),"unpackedBytes":int(unpacked),"architectures":[arch],"signaturePolicy":"teamID:"+team},open(o,"w"),indent=2)
PY
echo "package: $zipfile"; echo "integrity values (after signing): $out/manifest-fragment.json"
echo "next: xcrun notarytool submit \"$zipfile\" --keychain-profile <profile> --wait ; host the zip at the approved address; set sourceURL in MANIFEST.json"
if [ $write -eq 1 ]; then python3 - "$tp/MANIFEST.json" "$out/manifest-fragment.json" <<'PY'
import json,sys
m=json.load(open(sys.argv[1])); m.update(json.load(open(sys.argv[2]))); json.dump(m,open(sys.argv[1],"w"),indent=2); open(sys.argv[1],"a").write("\n")
PY
echo "MANIFEST.json updated (set sourceURL to the hosted zip)"; fi
