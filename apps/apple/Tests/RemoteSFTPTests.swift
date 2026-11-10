import CryptoKit
import XCTest
@testable import Browser_Setu

/// A real OpenSSH server (the system's sshd, run as this user on a loopback port with throwaway keys) and a tree of files to fetch. Nothing outside the temporary folder is touched.
final class SSHDFixture {
    let root: URL, port: Int
    let tree: URL, clientKey: URL, passphraseKey: URL, otherKey: URL, knownHosts: URL, hostKeyPub: URL
    private var supervised: String?

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bs-sshd-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        tree = root.appendingPathComponent("tree"); clientKey = root.appendingPathComponent("client"); passphraseKey = root.appendingPathComponent("client-pp"); otherKey = root.appendingPathComponent("other")
        knownHosts = root.appendingPathComponent("known_hosts"); hostKeyPub = root.appendingPathComponent("host.pub")
        port = Int.random(in: 24_000..<30_000)
        let host = root.appendingPathComponent("host")
        func keygen(_ file: URL, pass: String = "") throws {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen"); p.arguments = ["-q", "-t", "ed25519", "-N", pass, "-f", file.path, "-C", "bs-test"]
            try p.run(); p.waitUntilExit(); if p.terminationStatus != 0 { throw NSError(domain: "keygen", code: 1) }
        }
        try keygen(host); try keygen(clientKey); try keygen(passphraseKey, pass: "s3cret pass"); try keygen(otherKey)
        try FileManager.default.copyItem(at: root.appendingPathComponent("host.pub"), to: hostKeyPub.deletingLastPathComponent().appendingPathComponent("host-copy.pub"))
        let authorized = root.appendingPathComponent("authorized_keys")
        let keys = try [clientKey, passphraseKey].map { try String(contentsOf: URL(fileURLWithPath: $0.path + ".pub")) }.joined()
        try keys.write(to: authorized, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authorized.path)
        let config = """
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(host.path)
        PidFile \(root.appendingPathComponent("pid").path)
        AuthorizedKeysFile \(authorized.path)
        PubkeyAuthentication yes
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        UsePAM no
        StrictModes no
        LogLevel ERROR
        Subsystem sftp /usr/libexec/sftp-server
        """
        try config.write(to: root.appendingPathComponent("sshd_config"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        // sshd is started by the test scheme's supervisor (a sandboxed test host cannot start it); its config, keys and tree are in this process's own temporary folder.
        supervised = try TestProcessSupervisor.start(kind: "sshd", args: [root.appendingPathComponent("sshd_config").path], port: port)
    }

    func stop() { TestProcessSupervisor.stop(supervised); supervised = nil; try? FileManager.default.removeItem(at: root) }

    func config(key: URL? = nil, secret: String? = nil, knownHosts hosts: URL? = nil) -> SFTPConfig {
        SFTPConfig(host: "127.0.0.1", port: port, user: NSUserName(), identityFile: key?.path, secret: secret, useAgent: false, knownHosts: hosts ?? knownHosts)
    }

    /// Trusts the server's key the way the app does: read it, show it, record it.
    func trustHostKey() async throws -> HostKeyInfo {
        let keys = try await SSHHostKeyStore.scan(host: "127.0.0.1", port: port)
        let key = try XCTUnwrap(keys.first)
        try SSHHostKeyStore(file: knownHosts).trust(key, host: "127.0.0.1", port: port)
        return key
    }
}

final class RemoteSFTPTests: XCTestCase {
    var server: SSHDFixture!
    override func setUpWithError() throws { server = try SSHDFixture() }
    override func tearDown() { server?.stop() }

    func sha(_ url: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined() }

