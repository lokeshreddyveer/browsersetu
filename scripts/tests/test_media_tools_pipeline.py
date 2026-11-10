#!/usr/bin/env python3
"""Tests for the media-tools pipeline (scripts/media_tools_cache.py and the shell entry points).

Package tests: a real zip, real digests, real tree_digest.py; only the Mach-O inspection is replaced by a controllable stand-in, so every signing rule (Team ID, ad-hoc,
hardened runtime, chain, architecture, timestamp, notarization record) is exercised without Apple credentials. The shell-script cases run the real scripts.
Run:  python3 -I -m unittest discover -s scripts/tests -v     (from the repository root)
"""
import argparse, contextlib, copy, io, json, os, plistlib, shutil, stat, subprocess, sys, tempfile, unittest, zipfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import media_tools_cache as C  # noqa: E402

TEAM = "X4MH29QNRS"
GOOD = {"verified": True, "verify_error": "", "team": TEAM, "runtime": True, "adhoc": False, "timestamp": True, "archs": ["arm64"],
        "authorities": ["Developer ID Application: Test (X4MH29QNRS)", "Developer ID Certification Authority", "Apple Root CA"]}


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="mt-test-")
        self.cache = os.path.join(self.tmp, "cache")
        self.info = dict(GOOD)
        self._patches = [(C, "macho_info", lambda p: dict(self.info)), (C, "macho_files", lambda root: [os.path.join(root, "ffmpeg")] if os.path.isfile(os.path.join(root, "ffmpeg")) else [])]
        self._orig = [(m, n, getattr(m, n)) for m, n, _ in self._patches]
        for m, n, f in self._patches:
            setattr(m, n, f)

    def tearDown(self):
        for m, n, f in self._orig:
            setattr(m, n, f)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def args(self, **kw):
        d = dict(tool="ffmpeg", arch="arm64", team=TEAM, cache=self.cache, online=None)
        d.update(kw)
        return argparse.Namespace(**d)

    def make_build(self, content=b"#!/bin/sh\necho ffmpeg\n", name="build", team=TEAM, arch="arm64", licence=True):
        """A built package folder like release-media-tools.sh leaves: <tool>-<ver>-<arch>.zip + manifest-fragment.json."""
        b = os.path.join(self.tmp, name)
        os.makedirs(os.path.join(b, "tree"), exist_ok=True)
        exe = os.path.join(b, "tree", "ffmpeg")
        open(exe, "wb").write(content)
        os.chmod(exe, 0o755)
        if licence:
            open(os.path.join(b, "tree", "COPYING.LGPLv2.1"), "w").write("lgpl")          # licence texts travel INSIDE the signed package, as in the real one
        z = os.path.join(b, "ffmpeg-9.0.2-arm64.zip")
        with zipfile.ZipFile(z, "w") as zf:
            info = zipfile.ZipInfo("ffmpeg")
            info.external_attr = (stat.S_IFREG | 0o755) << 16
            zf.writestr(info, content)
            if licence:
                zf.writestr("COPYING.LGPLv2.1", "lgpl")
        json.dump({"sha256": C.sha256_file(z), "treeSHA256": C.tree_digest(os.path.join(b, "tree")), "size": os.path.getsize(z), "unpackedBytes": len(content),
                   "architectures": [arch], "signaturePolicy": "teamID:" + team}, open(os.path.join(b, "manifest-fragment.json"), "w"))
        return b

    def store(self, build=None, submission="sub-1", status="Accepted"):
        build = build or self.make_build()
        a = self.args(build=build, submission=submission, status=status, profile="P", signer="ABC")
        with contextlib.redirect_stdout(io.StringIO()):
            C.cmd_store(a)
        return C.entry_dir(self.cache, "ffmpeg", "arm64", TEAM)[0]

    def lookup(self, **kw):
        err = io.StringIO()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
            rc = C.cmd_lookup(self.args(**kw))
        return rc, err.getvalue()


class CacheKeyTests(Base):
    def test_key_is_stable_and_input_sensitive(self):
        k1 = C.cache_key("ffmpeg", "arm64", TEAM)[0]
        self.assertEqual(k1, C.cache_key("ffmpeg", "arm64", TEAM)[0])
        self.assertNotEqual(k1, C.cache_key("ffmpeg", "x86_64", TEAM)[0])
        self.assertNotEqual(k1, C.cache_key("ffmpeg", "arm64", "AAAAAAAAAA")[0])
        self.assertNotEqual(k1, C.cache_key("yt-dlp", "arm64", TEAM)[0])
        orig = C.recipe_digest
        C.recipe_digest = lambda: "0" * 64          # a changed packaging recipe invalidates every package
        try:
            self.assertNotEqual(k1, C.cache_key("ffmpeg", "arm64", TEAM)[0])
        finally:
            C.recipe_digest = orig

    def test_key_changes_with_the_pinned_version_or_source(self):
        orig = C.template
        for field, value in (("version", "9.9.9"), ("sourceArchiveSHA256", "f" * 64)):
            def t(tool, f=field, v=value):
                m = copy.deepcopy(orig(tool))
                if tool == "ffmpeg":
                    m[f] = v
                return m
            C.template = t
            try:
                self.assertNotEqual(C.cache_key("ffmpeg", "arm64", TEAM)[0], self.base_key(orig), field)
            finally:
                C.template = orig

    def base_key(self, orig):
        C.template = orig
        return C.cache_key("ffmpeg", "arm64", TEAM)[0]

    def test_clean_checkout_without_downloaded_or_built_trees_has_the_same_key(self):
        key = C.cache_key("ffmpeg", "arm64", TEAM)[0], C.cache_key("yt-dlp", "arm64", TEAM)[0]
        fake = os.path.join(self.tmp, "ThirdParty")
        for t in C.TOOLS:                              # only the committed templates, no bin/ folders
            os.makedirs(os.path.join(fake, t))
            shutil.copy(os.path.join(C.THIRD, t, "MANIFEST.json"), os.path.join(fake, t))
        old = C.THIRD
        C.THIRD = fake
        try:
            self.assertEqual(key, (C.cache_key("ffmpeg", "arm64", TEAM)[0], C.cache_key("yt-dlp", "arm64", TEAM)[0]))
            with self.assertRaises(C.Fail):             # but a REBUILD needs the tree, and says exactly what to run
                C.verify_inputs("ffmpeg")
        finally:
            C.THIRD = old


