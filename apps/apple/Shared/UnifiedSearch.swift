import Foundation

/// One thing the browser knows about, from any source.
struct SearchEntry: Identifiable, Equatable {
    enum Kind: String, CaseIterable { case tab, bookmark, history, download, reading, closed, session, research, note, command
        var title: String {
            switch self { case .tab: "Open tabs"; case .bookmark: "Bookmarks"; case .history: "History"; case .download: "Downloads"
                case .reading: "Reading list"; case .closed: "Recently closed"; case .session: "Saved sessions"
                case .research: "Research"; case .note: "Notes"; case .command: "Commands" }
        }
        var symbol: String {
            switch self { case .tab: "square.on.square"; case .bookmark: "star"; case .history: "clock"; case .download: "arrow.down.circle"
                case .reading: "book"; case .closed: "arrow.uturn.backward"; case .session: "rectangle.stack"
                case .research: "books.vertical"; case .note: "note.text"; case .command: "command" }
        }
        /// A tab you already have open is worth more than the same page in history.
        var weight: Double {
            switch self { case .tab: 30; case .command: 24; case .bookmark: 20; case .reading: 18; case .session: 17; case .research: 16; case .closed: 12; case .note: 14; case .download: 10; case .history: 0 }
        }
    }
    var kind: Kind
    var title: String
    var detail: String
    var url: String?
    var key: String
    var id: String { kind.rawValue + "|" + key }
}

enum UnifiedSearch {
    /// Words that all have to appear, in the title or the address; earlier and whole-word matches rank higher.
    static func score(_ entry: SearchEntry, terms: [String]) -> Double? {
        guard !terms.isEmpty else { return nil }
        let title = entry.title.lowercased(), detail = entry.detail.lowercased(), url = (entry.url ?? "").lowercased()
        var total = entry.kind.weight
        for term in terms {
            if let r = title.range(of: term) {
                total += 40
                if r.lowerBound == title.startIndex { total += 20 }
                else if title[title.index(before: r.lowerBound)] == " " { total += 10 }
            } else if url.contains(term) { total += 18 }
            else if detail.contains(term) { total += 8 }
            else { return nil }
        }
        return total
    }

    static func terms(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Best matches first, the same page from two sources shown once (the stronger source wins), capped per kind so one source cannot fill the list.
    static func search(_ query: String, in entries: [SearchEntry], limit: Int = 40, perKind: Int = 12) -> [SearchEntry] {
        let words = terms(query)
        let scored = entries.compactMap { e in score(e, terms: words).map { (e, $0) } }.sorted { $0.1 > $1.1 }
        var seen = Set<String>(), counts: [SearchEntry.Kind: Int] = [:], out: [SearchEntry] = []
        for (entry, _) in scored {
            if let url = entry.url, entry.kind != .tab { guard seen.insert(url).inserted else { continue } }
            else if let url = entry.url { seen.insert(url) }
            guard counts[entry.kind, default: 0] < perKind else { continue }
            counts[entry.kind, default: 0] += 1
            out.append(entry)
            if out.count >= limit { break }
        }
        return out
    }
}
