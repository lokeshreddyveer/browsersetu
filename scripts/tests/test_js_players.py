#!/usr/bin/env python3
"""OPTIONAL multi-version compatibility test (contacts YouTube's static player files; nothing is downloaded but player scripts, no video, no account).

It reuses the fixtures of yt-dlp's own EJS integration test (test/test_jsc/test_ejs_integration.py in the git-tag archive that `scripts/prepare-media-sources.py fetch` stages): REAL player versions and variants,
the challenge strings (including control characters, '%', '/', '=') and the EXACT answers they must produce. Each player is run through our real adapter (`ejs_script_v1`), the real solver scripts of the
built app, and the SHIPPED setu-jsc helper, and the answers are compared with the expected ones (and, when BS_DENO is given, with a Deno run of the same script, to tell an engine problem from an EJS limit).

  BS_LIVE=1 BS_APP=<built app> [BS_DENO=<deno>] [BS_PLAYERS_MAX=30] [BS_YTDLP_TAG_TAR=<git-tag archive>]  python3 -I -m unittest discover -s scripts/tests -p 'test_js_players.py' -v

A player that can no longer be downloaded is reported as UNVERIFIED (skipped), never as a pass.
"""
import dataclasses, enum, importlib.util, json, os, re, subprocess, sys, tarfile, tempfile, unittest, urllib.error, urllib.request
from ytdlp_tree_support import ytdlp_tree

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
APP, LIVE, DENO = os.environ.get("BS_APP"), os.environ.get("BS_LIVE") == "1", os.environ.get("BS_DENO")
TAR = os.environ.get("BS_YTDLP_TAG_TAR") or os.path.join(ROOT, "build", "media-sources", "yt-dlp-2026.10.26-git-tag.tar.gz")
UA = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"}


def load_challenges():
    with tarfile.open(TAR) as t:
        name = next(m.name for m in t.getmembers() if m.name.endswith("test/test_jsc/test_ejs_integration.py"))
        text = t.extractfile(name).read().decode()
    start = text.index("class Variant(enum.Enum):")
    end = re.search(r"^\]\n", text[text.index("CHALLENGES: list[Challenge] = ["):], re.M).end() + text.index("CHALLENGES: list[Challenge] = [")
    ns = {"dataclasses": dataclasses, "enum": enum}
    exec("from __future__ import annotations\nclass JsChallengeType(enum.Enum):\n    N = 'n'\n    SIG = 'sig'\n" + text[start:end], ns)
    return ns["CHALLENGES"]


def load_plugin():
    path = os.path.join(APP, "Contents", "Resources", "YtDlpPlugins", "setu", "yt_dlp_plugins", "extractor", "setu_jsc.py")
    spec = importlib.util.spec_from_file_location("setu_jsc_players", path)
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
    return mod


@unittest.skipUnless(LIVE and APP and os.path.exists(TAR), "set BS_LIVE=1, BS_APP, and stage the yt-dlp git-tag archive (scripts/prepare-media-sources.py fetch)")
class PlayerVersionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.plugin = load_plugin()
        tree = ytdlp_tree()
        if not tree: raise unittest.SkipTest("no verified yt-dlp package (media-tools cache or BS_YTDLP_TREE): the app carries none")
        solver = os.path.join(tree, "_internal", "yt_dlp_ejs", "yt", "solver")
        with open(os.path.join(solver, "lib.min.js"), encoding="utf-8") as f: cls.lib = f.read()
        with open(os.path.join(solver, "core.min.js"), encoding="utf-8") as f: cls.core = f.read()
        cls.helper = os.path.join(APP, "Contents", "Helpers", "setu-jsc")
        cls.tmp = tempfile.mkdtemp(prefix="players-")
        by = {}
        for c in load_challenges():
            by.setdefault((c.player, c.variant.value), {"n": {}, "sig": {}})[c.type.value].update(c.values)
        cls.groups = by
        cls.results = []

    @classmethod
    def tearDownClass(cls):
        import shutil; shutil.rmtree(cls.tmp, ignore_errors=True)
        ok = sum(1 for r in cls.results if r[1] == "match"); unver = [r for r in cls.results if r[1] == "unverified"]; bad = [r for r in cls.results if r[1] not in ("match", "unverified")]
        print(f"\n  PLAYER VERSIONS: {len(cls.results)} tried, {ok} matched yt-dlp's expected answers exactly, {len(unver)} UNVERIFIED (player no longer downloadable), {len(bad)} differ")
        for r in bad: print("   DIFFERS:", r)

    def fetch(self, player, variant):
        url = f"https://www.youtube.com/s/player/{player}/{variant}"
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=60) as r:
                return r.read().decode("utf-8")
        except (urllib.error.HTTPError, urllib.error.URLError):
            return None

    def run_engine(self, cmd, script):
        p = subprocess.run(cmd, input=script.encode(), capture_output=True, timeout=120)
        return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")

    def test_every_available_player_version_gives_the_expected_answers(self):
        limit = int(os.environ.get("BS_PLAYERS_MAX", "30"))
        for (player, variant), kinds in list(self.groups.items())[:limit]:
            with self.subTest(player=player, variant=variant):
                code = self.fetch(player, variant)
                if code is None:
                    self.results.append((player, "unverified")); self.skipTest(f"{player}/{variant} is no longer downloadable: UNVERIFIED"); continue
                groups = [(k, list(v)) for k, v in kinds.items() if v]
                script = self.plugin.ejs_script_v1(self.lib, self.core, code, groups)
                rc, out, err = self.run_engine([self.helper, "--deadline", "100", "-"], script)
                self.assertEqual(rc, 0, f"helper failed on {player}: {err[-200:]}")
                answers = self.plugin.validate_answer(out, groups)
                mismatches = []
                for (kind, challenges), (status, data) in zip(groups, answers):
                    if status != "ok":
                        mismatches.append((kind, "solver error", data)); continue
                    for ch, want in kinds[kind].items():
                        if data.get(ch) != want:
                            mismatches.append((kind, ch[:24], data.get(ch), want))
                if mismatches and DENO:                          # is it the engine, or does EJS itself not solve this player?
                    rcd, outd, _ = self.run_engine([DENO, "run", "--ext=js", "--no-code-cache", "--no-prompt", "--no-remote", "--no-lock", "--node-modules-dir=none", "--no-config", "--no-npm", "--cached-only", "-"], script)
                    same_as_deno = rcd == 0 and json.loads(outd) == json.loads(out)
                    self.results.append((player, f"differs from expected; identical to Deno: {same_as_deno}"))
                    self.assertTrue(same_as_deno, f"{player}/{variant}: native differs from expected AND from Deno: {mismatches[:2]}")
                    continue
                self.results.append((player, "match" if not mismatches else f"differs: {mismatches[:2]}"))
                self.assertEqual(mismatches, [], f"{player}/{variant}")


if __name__ == "__main__":
    unittest.main()
