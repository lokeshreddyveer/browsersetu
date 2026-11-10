#!/usr/bin/env python3
"""Tests for Browser Setu's yt-dlp JavaScript provider plugin (apps/apple/Helpers/JSProvider/yt_dlp_plugins/extractor/setu_jsc.py).

Package tests: the plugin's REAL code runs; only yt-dlp's modules are replaced by small stand-ins (so the tests need no yt-dlp and no network) and the helper by fake programs that
time out, crash, print rubbish or exceed limits. Real-helper, real-yt-dlp and live-YouTube checks are in test_js_helper.py and test_js_live.py (opt-in).
Run:  python3 -I -m unittest discover -s scripts/tests -v     (from the repository root)
"""
import contextlib, copy, dataclasses, enum, importlib.util, json, os, stat, subprocess, sys, tempfile, types, unittest, shutil

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
PLUGIN = os.path.join(ROOT, "apps", "apple", "Helpers", "JSProvider", "yt_dlp_plugins", "extractor", "setu_jsc.py")


def load_plugin(with_yt_dlp):
    """Import the plugin file under a private name. With stand-in yt-dlp modules the provider class is defined; without them only the pure functions are."""
    names = ["yt_dlp", "yt_dlp.extractor", "yt_dlp.extractor.youtube", "yt_dlp.extractor.youtube.jsc", "yt_dlp.extractor.youtube.jsc.provider", "yt_dlp.utils", "yt_dlp.version",
             "yt_dlp_ejs", "yt_dlp_ejs.yt", "yt_dlp_ejs.yt.solver"]
    saved = {n: sys.modules.pop(n, None) for n in names}
    registered = {}

    def cleanup():
        for n in names:
            sys.modules.pop(n, None)
        for n, m in saved.items():
            if m is not None: sys.modules[n] = m
    try:
        if with_yt_dlp:
            class Err(Exception):
                def __init__(self, msg=None, expected=False):
                    super().__init__(msg); self.expected = expected
            class Rejected(Err): pass
            class ProvErr(Err): pass
            class JType(enum.Enum):
                N = "n"; SIG = "sig"
            @dataclasses.dataclass(frozen=True)
            class Input: player_url: str; challenges: list
            @dataclasses.dataclass(frozen=True)
            class Request: type: JType; input: Input; video_id: str = None
            @dataclasses.dataclass(frozen=True)
            class NOut: results: dict
            @dataclasses.dataclass(frozen=True)
            class SigOut: results: dict
            @dataclasses.dataclass
            class Resp: request: Request; response: object = None; error: Exception = None
            @dataclasses.dataclass
            class CResp: type: JType; output: object
            class Provider:
                def __init__(self, ie, logger, settings, *_, **__): self.ie, self.logger, self.settings = ie, logger, settings
                def __init_subclass__(cls, **kw): super().__init_subclass__(**kw)
                def _get_player(self, video_id, url): return self.ie.player
            class Popen(subprocess.Popen):
                def communicate_or_kill(self, *a, **k):
                    try: return self.communicate(*a, **k)
                    except BaseException:
                        self.kill(); self.wait(); raise
            prov = types.ModuleType("yt_dlp.extractor.youtube.jsc.provider")
            prov.JsChallengeProvider, prov.JsChallengeProviderError, prov.JsChallengeProviderRejectedRequest = Provider, ProvErr, Rejected
            prov.JsChallengeProviderResponse, prov.JsChallengeResponse, prov.JsChallengeType = Resp, CResp, JType
            prov.NChallengeOutput, prov.SigChallengeOutput = NOut, SigOut
            prov.register_provider = lambda c: registered.setdefault("provider", c) and c
            prov.register_preference = lambda *c: (lambda f: registered.setdefault("preference", f) and f)
            utils = types.ModuleType("yt_dlp.utils"); utils.Popen = Popen
            ver = types.ModuleType("yt_dlp.version"); ver.__version__ = "2026.10.26"
            for n in ("yt_dlp", "yt_dlp.extractor", "yt_dlp.extractor.youtube", "yt_dlp.extractor.youtube.jsc"):
                sys.modules[n] = types.ModuleType(n)
            sys.modules.update({"yt_dlp.extractor.youtube.jsc.provider": prov, "yt_dlp.utils": utils, "yt_dlp.version": ver})
            ns = types.SimpleNamespace(Request=Request, Input=Input, JType=JType, ProvErr=ProvErr, Rejected=Rejected, NOut=NOut, SigOut=SigOut)
        else:
            ns = None
        spec = importlib.util.spec_from_file_location("setu_jsc_under_test", PLUGIN)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod, ns, registered, cleanup
    except BaseException:
        cleanup(); raise


