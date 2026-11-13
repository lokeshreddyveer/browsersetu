import XCTest

/// Read-only look at what chrome exists while One Row appears: at startup from a saved One Row profile, and when switching to and from it.
/// Samples the accessibility tree as fast as it can be read and records, per sample, the One Row bar, every "tab-bar" element (Classic's and Minimal's strips are also called that) and the address fields.
final class D1cOneRowTransitionUITests: PerfCase {
    struct Sample: Equatable { var inline: Bool; var tabBars: [String]; var fields: [String] }

    private func sample() -> Sample {
        let w = win.frame
        func box(_ e: XCUIElement) -> String { let f = e.frame; return "y\(Int(f.minY - w.minY)) h\(Int(f.height)) x\(Int(f.minX - w.minX)) w\(Int(f.width))" }
        let bars = win.descendants(matching: .any).matching(identifier: "tab-bar").allElementsBoundByIndex.map(box)
        let fields = win.descendants(matching: .any).matching(identifier: "omnibox").allElementsBoundByIndex.map(box)
        return Sample(inline: any("inline-bar").exists, tabBars: bars, fields: fields)
    }

    /// Samples for `seconds`, keeping the first sample and every change; returns the lines.
    private func trace(_ name: String, seconds: Double, whileDoing action: (() -> Void)? = nil) -> [String] {
        var lines: [String] = [], last: Sample?
        let t0 = PerfClock.ms()
        var acted = action == nil
        while PerfClock.ms() - t0 < seconds * 1000 {
            if !acted { acted = true; action?() ; lines.append("\(name) t=\(Int(PerfClock.ms() - t0)) ACTION returned") }
            let s = sample()
            if s != last { lines.append("\(name) t=\(Int(PerfClock.ms() - t0)) inline=\(s.inline) tabBars=\(s.tabBars) fields=\(s.fields)"); last = s }
        }
        return lines
    }

    private var traceFile: String { NSTemporaryDirectory() + "bs-chrome-trace.log" }
    /// The seconds from the preset change to the last view that leaves: the old chrome must go at once, not fade under the new one.
    @discardableResult private func dumpTrace(_ title: String) -> Double? {
        let text = (try? String(contentsOfFile: traceFile, encoding: .utf8)) ?? ""
        text.split(separator: "\n").forEach { report.note("CHROMETRACE \(title) | \($0)") }
        try? FileManager.default.removeItem(atPath: traceFile)
        let rows = text.split(separator: "\n").map { $0.split(separator: " ", maxSplits: 1).map(String.init) }
        guard let change = rows.first(where: { $0.count == 2 && $0[1].hasPrefix("PRESET") && $0[1].contains("applying=false") }), let t0 = Double(change[0]) else { return nil }
        let leaves = rows.filter { $0.count == 2 && $0[1].hasPrefix("DISAPPEAR") }.compactMap { Double($0[0]) }
        return leaves.max().map { $0 - t0 }
    }
    private func switchLayout(_ name: String) {
        app.typeKey("k", modifierFlags: .command)
        _ = until(8) { any("palette-field").exists }
        paste("Layout: \(name)"); app.typeKey(.return, modifierFlags: [])
    }

