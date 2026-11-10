import XCTest
import CryptoKit
@testable import Browser_Setu

// Phase 22: adaptive bandwidth, connection intelligence, per-profile limits. The rules are tested with no clock and no network (pure state and fake clocks); the integration tests use the
// local fixture server (port 18766), and the measurements are of real loopback transfers.

private func input(_ now: Double, rate: Double = 1_000_000, active: Int = 1, busy: Bool = false, lowPower: Bool = false, hot: Bool = false, held: Bool = false, workers: Int = 4) -> AdaptiveInput {
    AdaptiveInput(now: now, bytesPerSecond: rate, activeTransfers: active, browserBusy: busy, lowPower: lowPower, thermalSerious: hot, held: held, workersMax: workers)
}

// MARK: - The rules

final class AdaptiveRuleTests: XCTestCase {
    func testUnlimitedAndCustomNeverAdjustAnything() {
        for mode in [AdaptiveMode.unlimited, .custom] {
            var s = AdaptiveState()
            s.noteFailure(at: 0); s.noteFailure(at: 1)
            for t in 0..<10 { let d = s.step(mode: mode, input(Double(t) * 2, busy: true, lowPower: true)); XCTAssertNil(d.rateCeiling); XCTAssertNil(d.workerCeiling); XCTAssertNil(d.reason) }
        }
        XCTAssertFalse(AdaptiveMode.unlimited.isAdaptive); XCTAssertFalse(AdaptiveMode.custom.isAdaptive)
        for m in [AdaptiveMode.balanced, .browserPriority, .downloadPriority] { XCTAssertTrue(m.isAdaptive) }
    }

    func testTooLittleHistoryInventsNoCapacityAndSetsNoCeiling() {
        var s = AdaptiveState()
        let d1 = s.step(mode: .browserPriority, input(0, busy: true)), d2 = s.step(mode: .browserPriority, input(2, busy: true))
        XCTAssertNil(d1.rateCeiling); XCTAssertNil(d2.rateCeiling, "two samples are not a measurement")
        XCTAssertNil(s.estimator.estimate)
        _ = s.step(mode: .browserPriority, input(4, busy: true))
        XCTAssertEqual(s.step(mode: .browserPriority, input(6, busy: true)).rateCeiling.map { $0 > 0 }, true, "after enough samples the browser being busy has an effect")
    }

    func testTheEstimateIsSmoothedAndIgnoresSilence() {
        var e = ThroughputEstimator()
        for r in [1000.0, 1000, 1000] { e.add(bytesPerSecond: r) }
        XCTAssertEqual(e.estimate ?? 0, 1000, accuracy: 1)
        e.add(bytesPerSecond: 10_000)                         // one burst moves it only part of the way
        XCTAssertLessThan(e.estimate ?? 0, 4000); XCTAssertGreaterThan(e.estimate ?? 0, 1000)
        let before = e
        e.add(bytesPerSecond: 0); e.add(bytesPerSecond: .nan); e.add(bytesPerSecond: -5); e.add(bytesPerSecond: .infinity)
        XCTAssertEqual(e, before, "silence and nonsense are not samples")
    }

    func testEachModeHoldsDownloadsBackInProportionWhileTheBrowserIsBusy() {
        var results: [AdaptiveMode: Int64] = [:]
        for mode in [AdaptiveMode.balanced, .browserPriority, .downloadPriority] {
            var s = AdaptiveState()
            for t in 0..<4 { _ = s.step(mode: mode, input(Double(t) * 2, rate: 2_000_000)) }
            let d = s.step(mode: mode, input(8, rate: 2_000_000, busy: true))
            results[mode] = d.rateCeiling
            XCTAssertNotNil(d.reason)
        }
        let browser = results[.browserPriority]!, balanced = results[.balanced]!, download = results[.downloadPriority]!
        XCTAssertLessThan(browser, balanced); XCTAssertLessThan(balanced, download); XCTAssertLessThan(download, 2_000_000, "never above what was measured")
        XCTAssertEqual(Double(browser), 800_000, accuracy: 80_000)
    }

    func testTheCeilingDoesNotCollapseOnItsOwnEffectAndLiftsWhenTheBrowserIsIdle() {
        var s = AdaptiveState()
        for t in 0..<4 { _ = s.step(mode: .browserPriority, input(Double(t) * 2, rate: 2_000_000)) }
        var ceilings: [Int64] = []
        for t in 4..<40 {
            // The measured rate now follows the ceiling it is under: a controller that took a share of THAT would shrink it every step.
            let d = s.step(mode: .browserPriority, input(Double(t) * 2, rate: Double(ceilings.last ?? 2_000_000), busy: true))
            if let c = d.rateCeiling { ceilings.append(c) }
        }
        XCTAssertEqual(Set(ceilings).count, 1, "one steady ceiling, no spiral: \(Set(ceilings))")
        let off = s.step(mode: .browserPriority, input(100, busy: false))
        XCTAssertNil(off.rateCeiling); XCTAssertEqual(off.reason, "The browser is idle: no speed ceiling")
    }

