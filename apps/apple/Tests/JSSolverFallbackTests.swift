#if os(macOS)
import XCTest
@testable import Browser_Setu

/// The explicit order of how YouTube's JavaScript puzzles are answered (native helper, then a verified managed Deno that is NOT part of 0.4.1, then no solver), the gates a managed Deno must pass, and the
/// guarantee that a yt-dlp the person chose themselves is never given any of it.
final class JSSolverFallbackTests: XCTestCase {
    private var root: URL!
    private let team = "X4MH29QNRS"
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("jss-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    // MARK: a fixture managed Deno (a stand-in program; the signature and architecture judgements are injected, and tested for real below)

    private struct Fixture { var tool: ManagedTool; var exe: URL }
    private func makeDeno(version: String = "2.9.8", forYtDlp: [String] = ["2026.10.26"], teamPolicy: String? = nil, architectures: [String]? = nil, mutate: (inout [String: Any]) -> Void = { _ in }) throws -> Fixture {
        let folder = root.appendingPathComponent("tools/deno", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let exe = folder.appendingPathComponent("deno"); try Data("#!/bin/sh\necho deno\n".utf8).write(to: exe)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        var pin: [String: Any] = ["name": "deno", "version": version, "sha256": "x", "sourceURL": "", "executable": "deno", "layout": "flat", "treeSHA256": ManagedTool.treeDigest(of: folder)!,
                                  "architectures": architectures ?? [ManagedDeno.thisMacsArchitecture], "signaturePolicy": teamPolicy ?? "teamID:\(team)", "forYtDlp": forYtDlp]
        mutate(&pin)
        let pinURL = root.appendingPathComponent("BundledDeno.json"); try JSONSerialization.data(withJSONObject: pin).write(to: pinURL)
        let tool = ManagedTool(resource: "BundledDenoTest", component: "denotest")
        tool.manifestURL = pinURL; tool.helpersFolder = root.appendingPathComponent("tools", isDirectory: true); tool.forgetCache()
        return Fixture(tool: tool, exe: exe)
    }
    private let signedOK: (URL, String) -> Bool = { _, _ in true }
    private func arch(_ a: [String]? = nil) -> (URL) -> [String] { { _ in a ?? [ManagedDeno.thisMacsArchitecture] } }
    private func verify(_ f: Fixture, yt: String? = "2026.10.26", team t: String? = nil, signature: ((URL, String) -> Bool)? = nil, arch a: [String]? = nil) -> Result<ManagedDeno.Verified, ManagedDeno.Unavailable> {
        ManagedDeno.verify(tool: f.tool, ytDlpVersion: yt, team: t ?? team, signatureCheck: signature ?? signedOK, architectures: arch(a))
    }

    // MARK: 0.4.1 reality

    func testNothingInThisReleaseOffersAManagedDenoAndNoArgumentIsAdded() {
        let none = ManagedTool(resource: "BundledDenoDoesNotExist", component: "denotest2")
        XCTAssertEqual(ManagedDeno.verify(tool: none, ytDlpVersion: "2026.10.26", team: team), .failure(.notOffered))
        XCTAssertEqual(ManagedDeno.runtimeArguments(tool: none, ytDlpVersion: "2026.10.26", team: team), [])
        XCTAssertNil(Bundle.main.url(forResource: "BundledDeno", withExtension: "json"), "no BundledDeno.json is built into any 0.4.1 app")
        XCTAssertEqual(BundledExtractor.extraArguments, BundledExtractor.baseArguments, "outside a real app bundle the options are exactly the long-standing four")
        XCTAssertFalse(BundledExtractor.extraArguments.contains("--js-runtimes"))
    }

    // MARK: the gates a managed Deno must pass (each one alone is enough to refuse it)

    func testAFullyVerifiedDenoIsHandedToYtDlpByAbsolutePath() throws {
        let f = try makeDeno()
        guard case .success(let d) = verify(f) else { return XCTFail("a verified Deno must be accepted: \(verify(f))") }
        XCTAssertEqual(d.version, "2.9.8"); XCTAssertTrue(d.url.path.hasPrefix("/"))
        let args = ManagedDeno.runtimeArguments(tool: f.tool, ytDlpVersion: "2026.10.26", team: team, signatureCheck: signedOK, architectures: arch())
        XCTAssertEqual(args, ["--js-runtimes", "deno:" + d.url.path], "an absolute path, explicitly: never a bare name that would be looked up in PATH")
        XCTAssertFalse(args[1].dropFirst(5).hasPrefix("deno") && !args[1].dropFirst(5).hasPrefix("/"))
    }

    func testEachGateRefusesOnItsOwn() throws {
        let f = try makeDeno()
        XCTAssertEqual(verify(f, team: "AAAAAAAAAA"), .failure(.teamMismatch), "signed by another team than this app")
        XCTAssertEqual(ManagedDeno.verify(tool: f.tool, ytDlpVersion: "2026.10.26", team: nil, ownTeam: { nil }, signatureCheck: signedOK, architectures: arch()), .failure(.appHasNoTeamID), "an app with no team of its own never uses a managed Deno (unconditional: the app's team is injected)")
        XCTAssertEqual(try? ManagedDeno.verify(tool: f.tool, ytDlpVersion: "2026.10.26", team: nil, ownTeam: { self.team }, signatureCheck: signedOK, architectures: arch()).get().version, "2.9.8")
        XCTAssertEqual(ManagedDeno.verify(tool: f.tool, ytDlpVersion: nil, ytDlpVersionProvider: { nil }, team: team, signatureCheck: signedOK, architectures: arch()), .failure(.notVerifiedForThisYtDlp), "fails CLOSED when the yt-dlp release cannot be read")
        XCTAssertEqual(try? ManagedDeno.verify(tool: f.tool, ytDlpVersion: nil, ytDlpVersionProvider: { "2026.10.26" }, team: team, signatureCheck: signedOK, architectures: arch()).get().version, "2.9.8", "readable and listed: accepted")
        XCTAssertEqual(verify(f, signature: { _, _ in false }), .failure(.signatureInvalid))
        XCTAssertEqual(verify(f, arch: ["x86_64"]), .failure(.wrongArchitecture), "the file's own header says another processor")
        XCTAssertEqual(verify(f, arch: ["arm64", "x86_64"]), .failure(.wrongArchitecture), "universal is not what was verified")
        XCTAssertEqual(verify(f, yt: "2026.12.01"), .failure(.notVerifiedForThisYtDlp), "verified for a different yt-dlp release")
        let old = try makeDeno(version: "2.2.9")
        XCTAssertEqual(verify(old), .failure(.tooOld("2.2.9")), "older than yt-dlp's own minimum")
        let wrongArchPin = try makeDeno(architectures: ["x86_64"])
        XCTAssertEqual(verify(wrongArchPin), .failure(.wrongArchitecture), "the pin says another processor")
        let policy = try makeDeno(teamPolicy: "adhoc")
        XCTAssertEqual(verify(policy), .failure(.teamMismatch), "an ad-hoc policy is never a team")
    }

    func testAChangedOrMissingFileIsRefusedAndNeverTrustedByName() throws {
        let f = try makeDeno()
        XCTAssertNotNil(try? verify(f).get())
        try Data("#!/bin/sh\necho evil\n".utf8).write(to: f.exe)                            // same name, different bytes
        f.tool.forgetCache()
        XCTAssertEqual(verify(f), .failure(.changed))
        try FileManager.default.removeItem(at: f.exe); f.tool.forgetCache()
        XCTAssertEqual(verify(f), .failure(.notInstalled))
    }

    func testMalformedPinsAreRefused() throws {
        for (label, change) in [("not deno", { (m: inout [String: Any]) in m["name"] = "node" }), ("no tree pin", { (m: inout [String: Any]) in m.removeValue(forKey: "treeSHA256") }),
                                ("empty tree pin", { (m: inout [String: Any]) in m["treeSHA256"] = "" })] as [(String, (inout [String: Any]) -> Void)] {
            try? FileManager.default.removeItem(at: root); try setUpWithError()
            let f = try makeDeno(mutate: change)
            XCTAssertEqual(verify(f), .failure(.pinInvalid), label)
        }
    }

    func testVersionComparison() {
        XCTAssertTrue(ManagedDeno.compare("2.9.8", atLeast: [2, 3, 0])); XCTAssertTrue(ManagedDeno.compare("2.3.0", atLeast: [2, 3, 0])); XCTAssertTrue(ManagedDeno.compare("3.0.0", atLeast: [2, 3, 0]))
        XCTAssertFalse(ManagedDeno.compare("2.2.99", atLeast: [2, 3, 0])); XCTAssertFalse(ManagedDeno.compare("1.46.3", atLeast: [2, 3, 0]))
        for junk in ["", "2", "2.9", "x.y.z", "2.9.8-rc1"] { XCTAssertFalse(ManagedDeno.compare(junk, atLeast: [2, 3, 0]), junk) }
    }

    func testMachOArchitectureReader() throws {
        let system = ManagedDeno.machOArchitectures(URL(fileURLWithPath: "/bin/ls"))
        XCTAssertFalse(system.isEmpty); XCTAssertFalse(system.contains("other"), "a real system program is read as a Mach-O file: \(system)")
        let script = root.appendingPathComponent("script.sh"); try Data("#!/bin/sh\n".utf8).write(to: script)
        XCTAssertEqual(ManagedDeno.machOArchitectures(script), ["other"], "a script is not a Mach-O file")
        XCTAssertEqual(ManagedDeno.machOArchitectures(root.appendingPathComponent("missing")), [])
        let thin = root.appendingPathComponent("thin"); var h = Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01]); h.append(Data(count: 64)); try h.write(to: thin)
        XCTAssertEqual(ManagedDeno.machOArchitectures(thin), ["arm64"])
        var x = Data([0xcf, 0xfa, 0xed, 0xfe, 0x07, 0x00, 0x00, 0x01]); x.append(Data(count: 64)); let xt = root.appendingPathComponent("x86"); try x.write(to: xt)
        XCTAssertEqual(ManagedDeno.machOArchitectures(xt), ["x86_64"])
    }

