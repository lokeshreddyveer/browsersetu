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

    /// Whether `needed` bytes fit with room to spare: the spare is the larger of `floor` and `needed / divisor`. Every engine asks here; each passes the spare its own work needs
    /// (a torrent's pieces, a converted movie and a thousand small files do not need the same), so the rule is one and the margins stay the engine's own.
    static func fits(needed: Int64, available: Int64, floor: Int64 = 0, divisor: Int64 = 20) -> Bool {
        let spare = max(floor, divisor > 0 ? needed / divisor : 0)
        let (total, overflow) = needed.addingReportingOverflow(spare)
        return !overflow && available >= total
    }

    /// Tight when the file would leave less than 5% of what it needs, or under 100 MB, spare.
    static func isTight(needed: Int64, available: Int64) -> Bool {
        guard needed > 0 else { return false }
        return !fits(needed: needed, available: available, floor: 100_000_000, divisor: 20)
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
