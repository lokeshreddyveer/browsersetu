import XCTest
import SQLite3
@testable import Browser_Setu

// MARK: Persistence (no server)

@MainActor
final class SchedulerPersistenceTests: XCTestCase {
    private var folder: URL!
    override func setUp() { super.setUp(); folder = FileManager.default.temporaryDirectory.appendingPathComponent("sched-\(UUID().uuidString)") }
    override func tearDown() { DownloadTaskStore.close(folder: folder); try? FileManager.default.removeItem(at: folder); super.tearDown() }

    func testADatabaseAtVersionTwoGainsTheSchedulerColumnsAndKeepsEveryTask() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("downloads.sqlite")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &handle), SQLITE_OK)
        let id = UUID().uuidString
        sqlite3_exec(handle, """
        CREATE TABLE meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
        CREATE TABLE tasks (id TEXT PRIMARY KEY NOT NULL, protocol TEXT NOT NULL, profile TEXT NOT NULL,
          state TEXT NOT NULL CHECK (state IN ('created','resolving','queued','scheduled','starting','running','pausing','paused','resuming','verifying','retrying','completed','failed','cancelled','recoveryRequired')),
          priority INTEGER NOT NULL, queue_order INTEGER NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL, started_at REAL, completed_at REAL, scheduled_at REAL,
          attempt INTEGER NOT NULL DEFAULT 0, retry_count INTEGER NOT NULL DEFAULT 0, source_url TEXT, source_host TEXT, filename TEXT NOT NULL, destination_path TEXT, temporary_path TEXT,
          integrity TEXT NOT NULL DEFAULT 'unknown', total_bytes INTEGER, completed_bytes INTEGER NOT NULL DEFAULT 0, resume_available INTEGER NOT NULL DEFAULT 0, failure_code TEXT,
          failure_reason TEXT, failure_retryable INTEGER, engine_metadata TEXT, record_version INTEGER NOT NULL DEFAULT 1);
        CREATE TABLE task_resume (task_id TEXT PRIMARY KEY NOT NULL REFERENCES tasks (id) ON DELETE CASCADE, data BLOB NOT NULL);
        CREATE TABLE task_pieces (task_id TEXT NOT NULL REFERENCES tasks (id) ON DELETE CASCADE, idx INTEGER NOT NULL, start_byte INTEGER NOT NULL, end_byte INTEGER NOT NULL,
          state TEXT NOT NULL CHECK (state IN ('pending', 'done')), checksum TEXT, session INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (task_id, idx), CHECK (start_byte >= 0 AND end_byte >= start_byte));
        INSERT INTO tasks (id, protocol, profile, state, priority, queue_order, created_at, updated_at, filename, engine_metadata) VALUES ('\(id)', 'http', 'default', 'paused', 2, 7, 1, 1, 'kept.bin', '{"etag":"\\"e\\""}');
        PRAGMA user_version = 2;
        """, nil, nil, nil)
        sqlite3_close(handle)
        let store = DownloadTaskStore.open(folder: folder)
        XCTAssertEqual(store.outcome, .opened)
        var record = try XCTUnwrap(store.loadAll(profile: "default").records.first)
        XCTAssertEqual(record.file.filename, "kept.bin"); XCTAssertEqual(record.priority, .high); XCTAssertEqual(record.queueOrder, 7)
        XCTAssertEqual(record.engineMetadata["etag"], "\"e\"")
        XCTAssertNil(record.enqueuedAt); XCTAssertNil(record.retryAt)
        record.enqueuedAt = Date(timeIntervalSince1970: 1_800_000_000); record.retryAt = Date(timeIntervalSince1970: 1_800_000_123)
        store.save(record); store.flush()
        let again = try XCTUnwrap(store.loadAll(profile: "default").records.first)
        XCTAssertEqual(again.enqueuedAt, record.enqueuedAt); XCTAssertEqual(again.retryAt, record.retryAt)
    }

    func testSchedulerStateDoesNotCompeteWithTheEngineForMetadataRoom() throws {
        let store = DownloadTaskStore.open(folder: folder)
        var record = DownloadTaskRecord(protocolID: .http, profile: "default", source: DownloadSourceRef(url: nil), filename: "full.bin")
        for i in 0..<DownloadEngineMetadata.maxEntries { record.engineMetadata["k\(i)"] = "v" }
        record.enqueuedAt = Date(timeIntervalSince1970: 5); record.retryAt = Date(timeIntervalSince1970: 9)
        store.save(record); store.flush()
        let read = try XCTUnwrap(store.loadAll(profile: "default").records.first)
        XCTAssertEqual(read.engineMetadata.count, DownloadEngineMetadata.maxEntries, "all sixteen survived")
        XCTAssertEqual(read.enqueuedAt, Date(timeIntervalSince1970: 5)); XCTAssertEqual(read.retryAt, Date(timeIntervalSince1970: 9))
        XCTAssertTrue(store.takeFailures().isEmpty, "and nothing was reported lost")
    }

    func testAnythingLeftOutOfSavedMetadataIsReported() throws {
        let store = DownloadTaskStore.open(folder: folder)
        var record = DownloadTaskRecord(protocolID: .http, profile: "default", source: DownloadSourceRef(url: nil), filename: "over.bin")
        for i in 0..<(DownloadEngineMetadata.maxEntries + 2) { record.engineMetadata["k\(i)"] = "v" }
        record.engineMetadata["bad key!"] = "x"
        store.save(record); store.flush()
        let reported = store.takeFailures().joined(separator: " ")
        XCTAssertTrue(reported.contains("over.bin"), reported)
        XCTAssertTrue(reported.contains("overCapacity") && reported.contains("invalidKey"), reported)
    }

    func testTheHoldIsSavedAsTheModeItIs() throws {
        let ledger = DownloadLedger(profile: "default")
        _ = ledger.attach(folder: folder, safeName: { $0 })
        XCTAssertNil(ledger.loadHold())
        ledger.saveHold(.distantFuture); ledger.flush()
        XCTAssertEqual(ledger.loadHold(), .distantFuture, "until I resume")
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        ledger.saveHold(when); ledger.flush()
        XCTAssertEqual(ledger.loadHold(), when)
        ledger.saveHold(nil); ledger.flush()
        XCTAssertNil(ledger.loadHold())
    }

    func testTheHoldOfOneProfileIsNotAnotherProfilesHold() throws {
        let a = DownloadLedger(profile: "work"); _ = a.attach(folder: folder, safeName: { $0 })
        a.saveHold(.distantFuture); a.flush()
        let b = DownloadLedger(profile: "home"); _ = b.attach(folder: folder, safeName: { $0 })
        XCTAssertNil(b.loadHold())
    }

    func testPriorityAndWaitingTimeSurviveReloading() throws {
        let ledger = DownloadLedger(profile: "default"); _ = ledger.attach(folder: folder, safeName: { $0 })
        let r = ledger.create(protocolID: .http, source: URL(string: "https://example.com/a.bin"), filename: "a.bin", isPrivate: false, priority: .high)
        _ = ledger.apply(.queued, to: r.id); ledger.flush()
        let reopened = DownloadLedger(profile: "default"); _ = reopened.attach(folder: folder, safeName: { $0 })
        let back = try XCTUnwrap(reopened.record(r.id))
        XCTAssertEqual(back.priority, .high)
        XCTAssertEqual(back.state, .scheduled, "a start that was waiting is put off, to go back in line, not left as a dead 'queued'")
        XCTAssertNotNil(back.enqueuedAt, "and how long it had waited is kept")
    }

    func testARetryThatWasPlannedWhenTheAppEndedIsShownNotLeftInvisible() throws {
        let ledger = DownloadLedger(profile: "default"); _ = ledger.attach(folder: folder, safeName: { $0 })
        let r = ledger.create(protocolID: .http, source: URL(string: "https://example.com/r.bin"), filename: "r.bin", isPrivate: false)
        for e in [DownloadEvent.queued, .started, .running, .retryPlanned] { XCTAssertNotNil(ledger.apply(e, to: r.id), e.name) }
        ledger.update(r.id) { $0.retryAt = Date().addingTimeInterval(30) }
        ledger.flush()
        let reopened = DownloadLedger(profile: "default"); _ = reopened.attach(folder: folder, safeName: { $0 })
        XCTAssertEqual(reopened.record(r.id)?.state, .recoveryRequired, "it does not restart by itself, and it is not lost")
        XCTAssertEqual(reopened.record(r.id)?.retryCount, 1)
    }
}

