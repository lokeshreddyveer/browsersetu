import Foundation

// MARK: Tracker management (BEP 12 announce lists, BEP 3 announce events, scrape)
//
// A torrent names its trackers in tiers (BEP 12). Each tier is an ordered list; the client talks to one tracker of a tier at a time, the first that answers, and moves an endpoint that
// answered to the front of its tier so the next announce asks it first. A failing endpoint is left alone for a while (doubling, up to an hour) and the next one in its tier is used,
// but it is never dropped for good. Tiers are independent of each other, each with its own announce, so a magnet link (which has no tiers: every `tr` is a list of one) is announced to
// every tracker it names, as before.
//
// Events (BEP 3 / BEP 15): `started` once per endpoint that answered it, `completed` once when the download finishes, `stopped` once when the torrent stops. A torrent that was already
// complete when it began does not send `completed`. After a relaunch the book is rebuilt from the torrent's own tiers and `started` is sent again, as a new session should.

struct TrackerScrape: Sendable, Equatable {
    /// nil is unknown, never zero.
    var seeders: Int?
    var completed: Int?
    var leechers: Int?
}

protocol TrackerScraping: AnyObject, Sendable {
    func scrape(_ tracker: URL, infoHash: Data) async throws -> TrackerScrape
}

/// What the torrent inspector shows for one tracker.
struct TrackerStatusRow: Identifiable, Equatable, Sendable {
    enum State: String, Sendable { case working = "Working", waiting = "Waiting", error = "Error", unsupported = "Unsupported" }
    var id: String
    /// Host and port only: the path and query of a tracker address can carry a personal key.
    var name: String
    var scheme: String
    var tier: Int
    var state: State
    var secondsSinceAnnounce: TimeInterval?
    var secondsUntilAnnounce: TimeInterval?
    var interval: TimeInterval?
    var seeders: Int?
    var leechers: Int?
    var completed: Int?
    var lastError: String?
    var scrapeNote: String?
    /// The failure is about the person's proxy choice, which only they can change: the inspector offers Open Settings.
    var needsSettings = false
}

struct TrackerBook: Sendable {
    struct Endpoint: Sendable {
        var url: URL
        var unsupported: String?
        var failures = 0
        var retryAt: TimeInterval = 0
        var lastAnnounce: TimeInterval?
        var interval: TimeInterval?
        var seeders: Int?, leechers: Int?, completed: Int?
        var lastError: String?
        var answered = false
        var startedSent = false
        var completedSent = false
        var stoppedSent = false
        var lastScrape: TimeInterval?
        /// Why the counts are not known, when asking failed. Kept apart from `lastError`, which is about announcing: a tracker that will not scrape is still a working tracker.
        var scrapeNote: String?
        var needsSettings = false
    }

    private(set) var tiers: [[Endpoint]]
    /// When each tier next announces (regularly), after its last good answer.
    private var nextAt: [TimeInterval]
    private var inFlight: [Int: URL] = [:]
    static let schemes: Set<String> = ["http", "https", "udp"]
    static let maxBackoff: TimeInterval = 3600
    static let minScrapeGap: TimeInterval = 60

    /// `tiers` in the order the torrent gives them. Equivalent addresses are kept once (the first wins), addresses of other kinds are kept but marked unsupported.
    init(tiers input: [[URL]]) {
        var seen = Set<String>(), out: [[Endpoint]] = []
        for tier in input {
            var list: [Endpoint] = []
            for url in tier {
                let key = Self.key(url)
                guard seen.insert(key).inserted else { continue }
                var e = Endpoint(url: url)
                if let scheme = url.scheme?.lowercased(), !Self.schemes.contains(scheme) { e.unsupported = "\(scheme) trackers are not supported" }
                list.append(e)
            }
            if !list.isEmpty { out.append(list) }
        }
        tiers = out
        nextAt = Array(repeating: 0, count: out.count)
    }

    /// Two addresses that reach the same tracker compare equal: scheme and host in lower case, the default port made explicit, a trailing slash ignored.
    static func key(_ url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? "", host = url.host?.lowercased() ?? ""
        let port = url.port ?? (scheme == "https" ? 443 : (scheme == "http" ? 80 : 0))
        var path = url.path; while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return "\(scheme)://\(host):\(port)\(path == "/" ? "" : path)\(url.query.map { "?" + $0 } ?? "")"
    }

    var endpointCount: Int { tiers.reduce(0) { $0 + $1.count } }
    var urls: [URL] { tiers.flatMap { $0.map(\.url) } }

    // MARK: Choosing

    /// The announces to start now: for each tier with nothing in flight and its time come, the first endpoint that is supported and not waiting out a failure. A tier whose endpoints are
    /// all waiting does nothing until the first of them is ready.
    func due(at now: TimeInterval) -> [(tier: Int, url: URL, event: String?)] {
        var out: [(Int, URL, String?)] = []
        for (t, list) in tiers.enumerated() where inFlight[t] == nil && nextAt[t] <= now {
            guard let e = list.first(where: { $0.unsupported == nil && $0.retryAt <= now }) else { continue }
            out.append((t, e.url, e.startedSent ? nil : "started"))
        }
        return out
    }

    mutating func began(tier: Int, url: URL) { inFlight[tier] = url }

    /// Announces owed because the download finished: one to each endpoint that heard `started` and has not heard `completed`.
    func completionTargets() -> [URL] { tiers.flatMap { $0.filter { $0.startedSent && !$0.completedSent && !$0.stoppedSent }.map(\.url) } }
    mutating func markCompletedSent(_ url: URL) { update(url) { $0.completedSent = true } }