    func testTheRealSignatureCheckRefusesAnythingNotSignedByTheTeam() throws {
        let script = root.appendingPathComponent("s"); try Data("#!/bin/sh\n".utf8).write(to: script)
        XCTAssertFalse(ManagedDeno.isSignedAsRequired(script, team: team), "an unsigned file")
        XCTAssertFalse(ManagedDeno.isSignedAsRequired(URL(fileURLWithPath: "/usr/bin/true"), team: team), "Apple's own program is not the team's")
        let adhoc = root.appendingPathComponent("adhoc"); try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: adhoc)
        _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["--force", "-s", "-", adhoc.path]).waitUntilExit()
        XCTAssertFalse(ManagedDeno.isSignedAsRequired(adhoc, team: team), "an ad-hoc signature is not a Developer ID of the team")
    }

    /// Opt-in: a REAL Deno that the media-tools pipeline signed locally with the team's Developer ID and the entitlements Deno needs (TEST_RUNNER_BS_SIGNED_DENO=<that program>, TEST_RUNNER_BS_TEAM=<Team ID>).
    func testARealSignedDenoPassesTheRealChecks() throws {
        guard let path = ProcessInfo.processInfo.environment["BS_SIGNED_DENO"], let team = ProcessInfo.processInfo.environment["BS_TEAM"], FileManager.default.isExecutableFile(atPath: path) else { throw XCTSkip("set TEST_RUNNER_BS_SIGNED_DENO and TEST_RUNNER_BS_TEAM") }
        let url = URL(fileURLWithPath: path)
        XCTAssertTrue(ManagedDeno.isSignedAsRequired(url, team: team), "a Deno signed with the team's Developer ID, the hardened runtime and only Deno's entitlements")
        XCTAssertFalse(ManagedDeno.isSignedAsRequired(url, team: "AAAAAAAAAA"))
        XCTAssertEqual(ManagedDeno.machOArchitectures(url), [ManagedDeno.thisMacsArchitecture])
    }

    // MARK: the order, stated honestly

    func testTheReportNamesEveryTierAndNeverClaimsTheManagedDenoWorks() {
        let none: Result<ManagedDeno.Verified, ManagedDeno.Unavailable> = .failure(.notOffered)
        let r = JSSolver.report(contents: root, team: team, nativeSignatureCheck: { _, _ in true }, deno: none)
        XCTAssertTrue(r.native.hasPrefix("unavailable"), "no provider in this folder"); XCTAssertTrue(r.managedDeno.contains("planned, not part of this release"))
        XCTAssertTrue(r.effective.hasPrefix("none"), r.effective); XCTAssertTrue(r.diagnostics.contains("1. built-in solver") && r.diagnostics.contains("2. managed Deno") && r.diagnostics.contains("3. no solver"))
        XCTAssertTrue(r.diagnostics.contains("never given any of this automatically") && r.diagnostics.contains("PATH is never searched"))
        let withDeno = JSSolver.report(contents: root, team: team, nativeSignatureCheck: { _, _ in true }, deno: .success(.init(url: root, version: "2.9.8")))
        XCTAssertEqual(withDeno.effective, "the managed Deno", "tier 2 is only ever the one in use when tier 1 is unavailable")
        XCTAssertTrue(withDeno.managedDeno.hasPrefix("available (Deno 2.9.8"))
    }

    // MARK: a yt-dlp the person chose is never given any of it

    func testACustomYtDlpGetsExactlyTheArgumentsItAlwaysGotAndNothingFromTheFallbackTiers() throws {
        let page = URL(string: "https://www.youtube.com/watch?v=abc")!
        let extras = ["--ignore-config", "--no-plugin-dirs", "--plugin-dirs", "/Applications/B.app/x", "--js-runtimes", "deno:/abs/deno"]
        let custom = try ExternalExtractor.launchArguments(for: page, bundled: false, bundledExtras: extras)
        XCTAssertEqual(custom, try ExternalExtractor.arguments(for: page), "exactly the page arguments")
        for forbidden in ["--plugin-dirs", "--js-runtimes", "--ignore-config", "--no-plugin-dirs", "--remote-components"] { XCTAssertFalse(custom.contains(forbidden), forbidden) }
        let bundled = try ExternalExtractor.launchArguments(for: page, bundled: true, bundledExtras: extras)
        XCTAssertEqual(bundled, extras + (try ExternalExtractor.arguments(for: page)))
        XCTAssertEqual(bundled.firstIndex(of: "--no-plugin-dirs")! < bundled.firstIndex(of: "--plugin-dirs")!, true, "other plugin folders are cleared before the verified one is added")
    }

    func testNoCodePathLooksUpAProgramByName() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Shared/Downloads/Media/ManagedJSRuntime.swift"), encoding: .utf8)
        // Code only: the comments explain that PATH and Homebrew are never used, and must be allowed to say so.
        let code = source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard let r = line.range(of: "//") else { return String(line) }
            return String(line[line.startIndex..<r.lowerBound])
        }.joined(separator: "\n")
        XCTAssertFalse(code.contains("/usr/bin/env"), "no PATH lookup"); XCTAssertFalse(code.contains("which"), "no lookup by name"); XCTAssertFalse(code.lowercased().contains("homebrew"))
        XCTAssertFalse(code.contains("ProcessInfo.processInfo.environment[\"PATH\"]"), "PATH is never read")
        XCTAssertTrue(code.contains("\"deno:\" + d.url.path"), "the runtime argument is built from the verified ABSOLUTE path")
    }

    func testAnExecutableThatIsALinkOutOfItsFolderIsRefused() throws {
        let folder = root.appendingPathComponent("tools/deno", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("deno"), withDestinationURL: URL(fileURLWithPath: "/bin/echo"))
        let pinURL = root.appendingPathComponent("BundledDeno.json")
        try JSONSerialization.data(withJSONObject: ["name": "deno", "version": "2.9.8", "sha256": "x", "sourceURL": "", "executable": "deno", "layout": "flat", "treeSHA256": ManagedTool.treeDigest(of: folder)!,
                                                    "architectures": [ManagedDeno.thisMacsArchitecture], "signaturePolicy": "teamID:\(team)", "forYtDlp": ["2026.10.26"]] as [String: Any]).write(to: pinURL)
        let tool = ManagedTool(resource: "BundledDenoTest", component: "denotest3"); tool.manifestURL = pinURL; tool.helpersFolder = root.appendingPathComponent("tools", isDirectory: true); tool.forgetCache()
        XCTAssertEqual(ManagedDeno.verify(tool: tool, ytDlpVersion: "2026.10.26", team: team, signatureCheck: signedOK, architectures: arch()), .failure(.outsideItsFolder), "a link that leaves Browser Setu's folder is never handed to yt-dlp")
    }

    func testTheOptionsAreComposedInOneOrderThatClearsBeforeItAdds() {
        let args = BundledExtractor.composeExtraArguments(plugin: ["--plugin-dirs", "/App/Contents/Resources/YtDlpPlugins"], runtime: ["--js-runtimes", "deno:/abs/deno"])
        XCTAssertEqual(args, BundledExtractor.baseArguments + ["--plugin-dirs", "/App/Contents/Resources/YtDlpPlugins", "--js-runtimes", "deno:/abs/deno"])
        let i = { (a: String) in args.firstIndex(of: a)! }
        XCTAssertLessThan(i("--no-plugin-dirs"), i("--plugin-dirs"), "other plugin folders are cleared before the verified one is added")
        XCTAssertLessThan(i("--no-js-runtimes"), i("--js-runtimes"), "yt-dlp's default runtime (a deno in PATH) is cleared before a verified one is added")
        XCTAssertEqual(BundledExtractor.composeExtraArguments(plugin: [], runtime: []), BundledExtractor.baseArguments, "with nothing verified, only the clearing options remain")
    }

    /// The real boundary: the app really starts a program the person chose, and what it was given is recorded by the program itself.
    func testARealCustomProgramIsStartedWithExactlyThePageArguments() async throws {
        let script = TestExtractorScript.path
        let home = NSTemporaryDirectory() + "bs-ext-args.txt"; try? FileManager.default.removeItem(atPath: home)
        let page = URL(string: "http://127.0.0.1:18766/media/k/page.html?recordargs")!
        _ = try await ExternalExtractor.lookup(page: page, path: script, isPrivate: false, allowLocal: true)
        let got = (try String(contentsOfFile: home, encoding: .utf8)).split(separator: "\n").map(String.init)
        XCTAssertEqual(got, try ExternalExtractor.arguments(for: page), "exactly the page arguments")
        for forbidden in ["--plugin-dirs", "--js-runtimes", "--no-js-runtimes", "--ignore-config", "--no-plugin-dirs", "--remote-components"] { XCTAssertFalse(got.contains(forbidden), "a program the person chose is never given \(forbidden)") }
    }

    func testTheOptionsThatNameAProgramOrFolderExistInExactlyOnePlace() throws {
        let shared = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Shared", isDirectory: true)
        func code(_ file: String) throws -> String {
            try String(contentsOf: shared.appendingPathComponent(file), encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).map { l -> String in
                guard let r = l.range(of: "//") else { return String(l) }; return String(l[l.startIndex..<r.lowerBound]) }.joined(separator: "\n")
        }
        let files = ["Downloads/Media/ManagedJSRuntime.swift", "Downloads/Media/JSChallengeProvider.swift", "Downloads/Media/BundledExtractor.swift", "Downloads/Media/ExternalExtractor.swift"]
        for f in files {
            let c = try code(f)
            XCTAssertFalse(c.contains("/usr/bin/env"), "\(f): no PATH lookup"); XCTAssertFalse(c.contains("which "), "\(f): no lookup by name"); XCTAssertFalse(c.lowercased().contains("homebrew"), f)
            XCTAssertFalse(c.contains("environment[\"PATH\"]"), "\(f): PATH is never read")
        }
        XCTAssertEqual(try files.filter { try code($0).contains("\"--js-runtimes\"") }, ["Downloads/Media/ManagedJSRuntime.swift"], "only the verified-runtime code may name the runtime option")
        XCTAssertEqual(try files.filter { try code($0).contains("\"--plugin-dirs\"") }, ["Downloads/Media/JSChallengeProvider.swift"], "only the verified-provider code may name the plugin option")
    }
}
#endif
