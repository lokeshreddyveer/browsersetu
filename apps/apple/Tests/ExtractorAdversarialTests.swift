import XCTest
import AVFoundation
@testable import Browser_Setu

/// Regression tests for the eight review findings on the external extractor and the move out of the App Sandbox.
@MainActor
final class ExtractorAdversarialTests: XCTestCase {
    var script: String { TestExtractorScript.path }
    func page(_ word: String, key: String = "k") -> URL { URL(string: "http://127.0.0.1:18766/media/\(key)/page.html?\(word)")! }
    func needScript() throws { XCTAssertTrue(FileManager.default.fileExists(atPath: script), "the stand-in extractor is not installed") }

    // 1. Hostile numbers never trap; an out-of-range field only costs that format.
    func testHugeAndNonFiniteNumbersDoNotCrash() async throws {
        try needScript()
        let s = try await ExternalExtractor.lookup(page: page("bighuge"), path: script, isPrivate: false, allowLocal: true)
        guard case .tracks(let r) = s.shape, let f = r.first(where: { $0.formatID == "ok" }) else { return XCTFail() }
        XCTAssertEqual(f.height, 720); XCTAssertEqual(f.bitrate, 4_000_000)
        let bad = r.first { $0.formatID == nil }
        XCTAssertNil(bad?.height); XCTAssertNil(bad?.bitrate); XCTAssertNil(bad?.bytes); XCTAssertNil(bad?.frameRate)
        let json = #"{"id":"a","webpage_url":"https://x.org/w","formats":[{"url":"https://c.example/a.mp4","ext":"mp4","vcodec":"h","acodec":"a","tbr":1e300,"height":-1,"filesize":1e30,"fps":true,"url_expires":1e30}]}"#
        XCTAssertNoThrow(try ExtractorParser.parse(Data(json.utf8), asked: URL(string: "https://x.org/w")!))
        let long = String(repeating: "a", count: 5000)
        let j2 = #"{"id":"a","webpage_url":"https://x.org/w","formats":[{"url":"https://c.example/a.mp4","ext":"mp4","vcodec":"\#(long)","acodec":"a"}]}"#
        guard case .tracks(let r2) = try ExtractorParser.parse(Data(j2.utf8), asked: URL(string: "https://x.org/w")!).shape else { return XCTFail() }
        XCTAssertEqual(r2.first?.codecs, "unknown,a", "an oversized codec string is ignored (shown as unknown), never echoed")
    }

