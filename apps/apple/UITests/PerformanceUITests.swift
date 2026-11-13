import XCTest
import ApplicationServices

/// Fast, realistic UI automation that measures how responsive the real window is. Every launch uses a throwaway profile, a scratch downloads folder and throwaway media-tool folders (never the person's own),
/// and refuses to run while another copy of the app (the installed one shares the bundle identifier) is running. Needs scripts/testserver.py on :18765 and scripts/download_fixture_server.py on :18766.
class PerfCase: XCTestCase {
    var app: XCUIApplication!
    let report = PerfReport.shared
    let server = "http://127.0.0.1:18765"

    // MARK: Safe launch

    /// The small purpose-built fixture packages the scheme's pre-action creates (the same ones the media-tool UI tests use; this runner is sandboxed and cannot read the person's caches). The app's debug
    /// fixture mode installs them only into throwaway folders, so the person's own media-tool folder, packages and installed tools are never involved.
    static let fixtures: (yt: String, ff: String, root: String)? = {
        let fm = FileManager.default, env = ProcessInfo.processInfo.environment
        let yt = env["BS_MEDIATOOLS_FIXTURE"] ?? "/private/tmp/bs-mediatools-ui-fixture", ff = env["BS_FFMPEGTOOLS_FIXTURE"] ?? "/private/tmp/bs-ffmpegtools-ui-fixture"
        guard fm.fileExists(atPath: yt), fm.fileExists(atPath: ff) else { return nil }
        let root = NSTemporaryDirectory() + "bs-perf-installs-\(UUID().uuidString)"
        return (yt, ff, root)
    }()

    override func setUpWithError() throws {
        continueAfterFailure = false
        // Another copy of the app (the installed one) shares this bundle identifier: launching would quit it. Never do that to a person's open browser.
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.browsersetu.mac")
        try XCTSkipUnless(running.isEmpty, "Browser Setu is already running (\(running.count) instance): not launching a test copy over it")
        try XCTSkipUnless(Self.fixtures != nil, "the media-tool UI fixtures are missing (the scheme pre-action builds them); without them the media-tool folders cannot be isolated, so nothing is launched")
        // The fixture servers are started by the scheme's pre-action. The sandboxed runner cannot reliably probe them, so a missing server shows up as a page that never loads (every scenario waits for real page content).
        _ = try? String(contentsOf: URL(string: "\(server)/_reset")!, encoding: .utf8)
    }

    override func tearDown() {
        if let run = testRun, run.totalFailureCount > 0, let app, app.state != .notRunning {
            let shot = app.windows.firstMatch.safeAttachment(); shot.name = "failure-window"; shot.lifetime = .keepAlways; add(shot)
            let tree = XCTAttachment(string: app.debugDescription); tree.name = "failure-hierarchy"; tree.lifetime = .keepAlways; add(tree)
            report.failure(name, "failed; screenshot and hierarchy attached")
        }
        app?.terminate()
    }

    /// Launches with a throwaway profile; returns the milliseconds from the call to a usable window (an address field that can be clicked).
    @discardableResult
    func launch(state: String = "none", root: String? = nil, extra: [String] = [], env: [String: String] = [:]) -> Double {
        let fx = Self.fixtures!
        let id = UUID().uuidString.prefix(8)
        app = XCUIApplication()
        app.launchArguments += ["-UITestRoot", root ?? "bs-perf-\(id)", "-UIState", state, "-UIDownloadsScratch", "perf-\(id)",
                                "-MediaToolsFixture", fx.yt, "-MediaToolsFixtureRoot", fx.root + "/install-yt-\(id)", "-MediaToolsFixtureSuite", "bs.perf.yt.\(id)",
                                "-FFmpegToolsFixture", fx.ff, "-FFmpegToolsFixtureRoot", fx.root + "/install-ff-\(id)", "-FFmpegToolsFixtureSuite", "bs.perf.ff.\(id)"] + extra
        for (k, v) in env { app.launchEnvironment[k] = v }
        // A relocated home for this run: WebKit's data and caches go there instead of the person's own Library (measured: with it, nothing under ~/Library/WebKit/com.browsersetu.mac changes).
        let home = NSTemporaryDirectory() + "bs-ui-home"
        try? FileManager.default.createDirectory(atPath: home + "/Library/Preferences", withIntermediateDirectories: true)
        app.launchEnvironment["CFFIXED_USER_HOME"] = home
        let t0 = PerfClock.ms()
        app.launch()
        app.activate()
        let field = app.textFields["omnibox"], start = app.textFields["start-search"]
        _ = until(15) { app.windows.firstMatch.exists && ((field.exists && field.isHittable) || (start.exists && start.isHittable)) }
        return PerfClock.ms() - t0
    }

