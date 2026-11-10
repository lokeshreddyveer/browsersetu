import Foundation

/// One thing the favicon subsystem did, in words that can be shown to the person without revealing what they browse.
/// A host and a fixed reason, never a page address, an icon address or a query. Held in memory only, a small ring, and never sent anywhere.
struct FaviconDiagnosticEvent: Sendable, Equatable {
    enum Kind: String, Sendable {
        case cacheHit, backedOff, stored, revalidated, staleKept, fetchFailed, decodeFailed, candidateOrder, candidateBlocked, evicted, quarantined, imported, cleared
    }
    var at: Date
    var kind: Kind
    var host: String
    /// A fixed token (an `IconFetchFailure` or `IconDecoder.Failure` name, a count), never free text from the network.
    var detail: String
}

struct FaviconDiagnosticsLog: Sendable {
    static let capacity = 200
    private(set) var events: [FaviconDiagnosticEvent] = []

    mutating func add(_ kind: FaviconDiagnosticEvent.Kind, host: String, detail: String = "", at: Date) {
        events.append(FaviconDiagnosticEvent(at: at, kind: kind, host: host, detail: detail))
        if events.count > Self.capacity { events.removeFirst(events.count - Self.capacity) }
    }

    mutating func removeAll() { events.removeAll() }
}
