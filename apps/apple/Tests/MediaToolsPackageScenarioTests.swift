import XCTest
@testable import Browser_Setu

/// The REAL signed packages made by `scripts/release-media-tools.sh` (yt-dlp and ffmpeg), pushed through the app's own installer in an isolated temporary folder, one failure at a time.
/// Nothing touches the person's profile or `~/Library/Application Support/BrowserSetu`: every root is a fresh folder under the temporary directory, and a local file stands in for the download
/// (the only fake). Skipped unless `BS_SIGNED_PACKAGES` lists package folders (each holding the zip and `manifest-fragment.json`), separated by ":".
///
/// Before notarization the expected outcome of the happy path is a REFUSAL by the system's own assessment ("not notarized"), after every other check (size, SHA-256, archive entries, links, tree
/// digest, executable, architecture, Team ID, hardened runtime, every nested program) has passed. That refusal is what this test pins; it does not claim an install succeeded.
@MainActor
final class MediaToolsPackageScenarioTests: XCTestCase {
    struct Local: MediaToolsTransport {
        var src: URL
        func download(_ url: URL, to d: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws { try FileManager.default.copyItem(at: src, to: d) }
    }
    struct Offline: MediaToolsTransport {
        func download(_ url: URL, to d: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws { throw MediaToolsError.transport("the host cannot be reached") }
    }

    struct Package { var dir: URL; var zip: URL; var frag: [String: Any]; var name: String; var version: String }