    // MARK: Event-driven waiting

    /// Asks `condition` as often as it can be asked until it is true or the (short) timeout passes. Returns the milliseconds it took, nil on timeout.
    @discardableResult
    func until(_ timeout: Double = 3, _ condition: () -> Bool) -> Double? {
        let t0 = PerfClock.ms()
        repeat { if condition() { return PerfClock.ms() - t0 } } while PerfClock.ms() - t0 < timeout * 1000
        return nil
    }

    /// The response time of one action: `action` is issued, then the condition is asked until it holds. Returns (ms until the first poll that saw the change, ms the action call itself took).
    func respond(timeout: Double = 3, _ action: () -> Void, until condition: () -> Bool) -> (seen: Double, returned: Double)? {
        let t0 = PerfClock.ms()
        action()
        let returned = PerfClock.ms() - t0
        if condition() { return (PerfClock.ms() - t0, returned) }
        guard until(timeout, condition) != nil else { return nil }
        return (PerfClock.ms() - t0, returned)
    }

    func chips() -> XCUIElementQuery { app.descendants(matching: .any).matching(identifier: "tab-chip") }

    // MARK: Window-scoped queries (asking the whole app makes the accessibility service describe every window, including the web page: ~50 ms a query)

    var win: XCUIElement { app.windows["browser-AppWindow-1"] }                                   // the browser window (Settings is a separate window)
    var settingsWin: XCUIElement { app.windows["com_apple_SwiftUI_Settings_window"] }
    func any(_ id: String) -> XCUIElement { win.descendants(matching: .any).matching(identifier: id).firstMatch }
    func tabChips() -> XCUIElementQuery { win.descendants(matching: .any).matching(identifier: "tab-chip") }
    /// Every tab chip's state from ONE snapshot of the window. Asking chip by chip (`chip(i).isSelected` for each i) is one snapshot of the whole accessibility tree per question: measured 1.1 s for 10 tabs and 4.1 s
    /// for 25 (one snapshot: 65–82 ms), which at 100 tabs outlasts any poll and starves the app of the answers.
    func chipSnapshots() -> [(selected: Bool, frame: CGRect, label: String)] {
        guard win.exists, let snapshot = try? win.snapshot() else { return [] }
        var found: [(selected: Bool, frame: CGRect, label: String)] = []
        func walk(_ s: XCUIElementSnapshot) {
            if s.identifier == "tab-chip" { found.append((s.isSelected, s.frame, s.label)) }
            s.children.forEach(walk)
        }
        walk(snapshot)
        return found
    }
    /// One consistent accessibility snapshot of the window as a flat list (identifier, label, frame, selected). Per-element queries (`allElementsBoundByIndex`) go stale while rows come and go; this cannot.
    struct SnapItem { let id: String; let label: String; let frame: CGRect; let selected: Bool; let type: UInt }
    func snapItems() -> [SnapItem] {
        guard win.exists, let snapshot = try? win.snapshot() else { return [] }
        var found: [SnapItem] = []
        func walk(_ s: XCUIElementSnapshot) { found.append(SnapItem(id: s.identifier, label: s.label.isEmpty ? s.title : s.label, frame: s.frame, selected: s.isSelected, type: s.elementType.rawValue)); s.children.forEach(walk) }
        walk(snapshot)
        return found
    }
    /// The accessibility identifiers present in the window, for a failure message that says what IS there.
    func presentIDs(limit: Int = 60) -> String { Array(Set(snapItems().map(\.id).filter { !$0.isEmpty })).sorted().prefix(limit).joined(separator: ", ") }
    func chipLabels() -> [String] { (0..<tabChips().count).map { tabChips().element(boundBy: $0).label } }

