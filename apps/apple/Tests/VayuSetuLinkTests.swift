import XCTest
@testable import Browser_Setu

final class VayuSetuLinkTests: XCTestCase {
    func testTheLinksAreSecureAndPointAtTheAuthorsOwnPages() {
        XCTAssertEqual(VayuSetuLink.downloadPage.scheme, "https")
        XCTAssertEqual(VayuSetuLink.downloadPage.host, "github.com")
        XCTAssertTrue(VayuSetuLink.downloadPage.path.hasPrefix("/lokeshreddyveer/vayusetu"))
        XCTAssertEqual(VayuSetuLink.website.scheme, "https")
        XCTAssertEqual(VayuSetuLink.website.host, "lokeshreddyveer.github.io")
        XCTAssertEqual(VayuSetuLink.macBundleID, "app.vayusetu.macos")
    }
}
