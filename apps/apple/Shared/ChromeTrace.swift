import SwiftUI

#if DEBUG
/// Development only (compiled out of release builds; read by D1cOneRowTransitionUITests to prove the old bar leaves at once when the layout changes): with BS_CHROME_TRACE=<file>, appends one line each time a chrome view appears or disappears and each time the layout preset changes.
enum ChromeTrace {
    static let path = ProcessInfo.processInfo.environment["BS_CHROME_TRACE"]
    static func log(_ text: String) {
        guard let path else { return }
        MainThreadWatchdog.startIfTracing()
        let line = String(format: "%.3f %@\n", ProcessInfo.processInfo.systemUptime, text)
        if let handle = FileHandle(forWritingAtPath: path) { defer { try? handle.close() }; _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(line.utf8)) }
        else { try? line.write(toFile: path, atomically: false, encoding: .utf8) }
    }
}
/// Development only, and only while tracing (BS_CHROME_TRACE set): tells apart "the app's main thread was busy" from "the test runner was waiting". A background timer sends the main queue a tiny
/// block every 100 ms; when one is not answered for more than 250 ms, "STALL" lines are written to the same trace file, on the same clock (system uptime) as the lines the app logs for tab changes.
enum MainThreadWatchdog {
    private static let lock = NSLock()
    private static var started = false
    private static var sentAt: Double?
    private static var reported = false
    private static var timer: DispatchSourceTimer?
    private static let thresholdMs = 250.0

    static func startIfTracing() {
        guard ChromeTrace.path != nil else { return }
        lock.lock(); defer { lock.unlock() }
        guard !started else { return }
        started = true
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "browsersetu.trace.watchdog", qos: .userInteractive))
        source.schedule(deadline: .now() + 0.1, repeating: 0.1)
        source.setEventHandler {
            let now = ProcessInfo.processInfo.systemUptime
            lock.lock()
            if let sent = sentAt {
                let lateMs = (now - sent) * 1000
                let first = lateMs > thresholdMs && !reported
                if first { reported = true }
                lock.unlock()
                if first { ChromeTrace.log("STALL begins: the main thread has not answered for \(Int(lateMs)) ms") }
                return
            }
            sentAt = now
            lock.unlock()
            DispatchQueue.main.async {
                let answered = ProcessInfo.processInfo.systemUptime
                lock.lock(); let sent = sentAt; sentAt = nil; reported = false; lock.unlock()
                if let sent, (answered - sent) * 1000 > thresholdMs { ChromeTrace.log("STALL ends: the main thread answered after \(Int((answered - sent) * 1000)) ms") }
            }
        }
        timer = source
        source.resume()
    }
}
private struct ChromeTraceModifier: ViewModifier {
    @EnvironmentObject var model: BrowserModel
    let name: String
    func body(content: Content) -> some View {
        content
            .onAppear { ChromeTrace.log("APPEAR \(name) preset=\(model.layoutPreset) singleRow=\(model.singleRow) tabLayout=\(model.effectiveTabLayout)") }
            .onDisappear { ChromeTrace.log("DISAPPEAR \(name) preset=\(model.layoutPreset) singleRow=\(model.singleRow)") }
    }
}
extension View { func chromeTrace(_ name: String) -> some View { modifier(ChromeTraceModifier(name: name)) } }
#else
/// Release builds: nothing is logged and the message is never built.
enum ChromeTrace { static func log(_ text: @autoclosure () -> String) {} }
extension View { func chromeTrace(_ name: String) -> some View { self } }
#endif