    /// Puts text in the field that has the keyboard IMMEDIATELY (paste), then optionally presses Return. Used everywhere except the address-bar typing scenarios, where realistic typing is the point.
    func paste(_ text: String, thenReturn: Bool = false) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        app.typeKey("v", modifierFlags: .command)
        if thenReturn { app.typeKey(.return, modifierFlags: []) }
    }

    /// Loads a fixture page in the current tab: focus the address bar, paste, Return, wait for the page itself (its title), not for a time.
    @discardableResult
    func open(_ path: String, title: String, timeout: Double = 8) -> Double? {
        let t0 = PerfClock.ms()
        app.typeKey("l", modifierFlags: .command)
        paste(server + path, thenReturn: true)
        guard until(timeout, { win.title.contains(title) || chip(0).label.contains(title) }) != nil else { return nil }
        return PerfClock.ms() - t0
    }

    func median(_ v: [Double]) -> Double { PerfStats(v).median }

    func attachShot(_ name: String) {
        let shot = win.safeAttachment(); shot.name = name; shot.lifetime = .keepAlways; add(shot)
        let tree = XCTAttachment(string: win.debugDescription); tree.name = name + "-hierarchy"; tree.lifetime = .keepAlways; add(tree)
    }

    /// One action, repeated: for each repetition `prepare` runs, the action is issued and the condition is asked until it holds (or the short timeout passes, which FAILS the scenario with a screenshot:
    /// a change that never shows up is never a pass). Reports three separate numbers so the automation's share is visible: the action call (event delivery + waiting for the app to go idle), the first poll
    /// that saw the change, and what one poll of this very condition costs on an idle window.
    @discardableResult
    func measureAction(_ scenario: String, reps: Int, timeout: Double = 3, prepare: () -> Void = {}, action: () -> Void, until condition: () -> Bool, reset: () -> Void = {}, note: String = "") -> (returned: [Double], seen: [Double]) {
        var returned: [Double] = [], seen: [Double] = [], misses = 0
        var poll: [Double] = []
        for _ in 0..<12 { let t = PerfClock.ms(); _ = condition(); poll.append(PerfClock.ms() - t) }
        for _ in 0..<reps {
            prepare()
            if let r = respond(timeout: timeout, action, until: condition) { returned.append(r.returned); seen.append(r.seen) } else { misses += 1; attachShot("\(scenario)-miss-\(misses)") }
            reset()
        }
        report.add(scenario, "action to idle (action call returned)", returned, note: note)
        report.add(scenario, "action to first poll that saw the change", seen)
        report.add(scenario, "cost of one poll of this condition (idle)", poll)
        report.add(scenario, "estimate: seen minus one poll (lower bound)", seen.map { Swift.max(0, $0 - median(poll)) })
        if misses > 0 { report.failure(scenario, "\(misses) of \(reps) repetitions never showed the expected change") }
        XCTAssertEqual(misses, 0, "\(scenario): \(misses) of \(reps) repetitions never showed the expected change (see the attached screenshots)")
        return (returned, seen)
    }

    /// CPU and memory of the app around a stretch of work.
    func sampleProcess(_ scenario: String, _ work: () -> Void) {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.browsersetu.mac").first?.processIdentifier, let a = ProcSample.read(pid: pid) else { return }
        let t0 = PerfClock.ms(); work(); let wall = (PerfClock.ms() - t0) / 1000
        guard let b = ProcSample.read(pid: pid), wall > 0 else { return }
        report.add(scenario, "app CPU over the run", [(b.cpuSeconds - a.cpuSeconds) / wall * 100], unit: "% of one core", note: "wall \(String(format: "%.1f", wall)) s")
        report.add(scenario, "app memory (resident) after", [b.rssMB], unit: "MB", note: "before \(String(format: "%.0f", a.rssMB)) MB; the app process only (WebKit helper processes are separate)")
    }

    /// How quickly the app answers while it is busy: a cheap question is asked back to back for `seconds`; the longest answer times are a main-thread stall (the app's main thread serves these requests).
    func heartbeat(_ scenario: String, seconds: Double, during work: () -> Void = {}) {
        var rtt: [Double] = []
        let end = PerfClock.ms() + seconds * 1000
        while PerfClock.ms() < end { let t = PerfClock.ms(); _ = win.exists; rtt.append(PerfClock.ms() - t); work() }
        report.add(scenario, "app answer time while busy (main-thread responsiveness)", rtt, note: "stalls over 100 ms: \(rtt.filter { $0 > 100 }.count), over 250 ms: \(rtt.filter { $0 > 250 }.count); idle baseline is about 1 ms")
    }

    func chip(_ i: Int) -> XCUIElement { tabChips().element(boundBy: i) }
}

