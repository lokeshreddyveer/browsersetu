import XCTest
@testable import Browser_Setu

/// Multipart downloads, run for real against the local fixture server (started by the Mac scheme on port 18766).
@MainActor
final class MultipartIntegrationTests: XCTestCase {
    private static let port = 18766

    private var root: URL!
    private var folder: URL!
    private var downloads: URL!
    private var savedOverride: URL?
    private var savedScale = 1.0
    private var c: DownloadCoordinator!
    private let mib = 1 << 20

    override func setUp() async throws {
        try await super.setUp()
        let reachable = (try? await URLSession(configuration: .ephemeral).data(from: URL(string: "http://127.0.0.1:\(Self.port)/")!)) != nil
        XCTAssertTrue(reachable, "the download fixture server is not running on port \(Self.port): run these tests through the BrowserSetuMac scheme, which starts it")
        guard reachable else { throw XCTSkip("fixture server not running") }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("multi-\(UUID().uuidString)")
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
        if let c { for (id, record) in c.ledger.records where !record.state.isFinal && record.state != .failed { c.cancel(id) } }
        try? await Task.sleep(for: .milliseconds(200))
        if let folder { DownloadTaskStore.close(folder: folder) }
        if let root { try? FileManager.default.removeItem(at: root) }
        DownloadCoordinator.directoryOverride = savedOverride
        HTTPRetrySchedule.delayScale = savedScale
        try await super.tearDown()
    }

    // MARK: Helpers

    private func coordinator(profile: String = "default") -> DownloadCoordinator {
        let coordinator = DownloadCoordinator()
        coordinator.profileName = profile
        coordinator.store = folder
        coordinator.hasHost = { true }
        return coordinator
    }

    private func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(Self.port)\(path)")! }

