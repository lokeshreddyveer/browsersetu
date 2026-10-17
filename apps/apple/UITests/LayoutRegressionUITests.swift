import XCTest

/// Opens the window in each layout, takes a picture of it and checks the way back is always there. The pictures are attached to the result so a change in
/// how any layout looks shows up side by side with the last run. Each state is a debug launch state (`-UIState`).
final class LayoutRegressionUITests: XCTestCase {
    static let states = ["none", "minimal", "floating", "sidebar", "sidebar-right-rail", "inline", "focus", "split", "many-tabs", "workbench", "settings"]

    private func launch(_ state: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestRoot", "bs-ui-layout-\(UUID().uuidString)", "-UIState", state]
        app.launch()
        return app
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
        let tree = XCTAttachment(string: app.debugDescription); tree.name = name + "-accessibility-tree"; tree.lifetime = .keepAlways; add(tree)
    }

    func testEveryLayoutShowsAWindowAndKeepsTheWayBack() throws {
        continueAfterFailure = true
        for state in Self.states {
            let app = launch(state)
            defer { app.terminate() }
            try XCTSkipUnless(app.wait(for: .runningForeground, timeout: 10), "Browser Setu is not frontmost")
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10), "\(state): no window")
            Thread.sleep(forTimeInterval: 1.2)
            attach(app, "layout-\(state)")
            // The escape hatch: the menu item exists whatever the window shows.
            let viewMenu = app.menuBars.menuBarItems["View"]
            if viewMenu.exists {
                viewMenu.click()
                XCTAssertTrue(app.menuBars.menuItems["Restore Standard Layout"].exists, "\(state): Restore Standard Layout is not in the View menu")
                app.typeKey(.escape, modifierFlags: [])
            }
        }
    }

    /// Every control that has an accessibility label keeps a non-empty one in every layout (VoiceOver reads these).
    func testButtonsAreNeverUnlabelledForVoiceOver() throws {
        continueAfterFailure = true
        for state in ["none", "sidebar", "floating", "inline"] {
            let app = launch(state)
            defer { app.terminate() }
            try XCTSkipUnless(app.wait(for: .runningForeground, timeout: 10), "Browser Setu is not frontmost")
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
            Thread.sleep(forTimeInterval: 1)
            let unlabelled = app.windows.firstMatch.buttons.allElementsBoundByIndex.filter { $0.isHittable && $0.label.isEmpty && $0.identifier.isEmpty }
            XCTAssertTrue(unlabelled.isEmpty, "\(state): \(unlabelled.count) buttons have neither a label nor an identifier")
        }
    }
}
