import CryptoKit
import XCTest
@testable import Browser_Setu

/// Remote files as ordinary download tasks, through the real coordinator: queue, progress, pause, resume, retry, naming, ledger, collections. The servers are a real OpenSSH sshd (SFTP) and the
/// test FTP server; secrets go to an in-memory store, never the Keychain.
@MainActor
final class RemoteTransferTests: MediaCase {
    var sshd: SSHDFixture?, ftp: FTPFixture?

    override func setUp() async throws {
        try await super.setUp()
        c.remoteSecretOverride = MemoryAccountSecretStore()
        RemoteFileRunner.backoffSeconds = 0.05
    }
    override func tearDown() async throws {
        sshd?.stop(); ftp?.stop(); RemoteFileRunner.backoffSeconds = 2
        try await super.tearDown()
    }

    func sha(_ u: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: u)).map { String(format: "%02x", $0) }.joined() }
    func pattern(_ n: Int) -> Data { var d = Data(count: n); d.withUnsafeMutableBytes { for i in 0..<$0.count { $0[i] = UInt8(truncatingIfNeeded: i &* 13 &+ (i >> 7)) } }; return d }

    func waitFor(_ id: UUID, _ states: Set<DownloadState>, seconds: Double = 40) async -> DownloadTaskRecord? {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if let r = c.ledger.record(id), states.contains(r.state) { return r }; try? await Task.sleep(nanoseconds: 50_000_000) }
        return c.ledger.record(id)
    }

    func sftpConnection() async throws -> RemoteConnection {
        let s = try SSHDFixture(); sshd = s
        _ = try await s.trustHostKeyInto(c.remotes.hostKeys)
        let conn = RemoteConnection(name: "Test SSH", scheme: .sftp, host: "127.0.0.1", port: s.port, user: NSUserName(), auth: .key, keyPath: s.clientKey.path)
        XCTAssertTrue(c.remotes.save(conn, secret: nil))
        return conn
    }

    func testAnSFTPFileBecomesAnOrdinaryTaskWithExactBytesAndACleanRecord() async throws {
        let conn = try await sftpConnection()
        let src = sshd!.tree.appendingPathComponent("data.bin"); let data = pattern(3_000_017); try data.write(to: src)
        let id = try XCTUnwrap(c.remoteFiles.add(RemoteFileJob(connection: conn.id, path: src.path, size: Int64(data.count), modified: nil, filename: "data.bin")))
        let done = await waitFor(id, [.completed, .failed])
        XCTAssertEqual(done?.state, .completed, "\(String(describing: done?.state)) \(String(describing: c.failures.first?.reason))")
        let record = try XCTUnwrap(done)
        XCTAssertEqual(record.protocolID, .remoteFile); XCTAssertEqual(record.transfer.totalBytes, Int64(data.count)); XCTAssertEqual(record.file.integrity, .verified)
        let path = try XCTUnwrap(record.file.destinationPath)
        XCTAssertEqual(URL(fileURLWithPath: path).deletingLastPathComponent().resolvingSymlinksInPath().path, downloads.resolvingSymlinksInPath().path, "saved in the download folder")
        XCTAssertEqual(try sha(URL(fileURLWithPath: path)), try sha(src), "the file is the server's file, byte for byte")
        let source = record.source.asURL?.absoluteString ?? ""
        XCTAssertTrue(source.hasPrefix("sftp://127.0.0.1:\(sshd!.port)/"), source); XCTAssertFalse(source.contains(NSUserName()) && source.contains("@"), "no user name or password in the record: \(source)")
        XCTAssertNil(c.remotes.secret(for: conn.id))
        // Another file of the same name from the server gets a free name; nothing is replaced.
        let id2 = try XCTUnwrap(c.remoteFiles.add(RemoteFileJob(connection: conn.id, path: src.path, size: Int64(data.count), modified: nil, filename: "data.bin")))
        let second = await waitFor(id2, [.completed, .failed]); XCTAssertEqual(second?.state, .completed)
        XCTAssertNotEqual(second?.file.destinationPath, record.file.destinationPath); XCTAssertEqual(try sha(URL(fileURLWithPath: try XCTUnwrap(second?.file.destinationPath))), try sha(src))
        // A file that is not there fails with a sentence, not a hang.
        let id3 = try XCTUnwrap(c.remoteFiles.add(RemoteFileJob(connection: conn.id, path: src.path + ".gone", size: 10, modified: nil, filename: "gone.bin")))
        let failed = await waitFor(id3, [.failed, .completed]); XCTAssertEqual(failed?.state, .failed)
        XCTAssertTrue(c.failures.contains { $0.id == id3 && $0.reason.contains("not on the server") }, "\(c.failures.map(\.reason))")
    }

    func testAFolderBecomesACollectionKeepingItsStructureAndAFileChangedOnTheServerIsNotMixed() async throws {
        let conn = try await sftpConnection()
        let dir = sshd!.tree.appendingPathComponent("proj"); try FileManager.default.createDirectory(at: dir.appendingPathComponent("docs/deep"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: dir.appendingPathComponent("a.txt")); try Data("b".utf8).write(to: dir.appendingPathComponent("docs/b.txt")); try Data("c".utf8).write(to: dir.appendingPathComponent("docs/deep/c.txt"))
        let session = try c.remotes.makeSession(for: conn, secret: nil, network: DownloadNetworkSetup()); defer { session.close() }
        try await (session as! SFTPSession).connect()
        let plan = try await RemoteFolderPlanner.plan(session: session, roots: [RemoteEntry(name: "proj", kind: .directory)], base: sshd!.tree.path, limits: .default)
        XCTAssertEqual(plan.files.map { $0.subfolders + [$0.name] }.sorted { $0.joined(separator: "/") < $1.joined(separator: "/") }, [["proj", "a.txt"], ["proj", "docs", "b.txt"], ["proj", "docs", "deep", "c.txt"]])
        let started = await RemoteCollection.download(plan, from: conn, base: sshd!.tree.path, title: "proj", coordinator: c)
        XCTAssertEqual(started.started, 3)
        let pkg = try XCTUnwrap(c.packages.package(withSource: started.source))
        for id in pkg.members { let r = await waitFor(id, [.completed, .failed]); XCTAssertEqual(r?.state, .completed) }
        let dests = pkg.members.compactMap { c.ledger.record($0)?.file.destinationPath }.map { String($0.dropFirst(downloads.resolvingSymlinksInPath().path.count)) }
        XCTAssertTrue(dests.contains { $0.hasSuffix("/proj/docs/deep/c.txt") } && dests.contains { $0.hasSuffix("/proj/a.txt") }, "\(dests)")
        XCTAssertEqual(c.packages.progress(of: pkg.id).status, .completed)
        // Asking for the same folder again downloads nothing twice.
        let again = await RemoteCollection.download(plan, from: conn, base: sshd!.tree.path, title: "proj", coordinator: c)
        XCTAssertEqual(again.started, 0); XCTAssertEqual(again.alreadyThere, 3)
    }

    func testFTPDownloadPausesKeepsItsBytesResumesAndSurvivesAConnectionCut() async throws {
        let s = try FTPFixture(extra: ["--throttle", "0.02", "--flaky", "cut.bin"]); ftp = s
        let big = s.files.appendingPathComponent("big.bin"); let data = pattern(2_400_000); try data.write(to: big)
        let cut = s.files.appendingPathComponent("cut.bin"); let cutData = pattern(900_000); try cutData.write(to: cut)
        let conn = RemoteConnection(name: "Test FTP", scheme: .ftp, host: "127.0.0.1", port: s.port, user: "alice", auth: .password)
        XCTAssertTrue(c.remotes.save(conn, secret: "s3cret"))
        let id = try XCTUnwrap(c.remoteFiles.add(RemoteFileJob(connection: conn.id, path: "/big.bin", size: Int64(data.count), modified: nil, filename: "big.bin")))
        // Let some of it arrive, then pause: the bytes stay.
        let end = Date().addingTimeInterval(20)
        while Date() < end, (c.ledger.record(id)?.transfer.completedBytes ?? 0) < 200_000 { try await Task.sleep(nanoseconds: 50_000_000) }
        c.pause(id)
        let paused = await waitFor(id, [.paused, .completed, .failed], seconds: 15)
        XCTAssertEqual(paused?.state, .paused, "\(String(describing: paused?.state))")
        let partial = try XCTUnwrap(c.ledger.record(id)?.file.destinationPath)
        let have = ((try? FileManager.default.attributesOfItem(atPath: partial))?[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(have, 0); XCTAssertLessThan(have, data.count)
        c.resume(id)
        let finished = await waitFor(id, [.completed, .failed], seconds: 60)
        XCTAssertEqual(finished?.state, .completed)
        XCTAssertEqual(try sha(URL(fileURLWithPath: try XCTUnwrap(finished?.file.destinationPath))), try sha(big), "paused and resumed: the exact file")
        // The server drops the first attempt half-way: the app tries again by itself, from the bytes it has.
        let id2 = try XCTUnwrap(c.remoteFiles.add(RemoteFileJob(connection: conn.id, path: "/cut.bin", size: Int64(cutData.count), modified: nil, filename: "cut.bin")))
        let r2 = await waitFor(id2, [.completed, .failed], seconds: 60)
        XCTAssertEqual(r2?.state, .completed); XCTAssertEqual(try sha(URL(fileURLWithPath: try XCTUnwrap(r2?.file.destinationPath))), try sha(cut), "the retry carried on and the file is exact")
        // A wrong password is a clear failure, not a retry loop.
        var bad = conn; bad.id = UUID(); XCTAssertTrue(c.remotes.save(bad, secret: "nope"))
        let id3 = try XCTUnwrap(c.remoteFiles.add(RemoteFileJob(connection: bad.id, path: "/big.bin", size: 1, modified: nil, filename: "x.bin")))
        let r3 = await waitFor(id3, [.failed, .completed]); XCTAssertEqual(r3?.state, .failed)
        XCTAssertTrue(c.failures.contains { $0.id == id3 && $0.reason.contains("refused") }, "\(c.failures.map(\.reason))")
    }

    func testRelaunchKeepsAnInterruptedRemoteTaskAndItsConnectionButNotItsSecretInTheRecord() async throws {
        let s = try FTPFixture(extra: ["--throttle", "0.05"]); ftp = s
        let data = pattern(3_000_000); try data.write(to: s.files.appendingPathComponent("slow.bin"))
        let conn = RemoteConnection(name: "FTP", scheme: .ftp, host: "127.0.0.1", port: s.port, user: "alice", auth: .password)
        XCTAssertTrue(c.remotes.save(conn, secret: "s3cret"))
        let id = try XCTUnwrap(c.remoteFiles.add(RemoteFileJob(connection: conn.id, path: "/slow.bin", size: Int64(data.count), modified: nil, filename: "slow.bin")))
        let end = Date().addingTimeInterval(20)
        while Date() < end, (c.ledger.record(id)?.transfer.completedBytes ?? 0) < 100_000 { try await Task.sleep(nanoseconds: 50_000_000) }
        c.ledger.flush()
        let onDisk = (try? String(contentsOf: folder.appendingPathComponent("remote-connections.json"))) ?? ""
        XCTAssertTrue(onDisk.contains("127.0.0.1")); XCTAssertFalse(onDisk.contains("s3cret"), "the password is never in the connections file")
        for f in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] { if let t = try? String(contentsOf: f), !f.hasDirectoryPath { XCTAssertFalse(t.contains("s3cret"), "the password is nowhere in \(f.lastPathComponent)") } }
        c.cancel(id)
    }
}

extension SSHDFixture {
    func trustHostKeyInto(_ store: SSHHostKeyStore) async throws -> HostKeyInfo {
        let keys = try await SSHHostKeyStore.scan(host: "127.0.0.1", port: port)
        let key = try XCTUnwrap(keys.first)
        try store.trust(key, host: "127.0.0.1", port: port)
        return key
    }
}
