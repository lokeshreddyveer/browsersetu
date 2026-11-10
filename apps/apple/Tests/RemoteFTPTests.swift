import CryptoKit
import XCTest
@testable import Browser_Setu

/// A small FTP/FTPS server written for the tests (scripts/ftp_fixture_server.py, standard library only) and the system's curl as the client. Throwaway files and certificate in a temporary folder.
final class FTPFixture {
    let root: URL, files: URL, port: Int
    var cert: URL { root.appendingPathComponent("cert.pem") }
    private var supervised: String?

    init(extra: [String] = [], tls: Bool = false, implicit: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bs-ftp-\(UUID().uuidString.prefix(8))")
        files = root.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: files.appendingPathComponent("sub"), withIntermediateDirectories: true)
        port = Int.random(in: 30_000..<36_000)
        var args = [files.path, String(port)] + extra
        if tls {
            let key = root.appendingPathComponent("key.pem")
            let o = Process(); o.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            o.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key.path, "-out", cert.path, "-days", "2", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1"]
            o.standardOutput = FileHandle.nullDevice; o.standardError = FileHandle.nullDevice
            try o.run(); o.waitUntilExit()
            args += ["--tls", cert.path, key.path] + (implicit ? ["--implicit"] : [])
        }
        // The server itself is started by the test scheme's supervisor (a sandboxed test host cannot start it); the files above are in this process's own temporary folder.
        supervised = try TestProcessSupervisor.start(kind: "ftp", args: args)
    }

    func stop() { TestProcessSupervisor.stop(supervised); supervised = nil; try? FileManager.default.removeItem(at: root) }

    func config(user: String? = "alice", password: String? = "s3cret", tls: Bool = false, implicit: Bool = false, trusted: Bool = false) -> FTPConfig {
        FTPConfig(host: "127.0.0.1", port: port, user: user, password: password, explicitTLS: tls && !implicit, implicitTLS: implicit, trustedCertificate: trusted ? cert : nil)
    }
}

final class RemoteFTPTests: XCTestCase {
    var server: FTPFixture!
    override func tearDown() { server?.stop() }

