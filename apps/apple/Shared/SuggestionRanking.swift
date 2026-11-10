import Foundation

/// One result that could be shown under the address bar, reduced to what ranking needs.
struct RankCandidate: Equatable {
    enum Source: Int { case command = 0, page = 1, history = 2, bookmark = 3, openTab = 4 }      // when two are the same destination, the higher one is kept
    var key: String
    var source: Source
    var title: String
    var url: String
    var visitCount: Int = 0
    var lastVisit: Date?
    var isBookmark = false
    var isEssential = false
    var isOpenTab = false
    /// Where it sat in the list before ranking, so equal scores keep their order.
    var order = 0
}

/// What the device has learned about one destination.
struct LearnedSignals: Equatable {
    var workspaceVisits = 0
    var totalVisits = 0
    /// Times it was chosen after typing something that starts like what is typed now (or the other way round).
    var selectionsForQuery = 0
    var selectionsTotal = 0
}

/// Orders the address bar's results by a weighted sum of six signals, each scaled to 0…1:
///
///     S = 0.35·T + 0.20·F + 0.15·R + 0.15·W + 0.10·B + 0.05·H
///
/// T text relevance, F visit frequency, R recency, W workspace affinity, B bookmarks and Essentials, H what was chosen before. The weights are first guesses
/// to be tuned by watching people use it, not measured optima. Everything is computed here, on the device, from the profile's own history.
enum SuggestionRanking {
    static let wText = 0.35, wFrequency = 0.20, wRecency = 0.15, wWorkspace = 0.15, wFavorite = 0.10, wChosen = 0.05
    /// Recency halves every two weeks.
    static let recencyHalfLifeDays = 14.0
    /// A result this good is promoted to sit right under the typed text ("top hit").
    static let topHitThreshold = 0.5

    struct Scored: Equatable {
        var candidate: RankCandidate
        var score: Double
        var text: Double
    }

    // MARK: Signals

