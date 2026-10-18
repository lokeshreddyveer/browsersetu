import Foundation

/// Finishing an address as you type it: "git" becomes "github.com" when you have been there. Only the start of a site's name counts, never the middle,
/// and nothing is completed once a space, a path or a scheme has been typed (that is a search or a full address, not a half-typed site).
enum URLCompletion {
    /// The site (without "www.") to finish `typed` with, from `sites` listed most-visited first; nil when none starts with it.
    static func complete(_ typed: String, sites: [String]) -> String? {
        let wanted = typed.lowercased()
        guard !wanted.isEmpty, !wanted.contains(" "), !wanted.contains("/"), !wanted.contains(":") else { return nil }
        for site in sites {
            let name = site.lowercased().hasPrefix("www.") ? String(site.lowercased().dropFirst(4)) : site.lowercased()
            if name.hasPrefix(wanted), name != wanted { return name }
        }
        return nil
    }

    /// The sites to complete from: the ones visited most, then bookmarked ones, each once.
    static func sites(history: [(url: String, visits: Int)], bookmarks: [String]) -> [String] {
        var counts: [String: Int] = [:]
        for item in history { if let host = URL(string: item.url)?.host { counts[host, default: 0] += max(1, item.visits) } }
        for url in bookmarks { if let host = URL(string: url)?.host { counts[host, default: 0] += 3 } }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    /// What to search for to look inside one website: the engines all understand "site:".
    static func siteQuery(host: String, query: String) -> String {
        let site = host.lowercased().hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return "site:\(site) \(query.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}
