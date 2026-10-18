import Foundation

/// What a page asked for on the network, worked out from the page's own resource timings and the requests that were refused.
struct PageNetworkReport: Equatable {
    var blockedURLs: [String] = []
    /// Hosts of other sites the page loaded something from, once each.
    var thirdPartyHosts: [String] = []

    /// Refused requests grouped by host, most first.
    var blockedByHost: [(host: String, count: Int)] {
        Dictionary(grouping: blockedURLs.compactMap { URL(string: $0)?.host?.lowercased() }, by: { $0 })
            .map { ($0.key, $0.value.count) }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
    }

    /// A guess from the names of the hosts, since the browser is not told which list blocked a request.
    var kinds: (ads: Int, trackers: Int, other: Int) {
        var r = (ads: 0, trackers: 0, other: 0)
        for (host, count) in blockedByHost {
            switch BlockedClassifier.kind(ofHost: host) {
            case .ad: r.ads += count
            case .tracker: r.trackers += count
            case .other: r.other += count
            }
        }
        return r
    }
}

enum BlockedKind { case ad, tracker, other }

enum BlockedClassifier {
    private static let adWords = ["doubleclick", "adservice", "adsystem", "adnxs", "adsrvr", "adform", "taboola", "outbrain", "criteo", "pubmatic", "rubicon", "openx",
                                  "googlesyndication", "amazon-adsystem", "smartadserver", "ads.", "ad.", "adserver", "advert"]
    private static let trackerWords = ["analytics", "tracker", "tracking", "pixel", "metrics", "telemetry", "segment", "mixpanel", "hotjar", "scorecardresearch",
                                       "quantserve", "demdex", "branch.io", "adjust.com", "appsflyer", "fullstory", "clarity.ms", "stats.", "beacon", "collect"]

    static func kind(ofHost host: String) -> BlockedKind {
        let h = host.lowercased()
        if adWords.contains(where: { h.contains($0) }) { return .ad }
        if trackerWords.contains(where: { h.contains($0) }) { return .tracker }
        return .other
    }
}

/// The choice for how much of the address a page learns about where a visitor came from.
enum ReferrerMode: String, CaseIterable, Identifiable {
    case standard, sameSite
    var id: String { rawValue }
    var title: String { self == .standard ? "Standard" : "Only within the same site" }
    var summary: String {
        self == .standard ? "Other sites learn which site you came from, never the full address (the browser's normal rule)."
                          : "Other sites learn nothing about where you came from. A few sites that check the referrer for sign-in or downloads may need an exception."
    }

    /// Added to every page before it runs. A page that sets its own policy on a link or request still wins; this is the default for the rest.
    static let script = """
    (function () {
      try {
        function add() {
          if (document.querySelector('meta[name=referrer][data-bs]')) { return; }
          var m = document.createElement('meta'); m.name = 'referrer'; m.content = 'same-origin'; m.setAttribute('data-bs', '1');
          (document.head || document.documentElement).appendChild(m);
        }
        add();
        if (!document.head) { new MutationObserver(function (_, o) { if (document.head) { add(); o.disconnect(); } }).observe(document, { childList: true, subtree: true }); }
      } catch (e) {}
    })();
    """
}

/// Turns a hosts file, an Adblock-style list or plain lines into domains for the custom rules. Only whole-domain rules are taken:
/// path, cosmetic and exception rules in such lists are skipped, so an imported list is never trusted with more than it can express.
enum FilterImport {
    static func domains(from text: String, limit: Int = 5000) -> (domains: [String], skipped: Int) {
        var found: [String] = [], seen = Set<String>(), skipped = 0
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("#") || line.hasPrefix("[") { continue }
            // Hosts file: "0.0.0.0 example.com" or "127.0.0.1 example.com".
            let words = line.split(separator: " ", omittingEmptySubsequences: true)
            if words.count >= 2, words[0] == "0.0.0.0" || words[0] == "127.0.0.1" { line = String(words[1]) }
            else if line.hasPrefix("||"), line.hasSuffix("^") { line = String(line.dropFirst(2).dropLast()) }
            else if line.hasPrefix("||"), line.hasSuffix("^$third-party") { line = String(line.dropFirst(2).dropLast(13)) }
            let candidate = line.lowercased()
            guard isDomain(candidate) else { skipped += 1; continue }
            if seen.insert(candidate).inserted { found.append(candidate) }
            if found.count >= limit { break }
        }
        return (found, skipped)
    }

    static func isDomain(_ s: String) -> Bool {
        guard s.count <= 253, s.contains("."), !s.hasPrefix("."), !s.hasSuffix(".") else { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." } && s.first != "-"
    }
}
