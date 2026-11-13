import SwiftUI

#if DEBUG
/// Development only (compiled out of release builds; read by D1cOneRowTransitionUITests to prove the old bar leaves at once when the layout changes): with BS_CHROME_TRACE=<file>, appends one line each time a chrome view appears or disappears and each time the layout preset changes.
enum ChromeTrace {
    static let path = ProcessInfo.processInfo.environment["BS_CHROME_TRACE"]
    static func log(_ text: String) {
        guard let path else { return }
        let line = String(format: "%.3f %@\n", ProcessInfo.processInfo.systemUptime, text)
        if let handle = FileHandle(forWritingAtPath: path) { defer { try? handle.close() }; _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(line.utf8)) }
        else { try? line.write(toFile: path, atomically: false, encoding: .utf8) }
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