    private func packages() throws -> [Package] {
        guard let list = ProcessInfo.processInfo.environment["BS_SIGNED_PACKAGES"], !list.isEmpty else { throw XCTSkip("no signed packages given (BS_SIGNED_PACKAGES)") }
        return try list.split(separator: ":").map { d in
            let dir = URL(fileURLWithPath: String(d))
            let zip = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first { $0.pathExtension == "zip" })
            let frag = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("manifest-fragment.json"))) as? [String: Any])
            let parts = zip.deletingPathExtension().lastPathComponent.split(separator: "-").map(String.init)      // name-version-arch ("yt-dlp-2026.10.26-arm64")
            let version = parts.dropLast().last ?? "1", name = parts.dropLast(2).joined(separator: "-")
            return Package(dir: dir, zip: zip, frag: frag, name: name, version: version)
        }
    }

    private func manifest(_ p: Package, executable: String? = nil, architectures: [String]? = nil, sourceURL: String = "https://github.com/lokeshreddyveer/browsersetu/releases/download/media-tools/package.zip",
                          sha256: String? = nil, size: Int64? = nil) -> BundledToolManifest {
        let exe = executable ?? (p.name == "yt-dlp" ? "yt-dlp_macos" : p.name)
        var m = BundledToolManifest(name: p.name, version: p.version, sha256: sha256 ?? (p.frag["sha256"] as! String), sourceURL: sourceURL, layout: p.name == "yt-dlp" ? "onedir" : "flat", executable: exe,
                                    treeSHA256: p.frag["treeSHA256"] as? String, size: size ?? (p.frag["size"] as? Int64), unpackedBytes: p.frag["unpackedBytes"] as? Int64,
                                    architectures: architectures ?? (p.frag["architectures"] as? [String]))
        m.signaturePolicy = p.frag["signaturePolicy"] as? String
        return m
    }

    private func isolatedRoot() -> URL {
        let r = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bs-scenario-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: r) }
        return r
    }

    private func assertNothingInstalled(_ root: URL, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(MediaToolsInstall.activeVersion(root: root), "\(what): nothing may be active", file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("versions").path), "\(what): no version folder", file: file, line: line)
        let staging = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("staging").path)) ?? []
        XCTAssertTrue(staging.isEmpty, "\(what): no staging left behind", file: file, line: line)
    }

    /// Runs one install and returns the error it was refused with (nil if it was accepted).
    private func attempt(_ m: BundledToolManifest, policy: String, transport: MediaToolsTransport, root: URL) async -> MediaToolsError? {
        // The same start check the app uses for each tool: FFmpeg answers `-version`, not yt-dlp's `--version` plus its options.
        let check: ((URL, BundledToolManifest) async throws -> Void)? = m.name == "ffmpeg" ? MediaToolsInstall.ffmpegLaunchCheck : nil
        do { try await MediaToolsInstall.install(m, root: root, transport: transport, policy: .init(requiredSignature: policy), launchCheck: check) { _, _ in }; return nil }
        catch let e as MediaToolsError { return e }
        catch { XCTFail("unexpected error type \(error)"); return nil }
    }

    func testEveryPackageIsAcceptedByEveryCheckUpToTheNotarizationAssessment() async throws {
        for p in try packages() {
            let root = isolatedRoot()
            let policy = p.frag["signaturePolicy"] as! String
            let err = await attempt(manifest(p), policy: policy, transport: Local(src: p.zip), root: root)
            // Size, SHA-256, entries, links, tree digest, executable, architecture, Team ID, hardened runtime and every nested program must all pass. The last gate is Apple's own assessment, which looks the program's
            // code-directory hash up with Apple: a package whose files were never submitted is refused ("Unnotarized Developer ID"); one whose files were already accepted (same signing, same hashes) is accepted, even
            // unstapled. Either outcome is correct; what is not allowed is any OTHER refusal, or an install that leaves anything half done.
            switch err {
            case nil:
                XCTAssertEqual(MediaToolsInstall.activeVersion(root: root), p.version, "\(p.name): an accepted package is activated exactly once")
                print("SCENARIO \(p.name) happy path: ACCEPTED end to end by the installer (Apple already holds notarization for these exact signed files), started once under the app's launcher")
            case .badSignature(let why)?:
                print("SCENARIO \(p.name) happy path: refused at the notarization assessment: \(why)")
                XCTAssertTrue(why.contains("notarized"), "\(p.name): the only acceptable refusal is the notarization assessment, was: \(why)")
                assertNothingInstalled(root, "\(p.name) before notarization")
            default:
                XCTFail("\(p.name): unexpected refusal \(String(describing: err))")
            }
        }
    }

    func testTheWrongTeamIDIsRefused() async throws {
        for p in try packages() {
            let root = isolatedRoot()
            let err = await attempt(manifest(p), policy: "teamID:AAAAAAAAAA", transport: Local(src: p.zip), root: root)
            guard case .badSignature? = err else { return XCTFail("\(p.name): expected badSignature for a wrong Team ID, got \(String(describing: err))") }
            assertNothingInstalled(root, "\(p.name) wrong team")
        }
    }

    func testAnAdhocPolicyIsNotWeakenedIntoAcceptingAPublisherPackage() async throws {
        // The app's rule is that a release build accepts only "teamID:"; in this Debug test run "adhoc" is allowed as a policy, and the package (signed by the publisher, not ad-hoc) must still be refused.
        for p in try packages() {
            let root = isolatedRoot()
            let err = await attempt(manifest(p), policy: "adhoc", transport: Local(src: p.zip), root: root)
            XCTAssertNotNil(err, "\(p.name): a publisher-signed package must not pass an ad-hoc policy")
            assertNothingInstalled(root, "\(p.name) adhoc policy")
        }
    }

    func testAMissingExecutableIsRefused() async throws {
        for p in try packages() {
            let root = isolatedRoot()
            let err = await attempt(manifest(p, executable: "no-such-program"), policy: p.frag["signaturePolicy"] as! String, transport: Local(src: p.zip), root: root)
            guard case .notExecutable? = err else { return XCTFail("\(p.name): expected notExecutable, got \(String(describing: err))") }
            assertNothingInstalled(root, "\(p.name) missing executable")
        }
    }

    func testACorruptedPackageIsRefusedByItsChecksum() async throws {
        for p in try packages() {
            let root = isolatedRoot()
            let bad = FileManager.default.temporaryDirectory.appendingPathComponent("bs-corrupt-\(UUID().uuidString).zip")
            addTeardownBlock { try? FileManager.default.removeItem(at: bad) }
            var data = try Data(contentsOf: p.zip); data[data.count / 2] ^= 0xFF            // one flipped byte, the same size
            try data.write(to: bad)
            let err = await attempt(manifest(p), policy: p.frag["signaturePolicy"] as! String, transport: Local(src: bad), root: root)
            guard case .badChecksum? = err else { return XCTFail("\(p.name): expected badChecksum, got \(String(describing: err))") }
            let truncated = FileManager.default.temporaryDirectory.appendingPathComponent("bs-trunc-\(UUID().uuidString).zip")
            addTeardownBlock { try? FileManager.default.removeItem(at: truncated) }
            try data.prefix(data.count / 2).write(to: truncated)
            let err2 = await attempt(manifest(p), policy: p.frag["signaturePolicy"] as! String, transport: Local(src: truncated), root: isolatedRoot())
            guard case .badSize? = err2 else { return XCTFail("\(p.name): expected badSize for a truncated download, got \(String(describing: err2))") }
            assertNothingInstalled(root, "\(p.name) corrupted")
        }
    }

    func testAPackageForAnotherProcessorIsRefusedBeforeDownloading() async throws {
        for p in try packages() {
            let root = isolatedRoot()
            let other = MediaToolsInstall.hostArchitecture == "arm64" ? "x86_64" : "arm64"
            // A transport that would fail the test if it were ever asked to download.
            struct MustNotDownload: MediaToolsTransport { func download(_ url: URL, to d: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws { XCTFail("downloaded a package for the wrong processor") } }
            let err = await attempt(manifest(p, architectures: [other]), policy: p.frag["signaturePolicy"] as! String, transport: MustNotDownload(), root: root)
            guard case .wrongArchitecture? = err else { return XCTFail("\(p.name): expected wrongArchitecture, got \(String(describing: err))") }
        }
    }

    func testAnUnavailableOrUnapprovedHostInstallsNothing() async throws {
        for p in try packages() {
            // (a) The host cannot be reached.
            var root = isolatedRoot()
            var err = await attempt(manifest(p), policy: p.frag["signaturePolicy"] as! String, transport: Offline(), root: root)
            guard case .transport? = err else { return XCTFail("\(p.name): expected a transport error, got \(String(describing: err))") }
            assertNothingInstalled(root, "\(p.name) unreachable host")
            // (b) An address that is not on the installer's approved list is refused by the real transport without connecting anywhere.
            root = isolatedRoot()
            err = await attempt(manifest(p, sourceURL: "https://example.com/package.zip"), policy: p.frag["signaturePolicy"] as! String, transport: HTTPSMediaToolsTransport(), root: root)
            XCTAssertNotNil(err, "\(p.name): example.com must be refused")
            assertNothingInstalled(root, "\(p.name) unapproved host")
            // (c) Plain http is refused before anything else.
            root = isolatedRoot()
            err = await attempt(manifest(p, sourceURL: "http://github.com/package.zip"), policy: p.frag["signaturePolicy"] as! String, transport: HTTPSMediaToolsTransport(), root: root)
            guard case .insecureAddress? = err else { return XCTFail("\(p.name): expected insecureAddress for http, got \(String(describing: err))") }
        }
    }

    func testThePackageIsNotYetHostedSoTheRealApprovedAddressAnswersNotFound() async throws {
        // The approved host is github.com; the file is not there yet, which is exactly today's state. Offline machines skip.
        let list = try packages()   // throws XCTSkip when no signed packages are given; XCTUnwrap would turn that skip into a failure
        guard let p = list.first else { throw XCTSkip("no signed packages given") }
        let root = isolatedRoot()
        let err = await attempt(manifest(p, sourceURL: "https://github.com/lokeshreddyveer/browsersetu/releases/download/media-tools-not-published/\(p.zip.lastPathComponent)"),
                                policy: p.frag["signaturePolicy"] as! String, transport: HTTPSMediaToolsTransport(), root: root)
        guard let err else { return XCTFail("an unpublished file must not install") }
        if case .transport(let why) = err, why.lowercased().contains("offline") || why.lowercased().contains("internet") { throw XCTSkip("offline: \(why)") }
        print("SCENARIO unpublished address refused with: \(err.localizedDescription)")
        assertNothingInstalled(root, "unpublished address")
    }
}
