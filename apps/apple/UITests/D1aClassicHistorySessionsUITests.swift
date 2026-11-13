import XCTest

/// Section 17: History, Reading List, Saved Sessions and Recently Closed in Classic's Library, each on its own data, on a throwaway profile. Dialog answers go through the Debug test seams.
final class D1aClassicHistorySessionsUITests: PerfCase {
    private func launchLibrary(_ extra: [String] = []) {
        launch(state: "bulk-tabs", extra: ["-UITabCount", "5", "-UILayout", "classic", "-UIBookmarks", "1", "-UISidebarOpen", "1"] + extra, env: [:])
        XCTAssertNotNil(until(30) { win.exists && any("sidebar").exists }, "the Library did not open")
        Thread.sleep(forTimeInterval: 0.5)
        app.typeKey(.escape, modifierFlags: [])
        win.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.7)).hover()
        Thread.sleep(forTimeInterval: 0.2)
    }
    private func section(_ name: String) { let r = win.radioButtons[name].exists ? win.radioButtons[name] : win.buttons[name]; XCTAssertTrue(r.exists, "no \(name) in the Library's picker"); r.click(); Thread.sleep(forTimeInterval: 0.4) }
    private func item(_ title: String) -> XCUIElement? { app.menuItems.matching(NSPredicate(format: "title == %@", title)).allElementsBoundByIndex.first { $0.isHittable } }
    private func element(_ label: String) -> XCUIElement { win.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch }
    private func historyItems() -> [SnapItem] { snapItems().filter { ($0.label.contains("/p/Bulk") || $0.label.hasPrefix("Page Bulk")) && $0.frame.minX - win.frame.minX < 300 && $0.frame.minY - win.frame.minY > 150 }.sorted { $0.frame.minY < $1.frame.minY } }
    private func historyRows() -> [String] { historyItems().map(\.label) }

    /// HIS-02/05/08/09/10/25: the row menu acts on the clicked entry; removing it updates the list; Clear History asks, says what it clears, and clears history only.
    func testHistoryRemoveAndClearAreScopedAndConfirmed() throws {
        launchLibrary()
        section("History")
        let before = historyRows().count
        XCTAssertGreaterThan(before, 2, "history shows nothing")
        let f = historyItems()[1].frame           // by position: the same title is also an open tab in the strip
        win.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: f.midX - win.frame.minX, dy: f.midY - win.frame.minY)).rightClick()
        XCTAssertNotNil(until(3) { self.item("Remove from History") != nil && self.item("Copy Address") != nil && self.item("Open in Background Tab") != nil }, "the history menu is incomplete; menu items: \(app.menuItems.allElementsBoundByIndex.map(\.title))")
        item("Remove from History")?.click(); Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(historyRows().count, before - 1, "removing one entry should leave \(before - 1) (\(historyRows().count))")
        // Clear History: cancel first.
        any("clear-history").click()
        XCTAssertNotNil(until(3) { self.app.buttons["Clear History"].exists }, "Clear History did not ask")
        // What macOS actually presents for the confirmation: one container (sheet, dialog or alert) that holds the destructive action, Cancel and the consequence text.
        let box = [win.sheets.firstMatch, app.dialogs.firstMatch, app.alerts.firstMatch].first { $0.exists }
        let dump = XCTAttachment(string: (box ?? win).debugDescription); dump.name = "history-confirmation-hierarchy"; dump.lifetime = .keepAlways; add(dump)
        let presented = try XCTUnwrap(box, "the confirmation is not a sheet, dialog or alert of the window; see the attached hierarchy")
        XCTAssertTrue(presented.buttons["Clear History"].exists && presented.buttons["Cancel"].exists, "the confirmation lacks its destructive action or Cancel")
        let consequence = presented.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'bookmarks' OR value CONTAINS 'bookmarks'")).count
        XCTAssertGreaterThan(consequence, 0, "the confirmation itself does not say that bookmarks are kept")
        attachShot("hist-clear-confirmation")
        app.buttons["Cancel"].click(); Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(historyRows().count, before - 1, "Cancel cleared something")
        any("clear-history").click()
        XCTAssertNotNil(until(3) { self.app.buttons["Clear History"].exists })
        app.buttons["Clear History"].click(); Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(win.staticTexts["No History"].exists, "history is not empty after Clear History")
        section("Bookmarks")
        XCTAssertTrue(element("Bookmark 1").exists, "Clear History removed a bookmark")
        XCTAssertEqual(chipSnapshots().count, 5, "Clear History changed the open tabs")
    }

    /// HIS-11/12/13: the Reading List is a real list with unread state; adding, marking read and removing work, and the section is empty before anything is saved.
    func testReadingListAddMarkReadAndRemove() throws {
        launchLibrary()
        section("Reading List")
        XCTAssertTrue(win.staticTexts["Nothing Saved Yet"].exists, "the Reading List should start empty")
        XCTAssertTrue(any("library-reading-add").exists, "no Add This Page button; present: \(presentIDs())")
        any("library-reading-add").click()
        XCTAssertNotNil(until(8) { self.element("Page Bulk4, unread").exists }, "the page was not added as an unread item")
        attachShot("reading-list-added")
        element("Page Bulk4, unread").rightClick()
        XCTAssertNotNil(until(3) { self.item("Mark as Read") != nil }); item("Mark as Read")?.click(); Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(element("Page Bulk4, read").exists, "the item is not marked read")
        element("Page Bulk4, read").rightClick()
        XCTAssertNotNil(until(3) { self.item("Remove") != nil }); item("Remove")?.click(); Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(win.staticTexts["Nothing Saved Yet"].exists, "removing the only item did not empty the list")
    }

    /// HIS-14/15/16: saving makes a session of the open tabs; opening adds its tabs and replaces none; deleting asks and removes only the session.
    func testSessionsSaveOpenAndDelete() throws {
        launchLibrary(["-UITestPromptAnswer", "Research", "-UITestDialogAnswer", "Delete"])
        section("Sessions")
        XCTAssertTrue(win.staticTexts["No Saved Sessions"].exists, "Sessions should start empty")
        let tabs = chipSnapshots().count, labels = Set(chipSnapshots().map { $0.label })
        XCTAssertTrue(any("library-session-save").exists, "no Save button; present: \(presentIDs())")
        any("library-session-save").click(); Thread.sleep(forTimeInterval: 0.5)
        let row = element("Research, \(tabs) tabs")
        XCTAssertTrue(row.exists, "the saved session is not listed (name, tab count)")
        attachShot("sessions-saved")
        row.click()
        XCTAssertNotNil(until(8) { self.chipSnapshots().count == tabs * 2 }, "opening the session should add its \(tabs) tabs to the \(tabs) open ones (\(self.chipSnapshots().count))")
        XCTAssertTrue(labels.isSubset(of: Set(chipSnapshots().map { $0.label })), "opening a session replaced a tab")
        row.rightClick()
        XCTAssertNotNil(until(3) { self.item("Delete…") != nil }); item("Delete…")?.click(); Thread.sleep(forTimeInterval: 0.4)
        XCTAssertTrue(win.staticTexts["No Saved Sessions"].exists, "the session was not deleted")
        XCTAssertEqual(chipSnapshots().count, tabs * 2, "deleting the session closed tabs")
    }

    /// HIS-17: Recently Closed is its own recovery (Shift-Cmd-T), not a saved session and not history.
    func testRecentlyClosedIsSeparateFromSessionsAndHistory() throws {
        launchLibrary()
        let tabs = chipSnapshots().count
        app.typeKey("w", modifierFlags: .command)
        XCTAssertNotNil(until(4) { self.chipSnapshots().count == tabs - 1 }, "Cmd-W did not close the tab")
        section("Sessions")
        XCTAssertTrue(win.staticTexts["No Saved Sessions"].exists, "closing a tab created a saved session")
        app.typeKey("t", modifierFlags: [.command, .shift])
        XCTAssertNotNil(until(5) { self.chipSnapshots().count == tabs }, "Shift-Cmd-T did not bring the closed tab back")
    }
}
