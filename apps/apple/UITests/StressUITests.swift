import XCTest
import Darwin

/// The whole-browser stress: a hundred tabs, then about three minutes of random tab choices, window sizes, every layout, private tabs, workspaces, split view and the sidebar, all in
/// the real Debug app on a throwaway profile (Debug state "stress-tabs", `-UIStressAllLayouts 1`). It passes when the app is still running and answering at the end, no crash report was
/// written, and the memory of the app process stayed within a bound. Memory is printed (STRESS lines) so one build can be compared with the next.
final class StressUITests: PerfCase {
    /// Resident memory, in megabytes, of the Browser Setu process itself, read from the system's process information (the test runner cannot run ps). WebKit's page-content
    /// processes are not included: they are not children of the app. 0 when the process cannot be read.
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

    func testAHundredTabsEveryLayoutThreeMinutes() throws {
        let start = Date()
        launch(state: "stress-tabs", extra: ["-UIStressAllLayouts", "1"], env: ["BS_WINDOW_SIZE": "1100x800", "BS_SKIP_SETUP": "1"])
        XCTAssertTrue(win.waitForExistence(timeout: 30), "the browser window did not come up")
        let before = memoryMB()
        print("STRESS memory at start: \(Int(before)) MB")
        var peak = before
        // The run itself: 8 s for the tabs, then 400 steps of 0.45 s.
        let end = Date().addingTimeInterval(8 + 400 * 0.45 + 12)
        var samples = 0
        while Date() < end {
            Thread.sleep(forTimeInterval: 15)
            samples += 1
            let now = memoryMB(); peak = max(peak, now)
            print("STRESS memory sample \(samples): \(Int(now)) MB")
            XCTAssertEqual(app.state, .runningForeground, "the app is not running in front any more (sample \(samples)): it may have crashed")
            if app.state != .runningForeground { break }
        }
        // Still answering: the window exists and takes a click and a shortcut.
        XCTAssertTrue(win.exists, "the window is gone")
        win.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        app.typeKey("t", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(win.exists && app.state == .runningForeground, "the app did not answer ⌘T after the stress")
        let after = memoryMB()
        print("STRESS memory at end: \(Int(after)) MB, peak \(Int(peak)) MB")
        XCTAssertLessThan(peak, 8192, "memory peaked at \(Int(peak)) MB")
        XCTAssertTrue(crashReports(since: start).isEmpty, "a crash report was written: \(crashReports(since: start))")
        app.terminate()
    }
}
