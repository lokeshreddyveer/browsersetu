import XCTest
import CoreGraphics

extension XCUIElement {
    /// A picture of this element ONLY (for the application element: of its first window), or nil when it cannot be taken (the element is gone, or not on the main display, where `screenshot()` records a failure).
    /// It never falls back to a picture of the whole screen: a screen picture shows whatever else is on the person's displays. scripts/check-uitest-privacy.py fails the build of any test that asks for one.
    func safeScreenshot() -> XCUIScreenshot? {
        let target: XCUIElement = (self as? XCUIApplication)?.windows.firstMatch ?? self
        guard target.exists, CGDisplayBounds(CGMainDisplayID()).intersects(target.frame) else { return nil }
        return target.screenshot()
    }

    /// The same as an attachment; when no picture can be taken the attachment says so.
    func safeAttachment() -> XCTAttachment {
        if let picture = safeScreenshot() { return XCTAttachment(screenshot: picture) }
        return XCTAttachment(string: "No picture: the window is not on the main display (screen captures are never taken).")
    }
}
