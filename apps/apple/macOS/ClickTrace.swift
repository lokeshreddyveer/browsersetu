import AppKit

#if DEBUG
/// DEBUG-only, bounded record of the mouse around a tab click, to catch a click that is lost (the Minimal hover-then-click failure). Off unless BS_CLICK_TRACE=1 and BS_CHROME_TRACE names a file; it then
/// writes each left-button press, release and drag (window point, screen point, click count, the views under the pointer, the key window, how many windows hang off the browser window) to that same file and clock
/// as the chrome trace, at most 300 lines. It changes no event and nothing in a Release build.
enum ClickTrace {
    nonisolated(unsafe) private static var installed = false
    nonisolated(unsafe) private static var lines = 0

    @MainActor static func installIfRequested() {
        guard !installed, ProcessInfo.processInfo.environment["BS_CLICK_TRACE"] == "1" else { return }
        installed = true
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]) { event in
            guard lines < 300 else { return event }
            lines += 1
            let kind: String = event.type == .leftMouseDown ? "down" : (event.type == .leftMouseUp ? "up" : "drag")
            var hit = "-"
            if let content = event.window?.contentView {
                var view = content.hitTest(content.convert(event.locationInWindow, from: nil))
                var chain: [String] = []
                while let v = view, chain.count < 4 { chain.append(String(describing: type(of: v))); view = v.superview }
                hit = chain.joined(separator: " < ")
            }
            let screen = NSEvent.mouseLocation
            ChromeTrace.log(String(format: "MOUSE %@ win(%.0f,%.0f) screen(%.0f,%.0f) clicks=%d keyWindow=%@ children=%d appActive=%@ hit=%@", kind, event.locationInWindow.x, event.locationInWindow.y, screen.x, screen.y,
                                   event.clickCount, NSApp.keyWindow === event.window ? "this" : "other", event.window?.childWindows?.count ?? 0, NSApp.isActive ? "yes" : "no", hit))
            return event
        }
    }
}
#else
enum ClickTrace { @MainActor static func installIfRequested() {} }
#endif
