import Foundation

/// The rules for when a window may exist, with nothing in them that needs a screen, so each can be tested. The behaviour they add up to is written down
/// in docs/windows.md.
enum WindowPolicy {
    /// A window the app asked for stays "asked for" this long. A request that never produced a window (the system declined to open one) must not be
    /// handed to a window that appears later for some other reason.
    static let requestLifetime: TimeInterval = 5

    /// The same link can reach the app more than once (for each window that listens for it). It is acted on once.
    static let duplicateWindow: TimeInterval = 1.5

    /// At most this many extra windows are brought back at start.
    static let restoreCap = 8

    static func live(_ requests: [Date], now: Date) -> [Date] {
        requests.filter { now.timeIntervalSince($0) < requestLifetime }
    }

    static func isDuplicate(_ url: URL, last: (url: URL, at: Date)?, now: Date) -> Bool {
        guard let last else { return false }
        return last.url == url && now.timeIntervalSince(last.at) < duplicateWindow
    }

    /// The windows saved at the last quit, made safe to use: no empty window, no tab in two windows, no more than the cap.
    static func restorable(_ stored: [[UInt64]]) -> [[UInt64]] {
        var seen = Set<UInt64>()
        var out: [[UInt64]] = []
        for group in stored {
            let fresh = group.filter { seen.insert($0).inserted }
            if !fresh.isEmpty { out.append(fresh) }
            if out.count == restoreCap { break }
        }
        return out
    }

    /// Which window a link from another app opens in: the one in front if it can take it, otherwise the first window, never a guest window and never
    /// one that is only there by accident. Names stand for windows; the caller maps them back.
    struct Candidate: Equatable {
        var id: Int
        var isGuest: Bool
        var isUnrequested: Bool
        var isFocused: Bool
        var isPrimary: Bool
    }

    static func externalTarget(among all: [Candidate]) -> Int? {
        let usable = all.filter { !$0.isGuest && !$0.isUnrequested }
        return usable.first(where: \.isFocused)?.id ?? usable.first(where: \.isPrimary)?.id ?? usable.first?.id
    }
}
