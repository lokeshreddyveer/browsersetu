import XCTest
@testable import Browser_Setu

final class PageMemoryTests: XCTestCase {
    func testKeyIgnoresFragmentAndTracking() {
        let a = PageMemoryKey.key(for: URL(string: "https://a.test/post?id=3&utm_source=x#comments")!)
        let b = PageMemoryKey.key(for: URL(string: "https://a.test/post?id=3")!)
        XCTAssertEqual(a, b)
        XCTAssertNil(PageMemoryKey.key(for: URL(string: "file:///tmp/x.html")!))
    }

    func testOnlyMidArticlePositionsAreWorthKeeping() {
        XCTAssertFalse(PageMemoryRules.worthRemembering(0.01))
        XCTAssertTrue(PageMemoryRules.worthRemembering(0.5))
        XCTAssertFalse(PageMemoryRules.worthRemembering(0.99))
    }

    func testSensitiveFieldsAreNeverKept() {
        XCTAssertTrue(PageMemoryRules.isSensitive(name: "user_password", type: "text", autocomplete: ""))
        XCTAssertTrue(PageMemoryRules.isSensitive(name: "x", type: "email", autocomplete: ""))
        XCTAssertTrue(PageMemoryRules.isSensitive(name: "x", type: "text", autocomplete: "cc-number"))
        XCTAssertTrue(PageMemoryRules.isSensitive(name: "otp", type: "text", autocomplete: ""))
        XCTAssertFalse(PageMemoryRules.isSensitive(name: "comment", type: "textarea", autocomplete: ""))
    }

    func testPruneKeepsNewest() {
        var map: [String: ReadingPosition] = [:]
        for i in 0..<(PageMemoryRules.maxEntries + 20) { map["k\(i)"] = ReadingPosition(fraction: 0.5, date: Date(timeIntervalSince1970: Double(i))) }
        let pruned = PageMemoryRules.prune(map) { $0.date }
        XCTAssertEqual(pruned.count, PageMemoryRules.maxEntries)
        XCTAssertNil(pruned["k0"])
        XCTAssertNotNil(pruned["k\(PageMemoryRules.maxEntries + 19)"])
    }
}
