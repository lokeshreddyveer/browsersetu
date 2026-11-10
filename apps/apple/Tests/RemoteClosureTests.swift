import CryptoKit
import XCTest
@testable import Browser_Setu

/// The closure pass for DX-11: a server that really checks passwords, the SSH agent, the secret staying out of argv, a cancellable handshake that leaves no process behind, private trust that is never written
/// to the profile, and the WebDAV account that goes when its server is forgotten.

/// A server that accepts connections and never says a word (a host that is up but not an SSH server).
final class SilentServer {
    let port: Int; private var process: Process?
    init() throws {
        port = Int.random(in: 40_000..<44_000)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-I", "-c", "import socket,time\ns=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind(('127.0.0.1',\(port)));s.listen(8)\nconns=[]\nwhile True:\n    c,_=s.accept();conns.append(c)\n"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); process = p
        let end = Date().addingTimeInterval(8)
        while Date() < end { let s = socket(AF_INET, SOCK_STREAM, 0); var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_port = in_port_t(port).bigEndian; a.sin_addr.s_addr = inet_addr("127.0.0.1")
            let ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0; close(s); if ok { return }; Thread.sleep(forTimeInterval: 0.1) }
    }
    func stop() { process?.terminate() }
}

func processLines(matching needle: String) -> [String] {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-ww", "-A", "-o", "pid=,args="]
    let o = Pipe(); p.standardOutput = o; p.standardError = FileHandle.nullDevice
    try? p.run(); let data = o.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init).filter { $0.contains(needle) && !$0.contains("/bin/ps") && !$0.contains("xctest") }
}

/// An SFTP server that checks passwords (scripts/sftp_password_fixture.py + asyncssh from a throwaway folder).
final class PasswordSFTPFixture {
    let root: URL, files: URL, port: Int, knownHosts: URL
    private var process: Process?, stdin: Pipe?
    /// Prepared on purpose by scripts/prepare-sftp-test-deps.sh (hash-pinned wheels); the test never installs anything itself.
    static var lib: String {
        if let env = ProcessInfo.processInfo.environment["BS_PWSERVER_LIB"], !env.isEmpty { return env }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/test-deps/sftp").path
    }
    let password: String
    init(password: String = "s3cret") throws {
        self.password = password
        guard FileManager.default.fileExists(atPath: Self.lib + "/asyncssh") else { throw XCTSkip("asyncssh is not prepared: run scripts/prepare-sftp-test-deps.sh (hash-pinned; the tests never install packages themselves)") }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bs-pw-\(UUID().uuidString.prefix(8))")
        files = root.appendingPathComponent("files"); knownHosts = root.appendingPathComponent("known_hosts")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        port = Int.random(in: 44_000..<48_000)
        let host = root.appendingPathComponent("host")
        let k = Process(); k.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen"); k.arguments = ["-q", "-t", "ed25519", "-N", "", "-f", host.path]; try k.run(); k.waitUntilExit()
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/sftp_password_fixture.py").path
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); p.arguments = ["-I", script, files.path, String(port), host.path, "--password", password]; p.environment = ["BS_PWSERVER_LIB": Self.lib]
        let i = Pipe(), o = Pipe(); p.standardInput = i; p.standardOutput = o; p.standardError = FileHandle.nullDevice
        try p.run(); process = p; stdin = i
        guard String(decoding: o.fileHandleForReading.availableData, as: UTF8.self).contains("ready") else { throw NSError(domain: "pw", code: 2, userInfo: [NSLocalizedDescriptionKey: "the password SFTP fixture did not start"]) }
    }
    func stop() { try? stdin?.fileHandleForWriting.write(contentsOf: Data("quit\n".utf8)); process?.terminate(); try? FileManager.default.removeItem(at: root) }
    func trust() async throws { let keys = try await SSHHostKeyStore.scan(host: "127.0.0.1", port: port); try SSHHostKeyStore(file: knownHosts).trust(try XCTUnwrap(keys.first), host: "127.0.0.1", port: port) }
    func config(password: String?) -> SFTPConfig { SFTPConfig(host: "127.0.0.1", port: port, user: "alice", identityFile: nil, secret: password, useAgent: false, knownHosts: knownHosts) }
}

final class RemoteClosureTests: XCTestCase {
    final class Box: @unchecked Sendable { var all: [RemoteEntry] = []; let l = NSLock(); func add(_ e: [RemoteEntry]) { l.lock(); all += e; l.unlock() } }

