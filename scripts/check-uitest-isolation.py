#!/usr/bin/env python3
"""Proves a UI-test run left the person's own Browser Setu state untouched, and keeps the evidence even when the run is interrupted.

    python3 -I scripts/check-uitest-isolation.py [--label NAME] -- xcodebuild test-without-building ... -only-testing:...
    python3 -I scripts/check-uitest-isolation.py --compare EVIDENCE_DIR          check now against a saved "before" (a run that was killed, so its own "after" never happened)

Before the command starts, the real state is recorded to a new evidence folder and flushed to disk (default /private/tmp/bs-isolation-evidence/<time>-<label>, or $BS_ISOLATION_EVIDENCE).
After it ends (or on SIGINT, SIGTERM or SIGHUP, which are forwarded to the command and then still lead to the second record) the state is recorded again and compared. A SIGKILL cannot be caught, but the
"before" is already on disk, so `--compare` finishes the proof afterwards. It reads the person's files; it never writes, moves or deletes any of them. Run it with Browser Setu CLOSED.

What is recorded, for the app's bundle id and its test, runner and helper ids (com.browsersetu.mac, .tests, .uitests, .uitests.xctrunner, .jsc, .share):
  ~/Library/Preferences (the plist files, the ByHost ones, and any bs.* / bs-ui* file) and `defaults read` of each id
  ~/Library/WebKit, Caches, HTTPStorages, Saved Application State, Containers and Logs/DiagnosticReports entries of those ids
  ~/Library/Application Support/BrowserSetu* and "Browser Setu*"
  the per-user cache and temporary folders the system keeps outside the home (getconf DARWIN_USER_CACHE_DIR and DARWIN_USER_TEMP_DIR), entries of those ids
Each file is recorded with its size, modification time, inode and, up to 64 MB, a SHA-256 of its contents, so a change that keeps the time is still seen.
NOT covered: the Keychain (it is audited in the source, not read here), files outside the places above, and anything a process holds only in memory.
Exit status: 70 when the run changed the person's state (the launcher stops there), otherwise the command's own status.
"""
import hashlib, json, os, signal, subprocess, sys, time, difflib

HOME = os.path.expanduser("~")
BUNDLE = "com.browsersetu.mac"
IDS = [BUNDLE, BUNDLE + ".tests", BUNDLE + ".uitests", BUNDLE + ".uitests.xctrunner", BUNDLE + ".jsc", BUNDLE + ".share"]
EVIDENCE_ROOT = os.environ.get("BS_ISOLATION_EVIDENCE", "/private/tmp/bs-isolation-evidence")
HASH_LIMIT = 64 * 1024 * 1024

def record(path):
    try:
        st = os.lstat(path)
    except OSError:
        return None
    entry = {"size": st.st_size, "mtime_ns": st.st_mtime_ns, "inode": st.st_ino}
    if os.path.isfile(path) and not os.path.islink(path) and st.st_size <= HASH_LIMIT:
        try:
            h = hashlib.sha256()
            with open(path, "rb") as f:
                for chunk in iter(lambda: f.read(1 << 20), b""): h.update(chunk)
            entry["sha256"] = h.hexdigest()
        except OSError:
            entry["sha256"] = "unreadable"
    return entry

def tree(path, out):
    if not os.path.lexists(path): return
    e = record(path)
    if e: out[path] = e
    if os.path.isdir(path) and not os.path.islink(path):
        for base, dirs, files in os.walk(path):
            for name in files + dirs:
                p = os.path.join(base, name)
                e = record(p)
                if e: out[p] = e

