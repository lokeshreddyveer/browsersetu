import XCTest
@testable import Browser_Setu

/// The coordinator and the ledger together: one task, one identity, one record, one completion.
@MainActor
final class DownloadLedgerIntegrationTests: XCTestCase {
    private var folder: URL!
    private var downloads: URL!
    private var savedOverride: URL?

    override func setUp() {
        super.setUp()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dl-int-\(UUID().uuidString)")
        folder = root.appendingPathComponent("store")
        downloads = root.appendingPathComponent("Downloads")
        try? FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        savedOverride = DownloadCoordinator.directoryOverride
        DownloadCoordinator.directoryOverride = downloads
    }

    override func tearDown() {
        DownloadTaskStore.close(folder: folder)
        try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
        DownloadCoordinator.directoryOverride = savedOverride
        super.tearDown()
    }

    private func coordinator(profile: String = "default") -> DownloadCoordinator {
        let c = DownloadCoordinator()
        c.profileName = profile
        c.store = folder
        return c
    }

    private let source = URL(string: "https://files.test/big.zip")!

    func testOneIdentityFromTheFirstRequestToTheLastByte() async {
        let c = coordinator()
        let ticket = await c.admitTicket(filename: "big.zip", source: source)
        XCTAssertTrue(ticket.admitted)
        XCTAssertEqual(c.ledger.record(ticket.id)?.state, .queued)
        let started = c.begin(suggestedName: "big.zip", sourceURL: source, taskID: ticket.id, cancel: {})
        XCTAssertEqual(started.id, ticket.id, "the id the queue knew is the id the download has")
        XCTAssertEqual(c.ledger.record(ticket.id)?.state, .running)
        XCTAssertEqual(c.ledger.record(ticket.id)?.attempt, 1)
        c.finish(started.id, source: source)
        XCTAssertEqual(c.ledger.record(ticket.id)?.state, .completed)
        XCTAssertNotNil(c.ledger.record(ticket.id)?.completedAt)
    }

    func testACompletionReportedTwiceCompletesOnce() {
        let c = coordinator()
        var finished = 0
        c.onFinished = { _, _, _ in finished += 1 }
        let started = c.begin(suggestedName: "a.bin", sourceURL: source, cancel: {})
        c.finish(started.id, source: source)
        c.finish(started.id, source: source)
        XCTAssertEqual(finished, 1)
        XCTAssertEqual(c.completed.count, 1)
    }

    func testPausingAndResumingKeepsTheTaskAndItsRecord() async throws {
        let c = coordinator()
        let started = c.begin(suggestedName: "a.bin", sourceURL: source, cancel: {}, suspend: { done in done(Data("place".utf8)) })
        XCTAssertTrue(c.canPause(started.id))
        c.pause(started.id)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(c.ledger.record(started.id)?.state, .paused)
        XCTAssertNotNil(c.interrupted[started.id])
        var resumedWith: Data?
        c.resumer = { resumedWith = $0 }
        c.resume(started.id)
        XCTAssertEqual(resumedWith, Data("place".utf8))
        XCTAssertEqual(c.ledger.record(started.id)?.state, .running)
        XCTAssertNotNil(c.active[started.id], "listed as running again, under the same id")
        XCTAssertEqual(c.ledger.record(started.id)?.attempt, 2)
    }

    func testAPieceDownloadIsNotOfferedAPauseItCannotDo() {
        let c = coordinator()
        let started = c.begin(suggestedName: "p.bin", sourceURL: source, protocolID: .httpPieces, cancel: {}, suspend: { done in done(Data("x".utf8)) })
        XCTAssertFalse(c.canPause(started.id), "its engine has no pause, so no control is shown")
    }

    func testACancelledDownloadStaysCancelledWhateverTheEngineReportsNext() {
        let c = coordinator()
        let started = c.begin(suggestedName: "a.bin", sourceURL: source, cancel: {})
        c.cancel(started.id)
        XCTAssertEqual(c.ledger.record(started.id)?.state, .cancelled)
        c.fail(started.id, source: source, error: URLError(.cancelled), willRetry: false)
        XCTAssertEqual(c.ledger.record(started.id)?.state, .cancelled)
        XCTAssertTrue(c.failures.isEmpty, "stopping it is not a failure")
        c.finish(started.id, source: source)
        XCTAssertEqual(c.completed.count, 0, "and it is never reported complete")
    }