    func testSFTPPasswordSignInAgainstAServerThatChecksPasswordsAndTheSecretStaysOutOfTheProcessList() async throws {
        let secret = "pw-\(UUID().uuidString.prefix(12))"          // unique to this run, so no other process (another fixture) can have it
        let server = try PasswordSFTPFixture(password: secret); defer { server.stop() }
        let payload = Data((0..<700_001).map { UInt8(truncatingIfNeeded: $0 &* 17) }); try payload.write(to: server.files.appendingPathComponent("data.bin"))
        try await server.trust()
        let ok = SFTPSession(config: server.config(password: secret)); defer { ok.close() }
        try await ok.connect()
        // While signed in: the password is in no process's argument list.
        XCTAssertEqual(processLines(matching: secret).filter { !$0.contains("sftp_password_fixture") }, [], "the password must never appear in the command line of ssh or anything the app runs (the test server itself is told it, being the thing that checks it)")
        XCTAssertTrue(processLines(matching: "-p \(server.port)").contains { $0.contains("/usr/bin/ssh") }, "(the ssh process is the one running)")
        let box = Box(); _ = try await ok.list("/", limit: 10) { box.add($0) }
        XCTAssertEqual(box.all.map(\.name), ["data.bin"]); XCTAssertEqual(box.all.first?.size, 700_001)
        let out = server.root.appendingPathComponent("out.bin"); FileManager.default.createFile(atPath: out.path, contents: nil); let fd = open(out.path, O_WRONLY); defer { close(fd) }
        let got = try await ok.download("/data.bin", into: fd, from: 0, size: 700_001) { _ in }
        XCTAssertEqual(got, 700_001); XCTAssertEqual(try Data(contentsOf: out), payload, "bytes over a password-authenticated SFTP session")
        // A wrong password and an empty one are refused as sign-in failures, and nothing is left on disk.
        let wrong = SFTPSession(config: server.config(password: "nope")); defer { wrong.close() }
        do { try await wrong.connect(); XCTFail("a wrong password") } catch { XCTAssertEqual(error as? RemoteError, .authenticationFailed) }
        let none = SFTPSession(config: server.config(password: nil)); defer { none.close() }
        do { try await none.connect(); XCTFail("no password at all") } catch { XCTAssertEqual(error as? RemoteError, .authenticationFailed, "the person's own keys are not offered instead") }
        let left = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path))?.filter { $0.hasPrefix("bsetu-ssh-") } ?? []
        XCTAssertEqual(left, [])
        ok.close()
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(processLines(matching: "/usr/bin/ssh").filter { $0.contains("-p \(server.port)") }, [], "closing the session ends its ssh process")
    }

    func testTheSSHAgentIsUsedWhenChosenAndAnUnansweringServerCanBeCancelledWithNoProcessLeft() async throws {
        // (1) A real ssh-agent holding the key: sign in with it, no key file given.
        let sshd = try SSHDFixture(); defer { sshd.stop() }
        _ = try await sshd.trustHostKey()
        let sock = "/private/tmp/bs-agent-\(UUID().uuidString.prefix(6)).sock"
        let agent = Process(); agent.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-agent"); agent.arguments = ["-D", "-a", sock]; agent.standardOutput = FileHandle.nullDevice; agent.standardError = FileHandle.nullDevice
        try agent.run(); defer { agent.terminate(); try? FileManager.default.removeItem(atPath: sock) }
        let end = Date().addingTimeInterval(5); while Date() < end, !FileManager.default.fileExists(atPath: sock) { Thread.sleep(forTimeInterval: 0.1) }
        let add = Process(); add.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add"); add.arguments = [sshd.clientKey.path]; add.environment = ["SSH_AUTH_SOCK": sock]; add.standardOutput = FileHandle.nullDevice; add.standardError = FileHandle.nullDevice
        try add.run(); add.waitUntilExit(); XCTAssertEqual(add.terminationStatus, 0)
        let saved = getenv("SSH_AUTH_SOCK").map { String(cString: $0) }; setenv("SSH_AUTH_SOCK", sock, 1)
        defer { if let saved { setenv("SSH_AUTH_SOCK", saved, 1) } else { unsetenv("SSH_AUTH_SOCK") } }
        var cfg = sshd.config(key: nil); cfg.useAgent = true
        let viaAgent = SFTPSession(config: cfg); defer { viaAgent.close() }
        try await viaAgent.connect()
        let home = try await viaAgent.canonical("."); XCTAssertTrue(home.hasPrefix("/"), "signed in with the key the agent holds")
        viaAgent.close()

        // (2) A server that never answers: Disconnect (cancel) ends the attempt at once and leaves no ssh process.
        let silent = try SilentServer(); defer { silent.stop() }
        try SSHHostKeyStore(file: sshd.knownHosts).trust(HostKeyInfo(type: "ssh-ed25519", keyBase64: "AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", fingerprint: "SHA256:x"), host: "127.0.0.1", port: silent.port)
        let s = SFTPSession(config: SFTPConfig(host: "127.0.0.1", port: silent.port, user: NSUserName(), identityFile: sshd.clientKey.path, secret: nil, useAgent: false, knownHosts: sshd.knownHosts))
        let started = Date()
        let attempt = Task { try await s.connect() }
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertFalse(processLines(matching: "-p \(silent.port)").isEmpty, "the ssh process is running while it waits")
        attempt.cancel()
        _ = await attempt.result
        XCTAssertLessThan(Date().timeIntervalSince(started), 6, "a cancelled connect ends at once, not after the connection timeout")
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(processLines(matching: "-p \(silent.port)"), [], "no ssh process is left after the cancel")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path))?.filter { $0.hasPrefix("bsetu-ssh-") } ?? []
        XCTAssertEqual(left, [])
    }

    @MainActor
    func testPrivateTrustIsNeverWrittenToTheProfileAndWebDAVAccountsGoWithTheirServer() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bs-priv-\(UUID().uuidString.prefix(8))"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let secrets = MemoryAccountSecretStore()
        let store = RemoteConnectionStore(profile: "closure-test", folder: folder, secrets: secrets)
        let key = HostKeyInfo(type: "ssh-ed25519", keyBase64: "AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", fingerprint: "SHA256:x")
        // What a private tab trusts goes to a scratch folder of its own...
        try store.hostKeys(isPrivate: true).trust(key, host: "h.example", port: 22)
        let id = UUID(); try store.trustCertificate(pem: "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n", for: id, isPrivate: true)
        XCTAssertNotNil(store.trustedCertificate(for: id, isPrivate: true)); XCTAssertEqual(store.hostKeys(isPrivate: true).trusted(host: "h.example", port: 22).count, 1)
        // ...never the profile's folder, and a normal session does not see it.
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("remote_known_hosts").path), "the profile's known_hosts was not created by a private tab")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("remote-certs").path))
        XCTAssertEqual(store.hostKeys(isPrivate: false).trusted(host: "h.example", port: 22).count, 0); XCTAssertNil(store.trustedCertificate(for: id, isPrivate: false))
        let scratchPath = FileManager.default.temporaryDirectory.path
        XCTAssertTrue(store.hasPrivateScratch)
        store.wipePrivateScratch()
        XCTAssertFalse(store.hasPrivateScratch); XCTAssertNil(store.trustedCertificate(for: id, isPrivate: true), "ending the private session removes what it trusted"); _ = scratchPath
        // A normal profile does persist its trust.
        try store.hostKeys(isPrivate: false).trust(key, host: "h.example", port: 22)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("remote_known_hosts").path))

        // Forgetting a WebDAV server removes the website account made for it.
        let c = DownloadCoordinator(); c.profileName = "closure-test-\(UUID().uuidString.prefix(6))"; c.store = folder.appendingPathComponent("coordinator"); c.remoteSecretOverride = secrets
        let accounts = AccountStore(profile: c.profileName, file: nil, secrets: secrets); c.accountStore = accounts
        guard case .ok(let accountID) = accounts.add(name: "Cloud", host: "cloud.example", method: .httpBasic, username: "alice", secret: "pw") else { return XCTFail("account") }
        var conn = RemoteConnection(name: "Cloud", scheme: .webdavs, host: "cloud.example", port: 443, user: "alice", auth: .password); conn.davAccountID = accountID
        XCTAssertTrue(c.remotes.save(conn, secret: "pw")); XCTAssertNotNil(accounts.account(accountID))
        let model = RemoteBrowserModel(coordinator: c)
        model.forget(conn)
        XCTAssertNil(accounts.account(accountID), "the site-wide account goes with the server entry"); XCTAssertNil(c.remotes.connection(conn.id)); XCTAssertNil(c.remotes.secret(for: conn.id))
    }
}
