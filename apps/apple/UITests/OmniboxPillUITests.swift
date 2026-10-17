import XCTest

/// The Floating layout's Search pill: one capsule that grows in width into the address field, with the suggestions in a separate card.
/// Every frame of the opening is captured, so the animation can be looked at afterwards.
final class OmniboxPillUITests: XCTestCase {
    var app: XCUIApplication!

    private func launch(dark: Bool = false, light: Bool = false) throws {
        continueAfterFailure = false
        _ = try? String(contentsOf: URL(string: "http://127.0.0.1:18765/_reset")!, encoding: .utf8)
        app = XCUIApplication()
        app.launchArguments += ["-UITestRoot", "bs-ui-pill-\(UUID().uuidString)", "-UIState", "floating"]
        if dark { app.launchArguments += ["-AppleInterfaceStyle", "Dark"] }
        if light { app.launchArguments += ["-NSRequiresAquaSystemAppearance", "YES"] }
        app.launch()
        try XCTSkipUnless(app.wait(for: .runningForeground, timeout: 10), "Browser Setu is not frontmost")
        XCTAssertTrue(pillCollapsed().waitForExistence(timeout: 10))
    }

    override func tearDown() { app?.terminate() }

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }
    private func pillCollapsed() -> XCUIElement { app.buttons["floating-search-button"] }
    private func pillExpanded() -> XCUIElement { any("floating-address-bar") }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private func gone(_ element: XCUIElement, _ seconds: Double = 4) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if !element.exists { return true }; Thread.sleep(forTimeInterval: 0.1) }
        return !element.exists
    }

    // MARK: Opening

    func testOpeningGrowsOnlyInWidthAtAFixedHeight() throws {
        try launch()
        let before = pillCollapsed().frame
        shot("00-collapsed")
        pillCollapsed().click()
        var widths: [CGFloat] = [], heights: [CGFloat] = []
        let start = Date()
        var frame = 0
        while Date().timeIntervalSince(start) < 1.2 {
            let pill = pillExpanded()
            if pill.exists { widths.append(pill.frame.width); heights.append(pill.frame.height) }
            if frame < 12 { shot(String(format: "open-%02d", frame)) }
            frame += 1
        }
        XCTAssertTrue(pillExpanded().exists, "the pill did not open")
        XCTAssertGreaterThan(widths.last ?? 0, before.width + 100, "the pill should have grown wider")
        XCTAssertLessThanOrEqual(widths.max() ?? 0, 440, "it never overshoots into an oversized shape")
        for h in heights { XCTAssertEqual(h, before.height, accuracy: 1.5, "the height must stay the same during the whole animation") }
        // It grows toward the middle of the window and stays attached to its edge.
        XCTAssertEqual(pillExpanded().frame.maxX, before.maxX, accuracy: 2, "the pill stays anchored where it was")
        shot("99-open-final")
    }

    func testTheCurrentAddressIsShownAndSelectedOnFocus() throws {
        try launch()
        app.typeKey("l", modifierFlags: .command)
        XCTAssertTrue(pillExpanded().waitForExistence(timeout: 3), "⌘L did not open the pill")
        let field = app.textFields["omnibox"].exists ? app.textFields["omnibox"] : app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        // Typing replaces whatever was selected, so the field holds only what was typed.
        field.typeText("zz")
        XCTAssertEqual(field.value as? String, "zz", "the old text was selected and was replaced")
    }

    // MARK: Suggestions

    func testSuggestionsAreASeparateCardBelowThePill() throws {
        try launch()
        pillCollapsed().click()
        XCTAssertTrue(pillExpanded().waitForExistence(timeout: 3))
        let field = app.textFields.firstMatch
        field.typeText("te")
        let card = any("suggestions")
        XCTAssertTrue(card.waitForExistence(timeout: 5), "no suggestions appeared")
        Thread.sleep(forTimeInterval: 0.5)
        shot("suggestions")
        // The pill's own accessibility frame includes the card hanging under it, so its top plus the capsule's height is where it ends.
        XCTAssertGreaterThanOrEqual(card.frame.minY, pillExpanded().frame.minY + 30 - 1, "the card sits below the pill, not inside it")
        XCTAssertEqual(card.frame.maxX, pillExpanded().frame.maxX, accuracy: 3, "and lines up with the pill's edge")
    }

    // MARK: Closing

    func testEscapeClosesAndReturnNavigatesOnce() throws {
        try launch()
        pillCollapsed().click()
        XCTAssertTrue(pillExpanded().waitForExistence(timeout: 3))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(gone(pillExpanded()), "Escape did not close the pill")
        XCTAssertTrue(pillCollapsed().waitForExistence(timeout: 3))

        app.typeKey("l", modifierFlags: .command)
        XCTAssertTrue(pillExpanded().waitForExistence(timeout: 3))
        app.textFields.firstMatch.typeText("127.0.0.1:18765/page")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(gone(pillExpanded()), "Return did not close the pill")
        Thread.sleep(forTimeInterval: 1.5)
        let log = (try? String(contentsOf: URL(string: "http://127.0.0.1:18765/_requests")!, encoding: .utf8)) ?? ""
        let hits = log.components(separatedBy: "\n").filter { $0.contains("/page") && !$0.contains("/page2") }.count
        XCTAssertEqual(hits, 1, "Return must navigate exactly once. Server saw:\n\(log)")
    }

    func testClickingThePageClosesThePill() throws {
        try launch()
        pillCollapsed().click()
        XCTAssertTrue(pillExpanded().waitForExistence(timeout: 3))
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.7)).click()
        XCTAssertTrue(gone(pillExpanded()), "a click on the page did not close the pill")
    }

    func testOpeningAndClosingRapidlyLeavesItWorking() throws {
        try launch()
        for i in 0..<20 {
            if i % 2 == 0 { pillCollapsed().click() } else { app.typeKey(.escape, modifierFlags: []) }
            Thread.sleep(forTimeInterval: 0.05)
        }
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(pillCollapsed().waitForExistence(timeout: 4), "the pill did not settle collapsed")
        pillCollapsed().click()
        XCTAssertTrue(pillExpanded().waitForExistence(timeout: 3))
        let field = app.textFields.firstMatch
        field.typeText("ok")
        XCTAssertEqual(field.value as? String, "ok", "focus survived the rapid opening and closing")
        shot("after-rapid")
    }

    func testOpensCleanlyInDarkAppearanceToo() throws {
        try launch(dark: true)
        shot("dark-collapsed")
        pillCollapsed().click()
        XCTAssertTrue(pillExpanded().waitForExistence(timeout: 3))
        app.textFields.firstMatch.typeText("te")
        _ = any("suggestions").waitForExistence(timeout: 5)
        Thread.sleep(forTimeInterval: 0.5)
        shot("dark-suggestions")
    }

    func testOpensCleanlyInLightAppearanceToo() throws {
        try launch(light: true)
        shot("light-collapsed")
        pillCollapsed().click()
        XCTAssertTrue(pillExpanded().waitForExistence(timeout: 3))
        app.textFields.firstMatch.typeText("te")
        _ = any("suggestions").waitForExistence(timeout: 5)
        Thread.sleep(forTimeInterval: 0.5)
        shot("light-suggestions")
    }
}