    func makeTree() throws -> (big: URL, bigSize: Int) {
        let t = server.tree
        let big = t.appendingPathComponent("big.bin")
        var data = Data(count: 6_000_001); data.withUnsafeMutableBytes { for i in 0..<$0.count { $0[i] = UInt8(truncatingIfNeeded: i &* 31 &+ (i >> 8)) } }
        try data.write(to: big)
        try Data("hello".utf8).write(to: t.appendingPathComponent("Ünï café ☕.txt"))
        try Data("a\nb".utf8).write(to: t.appendingPathComponent("with\nnewline.txt"))
        let sub = t.appendingPathComponent("sub"); try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("inner".utf8).write(to: sub.appendingPathComponent("inner.txt"))
        try FileManager.default.createSymbolicLink(at: t.appendingPathComponent("link-to-file"), withDestinationURL: t.appendingPathComponent("Ünï café ☕.txt"))
        try FileManager.default.createSymbolicLink(at: t.appendingPathComponent("link-broken"), withDestinationURL: t.appendingPathComponent("nowhere"))
        try FileManager.default.createSymbolicLink(at: sub.appendingPathComponent("loop"), withDestinationURL: t)
        let locked = t.appendingPathComponent("locked"); try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        return (big, data.count)
    }

    final class Collector: @unchecked Sendable { var all: [RemoteEntry] = []; let l = NSLock(); func add(_ e: [RemoteEntry]) { l.lock(); all += e; l.unlock() } }

    func testKeyLoginListsTreeDownloadsExactBytesAndResumes() async throws {
        let (big, size) = try makeTree()
        let key = try await server.trustHostKey()
        XCTAssertTrue(key.fingerprint.hasPrefix("SHA256:"))
        XCTAssertEqual(SSHHostKeyStore(file: server.knownHosts).verdict(host: "127.0.0.1", port: server.port, offered: [key]), .trusted)
        let s = SFTPSession(config: server.config(key: server.clientKey)); defer { s.close() }
        try await s.connect()
        XCTAssertEqual(s.serverVersion, 3)
        let home = try await s.canonical(".")
        XCTAssertTrue(home.hasPrefix("/"))

        let c = Collector()
        let r = try await s.list(server.tree.path, limit: 1000) { c.add($0) }
        XCTAssertFalse(r.truncated)
        let byName = Dictionary(uniqueKeysWithValues: c.all.map { ($0.name, $0) })
        XCTAssertEqual(byName["big.bin"]?.size, Int64(size)); XCTAssertEqual(byName["big.bin"]?.kind, .file)
        XCTAssertEqual(byName["Ünï café ☕.txt"]?.size, 5, "Unicode names come through intact")
        XCTAssertEqual(byName["sub"]?.kind, .directory)
        XCTAssertEqual(byName["link-to-file"]?.kind, .file, "a link is described by its target"); XCTAssertEqual(byName["link-to-file"]?.size, 5)
        XCTAssertEqual(byName["link-broken"]?.isBroken, true, "a link to nowhere is shown, not hidden, and cannot be chosen")
        XCTAssertNil(byName["with\nnewline.txt"], "a name with a control character is not offered")
        do { _ = try await s.list(server.tree.appendingPathComponent("locked").path, limit: 10) { _ in }; XCTFail("a folder this account cannot read") } catch { XCTAssertEqual(error as? RemoteError, .permissionDenied) }
        do { _ = try await s.list(server.tree.appendingPathComponent("absent").path, limit: 10) { _ in }; XCTFail() } catch { XCTAssertEqual(error as? RemoteError, .notFound) }

        // The whole file, byte for byte.
        let out = server.root.appendingPathComponent("out.bin")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        var fd = open(out.path, O_WRONLY); defer { close(fd) }
        let t0 = Date()
        let got = try await s.download(big.path, into: fd, from: 0, size: UInt64(size)) { _ in }
        let seconds = Date().timeIntervalSince(t0)
        XCTAssertEqual(got, UInt64(size)); XCTAssertEqual(try sha(out), try sha(big))
        print("SFTP-PERF 6 MB in \(String(format: "%.3f", seconds)) s = \(String(format: "%.1f", 6.0 / max(seconds, 0.001))) MB/s")

        // Resume: the first 2,500,000 bytes are already here (as a stopped transfer left them); the rest is fetched from there.
        let part = server.root.appendingPathComponent("part.bin")
        try Data(contentsOf: big).prefix(2_500_000).write(to: part)
        close(fd); fd = open(part.path, O_WRONLY)
        let more = try await s.download(big.path, into: fd, from: 2_500_000, size: UInt64(size)) { _ in }
        XCTAssertEqual(more, UInt64(size)); XCTAssertEqual(try sha(part), try sha(big), "a resumed file equals the original")
    }