// MARK: Scheduler with the real engines (fixture server on port 18766)

@MainActor
final class Phase5IntegrationTests: XCTestCase {
    private static let port = 18766
    private var root: URL!
    private var folder: URL!
    private var downloads: URL!
    private var savedOverride: URL?
    private var savedScale = 1.0
    private var clock: ManualClock!
    private var c: DownloadCoordinator!
    private let mib = 1 << 20

    override func setUp() async throws {
        try await super.setUp()
        let reachable = (try? await URLSession(configuration: .ephemeral).data(from: URL(string: "http://127.0.0.1:\(Self.port)/")!)) != nil
        XCTAssertTrue(reachable, "the download fixture server is not running on port \(Self.port): run these tests through the BrowserSetuMac scheme")
        guard reachable else { throw XCTSkip("fixture server not running") }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("phase5-\(UUID().uuidString)")
        folder = root.appendingPathComponent("store")
        downloads = root.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        savedOverride = DownloadCoordinator.directoryOverride
        DownloadCoordinator.directoryOverride = downloads
        savedScale = HTTPRetrySchedule.delayScale
        HTTPRetrySchedule.delayScale = 1
        clock = ManualClock()
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

    private func coordinator(clock override: ManualClock? = nil) -> DownloadCoordinator {
        let coordinator = DownloadCoordinator(clock: override ?? clock)
        coordinator.profileName = "default"
        coordinator.store = folder
        return coordinator
    }
    private func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(Self.port)\(path)")! }
    private func fetch(_ path: String) async throws -> Data { try await URLSession(configuration: .ephemeral).data(from: url(path)).0 }
    /// `method` narrows the count: a task started from an address alone first asks the server about the file (HEAD) and then fetches it (GET), which is one start, not two.
    private func requests(_ prefix: String, method: String? = nil) async -> Int {
        let data = (try? await fetch("/_log")) ?? Data()
        let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        return entries.filter { (($0["path"] as? String) ?? "").hasPrefix(prefix) && (method == nil || ($0["method"] as? String) == method) }.count
    }
    @discardableResult
    private func wait(_ id: UUID, for states: Set<DownloadState>, seconds: Double = 40) async -> DownloadTaskRecord? {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let record = c.ledger.record(id), states.contains(record.state) { return record }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return c.ledger.record(id)
    }
    private func waitUntil(_ seconds: Double = 20, _ condition: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if await condition() { return true }; try? await Task.sleep(for: .milliseconds(30)) }
        return await condition()
    }
    private func plantQueued(_ path: String, name: String, priority: DownloadPriority = .normal) -> UUID {
        let record = c.ledger.create(protocolID: .http, source: url(path), filename: name, isPrivate: false, priority: priority)
        c.ledger.update(record.id) { $0.engineMetadata["origin"] = DownloadRequestOrigin.user.rawValue }
        _ = c.ledger.apply(.queued, to: record.id)
        c.ledger.flush()
        return record.id
    }

