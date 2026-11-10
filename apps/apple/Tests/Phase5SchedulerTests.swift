import XCTest
@testable import Browser_Setu

// MARK: Test clock

/// Time that moves only when a test says so: no test waits for a real second.
@MainActor
final class ManualClock: SchedulerClock {
    var now: Date
    var uptime: TimeInterval = 1000

    private final class Slot: SchedulerTimer {
        var due: Date; var action: (@MainActor () -> Void)?
        init(due: Date, action: @escaping @MainActor () -> Void) { self.due = due; self.action = action }
        func cancel() { action = nil }
    }
    private var slots: [Slot] = []

    init(start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { now = start }

    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> SchedulerTimer {
        let slot = Slot(due: now.addingTimeInterval(max(0, seconds)), action: action)
        slots.append(slot)
        return slot
    }

    /// Time passes, and every timer that comes due fires in order (one that sets another timer within the span fires too).
    func advance(by seconds: TimeInterval) {
        let end = now.addingTimeInterval(seconds)
        while let next = slots.filter({ $0.action != nil && $0.due <= end }).min(by: { $0.due < $1.due }) {
            let step = max(0, next.due.timeIntervalSince(now))
            now = max(now, next.due); uptime += step
            slots.removeAll { $0 === next }
            next.action?()
        }
        uptime += max(0, end.timeIntervalSince(now)); now = end
    }

    /// The wall clock moves (the Mac slept, or the clock was set) and no timer is told: only `reconcile` can notice.
    func jumpWall(by seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }

    var liveTimers: Int { slots.filter { $0.action != nil }.count }
}

/// A scheduler and the bookkeeping a coordinator would do around it, with names so a failed order reads as words.
@MainActor
private final class Line {
    let clock = ManualClock()
    let scheduler: DownloadScheduler
    var running = Set<UUID>()
    var admitted: [UUID] = []
    var names: [UUID: String] = [:]
    var limit = 3

    init() {
        scheduler = DownloadScheduler(clock: clock)
        scheduler.slotLimit = { [unowned self] in self.limit }
        scheduler.occupied = { [unowned self] in self.running.count }
    }

    @discardableResult
    func add(_ name: String, _ priority: DownloadPriority = .normal, need: ResourceNeed = .none, kind: DownloadScheduler.Kind = .resume) -> UUID {
        let id = UUID()
        names[id] = name
        scheduler.enqueue(id: id, kind: kind, filename: name, priority: priority, need: need) { [unowned self] in
            self.admitted.append(id)
            if kind != .start { self.running.insert(id) }
        }
        return id
    }
    func finish(_ id: UUID) { running.remove(id); scheduler.release(task: id); scheduler.pump() }
    var order: [String] { admitted.compactMap { names[$0] } }
}

private func connections(_ host: String, _ amount: Int = 1) -> ResourceNeed { ResourceNeed(requests: [.init(pool: ConnectionBudget.poolName, amount: amount, scope: host)]) }

// MARK: Queue

@MainActor
final class SchedulerQueueTests: XCTestCase {
    func testHigherPriorityGoesFirst() {
        let l = Line(); l.limit = 0
        l.add("low", .low); l.add("normal", .normal); l.add("high", .high)
        l.limit = 3; l.scheduler.pump()
        XCTAssertEqual(l.order, ["high", "normal", "low"])
    }

    func testEqualPriorityIsFirstInFirstOut() {
        let l = Line(); l.limit = 0
        for name in ["a", "b", "c", "d"] { l.add(name) }
        l.limit = 4; l.scheduler.pump()
        XCTAssertEqual(l.order, ["a", "b", "c", "d"])
    }

    func testChangingPriorityReordersTheLine() {
        let l = Line(); l.limit = 0
        l.add("a"); let b = l.add("b"); l.add("c")
        l.scheduler.setPriority(b, .high)
        XCTAssertEqual(l.scheduler.position(of: b), 1)
        l.limit = 3; l.scheduler.pump()
        XCTAssertEqual(l.order, ["b", "a", "c"])
    }

