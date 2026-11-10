import XCTest
@testable import Browser_Setu

/// The managed install of the media tools, with a local package standing in for the download (the transport is the only fake; unpacking, checks and activation are the real code).
@MainActor
final class MediaToolsInstallerTests: XCTestCase {
    struct LocalTransport: MediaToolsTransport {
        var source: URL; var delay: UInt64 = 0; var failWith: MediaToolsError?
        func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
            if let f = failWith { throw f }
            let size = (try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int64) ?? 0
            progress(size / 2, size)
            if delay > 0 { try await Task.sleep(nanoseconds: delay) }
            try Task.checkCancellation()
            try FileManager.default.copyItem(at: source, to: destination); progress(size, size)
        }
    }

    var work: URL!
    override func setUp() async throws {
        work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bs-mt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: work); BundledExtractor.forgetCache() }

    /// A tiny onedir "tool" (a shell script and a library file), zipped, with a manifest that pins it.
    func makePackage(version: String = "1", sign: Bool = true, tamperAfterPin: Bool = false, extraEntry: String? = nil) throws -> (zip: URL, manifest: BundledToolManifest) {
        let tree = work.appendingPathComponent("pkg-\(version)", isDirectory: true)
        try? FileManager.default.removeItem(at: tree)
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("_internal"), withIntermediateDirectories: true)
        let exe = tree.appendingPathComponent("mini")
        // A real (tiny) executable for this Mac's processor, so the architecture and signature checks run on a genuine Mach-O file.
        let src = work.appendingPathComponent("mini-\(version).c"); try "#include <stdio.h>\nint main(void){puts(\"\(version)\");return 0;}\n".write(to: src, atomically: true, encoding: .utf8)
        XCTAssertEqual(MediaToolsInstall.run("/usr/bin/clang", ["-arch", MediaToolsInstall.hostArchitecture, "-o", exe.path, src.path]).status, 0)
        try "lib".write(to: tree.appendingPathComponent("_internal/lib.dat"), atomically: true, encoding: .utf8)
        if let e = extraEntry { try? FileManager.default.createSymbolicLink(atPath: tree.appendingPathComponent(e).path, withDestinationPath: "/etc/hosts") }
        if sign { _ = MediaToolsInstall.run("/usr/bin/codesign", ["--force", "-s", "-", exe.path]) }
        else { _ = MediaToolsInstall.run("/usr/bin/codesign", ["--remove-signature", exe.path]) }
        let digest = try XCTUnwrap(BundledExtractor.treeDigest(of: tree))
        if tamperAfterPin { try "lib!".write(to: tree.appendingPathComponent("_internal/lib.dat"), atomically: true, encoding: .utf8) }
        let zip = work.appendingPathComponent("mini-\(version).zip")
        try? FileManager.default.removeItem(at: zip)
        XCTAssertEqual(MediaToolsInstall.run("/bin/sh", ["-c", "cd '\(tree.path)' && /usr/bin/zip -qry '\(zip.path)' ."]).status, 0)
        let size = (try FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int64) ?? 0
        let m = BundledToolManifest(name: "mini", version: version, sha256: BundledExtractor.sha256(of: zip)!, sourceURL: "https://github.com/example/mini-\(version).zip", layout: "onedir", executable: "mini", treeSHA256: digest, size: size, unpackedBytes: 4096, architectures: [MediaToolsInstall.hostArchitecture])
        return (zip, m)
    }
    func root(_ n: String = "root") -> URL { work.appendingPathComponent(n, isDirectory: true) }
    let adhoc = MediaToolsInstall.Policy(requiredSignature: "adhoc")
    func install(_ m: BundledToolManifest, _ zip: URL, root: URL, policy: MediaToolsInstall.Policy? = nil, space: Int64 = 1 << 40) async throws {
        try await MediaToolsInstall.install(m, root: root, transport: LocalTransport(source: zip), policy: policy ?? adhoc, availableBytes: { space }, launchCheck: { _, _ in }) { _, _ in }
    }

    func testAVerifiedPackageIsInstalledAndActivatedInAVersionedFolder() async throws {
        let (zip, m) = try makePackage(); let r = root()
        try await install(m, zip, root: r)
        XCTAssertEqual(MediaToolsInstall.activeVersion(root: r), "1")
        let exe = r.appendingPathComponent("versions/1/mini/mini")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: exe.path))
        XCTAssertEqual(BundledExtractor.treeDigest(of: r.appendingPathComponent("versions/1/mini")), m.treeSHA256)
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.appendingPathComponent("staging").path + "/x"), "staging is cleaned")
        XCTAssertEqual((try FileManager.default.contentsOfDirectory(atPath: r.appendingPathComponent("staging").path)).count, 0)
        let attrs = try FileManager.default.attributesOfItem(atPath: r.path)
        XCTAssertEqual((attrs[.posixPermissions] as? Int) ?? 0, 0o700, "owner only")
    }

    func testTamperedPackageIsRefusedAndNothingIsActivated() async throws {
        let (zip, m) = try makePackage(tamperAfterPin: true); var bad = m
        bad.sha256 = BundledExtractor.sha256(of: zip)!      // the file checksum is right, so the tree check is what catches it
        let r = root()
        do { try await install(bad, zip, root: r); XCTFail() } catch { XCTAssertEqual(error as? MediaToolsError, .treeMismatch) }
        XCTAssertNil(MediaToolsInstall.activeVersion(root: r)); XCTAssertFalse(FileManager.default.fileExists(atPath: r.appendingPathComponent("versions/1").path))
        var wrongSum = m; wrongSum.sha256 = String(repeating: "0", count: 64)
        do { try await install(wrongSum, zip, root: r); XCTFail() } catch { XCTAssertEqual(error as? MediaToolsError, .badChecksum) }
        var wrongSize = m; wrongSize.size = (m.size ?? 0) + 1
        do { try await install(wrongSize, zip, root: r); XCTFail() } catch { if case .badSize = (error as? MediaToolsError) ?? .cancelled {} else { XCTFail("\(error)") } }
    }

    func testWrongArchitectureLowDiskAndInsecureAddressAreRefusedBeforeDownloading() async throws {
        let (zip, m) = try makePackage(); let r = root()
        var other = m; other.architectures = [MediaToolsInstall.hostArchitecture == "arm64" ? "x86_64" : "arm64"]
        do { try await install(other, zip, root: r); XCTFail() } catch { if case .wrongArchitecture = (error as? MediaToolsError) ?? .cancelled {} else { XCTFail("\(error)") } }
        do { try await install(m, zip, root: r, space: 1000); XCTFail() } catch { if case .notEnoughSpace = (error as? MediaToolsError) ?? .cancelled {} else { XCTFail("\(error)") } }
        var http = m; http.sourceURL = "http://example.com/x.zip"
        do { try await install(http, zip, root: r); XCTFail() } catch { XCTAssertEqual(error as? MediaToolsError, .insecureAddress) }
        XCTAssertNil(MediaToolsInstall.activeVersion(root: r))
        XCTAssertFalse(HTTPSMediaToolsTransport.approved(URL(string: "https://evil.example/yt-dlp.zip")!))
        XCTAssertFalse(HTTPSMediaToolsTransport.approved(URL(string: "http://github.com/x")!))
        XCTAssertFalse(HTTPSMediaToolsTransport.approved(URL(string: "https://githubusercontent.com.evil.example/x")!))
        XCTAssertTrue(HTTPSMediaToolsTransport.approved(URL(string: "https://github.com/yt-dlp/yt-dlp/releases/download/1/x.zip")!))
        XCTAssertTrue(HTTPSMediaToolsTransport.approved(URL(string: "https://release-assets.githubusercontent.com/x")!))
    }

    func testSignaturePolicyIsEnforced() async throws {
        let (zip, m) = try makePackage(); let r = root()
        do { try await install(m, zip, root: r, policy: .init(requiredSignature: "teamID:X4MH29QNRS")); XCTFail() } catch { if case .badSignature = (error as? MediaToolsError) ?? .cancelled {} else { XCTFail("\(error)") } }
        let (zip2, m2) = try makePackage(version: "2", sign: false)
        // An unsigned executable on Apple silicon does not verify.
        do { try await install(m2, zip2, root: r); XCTFail() } catch { if case .badSignature = (error as? MediaToolsError) ?? .cancelled {} else { XCTFail("\(error)") } }
        XCTAssertNil(MediaToolsInstall.activeVersion(root: r))
    }

    func testLinksLeavingThePackageAreRefused() async throws {
        let (zip, m) = try makePackage(extraEntry: "evil-link"); let r = root()
        do { try await install(m, zip, root: r); XCTFail() } catch { if case .unsafeEntry = (error as? MediaToolsError) ?? .cancelled {} else { XCTFail("\(error)") } }
        XCTAssertNil(MediaToolsInstall.activeVersion(root: r))
    }

    func testAnUpdateReplacesTheActiveVersionAndAFailedUpdateLeavesItAlone() async throws {
        let (z1, m1) = try makePackage(version: "1"); let r = root()
        try await install(m1, z1, root: r); XCTAssertEqual(MediaToolsInstall.activeVersion(root: r), "1")
        let (z2bad, m2bad) = try makePackage(version: "2", tamperAfterPin: true)
        var m2 = m2bad; m2.sha256 = BundledExtractor.sha256(of: z2bad)!
        do { try await install(m2, z2bad, root: r); XCTFail() } catch {}
        XCTAssertEqual(MediaToolsInstall.activeVersion(root: r), "1", "a failed update changes nothing")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: r.appendingPathComponent("versions/1/mini/mini").path))
        let (z2, m2ok) = try makePackage(version: "2")
        try await install(m2ok, z2, root: r)
        XCTAssertEqual(MediaToolsInstall.activeVersion(root: r), "2")
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.appendingPathComponent("versions/1").path), "the old version is removed only after the new one is active")
        // Re-installing the same version (repair) replaces it whole.
        try "junk".write(to: r.appendingPathComponent("versions/2/mini/_internal/lib.dat"), atomically: true, encoding: .utf8)
        try await install(m2ok, z2, root: r)
        XCTAssertEqual(BundledExtractor.treeDigest(of: r.appendingPathComponent("versions/2/mini")), m2ok.treeSHA256)
    }

    func testCancelLeavesNothingBehindAndASecondInstallIsRefusedWhileOneRuns() async throws {
        let (zip, m) = try makePackage(); let r = root()
        let t = Task { try await MediaToolsInstall.install(m, root: r, transport: LocalTransport(source: zip, delay: 3_000_000_000), policy: adhoc, availableBytes: { 1 << 40 }, launchCheck: { _, _ in }) { _, _ in } }
        try await Task.sleep(nanoseconds: 600_000_000)
        do { try await install(m, zip, root: r); XCTFail("a second installer must not run at once") } catch { XCTAssertEqual(error as? MediaToolsError, .alreadyRunning) }
        t.cancel()
        _ = await t.result
        XCTAssertNil(MediaToolsInstall.activeVersion(root: r))
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: r.appendingPathComponent("staging").path))?.count ?? 0, 0)
        try await install(m, zip, root: r)       // retry works
        XCTAssertEqual(MediaToolsInstall.activeVersion(root: r), "1")
    }

    func testInterruptedInstallLeavesStagingThatIsCleanedAtRestart() throws {
        let r = root(); try FileManager.default.createDirectory(at: r.appendingPathComponent("staging/abc"), withIntermediateDirectories: true)
        try Data(count: 10).write(to: r.appendingPathComponent("staging/abc/package.zip.part"))
        try FileManager.default.createDirectory(at: r.appendingPathComponent("versions/.old-x"), withIntermediateDirectories: true)
        MediaToolsInstall.cleanup(root: r)
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.appendingPathComponent("staging").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.appendingPathComponent("versions/.old-x").path))
    }

    /// Points the app's pin and managed folder at a fixture package, as the shipped manifest does for the real one.
    func pin(_ m: BundledToolManifest, root: URL) throws {
        var d: [String: Any] = ["name": m.name, "version": m.version, "sha256": m.sha256, "sourceURL": m.sourceURL, "layout": "onedir", "executable": m.executable ?? m.name,
                                "treeSHA256": m.treeSHA256 ?? "", "size": m.size ?? 0, "unpackedBytes": 4096, "architectures": [MediaToolsInstall.hostArchitecture], "signaturePolicy": "adhoc"]
        d["x"] = 1
        let f = work.appendingPathComponent("pin-\(m.version).json"); try JSONSerialization.data(withJSONObject: d).write(to: f)
        BundledExtractor.manifestURL = f; BundledExtractor.managedRoot = root; BundledExtractor.helpersFolder = nil; BundledExtractor.forgetCache()
    }
    func unpin() { BundledExtractor.manifestURL = nil; BundledExtractor.managedRoot = MediaToolsInstall.defaultRoot(); BundledExtractor.helpersFolder = nil; BundledExtractor.forgetCache() }

    func testABlockedToolIsNeverActivatedAndNeverReported() async throws {
        let (zip, m) = try makePackage(); let r = root()
        // Gatekeeper kills the program before it can answer: the install refuses, nothing is active.
        do { try await MediaToolsInstall.install(m, root: r, transport: LocalTransport(source: zip), policy: adhoc, availableBytes: { 1 << 40 }, launchCheck: { _, _ in throw MediaToolsError.blockedByMacOS }) { _, _ in }; XCTFail() }
        catch { XCTAssertEqual(error as? MediaToolsError, .blockedByMacOS) }
        XCTAssertNil(MediaToolsInstall.activeVersion(root: r)); XCTAssertFalse(FileManager.default.fileExists(atPath: r.appendingPathComponent("versions/1").path))
        XCTAssertTrue((MediaToolsError.blockedByMacOS.errorDescription ?? "").contains("Gatekeeper"), "a meaningful message")
        // The same through the screen model: failed with that message, never Ready; then a program that does start becomes Ready.
        try pin(m, root: r); defer { unpin() }
        let store = MediaToolsStore(root: r, transport: LocalTransport(source: zip), defaults: UserDefaults(suiteName: "bs-gate-\(UUID().uuidString)")!, policy: adhoc)
        store.launchCheck = { _, _ in throw MediaToolsError.blockedByMacOS }
        store.install()
        for _ in 0..<100 { if !store.isBusy { break }; try await Task.sleep(nanoseconds: 100_000_000) }
        guard case .failed(let why) = store.phase else { return XCTFail("\(store.phase)") }
        XCTAssertTrue(why.contains("Gatekeeper")); XCTAssertFalse(store.isReady)
        XCTAssertNil(MediaToolsInstall.activeVersion(root: r))
        store.launchCheck = { _, _ in }
        store.install()
        for _ in 0..<100 { if !store.isBusy { break }; try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(store.phase, .ready("1")); XCTAssertEqual(MediaToolsInstall.activeVersion(root: r), "1")
    }

    func testAProgramMacOSKillsOnStartIsReportedAsBlocked() async throws {
        // A script that ends itself with SIGKILL (what the system does to a program it refuses to start). A script is used, not a compiled program, so the test never makes Gatekeeper show a dialog.
        let exe = work.appendingPathComponent("die"); try "#!/bin/sh\nkill -9 $$\n".write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        let m = BundledToolManifest(name: "die", version: "1", sha256: "x", sourceURL: "https://github.com/x", treeSHA256: "x")
        do { try await MediaToolsInstall.defaultLaunchCheck(exe, m); XCTFail() } catch { XCTAssertEqual(error as? MediaToolsError, .blockedByMacOS) }
        let msg = ExtractorFailure.failed(137, "").errorDescription ?? ""
        XCTAssertTrue(msg.contains("Gatekeeper") || msg.contains("macOS stopped"), msg)
    }

    func testEveryNestedProgramMustVerifyNotOnlyTheMainOne() async throws {
        let (_, m0) = try makePackage(); _ = m0
        let tree = work.appendingPathComponent("nested", isDirectory: true); try FileManager.default.createDirectory(at: tree.appendingPathComponent("_internal"), withIntermediateDirectories: true)
        let c = work.appendingPathComponent("lib.c"); try "int f(void){return 1;}\n".write(to: c, atomically: true, encoding: .utf8)
        let dylib = tree.appendingPathComponent("_internal/libx.dylib")
        XCTAssertEqual(MediaToolsInstall.run("/usr/bin/clang", ["-dynamiclib", "-arch", MediaToolsInstall.hostArchitecture, "-o", dylib.path, c.path]).status, 0)
        _ = MediaToolsInstall.run("/usr/bin/codesign", ["--force", "-s", "-", dylib.path])
        XCTAssertEqual(MediaToolsInstall.machOFailures(in: tree, policy: adhoc), [])
        _ = MediaToolsInstall.run("/usr/bin/codesign", ["--remove-signature", dylib.path])
        XCTAssertEqual(MediaToolsInstall.machOFailures(in: tree, policy: adhoc), ["_internal/libx.dylib"], "an unsigned nested library is found")
        XCTAssertThrowsError(try MediaToolsInstall.checkEveryMachO(in: tree, policy: .init(requiredSignature: "teamID:X4MH29QNRS")), "and refused under the publisher policy")
        _ = MediaToolsInstall.run("/usr/bin/codesign", ["--force", "-s", "-", dylib.path])
        XCTAssertThrowsError(try MediaToolsInstall.checkEveryMachO(in: tree, policy: .init(requiredSignature: "teamID:X4MH29QNRS")), "ad-hoc is not the publisher's Team ID")
    }

    func testAModifiedSignedProgramFailsVerificationAndTheReleasePolicyIsPublisherOnly() async throws {
        let tree = work.appendingPathComponent("signed", isDirectory: true); try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        let c = work.appendingPathComponent("m.c"); try "int f(void){return 1;}\n".write(to: c, atomically: true, encoding: .utf8)
        let lib = tree.appendingPathComponent("libm.dylib")
        XCTAssertEqual(MediaToolsInstall.run("/usr/bin/clang", ["-dynamiclib", "-arch", MediaToolsInstall.hostArchitecture, "-o", lib.path, c.path]).status, 0)
        _ = MediaToolsInstall.run("/usr/bin/codesign", ["--force", "-s", "-", lib.path])
        XCTAssertEqual(MediaToolsInstall.machOFailures(in: tree, policy: adhoc), [])
        // One byte changed in the signed file's code: the signature no longer verifies, and that is found.
        let h = try FileHandle(forUpdating: lib); try h.seek(toOffset: 64); let b = try h.read(upToCount: 1) ?? Data([0]); try h.seek(toOffset: 64); try h.write(contentsOf: Data([b.first.map { $0 ^ 0xff } ?? 1])); try h.close()
        XCTAssertEqual(MediaToolsInstall.machOFailures(in: tree, policy: adhoc), ["libm.dylib"], "a modified signed binary")
        // A release build accepts only the publisher policy; the development policy is refused there, whatever the manifest or settings say.
        XCTAssertFalse(MediaToolsInstall.policyAllowed(.init(requiredSignature: "adhoc"), release: true))
        XCTAssertFalse(MediaToolsInstall.policyAllowed(.init(requiredSignature: ""), release: true))
        XCTAssertFalse(MediaToolsInstall.policyAllowed(.init(requiredSignature: "anything"), release: false))
        XCTAssertTrue(MediaToolsInstall.policyAllowed(.init(requiredSignature: "teamID:X4MH29QNRS"), release: true))
        XCTAssertTrue(MediaToolsInstall.policyAllowed(.init(requiredSignature: "adhoc"), release: false))
        #if DEBUG
        XCTAssertFalse(MediaToolsInstall.isReleaseBuild)
        #endif
    }

    func testAnUpdateThatDiedMidActivationIsRestoredAtTheNextLaunch() async throws {
        let (zip, m) = try makePackage(); let r = root()
        try await install(m, zip, root: r)
        // Simulate the crash window of a repair/update: the active folder was moved aside and the new one never arrived.
        let versions = r.appendingPathComponent("versions")
        try FileManager.default.moveItem(at: versions.appendingPathComponent("1"), to: versions.appendingPathComponent(".old-1"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: versions.appendingPathComponent("1").path))
        MediaToolsInstall.cleanup(root: r)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: versions.appendingPathComponent("1/mini/mini").path), "the working version is back")
        XCTAssertEqual(BundledExtractor.treeDigest(of: versions.appendingPathComponent("1/mini")), m.treeSHA256)
        // The other crash window: the new folder was created but the verified tree never reached it (empty folder next to `.old-1`). The old version is restored, not deleted.
        try FileManager.default.moveItem(at: versions.appendingPathComponent("1"), to: versions.appendingPathComponent(".old-1"))
        try FileManager.default.createDirectory(at: versions.appendingPathComponent("1"), withIntermediateDirectories: true)
        MediaToolsInstall.cleanup(root: r)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: versions.appendingPathComponent("1/mini/mini").path), "restored although the empty folder was there")
        XCTAssertEqual(BundledExtractor.treeDigest(of: versions.appendingPathComponent("1/mini")), m.treeSHA256)
        // A leftover next to a healthy active version is just removed, and retired versions go too.
        try FileManager.default.createDirectory(at: versions.appendingPathComponent(".old-1"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: versions.appendingPathComponent("0.9"), withIntermediateDirectories: true)
        MediaToolsInstall.cleanup(root: r)
        XCTAssertEqual(Set((try FileManager.default.contentsOfDirectory(atPath: versions.path))), ["1"])
    }

    func testApprovedHostsRequirePort443NoUserinfoAndTheErrorTextHidesPaths() {
        XCTAssertFalse(HTTPSMediaToolsTransport.approved(URL(string: "https://github.com:8443/x")!))
        XCTAssertTrue(HTTPSMediaToolsTransport.approved(URL(string: "https://github.com:443/x")!))
        XCTAssertFalse(HTTPSMediaToolsTransport.approved(URL(string: "https://user:pw@github.com/x")!))
        let shown = MediaToolsInstall.redact("failed at \(NSHomeDirectory())/Library/Application Support/x and \(NSTemporaryDirectory())abc")
        XCTAssertFalse(shown.contains(NSHomeDirectory())); XCTAssertTrue(shown.contains("~/Library")); XCTAssertTrue(shown.contains("…/abc"))
        XCTAssertEqual(MediaToolsInstall.friendly(URLError(.notConnectedToInternet)), "there is no internet connection")
        XCTAssertFalse(MediaToolsInstall.friendly(URLError(.cannotFindHost, userInfo: [NSURLErrorFailingURLStringErrorKey: "https://x/secret"])).contains("secret"))
    }

    func testTheVerifiedResultCannotBeFooledByRestoringATimestamp() async throws {
        let (zip, m) = try makePackage(); let r = root()
        try await install(m, zip, root: r); try pin(m, root: r); defer { unpin() }
        let verified = await BundledExtractor.verifyAsync(); XCTAssertNotNil(verified)
        let lib = r.appendingPathComponent("versions/1/mini/_internal/lib.dat")
        let before = try FileManager.default.attributesOfItem(atPath: lib.path)[.modificationDate] as! Date
        try "XYZ".write(to: lib, atomically: false, encoding: .utf8)             // same size ("lib" is 3 bytes), different bytes
        try FileManager.default.setAttributes([.modificationDate: before], ofItemAtPath: lib.path)
        XCTAssertNil(BundledExtractor.verify(), "same size and same modification time, different content: refused")
    }

    func testStoreInstallRemoveAndTheRecordedChoice() async throws {
        let (zip, m) = try makePackage()
        let defaults = UserDefaults(suiteName: "bs-mt-\(UUID().uuidString)")!
        let store = MediaToolsStore(root: root("store"), transport: LocalTransport(source: zip), defaults: defaults, policy: adhoc)
        XCTAssertEqual(store.choice, .undecided)
        store.decline(); XCTAssertEqual(store.choice, .declined)
        XCTAssertEqual(MediaToolsStore(root: root("store"), transport: LocalTransport(source: zip), defaults: defaults).choice, .declined, "the choice is remembered, so nothing asks again")
        // The store reads the pinned manifest from the app; for this fixture the pieces are exercised directly.
        try await install(m, zip, root: root("store")); XCTAssertEqual(MediaToolsInstall.activeVersion(root: root("store")), "1")
        store.remove()
        for _ in 0..<50 { if store.phase == .notInstalled { break }; try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(store.phase, .notInstalled)
        XCTAssertNil(MediaToolsInstall.activeVersion(root: root("store")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root("store").appendingPathComponent("versions").path))
    }
}