    func testAFailedDownloadIsListedUnderItsOwnIdAndTriedAgainAsTheSameTask() async {
        let c = coordinator()
        c.hasHost = { true }
        var startedURLs: [URL] = []
        c.starter = { startedURLs.append($0) }
        let first = c.begin(suggestedName: "a.bin", sourceURL: source, cancel: {})
        c.fail(first.id, source: source, error: URLError(.fileDoesNotExist), willRetry: false)
        XCTAssertEqual(c.failures.first?.id, first.id)
        XCTAssertEqual(c.ledger.record(first.id)?.state, .failed)
        c.retryFailure(first.id)
        XCTAssertEqual(startedURLs, [source])
        let ticket = await c.admitTicket(filename: "a.bin", source: source)
        XCTAssertEqual(ticket.id, first.id, "tried again as the same task, not a new one")
        XCTAssertEqual(c.ledger.record(ticket.id)?.state, .queued)
    }

    func testScheduledDownloadsSurviveARestartAndKeepTheirIdentity() async {
        let c = coordinator()
        c.holdQueue(until: .distantFuture)
        let ticket = await c.admitTicket(filename: "later.zip", source: source)
        XCTAssertFalse(ticket.admitted)
        XCTAssertEqual(c.scheduled.map(\.id), [ticket.id])
        let after = coordinator()
        XCTAssertEqual(after.scheduled.map(\.id), [ticket.id])
        XCTAssertEqual(after.ledger.record(ticket.id)?.state, .scheduled)
        after.hasHost = { true }
        var startedURLs: [URL] = []
        after.starter = { startedURLs.append($0) }
        after.holdQueue(until: nil)
        after.startScheduledNow()
        XCTAssertEqual(startedURLs, [source])
        let admitted = await after.admitTicket(filename: "later.zip", source: source)
        XCTAssertEqual(admitted.id, ticket.id)
    }

    func testAQueuedDownloadIsRestoredAsOnePutOffForLater() async throws {
        let c = coordinator()
        c.maxConcurrent = 1
        _ = c.begin(suggestedName: "first.bin", sourceURL: source, cancel: {})
        let waiting = Task { await c.admitTicket(filename: "second.bin", source: URL(string: "https://files.test/second.bin")) }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(c.waiting.count, 1)
        let after = coordinator()
        XCTAssertEqual(after.scheduled.count, 1, "its place in line went with the old session, so it waits to be started again from its address")
        XCTAssertEqual(after.scheduled.first?.filename, "second.bin")
        c.cancelWaiting(c.waiting[0].id)
        _ = await waiting.value
    }

    func testADownloadFoundPartWayAfterTheAppWasClosedIsReportedAndNeverRestartsItself() {
        let first = coordinator()
        let started = first.begin(suggestedName: "half.bin", sourceURL: source, cancel: {})
        let second = coordinator()
        var autoStarted = false
        second.starter = { _ in autoStarted = true }
        second.resumer = { _ in autoStarted = true }
        second.hasHost = { true }
        XCTAssertEqual(second.ledger.record(started.id)?.state, .recoveryRequired)
        XCTAssertEqual(second.failures.first?.id, started.id)
        XCTAssertTrue(second.failures.first?.canRetry == true)
        XCTAssertTrue(second.interrupted.isEmpty)
        XCTAssertFalse(autoStarted)
    }

    func testAPrivateDownloadLeavesNoRecordOnDisk() {
        let c = coordinator()
        let started = c.begin(suggestedName: "secret.bin", sourceURL: source, isPrivate: true, cancel: {})
        c.ledger.flush()
        XCTAssertEqual(DownloadTaskStore.open(folder: folder).counts().tasks, 0)
        c.finish(started.id, source: source)
        c.ledger.flush()
        XCTAssertEqual(DownloadTaskStore.open(folder: folder).counts().tasks, 0)
    }

    func testNoPasswordOrTokenInAHeaderIsEverWritten() throws {
        let c = coordinator()
        let withPassword = URL(string: "https://user:hunter2@files.test/f.zip")
        let started = c.begin(suggestedName: "f.zip", sourceURL: withPassword, cancel: {})
        c.interrupt(started.id, resumeData: Data("resume".utf8), source: withPassword)
        c.ledger.flush()
        DownloadTaskStore.close(folder: folder)
        let raw = try Data(contentsOf: folder.appendingPathComponent("downloads.sqlite"))
        XCTAssertNil(raw.range(of: Data("hunter2".utf8)), "the password never reaches the file")
    }

