import XCTest

/// Section 21: the Classic quality gate, kept to checks the other Classic classes do not already make. Not yet run.
final class D1aClassicQualityUITests: PerfCase {
    private func launchClassic(open: Bool = false, light: Bool = false, extra: [String] = []) {
        launch(state: "bulk-tabs", extra: ["-UITabCount", "5", "-UILayout", "classic", "-UIBookmarks", "1"] + (open ? ["-UISidebarOpen", "1"] : []) + extra, env: light ? ["BS_SETUP_LIGHT": "1"] : [:])
        XCTAssertNotNil(until(30) { win.exists && any("omnibox").exists }, "Classic did not come up")
        Thread.sleep(forTimeInterval: 0.5)
        app.typeKey(.escape, modifierFlags: [])
    }

    /// QA-23: toggling the Library and resizing it leaves the selected tab and every tab title alone (the same tabs, no reload or reorder).
    func testLibraryToggleAndResizeKeepTheTabs() throws {
        launchClassic(open: true)
        let before = chipSnapshots().map(\.label)
        let selected = chipSnapshots().firstIndex { $0.selected }
        let handle = any("sidebar-resize-handle")
        XCTAssertTrue(handle.exists, "no resize handle")
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.click(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 40, dy: 0)))
        any("close-library").click()
        XCTAssertNotNil(until(4) { !self.any("sidebar").exists })
        app.typeKey("l", modifierFlags: [.command, .shift])
        XCTAssertNotNil(until(4) { self.any("sidebar").exists })
        XCTAssertEqual(chipSnapshots().map(\.label), before, "the tabs changed while the Library was toggled and resized")
        XCTAssertEqual(chipSnapshots().firstIndex { $0.selected }, selected, "the selected tab changed")
    }

    /// QA-12/13: the width the Library was dragged to is the width it reopens at, in this run (the delayed save must not undo it).
    func testDraggedWidthSurvivesCloseAndReopen() throws {
        launchClassic(open: true)
        let widthBefore = any("sidebar").frame.width
        let handle = any("sidebar-resize-handle")
        XCTAssertTrue(handle.exists, "no resize handle")
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.click(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 50, dy: 0)))
        Thread.sleep(forTimeInterval: 0.25)
        let dragged = any("sidebar").frame.width
        XCTAssertGreaterThan(dragged, widthBefore + 20, "the drag did not change the width, so persistence below would prove nothing (\(widthBefore) -> \(dragged))")
        any("close-library").click()
        Thread.sleep(forTimeInterval: 0.3)
        app.typeKey("l", modifierFlags: [.command, .shift])
        XCTAssertNotNil(until(4) { self.any("sidebar").exists })
        Thread.sleep(forTimeInterval: 0.4)                              // longer than the delayed save
        XCTAssertEqual(any("sidebar").frame.width, dragged, accuracy: 2, "the Library reopened at a different width")
    }

    /// QA-19: the Classic composition in the light theme, with and without the Library (pictures for the review).
    func testLightThemePictures() throws {
        launchClassic(open: true, light: true)
        attachShot("quality-light-library")
        any("close-library").click()
        Thread.sleep(forTimeInterval: 0.3)
        attachShot("quality-light-plain")
    }
}
