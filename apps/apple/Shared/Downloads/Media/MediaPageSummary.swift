import Foundation

/// What the page in front has shown of its media, for the toolbar: how many items were detected, and how many of those the existing picker would let the person open. The classification is the
/// picker's own (a scratch store with the same rules), so the badge never promises more than the picker offers; an item a provider restricts, protected media and in-page streams are detected
/// but not counted as openable.
struct MediaPageSummary: Equatable, Sendable {
    var detected = 0
    var openable = 0
    var restrictedBy: MediaProviderID?
    /// Of the detected items, how many are audio (the rest are video or in-page streams), and how many of those the picker can open.
    var audioDetected = 0
    var audioOpenable = 0
    static let empty = MediaPageSummary()
    var isEmpty: Bool { detected == 0 }

    @MainActor
    static func make(hits: [MediaPageHit], pageHost: String?, isPrivate: Bool) -> MediaPageSummary {
        guard !hits.isEmpty else { return .empty }
        let scratch = MediaDiscoveryStore(profile: "summary", isPrivate: isPrivate)
        _ = scratch.ingest(MediaPageSnapshot(hits: hits, truncated: false), pageKey: "summary|page", pageHost: pageHost, removeMissing: false)
        let all = scratch.candidates
        var s = MediaPageSummary(detected: all.count, openable: all.filter(\.canOpen).count)
        s.audioDetected = all.filter { $0.kind == .directAudio }.count
        s.audioOpenable = all.filter { $0.kind == .directAudio && $0.canOpen }.count
        s.restrictedBy = all.compactMap { ProviderPolicy.governing($0) }.first
        return s
    }

    var accessibilityText: String {
        if openable > 0 { return "Media on this page: \(detected) found, \(openable) can be opened" }
        if let p = restrictedBy { return "Media on this page: \(detected) found, none can be downloaded from \(p.displayName)" }
        return "Media on this page: \(detected) found, none can be downloaded"
    }
}
