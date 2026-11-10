import CryptoKit
import XCTest
@testable import Browser_Setu

/// Speed limits, proxies, FTP symbolic links and SHA-512: each against the real thing (OpenSSH, curl, the local proxy fixture).
final class ProxyFixture {
    let http: Int, socks: Int, ctl: Int
    private var process: Process?
    init(mapping target: Int, auth: String? = nil) throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/download_proxy_fixture.py").path
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-I", script, "--http", "0", "--socks", "0", "--ctl", "0", "--map", "originhost=127.0.0.1:\(target)"] + (auth.map { ["--auth", $0] } ?? [])
        let o = Pipe(); p.standardOutput = o; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        try p.run(); process = p
        let line = String(decoding: o.fileHandleForReading.availableData, as: UTF8.self)
        func port(_ k: String) -> Int { line.components(separatedBy: " ").first { $0.hasPrefix(k + "=") }.flatMap { Int($0.dropFirst(k.count + 1).trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0 }
        http = port("http"); socks = port("socks"); ctl = port("ctl")
        guard http > 0, socks > 0, ctl > 0 else { throw NSError(domain: "proxy", code: 1, userInfo: [NSLocalizedDescriptionKey: "the proxy fixture did not start: \(line)"]) }
    }
    func stop() { process?.terminate() }
    func log() async -> [[String: Any]] {
        guard let (d, _) = try? await URLSession(configuration: .ephemeral).data(from: URL(string: "http://127.0.0.1:\(ctl)/log")!), let j = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return [] }
        return j
    }
}

