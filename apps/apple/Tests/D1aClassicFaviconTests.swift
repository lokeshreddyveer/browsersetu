import XCTest
@testable import Browser_Setu

/// Section 24 guardrail: icons are cached by site, so a tab, a bookmark and a history row of one site share one icon and hovering never asks the network for another. Pure key logic: no singleton is
/// activated, no folder is written and nothing is fetched. WRITTEN, NOT RUN.
final class D1aClassicFaviconTests: XCTestCase {
    func testOneSiteIsOneCacheKeyWhateverThePage() {
        let a = FaviconStore.key(forURL: URL(string: "https://example.com/a?x=1"))
        let b = FaviconStore.key(forURL: URL(string: "https://example.com/other/page#frag"))
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b, "two pages of one site would load two icons")
    }

    func testDifferentSitesHaveDifferentKeys() {
        XCTAssertNotEqual(FaviconStore.key(forURL: URL(string: "https://example.com/")), FaviconStore.key(forURL: URL(string: "https://example.org/")))
    }

    func testTheKeyIsTheSameForAHostAndForAPageOnIt() {
        XCTAssertEqual(FaviconStore.key(forHost: "example.com"), FaviconStore.key(forURL: URL(string: "https://example.com/x")))
    }

    func testNoKeyMeansNoRequest() {
        XCTAssertNil(FaviconStore.key(forURL: nil))
        XCTAssertNil(FaviconStore.key(forURL: URL(string: "about:blank")), "a blank page must not ask for an icon")
        XCTAssertNil(FaviconStore.key(forHost: nil))
    }
}
