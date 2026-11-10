import XCTest

/// Clicks every button in the sidebar and the floating controls, in the layouts that have them, and checks each one does its job.
/// Needs scripts/testserver.py on :18765 for the page the buttons act on.
final class SidebarButtonsUITests: XCTestCase {
    var app: XCUIApplication!

    private func launch(state: String) throws {
        continueAfterFailure = false
        _ = try? String(contentsOf: URL(string: "http://127.0.0.1:18765/_reset")!, encoding: .utf8)
        app = XCUIApplication()
        app.launchArguments += ["-UITestRoot", "bs-ui-buttons-\(UUID().uuidString)", "-UIState", state]
        app.launch()
        try XCTSkipUnless(app.wait(for: .runningForeground, timeout: 10), "Browser Setu is not frontmost")
    }

    override func tearDown() {
        if testRun?.hasSucceeded == false, app != nil { snapshot("at-failure") }
        app?.terminate()
    }

    private func button(_ id: String) -> XCUIElement { app.buttons[id] }
    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    /// What is on screen, attached to the test result, for when a button does not do what it should.
    private func snapshot(_ name: String) {
        let shot = XCTAttachment(screenshot: app.safeScreenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
        let tree = XCTAttachment(string: app.debugDescription); tree.name = name + "-tree"; tree.lifetime = .keepAlways; add(tree)
        print("SNAPSHOT \(name): windows=\(app.windows.count) buttons=\(app.buttons.allElementsBoundByIndex.prefix(60).map { $0.identifier + "|" + $0.label })")
    }

    private func click(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let b = button(id)
        XCTAssertTrue(b.waitForExistence(timeout: 6), "\(id) is not on screen", file: file, line: line)
        XCTAssertTrue(b.isHittable, "\(id) is covered by something and cannot be clicked", file: file, line: line)
        b.click()
    }

    private func revealPeekSidebar() {
        let window = app.windows["browser-AppWindow-1"]          // the main window, not whichever window happens to be listed first
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.002, dy: 0.5)).hover()
        XCTAssertTrue(button("pin-sidebar").waitForExistence(timeout: 5), "the left edge did not bring out the sidebar")
    }

    // MARK: The sidebar layout (tabs and address bar in the sidebar)

    func testEveryButtonInTheSidebarLayout() throws {
        try launch(state: "sidebar")
        XCTAssertTrue(button("hide-sidebar").waitForExistence(timeout: 8))

        // The footer's Downloads button opens the Downloads panel (docked beside the page) and the same button closes it again.
        click("downloads-button")
        let table = any("downloads-table")
        let opened = table.waitForExistence(timeout: 6); if !opened { snapshot("downloads-missing") }
        XCTAssertTrue(opened, "Downloads did not open")
        click("downloads-button")
        XCTAssertTrue(waitGone(table), "the Downloads button did not close the panel again")

        // A new tab from the + beside the Open Tabs heading.
        let before = app.descendants(matching: .any).matching(identifier: "tab-chip").count
        click("open-tabs-add")
        XCTAssertTrue(waitFor(5) { self.app.descendants(matching: .any).matching(identifier: "tab-chip").count == before + 1 }, "New Tab did nothing")

        // Settings.
        click("footer-settings")
        let settingsOpen = settingsWindowOpens(); if !settingsOpen { snapshot("settings-missing") }
        XCTAssertTrue(settingsOpen, "Settings did not open")
        app.typeKey("w", modifierFlags: .command)

        // Auto-hide, then the pin button brings the sidebar back.
        click("hide-sidebar")
        revealPeekSidebar()
        click("pin-sidebar")
        XCTAssertTrue(button("hide-sidebar").waitForExistence(timeout: 5), "Pin did not keep the sidebar open")
    }

    // MARK: The Floating layout (pill, search button, sliding sidebar)

    func testEveryButtonInTheFloatingLayout() throws {
        try launch(state: "floating")
        XCTAssertTrue(any("collapsed-pill").waitForExistence(timeout: 8), "the pill is not there")

        // The pill's own buttons: fold it away and open it again.
        click("pill-chevron.up")
        XCTAssertTrue(any("pill-handle").waitForExistence(timeout: 4), "the pill did not fold into its handle")
        XCTAssertFalse(button("collapsed-pill").exists, "the pill should fold away into its handle")
        click("pill-handle")
        XCTAssertTrue(button("pill-chevron.up").waitForExistence(timeout: 4), "the handle did not bring the pill back")
        XCTAssertTrue(button("collapsed-pill").waitForExistence(timeout: 4))

        // On a blank tab "search" is the search box in the page itself, so a page is loaded first (typed there, as a person would).
        let box = app.textFields["start-search"]
        XCTAssertTrue(box.waitForExistence(timeout: 6))
        box.click(); box.typeText("127.0.0.1:18765/page\n")
        XCTAssertTrue(waitFor(15) { !self.button("collapsed-pill").label.contains("New Tab") }, "the page did not load")

        // The pill opens the search panel; Escape closes it.
        click("collapsed-pill")
        XCTAssertTrue(any("floating-address-bar").waitForExistence(timeout: 4), "Search did not open")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitGone(any("floating-address-bar")), "Escape did not close the search panel")

        // The pill's site name opens search too.
        click("collapsed-pill")
        XCTAssertTrue(any("floating-address-bar").waitForExistence(timeout: 4), "the site name did not open search")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitGone(any("floating-address-bar")))

        // The sidebar slides out at the edge; every button in it.
        revealPeekSidebar()
        click("search-tabs-button")
        XCTAssertTrue(any("tab-search").waitForExistence(timeout: 4), "tab search did not open")
        app.buttons["tab-search"].firstMatch.click()
        XCTAssertTrue(waitGone(any("tab-search")), "tab search did not close")

        click("downloads-button")
        let downloadsTable = any("downloads-table")
        let downloadsOpen = downloadsTable.waitForExistence(timeout: 6); if !downloadsOpen { snapshot("downloads-missing") }
        XCTAssertTrue(downloadsOpen, "Downloads did not open")
        click("downloads-button")
        XCTAssertTrue(waitGone(downloadsTable), "the Downloads button did not close the panel again")

        click("footer-bookmarks")
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 4) || app.staticTexts["Bookmarks"].waitForExistence(timeout: 4), "Bookmarks did not open")
        app.typeKey(.escape, modifierFlags: [])
        revealPeekSidebar()
        click("footer-history")
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 4) || app.staticTexts["History"].waitForExistence(timeout: 4), "History did not open")
        app.typeKey(.escape, modifierFlags: [])
        revealPeekSidebar()

        click("footer-settings")
        let settingsOpen = settingsWindowOpens(); if !settingsOpen { snapshot("settings-missing") }
        XCTAssertTrue(settingsOpen, "Settings did not open")
        app.typeKey("w", modifierFlags: .command)
        revealPeekSidebar()

        click("pin-sidebar")
        XCTAssertTrue(button("hide-sidebar").waitForExistence(timeout: 5), "Pin did not keep the sidebar open")
        click("hide-sidebar")
        XCTAssertTrue(waitFor(5) { !self.button("hide-sidebar").exists }, "Unpin did not release the sidebar")
    }

    // MARK: Helpers

    /// The Settings window is up when its General pane is there, or its toolbar tabs are.
    private func settingsWindowOpens() -> Bool {
        waitFor(6) { self.any("settings-general").exists || self.button("General").exists && self.button("Appearance").exists }
    }

    private func waitFor(_ seconds: Double, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if condition() { return true }; Thread.sleep(forTimeInterval: 0.2) }
        return condition()
    }

    private func waitGone(_ element: XCUIElement, timeout: Double = 5) -> Bool { waitFor(timeout) { !element.exists } }
}
