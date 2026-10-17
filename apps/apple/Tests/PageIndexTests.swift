import XCTest
@testable import Browser_Setu

final class PageIndexTests: XCTestCase {
    private func index() throws -> PageIndex {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bs-index-" + UUID().uuidString)
        return try XCTUnwrap(PageIndex(folder: folder))
    }

    func testFindsWordsInsideAPageAndRanksTitleMatchesFirst() throws {
        let i = try index()
        i.upsert(url: "https://a.test/1", title: "Gardening basics", host: "a.test", body: "How to grow tomatoes in a small garden with compost.")
        i.upsert(url: "https://b.test/2", title: "Cooking", host: "b.test", body: "A tomato sauce recipe. Gardening is mentioned once.")
        let hits = i.searchAfterWrites("garden")
        XCTAssertEqual(hits.first?.url, "https://a.test/1")
        XCTAssertEqual(hits.count, 2)
        XCTAssertTrue(i.searchAfterWrites("tomat").contains { $0.url == "https://b.test/2" }, "a word prefix matches")
        XCTAssertTrue(i.searchAfterWrites("zebra").isEmpty)
    }

    func testReplacingAPageKeepsOneCopyAndForgettingRemovesIt() throws {
        let i = try index()
        i.upsert(url: "https://a.test/1", title: "T", host: "a.test", body: "first version about apples")
        i.upsert(url: "https://a.test/1", title: "T", host: "a.test", body: "second version about pears")
        XCTAssertEqual(i.count, 1)
        XCTAssertTrue(i.searchAfterWrites("apples").isEmpty)
        XCTAssertEqual(i.searchAfterWrites("pears").count, 1)
        i.remove(url: "https://a.test/1")
        XCTAssertEqual(i.count, 0)
    }

    func testHostRemovalAndEraseAll() throws {
        let i = try index()
        i.upsert(url: "https://a.test/1", title: "A", host: "a.test", body: "alpha text")
        i.upsert(url: "https://b.test/1", title: "B", host: "b.test", body: "beta text")
        i.removeHost("a.test")
        XCTAssertEqual(i.count, 1)
        i.removeAll()
        XCTAssertEqual(i.count, 0)
        XCTAssertTrue(i.searchAfterWrites("beta").isEmpty)
    }

    func testPruneDropsOldAndKeepsTheNewestWithinTheLimit() throws {
        let i = try index()
        let now = Date()
        i.upsert(url: "https://a.test/old", title: "Old", host: "a.test", body: "ancient words", visited: now.addingTimeInterval(-200 * 86400))
        for n in 0..<5 { i.upsert(url: "https://a.test/\(n)", title: "N\(n)", host: "a.test", body: "recent words \(n)", visited: now.addingTimeInterval(Double(-n) * 60)) }
        i.prune(olderThan: 90, maxPages: 3, now: now)
        XCTAssertEqual(i.count, 3)
        XCTAssertTrue(i.searchAfterWrites("ancient").isEmpty)
        XCTAssertEqual(Set(i.searchAfterWrites("recent").map(\.url)), ["https://a.test/0", "https://a.test/1", "https://a.test/2"])
    }

    func testQueriesCannotInjectSearchSyntax() throws {
        let i = try index()
        i.upsert(url: "https://a.test/1", title: "T", host: "a.test", body: "plain words here")
        XCTAssertNil(PageIndex.matchQuery("   "))
        XCTAssertNil(PageIndex.matchQuery("\" * ( )"))
        XCTAssertEqual(PageIndex.matchQuery("Plain  \"words\" OR x*"), "\"plain\"* \"words\"* \"or\"* \"x\"*")
        XCTAssertNoThrow(i.searchAfterWrites("NEAR(a b) \" -- ; DROP"))
    }

    func testOnlyOrdinaryHTTPSPagesAreEverCopied() {
        XCTAssertTrue(PageIndexRules.shouldIndex(URL(string: "https://news.test/story/42")!, excludedHosts: []))
        XCTAssertFalse(PageIndexRules.shouldIndex(URL(string: "http://news.test/story")!, excludedHosts: []))
        XCTAssertFalse(PageIndexRules.shouldIndex(URL(string: "https://bank.test/home")!, excludedHosts: []))
        XCTAssertFalse(PageIndexRules.shouldIndex(URL(string: "https://shop.test/checkout/step2")!, excludedHosts: []))
        XCTAssertFalse(PageIndexRules.shouldIndex(URL(string: "https://site.test/login")!, excludedHosts: []))
        XCTAssertFalse(PageIndexRules.shouldIndex(URL(string: "https://sub.skip.test/a")!, excludedHosts: ["skip.test"]))
        XCTAssertFalse(PageIndexRules.shouldIndex(URL(string: "file:///etc/hosts")!, excludedHosts: []))
    }
}
