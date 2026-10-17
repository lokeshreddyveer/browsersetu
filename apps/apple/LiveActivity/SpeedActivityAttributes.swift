import Foundation
#if canImport(ActivityKit)
import ActivityKit

/// What the Dynamic Island shows: the current download and upload speed, in bytes per second. Shared by the app and its widget.
struct SpeedActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var down: Double
        var up: Double
    }
}
#endif

enum SpeedText {
    /// "2.4 Mbps", "320 Kbps": bits per second, as network speeds are quoted.
    static func full(_ bytesPerSecond: Double) -> String {
        let bits = max(bytesPerSecond, 0) * 8
        switch bits {
        case ..<1_000: return "0 Kbps"
        case ..<1_000_000: return String(format: "%.0f Kbps", bits / 1_000)
        case ..<100_000_000: return String(format: "%.1f Mbps", bits / 1_000_000)
        default: return String(format: "%.0f Mbps", bits / 1_000_000)
        }
    }

    /// Short enough for the narrow side of the island: "2.4M", "320K".
    static func short(_ bytesPerSecond: Double) -> String {
        let bits = max(bytesPerSecond, 0) * 8
        switch bits {
        case ..<1_000: return "0K"
        case ..<1_000_000: return String(format: "%.0fK", bits / 1_000)
        case ..<100_000_000: return String(format: "%.1fM", bits / 1_000_000)
        default: return String(format: "%.0fM", bits / 1_000_000)
        }
    }
}
