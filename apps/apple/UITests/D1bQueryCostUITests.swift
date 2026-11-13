import XCTest

/// Diagnostic, not a gate: what one question about the tab chips costs the way the D1b many-tabs test asks it (one query per chip) against asking once (one snapshot of the window). With 100 tabs the first way
/// is 100 snapshots of the whole accessibility tree for every poll, which is what makes that test depend on the machine's load.
final class D1bQueryCostUITests: PerfCase {
    private func loadAverage() -> Double { var l = [Double](repeating: 0, count: 3); getloadavg(&l, 3); return l[0] }

    private func slowSelectedIndex() -> Int? { (0..<tabChips().count).first { chip($0).isSelected } }
    private func snapshotSelectedIndex() -> Int? {
        guard let snap = try? win.snapshot() else { return nil }
        var found: [Bool] = []
        func walk(_ s: XCUIElementSnapshot) { if s.identifier == "tab-chip" { found.append(s.isSelected) }; s.children.forEach(walk) }
        walk(snap)
        return found.firstIndex(of: true)
    }

    func testChipQueryCost() throws {
        for count in [10, 25] {
            launch(state: "bulk-tabs", extra: ["-UITabCount", "\(count)", "-UILayout", "minimal"], env: ["BS_WINDOW_SIZE": "800x800"])
            XCTAssertNotNil(until(30) { win.exists && tabChips().count >= count - 1 })
            Thread.sleep(forTimeInterval: 1.0)
            let t0 = PerfClock.ms(); let a = slowSelectedIndex(); let slow = PerfClock.ms() - t0
            let t1 = PerfClock.ms(); let b = snapshotSelectedIndex(); let fast = PerfClock.ms() - t1
            report.note(String(format: "QUERYCOST %d tabs: per-chip queries %.0f ms (selected %@), one snapshot %.0f ms (selected %@), load average %.1f", count, slow, String(describing: a), fast, String(describing: b), loadAverage()))
            XCTAssertEqual(a, b, "the two ways of asking disagree")
            app.terminate()
        }
    }
}