final class PerformanceFeasibilityUITests: PerfCase {
    /// Not a benchmark: it answers whether this machine and runner can drive the app at all, and what one observation costs, so the real scenarios can be read honestly.
    func testFeasibilityAndAutomationCost() throws {
        let trusted = AXIsProcessTrusted()
        report.note("machine: \(PerfMachine.describe())")
        report.note("runner AXIsProcessTrusted = \(trusted)")
        let launchMs = launch()
        XCTAssertTrue(app.windows.firstMatch.exists, "no window after launch")
        report.add("feasibility", "launch to usable window", [launchMs])

        // What one observation costs on an idle window (the automation's share of every result below).
        let window = app.windows.firstMatch, field = app.textFields["start-search"].exists ? app.textFields["start-search"] : app.textFields["omnibox"]
        var windowPoll: [Double] = [], fieldPoll: [Double] = [], inert: [Double] = []
        for _ in 0..<60 { let t = PerfClock.ms(); _ = window.exists; windowPoll.append(PerfClock.ms() - t) }
        for _ in 0..<60 { let t = PerfClock.ms(); _ = field.exists; fieldPoll.append(PerfClock.ms() - t) }
        for _ in 0..<30 { let t = PerfClock.ms(); app.typeKey(.F13, modifierFlags: []); inert.append(PerfClock.ms() - t) }
        report.add("feasibility", "poll: window.exists (idle)", windowPoll)
        report.add("feasibility", "poll: field.exists (idle)", fieldPoll)
        report.add("feasibility", "inert keystroke call (idle)", inert, note: "cost of delivering one key event and waiting for the app to settle")

        // A real action: new tab. How long until the chip count changes, and how long the key call itself blocks.
        var seen: [Double] = [], returned: [Double] = []
        for _ in 0..<10 {
            let before = chips().count
            if let r = respond({ app.typeKey("t", modifierFlags: .command) }, until: { chips().count > before }) { seen.append(r.seen); returned.append(r.returned) }
        }
        XCTAssertFalse(seen.isEmpty, "new tab never showed up")
        report.add("feasibility", "new tab: key to first poll that sees it", seen)
        report.add("feasibility", "new tab: key call returned after", returned)
    }
}

// MARK: - Scenarios

/// Realistic typing for the address bar ONLY: one key at a time with a human gap (the gap is the person, not the app; it is excluded from every response time).
extension PerfCase {
    func typeLikeAPerson(_ text: String, gap: (min: Double, max: Double)) -> [Double] {
        var echo: [Double] = []
        for ch in text {
            let before = (any("omnibox").value as? String) ?? ""
            let t0 = PerfClock.ms()
            app.typeKey(String(ch), modifierFlags: [])
            _ = until(1.5) { ((any("omnibox").value as? String) ?? "") != before }
            echo.append(PerfClock.ms() - t0)
            Thread.sleep(forTimeInterval: Double.random(in: gap.min...gap.max) / 1000)
        }
        return echo
    }
    var hasFocus: Bool { (any("omnibox").value(forKey: "hasKeyboardFocus") as? Bool) == true }
}

