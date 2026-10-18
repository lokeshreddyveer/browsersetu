#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation
import CryptoKit
import UserNotifications

/// Wording for download progress: sizes, speed and time left.
enum DownloadStats {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    /// Seconds left, or nil when the rate or size is unknown.
    static func secondsLeft(completed: Int64, total: Int64, rate: Double) -> Double? {
        guard total > completed, rate > 1 else { return nil }
        return Double(total - completed) / rate
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(max(1, s)) s" }
        if s < 3600 { return "\((s + 30) / 60) min" }
        return "\(s / 3600) h \((s % 3600) / 60) min"
    }

    /// "48 of 78 MB · 6.1 MB/s · about 5 s left", leaving out whatever is not known yet.
    static func detail(completed: Int64, total: Int64, rate: Double) -> String {
        var parts: [String] = []
        if total > 0 { parts.append("\(bytes(completed)) of \(bytes(total))") } else if completed > 0 { parts.append(bytes(completed)) }
        if rate > 1 { parts.append("\(bytes(Int64(rate)))/s") }
        if let left = secondsLeft(completed: completed, total: total, rate: rate) { parts.append("about \(duration(left)) left") }
        return parts.joined(separator: " · ")
    }
}

enum DiskSpace {
    static func available(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Tight when the file would leave less than 5% of what it needs, or under 100 MB, spare.
    static func isTight(needed: Int64, available: Int64) -> Bool {
        guard needed > 0 else { return false }
        return available < needed + max(100_000_000, needed / 20)
    }
}

enum FileChecksum {
    /// SHA-256 as lowercase hex, read in chunks so a large file never sits in memory.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Compares ignoring case, spaces and an optional "sha256:" prefix.
    static func matches(_ expected: String, _ actual: String) -> Bool {
        func clean(_ s: String) -> String {
            var t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if t.hasPrefix("sha256:") { t.removeFirst(7) }
            return t.replacingOccurrences(of: " ", with: "")
        }
        let e = clean(expected)
        return !e.isEmpty && e == clean(actual)
    }
}

/// A banner when a download finishes while the app is in the background.
enum DownloadNotifier {
    @MainActor static func finished(_ filename: String) {
        #if os(macOS)
        let inactive = !NSApplication.shared.isActive
        #else
        let inactive = UIApplication.shared.applicationState != .active
        #endif
        guard inactive else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Download finished"
            content.body = filename
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
