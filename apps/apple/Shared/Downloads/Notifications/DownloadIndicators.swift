import Foundation

/// What the Dock badge and the toolbar say about downloads, worked out from the shared state. One calculation, so the two never disagree.
struct DownloadIndicatorSnapshot: Equatable {
    var active: Int
    var queued: Int
    var failed: Int
    var needsAttention: Int
    /// Only when every running download has a known size; otherwise nil, because an average of unknown sizes would be a made-up number.
    var aggregateProgress: Double?
    var badge: String?
    var summary: String
}

enum DownloadIndicators {
    static func make(active: [ActiveDownload], queued: Int, failed: Int, needsAttention: Int) -> DownloadIndicatorSnapshot {
        let running = active.count
        var aggregate: Double?
        if running > 0, active.allSatisfy({ $0.totalBytes > 0 }) {
            let total = active.reduce(Int64(0)) { $0 + $1.totalBytes }, done = active.reduce(Int64(0)) { $0 + min($1.completedBytes, $1.totalBytes) }
            aggregate = total > 0 ? Double(done) / Double(total) : nil
        }
        let badge: String?
        if running > 0 { badge = aggregate.map { "\(Int(($0 * 100).rounded()))%" } ?? "\(running)" }
        else if needsAttention > 0 || failed > 0 { badge = "!" }
        else if queued > 0 { badge = "\(queued)" }
        else { badge = nil }
        var parts: [String] = []
        if running > 0 { parts.append("\(running) downloading") }
        if queued > 0 { parts.append("\(queued) waiting") }
        if failed > 0 { parts.append("\(failed) failed") }
        if needsAttention > 0 { parts.append("\(needsAttention) need attention") }
        return DownloadIndicatorSnapshot(active: running, queued: queued, failed: failed, needsAttention: needsAttention, aggregateProgress: aggregate, badge: badge, summary: parts.isEmpty ? "No downloads" : parts.joined(separator: ", "))
    }

    /// A private download is never counted: the Dock icon and the toolbar are on screen for anyone looking.
    @MainActor
    static func make(_ c: DownloadCoordinator) -> DownloadIndicatorSnapshot {
        func isPrivate(_ id: UUID) -> Bool { c.ledger.record(id)?.isPrivate == true }
        let mine = c.ledger.records.values.filter { !$0.isPrivate }
        return make(active: c.active.values.filter { !isPrivate($0.id) }, queued: c.waiting.filter { !isPrivate($0.id) }.count, failed: c.failures.filter { !isPrivate($0.id) }.count,
                    needsAttention: mine.filter { $0.state == .recoveryRequired }.count)
    }
}
