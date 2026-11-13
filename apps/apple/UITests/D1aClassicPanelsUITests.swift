import XCTest

/// Section 19: Classic's Library sidebar next to the docked panels (Bookmarks / History opened from the toolbar). Throwaway profile, window-only pictures. Not yet run.
final class D1aClassicPanelsUITests: PerfCase {
    private func launchClassic(open: Bool, extra: [String] = []) {
        launch(state: "bulk-tabs", extra: ["-UITabCount", "5", "-UILayout", "classic", "-UIBookmarks", "1"] + (open ? ["-UISidebarOpen", "1"] : []) + extra, env: [:])
        XCTAssertNotNil(until(30) { win.exists && any("omnibox").exists }, "Classic did not come up")
        Thread.sleep(forTimeInterval: 0.5)
        app.typeKey(.escape, modifierFlags: [])
    }
    private func pageWidth() -> CGFloat { win.descendants(matching: .webView).firstMatch.frame.width }

    /// PANEL: with the Library open, opening the docked Bookmarks panel leaves the page a usable width and the Library untouched.
    func testDockedPanelAndLibraryShareTheWindowWithoutStarvingThePage() throws {
        launchClassic(open: true)
        let libraryWidth = any("sidebar").frame.width
        app.typeKey("b", modifierFlags: [.command, .shift])             // Show Bookmarks (the docked panel); the default toolbar has no Bookmarks button
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(any("sidebar").exists, "opening the docked panel closed the Library")
        XCTAssertEqual(any("sidebar").frame.width, libraryWidth, accuracy: 1, "opening the docked panel resized the Library")
        XCTAssertGreaterThanOrEqual(pageWidth(), 300, "the page lost its room to the Library plus the docked panel (\(pageWidth()))")
        attachShot("panel-with-library")
    }

    /// PANEL: closing the docked panel (Escape) does not close the Library, and closing the Library does not close the panel.
    func testClosingOneSurfaceLeavesTheOther() throws {
        launchClassic(open: true)
        app.typeKey("b", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 0.5)
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(any("sidebar").exists, "Escape on the docked panel closed the Library")
        any("close-library").click()
        XCTAssertNotNil(until(4) { !self.any("sidebar").exists }, "the Library did not close")
        XCTAssertTrue(win.exists)
    }

    /// PANEL: opening a panel with the Library closed does not open the Library.
    func testPanelDoesNotOpenTheLibrary() throws {
        launchClassic(open: false)
        app.typeKey("b", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(any("sidebar").exists, "the docked Bookmarks panel opened the Library sidebar")
        attachShot("panel-without-library")
    }
}