    func testAnArrivingHighTaskDoesNotPreemptARunningOne() {
        let l = Line(); l.limit = 1
        let first = l.add("first", .low)
        l.add("urgent", .high)
        XCTAssertEqual(l.order, ["first"], "the running one is left alone")
        XCTAssertTrue(l.running.contains(first))
        l.finish(first)
        XCTAssertEqual(l.order, ["first", "urgent"])
    }

    func testAWaitingTaskGainsRankByWaitingAndNoNewTaskPassesOneThatHasWaitedLonger() {
        let l = Line(); l.limit = 0
        l.add("old low", .low)
        l.clock.advance(by: DownloadScheduler.agingInterval * 5)     // five intervals
        l.add("new high", .high)
        l.limit = 1; l.scheduler.pump()
        XCTAssertEqual(l.order, ["old low"], "five intervals of waiting outweigh two steps of priority")
    }

    func testBeforeItHasWaitedLongEnoughHighStillWins() {
        let l = Line(); l.limit = 0
        l.add("low", .low)
        l.clock.advance(by: DownloadScheduler.agingInterval)
        l.add("high", .high)
        l.limit = 1; l.scheduler.pump()
        XCTAssertEqual(l.order, ["high"])
    }

    func testAStreamOfNewHighTasksCannotStarveALowOne() {
        let l = Line(); l.limit = 1
        let blocker = l.add("blocker", .high)
        l.add("starving low", .low)
        var current = blocker
        for round in 1...8 {
            l.clock.advance(by: DownloadScheduler.agingInterval)
            l.add("high \(round)", .high)
            l.finish(current)
            current = l.admitted.last!
            if l.order.contains("starving low") { break }
        }
        XCTAssertTrue(l.order.contains("starving low"), "it was served after a bounded wait, not behind every later high: \(l.order)")
        XCTAssertLessThanOrEqual(l.order.firstIndex(of: "starving low") ?? 99, 7)
    }

    func testCancellingAWaitingTaskRemovesItAndItNeverStarts() {
        let l = Line(); l.limit = 0
        let a = l.add("a"); l.add("b")
        XCTAssertTrue(l.scheduler.remove(a))
        XCTAssertFalse(l.scheduler.remove(a), "removing twice is harmless")
        l.limit = 2; l.scheduler.pump()
        XCTAssertEqual(l.order, ["b"])
    }

    func testAnEntryAddedTwiceIsOnlyOneEntry() {
        let l = Line(); l.limit = 0
        let id = UUID()
        for _ in 0..<3 { l.scheduler.enqueue(id: id, kind: .start, filename: "x", priority: .normal) { } }
        XCTAssertEqual(l.scheduler.entries.count, 1)
    }

    func testAPausedQueueStartsNothingUntilResumed() {
        let l = Line()
        l.scheduler.hold(until: .distantFuture)
        l.add("a"); l.add("b")
        XCTAssertEqual(l.order, [])
        l.clock.advance(by: 365 * 86_400)
        XCTAssertEqual(l.order, [], "a pause the person asked for never lifts by itself")
        l.scheduler.hold(until: nil)
        XCTAssertEqual(l.order, ["a", "b"])
    }

    func testATimedHoldEndsByItselfAndSaysSo() {
        let l = Line()
        var ended = 0
        l.scheduler.onHoldExpired = { ended += 1 }
        l.scheduler.hold(until: l.clock.now.addingTimeInterval(600))
        l.add("a")
        XCTAssertEqual(l.order, [])
        XCTAssertEqual(l.scheduler.waitingReason, .held)
        l.clock.advance(by: 601)
        XCTAssertEqual(l.order, ["a"])
        XCTAssertEqual(ended, 1)
        XCTAssertNil(l.scheduler.heldUntil)
    }

