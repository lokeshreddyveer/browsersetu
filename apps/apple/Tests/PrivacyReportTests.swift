import XCTest
@testable import Browser_Setu

final class PrivacyReportTests: XCTestCase {
    func testBlockedRequestsGroupByHostMostFirst() {
        let report = PageNetworkReport(blockedURLs: ["https://ads.example.net/a.js", "https://ads.example.net/b.js", "https://px.tracker.io/p.gif"], thirdPartyHosts: [])
        XCTAssertEqual(report.blockedByHost.map(\.host), ["ads.example.net", "px.tracker.io"])
        XCTAssertEqual(report.blockedByHost.map(\.count), [2, 1])
    }

    func testKindsAreGuessedFromNames() {
        XCTAssertEqual(BlockedClassifier.kind(ofHost: "securepubads.g.doubleclick.net"), .ad)
        XCTAssertEqual(BlockedClassifier.kind(ofHost: "www.google-analytics.com"), .tracker)
        XCTAssertEqual(BlockedClassifier.kind(ofHost: "cdn.example.com"), .other)
        let report = PageNetworkReport(blockedURLs: ["https://x.doubleclick.net/1", "https://x.doubleclick.net/2", "https://www.google-analytics.com/c", "https://cdn.example.com/z"])
        XCTAssertEqual(report.kinds.ads, 2)
        XCTAssertEqual(report.kinds.trackers, 1)
        XCTAssertEqual(report.kinds.other, 1)
    }

    func testImportReadsHostsFilesAdblockLinesAndPlainDomains() {
        let text = """
        ! comment
        # another
        [Adblock Plus 2.0]
        0.0.0.0 ads.one.com
        127.0.0.1 track.two.com
        ||three.com^
        ||four.com^$third-party
        five.com
        ||six.com/path/ads.js
        @@||allowed.com^
        ##.banner
        ads.one.com
        """
        let result = FilterImport.domains(from: text)
        XCTAssertEqual(result.domains, ["ads.one.com", "track.two.com", "three.com", "four.com", "five.com"])
        XCTAssertEqual(result.skipped, 2, "the path rule and the exception rule; ## lines count as comments")
    }

    func testImportRefusesBadNamesAndHonoursTheLimit() {
        XCTAssertFalse(FilterImport.isDomain("-bad.com"))
        XCTAssertFalse(FilterImport.isDomain("nodot"))
        XCTAssertFalse(FilterImport.isDomain("a b.com"))
        let many = (0..<50).map { "d\($0).com" }.joined(separator: "\n")
        XCTAssertEqual(FilterImport.domains(from: many, limit: 10).domains.count, 10)
    }

    func testReferrerModes() {
        XCTAssertEqual(ReferrerMode.allCases.count, 2)
        XCTAssertTrue(ReferrerMode.script.contains("same-origin"))
    }
}
