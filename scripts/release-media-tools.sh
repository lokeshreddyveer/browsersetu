#!/bin/bash
# Builds the publisher's media-tools packages (yt-dlp, ffmpeg + ffprobe): thin, sign every Mach-O inside-out with Developer ID, verify, zip, notarize, and keep the result in a persistent
# content-addressed cache so an unchanged tool is NEVER signed or notarized twice. Manifests are not edited by hand: they are generated from the cached, verified package
# (scripts/media_tools_cache.py manifest) when the app is assembled (scripts/embed-media-manifests.sh; no tool is embedded in the app).
#
#   scripts/release-media-tools.sh --ensure --identity <40-hex certificate SHA-1> --team TEAMID --notary-profile PROFILE [--tool yt-dlp|ffmpeg|all] [--cache DIR]
#       Reuses the cached package if its key (version, architecture, Team, unsigned tree, packaging recipe) is unchanged AND it re-verifies from its bytes
#       (digests, every signature, Team ID, hardened runtime, chain, architecture, an Accepted notarization record for exactly that zip). Otherwise rebuilds,
#       submits to Apple, requires "Accepted", and caches. Prints  ENTRY=<cache entry>  per tool. Fails closed on any doubt.
#   scripts/release-media-tools.sh --identity <name or SHA-1> --team TEAMID --out DIR [--arch arm64] [--tool yt-dlp|ffmpeg]
#       Builds and signs one package into DIR without notarizing or caching (for experiments; the release uses --ensure).
#
# The signing identity should be given as the certificate's SHA-1 fingerprint (a team can own several certificates with the same name; the name is then ambiguous).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
identity=""; team=""; out=""; arch="arm64"; tool="yt-dlp"; ensure=0; profile="${NOTARY_PROFILE:-}"; cache="${MEDIA_TOOLS_CACHE:-$HOME/Library/Caches/BrowserSetu/media-tools}"; online=""
while [ $# -gt 0 ]; do case "$1" in
  --identity) identity="$2"; shift 2;; --team) team="$2"; shift 2;; --out) out="$2"; shift 2;; --arch) arch="$2"; shift 2;; --tool) tool="$2"; shift 2;;
  --ensure) ensure=1; shift;; --notary-profile) profile="$2"; shift 2;; --cache) cache="$2"; shift 2;; --online) online=1; shift;;
  *) echo "unknown option $1" >&2; exit 2;; esac; done
[ -n "$identity" ] && [ -n "$team" ] || { echo "need --identity and --team" >&2; exit 2; }
case "$tool" in yt-dlp|ffmpeg|deno|all) ;; *) echo "unknown tool $tool" >&2; exit 2;; esac     # "all" is yt-dlp and ffmpeg only: the tools every release embeds. deno is optional and is built only when asked for by name.
cachepy="$here/media_tools_cache.py"

if [ $ensure -eq 1 ]; then
  [ -n "$profile" ] || { echo "--ensure needs --notary-profile (or NOTARY_PROFILE)" >&2; exit 2; }
  echo "$identity" | grep -Eq '^[0-9A-F]{40}$' || { echo "✘ --ensure needs the certificate's SHA-1 fingerprint (40 hex digits), not a name: names can be ambiguous" >&2; exit 2; }
  line="$(security find-identity -v -p codesigning | grep "$identity" | head -1 || true)"
  case "$line" in *'"Developer ID Application: '*"($team)\""*) ;; *) echo "✘ $identity is not a valid 'Developer ID Application' certificate of team $team in this keychain. Nothing was signed." >&2; exit 1;; esac
  if [ "$tool" = all ]; then for t in yt-dlp ffmpeg; do "$0" --ensure --identity "$identity" --team "$team" --notary-profile "$profile" --cache "$cache" --arch "$arch" --tool "$t" ${online:+--online}; done; exit 0; fi
  set +e; entry="$(python3 -I "$cachepy" lookup --tool "$tool" --arch "$arch" --team "$team" --cache "$cache" ${online:+--online "$profile"})"; rc=$?; set -e
  if [ $rc -eq 0 ]; then echo "▸ $tool: reusing the verified signed + notarized package (nothing signed or submitted)"; echo "ENTRY=$entry"; exit 0; fi
  [ $rc -eq 3 ] || [ $rc -eq 4 ] || { echo "✘ cache lookup failed unexpectedly (exit $rc)" >&2; exit 1; }
  echo "▸ $tool: building, signing and notarizing (inputs changed or no valid cached package)"
  out="$(mktemp -d "${TMPDIR:-/tmp}/media-tools-build.XXXXXX")"; trap 'rm -rf "$out"' EXIT
