#!/bin/sh
# Downloads the pinned CEF (Chromium Embedded Framework) macOS arm64 "minimal" distribution
# into third_party/cef and verifies it against the SHA-1 published in CEF's build index.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CEF_VERSION="154.0.34+g14c5a08+chromium-154.0.8037.98"
NAME="cef_binary_${CEF_VERSION}_macosarm64_minimal"
DEST="$ROOT/third_party/cef"
[ -d "$DEST/Release" ] && { echo "CEF already present at $DEST"; exit 0; }
TMP="$(mktemp -d)"
ENC="$(printf '%s' "$NAME" | sed 's/+/%2B/g')"
curl -fL --retry 3 -o "$TMP/cef.tar.bz2" "https://cef-builds.spotifycdn.com/${ENC}.tar.bz2"
EXPECTED="$(curl -fsS "https://cef-builds.spotifycdn.com/${ENC}.tar.bz2.sha1")"
ACTUAL="$(shasum -a 1 "$TMP/cef.tar.bz2" | cut -d' ' -f1)"
[ "$EXPECTED" = "$ACTUAL" ] || { echo "SHA-1 mismatch: expected $EXPECTED got $ACTUAL" >&2; exit 1; }
mkdir -p "$DEST"
tar -xjf "$TMP/cef.tar.bz2" -C "$DEST" --strip-components=1
rm -rf "$TMP"
echo "CEF $CEF_VERSION installed at $DEST"
