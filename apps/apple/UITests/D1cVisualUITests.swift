import XCTest

/// Window-only pictures of One Row (and Classic and Minimal for comparison) in the states D1c's visual review asks for. Run before and after a visual change; compare the files.
final class D1cVisualUITests: PerfCase {
    private func launchLayout(_ layout: String, width: Int, tabs: Int = 6, light: Bool = false) {
        var env = ["BS_WINDOW_SIZE": "\(width)x800"]
        if light { env["BS_SETUP_LIGHT"] = "1" }
        launch(state: "bulk-tabs", extra: ["-UITabCount", "\(tabs)", "-UILayout", layout], env: env)
        XCTAssertNotNil(until(30) { win.exists && abs(win.frame.width - CGFloat(width)) < 6 && any("omnibox").exists }, "\(layout) did not come up at \(width)")
        Thread.sleep(forTimeInterval: 1.0)
        app.typeKey(.escape, modifierFlags: [])
        win.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).hover()   // the pointer rests on the page, so no tab shows a hover
        Thread.sleep(forTimeInterval: 0.4)
    }
    /// A close-up of the top-left of the window at full pixel density: the toolbar and the seam below it.
    private func attachCrop(_ name: String, width: CGFloat = 520, height: CGFloat = 64) {
        guard let cg = win.safeScreenshot()?.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let scale = CGFloat(cg.width) / win.frame.width
        guard let crop = cg.cropping(to: CGRect(x: 0, y: 0, width: min(width, win.frame.width) * scale, height: height * scale)) else { return }
        let attachment = XCTAttachment(image: NSImage(cgImage: crop, size: NSSize(width: crop.width, height: crop.height)))
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func visibleItem(_ title: String) -> XCUIElement? { app.menuItems.matching(NSPredicate(format: "title == %@", title)).allElementsBoundByIndex.first { $0.isHittable } }

    func testOneRowStates() throws {
        launchLayout("inline", width: 1000)
        attachShot("v-onerow-1000-dark"); attachCrop("v-onerow-1000-dark-seam")
        // An inactive tab under the pointer, titled or compact.
        chip(1).hover(); Thread.sleep(forTimeInterval: 0.5); attachShot("v-onerow-inactive-hover"); attachCrop("v-onerow-inactive-hover-crop")
        // Locked.
        chip(1).rightClick()
        XCTAssertNotNil(until(3) { visibleItem("Lock Tab") != nil }); visibleItem("Lock Tab")?.click()
        win.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).hover(); Thread.sleep(forTimeInterval: 0.5)
        attachCrop("v-onerow-locked-crop")
        // Editing.
        app.typeKey("l", modifierFlags: .command); paste("swift browser"); Thread.sleep(forTimeInterval: 0.8)
        attachShot("v-onerow-editing"); attachCrop("v-onerow-editing-crop")
        app.typeKey(.escape, modifierFlags: [])
        app.terminate()

        launchLayout("inline", width: 520, tabs: 8)
        attachShot("v-onerow-520-dark"); attachCrop("v-onerow-520-crop", width: 520)
        chip(1).hover(); Thread.sleep(forTimeInterval: 0.5); attachCrop("v-onerow-520-hover-crop", width: 520)
        app.terminate()

        launchLayout("inline", width: 1200)
        attachShot("v-onerow-1200-dark"); attachCrop("v-onerow-1200-seam", width: 700)
        app.terminate()

        launchLayout("inline", width: 1200, light: true)
        attachShot("v-onerow-1200-light"); attachCrop("v-onerow-1200-light-crop", width: 700)
    }

    /// Classic and Minimal as they are, so a One Row change can be shown not to have touched them.
    func testClassicAndMinimalUnchanged() throws {
        for layout in ["classic", "minimal"] {
            launchLayout(layout, width: 1200)
            attachShot("v-\(layout)-1200-dark")
            app.terminate()
        }
    }
}
