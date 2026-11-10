#!/bin/bash
# Runs the player's controls against a REAL video in the iPhone simulator (where video plays; the sandboxed Mac test process cannot load media) and checks what the player reports.
# Needs: a simulator with the debug build of the iOS app installed (xcodebuild -scheme BrowserSetuiOS -destination 'id=<udid>' build, then simctl install), and Python 3.
# Usage: scripts/player-selftest.sh <simulator udid> <bundle id, default com.browsersetu.ios>
set -u
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(ls -d /Applications/Xcode*.app | head -1)/Contents/Developer}"
UDID="${1:?simulator udid}"; BUNDLE="${2:-com.browsersetu.ios}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; FIX="$ROOT/apps/apple/Tests/Fixtures/video"; LOG=/tmp/claude/audit/inset.log
mkdir -p /tmp/claude/audit; rm -f "$LOG"
( cd "$FIX" && python3 -m http.server 8766 >/dev/null 2>&1 & echo $! > /tmp/claude/player-selftest.pid ); sleep 1
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null
SIMCTL_CHILD_BS_PLAYER_TEST=1 SIMCTL_CHILD_BS_NO_TIP=1 SIMCTL_CHILD_BS_SKIP_SETUP=1 SIMCTL_CHILD_BS_PHONE_PRESET=bottomBar \
  SIMCTL_CHILD_BS_OPEN_URL="http://127.0.0.1:8766/index.html" xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null
for _ in $(seq 1 120); do grep -q "PLAYER done" "$LOG" 2>/dev/null && break; sleep 2; done
kill "$(cat /tmp/claude/player-selftest.pid)" 2>/dev/null
python3 - "$LOG" <<'PY'
import re, sys
lines = [l for l in open(sys.argv[1]).read().splitlines() if l.startswith("PLAYER")]
def field(line, name):
    m = re.search(name + r"=([^ ]+)", line); return m.group(1) if m else None
def step(name):
    for l in lines:
        if l.startswith("PLAYER " + name + ":"): return l
    return ""
fails = []
def check(ok, what):
    print(("PASS  " if ok else "FAIL  ") + what)
    if not ok: fails.append(what)
start = next((l for l in lines if l.startswith("PLAYER start")), "")
check("seek=0.0...90.0" in start and "canSeek=true" in start, "the clip is found, 90 s long, and can be moved through")
check("chapters=[\"Start\", \"Middle\", \"End\"]" in start, "its three chapters are read")
p = step("play"); check("problem=none" in p and "paused=false" in p and float(field(p, "t") or 0) > 1.5, "Play starts real playback (position moved on by > 1.5 s)")
check("paused=true" in step("pause"), "Pause stops it")
paused_at = float(field(step("pause"), "t") or 0)
check(abs(float(field(step("seekBy +10"), "t") or 0) - (paused_at + 10)) < 0.7, "skipping 10 s lands 10 s on from where it was paused (%.2f)" % paused_at)
d = [l for l in lines if "frame delta" in l]
delta = float(d[0].split("=")[1].split()[0]) if d else -1
check(abs(delta - 1/30) < 0.01, "a frame step moves by 1/30 s (%.4f s): a fixed time step, NOT a frame (the clip has 10 pictures a second)" % delta)
check("rate=1.25" in step("speedBy +0.25"), "speed +0.05-style step: 1.25x")
check("tracks=[true]" in step("subtitle 0"), "subtitles can be turned on")
check("no other audio" in step("audioTrack 1"), "audio-track choice says there is none to choose")
ab = step("markB"); check("ab=Optional" in ab and "-Optional" in ab, "A and B are both set")
rep = step("play (repeat A-B)"); t = float(field(rep, "t") or 0)
a = re.search(r"ab=Optional\(([0-9.]+)\)-Optional\(([0-9.]+)\)", rep)
check(bool(a) and float(a.group(1)) - 0.3 <= t <= float(a.group(2)) + 0.6, "A-B repeat kept playback inside A..B after 7.5 s of video time (position %.2f, range %s)" % (t, a.groups() if a else None))
check("ab=nil-nil" in step("clearAB"), "clearing A-B works")
check("loop=true" in step("loop on"), "repeat-this-video turns on")
check("fit=cover" in step("fit cover"), "fit: fill")
check("contrast: 1.2" in step("picture contrast"), "picture contrast +0.2")
check("focus=true" in step("focus on") and "focus=false" in step("focus off"), "focus mode on and off")
check("theater=true" in step("theater on") and "theater=false" in step("theater off"), "theater mode on and off")
tr = next((l for l in lines if "transcript" in l), ""); check("4 lines" in tr, "the transcript has the 4 subtitle lines")
cap = next((l for l in lines if "capture notice" in l), ""); check("Picture copied" in cap, "a picture of the video is copied")
print("\n%d checks failed" % len(fails) if fails else "\nall checks passed")
sys.exit(1 if fails else 0)
PY