    // MARK: Retry

    func testARetryWaitsForItsTimeThenQueuesAgainAndTriesOnce() async throws {
        let id = try await c.http.start(url: url("/status/503"))
        let planned = await wait(id, for: [.retrying, .failed])
        XCTAssertEqual(planned?.state, .retrying)
        let due = try XCTUnwrap(planned?.retryAt, "the due time is saved with the task")
        XCTAssertEqual(due.timeIntervalSince(clock.now), 5, accuracy: 1.01, "five seconds, spread by at most a fifth")
        XCTAssertTrue(c.scheduler.isScheduled(id), "one timer, owned by the scheduler")
        let before = await requests("/status")
        clock.advance(by: 3)
        try? await Task.sleep(for: .milliseconds(300))
        let early = await requests("/status")
        XCTAssertEqual(early, before, "not before its time")
        clock.advance(by: 4)
        let again = await waitUntil { await self.requests("/status") == before + 1 }
        XCTAssertTrue(again, "tried again once its time came")
        try? await Task.sleep(for: .milliseconds(300))
        let total = await requests("/status")
        XCTAssertEqual(total, before + 1, "exactly once")
        XCTAssertEqual(ConnectionBudget.shared.holding(task: id) <= 1, true)
    }

    func testACancelledRetryNeverRestartsAndLeavesNoTimer() async throws {
        let id = try await c.http.start(url: url("/status/503"))
        _ = await wait(id, for: [.retrying])
        let before = await requests("/status")
        c.cancel(id)
        XCTAssertEqual(c.http.pendingRetries, 0)
        XCTAssertFalse(c.scheduler.isScheduled(id), "its timer went with it")
        XCTAssertFalse(c.scheduler.contains(id))
        clock.advance(by: 7200)
        try? await Task.sleep(for: .milliseconds(400))
        let after = await requests("/status")
        XCTAssertEqual(after, before)
        XCTAssertEqual(c.ledger.record(id)?.state, .cancelled)
        XCTAssertEqual(ConnectionBudget.shared.holding(task: id), 0)
    }

