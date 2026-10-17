import XCTest
@testable import Browser_Setu

@MainActor
final class DownloadPersistenceTests: XCTestCase {
    func testAnInterruptedDownloadSurvivesRestartAndIsForgottenOnceHandled() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = DownloadCoordinator()
        first.store = folder
        let started = first.begin(suggestedName: "big.zip", cancel: {})
        first.interrupt(started.id, resumeData: Data("resume-bytes".utf8), source: URL(string: "https://a.test/big.zip"))
        XCTAssertEqual(first.interrupted.count, 1)

        let second = DownloadCoordinator()          // the app was quit and opened again
        second.store = folder
        XCTAssertEqual(second.interrupted.count, 1)
        XCTAssertEqual(second.interrupted[started.id]?.filename, "big.zip")
        XCTAssertEqual(second.interrupted[started.id]?.resumeData, Data("resume-bytes".utf8))

        var resumedWith: Data?
        second.resumer = { resumedWith = $0 }
        second.resume(started.id)
        XCTAssertEqual(resumedWith, Data("resume-bytes".utf8))
        let third = DownloadCoordinator(); third.store = folder
        XCTAssertTrue(third.interrupted.isEmpty, "a resumed download is not offered again")
        XCTAssertTrue(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".resume") }.isEmpty)
    }

    func testRunningDownloadsHandBackTheirPlaceWhenAskedToStop() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let c = DownloadCoordinator(); c.store = folder
        _ = c.begin(suggestedName: "a.bin", cancel: {}, suspend: { done in done(Data("place".utf8)) })
        _ = c.begin(suggestedName: "b.bin", cancel: {}, suspend: { done in done(nil) })    // one that has nothing to resume
        await withCheckedContinuation { cont in c.suspendAll { cont.resume() } }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(c.interrupted.count, 1)
        let again = DownloadCoordinator(); again.store = folder
        XCTAssertEqual(again.interrupted.count, 1)
    }

    func testAHostileIndexCannotEscapeOrOverfillTheList() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = UUID()
        try Data("x".utf8).write(to: folder.appendingPathComponent(id.uuidString + ".resume"))
        try Data("[{\"id\":\"\(id.uuidString)\",\"filename\":\"../../etc/passwd\",\"source\":null}]".utf8).write(to: folder.appendingPathComponent("interrupted.json"))
        let c = DownloadCoordinator(); c.store = folder
        XCTAssertEqual(c.interrupted[id]?.filename, "passwd", "only a plain file name is kept")
    }
}

@MainActor
final class DownloadQueueTests: XCTestCase {
    private func item(_ name: String, _ p: DownloadPriority, _ seconds: Double) -> QueuedDownload {
        QueuedDownload(id: UUID(), filename: name, priority: p, enqueued: Date(timeIntervalSince1970: seconds), source: nil)
    }

    func testHigherPriorityGoesFirstThenWhoeverWaitedLongest() {
        let list = [item("a", .normal, 1), item("b", .high, 5), item("c", .low, 0), item("d", .high, 3)]
        XCTAssertEqual(DownloadQueueRules.next(from: list)?.filename, "d")
        XCTAssertNil(DownloadQueueRules.next(from: []))
        XCTAssertEqual(DownloadQueueRules.freeSlots(limit: 3, running: 2, reserved: 1), 0)
        XCTAssertEqual(DownloadQueueRules.freeSlots(limit: 3, running: 1, reserved: 0), 2)
        XCTAssertEqual(DownloadQueueRules.freeSlots(limit: 1, running: 4, reserved: 0), 0)
    }

    func testRetriesBackOffAndOnlyForFailuresARetryCanFix() {
        XCTAssertEqual((1...4).map { DownloadRetry.delay(afterAttempt: $0) }, [5, 10, 20, 40])
        XCTAssertEqual(DownloadRetry.delay(afterAttempt: 20), 300)
        XCTAssertTrue(DownloadRetry.isRetryable(URLError(.networkConnectionLost)))
        XCTAssertTrue(DownloadRetry.isRetryable(URLError(.timedOut)))
        XCTAssertFalse(DownloadRetry.isRetryable(URLError(.cancelled)), "a download the person cancelled is never restarted")
        XCTAssertFalse(DownloadRetry.isRetryable(URLError(.fileDoesNotExist)))
        XCTAssertFalse(DownloadRetry.isRetryable(CocoaError(.fileWriteOutOfSpace)))
    }

