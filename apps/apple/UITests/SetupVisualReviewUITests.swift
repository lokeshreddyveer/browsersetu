import XCTest
import AppKit

/// Walks the first-run assistant in the real Debug app (throwaway profile), one screenshot per step, in dark and in light, with the app frontmost.
/// Screenshots go to the folder named by SETUP_SHOTS_DIR (TEST_RUNNER_SETUP_SHOTS_DIR), and are attached to the result.
/// The assistant's scheme is dark unless Light is chosen in step 2, so the light walk picks Light there and every later step shows in light.
final class SetupVisualReviewUITests: XCTestCase {
    var app: XCUIApplication!
    private var dir: String { ProcessInfo.processInfo.environment["SETUP_SHOTS_DIR"] ?? NSTemporaryDirectory() }
    private var tag: String { ProcessInfo.processInfo.environment["SETUP_SHOTS_TAG"] ?? "run" }

    private func launch() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-UITestRoot", "bs-ui-setup-\(UUID().uuidString)"]
        app.launchEnvironment["BS_SKIP_INTRO"] = "1"     // the first-launch film has its own test (IntroUITests)
        app.launch()
        app.activate()
        try XCTSkipUnless(app.wait(for: .runningForeground, timeout: 15), "Browser Setu is not frontmost")
    }
    override func tearDown() { app?.terminate() }

    private var window: XCUIElement { app.windows["browser-AppWindow-1"] }

    private func shot(_ name: String) {
        let image = window.safeScreenshot()
        try? image.pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/\(tag)-\(name).png"))
        let a = XCTAttachment(screenshot: image); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private func walk(_ prefix: String, light: Bool) throws {
        try launch()
        let setUp = app.buttons["Set Up"]
        XCTAssertTrue(setUp.waitForExistence(timeout: 15), "the assistant did not open")
        shot("\(prefix)-1-welcome")
        setUp.click()
        var index = 2
        let names = ["", "", "look", "layout", "panels", "search", "protection", "passwords", "import", "sync", "media", "done"]
        let last = names.count - 1          // the final step (Start Browsing)
        while index <= last {
            let next = app.buttons["Continue"]
            let finish = app.buttons["Start Browsing"]
            XCTAssertTrue(index == last ? finish.waitForExistence(timeout: 15) : next.waitForExistence(timeout: 8), "step \(index) has no way forward")
            if index == 2 && light {
                let choice = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Light' OR title == 'Light'")).firstMatch
                XCTAssertTrue(choice.waitForExistence(timeout: 5), "no Light choice on the look step")
                choice.click()
            }
            shot("\(prefix)-\(index)-\(names[min(index, names.count - 1)])")
            if index == last { break }
            // On the media step, switch the tools off first: Continue would otherwise start a real install in this test.
            if names[index] == "media" { let toggle = app.descendants(matching: .any)["setup-media-toggle"]; if toggle.exists, "\(toggle.value ?? "")" == "1" { toggle.click() } }
            next.click(); index += 1
        }
        XCTAssertTrue(app.buttons["Start Browsing"].exists, "the last step has no Start Browsing")
        // The start page after setup, for the empty first-run state.
        app.buttons["Start Browsing"].click()
        XCTAssertTrue(app.descendants(matching: .any)["start-search"].waitForExistence(timeout: 10), "the start page did not appear after setup")
        shot("\(prefix)-start-page")
    }

    /// The keyboard alone moves through the assistant: Return is the default button (Set Up, Continue), Escape is Back.
    func testKeyboardMovesThroughTheSteps() throws {
        try launch()
        XCTAssertTrue(app.buttons["Set Up"].waitForExistence(timeout: 15), "the assistant did not open")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["Continue"].waitForExistence(timeout: 5), "Return did not move to the next step")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["Back"].waitForExistence(timeout: 5), "Return did not reach step 3")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.buttons["Continue"].waitForExistence(timeout: 5), "Escape did not go back a step")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.buttons["Set Up"].waitForExistence(timeout: 5), "Escape did not return to the welcome step")
    }

    func testWalkDark() throws { try walk("dark", light: false) }
    func testWalkLight() throws { try walk("light", light: true) }
}
