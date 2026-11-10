import XCTest
@testable import Browser_Setu

final class FakeMonotonic: MonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var t = 1000.0
    func now() -> Double { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ s: Double) { lock.lock(); t += s; lock.unlock() }
    func set(_ s: Double) { lock.lock(); t = s; lock.unlock() }
}

/// Simulates receivers that each take a chunk, reserve it, and wait the returned time (exactly what the transport does), on a manual clock, with no real sleeping.
private func simulate(controller: BandwidthController, clock: FakeMonotonic, workers: [(task: UUID, chunk: Int)], seconds: Double) -> [UUID: Int64] {
    var due = workers.map { _ in clock.now() }
    var got: [UUID: Int64] = [:]
    let end = clock.now() + seconds
    while true {
        guard let i = due.indices.min(by: { due[$0] < due[$1] }), due[i] < end else { break }
        clock.set(max(clock.now(), due[i]))
        let w = workers[i]
        got[w.task, default: 0] += Int64(w.chunk)
        due[i] = clock.now() + controller.reserve(task: w.task, bytes: w.chunk)
    }
    return got
}

final class BandwidthControllerTests: XCTestCase {
    func testUnlimitedNeverWaits() {
        let c = BandwidthController(clock: FakeMonotonic())
        let t = UUID()
        for _ in 0..<1000 { XCTAssertEqual(c.reserve(task: t, bytes: 1 << 20), 0) }
        XCTAssertNil(c.effectiveLimit(for: t))
        XCTAssertFalse(c.isLimiting)
    }

    func testOverallLimitHoldsLongRunRate() {
        let clock = FakeMonotonic(), c = BandwidthController(clock: clock)
        c.setOverallLimit(1_000_000)
        let t = UUID()
        let got = simulate(controller: c, clock: clock, workers: [(t, 64 * 1024)], seconds: 20)[t]!
        XCTAssertEqual(Double(got), 20_000_000, accuracy: 20_000_000 * 0.03 + 300_000)
    }

    func testPerTaskLimitIsStricterThanOverall() {
        let clock = FakeMonotonic(), c = BandwidthController(clock: clock)
        c.setOverallLimit(4_000_000)
        let a = UUID(), b = UUID()
        c.setTaskLimit(500_000, for: a)
        let got = simulate(controller: c, clock: clock, workers: [(a, 32 * 1024), (b, 32 * 1024)], seconds: 20)
        XCTAssertEqual(Double(got[a]!), 10_000_000, accuracy: 600_000)
        XCTAssertEqual(c.effectiveLimit(for: a)?.source, .download)
        XCTAssertEqual(c.effectiveLimit(for: b)?.source, .overall)
        // the other download uses what the first leaves, up to its share, never the total
        XCTAssertLessThanOrEqual(Double(got[a]! + got[b]!), 4_000_000 * 20 * 1.05 + 400_000)
    }

    func testTaskLimitAboveOverallDoesNotRaiseIt() {
        let c = BandwidthController(clock: FakeMonotonic()), t = UUID()
        c.setOverallLimit(1_000_000); c.setTaskLimit(9_000_000, for: t)
        XCTAssertEqual(c.effectiveLimit(for: t)?.bytesPerSecond, 1_000_000)
        XCTAssertEqual(c.effectiveLimit(for: t)?.source, .overall)
    }

    func testConnectionsOfOneTaskShareOneBudget() {
        // Four workers of one download and one worker of another, same chunk size: the overall limit is split between DOWNLOADS, not connections.
        let clock = FakeMonotonic(), c = BandwidthController(clock: clock)
        c.setOverallLimit(2_000_000)
        let big = UUID(), small = UUID()
        let got = simulate(controller: c, clock: clock, workers: [(big, 32768), (big, 32768), (big, 32768), (big, 32768), (small, 32768)], seconds: 30)
        let sum = Double(got[big]! + got[small]!)
        XCTAssertEqual(sum, 60_000_000, accuracy: 60_000_000 * 0.05 + 400_000)
        let ratio = Double(got[big]!) / Double(got[small]!)
        XCTAssertLessThan(ratio, 1.6, "one download with many connections must not take most of the budget (ratio \(ratio))")
        XCTAssertGreaterThan(ratio, 0.6)
    }