def install_ejs(lib, core, version="0.8.0"):
    sol = types.ModuleType("yt_dlp_ejs.yt.solver"); sol.lib = lambda: lib; sol.core = lambda: core
    top = types.ModuleType("yt_dlp_ejs"); top.version = version
    sys.modules.update({"yt_dlp_ejs": top, "yt_dlp_ejs.yt": types.ModuleType("yt_dlp_ejs.yt"), "yt_dlp_ejs.yt.solver": sol})
    return lambda: [sys.modules.pop(n, None) for n in ("yt_dlp_ejs", "yt_dlp_ejs.yt", "yt_dlp_ejs.yt.solver")]


class PureFunctionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.p, _, _, cleanup = load_plugin(False)
        cleanup()

    def test_the_record_is_complete_and_consistent(self):
        c = self.p.COMPATIBILITY
        self.assertEqual(set(c), {"provider", "helperProtocol", "ytDlp", "ejs", "scriptContract", "challengeTypes"})
        self.assertEqual(c["challengeTypes"], ["n", "sig"])
        for ver, pins in c["ejs"].items():
            self.assertRegex(ver, r"^\d+\.\d+\.\d+$"); self.assertEqual(set(pins), {"lib", "core"})
            for h in pins.values(): self.assertRegex(h, r"^[0-9a-f]{64}$")

    def test_pairing_accepts_only_the_verified_combination(self):
        c = copy.deepcopy(self.p.COMPATIBILITY)
        c["ejs"]["0.8.0"] = {"lib": self.p.sha256_text("L"), "core": self.p.sha256_text("C")}
        self.assertIsNone(self.p.check_pairing("2026.10.26", "0.8.0", "L", "C", c))
        self.assertIn("yt-dlp 2026.11.01 has not been verified", self.p.check_pairing("2026.11.01", "0.8.0", "L", "C", c))
        self.assertIn("yt-dlp-ejs 0.9.0 has not been verified", self.p.check_pairing("2026.10.26", "0.9.0", "L", "C", c))
        self.assertIn("differ from the verified ones", self.p.check_pairing("2026.10.26", "0.8.0", "L!", "C", c))
        self.assertIn("differ from the verified ones", self.p.check_pairing("2026.10.26", "0.8.0", "L", "C!", c))

    def test_handshake(self):
        self.assertEqual(self.p.parse_handshake("setu-jsc 1.0.0 protocol 1\n"), ("1.0.0", None))
        for bad in ("", "setu-jsc 1.0.0", "deno 2.9.8", "setu-jsc 1.0.0 protocol 1 extra", "setu-jsc 1.0 protocol 1", "xsetu-jsc 1.0.0 protocol 1"):
            self.assertIsNone(self.p.parse_handshake(bad)[0], bad)
        self.assertIn("protocol 2", self.p.parse_handshake("setu-jsc 1.0.0 protocol 2")[1])

    def test_script_adapter_matches_the_documented_ejs_contract(self):
        s = self.p.ejs_script_v1("LIB();", "CORE();", 'var p="x";', [("n", ["a"]), ("sig", ["b", "c"])])
        self.assertTrue(s.startswith("LIB();\nObject.assign(globalThis, lib);\nCORE();\nconsole.log(JSON.stringify(jsc("))
        self.assertTrue(s.endswith(")));\n"))
        data = json.loads(s[s.index("jsc(") + 4:s.rindex(")));")])
        self.assertEqual(data, {"type": "player", "player": 'var p="x";', "requests": [{"type": "n", "challenges": ["a"]}, {"type": "sig", "challenges": ["b", "c"]}], "output_preprocessed": False})
        # hostile text in the player cannot break out of the JSON string
        evil = '"});console.log(process);//'
        d2 = json.loads(self.p.ejs_script_v1("", "", evil, [("n", ["a"])]).split("jsc(", 1)[1].rsplit(")));", 1)[0])
        self.assertEqual(d2["player"], evil)

    def test_the_adapter_matches_ytdlps_own_script_when_its_source_is_available(self):
        src = os.environ.get("BS_YTDLP_SOURCE")        # a yt-dlp source tree of the pinned release (optional)
        if not src: self.skipTest("set BS_YTDLP_SOURCE to a yt-dlp source tree to compare with its _construct_stdin")
        text = open(os.path.join(src, "yt_dlp", "extractor", "youtube", "jsc", "_builtin", "ejs.py")).read()
        for needle in ("Object.assign(globalThis, lib);", "console.log(JSON.stringify(jsc({json.dumps(data)})));", "'type': 'player'", "'preprocessed_player': player"):
            self.assertIn(needle, text)

    def test_answer_validation(self):
        groups = [("n", ["a", "b"]), ("sig", ["s"])]
        good = {"type": "result", "responses": [{"type": "result", "data": {"a": "A", "b": "B"}}, {"type": "result", "data": {"s": "S"}}]}
        self.assertEqual(self.p.validate_answer(json.dumps(good), groups), [("ok", {"a": "A", "b": "B"}), ("ok", {"s": "S"})])
        partial = copy.deepcopy(good); partial["responses"][0] = {"type": "error", "error": "no n function"}
        self.assertEqual(self.p.validate_answer(json.dumps(partial), groups)[0], ("error", "no n function"))
        bad = {
            "not json": "nope", "array": "[]", "no type": "{}", "unknown type": '{"type":"weird"}', "top-level error": '{"type":"error","error":"boom"}',
            "wrong count": json.dumps({"type": "result", "responses": [good["responses"][0]]}), "responses not a list": '{"type":"result","responses":{}}',
            "response not a dict": '{"type":"result","responses":[1,2]}', "response bad type": '{"type":"result","responses":[{"type":"x"},{"type":"x"}]}',
            "data not text": json.dumps({"type": "result", "responses": [{"type": "result", "data": {"a": 1}}, good["responses"][1]]}),
            "data not a dict": json.dumps({"type": "result", "responses": [{"type": "result", "data": ["a"]}, good["responses"][1]]}),
            "unasked challenge": json.dumps({"type": "result", "responses": [{"type": "result", "data": {"zzz": "A"}}, good["responses"][1]]}),
            "result too long": json.dumps({"type": "result", "responses": [{"type": "result", "data": {"a": "x" * 5000}}, good["responses"][1]]}),
        }
        for label, text in bad.items():
            with self.subTest(label), self.assertRaises(self.p.AnswerError):
                self.p.validate_answer(text, groups)
        with self.assertRaises(self.p.AnswerError):
            self.p.validate_answer("x" * (self.p.MAX_ANSWER_BYTES + 1), groups)


