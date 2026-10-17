import XCTest
@testable import Browser_Setu

final class SyncMergeTests: XCTestCase {
    typealias Cells = [String: SyncCell<String>]
    private func cell(_ v: String?, _ t: Double, _ d: String) -> SyncCell<String> { SyncCell(stamp: SyncStamp(time: t, device: d), value: v) }

    func testTheLaterChangeWinsAndTiesGoToTheHigherDeviceIdEverywhere() {
        let a: Cells = ["k": cell("old", 1, "A")], b: Cells = ["k": cell("new", 2, "B")]
        XCTAssertEqual(SyncMerge.merge(a, b)["k"]?.value, "new")
        XCTAssertEqual(SyncMerge.merge(b, a)["k"]?.value, "new")
        let t1: Cells = ["k": cell("fromA", 5, "A")], t2: Cells = ["k": cell("fromB", 5, "B")]
        XCTAssertEqual(SyncMerge.merge(t1, t2), SyncMerge.merge(t2, t1), "a tie is broken the same way in either order")
        XCTAssertEqual(SyncMerge.merge(t1, t2)["k"]?.value, "fromB")
    }

    func testADeletionBeatsAnOlderEditAndAnOlderDeletionLosesToANewerEdit() {
        let edited: Cells = ["k": cell("edited", 1, "A")], deleted: Cells = ["k": cell(nil, 2, "B")]
        XCTAssertNil(SyncMerge.merge(edited, deleted)["k"]?.value)
        let readded: Cells = ["k": cell("again", 3, "A")]
        XCTAssertEqual(SyncMerge.merge(deleted, readded)["k"]?.value, "again")
    }

    func testThreeDevicesInAnyOrderAnyNumberOfTimesAgree() {
        var rng = FuzzTests.Rng(state: 77)
        for round in 0..<200 {
            var devices: [Cells] = [[:], [:], [:]]
            for step in 0..<30 {
                let d = Int.random(in: 0..<3, using: &rng), key = "k\(Int.random(in: 0..<6, using: &rng))"
                let value: String? = Bool.random(using: &rng) ? "v\(round)-\(step)" : nil
                devices[d][key] = cell(value, Double(step) + Double.random(in: 0..<0.5, using: &rng), "dev\(d)")
                if Int.random(in: 0..<4, using: &rng) == 0 {                                  // sometimes two devices sync in the middle
                    let x = Int.random(in: 0..<3, using: &rng), y = Int.random(in: 0..<3, using: &rng)
                    devices[x] = SyncMerge.merge(devices[x], devices[y])
                }
            }
            // Everyone eventually hears from everyone, in a random order, some of it twice.
            for _ in 0..<12 { let x = Int.random(in: 0..<3, using: &rng), y = Int.random(in: 0..<3, using: &rng); devices[x] = SyncMerge.merge(devices[x], devices[y]) }
            for x in 0..<3 { for y in 0..<3 { devices[x] = SyncMerge.merge(devices[x], devices[y]) } }
            XCTAssertEqual(devices[0], devices[1]); XCTAssertEqual(devices[1], devices[2])
        }
    }

    func testMergingIsIdempotentAndCommutative() {
        let a: Cells = ["x": cell("1", 1, "A"), "y": cell(nil, 4, "A")], b: Cells = ["x": cell("2", 3, "B"), "z": cell("3", 1, "B")]
        let m = SyncMerge.merge(a, b)
        XCTAssertEqual(SyncMerge.merge(m, b), m); XCTAssertEqual(SyncMerge.merge(m, a), m); XCTAssertEqual(SyncMerge.merge(b, a), m)
    }

    func testChangesOnThisDeviceAreStampedAndRemovalsBecomeTombstones() {
        var clock = SyncClock(), ledger: Cells = [:]
        let t0 = Date(timeIntervalSince1970: 1000)
        SyncMerge.observe(ledger: &ledger, current: ["a": "1", "b": "2"], clock: &clock, device: "me", now: t0)
        XCTAssertEqual(ledger["a"]?.value, "1")
        let stampA = ledger["a"]?.stamp
        SyncMerge.observe(ledger: &ledger, current: ["a": "1"], clock: &clock, device: "me", now: t0.addingTimeInterval(5))
        XCTAssertEqual(ledger["a"]?.stamp, stampA, "unchanged things keep their stamp")
        XCTAssertNil(ledger["b"]?.value, "removed things become tombstones")
        XCTAssertGreaterThan(ledger["b"]!.stamp, stampA!)
    }

    func testAClockThatRunsSlowNeverHandsOutAStampBelowOneItHasSeen() {
        var clock = SyncClock()
        clock.observe(SyncStamp(time: 5000, device: "other"))
        let s = clock.stamp(now: Date(timeIntervalSince1970: 100), device: "me")
        XCTAssertGreaterThan(s.time, 5000)
        XCTAssertGreaterThan(clock.stamp(now: Date(timeIntervalSince1970: 100), device: "me"), s)
    }

    func testThePlanSaysOnlyWhatMustChangeHere() {
        let merged: Cells = ["keep": cell("same", 1, "A"), "new": cell("added", 2, "B"), "gone": cell(nil, 3, "B"), "alreadyGone": cell(nil, 3, "B"), "edit": cell("theirs", 4, "B")]
        let plan = SyncMerge.plan(merged: merged, current: ["keep": "same", "gone": "x", "edit": "mine"])
        XCTAssertEqual(plan.upsert, ["new": "added", "edit": "theirs"])
        XCTAssertEqual(plan.delete, ["gone"])
        XCTAssertTrue(SyncMerge.plan(merged: merged, current: ["keep": "same", "new": "added", "edit": "theirs"]).isEmpty)
    }

    func testOldTombstonesAreForgottenButLiveValuesAreKept() {
        let now = Date(timeIntervalSince1970: 400 * 24 * 3600)
        var state = SyncState()
        state.settings["live"] = cell("v", 1, "A")
        state.settings["oldGone"] = cell(nil, now.timeIntervalSince1970 - 100 * 24 * 3600, "A")
        state.settings["freshGone"] = cell(nil, now.timeIntervalSince1970 - 10 * 24 * 3600, "A")
        let pruned = SyncMerge.pruned(state, now: now)
        XCTAssertEqual(Set(pruned.settings.keys), ["live", "freshGone"])
    }

    func testAStaleSnapshotCannotUndoANewerChange() {
        let newer: Cells = ["k": cell("current", 100, "A")]
        let stale: Cells = ["k": cell("ancient", 1, "B")]
        XCTAssertEqual(SyncMerge.merge(newer, stale)["k"]?.value, "current")
        XCTAssertEqual(SyncMerge.merge(stale, newer)["k"]?.value, "current")
    }
}