/// Real acceptance: the pinned yt-dlp package is downloaded from its official release address by the real transport, unpacked, verified and activated in a throwaway folder (never the person's
/// Application Support), verified again by the app. It is NOT started here (see below). Skipped when offline.
@MainActor
final class MediaToolsRealInstallTests: XCTestCase {
    func testTheRealPinnedPackageDownloadsVerifiesActivatesAndRuns() async throws {
        let m = try XCTUnwrap(BundledExtractor.manifest(), "the app's pinned manifest")
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bs-real-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root); BundledExtractor.helpersFolder = nil; BundledExtractor.managedRoot = MediaToolsInstall.defaultRoot(); BundledExtractor.forgetCache() }
        var last = 0.0
        do {
            try await MediaToolsInstall.install(m, root: root, transport: HTTPSMediaToolsTransport(), policy: .init(requiredSignature: m.signaturePolicy ?? "adhoc"),
                                                launchCheck: { _, _ in /* not started: the unnotarized upstream tool would make Gatekeeper show a dialog; the refusal itself is tested with a self-killing program */ }) { f, _ in last = max(last, f) }
        } catch let e as MediaToolsError {
            if case .transport = e { throw XCTSkip("offline: \(e.localizedDescription)") }
            throw e
        }
        XCTAssertEqual(last, 1)
        XCTAssertEqual(MediaToolsInstall.activeVersion(root: root), m.version)
        // The app now finds, verifies (whole tree against the app's pin) and starts it from the managed folder.
        BundledExtractor.helpersFolder = nil; BundledExtractor.managedRoot = root; BundledExtractor.forgetCache()
        let verified = await BundledExtractor.verifyAsync()
        let v = try XCTUnwrap(verified, "verified from the managed folder")
        XCTAssertTrue(v.url.path.hasPrefix(root.path) || v.url.path.hasPrefix(root.resolvingSymlinksInPath().path))
        XCTAssertTrue(ExtractorChoice.isAvailable)
        XCTAssertEqual(v.manifest.version, m.version)
        // The upstream package is ad-hoc signed and not notarized, and this app marks its downloads as quarantined, so macOS (Gatekeeper) refuses to START it from here: that is expected, and it is why the
        // release pipeline must ship a Developer ID signed, notarized package. Starting the real program is covered by the other tests, which use the pinned copy in ThirdParty.
        // Audit of the real upstream package: exactly the three Python.framework copies of `Python` fail strict verification (their ad-hoc signature expects bundle resources that are absent), and every
        // other Mach-O verifies. That is an upstream packaging defect; re-signing every file with the release identity is what fixes it.
        let nested = MediaToolsInstall.machOFailures(in: v.url.deletingLastPathComponent(), policy: .init(requiredSignature: "adhoc")).sorted()
        print("REAL-INSTALL nested signature failures: \(nested)")
        XCTAssertEqual(nested.count, 3); XCTAssertTrue(nested.allSatisfy { $0.hasPrefix("_internal/Python.framework/") && $0.hasSuffix("/Python") })
        XCTAssertFalse(MediaToolsInstall.machOFailures(in: v.url.deletingLastPathComponent(), policy: .init(requiredSignature: "teamID:X4MH29QNRS")).isEmpty, "the upstream package fails the publisher policy")
        let q = MediaToolsInstall.run("/usr/bin/xattr", ["-p", "com.apple.quarantine", v.url.path])
        print("REAL-INSTALL quarantine attribute present on the installed tool: \(q.status == 0)")
        // Owner-only folder, and removal leaves nothing active.
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int) ?? 0, 0o700)
        try MediaToolsInstall.remove(root: root)
        XCTAssertNil(MediaToolsInstall.activeVersion(root: root)); BundledExtractor.forgetCache()
        XCTAssertNil(BundledExtractor.verify())
    }
}

