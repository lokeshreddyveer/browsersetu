import XCTest
@testable import Browser_Setu

final class WebDAVFixture {
    let root: URL, files: URL, port: Int
    private var process: Process?, stdin: Pipe?
    init(extra: [String] = []) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bs-dav-\(UUID().uuidString.prefix(8))")
        files = root.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        port = Int.random(in: 36_000..<40_000)
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/webdav_fixture_server.py").path
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); p.arguments = ["-I", script, files.path, String(port)] + extra
        let i = Pipe(), o = Pipe(); p.standardInput = i; p.standardOutput = o; p.standardError = FileHandle.nullDevice
        try p.run(); process = p; stdin = i
        guard String(decoding: o.fileHandleForReading.availableData, as: UTF8.self).contains("ready") else { throw NSError(domain: "dav", code: 1, userInfo: [NSLocalizedDescriptionKey: "the test WebDAV server did not start"]) }
    }
    func stop() { try? stdin?.fileHandleForWriting.write(contentsOf: Data("quit\n".utf8)); process?.terminate(); try? FileManager.default.removeItem(at: root) }
    func config(auth: String? = nil, base: String = "/") -> WebDAVConfig { WebDAVConfig(base: URL(string: "http://127.0.0.1:\(port)\(base)")!, authorization: auth) }
}

final class RemoteWebDAVTests: XCTestCase {
    var server: WebDAVFixture!
    override func tearDown() { server?.stop() }
    final class Box: @unchecked Sendable { var all: [RemoteEntry] = []; let l = NSLock(); func add(_ e: [RemoteEntry]) { l.lock(); all += e; l.unlock() } }

    func testBrowsesFoldersWithUnicodeSizesAndDatesAndDetectsWebDAV() async throws {
        server = try WebDAVFixture()
        try Data(count: 1234).write(to: server.files.appendingPathComponent("data set.parquet"))
        try Data("x".utf8).write(to: server.files.appendingPathComponent("Ünï café ☕.txt"))
        try FileManager.default.createDirectory(at: server.files.appendingPathComponent("reports 2026"), withIntermediateDirectories: true)
        try Data("r".utf8).write(to: server.files.appendingPathComponent("reports 2026/q1.csv"))
        let s = WebDAVSession(config: server.config(), network: DownloadNetworkSetup())
        let dav = try await s.supportsWebDAV(); XCTAssertTrue(dav)
        let box = Box(); let r = try await s.list("/", limit: 100) { box.add($0) }
        XCTAssertEqual(r.count, 3)
        let by = Dictionary(uniqueKeysWithValues: box.all.map { ($0.name, $0) })
        XCTAssertEqual(by["data set.parquet"]?.size, 1234); XCTAssertEqual(by["data set.parquet"]?.kind, .file); XCTAssertNotNil(by["data set.parquet"]?.modified)
        XCTAssertEqual(by["reports 2026"]?.kind, .directory); XCTAssertNil(by["reports 2026"]?.size); XCTAssertEqual(by["Ünï café ☕.txt"]?.size, 1, "Unicode paths round-trip")
        let sub = Box(); _ = try await s.list("/reports 2026", limit: 100) { sub.add($0) }; XCTAssertEqual(sub.all.map(\.name), ["q1.csv"])
        do { _ = try await s.list("/nope", limit: 10) { _ in }; XCTFail() } catch { XCTAssertEqual(error as? RemoteError, .notFound) }
        // The file itself is an ordinary HTTP address.
        XCTAssertEqual(s.url(for: "/reports 2026/q1.csv").absoluteString, "http://127.0.0.1:\(server.port)/reports%202026/q1.csv")
    }

    func testBasicAuthenticationAndAFolderThatIsNotWebDAV() async throws {
        server = try WebDAVFixture(extra: ["--user", "alice", "--password", "s3cret"])
        try Data("x".utf8).write(to: server.files.appendingPathComponent("a.txt"))
        let anonymous = WebDAVSession(config: server.config(), network: DownloadNetworkSetup())
        do { _ = try await anonymous.list("/", limit: 10) { _ in }; XCTFail() } catch { XCTAssertEqual(error as? RemoteError, .authenticationFailed) }
        let wrong = WebDAVSession(config: server.config(auth: "Basic " + Data("alice:bad".utf8).base64EncodedString()), network: DownloadNetworkSetup())
        do { _ = try await wrong.list("/", limit: 10) { _ in }; XCTFail() } catch { XCTAssertEqual(error as? RemoteError, .authenticationFailed) }
        let ok = WebDAVSession(config: server.config(auth: "Basic " + Data("alice:s3cret".utf8).base64EncodedString()), network: DownloadNetworkSetup())
        let box = Box(); _ = try await ok.list("/", limit: 10) { box.add($0) }; XCTAssertEqual(box.all.map(\.name), ["a.txt"])
        XCTAssertThrowsError(try WebDAVSession.validate(WebDAVConfig(base: URL(string: "http://alice:pw@h.example/")!))) { XCTAssertTrue("\($0)".contains("invalidAddress")) }
        XCTAssertThrowsError(try WebDAVSession.validate(WebDAVConfig(base: URL(string: "ftp://h.example/")!)))
    }

    func testAServerListingForeignAndTraversalResourcesIsIgnoredAndStatusMapping() async throws {
        server = try WebDAVFixture(extra: ["--hostile"])
        try Data("x".utf8).write(to: server.files.appendingPathComponent("ok.txt"))
        let s = WebDAVSession(config: server.config(), network: DownloadNetworkSetup())
        let box = Box(); _ = try await s.list("/", limit: 100) { box.add($0) }
        XCTAssertEqual(box.all.map(\.name), ["ok.txt"], "a resource outside the folder, on another host, named '..' or with a slash is not part of the listing")
        XCTAssertEqual(WebDAVSession.statusError(401, headers: ["www-authenticate": "Digest realm=x"]), .unsupported("This server asks for Digest sign-in, which this app does not use. Use a server setting that allows Basic over https, or an app password."))
        XCTAssertEqual(WebDAVSession.statusError(403, headers: [:]), .permissionDenied); XCTAssertEqual(WebDAVSession.statusError(405, headers: [:]), .unsupported("This address is not a WebDAV folder."))
        XCTAssertNil(WebDAVSession.statusError(207, headers: [:]))
        // XML that is not a multistatus, and one with an external entity, are refused or ignored without reading anything outside.
        XCTAssertThrowsError(try WebDAVSession.parseMultistatus(Data("<html><body>hi</body></html>".utf8), requestPath: "/", host: "h"))
        let xxe = Data("<?xml version=\"1.0\"?><!DOCTYPE d [<!ENTITY x SYSTEM \"file:///etc/passwd\">]><D:multistatus xmlns:D=\"DAV:\"><D:response><D:href>/&x;</D:href></D:response></D:multistatus>".utf8)
        let parsed = try? WebDAVSession.parseMultistatus(xxe, requestPath: "/", host: "h")
        XCTAssertTrue((parsed ?? []).isEmpty, "an external entity is never loaded")
    }
}
