#!/usr/bin/env python3
"""Security-chain tests on a BUILT app: BrowserSetu -> yt-dlp -> provider plugin -> helper. Offline (no website is contacted).

Set BS_APP to a built Browser Setu.app that went through scripts/embed-media-manifests.sh and scripts/embed-js-provider.sh (for example the --verify-only build). The arguments and the environment
are the ones the app really uses (parsed from BundledExtractor.swift and ExternalExtractor.swift, so this cannot drift from the code).
Run:  BS_APP=<app> python3 -I -m unittest discover -s scripts/tests -p 'test_js_chain.py' -v
"""
import os, re, shutil, signal, subprocess, tempfile, time, unittest
from ytdlp_tree_support import ytdlp_tree

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
APP = os.environ.get("BS_APP")


def swift_list(path, name):
    text = open(path).read()
    m = re.search(rf"static let {name} = \[(.*?)\]", text)
    return re.findall(r'"([^"]*)"', m.group(1))


def swift_env():
    text = open(os.path.join(ROOT, "apps/apple/Shared/Downloads/Media/ExternalExtractor.swift")).read()
    m = re.search(r"static let childEnvironment = \[(.*?)\]", text)
    pairs = re.findall(r'"(\w+)": ("[^"]*"|NSTemporaryDirectory\(\))', m.group(1))
    return {k: (None if v.startswith("NSTemp") else v.strip('"')) for k, v in pairs}