class ProviderClassTests(unittest.TestCase):
    """The real provider class with stand-in yt-dlp modules and fake helper programs."""
    LIB, CORE = "var lib={};", "function jsc(){}"

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="jscp-")
        self.p, self.ns, self.reg, self.unload = load_plugin(True)
        self.restore_ejs = install_ejs(self.LIB, self.CORE)
        c = copy.deepcopy(self.p.COMPATIBILITY)
        c["ejs"] = {"0.8.0": {"lib": self.p.sha256_text(self.LIB), "core": self.p.sha256_text(self.CORE)}}
        self.p.COMPATIBILITY.clear(); self.p.COMPATIBILITY.update(c)
        self.logs = []
        self.logger = types.SimpleNamespace(warning=lambda m: self.logs.append(("warning", m)), info=lambda m: None, debug=lambda m: self.logs.append(("debug", m)))
        self.ie = types.SimpleNamespace(player="var player = 1;")
        self.p._breaker.update(failures=0, open=False)

    def tearDown(self):
        self.restore_ejs(); self.unload(); shutil.rmtree(self.tmp, ignore_errors=True)

    def helper(self, body, version="setu-jsc 1.0.0 protocol 1"):
        path = os.path.join(self.tmp, "setu-jsc")
        open(path, "w").write(f'#!/bin/sh\nif [ "$1" = "--version" ]; then echo "{version}"; exit 0; fi\n{body}\n')
        os.chmod(path, 0o755)
        self.p._helper_path = lambda: path
        return path

    def provider(self):
        return self.reg["provider"](self.ie, self.logger, {})

    def request(self, kind="n", challenges=("abc",)):
        return self.ns.Request(self.ns.JType(kind), self.ns.Input("https://youtube.com/p.js", list(challenges)), "vid")

    def solve(self, *requests):
        return list(self.provider()._real_bulk_solve(list(requests)))

    GOOD = '{"type":"result","responses":[{"type":"result","data":{"abc":"ABC"}}]}'

    def test_registered_with_the_public_api_and_prefers_itself_over_deno(self):
        self.assertEqual(self.reg["preference"](None, []), 1100)
        self.assertEqual(self.reg["provider"].__name__, "SetuJSCJCP")
        self.assertEqual(self.reg["provider"]._SUPPORTED_TYPES, (self.ns.JType.N, self.ns.JType.SIG))
        src = open(PLUGIN).read()
        self.assertNotIn("EJSBaseJCP", src.replace("Nothing from yt-dlp's private EJS classes", ""), "no private yt-dlp class may be imported")
        self.assertNotIn("_builtin", src)

    def test_available_when_everything_matches(self):
        self.helper(f"cat >/dev/null; echo '{self.GOOD}'")
        self.assertTrue(self.provider().is_available())

    def test_unavailable_without_a_helper_or_with_a_wrong_handshake(self):
        self.p._helper_path = lambda: os.path.join(self.tmp, "missing")
        pr = self.provider(); self.assertFalse(pr.is_available()); self.assertTrue(any("not in this app" in m for _, m in self.logs))
        self.helper("exit 0", version="setu-jsc 1.0.0 protocol 9")
        self.assertFalse(self.provider().is_available())
        self.helper("exit 0", version="something else")
        self.assertFalse(self.provider().is_available())

    def test_unavailable_for_an_unverified_ytdlp_or_ejs(self):
        self.helper("cat >/dev/null; echo '{}'")
        sys.modules["yt_dlp.version"].__version__ = "2026.11.01"
        self.assertFalse(self.provider().is_available()); self.assertTrue(any("yt-dlp 2026.11.01" in m for _, m in self.logs))
        sys.modules["yt_dlp.version"].__version__ = "2026.10.26"
        self.restore_ejs(); self.restore_ejs = install_ejs(self.LIB, self.CORE, version="0.9.0")
        self.assertFalse(self.provider().is_available())
        self.restore_ejs(); self.restore_ejs = install_ejs(self.LIB + " //changed", self.CORE)
        self.assertFalse(self.provider().is_available())
        self.restore_ejs(); self.restore_ejs = lambda: None
        for n in ("yt_dlp_ejs", "yt_dlp_ejs.yt", "yt_dlp_ejs.yt.solver"): sys.modules.pop(n, None)
        self.assertFalse(self.provider().is_available(), "no yt_dlp_ejs package at all")

    def test_a_good_answer_becomes_responses(self):
        self.helper(f"cat >/dev/null; echo '{self.GOOD}'")
        out = self.solve(self.request())
        self.assertEqual(len(out), 1); self.assertIsNone(out[0].error)
        self.assertEqual(out[0].response.output.results, {"abc": "ABC"})

    def test_the_helper_gets_the_script_on_stdin_and_a_bounded_deadline(self):
        rec = os.path.join(self.tmp, "args.txt"); stdin = os.path.join(self.tmp, "stdin.txt")
        self.helper(f'echo "$@" > {rec}; cat > {stdin}; echo \'{self.GOOD}\'')
        self.solve(self.request())
        self.assertEqual(open(rec).read().split(), ["--deadline", str(self.p.SOLVE_SECONDS + 5), "-"])
        text = open(stdin).read()
        self.assertTrue(text.startswith(self.LIB)); self.assertIn("var player = 1;", text)

    def test_the_helper_gets_no_inherited_environment_and_no_shell(self):
        out = os.path.join(self.tmp, "env.txt")
        self.helper(f'env > {out}; cat >/dev/null; echo \'{self.GOOD}\'')
        os.environ["SECRET_TOKEN_FOR_TEST"] = "hunter2"
        try: self.solve(self.request())
        finally: del os.environ["SECRET_TOKEN_FOR_TEST"]
        env = open(out).read()
        self.assertNotIn("hunter2", env); self.assertNotIn("SECRET_TOKEN", env)
        self.assertNotIn("HOME=", env); self.assertIn("PATH=/usr/bin:/bin", env)

    def test_timeout_is_classified_ended_and_counted(self):
        self.p.SOLVE_SECONDS = 1
        self.helper("cat >/dev/null; sleep 30")
        import time; t = time.time()
        with self.assertRaises(self.ns.ProvErr) as cm: self.solve(self.request())
        self.assertIn("[timeout]", str(cm.exception)); self.assertLess(time.time() - t, 8, "the stalled helper was ended, not waited for")

    def test_circuit_breaker_stops_repeated_waits(self):
        self.p.SOLVE_SECONDS = 1
        self.helper("cat >/dev/null; sleep 30")
        for _ in range(self.p.CIRCUIT_BREAKER):
            with self.assertRaises(self.ns.ProvErr): self.solve(self.request())
        self.assertTrue(self.p._breaker["open"])
        self.assertFalse(self.provider().is_available(), "no further attempts in this run")
        self.assertTrue(any("failed repeatedly" in m for _, m in self.logs))

    def test_a_success_resets_the_failure_count(self):
        self.helper("cat >/dev/null; exit 9")
        with self.assertRaises(self.ns.ProvErr): self.solve(self.request())
        self.assertEqual(self.p._breaker["failures"], 1)
        self.helper(f"cat >/dev/null; echo '{self.GOOD}'")
        self.solve(self.request()); self.assertEqual(self.p._breaker["failures"], 0)

    def test_exit_codes_are_classified(self):
        for code, kind in ((1, "js-error"), (2, "input"), (3, "unsandboxed"), (4, "output-limit"), (5, "memory-limit"), (9, "crash"), (139, "crash")):
            self.p._breaker.update(failures=0, open=False)
            self.helper(f"cat >/dev/null; echo 'setu-jsc: [x] detail' >&2; exit {code}")
            with self.subTest(code), self.assertRaises(self.ns.ProvErr) as cm: self.solve(self.request())
            self.assertIn(f"[{kind}]", str(cm.exception)); self.assertIn("detail", str(cm.exception))

    def test_signals_are_classified(self):
        self.helper("cat >/dev/null; kill -KILL $$")
        with self.assertRaises(self.ns.ProvErr) as cm: self.solve(self.request())
        self.assertIn("[crash]", str(cm.exception))
        self.p._breaker.update(failures=0, open=False)
        self.helper("cat >/dev/null; kill -ALRM $$")
        with self.assertRaises(self.ns.ProvErr) as cm: self.solve(self.request())
        self.assertIn("[deadline]", str(cm.exception))
        self.p._breaker.update(failures=0, open=False)
        self.helper("cat >/dev/null; kill -XCPU $$")                  # SIGXCPU: the helper's CPU-time limit
        with self.assertRaises(self.ns.ProvErr) as cm: self.solve(self.request())
        self.assertIn("[deadline]", str(cm.exception))

    def test_malformed_or_chatty_helper_output_is_a_protocol_error(self):
        for body, why in (("cat >/dev/null; echo 'not json'", "not JSON"), ("cat >/dev/null; echo '{}'", "no valid"), ("cat >/dev/null; echo diagnostics >&2; echo '%s'" % self.GOOD, "diagnostics"),
                          ("cat >/dev/null; echo '{\"type\":\"result\",\"responses\":[]}'", "expected 1 responses")):
            self.p._breaker.update(failures=0, open=False)
            self.helper(body)
            with self.subTest(why), self.assertRaises(self.ns.ProvErr) as cm: self.solve(self.request())
            self.assertIn("[protocol]", str(cm.exception)); self.assertIn(why, str(cm.exception))

    def test_a_per_challenge_error_fails_only_that_request(self):
        ans = '{"type":"result","responses":[{"type":"error","error":"no n function"},{"type":"result","data":{"s":"S"}}]}'
        self.helper(f"cat >/dev/null; echo '{ans}'")
        out = self.solve(self.request("n", ["abc"]), self.request("sig", ["s"]))
        self.assertIn("[solver] no n function", str(out[0].error)); self.assertIsNone(out[1].error)
        self.assertEqual(out[1].response.output.results, {"s": "S"})


    def test_a_recursion_bomb_in_the_answer_is_a_classified_error_not_an_exception(self):
        bomb = "[" * 200000
        self.helper(f"cat >/dev/null; printf '{bomb}'")
        with self.assertRaises(self.ns.ProvErr) as cm: self.solve(self.request())
        self.assertIn("[protocol]", str(cm.exception))

    def test_invalid_utf8_from_the_helper_cannot_raise_a_decode_error(self):
        self.helper("cat >/dev/null; printf '\\377\\376 not utf8'; printf '\\377' >&2; exit 0")
        with self.assertRaises(self.ns.ProvErr) as cm: self.solve(self.request())
        self.assertRegex(str(cm.exception), r"\[(protocol)\]")
        self.p._breaker.update(failures=0, open=False)
        self.helper("cat >/dev/null; printf '\\377\\376' >&2; exit 1")
        with self.assertRaises(self.ns.ProvErr): self.solve(self.request())

    def test_a_huge_stderr_is_survived_and_the_message_is_short_and_plain(self):
        self.helper("cat >/dev/null; head -c 3000000 /dev/zero | tr '\\0' 'e' >&2; exit 1")
        with self.assertRaises(self.ns.ProvErr) as cm: self.solve(self.request())
        self.assertLess(len(str(cm.exception)), 400)

    def test_hostile_helper_text_is_flattened_before_it_can_reach_a_dialog(self):
        self.helper("cat >/dev/null; printf 'line1\\n\\033[31mRED\\033[0m\\ttab \\342\\200\\256rtl' >&2; exit 1")
        with self.assertRaises(self.ns.ProvErr) as cm: self.solve(self.request())
        msg = str(cm.exception)
        self.assertNotIn("\n", msg); self.assertNotIn("\x1b", msg); self.assertNotIn("\t", msg); self.assertTrue(msg.isascii())
        self.assertEqual(self.p.clean_text("a\nb\x1b[0mc" + "x" * 1000, 20), "a b [0mc" + "x" * 12)

    def test_partial_answers_are_failures_of_that_request_not_successes(self):
        ans = '{"type":"result","responses":[{"type":"result","data":{"abc":"A"}}]}'
        self.helper(f"cat >/dev/null; echo '{ans}'")
        out = self.solve(self.request("n", ["abc", "def"]))
        self.assertIn("only some of the challenges", str(out[0].error)); self.assertIsNone(out[0].response)
        self.assertEqual(self.p.validate_answer('{"type":"result","responses":[{"type":"result","data":{}}]}', [("n", ["a"])]), [("error", "the solver answered only some of the challenges")])

    def test_an_unforeseen_exception_becomes_a_classified_failure(self):
        self.helper(f"cat >/dev/null; echo '{self.GOOD}'")
        self.p.validate_answer = lambda *a, **k: (_ for _ in ()).throw(KeyError("surprise"))
        with self.assertRaises(self.ns.ProvErr) as cm: self.solve(self.request())
        self.assertIn("[internal] KeyError", str(cm.exception)); self.assertEqual(self.p._breaker["failures"], 1)

    def test_unicode_player_text_reaches_the_helper_intact_as_escapes_in_an_ascii_script(self):
        stdin = os.path.join(self.tmp, "stdin.bin")
        self.helper(f"cat > {stdin}; echo '{self.GOOD}'")
        self.ie.player = "var s = '\u00e9\u2713\U0001F600';"
        self.solve(self.request())
        raw = open(stdin, "rb").read()
        self.assertTrue(raw.decode("ascii"), "the script is pure ASCII: no encoding ambiguity between Python and the helper")
        self.assertIn(b"\\u00e9\\u2713\\ud83d\\ude00", raw, "the engine decodes these escapes back to the exact characters")

    def test_an_oversized_script_is_rejected_before_anything_runs(self):
        marker = os.path.join(self.tmp, "ran")
        self.helper(f"touch {marker}; cat >/dev/null; echo '{self.GOOD}'")
        self.ie.player = "x" * (self.p.MAX_SCRIPT_BYTES + 10)
        with self.assertRaises(self.ns.Rejected): self.solve(self.request())
        self.assertFalse(os.path.exists(marker))

    def test_logs_never_contain_the_player_or_the_script(self):
        self.helper("cat >/dev/null; echo 'oops' >&2; exit 1")
        self.ie.player = "var SECRET_PLAYER_CONTENT = 'abcdef';"
        with self.assertRaises(self.ns.ProvErr) as cm: self.solve(self.request())
        text = " ".join(m for _, m in self.logs) + str(cm.exception)
        self.assertNotIn("SECRET_PLAYER_CONTENT", text)

    def test_hostile_player_text_cannot_inject_a_command(self):
        marker = os.path.join(self.tmp, "pwned")
        self.helper(f"cat >/dev/null; echo '{self.GOOD}'")
        self.ie.player = f"'; touch {marker}; echo '\"; $(touch {marker}); `touch {marker}`"
        self.solve(self.request())
        self.assertFalse(os.path.exists(marker), "the player is data on stdin, never part of a command line")


if __name__ == "__main__":
    unittest.main()
