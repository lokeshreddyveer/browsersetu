import XCTest
@testable import Browser_Setu

// Phase 6: the rows the Downloads dashboard shows, how they are searched, filtered and sorted, what a selection may do, and the guarantees around them.

private func makeRecord(_ name: String, state: DownloadState, url: String = "https://files.example.com/path/\(UUID().uuidString.prefix(4)).bin", proto: DownloadProtocolID = .http,
                    total: Int64? = nil, done: Int64 = 0, priority: DownloadPriority = .normal, created: TimeInterval = 1_000, isPrivate: Bool = false) -> DownloadTaskRecord {
    var r = DownloadTaskRecord(protocolID: proto, profile: "default", isPrivate: isPrivate, source: DownloadSourceRef(url: URL(string: url)), filename: name, now: Date(timeIntervalSince1970: created))
    r.state = state; r.priority = priority
    r.transfer.totalBytes = total; r.transfer.completedBytes = done
    return r
}

private func active(_ r: DownloadTaskRecord, rate: Double = 0, done: Int64 = 0, total: Int64 = 0) -> ActiveDownload {
    var a = ActiveDownload(id: r.id, filename: r.file.filename, fraction: total > 0 ? Double(done) / Double(total) : 0, completedBytes: done, totalBytes: total)
    a.bytesPerSecond = rate
    return a
}

private func project(_ records: [DownloadTaskRecord], tweak: (inout DownloadsSnapshot) -> Void = { _ in }) -> [DownloadRow] {
    var s = DownloadsSnapshot(records: records)
    tweak(&s)
    return DownloadRowProjector.rows(from: s)
}

// MARK: Projection

@MainActor
final class DownloadRowProjectionTests: XCTestCase {
    func testRunningTaskShowsRealProgressSpeedAndTimeLeft() {
        let r = makeRecord("movie.mp4", state: .running, total: 1_000_000, done: 400_000)
        let row = project([r]) { $0.live[r.id] = active(r, rate: 100_000, done: 400_000, total: 1_000_000); $0.canPause = [r.id] }[0]
        XCTAssertEqual(row.status, .downloading)
        XCTAssertEqual(row.fraction!, 0.4, accuracy: 0.001)
        XCTAssertEqual(row.bytesPerSecond, 100_000)
        XCTAssertEqual(row.secondsLeft!, 6, accuracy: 0.01)
        XCTAssertTrue(row.actions.contains(.pause) && row.actions.contains(.cancel))
        XCTAssertFalse(row.actions.contains(.resume))
    }

    func testUnknownSizeIsIndeterminateAndNothingIsInvented() {
        let r = makeRecord("stream.bin", state: .running, total: nil, done: 0)
        let row = project([r]) { $0.live[r.id] = active(r) }[0]
        XCTAssertNil(row.fraction, "no total means no percentage")
        XCTAssertNil(row.bytesPerSecond)
        XCTAssertNil(row.secondsLeft)
        XCTAssertNil(DownloadFormat.speed(row.bytesPerSecond))
        XCTAssertNil(DownloadFormat.eta(row.secondsLeft))
        XCTAssertEqual(row.detail, "Starting…")
    }

    func testSpeedIsNeverShownForATaskThatIsNotMoving() {
        let r = makeRecord("a.bin", state: .paused, total: 100, done: 50)
        let row = project([r]) { $0.live[r.id] = active(r, rate: 5_000, done: 50, total: 100) }[0]
        XCTAssertNil(row.bytesPerSecond)
        XCTAssertNil(row.secondsLeft)
    }

    func testStatusLabelsForEveryState() {
        let cases: [(DownloadState, DownloadRowStatus, String)] = [
            (.running, .downloading, "Downloading"), (.queued, .queued, "Waiting"), (.scheduled, .scheduled, "Held"), (.paused, .paused, "Paused"),
            (.verifying, .verifying, "Finishing"), (.completed, .completed, "Completed"), (.failed, .failed, "Failed"), (.cancelled, .cancelled, "Cancelled"),
            (.recoveryRequired, .recoveryRequired, "Stopped part-way"), (.retrying, .retrying, "Trying again"),
        ]
        for (state, status, text) in cases {
            let row = project([makeRecord("f.bin", state: state)])[0]
            XCTAssertEqual(row.status, status, "\(state)")
            XCTAssertTrue(row.statusText.hasPrefix(text), "\(state) said \(row.statusText)")
        }
    }

    func testQueuedShowsPositionAndTheReason() {
        let r = makeRecord("q.bin", state: .queued)
        let row = project([r]) { $0.positions[r.id] = 3; $0.queueNote = "Waiting for a free place" }[0]
        XCTAssertEqual(row.statusText, "Waiting · #3 in line")
        XCTAssertEqual(row.detail, "Waiting for a free place")
        XCTAssertEqual(row.queuePosition, 3)
        XCTAssertTrue(row.actions.contains(.setPriority) && row.actions.contains(.cancel))
        XCTAssertFalse(row.actions.contains(.pause))
    }

    func testScheduledShowsStartAndStartNowAndOverdueWording() {
        var r = makeRecord("s.bin", state: .scheduled)
        r.scheduledAt = Date().addingTimeInterval(3600)
        let later = project([r])[0]
        XCTAssertEqual(later.statusText, "Scheduled")
        XCTAssertTrue(later.detail.hasPrefix("Starts "))
        XCTAssertTrue(later.actions.contains(.startNow))
        let late = project([r]) { $0.overdue = [r.id] }[0]
        XCTAssertEqual(late.statusText, "Missed its start")
        XCTAssertTrue(late.detail.contains("Start it when you are ready"))
        XCTAssertTrue(late.actions.contains(.startNow))
    }