    func testAnotherProfileDoesNotSeeThisProfilesDownloads() {
        let mine = coordinator(profile: "default")
        let started = mine.begin(suggestedName: "mine.bin", sourceURL: source, cancel: {})
        mine.interrupt(started.id, resumeData: Data("r".utf8), source: source)
        let theirs = coordinator(profile: "work")
        XCTAssertTrue(theirs.interrupted.isEmpty)
        XCTAssertNil(theirs.ledger.record(started.id))
    }

    func testASavedDestinationOutsideTheDownloadsFolderIsNotBelieved() {
        let store = DownloadTaskStore.open(folder: folder)
        var r = DownloadTaskRecord(protocolID: .webKit, profile: "default", source: DownloadSourceRef(url: source), filename: "x.bin")
        r.state = .paused
        r.transfer.resumeAvailable = true
        r.file.destinationPath = "/etc/passwd"
        store.save(r, resumeData: .some(Data("r".utf8)))
        store.flush()
        let c = coordinator()
        XCTAssertNil(c.ledger.record(r.id)?.file.destinationPath)
        XCTAssertTrue(c.events.contains { $0.contains("outside the downloads folder") })
    }

    func testRapidPauseResumeCancelEndsCancelledAndTheDatabaseAgrees() {
        let c = coordinator()
        let started = c.begin(suggestedName: "a.bin", sourceURL: source, cancel: {}, suspend: { _ in })
        c.pause(started.id)
        XCTAssertEqual(c.ledger.record(started.id)?.state, .pausing)
        c.resume(started.id)
        XCTAssertEqual(c.ledger.record(started.id)?.state, .pausing, "a resume asked for before the pause was answered is refused")
        c.cancel(started.id)
        XCTAssertEqual(c.ledger.record(started.id)?.state, .cancelled)
        c.ledger.flush()
        let stored = DownloadTaskStore.open(folder: folder).loadAll(profile: "default").records.first { $0.id == started.id }
        XCTAssertEqual(stored?.state, .cancelled)
    }

    func testProgressUpdatesAreNotWrittenEveryTick() {
        let c = coordinator()
        let started = c.begin(suggestedName: "a.bin", sourceURL: source, cancel: {})
        c.ledger.flush()
        for i in 1...200 { c.ledger.progress(started.id, completed: Int64(i), total: 1000) }
        c.ledger.flush()
        XCTAssertEqual(c.ledger.record(started.id)?.transfer.completedBytes, 200, "kept in memory at once")
        let stored = DownloadTaskStore.open(folder: folder).loadAll(profile: "default").records.first { $0.id == started.id }
        XCTAssertLessThan(stored?.transfer.completedBytes ?? 0, 200, "but written to disk a couple of times at most")
    }

    func testManyWritersAtOnceLoseNothing() async {
        let store = DownloadTaskStore.open(folder: folder)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<40 {
                group.addTask {
                    var r = DownloadTaskRecord(protocolID: .webKit, profile: "default", source: DownloadSourceRef(url: nil), filename: "f\(i).bin")
                    r.state = .queued
                    store.save(r)
                }
            }
        }
        store.flush()
        XCTAssertEqual(store.counts().tasks, 40)
    }
}

@MainActor
final class DownloadLedgerBoundsTests: XCTestCase {
    func testFinishedRecordsAreNotKeptInMemoryWithoutLimit() {
        let ledger = DownloadLedger(profile: "default")      // no database: memory only
        for i in 0..<(DownloadTaskStore.keepCompleted + DownloadTaskStore.keepFailedOrCancelled + 50) {
            let r = ledger.create(protocolID: .webKit, source: nil, filename: "f\(i)", isPrivate: false)
            ledger.apply(.queued, to: r.id); ledger.apply(.started, to: r.id); ledger.apply(.running, to: r.id); ledger.apply(.verifying, to: r.id); ledger.apply(.completed(.unknown), to: r.id)
        }
        XCTAssertLessThanOrEqual(ledger.records.count, DownloadTaskStore.keepCompleted + DownloadTaskStore.keepFailedOrCancelled)
    }

    func testAnIllegalMoveIsRefusedAndReportedAndChangesNothing() {
        let ledger = DownloadLedger(profile: "default")
        var problems: [String] = []
        ledger.onProblem = { problems.append($0) }
        let r = ledger.create(protocolID: .webKit, source: nil, filename: "x", isPrivate: false)
        XCTAssertNil(ledger.apply(.completed(.verified), to: r.id), "created cannot jump to completed")
        XCTAssertEqual(ledger.record(r.id)?.state, .created)
        XCTAssertEqual(problems.count, 1)
        XCTAssertNil(ledger.apply(.queued, to: UUID()), "an unknown task is refused too")
    }
}
