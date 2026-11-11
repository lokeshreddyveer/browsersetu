import importlib.util, os, unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
spec = importlib.util.spec_from_file_location("check_architecture", os.path.join(ROOT, "scripts", "check-architecture.py"))
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)


class ArchitectureRecordTests(unittest.TestCase):
    def test_repository_is_consistent_with_the_decision_record(self):
        self.assertEqual(mod.check(), [])

    def test_a_bundling_claim_is_detected(self):
        line = "yt-dlp is bundled inside the app."
        self.assertTrue(mod.TOOLS.search(line) and mod.CLAIM.search(line) and not mod.NEGATION.search(line))

    def test_negated_and_plugin_statements_are_allowed(self):
        for line in ("ffmpeg is never bundled inside the app.", "The yt-dlp plugin is inside the app.", "No tool is part of the app."):
            self.assertFalse(mod.TOOLS.search(line) and mod.CLAIM.search(line) and not mod.NEGATION.search(line), line)


if __name__ == "__main__":
    unittest.main()


class ReleaseProvenanceGuardTests(unittest.TestCase):
    def read(self, rel):
        with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
            return f.read()

    def test_production_build_requires_a_clean_pushed_commit_and_records_hashes(self):
        s = self.read("scripts/release.sh")
        for needle in ('git status --porcelain', 'branch -r --contains HEAD', '"artifacts"', 'sha256'):
            self.assertIn(needle, s)

    def test_publish_tags_the_built_commit_and_matches_the_recorded_hash(self):
        s = self.read("scripts/publish-release.sh")
        for needle in ('--target "$SRC_COMMIT"', '"artifacts"', 'source_dirty'):
            self.assertIn(needle, s)
