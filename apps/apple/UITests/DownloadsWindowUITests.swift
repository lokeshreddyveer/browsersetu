import XCTest
import AppKit

/// Opens the real Downloads window in the running app (throwaway profile), fills it with real downloads from the local fixture server, and saves screenshots.
/// Screenshots go to the folder named by DOWNLOADS_SHOTS_DIR (passed as TEST_RUNNER_DOWNLOADS_SHOTS_DIR) and are also attached to the result.
final class DownloadsWindowUITests: XCTestCase {
    var app: XCUIApplication!
    private let port = 18766
    private var dir: String { ProcessInfo.processInfo.environment["DOWNLOADS_SHOTS_DIR"] ?? NSTemporaryDirectory() }

    private func launch(root: String, dark: Bool = false, relaunch: Bool = false) throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-UITestRoot", root, "-UIState", "none"]
        if dark { app.launchArguments += ["-AppleInterfaceStyle", "Dark"] } else { app.launchArguments += ["-NSRequiresAquaSystemAppearance", "YES"] }
        app.launch()
        try XCTSkipUnless(app.wait(for: .runningForeground, timeout: 15), "Browser Setu is not frontmost")
    }

    override func tearDown() { app?.terminate() }

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    private func shot(_ name: String, element: XCUIElement? = nil) {
        let target = element ?? app.windows["browser-AppWindow-1"]
        guard let image = target.safeScreenshot() else { return }
        try? image.pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        let a = XCTAttachment(screenshot: image); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private func openWindow() {
        let button = any("downloads-button")
        XCTAssertTrue(button.waitForExistence(timeout: 15), "no Downloads button")
        button.click()
        // The toolbar button opens the popover; the window is one step further.
        let open = app.buttons["Open Downloads"]
        XCTAssertTrue(open.waitForExistence(timeout: 6), "the popover has no way into the window")
        open.click()
        XCTAssertTrue(any("downloads-table").waitForExistence(timeout: 8), "the Downloads window did not open")
    }

    private func add(_ path: String) {
        let plus = app.buttons["Add download"]
        XCTAssertTrue(plus.waitForExistence(timeout: 5))
        plus.click()
        let field = app.textFields.matching(NSPredicate(format: "placeholderValue CONTAINS 'example.com'")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeText("http://127.0.0.1:\(port)\(path)")
        app.buttons["Download"].firstMatch.click()
        Thread.sleep(forTimeInterval: 0.4)
    }

    private func pause(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

    func testWindowStatesLight() throws {
        try launch(root: "bs-ui-dl-\(UUID().uuidString)")
        // 1. The popover with nothing in it, then the window empty.
        any("downloads-button").click()
        pause(0.6)
        shot("01-popover-empty")
        XCTAssertTrue(app.buttons["Open Downloads"].waitForExistence(timeout: 5), "the popover has no way into the window")
        app.buttons["Open Downloads"].click()
        XCTAssertTrue(app.tables["downloads-table"].waitForExistence(timeout: 8) || app.outlines["downloads-table"].waitForExistence(timeout: 2) || any("downloads-table").exists, "the Downloads table did not appear")
        pause(0.6)
        shot("02-window-empty")

        // 2. Real downloads: one that finishes, one that fails, and enough slow ones to fill every place and leave some waiting.
        add("/file/2000000")
        add("/status/404")
        for i in 0..<6 { add("/throttle/\(8 << 20)?bps=150000&n=\(i)") }
        pause(3.5)
        shot("03-window-mixed")

        // 3. Filters.
        for title in ["Active", "Queued", "Completed", "Failed"] {
            // A filter chip's label is its name and, when there are any, how many (for example "Completed 3").
            let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
            if chip.exists { chip.click(); pause(0.4); shot("04-filter-\(title.lowercased())") }
        }
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'All'")).firstMatch.click()

        // 4. Search.
        let search = app.textFields["Search downloads"]
        if search.exists { search.click(); search.typeText("file"); pause(0.4); shot("05-search"); search.typeKey("a", modifierFlags: .command); search.typeKey(.delete, modifierFlags: []) }

        // 5. Selection, inspector and the context menu.
        let table = any("downloads-table")
        // The table is an outline in the accessibility tree: its rows are outline rows (table rows in older builds).
        let outlineRows = table.descendants(matching: .outlineRow)
        let rows = outlineRows.count > 0 ? outlineRows : table.descendants(matching: .tableRow)
        if rows.count > 0 {
            rows.element(boundBy: 0).coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).click(); pause(0.4); shot("06-selected-one")
            rows.element(boundBy: 0).coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).rightClick(); pause(0.5); shot("07-context-menu-one")
            app.typeKey(.escape, modifierFlags: [])
            if rows.count > 2 {
                rows.element(boundBy: 0).coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).click()
                XCUIElement.perform(withKeyModifiers: .shift) { rows.element(boundBy: min(3, rows.count - 1)).coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).click() }
                pause(0.4); shot("08-selected-many")
                rows.element(boundBy: 1).coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).rightClick(); pause(0.5); shot("09-context-menu-many")
                app.typeKey(.escape, modifierFlags: [])
            }
        }
        XCTAssertGreaterThan(rows.count, 0, "no rows were shown for the downloads that were added")

        // 6. Sorting by a column header.
        let header = table.descendants(matching: .any).matching(NSPredicate(format: "label == 'Name'")).firstMatch
        if header.exists { header.click(); pause(0.4); shot("10-sorted-by-name") }

        // 7. The popover with real activity.
        app.typeKey(.escape, modifierFlags: [])
        pause(0.3)
        any("downloads-button").click(); pause(0.7)
        shot("11-popover-active")
        app.typeKey(.escape, modifierFlags: [])
    }

    func testWindowAfterRestartAndDark() throws {
        let root = "bs-ui-dl-\(UUID().uuidString)"
        try launch(root: root, dark: true)
        openWindow()          // through the popover, into the full window
        pause(0.8)
        add("/file/3000000")
        add("/status/404")
        for i in 0..<3 { add("/throttle/\(8 << 20)?bps=100000&n=\(i)") }
        pause(2.5)
        shot("20-dark-mixed")
        // Quit with downloads running, and open the same profile again: what was running is found part-way and waits for a decision.
        app.terminate()
        app = XCUIApplication()
        app.launchArguments += ["-UITestRoot", root, "-UIState", "none", "-AppleInterfaceStyle", "Dark"]
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 15)
        any("downloads-button").click(); pause(0.5)
        if app.buttons["Open Downloads"].waitForExistence(timeout: 5) { app.buttons["Open Downloads"].click() }
        pause(1.2)
        shot("21-dark-after-restart")
        let chip = app.buttons["Recovery Required"].firstMatch
        if chip.exists { chip.click(); pause(0.4); shot("22-dark-recovery-required") }
        let paused = app.buttons["Paused"].firstMatch
        if paused.exists { paused.click(); pause(0.4); shot("23-dark-paused") }
    }
}