    func fill(_ name: String, bytes: Int) throws -> URL {
        let u = server.files.appendingPathComponent(name)
        var d = Data(count: bytes); d.withUnsafeMutableBytes { for i in 0..<$0.count { $0[i] = UInt8(truncatingIfNeeded: i &* 7 &+ (i >> 9)) } }
        try d.write(to: u); return u
    }
    func sha(_ u: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: u)).map { String(format: "%02x", $0) }.joined() }
    final class Box: @unchecked Sendable { var all: [RemoteEntry] = []; let l = NSLock(); func add(_ e: [RemoteEntry]) { l.lock(); all += e; l.unlock() } }

    func testPlainFTPListsDownloadsResumesAndReportsErrors() async throws {
        server = try FTPFixture()
        let big = try fill("big.bin", bytes: 4_000_003)
        try Data("hi".utf8).write(to: server.files.appendingPathComponent("Ünï café.txt")); try Data("x".utf8).write(to: server.files.appendingPathComponent("sub/in.txt"))
        let s = FTPSession(config: server.config()); defer { s.close() }
        let box = Box()
        let r = try await s.list("/", limit: 100) { box.add($0) }
        XCTAssertEqual(r.count, 3)
        let by = Dictionary(uniqueKeysWithValues: box.all.map { ($0.name, $0) })
        XCTAssertEqual(by["big.bin"]?.size, 4_000_003); XCTAssertEqual(by["sub"]?.kind, .directory); XCTAssertEqual(by["Ünï café.txt"]?.size, 2, "Unicode names survive")
        XCTAssertNotNil(by["big.bin"]?.modified)
        let sub = Box(); _ = try await s.list("/sub", limit: 100) { sub.add($0) }; XCTAssertEqual(sub.all.map(\.name), ["in.txt"])

        let info = try await s.info("/big.bin"); XCTAssertEqual(info.size, 4_000_003)
        let out = server.root.appendingPathComponent("out.bin")
        let t0 = Date()
        try await s.download("/big.bin", to: out, from: 0) { _ in }
        let secs = Date().timeIntervalSince(t0)
        XCTAssertEqual(try sha(out), try sha(big)); print("FTP-PERF 4 MB in \(String(format: "%.3f", secs)) s")
        // Resume from what a stopped transfer left: the file holds exactly the first 1,500,000 bytes.
        let part = server.root.appendingPathComponent("part.bin")
        try Data(contentsOf: big).prefix(1_500_000).write(to: part)
        try await s.download("/big.bin", to: part, from: 1_500_000) { _ in }
        XCTAssertEqual(try sha(part), try sha(big), "a resumed FTP download equals the original")

        do { try await s.download("/missing.bin", to: server.root.appendingPathComponent("m"), from: 0) { _ in }; XCTFail() } catch { XCTAssertEqual(error as? RemoteError, .notFound) }
        let bad = FTPSession(config: server.config(password: "wrong")); defer { bad.close() }
        do { _ = try await bad.list("/", limit: 10) { _ in }; XCTFail() } catch { XCTAssertEqual(error as? RemoteError, .authenticationFailed) }
        let dead = FTPSession(config: FTPConfig(host: "127.0.0.1", port: 1, user: "a", password: "b")); defer { dead.close() }
        do { _ = try await dead.list("/", limit: 10) { _ in }; XCTFail() } catch { if case .unreachable = error as! RemoteError {} else { XCTFail("\(error)") } }
    }

    func testAnonymousAccessAndServersWithoutMLSDOrREST() async throws {
        server = try FTPFixture(extra: ["--anonymous", "--no-mlsd", "--no-rest"])
        _ = try fill("a.bin", bytes: 100_000); try FileManager.default.createDirectory(at: server.files.appendingPathComponent("d"), withIntermediateDirectories: true)
        let s = FTPSession(config: server.config(user: nil, password: nil)); defer { s.close() }
        let box = Box(); _ = try await s.list("/", limit: 10) { box.add($0) }
        XCTAssertEqual(Set(box.all.map(\.name)), ["a.bin", "d", "sub"], "anonymous login and the older LIST format")
        XCTAssertEqual(box.all.first { $0.name == "a.bin" }?.size, 100_000); XCTAssertEqual(box.all.first { $0.name == "d" }?.kind, .directory)
        // A server that cannot resume: the error says so, so the app restarts the file instead of appending wrong bytes.
        let part = server.root.appendingPathComponent("p"); try Data(count: 5000).write(to: part)
        do { try await s.download("/a.bin", to: part, from: 5000) { _ in }; XCTFail("no REST") } catch { XCTAssertEqual(error as? RemoteError, .unsupported("resume")) }
    }

    func testAConnectionCutShortKeepsItsBytesAndResumesToTheExactFile() async throws {
        server = try FTPFixture(extra: ["--flaky", "cut.bin"])
        let src = try fill("cut.bin", bytes: 3_000_000)
        let s = FTPSession(config: server.config()); defer { s.close() }
        let out = server.root.appendingPathComponent("cut.out")
        do { try await s.download("/cut.bin", to: out, from: 0) { _ in }; XCTFail("the server cut the transfer") } catch { XCTAssertTrue((error as? RemoteError)?.isRetryable == true, "\(error)") }
        let have = (try FileManager.default.attributesOfItem(atPath: out.path)[.size] as! NSNumber).int64Value
        XCTAssertGreaterThan(have, 0); XCTAssertLessThan(have, 3_000_000)
        try await s.download("/cut.bin", to: out, from: have) { _ in }
        XCTAssertEqual(try sha(out), try sha(src), "after the cut, the rest was fetched and the file is exact")
    }

    func testExplicitFTPSRefusesAnUntrustedCertificateAndTrustsOneThePersonSaved() async throws {
        server = try FTPFixture(tls: true)
        let src = try fill("s.bin", bytes: 500_000)
        let untrusted = FTPSession(config: server.config(tls: true)); defer { untrusted.close() }
        do { _ = try await untrusted.list("/", limit: 10) { _ in }; XCTFail("a self-signed certificate must not be accepted silently") } catch { if case .certificateRejected = error as! RemoteError {} else { XCTFail("\(error)") } }
        let presented = try await FTPSession.presentedCertificate(host: "127.0.0.1", port: server.port, implicit: false)
        XCTAssertTrue(presented.fingerprint.hasPrefix("SHA256:")); XCTAssertEqual(presented.fingerprint.split(separator: ":").count, 33)
        XCTAssertEqual(presented.pem.trimmingCharacters(in: .whitespacesAndNewlines), try String(contentsOf: server.cert).trimmingCharacters(in: .whitespacesAndNewlines), "what was shown is what the server uses")
        let trusted = FTPSession(config: server.config(tls: true, trusted: true)); defer { trusted.close() }
        let box = Box(); _ = try await trusted.list("/", limit: 10) { box.add($0) }; XCTAssertEqual(Set(box.all.map(\.name)), ["s.bin", "sub"])
        let out = server.root.appendingPathComponent("s.out")
        try await trusted.download("/s.bin", to: out, from: 0) { _ in }
        XCTAssertEqual(try sha(out), try sha(src), "bytes over explicit FTPS")
    }

    func testListingParsersRefuseHostileNames() {
        let m = FTPSession.parseListing("type=file;size=1;modify=20260101000000; ok.txt\ntype=file;size=1; ../evil\ntype=file;size=1; a/b\ntype=cdir; .\ntype=dir;modify=20260101000000; folder\ntype=OS.unix=slink:/x; link", mlsd: true)
        XCTAssertEqual(m.map(\.name), ["ok.txt", "folder", "link"]); XCTAssertEqual(m.last?.kind, .symlink)
        let u = FTPSession.parseListing("-rw-r--r--   1 ftp ftp  1234 Jan  5 10:11 file name.txt\ndrwxr-xr-x   2 ftp ftp  4096 Jan  5 10:11 dir\nlrwxrwxrwx   1 ftp ftp     5 Jan  5 10:11 lnk -> target\n-rw-r--r--   1 ftp ftp     1 Jan  5 10:11 ..", mlsd: false)
        XCTAssertEqual(u.map(\.name), ["file name.txt", "dir", "lnk"]); XCTAssertEqual(u.first?.size, 1234)
        let s = FTPSession(config: FTPConfig(host: "h.example", port: 2121))
        XCTAssertEqual(s.url(for: "/a b/ü?#/x.txt"), "ftp://h.example:2121//a%20b/%C3%BC%3F%23/x.txt", "reserved characters in a path are escaped")
        XCTAssertThrowsError(try FTPSession.validate(FTPConfig(host: "-oProxyCommand=x", user: "a", password: "b")))
        XCTAssertThrowsError(try FTPSession.validate(FTPConfig(host: "h", user: "a\nb", password: "b")))
    }
}

