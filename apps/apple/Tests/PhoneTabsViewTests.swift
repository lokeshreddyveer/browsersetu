import XCTest
@testable import Browser_Setu

/// How the phone's tabs button opens the tabs. A choice saved by an earlier version must still read as what it was.
final class PhoneTabsViewTests: XCTestCase {
    func testSavedChoicesKeepTheirMeaning() {
        XCTAssertEqual(PhoneTabsView(rawValue: "grid"), .grid)
        XCTAssertEqual(PhoneTabsView(rawValue: "vertical"), .vertical, "the old vertical list is the floating list and keeps its saved name")
        XCTAssertEqual(PhoneTabsView(rawValue: "sidebar"), .sidebar)
        XCTAssertNil(PhoneTabsView(rawValue: "nonsense"))
    }

    func testTheThreeChoicesAreNamedForWhatTheyAre() {
        XCTAssertEqual(PhoneTabsView.allCases.map(\.title), ["Grid of pages", "Floating tabs", "Vertical tabs"])
        XCTAssertEqual(Set(PhoneTabsView.allCases.map(\.title)).count, 3)
    }
}
