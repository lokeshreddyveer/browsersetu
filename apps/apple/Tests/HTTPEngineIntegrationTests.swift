import CryptoKit
import XCTest
@testable import Browser_Setu

/// The HTTP engine, run for real: through the coordinator and the ledger, against a local fixture server (scripts/download_fixture_server.py).
@MainActor
final class HTTPEngineIntegrationTests: XCTestCase {
    /// The fixture server is started by the Mac scheme before the tests (see project.yml), outside the test host's sandbox.
    private static let port = 18766

    // MARK: Fixtures

    private var root: URL!
    private var folder: URL!
    private var downloads: URL!
    private var savedOverride: URL?
    private var savedScale = 1.0
    private var c: DownloadCoordinator!

    override func setUp() async throws {
        try await super.setUp()
        let reachable = (try? await URLSession(configuration: .ephemeral).data(from: URL(string: "http://127.0.0.1:\(Self.port)/")!)) != nil
        XCTAssertTrue(reachable, "the download fixture server is not running on port \(Self.port): run these tests through the BrowserSetuMac scheme, which starts it")
        guard reachable else { throw XCTSkip("fixture server not running") }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("http-int-\(UUID().uuidString)")
        folder = root.appendingPathComponent("store")
        downloads = root.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        savedOverride = DownloadCoordinator.directoryOverride
        DownloadCoordinator.directoryOverride = downloads
        savedScale = HTTPRetrySchedule.delayScale
        HTTPRetrySchedule.delayScale = 0.02
        c = coordinator()
        _ = try? await fetch("/_reset")
    }