final class MetalinkImportTests: XCTestCase {
    let v4 = """
    <?xml version="1.0" encoding="UTF-8"?><metalink xmlns="urn:ietf:params:xml:ns:metalink">
    <file name="a.iso"><size>1000</size><hash type="sha-256">\(String(repeating: "ab", count: 32))</hash><url priority="2">https://mirror2.example.org/a.iso</url><url priority="1">https://mirror1.example.org/a.iso</url></file>
    <file name="b.iso"><url>http://127.0.0.1/b.iso</url><url>https://mirror.example.org/b.iso</url></file></metalink>
    """
    let v3 = """
    <?xml version="1.0" encoding="UTF-8"?><metalink version="3.0" xmlns="http://www.metalinker.org/"><files>
    <file name="old.zip"><size>55</size><verification><hash type="sha256">\(String(repeating: "cd", count: 32))</hash><hash type="md5">abc</hash></verification>
    <resources><url type="http" preference="50">http://low.example.org/old.zip</url><url type="https" preference="100">https://high.example.org/old.zip</url><url type="ftp" preference="90">ftp://x.example.org/old.zip</url><url type="bittorrent">http://t.example.org/x.torrent</url></resources></file></files></metalink>
    """

    func testMetalink4AndTheOlderMetalink3AreBothReadWithTheirPreferencesAndHashes() throws {
        let a = try MetalinkParser.parse(Data(v4.utf8))
        XCTAssertEqual(a.map(\.name), ["a.iso", "b.iso"]); XCTAssertEqual(a[0].urls, ["https://mirror1.example.org/a.iso", "https://mirror2.example.org/a.iso"], "lower priority number first"); XCTAssertEqual(a[0].sha256?.count, 64)
        let o = try MetalinkParser.parse(Data(v3.utf8))
        XCTAssertEqual(o.count, 1); XCTAssertEqual(o[0].urls.first, "https://high.example.org/old.zip", "a higher preference comes first"); XCTAssertEqual(o[0].sha256, String(repeating: "cd", count: 32))
        XCTAssertFalse(o[0].urls.contains { $0.hasPrefix("ftp:") }, "only web sources"); XCTAssertTrue(o[0].notes.contains { $0.contains("md5") }, "a weak hash is said to be ignored")
        XCTAssertThrowsError(try MetalinkParser.parse(Data("<metalink xmlns=\"http://www.metalinker.org/\"><files><file name=\"../x\"><resources><url type=\"http\">http://e.example.org/x</url></resources></file></files></metalink>".utf8)))
        XCTAssertThrowsError(try MetalinkParser.parse(Data("<!DOCTYPE x [<!ENTITY e SYSTEM \"file:///etc/passwd\">]><metalink xmlns=\"urn:ietf:params:xml:ns:metalink\"/>".utf8)))
    }

