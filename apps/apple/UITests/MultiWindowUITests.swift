import XCTest

/// Real windows: a second window opens, tabs move between windows through the menus, and closing the last tab of an extra window closes it.
final class MultiWindowUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-UITestRoot", "bs-ui-windows-\(UUID().uuidString)"]
        app.launch()
        try XCTSkipUnless(app.wait(for: .runningForeground, timeout: 10), "Browser Setu is not frontmost")
        XCTAssertTrue(app.buttons.firstMatch.waitForExistence(timeout: 15), "the window never showed any control")
        let tree = XCTAttachment(string: app.debugDescription); tree.name = "start-tree"; tree.lifetime = .keepAlways; add(tree)
        print("MWUI windows=\(app.windows.count) frames=\(app.windows.allElementsBoundByIndex.map { $0.frame })")
    }

    override func tearDown() {
        if testRun?.hasSucceeded == false, app != nil {
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "at-failure"; shot.lifetime = .keepAlways; add(shot)
        }
        app?.terminate()
    }

    private func windowCount(timeout: TimeInterval = 5, equals expected: Int) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if app.windows.count == expected { return true }; Thread.sleep(forTimeInterval: 0.2) }
        return app.windows.count == expected
    }

    func testANewWindowOpensAndCanBeClosed() throws {
        XCTAssertEqual(app.windows.count, 1)
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(windowCount(equals: 2), "⌘N opens a second window (found \(app.windows.count))")
        app.typeKey("w", modifierFlags: .command)                 // closes the tab: the extra window had one blank tab, so it closes itself
        XCTAssertTrue(windowCount(equals: 1), "closing the last tab closes the extra window (found \(app.windows.count))")
    }

    func testATabMovesToANewWindowFromTheMenu() throws {
        app.typeKey("t", modifierFlags: .command)                 // a second tab, so one can leave
        Thread.sleep(forTimeInterval: 0.6)
        app.menuBars.menuBarItems["File"].click()
        let item = app.menuBars.menuItems["Move Tab to New Window"]
        XCTAssertTrue(item.waitForExistence(timeout: 3))
        item.click()
        XCTAssertTrue(windowCount(equals: 2), "the tab went to a window of its own (found \(app.windows.count))")
    }
}
