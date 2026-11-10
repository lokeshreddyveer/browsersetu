import XCTest
@testable import Browser_Setu

/// Pause, resume, cancel and recovery, run for real against the local fixture server (port 18766), with the race points made exact by a hook rather than by timing.
@MainActor
final class Phase4IntegrationTests: XCTestCase {
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
        XCTAssertTrue(reachable, "the download fixture server is not running on port \(Self.port): run these tests through the BrowserSetuMac scheme")
        guard reachable else { throw XCTSkip("fixture server not running") }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("phase4-\(UUID().uuidString)")
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
        FinalizationTestHook.hook = nil
        if let c { for (id, record) in c.ledger.records where !record.state.isFinal && record.state != .failed { c.cancel(id) } }
        try? await Task.sleep(for: .milliseconds(200))
        if let folder { DownloadTaskStore.close(folder: folder) }
        if let root { try? FileManager.default.removeItem(at: root) }
        DownloadCoordinator.directoryOverride = savedOverride
        HTTPRetrySchedule.delayScale = savedScale
        try await super.tearDown()
    }

    // MARK: Helpers

    private func coordinator() -> DownloadCoordinator {
        let coordinator = DownloadCoordinator()
        coordinator.profileName = "default"
        coordinator.store = folder
        coordinator.hasHost = { true }
        return coordinator
    }
    private func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(Self.port)\(path)")! }
    private func fetch(_ path: String) async throws -> Data { try await URLSession(configuration: .ephemeral).data(from: url(path)).0 }
    private func expected(_ size: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: size)
        for i in 0..<size { bytes[i] = UInt8(truncatingIfNeeded: (i * 31 + 7) % 251) }
        return Data(bytes)
    }
    @discardableResult
    private func wait(_ id: UUID, for states: Set<DownloadState>, seconds: Double = 60) async -> DownloadTaskRecord? {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let record = c.ledger.record(id), states.contains(record.state) { return record }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return c.ledger.record(id)
    }
    private func waitForPieces(_ id: UUID, atLeast count: Int, seconds: Double = 30) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, (c.http.multipartSnapshot(id)?.done ?? 0) < count { try? await Task.sleep(for: .milliseconds(30)) }
    }
    private func contents(_ record: DownloadTaskRecord?) -> Data? { record?.file.destinationPath.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0), options: .mappedIfSafe) } }
    private func visibleFiles() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: downloads.path)) ?? []).filter { !$0.hasPrefix(".") } }
    private func hiddenFiles() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: downloads.path)) ?? []).filter { $0.hasPrefix(".") } }

    /// Runs `action` on the main actor from the engine's own queue and waits for it to return, so a person's click lands at exactly this point of the finish.
    nonisolated private func clickNow(_ action: @escaping @MainActor () -> Void) {
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in action(); done.signal() }
        done.wait()
    }

    // MARK: Cancel against finalisation (both engines)

    func testMultipartCancelBeforeTheFileIsClaimedWinsAndLeavesNothingBehind() async throws {
        var id: UUID?
        FinalizationTestHook.hook = { [self] stage in if stage == .beforeClaim, let id { clickNow { self.c.cancel(id) } } }
        let size = 20 * mib
        id = try await c.http.start(url: url("/file/\(size)"))
        let record = await wait(id!, for: [.completed, .cancelled, .failed])
        XCTAssertEqual(record?.state, .cancelled, "the cancel came first and is honoured")
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(visibleFiles(), [], "no finished file appears for a download that was cancelled")
        XCTAssertEqual(hiddenFiles(), [], "and no working file is left")
        XCTAssertEqual(DownloadTaskStore.open(folder: folder).loadPieces(task: id!).count, 0)
    }

    func testMultipartCancelAfterTheFileIsClaimedIsTooLateAndTheDownloadCompletes() async throws {
        var id: UUID?
        FinalizationTestHook.hook = { [self] stage in if stage == .afterClaim, let id { clickNow { self.c.cancel(id) } } }
        let size = 20 * mib
        id = try await c.http.start(url: url("/file/\(size)"))
        let record = await wait(id!, for: [.completed, .cancelled, .failed])
        XCTAssertEqual(record?.state, .completed, "it had passed the point of no return, so it is not reported cancelled")
        XCTAssertEqual(contents(record), expected(size), "and the file is whole")
        XCTAssertTrue(c.events.contains { $0.contains("finished before it could be cancelled") })
        XCTAssertEqual(hiddenFiles(), [])
    }

    func testMultipartPauseAfterTheFileIsClaimedIsAnsweredByTheCompletion() async throws {
        var id: UUID?
        FinalizationTestHook.hook = { [self] stage in if stage == .afterClaim, let id { clickNow { self.c.pause(id) } } }
        let size = 20 * mib
        id = try await c.http.start(url: url("/file/\(size)"))
        let record = await wait(id!, for: [.completed, .paused, .failed])
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? "")
        XCTAssertEqual(contents(record), expected(size))
        XCTAssertEqual(c.http.pendingRetries, 0)
    }

    func testSingleTransferCancelBeforeTheFileIsClaimedWinsAndLeavesNothingBehind() async throws {
        var id: UUID?
        FinalizationTestHook.hook = { [self] stage in if stage == .beforeClaim, let id { clickNow { self.c.cancel(id) } } }
        id = try await c.http.start(url: url("/file/\(2 * mib)"))
        let record = await wait(id!, for: [.completed, .cancelled, .failed])
        XCTAssertEqual(record?.state, .cancelled)
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(visibleFiles(), [])
        XCTAssertEqual(hiddenFiles(), [])
    }

    func testSingleTransferCancelAfterTheFileIsClaimedIsTooLateAndTheDownloadCompletes() async throws {
        var id: UUID?
        FinalizationTestHook.hook = { [self] stage in if stage == .afterClaim, let id { clickNow { self.c.cancel(id) } } }
        id = try await c.http.start(url: url("/file/\(2 * mib)"))
        let record = await wait(id!, for: [.completed, .cancelled, .failed])
        XCTAssertEqual(record?.state, .completed)
        XCTAssertEqual(contents(record), expected(2 * mib))
        XCTAssertTrue(c.events.contains { $0.contains("finished before it could be cancelled") })
    }

    func testCancellingAFinishedDownloadNeverDeletesItsFile() async throws {
        let id = try await c.http.start(url: url("/file/\(2 * mib)"))
        let record = await wait(id, for: [.completed])
        XCTAssertEqual(record?.state, .completed)
        c.cancel(id)
        c.cancel(id)
        XCTAssertEqual(c.ledger.record(id)?.state, .completed)
        XCTAssertEqual(contents(c.ledger.record(id)), expected(2 * mib))
    }

    func testACancelNeverOverwritesOrDeletesAFileThatWasAlreadyThere() async throws {
        let mine = downloads.appendingPathComponent("file-\(20 * mib).bin")
        _ = mine
        let existing = try XCTUnwrap(FileManager.default.createFile(atPath: downloads.appendingPathComponent("keep.txt").path, contents: Data("mine".utf8)) ? downloads.appendingPathComponent("keep.txt") : nil)
        let id = try await c.http.start(url: url("/throttle/\(24 * mib)?bps=1000000"))
        try? await Task.sleep(for: .milliseconds(600))
        c.cancel(id)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(try? Data(contentsOf: existing), Data("mine".utf8))
    }

    // MARK: Progress

    func testProgressNeverGoesBackwardsAcrossAPauseAndResume() async throws {
        let size = 32 * mib
        let id = try await c.http.start(url: url("/throttle/\(size)?bps=1000000"))
        await waitForPieces(id, atLeast: 1)
        try? await Task.sleep(for: .milliseconds(800))            // some of the next piece is on its way too
        c.pause(id)
        await wait(id, for: [.paused])
        let before = c.ledger.record(id)?.transfer.completedBytes ?? 0
        XCTAssertGreaterThan(before, 0)
        c.resume(id)
        var samples: [Int64] = []
        let end = Date().addingTimeInterval(90)
        while Date() < end {
            if let r = c.ledger.record(id) {
                if r.state == .running || r.state == .resuming { samples.append(r.transfer.completedBytes) }
                if r.state == .completed || r.state == .failed { break }
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
        XCTAssertEqual(c.ledger.record(id)?.state, .completed)
        XCTAssertFalse(samples.isEmpty)
        XCTAssertGreaterThanOrEqual(samples.min() ?? 0, before, "the bar did not fall after the resume")
        XCTAssertEqual(samples, samples.sorted(), "and it only ever rose")
        XCTAssertLessThan(samples.max() ?? 0, Int64(size) + 1)
    }

    func testAnExplainedStartOverIsTheOnlyWayProgressFalls() async throws {
        let size = 32 * mib
        let id = try await c.http.start(url: url("/throttle/\(size)?bps=1000000"))
        await waitForPieces(id, atLeast: 1)
        c.pause(id)
        await wait(id, for: [.paused])
        let before = c.ledger.record(id)?.transfer.completedBytes ?? 0
        _ = try await fetch("/_bump")                              // the website's file is now a different one
        c.resume(id)
        var lowest = before
        let end = Date().addingTimeInterval(90)
        while Date() < end {
            if let r = c.ledger.record(id) {
                if r.state == .running || r.state == .resuming { lowest = min(lowest, r.transfer.completedBytes) }
                if r.state == .completed || r.state == .failed { break }
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
        XCTAssertLessThan(lowest, before, "the old bytes were no longer wanted, so the figure restarted")
        XCTAssertTrue(c.events.contains { $0.contains("changed on the website") }, "and the person is told why")
        XCTAssertEqual(c.ledger.record(id)?.state, .completed)
    }

    func testACancelWhileTheCompletionIsBeingRecordedNeverDeletesTheFinishedFile() async throws {
        // The file is in place and the checksum is still being read: the task is still "running" on record, which is exactly when a cancel used to slip through.
        let destination = downloads.appendingPathComponent("finished.bin")
        let id = plant(state: .running, total: 4096, started: Date().addingTimeInterval(-60), destination: destination, mode: "multipart")
        try Data(repeating: 5, count: 4096).write(to: destination)
        c.http.finishing.insert(id)
        c.cancel(id)
        XCTAssertEqual(c.ledger.record(id)?.state, .running, "not reported cancelled")
        XCTAssertEqual(try Data(contentsOf: destination), Data(repeating: 5, count: 4096), "and the finished file is still there")
        XCTAssertTrue(c.events.contains { $0.contains("finished before it could be cancelled") })
    }

    func testAPauseAskedWhileFinishingIsAnsweredAndNotLeftWaiting() async throws {
        var id: UUID?
        var answered = false
        FinalizationTestHook.hook = { [self] stage in
            if stage == .afterClaim, let id { clickNow { self.c.http.pauseTransferPublic(id) { _ in answered = true } } }
        }
        let size = 20 * mib
        id = try await c.http.start(url: url("/file/\(size)"))
        let record = await wait(id!, for: [.completed, .failed])
        XCTAssertEqual(record?.state, .completed)
        XCTAssertTrue(answered, "whoever asked (a pause-all, a quit) is told, so it does not wait for an answer that never comes")
    }

    func testPartsThatCouldNotBeKeptRestartTheFigureAtZero() async throws {
        let size = 32 * mib
        let id = try await c.http.start(url: url("/throttle/\(size)?bps=1000000"))
        await waitForPieces(id, atLeast: 2)
        try? await Task.sleep(for: .milliseconds(2300))            // so the figure has been written to disk
        c.ledger.flush(); DownloadTaskStore.open(folder: folder).flush()
        c.http.simulateCrash(id)
        try FileManager.default.removeItem(at: MultipartRun.workingURL(for: id, in: downloads))
        c = coordinator()
        let before = c.ledger.record(id)?.transfer.completedBytes ?? 0
        XCTAssertGreaterThan(before, 0)
        c.resume(id)
        var lowest = before
        let end = Date().addingTimeInterval(90)
        while Date() < end {
            if let r = c.ledger.record(id) {
                if r.state == .running || r.state == .resuming { lowest = min(lowest, r.transfer.completedBytes) }
                if r.state == .completed || r.state == .failed { break }
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertLessThan(lowest, before, "the old figure described parts that no longer exist")
        XCTAssertEqual(c.ledger.record(id)?.state, .completed)
    }

    func testAResumeRefusedByPolicyLeavesNoWorkingFileBehind() async throws {
        let size = 32 * mib
        let id = try await c.http.start(url: url("/throttle/\(size)?bps=1000000"))
        await waitForPieces(id, atLeast: 1)
        c.ledger.update(id) { $0.engineMetadata["origin"] = "automation" }          // what a script's task would have recorded
        c.ledger.flush(); DownloadTaskStore.open(folder: folder).flush()
        c.http.simulateCrash(id)
        c = coordinator()
        c.resume(id)
        _ = await wait(id, for: [.failed, .completed], seconds: 30)
        XCTAssertFalse(FileManager.default.fileExists(atPath: MultipartRun.workingURL(for: id, in: downloads).path), "a refused resume cannot use it, so it is not kept")
        XCTAssertEqual(DownloadTaskStore.open(folder: folder).loadPieces(task: id).count, 0)
    }

    // MARK: Retry lifecycle

    func testACancelledTaskWaitingToRetryNeverRetries() async throws {
        HTTPRetrySchedule.delayScale = 1
        let id = try await c.http.start(url: url("/status/503"))
        let planned = await wait(id, for: [.retrying, .failed, .cancelled], seconds: 20)
        XCTAssertEqual(planned?.state, .retrying)
        let seenBefore = try await requestCount()
        c.cancel(id)
        XCTAssertEqual(c.http.pendingRetries, 0, "its timer was cancelled with it")
        try? await Task.sleep(for: .seconds(4))
        XCTAssertEqual(c.ledger.record(id)?.state, .cancelled)
        let seenAfter = try await requestCount()
        XCTAssertEqual(seenAfter, seenBefore, "nothing was sent after the cancel")
    }

    private func requestCount() async throws -> Int {
        let data = try await fetch("/_log")
        // The server's own bookkeeping calls (paths starting with /_) are not downloads' requests.
        let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        return entries.filter { !(($0["path"] as? String) ?? "").hasPrefix("/_") }.count
    }

    // MARK: Crash recovery of the files against the database

    private func plant(state: DownloadEvent, total: Int64, started: Date, destination: URL, mode: String? = nil) -> UUID {
        let record = c.ledger.create(protocolID: .http, source: url("/file/\(total)"), filename: destination.lastPathComponent, isPrivate: false)
        c.ledger.update(record.id) {
            $0.file.destinationPath = destination.path
            $0.transfer.totalBytes = total
            $0.startedAt = started
            if let mode { $0.engineMetadata["mode"] = mode }
        }
        _ = c.ledger.apply(.queued, to: record.id)
        _ = c.ledger.apply(.started, to: record.id)
        _ = c.ledger.apply(.running, to: record.id)
        c.ledger.update(record.id) { $0.startedAt = started }
        c.ledger.flush()
        return record.id
    }

    func testAFileMovedIntoPlaceBeforeTheAppEndedIsCompletedNotDownloadedAgain() async throws {
        let destination = downloads.appendingPathComponent("moved.bin")
        let id = plant(state: .running, total: 4096, started: Date().addingTimeInterval(-60), destination: destination)
        try Data(repeating: 7, count: 4096).write(to: destination)
        c = coordinator()
        XCTAssertEqual(c.ledger.record(id)?.state, .completed, "found complete on disk, so finished rather than restarted")
        XCTAssertEqual(try Data(contentsOf: destination).count, 4096)
    }

    func testAnOlderFileWithTheSameNameAndSizeIsNeverTakenForTheDownload() async throws {
        let destination = downloads.appendingPathComponent("old.bin")
        try Data(repeating: 1, count: 4096).write(to: destination)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-86_400)], ofItemAtPath: destination.path)
        let id = plant(state: .running, total: 4096, started: Date().addingTimeInterval(-60), destination: destination)
        c = coordinator()
        XCTAssertEqual(c.ledger.record(id)?.state, .recoveryRequired, "it needs a decision; it was not silently marked finished")
        XCTAssertEqual(try Data(contentsOf: destination), Data(repeating: 1, count: 4096), "and the person's file is untouched")
    }

    func testLeftoversOfAFinishedTaskAreSweptAndItsFileIsNot() async throws {
        let destination = downloads.appendingPathComponent("done.bin")
        let id = plant(state: .running, total: 4096, started: Date().addingTimeInterval(-60), destination: destination, mode: "multipart")
        try Data(repeating: 9, count: 4096).write(to: destination)
        _ = c.ledger.apply(.verifying, to: id)
        _ = c.ledger.apply(.completed(.verified), to: id)
        // The cleanup was cut short: the working file and the saved pieces are still there.
        let working = MultipartRun.workingURL(for: id, in: downloads)
        try Data(repeating: 0, count: 4096).write(to: working)
        try c.ledger.store?.savePlan(task: id, pieces: MultipartPlanner.plan(total: 4096 << 10))
        c.ledger.flush()
        c = coordinator()
        XCTAssertFalse(FileManager.default.fileExists(atPath: working.path), "its working file is gone")
        XCTAssertEqual(DownloadTaskStore.open(folder: folder).loadPieces(task: id).count, 0, "and its pieces")
        XCTAssertEqual(try Data(contentsOf: destination), Data(repeating: 9, count: 4096), "but the finished file is exactly as it was")
    }

    func testAMissingWorkingFileIsReportedAsAStartOverNotAsAResume() async throws {
        let size = 32 * mib
        let id = try await c.http.start(url: url("/throttle/\(size)?bps=1000000"))
        await waitForPieces(id, atLeast: 1)
        c.ledger.flush(); DownloadTaskStore.open(folder: folder).flush()
        c.http.simulateCrash(id)
        try FileManager.default.removeItem(at: MultipartRun.workingURL(for: id, in: downloads))
        c = coordinator()
        let item = try XCTUnwrap(c.interrupted[id])
        guard case .restartRequired = item.recovery else { return XCTFail("said it would resume: \(item.recovery)") }
        XCTAssertEqual(item.recovery.actionTitle, "Start Over")
        c.resume(id)
        let done = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(done?.state, .completed, done?.failure?.reason ?? "")
        XCTAssertEqual(contents(done), expected(size))
    }

    func testAnIntactCrashedDownloadIsOfferedAsAResume() async throws {
        let size = 32 * mib
        let id = try await c.http.start(url: url("/throttle/\(size)?bps=1000000"))
        await waitForPieces(id, atLeast: 2)
        c.ledger.flush(); DownloadTaskStore.open(folder: folder).flush()
        c.http.simulateCrash(id)
        c = coordinator()
        XCTAssertEqual(c.interrupted[id]?.recovery, .resumable)
        XCTAssertEqual(c.interrupted[id]?.recovery.actionTitle, "Resume")
        XCTAssertEqual(c.ledger.record(id)?.state, .recoveryRequired, "never started by itself")
    }

    // MARK: Untrusted requests

    func testARequestFromAScriptIsRefusedBeforeAnythingIsSent() async throws {
        let saved = HTTPRequestPolicy.untrustedRequestsEnabled
        HTTPRequestPolicy.untrustedRequestsEnabled = false
        defer { HTTPRequestPolicy.untrustedRequestsEnabled = saved }
        let before = try await requestCount()
        var options = HTTPDownloadRunner.Options()
        options.origin = .automation
        do { _ = try await c.http.start(url: url("/file/\(2 * mib)"), options: options); XCTFail("a script's request must be refused") }
        catch { XCTAssertEqual(error as? HTTPRequestPolicy.Refusal, .untrustedRequestsDisabled) }
        let after = try await requestCount()
        XCTAssertEqual(after, before, "no connection was made, not even a probe")
        XCTAssertTrue(c.ledger.records.values.filter { $0.protocolID == .http }.isEmpty, "and no task was created")
    }

    // MARK: Slow first answer

    func testASlowWebsitePrefersOneTransferForASmallFile() async throws {
        let id = try await c.http.start(url: url("/latency/\(24 * mib)?ms=400&bps=0"))
        let record = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? "")
        XCTAssertEqual(record?.engineMetadata["mode"], "single")
        XCTAssertEqual(record?.engineMetadata["multipartRefused"], "slow-first-answer")
        XCTAssertEqual(contents(record), expected(24 * mib))
    }
}
