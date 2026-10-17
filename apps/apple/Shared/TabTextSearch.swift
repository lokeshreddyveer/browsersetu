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
}

extension BrowserModel {
    /// Searches the text of every open tab of the same kind as the one in front (normal or private). A loaded page is read directly; a tab that is asleep is looked up in the
    /// searchable copy of pages (when that is on), so it can be found without waking it.
    func searchTabText(_ text: String, limit: Int = 30) async -> [TabTextHit] {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard word.count >= 2 else { return [] }
        var hits: [TabTextHit] = []
        let privateNow = activeIsPrivate
        let indexed: [String: PageHit] = (indexPages && !privateNow) ? Dictionary((pageIndex?.search(word, limit: 100) ?? []).map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first }) : [:]
        for tab in tabs where tab.isPrivate == privateNow && !tab.isBlank {
            if Task.isCancelled { return hits }
            let host = displayHost(tab.url)
            if tab.hasLoadedPage, !tab.isDiscarded {
                guard let page = await tab.engine.pageText() else { continue }
                if let snippet = TextSnippet.make(in: page, around: word) {
                    hits.append(TabTextHit(tabID: tab.id, title: tab.displayTitle, host: host, snippet: snippet, asleep: false))
                } else if tab.displayTitle.localizedCaseInsensitiveContains(word) {
                    hits.append(TabTextHit(tabID: tab.id, title: tab.displayTitle, host: host, snippet: "In the title", asleep: false))
                }
            } else if let address = tab.url?.absoluteString, let stored = indexed.first(where: { $0.key == address || PageMemoryKey.key(for: URL(string: $0.key) ?? URL(fileURLWithPath: "/")) == PageMemoryKey.key(for: tab.url ?? URL(fileURLWithPath: "/")) })?.value {
                hits.append(TabTextHit(tabID: tab.id, title: tab.displayTitle, host: host, snippet: stored.snippet, asleep: true))
            } else if tab.displayTitle.localizedCaseInsensitiveContains(word) || (tab.url?.absoluteString.localizedCaseInsensitiveContains(word) ?? false) {
                hits.append(TabTextHit(tabID: tab.id, title: tab.displayTitle, host: host, snippet: "In the title or address (the page is asleep)", asleep: true))
            }
            if hits.count >= limit { break }
        }
        return hits
    }
}