    func testAPermanentFailureIsNeverRetried() async throws {
        let id = try await c.http.start(url: url("/status/404"))
        let record = await wait(id, for: [.failed, .retrying])
        XCTAssertEqual(record?.state, .failed)
        XCTAssertEqual(c.http.pendingRetries, 0)
        XCTAssertEqual(c.scheduler.scheduledCount, 0)
        let before = await requests("/status")
        clock.advance(by: 7200)
        try? await Task.sleep(for: .milliseconds(300))
        let after = await requests("/status")
        XCTAssertEqual(after, before)
        XCTAssertEqual(ConnectionBudget.shared.holding(task: id), 0, "and no connection is held for it")
    }

    func testARetryWaitsForAFreePlaceBehindARunningDownloadAndTakesItWhenItFrees() async throws {
        c.maxConcurrent = 1
        let a = try await c.http.start(url: url("/status/503"))
        _ = await wait(a, for: [.retrying])                       // it gave its place back while it waits
        let b = try await c.http.start(url: url("/throttle/\(6 * mib)?bps=1500000"))
        _ = await wait(b, for: [.running])
        let before = await requests("/status")
        clock.advance(by: 7)                                       // the retry is due, and the only place is taken
        XCTAssertTrue(c.scheduler.contains(a), "it is in line")
        XCTAssertEqual(c.scheduler.entries.first { $0.id == a }?.kind, .retry)
        XCTAssertEqual(c.queuePosition(of: a), 1)
        XCTAssertEqual(c.queueNote, "Waiting for a free place")
        try? await Task.sleep(for: .milliseconds(300))
        let waitingCount = await requests("/status")
        XCTAssertEqual(waitingCount, before, "it did not start past the limit")
        c.cancel(b)                                                // the place frees
        let started = await waitUntil { await self.requests("/status") == before + 1 }
        XCTAssertTrue(started, "and then it took the place")
    }

    // MARK: Connections

    func testEveryKindOfDownloadGivesItsConnectionsBack() async throws {
        let single = try await c.http.start(url: url("/file/\(2 * mib)"))
        _ = await wait(single, for: [.completed])
        // Per task, not the process-wide count: the budget is shared by every coordinator in the process, so a transfer left running by another test would inflate a global count.
        XCTAssertEqual(ConnectionBudget.shared.holding(task: single), 0, "one transfer, given back")
        let multi = try await c.http.start(url: url("/file/\(24 * mib)"))
        _ = await wait(multi, for: [.completed])
        XCTAssertEqual(ConnectionBudget.shared.holding(task: multi), 0, "in pieces, every one given back")
        XCTAssertEqual(c.scheduler.reserved, 0)
    }

    func testARunningTransferHoldsOneConnectionFromTheSharedBudget() async throws {
        let id = try await c.http.start(url: url("/throttle/\(4 * mib)?bps=1000000"))
        _ = await wait(id, for: [.running])
        XCTAssertEqual(ConnectionBudget.shared.holding(task: id), 1)
        c.cancel(id)
        XCTAssertEqual(ConnectionBudget.shared.holding(task: id), 0)
    }

    // MARK: Relaunch

    func testQueuedDownloadsComeBackAfterARelaunchAndStartExactlyOnce() async throws {
        let id = plantQueued("/file/2000", name: "q.bin", priority: .high)
        c = coordinator()
        XCTAssertEqual(c.ledger.record(id)?.priority, .high, "priority restored")
        let done = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(done?.state, .completed, done?.failure?.reason ?? "")
        let first = await requests("/file/2000", method: "GET")
        XCTAssertEqual(first, 1)
        c.ledger.flush()
        c = coordinator()                                          // and again
        try? await Task.sleep(for: .milliseconds(500))
        let second = await requests("/file/2000", method: "GET")
        XCTAssertEqual(second, 1, "no second start")
        XCTAssertEqual(c.ledger.record(id)?.state, .completed)
    }