    func testRetryingShowsNextTryAndOffersOnlyCancelAndPriority() {
        var r = makeRecord("r.bin", state: .retrying)
        r.retryAt = Date().addingTimeInterval(30); r.retryCount = 1
        let row = project([r])[0]
        XCTAssertEqual(row.statusText, "Trying again (attempt 2)")
        XCTAssertTrue(row.detail.hasPrefix("Next try at "))
        XCTAssertEqual(row.actions, [.cancel, .setPriority])
    }

    func testFinishedTaskNeverRegainsAnActiveControl() {
        for state in [DownloadState.completed, .cancelled] {
            let row = project([makeRecord("d.bin", state: state)])[0]
            XCTAssertTrue(row.actions.isDisjoint(with: [.pause, .resume, .retry, .cancel, .startNow, .setPriority]), "\(state)")
        }
        let verifying = project([makeRecord("v.bin", state: .verifying)])[0]
        XCTAssertTrue(verifying.actions.isEmpty, "a file being put in place cannot be cancelled")
    }

    func testCompletedFileActionsNeedTheFileToBeThere() {
        let r = makeRecord("done.pdf", state: .completed, total: 2_000)
        XCTAssertEqual(project([r])[0].actions, [.removeRecord], "file gone: only forgetting the entry")
        let there = project([r]) { $0.fileExists = { _ in true } }[0]
        XCTAssertTrue(there.actions.isSuperset(of: [.open, .reveal, .trashFile, .removeRecord]))
        XCTAssertEqual(there.fraction, 1)
    }

    func testPausedResumeIsOfferedOnlyWhenTheCoordinatorCanDoIt() {
        let r = makeRecord("p.bin", state: .paused, total: 100, done: 40)
        XCTAssertFalse(project([r])[0].actions.contains(.resume))
        XCTAssertNotNil(project([r])[0].recoveryNote)
        let row = project([r]) { $0.canResume = [r.id] }[0]
        XCTAssertTrue(row.actions.contains(.resume))
        XCTAssertTrue(row.recoveryNote!.contains("carries on"))
    }

    func testRecoveryRequiredActionFollowsTheRecoveryClass() {
        let r = makeRecord("x.bin", state: .recoveryRequired)
        let cases: [(DownloadRecoveryClass, Bool, String)] = [
            (.resumable, true, "Resume"), (.restartRequired("The file changed."), true, "Start Over"),
            (.needsNewLink("The link has expired."), false, "Resume"), (.cannotRecover("Nothing is left."), false, "Resume"),
        ]
        for (kind, offered, title) in cases {
            let row = project([r]) { $0.recoveries[r.id] = kind; if offered { $0.canResume = [r.id] } }[0]
            XCTAssertEqual(row.actions.contains(.resume), offered, "\(kind)")
            if offered { XCTAssertEqual(row.resumeTitle, title) }
            XCTAssertTrue(row.actions.contains(.removeRecord))
            XCTAssertEqual(row.problem, kind.summary)
        }
    }

    func testFailedOffersRetryOnlyWhenItCanBeRestarted() {
        let r = makeRecord("f.bin", state: .failed)
        XCTAssertFalse(project([r])[0].actions.contains(.retry))
        XCTAssertTrue(project([r]) { $0.canRetry = [r.id] }[0].actions.contains(.retry))
    }

    func testPrivateDownloadsAreShownOnlyWhileTheyRun() {
        let running = makeRecord("p1.bin", state: .running, isPrivate: true)
        let done = makeRecord("p2.bin", state: .completed, isPrivate: true)
        let failed = makeRecord("p3.bin", state: .failed, isPrivate: true)
        XCTAssertEqual(project([running, done, failed]).map(\.filename), ["p1.bin"])
    }

    func testHistoryIsBoundedAndLiveRowsAreNeverDropped() {
        var all = (0..<1_200).map { makeRecord("old\($0).bin", state: .completed, created: Double($0)) }
        let live = makeRecord("now.bin", state: .running)
        all.append(live)
        let rows = project(all)
        XCTAssertEqual(rows.count, DownloadRowProjector.maxRows)
        XCTAssertTrue(rows.contains { $0.id == live.id })
        XCTAssertTrue(rows.contains { $0.filename == "old1199.bin" }, "the newest history is kept")
        XCTAssertFalse(rows.contains { $0.filename == "old0.bin" }, "the oldest is what goes")
    }

    func testProtocolIsNotAssumedToBeHTTP() {
        let torrent = project([makeRecord("t.iso", state: .running, proto: "bittorrent")])[0]
        XCTAssertEqual(torrent.protocolLabel, "BITTORRENT")
        XCTAssertEqual(torrent.protocolID, "bittorrent")
        XCTAssertEqual(project([makeRecord("w.zip", state: .running, proto: .webKit)])[0].protocolLabel, "Browser")
    }
}

// MARK: Wording and redaction