    func testAnUnknownOrChangedHostKeyIsNeverAcceptedAndAWrongKeyIsRefused() async throws {
        _ = try makeTree()
        // Not trusted yet: ssh itself refuses, whatever the app did before.
        let strange = SFTPSession(config: server.config(key: server.clientKey)); defer { strange.close() }
        do { try await strange.connect(); XCTFail("an untrusted server must be refused") } catch { XCTAssertTrue("\(error)".contains("key") || error is RemoteError, "\(error)") }
        // The app's own check: unknown first, then a different key for the same server is "changed".
        let offered = try await SSHHostKeyStore.scan(host: "127.0.0.1", port: server.port)
        let store = SSHHostKeyStore(file: server.knownHosts)
        guard case .unknown = store.verdict(host: "127.0.0.1", port: server.port, offered: offered) else { return XCTFail("first sight is unknown") }
        let pub = try String(contentsOf: URL(fileURLWithPath: server.otherKey.path + ".pub")).split(separator: " ")
        let imposter = HostKeyInfo(type: String(pub[0]), keyBase64: String(pub[1]), fingerprint: SSHHostKeyStore.fingerprint(ofBase64: String(pub[1]))!)
        try store.trust(imposter, host: "127.0.0.1", port: server.port)          // an earlier, different key was trusted
        guard case .changed(let old, let new) = store.verdict(host: "127.0.0.1", port: server.port, offered: offered) else { return XCTFail("a different key must be reported as changed") }
        XCTAssertEqual(old, [imposter.fingerprint]); XCTAssertEqual(new.type, offered.first { $0.type == new.type }?.type)
        // ...and ssh refuses it as well (defence in depth), and a key the server does not know is refused as a login.
        let refused = SFTPSession(config: server.config(key: server.clientKey)); defer { refused.close() }
        do { try await refused.connect(); XCTFail("a changed key must be refused") } catch {}
        store.forget(host: "127.0.0.1", port: server.port)
        _ = try await server.trustHostKey()
        let wrong = SFTPSession(config: server.config(key: server.otherKey)); defer { wrong.close() }
        do { try await wrong.connect(); XCTFail("a key the server does not know") } catch { XCTAssertEqual(error as? RemoteError, .authenticationFailed) }
    }

