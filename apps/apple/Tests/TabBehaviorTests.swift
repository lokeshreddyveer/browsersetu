import XCTest
@testable import Browser_Setu

final class TabBehaviorTests: XCTestCase {
    private func strip(_ items: [(UInt64, UInt64?, Bool)]) -> [TabBehavior.Entry] {
        items.map { TabBehavior.Entry(id: $0.0, opener: $0.1, pinned: $0.2) }
    }

    // MARK: where a new tab goes

    func testATabOpenedByItselfGoesToTheEnd() {
        let order = strip([(1, nil, false), (2, nil, false), (3, nil, false)])
        XCTAssertEqual(TabBehavior.insertionIndex(in: order, opener: nil, foreground: true), 3, "New Tab, a typed address, a link from another app")
        XCTAssertEqual(TabBehavior.insertionIndex(in: [], opener: nil, foreground: true), 0)
    }

    func testALinkTabOpenedInFrontSitsRightAfterItsOpener() {
        let order = strip([(1, nil, false), (2, nil, false), (3, nil, false)])
        XCTAssertEqual(TabBehavior.insertionIndex(in: order, opener: 1, foreground: true), 1)
        XCTAssertEqual(TabBehavior.insertionIndex(in: order, opener: 2, foreground: true), 2)
        XCTAssertEqual(TabBehavior.insertionIndex(in: order, opener: 3, foreground: true), 3)
    }

    func testSeveralBackgroundTabsKeepTheOrderTheyWereOpenedIn() {
        // Tab 1 opened 10 and 11 already; a third background tab goes after them, not between 1 and 10.
        let order = strip([(1, nil, false), (10, 1, false), (11, 1, false), (2, nil, false)])
        XCTAssertEqual(TabBehavior.insertionIndex(in: order, opener: 1, foreground: false), 3)
        // In front, it goes straight after the opener instead.
        XCTAssertEqual(TabBehavior.insertionIndex(in: order, opener: 1, foreground: true), 1)
        // An opener with no children yet: right after it.
        XCTAssertEqual(TabBehavior.insertionIndex(in: order, opener: 2, foreground: false), 4)
    }

    func testAnOpenerThatIsGoneMeansTheEnd() {
        let order = strip([(1, nil, false), (2, nil, false)])
        XCTAssertEqual(TabBehavior.insertionIndex(in: order, opener: 99, foreground: true), 2)
    }

    func testNothingIsInsertedAmongThePinnedTabs() {
        let order = strip([(1, nil, true), (2, nil, true), (3, nil, false), (4, nil, false)])
        // Opened from a pinned tab, the new (unpinned) tab still comes after the pinned block.
        XCTAssertEqual(TabBehavior.insertionIndex(in: order, opener: 1, foreground: true), 2)
        XCTAssertEqual(TabBehavior.insertionIndex(in: order, opener: 2, foreground: false), 2)
        XCTAssertEqual(TabBehavior.insertionIndex(in: order, opener: 3, foreground: true), 3)
        // Only pinned tabs: the end.
        XCTAssertEqual(TabBehavior.insertionIndex(in: strip([(1, nil, true)]), opener: 1, foreground: true), 1)
    }

    // MARK: which tab comes forward when one closes

    func testClosingGoesToTheTabOnTheRight() {
        let order = strip([(1, nil, false), (2, nil, false), (3, nil, false), (4, nil, false)])
        XCTAssertEqual(TabBehavior.selectionAfterClosing(2, in: order, returnTo: nil), 3)
        XCTAssertEqual(TabBehavior.selectionAfterClosing(1, in: order, returnTo: nil), 2)
    }

    func testClosingTheLastTabGoesToTheOneOnTheLeft() {
        let order = strip([(1, nil, false), (2, nil, false), (3, nil, false)])
        XCTAssertEqual(TabBehavior.selectionAfterClosing(3, in: order, returnTo: nil), 2)
    }

    func testClosingTheOnlyTabLeavesNothing() {
        XCTAssertNil(TabBehavior.selectionAfterClosing(1, in: strip([(1, nil, false)]), returnTo: nil))
        XCTAssertNil(TabBehavior.selectionAfterClosing(1, in: [], returnTo: nil))
    }

    func testATabOpenedFromAnotherGoesBackToItWhenClosedUntouched() {
        let order = strip([(1, nil, false), (2, nil, false), (3, nil, false), (9, 1, false)])
        XCTAssertEqual(TabBehavior.selectionAfterClosing(9, in: order, returnTo: 1), 1, "back to the page it was opened from, not the neighbour on the left")
        // The owner is gone: the ordinary rule.
        XCTAssertEqual(TabBehavior.selectionAfterClosing(9, in: order, returnTo: 77), 3)
        // Returning to itself is never offered.
        XCTAssertEqual(TabBehavior.selectionAfterClosing(9, in: order, returnTo: 9), 3)
    }

    func testClosingWorksOnTheStripThePersonSeesNotTheWholeList() {
        // The old code took a position in the full list and used it in the visible one. Here the strip is only what is visible.
        let visible = strip([(5, nil, false), (6, nil, false), (7, nil, false)])
        XCTAssertEqual(TabBehavior.selectionAfterClosing(6, in: visible, returnTo: nil), 7)
        // A tab that is not in the strip at all: the first one shown.
        XCTAssertEqual(TabBehavior.selectionAfterClosing(100, in: visible, returnTo: nil), 5)
    }
}
