#!/bin/sh
# Rust -> Swift smoke test: build core, generate bindings, compile and run a Swift caller.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)"
cd "$ROOT/core"
cargo build -p browser-ffi
LIB=target/debug/libbrowser_core.dylib
cargo run -q -p browser-ffi --bin uniffi-bindgen -- generate --library "$LIB" --language swift --out-dir "$OUT"
cat > "$OUT/main.swift" <<'SWIFT'
let core = try BrowserCore.inMemory()
let p = core.createTab(url: "about:blank", private: true)
let n = core.createTab(url: "about:blank", private: false)
try core.commitNavigation(tabId: p.id, url: "https://secret.example/", title: "S")
try core.commitNavigation(tabId: n.id, url: "https://open.example/", title: "O")
let urls = try core.recentHistory(limit: 10).map(\.url)
precondition(urls == ["https://open.example/"])
precondition(evaluateNavigation(url: "javascript:alert(1)", mainFrame: true) == .deny)
if case .search(let u)? = resolveInput(input: "rust lang", searchTemplate: defaultSearchTemplate()) { precondition(u.contains("rust+lang")) } else { preconditionFailure() }
do { try core.closeTab(tabId: 9999); preconditionFailure("expected error") }
catch CoreError.TabNotFound { }
print("rust-swift ok")
SWIFT
cd "$OUT"
swiftc -o smoke -Xcc -fmodule-map-file="$OUT/browser_coreFFI.modulemap" -I "$OUT" \
  -L "$ROOT/core/target/debug" -lbrowser_core browser_core.swift main.swift
DYLD_LIBRARY_PATH="$ROOT/core/target/debug" ./smoke