    func testRapidFlappingOfTheBrowserSignalIsDamped() {
        var s = AdaptiveState()
        for t in 0..<4 { _ = s.step(mode: .balanced, input(Double(t) * 2, rate: 1_000_000)) }
        var changes = 0, last: Int64??
        for i in 0..<20 {
            let d = s.step(mode: .balanced, input(8 + Double(i) * 0.5, rate: 1_000_000, busy: i % 2 == 0))      // flips twice a second
            if last == nil || last! != d.rateCeiling { changes += 1 }
            last = .some(d.rateCeiling)
        }
        XCTAssertLessThanOrEqual(changes, 3, "ten seconds of flapping is a few changes, not twenty (\(changes))")
    }

    func testRepeatedErrorsLowerConnectionsAndAQuietSpellRestoresThemOneAtATime() {
        var s = AdaptiveState()
        s.noteFailure(at: 0); s.noteFailure(at: 1)
        let d = s.step(mode: .balanced, input(2, workers: 8))
        XCTAssertEqual(d.workerCeiling, 6); XCTAssertNotNil(d.reason)
        s.noteFailure(at: 3); s.noteFailure(at: 4)
        XCTAssertEqual(s.step(mode: .balanced, input(5, workers: 8)).workerCeiling, 6, "a second cut waits out the cooldown")
        s.noteFailure(at: 13); s.noteFailure(at: 14)
        XCTAssertEqual(s.step(mode: .balanced, input(15, workers: 8)).workerCeiling, 4)
        var t = 16.0, ceiling: Int? = 4, steps = 0
        while ceiling != nil, steps < 40 {
            t += 31; steps += 1
            let before = ceiling
            ceiling = s.step(mode: .balanced, input(t, workers: 8)).workerCeiling
            if let b = before, let c = ceiling { XCTAssertEqual(c, b + 1, "restored one at a time") }
        }
        XCTAssertNil(ceiling, "full connections come back after a quiet while"); XCTAssertLessThan(steps, 10)
    }

    func testTheFloorIsOneConnectionAndNeverZero() {
        var s = AdaptiveState()
        var t = 0.0
        for _ in 0..<30 { s.noteFailure(at: t); s.noteFailure(at: t + 0.1); t += 11; XCTAssertGreaterThanOrEqual(s.step(mode: .balanced, input(t, workers: 4)).workerCeiling ?? 4, 1) }
        XCTAssertEqual(s.workerCeiling, 1)
    }

    func testLowPowerAndHeatLimitConnectionsInAdaptiveModesOnly() {
        var s = AdaptiveState()
        XCTAssertEqual(s.step(mode: .balanced, input(0, lowPower: true, workers: 8)).workerCeiling, 2)
        var t = AdaptiveState()
        XCTAssertEqual(t.step(mode: .downloadPriority, input(0, hot: true, workers: 8)).workerCeiling, 2)
        var u = AdaptiveState()
        XCTAssertNil(u.step(mode: .unlimited, input(0, lowPower: true, hot: true, workers: 8)).workerCeiling)
        var v = AdaptiveState()
        XCTAssertNil(v.step(mode: .custom, input(0, lowPower: true, workers: 8)).workerCeiling)
    }

    func testANetworkHoldClearsEveryAdaptiveLimit() {
        var s = AdaptiveState()
        for t in 0..<4 { _ = s.step(mode: .browserPriority, input(Double(t) * 2, rate: 1_000_000)) }
        XCTAssertNotNil(s.step(mode: .browserPriority, input(8, busy: true)).rateCeiling)
        let held = s.step(mode: .browserPriority, input(10, busy: true, held: true))
        XCTAssertNil(held.rateCeiling); XCTAssertNil(held.workerCeiling)
    }

    func testBrowserActivityHasAGraceAndANeverEndingLoadDoesNotHoldDownloadsBackForever() {
        let clock = FakeMonotonic()
        let b = BrowserActivity(clock: clock)
        XCTAssertFalse(b.isBusy(grace: 8))
        b.navigationStarted(); XCTAssertTrue(b.isBusy(grace: 8))
        clock.advance(3); b.navigationEnded()
        XCTAssertTrue(b.isBusy(grace: 8), "still within the grace period"); clock.advance(5); XCTAssertTrue(b.isBusy(grace: 8)); clock.advance(4); XCTAssertFalse(b.isBusy(grace: 8))
        b.navigationStarted()                                  // its end is never reported
        clock.advance(30); XCTAssertTrue(b.isBusy(grace: 8)); clock.advance(40)
        XCTAssertFalse(b.isBusy(grace: 8), "a stale flag is dropped")
        b.navigationEnded(); b.navigationEnded(); XCTAssertTrue(b.isBusy(grace: 8), "an extra end never makes the count negative"); clock.advance(9); XCTAssertFalse(b.isBusy(grace: 8))
    }
}

// MARK: - Limits: the manual limit stays the hard bound, and profiles are separate

final class ProfileLimitTests: XCTestCase {
    private func drive(_ c: BandwidthController, clock: FakeMonotonic, task: UUID, seconds: Double) -> Int64 {
        var got: Int64 = 0
        let end = clock.now() + seconds
        while clock.now() < end {
            let wait = c.reserve(task: task, bytes: 16 * 1024); got += 16 * 1024
            clock.advance(max(wait, 0.001))
        }
        return got
    }

