#!/bin/sh
# Launches the real, normally started Debug app with -SandboxProbe and checks sandbox enforcement.
# Run it on a container no Xcode test session has touched: after `xcodebuild test`, macOS leaves the
# test-host bundle id able to read Documents/Desktop. Build with a throwaway id to get a clean container:
#   xcodebuild ... PRODUCT_BUNDLE_IDENTIFIER=com.browsersetu.probe build
#   scripts/sandbox-check.sh "<path>/Browser Setu.app" com.browsersetu.probe
set -eu
APP="${1:?usage: sandbox-check.sh path/to/Browser Setu.app [bundle-id]}"
ID="${2:-com.browsersetu.mac}"
OUT="$HOME/Library/Containers/$ID/Data/tmp/probe.txt"
rm -f "$OUT"
open -W "$APP" --args -SandboxProbe YES || true
sleep 1
cat "$OUT"; echo
grep -q "^Documents: blocked" "$OUT" && grep -q "^Desktop: blocked" "$OUT" \
  && grep -q "^write outside container: blocked" "$OUT" \
  && grep -q "Containers/$ID" "$OUT" && echo "SANDBOX ENFORCED" || { echo "SANDBOX CHECK FAILED"; exit 1; }
