import Foundation

#if DEBUG
/// Development only: appends a line to a file the simulator shares with the Mac, so a run can be read afterwards.
func debugLog(_ line: String) {
    let url = URL(fileURLWithPath: "/tmp/claude/audit/inset.log")
    let data = Data((line + "\n").utf8)
    if let handle = try? FileHandle(forWritingTo: url) { handle.seekToEndOfFile(); handle.write(data); try? handle.close() } else { try? data.write(to: url) }
}
#endif
