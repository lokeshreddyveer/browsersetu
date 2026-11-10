#if os(macOS)
import XCTest
@testable import Browser_Setu

/// The app lets yt-dlp load Browser Setu's JavaScript challenge plugin only when the helper, the WHOLE plugin folder and the manifest all match their pins, the manifest was written for the pinned yt-dlp, and
/// the helper's code signature is the app's own team's. These tests build a fake app folder and break one thing at a time.
final class JSChallengeProviderTests: XCTestCase {
    private var root: URL!
    private var contents: URL { root.appendingPathComponent("Fake.app/Contents", isDirectory: true) }
    private let team = "X4MH29QNRS"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("jsc-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private struct Parts { var helper = Data("#!/bin/sh\necho helper\n".utf8); var plugin = Data("# plugin\n".utf8); var ytDlp = "2026.10.26"; var pinned = "2026.10.26" }
    private let signedOK: (URL, String) -> Bool = { _, _ in true }

    /// The whole check with a stub for the (separately tested) signature judgement.
    private func verified(team override: String? = nil, signature: ((URL, String) -> Bool)? = nil) -> URL? {
        JSChallengeProvider.verifiedPluginFolder(contents: contents, team: override ?? team, helperSignatureCheck: signature ?? signedOK)
    }

    @discardableResult
    private func build(_ p: Parts = Parts(), mutate: (inout [String: Any]) -> Void = { _ in }, helperMode: Int = 0o755, pinTreeAfter: (() throws -> Void)? = nil) throws -> URL {
        let fm = FileManager.default
        let res = contents.appendingPathComponent("Resources", isDirectory: true)
        let pluginDir = res.appendingPathComponent("YtDlpPlugins/setu/yt_dlp_plugins/extractor", isDirectory: true)
        try fm.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: contents.appendingPathComponent("Helpers"), withIntermediateDirectories: true)
        let helperURL = contents.appendingPathComponent("Helpers/setu-jsc"), pluginURL = pluginDir.appendingPathComponent("setu_jsc.py")
        try p.helper.write(to: helperURL); try p.plugin.write(to: pluginURL)
        try fm.setAttributes([.posixPermissions: helperMode], ofItemAtPath: helperURL.path)
        try pinTreeAfter?()          // extra files that exist BEFORE the pin is taken (the pin then covers them: used to show the pin itself is over the whole folder)
        var m: [String: Any] = ["schemaVersion": 1, "name": "setu-jsc", "version": "1.0.0", "helper": "Helpers/setu-jsc", "helperSHA256": ManagedTool.sha256(of: helperURL)!,
                                "pluginDirectory": "YtDlpPlugins", "plugin": "YtDlpPlugins/setu/yt_dlp_plugins/extractor/setu_jsc.py", "pluginSHA256": ManagedTool.sha256(of: pluginURL)!,
                                "pluginTreeSHA256": ManagedTool.treeDigest(of: res.appendingPathComponent("YtDlpPlugins"))!,
                                "architectures": ["arm64"], "signaturePolicy": "teamID:\(team)", "entitlements": ["com.apple.security.app-sandbox"], "pinnedYtDlpVersion": p.pinned]
        mutate(&m)
        try JSONSerialization.data(withJSONObject: m).write(to: res.appendingPathComponent("BundledJSProvider.json"))
        try JSONSerialization.data(withJSONObject: ["name": "yt-dlp", "version": p.ytDlp]).write(to: res.appendingPathComponent("BundledTools.json"))
        return contents
    }

    private var pluginRoot: URL { contents.appendingPathComponent("Resources/YtDlpPlugins", isDirectory: true) }

    func testAMatchingProviderIsOfferedToYtDlp() throws {
        try build()
        let folder = try XCTUnwrap(verified())
        XCTAssertTrue(folder.path.hasSuffix("Contents/Resources/YtDlpPlugins"))
        XCTAssertEqual(JSChallengeProvider.pluginArguments(contents: contents, team: team, helperSignatureCheck: signedOK), ["--plugin-dirs", folder.path])
    }

