#!/bin/sh
# Runs the keyboard-driven UI tests only after the Mac has been idle. The tests also refuse to type unless
# Browser Setu is the frontmost app (they skip instead), so keystrokes cannot land in another app.
set -u
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDLE_NEEDED="${IDLE_NEEDED:-120}"
idle() { ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}'; }

echo "waiting for $IDLE_NEEDED s of inactivity (up to 40 min)..."
waited=0
while [ "$(idle)" -lt "$IDLE_NEEDED" ]; do
  sleep 10; waited=$((waited + 10))
  [ "$waited" -ge 2400 ] && { echo "NOT RUN: the Mac was never idle long enough"; exit 2; }
done

curl -s -m 3 http://127.0.0.1:18765/page >/dev/null || (python3 "$ROOT/scripts/testserver.py" 18765 >/dev/null 2>&1 &)
sleep 1
cd "$ROOT/apps/apple"
xcodebuild -project BrowserSetu.xcodeproj -scheme BrowserSetuMac -derivedDataPath "${TMPDIR:-/tmp}/dd" \
  test -only-testing:BrowserSetuMacUITests > "${TMPDIR:-/tmp}/ui-idle.log" 2>&1 &
XB=$!
wait "$XB"; RC=$?
pkill -f testserver.py; pkill -f "Browser Setu"
grep -E "Tests.swift.*error|' (failed|passed)|Executed [0-9]+ tests|TEST (SUCCEEDED|FAILED)" "${TMPDIR:-/tmp}/ui-idle.log" | sed 's/^.*Tests[. ]//' | cut -c1-300 | sort -u
exit $RC