    func testWhyTheNextOneIsWaitingIsSaid() {
        let l = Line(); l.limit = 1
        XCTAssertEqual(l.scheduler.waitingReason, .nothing)
        l.add("a"); l.add("b")
        XCTAssertEqual(l.scheduler.waitingReason, .noFreePlace)
    }
}

// MARK: Resources

@MainActor
final class SchedulerResourceTests: XCTestCase {
    private func lined(total: Int = 3, perHost: Int = 2) -> (Line, ConnectionBudget) {
        let l = Line(); l.limit = 10
        let budget = ConnectionBudget()
        budget.totalLimitOverride = total; budget.hostLimitOverride = perHost
        l.scheduler.register(budget)
        return (l, budget)
    }

    func testTheGlobalTaskLimitIsNeverExceeded() {
        let l = Line(); l.limit = 2
        for i in 0..<6 { l.add("t\(i)") }
        XCTAssertEqual(l.running.count, 2)
        l.finish(l.admitted[0])
        XCTAssertEqual(l.running.count, 2)
        XCTAssertEqual(l.order.count, 3)
    }

    func testTheGlobalConnectionLimitIsNeverExceeded() {
        let (l, budget) = lined(total: 3, perHost: 3)
        for i in 0..<6 { l.add("t\(i)", need: connections("h\(i)")) }
        XCTAssertEqual(budget.open, 3)
        XCTAssertEqual(l.running.count, 3)
    }

    func testThePerHostLimitHoldsAndAnotherHostIsNotHeldUpByIt() {
        let (l, budget) = lined(total: 8, perHost: 2)
        for i in 0..<4 { l.add("a\(i)", need: connections("a.example")) }
        l.add("b", need: connections("b.example"))
        XCTAssertEqual(l.order, ["a0", "a1", "b"], "two to one host, and the other host passes the waiting ones")
        XCTAssertEqual(budget.open, 3)
        l.finish(l.admitted[0])
        XCTAssertEqual(l.order.last, "a2", "the first waiting one goes the moment a connection to its host frees")
    }

    func testALargeNeedDoesNotBlockSmallOnesBehindIt() {
        let (l, _) = lined(total: 4, perHost: 4)
        l.add("big", need: connections("h", 5))           // can never fit
        l.add("small", need: connections("h", 1))
        XCTAssertEqual(l.order, ["small"], "a single-connection download is not starved behind one that wants many")
    }

    func testLeasesAreGivenBackExactlyOnceWhateverHowManyTimesTheEndIsReported() {
        let (l, budget) = lined()
        let a = l.add("a", need: connections("h"))
        XCTAssertEqual(budget.holding(task: a), 1)
        l.finish(a); l.finish(a); l.scheduler.release(task: a)
        XCTAssertEqual(budget.open, 0)
        XCTAssertEqual(budget.holding(task: a), 0)
    }

    func testAFailureDuringStartupGivesTheLeaseBack() {
        let (l, budget) = lined()
        let a = l.add("a", need: connections("h"))
        XCTAssertEqual(budget.open, 1)
        l.scheduler.release(task: a)          // what the coordinator does when the engine could not start it
        XCTAssertEqual(budget.open, 0)
    }

    func testRemovingATaskThatWasWaitingNeverLeavesALease() {
        let (l, budget) = lined(total: 1, perHost: 1)
        l.add("a", need: connections("h"))
        let b = l.add("b", need: connections("h"))
        l.scheduler.remove(b)
        XCTAssertEqual(budget.open, 1)
    }

    func testAReservationIsCountedUntilTheTaskBeginsAndNoLongerThanThat() {
        let l = Line(); l.limit = 1
        l.add("a", kind: .start)
        XCTAssertEqual(l.scheduler.reserved, 1)
        l.add("b", kind: .start)
        XCTAssertEqual(l.order, ["a"], "the promised place counts, so a second is not promised too")
        l.scheduler.settleReservation()
        XCTAssertEqual(l.order, ["a", "b"], "the first began, so its place is counted as running; the next in line was promised the freed one")
        XCTAssertEqual(l.scheduler.reserved, 1)
        l.scheduler.settleReservation()
        l.scheduler.settleReservation()
        XCTAssertEqual(l.scheduler.reserved, 0, "never below zero")
    }