    func testAPausedQueueIsStillPausedAfterARelaunch() async throws {
        c.holdQueue(until: .distantFuture)
        let id = plantQueued("/file/3000", name: "held.bin")
        c = coordinator()
        XCTAssertEqual(c.heldUntil, .distantFuture)
        try? await Task.sleep(for: .milliseconds(700))
        let sent = await requests("/file/3000")
        XCTAssertEqual(sent, 0, "nothing started under a pause the person asked for")
        XCTAssertEqual(c.ledger.record(id)?.state, .scheduled)
        c.resumeAll()
        let done = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(done?.state, .completed, done?.failure?.reason ?? "")
    }

    func testATimedHoldThatEndedWhileTheAppWasClosedIsClearedAndWhatWaitedStarts() async throws {
        c.holdQueue(until: clock.now.addingTimeInterval(3600))
        let id = plantQueued("/file/4000", name: "later.bin")
        let later = ManualClock(start: clock.now.addingTimeInterval(7200))
        c = coordinator(clock: later)
        XCTAssertNil(c.heldUntil)
        XCTAssertNil(c.ledger.loadHold())
        let done = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(done?.state, .completed, done?.failure?.reason ?? "")
    }

    func testAScheduledDownloadKeepsItsPriorityAndMomentAcrossARelaunchAndStartsOnTime() async throws {
        let due = clock.now.addingTimeInterval(3600)
        let id = try XCTUnwrap(c.scheduleDownload(url: url("/file/5000"), at: due, priority: .high))
        XCTAssertTrue(c.scheduler.isScheduled(id))
        c.ledger.flush()
        c = coordinator()
        let item = try XCTUnwrap(c.scheduled.first { $0.id == id })
        XCTAssertEqual(item.priority, .high)
        XCTAssertEqual(try XCTUnwrap(item.dueAt).timeIntervalSince1970, due.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertTrue(c.scheduler.isScheduled(id), "its timer is set again")
        let early = await requests("/file/5000")
        XCTAssertEqual(early, 0)
        clock.advance(by: 3601)
        let done = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(done?.state, .completed, done?.failure?.reason ?? "")
        let sent = await requests("/file/5000")
        XCTAssertEqual(sent, 2, "once to ask the server for the name and size (Phase 7), once for the file: it did not start twice")
    }

    func testAStartDueWhileClosedGoesAheadIfRecentAndWaitsForThePersonIfOld() async throws {
        let old = try XCTUnwrap(c.scheduleDownload(url: url("/file/6111"), at: clock.now.addingTimeInterval(600)))
        let recent = try XCTUnwrap(c.scheduleDownload(url: url("/file/6222"), at: clock.now.addingTimeInterval(5 * 3600)))
        c.ledger.flush()
        let later = ManualClock(start: clock.now.addingTimeInterval(10 * 3600))
        c = coordinator(clock: later)
        let done = await wait(recent, for: [.completed, .failed])
        XCTAssertEqual(done?.state, .completed, "five hours late is still expected: " + (done?.failure?.reason ?? ""))
        XCTAssertTrue(c.overdue.contains(old), "nine hours late is shown, not run behind the person's back")
        XCTAssertTrue(c.scheduled.contains { $0.id == old })
        let sentOld = await requests("/file/6111")
        XCTAssertEqual(sentOld, 0)
        c.startScheduled(old)
        let ran = await wait(old, for: [.completed, .failed])
        XCTAssertEqual(ran?.state, .completed, ran?.failure?.reason ?? "")
        XCTAssertFalse(c.overdue.contains(old))
    }

    func testAMacThatSleptThroughASchedulePicksItUpOnWake() async throws {
        let id = try XCTUnwrap(c.scheduleDownload(url: url("/file/7000"), at: clock.now.addingTimeInterval(1800)))
        clock.jumpWall(by: 3600)                                   // asleep for an hour: the timer was not told
        let before = await requests("/file/7000")
        XCTAssertEqual(before, 0)
        c.reconcileAfterWakeOrClockChange()
        let done = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(done?.state, .completed, done?.failure?.reason ?? "")
        let sent = await requests("/file/7000")
        XCTAssertEqual(sent, 2, "once to ask the server for the name and size, once for the file: the schedule did not fire twice")
    }

    func testReschedulingAndCancellingAScheduledStart() async throws {
        let id = try XCTUnwrap(c.scheduleDownload(url: url("/file/8000"), at: clock.now.addingTimeInterval(600)))
        c.reschedule(id, at: clock.now.addingTimeInterval(7200))
        XCTAssertEqual(c.scheduler.scheduledCount, 1, "one start time")
        clock.advance(by: 900)
        try? await Task.sleep(for: .milliseconds(300))
        let early = await requests("/file/8000")
        XCTAssertEqual(early, 0, "the old time no longer fires")
        c.removeScheduled(id)
        clock.advance(by: 86_400)
        try? await Task.sleep(for: .milliseconds(300))
        let after = await requests("/file/8000")
        XCTAssertEqual(after, 0)
        XCTAssertEqual(c.ledger.record(id)?.state, .cancelled)
        XCTAssertEqual(c.scheduler.scheduledCount, 0)
    }

    func testACrashedDownloadIsNeverStartedByTheSchedule() async throws {
        let size = 32 * mib
        let id = try await c.http.start(url: url("/throttle/\(size)?bps=1000000"))
        _ = await wait(id, for: [.running])
        try? await Task.sleep(for: .milliseconds(800))
        c.ledger.flush()
        c.http.simulateCrash(id)
        let sentBefore = await requests("/throttle")
        c = coordinator(clock: ManualClock(start: clock.now.addingTimeInterval(86_400)))
        try? await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(c.ledger.record(id)?.state, .recoveryRequired)
        let sentAfter = await requests("/throttle")
        XCTAssertEqual(sentAfter, sentBefore, "nothing restarted it")
    }

    // MARK: Queue through the coordinator

    func testTheLineAndTheLimitAreTheCoordinatorsToo() async throws {
        c.maxConcurrent = 1
        let first = try await c.http.start(url: url("/throttle/\(3 * mib)?bps=1000000"))
        _ = await wait(first, for: [.running])
        let second = Task { try await self.c.http.start(url: self.url("/file/1500")) }
        let queued = await waitUntil { self.c.waiting.count == 1 }
        XCTAssertTrue(queued)
        XCTAssertEqual(c.waiting.first?.position, 1)
        XCTAssertEqual(c.queueNote, "Waiting for a free place")
        let id = try await second.value
        let done = await wait(id, for: [.completed, .failed], seconds: 60)
        XCTAssertEqual(done?.state, .completed, done?.failure?.reason ?? "")
        XCTAssertTrue(c.waiting.isEmpty)
    }

    func testCancellingWhileWaitingStartsNothing() async throws {
        c.maxConcurrent = 1
        let first = try await c.http.start(url: url("/throttle/\(3 * mib)?bps=1000000"))
        _ = await wait(first, for: [.running])
        let pending = Task { try await self.c.http.start(url: self.url("/file/1600")) }
        _ = await waitUntil { self.c.waiting.count == 1 }
        let waitingID = try XCTUnwrap(c.waiting.first?.id)
        c.cancelWaiting(waitingID)
        _ = try? await pending.value
        c.cancel(first)
        try? await Task.sleep(for: .milliseconds(500))
        let sent = await requests("/file/1600")
        XCTAssertEqual(sent, 0, "it was cancelled before it began")
        XCTAssertEqual(c.ledger.record(waitingID)?.state, .cancelled)
        XCTAssertEqual(ConnectionBudget.shared.holding(task: waitingID), 0)
    }

    func testAnUrgentDownloadGoesBeforeAnEarlierNormalOneButNeverPreemptsARunningOne() async throws {
        c.maxConcurrent = 1
        let running = try await c.http.start(url: url("/throttle/\(3 * mib)?bps=1000000"))
        _ = await wait(running, for: [.running])
        let normal = Task { try await self.c.http.start(url: self.url("/file/1700")) }
        _ = await waitUntil { self.c.waiting.count == 1 }
        let urgent = Task { try await self.c.http.start(url: self.url("/file/1800")) }
        _ = await waitUntil { self.c.waiting.count == 2 }
        let urgentID = try XCTUnwrap(c.waiting.last?.id)
        c.setPriority(urgentID, .high)
        XCTAssertEqual(c.waiting.first?.id, urgentID, "it moved to the front")
        XCTAssertEqual(c.ledger.record(running)?.state, .running, "and the running one was left alone")
        XCTAssertEqual(c.ledger.record(urgentID)?.priority, .high, "the choice is saved")
        _ = try? await normal.value; _ = try? await urgent.value
        _ = await wait(urgentID, for: [.completed], seconds: 60)
    }
}

// MARK: Coordinator without a server

@MainActor
final class CoordinatorSchedulingTests: XCTestCase {
    private var folder: URL!
    private var clock: ManualClock!
    private var c: DownloadCoordinator!
    private var savedOverride: URL?