    /// 0…1: how well the words typed fit the title and the address. Every word has to fit somewhere; the score is the average of each word's best fit.
    static func textRelevance(query: String, title: String, url: String) -> Double {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return 0 }
        let title = title.lowercased()
        let host = hostWithoutWWW(url)
        let address = url.lowercased()
        var total = 0.0
        for word in words {
            let best = max(fit(word, in: host, hostField: true), fit(word, in: title, hostField: false), address.contains(word) ? 0.4 : 0)
            if best == 0 { return 0 }
            total += best
        }
        return total / Double(words.count)
    }

    private static func fit(_ word: String, in field: String, hostField: Bool) -> Double {
        guard !field.isEmpty, field.contains(word) else { return 0 }
        if field == word || (hostField && field.hasPrefix(word + ".")) { return 1.0 }           // the whole name: "github" for github.com
        if field.hasPrefix(word) { return hostField ? 0.9 : 0.8 }
        // The start of a later word: "hub" in "Git Hub Docs".
        let separators = CharacterSet(charactersIn: " .-_/:")
        if field.components(separatedBy: separators).contains(where: { $0.hasPrefix(word) }) { return hostField ? 0.7 : 0.75 }
        return 0.5                                                                                  // somewhere inside
    }

    private static func hostWithoutWWW(_ url: String) -> String {
        var host = URL(string: url)?.host?.lowercased() ?? ""
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    /// A page chosen from the address bar is worth more than one reached by a link, as in Firefox's frecency (typed and bookmarked visits weigh most): each choice
    /// counts as this many visits on top of the page's ordinary ones.
    static let choiceCountsAsVisits = 3

    static func effectiveVisits(_ c: RankCandidate, _ signals: LearnedSignals) -> Int {
        max(c.visitCount, signals.totalVisits) + choiceCountsAsVisits * signals.selectionsTotal
    }

    /// 0…1 against the most visited of the candidates (log scale, so one huge count does not flatten the rest).
    static func frequency(_ visits: Int, maxVisits: Int) -> Double {
        guard visits > 0, maxVisits > 0 else { return 0 }
        return min(1, log(1 + Double(visits)) / log(1 + Double(maxVisits)))
    }

    static func recency(_ last: Date?, now: Date) -> Double {
        guard let last else { return 0 }
        let days = max(0, now.timeIntervalSince(last) / 86_400)
        return pow(0.5, days / recencyHalfLifeDays)
    }

    /// The share of this destination's learned visits that happened in the workspace in front.
    static func workspaceAffinity(_ signals: LearnedSignals) -> Double {
        guard signals.totalVisits > 0 else { return 0 }
        return min(1, Double(signals.workspaceVisits) / Double(signals.totalVisits))
    }

    static func favorite(_ c: RankCandidate) -> Double {
        if c.isEssential || c.isBookmark { return 1.0 }
        return c.isOpenTab ? 0.5 : 0
    }

    /// Chosen for something like this query counts most; chosen at all counts a little.
    static func chosen(_ signals: LearnedSignals) -> Double {
        min(1, 0.7 * min(1, Double(signals.selectionsForQuery) / 3) + 0.3 * min(1, Double(signals.selectionsTotal) / 10))
    }

    // MARK: Ranking

    static func score(_ c: RankCandidate, query: String, signals: LearnedSignals, maxVisits: Int, now: Date) -> Scored {
        let t = textRelevance(query: query, title: c.title, url: c.url)
        // Nothing that does not fit what was typed is shown because it is popular.
        guard t > 0 else { return Scored(candidate: c, score: 0, text: 0) }
        let visits = effectiveVisits(c, signals)
        let s = wText * t + wFrequency * frequency(visits, maxVisits: maxVisits) + wRecency * recency(c.lastVisit, now: now)
            + wWorkspace * workspaceAffinity(signals) + wFavorite * favorite(c) + wChosen * chosen(signals)
        return Scored(candidate: c, score: min(1, s), text: t)
    }

    /// Several results for one destination become one: the best kind of them (an open tab, then a bookmark, then history), with the largest counts and
    /// the favourite marks of all.
    static func deduplicated(_ list: [RankCandidate]) -> [RankCandidate] {
        var byKey: [String: RankCandidate] = [:]
        var order: [String] = []
        for item in list {
            if var existing = byKey[item.key] {
                if item.source.rawValue > existing.source.rawValue { existing.source = item.source; existing.title = item.title.isEmpty ? existing.title : item.title; existing.url = item.url }
                existing.visitCount = max(existing.visitCount, item.visitCount)
                if let d = item.lastVisit { existing.lastVisit = max(existing.lastVisit ?? d, d) }
                existing.isBookmark = existing.isBookmark || item.isBookmark
                existing.isEssential = existing.isEssential || item.isEssential
                existing.isOpenTab = existing.isOpenTab || item.isOpenTab
                byKey[item.key] = existing
            } else {
                byKey[item.key] = item
                order.append(item.key)
            }
        }
        return order.compactMap { byKey[$0] }
    }

    /// Best first; equal scores keep the order they came in.
    static func rank(_ candidates: [RankCandidate], query: String, now: Date = Date(), signals: (RankCandidate) -> LearnedSignals) -> [Scored] {
        let unique = deduplicated(candidates)
        let maxVisits = unique.map { effectiveVisits($0, signals($0)) }.max() ?? 0
        return unique.map { score($0, query: query, signals: signals($0), maxVisits: maxVisits, now: now) }
            .sorted { ($0.score, -Double($0.candidate.order)) > ($1.score, -Double($1.candidate.order)) }
    }

    static func isTopHit(_ scored: Scored) -> Bool { scored.score >= topHitThreshold }
}

/// Which destinations may be learned at all.
enum SuggestionPrivacy {
    /// A normal web page, not an internal page, not one with a password in its address, not a site the person excluded.
    static func isLearnable(_ url: URL?, excludedHosts: [String]) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host?.lowercased(), !host.isEmpty else { return false }
        guard url.user == nil, url.password == nil else { return false }
        return !excludedHosts.contains { rule in
            let r = rule.lowercased()
            return !r.isEmpty && (host == r || host.hasSuffix("." + r))
        }
    }

    /// The destination without its query or fragment (search words and tokens are not kept), "host/path", lowercase, no "www." and no trailing slash.
    static func key(for url: URL) -> String {
        var host = (url.host ?? "").lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        var path = url.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path == "/" { path = "" }
        return String((host + path.lowercased()).prefix(160))
    }
}
