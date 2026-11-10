import XCTest
import AVFoundation
@testable import Browser_Setu

/// The optional external extractor, with a deterministic stand-in script (bs-test-extractor.sh in this app's Application Scripts folder, which is where the sandboxed app is allowed to run scripts from).
@MainActor
final class ExternalExtractorTests: XCTestCase {
    var script: String { TestExtractorScript.path }
    func page(_ key: String, _ word: String) -> URL { URL(string: "http://127.0.0.1:18766/media/\(key)/page.html?\(word)")! }
    func lookup(_ word: String, key: String = "k", timeout: TimeInterval = 30) async throws -> NormalizedMediaSource {
        try await ExternalExtractor.lookup(page: page(key, word), path: script, isPrivate: false, allowLocal: true, timeout: timeout)
    }
    func fails(_ word: String, _ expected: ExtractorFailure, timeout: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await lookup(word, timeout: timeout); XCTFail("expected \(expected)", file: file, line: line) }
        catch let e as ExtractorFailure { XCTAssertEqual(e, expected, file: file, line: line) }
        catch { XCTFail("\(error)", file: file, line: line) }
    }

    func testConfigurationAndHealth() async throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: script), "the stand-in script is not installed")
        let h = await ExternalExtractor.health(path: script)
        XCTAssertEqual(h.version, "2099.01.01-stand-in"); XCTAssertTrue(h.ok)
        let missing = await ExternalExtractor.health(path: "/nonexistent/tool")
        XCTAssertFalse(missing.ok)
        let elsewhere = await ExternalExtractor.health(path: "/usr/bin/true")
        XCTAssertFalse(elsewhere.ok, "a program that reports no version is not healthy")
        XCTAssertNil(ExtractorSettings.path.flatMap { _ in ExtractorSettings.isEnabled ? "on" : nil }, "disabled by default")
    }

    func testArgumentsAreFixedAndTheAddressCannotBecomeAnOption() throws {
        let a = try ExternalExtractor.arguments(for: URL(string: "https://x.org/watch?v=1")!)
        XCTAssertEqual(Array(a.prefix(4)), ["--dump-single-json", "--no-playlist", "--no-warnings", "--"]); XCTAssertEqual(a.last, "https://x.org/watch?v=1")
        XCTAssertThrowsError(try ExternalExtractor.arguments(for: URL(string: "file:///etc/passwd")!))
        XCTAssertThrowsError(try ExternalExtractor.arguments(for: URL(string: "ftp://x.org/a")!))
    }

    func testFormatsAreNormalizedAndUnusableOnesAreSkipped() async throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: script))
        let s = try await lookup("separate")
        guard case .tracks(let r) = s.shape else { return XCTFail() }
        XCTAssertEqual(r.count, 2, "the format that needs cookies is not offered")
        XCTAssertEqual(r.first { $0.role == .video }?.height, 120); XCTAssertEqual(r.first { $0.role == .audio }?.language, "en")
        XCTAssertEqual(s.title, "Separate tracks")
        XCTAssertTrue(s.options(encoders: (true, true)).contains { $0.kind == .video && $0.isAvailable })
        let m = try await lookup("muxed")
        guard case .tracks(let mr) = m.shape else { return XCTFail() }
        XCTAssertEqual(mr.first?.role, .muxed); XCTAssertEqual(mr.first?.bytes, 788493)
    }

    func testFailuresAreClassified() async throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: script))
        await fails("malformed", .malformed("not a JSON object"))
        await fails("huge", .tooMuchOutput)
        await fails("fail", .failed(3, "ERROR: Video unavailable"))
        await fails("noformats", .noFormats("the extractor returned no downloadable formats."))
        await fails("wrongvideo", .wrongVideo)
        await fails("slow", .timedOut, timeout: 2)
        do { _ = try await lookup("expired"); XCTFail() } catch { XCTAssertEqual(error as? NormalizedFailure, .expired) }
        do { _ = try await lookup("dashonly"); XCTFail() } catch let e as ExtractorFailure { if case .noFormats(let why) = e { XCTAssertTrue(why.contains("http_dash_segments")) } else { XCTFail("\(e)") } }
    }

    func testCancellationReturnsPromptly() async throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: script))
        let t = Task { try await self.lookup("slow") }
        try await Task.sleep(nanoseconds: 700_000_000)
        let started = Date(); t.cancel()
        _ = try? await t.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 4, "a cancelled lookup does not wait for the program")
    }

    func testNeverRunsInAPrivateTabOrWithoutConsent() async throws {
        do { _ = try await ExternalExtractor.lookup(page: page("k", "muxed"), path: script, isPrivate: true); XCTFail() } catch { XCTAssertNotNil(error as? ExtractorFailure) }
        let d = UserDefaults(suiteName: "bs.test.ext.\(UUID().uuidString)")!
        let c = MediaConsentStore(defaults: d)
        XCTAssertFalse(c.isAllowed(.externalExtractor("/bin/x|aa"), host: "x.org", profile: "p", isPrivate: false), "nothing is allowed until the person says so")
        c.grant(.externalExtractor("/bin/x|aa"), scope: .site("x.org"), profile: "p", isPrivate: false)
        XCTAssertTrue(c.isAllowed(.externalExtractor("/bin/x|aa"), host: "x.org", profile: "p", isPrivate: false))
        XCTAssertFalse(c.isAllowed(.externalExtractor("/bin/x|aa"), host: "y.org", profile: "p", isPrivate: false))
        XCTAssertFalse(c.isAllowed(.externalExtractor("/bin/x|aa"), host: "x.org", profile: "p", isPrivate: true))
        c.revoke(.externalExtractor("/bin/x|aa"), profile: "p")
        XCTAssertFalse(c.isAllowed(.externalExtractor("/bin/x|aa"), host: "x.org", profile: "p", isPrivate: false))
    }

    func testParserRejectsHostileShapes() throws {
        let page = URL(string: "https://x.org/w")!
        func parse(_ j: String) throws -> NormalizedMediaSource { try ExtractorParser.parse(Data(j.utf8), asked: page) }
        XCTAssertThrowsError(try parse("[]")); XCTAssertThrowsError(try parse("{\"formats\":[]}"))
        XCTAssertThrowsError(try parse("{\"id\":\"a\",\"webpage_url\":\"https://x.org/w\",\"formats\":[{\"url\":\"javascript:alert(1)\",\"ext\":\"mp4\",\"vcodec\":\"h\"}]}"))
        XCTAssertThrowsError(try parse("{\"id\":\"a\",\"webpage_url\":\"https://x.org/w\",\"formats\":[{\"url\":\"http://192.168.0.2/a.mp4\",\"ext\":\"mp4\",\"vcodec\":\"h\",\"acodec\":\"a\"}]}"), "a local address is refused")
        XCTAssertThrowsError(try parse("{\"id\":\"a\",\"webpage_url\":\"https://x.org/w\",\"formats\":[{\"url\":\"https://c.example/a.jpg\",\"ext\":\"jpg\",\"vcodec\":\"h\"}]}"), "a picture is not media")
        XCTAssertNoThrow(try parse("{\"id\":\"a\",\"webpage_url\":\"https://x.org/w\",\"formats\":[{\"url\":\"https://c.example/a.mp4\",\"ext\":\"mp4\",\"vcodec\":\"h\",\"acodec\":\"a\"}]}"))
        XCTAssertTrue(ExtractorParser.sameSite("www.youtube.com", "m.youtube.com")); XCTAssertFalse(ExtractorParser.sameSite("youtube.com", "evil.com"))
    }
}