final class DownloadWordingTests: XCTestCase {
    func testProgressSpeedEtaAndSizeFormatting() {
        XCTAssertEqual(DownloadFormat.percent(0.426), "42%")
        XCTAssertEqual(DownloadFormat.percent(1.7), "100%")
        XCTAssertNil(DownloadFormat.percent(nil))
        XCTAssertNil(DownloadFormat.speed(0)); XCTAssertNil(DownloadFormat.speed(nil)); XCTAssertNotNil(DownloadFormat.speed(2_000_000))
        XCTAssertTrue(DownloadFormat.speed(2_000_000)!.hasSuffix("/s"))
        XCTAssertNil(DownloadFormat.eta(nil)); XCTAssertNil(DownloadFormat.eta(0)); XCTAssertNil(DownloadFormat.eta(.infinity))
        XCTAssertEqual(DownloadFormat.eta(45), "45 s")
        XCTAssertEqual(DownloadFormat.eta(600), "10 min")
        XCTAssertNil(DownloadFormat.size(nil)); XCTAssertNil(DownloadFormat.size(0))
        XCTAssertNil(DownloadFormat.progress(completed: 0, total: nil))
        XCTAssertEqual(DownloadFormat.progress(completed: 0, total: 1_000_000)?.hasPrefix("Zero"), true)
    }

    func testErrorsAreWordedForPeopleNotForCode() {
        XCTAssertEqual(DownloadErrorPresenter.message(reason: nil, code: "NSURLErrorDomain:-1009"), "The network connection was lost.")
        XCTAssertEqual(DownloadErrorPresenter.message(reason: nil, code: "http-403"), "The website refused the download.")
        XCTAssertEqual(DownloadErrorPresenter.message(reason: nil, code: "http-404"), "The file is no longer available.")
        XCTAssertEqual(DownloadErrorPresenter.message(reason: nil, code: "http-412"), "The website changed the file, so it cannot carry on.")
        XCTAssertEqual(DownloadErrorPresenter.message(reason: nil, code: "NSCocoaErrorDomain:640"), "There is not enough space on the disk.")
        XCTAssertTrue(DownloadErrorPresenter.message(reason: "x", code: "retry-not-scheduled").contains("could not schedule another try"))
        XCTAssertEqual(DownloadErrorPresenter.message(reason: nil, code: nil), "It could not be downloaded.")
    }

    func testAddressesInMessagesLoseTheirTokens() {
        let text = DownloadErrorPresenter.scrub("Failed from https://cdn.example.com/f.zip?token=SECRET123&sig=ABC okay")
        XCTAssertFalse(text.contains("SECRET123")); XCTAssertFalse(text.contains("ABC"))
        XCTAssertTrue(text.contains("cdn.example.com"))
    }

    func testRowNeverCarriesTheQueryOrCredentials() {
        let r = makeRecord("f.zip", state: .running, url: "https://user:pw@cdn.example.com/files/f.zip?X-Amz-Signature=TOPSECRET&token=abc")
        let row = project([r])[0]
        let blob = [row.sourceDisplay, row.host, row.detail, row.statusText, row.accessibilitySummary].joined(separator: "|")
        XCTAssertFalse(blob.contains("TOPSECRET")); XCTAssertFalse(blob.contains("pw")); XCTAssertFalse(blob.contains("token"))
        XCTAssertEqual(row.sourceDisplay, "cdn.example.com", "a signed link is shown as its site only")
        let plain = project([makeRecord("g.zip", state: .running, url: "https://cdn.example.com/files/g.zip?page=2")])[0]
        XCTAssertEqual(plain.sourceDisplay, "cdn.example.com/files/g.zip", "an ordinary link keeps its path but never its query")
    }

    func testASignedPathIsCutBackToTheSiteAlone() {
        let source = DownloadSourceRef(url: URL(string: "https://cdn.example.com/dl/0123456789abcdef0123456789abcdef0123456789abcdef/f.zip?token=1"))
        let shown = DownloadRowProjector.displayAddress(source)
        XCTAssertFalse(shown.contains("token"))
        XCTAssertFalse(shown.contains("?"))
    }
}

// MARK: Search, filter, sort

final class DownloadQueryTests: XCTestCase {
    private func rows() -> [DownloadRow] {
        project([
            makeRecord("alpha.zip", state: .running, url: "https://cdn.one.com/alpha.zip?token=SIGNEDTOKEN", total: 500, done: 100, priority: .high, created: 10),
            makeRecord("Beta.pdf", state: .completed, url: "https://docs.two.org/beta.pdf", total: 90, priority: .low, created: 20),
            makeRecord("gamma.bin", state: .queued, url: "https://cdn.one.com/gamma.bin", proto: .webKit, priority: .normal, created: 30),
            makeRecord("delta.iso", state: .failed, url: "https://files.three.net/delta.iso", total: 9_000, created: 40),
            makeRecord("eps.dmg", state: .recoveryRequired, url: "https://files.three.net/eps.dmg", created: 50),
            makeRecord("zeta.mov", state: .paused, url: "https://files.three.net/zeta.mov", total: 40, done: 20, created: 60),
            makeRecord("eta.txt", state: .scheduled, url: "https://files.three.net/eta.txt", created: 70),
        ])
    }

    func testSearchMatchesNameAndHostButNeverTheAddressQuery() {
        var q = DownloadQuery(); q.search = "BETA"
        XCTAssertEqual(q.apply(to: rows()).map(\.filename), ["Beta.pdf"])
        q.search = "two.org"; XCTAssertEqual(q.apply(to: rows()).map(\.filename), ["Beta.pdf"])
        q.search = "SIGNEDTOKEN"; XCTAssertTrue(q.apply(to: rows()).isEmpty, "a signed token is not searchable")
        q.search = "token"; XCTAssertTrue(q.apply(to: rows()).isEmpty)
        q.search = "   "; XCTAssertEqual(q.apply(to: rows()).count, 7)
    }

