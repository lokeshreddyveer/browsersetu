import AppKit
import ObjectiveC

#if DEBUG
/// A test process never lets AppKit remember a window's frame. AppKit saves a frame into the person's own preferences (`NSWindow Frame <name>`, outside the relocated home) whenever a window with an autosave
/// name is resized or moved, and SwiftUI gives its windows such a name. Clearing the name after the fact lost races with SwiftUI putting it back, so in a test process the name itself is refused: with no name
/// there is nothing to save. Only a test process (a `-UITestRoot` launch or an XCTest host) installs this; the installed app never does.
enum TestWindowFrameGuard {
    private static var installed = false

    static func installIfTestProcess() {
        let environment = ProcessInfo.processInfo.environment
        let decision = TestIsolation.homeDecision(environment: environment, arguments: CommandLine.arguments, realHome: TestIsolation.realHome, relocatedHome: "")
        guard decision != .notATestProcess, !installed else { return }
        installed = true
        swap(#selector(NSWindow.setFrameAutosaveName(_:)), #selector(NSWindow.bsTest_setFrameAutosaveName(_:)))
        swap(#selector(NSWindow.saveFrame(usingName:)), #selector(NSWindow.bsTest_saveFrame(usingName:)))
    }

    private static func swap(_ original: Selector, _ replacement: Selector) {
        guard let a = class_getInstanceMethod(NSWindow.self, original), let b = class_getInstanceMethod(NSWindow.self, replacement) else { return }
        method_exchangeImplementations(a, b)
    }
}

extension NSWindow {
    /// After the exchange this is `setFrameAutosaveName(_:)`: whatever name is asked for, the empty one is set.
    @objc func bsTest_setFrameAutosaveName(_ name: NSWindow.FrameAutosaveName) -> Bool {
        bsTest_setFrameAutosaveName("")
    }
    /// After the exchange this is `saveFrame(usingName:)`: nothing is saved.
    @objc func bsTest_saveFrame(usingName name: NSWindow.FrameAutosaveName) {}
}
#endif