    func testLoweringTheLimitStartsNothingNewAndStopsNothingRunning() {
        let l = Line(); l.limit = 3
        l.add("a"); l.add("b"); l.add("c")
        l.limit = 1
        l.add("d")
        XCTAssertEqual(l.running.count, 3, "no running task was stopped")
        XCTAssertEqual(l.order.count, 3)
        l.finish(l.admitted[0]); l.finish(l.admitted[1])
        XCTAssertEqual(l.order.count, 3, "still above the new limit")
        l.finish(l.admitted[2])
        XCTAssertEqual(l.order, ["a", "b", "c", "d"])
    }

    /// A different kind of engine asks for a different kind of resource and the scheduler needs no change.
    func testAnotherKindOfResourceUsesTheSameLeases() {
        final class Peers: ResourcePool {
            let name = "peers"; var used = 0; var held: [UUID: Int] = [:]
            func canGrant(_ amount: Int, scope: String?) -> Bool { used + amount <= 50 }
            func grant(_ amount: Int, scope: String?, task: UUID) -> Bool { guard used + amount <= 50 else { return false }; used += amount; held[task, default: 0] += amount; return true }
            func release(task: UUID) { used -= held.removeValue(forKey: task) ?? 0 }
        }
        let l = Line(); l.limit = 10
        let peers = Peers(); l.scheduler.register(peers)
        let need = ResourceNeed(requests: [.init(pool: "peers", amount: 30, scope: nil)])
        let a = l.add("a", need: need); l.add("b", need: need)
        XCTAssertEqual(l.order, ["a"])
        l.finish(a)
        XCTAssertEqual(l.order, ["a", "b"])
        XCTAssertEqual(peers.used, 30)
    }
}

// MARK: Scheduling and time

@MainActor
final class SchedulerTimeTests: XCTestCase {
    func testAStartFiresOnceAtItsTime() {
        let clock = ManualClock(); let s = DownloadScheduler(clock: clock)
        var fired = 0
        s.schedule(UUID(), due: clock.now.addingTimeInterval(3600)) { fired += 1 }
        clock.advance(by: 3599); XCTAssertEqual(fired, 0)
        clock.advance(by: 2); XCTAssertEqual(fired, 1)
        clock.advance(by: 86_400); XCTAssertEqual(fired, 1, "once")
    }

    func testReschedulingReplacesTheOldTimeAndCancellingStopsIt() {
        let clock = ManualClock(); let s = DownloadScheduler(clock: clock)
        let id = UUID(); var firstFired = 0, secondFired = 0
        s.schedule(id, due: clock.now.addingTimeInterval(100)) { firstFired += 1 }
        s.schedule(id, due: clock.now.addingTimeInterval(500)) { secondFired += 1 }
        XCTAssertEqual(s.scheduledCount, 1, "a task has one start time")
        clock.advance(by: 200); XCTAssertEqual(firstFired, 0)
        clock.advance(by: 400); XCTAssertEqual(secondFired, 1)
        s.schedule(id, due: clock.now.addingTimeInterval(10)) { secondFired += 10 }
        s.cancelTimer(id)
        clock.advance(by: 100); XCTAssertEqual(secondFired, 1, "cancelled, so never fired")
    }

    func testAMacThatSleptPastADeadlineFiresItOnWakeFromTheWallClock() {
        let clock = ManualClock(); let s = DownloadScheduler(clock: clock)
        var fired = 0
        s.schedule(UUID(), due: clock.now.addingTimeInterval(3600)) { fired += 1 }
        clock.jumpWall(by: 7200)               // asleep for two hours: no timer was told anything
        XCTAssertEqual(fired, 0)
        s.reconcile()
        XCTAssertEqual(fired, 1)
    }

