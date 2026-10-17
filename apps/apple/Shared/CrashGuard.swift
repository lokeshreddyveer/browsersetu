import Foundation

/// Counts how often one tab's web process has ended unexpectedly, so that reloading a page that keeps crashing
/// cannot trap the user in a crash-reload cycle. Pure: the caller supplies the clock.
struct CrashGuard {
    enum Verdict: Equatable {
        /// An isolated crash: offer a normal reload.
        case first
        /// Again within the window: still offer a reload, but say it is happening repeatedly.
        case repeated(Int)
        /// Three in the window: stop offering reloads for a while.
        case loop
    }

    static let window: TimeInterval = 120
    static let loopThreshold = 3
    static let pause: TimeInterval = 60

    private(set) var crashes: [Date] = []
    private(set) var pausedUntil: Date?

    mutating func record(at now: Date) -> Verdict {
        crashes.removeAll { now.timeIntervalSince($0) > Self.window }
        crashes.append(now)
        if crashes.count >= Self.loopThreshold {
            pausedUntil = now.addingTimeInterval(Self.pause)
            return .loop
        }
        return crashes.count == 1 ? .first : .repeated(crashes.count)
    }

    /// True while reloading the crashing page should be refused.
    func isPaused(at now: Date) -> Bool {
        guard let pausedUntil else { return false }
        return now < pausedUntil
    }

    func secondsLeft(at now: Date) -> Int {
        guard let pausedUntil, now < pausedUntil else { return 0 }
        return Int(pausedUntil.timeIntervalSince(now).rounded(.up))
    }

    /// Navigating somewhere else starts the count again.
    mutating func reset() {
        crashes = []
        pausedUntil = nil
    }
}

/// Notices when the app keeps ending during start-up (a crash while restoring the last session, say), so the next
/// start can bring tabs back without loading the page that may be responsible.
enum LaunchGuard {
    /// Consecutive earlier launches that never reached the healthy mark.
    static let loopThreshold = 2

    private static func marker(_ root: String) -> URL { URL(fileURLWithPath: root).appendingPathComponent(".launching") }

    /// Call at launch. Returns how many launches in a row ended before they were marked healthy (0 for a normal start).
    @discardableResult
    static func begin(root: String) -> Int {
        let url = marker(root)
        let previous = (try? String(contentsOf: url, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        let unfinished = FileManager.default.fileExists(atPath: url.path) ? max(previous, 1) : 0
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try? String(unfinished + 1).write(to: url, atomically: true, encoding: .utf8)
        return unfinished
    }

    /// Call once the app has run long enough to be considered started.
    static func markHealthy(root: String) {
        try? FileManager.default.removeItem(at: marker(root))
    }

    static func isLoop(unfinishedLaunches: Int) -> Bool { unfinishedLaunches >= loopThreshold }
}
