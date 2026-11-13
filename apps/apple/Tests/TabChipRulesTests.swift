import XCTest
@testable import Browser_Setu

/// The decisions behind the Mac tab chips (D1a-A): locked tabs, arrow-key movement, what a screen reader is told, and when a delayed hover preview may still appear.
final class TabChipRulesTests: XCTestCase {
    func testLockedTabNeverOffersClose() {
        XCTAssertFalse(TabChipRules.showsCloseButton(locked: true, selected: true, hovering: true))
        XCTAssertTrue(TabChipRules.showsCloseButton(locked: false, selected: true, hovering: false), "an unlocked selected tab shows Close")
        XCTAssertTrue(TabChipRules.showsCloseButton(locked: false, selected: false, hovering: true), "an unlocked hovered tab shows Close")
        XCTAssertFalse(TabChipRules.showsCloseButton(locked: false, selected: false, hovering: false))
    }

    func testArrowKeysMoveWithoutWrapping() {
        let ids: [UInt64] = [4, 7, 9, 12]
        XCTAssertEqual(TabChipRules.neighbor(of: 7, in: ids, .next), 9)
        XCTAssertEqual(TabChipRules.neighbor(of: 7, in: ids, .previous), 4)
        XCTAssertNil(TabChipRules.neighbor(of: 4, in: ids, .previous), "no wrap at the start")
        XCTAssertNil(TabChipRules.neighbor(of: 12, in: ids, .next), "no wrap at the end")
        XCTAssertEqual(TabChipRules.neighbor(of: 9, in: ids, .first), 4)
        XCTAssertEqual(TabChipRules.neighbor(of: 9, in: ids, .last), 12)
        XCTAssertNil(TabChipRules.neighbor(of: 4, in: ids, .first), "already there")
        XCTAssertNil(TabChipRules.neighbor(of: 99, in: ids, .next), "a tab that is not in the strip")
        XCTAssertNil(TabChipRules.neighbor(of: 1, in: [1], .next))
    }

    func testSpokenState() {
        XCTAssertNil(TabChipRules.spokenState(locked: false, pinned: false, playing: false, muted: false))
        XCTAssertEqual(TabChipRules.spokenState(locked: true, pinned: false, playing: false, muted: false), "Locked")
        XCTAssertEqual(TabChipRules.spokenState(locked: true, pinned: true, playing: true, muted: false), "Pinned, Locked, Playing sound")
        XCTAssertEqual(TabChipRules.spokenState(locked: false, pinned: false, playing: true, muted: true), "Muted")
        XCTAssertEqual(TabChipRules.spokenState(locked: false, pinned: false, playing: false, muted: false, asleep: true), "Asleep, reloads when opened")
        XCTAssertEqual(TabChipRules.spokenState(locked: true, pinned: true, playing: false, muted: false, asleep: true), "Pinned, Locked, Asleep, reloads when opened")
    }

    func testPreviewOnlyWhileTheSituationHolds() {
        func may(setting: Bool = true, exists: Bool = true, internalPage: Bool = false, inside: Bool = true, active: Bool = true, dragging: Bool = false) -> Bool {
            TabChipRules.previewMayAppear(settingOn: setting, tabExists: exists, isInternalPage: internalPage, pointerInside: inside, appActive: active, dragging: dragging)
        }
        XCTAssertTrue(may())
        XCTAssertFalse(may(setting: false)); XCTAssertFalse(may(exists: false)); XCTAssertFalse(may(internalPage: true))
        XCTAssertFalse(may(inside: false)); XCTAssertFalse(may(active: false)); XCTAssertFalse(may(dragging: true))
        XCTAssertFalse(TabChipRules.previewMayAppear(settingOn: true, tabExists: true, isInternalPage: false, pointerInside: true, appActive: true, dragging: false, modalUIVisible: true), "nothing previews over the palette, the overview or a sheet")
    }

    /// The real model: a locked tab is refused by closeTab (the rule above only hides the control), and unlocking restores closing.
    @MainActor func testLockedTabIsStillProtectedAndUnlockRestoresClosing() throws {
        let model = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-chip-rules-\(UUID().uuidString)", profile: "default")
        model.newTab(); model.newTab()                    // never the only tab: closing the last one makes the window open a fresh blank tab
        let tab = try XCTUnwrap(model.active)
        model.toggleLock(tab)
        XCTAssertTrue(tab.isLocked)
        let before = model.tabs.count
        model.closeTab(id: tab.id)
        XCTAssertEqual(model.tabs.count, before, "a locked tab is not closed")
        model.toggleLock(tab)
        XCTAssertFalse(tab.isLocked)
        model.closeTab(id: tab.id)
        XCTAssertEqual(model.tabs.count, before - 1, "an unlocked tab closes again")
    }
}
