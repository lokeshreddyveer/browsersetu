#!/bin/bash
# Fetches the pinned third-party tools named in apps/apple/ThirdParty/*/MANIFEST.json into their bin/ folders. It refuses anything whose SHA-256 differs from the manifest, and for an unpackaged
# tool it also checks the folder digest after unpacking. Nothing is installed system-wide and nothing is run. The result is what the app's build phase embeds.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/../apps/apple/ThirdParty"
fetch() {
  local dir="$1" name url sha tree out tmp
  name=$(python3 -c "import json;print(json.load(open('$dir/MANIFEST.json'))['name'])")
  url=$(python3 -c "import json;print(json.load(open('$dir/MANIFEST.json'))['sourceURL'])")
  sha=$(python3 -c "import json;print(json.load(open('$dir/MANIFEST.json'))['sha256'])")
  tree=$(python3 -c "import json;print(json.load(open('$dir/MANIFEST.json')).get('treeSHA256',''))")
  out="$dir/bin/$name"
  if [ -d "$out" ] && [ "$(python3 "$here/tree_digest.py" "$out" | cut -d' ' -f1)" = "$tree" ]; then echo "$name: already present and verified"; return; fi
  tmp="$(mktemp -d)"; trap "rm -rf '$tmp'" EXIT   # expanded now: the variable is local to this function and gone when the trap fires
  curl -fsSL -o "$tmp/asset" "$url"
  got=$(shasum -a 256 "$tmp/asset" | cut -d' ' -f1)
  if [ "$got" != "$sha" ]; then echo "$name: archive digest mismatch (got $got, expected $sha); refusing" >&2; exit 1; fi
  mkdir -p "$tmp/unpacked"; unzip -q "$tmp/asset" -d "$tmp/unpacked"
  gottree=$(python3 "$here/tree_digest.py" "$tmp/unpacked" | cut -d' ' -f1)
  if [ -n "$tree" ] && [ "$gottree" != "$tree" ]; then echo "$name: folder digest mismatch (got $gottree, expected $tree); refusing" >&2; exit 1; fi
  rm -rf "$out"; mkdir -p "$dir/bin"; mv "$tmp/unpacked" "$out"; echo "$name: fetched and verified"
}
for d in yt-dlp; do fetch "$d"; done
