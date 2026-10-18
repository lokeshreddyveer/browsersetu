import XCTest
@testable import Browser_Setu

final class URLCompletionTests: XCTestCase {
    private let sites = ["github.com", "www.gmail.com", "news.ycombinator.com", "gitlab.com"]

    func testTheMostVisitedSiteThatStartsWithWhatWasTypedWins() {
        XCTAssertEqual(URLCompletion.complete("git", sites: sites), "github.com")
        XCTAssertEqual(URLCompletion.complete("gm", sites: sites), "gmail.com", "www. is left off")
        XCTAssertEqual(URLCompletion.complete("GIT", sites: sites), "github.com")
    }

    func testOnlyTheStartOfASiteCounts() {
        XCTAssertNil(URLCompletion.complete("hub", sites: sites), "the middle of a name is not a start")
        XCTAssertNil(URLCompletion.complete("ycom", sites: sites))
    }

    func testNothingIsCompletedOnceItLooksLikeASearchOrAFullAddress() {
        XCTAssertNil(URLCompletion.complete("git hub", sites: sites))
        XCTAssertNil(URLCompletion.complete("github.com/lo", sites: sites))
        XCTAssertNil(URLCompletion.complete("https://git", sites: sites))
        XCTAssertNil(URLCompletion.complete("", sites: sites))
        XCTAssertNil(URLCompletion.complete("github.com", sites: sites), "already complete")
    }

    func testSitesAreRankedByVisitsWithBookmarksCountingToo() {
        let ranked = URLCompletion.sites(history: [("https://a.com/x", 2), ("https://b.com/", 9), ("https://a.com/y", 3)], bookmarks: ["https://c.com/"])
        XCTAssertEqual(ranked, ["b.com", "a.com", "c.com"])
    }

    func testASearchInsideASiteIsBuiltForAnyEngine() {
        XCTAssertEqual(URLCompletion.siteQuery(host: "www.example.com", query: "  pricing  "), "site:example.com pricing")
        XCTAssertEqual(URLCompletion.siteQuery(host: "docs.example.com", query: "api"), "site:docs.example.com api")
    }
}