    func testTheManualLimitIsNeverRaisedByAnAdaptiveCeiling() {
        let owner = UUID(), clock = FakeMonotonic(), c = BandwidthController(clock: clock)
        c.setOverallLimit(1_000_000, owner: owner)
        c.setAdaptiveCeiling(5_000_000, owner: owner)
        XCTAssertEqual(c.effectiveOverall(owner: owner), 1_000_000, "a higher ceiling changes nothing")
        c.setAdaptiveCeiling(200_000, owner: owner)
        XCTAssertEqual(c.effectiveOverall(owner: owner), 200_000)
        c.setAdaptiveCeiling(nil, owner: owner)
        XCTAssertEqual(c.effectiveOverall(owner: owner), 1_000_000); XCTAssertEqual(c.overallLimit(owner: owner), 1_000_000)
        c.setOverallLimit(nil, owner: owner)
        XCTAssertNil(c.effectiveOverall(owner: owner))
    }

    func testAnAdaptiveCeilingAloneSlowsADownloadAndIsReportedAsAdaptive() {
        let task = UUID(), owner = UUID(), clock = FakeMonotonic(), c = BandwidthController(clock: clock)
        TransferOwnership.shared.assign(task, owner: owner)
        c.setAdaptiveCeiling(100_000, owner: owner)
        let got = drive(c, clock: clock, task: task, seconds: 10)
        XCTAssertEqual(Double(got) / 10, 100_000, accuracy: 20_000)
        XCTAssertEqual(c.effectiveLimit(for: task)?.source, .adaptive)
        c.setOverallLimit(50_000, owner: owner)
        XCTAssertEqual(c.effectiveLimit(for: task)?.bytesPerSecond, 50_000); XCTAssertEqual(c.effectiveLimit(for: task)?.source, .overall)
    }

    func testOneProfilesLimitDoesNotSlowAnother() {
        let a = UUID(), b = UUID(), ta = UUID(), tb = UUID(), clock = FakeMonotonic(), c = BandwidthController(clock: clock)
        TransferOwnership.shared.assign(ta, owner: a); TransferOwnership.shared.assign(tb, owner: b)
        c.setOverallLimit(100_000, owner: a)
        let gotA = drive(c, clock: clock, task: ta, seconds: 5)
        XCTAssertEqual(Double(gotA) / 5, 100_000, accuracy: 25_000)
        XCTAssertEqual(c.reserve(task: tb, bytes: 50_000_000), 0, "profile B has no limit and is never made to wait")
        c.setOverallLimit(5_000_000, owner: b)
        XCTAssertEqual(c.overallLimit(owner: a), 100_000, "B's setting did not replace A's"); XCTAssertEqual(c.overallLimit(owner: b), 5_000_000)
        XCTAssertNil(c.overallLimit(owner: UUID()), "an unknown profile has none")
    }

    func testEachProfileSharesItsOwnLimitAmongItsOwnDownloads() {
        let a = UUID(), b = UUID(), clock = FakeMonotonic(), c = BandwidthController(clock: clock)
        let a1 = UUID(), a2 = UUID(), b1 = UUID()
        for (t, o) in [(a1, a), (a2, a), (b1, b)] { TransferOwnership.shared.assign(t, owner: o) }
        c.setOverallLimit(200_000, owner: a); c.setOverallLimit(200_000, owner: b)
        var got: [UUID: Int64] = [:]
        let end = clock.now() + 10
        var due: [UUID: Double] = [a1: clock.now(), a2: clock.now(), b1: clock.now()]
        while clock.now() < end {
            let (t, when) = due.min { $0.value < $1.value }!
            clock.set(max(clock.now(), when))
            let wait = c.reserve(task: t, bytes: 8 * 1024); got[t, default: 0] += 8 * 1024
            due[t] = clock.now() + max(wait, 0.001)
        }
        let aTotal = Double(got[a1]! + got[a2]!) / 10, bTotal = Double(got[b1]!) / 10
        XCTAssertEqual(aTotal, 200_000, accuracy: 50_000, "A's two downloads share A's limit"); XCTAssertEqual(bTotal, 200_000, accuracy: 50_000, "B's one gets all of B's")
    }

    func testConnectionCapsAreTheProfilesOwnAndTheTotalsAreShared() {
        let budget = ConnectionBudget()
        budget.totalLimitOverride = 10
        let a = UUID(), b = UUID(), ta = UUID(), tb = UUID()
        TransferOwnership.shared.assign(ta, owner: a); TransferOwnership.shared.assign(tb, owner: b)
        budget.setHostLimit(2, owner: a); budget.setHostLimit(6, owner: b)
        XCTAssertEqual((0..<8).filter { _ in budget.acquire(host: "x.org", task: ta) }.count, 2, "A is held to its own cap of 2")
        XCTAssertEqual((0..<8).filter { _ in budget.acquire(host: "x.org", task: tb) }.count, 6, "B has 6 although A set 2")
        XCTAssertEqual(budget.holding(owner: a), 2); XCTAssertEqual(budget.holding(owner: b), 6)
        XCTAssertEqual(budget.open, 8)
        XCTAssertTrue(budget.acquire(host: "y.org", task: tb)); XCTAssertTrue(budget.acquire(host: "y.org", task: tb))
        XCTAssertFalse(budget.acquire(host: "z.org", task: tb), "the shared total of 10 holds")
        budget.release(task: ta)
        XCTAssertEqual(budget.holding(owner: a), 0); XCTAssertEqual(budget.open, 8)
        XCTAssertTrue(budget.acquire(host: "z.org", task: tb))
        budget.release(task: tb)
        XCTAssertEqual(budget.open, 0); XCTAssertEqual(budget.holding(owner: b), 0, "nothing leaks")
        budget.release(task: tb); XCTAssertEqual(budget.open, 0, "a repeated release is harmless")
    }