    override func setUp() async throws {
        try await super.setUp()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("coord5-\(UUID().uuidString)")
        savedOverride = DownloadCoordinator.directoryOverride
        DownloadCoordinator.directoryOverride = folder.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: DownloadCoordinator.directoryOverride!, withIntermediateDirectories: true)
        clock = ManualClock()
        c = DownloadCoordinator(clock: clock)
        c.profileName = "default"
        c.store = folder
    }
    override func tearDown() async throws {
        DownloadCoordinator.directoryOverride = savedOverride
        DownloadTaskStore.close(folder: folder)
        try? FileManager.default.removeItem(at: folder)
        try await super.tearDown()
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(60)) }

    func testBeginningATaskNeverLetsTheNextOneStartPastTheLimit() async {
        c.maxConcurrent = 1
        let first = await c.admitTicket(filename: "a.bin", source: URL(string: "https://example.com/a.bin"))
        XCTAssertTrue(first.admitted)
        var second: (admitted: Bool, id: UUID)?
        Task { second = await self.c.admitTicket(filename: "b.bin", source: URL(string: "https://example.com/b.bin")) }
        await settle()
        XCTAssertEqual(c.waiting.count, 1)
        _ = c.begin(suggestedName: "a.bin", sourceURL: URL(string: "https://example.com/a.bin"), taskID: first.id, cancel: {})
        await settle()
        XCTAssertEqual(c.active.count, 1)
        XCTAssertEqual(c.waiting.count, 1, "the second is still waiting: one place, one task")
        XCTAssertNil(second)
        XCTAssertEqual(c.scheduler.reserved, 0)
        c.cancel(first.id)
        await settle()
        XCTAssertEqual(second?.admitted, true, "and takes the place when the first ends")
    }

    func testAWebKitRetryTimerSurvivesTheFailureThatPlannedIt() {
        var started: [URL] = []
        c.starter = { started.append($0) }
        let source = URL(string: "https://example.com/again.bin")!
        let started1 = c.begin(suggestedName: "again.bin", sourceURL: source, cancel: {})
        XCTAssertTrue(c.planRetry(for: source, error: URLError(.timedOut), resumeData: nil, id: started1.id))
        c.fail(started1.id, source: source, error: URLError(.timedOut), willRetry: true)       // what the engine does next
        XCTAssertEqual(c.ledger.record(started1.id)?.state, .retrying)
        XCTAssertTrue(c.scheduler.isScheduled(started1.id), "the timer was not cancelled by the cleanup")
        clock.advance(by: 7)
        XCTAssertEqual(started, [source])
    }

    func testPausingEverythingHoldsTheLineBeforeAnythingStops() async {
        c.maxConcurrent = 1
        let first = await c.admitTicket(filename: "a.bin", source: URL(string: "https://example.com/a.bin"))
        _ = c.begin(suggestedName: "a.bin", sourceURL: URL(string: "https://example.com/a.bin"), taskID: first.id, cancel: {})
        Task { _ = await self.c.admitTicket(filename: "b.bin", source: URL(string: "https://example.com/b.bin")) }
        await settle()
        c.pauseAll()
        XCTAssertEqual(c.heldUntil, .distantFuture, "held at once")
        c.cancel(first.id)                                          // a place frees
        await settle()
        XCTAssertEqual(c.waiting.count, 1, "and the waiting one did not take it")
        XCTAssertTrue(c.active.isEmpty)
    }

    func testEndingATimedHoldStartsOnlyWhatItPutOff() async {
        var started: [URL] = []
        c.starter = { started.append($0) }
        c.holdQueue(until: clock.now.addingTimeInterval(600))
        let heldURL = URL(string: "https://example.com/held.bin")!
        Task { _ = await self.c.admitTicket(filename: "held.bin", source: heldURL) }
        await settle()
        let later = c.scheduleDownload(url: URL(string: "https://example.com/tenhours.bin")!, at: clock.now.addingTimeInterval(36_000))
        XCTAssertNotNil(later)
        clock.advance(by: 601)
        XCTAssertEqual(started, [heldURL], "what the hold put off")
        XCTAssertTrue(c.scheduled.contains { $0.id == later }, "a start the person set for ten hours from now is still set for then")
        XCTAssertTrue(c.scheduler.isScheduled(later!))
    }

    func testADueStartWithNoPageOpenWaitsListedAndGoesWhenAPageExists() async {
        var started: [URL] = []
        c.starter = { started.append($0) }
        c.hasHost = { false }
        c.holdQueue(until: clock.now.addingTimeInterval(60))
        let source = URL(string: "https://example.com/needspage.bin")!
        Task { _ = await self.c.admitTicket(filename: "needspage.bin", source: source) }
        await settle()
        clock.advance(by: 61)
        XCTAssertEqual(started, [])
        let id = try! XCTUnwrap(c.scheduled.first?.id)
        c.hasHost = { true }
        c.startScheduled(id)
        XCTAssertEqual(started, [source], "it was kept, and went once a page existed")
    }

    func testAskingForTheSameTaskTwiceDoesNotLeaveTheFirstCallerWaitingForEver() async {
        c.maxConcurrent = 0
        let id = UUID()
        let source = URL(string: "https://example.com/twice.bin")!
        var firstResult: Bool?
        c.reserveTaskID(id, for: source)
        Task { firstResult = await self.c.admitTicket(filename: "twice.bin", source: source).admitted }
        await settle()
        c.reserveTaskID(id, for: source)
        Task { _ = await self.c.admitTicket(filename: "twice.bin", source: source) }
        await settle()
        XCTAssertEqual(firstResult, false, "released, not stranded")
        XCTAssertEqual(c.waiting.count, 1, "and the task is in line once")
    }

    func testAScheduleThatCouldNotBeMadeLeavesNoRecordBehind() {
        let before = c.ledger.records.count
        XCTAssertNil(c.scheduleDownload(url: URL(string: "ftp://example.com/x")!, at: clock.now))
        XCTAssertEqual(c.ledger.records.count, before)
    }

    func testAPutOffDownloadWithNothingToStartItWithStaysListed() {
        c.holdQueue(until: .distantFuture)
        let source = URL(string: "https://example.com/stay.bin")!
        Task { _ = await c.admitTicket(filename: "stay.bin", source: source) }
        let listed = expectation(description: "listed")
        Task { while c.scheduled.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }; listed.fulfill() }
        wait(for: [listed], timeout: 5)
        c.holdQueue(until: nil)
        c.startScheduledNow()          // there is no engine hook to start it with
        XCTAssertEqual(c.scheduled.map(\.filename), ["stay.bin"], "it was not dropped")
    }

    func testAWebKitRetryUsesTheSchedulersTimerAndTheSharedDelayAndFiresOnce() {
        var started: [URL] = []
        c.starter = { started.append($0) }
        let id = UUID()
        let source = URL(string: "https://example.com/retry.bin")!
        c.ledger.create(id: id, protocolID: .webKit, source: source, filename: "retry.bin", isPrivate: false)
        XCTAssertTrue(c.planRetry(for: source, error: URLError(.timedOut), resumeData: nil, id: id))
        let due = c.ledger.record(id)?.retryAt
        XCTAssertNotNil(due, "saved with the task")
        XCTAssertEqual(due!.timeIntervalSince(clock.now), 5, accuracy: 1.01)
        XCTAssertTrue(c.scheduler.isScheduled(id))
        clock.advance(by: 3); XCTAssertEqual(started, [])
        clock.advance(by: 4); XCTAssertEqual(started, [source], "once the time came")
        clock.advance(by: 3600); XCTAssertEqual(started.count, 1)
    }

    func testAWebKitRetryOfATaskThatWasCancelledWhileWaitingNeverStarts() {
        var started: [URL] = []
        c.starter = { started.append($0) }
        let id = UUID()
        let source = URL(string: "https://example.com/gone.bin")!
        c.ledger.create(id: id, protocolID: .webKit, source: source, filename: "gone.bin", isPrivate: false)
        XCTAssertTrue(c.planRetry(for: source, error: URLError(.timedOut), resumeData: nil, id: id))
        _ = c.ledger.apply(.cancelled, to: id)
        clock.advance(by: 60)
        XCTAssertEqual(started, [], "a task the person cancelled is never restarted")
    }

    func testTheRetryCountStopsTheStorm() {
        var started = 0
        c.starter = { _ in started += 1 }
        let source = URL(string: "https://example.com/storm.bin")!
        let id = UUID()
        c.ledger.create(id: id, protocolID: .webKit, source: source, filename: "storm.bin", isPrivate: false)
        var planned = 0
        while planned < 10, c.planRetry(for: source, error: URLError(.timedOut), resumeData: nil, id: id) { planned += 1; clock.advance(by: 400) }
        XCTAssertEqual(planned, DownloadRetry.maxAttempts, "a bounded number of tries")
        XCTAssertEqual(started, planned)
    }
}
