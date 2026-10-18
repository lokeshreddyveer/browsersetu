import XCTest
@testable import Browser_Setu

final class KnowledgeToolsTests: XCTestCase {
    private func b(_ url: String, _ title: String = "", created: Int64 = 0, folder: String = "") -> BookmarkItem {
        BookmarkItem(url: url, title: title, folder: folder, created: created)
    }

    func testKeyIgnoresWWWFragmentSlashAndCase() {
        let a = BookmarkTools.key("https://WWW.Example.com/page/#top")
        XCTAssertEqual(a, BookmarkTools.key("https://example.com/page"))
        XCTAssertNotEqual(BookmarkTools.key("https://example.com/a"), BookmarkTools.key("https://example.com/b"))
        XCTAssertNotEqual(BookmarkTools.key("https://example.com/?q=1"), BookmarkTools.key("https://example.com/?q=2"))
        XCTAssertEqual(BookmarkTools.key("https://example.com/"), BookmarkTools.key("https://example.com"))
    }

    func testDuplicatesGroupOldestFirst() {
        let items = [b("https://example.com/a/", "A2", created: 20), b("https://www.example.com/a", "A1", created: 10), b("https://other.com", "O", created: 5)]
        let groups = BookmarkTools.duplicates(items)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].map(\.title), ["A1", "A2"])
    }

    func testSmartCollections() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let day = Int64(86_400)
        let t = Int64(now.timeIntervalSince1970)
        let items = [b("https://a.com/1", "new", created: t - day), b("https://a.com/2", "mid", created: t - 10 * day), b("https://a.com/3", "old", created: t - 90 * day), b("https://x.org", "x", created: t - 200 * day)]
        let tags = ["https://a.com/1": ["work"], "https://x.org": ["work", "read"]]
        let c = BookmarkTools.smartCollections(items, tags: tags, now: now)
        func ids() -> [String] { c.map(\.id) }
        XCTAssertTrue(ids().contains("week"))
        XCTAssertEqual(c.first { $0.id == "week" }?.items.map(\.title), ["new"])
        XCTAssertEqual(c.first { $0.id == "month" }?.items.count, 2)
        XCTAssertEqual(c.first { $0.id == "tag-work" }?.items.count, 2)
        XCTAssertEqual(c.first { $0.id == "untagged" }?.items.count, 2)
        XCTAssertEqual(c.first { $0.id == "site-a.com" }?.items.count, 3)
        XCTAssertNil(c.first { $0.id == "site-x.org" }, "a site needs three bookmarks")
    }

    func testLinkClassification() {
        XCTAssertEqual(LinkChecker.classify(status: 200, error: nil), .ok)
        XCTAssertEqual(LinkChecker.classify(status: 301, error: nil), .ok)
        if case .broken = LinkChecker.classify(status: 404, error: nil) {} else { XCTFail("404 is broken") }
        if case .broken = LinkChecker.classify(status: 410, error: nil) {} else { XCTFail("410 is broken") }
        if case .unsure = LinkChecker.classify(status: 403, error: nil) {} else { XCTFail("403 is only unsure") }
        if case .unsure = LinkChecker.classify(status: 503, error: nil) {} else { XCTFail("5xx is only unsure") }
        if case .broken = LinkChecker.classify(status: nil, error: .cannotFindHost) {} else { XCTFail("no such host is broken") }
        if case .unsure = LinkChecker.classify(status: nil, error: .timedOut) {} else { XCTFail("a timeout is unsure") }
        if case .unsure = LinkChecker.classify(status: nil, error: .notConnectedToInternet) {} else { XCTFail("offline is unsure, never broken") }
    }

    func testRetentionPicksOnlyOldEntries() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let t = Int64(now.timeIntervalSince1970)
        let items = [HistoryItem(url: "https://new.com", title: "", lastVisit: t - 86_400, visitCount: 1), HistoryItem(url: "https://old.com", title: "", lastVisit: t - 40 * 86_400, visitCount: 3)]
        XCTAssertEqual(HistoryRetention.expired(items, days: 30, now: now), ["https://old.com"])
        XCTAssertTrue(HistoryRetention.expired(items, days: 0, now: now).isEmpty, "0 keeps everything")
        XCTAssertEqual(HistoryRetention.title(0), "Forever")
        XCTAssertEqual(HistoryRetention.title(365), "1 year")
    }

    func testUniversalSearchLabelsEverySourceAndFindsNewOnes() {
        let entries = [SearchEntry(kind: .reading, title: "Bees in autumn", detail: "bees.org", url: "https://bees.org/a", key: "1"),
                       SearchEntry(kind: .closed, title: "Bee supplies", detail: "shop.com", url: "https://shop.com", key: "2"),
                       SearchEntry(kind: .session, title: "Garden research", detail: "3 tabs · Bees", url: nil, key: "3")]
        let found = UnifiedSearch.search("bee", in: entries)
        XCTAssertEqual(Set(found.map(\.kind)), [.reading, .closed, .session])
        XCTAssertEqual(SearchEntry.Kind.reading.title, "Reading list")
        XCTAssertEqual(SearchEntry.Kind.closed.title, "Recently closed")
        XCTAssertEqual(SearchEntry.Kind.allCases.count, Set(SearchEntry.Kind.allCases.map(\.title)).count, "every source has its own label")
    }
}