    /// A profile that saved a layout starts straight in it: the first chrome mounted is that layout's, nothing else is ever mounted, and nothing is taken away again (a Classic bar replaced by One Row would be a flash).
    func testDirectStartupMountsOnlyTheSavedLayout() throws {
        let cases: [(preset: String, expected: Set<String>)] = [("inline", ["InlineBar"]), ("classic", ["TopBar.standard", "HorizontalTabStrip"]), ("minimal", ["TopBar.standard", "CompactTabStrip"])]
        for (preset, expected) in cases {
            let root = "d1c-trans-\(UUID().uuidString.prefix(6))"
            try? FileManager.default.removeItem(atPath: traceFile)
            launch(state: "none", root: root, env: ["BS_LAYOUT": preset, "BS_WINDOW_SIZE": "1000x800"])
            Thread.sleep(forTimeInterval: 2.5)
            app.terminate()
            try? FileManager.default.removeItem(atPath: traceFile)
            // Second launch: nothing asks for a layout; the saved setting alone decides.
            app = XCUIApplication()
            app.launchArguments += ["-UITestRoot", root, "-UIState", "none"]
            app.launchEnvironment["CFFIXED_USER_HOME"] = NSTemporaryDirectory() + "bs-ui-home"
            app.launchEnvironment["BS_CHROME_TRACE"] = traceFile
            app.launch()
            let lines = trace("STARTUP \(preset)", seconds: 3)
            if preset == "inline" { attachShot("one-row-direct-startup") }
            let events = ((try? String(contentsOfFile: traceFile, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            dumpTrace("direct startup \(preset)")
            lines.forEach { report.note("TRANS " + $0) }
            func names(_ kind: String) -> [String] { events.filter { $0.contains(" \(kind) ") }.compactMap { $0.split(separator: " ").dropFirst(2).first.map(String.init) } }
            XCTAssertEqual(Set(names("APPEAR")), expected, "\(preset): the chrome mounted at startup was \(names("APPEAR")) (events \(events))")
            XCTAssertTrue(names("DISAPPEAR").isEmpty, "\(preset): chrome was taken away again after startup (a flash): \(names("DISAPPEAR"))")
            XCTAssertTrue(events.contains { $0.contains("PRESET classic -> \(preset)") || preset == "classic" }, "\(preset): the saved layout was not applied while the model was starting (events \(events))")
            app.terminate()
        }
    }

    /// Minimal -> Sidebar measured twice in one app run: the first time the Sidebar layout is ever built (cold) and again after a round trip (warm). The command palette and Minimal are warmed first, so the cold figure is
    /// the Sidebar's own. Both are recorded from the app's own trace (preset change -> last old view leaving) and from the accessibility tree (when the Sidebar first shows). Only the warm figure is asserted: the cold one is
    /// what `testSwitchesIntoAndOutOfOneRow` keeps measuring against its 0.2 s expectation, unchanged.
    func testMinimalToSidebarColdAndWarm() throws {
        try? FileManager.default.removeItem(atPath: traceFile)
        launch(state: "bulk-tabs", extra: ["-UITabCount", "6", "-UILayout", "classic"], env: ["BS_WINDOW_SIZE": "1000x800", "BS_CHROME_TRACE": traceFile])
        Thread.sleep(forTimeInterval: 1.5); _ = dumpTrace("launch")
        switchLayout("Minimal"); Thread.sleep(forTimeInterval: 2.0); _ = dumpTrace("warm-up classic->minimal")
        var summary: [String] = [], warmGone: Double?
        for round in ["cold", "warm"] {
            let t0 = PerfClock.ms(); var acted = false; var sidebarSeenAt: Double?
            while PerfClock.ms() - t0 < 2500 {
                if !acted { acted = true; switchLayout("Sidebar") }
                if sidebarSeenAt == nil, snapItems().contains(where: { $0.id == "sidebar" }) { sidebarSeenAt = PerfClock.ms() - t0 }
            }
            let gone = dumpTrace("minimal->sidebar \(round)")
            summary.append("\(round): old chrome left \(gone.map { String(format: "%.3f", $0) } ?? "n/a") s after the preset changed; the Sidebar first showed \(sidebarSeenAt.map { String(format: "%.0f", $0) } ?? "never") ms after the command started")
            if round == "warm" { warmGone = gone }
            attachShot("minimal-to-sidebar-\(round)")
            switchLayout("Minimal"); Thread.sleep(forTimeInterval: 2.0); _ = dumpTrace("sidebar->minimal after \(round)")
        }
        let note = XCTAttachment(string: summary.joined(separator: "\n")); note.name = "cold-warm-summary"; note.lifetime = .keepAlways; add(note)
        report.note("COLDWARM " + summary.joined(separator: " | "))
        XCTAssertNotNil(warmGone, "no trace for the warm switch")
        if let warmGone { XCTAssertLessThan(warmGone, 0.2, "warm Minimal->Sidebar: the old chrome stayed mounted for \(warmGone) s (\(summary))") }
    }

    /// A slow, widely spaced sequence made to be profiled (nothing is asserted): the failing Minimal -> Sidebar switch cold and warm, and two switches that pass (Sidebar -> Classic, Classic -> Sidebar) as controls. Each step's trace
    /// (the app's own uptime-clock times for the preset change and for the old chrome leaving) is written to the report, so the profile can be lined up with it; the steps are 4 s apart so each is its own window in the capture.
    func testProfileMinimalToSidebarWithControls() throws {
        try? FileManager.default.removeItem(atPath: traceFile)
        launch(state: "bulk-tabs", extra: ["-UITabCount", "6", "-UILayout", "classic"], env: ["BS_WINDOW_SIZE": "1000x800", "BS_CHROME_TRACE": traceFile])
        Thread.sleep(forTimeInterval: 3.0); _ = dumpTrace("launch")
        let steps: [(label: String, target: String)] = [("classic->minimal (palette warm-up)", "Minimal"), ("minimal->sidebar COLD", "Sidebar"), ("sidebar->minimal", "Minimal"),
                                                        ("minimal->sidebar WARM", "Sidebar"), ("sidebar->classic CONTROL", "Classic"), ("classic->sidebar CONTROL", "Sidebar")]
        var summary: [String] = []
        for step in steps {
            switchLayout(step.target)
            Thread.sleep(forTimeInterval: 4.0)
            let gone = dumpTrace(step.label)
            summary.append("\(step.label): old chrome left \(gone.map { String(format: "%.3f", $0) } ?? "n/a") s after the preset changed")
        }
        let note = XCTAttachment(string: summary.joined(separator: "\n")); note.name = "profile-steps"; note.lifetime = .keepAlways; add(note)
        report.note("PROFILESTEPS " + summary.joined(separator: " | "))
    }

    func testSwitchesIntoAndOutOfOneRow() throws {
        try? FileManager.default.removeItem(atPath: traceFile)
        launch(state: "bulk-tabs", extra: ["-UITabCount", "6", "-UILayout", "classic"], env: ["BS_WINDOW_SIZE": "1000x800", "BS_CHROME_TRACE": traceFile])
        Thread.sleep(forTimeInterval: 1.5)
        dumpTrace("debug-state launch (classic requested)")
        for (from, to) in [("classic", "One Row"), ("One Row", "Classic"), ("Classic", "Minimal"), ("Minimal", "One Row"), ("One Row", "Minimal"), ("Minimal", "Sidebar"), ("Sidebar", "Classic"), ("Classic", "Sidebar"), ("Sidebar", "One Row")] {
            let lines = trace("\(from)->\(to)", seconds: 2.2) { self.switchLayout(to) }
            lines.forEach { report.note("TRANS " + $0) }
            if let gone = dumpTrace("\(from)->\(to)") { XCTAssertLessThan(gone, 0.2, "\(from)->\(to): the old chrome stayed mounted for \(gone) s under the new one") }
            // After it settles there is exactly one top bar, and it is the right one.
            let end = sample()
            if to == "One Row" { XCTAssertTrue(end.inline, "\(from)->\(to): One Row bar missing at the end"); XCTAssertLessThanOrEqual(end.tabBars.count, 1, "\(from)->\(to): tab strips at the end \(end.tabBars)") }
            else { XCTAssertFalse(end.inline, "\(from)->\(to): One Row bar still there") }
            if to == "One Row" { attachShot("one-row-after-\(from.lowercased().replacingOccurrences(of: " ", with: ""))") }
        }
    }
}
