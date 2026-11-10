#!/usr/bin/env python3
"""Tests of the real setu-jsc helper binary: protocol, limits, hostile scripts, concurrency, fail-closed behaviour, and the sandbox state of the RUNNING process.

The helper is built from source exactly as scripts/embed-js-provider.sh builds it (same flags, embedded Info.plist, hardened runtime, the App Sandbox entitlement only) and signed with the
Developer ID certificate if the keychain has one, else ad hoc. Set BS_JSC_HELPER to test an already-built helper (for example the one inside a built app).
Run:  python3 -I -m unittest discover -s scripts/tests -p 'test_js_helper.py' -v
"""
import ctypes, ctypes.util, json, os, plistlib, re, shutil, signal, subprocess, sys, tempfile, threading, time, unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SRC = os.path.join(ROOT, "apps", "apple", "Helpers", "JSProvider")
HOME = os.path.expanduser("~")


def developer_id():
    out = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"], capture_output=True, text=True).stdout
    m = re.search(r"([0-9A-F]{40}) \"Developer ID Application", out)
    return m.group(1) if m else "-"


def build(dest, sandbox=True):
    exe = os.path.join(dest, "setu-jsc" if sandbox else "setu-jsc-unsandboxed")
    subprocess.run(["swiftc", "-O", "-target", "arm64-apple-macos14.0", "-o", exe, os.path.join(SRC, "setu-jsc.swift"), "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist", "-Xlinker", os.path.join(SRC, "Info.plist")], check=True, capture_output=True)
    cmd = ["codesign", "--force", "--options", "runtime", "-s", developer_id()]
    if sandbox:
        cmd += ["--entitlements", os.path.join(SRC, "setu-jsc.entitlements")]
    subprocess.run(cmd + [exe], check=True, capture_output=True)
    return exe


class HelperTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="jsh-")
        cls.helper = os.environ.get("BS_JSC_HELPER") or build(cls.tmp)
        cls.unsandboxed = None if os.environ.get("BS_JSC_HELPER") else build(cls.tmp, sandbox=False)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def run_js(self, script, *extra, exe=None, timeout=60, data=None):
        p = subprocess.run([exe or self.helper, *extra, "-"], input=data if data is not None else script.encode(), capture_output=True, timeout=timeout)
        return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")

    # ---- protocol -------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    def test_handshake(self):
        p = subprocess.run([self.helper, "--version"], capture_output=True, text=True)
        self.assertRegex(p.stdout, r"^setu-jsc \d+\.\d+\.\d+ protocol 1\n$"); self.assertEqual(p.returncode, 0)

    def test_arguments_are_strict(self):
        for args in (["--script", "/etc/hosts"], ["--deadline", "0", "-"], ["--deadline", "301", "-"], ["--deadline", "x", "-"], ["-", "extra"], ["/etc/passwd"], []):
            p = subprocess.run([self.helper, *args], input=b"console.log(1)", capture_output=True)
            self.assertIn(p.returncode, (2,), args)
            self.assertEqual(p.stdout, b"", args)

    def test_a_normal_script_runs_and_unicode_survives(self):
        rc, out, err = self.run_js('console.log(JSON.stringify({a:[1,2,3].map(x=>x*2), s:"héllo ✓ 😀"}))')
        self.assertEqual((rc, err), (0, "")); self.assertEqual(json.loads(out), {"a": [2, 4, 6], "s": "héllo ✓ 😀"})

    def test_invalid_utf8_and_oversized_scripts_are_refused(self):
        rc, out, err = self.run_js("", data=b"console.log(1);\xff\xfe")
        self.assertEqual(rc, 2); self.assertIn("[input]", err)
        rc, out, err = self.run_js("", data=b"/*" + b"x" * ((16 << 20) + 10) + b"*/")
        self.assertEqual(rc, 2); self.assertIn("[input]", err); self.assertEqual(out, "")

    # ---- hostile scripts ------------------------------------------------------------------------------------------------------------------------------------------------------------------
    def test_there_is_no_host_api_to_reach_anything(self):
        names = ["fetch", "XMLHttpRequest", "WebSocket", "setTimeout", "setInterval", "setImmediate", "queueMicrotask_", "window", "document", "navigator", "location", "require", "process",
                 "Buffer", "module", "exports", "importScripts", "postMessage", "localStorage", "indexedDB", "WebAssembly", "Deno", "Bun", "os", "fs", "$", "readFile", "load", "print", "read"]
        rc, out, err = self.run_js("console.log(JSON.stringify(%s.filter(n => typeof globalThis[n] !== 'undefined')))" % json.dumps(names))
        self.assertEqual(rc, 0); self.assertEqual(json.loads(out), [], f"unexpected host objects: {out}")

    def test_dynamic_import_and_eval_tricks_reach_nothing(self):
        script = r'''
        var r = {};
        import("fs").then(() => console.log(JSON.stringify({imported: true})), e => console.log(JSON.stringify({importRejected: String(e).slice(0, 40)})));
        r.fn = (new Function("return typeof require + typeof process + typeof fetch"))();
        r.eval = (0, eval)("typeof process + typeof require + typeof XMLHttpRequest");
        console.log(JSON.stringify(r));'''
        rc, out, err = self.run_js(script)
        lines = [json.loads(l) for l in out.splitlines()]
        self.assertEqual(rc, 0)
        self.assertEqual(lines[0], {"fn": "undefinedundefinedundefined", "eval": "undefinedundefinedundefined"})
        self.assertTrue(any("importRejected" in l for l in lines[1:]) and not any(l.get("imported") for l in lines), "dynamic import() cannot load anything")

    def test_syntax_errors_and_exceptions_are_classified(self):
        for script, label in (("var = ;", "syntax"), ("throw new Error('boom')", "throw"), ("null.x", "typeerror")):
            rc, out, err = self.run_js(script)
            self.assertEqual(rc, 1, label); self.assertIn("[js-error]", err); self.assertLess(len(err), 400)

    def test_deep_recursion_is_an_error_not_a_crash(self):
        rc, out, err = self.run_js("function f(){return f()+1} f()")
        self.assertEqual(rc, 1); self.assertIn("[js-error]", err)

    def test_an_infinite_loop_is_ended_by_the_wall_clock_limit(self):
        t = time.time(); rc, out, err = self.run_js("while(true){}", "--deadline", "2")
        self.assertEqual(rc, -signal.SIGALRM); self.assertLess(time.time() - t, 6)

    def test_a_catch_loop_cannot_swallow_the_deadline(self):
        t = time.time(); rc, out, err = self.run_js("for(;;){ try { while(true){} } catch(e) {} }", "--deadline", "2")
        self.assertEqual(rc, -signal.SIGALRM); self.assertLess(time.time() - t, 6)

    def test_memory_exhaustion_is_ended_by_the_memory_limit(self):
        t = time.time(); rc, out, err = self.run_js("var a=[];for(;;){a.push(new Array(1e6).fill(1.5))}", "--deadline", "100", timeout=100)
        self.assertEqual(rc, 5); self.assertIn("[memory-limit]", err); self.assertLess(time.time() - t, 60)

    def test_output_flooding_is_ended_by_the_output_limit(self):
        rc, out, err = self.run_js("for(;;){console.log('x'.repeat(1e6))}", "--deadline", "100", timeout=100)
        self.assertEqual(rc, 4); self.assertIn("[output-limit]", err); self.assertLessEqual(len(out), (8 << 20) + 1_000_002)

    def test_stderr_output_is_short_and_labelled(self):
        rc, out, err = self.run_js("console.error('x'.repeat(10000)); console.log('ok')")
        self.assertEqual(rc, 0); self.assertTrue(err.startswith("setu-jsc: [js-log] ")); self.assertLess(len(err), 400)

    def test_concurrent_runs_do_not_interfere(self):
        results = []
        def one(i):
            results.append(self.run_js(f"var s=0;for(var i=0;i<2e6;i++)s+=i%7;console.log({i}+':'+s)"))
        threads = [threading.Thread(target=one, args=(i,)) for i in range(6)]
        [t.start() for t in threads]; [t.join() for t in threads]
        self.assertEqual(sorted(r[1].strip() for r in results), sorted(f"{i}:{sum(j % 7 for j in range(2000000))}" for i in range(6)))
        self.assertTrue(all(r[0] == 0 for r in results))

    def test_stderr_flooding_is_capped(self):
        t = time.time(); p = subprocess.Popen([self.helper, "--deadline", "30", "-"], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        p.stdin.write(b"for(;;)console.error(1)"); p.stdin.close(); got = len(p.stderr.read()); p.wait(timeout=30)
        self.assertEqual(p.returncode, 4); self.assertLessEqual(got, (64 << 10) + 400); self.assertLess(time.time() - t, 10)

    def test_a_stdin_that_never_closes_is_still_bound_by_the_deadline(self):
        t = time.time(); p = subprocess.Popen([self.helper, "--deadline", "2", "-"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            p.stdin.write(b"console.log(1);")       # never closed, never completed
            p.wait(timeout=10)
        finally:
            if p.poll() is None: p.kill()
        self.assertEqual(p.returncode, -signal.SIGALRM); self.assertLess(time.time() - t, 8)

    def test_fast_large_allocations_are_ended_cleanly(self):
        for label, js in (("string doubling", "var s='x';for(;;){s+=s}"), ("typed array 3 GB", "var a=new Uint8Array(3e9);a.fill(1)"), ("huge array", "var a=new Array(2**31).fill(1)")):
            t = time.time(); rc, out, err = self.run_js(js, "--deadline", "30", timeout=60)
            self.assertIn(rc, (1, 5), label); self.assertLess(time.time() - t, 20, label); self.assertRegex(err, r"\[(js-error|memory-limit)\]")

    # ---- fail closed ----------------------------------------------------------------------------------------------------------------------------------------------------------------------
    def test_without_the_app_sandbox_it_refuses_to_run_any_script(self):
        if not self.unsandboxed: self.skipTest("needs the locally built unsandboxed twin")
        rc, out, err = self.run_js("console.log('should not run')", exe=self.unsandboxed)
        self.assertEqual(rc, 3); self.assertEqual(out, ""); self.assertIn("[unsandboxed]", err)

    def test_no_environment_variable_can_fake_or_switch_off_the_sandbox_check(self):
        if not self.unsandboxed: self.skipTest("needs the locally built unsandboxed twin")
        for extra in ({"BS_JSC_ALLOW_UNSANDBOXED": "1"}, {"APP_SANDBOX_CONTAINER_ID": "spoofed"}, {"APP_SANDBOX_CONTAINER_ID": "com.browsersetu.mac.jsc", "BS_JSC_ALLOW_UNSANDBOXED": "1"}):
            p = subprocess.run([self.unsandboxed, "-"], input=b"console.log('RAN UNCONFINED')", capture_output=True, env=dict(os.environ, **extra))
            self.assertEqual((p.returncode, p.stdout), (3, b""), f"{extra}: the kernel's answer decides, not the environment")
            self.assertIn(b"[unsandboxed]", p.stderr)

    def test_signature_and_entitlements(self):
        ents = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", self.helper], capture_output=True).stdout
        self.assertEqual(sorted(plistlib.loads(ents[ents.index(b"<?xml"):]).keys()), ["com.apple.security.app-sandbox"])
        info = subprocess.run(["codesign", "-dvv", self.helper], capture_output=True, text=True).stderr
        self.assertRegex(info, r"flags=0x[0-9a-f]+\(.*runtime")
        if os.environ.get("BS_JSC_HELPER"):          # the SHIPPED binary: a real Developer ID signature, never ad hoc
            self.assertRegex(info, r"TeamIdentifier=[A-Z0-9]{10}"); self.assertIn("Authority=Developer ID Application:", info); self.assertNotIn("Signature=adhoc", info)

    # ---- the sandbox of the RUNNING helper -------------------------------------------------------------------------------------------------------------------------------------------------
    @classmethod
    def query_tool(cls):
        if not getattr(cls, "_q", None):
            cls._q = os.path.join(cls.tmp, "sandbox_query")
            subprocess.run(["clang", "-O1", "-o", cls._q, os.path.join(ROOT, "scripts", "tests", "support", "sandbox_query.c")], check=True, capture_output=True)
        return cls._q

    def test_the_running_helper_is_denied_the_users_data_and_the_network(self):
        # Spawning a child is NOT in this list on purpose: the App Sandbox lets a process start a child, which inherits the sandbox. The script has no API to start one in any case (no process object exists).
        q = self.query_tool()
        p = subprocess.Popen([self.helper, "--deadline", "30", "-"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            p.stdin.write(b"while(true){}"); p.stdin.close(); time.sleep(1.0)
            self.assertIsNone(p.poll(), "the helper is running")
            def ask(op, path=None):
                return subprocess.run([q, str(p.pid), op] + ([path] if path else []), capture_output=True, text=True).stdout.strip()
            denied = [("file-read-data", HOME + "/Documents"), ("file-read-data", HOME + "/Desktop"), ("file-read-data", HOME + "/Downloads"), ("file-read-data", HOME + "/Library/Application Support/BrowserSetu"),
                      ("file-read-data", HOME + "/Library/Cookies"), ("file-read-data", HOME + "/Library/Safari"), ("file-read-data", HOME + "/.zshrc"), ("file-read-data", HOME + "/.ssh"),
                      ("file-read-data", "/tmp"), ("file-read-data", "/Users"), ("file-write-data", "/tmp/x"), ("file-write-data", HOME + "/x"), ("file-write-data", HOME + "/Documents/x"),
                      ("network-outbound", None), ("network-inbound", None), ("network-bind", None)]
            got = {f"{op} {path or ''}".strip(): ask(op, path) for op, path in denied}
            self.assertEqual({k: v for k, v in got.items() if v != "DENIED"}, {}, "each of these must be DENIED to the running helper (an ERROR is a failed query, not a denial)")
            for allowed in ("/System/Library/Frameworks/JavaScriptCore.framework", "/usr/share/icu"):
                self.assertEqual(ask("file-read-data", allowed), "ALLOWED", f"{allowed} must stay readable: it is the OS's own code and data")
        finally:
            p.kill(); p.wait()

    def test_the_unconfined_twin_is_not_denied_so_the_query_means_something(self):
        # A positive control for the tool: a process with no sandbox at all must come out ALLOWED, otherwise "DENIED" above would prove nothing.
        q = self.query_tool()
        p = subprocess.Popen(["/bin/sleep", "5"])
        try:
            time.sleep(0.3)
            r = subprocess.run([q, str(p.pid), "file-read-data", HOME + "/Documents"], capture_output=True, text=True).stdout.strip()
            self.assertEqual(r, "ALLOWED")
        finally:
            p.kill(); p.wait()


if __name__ == "__main__":
    unittest.main()