    override func tearDown() async throws {
        for (id, record) in c.ledger.records where !record.state.isFinal && record.state != .failed { c.cancel(id) }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: downloads.path)
        DownloadTaskStore.close(folder: folder)
        try? FileManager.default.removeItem(at: root)
        DownloadCoordinator.directoryOverride = savedOverride
        HTTPRetrySchedule.delayScale = savedScale
        try await super.tearDown()
    }

    private func coordinator(profile: String = "default") -> DownloadCoordinator {
        let coordinator = DownloadCoordinator()
        coordinator.profileName = profile
        coordinator.store = folder
        coordinator.hasHost = { true }
        return coordinator
    }

    private func url(_ path: String, host: String = "127.0.0.1") -> URL { URL(string: "http://\(host):\(Self.port)\(path)")! }

    private func expected(_ size: Int) -> Data { Data((0..<size).map { UInt8(truncatingIfNeeded: ($0 * 31 + 7) % 251) }) }

    private func fetch(_ path: String) async throws -> Data { try await URLSession(configuration: .ephemeral).data(from: url(path)).0 }

    private struct LogEntry: Decodable { var method: String; var path: String; var headers: [String: String]; var host: String }
    /// What the server was asked for, not counting the test's own questions to it (paths that start with "/_").
    private func log() async -> [LogEntry] {
        let all = ((try? await fetch("/_log")).flatMap { try? JSONDecoder().decode([LogEntry].self, from: $0) }) ?? []
        return all.filter { !$0.path.hasPrefix("/_") }
    }

    @discardableResult
    private func wait(_ id: UUID, for states: Set<DownloadState>, seconds: Double = 25) async -> DownloadTaskRecord? {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let record = c.ledger.record(id), states.contains(record.state) { return record }
            try? await Task.sleep(for: .milliseconds(40))
        }
        return c.ledger.record(id)
    }

    private func waitForBytes(_ id: UUID, atLeast bytes: Int64, seconds: Double = 15) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, (c.active[id]?.completedBytes ?? 0) < bytes { try? await Task.sleep(for: .milliseconds(30)) }
    }

    private func contents(of record: DownloadTaskRecord?) -> Data? { record?.file.destinationPath.flatMap { FileManager.default.contents(atPath: $0) } }

    // MARK: Ordinary downloads

    func testAnOrdinaryDownloadCompletesWithTheRightBytesAndTheTaskKeepsItsIdentity() async throws {
        let id = try await c.http.start(url: url("/file/5000"))
        let record = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(record?.state, .completed)
        XCTAssertEqual(record?.id, id)
        XCTAssertEqual(record?.protocolID, .http)
        XCTAssertEqual(contents(of: record), expected(5000))
        XCTAssertEqual(record?.file.integrity, .verified, "the size matched what the server promised")
        XCTAssertEqual(c.completed.count, 1)
        XCTAssertEqual(record?.attempt, 1)
        XCTAssertEqual(c.http.engine.activeCount, 0, "the engine let go of it")
    }

    func testTheFinishedFileIsMarkedAsDownloadedFromTheInternet() async throws {
        let id = try await c.http.start(url: url("/file/100"))
        let record = await wait(id, for: [.completed])
        let path = try XCTUnwrap(record?.file.destinationPath)
        XCTAssertGreaterThan(getxattr(path, "com.apple.quarantine", nil, 0, 0, 0), 0, "Gatekeeper treats it like any browser download")
    }

    func testALargeFileIsWrittenToDiskAndArrivesIntact() async throws {
        let size = 24_000_000
        let id = try await c.http.start(url: url("/file/\(size)"))
        let record = await wait(id, for: [.completed, .failed], seconds: 60)
        XCTAssertEqual(record?.state, .completed)
        let path = try XCTUnwrap(record?.file.destinationPath)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue, size)
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        XCTAssertEqual(data.prefix(1000), expected(1000))
        XCTAssertEqual(data.suffix(1000), Data(expected(size).suffix(1000)))
        XCTAssertEqual(record?.transfer.completedBytes, Int64(size))
    }

    func testAnUnknownLengthChunkedBodyCompletesWithoutAnInventedTotal() async throws {
        let id = try await c.http.start(url: url("/nolength/70000"))
        let record = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(record?.state, .completed)
        XCTAssertEqual(contents(of: record), expected(70000))
        XCTAssertEqual(record?.file.integrity, .unknown, "nothing to compare it against")
    }

    func testTheServersOwnContentTypeAndTheFinalAddressAreReported() async throws {
        let page = try await c.http.engine.resolve(DownloadSourceRequest(url: url("/htmlpage"), profile: "default", isPrivate: false))
        XCTAssertEqual(page.contentType, "text/html")
        XCTAssertEqual(AddressClassifier.classify(url("/htmlpage"), contentType: page.contentType, finalURL: page.finalURL), .webPage, "a real web page is the person's choice")
        let video = try await c.http.engine.resolve(DownloadSourceRequest(url: url("/file/100?ctype=video/mp4"), profile: "default", isPrivate: false))
        XCTAssertEqual(video.contentType, "video/mp4")
        XCTAssertEqual(AddressClassifier.classify(url("/file/100?ctype=video/mp4"), contentType: video.contentType, finalURL: video.finalURL), .file)
        let hopped = try await c.http.engine.resolve(DownloadSourceRequest(url: url("/redirect/2/100"), profile: "default", isPrivate: false))
        XCTAssertEqual(hopped.finalURL?.path, "/file/100", "the address after redirects is known")
    }

    func testAServerThatRefusesHeadIsAskedAnotherWay() async throws {
        let resolved = try await c.http.engine.resolve(DownloadSourceRequest(url: url("/nohead/4321"), profile: "default", isPrivate: false))
        XCTAssertEqual(resolved.totalBytes, 4321)
        XCTAssertTrue(resolved.acceptsRanges)
        let entries = await log().filter { $0.path == "/nohead/4321" }
        XCTAssertEqual(entries.map(\.method), ["HEAD", "GET"])
        XCTAssertEqual(entries.last?.headers["range"], "bytes=0-0", "the fallback asks for one byte, not the whole file")
        let id = try await c.http.start(url: url("/nohead/4321"))
        let record = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(contents(of: record), expected(4321))
    }

    func testNoCookiesAndNoBrowserLoginsAreSent() async throws {
        let cookie = HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "session", .value: "browser-login", .secure: "FALSE"])!
        HTTPCookieStorage.shared.setCookie(cookie)
        defer { HTTPCookieStorage.shared.deleteCookie(cookie) }
        let id = try await c.http.start(url: url("/file/200"))
        await wait(id, for: [.completed])
        let entries = await log().filter { $0.path == "/file/200" }
        XCTAssertFalse(entries.isEmpty)
        for entry in entries { XCTAssertNil(entry.headers["cookie"], "\(entry.method) carried a cookie") }
        XCTAssertEqual(entries.last?.headers["accept-encoding"], "identity", "exact bytes: a compressed body has no usable length")
    }

    // MARK: Redirects

    func testRedirectChainsAreFollowed() async throws {
        let id = try await c.http.start(url: url("/redirect/3/2000"))
        let record = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(record?.state, .completed)
        XCTAssertEqual(contents(of: record), expected(2000))
    }

    func testARedirectLoopAndAnEndlessChainAreStopped() async throws {
        let loop = try await c.http.start(url: url("/redirect-loop"))
        let looped = await wait(loop, for: [.failed, .completed])
        XCTAssertEqual(looped?.state, .failed)
        XCTAssertTrue(looped?.failure?.reason.contains("redirects back") == true, looped?.failure?.reason ?? "")
        let long = try await c.http.start(url: url("/redirect/14/100"))
        let tooLong = await wait(long, for: [.failed, .completed])
        XCTAssertEqual(tooLong?.state, .failed)
        XCTAssertTrue(tooLong?.failure?.reason.contains("too many") == true, tooLong?.failure?.reason ?? "")
        XCTAssertEqual(looped?.retryCount, 0, "a redirect problem is not retried")
    }

    func testCredentialsAreNotForwardedToAnotherOrigin() async throws {
        let target = url("/file/100", host: "localhost").absoluteString
        let escaped = target.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        var options = HTTPDownloadRunner.Options()
        options.headers = ["Authorization": "Bearer SECRET-TOKEN", "Accept": "*/*"]
        let id = try await c.http.start(url: url("/redirect-to?url=\(escaped)"), options: options)
        let record = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(record?.state, .completed)
        let entries = await log()
        let first = entries.first { $0.path.hasPrefix("/redirect-to") && $0.headers["authorization"] != nil }
        XCTAssertNotNil(first, "the origin it was meant for did get it")
        let elsewhere = entries.filter { $0.host.hasPrefix("localhost") }
        XCTAssertFalse(elsewhere.isEmpty)
        for entry in elsewhere { XCTAssertNil(entry.headers["authorization"], "\(entry.path) on another origin must not receive the credential") }
    }

    func testAScriptCannotReachThePrivateNetworkOrAttachCredentials() async {
        // With scripts' requests switched on (they are off by default, see Phase4PolicyTests), the address rules behind that switch still hold.
        let saved = HTTPRequestPolicy.untrustedRequestsEnabled
        HTTPRequestPolicy.untrustedRequestsEnabled = true
        defer { HTTPRequestPolicy.untrustedRequestsEnabled = saved }
        var options = HTTPDownloadRunner.Options()
        options.origin = .automation
        options.headers = ["Authorization": "Bearer x"]
        do { _ = try await c.http.start(url: url("/file/10"), options: options); XCTFail("an automation request to loopback must be refused") }
        catch { XCTAssertEqual(error as? HTTPRequestPolicy.Refusal, .internalAddress("127.0.0.1")) }
        XCTAssertTrue(c.ledger.records.isEmpty, "nothing was created for a refused request")
        let sent = await log()
        XCTAssertTrue(sent.isEmpty, "and nothing was sent")
    }

    // MARK: Names

    func testNamesComeFromTheServerSafely() async throws {
        let euro = "attachment; filename*=UTF-8''%E2%82%AC%20rates.txt".addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let first = try await c.http.start(url: url("/file/300?cd=\(euro)"))
        let a = await wait(first, for: [.completed])
        XCTAssertEqual(a?.file.filename, "€ rates.txt")
        let hostile = "attachment; filename=\"../../etc/passwd\"".addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let second = try await c.http.start(url: url("/file/301?cd=\(hostile)"))
        let b = await wait(second, for: [.completed])
        XCTAssertEqual(b?.file.filename, "passwd")
        let path = try XCTUnwrap(b?.file.destinationPath)
        XCTAssertTrue(DownloadPathPolicy.isAuthorized(path, roots: [downloads]), "it stayed inside the downloads folder: \(path)")
        let garbage = "attachment; filename=\"".addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let third = try await c.http.start(url: url("/file/302?cd=\(garbage)"))
        let d = await wait(third, for: [.completed])
        XCTAssertEqual(d?.file.filename, "302", "an unusable header falls back to the address")
    }

    func testTwoDownloadsWithTheSameNameNeverOverwriteEachOther() async throws {
        let cd = "attachment; filename=\"same.bin\"".addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let first = try await c.http.start(url: url("/file/400?cd=\(cd)"))
        let a = await wait(first, for: [.completed])
        let second = try await c.http.start(url: url("/file/401?cd=\(cd)"))
        let b = await wait(second, for: [.completed])
        XCTAssertNotEqual(a?.file.destinationPath, b?.file.destinationPath)
        XCTAssertEqual(contents(of: a), expected(400))
        XCTAssertEqual(contents(of: b), expected(401))
    }

    // MARK: Failures and retries

    func testAConnectionThatDropsMidFileIsResumedAsTheSameTask() async throws {
        let id = try await c.http.start(url: url("/flaky/300000?cut=60000"))
        let record = await wait(id, for: [.completed, .failed], seconds: 40)
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? "")
        XCTAssertEqual(record?.id, id, "retries never make a new task")
        XCTAssertGreaterThanOrEqual(record?.retryCount ?? 0, 1)
        XCTAssertEqual(contents(of: record), expected(300000), "joined correctly, not corrupted")
        XCTAssertEqual(c.ledger.records.values.filter { $0.protocolID == .http }.count, 1)
    }

    func testAFileThatEndsEarlyIsNotAccepted() async throws {
        let id = try await c.http.start(url: url("/wrongsize/50000"))
        let record = await wait(id, for: [.completed, .failed], seconds: 40)
        XCTAssertEqual(record?.state, .failed, "a file shorter than promised is never reported complete")
        XCTAssertNil(contents(of: record).flatMap { $0.isEmpty ? nil : $0 }, "and no short file is left in the downloads folder")
    }

    func testPermanentFailuresAreNotRetried() async throws {
        for status in [401, 403, 404] {
            let id = try await c.http.start(url: url("/status/\(status)"))
            let record = await wait(id, for: [.failed, .completed])
            XCTAssertEqual(record?.state, .failed, "\(status)")
            XCTAssertEqual(record?.failure?.code, "http:\(status)")
            XCTAssertEqual(record?.retryCount, 0, "\(status) must not be retried")
            XCTAssertEqual(c.failures.first { $0.id == id }?.reason, record?.failure?.reason, "the person is told why")
        }
    }

    func testServerErrorsAreRetriedAFewTimesThenStop() async throws {
        let id = try await c.http.start(url: url("/status/503?ra=0"))
        let record = await wait(id, for: [.failed, .completed], seconds: 30)
        XCTAssertEqual(record?.state, .failed)
        XCTAssertEqual(record?.retryCount, HTTPRetrySchedule.maxAttempts - 1, "bounded")
        XCTAssertEqual(record?.id, id)
        XCTAssertEqual(c.http.pendingRetries, 0, "no timer is left running")
        let hits = await log().filter { $0.method == "GET" && $0.path.hasPrefix("/status/503") }.count
        XCTAssertGreaterThanOrEqual(hits, HTTPRetrySchedule.maxAttempts)
    }

    func testATransferThatStopsAnsweringTimesOutAndIsRetriedAFewTimes() async throws {
        var options = HTTPDownloadRunner.Options()
        options.timeout = 1
        let id = try await c.http.start(url: url("/hang"), options: options)
        let record = await wait(id, for: [.failed, .completed], seconds: 40)
        XCTAssertEqual(record?.state, .failed)
        XCTAssertTrue(record?.failure?.reason.contains("too long") == true, record?.failure?.reason ?? "")
        XCTAssertGreaterThanOrEqual(record?.retryCount ?? 0, 1)
    }

    func testSigningTokensNeverReachDiagnosticsOrMessages() async throws {
        let id = try await c.http.start(url: url("/status/404?token=SECRETTOKEN&X-Amz-Signature=SIGVALUE"))
        let record = await wait(id, for: [.failed])
        XCTAssertEqual(record?.state, .failed)
        let everything = ([c.diagnostics] + c.events + c.failures.map(\.reason) + [record?.failure?.reason ?? ""]).joined(separator: "\n")
        XCTAssertFalse(everything.contains("SECRETTOKEN")); XCTAssertFalse(everything.contains("SIGVALUE"))
    }

    // MARK: Pause, resume, cancel

    func testAResumableDownloadCanBePausedAndResumedAsTheSameTask() async throws {
        let size = 3_000_000
        let id = try await c.http.start(url: url("/slow/\(size)?ms=15"))
        await waitForBytes(id, atLeast: 200_000)
        XCTAssertTrue(c.canPause(id))
        c.pause(id)
        let paused = await wait(id, for: [.paused, .completed, .failed])
        XCTAssertEqual(paused?.state, .paused)
        XCTAssertNotNil(c.interrupted[id], "kept in the list with its resume button")
        c.resume(id)
        let done = await wait(id, for: [.completed, .failed], seconds: 40)
        XCTAssertEqual(done?.state, .completed, done?.failure?.reason ?? "")
        XCTAssertEqual(done?.id, id)
        XCTAssertGreaterThanOrEqual(done?.attempt ?? 0, 2)
        XCTAssertEqual(contents(of: done), expected(size), "the two parts joined correctly")
    }

    func testADownloadThatCannotBeResumedIsNotOfferedAPause() async throws {
        let id = try await c.http.start(url: url("/slownores/3000000?ms=15"))
        await waitForBytes(id, atLeast: 100_000)
        XCTAssertEqual(c.http.engine.isResumable(task: id), false)
        XCTAssertFalse(c.canPause(id), "the server gave no way to continue it, so no pause control is shown")
        c.cancel(id)
    }

    func testAFileThatChangedOnTheServerRestartsInsteadOfBeingCorrupted() async throws {
        let size = 2_000_000
        let id = try await c.http.start(url: url("/slow/\(size)?ms=15"))
        await waitForBytes(id, atLeast: 150_000)
        c.pause(id)
        await wait(id, for: [.paused])
        _ = try await fetch("/_bump")                       // the file is now a different version
        c.resume(id)
        let done = await wait(id, for: [.completed, .failed], seconds: 40)
        XCTAssertEqual(done?.state, .completed, done?.failure?.reason ?? "")
        XCTAssertEqual(contents(of: done), expected(size), "never the old part joined to the new file")
    }

    func testResumeDataThatIsNotUsableDoesNotHangOrCorrupt() async throws {
        let id = UUID()
        c.ledger.create(id: id, protocolID: .http, source: url("/file/20000"), filename: "bad-resume.bin", isPrivate: false)
        c.ledger.apply(.queued, to: id); c.ledger.apply(.started, to: id); c.ledger.apply(.running, to: id)
        let destination = downloads.appendingPathComponent("bad-resume.bin")
        c.ledger.update(id) { $0.file.destinationPath = destination.path; $0.transfer.totalBytes = 20000 }
        c.ledger.apply(.paused(resumeAvailable: true), to: id, resumeData: .some(Data("this is not resume data".utf8)))
        c.engines.register(c.http.engine)
        c.http.engine.prepare(HTTPTransferRequest(url: url("/file/20000"), policy: HTTPRequestPolicy(origin: .user), headers: [:], destination: destination, expectedSHA256: nil), for: id)
        c.ledger.flush()
        let again = coordinator()                                   // as after a relaunch
        XCTAssertNotNil(again.interrupted[id])
        c = again
        c.hasHost = { true }
        c.resume(id)
        let done = await wait(id, for: [.completed, .failed], seconds: 30)
        XCTAssertTrue([.completed, .failed].contains(done?.state), "it ended one way or the other: \(String(describing: done?.state))")
        if done?.state == .completed { XCTAssertEqual(contents(of: done), expected(20000)) }
    }

    func testCancellingMidTransferLeavesNothingBehindAndIsNotAFailure() async throws {
        let id = try await c.http.start(url: url("/slow/5000000?ms=20"))
        await waitForBytes(id, atLeast: 100_000)
        c.cancel(id)
        XCTAssertEqual(c.ledger.record(id)?.state, .cancelled)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(c.ledger.record(id)?.state, .cancelled, "late reports from the stopped transfer change nothing")
        XCTAssertTrue(c.failures.isEmpty, "cancelling is not a failure")
        XCTAssertEqual(c.http.engine.activeCount, 0)
        XCTAssertTrue(c.completed.isEmpty)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: downloads.path)) ?? []
        XCTAssertTrue(left.isEmpty, "no partial or final file: \(left)")
    }

    func testCancellingAfterCompletionChangesNothing() async throws {
        let id = try await c.http.start(url: url("/file/300"))
        let done = await wait(id, for: [.completed])
        c.cancel(id)
        XCTAssertEqual(c.ledger.record(id)?.state, .completed)
        XCTAssertNotNil(contents(of: done), "the finished file is not touched")
    }

    // MARK: Files

    func testADestinationThatCannotBeWrittenFailsClearlyAndKeepsExistingFiles() async throws {
        let existing = downloads.appendingPathComponent("keep-me.txt")
        try Data("mine".utf8).write(to: existing)
        let id = try await c.http.start(url: url("/slow/2000000?ms=15"))
        await waitForBytes(id, atLeast: 100_000)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: downloads.path)       // no longer writable
        let record = await wait(id, for: [.failed, .completed], seconds: 40)
        XCTAssertEqual(record?.state, .failed)
        XCTAssertTrue(record?.failure?.reason.contains("not allowed") == true || record?.failure?.reason.contains("could not save") == true, record?.failure?.reason ?? "")
        XCTAssertEqual(record?.retryCount, 0, "a permission problem is not retried")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: downloads.path)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "mine", "an existing file is never touched")
    }

    func testFinalisingNeverOverwritesAndRepeatingItIsSafe() throws {
        let location = root.appendingPathComponent("incoming-1")
        try Data("new".utf8).write(to: location)
        let destination = downloads.appendingPathComponent("file.txt")
        try Data("old".utf8).write(to: destination)
        let id = UUID()
        let result = try HTTPTransferEngine.finalise(from: location, to: destination, taskID: id, sourceOrigin: "http://x")
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "old", "the file that was there is untouched")
        XCTAssertEqual(try String(contentsOf: result, encoding: .utf8), "new")
        XCTAssertNotEqual(result, destination)
        // The same task's leftover temporary file does not get in the way of a repeat.
        let again = root.appendingPathComponent("incoming-2")
        try Data("third".utf8).write(to: again)
        try Data("stale".utf8).write(to: HTTPTransferEngine.partialURL(for: id, in: downloads))
        let second = try HTTPTransferEngine.finalise(from: again, to: destination, taskID: id, sourceOrigin: "http://x")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "third")
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "old")
    }

    func testFinalisingIntoAPathThatIsAFileFailsInsteadOfDamagingAnything() throws {
        let blocker = root.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        let location = root.appendingPathComponent("incoming-3")
        try Data("data".utf8).write(to: location)
        XCTAssertThrowsError(try HTTPTransferEngine.finalise(from: location, to: blocker.appendingPathComponent("sub/file.txt"), taskID: UUID(), sourceOrigin: "http://x"))
        XCTAssertEqual(try String(contentsOf: blocker, encoding: .utf8), "x")
    }

    func testAChecksumFromATrustedSourceIsCheckedAndAWrongFileIsRemoved() async throws {
        let size = 4096
        let good = SHA256.hash(data: expected(size)).map { String(format: "%02x", $0) }.joined()
        var options = HTTPDownloadRunner.Options()
        options.expectedSHA256 = good
        let ok = try await c.http.start(url: url("/file/\(size)"), options: options)
        let verified = await wait(ok, for: [.completed, .failed])
        XCTAssertEqual(verified?.state, .completed)
        XCTAssertEqual(verified?.file.integrity, .verified)
        options.expectedSHA256 = String(repeating: "0", count: 64)
        let bad = try await c.http.start(url: url("/file/\(size)?x=2"), options: options)
        let rejected = await wait(bad, for: [.failed, .completed])
        XCTAssertEqual(rejected?.state, .failed)
        XCTAssertTrue(rejected?.failure?.reason.contains("checksum") == true)
        XCTAssertNil(contents(of: rejected), "a file that is not the one promised is not kept")
    }

    // MARK: Restart, concurrency, isolation

    func testAnInterruptedTransferIsFoundAfterARestartAndNeverStartsItself() async throws {
        let id = try await c.http.start(url: url("/slow/5000000?ms=30"))
        await waitForBytes(id, atLeast: 100_000)
        c.ledger.flush()
        await c.http.engine.cancel(task: id, attempt: -1)            // the app is gone: nothing is handed back
        let reopened = coordinator()
        XCTAssertEqual(reopened.ledger.record(id)?.state, .recoveryRequired)
        XCTAssertTrue(reopened.failures.contains { $0.id == id }, "listed, with its reason, and a way to try again")
        let before = await log().count
        try await Task.sleep(for: .milliseconds(500))
        let after = await log().count
        XCTAssertEqual(before, after, "nothing was started by itself")
    }

    func testADownloadFoundCompleteAfterACrashIsFinishedNotFetchedAgain() async throws {
        let destination = downloads.appendingPathComponent("already-here.bin")
        try expected(7000).write(to: destination)
        let store = DownloadTaskStore.open(folder: folder)
        var record = DownloadTaskRecord(protocolID: .http, profile: "default", source: DownloadSourceRef(url: url("/file/7000")), filename: "already-here.bin")
        record.state = .verifying
        record.transfer.totalBytes = 7000
        record.file.destinationPath = destination.path
        store.save(record); store.flush()
        let reopened = coordinator()
        XCTAssertEqual(reopened.ledger.record(record.id)?.state, .completed, "the file was in place and the right size: finishing it is all that was left")
        XCTAssertEqual(reopened.ledger.record(record.id)?.file.integrity, .verified)
        let requests = await log()
        XCTAssertTrue(requests.isEmpty, "nothing was downloaded again")
    }

    func testManyDownloadsAtOnceRespectTheLimitAndAllFinish() async throws {
        c.maxConcurrent = 3
        var peak = 0
        let sampler = Task { @MainActor in
            while !Task.isCancelled { peak = max(peak, c.active.count); try? await Task.sleep(for: .milliseconds(10)) }
        }
        var ids: [UUID] = []
        try await withThrowingTaskGroup(of: UUID.self) { group in
            for i in 0..<8 { group.addTask { try await self.c.http.start(url: self.url("/slow/\(300_000 + i)?ms=4")) } }
            for try await id in group { ids.append(id) }
        }
        for id in ids { await wait(id, for: [.completed, .failed], seconds: 60) }
        sampler.cancel()
        XCTAssertEqual(Set(ids).count, 8)
        for (index, id) in ids.enumerated() { XCTAssertEqual(c.ledger.record(id)?.state, .completed, "\(index)") }
        XCTAssertLessThanOrEqual(peak, 3, "no more than the limit ran at once")
        let names = Set(ids.compactMap { c.ledger.record($0)?.file.destinationPath })
        XCTAssertEqual(names.count, 8, "each has its own file")
    }

    func testAnotherProfileNeverSeesOrTouchesTheseDownloads() async throws {
        let id = try await c.http.start(url: url("/file/500"))
        await wait(id, for: [.completed])
        c.ledger.flush()
        let other = coordinator(profile: "work")
        XCTAssertNil(other.ledger.record(id))
        XCTAssertTrue(other.ledger.records.isEmpty)
        other.cancel(id)
        XCTAssertEqual(c.ledger.record(id)?.state, .completed)
    }

    // MARK: Found in review

    func testResolvingNeverReadsTheWholeBodyOfAServerThatIgnoresTheRange() async throws {
        // 20 MB sent slowly (about 12 seconds to send in full): the answer must come from the headers alone.
        let started = Date()
        let resolved = try await c.http.engine.resolve(DownloadSourceRequest(url: url("/nohead-norange/20000000"), profile: "default", isPrivate: false))
        XCTAssertLessThan(Date().timeIntervalSince(started), 4, "it did not wait for the body")
        XCTAssertEqual(resolved.totalBytes, 20_000_000)
    }

    func testASecondPauseWorksAfterAResume() async throws {
        let id = try await c.http.start(url: url("/slow/4000000?ms=15"))
        await waitForBytes(id, atLeast: 150_000)
        c.pause(id)
        await wait(id, for: [.paused])
        c.resume(id)
        await waitForBytes(id, atLeast: (c.active[id]?.completedBytes ?? 0) + 150_000)
        XCTAssertTrue(c.canPause(id), "still pausable after being resumed")
        c.pause(id)
        let again = await wait(id, for: [.paused, .completed, .failed])
        XCTAssertEqual(again?.state, .paused)
        c.resume(id)
        let done = await wait(id, for: [.completed, .failed], seconds: 40)
        XCTAssertEqual(done?.state, .completed, done?.failure?.reason ?? "")
        XCTAssertEqual(contents(of: done), expected(4_000_000))
    }

    func testAHeldDownloadIsStartedAgainByTheHTTPEngineAsTheSameTask() async throws {
        c.holdQueue(until: .distantFuture)
        let id = try await c.http.start(url: url("/file/3000"))
        XCTAssertEqual(c.ledger.record(id)?.state, .scheduled)
        XCTAssertEqual(c.ledger.record(id)?.protocolID, .http, "recorded as the engine that will start it")
        c.ledger.flush()
        let reopened = coordinator()
        c = reopened
        c.holdQueue(until: nil)
        c.startScheduledNow()
        let done = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(done?.state, .completed, done?.failure?.reason ?? "")
        XCTAssertEqual(done?.id, id)
        XCTAssertEqual(c.ledger.records.values.filter { $0.protocolID == .http && $0.state == .queued }.count, 0, "no orphaned record was left behind")
        XCTAssertEqual(contents(of: done), expected(3000))
    }

    func testWhoAskedSurvivesARestartAndAMissingRecordIsTheLeastTrusted() async throws {
        // The address rules behind the switch for scripts' requests are what is checked here, so the switch is on (and put back).
        let savedUntrusted = HTTPRequestPolicy.untrustedRequestsEnabled
        HTTPRequestPolicy.untrustedRequestsEnabled = true
        defer { HTTPRequestPolicy.untrustedRequestsEnabled = savedUntrusted }
        let store = DownloadTaskStore.open(folder: folder)
        func scheduled(_ origin: String?) -> DownloadTaskRecord {
            var r = DownloadTaskRecord(protocolID: .http, profile: "default", source: DownloadSourceRef(url: url("/file/900")), filename: "o.bin")
            r.state = .scheduled
            if let origin { r.engineMetadata["origin"] = origin }
            r.file.destinationPath = downloads.appendingPathComponent("o-\(origin ?? "none").bin").path
            return r
        }
        let user = scheduled("user"), unknown = scheduled(nil), script = scheduled("automation")
        for r in [user, unknown, script] { store.save(r) }
        store.flush()
        let reopened = coordinator()
        c = reopened
        c.holdQueue(until: nil)
        c.startScheduledNow()
        let a = await wait(user.id, for: [.completed, .failed])
        let b = await wait(unknown.id, for: [.completed, .failed])
        let d = await wait(script.id, for: [.completed, .failed])
        XCTAssertEqual(a?.state, .completed, "the person's own request may reach their network")
        XCTAssertEqual(b?.state, .failed, "no record of who asked: treated as a script, which may not")
        XCTAssertEqual(d?.state, .failed)
        XCTAssertTrue(b?.failure?.reason.contains("private network") == true, b?.failure?.reason ?? "")
    }
}
