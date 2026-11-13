import XCTest
import ApplicationServices
import Darwin

// Support for PerformanceUITests: timing, statistics, process sampling and the report.
//
// How the numbers are made (and what they are not):
//  * Waits are event-driven: a bounded loop that asks the window a question until the answer is "yes" (no fixed sleeps, except the typing delay of the address bar scenarios, which is the point of them).
//  * An action's response time is the time from just before the action is issued until the first poll that sees the expected change. Every poll costs something (an accessibility query). That cost is MEASURED
//    on an idle window (`calibrate`) and reported next to the result, so the automation's share can be read off; results are reported raw and with one poll cost subtracted (a lower bound).
//  * Nothing here disables or shortens an animation. XCUITest itself waits for the app to go idle before it answers a query, which is part of what is measured; the report says so.

enum PerfClock {
    static func ms() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }
}

struct PerfStats {
    var n = 0, min = 0.0, median = 0.0, p95 = 0.0, max = 0.0, mean = 0.0
    init(_ values: [Double]) {
        let v = values.sorted(); guard !v.isEmpty else { return }
        n = v.count; min = v[0]; max = v[n - 1]; mean = v.reduce(0, +) / Double(n)
        func pct(_ p: Double) -> Double { v[Swift.min(n - 1, Int((p * Double(n)).rounded(.up)) - 1 < 0 ? 0 : Int((p * Double(n)).rounded(.up)) - 1)] }   // nearest rank
        median = n % 2 == 1 ? v[n / 2] : (v[n / 2 - 1] + v[n / 2]) / 2
        p95 = pct(0.95)
    }
    var line: String { String(format: "n=%d  min %.1f  median %.1f  p95 %.1f  max %.1f  mean %.1f", n, min, median, p95, max, mean) }
}

/// Collects results and writes them (JSON lines + a readable text file) so nothing is lost if a later test fails.
final class PerfReport {
    static let shared = PerfReport()
    let dir: URL
    private var notes: [String] = []
    init() {
        // This runner is sandboxed: it writes inside its own temporary folder (the path is printed, and the report is also attached to the test).
        let base = ProcessInfo.processInfo.environment["PERF_OUT"] ?? NSTemporaryDirectory() + "bs-perf-report"
        dir = URL(fileURLWithPath: base, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        print("PERF-REPORT-DIR \(dir.path)")
    }
    func add(_ scenario: String, _ metric: String, _ values: [Double], unit: String = "ms", note: String = "") {
        let s = PerfStats(values)
        let line = "\(scenario) | \(metric) | \(s.line) \(unit)" + (note.isEmpty ? "" : " | \(note)")
        append(line)
        let obj: [String: Any] = ["scenario": scenario, "metric": metric, "unit": unit, "n": s.n, "min": s.min, "median": s.median, "p95": s.p95, "max": s.max, "mean": s.mean, "samples": values, "note": note]
        if let d = try? JSONSerialization.data(withJSONObject: obj), let text = String(data: d, encoding: .utf8) { appendJSON(text) }
    }
    func note(_ text: String) { append("NOTE: \(text)") }
    func failure(_ scenario: String, _ reason: String) { append("FAILED: \(scenario) | \(reason)") }
    private func append(_ line: String) { write(line + "\n", to: dir.appendingPathComponent("perf-report.txt")) }
    private func appendJSON(_ line: String) { write(line + "\n", to: dir.appendingPathComponent("perf-results.jsonl")) }
    private func write(_ text: String, to url: URL) {
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close() } else { try? text.write(to: url, atomically: true, encoding: .utf8) }
    }
}

/// CPU time and memory of one process, read without disturbing it.
struct ProcSample {
    var rssMB: Double, cpuSeconds: Double, threads: Int
    static func read(pid: pid_t) -> ProcSample? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        let toSeconds = Double(tb.numer) / Double(tb.denom) / 1e9
        return ProcSample(rssMB: Double(info.pti_resident_size) / 1_048_576, cpuSeconds: Double(info.pti_total_user + info.pti_total_system) * toSeconds, threads: Int(info.pti_threadnum))
    }
}

/// One-line description of the machine at the time of the run (load, memory pressure), kept with the results.
enum PerfMachine {
    static func describe() -> String {
        var load = [Double](repeating: 0, count: 3); getloadavg(&load, 3)
        let mem = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
        let thermal = ["nominal", "fair", "serious", "critical"][ProcessInfo.processInfo.thermalState.rawValue]
        return String(format: "load avg %.2f/%.2f/%.2f, %d cores, %d GB RAM, thermal %@, low power %@, macOS %@", load[0], load[1], load[2], ProcessInfo.processInfo.activeProcessorCount, Int(mem), thermal,
                      ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off", ProcessInfo.processInfo.operatingSystemVersionString)
    }
}
