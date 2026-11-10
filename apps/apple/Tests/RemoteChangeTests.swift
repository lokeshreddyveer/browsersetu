import CryptoKit
import XCTest
@testable import Browser_Setu

/// Upload and delete (never sync): against the real OpenSSH server, the FTP server and the WebDAV server, and through the model's confirmations. Nothing is replaced, nothing outside what was chosen is touched,
/// a link is never followed out of a folder, and a private tab cannot change a server.
final class RemoteChangeTests: XCTestCase {
    final class Box: @unchecked Sendable { var all: [RemoteEntry] = []; let l = NSLock(); func add(_ e: [RemoteEntry]) { l.lock(); all += e; l.unlock() } }
    func names(_ s: RemoteSession, _ path: String) async throws -> [String] { let b = Box(); _ = try await s.list(path, limit: 1000) { b.add($0) }; return b.all.map(\.name).sorted() }
    func pattern(_ n: Int, _ k: Int = 13) -> Data { var d = Data(count: n); d.withUnsafeMutableBytes { for i in 0..<$0.count { $0[i] = UInt8(truncatingIfNeeded: i &* k &+ (i >> 6)) } }; return d }
    /// The folders `localFile` made, removed when the test ends (one test writes a 150 MB file: left behind, runs fill the disk).
    private var madeFolders: [URL] = []
    override func tearDown() { for f in madeFolders { try? FileManager.default.removeItem(at: f) }; madeFolders = []; super.tearDown() }
    func localFile(_ data: Data, name: String) throws -> URL { let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bs-up-\(UUID().uuidString.prefix(8))"); madeFolders.append(dir); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); let u = dir.appendingPathComponent(name); try data.write(to: u); return u }

    func testSFTPUploadNeverReplacesCleansUpWhenCancelledAndDeleteNeverFollowsALink() async throws {
        let sshd = try SSHDFixture(); defer { sshd.stop() }
        _ = try await sshd.trustHostKey()
        let s = SFTPSession(config: sshd.config(key: sshd.clientKey)); defer { s.close() }
        try await s.connect()
        let dest = sshd.tree.appendingPathComponent("incoming"); try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        // Upload: exact bytes, no hidden file left, progress reaches the full size.
        let data = pattern(3_000_017); let local = try localFile(data, name: "Ünï report.bin")
        let progressBox = Box2(); 
        try await s.upload(local, to: dest.appendingPathComponent("Ünï report.bin").path) { progressBox.set($0) }
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("Ünï report.bin")), data, "the server holds exactly the file"); XCTAssertEqual(progressBox.value, Int64(data.count))
        let afterNames = try await names(s, dest.path); XCTAssertEqual(afterNames, ["Ünï report.bin"], "no hidden working file is left")
        // The same name again: refused, and the existing file is kept as it was.
        let other = try localFile(Data("different".utf8), name: "Ünï report.bin")
        do { try await s.upload(other, to: dest.appendingPathComponent("Ünï report.bin").path) { _ in }; XCTFail("an existing file must not be replaced") } catch { XCTAssertEqual(error as? RemoteError, .alreadyExists) }
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("Ünï report.bin")), data); let keptNames = try await names(s, dest.path); XCTAssertEqual(keptNames, ["Ünï report.bin"])
        // Cancelled part-way: nothing is left under any name.
        let big = try localFile(pattern(150_000_000, 7), name: "huge.bin")
        let task = Task { try await s.upload(big, to: dest.appendingPathComponent("huge.bin").path) { _ in } }
        try await Task.sleep(nanoseconds: 150_000_000); task.cancel(); _ = await task.result
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let afterCancel = try await names(s, dest.path); XCTAssertEqual(afterCancel, ["Ünï report.bin"], "a cancelled upload leaves no file and no hidden file: \(afterCancel)")
        // Delete: a folder with files, a sub-folder and a LINK to a folder outside it. The plan counts them; the link is removed as a link; the outside folder is untouched.
        let outside = sshd.tree.appendingPathComponent("outside-keep"); try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("precious".utf8).write(to: outside.appendingPathComponent("important.txt"))
        let victim = sshd.tree.appendingPathComponent("victim"); try FileManager.default.createDirectory(at: victim.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: victim.appendingPathComponent("a.txt")); try Data("b".utf8).write(to: victim.appendingPathComponent("sub/b.txt"))
        try FileManager.default.createSymbolicLink(at: victim.appendingPathComponent("link-out"), withDestinationURL: outside)
        let top = Box(); _ = try await s.list(sshd.tree.path, limit: 100) { top.add($0) }
        let victimEntry = try XCTUnwrap(top.all.first { $0.name == "victim" })
        let plan = try await RemoteDeletePlanner.plan(session: s, roots: [victimEntry], base: sshd.tree.path)
        XCTAssertEqual(plan.files.map { ($0 as NSString).lastPathComponent }.sorted(), ["a.txt", "b.txt", "link-out"], "the link is an item to remove, not a folder to enter")
        XCTAssertEqual(plan.folders.map { ($0 as NSString).lastPathComponent }, ["sub", "victim"], "deepest first")
        for f in plan.files { try await s.remove(f, isDirectory: false) }
        for f in plan.folders { try await s.remove(f, isDirectory: true) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: victim.path), "the folder is gone")
        XCTAssertEqual(try String(contentsOf: outside.appendingPathComponent("important.txt")), "precious", "what the link pointed at is untouched")
        // Errors are said plainly.
        do { try await s.remove(sshd.tree.appendingPathComponent("not-there").path, isDirectory: false); XCTFail() } catch { XCTAssertEqual(error as? RemoteError, .notFound) }
        let locked = sshd.tree.appendingPathComponent("locked-dir"); try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true); try Data("x".utf8).write(to: locked.appendingPathComponent("f"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path); defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        do { try await s.remove(locked.appendingPathComponent("f").path, isDirectory: false); XCTFail("a folder this account cannot write to") } catch { XCTAssertEqual(error as? RemoteError, .permissionDenied) }
    }
    final class Box2: @unchecked Sendable { private let l = NSLock(); private var v: Int64 = 0; func set(_ x: Int64) { l.lock(); v = x; l.unlock() }; var value: Int64 { l.lock(); defer { l.unlock() }; return v } }

    func testFTPAndWebDAVUploadAndDeleteWithoutReplacingAndWithPlainErrors() async throws {
        // FTP
        let ftp = try FTPFixture(); defer { ftp.stop() }
        let f = FTPSession(config: ftp.config()); defer { f.close() }
        let data = pattern(2_000_003); let local = try localFile(data, name: "report.bin")
        try await f.upload(local, to: "/report.bin") { _ in }
        XCTAssertEqual(try Data(contentsOf: ftp.files.appendingPathComponent("report.bin")), data)
        let ftpNames = try await names(f, "/"); XCTAssertEqual(Set(ftpNames), ["report.bin", "sub"], "no hidden working file is left")
        do { try await f.upload(try localFile(Data("x".utf8), name: "report.bin"), to: "/report.bin") { _ in }; XCTFail() } catch { XCTAssertEqual(error as? RemoteError, .alreadyExists) }
        XCTAssertEqual(try Data(contentsOf: ftp.files.appendingPathComponent("report.bin")), data, "the existing file was kept")
        try await f.remove("/report.bin", isDirectory: false); XCTAssertFalse(FileManager.default.fileExists(atPath: ftp.files.appendingPathComponent("report.bin").path))
        try await f.remove("/sub", isDirectory: true); XCTAssertFalse(FileManager.default.fileExists(atPath: ftp.files.appendingPathComponent("sub").path))
        do { try await f.remove("/nothing.bin", isDirectory: false); XCTFail() } catch { XCTAssertNotNil((error as? RemoteError)?.errorDescription) }
        let ro = try FTPFixture(extra: ["--readonly"]); defer { ro.stop() }
        let r = FTPSession(config: ro.config()); defer { r.close() }
        do { try await r.upload(local, to: "/nope.bin") { _ in }; XCTFail("a read-only server") } catch { XCTAssertNotNil((error as? RemoteError)?.errorDescription, "\(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ro.files.appendingPathComponent("nope.bin").path))

        // WebDAV
        let dav = try WebDAVFixture(); defer { dav.stop() }
        let w = WebDAVSession(config: dav.config(), network: DownloadNetworkSetup())
        try await w.upload(local, to: "/up.bin") { _ in }
        XCTAssertEqual(try Data(contentsOf: dav.files.appendingPathComponent("up.bin")), data)
        do { try await w.upload(try localFile(Data("x".utf8), name: "up.bin"), to: "/up.bin") { _ in }; XCTFail() } catch { XCTAssertEqual(error as? RemoteError, .alreadyExists) }
        XCTAssertEqual(try Data(contentsOf: dav.files.appendingPathComponent("up.bin")), data, "If-None-Match: * kept the existing file")
        try FileManager.default.createDirectory(at: dav.files.appendingPathComponent("folder/inner"), withIntermediateDirectories: true); try Data("z".utf8).write(to: dav.files.appendingPathComponent("folder/inner/z.txt"))
        try await w.remove("/up.bin", isDirectory: false); try await w.remove("/folder", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dav.files.appendingPathComponent("up.bin").path)); XCTAssertFalse(FileManager.default.fileExists(atPath: dav.files.appendingPathComponent("folder").path))
        do { try await w.remove("/missing", isDirectory: false); XCTFail() } catch { XCTAssertEqual(error as? RemoteError, .notFound) }
    }

    @MainActor
    func testTheConfirmationsNameTheItemsAndServerDefaultToCancelAndAPrivateTabCannotChangeAnything() async throws {
        let sshd = try SSHDFixture(); defer { sshd.stop() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bs-chg-\(UUID().uuidString.prefix(8))"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let saved = DownloadCoordinator.directoryOverride; DownloadCoordinator.directoryOverride = folder; defer { DownloadCoordinator.directoryOverride = saved }
        let c = DownloadCoordinator(); c.profileName = "change-test-\(UUID().uuidString.prefix(6))"; c.store = folder.appendingPathComponent("store"); c.remoteSecretOverride = MemoryAccountSecretStore()
        _ = try await sshd.trustHostKeyInto(c.remotes.hostKeys)
        try Data("keep me".utf8).write(to: sshd.tree.appendingPathComponent("keep.txt")); try Data("remove me".utf8).write(to: sshd.tree.appendingPathComponent("remove.txt"))
        var conn = RemoteConnection(name: "Build server", scheme: .sftp, host: "127.0.0.1", port: sshd.port, user: NSUserName(), auth: .key, keyPath: sshd.clientKey.path); conn.path = sshd.tree.path
        XCTAssertTrue(c.remotes.save(conn, secret: nil))
        let model = RemoteBrowserModel(coordinator: c); model.remember = false
        model.use(conn)
        let end = Date().addingTimeInterval(30); while Date() < end, model.entries.isEmpty || model.phase != .browsing { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(model.phase, .browsing)

        var asked: [(String, String, [String])] = []
        var answer = 0
        Dialogs.testHandler = { t, m, b in asked.append((t, m, b)); return answer }; defer { Dialogs.testHandler = nil }
        // Delete: Cancel (the default) does nothing; the question names the item, the server and the folder.
        model.selection = ["remove.txt"]; model.requestDelete()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let q = try XCTUnwrap(asked.last)
        XCTAssertEqual(q.2, ["Cancel", "Delete"], "the first button, the default, is Cancel"); XCTAssertTrue(q.1.contains("remove.txt") && q.1.contains("Build server") && q.1.contains("127.0.0.1") && q.1.contains(sshd.tree.path) && q.1.contains("cannot be undone"), q.1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sshd.tree.appendingPathComponent("remove.txt").path), "Cancel deleted nothing"); XCTAssertEqual(model.message, "Nothing was deleted.")
        answer = 1; model.selection = ["remove.txt"]; model.requestDelete()
        let end2 = Date().addingTimeInterval(20); while Date() < end2, FileManager.default.fileExists(atPath: sshd.tree.appendingPathComponent("remove.txt").path) { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sshd.tree.appendingPathComponent("remove.txt").path), "Delete removed exactly the chosen file"); XCTAssertTrue(FileManager.default.fileExists(atPath: sshd.tree.appendingPathComponent("keep.txt").path), "and nothing else")

        // Upload: Cancel does nothing; Upload sends; a file already there is kept and said so.
        let up = try localFile(Data("uploaded".utf8), name: "new.txt"), dup = try localFile(Data("replacement".utf8), name: "keep.txt")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        answer = 0; model.requestUpload([up]); try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(asked.last?.2, ["Cancel", "Upload"]); XCTAssertTrue(asked.last?.1.contains("new.txt") == true && asked.last?.1.contains("Build server") == true && asked.last?.1.contains("not replaced") == true, asked.last?.1 ?? "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sshd.tree.appendingPathComponent("new.txt").path), "Cancel uploaded nothing")
        answer = 1; model.requestUpload([up, dup])
        let end3 = Date().addingTimeInterval(20); while Date() < end3, !FileManager.default.fileExists(atPath: sshd.tree.appendingPathComponent("new.txt").path) { try await Task.sleep(nanoseconds: 100_000_000) }
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(try String(contentsOf: sshd.tree.appendingPathComponent("new.txt")), "uploaded"); XCTAssertEqual(try String(contentsOf: sshd.tree.appendingPathComponent("keep.txt")), "keep me", "the file that was already there was not replaced")
        XCTAssertTrue(model.message?.contains("already there") == true, model.message ?? "")

        // A private tab cannot change a server at all: no question is even asked.
        let before = asked.count
        model.isPrivate = true
        XCTAssertFalse(model.canChange); model.selection = ["keep.txt"]; model.requestDelete(); model.requestUpload([up])
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(asked.count, before, "a private tab never asks, never deletes, never uploads"); XCTAssertTrue(FileManager.default.fileExists(atPath: sshd.tree.appendingPathComponent("keep.txt").path))
    }
}
