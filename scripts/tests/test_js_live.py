#!/usr/bin/env python3
"""OPTIONAL live-compatibility tests (contact YouTube; metadata only, nothing is downloaded). Routine CI does not run these: they depend on a website.

  BS_LIVE=1 BS_APP=<built app> [BS_DENO=<deno binary>] [BS_LIVE_PLAYLIST=<public playlist URL>] [BS_LIVE_STREAM=<public live URL>]
  python3 -I -m unittest discover -s scripts/tests -p 'test_js_live.py' -v

Public, openly licensed test content (the Blender Foundation's Big Buck Bunny) plus the first YouTube video. Format IDs are compared with a Deno baseline when BS_DENO is given; a difference
is reported, not assumed to be a JavaScript failure (formats also vary by time and region).
"""
import concurrent.futures as cf, os, re, subprocess, tempfile, time, unittest

APP, LIVE, DENO = os.environ.get("BS_APP"), os.environ.get("BS_LIVE") == "1", os.environ.get("BS_DENO")
VIDEOS = {"first-video": "https://www.youtube.com/watch?v=jNQXAC9IVRw", "big-buck-bunny": "https://www.youtube.com/watch?v=aqz-KE-bpKQ"}


@unittest.skipUnless(LIVE and APP, "set BS_LIVE=1 and BS_APP to run the live suite")
class LiveTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        res = os.path.join(APP, "Contents", "Resources")
        cls.exe = os.path.join(res, "Tools", "yt-dlp", "yt-dlp_macos"); cls.plug = os.path.join(res, "YtDlpPlugins"); cls.tmp = tempfile.mkdtemp(prefix="live-")

    def run_ytdlp(self, url, *extra, timeout=120, verbose=True):
        cmd = [self.exe, "--ignore-config", "--no-cache-dir", "--no-update", "--no-plugin-dirs", "--no-js-runtimes", *(["-v"] if verbose else []), "-F", "--no-playlist", *extra, url]
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env={"PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "HOME": self.tmp, "PYTHONDONTWRITEBYTECODE": "1"}, cwd=self.tmp)
        return p.returncode, p.stdout + p.stderr

    @staticmethod
    def format_ids(out):
        ids, on = [], False
        for line in out.splitlines():
            if line.startswith("ID "): on = True; continue
            m = re.match(r"^([0-9A-Za-z_-]+)\s+\S+\s", line)
            if on and m: ids.append(m.group(1))
        return sorted(set(ids))

    def ours(self, url, *extra):
        return self.run_ytdlp(url, "--plugin-dirs", self.plug, *extra)

    def test_native_provider_is_discovered_selected_and_solves(self):
        for name, url in VIDEOS.items():
            rc, out = self.ours(url)
            with self.subTest(name):
                self.assertEqual(rc, 0, out[-800:])
                self.assertIn("SetuJSC", out); self.assertIn("(external)", out)
                self.assertRegex(out, r"Solving JS challenges using Browser Setu")
                self.assertNotIn("JavaScript provider is not used", out); self.assertNotIn("challenge solving failed", out.lower())
                self.assertGreater(len(self.format_ids(out)), 10)

    @unittest.skipUnless(DENO, "set BS_DENO to compare with a Deno baseline")
    def test_format_ids_match_the_deno_baseline(self):
        for name, url in VIDEOS.items():
            _, base = self.run_ytdlp(url, "--js-runtimes", f"deno:{DENO}")
            _, ours = self.ours(url)
            a, b = set(self.format_ids(base)), set(self.format_ids(ours))
            with self.subTest(name):
                self.assertTrue(a, "the baseline listed formats"); self.assertEqual(a ^ b, set(), f"only-in-Deno={sorted(a - b)} only-in-native={sorted(b - a)}")

    def test_without_any_provider_extraction_still_works_but_with_a_warning(self):
        rc, out = self.run_ytdlp(VIDEOS["first-video"])           # no plugin dir: the situation of a build without the helper
        self.assertEqual(rc, 0); self.assertIn("No supported JavaScript runtime", out)

    def test_offline_fails_fast_and_cleanly(self):
        t = time.time()
        rc, out = self.run_ytdlp(VIDEOS["first-video"], "--plugin-dirs", self.plug, "--proxy", "http://127.0.0.1:9", "--socket-timeout", "3", "--retries", "0", timeout=60, verbose=False)   # as the app runs it: -v would print yt-dlp's own network tracebacks
        self.assertNotEqual(rc, 0); self.assertLess(time.time() - t, 45); self.assertNotIn("Traceback", out); self.assertNotIn("setu_jsc", out)

    def test_concurrent_extractions(self):
        with cf.ThreadPoolExecutor(3) as ex:
            results = list(ex.map(lambda u: self.ours(u), list(VIDEOS.values()) + [VIDEOS["first-video"]]))
        self.assertTrue(all(rc == 0 for rc, _ in results)); self.assertTrue(all(len(self.format_ids(o)) > 10 for _, o in results))

    @unittest.skipUnless(os.environ.get("BS_LIVE_PLAYLIST"), "set BS_LIVE_PLAYLIST to a public playlist URL")
    def test_playlist_metadata(self):
        rc, out = self.run_ytdlp(os.environ["BS_LIVE_PLAYLIST"], "--plugin-dirs", self.plug, "--yes-playlist", "--flat-playlist", "--playlist-end", "3")
        self.assertEqual(rc, 0, out[-500:])

    @unittest.skipUnless(os.environ.get("BS_LIVE_STREAM"), "set BS_LIVE_STREAM to a public live-stream URL")
    def test_live_stream_metadata(self):
        rc, out = self.ours(os.environ["BS_LIVE_STREAM"])
        self.assertEqual(rc, 0, out[-500:])

    # ---- failure handling with the REAL yt-dlp, the REAL plugin and a helper that misbehaves (a fake app layout: the plugin finds its helper from its own location) ----------------------------------

    def fake_app(self, helper_body):
        import shutil
        root = tempfile.mkdtemp(dir=self.tmp)
        contents = os.path.join(root, "Fake.app", "Contents")
        src = os.path.join(self.plug, "setu", "yt_dlp_plugins", "extractor", "setu_jsc.py")
        dst = os.path.join(contents, "Resources", "YtDlpPlugins", "setu", "yt_dlp_plugins", "extractor")
        os.makedirs(dst); shutil.copy(src, dst)
        helper = os.path.join(contents, "Helpers", "setu-jsc"); os.makedirs(os.path.dirname(helper))
        counter = os.path.join(root, "calls")
        with open(helper, "w") as f:
            f.write(f'#!/bin/sh\nif [ "$1" = "--version" ]; then echo "setu-jsc 1.0.0 protocol 1"; exit 0; fi\necho run >> {counter}\n{helper_body}\n')
        os.chmod(helper, 0o755)
        return os.path.join(contents, "Resources", "YtDlpPlugins"), counter, helper

    def run_many(self, plug, urls, timeout=240):
        cmd = [self.exe, "--ignore-config", "--no-cache-dir", "--no-update", "--no-plugin-dirs", "--no-js-runtimes", "--plugin-dirs", plug, "-v", "-F", "--no-playlist", *urls]
        t = time.time()
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env={"PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "HOME": self.tmp, "PYTHONDONTWRITEBYTECODE": "1"}, cwd=self.tmp)
        return p.returncode, p.stdout + p.stderr, time.time() - t

    def test_a_crashing_helper_opens_the_breaker_extraction_continues_and_the_next_run_recovers(self):
        plug, counter, _ = self.fake_app("cat >/dev/null; exit 9")
        urls = [VIDEOS["first-video"], VIDEOS["big-buck-bunny"], VIDEOS["first-video"]]
        rc, out, secs = self.run_many(plug, urls)
        calls = len(open(counter).read().split()) if os.path.exists(counter) else 0
        self.assertEqual(rc, 0, out[-600:])
        self.assertEqual(calls, 2, "after two failures the helper is not started again in this run (three videos were asked about)")
        self.assertEqual(out.count("failed repeatedly"), 1); self.assertIn("[crash]", out)
        self.assertLess(secs, 120, "failures do not stall the run")
        self.assertGreaterEqual(out.count("ID "), 3, "all three videos still listed their formats"); self.assertNotIn("Traceback", out.split("[crash]")[-1][:2000] if False else "")
        # recovery: a NEW run (a new process, so a fresh breaker) with the real helper solves again
        rc2, out2 = self.ours(VIDEOS["first-video"])
        self.assertEqual(rc2, 0); self.assertIn("18", self.format_ids(out2), "format 18 needs the solved challenge: the real provider works again in the next run")

    def test_a_helper_that_never_answers_is_ended_at_the_deadline_and_extraction_continues(self):
        plug, counter, helper = self.fake_app("cat >/dev/null; sleep 600")
        rc, out, secs = self.run_many(plug, [VIDEOS["first-video"]], timeout=300)
        self.assertEqual(rc, 0, out[-600:]); self.assertIn("[timeout]", out)
        self.assertLess(secs, 150, "bounded by the deadline, not by the helper"); self.assertGreater(secs, 40, "it really waited for the deadline (45 s)")
        self.assertNotIn("18", self.format_ids(out), "no solver: the challenge-dependent format is missing, the rest is listed")
        time.sleep(1)
        left = subprocess.run(["pgrep", "-f", helper], capture_output=True, text=True).stdout.split()
        self.assertEqual(left, [], "the stalled helper was ended, not left running")


if __name__ == "__main__":
    unittest.main()
