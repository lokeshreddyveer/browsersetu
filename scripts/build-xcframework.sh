#!/bin/sh
# Builds the Rust core for macOS + iOS (device, simulator) into an XCFramework and
# generates the Swift bindings used by the Apple apps.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/core"
OUT="$ROOT/apps/apple/Generated"
export PATH="$HOME/.cargo/bin:$PATH"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export MACOSX_DEPLOYMENT_TARGET=14.0 IPHONEOS_DEPLOYMENT_TARGET=17.0
TARGETS="aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim"
cd "$CORE"
for t in $TARGETS; do
  cargo build --release --locked -p browser-ffi --target "$t"
done
rm -rf "$OUT" && mkdir -p "$OUT/headers"
cargo build -q --locked -p browser-ffi
cargo run -q --locked -p browser-ffi --bin uniffi-bindgen -- generate \
  --library target/debug/libbrowser_core.dylib --language swift --out-dir "$OUT/bindings"
mv "$OUT/bindings/browser_core.swift" "$OUT/browser_core.swift"
mv "$OUT/bindings/browser_coreFFI.h" "$OUT/headers/"
printf 'module browser_coreFFI {\n    header "browser_coreFFI.h"\n    export *\n}\n' > "$OUT/headers/module.modulemap"
rm -rf "$OUT/bindings"
xcodebuild -create-xcframework \
  -library "target/aarch64-apple-darwin/release/libbrowser_core.a" -headers "$OUT/headers" \
  -library "target/aarch64-apple-ios/release/libbrowser_core.a" -headers "$OUT/headers" \
  -library "target/aarch64-apple-ios-sim/release/libbrowser_core.a" -headers "$OUT/headers" \
  -output "$OUT/BrowserCore.xcframework"
# What this framework was built from, so a release can show it was not left over from older sources.
( cd "$ROOT" && find core -path core/target -prune -o \( -name '*.rs' -o -name 'Cargo.toml' -o -name 'Cargo.lock' -o -name 'rust-toolchain.toml' \) -type f -print | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256 | cut -d' ' -f1 ) > "$OUT/CORE_SOURCE_HASH"
rustc --version >> "$OUT/CORE_SOURCE_HASH"
echo "built $OUT"
