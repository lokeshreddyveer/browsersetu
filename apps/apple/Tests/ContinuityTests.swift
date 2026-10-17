import XCTest
import CoreSpotlight
@testable import Browser_Setu

final class ContinuityTests: XCTestCase {
    func testOnlyPublicWebPagesInNormalTabsAreHandedOffAndTrackingIsRemoved() {
        XCTAssertNil(Continuity.handoffURL(isPrivate: true, isBlank: false, url: URL(string: "https://a.test")))
        XCTAssertNil(Continuity.handoffURL(isPrivate: false, isBlank: true, url: URL(string: "https://a.test")))
        XCTAssertNil(Continuity.handoffURL(isPrivate: false, isBlank: false, url: URL(string: "file:///etc/passwd")))
        XCTAssertNil(Continuity.handoffURL(isPrivate: false, isBlank: false, url: nil))
        XCTAssertEqual(Continuity.handoffURL(isPrivate: false, isBlank: false, url: URL(string: "https://a.test/x?utm_source=n&id=3"))?.absoluteString, "https://a.test/x?id=3")
    }

    func testBookmarksBecomeSearchableOnlyWhenTheyAreWebAddresses() {
        let item = Continuity.searchableItem(url: "https://example.com/page", title: "Example")
        XCTAssertEqual(item?.uniqueIdentifier, "https://example.com/page")
        XCTAssertEqual(item?.domainIdentifier, "bookmarks")
        XCTAssertEqual(item?.attributeSet.title, "Example")
        XCTAssertEqual(Continuity.searchableItem(url: "https://example.com", title: "")?.attributeSet.title, "example.com")
        XCTAssertNil(Continuity.searchableItem(url: "javascript:alert(1)", title: "x"))
        XCTAssertNil(Continuity.searchableItem(url: "file:///etc", title: "x"))
    }
}
