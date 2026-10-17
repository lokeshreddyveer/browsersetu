import Foundation

/// One tab that contains the words searched for.
struct TabTextHit: Identifiable, Equatable {
    var id: UInt64 { tabID }
    var tabID: UInt64
    var title: String
    var host: String
    var snippet: String
    /// The tab's page is not loaded: it was found in the searchable copy kept for pages you read, not in the page itself.
    var asleep: Bool
    /// The words as the page spells them (a close match differs from what was typed); this is what the page is searched for after switching to it.
    var found = ""
    /// The words were not found exactly as typed.
    var close = false
}

extension BrowserModel {
    /// Searches the text of every open tab of the same kind as the one in front (normal or private). A loaded page is read directly; a tab that is asleep is looked up in the
    /// searchable copy of pages (when that is on), so it can be found without waking it.
    func searchTabText(_ text: String, limit: Int = 30) async -> [TabTextHit] {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard word.count >= 2 else { return [] }
        var hits: [TabTextHit] = []
        var grades: [UInt64: FuzzyText.Grade] = [:]
        let privateNow = activeIsPrivate
        let indexed: [String: PageHit] = (indexPages && !privateNow) ? Dictionary((pageIndex?.search(word, limit: 100) ?? []).map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first }) : [:]
        for tab in tabs where tab.isPrivate == privateNow && !tab.isBlank {
            if Task.isCancelled { return hits }
            let host = displayHost(tab.url)
            if tab.hasLoadedPage, !tab.isDiscarded {
                guard let page = await tab.engine.pageText() else { continue }
                // Worked out off the main thread: a long page has tens of thousands of words to compare.
                let found = await Task.detached(priority: .userInitiated) { FuzzyText.match(word, in: page).map { ($0.grade, TextSnippet.make(in: page, range: $0.range), $0.found) } }.value
                if let found {
                    grades[tab.id] = found.0
                    hits.append(TabTextHit(tabID: tab.id, title: tab.displayTitle, host: host, snippet: found.1, asleep: false, found: found.2, close: found.0 == .close))
                } else if FuzzyText.matches(word, in: tab.displayTitle) {
                    grades[tab.id] = .words
                    hits.append(TabTextHit(tabID: tab.id, title: tab.displayTitle, host: host, snippet: "In the title", asleep: false, found: word))
                }
            } else if let address = tab.url?.absoluteString, let stored = indexed.first(where: { $0.key == address || PageMemoryKey.key(for: URL(string: $0.key) ?? URL(fileURLWithPath: "/")) == PageMemoryKey.key(for: tab.url ?? URL(fileURLWithPath: "/")) })?.value {
                hits.append(TabTextHit(tabID: tab.id, title: tab.displayTitle, host: host, snippet: stored.snippet, asleep: true))
            } else if TabMatch.matches(title: tab.displayTitle, url: tab.url?.absoluteString ?? "", words: word) {
                grades[tab.id] = .words
                hits.append(TabTextHit(tabID: tab.id, title: tab.displayTitle, host: host, snippet: "In the title or address (the page is asleep)", asleep: true, found: word))
            }
            if hits.count >= limit { break }
        }
        // Exact matches first, then words found apart, then close spellings; tabs keep their order inside each group.
        return hits.enumerated().sorted { a, b in
            let ga = grades[a.element.tabID] ?? .words, gb = grades[b.element.tabID] ?? .words
            return ga != gb ? ga < gb : a.offset < b.offset
        }.map(\.element)
    }
}
