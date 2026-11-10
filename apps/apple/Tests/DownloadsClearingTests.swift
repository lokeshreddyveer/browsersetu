import XCTest
@testable import Browser_Setu

/// Removing records and clearing the list: records only, the real removal, never a running download and never a file.
@MainActor
final class DownloadsClearingTests: XCTestCase {
    private var coordinator: DownloadCoordinator!
    private var defaults: UserDefaults!
    private var suite = ""
    private var savedOverride: URL?
    private var folder: URL!

    override func setUp() async throws {
        try await super.setUp()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("clear-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        savedOverride = DownloadCoordinator.directoryOverride
        DownloadCoordinator.directoryOverride = folder
        coordinator = DownloadCoordinator()
        suite = "clear-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        DownloadCoordinator.directoryOverride = savedOverride
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
        try await super.tearDown()
    }

    @discardableResult
    private func make(_ name: String, _ events: [DownloadEvent], withFile: Bool = false) throws -> UUID {
        let r = coordinator.ledger.create(protocolID: .http, source: URL(string: "https://example.com/\(name)"), filename: name, isPrivate: false)
        for e in events { _ = coordinator.ledger.apply(e, to: r.id) }
        if withFile {
            let url = folder.appendingPathComponent(name)
            try Data("content of \(name)".utf8).write(to: url)
            coordinator.ledger.update(r.id) { $0.file.destinationPath = url.path }
        }
        return r.id
    }

    private let done: [DownloadEvent] = [.queued, .started, .running, .verifying, .completed(.unknown)]
    private let failed: [DownloadEvent] = [.queued, .started, .failed(DownloadFailureInfo(code: "x", reason: "y", retryable: false))]
    private let running: [DownloadEvent] = [.queued, .started, .running]

    private func model() -> DownloadsViewModel {
        let m = DownloadsViewModel(coordinator: coordinator, defaults: defaults, changeDelay: 0, progressDelay: 0.05)
        m.refreshNow()
        return m
    }

    func testClearCompletedRemovesOnlyCompletedRecordsAndKeepsTheirFiles() throws {
        let a = try make("a.bin", done, withFile: true), b = try make("b.bin", done, withFile: true)
        let f = try make("f.bin", failed), r = try make("r.bin", running), q = try make("q.bin", [.queued])
        let vm = model()
        XCTAssertEqual(vm.clearHistory(.completed), 2)
        XCTAssertNil(coordinator.ledger.record(a)); XCTAssertNil(coordinator.ledger.record(b))
        for kept in [f, r, q] { XCTAssertNotNil(coordinator.ledger.record(kept)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("a.bin").path), "a file is never deleted by clearing a record")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("b.bin").path))
    }

    func testClearFailedAndCancelledLeavesCompletedAndActive() throws {
        let c = try make("c.bin", done), f = try make("f.bin", failed), x = try make("x.bin", [.queued, .cancelled]), r = try make("r.bin", running)
        let vm = model()
        XCTAssertEqual(vm.clearHistory(.failedAndCancelled), 2)
        XCTAssertNil(coordinator.ledger.record(f)); XCTAssertNil(coordinator.ledger.record(x))
        XCTAssertNotNil(coordinator.ledger.record(c)); XCTAssertNotNil(coordinator.ledger.record(r))
    }

    func testClearAllHistoryNeverTouchesActiveQueuedPausedOrRecoveryRequiredDownloads() throws {
        let finished = [try make("c.bin", done), try make("f.bin", failed), try make("x.bin", [.queued, .cancelled])]
        let live = try make("r.bin", running), queued = try make("q.bin", [.queued])
        let paused = try make("p.bin", running + [.pauseRequested, .paused(resumeAvailable: true)])
        let recovery = try make("rec.bin", running + [.recoveryRequired(reason: "found after quit")])
        let vm = model()
        XCTAssertEqual(vm.clearHistory(.allFinished), 3)
        for id in finished { XCTAssertNil(coordinator.ledger.record(id)) }
        for id in [live, queued, paused] { XCTAssertNotNil(coordinator.ledger.record(id), "an unfinished download stays") }
        XCTAssertNotNil(coordinator.ledger.record(recovery), "a recovery-required download stays")
    }

    func testRecordsAreGoneAfterTheLedgerIsSavedAndReloaded() throws {
        let c = try make("c.bin", done), keep = try make("k.bin", running)
        let vm = model()
        vm.clearHistory(.completed)
        coordinator.ledger.flush()
        XCTAssertNil(coordinator.ledger.record(c))
        XCTAssertNotNil(coordinator.ledger.record(keep))
    }

    func testBulkRemovalActsOnlyOnTheSelectionAndOnlyOnFinishedRows() throws {
        let a = try make("a.bin", done), b = try make("b.bin", done), r = try make("r.bin", running)
        let vm = model()
        vm.selection = [a, r]
        XCTAssertEqual(vm.perform(.removeRecord), 1, "the running download is not removable from the list")
        XCTAssertNil(coordinator.ledger.record(a)); XCTAssertNotNil(coordinator.ledger.record(b)); XCTAssertNotNil(coordinator.ledger.record(r))
    }

    func testAMissingFileDoesNotStopItsRecordBeingCleared() throws {
        let c = try make("gone.bin", done)
        coordinator.ledger.update(c) { $0.file.destinationPath = folder.appendingPathComponent("never-existed.bin").path }
        let vm = model()
        XCTAssertEqual(vm.clearHistory(.completed), 1)
        XCTAssertNil(coordinator.ledger.record(c))
    }

    func testNothingToClearIsHarmless() throws {
        _ = try make("r.bin", running)
        let vm = model()
        XCTAssertEqual(vm.clearHistory(.allFinished), 0)
        XCTAssertEqual(vm.rowsToClear(.allFinished).count, 0)
    }

    func testCancelAndRemoveEndsAQueuedDownloadAndDropsItsRecord() async throws {
        let q = try make("q.bin", [.queued]), other = try make("o.bin", done)
        let vm = model()
        XCTAssertEqual(vm.cancelAndRemove(on: [q]), 1)
        for _ in 0..<40 where coordinator.ledger.record(q) != nil { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertNil(coordinator.ledger.record(q), "cancelled, then taken off the list")
        XCTAssertNotNil(coordinator.ledger.record(other), "nothing else is touched")
    }

    func testCancelAndRemoveLeavesAFinishedDownloadAlone() throws {
        let c = try make("c.bin", done, withFile: true)
        let vm = model()
        XCTAssertEqual(vm.cancelAndRemove(on: [c]), 0, "there is nothing to cancel")
        XCTAssertNotNil(coordinator.ledger.record(c))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("c.bin").path))
    }

    func testAnotherCoordinatorsRecordsAreNeverReachable() throws {
        let mine = try make("mine.bin", done)
        let other = DownloadCoordinator()
        let theirs = other.ledger.create(protocolID: .http, source: URL(string: "https://example.com/theirs.bin"), filename: "theirs.bin", isPrivate: false)
        for e in done { _ = other.ledger.apply(e, to: theirs.id) }
        let vm = model()
        XCTAssertEqual(vm.clearHistory(.allFinished), 1)
        XCTAssertNil(coordinator.ledger.record(mine))
        XCTAssertNotNil(other.ledger.record(theirs.id), "another profile's list is its own")
    }
}
