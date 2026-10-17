import XCTest

/// Drives the real window. Needs scripts/testserver.py on :18765.
final class BrowserUITests: XCTestCase {
    var app: XCUIApplication!
    var root = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        root = "bs-ui-\(UUID().uuidString)"
        _ = try? String(contentsOf: URL(string: "http://127.0.0.1:18765/_reset")!, encoding: .utf8)
        app = XCUIApplication()
        app.launchArguments += ["-UITestRoot", root]
        app.launch()
        try requireForeground()
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "could not be opened")).firstMatch.waitForExistence(timeout: 1.5),
                       "profile failed to open: test data folder is not writable by the app")
    }

    override func tearDown() {
        app?.terminate()
    }

    /// Keystrokes go to the frontmost app. If it is not ours, skip rather than type into someone else's window.
    func requireForeground() throws {
        let ok = app.wait(for: .runningForeground, timeout: 10)
        try XCTSkipUnless(ok, "Browser Setu is not the frontmost app; refusing to send keystrokes")
    }

    func omnibox() -> XCUIElement { app.textFields["omnibox"] }
    func tabChips() -> XCUIElementQuery { app.descendants(matching: .any).matching(identifier: "tab-chip") }

    func serverSaw(_ path: String) -> Bool {
        ((try? String(contentsOf: URL(string: "http://127.0.0.1:18765/_requests")!, encoding: .utf8)) ?? "").contains(path)
    }

    func waitFor(_ seconds: Double, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if cond() { return true }; Thread.sleep(forTimeInterval: 0.2) }
        return cond()
    }

    func navigate(to address: String) {
        guard app.state == .runningForeground else { XCTFail("lost foreground; not typing"); return }
        let box = omnibox()
        XCTAssertTrue(box.waitForExistence(timeout: 10), "address bar not found")
        box.click()
        box.typeText(address)
        XCTAssertEqual(box.value as? String, address, "native typing must preserve every character")
        capture("address-before-return")
        app.typeKey(.return, modifierFlags: [])
    }

    func testTypeAddressAndLoadPage() {
        navigate(to: "127.0.0.1:18765/page")
        XCTAssertTrue(waitFor(15) { self.serverSaw("/page") }, "typing an address and pressing Return did not navigate")
        let chip = tabChips().firstMatch
        XCTAssertTrue(waitFor(15) { chip.exists && chip.label == "Page" },
                      "tab title did not update; chip label = \(chip.exists ? chip.label : "missing")")
        XCTAssertEqual(omnibox().value as? String, "127.0.0.1", "address bar should show only the host until edited")
    }

    func testNewTabAndSwitchWithKeyboard() {
        XCTAssertTrue(omnibox().waitForExistence(timeout: 10))
        XCTAssertEqual(tabChips().count, 1)
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(tabChips().element(boundBy: 1).waitForExistence(timeout: 5))
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitFor(5) { self.tabChips().count == 1 })
    }

    func testBookmarkShortcutAndLibrary() {
        navigate(to: "127.0.0.1:18765/page")
        let chip = tabChips().firstMatch
        XCTAssertTrue(waitFor(15) { chip.exists && chip.label == "Page" }, "page did not load")
        app.typeKey("d", modifierFlags: .command)
        app.typeKey("b", modifierFlags: [.command, .shift])
        let url = "http://127.0.0.1:18765/page"
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@ OR title CONTAINS %@", url, url, url)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8), "bookmark not listed: \(String(app.debugDescription.prefix(2500)))")
    }

    func testTabOverviewShowsSearchesAndCloses() {
        navigate(to: "127.0.0.1:18765/page")
        XCTAssertTrue(waitFor(15) { self.tabChips().firstMatch.label == "Page" })
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(waitFor(5) { self.tabChips().count == 2 })
        app.typeKey("\\", modifierFlags: [.command, .shift])      // Show Tab Overview (the button now lives in the More menu)
        let cards = app.descendants(matching: .any).matching(identifier: "tab-card")
        XCTAssertTrue(waitFor(8) { cards.count == 2 }, "overview should show 2 cards, got \(cards.count)")
        let search = app.descendants(matching: .any).matching(identifier: "tab-search").firstMatch
        _ = search.waitForExistence(timeout: 5)
        XCTAssertTrue(search.exists, "search field missing")
        search.click()
        app.typeText("zzzz-no-match")
        XCTAssertTrue(waitFor(5) { cards.count == 0 }, "search should filter cards")
        app.buttons["overview-done"].click()
        XCTAssertTrue(waitFor(5) { !app.descendants(matching: .any)["tab-overview"].exists })
    }

    func testSuggestionsAppearWhileTyping() {
        navigate(to: "127.0.0.1:18765/page")
        XCTAssertTrue(waitFor(15) { self.tabChips().firstMatch.label == "Page" })
        let box = omnibox()
        box.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText("pag")
        XCTAssertEqual(box.value as? String, "pag")
        capture("search-suggestions")
        let row = app.buttons["Search for “pag”"]
        XCTAssertTrue(row.waitForExistence(timeout: 6), "search suggestion button should appear while typing")
    }

    func testSidebarToggle() {
        XCTAssertTrue(omnibox().waitForExistence(timeout: 10))
        app.typeKey("l", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.buttons["hide-sidebar"].waitForExistence(timeout: 6), "sidebar did not open")
    }

    func testCommandPaletteOpensAndRunsACommand() {
        XCTAssertTrue(omnibox().waitForExistence(timeout: 10))
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Toggle Sidebar"].waitForExistence(timeout: 6), "palette did not list commands")
        app.typeText("new priv")
        XCTAssertTrue(app.staticTexts["New Private Tab"].waitForExistence(timeout: 4))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitFor(6) { self.tabChips().count == 2 }, "palette command did not run")
    }

    func testFindBarOpensOnCommandF() {
        navigate(to: "127.0.0.1:18765/page")
        XCTAssertTrue(waitFor(15) { self.tabChips().firstMatch.label == "Page" })
        app.typeKey("f", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Not found"].exists == false)
        let field = app.descendants(matching: .any).matching(identifier: "find-field").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "find bar did not open")
        app.typeText("zzzqqq")
        XCTAssertTrue(app.staticTexts["Not found"].waitForExistence(timeout: 6), "missing text should report Not found")
    }

    func testFocusModeHidesTabBarAndKeepsExitPath() {
        XCTAssertTrue(omnibox().waitForExistence(timeout: 10))
        app.typeKey("f", modifierFlags: [.command, .option])
        XCTAssertTrue(waitFor(6) { !self.omnibox().isHittable || !self.omnibox().exists }, "toolbar should hide in focus mode")
        app.typeKey("f", modifierFlags: [.command, .option])
        XCTAssertTrue(omnibox().waitForExistence(timeout: 6), "focus mode did not exit")
    }

    func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func layout(_ name: String) {
        app.typeKey("k", modifierFlags: .command)
        let field = app.textFields["palette-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Layout " + name)
        app.typeKey(.return, modifierFlags: [])
    }

    func testEditingSelectAllBackspacePasteEscapeAndRepeatedFocus() {
        navigate(to: "127.0.0.1:18765/page")
        XCTAssertTrue(waitFor(15) { self.tabChips().firstMatch.label == "Page" })
        app.typeKey("l", modifierFlags: .command)
        app.typeText("draftx")
        app.typeKey(.delete, modifierFlags: [])
        XCTAssertEqual(omnibox().value as? String, "draft")
        app.typeKey("l", modifierFlags: .command)
        XCTAssertEqual(omnibox().value as? String, "draft", "repeated focus must not replace the draft")
        app.typeKey("a", modifierFlags: .command)
        app.typeKey("c", modifierFlags: .command)
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeKey("v", modifierFlags: .command)
        XCTAssertEqual(omnibox().value as? String, "draftdraft")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(omnibox().value as? String, "127.0.0.1")
    }

    func testSidebarCompactHoverPrivacyAndNarrowWindow() {
        XCTAssertTrue(omnibox().waitForExistence(timeout: 10))
        capture("classic-start")
        layout("Sidebar")
        XCTAssertTrue(app.buttons["hide-sidebar"].waitForExistence(timeout: 6))
        XCTAssertEqual(tabChips().count, 1)
        XCTAssertTrue(omnibox().exists)
        capture("sidebar-expanded")
        app.buttons["hide-sidebar"].click()
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.002, dy: 0.5)).hover()
        XCTAssertTrue(app.buttons["pin-sidebar"].waitForExistence(timeout: 5), "left edge must reveal")
        capture("sidebar-edge-reveal")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.7)).hover()
        XCTAssertTrue(waitFor(5) { !self.app.buttons["pin-sidebar"].exists }, "sidebar must hide after leaving")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.002, dy: 0.5)).hover()
        XCTAssertTrue(app.buttons["pin-sidebar"].waitForExistence(timeout: 5))
        app.buttons["pin-sidebar"].click()
        XCTAssertTrue(app.buttons["hide-sidebar"].waitForExistence(timeout: 5))
        app.buttons["shield-button"].click()
        XCTAssertTrue(app.staticTexts["Protected"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["protection-level"].exists)
        capture("vayusetu-popover")
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("l", modifierFlags: .command)
        XCTAssertTrue(omnibox().waitForExistence(timeout: 5))
        omnibox().typeText("127.0.0.1:18765/page2\n")
        XCTAssertTrue(waitFor(15) { self.serverSaw("/page2") })
        layout("Classic")
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -2, dy: -2))
        let target = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 540, dy: 440))
        corner.press(forDuration: 0.1, thenDragTo: target)
        XCTAssertTrue(omnibox().isHittable)
        XCTAssertTrue(app.buttons["shield-button"].isHittable)
        capture("narrow-classic")
    }
}