fi
[ -n "$out" ] || { echo "need --out DIR" >&2; exit 2; }
case "$tool" in yt-dlp|ffmpeg|deno) ;; *) echo "--tool all needs --ensure" >&2; exit 2;; esac
# Per-tool entitlements (Deno's V8 needs the JIT ones under the hardened runtime; yt-dlp and ffmpeg need none). Empty means no --entitlements argument at all.
ENT=""; [ "$tool" = deno ] && ENT="$here/media-tools-entitlements/deno.entitlements"

tp="$here/../apps/apple/ThirdParty/$tool"
[ -d "$tp/bin/$tool" ] || { echo "build or fetch the tool first (scripts/fetch-bundled-tools.sh for yt-dlp, scripts/build-ffmpeg-minimal.sh $tp/bin/ffmpeg for ffmpeg)" >&2; exit 1; }
python3 -I "$cachepy" inputs --tool "$tool" || exit 1     # the unsigned tree on disk must be exactly what the pins describe
name=$(python3 -c "import json;print(json.load(open('$tp/MANIFEST.json'))['name'])"); ver=$(python3 -c "import json;print(json.load(open('$tp/MANIFEST.json'))['version'])")
exe=$(python3 -c "import json;print(json.load(open('$tp/MANIFEST.json'))['executable'])")
rm -rf "$out"; mkdir -p "$out/tree"; ditto "$tp/bin/$tool" "$out/tree"
# RECIPE-BEGIN  (the cache key fingerprints everything between this line and RECIPE-END: change a step here and every cached package is rebuilt)
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
while read -r f; do [ "$f" = "$out/tree/$exe" ] && continue; codesign --force --timestamp --options runtime ${ENT:+--entitlements "$ENT"} -s "$identity" "$f"; done < "$out/macho.txt"
find "$out/tree" -type d -name "*.framework" | awk '{print length($0) " " $0}' | sort -rn | cut -d' ' -f2- | while read -r fw; do codesign --force --timestamp --options runtime ${ENT:+--entitlements "$ENT"} -s "$identity" "$fw"; done
codesign --force --timestamp --options runtime ${ENT:+--entitlements "$ENT"} -s "$identity" "$out/tree/$exe"
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
# RECIPE-END
tree=$(python3 -I "$here/tree_digest.py" "$out/tree" | cut -d' ' -f1); sha=$(shasum -a 256 "$zipfile" | cut -d' ' -f1)
size=$(stat -f %z "$zipfile"); unpacked=$(find "$out/tree" -type f -exec stat -f %z {} + | awk '{s+=$1} END {print s}')
python3 - "$out/manifest-fragment.json" "$sha" "$tree" "$size" "$unpacked" "$arch" "$team" <<'PY'
import json,sys
o,sha,tree,size,unpacked,arch,team=sys.argv[1:]
json.dump({"sha256":sha,"treeSHA256":tree,"size":int(size),"unpackedBytes":int(unpacked),"architectures":[arch],"signaturePolicy":"teamID:"+team},open(o,"w"),indent=2)
PY
echo "package: $zipfile"; echo "integrity values (after signing): $out/manifest-fragment.json"

if [ $ensure -eq 1 ]; then
  echo "▸ $tool: submitting to Apple notary service (waits)"
  res="$(xcrun notarytool submit "$zipfile" --keychain-profile "$profile" --wait --output-format json)" || { echo "$res" >&2; echo "✘ notarization submission failed" >&2; exit 1; }
  sid="$(printf '%s' "$res" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))')"; st="$(printf '%s' "$res" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("status",""))')"
  if [ "$st" != "Accepted" ]; then
    echo "✘ Apple answered '$st' for submission $sid. Nothing was cached. Details:" >&2; xcrun notarytool log "$sid" --keychain-profile "$profile" >&2 || true; exit 1
  fi
  entry="$(python3 -I "$cachepy" store --tool "$tool" --arch "$arch" --team "$team" --cache "$cache" --build "$out" --submission "$sid" --status "$st" --profile "$profile" --signer "$identity")"
  echo "▸ $tool: notarized (submission $sid) and cached"; echo "ENTRY=$entry"
else
  echo "next: scripts/release-media-tools.sh --ensure ...  (notarizes and caches); this build is not cached and is not releasable"
fi
