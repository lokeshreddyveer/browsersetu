import XCTest
@testable import Browser_Setu

final class ResourceGovernorTests: XCTestCase {
    private func power(battery: Bool = false, level: Double? = nil, low: Bool = false, thermal: ProcessInfo.ThermalState = .nominal) -> PowerState {
        PowerState(onBattery: battery, level: level, lowPowerMode: low, thermal: thermal)
    }

    func testBalancedBecomesBatterySaverOnlyWhenThereIsReason() {
        XCTAssertEqual(GovernorRules.effective(base: .balanced, power: power(), batteryAware: true, lowPowerSaves: true).mode, .balanced)
        XCTAssertEqual(GovernorRules.effective(base: .balanced, power: power(low: true), batteryAware: false, lowPowerSaves: true).mode, .battery)
        XCTAssertEqual(GovernorRules.effective(base: .balanced, power: power(battery: true, level: 0.15), batteryAware: true, lowPowerSaves: false).mode, .battery)
        XCTAssertEqual(GovernorRules.effective(base: .balanced, power: power(battery: true, level: 0.15), batteryAware: false, lowPowerSaves: false).mode, .balanced)
        XCTAssertEqual(GovernorRules.effective(base: .balanced, power: power(battery: true, level: 0.8), batteryAware: true, lowPowerSaves: true).mode, .balanced)
        XCTAssertEqual(GovernorRules.effective(base: .balanced, power: power(thermal: .serious), batteryAware: true, lowPowerSaves: false).mode, .battery)
    }

    func testAChosenProfileIsNeverOverridden() {
        XCTAssertEqual(GovernorRules.effective(base: .performance, power: power(low: true), batteryAware: true, lowPowerSaves: true).mode, .performance)
        XCTAssertEqual(GovernorRules.effective(base: .custom, power: power(battery: true, level: 0.05), batteryAware: true, lowPowerSaves: true).mode, .custom)
    }

    func testReasonIsGivenWhenSwitched() {
        XCTAssertEqual(GovernorRules.effective(base: .balanced, power: power(low: true), batteryAware: true, lowPowerSaves: true).reason, "Low Power Mode is on")
        XCTAssertEqual(GovernorRules.effective(base: .balanced, power: power(battery: true, level: 0.1), batteryAware: true, lowPowerSaves: true).reason, "the battery is at 10%")
        XCTAssertNil(GovernorRules.effective(base: .balanced, power: power(), batteryAware: true, lowPowerSaves: true).reason)
    }

    func testEnergyLabelsAndIntervalsAndThumbnails() {
        XCTAssertEqual(GovernorRules.energyLabel(averageCPU: 0.01), "Low")
        XCTAssertEqual(GovernorRules.energyLabel(averageCPU: 0.1), "Moderate")
        XCTAssertEqual(GovernorRules.energyLabel(averageCPU: 0.6), "High")
        XCTAssertGreaterThan(GovernorRules.watchInterval(for: .battery), GovernorRules.watchInterval(for: .balanced))
        XCTAssertFalse(GovernorRules.allowsThumbnails(mode: .battery, power: power()))
        XCTAssertFalse(GovernorRules.allowsThumbnails(mode: .balanced, power: power(thermal: .critical)))
        XCTAssertTrue(GovernorRules.allowsThumbnails(mode: .balanced, power: power()))
    }

    func testBatteryAndCustomProfilesReleaseIdleTabs() {
        let now = Date()
        func tab(_ id: UInt64, idle: TimeInterval, active: Bool = false) -> TabCandidate {
            TabCandidate(id: id, lastActive: now.addingTimeInterval(-idle), pinned: false, isPrivate: false, isActive: active, loaded: true, discarded: false)
        }
        let tabs = [tab(1, idle: 0, active: true), tab(2, idle: 400), tab(3, idle: 500), tab(4, idle: 900), tab(5, idle: 1000)]
        XCTAssertEqual(TabLifecyclePolicy.victims(tabs, mode: .battery, event: .timer, now: now, keepPinned: true), [5, 4, 3], "keeps the two most recent, releases the rest idle five minutes")
        let custom = CustomMemoryPolicy(keepRecent: 1, idleMinutes: 10)
        XCTAssertEqual(TabLifecyclePolicy.victims(tabs, mode: .custom, event: .timer, now: now, keepPinned: true, custom: custom), [5, 4])
        XCTAssertTrue(TabLifecyclePolicy.victims(tabs, mode: .balanced, event: .timer, now: now, keepPinned: true).isEmpty)
    }

    func testPerfLogKeepsTheLatestAndFlagsRegressions() {
        var list: [PerfRecord] = []
        let base = Date()
        for i in 0..<6 { list = PerfLog.add(PerfRecord(name: "start", millis: 400, date: base.addingTimeInterval(Double(i))), to: list) }
        XCTAssertEqual(PerfLog.compare("start", in: list)?.regression, false)
        list = PerfLog.add(PerfRecord(name: "start", millis: 900, date: base.addingTimeInterval(10)), to: list)
        XCTAssertEqual(PerfLog.compare("start", in: list)?.regression, true)
        for i in 0..<40 { list = PerfLog.add(PerfRecord(name: "start", millis: 400, date: base.addingTimeInterval(20 + Double(i))), to: list) }
        XCTAssertEqual(list.filter { $0.name == "start" }.count, PerfLog.keep)
        XCTAssertNil(PerfLog.compare("never", in: list))
    }
}