    func testAPassphraseReachesSSHThroughThePrivateHelperAndAWrongOneFails() async throws {
        _ = try makeTree(); _ = try await server.trustHostKey()
        let right = SFTPSession(config: server.config(key: server.passphraseKey, secret: "s3cret pass")); defer { right.close() }
        try await right.connect()
        let home = try await right.canonical(".")
        XCTAssertTrue(home.hasPrefix("/"))
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path))?.filter { $0.hasPrefix("bsetu-ssh-") } ?? []
        XCTAssertEqual(leftovers, [], "the temporary helper and the secret are removed once connected")
        let wrong = SFTPSession(config: server.config(key: server.passphraseKey, secret: "not it")); defer { wrong.close() }
        do { try await wrong.connect(); XCTFail("a wrong passphrase") } catch { XCTAssertEqual(error as? RemoteError, .authenticationFailed) }
        let after = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path))?.filter { $0.hasPrefix("bsetu-ssh-") } ?? []
        XCTAssertEqual(after, [], "nothing is left behind after a failed login either")
    }

    func testWireDecodingRefusesAnythingMalformed() throws {
        var r = SFTPWire.Reader(Data([0, 0, 0, 200, 1, 2]))
        XCTAssertThrowsError(try r.stringData(), "a string longer than its packet")
        var r2 = SFTPWire.Reader(Data([0, 0, 0, 9]))
        XCTAssertThrowsError(try SFTPWire.names(&r2))
        var big = SFTPWire.Writer(); big.u32(UInt32(SFTPWire.maxNames + 1)); var r3 = SFTPWire.Reader(big.bytes)
        XCTAssertThrowsError(try SFTPWire.names(&r3), "too many names")
        var ranges = SFTPWire.Ranges()
        ranges.insert(100, count: 50); XCTAssertEqual(ranges.contiguousPrefix, 0, "a gap at the start is not a prefix")
        ranges.insert(0, count: 100); XCTAssertEqual(ranges.contiguousPrefix, 150); XCTAssertEqual(ranges.total, 150)
        ranges.insert(300, count: 10); XCTAssertEqual(ranges.contiguousPrefix, 150, "a later piece does not extend the prefix over a gap")
        XCTAssertFalse(RemoteNames.isSafeComponent("../x")); XCTAssertFalse(RemoteNames.isSafeComponent("a/b")); XCTAssertFalse(RemoteNames.isSafeComponent("..")); XCTAssertTrue(RemoteNames.isSafeComponent("Ünï café"))
        XCTAssertEqual(RemoteNames.localName("a\u{202E}b:c"), "abc")
    }

    func testAnAbortedSFTPDownloadLeavesNoHolesAndAKnownHostsPathWithSpacesWorks() async throws {
        // A known_hosts file in a folder whose name has spaces (as under "Application Support"): the key is still found.
        let spaced = server.root.appendingPathComponent("Application Support/known hosts"); try FileManager.default.createDirectory(at: spaced.deletingLastPathComponent(), withIntermediateDirectories: true)
        let keys = try await SSHHostKeyStore.scan(host: "127.0.0.1", port: server.port)
        try SSHHostKeyStore(file: spaced).trust(try XCTUnwrap(keys.first), host: "127.0.0.1", port: server.port)
        let s = SFTPSession(config: server.config(key: server.clientKey, knownHosts: spaced)); defer { s.close() }
        try await s.connect()
        // A big patterned file; the connection is cut while it is being read.
        let big = server.tree.appendingPathComponent("huge.bin"); let size = 160_000_000
        var d = Data(count: size); d.withUnsafeMutableBytes { for i in 0..<$0.count { $0[i] = UInt8(truncatingIfNeeded: (i &* 31) | 1) } }; try d.write(to: big)
        let out = server.root.appendingPathComponent("huge.out"); FileManager.default.createFile(atPath: out.path, contents: nil)
        let fd = open(out.path, O_WRONLY); defer { close(fd) }
        let task = Task { try await s.download(big.path, into: fd, from: 0, size: UInt64(size)) { _ in } }
        try await Task.sleep(nanoseconds: 150_000_000); s.abort()
        _ = await task.result
        let have = try Data(contentsOf: out)
        XCTAssertLessThan(have.count, size, "the transfer was cut")
        // Everything that is in the file is the real file's bytes: no zero-filled gap (every byte of the pattern is odd, so a hole would show as 0).
        XCTAssertFalse(have.contains(0), "the file holds only a contiguous prefix of the real bytes")
        XCTAssertEqual(have, d.prefix(have.count))
    }

    func testAKeyTypeSwapIsReportedAsAChangeAndNamesAreMadeHarmless() throws {
        let file = server.root.appendingPathComponent("kh"); let store = SSHHostKeyStore(file: file)
        let ed = HostKeyInfo(type: "ssh-ed25519", keyBase64: "AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", fingerprint: "SHA256:x")
        try store.trust(ed, host: "h.example", port: 22)
        let rsa = HostKeyInfo(type: "ssh-rsa", keyBase64: "AAAAB3NzaC1yc2EAAAADAQABAAAAAAAAAAAAAAAAAAAA", fingerprint: "SHA256:y")
        guard case .changed = store.verdict(host: "h.example", port: 22, offered: [rsa]) else { return XCTFail("a server that offers only another kind of key than the trusted one is a CHANGE") }
        XCTAssertEqual(store.verdict(host: "h.example", port: 22, offered: [ed]), .trusted)
        let long = String(repeating: "𝔘", count: 100) + ".mp4"          // 4-byte characters: 400+ bytes
        let local = RemoteNames.localName(long)
        XCTAssertLessThanOrEqual(local.utf8.count, 255); XCTAssertTrue(local.hasSuffix(".mp4"), "the ending is kept")
        XCTAssertEqual(RemoteNames.localName("a\u{200B}b\u{0085}c\u{FEFF}d.txt"), "abcd.txt", "invisible and control characters are removed")
        let sorted = RemoteBrowserModel.sorted([RemoteEntry(name: "x", kind: .file), RemoteEntry(name: "x", kind: .directory), RemoteEntry(name: "a", kind: .file)])
        XCTAssertEqual(sorted.map(\.name), ["a", "x"], "one name is one entry")
        XCTAssertThrowsError(try FTPSession.validate(FTPConfig(host: "h", user: "a:b", password: "p")))
    }
}