    func testThePhysicalPerWebsiteCeilingBindsAllProfilesTogether() {
        let budget = ConnectionBudget()
        let a = UUID(), b = UUID(), ta = UUID(), tb = UUID()
        TransferOwnership.shared.assign(ta, owner: a); TransferOwnership.shared.assign(tb, owner: b)
        XCTAssertEqual((0..<8).filter { _ in budget.acquire(host: "x.org", task: ta) }.count, 8)
        XCTAssertFalse(budget.acquire(host: "x.org", task: tb), "8 to one website is the most for everyone together")
        XCTAssertTrue(budget.acquire(host: "y.org", task: tb))
    }

    @MainActor
    func testTwoCoordinatorsKeepTheirOwnSpeedLimitsAndConnectionCaps() {
        let a = DownloadCoordinator(), b = DownloadCoordinator()
        defer { BandwidthController.shared.setOverallLimit(nil, owner: a.ownerID); BandwidthController.shared.setOverallLimit(nil, owner: b.ownerID); ConnectionBudget.shared.setHostLimit(nil, owner: a.ownerID); ConnectionBudget.shared.setHostLimit(nil, owner: b.ownerID) }
        var sa = DownloadNetworkSettings(); sa.overallLimit = 1_000_000; sa.perHostConnections = 2; sa.requestTimeout = 20; sa.maxAutomaticRetries = 1
        var sb = DownloadNetworkSettings(); sb.overallLimit = 5_000_000; sb.perHostConnections = 6; sb.requestTimeout = 90; sb.maxAutomaticRetries = 8
        let savedTimeout = HTTPRequestPolicy.defaultRequestTimeout, savedAttempts = HTTPRetrySchedule.maxAttempts
        a.networkSettings = sa; b.networkSettings = sb
        XCTAssertNotEqual(a.ownerID, b.ownerID)
        XCTAssertEqual(BandwidthController.shared.overallLimit(owner: a.ownerID), 1_000_000); XCTAssertEqual(BandwidthController.shared.overallLimit(owner: b.ownerID), 5_000_000, "B did not replace A's")
        XCTAssertEqual(ConnectionBudget.shared.hostLimit(owner: a.ownerID), 2); XCTAssertEqual(ConnectionBudget.shared.hostLimit(owner: b.ownerID), 6)
        XCTAssertEqual(DownloadNetworkSetup(sa.normalized(), password: nil).maxAttempts, 2); XCTAssertEqual(DownloadNetworkSetup(sb.normalized(), password: nil).maxAttempts, 9)
        XCTAssertEqual(DownloadNetworkSetup(sa.normalized(), password: nil).requestTimeout, 20); XCTAssertEqual(DownloadNetworkSetup(sb.normalized(), password: nil).requestTimeout, 90)
        XCTAssertEqual(HTTPRequestPolicy.defaultRequestTimeout, savedTimeout, "no process-wide timeout is written any more"); XCTAssertEqual(HTTPRetrySchedule.maxAttempts, savedAttempts)
        XCTAssertEqual(a.networkSettings.proxy, DownloadNetworkSettings.Proxy())
        XCTAssertNil(BandwidthController.shared.overallLimit, "nothing was written to the shared default owner")
    }

    func testRetryRuleUsesTheProfilesOwnCount() {
        let transient = HTTPDownloadError(info: DownloadFailureInfo(code: "http:503", reason: "busy", retryable: true))
        XCTAssertTrue(HTTPRetrySchedule.mayRetry(transient, attempt: 1, max: 3)); XCTAssertFalse(HTTPRetrySchedule.mayRetry(transient, attempt: 3, max: 3))
        XCTAssertTrue(HTTPRetrySchedule.mayRetry(transient, attempt: 3, max: 9))
    }
}


// MARK: - Review fixes

final class Phase22ReviewFixTests: XCTestCase {
    func testALiveTasksOwnerSurvivesAFloodOfNewerTasks() {
        let budget = ConnectionBudget(), owner = UUID(), live = UUID()
        TransferOwnership.shared.assign(live, owner: owner)
        XCTAssertTrue(budget.acquire(host: "x.org", task: live))
        for _ in 0..<(TransferOwnership.capacity + 500) { TransferOwnership.shared.assign(UUID(), owner: UUID()) }
        XCTAssertEqual(TransferOwnership.shared.owner(of: live), owner, "a task that holds a lease is never evicted")
        budget.release(task: live)
        XCTAssertEqual(budget.holding(owner: owner), 0)
    }

