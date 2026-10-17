import AppKit
import SwiftUI
import XCTest
@testable import Browser_Setu

/// Exercises the address bar through the exact delegate entry points AppKit calls (begin editing, text changed,
/// Return, Escape, arrow keys), without sending keystrokes to the Mac. The test host app is not active, so AppKit
/// will not attach a live field editor here; real key-by-key typing is covered by the UI tests, which run only
/// while the Mac is idle (scripts/run-ui-tests-when-idle.sh).
@MainActor
final class OmniboxInteractionTests: XCTestCase {
    var model: BrowserModel!
    var window: NSWindow!
    var field: OmniboxTextField!
    var coordinator: OmniboxField.Coordinator!
    var tab: TabController!
    /// Tabs hold the model unowned and WebKit callbacks can arrive late, so test models outlive their tests.
    nonisolated(unsafe) static var retained: [AnyObject] = []

    override func setUp() async throws {
        model = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-ob-\(UUID().uuidString)", profile: "default")
        Self.retained.append(model)
        await model.start()
        tab = model.active!
        tab.engineURLChanged(URL(string: "https://example.com/some/path?q=1")!)
        tab.engineTitleChanged("Example")
        let host = NSHostingView(rootView: MacOmnibox(tab: tab, address: model.addressBar).environmentObject(model))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 40)
        window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFront(nil)
        window.layoutIfNeeded()
        pump()
        field = try XCTUnwrap(find(in: host))
        coordinator = try XCTUnwrap(field.delegate as? OmniboxField.Coordinator)
    }

    override func tearDown() async throws {
        window.close()
        field = nil; coordinator = nil
    }

    private func pump(_ seconds: TimeInterval = 0.25) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    private func find(in view: NSView) -> OmniboxTextField? {
        if let f = view as? OmniboxTextField { return f }
        for sub in view.subviews { if let f = find(in: sub) { return f } }
        return nil
    }

    /// What a click (or ⌘L) triggers: the field becomes first responder.
    private func focus() { field.onFocusChange?(true); pump(0.1) }

    /// What each keystroke triggers: the field's text changes and the delegate is told.
    private func userSets(_ text: String) {
        field.stringValue = text
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        pump(0.1)
    }

    private func command(_ selector: Selector, text: String? = nil) {
        let view = NSTextView()
        view.string = text ?? field.stringValue
        _ = coordinator.control(field, textView: view, doCommandBy: selector)
        pump(0.15)
    }

    // MARK: - Setup

    func testFieldIsAnEditableSelectableAppKitTextField() {
        XCTAssertTrue(field.isEditable, "a label-style field can never take focus")
        XCTAssertTrue(field.isSelectable)
        XCTAssertTrue(field.acceptsFirstResponder)
        XCTAssertEqual(field.placeholderString, "Search or enter address")
        XCTAssertEqual(field.accessibilityIdentifier(), "omnibox")
    }

    func testShowsOnlyTheHostUntilEdited() {
        XCTAssertEqual(field.stringValue, "example.com")
        XCTAssertFalse(model.addressBar.isEditing)
        XCTAssertEqual(field.alignment, .center)
    }

    // MARK: - Editing

    func testFocusShowsTheFullAddressAndStartsEditing() {
        focus()
        XCTAssertTrue(model.addressBar.isEditing)
        XCTAssertEqual(field.stringValue, "https://example.com/some/path?q=1")
        XCTAssertEqual(field.alignment, .left)
    }

    func testTypingReachesTheModelAndKeepsTheFullText() {
        focus()
        userSets("swift")
        XCTAssertEqual(field.stringValue, "swift")
        XCTAssertEqual(model.addressBar.text, "swift")
        userSets("swiftui")
        userSets(String(field.stringValue.dropLast()))                       // backspace
        XCTAssertEqual(field.stringValue, "swiftu")
        XCTAssertEqual(model.addressBar.text, "swiftu")
    }

    func testPageUpdatesNeverOverwriteWhatTheUserIsTyping() {
        focus(); userSets("hello wor")
        tab.engineURLChanged(URL(string: "https://other.example/")!)         // a page finishes loading mid-typing
        tab.engineTitleChanged("Other")
        model.objectWillChange.send()
        model.addressBar.objectWillChange.send()
        pump(0.4)
        XCTAssertEqual(field.stringValue, "hello wor", "SwiftUI updates must not reset the text while editing")
        XCTAssertTrue(model.addressBar.isEditing)
        userSets(field.stringValue + "ld")
        XCTAssertEqual(field.stringValue, "hello world")
    }

    func testEscapeRestoresTheDisplayTextAndStopsEditing() {
        focus(); userSets("typing then cancel")
        command(#selector(NSResponder.cancelOperation(_:)))
        XCTAssertFalse(model.addressBar.isEditing)
        XCTAssertEqual(field.stringValue, "example.com")
        XCTAssertEqual(field.alignment, .center)
        XCTAssertTrue(model.addressBar.suggestions.isEmpty)
    }

    func testReturnSubmitsTheTypedTextAndStopsEditing() async throws {
        _ = try String(contentsOf: URL(string: "http://127.0.0.1:18765/_reset")!, encoding: .utf8)
        focus(); userSets("127.0.0.1:18765/page")
        command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertFalse(model.addressBar.isEditing)
        let end = Date().addingTimeInterval(15)
        while Date() < end, tab.title != "Page" { try await Task.sleep(for: .milliseconds(200)) }   // yield the main actor: WebKit's async callbacks need it
        XCTAssertEqual(tab.url?.absoluteString, "http://127.0.0.1:18765/page", "Return navigated the tab")
        XCTAssertEqual(tab.title, "Page", "url=\(String(describing: tab.url)) loading=\(tab.isLoading) engineURL=\(String(describing: tab.engine.currentURL)) error=\(tab.isShowingError)")
    }

    func testReturnWithASelectedSuggestionOpensThatSuggestion() async throws {
        try model.core.addBookmark(url: "http://127.0.0.1:18765/page2", title: "Page Two Bookmark", folder: "")
        focus(); userSets("page two bookm")
        command(#selector(NSResponder.moveDown(_:)))      // row 0 is "Search for …"
        command(#selector(NSResponder.moveDown(_:)))      // row 1 is the bookmark
        let picked = try XCTUnwrap(model.addressBar.selectedSuggestion)
        XCTAssertEqual(picked.kind, .bookmark)
        command(#selector(NSResponder.insertNewline(_:)), text: "page two bookm")
        let end = Date().addingTimeInterval(15)
        while Date() < end, tab.title != "Page Two" { try await Task.sleep(for: .milliseconds(200)) }
        XCTAssertEqual(tab.url?.absoluteString, "http://127.0.0.1:18765/page2")
        XCTAssertEqual(tab.title, "Page Two", "the suggestion's page actually loaded")
    }

    func testSwitchingTabsWhileEditingPreservesDraft() {
        let other = model.newTab()
        other.engineURLChanged(URL(string: "https://second.example/")!)
        model.select(tab.id)
        pump(0.2)
        focus(); userSets("half typed")
        model.select(other.id)
        pump(0.3)
        XCTAssertTrue(model.addressBar.isEditing)
        XCTAssertEqual(field.stringValue, "half typed", "a tab update must not overwrite active typing")
    }

    func testArrowKeysMoveThroughSuggestions() throws {
        try model.core.addBookmark(url: "https://example.org/docs", title: "Example docs", folder: "")
        focus(); userSets("exampl")
        XCTAssertFalse(model.addressBar.suggestions.isEmpty)
        XCTAssertNil(model.addressBar.selection)
        command(#selector(NSResponder.moveDown(_:)))
        XCTAssertEqual(model.addressBar.selection, 0)
        command(#selector(NSResponder.moveDown(_:)))
        XCTAssertEqual(model.addressBar.selection, 1)
        command(#selector(NSResponder.moveUp(_:)))
        XCTAssertEqual(model.addressBar.selection, 0)
        XCTAssertTrue(model.addressBar.suggestions.contains { $0.kind == .bookmark })
        XCTAssertFalse(model.addressBar.suggestions.contains { $0.target.lowercased().hasPrefix("javascript:") })
    }

    func testUnhandledCommandsAreLeftToAppKit() {
        focus()
        let view = NSTextView()
        XCTAssertFalse(coordinator.control(field, textView: view, doCommandBy: #selector(NSResponder.deleteBackward(_:))),
                       "backspace, select-all, paste and cut are the field editor's own job")
        XCTAssertFalse(coordinator.control(field, textView: view, doCommandBy: #selector(NSResponder.selectAll(_:))))
    }

    func testFocusRequestRoutesToTheRightField() {
        let before = model.omniboxFocusTick
        model.focusAddressBar()
        XCTAssertEqual(model.omniboxFocusTick, before + 1, "classic layout: ⌘L reaches the top bar's field")
    }

    func testRepeatedFocusDoesNotResetDraft() {
        focus(); userSets("unfinished search")
        focus()
        XCTAssertEqual(field.stringValue, "unfinished search")
        XCTAssertEqual(model.addressBar.text, "unfinished search")
    }

    func testNativeBeginEditingNotificationOwnsDraftBeforeAnyKeystroke() {
        coordinator.controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification, object: field))
        XCTAssertTrue(model.addressBar.isEditing)
        XCTAssertEqual(field.stringValue, "https://example.com/some/path?q=1")
        userSets("native draft")
        coordinator.controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification, object: field))
        XCTAssertEqual(field.stringValue, "native draft")
    }
}
