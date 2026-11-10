import Foundation

enum DownloadPriority: Int, Codable, CaseIterable, Identifiable, Comparable {
    case low = 0, normal = 1, high = 2
    var id: Int { rawValue }
    var title: String { switch self { case .low: "Low"; case .normal: "Normal"; case .high: "High" } }
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// A download waiting for a free place. WebKit starts fetching only once a destination is chosen, so holding the answer holds the download.
struct QueuedDownload: Identifiable, Equatable {
    let id: UUID
    var filename: String
    var priority: DownloadPriority
    var enqueued: Date
    var source: URL?
    /// 1 for the next to start.
    var position = 0
    /// A paused download waiting for a free place to carry on, or a retry waiting for one (the list shows these as what they are, not as new downloads).
    var isResume = false
    var isRetry = false
}

enum DownloadQueueRules {
    static let maxConcurrentChoices = [1, 2, 3, 4, 6, 8]
    static let defaultConcurrent = 3

    /// Who goes next: higher priority first, then whoever has waited longest. Pure, so the order can be tested.
    static func next(from waiting: [QueuedDownload]) -> QueuedDownload? {
        waiting.min { a, b in a.priority != b.priority ? a.priority > b.priority : (a.enqueued, a.id.uuidString) < (b.enqueued, b.id.uuidString) }
    }

    /// How many more may start now.
    static func freeSlots(limit: Int, running: Int, reserved: Int) -> Int { max(0, limit - running - reserved) }
}

/// When a failed download is tried again: a few times, a little later each time, and only for failures that a retry can fix.
enum DownloadRetry {
    static let maxAttempts = 4

    /// The wait before an attempt, without jitter: 5 s, 10 s, 20 s, 40 s ... at most 5 minutes.
    static func delay(afterAttempt attempt: Int) -> TimeInterval { min(300, 5 * pow(2, Double(max(0, attempt - 1)))) }

    /// The longest a server's own "try again after" is honoured: an hour. A larger one is a different kind of problem and is not waited out silently.
    static let maxRetryAfter: TimeInterval = 3600

    /// The one wait every engine uses: the backoff above, spread by up to ±20% so many tasks that failed together do not all come back together, never sooner than the server
    /// asked (Retry-After), and never longer than `maxRetryAfter`. `jitter` is in 0...1 (a parameter so tests are exact). `scale` is 1 in the app.
    static func delay(afterAttempt attempt: Int, retryAfter: TimeInterval?, jitter: Double = Double.random(in: 0...1), scale: Double = 1) -> TimeInterval {
        let base = delay(afterAttempt: attempt)
        let spread = base * (0.8 + 0.4 * min(1, max(0, jitter)))
        return max(spread * scale, min(retryAfter ?? 0, maxRetryAfter))
    }

    static func isRetryable(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        return [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet, NSURLErrorCannotConnectToHost,
                NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed, NSURLErrorInternationalRoamingOff, NSURLErrorDataNotAllowed].contains(ns.code)
    }
}

/// "Start downloads later": a download that arrives while the queue is held until a set time is remembered by its address and started when the time comes.
struct ScheduledDownload: Codable, Equatable, Identifiable {
    var id = UUID()
    var url: String
    var filename: String
    var priority: DownloadPriority
    /// The absolute moment it starts (nil: when the queue is released). Saved with the task, so it survives a relaunch.
    var dueAt: Date? = nil
    /// Put off by the queue's hold (it starts when the hold ends), as opposed to scheduled by the person for a time of its own (it starts then, whatever happens to the hold).
    var heldByQueue = false
}

enum DownloadSchedule {
    /// The next occurrence of a time of day, today if it is still ahead, otherwise tomorrow.
    static func nextOccurrence(hour: Int, minute: Int, after now: Date = Date(), calendar: Calendar = .current) -> Date? {
        calendar.nextDate(after: now, matching: DateComponents(hour: hour, minute: minute, second: 0), matchingPolicy: .nextTime)
    }

    static func isHeld(until: Date?, now: Date = Date()) -> Bool { until.map { $0 > now } ?? false }

    /// Only web addresses can be started again later, and not one whose signature was not kept (it is never started from a stump).
    static func canSchedule(_ url: URL?) -> Bool { url.map { ["http", "https"].contains($0.scheme?.lowercased() ?? "") && $0.host != nil && !DownloadURLRedactor.lostSecret($0) } ?? false }
}


#if os(iOS)
import UIKit

/// Keeps downloads going for the extra time iOS gives an app that has just gone to the background, and asks them to save their place just before that time runs out,
/// so they can be resumed later. (WebKit downloads cannot continue once the app is suspended; a few minutes at most.)
@MainActor
final class DownloadBackgroundTask {
    static let shared = DownloadBackgroundTask()
    private var task = UIBackgroundTaskIdentifier.invalid
    var coordinator: DownloadCoordinator?

    func update(hasActive: Bool) {
        if hasActive, task == .invalid {
            task = UIApplication.shared.beginBackgroundTask(withName: "downloads") { [weak self] in
                MainActor.assumeIsolated {
                    self?.coordinator?.suspendAll { self?.finish() }
                }
            }
        } else if !hasActive { finish() }
    }

    private func finish() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}
#endif
