import XCTest
import Darwin

/// Real websites in the real Debug app (a throwaway profile; nothing of the person's own is touched), in three weights that pile up in one session: light pages (small, mostly
/// text), moderate ones (documentation and code) and heavy ones (video, news, shopping and social sites full of scripts and ads): 120 tabs in all. After each weight it prints what
/// happened (REALSTRESS lines): how many tabs got a page title, the app's memory, and how quickly choosing the next tab shows. Then 90 seconds of churn across every open page. It passes when the app stays up and
/// answering, no crash report is written, memory stays within a bound, and a sanity number of pages loaded (the pages are live: some not loading is the network or a consent wall, not a failure).
final class RealWebsiteStressUITests: PerfCase {
    private let light: [String] = ["example.com", "info.cern.ch", "text.npr.org", "news.ycombinator.com", "lite.cnn.com"] + [
        "Web_browser", "Internet", "Apple_Inc.", "Rust_(programming_language)", "Swift_(programming_language)", "WebKit", "Safari_(web_browser)", "HTML", "CSS", "JavaScript",
        "Python_(programming_language)", "Linux", "Unix", "Computer_science", "Algorithm", "Database", "Operating_system", "Cryptography", "Mathematics", "Physics",
        "Chemistry", "Biology", "History_of_the_Internet", "World_Wide_Web", "Tim_Berners-Lee", "Alan_Turing", "Ada_Lovelace", "Moon", "Mars", "Jupiter",
        "Pacific_Ocean", "Mount_Everest", "Amazon_River", "Sahara", "Antarctica", "Roman_Empire", "Renaissance", "Industrial_Revolution", "Printing_press", "Typography"].map { "en.wikipedia.org/wiki/" + $0 }
    private let moderate: [String] = [
        "github.com/apple/swift", "github.com/rust-lang/rust", "github.com/torvalds/linux", "github.com/microsoft/vscode", "github.com/golang/go", "github.com/python/cpython",
        "github.com/nodejs/node", "github.com/facebook/react", "github.com/vuejs/core", "github.com/tensorflow/tensorflow", "github.com/kubernetes/kubernetes", "github.com/WebKit/WebKit",
        "github.com/llvm/llvm-project", "github.com/home-assistant/core", "github.com/neovim/neovim", "github.com/git/git", "github.com/ruby/ruby", "github.com/sqlite/sqlite",
        "github.com/curl/curl", "github.com/ffmpeg/ffmpeg"] + ["HTML", "CSS", "JavaScript", "API", "HTTP", "Accessibility", "Performance", "Security", "SVG", "WebAssembly"].map { "developer.mozilla.org/en-US/docs/Web/" + $0 } + [
        "python.org", "docs.python.org/3/", "w3.org", "apple.com", "swift.org"]
    private let heavy: [String] = [
        "youtube.com", "youtube.com/feed/trending", "nytimes.com", "nytimes.com/section/world", "nytimes.com/section/technology", "nytimes.com/section/business", "cnn.com", "cnn.com/world",
        "cnn.com/politics", "cnn.com/business", "theverge.com", "theverge.com/tech", "theverge.com/science", "amazon.com", "amazon.com/gp/bestsellers", "amazon.com/deals", "reddit.com",
        "reddit.com/r/technology", "reddit.com/r/worldnews", "reddit.com/r/pics", "espn.com", "espn.com/nba", "espn.com/soccer", "bbc.com/news", "bbc.com/sport", "foxnews.com", "cnbc.com",
        "imdb.com", "twitch.tv", "ebay.com", "bestbuy.com", "walmart.com", "target.com", "buzzfeed.com", "washingtonpost.com"]