final class PerfStartupUITests: PerfCase {
    func testColdAndWarmStartup() throws {
        report.note("machine: \(PerfMachine.describe())")
        var times: [Double] = []
        for _ in 0..<6 {
            times.append(launch())
            XCTAssertTrue(win.exists, "no window")
            app.terminate()
        }
        report.add("startup", "cold (first launch, files not yet cached)", [times[0]])
        report.add("startup", "warm (repeat launches) to a usable window", Array(times.dropFirst()), note: "includes process start, window, first address-field query")
        // Resource use after settling.
        launch()
        XCTAssertNotNil(until(5) { win.exists })
        sampleProcess("startup idle") { Thread.sleep(forTimeInterval: 3) }
    }
}

final class PerfTabsUITests: PerfCase {
    func testTabCreateSwitchCloseAndLayouts() throws {
        launch(state: "many-tabs")
        XCTAssertNotNil(until(10) { tabChips().count >= 8 }, "tabs did not appear: \(chipLabels())")
        var n = tabChips().count
        measureAction("tab create (Cmd-T)", reps: 12, action: { n = tabChips().count; app.typeKey("t", modifierFlags: .command) }, until: { tabChips().count > n })
        measureAction("tab close (Cmd-W)", reps: 12, action: { n = tabChips().count; app.typeKey("w", modifierFlags: .command) }, until: { tabChips().count < n })
        // Switch: Cmd-1 / Cmd-2 alternate; the selected chip changes.
        var target = 1
        measureAction("tab switch (Cmd-number)", reps: 20, action: { target = target == 1 ? 2 : 1; app.typeKey("\(target)", modifierFlags: .command) },
                      until: { chip(target - 1).isSelected }, note: "waits until the target chip reports selected")
        // Switch by click.
        measureAction("tab switch (click)", reps: 12, action: { target = target == 1 ? 3 : 1; chip(target - 1).click() }, until: { chip(target - 1).isSelected })
        // Reorder by dragging the 3rd chip onto the 5th (the drag itself is as short as the system allows).
        let before = chipLabels()
        let a = chip(2).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)), b = chip(4).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let t0 = PerfClock.ms()
        a.press(forDuration: 0.3, thenDragTo: b, withVelocity: .fast, thenHoldForDuration: 0.1)
        let moved = until(3) { chipLabels() != before }
        report.add("tab reorder (drag)", "drag to new order visible", [moved ?? -1], note: moved == nil ? "ORDER DID NOT CHANGE" : "includes the drag gesture itself (\(Int(PerfClock.ms() - t0 - (moved ?? 0))) ms of system drag time not removed)")
        if moved == nil { attachShot("reorder-miss"); report.failure("tab reorder", "order unchanged after drag") }
        // Many tabs: CPU/memory.
        sampleProcess("many tabs idle") { Thread.sleep(forTimeInterval: 2) }
    }

    func testLayoutSwitches() throws {
        launch(state: "many-tabs")
        XCTAssertNotNil(until(10) { tabChips().count >= 8 })
        func signature() -> String { "\(any("sidebar").exists)|\(any("omnibox").exists)|\(any("floating-address-bar").exists)|\(any("collapsed-pill").exists)|\(chip(0).exists ? NSStringFromRect(chip(0).frame) : "-")" }
        var cur = "classic"
        for target in ["Sidebar", "Minimal", "Floating", "One Row", "Classic", "Sidebar", "Classic"] {
            var sig = ""
            measureAction("layout switch to \(target)", reps: 1, timeout: 4,
                          prepare: { sig = signature() },
                          action: { app.typeKey("k", modifierFlags: .command); XCTAssertNotNil(self.until(3) { self.any("palette-field").exists }); self.paste("Layout: \(target)"); self.app.typeKey(.return, modifierFlags: []) },
                          until: { signature() != sig }, note: "from Cmd-K (palette) through Return to a changed window; palette open time is part of it")
            cur = target
        }
        _ = cur
    }
}

