import XCTest

/// D1b-S2: the smallest scenario behind an intermittent crash ("window needs another Update Constraints pass", the window 22,500 points wide, about six seconds after launch): launch (with or without a
/// programmatic window size), switch layouts at once, wait past the moment the crashes happened, and check the app is still running and its window is a sane size. Looped, with the window probe on.
final class D1bWindowCrashReproUITests: PerfCase {
    private func switchLayout(_ name: String) {
        app.typeKey("k", modifierFlags: .command)
        _ = until(8) { any("palette-field").exists }
        paste("Layout: \(name)"); app.typeKey(.return, modifierFlags: [])
    }

    func testLaunchResizeAndSwitchLayoutsLoop() throws {
        let probe = NSTemporaryDirectory() + "bs-window-probe.log"
        try? FileManager.default.removeItem(atPath: probe)
        var crashes: [String] = []
        let scenarios: [(String, [String: String], [String])] = [
            ("900 + Minimal", ["BS_WINDOW_SIZE": "900x800"], ["Minimal", "Classic", "One Row"]),
            ("520 + Minimal", ["BS_WINDOW_SIZE": "520x800"], ["Minimal", "One Row", "Classic"]),
            ("1600 + Classic/Minimal", ["BS_WINDOW_SIZE": "1600x800"], ["Classic", "Minimal"]),
            ("default size + Minimal", [:], ["Minimal", "Classic"]),
            // The app's own resize scenario (BS_SCENARIO=resize) changes the window width every two seconds (1200, 1710, 900, 1500, 1710) while layouts switch: programmatic resizes during animated layout changes.
            ("resize scenario + rapid switching", ["BS_SCENARIO": "resize"], ["Minimal", "Classic", "One Row", "Classic", "Minimal", "Classic", "Minimal"]),
        ]
        for round in 1...3 {                                                       // 15 launches in all
            for (name, env, layouts) in scenarios {
                launch(state: "many-tabs", extra: ["-UIWindowProbe", probe], env: env)
                for layout in layouts { switchLayout(layout); Thread.sleep(forTimeInterval: 0.7) }
                Thread.sleep(forTimeInterval: env["BS_SCENARIO"] == nil ? 6.5 : 10)            // past the moment the crashes happened (the resize scenario runs for ten seconds)
                if app.state != .runningForeground && app.state != .runningBackground { crashes.append("round \(round) \(name): app not running (\(app.state.rawValue))"); continue }
                let width = win.frame.width
                if width > 3000 { crashes.append("round \(round) \(name): window \(Int(width)) wide") }
                app.terminate()
            }
        }
        let anomalies = (try? String(contentsOfFile: probe, encoding: .utf8)) ?? ""
        report.note("REPRO: 15 launches; \(crashes.count) failures: \(crashes); probe anomalies: \(anomalies.isEmpty ? "none" : String(anomalies.prefix(1500)))")
        XCTAssertTrue(crashes.isEmpty, "the app crashed or the window grew: \(crashes)")
        XCTAssertTrue(anomalies.isEmpty, "the window probe saw abnormal growth:\n\(anomalies.prefix(1500))")
    }
}