    func testAConnectionIsGivenBackToTheOwnerItWasGrantedTo() {
        let budget = ConnectionBudget(), a = UUID(), b = UUID(), task = UUID()
        TransferOwnership.shared.assign(task, owner: a)
        XCTAssertTrue(budget.acquire(host: "x.org", task: task))
        TransferOwnership.shared.assign(task, owner: b)               // the registry changes its mind (or the entry is lost) while the lease is held
        budget.release(host: "x.org", task: task)
        XCTAssertEqual(budget.holding(owner: a), 0, "A's count goes down, not B's"); XCTAssertEqual(budget.holding(owner: b), 0); XCTAssertEqual(budget.open, 0)
        TransferOwnership.shared.assign(task, owner: a)
        XCTAssertTrue(budget.acquire(host: "y.org", task: task)); XCTAssertTrue(budget.acquire(host: "y.org", task: task))
        TransferOwnership.shared.assign(task, owner: b)
        budget.release(task: task)
        XCTAssertEqual(budget.holding(owner: a), 0); XCTAssertEqual(budget.open, 0)
    }

    func testTheAdmissionQuestionIsAskedForTheTasksOwnProfile() {
        let budget = ConnectionBudget(), a = UUID(), b = UUID(), ta = UUID(), tb = UUID(), more = UUID()
        TransferOwnership.shared.assign(ta, owner: a); TransferOwnership.shared.assign(tb, owner: b); TransferOwnership.shared.assign(more, owner: a)
        budget.setHostLimit(1, owner: a)
        XCTAssertTrue(budget.acquire(host: "x.org", task: ta))
        XCTAssertFalse(budget.canGrant(1, scope: "x.org", task: more), "A is at its own cap of 1")
        XCTAssertTrue(budget.canGrant(1, scope: "x.org", task: tb), "B has no such cap and has not been counted out by A's")
        XCTAssertTrue(budget.canGrant(1, scope: "x.org", task: tb) == budget.acquire(host: "x.org", task: tb), "the question and the grant agree")
    }

    func testRepeatingTheSameAdaptiveCeilingChangesNothingAndWakesNobody() {
        let c = BandwidthController(), owner = UUID()
        final class Counter: @unchecked Sendable { var n = 0 }
        let counter = Counter()
        _ = c.observe { counter.n += 1 }
        c.setAdaptiveCeiling(500_000, owner: owner)
        XCTAssertEqual(counter.n, 1)
        for _ in 0..<10 { c.setAdaptiveCeiling(500_000, owner: owner) }
        XCTAssertEqual(counter.n, 1, "the same value again is not a change")
        c.setAdaptiveCeiling(nil, owner: owner); XCTAssertEqual(counter.n, 2)
        c.setAdaptiveCeiling(nil, owner: owner); XCTAssertEqual(counter.n, 2)
    }
}

// MARK: - Settings