    func testAClockSetBackwardsCannotStrandARetryForHours() {
        let clock = ManualClock(); let s = DownloadScheduler(clock: clock)
        var fired = 0
        s.schedule(UUID(), due: clock.now.addingTimeInterval(30), maxWait: DownloadScheduler.maxRetryWait) { fired += 1 }
        clock.jumpWall(by: -10 * 3600)         // the clock is set ten hours back
        s.reconcile()
        XCTAssertEqual(fired, 0)
        clock.advance(by: DownloadScheduler.maxRetryWait + 1)
        XCTAssertEqual(fired, 1, "it waited no longer than the longest a retry may")
    }

    func testAnExpiredHoldIsLiftedOnWake() {
        let l = Line()
        l.scheduler.hold(until: l.clock.now.addingTimeInterval(600))
        l.add("a")
        l.clock.jumpWall(by: 3600)
        l.scheduler.reconcile()
        XCTAssertEqual(l.order, ["a"])
    }

    func testTheOverduePolicy() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(SchedulePolicy.decide(dueAt: now.addingTimeInterval(600), now: now), .waitUntil(now.addingTimeInterval(600)))
        XCTAssertEqual(SchedulePolicy.decide(dueAt: now.addingTimeInterval(-3600), now: now), .startNow, "due an hour ago: the person expects it to have run")
        XCTAssertEqual(SchedulePolicy.decide(dueAt: now.addingTimeInterval(-SchedulePolicy.grace - 1), now: now), .needsPerson, "too old to start by itself")
        XCTAssertEqual(SchedulePolicy.decide(dueAt: nil, now: now), .needsPerson, "no time of its own: waits for the queue to be released")
    }

    func testAScheduledTimeIsAnAbsoluteMomentWhateverZoneThePersonIsIn() {
        var ny = Calendar(identifier: .gregorian); ny.timeZone = TimeZone(identifier: "America/New_York")!
        var tokyo = Calendar(identifier: .gregorian); tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let a = DownloadSchedule.nextOccurrence(hour: 2, minute: 0, after: now, calendar: ny)!
        XCTAssertEqual(ny.component(.hour, from: a), 2)
        let saved = a.timeIntervalSince1970
        XCTAssertEqual(Date(timeIntervalSince1970: saved), a, "what is saved is the moment, not a wall-clock reading")
        XCTAssertNotEqual(tokyo.component(.hour, from: a), 2, "and it is the same moment in another zone")
    }

    func testATimeThatDoesNotExistInTheSpringIsTheNextRealTimeNotTheNextDay() {
        var ny = Calendar(identifier: .gregorian); ny.timeZone = TimeZone(identifier: "America/New_York")!
        // 2026-03-08: at 02:00 clocks jump to 03:00, so 02:30 does not exist that day.
        let before = ny.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 1, minute: 0))!
        let due = DownloadSchedule.nextOccurrence(hour: 2, minute: 30, after: before, calendar: ny)!
        XCTAssertEqual(ny.component(.day, from: due), 8, "still that night")
        XCTAssertEqual(ny.component(.hour, from: due), 3, "just after the gap")
        XCTAssertGreaterThan(due, before)
    }

    func testATimeThatHappensTwiceInTheAutumnIsTheFirstOne() {
        var ny = Calendar(identifier: .gregorian); ny.timeZone = TimeZone(identifier: "America/New_York")!
        // 2026-11-01: at 02:00 clocks go back to 01:00, so 01:30 happens twice.
        let before = ny.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 0, minute: 0))!
        let due = DownloadSchedule.nextOccurrence(hour: 1, minute: 30, after: before, calendar: ny)!
        XCTAssertEqual(due.timeIntervalSince(before), 90 * 60, accuracy: 1, "an hour and a half later: the first 01:30, not the second")
    }
}

// MARK: Retry delay

final class RetryDelayTests: XCTestCase {
    func testTheDelayGrowsAndIsCapped() {
        let d = (1...6).map { DownloadRetry.delay(afterAttempt: $0, retryAfter: nil, jitter: 0.5) }
        XCTAssertEqual(d, [5, 10, 20, 40, 80, 160])
        XCTAssertEqual(DownloadRetry.delay(afterAttempt: 30, retryAfter: nil, jitter: 0.5), 300)
    }