/// Opt-in check of a package built by scripts/release-media-tools.sh (set TEST_RUNNER_BS_SIGNED_PACKAGE to the folder holding the zip and manifest-fragment.json). Skipped otherwise.
@MainActor
final class MediaToolsSignedPackageTests: XCTestCase {
    func testAResignedPackagePassesEveryStrictCheckAndIsRefusedUntilItIsNotarized() async throws {
        guard let dir = ProcessInfo.processInfo.environment["BS_SIGNED_PACKAGE"] else { throw XCTSkip("no signed package given") }
        let folder = URL(fileURLWithPath: dir)
        let zip = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first { $0.pathExtension == "zip" })
        let frag = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest-fragment.json"))) as! [String: Any]
        let team = (frag["signaturePolicy"] as! String)
        let work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bs-signed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let tree = work.appendingPathComponent("tree"); try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        XCTAssertEqual(MediaToolsInstall.run("/usr/bin/unzip", ["-q", zip.path, "-d", tree.path], timeout: 300).status, 0)
        // Every Mach-O, nested ones and Python.framework included, verifies strictly and carries the publisher's Team ID.
        let pol = MediaToolsInstall.Policy(requiredSignature: team)
        XCTAssertEqual(MediaToolsInstall.machOFailures(in: tree, policy: pol), [], "every file passes the publisher policy")
        XCTAssertEqual(BundledExtractor.treeDigest(of: tree), frag["treeSHA256"] as? String, "the integrity value was computed after signing")
        // The wrong Team ID is refused for the very same files.
        XCTAssertFalse(MediaToolsInstall.machOFailures(in: tree, policy: .init(requiredSignature: "teamID:AAAAAAAAAA")).isEmpty)
        // The whole installer: signed by the right team but not notarized, so the system assessment refuses it and nothing is activated.
        var m = BundledToolManifest(name: "yt-dlp", version: "2026.10.26", sha256: frag["sha256"] as! String, sourceURL: "https://github.com/x/yt-dlp.zip", layout: "onedir", executable: "yt-dlp_macos",
                                    treeSHA256: frag["treeSHA256"] as? String, size: frag["size"] as? Int64, unpackedBytes: frag["unpackedBytes"] as? Int64, architectures: ["arm64"])
        m.signaturePolicy = team
        struct Local: MediaToolsTransport { var src: URL; func download(_ url: URL, to d: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws { try FileManager.default.copyItem(at: src, to: d) } }
        let root = work.appendingPathComponent("root")
        if ProcessInfo.processInfo.environment["BS_EXPECT_NOTARIZED"] == "1" {
            // Real release conditions: the app's own quarantine behaviour stays on, Gatekeeper is on, the real launch check runs (the program is started once), and spctl must accept it.
            try await MediaToolsInstall.install(m, root: root, transport: Local(src: zip), policy: pol) { _, _ in }
            XCTAssertEqual(MediaToolsInstall.activeVersion(root: root), m.version)
            let exe = root.appendingPathComponent("versions/\(m.version)/yt-dlp/yt-dlp_macos")
            let q = MediaToolsInstall.run("/usr/bin/xattr", ["-p", "com.apple.quarantine", exe.path])
            let sp = MediaToolsInstall.run("/usr/sbin/spctl", ["--assess", "--type", "install", "--verbose=4", exe.path])
            print("NOTARIZED-INSTALL quarantine present on installed program: \(q.status == 0) | spctl: \(sp.status) \(sp.out.replacingOccurrences(of: "\n", with: " / "))")
            // The installed program starts through the app's own launcher and reports the pinned version.
            let out = try await ExternalExtractor.run(exe, arguments: ["--version"] + BundledExtractor.extraArguments, timeout: 30, maxBytes: 4096)
            XCTAssertEqual(String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), m.version)
            print("NOTARIZED-INSTALL started under Gatekeeper, version \(m.version)")
            // Through the app's own pieces: the pin and managed folder point at this isolated install, the program is verified (whole tree), resolved, and asked about an authorized sample page.
            let pinFile = work.appendingPathComponent("pin.json")
            var pin = try JSONSerialization.jsonObject(with: Data(contentsOf: Bundle.main.url(forResource: "BundledTools", withExtension: "json")!)) as! [String: Any]
            for (k, v) in frag { pin[k] = v }
            try JSONSerialization.data(withJSONObject: pin).write(to: pinFile)
            BundledExtractor.manifestURL = pinFile; BundledExtractor.managedRoot = root; BundledExtractor.helpersFolder = nil; BundledExtractor.forgetCache()
            defer { BundledExtractor.manifestURL = nil; BundledExtractor.managedRoot = ManagedToolFolder.defaultRoot(); BundledExtractor.helpersFolder = nil; BundledExtractor.forgetCache() }
            let choice = try await ExtractorChoice.resolveAsync()
            XCTAssertTrue(choice.bundled); XCTAssertTrue(choice.identity.hasPrefix("bundled:yt-dlp|"))
            XCTAssertTrue(choice.path.hasPrefix(root.resolvingSymlinksInPath().path) || choice.path.hasPrefix(root.path), "the program that runs is the one in the isolated install")
            let page = URL(string: "https://www.w3schools.com/html/html5_video.asp")!
            do {
                let src = try await ExternalExtractor.lookup(page: page, path: choice.path, isPrivate: false, allowLocal: false, timeout: 90, expectedIdentity: choice.identity)
                guard case .tracks(let reps) = src.shape else { return XCTFail("no formats") }
                print("NOTARIZED-INSTALL real extraction: \(reps.map { "\($0.formatID ?? "?"):\($0.container):\($0.url.lastPathComponent)" })")
                XCTAssertFalse(reps.isEmpty)
            } catch let e as ExtractorFailure { if case .failed = e { throw e }; print("NOTARIZED-INSTALL extraction not completed: \(e)"); throw e }
        } else {
            // Signed by the right team but not notarized: it must be refused, and nothing activated.
            do { try await MediaToolsInstall.install(m, root: root, transport: Local(src: zip), policy: pol, launchCheck: { _, _ in }) { _, _ in }; XCTFail("a package that is not notarized must be refused") }
            catch { XCTAssertEqual(error as? MediaToolsError, .badSignature("not accepted as notarized by the system")) }
            XCTAssertNil(MediaToolsInstall.activeVersion(root: root))
        }
    }
}