final class PerfWorkspaceUITests: PerfCase {
    func testWorkspaceSwitching() throws {
        launch(state: "workspaces")
        XCTAssertNotNil(until(10) { win.buttons["Workspace Dev"].exists }, "workspaces not shown")
        let names = [2: "Dev", 3: "Research", 1: "Personal"]
        var k = 1
        // The current workspace must be exposed to assistive technology (a selected row/dot); this also gives the test a verifiable state.
        measureAction("workspace switch (Ctrl-number)", reps: 12, action: { k = k == 1 ? 2 : (k == 2 ? 3 : 1); app.typeKey("\(k)", modifierFlags: .control) },
                      until: { win.buttons["Workspace \(names[k]!)"].isSelected }, note: "waits for the target workspace to be reported selected")
    }
}

final class PerfAddressBarUITests: PerfCase {
    func testFocusTypingSuggestionsAndNavigation() throws {
        launch(state: "classic-page")
        XCTAssertNotNil(until(15) { win.title.contains("Page") || chip(0).label == "Page" }, "start page did not load")
        // Focus latency (Cmd-L → field has the keyboard), repeated.
        measureAction("address bar focus (Cmd-L)", reps: 15, action: { app.typeKey("l", modifierFlags: .command) }, until: { hasFocus }, reset: { app.typeKey(.escape, modifierFlags: []); _ = until(1) { !hasFocus } })
        // Realistic typing, two speeds. Per-keystroke echo and suggestion latency are measured; the gap between keys is the typist, not the app.
        for (name, gap) in [("rapid typing (about 60 ms between keys)", (min: 40.0, max: 80.0)), ("normal typing (about 180 ms between keys)", (min: 120.0, max: 240.0))] {
            var echo: [Double] = [], suggest: [Double] = []
            for word in ["pag", "swift", "browser", "example"] {
                app.typeKey("l", modifierFlags: .command); _ = until(2) { hasFocus }
                app.typeKey("a", modifierFlags: .command)
                echo += typeLikeAPerson(word, gap: gap)
                let t0 = PerfClock.ms()
                let row = win.buttons["Search for “\(word)”"]
                if until(3, { row.exists }) != nil { suggest.append(PerfClock.ms() - t0) } else { attachShot("suggestion-miss-\(word)") ; report.failure(name, "suggestion for \(word) did not appear") }
                app.typeKey(.escape, modifierFlags: [])
                _ = until(1) { !hasFocus }
            }
            report.add("omnibox " + name, "key to visible character (per key)", echo, note: "includes one value query")
            report.add("omnibox " + name, "last key to suggestion row visible", suggest)
            XCTAssertEqual(suggest.count, 4, "\(name): a suggestion did not appear")
        }
        // Navigation: paste (not a typing scenario) + Return → page title in the window.
        var load: [Double] = []
        for i in 0..<10 {
            let t0 = PerfClock.ms()
            app.typeKey("l", modifierFlags: .command); paste(server + "/p/Nav\(i)", thenReturn: true)
            if until(8, { win.title.contains("Nav\(i)") || chip(0).label.contains("Nav\(i)") }) != nil { load.append(PerfClock.ms() - t0) } else { attachShot("nav-miss-\(i)") }
        }
        report.add("navigation (local server)", "Return to page title shown", load, note: "local page, so this is mostly the browser's own overhead")
        XCTAssertEqual(load.count, 10, "a navigation never completed")
    }
}

