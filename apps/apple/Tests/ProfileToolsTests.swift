import XCTest
@testable import Browser_Setu

final class ProfileToolsTests: XCTestCase {
    func testSiteKeyDropsWWWAndCase() {
        XCTAssertEqual(ProfileRegistry.siteKey("WWW.Example.com"), "example.com")
        XCTAssertNil(ProfileRegistry.siteKey(nil))
        XCTAssertNil(ProfileRegistry.siteKey(""))
    }

    func testPreferredProfileMatchesTheSiteAndItsSubdomainsOnly() {
        let sites = ["example.com": "Work", "docs.other.org": "Testing"]
        XCTAssertEqual(ProfileRegistry.preferred(forHost: "example.com", in: sites), "Work")
        XCTAssertEqual(ProfileRegistry.preferred(forHost: "www.example.com", in: sites), "Work")
        XCTAssertEqual(ProfileRegistry.preferred(forHost: "mail.eu.example.com", in: sites), "Work")
        XCTAssertNil(ProfileRegistry.preferred(forHost: "notexample.com", in: sites))
        XCTAssertEqual(ProfileRegistry.preferred(forHost: "docs.other.org", in: sites), "Testing")
        XCTAssertNil(ProfileRegistry.preferred(forHost: "other.org", in: sites), "a parent is not covered by a subdomain's rule")
    }

    func testTemporaryNamesAreValidProfileNames() {
        let name = ProfileRegistry.temporaryName()
        XCTAssertTrue(name.hasPrefix("Temporary-"))
        XCTAssertLessThanOrEqual(name.count, 32)
        XCTAssertTrue(name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }

    func testStyleRoundTripsAndKnowsItsColour() throws {
        let style = ProfileStyle(symbol: "briefcase", color: "blue")
        let back = try JSONDecoder().decode(ProfileStyle.self, from: JSONEncoder().encode(style))
        XCTAssertEqual(back, style)
        XCTAssertNotNil(style.tint)
        XCTAssertNil(ProfileStyle(symbol: "house", color: nil).tint)
        XCTAssertNil(ProfileStyle(symbol: "house", color: "nonsense").tint)
    }

    func testEachProfileGetsItsOwnDataStoreID() {
        XCTAssertNotEqual(ProfileIdentity.dataStoreID(for: "Work"), ProfileIdentity.dataStoreID(for: "Personal"))
        XCTAssertEqual(ProfileIdentity.dataStoreID(for: "Work"), ProfileIdentity.dataStoreID(for: "Work"))
    }
}