    func testStatusFiltersAndCounts() {
        let all = rows()
        func names(_ f: DownloadFilter) -> Set<String> { var q = DownloadQuery(); q.filter = f; return Set(q.apply(to: all).map(\.filename)) }
        XCTAssertEqual(names(.active), ["alpha.zip"]); XCTAssertEqual(names(.queued), ["gamma.bin"]); XCTAssertEqual(names(.scheduled), ["eta.txt"])
        XCTAssertEqual(names(.paused), ["zeta.mov"]); XCTAssertEqual(names(.completed), ["Beta.pdf"]); XCTAssertEqual(names(.failed), ["delta.iso"])
        XCTAssertEqual(names(.recovery), ["eps.dmg"]); XCTAssertEqual(names(.all).count, 7)
        let counts = DownloadQuery.counts(of: all)
        XCTAssertEqual(counts[.all], 7); XCTAssertEqual(counts[.active], 1); XCTAssertEqual(counts[.recovery], 1)
    }

    func testPriorityAndProtocolFilters() {
        var q = DownloadQuery(); q.priority = .high
        XCTAssertEqual(q.apply(to: rows()).map(\.filename), ["alpha.zip"])
        q = DownloadQuery(); q.protocolLabel = "Browser"
        XCTAssertEqual(q.apply(to: rows()).map(\.filename), ["gamma.bin"])
    }

    func testSortingByEachKeyAndDirection() {
        var q = DownloadQuery()
        q.sort = .name; q.ascending = true
        XCTAssertEqual(q.apply(to: rows()).first?.filename, "alpha.zip")
        q.sort = .size; q.ascending = false
        XCTAssertEqual(q.apply(to: rows()).first?.filename, "delta.iso")
        q.sort = .progress; q.ascending = false
        XCTAssertEqual(q.apply(to: rows()).first?.filename, "Beta.pdf", "a finished task is 100%")
        q.sort = .priority; q.ascending = false
        XCTAssertEqual(q.apply(to: rows()).first?.filename, "alpha.zip")
        q.sort = .date; q.ascending = false
        XCTAssertEqual(q.apply(to: rows()).first?.filename, "eta.txt")
        q.ascending = true
        XCTAssertEqual(q.apply(to: rows()).first?.filename, "alpha.zip")
    }

    func testEqualRowsKeepTheSameOrderEveryTime() {
        let same = (0..<20).map { makeRecord("same\($0).bin", state: .queued, created: 5) }
        let first = project(same).shuffled()
        var q = DownloadQuery(); q.sort = .priority
        let a = q.apply(to: first).map(\.id), b = q.apply(to: first.reversed()).map(\.id)
        XCTAssertEqual(a, b, "ties are broken the same way whatever order the rows arrive in")
    }
}

// MARK: Selection, batches and dispatch

@MainActor
private final class Spy: DownloadActionPerforming {
    var calls: [String] = []
    func performPause(_ id: UUID) { calls.append("pause:\(id)") }
    func performResume(_ id: UUID) { calls.append("resume:\(id)") }
    func performRetry(_ id: UUID) { calls.append("retry:\(id)") }
    func performCancel(_ id: UUID, status: DownloadRowStatus) { calls.append("cancel:\(id):\(status)") }
    func performStartNow(_ id: UUID) { calls.append("start:\(id)") }
    func performSetPriority(_ id: UUID, _ priority: DownloadPriority) { calls.append("priority:\(id):\(priority)") }
    func performRemoveRecord(_ id: UUID) { calls.append("remove:\(id)") }
}

@MainActor
final class DownloadsViewModelTests: XCTestCase {
    private var coordinator: DownloadCoordinator!
    private var defaults: UserDefaults!
    private var suite = ""
    private var savedOverride: URL?
    private var folder: URL!

