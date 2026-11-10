import XCTest
import CoreGraphics

extension XCUIElement {
    /// A screenshot that cannot fail the test. `XCUIElement.screenshot()` records a failure ("Image creation failed") when the element is not on the main display,
    /// and the app often opens on the second one. Off the main display the main screen is captured instead, so the picture is still evidence and never an assertion.
    func safeScreenshot() -> XCUIScreenshot {
        if exists, CGDisplayBounds(CGMainDisplayID()).intersects(frame) { return screenshot() }
        return XCUIScreen.main.screenshot()
    }
}
