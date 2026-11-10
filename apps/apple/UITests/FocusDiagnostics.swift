import XCTest
import AppKit
import ApplicationServices

/// What the UI tests need to know when a keystroke does not land: which processes are running under the app's identifier (the installed copy and the one under test share it), which one is in
/// front, whether this process may drive the interface at all, and where the window and the address bar are. Printed, and attached to the test so it can be read afterwards.
enum FocusDiagnostics {
    static let bundleID = "com.browsersetu.mac"

    @discardableResult
    static func report(app: XCUIApplication, label: String, test: XCTestCase) -> String {
        let trusted = AXIsProcessTrusted()
        let copies = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .map { "pid \($0.processIdentifier) active=\($0.isActive) hidden=\($0.isHidden) \($0.bundleURL?.path ?? "?")" }
        let front = NSWorkspace.shared.frontmostApplication.map { "\($0.localizedName ?? "?") pid \($0.processIdentifier) \($0.bundleIdentifier ?? "?")" } ?? "none"
        let window = app.windows.firstMatch
        let frame = window.exists ? NSStringFromRect(window.frame) : "no window"
        let screens = NSScreen.screens.map { NSStringFromRect($0.frame) }.joined(separator: "; ")
        let box = app.textFields["omnibox"]
        let focus = box.exists ? "\(box.value(forKey: "hasKeyboardFocus") ?? "?")" : "no address bar"
        // Every text field the app shows right now, and what sits on top of the window: where the keyboard could be going instead.
        let fields = app.textFields.allElementsBoundByIndex.prefix(6).map { "\($0.identifier.isEmpty ? "?" : $0.identifier) \(NSStringFromRect($0.frame)) focus=\($0.value(forKey: "hasKeyboardFocus") ?? "?")" }.joined(separator: "; ")
        let covering = "windows=\(app.windows.count) sheets=\(app.sheets.count) dialogs=\(app.dialogs.count) popovers=\(app.popovers.count)"
        let text = "FOCUS[\(label)] accessibilityTrusted=\(trusted) | app under test pid=\((app.value(forKey: "processID") as? Int32).map(String.init) ?? "?") state=\(app.state.rawValue) | copies running under \(bundleID): \(copies) | frontmost: \(front) | window \(frame) | screens [\(screens)] | address bar hasKeyboardFocus=\(focus) | \(covering) | text fields: \(fields)"
        print(text)
        let attachment = XCTAttachment(string: text)
        attachment.name = "focus-\(label)"
        attachment.lifetime = XCTAttachment.Lifetime.keepAlways
        test.add(attachment)
        return text
    }
}