    // 2. The whole process tree ends on timeout, and a program that ignores SIGTERM is still ended; the slot comes back.
    func pidAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }
    func testTimeoutEndsTheWholeTreeAndAStubbornProgramAndFreesTheSlot() async throws {
        try needScript()
        let pidFile = NSTemporaryDirectory() + "bs-ext-child.pid"; try? FileManager.default.removeItem(atPath: pidFile)
        do { _ = try await ExternalExtractor.lookup(page: page("descendant"), path: script, isPrivate: false, allowLocal: true, timeout: 1.5); XCTFail() } catch { XCTAssertEqual(error as? ExtractorFailure, .timedOut) }
        let child = pid_t(((try? String(contentsOfFile: pidFile, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        XCTAssertGreaterThan(child, 0, "the program started a child")
        // Wait for the child to be gone, not for a fixed time: returns the moment it is, and still fails if it outlives the same 6 s the old fixed wait allowed for.
        for _ in 0..<120 where pidAlive(child) { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertFalse(pidAlive(child), "the child the program started was ended with it")
        let started = Date()
        do { _ = try await ExternalExtractor.lookup(page: page("stubborn"), path: script, isPrivate: false, allowLocal: true, timeout: 1); XCTFail() } catch { XCTAssertEqual(error as? ExtractorFailure, .timedOut) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 8, "a program that ignores SIGTERM is ended by SIGKILL, not waited for")
        // Both slots are free again: two lookups at once work.
        async let a = ExternalExtractor.lookup(page: page("muxed"), path: script, isPrivate: false, allowLocal: true)
        async let b = ExternalExtractor.lookup(page: page("muxed"), path: script, isPrivate: false, allowLocal: true)
        _ = try await (a, b)
    }

    /// Opt-in (TEST_RUNNER_BS_HELPER=<path to the built app's Contents/Helpers/setu-jsc>): the app's OWN launcher times a program out, and the REAL sandboxed helper that program started must be ended with it.
    func testTimeoutEndsTheRealHelperStartedByTheProgram() async throws {
        guard let helper = ProcessInfo.processInfo.environment["BS_HELPER"], FileManager.default.isExecutableFile(atPath: helper) else { throw XCTSkip("set TEST_RUNNER_BS_HELPER to a built app's setu-jsc") }
        try needScript()
        let pidFile = NSTemporaryDirectory() + "bs-helper-child.pid"; try? FileManager.default.removeItem(atPath: pidFile)
        try helper.write(toFile: NSTemporaryDirectory() + "bs-helper-path.txt", atomically: true, encoding: .utf8)
        do { _ = try await ExternalExtractor.lookup(page: page("helperchild"), path: script, isPrivate: false, allowLocal: true, timeout: 2); XCTFail() } catch { XCTAssertEqual(error as? ExtractorFailure, .timedOut) }
        let child = pid_t(((try? String(contentsOfFile: pidFile, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        XCTAssertGreaterThan(child, 0, "the program started the helper")
        for _ in 0..<160 where pidAlive(child) { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertFalse(pidAlive(child), "the sandboxed helper was ended with the program that started it")
    }

    // 3. Identity: a webpage_url is required; deceptive and merely-similar hosts are different sites.
    func testIdentityAndDeceptiveDomains() throws {
        try needScript()
        XCTAssertFalse(ExtractorParser.sameSite("evil.co.uk", "bbc.co.uk")); XCTAssertFalse(ExtractorParser.sameSite("evil-youtube.com", "youtube.com"))
        XCTAssertFalse(ExtractorParser.sameSite("youtube.com.evil.com", "youtube.com")); XCTAssertFalse(ExtractorParser.sameSite("x.github.io", "y.github.io"))
        XCTAssertTrue(ExtractorParser.sameSite("m.youtube.com", "www.youtube.com")); XCTAssertTrue(ExtractorParser.sameSite("youtu.be", "www.youtube.com"))
        XCTAssertTrue(ExtractorParser.sameSite("example.com", "www.example.com")); XCTAssertFalse(ExtractorParser.sameSite("com", "example.com"), "a bare TLD is not a site")
        let j = #"{"id":"a","formats":[{"url":"https://c.example/a.mp4","ext":"mp4","vcodec":"h","acodec":"a"}]}"#
        XCTAssertThrowsError(try ExtractorParser.parse(Data(j.utf8), asked: URL(string: "https://x.org/w")!)) { XCTAssertEqual($0 as? ExtractorFailure, .malformed("no webpage_url")) }
    }
    func testAnAnswerWithoutAWebpageURLIsRefusedByTheRealProgram() async throws {
        try needScript()
        do { _ = try await ExternalExtractor.lookup(page: page("nowebpage"), path: script, isPrivate: false, allowLocal: true); XCTFail() } catch { XCTAssertEqual(error as? ExtractorFailure, .malformed("no webpage_url")) }
    }

    // 4. The format the person picked is the format downloaded (by identity, not "the best of its kind").
    func testPickedFormatIsTheOneDownloaded() throws {
        let a = NormalizedRepresentation(role: .muxed, url: URL(string: "https://c.example/hd.mp4")!, container: "mp4", height: 720, formatID: "hd")
        let b = NormalizedRepresentation(role: .muxed, url: URL(string: "https://c.example/sd.mp4")!, container: "mp4", height: 360, formatID: "sd")
        XCTAssertNotEqual(a.pickKey, b.pickKey); XCTAssertEqual(a.pickKey, "hd")
        XCTAssertEqual(NormalizedRepresentation(role: .muxed, url: URL(string: "https://c.example/z.mp4")!, container: "mp4").pickKey, "https://c.example/z.mp4")
    }

    func testDuplicateFormatIDsAreCollapsedAndTheDrainCannotHang() async throws {
        let j = #"{"id":"a","webpage_url":"https://x.org/w","formats":[{"format_id":"1","url":"https://c.example/a.mp4","ext":"mp4","vcodec":"h","acodec":"a","height":720},{"format_id":"1","url":"https://c.example/b.mp4","ext":"mp4","vcodec":"h","acodec":"a","height":360}]}"#
        guard case .tracks(let r) = try ExtractorParser.parse(Data(j.utf8), asked: URL(string: "https://x.org/w")!).shape else { return XCTFail() }
        XCTAssertEqual(r.count, 1); XCTAssertEqual(r.first?.height, 720)
    }

    // 7. A grant is for one program; a changed or different program asks again, and lookup refuses a program that changed after consent.
    func testConsentIsBoundToTheProgramAndAChangedProgramIsRefused() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bs-exe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        let exe = dir.appendingPathComponent("tool.sh")
        try "#!/bin/sh\necho 1.0\n".write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: exe.path)
        let before = try XCTUnwrap(ExternalExtractor.identity(of: exe))
        XCTAssertEqual(before.split(separator: "|").last?.count, 64, "the full SHA-256, not a prefix")
        let d = UserDefaults(suiteName: "bs.test.ext.\(UUID().uuidString)")!
        let c = MediaConsentStore(defaults: d)
        c.grant(.externalExtractor(before), scope: .profile, profile: "p", isPrivate: false)
        XCTAssertTrue(c.isAllowed(.externalExtractor(before), host: "x.org", profile: "p", isPrivate: false))
        try "#!/bin/sh\necho 2.0\n".write(to: exe, atomically: true, encoding: .utf8)
        let after = try XCTUnwrap(ExternalExtractor.identity(of: exe))
        XCTAssertNotEqual(before, after)
        XCTAssertFalse(c.isAllowed(.externalExtractor(after), host: "x.org", profile: "p", isPrivate: false), "a changed program is not covered by the earlier grant")
        do { _ = try await ExternalExtractor.lookup(page: URL(string: "https://x.org/w")!, path: exe.path, isPrivate: false, expectedIdentity: before); XCTFail() }
        catch { XCTAssertEqual(error as? ExtractorFailure, .unsafeLocation("the program changed after you allowed it")) }
    }

    // 8. Executable trust: not world/group writable, not in a writable folder, no ACL, owned by this person.
    func testExecutableTrustChecks() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bs-trust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        let exe = dir.appendingPathComponent("t.sh"); try "#!/bin/sh\n".write(to: exe, atomically: true, encoding: .utf8)
        func set(_ p: Int, _ url: URL) { try? FileManager.default.setAttributes([.posixPermissions: p], ofItemAtPath: url.path) }
        set(0o700, exe); XCTAssertNoThrow(try ExternalExtractor.validateLocation(exe.path))
        set(0o777, exe); XCTAssertThrowsError(try ExternalExtractor.validateLocation(exe.path), "world-writable program")
        set(0o755, exe); set(0o777, dir); XCTAssertThrowsError(try ExternalExtractor.validateLocation(exe.path), "program in a folder others can change")
        set(0o700, dir)
        XCTAssertThrowsError(try ExternalExtractor.validateLocation("relative/tool")); XCTAssertThrowsError(try ExternalExtractor.validateLocation("/nonexistent/tool"))
        XCTAssertEqual(ExternalExtractor.childEnvironment["PATH"], "/usr/bin:/bin", "no inherited or Homebrew PATH")
        XCTAssertEqual(Set(ExternalExtractor.childEnvironment.keys), ["PATH", "LANG", "HOME", "PYTHONDONTWRITEBYTECODE"])
    }
}

/// The stand-in extractor is a committed fixture (Tests/Fixtures/test-extractor.sh). Tests copy it into a private temporary folder, so nothing is installed anywhere else and the tests that need it never skip.
enum TestExtractorScript {
    static let path: String = {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/test-extractor.sh")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bs-test-extractor-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let dst = dir.appendingPathComponent("test-extractor.sh")
        try? FileManager.default.removeItem(at: dst)
        try? FileManager.default.copyItem(at: src, to: dst)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
        return dst.path
    }()
}