    struct Stub: HostAddressResolving { var map: [String: [String]]; func addresses(for host: String) async -> [String]? { map[host] } }

    @MainActor
    func testAMetalinkBecomesACollectionAndOnlyAVerifiedPublicFileMayUseItsSourcesTogether() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bs-ml-\(UUID().uuidString.prefix(8))"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let saved = DownloadCoordinator.directoryOverride; DownloadCoordinator.directoryOverride = dir; defer { DownloadCoordinator.directoryOverride = saved }
        let c = DownloadCoordinator(); c.profileName = "ml-test-\(UUID().uuidString.prefix(6))"; c.store = dir.appendingPathComponent("store"); c.hasHost = { true }
        let files = try MetalinkParser.parse(Data(v4.utf8))
        let stub = Stub(map: ["mirror1.example.org": ["93.184.216.34"], "mirror2.example.org": ["93.184.216.35"], "mirror.example.org": ["93.184.216.36"]])
        let publicA = await MetalinkImport.isPublic(files[0], resolver: stub), localB = await MetalinkImport.isPublic(files[1], resolver: stub)
        XCTAssertTrue(publicA); XCTAssertFalse(localB, "a source on this Mac's own network is not public")
        let sneaky = MetalinkFile(name: "s", size: nil, sha256: String(repeating: "ab", count: 32), urls: ["https://attacker.example.org/s"], notes: [])
        let sneakyPublic = await MetalinkImport.isPublic(sneaky, resolver: Stub(map: ["attacker.example.org": ["192.168.1.5"]])); let unresolvable = await MetalinkImport.isPublic(sneaky, resolver: Stub(map: [:]))
        XCTAssertFalse(sneakyPublic, "a name that points inside this Mac's network is not public"); XCTAssertFalse(unresolvable)
        let later = Date().addingTimeInterval(3600)          // put off: nothing is fetched by this test
        let out = await MetalinkImport.add(files, title: "Release", documentKey: "metalink:test", coordinator: c, startAt: later, resolver: stub)
        XCTAssertEqual(out.started, 2); XCTAssertEqual(out.combined, 1, "only the verified, all-public file")
        let pkg = try XCTUnwrap(c.packages.package(withSource: "metalink:test")); XCTAssertEqual(pkg.members.count, 2)
        let ids = pkg.members
        let verified = try XCTUnwrap(ids.first { c.ledger.record($0)?.file.filename == "a.iso" }), plain = try XCTUnwrap(ids.first { c.ledger.record($0)?.file.filename == "b.iso" })
        XCTAssertTrue(c.mirrors.canCombine(verified), "a given SHA-256 and public sources: used together, checked at the end"); XCTAssertFalse(c.mirrors.canCombine(plain), "no hash, and a local source: one source at a time")
        let again = await MetalinkImport.add(files, title: "Release", documentKey: "metalink:test", coordinator: c, startAt: later, resolver: stub)
        XCTAssertEqual(again.alreadyThere, 2, "opening it again adds nothing twice")
        let said = MetalinkImport.summary(files)
        XCTAssertTrue(said.contains("a.iso") && said.contains("1000 bytes".replacingOccurrences(of: "1000 bytes", with: "1 KB")) && said.contains("checked against its SHA-256"), said)
        XCTAssertTrue(said.contains("no hash given, so not checked"), "a file without a hash is said not to be checked: \(said)")
        XCTAssertTrue(MetalinkLink.isMetalink(URL(string: "https://x.example/a.meta4")!)); XCTAssertFalse(MetalinkLink.isMetalink(URL(string: "ftp://x.example/a.meta4")!)); XCTAssertFalse(MetalinkLink.isMetalink(URL(string: "https://x.example/a.zip")!))
    }
}
