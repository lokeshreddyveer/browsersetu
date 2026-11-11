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