final class AdaptiveSettingsTests: XCTestCase {
    func testOldSettingsReadAsUnlimitedAndTheNewOnesRoundTrip() {
        let old = #"{"overallLimit":1048576,"perHostConnections":3}"#
        let decoded = DownloadNetworkSettings.decode(old)
        XCTAssertEqual(decoded.adaptiveMode, .unlimited); XCTAssertEqual(decoded.browserGraceSeconds, DownloadNetworkSettings.defaultGrace); XCTAssertEqual(decoded.overallLimit, 1_048_576)
        var s = DownloadNetworkSettings(); s.adaptiveMode = .browserPriority; s.browserGraceSeconds = 20
        let back = DownloadNetworkSettings.decode(s.encoded())
        XCTAssertEqual(back.adaptiveMode, .browserPriority); XCTAssertEqual(back.browserGraceSeconds, 20)
        XCTAssertEqual(DownloadNetworkSettings.decode(#"{"adaptiveMode":"turbo"}"#).adaptiveMode, .unlimited, "an unknown mode is the safe one")
        var wild = DownloadNetworkSettings(); wild.browserGraceSeconds = 100_000
        XCTAssertEqual(wild.normalized().browserGraceSeconds, 60); wild.browserGraceSeconds = -3; XCTAssertEqual(wild.normalized().browserGraceSeconds, 2)
    }

    func testResetKeepsTheProxyAndTheNetworkRulesAndNothingElse() {
        var s = DownloadNetworkSettings()
        s.overallLimit = 1 << 20; s.adaptiveMode = .balanced; s.workersPerDownload = 2; s.perHostConnections = 2; s.requestTimeout = 100; s.maxAutomaticRetries = 9
        s.proxy = .init(mode: .socks5, host: "proxy.local", port: 1080, username: "me"); s.pauseOnExpensive = true; s.respectLowDataMode = true; s.waitForConnectivity = true
        let r = s.resettingSpeedAndConnections()
        XCTAssertNil(r.overallLimit); XCTAssertEqual(r.adaptiveMode, .unlimited); XCTAssertEqual(r.requestTimeout, DownloadNetworkSettings.defaultTimeout)
        XCTAssertEqual(r.proxy, s.proxy, "a reset never bypasses a proxy"); XCTAssertTrue(r.pauseOnExpensive && r.respectLowDataMode && r.waitForConnectivity)
    }

    func testAdaptiveModesDoNotTurnOnPeerNetworking() {
        XCTAssertFalse(TorrentSettings().enabled); XCTAssertFalse(ED2KSettings().enabled)
        var s = DownloadNetworkSettings(); s.adaptiveMode = .downloadPriority
        XCTAssertFalse(TorrentSettings().enabled)
    }
}

// MARK: - The controller on a real coordinator

@MainActor
final class AdaptiveControllerTests: XCTestCase {
    var c: DownloadCoordinator!
    var clock: FakeMonotonic!
    var browser: BrowserActivity!

    override func setUp() async throws {
        c = DownloadCoordinator()
        clock = FakeMonotonic()
        browser = BrowserActivity(clock: clock)
        c.adaptive.clock = clock; c.adaptive.browser = browser
        c.adaptive.lowPower = { false }; c.adaptive.thermalSerious = { false }
    }
    override func tearDown() async throws {
        BandwidthController.shared.setAdaptiveCeiling(nil, owner: c.ownerID); BandwidthController.shared.setOverallLimit(nil, owner: c.ownerID)
        c.adaptive.settingsChanged()
    }

    private func moveBytes(_ n: Int, task: UUID) { _ = BandwidthController.shared.reserve(task: task, bytes: n) }

    func testBalancedHoldsDownloadsBackOnlyWhileTheBrowserIsBusyAndReleasesAfterTheGrace() {
        var s = DownloadNetworkSettings(); s.adaptiveMode = .balanced; s.browserGraceSeconds = 4
        c.networkSettings = s
        let task = UUID(); TransferOwnership.shared.assign(task, owner: c.ownerID)
        _ = ConnectionBudget.shared.grant(1, scope: "h.test", task: task)
        defer { ConnectionBudget.shared.release(task: task) }
        c.adaptive.window = 4
        for _ in 0..<6 { clock.advance(2); moveBytes(2_000_000, task: task); c.adaptive.tick() }
        XCTAssertNil(BandwidthController.shared.adaptiveCeiling(owner: c.ownerID), "idle browser: nothing held back")
        browser.navigationStarted()
        clock.advance(2); moveBytes(2_000_000, task: task); c.adaptive.tick()
        let held = BandwidthController.shared.adaptiveCeiling(owner: c.ownerID)
        XCTAssertNotNil(held); XCTAssertLessThan(held!, 1_000_000, "a share of the 1 MB/s measured")
        XCTAssertEqual(c.adaptive.snapshot.rateCeiling, held); XCTAssertTrue(c.adaptive.snapshot.browserBusy)
        browser.navigationEnded()
        clock.advance(2); c.adaptive.tick(); XCTAssertNotNil(BandwidthController.shared.adaptiveCeiling(owner: c.ownerID), "within the 4 s grace")
        clock.advance(6); c.adaptive.tick(); XCTAssertNil(BandwidthController.shared.adaptiveCeiling(owner: c.ownerID), "released afterwards")
        XCTAssertFalse(c.adaptive.events.isEmpty); XCTAssertLessThanOrEqual(c.adaptive.events.count, AdaptiveController.maxEvents)
        XCTAssertFalse(c.adaptive.events.contains { $0.contains("http") || $0.contains("://") }, "events say nothing about addresses")
    }

    func testChangingTheModeToUnlimitedLiftsEverythingAndKeepsTheManualLimit() {
        var s = DownloadNetworkSettings(); s.adaptiveMode = .browserPriority; s.overallLimit = 3_000_000
        c.networkSettings = s
        BandwidthController.shared.setAdaptiveCeiling(100_000, owner: c.ownerID)
        XCTAssertEqual(BandwidthController.shared.effectiveOverall(owner: c.ownerID), 100_000)
        s.adaptiveMode = .unlimited; c.networkSettings = s
        XCTAssertNil(BandwidthController.shared.adaptiveCeiling(owner: c.ownerID)); XCTAssertEqual(BandwidthController.shared.effectiveOverall(owner: c.ownerID), 3_000_000, "the manual limit is untouched")
        XCTAssertNil(c.http.adaptiveWorkerCeiling)
    }

    func testRepeatedTransientErrorsLowerTheWorkerCeilingOnTheHTTPRunner() {
        var s = DownloadNetworkSettings(); s.adaptiveMode = .balanced; s.workersPerDownload = 8
        c.networkSettings = s
        c.adaptive.noteTransient(); c.adaptive.noteTransient()
        clock.advance(2); c.adaptive.tick()
        XCTAssertEqual(c.http.adaptiveWorkerCeiling, 6)
        s.adaptiveMode = .custom; c.networkSettings = s
        XCTAssertNil(c.http.adaptiveWorkerCeiling, "custom does nothing by itself")
    }

    func testANetworkHoldSuspendsAdaptiveLimitsAndTheTimerStopsWhenIdle() {
        var s = DownloadNetworkSettings(); s.adaptiveMode = .browserPriority; s.waitForConnectivity = true
        c.networkSettings = s
        c.networkPath = { PathInfo(online: false) }
        c.evaluateNetworkHold(PathInfo(online: false))
        XCTAssertNotNil(c.networkHold)
        browser.navigationStarted(); clock.advance(2); c.adaptive.tick()
        XCTAssertNil(BandwidthController.shared.adaptiveCeiling(owner: c.ownerID), "held downloads are not also throttled, and not resumed by this")
        c.networkPath = { PathInfo() }; c.evaluateNetworkHold(PathInfo())
        var stopped = false
        for _ in 0..<AdaptiveController.idleTicksBeforeStop { clock.advance(2); stopped = !c.adaptive.tick() || stopped }
        XCTAssertTrue(stopped, "after a few looks with nothing moving the timer may stop")
    }

    func testTheTimerOnlyRunsInAdaptiveModes() async throws {
        var s = DownloadNetworkSettings(); s.adaptiveMode = .unlimited
        c.networkSettings = s
        c.adaptive.startIfNeeded()
        XCTAssertEqual(c.adaptive.snapshot.mode, .unlimited)
        s.adaptiveMode = .balanced; c.networkSettings = s
        c.adaptive.interval = 0.05
        c.adaptive.startIfNeeded()
        try await Task.sleep(nanoseconds: 300_000_000)
        s.adaptiveMode = .unlimited; c.networkSettings = s      // cancels it
        XCTAssertNil(c.http.adaptiveWorkerCeiling)
    }
}

// MARK: - Integration with the multipart engine and mirrors (local fixture server)

@MainActor
final class AdaptiveTransferTests: MediaCase {
    static let big: Data = { var b = [UInt8](repeating: 0, count: 20 << 20); for i in 0..<b.count { b[i] = UInt8(truncatingIfNeeded: (i &* 37 &+ 11) % 251) }; return Data(b) }()
    static let bigHash = SHA256.hash(data: big).map { String(format: "%02x", $0) }.joined()
    private func hash(_ path: String?) -> String? {
        guard let path, let d = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }
    private func begin(_ primary: String, mirrors: [String] = [], sha: String? = nil) throws -> UUID {
        c.segmentedEnabled = true
        let id = try XCTUnwrap(c.scheduleDownload(url: url("/media/\(primary)"), at: Date(), expectedSHA256: sha, origin: .user))
        if !mirrors.isEmpty { c.mirrors.add(mirrors.map { url("/media/\($0)").absoluteString }, to: id) }
        return id
    }

    func testAWorkerCeilingOfOneKeepsAFileToOneConnectionAndItStillCompletesCorrectly() async throws {
        try await put("a22/one.bin", Self.big)
        var s = DownloadNetworkSettings(); s.workersPerDownload = 4; c.networkSettings = s
        c.http.setAdaptiveWorkerCeiling(1)
        let id = try begin("a22/one.bin", sha: Self.bigHash)
        var peak = 0
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            peak = max(peak, ConnectionBudget.shared.holding(task: id))
            if let st = c.ledger.record(id)?.state, st == .completed || st == .failed { break }
            try await Task.sleep(nanoseconds: 3_000_000)
        }
        let record = c.ledger.record(id)
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? ""); XCTAssertEqual(hash(record?.file.destinationPath), Self.bigHash)
        XCTAssertLessThanOrEqual(peak, 2, "one worker (plus at most the lease being handed over); peak \(peak)")
        XCTAssertEqual(ConnectionBudget.shared.holding(task: id), 0, "every lease given back")
    }

