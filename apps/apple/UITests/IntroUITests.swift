import XCTest

/// The first-launch film (the globe). Frames at fixed moments (BS_INTRO_AT freezes it), nothing of the browser visible, Skip reaching setup, and the film playing through to setup by itself.
final class IntroUITests: XCTestCase {
    private var dir: String { ProcessInfo.processInfo.environment["INTRO_SHOTS_DIR"] ?? NSTemporaryDirectory() }
    private func launch(at seconds: Double? = nil) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-UITestRoot", "bs-ui-intro-\(UUID().uuidString)"]
        if let seconds { app.launchEnvironment["BS_INTRO_AT"] = "\(seconds)" }
        app.launch(); app.activate()
        return app
    }
    private func shot(_ app: XCUIApplication, _ name: String) {
        let image = app.windows["browser-AppWindow-1"].safeScreenshot()
        try? image.pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/globe-\(name).png"))
        let a = XCTAttachment(screenshot: image); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    func testFramesAtFixedMoments() throws {
        for (name, t) in [("1-world", 0.9), ("2-storm", 1.6), ("3-arc-sweeping", 2.4), ("4-arc-complete", 3.3), ("5-dome", 4.0), ("6-calm", 4.7), ("7-name", 5.4)] {
            let app = launch(at: t)
            XCTAssertTrue(app.windows["browser-AppWindow-1"].waitForExistence(timeout: 15))
            XCTAssertFalse(app.buttons["Set Up"].exists, "setup must not show during the film")
            Thread.sleep(forTimeInterval: 1.0)
            shot(app, name)
            app.terminate()
        }
    }

    func testSkipReachesSetup() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["Skip introduction"].waitForExistence(timeout: 15), "the film has a Skip control")
        XCTAssertFalse(app.buttons["Set Up"].exists)
        app.buttons["Skip introduction"].click()
        XCTAssertTrue(app.buttons["Set Up"].waitForExistence(timeout: 10), "Skip goes straight to setup")
        app.terminate()
    }

    func testPlaysThroughToSetup() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["Skip introduction"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Set Up"].waitForExistence(timeout: 20), "after the film, the first setup step")
        app.terminate()
    }
}