    func testJitterSpreadsTasksThatFailedTogetherWithinTwentyPercent() {
        let low = DownloadRetry.delay(afterAttempt: 3, retryAfter: nil, jitter: 0)
        let high = DownloadRetry.delay(afterAttempt: 3, retryAfter: nil, jitter: 1)
        XCTAssertEqual(low, 16, accuracy: 0.001); XCTAssertEqual(high, 24, accuracy: 0.001)
        XCTAssertEqual(Set((0...10).map { DownloadRetry.delay(afterAttempt: 3, retryAfter: nil, jitter: Double($0) / 10) }).count, 11)
    }

    func testRetryAfterIsNeverUndercutButIsCappedAtAnHour() {
        XCTAssertEqual(DownloadRetry.delay(afterAttempt: 1, retryAfter: 120, jitter: 0), 120)
        XCTAssertEqual(DownloadRetry.delay(afterAttempt: 1, retryAfter: 86_400, jitter: 0), 3600, "a day is not waited out silently")
        XCTAssertEqual(DownloadRetry.delay(afterAttempt: 1, retryAfter: 1, jitter: 0.5), 5, "an early hint does not shorten the backoff")
    }

    func testOnlyTransientFailuresAreRetried() {
        XCTAssertTrue(DownloadRetry.isRetryable(URLError(.timedOut)))
        XCTAssertFalse(DownloadRetry.isRetryable(URLError(.fileDoesNotExist)))
        XCTAssertFalse(DownloadRetry.isRetryable(URLError(.cancelled)))
        XCTAssertEqual(HTTPRetrySchedule.delay(afterAttempt: 2, retryAfter: nil, jitter: 0.5), DownloadRetry.delay(afterAttempt: 2, retryAfter: nil, jitter: 0.5) * HTTPRetrySchedule.delayScale,
                       accuracy: 0.001, "every engine uses the one rule")
    }
}

// MARK: Metadata

final class MetadataCapacityTests: XCTestCase {
    func testCountersGoBeforeLastingFactsWhenRoomRunsShort() {
        var meta: [String: String] = [:]
        for key in ["etag", "lastModified", "mode", "multipartRefused", "multipartRestarts", "origin", "resumable", "serverName", "sha256", "suspiciousName"] { meta[key] = "x" }
        for key in DownloadEngineMetadata.volatileKeys { meta[key] = "1" }
        for i in 0..<4 { meta["extra\(i)"] = "x" }                 // 19 in all, 3 too many
        let (kept, rejected) = DownloadEngineMetadata.reconcile(meta)
        XCTAssertEqual(kept.count, DownloadEngineMetadata.maxEntries)
        XCTAssertEqual(rejected.count, 3)
        XCTAssertTrue(rejected.allSatisfy { DownloadEngineMetadata.volatileKeys.contains($0.key) && $0.reason == .overCapacity }, "only counters were lost: \(rejected)")
        for lasting in ["etag", "origin", "sha256", "resumable"] { XCTAssertNotNil(kept[lasting], lasting) }
    }

    func testEveryLossIsNamedAndNothingElseIsLost() {
        let (kept, rejected) = DownloadEngineMetadata.reconcile(["good": "1", "bad key!": "x", "long": String(repeating: "a", count: 300)])
        XCTAssertEqual(kept, ["good": "1"])
        XCTAssertEqual(Set(rejected.map(\.reason)), [.invalidKey, .valueTooLong])
        XCTAssertEqual(DownloadEngineMetadata.reconcile(["a": "1", "b": "2"]).rejected, [])
    }

    func testTheOutcomeIsTheSameEveryTime() {
        var meta: [String: String] = [:]
        for i in 0..<30 { meta["k\(i)"] = "v" }
        let first = DownloadEngineMetadata.reconcile(meta).kept
        for _ in 0..<5 { XCTAssertEqual(DownloadEngineMetadata.reconcile(meta).kept, first) }
    }
}