    private func expected(_ size: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: size)
        for i in 0..<size { bytes[i] = UInt8(truncatingIfNeeded: (i * 31 + 7) % 251) }
        return Data(bytes)
    }

    private func fetch(_ path: String) async throws -> Data { try await URLSession(configuration: .ephemeral).data(from: url(path)).0 }

    private struct Peak: Decodable { var peak: Int; var active: Int; var bytes_sent: Int }
    private func peak() async -> Peak { ((try? await fetch("/_peak")).flatMap { try? JSONDecoder().decode(Peak.self, from: $0) }) ?? Peak(peak: -1, active: -1, bytes_sent: -1) }

    @discardableResult
    private func wait(_ id: UUID, for states: Set<DownloadState>, seconds: Double = 60) async -> DownloadTaskRecord? {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let record = c.ledger.record(id), states.contains(record.state) { return record }
            try? await Task.sleep(for: .milliseconds(40))
        }
        return c.ledger.record(id)
    }

    private func waitForPieces(_ id: UUID, atLeast count: Int, seconds: Double = 30) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, (c.http.multipartSnapshot(id)?.done ?? 0) < count { try? await Task.sleep(for: .milliseconds(30)) }
    }

    private func contents(_ record: DownloadTaskRecord?) -> Data? { record?.file.destinationPath.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0), options: .mappedIfSafe) } }

    private func leftovers() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: downloads.path)) ?? []).filter { $0.hasPrefix(".") } }

    // MARK: Normal operation

    func testALargeFileIsFetchedInPiecesAndArrivesIntact() async throws {
        let size = 24 * mib
        let id = try await c.http.start(url: url("/file/\(size)"))
        let record = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? "")
        XCTAssertEqual(record?.engineMetadata["mode"], "multipart")
        XCTAssertEqual(record?.engineMetadata["pieces"], "\(MultipartPlanner.plan(total: Int64(size)).count)")
        XCTAssertEqual(record?.engineMetadata["piecesDone"], record?.engineMetadata["pieces"], "every piece done before it was called complete")
        XCTAssertEqual(contents(record), expected(size), "byte for byte")
        XCTAssertEqual(record?.file.integrity, .verified)
        XCTAssertTrue(DownloadQuarantine.isQuarantined(URL(fileURLWithPath: record?.file.destinationPath ?? "/nonexistent")), "marked as downloaded from the internet")
        XCTAssertEqual(record?.id, id)
        XCTAssertEqual(c.ledger.records.values.filter { $0.protocolID == .http }.count, 1, "one task, not one per piece")
        let served = await peak()
        XCTAssertGreaterThanOrEqual(served.peak, 2, "pieces really ran at the same time")
        XCTAssertLessThanOrEqual(served.peak, MultipartPlanner.defaultConnections, "and no more than the connection limit")
        XCTAssertTrue(leftovers().isEmpty, "no temporary file left behind: \(leftovers())")
        XCTAssertEqual(c.http.engine.activeCount, 0)
        XCTAssertEqual(ConnectionBudget.shared.open, 0, "every connection was given back")
        XCTAssertEqual(DownloadTaskStore.open(folder: folder).pieceCount(), 0, "checkpoints are cleaned up after a successful finalisation")
    }

    func testASmallFileIsNotWorthSeveralConnections() async throws {
        let id = try await c.http.start(url: url("/file/5000000"))
        let record = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(record?.state, .completed)
        XCTAssertEqual(record?.engineMetadata["mode"], "single")
        XCTAssertEqual(contents(record), expected(5_000_000))
    }

    func testTheSwitchTurnsAccelerationOff() async throws {
        c.segmentedEnabled = false
        let id = try await c.http.start(url: url("/file/\(20 * mib)"))
        let record = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(record?.state, .completed)
        XCTAssertNotEqual(record?.engineMetadata["mode"], "multipart")
    }

    // MARK: Servers that cannot or should not be asked for pieces

    func testAServerThatIgnoresRangesGetsOneTransfer() async throws {
        let size = 20 * mib
        let id = try await c.http.start(url: url("/ignorerange/\(size)"))
        let record = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? "")
        XCTAssertEqual(record?.engineMetadata["mode"], "single")
        XCTAssertNotNil(record?.engineMetadata["multipartRefused"], "the reason is recorded")
        XCTAssertEqual(contents(record), expected(size))
    }

    func testCompressionMeansNoPieces() async throws {
        let size = 20 * mib
        let id = try await c.http.start(url: url("/encoded/\(size)"))
        let record = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? "")
        XCTAssertEqual(record?.engineMetadata["mode"], "single")
        XCTAssertEqual(contents(record), expected(size))
    }

    /// Each of these passes the first one-byte check and then misbehaves on the real pieces. In every case the file must come out right, as one transfer, under the same task.
    private func misbehaving(_ route: String, reasonContains: String? = nil, file: StaticString = #filePath, line: UInt = #line) async throws {
        let size = 20 * mib
        let id = try await c.http.start(url: url("/\(route)/\(size)"))
        let record = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(record?.state, .completed, "\(route): \(record?.failure?.reason ?? "")", file: file, line: line)
        XCTAssertEqual(record?.id, id, "the task id never changed", file: file, line: line)
        XCTAssertEqual(contents(record), expected(size), "\(route): the file is exactly what the server has, never a mixture", file: file, line: line)
        XCTAssertEqual(record?.engineMetadata["mode"], "single", "\(route): fell back to the Phase 2 transfer", file: file, line: line)
        XCTAssertEqual(c.ledger.records.values.filter { $0.protocolID == .http }.count, 1, "\(route): no duplicate task", file: file, line: line)
        XCTAssertTrue(leftovers().isEmpty, "\(route): \(leftovers())", file: file, line: line)
        XCTAssertEqual(ConnectionBudget.shared.open, 0, file: file, line: line)
        if let reasonContains { XCTAssertTrue(c.events.contains { $0.contains(reasonContains) }, "\(route): the diagnostics say why: \(c.events.suffix(5))", file: file, line: line) }
    }

    func testAPieceAnsweredWithTheWrongOffsetFallsBackToOneTransfer() async throws { try await misbehaving("wrongstart", reasonContains: "one transfer") }
    func testAPieceAnsweredWithTheWrongTotalIsNeverMixedIn() async throws { try await misbehaving("wrongtotal") }
    func testAPieceOfTheWrongLengthFallsBack() async throws { try await misbehaving("longer") }
    func testA416OnAPieceFallsBack() async throws { try await misbehaving("range416") }

    func testAFileThatChangesWhileItDownloadsIsNeverAssembledFromTwoVersions() async throws {
        let size = 20 * mib
        let id = try await c.http.start(url: url("/changing/\(size)?after=3"))
        let record = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? "")
        XCTAssertEqual(contents(record), expected(size))
        let reacted = record?.engineMetadata["multipartRestarts"] != nil || record?.engineMetadata["multipartRefused"] != nil
        XCTAssertTrue(reacted, "the change was noticed and handled: \(String(describing: record?.engineMetadata))")
        XCTAssertTrue(leftovers().isEmpty)
    }

    // MARK: Failures inside a piece

    func testATruncatedPieceIsFetchedAgainAndTheDownloadStaysInPieces() async throws {
        let size = 20 * mib
        let id = try await c.http.start(url: url("/trunc/\(size)"))
        let record = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? "")
        XCTAssertEqual(record?.engineMetadata["mode"], "multipart", "one bad piece is not a reason to give up pieces")
        XCTAssertEqual(contents(record), expected(size), "the truncated piece was replaced, not appended to")
        let served = await peak()
        XCTAssertGreaterThan(served.bytes_sent, size, "some bytes had to be fetched again")
        XCTAssertLessThan(served.bytes_sent, size * 2, "but not the whole file")
    }

    func testAServerThatIsBusyMakesTheDownloadSlowerNotBroken() async throws {
        let size = 20 * mib
        let id = try await c.http.start(url: url("/busy/\(size)"))
        let record = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? "")
        XCTAssertEqual(contents(record), expected(size))
        XCTAssertEqual(record?.engineMetadata["mode"], "multipart")
    }

    // MARK: Pause, resume, cancel, crash

    func testPausingKeepsEveryValidatedPieceAndResumingFetchesOnlyTheRest() async throws {
        let size = 32 * mib
        let id = try await c.http.start(url: url("/throttle/\(size)?bps=1000000"))
        await waitForPieces(id, atLeast: 2)
        XCTAssertTrue(c.canPause(id))
        c.pause(id)
        let paused = await wait(id, for: [.paused, .completed, .failed])
        XCTAssertEqual(paused?.state, .paused)
        XCTAssertNotNil(c.interrupted[id], "listed with a Resume button")
        let kept = DownloadTaskStore.open(folder: folder).loadPieces(task: id)
        let doneBefore = kept.filter { $0.state == .done }.count
        XCTAssertGreaterThanOrEqual(doneBefore, 2, "the pieces that were finished are saved")
        XCTAssertEqual(c.ledger.records[id]?.transfer.resumeAvailable, true)
        let sentBeforeResume = await peak().bytes_sent
        c.resume(id)
        let done = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(done?.state, .completed, done?.failure?.reason ?? "")
        XCTAssertEqual(done?.id, id)
        XCTAssertEqual(contents(done), expected(size))
        let sentAfter = await peak().bytes_sent
        let doneBytes = kept.filter { $0.state == .done }.reduce(0) { $0 + Int($1.length) }
        XCTAssertLessThanOrEqual(sentAfter - sentBeforeResume, size - doneBytes + 2 * 8 * mib, "only what was missing was fetched again (not the whole file)")
    }

    func testAPausedDownloadCanBePausedAgainAfterResuming() async throws {
        let size = 32 * mib
        let id = try await c.http.start(url: url("/throttle/\(size)?bps=1000000"))
        await waitForPieces(id, atLeast: 1)
        c.pause(id)
        await wait(id, for: [.paused])
        c.resume(id)
        await waitForPieces(id, atLeast: (c.http.multipartSnapshot(id)?.done ?? 0) + 1)
        XCTAssertTrue(c.canPause(id))
        c.pause(id)
        let again = await wait(id, for: [.paused, .completed])
        XCTAssertEqual(again?.state, .paused)
        c.resume(id)
        let done = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(contents(done), expected(size))
    }

    func testCancellingStopsEveryWorkerAndRemovesItsOwnFilesOnly() async throws {
        let bystander = downloads.appendingPathComponent("my-own-file.txt")
        try Data("mine".utf8).write(to: bystander)
        let size = 32 * mib
        let id = try await c.http.start(url: url("/throttle/\(size)?bps=1000000"))
        await waitForPieces(id, atLeast: 1)
        c.cancel(id)
        XCTAssertEqual(c.ledger.record(id)?.state, .cancelled)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(c.ledger.record(id)?.state, .cancelled, "late callbacks change nothing")
        XCTAssertTrue(c.failures.isEmpty, "cancelling is not a failure")
        XCTAssertTrue(leftovers().isEmpty, "this task's working file is gone: \(leftovers())")
        XCTAssertEqual(try String(contentsOf: bystander, encoding: .utf8), "mine", "a file that was not this task's is untouched")
        XCTAssertEqual(DownloadTaskStore.open(folder: folder).loadPieces(task: id).count, 0)
        XCTAssertEqual(ConnectionBudget.shared.open, 0, "every connection was given back")
        let served = await peak()
        XCTAssertEqual(served.active, 0, "the server sees no connection still open")
        XCTAssertTrue(c.completed.isEmpty)
    }

    func testACrashLeavesAResumableDownloadAndTheFinishedPiecesAreReused() async throws {
        let size = 32 * mib
        let id = try await c.http.start(url: url("/throttle/\(size)?bps=1000000"))
        await waitForPieces(id, atLeast: 2)
        c.ledger.flush()
        DownloadTaskStore.open(folder: folder).flush()
        let finished = DownloadTaskStore.open(folder: folder).loadPieces(task: id).filter { $0.state == .done }
        XCTAssertGreaterThanOrEqual(finished.count, 2)
        c.http.simulateCrash(id)                                   // the app is gone
        DownloadTaskStore.open(folder: folder).flush()
        let sentAtCrash = await peak().bytes_sent
        let reopened = coordinator()
        c = reopened
        XCTAssertEqual(c.ledger.record(id)?.state, .recoveryRequired, "found part-way: never started by itself")
        XCTAssertNotNil(c.interrupted[id], "listed with a Resume button, not lost")
        c.resume(id)
        let done = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(done?.state, .completed, done?.failure?.reason ?? "")
        XCTAssertEqual(done?.id, id)
        XCTAssertEqual(contents(done), expected(size), "the pieces from before the crash and after it join exactly")
        let sentTotal = await peak().bytes_sent
        let reusedBytes = finished.reduce(0) { $0 + Int($1.length) }
        XCTAssertLessThanOrEqual(sentTotal - sentAtCrash, size - reusedBytes + 3 * 8 * mib, "the finished pieces were not fetched again")
        XCTAssertTrue(leftovers().isEmpty)
    }

    func testAPieceThatChangedOnDiskBetweenRunsIsCaughtBeforeTheFileIsCalledComplete() async throws {
        let size = 32 * mib
        let id = try await c.http.start(url: url("/throttle/\(size)?bps=1000000"))
        await waitForPieces(id, atLeast: 1)
        c.ledger.flush()
        DownloadTaskStore.open(folder: folder).flush()
        let finished = DownloadTaskStore.open(folder: folder).loadPieces(task: id).filter { $0.state == .done }
        let target = try XCTUnwrap(finished.first)
        c.http.simulateCrash(id)
        DownloadTaskStore.open(folder: folder).flush()
        // Damage the saved piece, as a bad disk or another program might.
        let working = MultipartRun.workingURL(for: id, in: downloads)
        let handle = try FileHandle(forUpdating: working)
        try handle.seek(toOffset: UInt64(target.start + 1000))
        try handle.write(contentsOf: Data(repeating: 0xEE, count: 64))
        try handle.close()
        c = coordinator()
        c.resume(id)
        let done = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(done?.state, .completed, done?.failure?.reason ?? "")
        XCTAssertEqual(contents(done), expected(size), "the damage was found and the file downloaded again, not delivered corrupt")
        XCTAssertEqual(done?.engineMetadata["multipartRestarts"], "1")
    }

    func testAFileThatChangedOnTheServerWhilePausedStartsOver() async throws {
        let size = 32 * mib
        let id = try await c.http.start(url: url("/throttle/\(size)?bps=1000000"))
        await waitForPieces(id, atLeast: 1)
        c.pause(id)
        await wait(id, for: [.paused])
        _ = try await fetch("/_bump")                              // a new version of the file
        c.resume(id)
        let done = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(done?.state, .completed, done?.failure?.reason ?? "")
        XCTAssertEqual(contents(done), expected(size))
        XCTAssertTrue(c.events.contains { $0.contains("changed on the website") }, "and the person is told: \(c.events.suffix(4))")
    }

    // MARK: Limits and isolation

    func testSeveralDownloadsStayInsideTheConnectionBudget() async throws {
        var ids: [UUID] = []
        for i in 0..<3 { ids.append(try await c.http.start(url: url("/throttle/\(24 * mib + i)?bps=2000000"))) }
        var highest = 0
        let end = Date().addingTimeInterval(40)
        while Date() < end, ids.contains(where: { !(c.ledger.record($0)?.state.isFinal ?? true) && c.ledger.record($0)?.state != .failed }) {
            highest = max(highest, ConnectionBudget.shared.open)
            try? await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertLessThanOrEqual(highest, ConnectionBudget.totalLimit, "never more connections than the global limit")
        for id in ids { XCTAssertEqual(c.ledger.record(id)?.state, .completed) }
        let served = await peak()
        // The budget bounds the piece connections; each new download also sends one short range probe before it gets a budget, so the server may briefly see one more.
        XCTAssertLessThanOrEqual(served.peak, ConnectionBudget.perHostLimit + 1, "and never more to one host than the per-host limit (plus a probe)")
        XCTAssertEqual(ConnectionBudget.shared.open, 0)
    }

    func testAnotherProfileNeverSeesTheseDownloadsOrTheirPieces() async throws {
        let size = 32 * mib
        let id = try await c.http.start(url: url("/throttle/\(size)?bps=1000000"))
        await waitForPieces(id, atLeast: 1)
        c.ledger.flush()
        let other = coordinator(profile: "work")
        XCTAssertNil(other.ledger.record(id))
        XCTAssertTrue(other.interrupted.isEmpty)
        other.cancel(id)
        XCTAssertNotEqual(c.ledger.record(id)?.state, .cancelled, "another profile cannot cancel it")
        c.cancel(id)
    }

    func testAScriptsRequestIsNeverSplitIntoPieces() async throws {
        // The origin check comes first: a script's request to a local address is refused before anything is asked for.
        var options = HTTPDownloadRunner.Options()
        options.origin = .automation
        do { _ = try await c.http.start(url: url("/file/\(24 * mib)"), options: options); XCTFail() } catch { XCTAssertTrue(error is HTTPRequestPolicy.Refusal) }
        let served = await peak()
        XCTAssertEqual(served.bytes_sent, 0, "nothing was requested")
    }

    // MARK: Benchmark

    /// Single transfer, the earlier piece downloader, and the new engine, on the same files. Printed as "BENCH …" lines. The comparison is asserted only where the result is not in doubt.
    func testBenchmarkSingleVersusThePreviousPiecesVersusMultipart() async throws {
        struct Row { var name: String; var seconds: Double; var sentBytes: Int; var peakConnections: Int; var memoryMB: Double }
        func measure(_ name: String, path: String, size: Int, run: () async throws -> Void) async throws -> Row {
            _ = try await fetch("/_reset")
            let before = currentMemoryFootprint()
            var highest = before
            let sampler = Task { @MainActor in while !Task.isCancelled { highest = max(highest, currentMemoryFootprint()); try? await Task.sleep(for: .milliseconds(25)) } }
            let started = Date()
            try await run()
            let seconds = Date().timeIntervalSince(started)
            sampler.cancel()
            let served = await peak()
            let row = Row(name: name, seconds: seconds, sentBytes: served.bytes_sent, peakConnections: served.peak, memoryMB: Double(highest &- before) / 1_048_576)
            print(String(format: "BENCH %@ | %@ | %.2f s | %.1f MB/s | server sent %.1f MB (%.2fx the file) | peak connections %d | memory +%.0f MB", name, path, seconds, Double(size) / 1_048_576 / seconds,
                         Double(served.bytes_sent) / 1_048_576, Double(served.bytes_sent) / Double(size), served.peak, row.memoryMB))
            return row
        }
        func viaCoordinator(_ path: String, multipart: Bool, size: Int) async throws {
            c.segmentedEnabled = multipart
            let id = try await c.http.start(url: url(path))
            let record = await wait(id, for: [.completed, .failed])
            XCTAssertEqual(record?.state, .completed, "\(path): \(record?.failure?.reason ?? "")")
            XCTAssertEqual(record?.file.integrity, .verified)
            try? FileManager.default.removeItem(atPath: record?.file.destinationPath ?? "/nonexistent")
        }
        // A server that limits each connection (the case pieces exist for).
        let size = 24 * mib
        let slow = "/throttle/\(size)?bps=3000000"
        let single = try await measure("single (phase 2)      ", path: slow, size: size) { try await viaCoordinator(slow, multipart: false, size: size) }
        let pieces = try await measure("previous 6 pieces     ", path: slow, size: size) {
            let target = downloads.appendingPathComponent("prev-\(UUID().uuidString).bin")
            try await PieceDownloader(url: url(slow), pieces: 6).run(total: Int64(size), to: target) { _ in }
            XCTAssertEqual(try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int, size)
            try? FileManager.default.removeItem(at: target)
        }
        let multi = try await measure("multipart (new, 4)    ", path: slow, size: size) { try await viaCoordinator(slow, multipart: true, size: size) }
        c.http.multipartConnections = 6
        let multi6 = try await measure("multipart (new, 6)    ", path: slow, size: size) { try await viaCoordinator(slow, multipart: true, size: size) }
        c.http.multipartConnections = MultipartPlanner.defaultConnections
        _ = multi6
        // A fast local server with no per-connection limit: pieces should not be expected to win, and must not cost much.
        let fast = "/file/\(size)"
        let fastSingle = try await measure("single, fast server  ", path: fast, size: size) { try await viaCoordinator(fast, multipart: false, size: size) }
        let fastMulti = try await measure("multipart, fast server", path: fast, size: size) { try await viaCoordinator(fast, multipart: true, size: size) }
        // High latency, little data: connection setup dominates.
        let lat = "/latency/\(size)?ms=300&bps=0"
        let latSingle = try await measure("single, 300 ms latency", path: lat, size: size) { try await viaCoordinator(lat, multipart: false, size: size) }
        let latMulti = try await measure("multipart, 300 ms     ", path: lat, size: size) { try await viaCoordinator(lat, multipart: true, size: size) }
        print("BENCH summary: throttled: multipart \(String(format: "%.2f", single.seconds / multi.seconds))x single, \(String(format: "%.2f", pieces.seconds / multi.seconds))x the previous pieces; fast server: \(String(format: "%.2f", fastSingle.seconds / fastMulti.seconds))x; high latency: \(String(format: "%.2f", latSingle.seconds / latMulti.seconds))x")

        XCTAssertLessThan(multi.seconds, single.seconds * 0.6, "on a server that limits each connection, four connections must clearly beat one")
        XCTAssertLessThanOrEqual(multi.sentBytes, Int(Double(size) * 1.1), "no wasted transfer when nothing goes wrong")
        XCTAssertLessThanOrEqual(multi.peakConnections, MultipartPlanner.defaultConnections)
        XCTAssertLessThan(multi.memoryMB, 120, "memory stays bounded: a 24 MB file never sits in memory")
        _ = (fastSingle, fastMulti, latSingle, latMulti)
    }
}