@unittest.skipUnless(APP and os.path.isdir(APP), "set BS_APP to a built app")
class ChainTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="chain-")
        res = os.path.join(APP, "Contents", "Resources")
        cls.ytdlp_dir = ytdlp_tree()           # the app carries no yt-dlp: the verified package from the cache (or BS_YTDLP_TREE)
        if not cls.ytdlp_dir: raise unittest.SkipTest("no verified yt-dlp package (media-tools cache or BS_YTDLP_TREE)")
        cls.plugdir = os.path.join(res, "YtDlpPlugins")
        cls.base = swift_list(os.path.join(ROOT, "apps/apple/Shared/Downloads/Media/BundledExtractor.swift"), "baseArguments")
        cls.env0 = swift_env()
        cls.helper = os.path.join(APP, "Contents", "Helpers", "setu-jsc")

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def env(self, home, **extra):
        e = dict(self.env0); e["HOME"] = home; e.update(extra); return e

    DECOY = 'open(%r, "w").write("decoy plugin was imported")\n'

    def plant(self, root, marker):
        d = os.path.join(root, "yt_dlp_plugins", "extractor"); os.makedirs(d, exist_ok=True)
        open(os.path.join(d, "evil.py"), "w").write(self.DECOY % marker)

    def run_ytdlp(self, home, args, exe=None, **env):
        cmd = [exe or os.path.join(self.ytdlp_dir, "yt-dlp_macos"), *args, "-v", "--simulate", "--skip-download", "--no-playlist", "--socket-timeout", "3", "--retries", "0", "http://127.0.0.1:9/x"]
        p = subprocess.run(cmd, capture_output=True, text=True, env=self.env(home, **env), cwd=home, timeout=90)
        return p.stdout + p.stderr

    def decoys(self, home):
        """A decoy plugin in EVERY place yt-dlp looks by default; returns the marker files."""
        marks = {}
        for label, root in (("home yt-dlp-plugins", f"{home}/yt-dlp-plugins/x"), ("config plugins", f"{home}/.config/yt-dlp/plugins/x"), ("XDG config", f"{home}/xdg/yt-dlp/plugins/x"),
                            ("PYTHONPATH", f"{home}/pypath"), ("cwd", f"{home}/cwdplug/x")):
            marks[label] = os.path.join(home, "marker-" + label.replace(" ", "_"))
            self.plant(root, marks[label])
        return marks

    def loaded_without_the_apps_flags(self, xdg):
        """Which decoy locations yt-dlp really searches by default, found by running it WITHOUT the app's plugin flags. `xdg` selects the environment: the app's own (no XDG_CONFIG_HOME) or one that sets it."""
        home = tempfile.mkdtemp(dir=self.tmp); marks = self.decoys(home)
        extra = {"XDG_CONFIG_HOME": f"{home}/xdg"} if xdg else {}
        self.run_ytdlp(home, ["--ignore-config"], PYTHONPATH=f"{home}/pypath", **extra)
        return {k for k, m in marks.items() if os.path.exists(m)}

    def test_control_the_decoys_do_load_without_the_apps_flags(self):
        # In the APP's environment (no XDG_CONFIG_HOME) yt-dlp searches ~/.config/yt-dlp/plugins; with XDG_CONFIG_HOME set it searches that instead. Each must be proved live, or "nothing loaded" means nothing for it.
        # (Other planted locations - ~/yt-dlp-plugins, PYTHONPATH, the current directory - are inert in this frozen build even without the flags; they are still planted below, harmlessly.)
        self.assertIn("config plugins", self.loaded_without_the_apps_flags(xdg=False), "~/.config/yt-dlp/plugins must be live in the app's own environment")
        self.assertIn("XDG config", self.loaded_without_the_apps_flags(xdg=True), "$XDG_CONFIG_HOME/yt-dlp/plugins must be live when that variable is set")

    def test_only_the_approved_plugin_folder_is_searched_with_the_apps_arguments(self):
        for xdg in (False, True):
            live = self.loaded_without_the_apps_flags(xdg)
            home = tempfile.mkdtemp(dir=self.tmp); marks = self.decoys(home)
            extra = {"XDG_CONFIG_HOME": f"{home}/xdg"} if xdg else {}
            out = self.run_ytdlp(home, [*self.base, "--plugin-dirs", self.plugdir], PYTHONPATH=f"{home}/pypath", **extra)
            self.assertEqual([k for k, m in marks.items() if os.path.exists(m)], [], f"no decoy plugin may run (xdg={xdg}; live in the control: {sorted(live)})")
            m = re.search(r"Plugin directories: (.*)", out)
            self.assertIsNotNone(m, out[-600:])
            dirs = [d.strip() for d in m.group(1).split(",")]
            self.assertTrue(all(d.startswith(self.plugdir) for d in dirs), f"only the app's folder may be searched, got {dirs}")

    def test_without_a_verified_folder_no_plugin_directory_is_searched_at_all(self):
        home = tempfile.mkdtemp(dir=self.tmp); marks = self.decoys(home)
        out = self.run_ytdlp(home, self.base, XDG_CONFIG_HOME=f"{home}/xdg", PYTHONPATH=f"{home}/pypath")
        self.assertEqual([k for k, m in marks.items() if os.path.exists(m)], [])
        self.assertIn("Plugin directories: none", out)

    def test_decoy_next_to_the_executable_is_not_loaded(self):
        home = tempfile.mkdtemp(dir=self.tmp)
        copy = os.path.join(home, "yt-dlp-copy"); shutil.copytree(self.ytdlp_dir, copy, symlinks=True)
        marker = os.path.join(home, "marker-exe"); self.plant(os.path.join(copy, "yt-dlp-plugins", "x"), marker)
        self.run_ytdlp(home, [*self.base, "--plugin-dirs", self.plugdir], exe=os.path.join(copy, "yt-dlp_macos"))
        self.assertFalse(os.path.exists(marker))

    def test_the_apps_fixed_environment_carries_nothing_that_could_inject_code_or_secrets(self):
        self.assertEqual(set(self.env0), {"PATH", "LANG", "HOME", "PYTHONDONTWRITEBYTECODE"})
        self.assertEqual(self.env0["PATH"], "/usr/bin:/bin")
        for bad in ("PYTHONPATH", "PYTHONSTARTUP", "PYTHONHOME", "DYLD_INSERT_LIBRARIES", "BROWSERSETU_JSC"):
            self.assertNotIn(bad, self.env0)

    def test_the_base_arguments_read_no_config_and_clear_plugin_dirs_and_runtimes_first(self):
        self.assertEqual(self.base[:4], ["--ignore-config", "--no-cache-dir", "--no-update", "--no-plugin-dirs"])
        self.assertIn("--no-js-runtimes", self.base, "yt-dlp's own default runtime search is switched off")

    def test_a_deno_in_path_is_ignored_with_the_apps_arguments_but_found_without_them(self):
        # yt-dlp by default enables "deno" and finds one in PATH. The app's PATH is /usr/bin:/bin, but a program planted anywhere on a PATH must not become a runtime the app never verified.
        home = tempfile.mkdtemp(dir=self.tmp)
        fake = os.path.join(home, "fakebin"); os.makedirs(fake)
        with open(os.path.join(fake, "deno"), "w") as f: f.write('#!/bin/sh\necho "deno 2.9.8 (stable, release, fake)"\n')
        os.chmod(os.path.join(fake, "deno"), 0o755)
        env = {"PATH": fake + ":/usr/bin:/bin"}
        without = self.run_ytdlp(home, ["--ignore-config"], **env)
        with_app_args = self.run_ytdlp(home, [*self.base, "--plugin-dirs", self.plugdir], **env)
        self.assertRegex(without, r"JS runtimes: deno-2\.9\.8", "control: without the app's options yt-dlp really does pick up a deno from PATH")
        self.assertIn("JS runtimes: none", with_app_args, "with the app's options no runtime is enabled")
        self.assertNotIn("deno-2.9.8", with_app_args)

    def test_a_group_signal_reaches_a_helper_started_by_a_session_leader(self):
        # Proves the kernel semantics the app relies on, NOT the app's code: the program is a session leader, the helper its child in the same group, and kill(-pgid) ends both. The app's own
        # Box.stop is exercised with the real helper in ExtractorAdversarialTests.testTimeoutEndsTheRealHelperStartedByTheProgram (TEST_RUNNER_BS_HELPER).
        if not os.path.exists(self.helper): self.skipTest("no helper in the app")
        script = f"import subprocess,time,sys; p=subprocess.Popen([{self.helper!r},'--deadline','100','-'],stdin=subprocess.PIPE); p.stdin.write(b'while(true){{}}'); p.stdin.close(); print(p.pid, flush=True); time.sleep(100)"
        parent = subprocess.Popen(["/usr/bin/python3", "-c", script], stdout=subprocess.PIPE, text=True, start_new_session=True)
        alive = lambda pid: subprocess.run(["kill", "-0", str(pid)], capture_output=True).returncode == 0
        try:
            child = int(parent.stdout.readline())
            for _ in range(60):                       # under load the helper can take a moment to start: wait for it, do not assume
                if alive(child): break
                time.sleep(0.1)
            self.assertTrue(alive(child), "the helper is running")
            time.sleep(0.5); self.assertTrue(alive(child), "and keeps running (it is a busy loop)")
            os.killpg(parent.pid, signal.SIGTERM)
            for _ in range(100):
                if not alive(child): break
                time.sleep(0.1)
            self.assertFalse(alive(child), "the helper did not outlive its group")
        finally:
            try: os.killpg(parent.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError): pass       # a finished group: macOS answers EPERM, not ESRCH
            parent.wait(timeout=10)

    def test_the_real_solver_scripts_in_the_app_are_the_pairing_the_plugin_pins(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("setu_jsc_plugin", os.path.join(self.plugdir, "setu", "yt_dlp_plugins", "extractor", "setu_jsc.py"))
        plugin = importlib.util.module_from_spec(spec); spec.loader.exec_module(plugin)       # without yt-dlp importable only the pure functions are defined
        solver = os.path.join(self.ytdlp_dir, "_internal", "yt_dlp_ejs", "yt", "solver")
        with open(os.path.join(solver, "lib.min.js"), encoding="utf-8") as f: lib = f.read()
        with open(os.path.join(solver, "core.min.js"), encoding="utf-8") as f: core = f.read()
        ejs = next(iter(plugin.COMPATIBILITY["ejs"]))
        self.assertIsNone(plugin.check_pairing(plugin.COMPATIBILITY["ytDlp"][0], ejs, lib, core), "the real embedded scripts must be accepted by the real plugin")
        self.assertIsNotNone(plugin.check_pairing(plugin.COMPATIBILITY["ytDlp"][0], ejs, lib + " ", core))

    @unittest.skipUnless(os.environ.get("BS_PLAYER"), "set BS_PLAYER to a saved YouTube player script to run the offline end-to-end check")
    def test_real_adapter_real_scripts_real_helper_on_a_saved_player(self):
        import importlib.util, json as _json
        spec = importlib.util.spec_from_file_location("setu_jsc_plugin2", os.path.join(self.plugdir, "setu", "yt_dlp_plugins", "extractor", "setu_jsc.py"))
        plugin = importlib.util.module_from_spec(spec); spec.loader.exec_module(plugin)
        solver = os.path.join(self.ytdlp_dir, "_internal", "yt_dlp_ejs", "yt", "solver")
        lib, core = (open(os.path.join(solver, n), encoding="utf-8").read() for n in ("lib.min.js", "core.min.js"))
        groups = [("n", ["ABCDEFGHIJKLMNOP"]), ("sig", ["A" * 106])]
        script = plugin.ejs_script_v1(lib, core, open(os.environ["BS_PLAYER"], encoding="utf-8").read(), groups)
        p = subprocess.run([self.helper, "--deadline", "50", "-"], input=script.encode(), capture_output=True, timeout=60)
        self.assertEqual(p.returncode, 0, p.stderr[-300:])
        results = plugin.validate_answer(p.stdout.decode(), groups)
        self.assertEqual([k for k, _ in results], ["ok", "ok"]); self.assertNotEqual(results[0][1]["ABCDEFGHIJKLMNOP"], "ABCDEFGHIJKLMNOP")

    def test_the_helper_in_the_app_answers_the_handshake_the_plugin_expects(self):
        if not os.path.exists(self.helper): self.skipTest("no helper in the app")
        out = subprocess.run([self.helper, "--version"], capture_output=True, text=True, env=self.env(self.tmp)).stdout
        self.assertRegex(out, r"^setu-jsc \d+\.\d+\.\d+ protocol 1\n$")


if __name__ == "__main__":
    unittest.main()