    override func setUp() async throws {
        try await super.setUp()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("dash6-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        savedOverride = DownloadCoordinator.directoryOverride
        DownloadCoordinator.directoryOverride = folder
        coordinator = DownloadCoordinator()
        suite = "dash6-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }
    override func tearDown() async throws {
        DownloadCoordinator.directoryOverride = savedOverride
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
        try await super.tearDown()
    }

    @discardableResult
    private func make(_ name: String, _ events: [DownloadEvent] = [], priority: DownloadPriority = .normal) -> UUID {
        let r = coordinator.ledger.create(protocolID: .http, source: URL(string: "https://example.com/\(name)"), filename: name, isPrivate: false, priority: priority)
        for e in events { _ = coordinator.ledger.apply(e, to: r.id) }
        return r.id
    }

    private func model(spy: Spy? = nil) -> DownloadsViewModel {
        let m = DownloadsViewModel(coordinator: coordinator, performer: spy, defaults: defaults, changeDelay: 0, progressDelay: 0.05)
        m.refreshNow()
        return m
    }

    func testRowsComeFromTheLedger() {
        make("a.bin", [.queued]); make("b.bin", [.queued, .started, .running])
        let vm = model()
        XCTAssertEqual(Set(vm.rows.map(\.filename)), ["a.bin", "b.bin"])
        XCTAssertEqual(vm.counts[.active], 1); XCTAssertEqual(vm.counts[.queued], 1)
    }

    func testBatchOffersAnActionWhenAnySelectedRowSupportsItAndActsOnlyOnThose() {
        let spy = Spy()
        let running = make("run.bin", [.queued, .started, .running])
        let queued = make("wait.bin", [.queued])
        let failedID = make("bad.bin", [.queued, .started, .failed(DownloadFailureInfo(code: "x", reason: "y", retryable: true))])
        let vm = model(spy: spy)
        vm.selection = [running, queued, failedID]
        let allowed = vm.allowedActions
        XCTAssertTrue(allowed.contains(.cancel)); XCTAssertTrue(allowed.contains(.removeRecord)); XCTAssertTrue(allowed.contains(.setPriority))
        XCTAssertEqual(vm.count(for: .cancel), 2, "the failed task cannot be cancelled")
        let n = vm.perform(.cancel)
        XCTAssertEqual(n, 2)
        XCTAssertEqual(Set(spy.calls), ["cancel:\(running):downloading", "cancel:\(queued):queued"])
        XCTAssertFalse(spy.calls.contains { $0.contains("\(failedID)") })
    }

    func testRemovingFromTheListIsNotCancellingAndNeverTouchesARunningTask() {
        let spy = Spy()
        let running = make("run.bin", [.queued, .started, .running])
        let vm = model(spy: spy)
        vm.selection = [running]
        XCTAssertEqual(vm.perform(.removeRecord), 0)
        XCTAssertTrue(spy.calls.isEmpty)
    }

    func testPriorityDispatchCarriesTheChoice() {
        let spy = Spy()
        let a = make("a.bin", [.queued]), b = make("b.bin", [.queued])
        let vm = model(spy: spy)
        vm.perform(.setPriority, on: [a, b], priority: .high)
        XCTAssertEqual(Set(spy.calls), ["priority:\(a):high", "priority:\(b):high"])
        XCTAssertEqual(vm.perform(.setPriority, on: [a]), 1)
        XCTAssertEqual(spy.calls.count, 2, "no priority given: nothing is sent")
    }

    func testContextMenuTargetsTheRowsItIsGivenNotTheOldSelection() {
        let spy = Spy()
        let a = make("a.bin", [.queued]), b = make("b.bin", [.queued])
        let vm = model(spy: spy)
        vm.selection = [a]
        vm.perform(.cancel, on: [b])
        XCTAssertEqual(spy.calls, ["cancel:\(b):queued"])
    }

    func testRealDispatchGoesThroughTheCoordinatorAndPriorityReachesTheScheduler() {
        let id = make("p.bin", [.queued])
        let vm = model()
        vm.perform(.setPriority, on: [id], priority: .high)
        XCTAssertEqual(coordinator.ledger.record(id)?.priority, .high)
    }

    func testTrashNeedsConfirmationAndTouchesOnlyCompletedFilesInTheFolder() throws {
        let id = make("keep.txt", [.queued, .started, .running, .verifying, .completed(.verified)])
        let file = folder.appendingPathComponent("keep.txt")
        try Data("x".utf8).write(to: file)
        coordinator.ledger.update(id) { $0.file.destinationPath = file.path }
        let vm = model()
        vm.recheckFiles(); vm.refreshNow()
        XCTAssertTrue(vm.row(id)!.actions.contains(.trashFile))
        vm.selection = [id]
        vm.requestTrash()
        XCTAssertEqual(vm.pendingTrash.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "asking does not move anything")
        vm.cancelTrash()
        XCTAssertTrue(vm.pendingTrash.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "declining keeps the file")
        let running = make("run.bin", [.queued, .started, .running])
        XCTAssertFalse(coordinator.trashFile(of: running), "a running download's file is never trashed")
        XCTAssertFalse(coordinator.trashFile(of: UUID()))
    }

    /// A finished download with a real file in the downloads folder.
    private func finishedWithFile(_ name: String) throws -> (id: UUID, file: URL) {
        let id = make(name, [.queued, .started, .running, .verifying, .completed(.verified)])
        let file = folder.appendingPathComponent(name)
        try Data("x".utf8).write(to: file)
        coordinator.ledger.update(id) { $0.file.destinationPath = file.path }
        return (id, file)
    }

    func testMovingAFileToTheTrashAlsoRemovesItsListEntryOnlyOnceTheFileIsGone() throws {
        let (id, file) = try finishedWithFile("gone.txt")
        let vm = model(); vm.recheckFiles(); vm.refreshNow()
        vm.selection = [id]; vm.requestTrash()
        // The Trash itself is replaced by a delete in this test so the person's real Trash is not touched; what is under test is the entry's lifecycle.
        vm.trashPerformer = { _ in (try? FileManager.default.removeItem(at: file)) != nil }
        vm.confirmTrash()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(coordinator.ledger.record(id), "the entry goes with its file")
        XCTAssertEqual(vm.message, "Moved 1 file to the Trash and removed it from the list")
        XCTAssertTrue(vm.pendingTrash.isEmpty)
    }

    func testAFileThatCouldNotBeMovedKeepsItsEntryAndItsFile() throws {
        let (id, file) = try finishedWithFile("stuck.txt")
        let vm = model(); vm.recheckFiles(); vm.refreshNow()
        vm.selection = [id]; vm.requestTrash()
        vm.trashPerformer = { _ in false }
        vm.confirmTrash()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "nothing was changed on disk")
        XCTAssertNotNil(coordinator.ledger.record(id), "an entry never disappears while its file is still there")
        XCTAssertEqual(vm.message, "“stuck.txt” could not be moved to the Trash. It is still in the list, and its file has not been changed")
    }

    func testSeveralFilesAreHandledOneByOneAndAFailureDoesNotUndoTheOthers() throws {
        let a = try finishedWithFile("a.txt"), b = try finishedWithFile("b.txt"), c = try finishedWithFile("c.txt")
        let vm = model(); vm.recheckFiles(); vm.refreshNow()
        vm.selection = [a.id, b.id, c.id]; vm.requestTrash()
        XCTAssertEqual(vm.pendingTrash.count, 3)
        vm.trashPerformer = { id in
            guard id != b.id else { return false }          // b fails
            let url = id == a.id ? a.file : c.file
            return (try? FileManager.default.removeItem(at: url)) != nil
        }
        vm.confirmTrash()
        XCTAssertNil(coordinator.ledger.record(a.id)); XCTAssertNil(coordinator.ledger.record(c.id))
        XCTAssertNotNil(coordinator.ledger.record(b.id), "the one that failed stays, with its file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.file.path))
        XCTAssertEqual(vm.message, "Moved 2 to the Trash. 1 could not be moved and stay in the list: “b.txt”")
    }

    func testAnActiveDownloadIsNeverOfferedForTheTrashAndRemoveFromListStaysSeparate() throws {
        let running = make("run.bin", [.queued, .started, .running])
        let (id, file) = try finishedWithFile("keep.txt")
        let vm = model(); vm.recheckFiles(); vm.refreshNow()
        vm.selection = [running, id]; vm.requestTrash()
        XCTAssertEqual(vm.pendingTrash.map(\.id), [id], "only the finished download with a file qualifies")
        vm.cancelTrash()
        vm.selection = [id]
        XCTAssertEqual(vm.perform(.removeRecord), 1)
        XCTAssertNil(coordinator.ledger.record(id), "Remove from List forgets the entry")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "and never touches the file")
        XCTAssertNotNil(coordinator.ledger.record(running), "the running download is untouched")
    }

    /// Two list entries for one file (a duplicate, a re-download that kept the name): moving the file takes both entries, and selecting both is not a failure for the second.
    func testEntriesSharingOneFileGoTogetherAndASecondSelectedEntryIsNotAFailure() throws {
        let first = try finishedWithFile("same.txt")
        let second = make("same-again.txt", [.queued, .started, .running, .verifying, .completed(.verified)])
        coordinator.ledger.update(second) { $0.file.destinationPath = first.file.path }
        let other = try finishedWithFile("other.txt")
        let vm = model(); vm.recheckFiles(); vm.refreshNow()
        // Only the first entry is selected: the entry that shares its file is found and removed with it; an unrelated file is untouched.
        vm.selection = [first.id]; vm.requestTrash()
        var calls = 0
        vm.trashPerformer = { id in calls += 1; return (try? FileManager.default.removeItem(at: first.file)) != nil }
        vm.confirmTrash()
        XCTAssertEqual(calls, 1, "the file is moved once")
        XCTAssertNil(coordinator.ledger.record(first.id)); XCTAssertNil(coordinator.ledger.record(second), "the other entry for the same file goes with it")
        XCTAssertNotNil(coordinator.ledger.record(other.id)); XCTAssertTrue(FileManager.default.fileExists(atPath: other.file.path))
        XCTAssertEqual(vm.message, "Moved 1 file to the Trash and removed it from the list (1 other entry for the same file removed too)")
        // Both entries selected at once: the second must not be reported as a failure just because the first already moved the file.
        let a = try finishedWithFile("pair.txt")
        let b = make("pair-copy.txt", [.queued, .started, .running, .verifying, .completed(.verified)])
        coordinator.ledger.update(b) { $0.file.destinationPath = a.file.path }
        vm.recheckFiles(); vm.refreshNow()
        vm.selection = [a.id, b]; vm.requestTrash()
        var again = 0
        vm.trashPerformer = { _ in again += 1; return (try? FileManager.default.removeItem(at: a.file)) != nil }
        vm.confirmTrash()
        XCTAssertEqual(again, 1, "one move for one file, however many entries name it")
        XCTAssertNil(coordinator.ledger.record(a.id)); XCTAssertNil(coordinator.ledger.record(b))
        XCTAssertFalse(vm.message?.contains("could not") ?? false, "no false failure: \(vm.message ?? "")")
    }

    /// What the person sees after quitting and reopening: a removed entry stays removed, and an entry whose file could not be moved is still there.
    func testTheListAfterARelaunchMatchesWhatTheTrashStepDid() throws {
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("relaunch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: store) }
        let ledger = DownloadLedger(profile: "default"); _ = ledger.attach(folder: store, safeName: { $0 })
        func finished(_ name: String) -> UUID {
            let r = ledger.create(protocolID: .http, source: URL(string: "https://example.com/\(name)"), filename: name, isPrivate: false, priority: .normal)
            for e: DownloadEvent in [.queued, .started, .running, .verifying, .completed(.verified)] { _ = ledger.apply(e, to: r.id) }
            return r.id
        }
        let trashed = finished("trashed.bin"), stuck = finished("stuck.bin")
        ledger.remove(trashed)          // what a successful trash does to the entry
        ledger.flush()
        let reopened = DownloadLedger(profile: "default"); _ = reopened.attach(folder: store, safeName: { $0 })
        XCTAssertNil(reopened.record(trashed), "a removed entry does not come back after a relaunch")
        XCTAssertEqual(reopened.record(stuck)?.state, .completed, "an entry whose file stayed is still listed after a relaunch")
    }

    func testRemoveFromListKeepsTheFile() throws {
        let id = make("stay.txt", [.queued, .started, .running, .verifying, .completed(.verified)])
        let file = folder.appendingPathComponent("stay.txt")
        try Data("x".utf8).write(to: file)
        coordinator.ledger.update(id) { $0.file.destinationPath = file.path }
        let vm = model()
        vm.selection = [id]
        XCTAssertEqual(vm.perform(.removeRecord), 1)
        XCTAssertNil(coordinator.ledger.record(id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "removing the entry never deletes the file")
    }

    func testSelectionDropsRowsThatNoLongerExist() {
        let a = make("a.bin", [.queued]), b = make("b.bin", [.queued])
        let vm = model()
        vm.selection = [a, b]
        coordinator.ledger.remove(a)
        vm.refreshNow()
        XCTAssertEqual(vm.selection, [b])
        XCTAssertEqual(vm.visible.map(\.id), [b])
    }

    func testEmptyStateHasNoRowsAndCountsAreZero() {
        let vm = model()
        XCTAssertTrue(vm.rows.isEmpty); XCTAssertTrue(vm.visible.isEmpty)
        XCTAssertEqual(vm.counts[.all], 0)
        XCTAssertTrue(vm.allowedActions.isEmpty)
    }

    func testViewPreferencesPersistButSelectionDoesNot() {
        let a = make("a.bin", [.queued])
        var vm: DownloadsViewModel? = model()
        vm?.query.filter = .queued; vm?.query.sort = .name; vm?.query.ascending = true
        vm?.selection = [a]
        vm = nil
        let again = model()
        XCTAssertEqual(again.query.filter, .queued); XCTAssertEqual(again.query.sort, .name); XCTAssertTrue(again.query.ascending)
        XCTAssertTrue(again.selection.isEmpty, "what is selected is never saved")
    }

    func testABurstOfProgressTicksCostsAFewRebuildsNotOneEach() async {
        let id = make("big.bin", [.queued, .started, .running])
        let vm = model()
        vm.acquire()
        let before = vm.rebuilds
        for i in 0..<200 { coordinator.update(id, fraction: Double(i) / 200, completed: Int64(i), total: 200) }
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertLessThan(vm.rebuilds - before, 20, "200 ticks were coalesced")
        vm.release()
    }

    func testAStateChangeShowsPromptlyEvenWhileProgressIsThrottled() async {
        let id = make("fin.bin", [.queued, .started, .running])
        let vm = DownloadsViewModel(coordinator: coordinator, defaults: defaults, changeDelay: 0.02, progressDelay: 5)
        vm.acquire()
        XCTAssertEqual(vm.row(id)?.status, .downloading)
        _ = coordinator.ledger.apply(.verifying, to: id); _ = coordinator.ledger.apply(.completed(.verified), to: id)
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(vm.row(id)?.status, .completed, "a completion is not held back by the progress interval")
        vm.release()
    }

    func testStaleResultsNeverOverwriteNewerOnes() async {
        let id = make("s.bin", [.queued])
        let vm = model()
        vm.refresh(after: 1.0)                        // a late request ...
        _ = coordinator.ledger.apply(.started, to: id); _ = coordinator.ledger.apply(.running, to: id)
        vm.refresh(after: 0.0)                        // ... replaced by a sooner one
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(vm.row(id)?.status, .downloading)
        let built = vm.rebuilds
        try? await Task.sleep(for: .milliseconds(1_100))
        XCTAssertEqual(vm.rebuilds, built, "the replaced late request never ran")
    }

    func testObserversAreRemovedWhenTheLastViewerLeavesAndTheModelCanBeFreed() async {
        let vm = model()
        XCTAssertFalse(vm.isObserving)
        vm.acquire(); vm.acquire()
        XCTAssertTrue(vm.isObserving)
        vm.release()
        XCTAssertTrue(vm.isObserving, "the popover closing must not stop the window's updates")
        vm.release()
        XCTAssertFalse(vm.isObserving)
        let id = make("late.bin", [.queued])
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(vm.row(id), "a detached model does no work")
        weak var weakVM: DownloadsViewModel?
        autoreleasepool { var local: DownloadsViewModel? = DownloadsViewModel(coordinator: coordinator, defaults: defaults); local?.acquire(); weakVM = local; local?.release(); local = nil }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(weakVM, "nothing keeps a released model alive")
    }

    func testTwoViewsOverTheSameCoordinatorAgree() {
        make("same.bin", [.queued])
        let window = model(), popover = model()
        XCTAssertEqual(window.rows.map(\.id), popover.rows.map(\.id))
    }
}

// MARK: Retry that cannot be scheduled

@MainActor
final class StrandedRetryTests: XCTestCase {
    private var coordinator: DownloadCoordinator!
    override func setUp() async throws { try await super.setUp(); coordinator = DownloadCoordinator() }

    private func retryingTask() -> UUID {
        let r = coordinator.ledger.create(protocolID: .http, source: URL(string: "https://example.com/f.bin"), filename: "f.bin", isPrivate: false)
        for e in [DownloadEvent.queued, .started, .running, .retryPlanned] { _ = coordinator.ledger.apply(e, to: r.id) }
        coordinator.ledger.update(r.id) { $0.retryAt = Date().addingTimeInterval(60); $0.retryCount = 1 }
        return r.id
    }

    func testARetryWithNoDeadlineBecomesAStateThePersonCanActOn() {
        let id = retryingTask()
        XCTAssertFalse(coordinator.scheduler.isScheduled(id), "the stranded condition: retrying, and nothing will wake it")
        coordinator.http.strandedRetry(id, why: "Browser Setu could not schedule another try.")
        let record = coordinator.ledger.record(id)!
        XCTAssertEqual(record.state, .recoveryRequired)
        XCTAssertNil(record.retryAt, "no deadline is left behind")
        XCTAssertEqual(coordinator.http.pendingRetries, 0)
        let row = DownloadRowProjector.rows(from: DownloadsSnapshot(records: [record]))[0]
        XCTAssertEqual(row.status, .recoveryRequired)
        XCTAssertTrue(row.problem!.contains("Browser Setu"))
    }

    func testAFailedStartOfARetryIsReportedNotSilentlyDropped() {
        let id = retryingTask()
        // Part-way through the move to running (queued), the next step is refused: the task must not stay there.
        _ = coordinator.ledger.apply(.queued, to: id)
        coordinator.http.strandedRetry(id, why: "Browser Setu could not start the next try.")
        let state = coordinator.ledger.record(id)!.state
        XCTAssertTrue(state == .failed || state == .recoveryRequired, "ended in \(state)")
        XCTAssertTrue(coordinator.events.contains { $0.contains("could not start the next try") })
    }

    func testAnAlreadyFinishedTaskIsLeftAlone() {
        let id = retryingTask()
        _ = coordinator.ledger.apply(.cancelled, to: id)
        coordinator.http.strandedRetry(id, why: "x")
        XCTAssertEqual(coordinator.ledger.record(id)?.state, .cancelled)
    }

    func testBeginRetryOnATaskThatIsNoLongerRetryingChangesNothing() {
        let id = retryingTask()
        _ = coordinator.ledger.apply(.cancelled, to: id)
        coordinator.http.beginRetry(id, keepsPlace: false)
        XCTAssertEqual(coordinator.ledger.record(id)?.state, .cancelled)
    }

    func testThePresentedMessageIsActionable() {
        let msg = DownloadErrorPresenter.message(reason: "Browser Setu could not schedule another try.", code: "retry-not-scheduled")
        XCTAssertTrue(msg.contains("Try again"))
    }
}

// MARK: The window, the popover and the older lists read the same state

@MainActor
final class DownloadsSyncTests: XCTestCase {
    func testTheOlderListsAndTheNewRowsAgreeAfterARelaunch() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sync6-\(UUID().uuidString)")
        let downloads = folder.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let saved = DownloadCoordinator.directoryOverride
        DownloadCoordinator.directoryOverride = downloads
        defer { DownloadTaskStore.close(folder: folder); try? FileManager.default.removeItem(at: folder); DownloadCoordinator.directoryOverride = saved }

        let first = DownloadCoordinator()
        first.store = folder
        func plant(_ name: String, _ events: [DownloadEvent], resume: Data? = nil) -> UUID {
            let r = first.ledger.create(protocolID: .http, source: URL(string: "https://example.com/\(name)"), filename: name, isPrivate: false)
            for (i, e) in events.enumerated() { _ = first.ledger.apply(e, to: r.id, resumeData: i == events.count - 1 && resume != nil ? .some(resume) : nil) }
            return r.id
        }
        let paused = plant("paused.bin", [.queued, .started, .running, .paused(resumeAvailable: true)], resume: Data("r".utf8))
        let failed = plant("failed.bin", [.queued, .started, .failed(DownloadFailureInfo(code: "http-404", reason: "gone", retryable: false))])
        let held = plant("held.bin", [.queued, .scheduled(at: nil)])
        first.ledger.flush()
        DownloadTaskStore.close(folder: folder)

        let second = DownloadCoordinator()
        second.store = folder
        let vm = DownloadsViewModel(coordinator: second, defaults: nil)
        vm.refreshNow()
        let byID = Dictionary(uniqueKeysWithValues: vm.rows.map { ($0.id, $0) })
        // Everything the older panel lists is a row, in the matching status, with the same id.
        for id in second.interrupted.keys { XCTAssertTrue([.paused, .recoveryRequired].contains(byID[id]?.status), "interrupted \(id)") }
        for f in second.failures { XCTAssertTrue([.failed, .recoveryRequired].contains(byID[f.id]?.status), "failure \(f.filename)") }
        for s in second.scheduled { XCTAssertEqual(byID[s.id]?.status, .scheduled, "scheduled \(s.filename)") }
        XCTAssertNotNil(byID[paused]); XCTAssertNotNil(byID[failed]); XCTAssertNotNil(byID[held])
        XCTAssertEqual(vm.rows.count, 3, "nothing missing and nothing extra")
        XCTAssertEqual(byID[failed]?.problem, "The file is no longer available.")
        // And a change made through the coordinator shows in the rows.
        second.removeScheduled(held)
        vm.refreshNow()
        XCTAssertEqual(vm.row(held)?.status, .cancelled)
        second.dismissFailure(failed)
        vm.refreshNow()
        XCTAssertNil(vm.row(failed), "dismissing it in one place removes it everywhere")
    }
}
