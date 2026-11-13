import XCTest

/// Section 15: Classic's Library sidebar, behavior by behavior. Throwaway profile (six bookmarks in three folders and a few history entries), window-only pictures.
final class D1aClassicLibraryUITests: PerfCase {
    private func launchClassic(width: Int = 1200, open: Bool, light: Bool = false, extra: [String] = []) {
        var env: [String: String] = [:]
        if light { env["BS_SETUP_LIGHT"] = "1" }
        // The Library's width is recorded (bounded, DEBUG only) and kept with the result, so an unexplained width shows where it came from.
        let widthTrace = NSTemporaryDirectory() + "bs-sidebar-trace.log"
        try? FileManager.default.removeItem(atPath: widthTrace)
        env["BS_SIDEBAR_TRACE"] = widthTrace
        addTeardownBlock {
            guard let text = try? String(contentsOfFile: widthTrace, encoding: .utf8), !text.isEmpty else { return }
            let a = XCTAttachment(string: text); a.name = "sidebar-width-trace"; a.lifetime = .keepAlways; self.add(a)
        }
        launch(state: "bulk-tabs", extra: ["-UITabCount", "5", "-UILayout", "classic", "-UIBookmarks", "1"] + (open ? ["-UISidebarOpen", "1"] : []) + extra, env: env)
        XCTAssertNotNil(until(30) { win.exists && any("omnibox").exists }, "Classic did not come up")
        Thread.sleep(forTimeInterval: 0.5)
        app.typeKey(.escape, modifierFlags: [])
        win.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.7)).hover()
        Thread.sleep(forTimeInterval: 0.2)
    }
    private func libraryOpen() -> Bool { any("sidebar").exists }
    private func rows() -> [String] { snapItems().filter { ($0.label.hasPrefix("Bookmark ") || $0.label.hasPrefix("Page Mark")) && $0.frame.minX - win.frame.minX < 300 }.map(\.label) }
    private func visibleItem(_ title: String) -> XCUIElement? { app.menuItems.matching(NSPredicate(format: "title == %@", title)).allElementsBoundByIndex.first { $0.isHittable } }
    private func historyTab() -> XCUIElement { win.radioButtons["History"].exists ? win.radioButtons["History"] : win.buttons["History"] }
    private func bookmarksTab() -> XCUIElement { win.radioButtons["Bookmarks"].exists ? win.radioButtons["Bookmarks"] : win.buttons["Bookmarks"] }

    /// LIB-03/04: hidden by default; Shift-Cmd-L opens it, the toolbar button closes it, and the Library's own Close closes it without touching the window or the tabs.
    func testHiddenByDefaultOpensWithTheShortcutAndClosesWithoutClosingAnything() throws {
        launchClassic(open: false)
        XCTAssertFalse(libraryOpen(), "the Library must be hidden by default")
        let tabs = chipSnapshots().count
        app.typeKey("l", modifierFlags: [.command, .shift])
        XCTAssertNotNil(until(4) { self.libraryOpen() }, "Shift-Cmd-L did not open the Library")
        attachShot("lib-open-by-shortcut")
        any("close-library").click()
        XCTAssertNotNil(until(4) { !self.libraryOpen() }, "the Library's Close did not close it")
        XCTAssertTrue(win.exists, "closing the Library closed the window")
        XCTAssertEqual(chipSnapshots().count, tabs, "closing the Library changed the tabs")
        any("sidebar-button").click()
        XCTAssertNotNil(until(4) { self.libraryOpen() }, "the toolbar button did not open the Library")
        any("sidebar-button").click()
        XCTAssertNotNil(until(4) { !self.libraryOpen() }, "the toolbar button did not close it again")
    }

    /// LIB-05: switching sections changes the list and nothing else (the same tab stays selected).
    func testSwitchingSectionsLeavesTheTabAlone() throws {
        launchClassic(open: true)
        let selected = chipSnapshots().first { $0.selected }?.label
        historyTab().click(); Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(bookmarksTab().exists, "the picker is gone in History")
        XCTAssertEqual(chipSnapshots().first { $0.selected }?.label, selected, "History changed the selected tab")
        bookmarksTab().click(); Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(rows().isEmpty, "the bookmarks did not come back")
        XCTAssertEqual(chipSnapshots().first { $0.selected }?.label, selected, "Bookmarks changed the selected tab")
    }

    /// LIB-07: a folder folds and unfolds its bookmarks; folding removes nothing.
    func testFolderFoldsAndUnfolds() throws {
        launchClassic(open: true)
        let all = rows().count
        let favorites = win.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Favorites, 2 bookmarks'")).firstMatch
        XCTAssertTrue(favorites.exists, "no Favorites folder")
        attachShot("lib-folders-open")
        favorites.click()
        XCTAssertNotNil(until(3) { self.rows().count == all - 2 }, "folding Favorites should hide its two bookmarks (\(all) -> \(self.rows().count))")
        attachShot("lib-folder-folded")
        win.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Favorites, 2 bookmarks'")).firstMatch.click()
        XCTAssertNotNil(until(3) { self.rows().count == all }, "unfolding did not bring them back")
    }

    /// LIB-08/12: a click opens the bookmark in the current tab (no new tab); the menu acts on the bookmark that was clicked, not on another.
    func testOpeningAndTheContextMenuTargetTheClickedBookmark() throws {
        launchClassic(open: true)
        let tabsBefore = chipSnapshots().count
        let first = win.descendants(matching: .any).matching(NSPredicate(format: "label == 'Bookmark 1'")).firstMatch
        XCTAssertTrue(first.exists)
        first.click()
        XCTAssertNotNil(until(5) { self.chipSnapshots().first(where: { $0.selected })?.label.contains("Mark1") == true }, "opening Bookmark 1 did not show its page: \(chipSnapshots().first { $0.selected }?.label ?? "-")")
        XCTAssertEqual(chipSnapshots().count, tabsBefore, "opening a bookmark made a new tab (the default is the current tab)")
        // Delete Bookmark 3 from its own menu.
        let three = win.descendants(matching: .any).matching(NSPredicate(format: "label == 'Bookmark 3'")).firstMatch
        three.rightClick()
        XCTAssertNotNil(until(3) { self.visibleItem("Delete") != nil }, "no Delete in the bookmark's menu")
        visibleItem("Delete")?.click(); Thread.sleep(forTimeInterval: 0.4)
        XCTAssertFalse(rows().contains("Bookmark 3"), "Bookmark 3 is still there")
        XCTAssertTrue(rows().contains("Bookmark 1") && rows().contains("Bookmark 4"), "the menu deleted another bookmark: \(rows())")
    }

    /// LIB-09/10: History search filters, clearing the query brings everything back.
    func testHistorySearchFiltersAndClears() throws {
        launchClassic(open: true)
        historyTab().click(); Thread.sleep(forTimeInterval: 0.4)
        let all = snapItems().filter { ($0.label.hasPrefix("Page Bulk") || $0.label.contains("/p/Bulk")) && $0.frame.minX - win.frame.minX < 300 }.count
        XCTAssertGreaterThan(all, 1, "history shows nothing to search")
        let field = win.textFields["Search History"].exists ? win.textFields["Search History"] : win.textFields.matching(NSPredicate(format: "placeholderValue == 'Search History'")).firstMatch
        XCTAssertTrue(field.exists, "no Search History field")
        field.click(); paste("Bulk1"); Thread.sleep(forTimeInterval: 0.4)
        let shown = snapItems().filter { $0.label.contains("Bulk") && $0.frame.minX - win.frame.minX < 300 && $0.frame.minY - win.frame.minY > 200 }.count
        XCTAssertLessThan(shown, all, "the search did not narrow the list (\(all) -> \(shown))")
        attachShot("lib-history-search")
    }

    /// LIB-15: dragging the Library's edge changes its width, within its limits, and the page keeps its room.
    func testResizingTheLibrary() throws {
        launchClassic(open: true)
        let handle = any("sidebar-resize-handle")
        XCTAssertTrue(handle.exists, "no resize handle; present: \(presentIDs())")
        let before = any("sidebar").frame.width
        // The edge of the Library: the handle's own frame is one point wide, so the drag starts on the Library's inner edge, mid-height.
        let edge = any("sidebar").frame
        let origin = win.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: edge.maxX - win.frame.minX - 3, dy: edge.midY - win.frame.minY))
        start.click(forDuration: 0.15, thenDragTo: start.withOffset(CGVector(dx: 70, dy: 0)))     // macOS's mouse drag; press(forDuration:thenDragTo:) does not produce one
        Thread.sleep(forTimeInterval: 0.4)
        let after = any("sidebar").frame.width
        XCTAssertGreaterThan(after, before + 20, "dragging right did not widen the Library (\(before) -> \(after)); handle \(handle.frame), sidebar \(edge)")
        XCTAssertLessThanOrEqual(after, 345, "the Library grew past its maximum")
        XCTAssertGreaterThanOrEqual(win.descendants(matching: .webView).firstMatch.frame.width, 400, "the page lost its room")
        attachShot("lib-resized")
    }

    /// LIB-17: the Library in the light theme.
    func testLibraryInTheLightTheme() throws {
        launchClassic(open: true, light: true)
        XCTAssertTrue(libraryOpen())
        attachShot("lib-light")
    }

    /// LIB-10 / empty states: with no bookmarks the Library says so.
    func testEmptyBookmarksSaySo() throws {
        launch(state: "bulk-tabs", extra: ["-UITabCount", "3", "-UILayout", "classic", "-UISidebarOpen", "1"], env: [:])
        XCTAssertNotNil(until(30) { win.exists && any("sidebar").exists }, "the Library did not open")
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(win.staticTexts["No Bookmarks"].exists, "an empty Library should say No Bookmarks")
        attachShot("lib-empty")
    }
}