    func testRaisingTheCeilingMidwayLetsMoreWorkersRunAndNothingIsRestarted() async throws {
        try await put("a22/two.bin", Self.big)
        var s = DownloadNetworkSettings(); s.workersPerDownload = 4; c.networkSettings = s
        c.http.setAdaptiveWorkerCeiling(1)
        let id = try begin("a22/two.bin", sha: Self.bigHash)
        try await Task.sleep(nanoseconds: 150_000_000)
        c.http.setAdaptiveWorkerCeiling(nil)
        let record = await wait(id, for: [.completed, .failed], seconds: 90)
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? ""); XCTAssertEqual(hash(record?.file.destinationPath), Self.bigHash)
        XCTAssertEqual(record?.engineMetadata["multipartRestarts"], nil, "no restart")
    }

    func testVerifiedMirrorsAreStillUsedUnderAnAdaptiveModeAndTheirRatesAreReportedPerSource() async throws {
        try await put("a22/m1.bin", Self.big); try await put("a22/m2.bin", Self.big)
        var s = DownloadNetworkSettings(); s.adaptiveMode = .balanced; s.workersPerDownload = 4; c.networkSettings = s
        let id = try begin("a22/m1.bin", mirrors: ["a22/m2.bin"], sha: Self.bigHash)
        var sawRates = false
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            if let r = c.http.sourceRates(id), r.count == 2 { sawRates = true }
            if let st = c.ledger.record(id)?.state, st == .completed || st == .failed { break }
            try await Task.sleep(nanoseconds: 3_000_000)
        }
        let record = c.ledger.record(id)
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? ""); XCTAssertEqual(hash(record?.file.destinationPath), Self.bigHash)
        XCTAssertTrue(sawRates, "two sources were measured while the file moved")
        XCTAssertEqual(record?.engineMetadata["origin"], "user"); XCTAssertEqual(ConnectionBudget.shared.holding(task: id), 0)
    }

    func testAnIntegrityFailureIsNotMistakenForATransientOneAndStaysDisabled() async throws {
        try await put("a22/g.bin", Self.big)
        var wrong = Self.big
        for i in stride(from: 4096, to: wrong.count, by: 1 << 20) { wrong[i] ^= 0x33 }
        try await put("a22/w.bin", wrong)
        var s = DownloadNetworkSettings(); s.adaptiveMode = .downloadPriority; c.networkSettings = s
        let id = try begin("a22/g.bin", mirrors: ["a22/w.bin"], sha: Self.bigHash)
        let record = await wait(id, for: [.completed, .failed], seconds: 120)
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? ""); XCTAssertEqual(hash(record?.file.destinationPath), Self.bigHash)
        XCTAssertEqual(record?.engineMetadata["mirrorsDisabled"], "1", "the bad source is not brought back by adaptive control")
        XCTAssertTrue(c.mirrors.mirrors(of: id).allSatisfy { !$0.isUsable })
    }

    func testPageDerivedRequestsStillGetNoMultipartAndNoExtraConnectionsUnderAnyMode() async throws {
        try await put("a22/p.bin", Self.big)
        var s = DownloadNetworkSettings(); s.adaptiveMode = .downloadPriority; s.workersPerDownload = 8; c.networkSettings = s
        c.segmentedEnabled = true
        let id = try XCTUnwrap(c.scheduleDownload(url: url("/media/a22/p.bin"), at: Date(), expectedSHA256: nil, origin: .page))
        var peak = 0
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            peak = max(peak, ConnectionBudget.shared.holding(task: id))
            if let st = c.ledger.record(id)?.state, st == .completed || st == .failed { break }
            try await Task.sleep(nanoseconds: 3_000_000)
        }
        XCTAssertLessThanOrEqual(peak, 1, "one connection")
        XCTAssertNotEqual(c.ledger.record(id)?.engineMetadata["mode"], "multipart")
    }

    /// Measured, not assumed: the same 20 MiB loopback file with the browser busy in the middle of the transfer. Printed for the report; asserts only what must hold.
    func testMeasuredEffectOfBrowserPriorityOnARateLimitedTransfer() async throws {
        try await put("a22/perf.bin", Self.big)
        func run(_ mode: AdaptiveMode, busy: Bool) async throws -> (seconds: Double, ceilingSeen: Bool, hash: String?) {
            let browser = BrowserActivity()
            c.adaptive.browser = browser; c.adaptive.interval = 0.25; c.adaptive.window = 1          // before the settings start the timer
            var s = DownloadNetworkSettings(); s.adaptiveMode = mode; s.overallLimit = 6 << 20; s.workersPerDownload = 2; s.browserGraceSeconds = 2
            c.networkSettings = s
            c.adaptive.startIfNeeded()
            let start = Date()
            let id = try begin("a22/perf.bin")
            if busy { browser.navigationStarted() }
            var seen = false, firstCeiling: (Double, Int64)?
            let deadline = Date().addingTimeInterval(120)
            while Date() < deadline {
                if let ceiling = BandwidthController.shared.adaptiveCeiling(owner: c.ownerID), !seen { seen = true; firstCeiling = (Date().timeIntervalSince(start), ceiling) }
                if let st = c.ledger.record(id)?.state, st == .completed || st == .failed { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let elapsed = Date().timeIntervalSince(start)
            let h = hash(c.ledger.record(id)?.file.destinationPath)
            NSLog("MEASURED debug mode %@ ownerOfTask==coordinator %d bytesForOwner %lld bytesDefaultOwner %lld total %lld", mode.rawValue, TransferOwnership.shared.owner(of: id) == c.ownerID ? 1 : 0, BandwidthController.shared.bytesAccounted(owner: c.ownerID), BandwidthController.shared.bytesAccounted(owner: TransferOwnership.defaultOwner), BandwidthController.shared.bytesAccounted)
            browser.navigationEnded()
            if let f = firstCeiling { NSLog("MEASURED ceiling %lld B/s first applied %.2f s into the transfer", f.1, f.0) }
            return (elapsed, seen, h)
        }
        let fixed = try await run(.unlimited, busy: true)
        let adaptive = try await run(.browserPriority, busy: true)
        NSLog("MEASURED 20 MiB at 6 MiB/s manual limit: fixed %.2f s (%.1f MiB/s); browser-priority with busy browser %.2f s (%.1f MiB/s); ceiling applied: %@",
              fixed.seconds, 20 / fixed.seconds, adaptive.seconds, 20 / adaptive.seconds, adaptive.ceilingSeen ? "yes" : "no")
        XCTAssertEqual(fixed.hash, Self.bigHash); XCTAssertEqual(adaptive.hash, Self.bigHash, "slower or not, the file is right")
        XCTAssertFalse(fixed.ceilingSeen, "unlimited mode never adds a ceiling")
        XCTAssertGreaterThanOrEqual(adaptive.seconds, fixed.seconds * 0.8, "adaptive control never makes the transfer faster than the fixed limit allows")
    }
}
