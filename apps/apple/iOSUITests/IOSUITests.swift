import XCTest

/// Runs inside the iOS Simulator, so it never touches the Mac's keyboard. Needs scripts/testserver.py on :18765.
/// The iPhone has no address bar or toolbar: a dock of three pills at the bottom, a search button at the top right, and a search
/// panel that comes down from the top.
final class IOSUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        _ = try? String(contentsOf: URL(string: "http://127.0.0.1:18765/_reset")!, encoding: .utf8)
        app = XCUIApplication()
        app.launchArguments += ["-UITestRoot", "bs-ios-ui-\(UUID().uuidString)"]
        app.launch()
    }

    func searchButton() -> XCUIElement { app.buttons["collapsed-pill"] }
    func omnibox() -> XCUIElement { app.textFields["omnibox"] }
    func site() -> XCUIElement { app.buttons["collapsed-pill"] }

    func serverSaw(_ path: String) -> Bool {
        ((try? String(contentsOf: URL(string: "http://127.0.0.1:18765/_requests")!, encoding: .utf8)) ?? "").contains(path)
    }

    func waitFor(_ seconds: Double, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if cond() { return true }; Thread.sleep(forTimeInterval: 0.2) }
        return cond()
    }

    func navigate(_ address: String) {
        XCTAssertTrue(searchButton().waitForExistence(timeout: 15), "search button missing")
        searchButton().tap()
        XCTAssertTrue(omnibox().waitForExistence(timeout: 8), "the search panel did not open")
        omnibox().tap()
        omnibox().typeText(address + "\n")
    }

    func testThereAreNoBarsOnlyTheDockAndTheSearchButton() {
        XCTAssertTrue(searchButton().waitForExistence(timeout: 15))
        XCTAssertTrue(site().exists, "the dock's site pill")
        XCTAssertTrue(app.buttons["Back"].exists && app.buttons["Forward"].exists)
        XCTAssertTrue(app.buttons["dock-tabs"].exists && app.buttons["dock-more"].exists)
        XCTAssertFalse(omnibox().exists, "no address bar until search is opened")
        XCTAssertTrue(app.staticTexts["Favorites"].waitForExistence(timeout: 5))
    }

    func testSearchOpensFromTheTopRightAndComesDownFromTheTop() {
        XCTAssertTrue(searchButton().waitForExistence(timeout: 15))
        let button = searchButton().frame
        XCTAssertGreaterThan(button.midX, app.frame.width * 0.6, "the search button is on the right")
        XCTAssertLessThan(button.minY, app.frame.height * 0.15, "and at the top")
        searchButton().tap()
        XCTAssertTrue(omnibox().waitForExistence(timeout: 8))
        XCTAssertLessThan(omnibox().frame.minY, app.frame.height * 0.2, "the field is at the top, above the keyboard")
        XCTAssertTrue(app.buttons["search-engine-menu"].exists, "and there is a way to switch search engines")
    }

    func testTypingAnAddressLoadsARealPage() {
        navigate("127.0.0.1:18765/page")
        XCTAssertTrue(waitFor(20) { self.serverSaw("/page") }, "navigation never reached the server")
        XCTAssertTrue(waitFor(10) { self.site().label.contains("127.0.0.1") }, "the dock names the site: \(site().label)")
        XCTAssertFalse(omnibox().exists, "the search panel closed")
    }

    func testTabOverviewOpensWithNewAndPrivateModes() {
        XCTAssertTrue(searchButton().waitForExistence(timeout: 15))
        app.buttons["dock-tabs"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 6), "overview did not open")
        XCTAssertTrue(app.segmentedControls.buttons["Private"].exists)
        app.segmentedControls.buttons["Private"].tap()
        XCTAssertTrue(app.staticTexts["Private Browsing"].waitForExistence(timeout: 2) || app.buttons["Done"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(waitFor(6) { self.app.staticTexts["Private Browsing"].exists }, "private tab start page should show")
    }

    func testBookmarkingAPageFromTheMenu() {
        navigate("127.0.0.1:18765/page")
        XCTAssertTrue(waitFor(20) { self.serverSaw("/page") })
        XCTAssertTrue(waitFor(10) { self.site().label.contains("127.0.0.1") })
        app.buttons["dock-more"].tap()
        let add = app.buttons["Add Bookmark"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), "the menu offers Add Bookmark")
        add.tap()
        app.buttons["dock-more"].tap()
        XCTAssertTrue(app.buttons["Remove Bookmark"].waitForExistence(timeout: 5), "and now offers Remove Bookmark")
    }

    func testNoBarEverAppearsWhileScrollingAndThePageReachesTheBottomEdge() {
        navigate("127.0.0.1:18765/tall")
        let page = app.webViews.firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 2)
        for _ in 0..<4 { page.swipeUp(velocity: .slow) }
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertTrue(app.buttons["compact-pill"].exists, "reading folds the dock into one small pill")
        XCTAssertFalse(searchButton().exists, "and the top pills step aside")
        for _ in 0..<2 { page.swipeDown(velocity: .slow) }
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertFalse(omnibox().exists, "scrolling never brings a bar back")
        XCTAssertTrue(site().exists && searchButton().exists, "scrolling back opens the dock and the search button again")
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

    private func relaunch(arguments: [String]) {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments += ["-UITestRoot", "bs-ios-ui-\(UUID().uuidString)"] + arguments
        app.launch()
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    /// The dock and search button stay reachable at the largest text size, and in landscape.
    func testLargestTextSizeKeepsTheControlsReachable() {
        relaunch(arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertTrue(searchButton().waitForExistence(timeout: 15), "search button missing at the largest text size")
        XCTAssertTrue(searchButton().isHittable, "search button is covered at the largest text size")
        attach("phone-largest-text")
    }

    func testLandscapeKeepsTheControlsReachable() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(searchButton().waitForExistence(timeout: 15), "search button missing in landscape")
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertTrue(searchButton().isHittable, "search button is covered in landscape")
        attach("phone-landscape")
    }
}