    /// Announces owed because the torrent stopped: one to each endpoint that heard `started` and has not heard `stopped`. Asked once; the book then remembers it was.
    mutating func stopTargets() -> [URL] {
        var out: [URL] = []
        for t in tiers.indices { for i in tiers[t].indices where tiers[t][i].startedSent && !tiers[t][i].stoppedSent { tiers[t][i].stoppedSent = true; out.append(tiers[t][i].url) } }
        return out
    }

    // MARK: Results

    mutating func answered(tier: Int, url: URL, interval: TimeInterval, seeders: Int?, leechers: Int?, event: String?, at now: TimeInterval) {
        inFlight[tier] = nil
        guard let t = tiers.firstIndex(where: { $0.contains { Self.key($0.url) == Self.key(url) } }), let i = tiers[t].firstIndex(where: { Self.key($0.url) == Self.key(url) }) else { return }
        var e = tiers[t][i]
        e.failures = 0; e.retryAt = 0; e.lastError = nil; e.needsSettings = false; e.answered = true
        e.lastAnnounce = now; e.interval = interval
        if let seeders { e.seeders = seeders }; if let leechers { e.leechers = leechers }
        if event == "started" { e.startedSent = true }
        if event == "completed" { e.completedSent = true }
        // The one that answered goes to the front of its tier.
        tiers[t].remove(at: i); tiers[t].insert(e, at: 0)
        nextAt[t] = now + interval
    }

    mutating func failed(tier: Int, url: URL, reason: String, unsupported: Bool = false, needsSettings: Bool = false, at now: TimeInterval) {
        inFlight[tier] = nil
        update(url) { e in
            e.lastError = reason; e.needsSettings = needsSettings
            if unsupported { e.unsupported = reason; return }
            e.failures += 1
            e.retryAt = now + min(Self.maxBackoff, 60 * pow(2, Double(min(e.failures - 1, 6))))
        }
        // The next endpoint of the tier may go at once; if all are waiting, the tier waits for the earliest.
        if let t = tiers.firstIndex(where: { $0.contains { Self.key($0.url) == Self.key(url) } }) { nextAt[t] = min(nextAt[t], now) }
    }

    /// The attempt could not be made now (the client's own sockets are all in use): not the tracker's fault, so it is not counted against it, and the tier tries again shortly.
    mutating func postponed(tier: Int, url: URL, delay: TimeInterval, at now: TimeInterval) {
        inFlight[tier] = nil
        if let t = tiers.firstIndex(where: { $0.contains { Self.key($0.url) == Self.key(url) } }) { nextAt[t] = now + delay }
    }

    /// A reply to an announce that was in flight when the torrent stopped changes nothing.
    mutating func abandonAll() { inFlight = [:] }

    mutating func scraped(_ url: URL, _ result: TrackerScrape, at now: TimeInterval) {
        update(url) { e in
            e.lastScrape = now; e.scrapeNote = nil
            if let s = result.seeders { e.seeders = s }; if let l = result.leechers { e.leechers = l }; if let c = result.completed { e.completed = c }
        }
    }

    /// Counted from the moment the request goes out, so asking twice quickly sends one request, not two.
    mutating func scrapeStarted(_ url: URL, at now: TimeInterval) { update(url) { $0.lastScrape = now } }

    mutating func scrapeFailed(_ url: URL, note: String, at now: TimeInterval) { update(url) { $0.lastScrape = now; $0.scrapeNote = note } }

    /// The endpoints that may be scraped now: supported, not scraped in the last minute, and one per tier (the first that has answered, or else the first).
    func scrapeTargets(at now: TimeInterval) -> [URL] {
        tiers.compactMap { list in
            let e = list.first(where: { $0.answered && $0.unsupported == nil }) ?? list.first(where: { $0.unsupported == nil })
            guard let e, e.lastScrape.map({ now - $0 >= Self.minScrapeGap }) ?? true else { return nil }
            return e.url
        }
    }

    // MARK: Status

    func statuses(at now: TimeInterval) -> [TrackerStatusRow] {
        var rows: [TrackerStatusRow] = []
        for (t, list) in tiers.enumerated() {
            for e in list {
                let state: TrackerStatusRow.State
                if e.unsupported != nil { state = .unsupported }
                else if e.failures > 0 { state = e.retryAt > now ? .error : .waiting }
                else if e.answered { state = .working }
                else { state = .waiting }
                let until: TimeInterval? = (e.unsupported == nil && e.answered && e.failures == 0) ? max(0, nextAt[t] - now) : (e.failures > 0 && e.retryAt > now ? e.retryAt - now : nil)
                rows.append(TrackerStatusRow(id: "\(Self.displayName(e.url))#\(abs(Self.key(e.url).hashValue))", name: Self.displayName(e.url), scheme: (e.url.scheme ?? "").uppercased(), tier: t + 1, state: state,
                                             secondsSinceAnnounce: e.lastAnnounce.map { max(0, now - $0) }, secondsUntilAnnounce: until, interval: e.interval,
                                             seeders: e.seeders, leechers: e.leechers, completed: e.completed, lastError: e.lastError ?? e.unsupported, scrapeNote: e.scrapeNote, needsSettings: e.needsSettings))
            }
        }
        return rows
    }

    static func displayName(_ url: URL) -> String {
        guard let host = url.host else { return "tracker" }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    private mutating func update(_ url: URL, _ change: (inout Endpoint) -> Void) {
        let k = Self.key(url)
        for t in tiers.indices { if let i = tiers[t].firstIndex(where: { Self.key($0.url) == k }) { change(&tiers[t][i]); return } }
    }
}
