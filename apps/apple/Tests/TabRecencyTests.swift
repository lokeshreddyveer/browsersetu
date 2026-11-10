import XCTest
@testable import Browser_Setu

/// Control-Tab: a walk back through the tabs in the order they were used.
final class TabRecencyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func used(_ ids: [UInt64]) -> TabRecency {
        var r = TabRecency(); for id in ids { r.noteSelected(id) }; return r
    }

    func testOnePressGoesToTheTabUsedJustBefore() {
        var r = used([1, 2, 3])                       // 3 is in front, 2 before it, then 1
        XCTAssertEqual(r.step(1, current: 3, available: [1, 2, 3], now: t0), 2)
    }

    func testPressesCloseTogetherWalkFurtherBackAndForwardAgain() {
        var r = used([1, 2, 3, 4])                    // order: 4, 3, 2, 1
        XCTAssertEqual(r.step(1, current: 4, available: [1, 2, 3, 4], now: t0), 3)
        XCTAssertEqual(r.step(1, current: 3, available: [1, 2, 3, 4], now: t0.addingTimeInterval(0.4)), 2)
        XCTAssertEqual(r.step(1, current: 2, available: [1, 2, 3, 4], now: t0.addingTimeInterval(0.8)), 1)
        XCTAssertEqual(r.step(1, current: 1, available: [1, 2, 3, 4], now: t0.addingTimeInterval(1.2)), 4, "it wraps to where it began")
        XCTAssertEqual(r.step(-1, current: 4, available: [1, 2, 3, 4], now: t0.addingTimeInterval(1.6)), 1, "and Shift goes forward again")
    }

    func testAPauseStartsANewWalkFromWhereYouAre() {
        var r = used([1, 2, 3])
        XCTAssertEqual(r.step(1, current: 3, available: [1, 2, 3], now: t0), 2)
        r.endWalk(on: 2)                              // the walk ended on 2: now 2, 3, 1
        XCTAssertEqual(r.order, [2, 3, 1])
        XCTAssertEqual(r.step(1, current: 2, available: [1, 2, 3], now: t0.addingTimeInterval(10)), 3)
    }

    func testTabsPassedOnTheWayDoNotReshuffleTheOrder() {
        var r = used([1, 2, 3, 4])                    // 4, 3, 2, 1
        _ = r.step(1, current: 4, available: [1, 2, 3, 4], now: t0)                                // to 3
        _ = r.step(1, current: 3, available: [1, 2, 3, 4], now: t0.addingTimeInterval(0.3))        // to 2
        XCTAssertTrue(r.isWalking)
        r.endWalk(on: 2)
        XCTAssertEqual(r.order, [2, 4, 3, 1], "2 first; the others keep the order they had")
    }

    func testChoosingATabByHandEndsTheWalk() {
        var r = used([1, 2, 3])
        _ = r.step(1, current: 3, available: [1, 2, 3], now: t0)
        r.noteSelected(1)
        XCTAssertFalse(r.isWalking)
        XCTAssertEqual(r.step(1, current: 1, available: [1, 2, 3], now: t0.addingTimeInterval(0.2)), 3)
    }

    func testOnlyTabsThatMayBeChosenAreChosen() {
        // 2 is a private tab that this window does not show: it is never stepped to.
        var r = used([1, 2, 3])
        XCTAssertEqual(r.step(1, current: 3, available: [1, 3], now: t0), 1)
    }

    func testClosedTabsAreSkippedAndTabsNeverUsedComeLast() {
        var r = used([1, 2])
        // 9 is new (never in front), 2 was closed.
        XCTAssertEqual(r.step(1, current: 1, available: [1, 9], now: t0), 9)
    }

    func testNowhereToGoGivesNil() {
        var r = used([1])
        XCTAssertNil(r.step(1, current: 1, available: [1], now: t0))
        XCTAssertNil(r.step(1, current: nil, available: [], now: t0))
    }

    func testFromAnEssentialsPageTheFirstPressGoesToTheMostRecentTab() {
        // The front tab is in no list (an Essential's page): the walk starts at the most recent listed tab.
        var r = used([1, 2])
        XCTAssertEqual(r.step(1, current: 77, available: [1, 2], now: t0), 2, "the most recent listed tab")
        var back = used([1, 2])
        XCTAssertEqual(back.step(-1, current: 77, available: [1, 2], now: t0), 1, "and Shift goes to the oldest")
    }
}

final class StripAndSnapSettingsTests: XCTestCase {
    func testTheNewShortcutsHaveDistinctUsableDefaults() {
        XCTAssertEqual(ShortcutAction.recentTab.defaultCombo.display, "⌃⇥")
        XCTAssertEqual(ShortcutAction.recentTabReverse.defaultCombo.display, "⌃⇧⇥")
        XCTAssertEqual(ShortcutAction.recentTab.group, "Tabs")
    }

    func testTheSidebarStandardWidthIsInsideTheAllowedRange() {
        XCTAssertTrue(sidebarWidthRange.contains(SidebarSnap.standard))
        XCTAssertEqual(clampedSidebarWidth(SidebarSnap.standard), SidebarSnap.standard)
    }
}
