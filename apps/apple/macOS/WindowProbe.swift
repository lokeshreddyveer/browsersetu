#if DEBUG
import AppKit

/// Debug only, started by `-UIWindowProbe <file>` (a throwaway test run): watches the browser window for the abnormal growth behind a crash ("The window has been marked as needing another Update Constraints
/// in Window pass", the window 22,500 points wide). It samples five times a second and writes a line ONLY when something looks wrong (the window wider than 2,500 points, SwiftUI asking for a minimum content
/// width over 1,800), with the widest views in the window at that moment. It records sizes and class names only: no URLs, titles or other content.
/// The file is capped at 120 lines, and nothing else is written.
@MainActor
enum WindowProbe {
    private static var timer: Timer?
    private static var lastWidth: CGFloat = 0
    private static var lines = 0
    private static var startedAt = Date()

    static func startIfRequested() {
        guard timer == nil, let path = UserDefaults.standard.string(forKey: "UIWindowProbe"), !path.isEmpty else { return }
        startedAt = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in MainActor.assumeIsolated { sample(path) } }
    }

    private static func sample(_ path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 300 && $0.identifier?.rawValue.contains("AppWindow") == true }) else { return }
        let width = window.frame.width, minWidth = window.contentMinSize.width
        defer { lastWidth = width }
        guard width > 2_500 || minWidth > 1_800, lines < 120 else { return }
        var report = String(format: "t=%.2fs frame=%.0fx%.0f contentMin=%.0fx%.0f contentMax=%.0f fitting=%.0f previous=%.0f", Date().timeIntervalSince(startedAt), width, window.frame.height,
                            minWidth, window.contentMinSize.height, window.contentMaxSize.width, window.contentView?.fittingSize.width ?? -1, lastWidth)
        var widest: [(CGFloat, String)] = []
        func walk(_ view: NSView, depth: Int) {
            widest.append((view.frame.width, "\(type(of: view)) depth \(depth) fitting \(Int(view.fittingSize.width))"))
            for sub in view.subviews { walk(sub, depth: depth + 1) }
        }
        if let content = window.contentView { walk(content, depth: 0) }
        for (w, name) in widest.sorted(by: { $0.0 > $1.0 }).prefix(6) { report += String(format: "\n    %.0f  %@", w, name) }
        lines += 1
        let data = Data((report + "\n").utf8)
        if let handle = FileHandle(forWritingAtPath: path) { defer { try? handle.close() }; _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data) }
        else { FileManager.default.createFile(atPath: path, contents: data) }
    }
}
#endif