final class PerfWebsitesUITests: PerfCase {
    func testRealWebsitesAndSwitching() throws {
        launch()
        let sites: [(String, String)] = [("https://example.com", "Example"), ("https://en.wikipedia.org/wiki/Safari_(web_browser)", "Safari"), ("https://www.apple.com", "Apple")]
        var firstContent: [String: [Double]] = [:]
        for round in 0..<3 {
            for (url, title) in sites {
                app.typeKey("t", modifierFlags: .command)
                _ = until(3) { hasFocus || any("start-search").exists }
                let t0 = PerfClock.ms()
                paste(url, thenReturn: true)
                if let ms = until(15, { chipLabels().contains { $0.contains(title) } }) { firstContent[title, default: []].append(ms + (PerfClock.ms() - t0 - ms) * 0) } else { attachShot("site-miss-\(title)-\(round)"); report.failure("real websites", "\(title) did not load within 15 s (network?)") }
            }
        }
        for (title, v) in firstContent { report.add("real site: \(title)", "Return to tab titled (first usable)", v, note: "real network; includes DNS/TLS/server time, not only the browser") }
        report.note("real-site numbers include internet conditions and cannot be compared across runs")
        XCTAssertFalse(firstContent.isEmpty, "no real site loaded at all (offline?)")
        // Switching between loaded pages.
        let n = tabChips().count
        var target = 0
        if n >= 3 { measureAction("switch between loaded real pages", reps: 15, action: { target = (target + 1) % 3; chip(target).click() }, until: { chip(target).isSelected }) }
        sampleProcess("after 9 real pages") { Thread.sleep(forTimeInterval: 2) }
    }
}

final class PerfScrollUITests: PerfCase {
    func testScrollingLongPage() throws {
        launch(state: "classic-page")
        XCTAssertNotNil(open("/tall", title: "Tall"), "tall page did not load")
        let w = win
        // Heartbeat while scrolling: how long the app takes to answer a question during continuous native scrolling.
        var rtt: [Double] = []
        let t0 = PerfClock.ms()
        for i in 0..<40 {
            w.scroll(byDeltaX: 0, deltaY: i % 10 == 9 ? 600 : -300)
            let t = PerfClock.ms(); _ = w.exists; rtt.append(PerfClock.ms() - t)
        }
        let wall = PerfClock.ms() - t0
        report.add("scroll /tall (40 wheel events)", "scroll call + app answer after each", [wall / 40], note: "average per event; each event waits for the app to go idle")
        report.add("scroll /tall (40 wheel events)", "app answer time right after a scroll event", rtt, note: "stalls over 100 ms: \(rtt.filter { $0 > 100 }.count)")
        XCTAssertLessThan(PerfStats(rtt).p95, 400, "app unresponsive during scrolling")
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let metric = XCTHitchMetric(application: app)
            measure(metrics: [metric], options: { let o = XCTMeasureOptions(); o.iterationCount = 5; return o }()) {
                for i in 0..<12 { w.scroll(byDeltaX: 0, deltaY: i % 6 == 5 ? 800 : -400) }
            }
            report.note("hitch metrics (XCTHitchMetric: time in hitches, hitch time ratio) are in the xcresult bundle")
        }
        #endif
        sampleProcess("scrolling CPU") { for i in 0..<30 { w.scroll(byDeltaX: 0, deltaY: i % 10 == 9 ? 600 : -300) } }
    }
}

