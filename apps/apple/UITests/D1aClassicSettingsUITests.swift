import XCTest

/// Section 20: Classic's settings reach their components. Each test launches with a setting through the Debug launch options and checks the consumer, not a saved value. Not yet run.
final class D1aClassicSettingsUITests: PerfCase {
    private func launchClassic(_ extra: [String] = [], tabs: Int = 5) {
        launch(state: "bulk-tabs", extra: ["-UITabCount", "\(tabs)", "-UILayout", "classic"] + extra, env: [:])
        XCTAssertNotNil(until(30) { win.exists && any("omnibox").exists }, "Classic did not come up")
        Thread.sleep(forTimeInterval: 0.5)
        app.typeKey(.escape, modifierFlags: [])
    }

    /// SET-01: Classic is a full top toolbar, one tab strip, and its sidebar (when opened) is the Library.
    func testClassicLayoutResolves() throws {
        launchClassic(["-UISidebarOpen", "1"])
        XCTAssertTrue(any("omnibox").exists, "no address field in the toolbar")
        XCTAssertGreaterThanOrEqual(chipSnapshots().count, 5, "no horizontal tab strip")
        XCTAssertTrue(any("close-library").exists, "Classic's sidebar is not the Library")
        XCTAssertFalse(any("sidebar-workspace-header").exists, "Classic's sidebar looks like the vertical tab navigator")
    }

    /// SET-08: the close-button setting reaches the tab strip; the selected tab keeps a Close.
    func testHideCloseButtonSettingReachesTheStrip() throws {
        launchClassic(["-UIHideClose", "1"])
        let closes = snapItems().filter { $0.id == "tab-close" && !$0.selected && $0.frame.width > 0 }.count
        XCTAssertEqual(closes, 0, "unselected tabs still show a Close with the setting off")
    }

    /// SET-09: the single-tab strip setting hides the strip with one tab and shows it with two.
    func testHideSingleTabStripSettingReachesTheStrip() throws {
        launchClassic(["-UIHideSingleStrip", "1"], tabs: 1)
        XCTAssertEqual(chipSnapshots().count, 0, "the strip shows with one tab while the setting is on")
    }

    /// SET-11/13: the Library's position and width settings reach the sidebar.
    func testSidebarPositionAndWidthSettingsReachTheLibrary() throws {
        launchClassic(["-UISidebarOpen", "1", "-UISidebarPosition", "right", "-UISidebarWidth", "300"])
        let sidebar = any("sidebar").frame
        XCTAssertGreaterThan(sidebar.minX - win.frame.minX, win.frame.width / 2, "the Library is not on the right")
        XCTAssertEqual(sidebar.width, 300, accuracy: 6, "the width setting did not reach the Library")
    }

    /// SET-10: tab stacks and tree have no Classic presentation, and the Settings text says so (source-checked wording is covered by the unit tests); the strip stays flat.
    func testTreeAndStacksDoNotChangeTheClassicStrip() throws {
        launchClassic(["-UITree", "1", "-UIStacks", "1"])
        XCTAssertGreaterThanOrEqual(chipSnapshots().count, 5, "tree or stacks changed which tabs the Classic strip shows")
    }
}
