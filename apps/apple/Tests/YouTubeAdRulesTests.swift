import XCTest
@testable import Browser_Setu

final class YouTubeAdRulesTests: XCTestCase {
    private func encode(_ rules: YouTubeAdRules) throws -> Data { try JSONEncoder().encode(rules) }

    func testBuiltInRulesAreAcceptable() throws {
        XCTAssertNotNil(YouTubeAdRules.validated(try encode(.builtIn)))
    }

    func testASelectorThatCouldStartAnotherRuleIsRefused() throws {
        var bad = YouTubeAdRules.builtIn
        bad.hideSelectors.append("body{background:url(https://x.test/a)}")
        XCTAssertNil(YouTubeAdRules.validated(try encode(bad)))
    }

    func testAFieldNameThatIsNotAPlainNameIsRefused() throws {
        var bad = YouTubeAdRules.builtIn
        bad.stripKeys.append("a-b;alert(1)")
        XCTAssertNil(YouTubeAdRules.validated(try encode(bad)))
    }

    func testOversizedAndEmptyFilesAreRefused() throws {
        var empty = YouTubeAdRules.builtIn
        empty.stripKeys = []
        XCTAssertNil(YouTubeAdRules.validated(try encode(empty)))
        XCTAssertNil(YouTubeAdRules.validated(Data(count: YouTubeAdRules.maxBytes + 1)))
    }

    func testTheScriptCarriesTheRulesAsData() {
        let script = YouTubeAdRules.builtIn.script
        XCTAssertTrue(script.contains("\"adPlacements\""))
        XCTAssertTrue(script.contains("ytInitialPlayerResponse"))
    }
}