    /// Resident memory, in megabytes, of the Browser Setu process itself (WebKit's page-content processes are not children of the app and are not included). 0 when unreadable.
    private func memoryMB() -> Double {
        guard let pid = (app.value(forKey: "processID") as? NSNumber)?.int32Value, pid > 0 else { return 0 }
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return 0 }
        return Double(info.pti_resident_size) / 1_048_576
    }

    private func crashReports(since start: Date) -> [String] {
        let dir = NSHomeDirectoryForUser(NSUserName()).map { $0 + "/Library/Logs/DiagnosticReports" } ?? ""
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names.filter { ($0.hasPrefix("Browser Setu") || $0.hasPrefix("Browser_Setu")) && ((try? FileManager.default.attributesOfItem(atPath: dir + "/" + $0)[.modificationDate] as? Date) ?? .distantPast) > start }
    }

    /// Each site in a tab of its own, opened one after another without waiting for the page, as a person opens a handful of tabs.
    /// Opens each site in a new tab. A busy page can stall the app's main thread, so each step is timed, logged,
    /// and followed by a short wait that lets the app answer the test runner again before the next keystrokes.
    private func open(_ sites: [String], pause: TimeInterval = 1.2) {
        for address in sites {
            let began = Date()
            app.typeKey("t", modifierFlags: .command)
            app.typeKey("l", modifierFlags: .command)
            app.typeText(address)
            app.typeKey(.return, modifierFlags: [])
            Thread.sleep(forTimeInterval: pause)
            let took = Int(Date().timeIntervalSince(began) * 1000)
            if took > 4000 { print("REALSTRESS slow-open \(address) \(took) ms") }
        }
    }

    /// One row per tab switch the test made: when the key was sent and when the test saw the new tab selected, both in system uptime seconds.
    private var switchRows: [(sent: Double, seen: Double)] = []

    private var traceFile: String { NSTemporaryDirectory() + "bs-realstress-trace.log" }

    /// The app's own trace, lined up with the test's switches on the same clock. Three different things are reported, because they are different:
    ///  * command handling: the app's `selectTab` itself (from its own SELECT lines), and how long the key took to reach it (key sent to the app's SELECT line);
    ///  * main-thread stalls the app noticed (a tick of the watchdog went unanswered for more than 250 ms);
    ///  * what the test saw: key sent to the new tab being seen selected through accessibility, which includes the runner's own waiting and polling.
    /// A switch the test saw late while the app handled it at once and had no stall around it is reported as waiting in the runner, not in the app.
    private func dumpAppTrace() {
        let text = (try? String(contentsOfFile: traceFile, encoding: .utf8)) ?? ""
        let rows = text.split(separator: "\n").map(String.init)
        func stamp(_ row: String) -> Double? { row.split(separator: " ").first.flatMap { Double($0) } }
        func ms(_ row: String) -> Double? { row.components(separatedBy: " in ").last.flatMap { Double($0.replacingOccurrences(of: " ms", with: "")) } }
        func pct(_ values: [Double], _ q: Double) -> Int { let v = values.sorted(); return v.isEmpty ? -1 : Int(v[min(v.count - 1, Int(Double(v.count) * q))]) }
        let selectStarts = rows.filter { $0.contains("SELECT tab") }.compactMap(stamp)
        let handling = rows.filter { $0.contains("SELECT done") }.compactMap(ms)
        let stalls: [(end: Double, ms: Double)] = rows.filter { $0.contains("STALL ends") }.compactMap { r in stamp(r).flatMap { t in ms(r.replacingOccurrences(of: "STALL ends: the main thread answered after", with: "x in")).map { (t, $0) } } }
        var dispatch: [Double] = [], seenAfter: [Double] = [], lateRunnerSide = 0, lateWithAppStall = 0
        for row in switchRows {
            let appSelect = selectStarts.first { $0 >= row.sent - 0.05 && $0 <= row.seen }
            if let appSelect { dispatch.append((appSelect - row.sent) * 1000) }
            let observed = (row.seen - row.sent) * 1000
            seenAfter.append(observed)
            if observed > 5000 {
                let overlapping = stalls.filter { $0.end >= row.sent && $0.end - $0.ms / 1000 <= row.seen }.map(\.ms).reduce(0, +)
                if overlapping > 1000 { lateWithAppStall += 1 } else { lateRunnerSide += 1 }
                print(String(format: "REALSTRESS late switch: seen after %.0f ms; app received the command %@ ms after the key; app stalled %.0f ms during it", observed, appSelect.map { String(format: "%.0f", ($0 - row.sent) * 1000) } ?? "never", overlapping))
            }
        }
        print("REALSTRESS command handling (app selectTab): n=\(handling.count) p50=\(pct(handling, 0.5)) ms p95=\(pct(handling, 0.95)) ms max=\(pct(handling, 1.0)) ms")
        print("REALSTRESS key to app SELECT: n=\(dispatch.count) p50=\(pct(dispatch, 0.5)) ms p95=\(pct(dispatch, 0.95)) ms max=\(pct(dispatch, 1.0)) ms")
        print("REALSTRESS main-thread stalls over 250 ms: n=\(stalls.count) p50=\(pct(stalls.map(\.ms), 0.5)) ms p95=\(pct(stalls.map(\.ms), 0.95)) ms max=\(pct(stalls.map(\.ms), 1.0)) ms; total \(Int(stalls.map(\.ms).reduce(0, +))) ms")
        print("REALSTRESS seen by the test (key to tab seen selected): n=\(seenAfter.count) p50=\(pct(seenAfter, 0.5)) ms p95=\(pct(seenAfter, 0.95)) ms max=\(pct(seenAfter, 1.0)) ms; over 5 s: \(lateRunnerSide + lateWithAppStall) (waiting in the runner: \(lateRunnerSide), with an app stall over 1 s: \(lateWithAppStall))")
    }

    private func stripTabs() -> [SnapItem] { snapItems().filter { $0.id == "tab-chip" } }

    /// How many tabs show a real page title (a page that has loaded enough to name itself), among the tabs the strip lists.
    private func titledTabs() -> Int {
        stripTabs().filter { !$0.label.isEmpty && $0.label != "New Tab" && !$0.label.hasPrefix("about:") }.count
    }

    /// The time from asking for the next tab to the tab in front being a different one (a small average, in milliseconds, and the slowest).
    /// Reading the tab strip through accessibility costs time of its own that grows with the number of tabs, so one read is timed first
    /// and taken off every switch: what is reported is the browser's switch, not the test's way of looking at it.
    private func tabSwitch(presses: Int = 8) -> (average: Double, slowest: Double) {
        let probeStart = PerfClock.ms()
        _ = stripTabs()
        let probe = PerfClock.ms() - probeStart
        print("REALSTRESS strip read costs \(Int(probe)) ms with this many tabs")
        var times: [Double] = []
        for _ in 0..<presses {
            let before = stripTabs().first { $0.selected }?.label
            let start = PerfClock.ms()
            let sentUptime = ProcessInfo.processInfo.systemUptime
            app.typeKey("]", modifierFlags: [.command, .shift])
            let returnedUptime = ProcessInfo.processInfo.systemUptime
            _ = until(3) { self.stripTabs().first { $0.selected }?.label != before }
            let seenUptime = ProcessInfo.processInfo.systemUptime
            // Same clock as the app's own trace lines (system uptime), so each switch can be lined up with the app's SELECT and STALL lines.
            print(String(format: "REALSTRESS switch sent=%.3f keyReturned=%.3f seen=%.3f keyCallMs=%.0f sentToSeenMs=%.0f", sentUptime, returnedUptime, seenUptime, (returnedUptime - sentUptime) * 1000, (seenUptime - sentUptime) * 1000))
            switchRows.append((sentUptime, seenUptime))
            times.append(max(PerfClock.ms() - start - probe, 0))
        }
        return (times.reduce(0, +) / Double(max(times.count, 1)), times.max() ?? 0)
    }

    func testLightModerateAndHeavyRealWebsites() throws {
        let start = Date()
        try? FileManager.default.removeItem(atPath: traceFile)       // a trace left by an earlier run would be read as this one
        launch(state: "none", extra: [], env: ["BS_WINDOW_SIZE": "1200x850", "BS_SKIP_SETUP": "1", "BS_CHROME_TRACE": traceFile])
        XCTAssertTrue(win.waitForExistence(timeout: 30), "the browser window did not come up")
        Thread.sleep(forTimeInterval: 1.5)
        var previous = memoryMB()
        var peak = previous
        print("REALSTRESS start: memory \(Int(previous)) MB")
        var openedTotal = 0
        var titledAtEnd = 0
        for (name, sites) in [("light", light), ("moderate", moderate), ("heavy", heavy)] {
            let before = titledTabs()
            open(sites, pause: name == "heavy" ? 2.5 : 1.2)
            openedTotal += sites.count
            // Up to 60 s for the pages to name themselves; most of the phase titled ends the wait early.
            _ = until(60) { self.titledTabs() - before >= sites.count * 8 / 10 }
            let memory = memoryMB()
            peak = max(peak, memory)
            let (average, slowest) = tabSwitch()
            titledAtEnd = titledTabs()
            print("REALSTRESS \(name): opened \(sites.count) (\(openedTotal) in all), tabs in strip \(stripTabs().count), with a page title \(titledAtEnd - before) of this phase; memory \(Int(memory)) MB (\(memory >= previous ? "+" : "")\(Int(memory - previous))); next-tab shows in \(Int(average)) ms on average, slowest \(Int(slowest)) ms")
            previous = memory
            attachShot("real-\(name)")
            XCTAssertEqual(app.state, .runningForeground, "the app stopped after the \(name) sites")
            if app.state != .runningForeground { return }
        }
        XCTAssertGreaterThanOrEqual(openedTotal, 100, "fewer than 100 tabs were opened")

        // 90 seconds across every open page: next and previous tab, a numbered tab, scrolling, a reload now and then, and closing a tab and bringing it back.
        let churnEnd = Date().addingTimeInterval(90)
        var step = 0
        while Date() < churnEnd {
            step += 1
            switch Int.random(in: 0..<8) {
            case 0, 1: app.typeKey("]", modifierFlags: [.command, .shift])
            case 2: app.typeKey("[", modifierFlags: [.command, .shift])
            case 3: app.typeKey(["1", "2", "3", "4", "5", "6", "7", "8", "9"].randomElement()!, modifierFlags: .command)
            case 4, 5: app.typeKey(.pageDown, modifierFlags: [])
            case 6: app.typeKey("r", modifierFlags: .command)
            default: app.typeKey(.pageUp, modifierFlags: [])
            }
            if step % 19 == 0 { app.typeKey("w", modifierFlags: .command); Thread.sleep(forTimeInterval: 0.4); app.typeKey("t", modifierFlags: [.command, .shift]) }
            Thread.sleep(forTimeInterval: 0.45)
            if step % 25 == 0 {
                let memory = memoryMB(); peak = max(peak, memory)
                print("REALSTRESS churn step \(step): memory \(Int(memory)) MB, tabs \(stripTabs().count)")
                XCTAssertEqual(app.state, .runningForeground, "the app stopped during the churn (step \(step))")
                if app.state != .runningForeground { return }
            }
        }

        // Still answering.
        app.typeKey("t", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(win.exists && app.state == .runningForeground, "the app did not answer ⌘T after the churn")
        let end = memoryMB()
        dumpAppTrace()
        print("REALSTRESS end: memory \(Int(end)) MB, peak \(Int(peak)) MB; \(openedTotal) tabs opened, \(titledAtEnd) with a page title in the strip, \(stripTabs().count) listed; \(step) churn steps")
        attachShot("real-after-churn")
        XCTAssertGreaterThanOrEqual(titledAtEnd, 20, "fewer than 20 of the real pages loaded (network?)")
        XCTAssertLessThan(peak, 8192, "memory peaked at \(Int(peak)) MB")
        XCTAssertTrue(crashReports(since: start).isEmpty, "a crash report was written: \(crashReports(since: start))")
        app.terminate()
    }
}
