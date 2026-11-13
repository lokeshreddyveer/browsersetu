import XCTest

/// Runs inside the iOS Simulator, so it never touches the Mac's keyboard. Needs scripts/testserver.py on :18765.
/// The iPhone opens with the Bottom Bar: an address field along the bottom with Back, Forward, Reload, Share, Tabs and Menu under it; while a page is read
/// the bar folds into one small capsule. (The older floating dock with a search button at the top right is gone.)
final class IOSUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        _ = try? String(contentsOf: URL(string: "http://127.0.0.1:18765/_reset")!, encoding: .utf8)
        app = XCUIApplication()
        app.launchArguments += ["-UITestRoot", "bs-ios-ui-\(UUID().uuidString)"]
        // The first-run Setup screen would cover everything: these tests are about the browser, not about Setup.
        app.launchEnvironment["BS_SKIP_SETUP"] = "1"
        app.launch()
    }

    func omnibox() -> XCUIElement { app.textFields["omnibox"] }
    func tabsButton() -> XCUIElement { app.buttons["Tab overview"] }
    func moreButton() -> XCUIElement { app.buttons["dock-more"] }
    func foldedBar() -> XCUIElement { app.buttons["bar-capsule"] }
    /// An entry of the system menu, whichever element type iOS exposes it as.
    func menuEntry(_ name: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", name)).firstMatch
    }

    /// The screen's element list, to the test log, without the long lists of plain containers.
    func dump(_ why: String) {
        let lines = app.debugDescription.split(separator: "\n").filter { $0.contains("Button") || $0.contains("StaticText") || $0.contains("MenuItem") || $0.contains("TextField") || $0.contains("Menu,") || $0.contains("Alert") || $0.contains("Sheet") }
        print("SCREEN (\(why)):\n" + lines.prefix(60).joined(separator: "\n"))
    }

    func serverSaw(_ path: String) -> Bool {
        ((try? String(contentsOf: URL(string: "http://127.0.0.1:18765/_requests")!, encoding: .utf8)) ?? "").contains(path)
    }

    func waitFor(_ seconds: Double, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if cond() { return true }; Thread.sleep(forTimeInterval: 0.2) }
        return cond()
    }

    func navigate(_ address: String) {
        XCTAssertTrue(omnibox().waitForExistence(timeout: 15), "address field missing")
        omnibox().tap()
        // Tapping the bar's field can bring up the search field in its place: wait for the keyboard, and tap the field that is there now.
        if !waitFor(4, { self.app.keyboards.count > 0 }) { Thread.sleep(forTimeInterval: 0.6); omnibox().tap() }
        _ = waitFor(6) { self.app.keyboards.count > 0 }
        if app.keyboards.count == 0 { print("SCREEN (no keyboard after tapping the address field):\n\(app.debugDescription)") }
        omnibox().typeText(address + "\n")
    }

    func testTheBottomBarHasTheAddressFieldAndItsButtons() {
        XCTAssertTrue(omnibox().waitForExistence(timeout: 15))
        XCTAssertGreaterThan(omnibox().frame.minY, app.frame.height * 0.6, "the address field is at the bottom, where the thumb is")
        if !(app.buttons["Back"].exists && app.buttons["Forward"].exists && app.buttons["Share"].exists) { print("SCREEN (bar buttons):\n\(app.debugDescription)") }
        XCTAssertTrue(app.buttons["Back"].exists && app.buttons["Forward"].exists && app.buttons["Share"].exists)
        XCTAssertTrue(tabsButton().exists && moreButton().exists, "the tabs and menu buttons")
        XCTAssertTrue(app.buttons["add-favorite"].waitForExistence(timeout: 5), "the start page is showing")
    }

    func testTypingAnAddressLoadsARealPage() {
        navigate("127.0.0.1:18765/page")
        XCTAssertTrue(waitFor(20) { self.serverSaw("/page") }, "navigation never reached the server")
        XCTAssertTrue(waitFor(10) { (self.omnibox().value as? String ?? "").contains("127.0.0.1") }, "the field names the site: \(omnibox().value as? String ?? "")")
    }

    func testTabOverviewOpensWithNewAndPrivateModes() {
        XCTAssertTrue(tabsButton().waitForExistence(timeout: 15))
        tabsButton().tap()
        let done = app.buttons["overview-done"]
        if !done.waitForExistence(timeout: 6) { print("SCREEN (overview did not open):\n\(app.debugDescription)") }
        XCTAssertTrue(done.exists, "overview did not open")
        XCTAssertTrue(app.segmentedControls.buttons["Private"].exists)
        app.segmentedControls.buttons["Private"].tap()
        XCTAssertTrue(app.staticTexts["Nothing here is saved"].waitForExistence(timeout: 2) || done.exists)
        done.tap()
        if !waitFor(6, { self.app.staticTexts["Nothing here is saved"].exists }) { dump("private tab start page") }
        XCTAssertTrue(app.staticTexts["Nothing here is saved"].exists, "private tab start page should show")
    }

    func testBookmarkingAPageFromTheMenu() {
        navigate("127.0.0.1:18765/page")
        XCTAssertTrue(waitFor(20) { self.serverSaw("/page") })
        XCTAssertTrue(waitFor(10) { (self.omnibox().value as? String ?? "").contains("127.0.0.1") })
        moreButton().tap()
        let add = menuEntry("Favorite")
        if !add.waitForExistence(timeout: 5) { dump("after tapping the menu button") }
        XCTAssertTrue(add.exists, "the menu offers Favorite")
        add.tap()
        moreButton().tap()
        XCTAssertTrue(menuEntry("Remove Favorite").waitForExistence(timeout: 5), "and now offers Remove Favorite")
    }

    /// The compact bars have no tabs button: the menu has Show All Tabs, which opens the overview.
    func testTheCompactBarReachesTabsFromTheMenu() {
        relaunch(arguments: [], environment: ["BS_PHONE_PRESET": "compactBottom"])
        XCTAssertTrue(omnibox().waitForExistence(timeout: 15), "the compact bar did not come up")
        XCTAssertFalse(tabsButton().exists, "the compact bar has no tabs button of its own")
        XCTAssertTrue(moreButton().waitForExistence(timeout: 5))
        moreButton().tap()
        let all = menuEntry("Show All Tabs")
        if !all.waitForExistence(timeout: 5) { dump("compact menu without Show All Tabs") }
        XCTAssertTrue(all.exists, "the compact bar's menu has Show All Tabs")
        all.tap()
        XCTAssertTrue(app.buttons["overview-done"].waitForExistence(timeout: 6), "Show All Tabs did not open the overview")
    }

    func testNoBarEverAppearsWhileScrollingAndThePageReachesTheBottomEdge() {
        navigate("127.0.0.1:18765/tall")
        let page = app.webViews.firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 2)
        for _ in 0..<4 { page.swipeUp(velocity: .slow) }
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertTrue(foldedBar().exists, "reading folds the bar into one small capsule")
        if tabsButton().exists && tabsButton().isHittable { dump("after scrolling, bar not folded away") }
        XCTAssertFalse(tabsButton().exists && tabsButton().isHittable, "and the bar's buttons step aside")
        for _ in 0..<2 { page.swipeDown(velocity: .slow) }
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertFalse(omnibox().exists, "scrolling never brings a bar back")
        XCTAssertTrue(omnibox().exists && tabsButton().exists, "scrolling back opens the bar again")
        let shot = app.screenshot()
        if let dir = ProcessInfo.processInfo.environment["PILL_SHOT_DIR"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir + "/dock.png"))
        }
        // The page reaches the bottom edge: the last rows of pixels are page, not an empty black strip.
        if let cg = shot.image.cgImage, let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) {
            let bytesPerPixel = cg.bitsPerPixel / 8
            func brightness(row: Int) -> Double {
                var total = 0.0, count = 0.0
                for x in stride(from: 0, to: cg.width, by: 12) {
                    let o = row * cg.bytesPerRow + x * bytesPerPixel
                    total += (Double(bytes[o]) + Double(bytes[o + 1]) + Double(bytes[o + 2])) / 765.0; count += 1
                }
                return total / count
            }
            XCTAssertGreaterThan(brightness(row: cg.height - 4), 0.5, "the bottom edge shows the page, not a black strip")
        }
    }

    // MARK: Layout and accessibility pictures

    private func relaunch(arguments: [String], environment: [String: String] = [:]) {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments += ["-UITestRoot", "bs-ios-ui-\(UUID().uuidString)"] + arguments
        app.launchEnvironment["BS_SKIP_SETUP"] = "1"
        app.launchEnvironment.merge(environment) { _, new in new }
        app.launch()
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    /// The address field and the bar's buttons stay reachable at the largest text size, and in landscape.
    func testLargestTextSizeKeepsTheControlsReachable() {
        relaunch(arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertTrue(omnibox().waitForExistence(timeout: 15), "address field missing at the largest text size")
        XCTAssertTrue(omnibox().isHittable, "address field is covered at the largest text size")
        attach("phone-largest-text")
    }

    func testLandscapeKeepsTheControlsReachable() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(omnibox().waitForExistence(timeout: 15), "address field missing in landscape")
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertTrue(omnibox().isHittable, "address field is covered in landscape")
        attach("phone-landscape")
    }
}