    func testIdleDownloadReleasesItsShare() {
        let clock = FakeMonotonic(), c = BandwidthController(clock: clock)
        c.setOverallLimit(2_000_000)
        let a = UUID(), b = UUID()
        _ = simulate(controller: c, clock: clock, workers: [(a, 32768), (b, 32768)], seconds: 5)
        // b stops; a alone now gets (nearly) all of it
        let alone = simulate(controller: c, clock: clock, workers: [(a, 32768)], seconds: 20)[a]!
        XCTAssertEqual(Double(alone), 40_000_000, accuracy: 40_000_000 * 0.08 + 600_000)
    }

    func testBurstIsBoundedAfterLongSilence() {
        let clock = FakeMonotonic(), c = BandwidthController(clock: clock)
        c.setOverallLimit(1_000_000)
        let t = UUID()
        clock.advance(3600)
        // an hour of silence banks at most a quarter second
        var free = 0
        while c.reserve(task: t, bytes: 1000) == 0 { free += 1000; if free > 5_000_000 { break } }
        XCTAssertLessThanOrEqual(free, 300_000)
    }

    func testClockGoingBackwardsNeitherMintsTokensNorStalls() {
        let clock = FakeMonotonic(), c = BandwidthController(clock: clock)
        c.setOverallLimit(1_000_000)
        let t = UUID()
        _ = c.reserve(task: t, bytes: 2_000_000)          // deep in debt
        let before = c.remainingWait(task: t)
        clock.advance(-5000)                              // wall clock set back
        let after = c.remainingWait(task: t)
        XCTAssertGreaterThan(after, 0)
        XCTAssertLessThanOrEqual(after, before + 0.001)
        clock.advance(5000 + 3)                           // and forward again: normal accrual from the new reference
        XCTAssertEqual(c.remainingWait(task: t), 0, accuracy: 0.0001)
    }

    func testLowerLimitTakesEffectAtOnceHigherLimitFillsGradually() {
        let clock = FakeMonotonic(), c = BandwidthController(clock: clock)
        c.setOverallLimit(10_000_000)
        let t = UUID()
        c.setOverallLimit(100_000)
        // the saved-up quarter second of the old limit is not kept
        var free = 0
        while c.reserve(task: t, bytes: 1000) == 0 { free += 1000; if free > 5_000_000 { break } }
        XCTAssertLessThanOrEqual(free, 40_000)
        c.setOverallLimit(nil)
        XCTAssertEqual(c.reserve(task: t, bytes: 1_000_000), 0)
        XCTAssertEqual(c.remainingWait(task: t), 0)
    }

    func testRaisingTheLimitShortensAWaitInProgress() {
        let clock = FakeMonotonic(), c = BandwidthController(clock: clock)
        c.setOverallLimit(10_000)
        let t = UUID()
        let first = c.reserve(task: t, bytes: 100_000)
        XCTAssertGreaterThan(first, 5)
        c.setOverallLimit(10_000_000)
        XCTAssertLessThan(c.remainingWait(task: t), 0.5)
    }

    func testValidationRaisesTinyLimitsAndDropsNonPositive() {
        XCTAssertNil(BandwidthController.valid(0)); XCTAssertNil(BandwidthController.valid(-5)); XCTAssertNil(BandwidthController.valid(nil))
        XCTAssertEqual(BandwidthController.valid(10), BandwidthController.minimumRate)
        XCTAssertEqual(BandwidthController.valid(5_000_000), 5_000_000)
    }

    func testForgetReleasesTaskState() {
        let c = BandwidthController(clock: FakeMonotonic()), t = UUID()
        c.setTaskLimit(50_000, for: t)
        _ = c.reserve(task: t, bytes: 10)
        c.forget(task: t)
        XCTAssertEqual(c.taskLimit(t), 50_000, "a pause keeps the download's own limit")
        c.discard(task: t)
        XCTAssertNil(c.taskLimit(t))
        XCTAssertEqual(c.reserve(task: t, bytes: 1 << 20), 0)
    }

    func testChangeObserversAreCalledAndRemoved() {
        let c = BandwidthController(clock: FakeMonotonic())
        let calls = NSLock(); var n = 0
        let token = c.observe { calls.lock(); n += 1; calls.unlock() }
        c.setOverallLimit(1_000_000); c.setTaskLimit(5000, for: UUID())
        c.unobserve(token)
        c.setOverallLimit(nil)
        XCTAssertEqual(n, 2)
    }

    func testReserveIsCheapWhenLimited() {
        let c = BandwidthController(), t = UUID()
        c.setOverallLimit(50_000_000)
        measure { for _ in 0..<20_000 { _ = c.reserve(task: t, bytes: 4096) } }
    }
}