    func testTheNextOccurrenceOfATimeIsTodayIfAheadElseTomorrow() throws {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let noon = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 12)))
        let evening = try XCTUnwrap(DownloadSchedule.nextOccurrence(hour: 20, minute: 0, after: noon, calendar: cal))
        XCTAssertEqual(cal.component(.day, from: evening), 17)
        let night = try XCTUnwrap(DownloadSchedule.nextOccurrence(hour: 2, minute: 0, after: noon, calendar: cal))
        XCTAssertEqual(cal.component(.day, from: night), 18)
        XCTAssertTrue(DownloadSchedule.isHeld(until: noon.addingTimeInterval(60), now: noon))
        XCTAssertFalse(DownloadSchedule.isHeld(until: nil))
        XCTAssertFalse(DownloadSchedule.canSchedule(URL(string: "blob:https://a.test/x")))
        XCTAssertTrue(DownloadSchedule.canSchedule(URL(string: "https://a.test/f.zip")))
    }

    func testOnlyAsManyRunAsAreAllowedAndTheRestWaitInPriorityOrder() async throws {
        let c = DownloadCoordinator()
        c.maxConcurrent = 1
        let first = await c.admit(filename: "first.bin", source: nil)
        XCTAssertTrue(first)
        let one = c.begin(suggestedName: "first.bin", cancel: {})
        var order: [String] = []
        let low = Task { @MainActor in _ = await c.admit(filename: "low.bin", source: nil); order.append("low") }
        try await Task.sleep(for: .milliseconds(30))
        let high = Task { @MainActor in _ = await c.admit(filename: "high.bin", source: nil); order.append("high") }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(c.waiting.map(\.filename), ["low.bin", "high.bin"])
        c.setPriority(try XCTUnwrap(c.waiting.first { $0.filename == "high.bin" }?.id), .high)
        c.finish(one.id, source: nil)                                     // a place frees up: the high one goes first
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(order, ["high"])
        XCTAssertEqual(c.waiting.map(\.filename), ["low.bin"])
        let b = c.begin(suggestedName: "high.bin", cancel: {})
        c.finish(b.id, source: nil)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(order, ["high", "low"])
        low.cancel(); high.cancel()
    }

    func testAWaitingDownloadCanBeCancelled() async throws {
        let c = DownloadCoordinator()
        c.maxConcurrent = 1
        _ = await c.admit(filename: "a.bin", source: nil); _ = c.begin(suggestedName: "a.bin", cancel: {})
        let waiter = Task { @MainActor in await c.admit(filename: "b.bin", source: nil) }
        try await Task.sleep(for: .milliseconds(30))
        c.cancelWaiting(try XCTUnwrap(c.waiting.first?.id))
        let result = await waiter.value
        XCTAssertFalse(result)
        XCTAssertTrue(c.waiting.isEmpty)
    }

    func testWhileHeldNewDownloadsAreRememberedAndStartedLaterFromTheirAddress() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dq-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let c = DownloadCoordinator(); c.store = folder
        c.holdQueue(until: Date().addingTimeInterval(3600))
        let go = await c.admit(filename: "late.zip", source: URL(string: "https://a.test/late.zip"))
        XCTAssertFalse(go, "it is put off, not started")
        XCTAssertEqual(c.scheduled.map(\.filename), ["late.zip"])
        let again = DownloadCoordinator(); again.store = folder
        XCTAssertEqual(again.scheduled.count, 1, "and remembered across a restart")
        var started: [URL] = []
        again.starter = { started.append($0) }
        again.resumeAll()
        XCTAssertEqual(started.map(\.absoluteString), ["https://a.test/late.zip"])
        XCTAssertTrue(again.scheduled.isEmpty)
        let plain = await again.admit(filename: "now.bin", source: URL(string: "https://a.test/now.bin"))
        XCTAssertTrue(plain, "with the hold lifted, downloads start again")
    }
}