    func testNoManifestMeansNoPluginAndUnchangedArguments() throws {
        XCTAssertNil(verified())
        XCTAssertEqual(JSChallengeProvider.pluginArguments(contents: contents, team: team, helperSignatureCheck: signedOK), [])
        // outside a real app bundle (tests, Debug runs) the extractor's options are exactly the long-standing four
        XCTAssertEqual(BundledExtractor.extraArguments, BundledExtractor.baseArguments)
        XCTAssertEqual(BundledExtractor.baseArguments, ["--ignore-config", "--no-cache-dir", "--no-update", "--no-plugin-dirs", "--no-js-runtimes"])
    }

    func testBaseOptionsStillClearEveryOtherPluginLocation() {
        XCTAssertTrue(BundledExtractor.baseArguments.contains("--no-plugin-dirs"), "--no-plugin-dirs must come before --plugin-dirs so only the verified folder can load")
        XCTAssertTrue(BundledExtractor.baseArguments.contains("--no-js-runtimes"), "yt-dlp's own default (a `deno` found in PATH) is switched off before any verified runtime is added")
    }

    func testATamperedHelperOrPluginIsRefused() throws {
        try build()
        try Data("#!/bin/sh\necho evil\n".utf8).write(to: contents.appendingPathComponent("Helpers/setu-jsc"))
        XCTAssertNil(verified(), "helper bytes differ from the pin")
        try? FileManager.default.removeItem(at: root); try setUpWithError()
        try build()
        try Data("import os; os.system('x')\n".utf8).write(to: contents.appendingPathComponent("Resources/YtDlpPlugins/setu/yt_dlp_plugins/extractor/setu_jsc.py"))
        XCTAssertNil(verified(), "plugin bytes differ from the pin")
    }