class CacheReuseTests(Base):
    def test_missing_entry_is_a_miss(self):
        self.assertEqual(self.lookup()[0], 3)

    def test_stored_valid_package_is_reused(self):
        entry = self.store()
        rc, err = self.lookup()
        self.assertEqual((rc, err), (0, ""), err)
        self.assertTrue(os.path.isfile(os.path.join(entry, "package.zip")))

    def test_reuse_survives_a_new_certificate_of_the_same_team(self):
        self.store()
        self.assertEqual(self.lookup()[0], 0)            # the key has the Team ID, not the certificate; the signature check is what matters

    def test_tampered_package_is_rejected(self):
        entry = self.store()
        z = os.path.join(entry, "package.zip")
        data = bytearray(open(z, "rb").read())
        data[len(data) // 2] ^= 0xFF
        open(z, "wb").write(bytes(data))
        rc, err = self.lookup()
        self.assertEqual(rc, 4)
        self.assertRegex(err, r"digest|corrupt|valid zip")

    def test_corrupt_truncated_zip(self):
        entry = self.store()
        z = os.path.join(entry, "package.zip")
        open(z, "wb").write(open(z, "rb").read()[:20])
        self.assertEqual(self.lookup()[0], 4)

    def test_replaced_zip_with_consistent_fragment_but_other_tree(self):
        entry = self.store()
        other = self.make_build(content=b"#!/bin/sh\necho evil\n", name="other")
        shutil.copy(os.path.join(other, "ffmpeg-9.0.2-arm64.zip"), os.path.join(entry, "package.zip"))
        rc, err = self.lookup()                          # zip digest no longer matches the recorded one
        self.assertEqual(rc, 4)
        self.assertIn("digest", err)

    def test_tree_digest_mismatch_with_matching_zip_digest(self):
        entry = self.store()
        frag = json.load(open(os.path.join(entry, "fragment.json")))
        frag["treeSHA256"] = "a" * 64
        json.dump(frag, open(os.path.join(entry, "fragment.json"), "w"))
        rc, err = self.lookup()
        self.assertEqual(rc, 4)
        self.assertIn("tree digest", err)

    def test_missing_files_in_entry(self):
        entry = self.store()
        os.remove(os.path.join(entry, "notarization.json"))
        rc, err = self.lookup()
        self.assertEqual(rc, 4)
        self.assertIn("missing notarization.json", err)

    def test_no_accepted_notarization_record(self):
        for status in ("Invalid", "In Progress", "Rejected"):
            shutil.rmtree(self.cache, ignore_errors=True)
            build = self.make_build(name="b-" + status.replace(" ", ""))
            with self.assertRaises(C.Fail):              # store itself refuses to cache an unnotarized package
                self.store(build, status=status)
            self.assertEqual(self.lookup()[0], 3)

    def test_notarization_record_for_a_different_zip(self):
        entry = self.store()
        n = json.load(open(os.path.join(entry, "notarization.json")))
        n["zipSHA256"] = "b" * 64
        json.dump(n, open(os.path.join(entry, "notarization.json"), "w"))
        rc, err = self.lookup()
        self.assertEqual(rc, 4)
        self.assertIn("notarization", err)

    def test_signature_rules(self):
        cases = {
            "wrong Team ID": ({"team": "AAAAAAAAAA"}, "Team ID"),
            "ad-hoc": ({"adhoc": True, "authorities": []}, "ad-hoc"),
            "no hardened runtime": ({"runtime": False}, "hardened runtime"),
            "no timestamp": ({"timestamp": False}, "timestamp"),
            "signature does not verify": ({"verified": False, "verify_error": "modified"}, "does not verify"),
            "wrong architecture": ({"archs": ["x86_64"]}, "architectures"),
            "universal when arm64 required": ({"archs": ["arm64", "x86_64"]}, "architectures"),
            "not a Developer ID chain": ({"authorities": ["Apple Development: x", "Apple Worldwide Developer Relations CA", "Apple Root CA"]}, "chain"),
        }
        for label, (change, expect) in cases.items():
            with self.subTest(label):
                shutil.rmtree(self.cache, ignore_errors=True)
                good = self.make_build(name="g-" + label.replace(" ", "_"))
                self.info = dict(GOOD)
                self.store(good)                          # stored while the tools verify...
                self.info = dict(GOOD, **change)          # ...then the same bytes are inspected as broken
                rc, err = self.lookup()
                self.assertEqual(rc, 4, label)
                self.assertRegex(err, expect)

    def test_store_refuses_a_package_that_does_not_verify(self):
        self.info = dict(GOOD, adhoc=True, authorities=[])
        with self.assertRaises(C.Fail):
            self.store()
        self.assertEqual(self.lookup()[0], 3)
        self.assertFalse([p for p in os.listdir(os.path.join(self.cache, "ffmpeg")) if p.endswith(".partial")] if os.path.isdir(os.path.join(self.cache, "ffmpeg")) else [])

    def test_a_failed_rebuild_keeps_the_previous_good_entry(self):
        entry = self.store()
        self.info = dict(GOOD, team="AAAAAAAAAA")
        with self.assertRaises(C.Fail):
            self.store(self.make_build(content=b"#!/bin/sh\necho new\n", name="new"))
        self.info = dict(GOOD)
        self.assertEqual(self.lookup()[0], 0)
        self.assertTrue(os.path.isdir(entry))

    def test_missing_or_non_executable_main_program(self):
        entry = self.store()
        # simulate a package whose main program lost its executable bit: rebuild the zip without the mode
        z = os.path.join(entry, "package.zip")
        with zipfile.ZipFile(z, "w") as zf:
            zf.writestr(zipfile.ZipInfo("ffmpeg"), b"#!/bin/sh\necho ffmpeg\n")
            zf.writestr("COPYING.LGPLv2.1", "lgpl")
        frag = json.load(open(os.path.join(entry, "fragment.json")))
        frag["sha256"] = C.sha256_file(z)
        frag["size"] = os.path.getsize(z)
        with tempfile.TemporaryDirectory() as t:
            open(os.path.join(t, "ffmpeg"), "w").write("#!/bin/sh\necho ffmpeg\n")
            open(os.path.join(t, "COPYING.LGPLv2.1"), "w").write("lgpl")
            frag["treeSHA256"] = C.tree_digest(t)
        json.dump(frag, open(os.path.join(entry, "fragment.json"), "w"))
        meta = json.load(open(os.path.join(entry, "meta.json"))); meta["zipSHA256"] = frag["sha256"]; json.dump(meta, open(os.path.join(entry, "meta.json"), "w"))
        n = json.load(open(os.path.join(entry, "notarization.json"))); n["zipSHA256"] = frag["sha256"]; json.dump(n, open(os.path.join(entry, "notarization.json"), "w"))
        rc, err = self.lookup()
        self.assertEqual(rc, 4)
        self.assertIn("not executable", err)

    def test_unsafe_zip_path_is_refused(self):
        build = self.make_build()
        z = os.path.join(build, "ffmpeg-9.0.2-arm64.zip")
        with zipfile.ZipFile(z, "a") as zf:
            zf.writestr("../escape", b"x")
        frag = json.load(open(os.path.join(build, "manifest-fragment.json")))
        frag["sha256"] = C.sha256_file(z); frag["size"] = os.path.getsize(z)
        json.dump(frag, open(os.path.join(build, "manifest-fragment.json"), "w"))
        with self.assertRaises(C.Fail):
            self.store(build)

    def test_upgrade_keeps_the_old_version_for_rollback(self):
        old = self.store()
        orig = C.template
        def newer(tool):
            m = copy.deepcopy(orig(tool))
            if tool == "ffmpeg":
                m["version"] = "9.0.3"
            return m
        C.template = newer
        try:
            self.assertEqual(self.lookup()[0], 3)        # new version: not cached yet, so it would be built
        finally:
            C.template = orig
        self.assertEqual(self.lookup()[0], 0)            # the previous release's package is untouched and reusable (rollback)
        self.assertTrue(os.path.isdir(old))


class ManifestTests(Base):
    def test_generated_manifest_drops_template_text_and_has_no_address_until_hosted(self):
        entry = self.store()
        m = C.generate_manifest("ffmpeg", entry)
        self.assertEqual(m["sourceURL"], "")
        self.assertNotIn("notes", m)
        self.assertEqual(m["signaturePolicy"], "teamID:" + TEAM)
        self.assertEqual(m["sha256"], json.load(open(os.path.join(entry, "fragment.json")))["sha256"])
        self.assertEqual(m["notarization"]["status"], "Accepted")
        self.assertEqual(C.validate_manifest(m, "ffmpeg"), [])

    def test_hosted_address_only_on_approved_hosts(self):
        entry = self.store()
        good = "https://github.com/lokeshreddyveer/browsersetu/releases/download/media-tools-ffmpeg-9.0.2/ffmpeg-9.0.2-arm64.zip"
        self.assertEqual(C.generate_manifest("ffmpeg", entry, good)["sourceURL"], good)
        with self.assertRaises(C.Fail):
            C.generate_manifest("ffmpeg", entry, "https://example.com/x.zip")
        with self.assertRaises(C.Fail):
            C.generate_manifest("ffmpeg", entry, "http://github.com/x.zip")

    def test_validator_rejects_malformed_manifests(self):
        entry = self.store()
        good = C.generate_manifest("ffmpeg", entry)
        bad = {
            "missing key": lambda m: m.pop("treeSHA256"),
            "stale notes key": lambda m: m.update(notes="Not hosted yet"),
            "stale text": lambda m: m.update(license="not hosted yet"),
            "bad sha": lambda m: m.update(sha256="xyz"),
            "ad-hoc policy": lambda m: m.update(signaturePolicy="adhoc"),
            "bad arch": lambda m: m.update(architectures=["ppc"]),
            "empty arch": lambda m: m.update(architectures=[]),
            "zero size": lambda m: m.update(size=0),
            "wrong schema": lambda m: m.update(schemaVersion=1),
            "wrong tool": lambda m: m.update(name="yt-dlp"),
        }
        for label, mutate in bad.items():
            with self.subTest(label):
                m = copy.deepcopy(good)
                mutate(m)
                self.assertTrue(C.validate_manifest(m, "ffmpeg"), label)
        self.assertTrue(C.validate_manifest("not a dict"))

    def test_template_placeholders_cannot_leak_into_a_shipped_manifest(self):
        t = C.template("ffmpeg")
        self.assertEqual(t["sha256"], "")                # the template carries no digest; a shipped manifest gets them only from a verified package
        self.assertTrue(C.validate_manifest(t, "ffmpeg"))


HOSTED_FFMPEG = "https://github.com/lokeshreddyveer/browsersetu/releases/download/media-tools-ffmpeg-9.0.2/ffmpeg-9.0.2-arm64.zip"


class AppCheckTests(Base):
    """check-app on a fabricated .app that carries manifests only; the packages they describe are in the (test) cache."""
    def make_app(self, version="1.0", url="", mutate=None, plant=None, build=None, offer=True):
        app = os.path.join(self.tmp, "Test.app")
        shutil.rmtree(app, ignore_errors=True)
        res = os.path.join(app, "Contents", "Resources")
        os.makedirs(os.path.join(res, "Notices"))
        os.makedirs(os.path.join(app, "Contents", "MacOS"))
        open(os.path.join(app, "Contents", "MacOS", "Test"), "w").write("x")
        plistlib.dump({"CFBundleShortVersionString": version}, open(os.path.join(app, "Contents", "Info.plist"), "wb"))
        entry = self.store(build)
        self.entries = {"ffmpeg": entry}
        if offer:
            with open(os.path.join(res, "Notices", "FFMPEG-source-offer.txt"), "w") as f:
                f.write("offer")
        m = C.generate_manifest("ffmpeg", entry, url or None)
        if mutate:
            mutate(m)
        json.dump(m, open(os.path.join(res, "BundledFFmpeg.json"), "w"))
        if plant:
            plant(app)
        self.res = res
        return app

    def check(self, app, tools=("ffmpeg",), readme=None, **kw):
        orig_tools, orig_app_arch = C.TOOLS, C.app_arch
        C.TOOLS, C.app_arch = tools, lambda a: ["arm64"]
        err, out = io.StringIO(), io.StringIO()
        try:
            with contextlib.redirect_stderr(err), contextlib.redirect_stdout(out):
                rc = C.cmd_check_app(argparse.Namespace(app=app, team=TEAM, readme=readme, cache=kw.get("cache", self.cache), hosted_verified=kw.get("hosted_verified", False),
                                                       sources_published=kw.get("sources_published", False), allow_unpublished_sources=kw.get("allow_unpublished", False)))
        finally:
            C.TOOLS, C.app_arch = orig_tools, orig_app_arch
        self.out = out.getvalue()
        return rc, err.getvalue()

    def readme(self, text):
        p = os.path.join(self.tmp, "README.md")
        open(p, "w").write(text)
        return p

    def test_a_consistent_manifests_only_app_passes(self):
        rc, err = self.check(self.make_app())
        self.assertEqual(rc, 0, err)
        self.assertIn("not bundled; manifests consistent with the verified packages", self.out)

    def test_a_tool_tree_in_the_app_is_refused(self):
        def plant(app):
            d = os.path.join(app, "Contents", "Resources", "Tools", "ffmpeg"); os.makedirs(d)
            open(os.path.join(d, "ffmpeg"), "w").write("x")
        rc, err = self.check(self.make_app(plant=plant))
        self.assertEqual(rc, 1)
        self.assertIn("a media tool is inside the app: Contents/Resources/Tools/ffmpeg/ffmpeg", err)

    def test_planted_tool_executables_anywhere_in_the_app_are_refused(self):
        for label, rel in (("yt-dlp in Helpers", "Contents/Helpers/yt-dlp"), ("yt-dlp_macos", "Contents/Resources/yt-dlp_macos"), ("ffmpeg", "Contents/MacOS/ffmpeg"),
                           ("ffprobe", "Contents/Frameworks/ffprobe")):
            def plant(app, rel=rel):
                path = os.path.join(app, rel); os.makedirs(os.path.dirname(path), exist_ok=True)
                open(path, "w").write("#!/bin/sh\n"); os.chmod(path, 0o755)
            rc, err = self.check(self.make_app(plant=plant))
            self.assertEqual(rc, 1, label); self.assertIn("a media tool is inside the app", err, label); self.assertIn(rel, err, label)

    def test_a_helpers_ytdlp_folder_is_refused_even_when_empty(self):
        rc, err = self.check(self.make_app(plant=lambda app: os.makedirs(os.path.join(app, "Contents", "Helpers", "yt-dlp"))))
        self.assertEqual(rc, 1); self.assertIn("Contents/Helpers/yt-dlp", err)

    def test_notices_named_like_the_tools_are_not_tools(self):
        def plant(app):
            open(os.path.join(app, "Contents", "Resources", "Notices", "YT-DLP-2026.10.26-NOTICE.txt"), "w").write("notice")     # not executable, not a Mach-O
        self.assertEqual(self.check(self.make_app(plant=plant))[0], 0)

    def test_the_manifest_must_equal_what_the_verified_package_generates(self):
        for label, mutate in (("tree digest", lambda m: m.update(treeSHA256="0" * 64)), ("zip digest", lambda m: m.update(sha256="1" * 64)), ("version", lambda m: m.update(version="9.9.9")),
                              ("size", lambda m: m.update(size=1)), ("notarization id", lambda m: m["notarization"].update(submissionID="forged"))):
            rc, err = self.check(self.make_app(mutate=mutate))
            self.assertEqual(rc, 1, label); self.assertIn("differs from the verified package's", err, label)

    def test_a_manifest_with_no_cached_package_cannot_be_checked(self):
        app = self.make_app()
        rc, err = self.check(app, cache=os.path.join(self.tmp, "empty-cache"))
        self.assertEqual(rc, 1); self.assertIn("no verified signed + notarized package in the cache", err)

    def test_the_cached_package_must_still_verify(self):
        app = self.make_app()
        self.info = dict(GOOD, adhoc=True, authorities=[])
        rc, err = self.check(app)
        self.assertEqual(rc, 1); self.assertIn("ad-hoc", err)

    def test_the_download_address_is_empty_or_the_hosted_pattern(self):
        app = self.make_app(url="https://github.com/lokeshreddyveer/browsersetu/releases/download/t/ffmpeg-9.0.2-arm64.zip")
        rc, err = self.check(app, hosted_verified=True)
        self.assertEqual(rc, 1); self.assertIn("neither empty nor the hosted address", err)

    def test_a_hosted_address_is_refused_unless_verified(self):
        app = self.make_app(url=HOSTED_FFMPEG)
        rc, err = self.check(app)
        self.assertEqual(rc, 1); self.assertIn("--hosted-verified", err)
        self.assertEqual(self.check(app, hosted_verified=True)[0], 0)

    def test_stale_manifest_text_is_refused(self):
        app = self.make_app(mutate=lambda m: m.update(notes="Not hosted yet"))
        rc, err = self.check(app)
        self.assertEqual(rc, 1)
        self.assertIn("unexpected key", err)

    def test_missing_source_offer(self):
        rc, err = self.check(self.make_app(offer=False))
        self.assertEqual(rc, 1); self.assertIn("source offer", err)

    def test_missing_licence_text_in_the_verified_package(self):
        rc, err = self.check(self.make_app(build=self.make_build(licence=False)))
        self.assertEqual(rc, 1); self.assertIn("LGPL licence", err)

    def test_readme_cannot_claim_the_tools_are_inside_the_app(self):
        for line in ("ffmpeg and yt-dlp come inside the app.", "yt-dlp is bundled.", "ffmpeg is embedded in the app.", "yt-dlp comes bundled inside the app (no JavaScript runtime needed)."):
            rc, err = self.check(self.make_app(), readme=self.readme(f"# R\n\n### New in 1.0\n\n- {line}\n\n## Next\n"))
            self.assertEqual(rc, 1, line); self.assertIn("optional downloads and the app carries none", err, line)

    def test_readme_may_describe_optional_downloads(self):
        ok = ("# R\n\n### New in 1.0\n\n- yt-dlp and ffmpeg are optional downloads you can install from Setup or Settings; they are not bundled in the app.\n"
              "- ffmpeg is installed on request and kept in its own folder.\n\n## Next\n")
        self.assertEqual(self.check(self.make_app(), readme=self.readme(ok))[0], 0)

    def test_readme_without_a_section_for_this_version(self):
        rc, err = self.check(self.make_app(version="9.9"), readme=self.readme("# R\n\n### New in 1.0\n\n- x\n\n## Next\n"))
        self.assertEqual(rc, 1)
        self.assertIn("New in 9.9", err)


class HostedPackageTests(Base):
    """The packages are uploaded separately: the asset has its hosted name, and the bytes at the address must be the verified package."""
    def test_hosted_address_scheme(self):
        self.assertEqual(C.hosted_url("ffmpeg", "9.0.2", "arm64"), HOSTED_FFMPEG)
        self.assertEqual(C.hosted_url("yt-dlp", "2026.10.26", "arm64"), "https://github.com/lokeshreddyveer/browsersetu/releases/download/media-tools-yt-dlp-2026.10.26/yt-dlp-2026.10.26-arm64.zip")

    def test_the_manifest_command_gives_the_hosted_address_only_when_asked(self):
        entry = self.store()
        out = os.path.join(self.tmp, "m.json")
        with contextlib.redirect_stdout(io.StringIO()):
            C.cmd_manifest(argparse.Namespace(tool="ffmpeg", entry=entry, out=out, hosted_url=None, hosted=False))
        self.assertEqual(json.load(open(out))["sourceURL"], "")
        with contextlib.redirect_stdout(io.StringIO()):
            C.cmd_manifest(argparse.Namespace(tool="ffmpeg", entry=entry, out=out, hosted_url=None, hosted=True))
        self.assertEqual(json.load(open(out))["sourceURL"], HOSTED_FFMPEG)

    def test_package_asset_has_the_hosted_name_and_the_recorded_digest(self):
        entry = self.store()
        out = os.path.join(self.tmp, "assets")
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            C.cmd_package_asset(argparse.Namespace(tool="ffmpeg", entry=entry, out=out))
        name, digest = buf.getvalue().split()
        self.assertEqual(name, "ffmpeg-9.0.2-arm64.zip")
        self.assertEqual(digest, json.load(open(os.path.join(entry, "fragment.json")))["sha256"])
        self.assertEqual(C.sha256_file(os.path.join(out, name)), digest)

    def test_package_asset_refuses_a_package_that_no_longer_verifies(self):
        entry = self.store()
        self.info = dict(GOOD, adhoc=True, authorities=[])
        with self.assertRaises(C.Fail):
            C.cmd_package_asset(argparse.Namespace(tool="ffmpeg", entry=entry, out=os.path.join(self.tmp, "assets")))

    def verify_hosted(self, entry, served):
        orig = C.fetch
        C.fetch = served
        err = io.StringIO()
        try:
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
                rc = C.cmd_verify_hosted(argparse.Namespace(tool="ffmpeg", entry=entry, url=None))
        finally:
            C.fetch = orig
        return rc, err.getvalue()

    def test_verify_hosted_accepts_exactly_the_verified_bytes(self):
        entry = self.store()
        good = open(os.path.join(entry, "package.zip"), "rb").read()
        asked = []
        rc, err = self.verify_hosted(entry, lambda url: (asked.append(url), good)[1])
        self.assertEqual((rc, asked), (0, [HOSTED_FFMPEG]), err)

    def test_verify_hosted_refuses_other_bytes_or_no_answer(self):
        entry = self.store()
        rc, err = self.verify_hosted(entry, lambda url: b"something else")
        self.assertEqual(rc, 1); self.assertIn("not the verified package", err)
        def boom(url): raise OSError("404")
        rc, err = self.verify_hosted(entry, boom)
        self.assertEqual(rc, 1); self.assertIn("cannot read", err)

    def test_the_real_fetch_reads_a_local_file_and_refuses_plain_http(self):
        entry = self.store()
        pkg = os.path.join(entry, "package.zip")
        self.assertEqual(C.fetch("file://" + pkg), open(pkg, "rb").read())
        with self.assertRaises(C.Fail):
            C.fetch("http://github.com/x.zip")
        rc = C.cmd_verify_hosted(argparse.Namespace(tool="ffmpeg", entry=entry, url="file://" + pkg))
        self.assertEqual(rc, 0)


class JSProviderCheckTests(Base):
    """check_js_provider on a fabricated app: the helper and plugin must be exactly what the manifest pins, signed and confined as required, and paired with this yt-dlp + EJS."""
    LIB, CORE = "/* lib */ var lib = {};\n", "/* core */ function jsc(){}\n"

    def plugin_text(self, ytdlp=("2026.10.26",), lib=None, core=None, extra="x = 1\n"):
        compat = {"provider": "1.1.0", "helperProtocol": 1, "ytDlp": list(ytdlp), "ejs": {"0.8.0": {"lib": C.hashlib.sha256((lib or self.LIB).encode()).hexdigest() if hasattr(C, "hashlib") else "", "core": ""}},
                  "scriptContract": 1, "challengeTypes": ["n", "sig"]}
        import hashlib
        compat["ejs"]["0.8.0"] = {"lib": hashlib.sha256((lib or self.LIB).encode()).hexdigest(), "core": hashlib.sha256((core or self.CORE).encode()).hexdigest()}
        return "COMPATIBILITY = " + json.dumps(compat, indent=4).replace("true", "True") + "\n" + extra

    def make(self, mutate=None, plugin=None, helper=b"#!/bin/sh\necho h\n", ytdlp="2026.10.26", pinned="2026.10.26", solver_lib=None, solver_core=None):
        app = os.path.join(self.tmp, "P.app")
        shutil.rmtree(app, ignore_errors=True)
        c = os.path.join(app, "Contents")
        pd = os.path.join(c, "Resources", "YtDlpPlugins", "setu", "yt_dlp_plugins", "extractor")
        self.tree = os.path.join(self.tmp, "verified-ytdlp-package")          # the app carries NO yt-dlp: the solver scripts come from the verified package unpacked from the cache
        shutil.rmtree(self.tree, ignore_errors=True)
        sd = os.path.join(self.tree, "_internal", "yt_dlp_ejs", "yt", "solver")
        os.makedirs(pd); os.makedirs(os.path.join(c, "Helpers")); os.makedirs(sd)
        open(os.path.join(sd, "lib.min.js"), "w").write(solver_lib if solver_lib is not None else self.LIB)
        open(os.path.join(sd, "core.min.js"), "w").write(solver_core if solver_core is not None else self.CORE)
        h = os.path.join(c, "Helpers", "setu-jsc"); pl = os.path.join(pd, "setu_jsc.py")
        open(h, "wb").write(helper); os.chmod(h, 0o755); open(pl, "w").write(plugin if plugin is not None else self.plugin_text())
        m = {"schemaVersion": 1, "name": "setu-jsc", "version": "1.0.0", "providerVersion": "1.1.0", "helperProtocol": 1, "helper": "Helpers/setu-jsc", "helperSHA256": C.sha256_file(h),
             "pluginDirectory": "YtDlpPlugins", "plugin": "YtDlpPlugins/setu/yt_dlp_plugins/extractor/setu_jsc.py", "pluginSHA256": C.sha256_file(pl), "pluginTreeSHA256": C.tree_digest(os.path.join(c, "Resources", "YtDlpPlugins")), "architectures": ["arm64"],
             "signaturePolicy": "teamID:" + TEAM, "entitlements": ["com.apple.security.app-sandbox"], "pinnedYtDlpVersion": pinned}
        if mutate:
            mutate(m)
        json.dump(m, open(os.path.join(c, "Resources", "BundledJSProvider.json"), "w"))
        return app, h, pl

    HEADER = "[debug] yt-dlp version stable@2026.10.26 from yt-dlp/yt-dlp [x] (darwin_dir)\n[debug] Optional libraries: certifi-1, yt_dlp_ejs-0.8.0\n[debug] Plugin directories: %s\n"

    def run_check(self, app, ents=("com.apple.security.app-sandbox",), ytdlp="2026.10.26", handshake="setu-jsc 1.0.0 protocol 1", header=None, selftest=()):
        orig = (C.entitlements, C.helper_handshake, C.ytdlp_debug_header, C.helper_selftest)
        folder = os.path.join(app, "Contents", "Resources", "YtDlpPlugins")
        C.entitlements, C.helper_handshake = (lambda path: list(ents)), (lambda path: handshake)
        C.ytdlp_debug_header = lambda a, f: (self.HEADER % os.path.join(f, "setu", "yt_dlp_plugins")) if header is None else header
        C.helper_selftest = lambda path: list(selftest)
        problems, notes = [], []
        try:
            ok = C.check_js_provider(app, TEAM, ["arm64"], ytdlp, problems, notes, self.tree)
        finally:
            C.entitlements, C.helper_handshake, C.ytdlp_debug_header, C.helper_selftest = orig
        return ok, problems

    def test_a_matching_signed_sandboxed_provider_passes(self):
        app, _, _ = self.make()
        ok, problems = self.run_check(app)
        self.assertTrue(ok, problems)

    def test_missing_manifest(self):
        app, _, _ = self.make()
        os.remove(os.path.join(app, "Contents", "Resources", "BundledJSProvider.json"))
        ok, problems = self.run_check(app)
        self.assertFalse(ok)
        self.assertIn("embed-js-provider.sh was not run", problems[0])

    def test_tampered_helper_or_plugin(self):
        app, h, pl = self.make()
        open(h, "ab").write(b"#")
        self.assertIn("helper differs", " ".join(self.run_check(app)[1]))
        app, h, pl = self.make()
        open(pl, "ab").write(b"#")
        self.assertIn("plugin differs", " ".join(self.run_check(app)[1]))

    def test_entitlements_must_be_exactly_the_app_sandbox(self):
        app, _, _ = self.make()
        for ents in (("com.apple.security.app-sandbox", "com.apple.security.network.client"), (), ("com.apple.security.cs.allow-jit",),
                     ("com.apple.security.app-sandbox", "com.apple.security.cs.allow-jit")):
            ok, problems = self.run_check(app, ents)
            self.assertFalse(ok, ents)
            self.assertIn("entitlements", " ".join(problems))

    def test_manifest_cannot_claim_other_entitlements(self):
        app, _, _ = self.make(mutate=lambda m: m.update(entitlements=["com.apple.security.app-sandbox", "com.apple.security.network.client"]))
        self.assertFalse(self.run_check(app)[0])

    def test_unsigned_adhoc_wrong_team_or_arch_helper(self):
        app, _, _ = self.make()
        for change, expect in (({"adhoc": True, "authorities": []}, "ad-hoc"), ({"team": "AAAAAAAAAA"}, "Team ID"), ({"archs": ["x86_64"]}, "architectures"), ({"runtime": False}, "hardened")):
            self.info = dict(GOOD, **change)
            ok, problems = self.run_check(app)
            self.assertFalse(ok)
            self.assertIn(expect, " ".join(problems))
        self.info = dict(GOOD)

    def test_written_for_another_ytdlp_release(self):
        app, _, _ = self.make(pinned="2026.10.26")
        ok, problems = self.run_check(app, ytdlp="2026.12.01")
        self.assertFalse(ok)
        self.assertIn("must be re-checked for every yt-dlp release", " ".join(problems))
        self.assertIn("was verified for yt-dlp", " ".join(problems), "the plugin's own compatibility record is checked too")

    def test_unverified_ejs_scripts_are_refused(self):
        app, _, _ = self.make(solver_lib="/* a different lib */\n")
        ok, problems = self.run_check(app)
        self.assertFalse(ok)
        self.assertIn("not a pairing the plugin was verified against", " ".join(problems))
        app, _, _ = self.make(solver_core="/* a different core */\n")
        self.assertFalse(self.run_check(app)[0])

    def test_missing_solver_scripts_are_refused(self):
        app, _, _ = self.make()
        shutil.rmtree(os.path.join(self.tree, "_internal"))
        ok, problems = self.run_check(app)
        self.assertFalse(ok)
        self.assertIn("solver scripts are not in the verified yt-dlp package", " ".join(problems))

    def test_handshake_must_match_version_and_protocol(self):
        app, _, _ = self.make()
        for said in ("", "setu-jsc 1.0.0 protocol 2", "setu-jsc 9.9.9 protocol 1", "garbage"):
            ok, problems = self.run_check(app, handshake=said)
            self.assertFalse(ok, said)
            self.assertIn("handshake", " ".join(problems))

    def test_manifest_provider_version_and_protocol_must_match_the_plugin(self):
        app, _, _ = self.make(mutate=lambda m: m.update(providerVersion="0.0.1"))
        self.assertIn("differ from the plugin's compatibility record", " ".join(self.run_check(app)[1]))
        app, _, _ = self.make(mutate=lambda m: m.update(helperProtocol=2))
        self.assertFalse(self.run_check(app)[0])

    def test_anything_added_to_the_plugin_folder_is_refused(self):
        for label, rel, content in (("extra module", "setu/yt_dlp_plugins/extractor/evil.py", "import os\n"), ("second package", "evil/yt_dlp_plugins/extractor/x.py", "import os\n"),
                                    ("cache file", "setu/yt_dlp_plugins/extractor/__pycache__/setu_jsc.cpython-39.pyc", "x"), ("init file", "setu/yt_dlp_plugins/__init__.py", "")):
            app, _, _ = self.make()
            path = os.path.join(app, "Contents", "Resources", "YtDlpPlugins", rel)
            os.makedirs(os.path.dirname(path), exist_ok=True); open(path, "w").write(content)
            ok, problems = self.run_check(app)
            self.assertFalse(ok, label)
            self.assertIn("plugin folder holds", " ".join(problems), label)

    def test_a_changed_plugin_tree_pin_is_refused(self):
        app, _, _ = self.make(mutate=lambda m: m.update(pluginTreeSHA256="0" * 64))
        self.assertIn("pinned tree digest", " ".join(self.run_check(app)[1]))

    def test_manifest_paths_must_stay_inside_the_app(self):
        for field, value in (("helper", "/bin/sh"), ("helper", "../../bin/sh"), ("plugin", "../x.py"), ("pluginDirectory", "."), ("pluginDirectory", ".."), ("pluginDirectory", "YtDlpPlugins/setu"), ("helper", "Helpers/./setu-jsc")):
            app, _, _ = self.make(mutate=lambda m, f=field, v=value: m.update({f: v}))
            ok, problems = self.run_check(app)
            self.assertFalse(ok, (field, value)); self.assertIn("escapes the app", " ".join(problems))

    def test_the_real_ejs_version_and_the_plugin_folder_are_read_from_ytdlp_itself(self):
        app, _, _ = self.make()
        self.assertTrue(self.run_check(app)[0])
        for header, expect in ((self.HEADER.replace("yt_dlp_ejs-0.8.0", "yt_dlp_ejs-0.9.1") % "/x/setu/yt_dlp_plugins", "reports yt-dlp-ejs 0.9.1"),
                               ("[debug] yt-dlp version stable@2026.10.26 x\n[debug] Plugin directories: none\n", "yt-dlp reports yt-dlp-ejs none"),
                               (self.HEADER.replace("2026.10.26", "2026.12.01") % "/x", "does not report version")):
            ok, problems = self.run_check(app, header=header)
            self.assertFalse(ok, expect); self.assertIn(expect, " ".join(problems))
        ok, problems = self.run_check(app, header=self.HEADER % "/somewhere/else")
        self.assertFalse(ok); self.assertIn("did not find the provider plugin folder", " ".join(problems))

    def test_the_final_helpers_behaviour_is_checked_not_just_its_handshake(self):
        app, _, _ = self.make()
        ok, problems = self.run_check(app, selftest=["a stderr flood was not stopped by the output limit (exit 0)"])
        self.assertFalse(ok); self.assertIn("helper behaviour: a stderr flood", " ".join(problems))

    def test_solver_scripts_are_hashed_as_text_like_the_plugin_does(self):
        app, _, _ = self.make()
        lib = os.path.join(self.tree, "_internal", "yt_dlp_ejs", "yt", "solver", "lib.min.js")
        open(lib, "wb").write(self.LIB.replace("\n", "\r\n").encode())        # CRLF: bytes differ; as text (universal newlines) it is the pinned script
        self.assertTrue(self.run_check(app)[0])
        open(lib, "wb").write(b"\xef\xbb\xbf" + self.LIB.encode())              # a BOM changes the text: the plugin would refuse it, so the preflight must too
        self.assertFalse(self.run_check(app)[0])

    def test_plugin_without_a_compatibility_record(self):
        app, _, _ = self.make(plugin="x = 1\n")
        ok, problems = self.run_check(app)
        self.assertFalse(ok)
        self.assertIn("compatibility record", " ".join(problems))

    def test_plugin_that_does_not_compile(self):
        app, _, _ = self.make(plugin=self.plugin_text(extra="def broken(:\n"))
        ok, problems = self.run_check(app)
        self.assertFalse(ok)
        self.assertIn("does not compile", " ".join(problems))

    def test_readme_rules_follow_the_provider(self):
        p = os.path.join(self.tmp, "README.md")
        app = os.path.join(self.tmp, "R.app")
        os.makedirs(os.path.join(app, "Contents")); plistlib.dump({"CFBundleShortVersionString": "1.0"}, open(os.path.join(app, "Contents", "Info.plist"), "wb"))
        open(p, "w").write("# R\n\n### New in 1.0\n\n- yt-dlp is an optional download; no Deno or Node is needed.\n\n## Next\n")
        self.assertTrue(C.readme_claims(p, app, [], provider_ok=False), "'no Deno needed' is only allowed with a verified provider")
        self.assertEqual(C.readme_claims(p, app, [], provider_ok=True), [])


class ReleaseGateTests(AppCheckTests):
    """Preflight rules added after the independent review: no unreviewed runtime in the app, and the source-offer promise is a release gate."""
    def test_a_deno_manifest_or_file_in_the_app_is_refused(self):
        for label, make in (("manifest", lambda app: open(os.path.join(app, "Contents", "Resources", "BundledDeno.json"), "w").write("{}")),
                            ("tool folder", lambda app: (os.makedirs(os.path.join(app, "Contents", "Resources", "Tools", "deno")), open(os.path.join(app, "Contents", "Resources", "Tools", "deno", "deno"), "w").write("x"))),
                            ("stray binary elsewhere", lambda app: open(os.path.join(app, "Contents", "Helpers_deno"), "w").write("x") if False else (os.makedirs(os.path.join(app, "Contents", "Helpers"), exist_ok=True), open(os.path.join(app, "Contents", "Helpers", "deno"), "w").write("x"))),
                            ("node", lambda app: (os.makedirs(os.path.join(app, "Contents", "Helpers"), exist_ok=True), open(os.path.join(app, "Contents", "Helpers", "node"), "w").write("x")))):
            app = self.make_app()
            make(app)
            rc, err = self.check(app)
            self.assertEqual(rc, 1, label); self.assertIn("unreviewed JavaScript runtime", err, label)

    def test_files_that_merely_contain_the_letters_are_not_flagged(self):
        app = self.make_app()
        os.makedirs(os.path.join(app, "Contents", "Frameworks"), exist_ok=True)
        for n in ("libdenoise.dylib", "nodeps.txt", "denominator.json"): open(os.path.join(app, "Contents", "Frameworks", n), "w").write("x")
        self.assertEqual(C.check_no_unreviewed_runtime(app), [])

    def test_the_source_offer_promise_needs_confirmation_for_a_real_release(self):
        app = self.make_app()
        with open(os.path.join(app, "Contents", "Resources", "Notices", "YT-DLP-notice.txt"), "w") as f:
            f.write("Browser Setu publishes the source of everything below with the release that contains this package.")
        rc, err = self.check(app)
        self.assertEqual(rc, 1); self.assertIn("--sources-published", err)
        self.assertEqual(self.check(app, sources_published=True)[0], 0, "confirmed: allowed")
        self.assertEqual(self.check(app, allow_unpublished=True)[0], 0, "a --verify-only build may carry the promise, and says so")

    def test_the_recipe_fingerprint_of_the_notarized_packages_is_pinned(self):
        # Changing the packaging recipe changes every cache key, which means re-signing and re-notarizing yt-dlp and ffmpeg. That must be a deliberate act: update this value in the same change.
        self.assertTrue(C.recipe_digest().startswith("98efb747"), "the signing recipe changed: every cached notarized package would be rebuilt (update this pin only if that is intended)")

    def test_release_script_requires_the_confirmation_outside_verify_only(self):
        text = open(os.path.join(ROOT, "scripts", "release.sh")).read()
        self.assertIn('MEDIA_SOURCES_PUBLISHED:-}" = "1"', text); self.assertIn("--allow-unpublished-sources", text)
        i = text.index('elif [ "$VERIFY_ONLY" = 1 ]'); self.assertIn("allow-unpublished-sources", text[i:i + 120], "only a verify-only build may skip the confirmation")


class CompatibilityRecordTests(Base):
    def test_the_record_is_found_by_the_parser_not_a_pattern(self):
        path = os.path.join(self.tmp, "p.py")
        open(path, "w").write('COMPATIBILITY = {\n    "a": {\n"nested": 1,\n},\n    "b": [1, 2],\n}\nother = 5\n')
        self.assertEqual(C.plugin_compatibility(path), {"a": {"nested": 1}, "b": [1, 2]})
        open(path, "w").write("x = 1\n")
        with self.assertRaises(C.Fail): C.plugin_compatibility(path)
        real = C.plugin_compatibility(os.path.join(ROOT, "apps", "apple", "Helpers", "JSProvider", "yt_dlp_plugins", "extractor", "setu_jsc.py"))
        self.assertEqual(real["helperProtocol"], 1); self.assertIn("2026.10.26", real["ytDlp"])


class OptionalDenoPipelineTests(Base):
    """A managed Deno is PREPARED, not shipped: the pipeline can build, sign and cache it when asked by name, and nothing else changes."""
    def test_deno_is_optional_and_never_part_of_the_embedded_set(self):
        self.assertEqual(C.TOOLS, ("yt-dlp", "ffmpeg")); self.assertEqual(C.OPTIONAL_TOOLS, ("deno",)); self.assertIn("deno", C.ALL_TOOLS)
        script = open(os.path.join(ROOT, "scripts", "release-media-tools.sh")).read()
        self.assertIn("for t in yt-dlp ffmpeg; do", script, "`--tool all` builds exactly the embedded tools")
        embed = open(os.path.join(ROOT, "scripts", "embed-media-manifests.sh")).read()
        self.assertIn("for t in yt-dlp ffmpeg; do", embed); self.assertNotIn("deno", embed.lower(), "the manifest embedder never mentions Deno")
        rel = open(os.path.join(ROOT, "scripts", "release.sh")).read()
        self.assertNotIn("deno", rel.lower(), "a release never builds, embeds or requires Deno")

    def test_existing_packages_keep_their_keys(self):
        # The signing recipe gained an optional entitlements argument; the key of the ALREADY signed and notarized yt-dlp and ffmpeg packages must not move (they would need re-notarizing).
        self.assertEqual(C.cache_key("yt-dlp", "arm64", TEAM)[0][:16], "e5772a0f1b65e5cc")
        self.assertEqual(C.cache_key("ffmpeg", "arm64", TEAM)[0][:16], "fc21e20926743f23")

    def test_deno_key_depends_on_its_entitlements_and_pin(self):
        k = C.cache_key("deno", "arm64", TEAM)[0]
        self.assertNotEqual(k, C.cache_key("yt-dlp", "arm64", TEAM)[0])
        orig = C.ENTITLEMENTS["deno"]
        alt = os.path.join(self.tmp, "other.entitlements"); open(alt, "w").write("<plist/>")
        C.ENTITLEMENTS["deno"] = alt
        try: self.assertNotEqual(k, C.cache_key("deno", "arm64", TEAM)[0], "different entitlements are a different package")
        finally: C.ENTITLEMENTS["deno"] = orig
        t = C.template("deno"); self.assertEqual(t["upstream"]["teamID"], "2H4KBF436B"); self.assertRegex(t["upstream"]["sha256"], r"^[0-9a-f]{64}$")

    def test_the_entitlements_are_exactly_the_four_deno_needs(self):
        import plistlib
        d = plistlib.load(open(C.ENTITLEMENTS["deno"], "rb"))
        self.assertEqual(sorted(d), ["com.apple.security.cs.allow-jit", "com.apple.security.cs.allow-unsigned-executable-memory", "com.apple.security.cs.disable-executable-page-protection", "com.apple.security.cs.disable-library-validation"])
        self.assertTrue(all(v is True for v in d.values()))
        for forbidden in ("com.apple.security.network.client", "com.apple.security.app-sandbox", "com.apple.security.files.all"): self.assertNotIn(forbidden, d)

    def test_the_unsigned_input_must_be_upstreams_signed_release(self):
        orig_t, orig_i = C.template, C.macho_info
        fake = os.path.join(self.tmp, "ThirdParty"); os.makedirs(os.path.join(fake, "deno", "bin", "deno")); open(os.path.join(fake, "deno", "bin", "deno", "deno"), "w").write("x")
        tpl = orig_t("deno"); old = C.THIRD; C.THIRD = fake
        C.template = lambda tool: tpl
        try:
            C.macho_info = lambda p: {"team": "SOMEONEELSE", "verified": True, "archs": ["arm64"]}
            with self.assertRaises(C.Fail) as cm: C.verify_inputs("deno")
            self.assertIn("not signed by upstream's team", str(cm.exception))
            C.macho_info = lambda p: {"team": "2H4KBF436B", "verified": False, "archs": ["arm64"]}
            with self.assertRaises(C.Fail): C.verify_inputs("deno")
            C.macho_info = lambda p: {"team": "2H4KBF436B", "verified": True, "archs": ["x86_64"]}
            with self.assertRaises(C.Fail) as cm: C.verify_inputs("deno")
            self.assertIn("expected arm64", str(cm.exception))
        finally:
            C.THIRD = old; C.template = orig_t; C.macho_info = orig_i

    def test_a_deno_manifest_carries_forytdlp_and_validates(self):
        m = {"schemaVersion": 2, "name": "deno", "version": "2.9.8", "layout": "flat", "executable": "deno", "sourceURL": "", "sha256": "a" * 64, "treeSHA256": "b" * 64, "size": 1, "unpackedBytes": 1,
             "architectures": ["arm64"], "signaturePolicy": "teamID:" + TEAM, "forYtDlp": ["2026.10.26"]}
        self.assertEqual(C.validate_manifest(m, "deno"), [])
        self.assertIn("forYtDlp", C.MANIFEST_KEYS)


class ScriptTests(unittest.TestCase):
    """The real shell entry points, run against missing / wrong credentials. Nothing here can sign: every case must stop first."""
    def run_script(self, *args):
        p = subprocess.run([os.path.join(ROOT, "scripts", "release-media-tools.sh"), *args], capture_output=True, text=True,
                           env=dict(os.environ, MEDIA_TOOLS_CACHE=tempfile.mkdtemp(prefix="mt-cache-")))
        return p.returncode, p.stdout + p.stderr

    def test_ensure_refuses_a_name_instead_of_a_fingerprint(self):
        rc, out = self.run_script("--ensure", "--identity", "Developer ID Application: Someone (X4MH29QNRS)", "--team", TEAM, "--notary-profile", "P", "--tool", "ffmpeg")
        self.assertEqual(rc, 2)
        self.assertIn("SHA-1 fingerprint", out)

    def test_ensure_refuses_an_identity_that_is_not_in_the_keychain(self):
        rc, out = self.run_script("--ensure", "--identity", "0" * 40, "--team", TEAM, "--notary-profile", "P", "--tool", "ffmpeg")
        self.assertEqual(rc, 1)
        self.assertIn("not a valid 'Developer ID Application' certificate", out)

    def test_ensure_needs_a_notary_profile(self):
        env = {k: v for k, v in os.environ.items() if k != "NOTARY_PROFILE"}
        p = subprocess.run([os.path.join(ROOT, "scripts", "release-media-tools.sh"), "--ensure", "--identity", "0" * 40, "--team", TEAM, "--tool", "ffmpeg"], capture_output=True, text=True, env=env)
        self.assertEqual(p.returncode, 2)
        self.assertIn("notary-profile", p.stderr)

    def test_embed_manifests_fails_closed_without_a_cached_package(self):
        app = tempfile.mkdtemp(prefix="mt-app-")
        os.makedirs(os.path.join(app, "Contents", "Resources"))
        p = subprocess.run([os.path.join(ROOT, "scripts", "embed-media-manifests.sh"), app, "--team", TEAM, "--arch", "arm64", "--cache", tempfile.mkdtemp()], capture_output=True, text=True)
        self.assertEqual(p.returncode, 1)
        self.assertIn("no valid signed + notarized", p.stderr)
        self.assertFalse(os.path.exists(os.path.join(app, "Contents", "Resources", "BundledTools.json")), "no manifest is written for a package that is not verified")

    def test_embed_manifests_removes_any_bundled_tool_and_never_adds_one(self):
        text = open(os.path.join(ROOT, "scripts", "embed-media-manifests.sh")).read()
        self.assertIn('rm -rf "$RES/Tools"', text)
        for forbidden in ("unzip", "ditto", "cp -R", "package.zip"):
            self.assertNotIn(forbidden, text, f"the manifest embedder must not copy a package into the app ({forbidden})")
        self.assertIn("HOSTED:+--hosted", text, "the download address is only written when --hosted is given")

    def test_check_fails_on_an_app_with_no_tools(self):
        app = tempfile.mkdtemp(prefix="mt-app-")
        os.makedirs(os.path.join(app, "Contents", "Resources"))
        os.makedirs(os.path.join(app, "Contents", "MacOS"))
        shutil.copy("/usr/bin/true", os.path.join(app, "Contents", "MacOS", "x"))
        p = subprocess.run([os.path.join(ROOT, "scripts", "check-media-tools.sh"), app, "--team", TEAM], capture_output=True, text=True)
        self.assertEqual(p.returncode, 1)
        self.assertIn("is missing from the app", p.stderr)

    def test_release_script_has_no_second_embedding_path(self):
        text = open(os.path.join(ROOT, "scripts", "release.sh")).read()
        self.assertNotIn("MEDIA_TOOLS_PACKAGES", text)
        proj = open(os.path.join(ROOT, "apps", "apple", "project.yml")).read()
        self.assertNotIn("BUNDLE_MEDIA_TOOLS", proj)
        self.assertNotIn("ditto \"$TOOLS/bin/yt-dlp\"", proj)
        self.assertNotIn("embed-media-tools", text)
        self.assertFalse(os.path.exists(os.path.join(ROOT, "scripts", "embed-media-tools.sh")), "the old embedder is gone")
        self.assertIn("embed-media-manifests.sh", text)

    def test_release_script_passes_hosted_only_after_the_hosted_bytes_are_verified(self):
        text = open(os.path.join(ROOT, "scripts", "release.sh")).read()
        i = text.index('MEDIA_PACKAGES_HOSTED:-}" = "1"')
        j = text.index("verify-hosted", i); k = text.index('HOSTED_FLAG="--hosted"', i)
        self.assertLess(j, k, "verify-hosted runs before --hosted is ever passed")
        self.assertIn("HOSTED_VERIFIED_FLAG", text)


if __name__ == "__main__":
    unittest.main()
