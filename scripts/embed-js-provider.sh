#!/bin/bash
# Builds Browser Setu's own JavaScript challenge runner (setu-jsc, Apple JavaScriptCore) from apps/apple/Helpers/JSProvider, signs it, and installs it with its yt-dlp plugin into a built app, so
# yt-dlp can solve YouTube's n / signature challenges with no Deno, Node or download:
#
#   scripts/embed-js-provider.sh "<Browser Setu.app>" --identity <certificate SHA-1> --team TEAMID
#
# The helper is signed with Developer ID, the hardened runtime, a timestamp and ONLY the App Sandbox entitlement (no network, no files, no JIT): macOS itself confines it, and it refuses to run
# outside the sandbox. It is our own source (84 KB), so it is compiled here every release rather than cached; the app's notarization covers it. Run it BEFORE the app's final signature.
# Writes Resources/BundledJSProvider.json (digests the app checks before it ever lets yt-dlp load the plugin) and prints nothing but facts.
set -euo pipefail
APP="${1:?usage: embed-js-provider.sh <app> --identity <SHA-1> --team TEAMID}"; shift
IDENTITY=""; TEAM=""
while [ $# -gt 0 ]; do case "$1" in --identity) IDENTITY="$2"; shift 2;; --team) TEAM="$2"; shift 2;; *) echo "unknown option $1" >&2; exit 2;; esac; done
echo "$IDENTITY" | grep -Eq '^[0-9A-F]{40}$' || { echo "✘ --identity must be the certificate's SHA-1 fingerprint" >&2; exit 2; }
[ -n "$TEAM" ] || { echo "✘ --team is required" >&2; exit 2; }
here="$(cd "$(dirname "$0")" && pwd)"; SRC="$here/../apps/apple/Helpers/JSProvider"; CONTENTS="$APP/Contents"
[ -d "$CONTENTS/Resources" ] || { echo "✘ $CONTENTS/Resources not found" >&2; exit 1; }
main="$(ls "$CONTENTS/MacOS" | head -1)"; ARCH="$(lipo -archs "$CONTENTS/MacOS/$main")"
[ "$(echo "$ARCH" | wc -w | tr -d ' ')" = 1 ] || { echo "✘ the app is a universal build ($ARCH); build the helper per architecture" >&2; exit 1; }
tmp="$(mktemp -d "${TMPDIR:-/tmp}/setu-jsc.XXXXXX")"; trap 'rm -rf "$tmp"' EXIT
swiftc -O -target "$ARCH-apple-macos14.0" -o "$tmp/setu-jsc" "$SRC/setu-jsc.swift" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$SRC/Info.plist" || { echo "✘ the helper did not compile" >&2; exit 1; }
codesign --force --timestamp --options runtime --entitlements "$SRC/setu-jsc.entitlements" -s "$IDENTITY" "$tmp/setu-jsc"
codesign --verify --strict "$tmp/setu-jsc"
# the entitlements must be exactly the App Sandbox and nothing else
ents="$(codesign -d --entitlements - --xml "$tmp/setu-jsc" 2>/dev/null | python3 -c 'import sys,plistlib; d=sys.stdin.buffer.read(); print(sorted(plistlib.loads(d[d.index(b"<?xml"):]).keys()))')"
[ "$ents" = "['com.apple.security.app-sandbox']" ] || { echo "✘ unexpected entitlements on the helper: $ents" >&2; exit 1; }
# Self-tests on the freshly SIGNED helper (they run it under the real App Sandbox): handshake, a normal script, a broken script, and the three limits a hostile script would hit.
want="setu-jsc 1.0.0 protocol $(python3 -I "$here/media_tools_cache.py" plugin-compat "$SRC/yt_dlp_plugins/extractor/setu_jsc.py" | python3 -c 'import sys,json;print(json.load(sys.stdin)["helperProtocol"])')"
[ "$("$tmp/setu-jsc" --version)" = "$want" ] || { echo "✘ the helper's handshake is not '$want'" >&2; exit 1; }
[ "$(printf 'console.log(JSON.stringify({s:[1,2,3].map(x=>x*2), t:[typeof fetch,typeof setTimeout,typeof window,typeof require,typeof process,typeof WebAssembly]}))' | "$tmp/setu-jsc" -)" = '{"s":[2,4,6],"t":["undefined","undefined","undefined","undefined","undefined","undefined"]}' ] || { echo "✘ the helper's self-test failed" >&2; exit 1; }
expect_status() {   # name, expected exit status, script, [extra helper args]
  local name="$1" want="$2" script="$3"; shift 3; local got=0
  printf '%s' "$script" | "$tmp/setu-jsc" "$@" - >/dev/null 2>&1 || got=$?
  [ "$got" = "$want" ] || { echo "✘ helper self-test '$name': expected exit $want, got $got" >&2; exit 1; }
}
expect_status "broken script"    1   'nope()'
expect_status "wall-clock limit" 142 'while(true){}' --deadline 1
expect_status "memory limit"     5   'var a=[];for(;;){a.push(new Array(1e6).fill(1.5))}' --deadline 60
expect_status "output limit"     4   'for(;;){console.log("x".repeat(1e6))}' --deadline 60
expect_status "stderr limit"     4   'for(;;)console.error(1)' --deadline 60
expect_status "invalid deadline" 2   '1' --deadline 0
mkdir -p "$CONTENTS/Helpers"; rm -f "$CONTENTS/Helpers/setu-jsc"; cp "$tmp/setu-jsc" "$CONTENTS/Helpers/setu-jsc"; chmod 755 "$CONTENTS/Helpers/setu-jsc"
PLUG="$CONTENTS/Resources/YtDlpPlugins/setu/yt_dlp_plugins/extractor"; rm -rf "$CONTENTS/Resources/YtDlpPlugins"; mkdir -p "$PLUG"
cp "$SRC/yt_dlp_plugins/extractor/setu_jsc.py" "$PLUG/setu_jsc.py"
ytv="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['version'])" "$CONTENTS/Resources/BundledTools.json" 2>/dev/null || echo unknown)"
python3 - "$CONTENTS" "$ARCH" "$TEAM" "$ytv" "$here" <<'PY'
import hashlib, json, subprocess, sys
contents, arch, team, ytv, here = sys.argv[1:]
sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
compat = json.loads(subprocess.run([sys.executable, "-I", here + "/media_tools_cache.py", "plugin-compat", contents + "/Resources/YtDlpPlugins/setu/yt_dlp_plugins/extractor/setu_jsc.py"], capture_output=True, text=True, check=True).stdout)
tree = subprocess.run([sys.executable, "-I", here + "/tree_digest.py", contents + "/Resources/YtDlpPlugins"], capture_output=True, text=True, check=True).stdout.split()[0]
m = {"schemaVersion": 1, "name": "setu-jsc", "version": "1.0.0", "providerVersion": compat["provider"], "helperProtocol": compat["helperProtocol"], "helper": "Helpers/setu-jsc", "helperSHA256": sha(contents + "/Helpers/setu-jsc"),
     "pluginDirectory": "YtDlpPlugins", "plugin": "YtDlpPlugins/setu/yt_dlp_plugins/extractor/setu_jsc.py",
     "pluginSHA256": sha(contents + "/Resources/YtDlpPlugins/setu/yt_dlp_plugins/extractor/setu_jsc.py"), "pluginTreeSHA256": tree,
     "architectures": [arch], "signaturePolicy": "teamID:" + team, "entitlements": ["com.apple.security.app-sandbox"], "pinnedYtDlpVersion": ytv}
json.dump(m, open(contents + "/Resources/BundledJSProvider.json", "w"), indent=2); open(contents + "/Resources/BundledJSProvider.json", "a").write("\n")
print("  embedded setu-jsc 1.0.0 (" + arch + "), helper " + m["helperSHA256"][:12] + "…, plugin " + m["pluginSHA256"][:12] + "…, for yt-dlp " + ytv)
PY