def getconf(name):
    r = subprocess.run(["getconf", name], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else ""

def snapshot():
    snap, defaults = {}, {}
    lib = os.path.join(HOME, "Library")
    prefs = os.path.join(lib, "Preferences")
    for base in (prefs, os.path.join(prefs, "ByHost")):
        if not os.path.isdir(base): continue
        for name in sorted(os.listdir(base)):
            if any(name.startswith(i) for i in IDS) or name.startswith("bs.") or name.startswith("bs-ui"):
                tree(os.path.join(base, name), snap)
    for sub in ("WebKit", "Caches", "HTTPStorages", "Containers"):
        for i in IDS: tree(os.path.join(lib, sub, i), snap)
    for i in IDS: tree(os.path.join(lib, "Saved Application State", i + ".savedState"), snap)
    reports = os.path.join(lib, "Logs", "DiagnosticReports")
    if os.path.isdir(reports):
        for name in sorted(os.listdir(reports)):
            if name.startswith("Browser Setu") or name.startswith("BrowserSetu"): tree(os.path.join(reports, name), snap)
    support = os.path.join(lib, "Application Support")
    if os.path.isdir(support):
        for name in os.listdir(support):
            if name.lower().startswith("browsersetu") or name.lower().startswith("browser setu"): tree(os.path.join(support, name), snap)
    for conf in ("DARWIN_USER_CACHE_DIR", "DARWIN_USER_TEMP_DIR"):
        base = getconf(conf)
        if base and os.path.isdir(base):
            for i in IDS: tree(os.path.join(base, i), snap)
    for i in IDS:
        r = subprocess.run(["defaults", "read", i], capture_output=True, text=True)
        defaults[i] = r.stdout if r.returncode == 0 else ""
    return {"files": snap, "defaults": defaults}

RUNNER = os.path.join(HOME, "Library", "Containers", BUNDLE + ".uitests.xctrunner", "Data")

def tolerated(path):
    """The only places a UI-test run may change, named exactly. Each is test-owned or owned by the operating system, never the person's own browsing state.
    1. The test runner's own sandbox: its tmp folder (the relocated home `bs-ui-home` and the run's scratch files lives there) and its own network caches.
    2. The system's Metal shader cache for the app's bundle id (com.apple.metal, com.apple.metalfe): the GPU driver writes it whenever the app draws; it is outside the home folder and cannot be redirected.
    Anything else, including every preference, WebKit, Caches, HTTPStorages, Saved State and Application Support place of the app itself, still counts."""
    if path == os.path.join(RUNNER, "tmp") or path.startswith(os.path.join(RUNNER, "tmp") + os.sep): return "runner tmp (relocated home and scratch)"
    for sub in ("Caches", "HTTPStorages"):
        if path.startswith(os.path.join(RUNNER, "Library", sub, BUNDLE + ".uitests.xctrunner")): return "runner own " + sub
    # macOS writes a report here when the app under test crashes; it is a record of the crash (a test failure in itself), not app state. It is named in the summary so it is never hidden.
    if path.startswith(os.path.join(HOME, "Library", "Logs", "DiagnosticReports") + os.sep) and os.path.basename(path).startswith("Browser Setu") and path.endswith(".ips"): return "CRASH REPORT written by macOS (the app under test crashed)"
    cache = getconf("DARWIN_USER_CACHE_DIR").rstrip("/")
    if cache:
        for sub in ("com.apple.metal", "com.apple.metalfe"):
            if path.startswith(os.path.join(cache, BUNDLE, sub)): return "system Metal shader cache"
    return None

def diff(before, after):
    changed, allowed = [], {}
    b, a = before["files"], after["files"]
    for key in sorted(set(b) | set(a)):
        if b.get(key) != a.get(key):
            why = tolerated(key)
            if why:
                allowed[why] = allowed.get(why, 0) + 1
                continue
            kind = "added" if key not in b else ("removed" if key not in a else "changed")
            how = ""
            if kind == "changed":
                parts = [k for k in ("sha256", "size", "mtime_ns", "inode") if b[key].get(k) != a[key].get(k)]
                how = " (" + ", ".join(parts) + ")"
            changed.append(f"  {kind}: {key}{how}")
    lines = []
    for i in IDS:
        if before["defaults"].get(i) != after["defaults"].get(i):
            lines.append(f"  preferences of {i} differ:")
            lines += ["    " + l for l in difflib.unified_diff(before["defaults"].get(i, "").splitlines(), after["defaults"].get(i, "").splitlines(), lineterm="", n=0)][:40]
    return changed, lines, allowed

def save(path, obj):
    with open(path, "w") as f:
        json.dump(obj, f, indent=1, sort_keys=True); f.flush(); os.fsync(f.fileno())

def verdict(before, after, evidence, status, note=""):
    changed, pref_lines, allowed = diff(before, after)
    tolerated_note = "" if not allowed else " Tolerated (test-owned or OS-owned): " + "; ".join(f"{n} in {w}" for w, n in sorted(allowed.items())) + "."
    report = []
    if changed or pref_lines:
        report.append("ISOLATION CHECK FAILED: the run changed the person's own Browser Setu state:")
        report += changed[:200] + pref_lines
        if tolerated_note: report.append(" " + tolerated_note.strip())
        report.append(f"  evidence: {evidence}")
        text = "\n".join(report); print(text); open(os.path.join(evidence, "report.txt"), "w").write(text + "\n"); return 70
    msg = f"ISOLATION CHECK PASSED: {len(before['files'])} real files (contents hashed) and the preferences of {len(IDS)} ids are identical before and after the run (command exit status {status}).{tolerated_note}{note} evidence: {evidence}"
    print(msg); open(os.path.join(evidence, "report.txt"), "w").write(msg + "\n")
    return status if status > 0 else 0

def main(argv):
    if "--compare" in argv:
        evidence = argv[argv.index("--compare") + 1]
        before = json.load(open(os.path.join(evidence, "before.json")))
        after = snapshot(); save(os.path.join(evidence, "after-compare.json"), after)
        return verdict(before, after, evidence, 0, " (checked afterwards: the original run did not finish its own check)")
    if "--" not in argv: print(__doc__); return 2
    label = "run"
    if "--label" in argv: label = argv[argv.index("--label") + 1]
    cmd = argv[argv.index("--") + 1:]
    if subprocess.run(["pgrep", "-x", "Browser Setu"], capture_output=True).returncode == 0:
        print("Browser Setu is running: close it first (an open copy writes its own state)."); return 2
    evidence = os.path.join(EVIDENCE_ROOT, time.strftime("%Y%m%d-%H%M%S") + "-" + "".join(c if c.isalnum() or c in "-_" else "_" for c in label))
    os.makedirs(evidence, exist_ok=True)
    before = snapshot()
    save(os.path.join(evidence, "before.json"), before)
    save(os.path.join(evidence, "command.json"), {"command": cmd, "started": time.time()})
    print(f"isolation evidence: {evidence} (before-state saved: {len(before['files'])} files)", flush=True)
    child = subprocess.Popen(cmd)
    interrupted = []
    def forward(signum, frame):
        interrupted.append(signum)
        try: child.send_signal(signum)
        except OSError: pass
    for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP): signal.signal(s, forward)
    status = child.wait()
    for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP): signal.signal(s, signal.SIG_DFL)
    after = snapshot(); save(os.path.join(evidence, "after.json"), after)
    return verdict(before, after, evidence, status, " (interrupted by signal %s)" % interrupted[0] if interrupted else "")

sys.exit(main(sys.argv[1:]))