final class RemoteExtrasTests: XCTestCase {
    func sha(_ u: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: u)).map { String(format: "%02x", $0) }.joined() }
    final class Box: @unchecked Sendable { var all: [RemoteEntry] = []; let l = NSLock(); func add(_ e: [RemoteEntry]) { l.lock(); all += e; l.unlock() } }

    func testSpeedLimitsSlowSFTPAndFTPToTheLimitWithExactBytes() async throws {
        let sshd = try SSHDFixture(); defer { sshd.stop() }
        _ = try await sshd.trustHostKey()
        let big = sshd.tree.appendingPathComponent("limited.bin"); let size = 6_000_000
        var d = Data(count: size); d.withUnsafeMutableBytes { for i in 0..<$0.count { $0[i] = UInt8(truncatingIfNeeded: i &* 5 &+ (i >> 4)) } }; try d.write(to: big)
        let s = SFTPSession(config: sshd.config(key: sshd.clientKey)); defer { s.close() }
        try await s.connect()
        let out = sshd.root.appendingPathComponent("lim.out"); FileManager.default.createFile(atPath: out.path, contents: nil); let fd = open(out.path, O_WRONLY); defer { close(fd) }
        let t0 = Date()
        let got = try await s.download(big.path, into: fd, from: 0, size: UInt64(size), rateLimit: { 3_000_000 }) { _ in }
        let secs = Date().timeIntervalSince(t0)
        XCTAssertEqual(got, UInt64(size)); XCTAssertEqual(try Data(contentsOf: out), d)
        XCTAssertGreaterThan(secs, 1.6, "6 MB at 3 MB/s takes about two seconds, not the instant it takes unlimited"); XCTAssertLessThan(secs, 6)
        print("PERF sftp limit 3 MB/s: 6 MB in \(String(format: "%.2f", secs)) s")

        let ftp = try FTPFixture(); defer { ftp.stop() }
        try d.write(to: ftp.files.appendingPathComponent("limited.bin"))
        var cfg = ftp.config(); cfg.rateLimit = 2_000_000
        let f = FTPSession(config: cfg); defer { f.close() }
        let o2 = ftp.root.appendingPathComponent("lim2.out"); let t1 = Date()
        try await f.download("/limited.bin", to: o2, from: 0) { _ in }
        let secs2 = Date().timeIntervalSince(t1)
        XCTAssertEqual(try Data(contentsOf: o2), d); XCTAssertGreaterThan(secs2, 1.5, "6 MB at 2 MB/s"); print("PERF ftp limit 2 MB/s: 6 MB in \(String(format: "%.2f", secs2)) s")
    }

    func testSFTPThroughSOCKS5AndHTTPConnectProxiesWithAndWithoutCredentialsAndFTPControlThroughSOCKS5() async throws {
        let sshd = try SSHDFixture(); defer { sshd.stop() }
        try await Task.sleep(nanoseconds: 100_000_000)
        let payload = Data((0..<500_000).map { UInt8(truncatingIfNeeded: $0 &* 3) }); try payload.write(to: sshd.tree.appendingPathComponent("p.bin"))
        // The server is only reachable by the name "originhost", which exists nowhere but inside the proxy: a connection that did not go through it could not work.
        let keys = try await SSHHostKeyStore.scan(host: "127.0.0.1", port: sshd.port)
        try SSHHostKeyStore(file: sshd.knownHosts).trust(try XCTUnwrap(keys.first), host: "originhost", port: sshd.port)
        func config(_ proxy: RemoteProxy?) -> SFTPConfig { SFTPConfig(host: "originhost", port: sshd.port, user: NSUserName(), identityFile: sshd.clientKey.path, secret: nil, useAgent: false, knownHosts: sshd.knownHosts, proxy: proxy) }

        let open = try ProxyFixture(mapping: sshd.port); defer { open.stop() }
        for kind in [RemoteProxy.Kind.socks5, .httpConnect] {
            let s = SFTPSession(config: config(RemoteProxy(kind: kind, host: "127.0.0.1", port: kind == .socks5 ? open.socks : open.http))); defer { s.close() }
            try await s.connect()
            let box = Box(); _ = try await s.list(sshd.tree.path, limit: 100) { box.add($0) }
            XCTAssertEqual(box.all.map(\.name), ["p.bin"], "listed through the \(kind == .socks5 ? "SOCKS 5" : "HTTP CONNECT") proxy")
            let out = sshd.root.appendingPathComponent("p-\(kind == .socks5 ? "s" : "h").out"); FileManager.default.createFile(atPath: out.path, contents: nil); let fd = Darwin.open(out.path, O_WRONLY); defer { close(fd) }
            _ = try await s.download(sshd.tree.appendingPathComponent("p.bin").path, into: fd, from: 0, size: 500_000) { _ in }
            XCTAssertEqual(try Data(contentsOf: out), payload)
        }
        let seen = await open.log().compactMap { $0["target"] as? String }
        XCTAssertTrue(seen.contains { $0.hasPrefix("originhost:") }, "the proxy was asked for the server: \(seen)")
        // Without the proxy the name cannot be reached at all.
        let direct = SFTPSession(config: config(nil)); defer { direct.close() }
        do { try await direct.connect(); XCTFail("originhost exists only inside the proxy") } catch { XCTAssertTrue((error as? RemoteError)?.errorDescription != nil) }

        // A proxy that wants a password: refused without it, with a wrong one, accepted with the right one.
        let locked = try ProxyFixture(mapping: sshd.port, auth: "bob:pw"); defer { locked.stop() }
        for (user, pass, ok) in [(nil as String?, nil as String?, false), ("bob", "wrong", false), ("bob", "pw", true)] {
            let s = SFTPSession(config: config(RemoteProxy(kind: .socks5, host: "127.0.0.1", port: locked.socks, username: user, password: pass))); defer { s.close() }
            if ok { try await s.connect(); let home = try await s.canonical("."); XCTAssertTrue(home.hasPrefix("/"), "signed in to the proxy with its user name and password") }
            else { do { try await s.connect(); XCTFail("the proxy must refuse \(String(describing: user))/\(String(describing: pass))") } catch {} }
        }

        // FTP: through SOCKS 5 (the control connection, which is all a size check needs); an HTTP proxy cannot carry FTP and says so.
        let ftp = try FTPFixture(); defer { ftp.stop() }
        try Data(count: 1234).write(to: ftp.files.appendingPathComponent("z.bin"))
        let ftpProxy = try ProxyFixture(mapping: ftp.port); defer { ftpProxy.stop() }
        var fc = ftp.config(); fc.host = "originhost"; fc.proxy = RemoteProxy(kind: .socks5, host: "127.0.0.1", port: ftpProxy.socks)
        let info = try await FTPSession(config: fc).info("/z.bin"); XCTAssertEqual(info.size, 1234, "an FTP size check through the SOCKS 5 proxy")
        let ftpSeen = await ftpProxy.log().compactMap { $0["target"] as? String }; XCTAssertTrue(ftpSeen.contains { $0.hasPrefix("originhost:") }, "\(ftpSeen)")
        fc.proxy = RemoteProxy(kind: .httpConnect, host: "127.0.0.1", port: ftpProxy.http)
        do { _ = try await FTPSession(config: fc).info("/z.bin"); XCTFail("FTP over an HTTP proxy") } catch { XCTAssertTrue("\(error)".contains("HTTP proxy") || (error as? RemoteError)?.errorDescription?.contains("HTTP proxy") == true, "\(error)") }
    }

    @MainActor
    func testFTPSymbolicLinksAreResolvedAndSHA512FromAMetalinkIsChecked() async throws {
        let ftp = try FTPFixture(extra: ["--symlinks"]); defer { ftp.stop() }
        try Data("hello".utf8).write(to: ftp.files.appendingPathComponent("real.txt"))
        let sub = ftp.files.appendingPathComponent("folder"); try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: ftp.files.appendingPathComponent("link-file"), withDestinationURL: ftp.files.appendingPathComponent("real.txt"))
        try FileManager.default.createSymbolicLink(at: ftp.files.appendingPathComponent("link-dir"), withDestinationURL: sub)
        try FileManager.default.createSymbolicLink(at: ftp.files.appendingPathComponent("link-nowhere"), withDestinationURL: ftp.files.appendingPathComponent("absent"))
        let s = FTPSession(config: ftp.config()); defer { s.close() }
        let box = Box(); _ = try await s.list("/", limit: 100) { box.add($0) }
        let by = Dictionary(uniqueKeysWithValues: box.all.map { ($0.name, $0) })
        XCTAssertEqual(by["link-file"]?.kind, .file); XCTAssertEqual(by["link-file"]?.size, 5, "a link to a file is a file, with its size")
        XCTAssertEqual(by["link-dir"]?.kind, .directory, "a link to a folder opens as a folder")
        XCTAssertEqual(by["link-nowhere"]?.isBroken, true, "a link to nowhere is shown, and cannot be chosen")

        // SHA-512: the document's value is read (version 4 and 3), and a finished download is checked against it.
        let v4 = "<metalink xmlns=\"urn:ietf:params:xml:ns:metalink\"><file name=\"a.bin\"><hash type=\"sha-512\">\(String(repeating: "ab", count: 64))</hash><url>https://m.example.org/a.bin</url></file></metalink>"
        XCTAssertEqual(try MetalinkParser.parse(Data(v4.utf8)).first?.sha512, String(repeating: "ab", count: 64))
        let v3 = "<metalink version=\"3.0\" xmlns=\"http://www.metalinker.org/\"><files><file name=\"b.bin\"><verification><hash type=\"sha512\">\(String(repeating: "cd", count: 64))</hash></verification><resources><url type=\"https\">https://m.example.org/b.bin</url></resources></file></files></metalink>"
        XCTAssertEqual(try MetalinkParser.parse(Data(v3.utf8)).first?.sha512, String(repeating: "cd", count: 64))
        XCTAssertThrowsError(try MetalinkParser.parse(Data("<metalink xmlns=\"urn:ietf:params:xml:ns:metalink\"><file name=\"c\"><hash type=\"sha-512\">12</hash><url>https://m.example.org/c</url></file></metalink>".utf8)))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bs-sha512-\(UUID().uuidString.prefix(8))"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let saved = DownloadCoordinator.directoryOverride; DownloadCoordinator.directoryOverride = dir; defer { DownloadCoordinator.directoryOverride = saved }
        let good = dir.appendingPathComponent("good.bin"), bad = dir.appendingPathComponent("bad.bin")
        try Data("payload".utf8).write(to: good); try Data("payload".utf8).write(to: bad)
        let digest = SHA512.hash(data: Data("payload".utf8)).map { String(format: "%02x", $0) }.joined()
        let (c, a, b): (DownloadCoordinator, UUID?, UUID?) = await MainActor.run {
            let c = DownloadCoordinator(); c.profileName = "sha512-test-\(UUID().uuidString.prefix(6))"; c.store = dir.appendingPathComponent("store"); c.hasHost = { true }
            let a = c.recordProducedFile(good, source: nil, isPrivate: false), b = c.recordProducedFile(bad, source: nil, isPrivate: false)
            if let b { c.ledger.update(b) { $0.file.integrity = .unknown } }
            if let a { c.ledger.update(a) { $0.file.integrity = .unknown; $0.engineMetadata["sha512"] = digest } }
            if let b { c.ledger.update(b) { $0.engineMetadata["sha512"] = String(repeating: "0", count: 128) } }
            return (c, a, b)
        }
        try await Task.sleep(nanoseconds: 2_500_000_000)
        let (ia, ib) = await MainActor.run { (a.flatMap { c.ledger.record($0)?.file.integrity }, b.flatMap { c.ledger.record($0)?.file.integrity }) }
        XCTAssertEqual(ia, .verified, "the file matches its SHA-512"); XCTAssertEqual(ib, .mismatch, "a different file does not")
    }
}