final class PerfDownloadsAndPanelsUITests: PerfCase {
    func testDownloadsWindowAddDownloadAndCollect() throws {
        launch(state: "downloads")
        // State "downloads" fills and opens the manager itself after a few seconds.
        XCTAssertNotNil(until(25) { any("downloads-table").exists }, "downloads window never opened")
        let tableUp = any("downloads-table")
        XCTAssertTrue(tableUp.exists)
        attachShot("downloads-window")
        // Rendering/updating while six downloads progress: how fast the app answers with live updates.
        heartbeat("downloads list with live progress", seconds: 4)
        sampleProcess("downloads list with live progress") { Thread.sleep(forTimeInterval: 3) }
        // Add Download sheet.
        let add = win.buttons["Add download"]
        measureAction("Add Download open", reps: 6, timeout: 4, action: { add.click() }, until: { win.textFields.count > 0 && win.sheets.count + win.dialogs.count >= 0 && win.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'address' OR placeholderValue CONTAINS[c] 'http' OR identifier CONTAINS 'add-download'")).count > 0 },
                      reset: { app.typeKey(.escape, modifierFlags: []); _ = until(2) { !(win.descendants(matching: .any).matching(identifier: "add-download-address").count > 0) } })
        // Collect menu → Link Grabber / Explore.
        let collect = any("downloads-collect")
        measureAction("Collect menu open", reps: 6, timeout: 3, action: { if collect.exists { collect.click() } }, until: { app.menuItems.count > 0 }, reset: { app.typeKey(.escape, modifierFlags: []); _ = until(2) { app.menuItems.count == 0 } })
    }

    func testSettingsPopoversAndSheets() throws {
        launch(state: "classic-page")
        XCTAssertNotNil(until(10) { win.exists })
        measureAction("Settings open (Cmd-,)", reps: 8, timeout: 5, action: { app.typeKey(",", modifierFlags: .command) }, until: { settingsWin.buttons["settings-nav-general"].exists },
                      reset: { app.typeKey("w", modifierFlags: .command); _ = until(3) { !settingsWin.exists } })
        app.typeKey(",", modifierFlags: .command)
        XCTAssertNotNil(until(5) { settingsWin.buttons["settings-nav-general"].exists })
        // Switching panels (includes the Downloads panel, which holds the optional media-tool status).
        let panels = ["appearance", "tabs", "search", "downloads", "privacy", "performance", "advanced", "general"]
        var p = 0
        measureAction("Settings panel switch", reps: 16, timeout: 4, action: { p = (p + 1) % panels.count; settingsWin.buttons["settings-nav-\(panels[p])"].click() }, until: { settingsWin.buttons["settings-nav-\(panels[p])"].isSelected })
        // Media-tool status (optional-tools UI) renders in Settings > Downloads: record how long it takes to show anything beyond the nav.
        settingsWin.buttons["settings-nav-downloads"].click()
        let t0 = PerfClock.ms()
        let shown = until(6) { settingsWin.buttons["media-tools-install"].exists || settingsWin.buttons["processing-tools-install"].exists }
        report.add("media-tool status panel", "Settings > Downloads shown", [shown ?? -1], note: "tool names are not displayed by design (ADR 0001); only that the panel renders is timed")
        
        _ = t0
        app.typeKey("w", modifierFlags: .command)
        // Command palette and shield popover.
        XCTAssertNotNil(until(4) { !settingsWin.exists }, "settings still open")
        app.activate()
        win.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)).click()
        measureAction("Command palette open (Cmd-K)", reps: 10, action: { app.typeKey("k", modifierFlags: .command) }, until: { any("palette-field").exists }, reset: { app.typeKey(.escape, modifierFlags: []); _ = until(2) { !any("palette-field").exists } })
        if win.buttons["shield-button"].exists {
            measureAction("Shield popover open", reps: 8, action: { win.buttons["shield-button"].click() }, until: { any("protection-level").exists }, reset: { app.typeKey(.escape, modifierFlags: []); _ = until(2) { !any("protection-level").exists } })
        }
        // Tab overview.
        app.typeKey("t", modifierFlags: .command)
        measureAction("Tab Overview open", reps: 8, action: { app.typeKey("\\", modifierFlags: [.command, .shift]) }, until: { any("tab-overview").exists || tabCardsExist() }, reset: { if win.buttons["overview-done"].exists { win.buttons["overview-done"].click() }; _ = until(2) { !tabCardsExist() } })
    }
    func tabCardsExist() -> Bool { win.descendants(matching: .any).matching(identifier: "tab-card").count > 0 }
}

final class PerfWindowUITests: PerfCase {
    func testResizeAndFullScreen() throws {
        // Measured attempts (see the report): this runner cannot drag a window edge (the drag never changes the size) and the full-screen menu command times out waiting for the menu to open, so there is no
        // trustworthy response time for either. They are skipped rather than reported as passing.
        throw XCTSkip("window resize by drag and full screen cannot be driven reliably from the UI-test runner on this machine; not measured")
    }
}