    /// yt-dlp imports every module under the folder it is given. Anything added next to the approved plugin must stop the whole provider.
    func testAnythingAddedToThePluginFolderIsRefused() throws {
        let intruders: [(String, (URL) throws -> Void)] = [
            ("a second module beside the plugin", { try Data("import os\n".utf8).write(to: $0.appendingPathComponent("setu/yt_dlp_plugins/extractor/evil.py")) }),
            ("a second plugin package", { try FileManager.default.createDirectory(at: $0.appendingPathComponent("evil/yt_dlp_plugins/extractor"), withIntermediateDirectories: true)
                                           try Data("import os\n".utf8).write(to: $0.appendingPathComponent("evil/yt_dlp_plugins/extractor/x.py")) }),
            ("a compiled cache file", { try FileManager.default.createDirectory(at: $0.appendingPathComponent("setu/yt_dlp_plugins/extractor/__pycache__"), withIntermediateDirectories: true)
                                         try Data([0, 1, 2]).write(to: $0.appendingPathComponent("setu/yt_dlp_plugins/extractor/__pycache__/setu_jsc.cpython-39.pyc")) }),
            ("a package init file", { try Data().write(to: $0.appendingPathComponent("setu/yt_dlp_plugins/__init__.py")) }),
            ("a symbolic link", { try FileManager.default.createSymbolicLink(at: $0.appendingPathComponent("setu/yt_dlp_plugins/extractor/link.py"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts")) }),
        ]
        for (label, add) in intruders {
            try? FileManager.default.removeItem(at: root); try setUpWithError()
            try build()
            XCTAssertNotNil(verified(), "control before adding: \(label)")
            try add(pluginRoot)
            XCTAssertNil(verified(), label)
            if case .builtIn = JSChallengeProvider.status(contents: contents, team: team, helperSignatureCheck: signedOK) { XCTFail("must not be built in: \(label)") }
        }
    }

    func testAMissingOrNonExecutableHelperIsRefused() throws {
        try build(helperMode: 0o644)
        XCTAssertNil(verified())
        try FileManager.default.removeItem(at: contents.appendingPathComponent("Helpers/setu-jsc"))
        XCTAssertNil(verified())
    }

    func testAManifestWrittenForAnotherYtDlpIsRefused() throws {
        try build(Parts(ytDlp: "2026.11.30", pinned: "2026.10.26"))
        XCTAssertNil(verified(), "the plugin was only checked against the pinned release")
    }

    func testManifestsThatClaimMorePowerOrEscapeTheAppAreRefused() throws {
        let cases: [(String, (inout [String: Any]) -> Void)] = [
            ("extra entitlement", { $0["entitlements"] = ["com.apple.security.app-sandbox", "com.apple.security.network.client"] }),
            ("no entitlement", { $0["entitlements"] = [String]() }),
            ("wrong name", { $0["name"] = "deno" }),
            ("ad-hoc policy", { $0["signaturePolicy"] = "adhoc" }),
            ("another team", { $0["signaturePolicy"] = "teamID:AAAAAAAAAA" }),
            ("future schema", { $0["schemaVersion"] = 2 }),
            ("helper outside the app", { $0["helper"] = "../../bin/sh" }),
            ("absolute helper", { $0["helper"] = "/bin/sh" }),
            ("plugin outside its folder", { $0["plugin"] = "BundledTools.json" }),
            ("plugin folder escapes", { $0["pluginDirectory"] = ".." }),
            ("plugin folder is the whole Resources folder", { $0["pluginDirectory"] = "." }),
            ("plugin folder is Resources with a dot", { $0["pluginDirectory"] = "./" }),
            ("plugin folder is nested", { $0["pluginDirectory"] = "YtDlpPlugins/setu" }),
            ("plugin path uses a dot", { $0["plugin"] = "YtDlpPlugins/./setu/yt_dlp_plugins/extractor/setu_jsc.py" }),
            ("universal", { $0["architectures"] = ["arm64", "x86_64"] }),
            ("wrong tree pin", { $0["pluginTreeSHA256"] = String(repeating: "0", count: 64) }),
            ("missing tree pin", { $0.removeValue(forKey: "pluginTreeSHA256") }),
        ]
        for (label, change) in cases {
            try? FileManager.default.removeItem(at: root); try setUpWithError()
            try build(mutate: change)
            XCTAssertNil(verified(), label)
        }
    }

    func testTheHelpersSignatureIsJudgedByTheAppAndTheManifestAloneIsNotEnough() throws {
        try build()
        XCTAssertNil(verified(signature: { _, _ in false }), "a helper whose code signature is not the team's is never offered, whatever the manifest says")
        XCTAssertNil(JSChallengeProvider.verifiedPluginFolder(contents: contents, team: nil, ownTeam: { nil }, helperSignatureCheck: signedOK), "an unsigned app (no Team ID of its own) never uses the provider, whatever signed this test host")
        XCTAssertEqual(try? JSChallengeProvider.verify(contents: contents, team: nil, ownTeam: { self.team }, helperSignatureCheck: signedOK).get().lastPathComponent, "YtDlpPlugins", "an app signed by the manifest's team does")
        XCTAssertNil(verified(team: "AAAAAAAAAA"), "the app's team must equal the manifest's team")
        var asked: (URL, String)?
        _ = verified(signature: { asked = ($0, $1); return true })
        XCTAssertEqual(asked?.0.lastPathComponent, "setu-jsc"); XCTAssertEqual(asked?.1, team)
    }

    func testTheRealSignatureCheckRefusesAnUnsignedOrAdHocProgram() throws {
        try build()
        let helper = contents.appendingPathComponent("Helpers/setu-jsc")
        XCTAssertFalse(JSChallengeProvider.helperIsSignedAsRequired(helper, team: team), "a shell script has no signature")
        let adhoc = root.appendingPathComponent("adhoc"); try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: adhoc)
        _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["--force", "-s", "-", adhoc.path]).waitUntilExit()
        XCTAssertFalse(JSChallengeProvider.helperIsSignedAsRequired(adhoc, team: team), "an ad-hoc signature is not a Developer ID of the team")
        XCTAssertFalse(JSChallengeProvider.helperIsSignedAsRequired(URL(fileURLWithPath: "/usr/bin/true"), team: team), "Apple's own program is not ours")
    }

    /// Opt-in: the REAL built app. Run with TEST_RUNNER_BS_APP=<path to a built Browser Setu.app>.
    func testTheRealBuiltAppIsAcceptedByTheRealVerifier() throws {
        guard let app = ProcessInfo.processInfo.environment["BS_APP"], !app.isEmpty else { throw XCTSkip("set TEST_RUNNER_BS_APP to a built app") }
        let c = URL(fileURLWithPath: app).appendingPathComponent("Contents", isDirectory: true)
        let folder = try XCTUnwrap(JSChallengeProvider.verifiedPluginFolder(contents: c, team: team), "the built app's helper, plugin folder and manifest must pass the production check, signature included")
        XCTAssertTrue(folder.path.hasSuffix("Contents/Resources/YtDlpPlugins"))
        XCTAssertEqual(JSChallengeProvider.pluginArguments(contents: c, team: team), ["--plugin-dirs", folder.path])
        XCTAssertEqual(JSChallengeProvider.status(contents: c, team: team), .builtIn(version: "1.0.0"))
        XCTAssertNil(JSChallengeProvider.verifiedPluginFolder(contents: c, team: "AAAAAAAAAA"), "another team's Team ID is refused")
    }

    func testMalformedManifestIsRefused() throws {
        try build()
        try Data("{not json".utf8).write(to: contents.appendingPathComponent("Resources/BundledJSProvider.json"))
        XCTAssertNil(verified())
    }

    func testASymlinkedHelperThatLeavesTheAppIsRefused() throws {
        try build()
        let helper = contents.appendingPathComponent("Helpers/setu-jsc")
        try FileManager.default.removeItem(at: helper)
        try FileManager.default.createSymbolicLink(at: helper, withDestinationURL: URL(fileURLWithPath: "/bin/sh"))
        XCTAssertNil(verified())
    }

    func testStatusIsOnlyBuiltInWhenTheProviderVerifies() throws {
        XCTAssertEqual(JSChallengeProvider.status(contents: contents, team: team, helperSignatureCheck: signedOK), .unavailable(.notInThisBuild), "no manifest")
        try build()
        XCTAssertEqual(JSChallengeProvider.status(contents: contents, team: team, helperSignatureCheck: signedOK), .builtIn(version: "1.0.0"))
        try Data("tampered".utf8).write(to: contents.appendingPathComponent("Helpers/setu-jsc"))
        XCTAssertEqual(JSChallengeProvider.status(contents: contents, team: team, helperSignatureCheck: signedOK), .unavailable(.helperChanged), "a changed helper is never reported as built in, and the reason is named")
    }

    func testChallengeFailuresGetActionableTextAndOtherErrorsAreUnchanged() {
        for stderr in ["WARNING: [youtube] No supported JavaScript runtime could be found.", "ERROR: n challenge solving failed", "Signature solving failed: Some formats may be missing", "JS Challenge Providers: none"] {
            XCTAssertTrue(JSChallengeProviderAdvice.matches(stderr), stderr)
            XCTAssertEqual(ExtractorFailure.failed(1, JSChallengeProviderAdvice.marker + stderr).errorDescription, JSChallengeProviderAdvice.text, "the bundled extractor's failure gets the advice: \(stderr)")
            XCTAssertEqual(ExtractorFailure.failed(1, stderr).errorDescription, "The extractor reported an error (code 1): \(stderr)", "a failure from a yt-dlp the person chose is shown as it is: the built-in solver was never involved")
        }
        XCTAssertEqual(ExtractorFailure.failed(1, "ERROR: Video unavailable").errorDescription, "The extractor reported an error (code 1): ERROR: Video unavailable")
        XCTAssertFalse(JSChallengeProviderAdvice.text.contains("Deno"), "people are never told to install a runtime Browser Setu cannot install for them")
        XCTAssertFalse(JSChallengeProviderAdvice.text.lowercased().contains("install deno") || JSChallengeProviderAdvice.text.lowercased().contains("homebrew") || JSChallengeProviderAdvice.text.lowercased().contains("node"))
        XCTAssertTrue(JSChallengeProviderAdvice.text.contains("not affected"), "does not imply every website is affected or supported")
        XCTAssertTrue(JSChallengeProviderAdvice.text.contains("try again later") && JSChallengeProviderAdvice.text.contains("update"), "says what the person can actually do")
        XCTAssertTrue(JSChallengeProviderAdvice.text.contains("Settings > Media"), "points to the custom yt-dlp option, which exists")
    }
}
#endif
