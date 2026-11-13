import importlib.util, os, subprocess, tempfile, unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
spec = importlib.util.spec_from_file_location("check_attribution", os.path.join(ROOT, "scripts", "check-attribution.py"))
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
HOOK = os.path.join(ROOT, ".githooks", "commit-msg")


class AttributionGuardTests(unittest.TestCase):
    def test_attribution_is_detected(self):
        for text in ["Fix a bug\n\nCo-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>\n", "x\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)\n",
                     "Written by ChatGPT", "Created with Copilot", '"author": "Codex"', "Contributors: Gemini"]:
            self.assertTrue(mod.scan_text(text, "t"), text)

    def test_the_products_own_feature_text_and_ordinary_words_are_not_attribution(self):
        for text in ["Lets AI tools (Claude Code, Gemini CLI, Codex, Cursor) use web pages through the Model Context Protocol.", "Click a link in the Claude app and it opens as a tab.",
                     "Pressing the cursor key moves the caret", "Co-Authored-By: Jane Doe <jane@example.org>", "Generated with AVAssetWriter and served by the fixture server"]:
            self.assertEqual(mod.scan_text(text, "t"), [], text)

    def test_the_repository_has_no_attribution_in_files_or_new_commits(self):
        self.assertEqual(mod.scan_files(mod.tracked()) + mod.scan_commits(), [])

    def test_the_hook_removes_trailers_and_keeps_the_rest(self):
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
            f.write("Add a feature\n\nBody line.\n\nCo-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>\nCo-Authored-By: Jane Doe <jane@example.org>\n🤖 Generated with [Claude Code](https://claude.com/claude-code)\n")
            path = f.name
        try:
            subprocess.run(["sh", HOOK, path], check=True)
            out = open(path).read()
            self.assertEqual(out, "Add a feature\n\nBody line.\n\nCo-Authored-By: Jane Doe <jane@example.org>\n")
        finally:
            os.unlink(path)

    def test_only_commits_after_the_baseline_are_checked_and_history_is_not_touched(self):
        with tempfile.TemporaryDirectory() as d:
            def git(*a): return subprocess.run(["git", "-c", "user.name=T", "-c", "user.email=t@example.org", *a], cwd=d, capture_output=True, text=True, check=True).stdout.strip()
            git("init", "-q"); open(os.path.join(d, "a"), "w").write("1")
            git("add", "a"); git("commit", "-q", "-m", "legacy\n\nCo-Authored-By: Claude <noreply@anthropic.com>")
            base = git("rev-parse", "HEAD")
            self.assertTrue(mod.scan_commits(repo=d, rev_range="HEAD"), "an unfiltered range sees the legacy commit")
            self.assertEqual(mod.scan_commits(repo=d, rev_range=f"{base}..HEAD"), [], "nothing after the baseline yet")
            open(os.path.join(d, "a"), "w").write("2"); git("add", "a"); git("commit", "-q", "-m", "new\n\nCo-Authored-By: Claude <noreply@anthropic.com>")
            self.assertEqual(len(mod.scan_commits(repo=d, rev_range=f"{base}..HEAD")), 1, "a new commit with attribution is caught")


class PolicyCoverageTests(unittest.TestCase):
    def test_every_trailer_type_in_the_policy_is_detected_and_stripped(self):
        for t in ["Signed-off-by: Claude <noreply@anthropic.com>", "Generated-by: ChatGPT", "Assisted-by: Copilot", "Co-authored-by: Gemini <g@example.com>"]:
            self.assertTrue(mod.scan_text("Fix\n\n" + t + "\n", "t"), t)
            with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
                f.write("Fix\n\n" + t + "\n"); path = f.name
            try:
                subprocess.run(["sh", HOOK, path], check=True); self.assertEqual(open(path).read(), "Fix\n", t)
            finally:
                os.unlink(path)

    def test_human_trailers_survive(self):
        for t in ["Signed-off-by: Jane Doe <jane@example.org>", "Co-authored-by: Sam Lee <sam@example.org>"]:
            with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
                f.write("Fix\n\n" + t + "\n"); path = f.name
            try:
                subprocess.run(["sh", HOOK, path], check=True); self.assertEqual(open(path).read(), "Fix\n\n" + t + "\n")
            finally:
                os.unlink(path)

    def test_technical_mentions_of_ai_are_not_blocked(self):
        for text in ["Browser Setu lets AI tools use shared tabs; Claude Code, Codex and Gemini CLI can connect.", "This build is AI-assisted search free.",
                     "The model context protocol is used by Claude, ChatGPT and Cursor.", "Suggestions are built with a local ranking, using no LLM."]:
            self.assertEqual(mod.scan_text(text, "t"), [], text)

    def test_the_hook_refuses_an_ai_identity_but_not_a_human_one(self):
        with tempfile.TemporaryDirectory() as d:
            subprocess.run(["git", "init", "-q"], cwd=d, check=True)
            msg = os.path.join(d, "msg"); open(msg, "w").write("A change\n")
            def run(name, email):
                env = dict(os.environ, GIT_AUTHOR_NAME=name, GIT_AUTHOR_EMAIL=email, GIT_COMMITTER_NAME=name, GIT_COMMITTER_EMAIL=email)
                return subprocess.run(["sh", HOOK, msg], cwd=d, env=env, capture_output=True, text=True).returncode
            self.assertEqual(run("Jane Doe", "jane@example.org"), 0)
            self.assertNotEqual(run("Claude", "noreply@anthropic.com"), 0)
            self.assertNotEqual(run("Jane Doe", "bot@openai.com"), 0)


if __name__ == "__main__":
    unittest.main()
