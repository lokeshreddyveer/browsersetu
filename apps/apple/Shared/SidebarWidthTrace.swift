import Foundation

#if DEBUG
/// DEBUG-only, bounded diagnosis of the Library's width. Off unless the environment variable BS_SIDEBAR_TRACE names a file; then every change of `sidebarWidth` (with the few calls above it), the stored value read
/// back at start-up, the drag events of the resize grip, the saves and the cross-window reloads are appended there, at most 400 lines. It writes nothing else and nothing in a Release build.
enum SidebarWidthTrace {
    private static let path = ProcessInfo.processInfo.environment["BS_SIDEBAR_TRACE"]
    nonisolated(unsafe) private static var lines = 0

    static func log(_ text: @autoclosure () -> String) {
        guard let path, lines < 400 else { return }
        lines += 1
        let line = String(format: "%.3f %@\n", ProcessInfo.processInfo.systemUptime, text())
        if let handle = FileHandle(forWritingAtPath: path) { defer { try? handle.close() }; _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(line.utf8)) }
        else { try? line.write(toFile: path, atomically: false, encoding: .utf8) }
    }

    /// The calls that led here, trimmed to the app's own frames.
    static func caller() -> String {
        guard path != nil else { return "" }
        return Thread.callStackSymbols.dropFirst(2).prefix(6).map { frame in
            frame.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).first.map(String.init) ?? frame
        }.joined(separator: " < ")
    }
}
#else
enum SidebarWidthTrace {
    @inline(__always) static func log(_ text: @autoclosure () -> String) {}
    @inline(__always) static func caller() -> String { "" }
}
#endif
