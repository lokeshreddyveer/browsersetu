import XCTest
@testable import Browser_Setu

final class SecurityEventsTests: XCTestCase {
    func testSiteIsTheLastTwoLabels() {
        XCTAssertEqual(RedirectWatch.site(of: "a.b.Example.com"), "example.com")
        XCTAssertEqual(RedirectWatch.site(of: "example.com"), "example.com")
        XCTAssertEqual(RedirectWatch.site(of: "localhost"), "localhost")
    }

    func testAChainThroughFourSitesAlertsOnceAndResets() {
        var watch = RedirectWatch()
        XCTAssertNil(watch.hop(to: "one.com"))
        XCTAssertNil(watch.hop(to: "www.one.com"), "the same site again is not a new hop")
        XCTAssertNil(watch.hop(to: "two.com"))
        XCTAssertNil(watch.hop(to: "three.com"))
        XCTAssertEqual(watch.hop(to: "four.com"), ["one.com", "two.com", "three.com", "four.com"])
        XCTAssertNil(watch.hop(to: "five.com"), "only once per chain")
        watch.reset()
        XCTAssertNil(watch.hop(to: "one.com"))
    }

    func testNilAndEmptyHostsAreIgnored() {
        var watch = RedirectWatch()
        XCTAssertNil(watch.hop(to: nil))
        XCTAssertNil(watch.hop(to: ""))
    }

    func testExtensionWarningsNameTheRealRisks() {
        let broad = ExtensionRisk.warnings(for: ["Read and change cookies", "<all_urls>", "Read your browsing history"])
        XCTAssertEqual(broad.count, 3)
        XCTAssertTrue(broad[0].contains("every website"))
        XCTAssertTrue(ExtensionRisk.warnings(for: ["Save its own settings", "example.com"]).isEmpty)
        XCTAssertFalse(ExtensionRisk.warnings(for: ["Talk to Apple's own helper apps on this Mac"]).isEmpty)
    }
}
