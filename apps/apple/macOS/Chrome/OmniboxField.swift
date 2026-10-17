import AppKit
import SwiftUI
import WebKit

/// Native text field for the address bar.
///
/// Why AppKit: the previous SwiftUI `TextField` sat inside a toolbar item, where `@FocusState` is not reliably reported, so
/// "editing started" was inferred from keystrokes, and page-load updates (URL changes, tab changes) rewrote the text while
/// the user was typing. Here the field editor itself is the source of truth: while the field is first responder SwiftUI
/// never writes to it, and every event (begin, change, submit, cancel, arrow keys) arrives through the real delegate.
@MainActor
final class OmniboxTextField: NSTextField {
    var onFocusChange: ((Bool) -> Void)?
    var focusWhenAttached = false
    /// True once the user has changed the text. Until then, taking focus selects the whole address.
    var userEdited = false
    /// Whether the suggestion list is showing, so a click on it is not mistaken for a click outside.
    var hasSuggestions: (() -> Bool)?
    private var clickMonitor: Any?
    /// The click that gave the field focus ends with a mouse-up that lands in the field editor, which would put the caret where the pointer is and
    /// undo the selection. That one mouse-up is swallowed, so the whole address stays selected.
    private var swallowMouseUp = false
    /// Set when this field took focus because of a mouse click. AppKit hands the field focus before the click's mouse-down reaches it, so that
    /// mouse-down is recognised by this flag, not by the field being idle.
    private var focusedByThisClick = false

    /// While the field is being used, a click anywhere else puts the address bar back as it was: on the page always, and on any
    /// other part of the window when there is no suggestion list that the click might be meant for. (Clicking the page does not
    /// always take the focus away from the field, so the focus alone cannot be relied on.)
    func installClickMonitor() {
        removeClickMonitor()
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            let consumed: Bool = MainActor.assumeIsolated {
                if let self, self.swallowMouseUp, event.window === self.window {
                    self.swallowMouseUp = false
                    return true
                }
                self?.handleClick(event)
                return false
            }
            return consumed ? nil : event
        }
    }

    func removeClickMonitor() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    private func handleClick(_ event: NSEvent) {
        guard currentEditor() != nil, event.window === window, let content = window?.contentView else { return }
        // A click in the field itself is the user working in it.
        if convert(bounds, to: nil).contains(event.locationInWindow) { return }
        let hit = content.hitTest(content.convert(event.locationInWindow, from: nil))
        let onPage = sequence(first: hit, next: { $0?.superview }).contains { $0 is WKWebView }
        guard onPage || !(hasSuggestions?() ?? false) else { return }
        // After the click has been handled, so a button that was clicked still does its job.
        DispatchQueue.main.async { [weak self] in self?.endEditingFromOutside() }
    }

    func endEditingFromOutside() {
        guard currentEditor() != nil else { return }
        window?.makeFirstResponder(nil)
        onFocusChange?(false)
    }

    deinit { if let clickMonitor { NSEvent.removeMonitor(clickMonitor) } }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard focusWhenAttached, window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.focusWhenAttached, self.window != nil else { return }
            self.focusWhenAttached = false
            self.onFocusChange?(true)
            self.selectText(nil)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The first click takes focus and selects the whole address, and does nothing else: no caret is placed where the
    /// pointer landed, which is what used to undo the selection. Once the field is being edited, clicks work as usual
    /// (a click places the caret, a drag selects part of the address).
    override func mouseDown(with event: NSEvent) {
        if focusedByThisClick {
            focusedByThisClick = false
            userEdited = false
            swallowMouseUp = true
            currentEditor()?.selectAll(nil)
            selectEverythingSoon()
            return
        }
        guard currentEditor() == nil else {
            userEdited = true            // the user is choosing a spot themselves; never override it
            wantsFullSelection = false
            super.mouseDown(with: event)
            return
        }
        onFocusChange?(true)             // puts the full address in the field
        userEdited = false
        swallowMouseUp = true
        window?.makeFirstResponder(self)
        currentEditor()?.selectAll(nil)
        selectEverythingSoon()
    }

    override func becomeFirstResponder() -> Bool {
        if let event = NSApp.currentEvent, event.type == .leftMouseDown, event.window === window,
           convert(bounds, to: nil).contains(event.locationInWindow) { focusedByThisClick = true }
        onFocusChange?(true)
        userEdited = false
        let accepted = super.becomeFirstResponder()
        if accepted { selectEverythingSoon() }
        return accepted
    }

    /// Taking focus selects the whole address, so typing replaces it and nothing has to be selected by hand. It is
    /// repeated over the next fraction of a second because the field's layout is still changing as it takes focus (the
    /// controls beside it give way to the return key), and a selection made too early can be lost. Typing stops it.
    fileprivate func selectEverythingSoon() {
        wantsFullSelection = true
        applyPendingSelection()
    }

    /// Set while a new editing session still owes the user a full selection. It is applied now and again whenever the field
    /// lays out or SwiftUI updates it (the moments at which the selection used to get lost), and it ends the instant the user
    /// types or places the caret themselves. No timers.
    fileprivate var wantsFullSelection = false

    func applyPendingSelection() {
        guard wantsFullSelection, !userEdited, let editor = currentEditor() else { return }
        let all = NSRange(location: 0, length: (editor.string as NSString).length)
        if editor.selectedRange != all { editor.selectAll(nil) }
    }

    override func layout() {
        super.layout()
        applyPendingSelection()
    }

    override func resignFirstResponder() -> Bool {
        wantsFullSelection = false
        return super.resignFirstResponder()
    }

}

@MainActor
struct OmniboxField: NSViewRepresentable {
    /// What to show while the user is not editing (the host, or empty for a blank tab).
    let displayText: String
    /// What to put in the field when editing begins (the full address).
    let editText: String
    let placeholder: String
    /// Increments when something (⌘L, a new tab) asks for focus.
    let focusTick: Int
    var focusOnMount: Bool = false
    @ObservedObject var address: AddressBarController

    var onTextChange: (String) -> Void
    var onSubmit: (String) -> Void
    var onMoveSelection: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> OmniboxTextField {
        let field = OmniboxTextField(frame: .zero)
        field.stringValue = displayText
        field.delegate = context.coordinator
        // Use an editable control cell, rather than the label convenience initializer.
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = placeholder
        field.alignment = .center
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.setAccessibilityIdentifier("omnibox")
        field.setAccessibilityLabel("Address and search")
        field.onFocusChange = { [weak coordinator = context.coordinator] focused in coordinator?.focusChanged(focused) }
        field.hasSuggestions = { [weak address] in !(address?.suggestions.isEmpty ?? true) }
        field.focusWhenAttached = focusOnMount
        context.coordinator.lastFocusTick = focusTick
        context.coordinator._field = field
        return field
    }

    func updateNSView(_ field: OmniboxTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        // Either signal means the user owns the text: the live field editor, or the editing flag the delegate set.
        let editing = field.currentEditor() != nil || address.isEditing
        field.applyPendingSelection()
        if focusTick != context.coordinator.lastFocusTick {
            context.coordinator.lastFocusTick = focusTick
            // First-responder changes publish editing state. Defer them out of SwiftUI's update pass.
            DispatchQueue.main.async { [weak field] in
                guard let field else { return }
                if field.window != nil {
                    field.onFocusChange?(true)
                    field.userEdited = false
                    if field.currentEditor() != nil { field.selectEverythingSoon() }
                    else { field.selectText(nil) }
                }
                else { field.focusWhenAttached = true }
                field.currentEditor()?.selectAll(nil)
            }
            return
        }
        if editing {
            // The user owns the text. If something outside (a tab switch) ended editing, let go of focus.
            if !address.isEditing, field.currentEditor() != nil, field.window?.firstResponder === field.currentEditor() {
                DispatchQueue.main.async { [weak field] in field?.window?.makeFirstResponder(nil) }
            }
            return
        }
        if field.stringValue != displayText { field.stringValue = displayText }
        field.alignment = .center
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: OmniboxField
        var lastFocusTick = 0
        private var ownsEditing = false
        init(_ parent: OmniboxField) { self.parent = parent }

        func focusChanged(_ focused: Bool) {
            guard let field = currentField else { return }
            if focused {
                // AppKit can repeat becomeFirstResponder during one editing session.
                // Never reseed a live draft from a page URL (including on repeated ⌘L).
                guard !ownsEditing else { return }
                ownsEditing = true
                field.installClickMonitor()
                field.alignment = .left
                field.stringValue = parent.address.isEditing ? parent.address.text : parent.editText
                field.currentEditor()?.selectAll(nil)       // a click or ⌘L selects the whole address, like Safari
                parent.address.isEditing = true
                parent.address.text = field.stringValue
                parent.onTextChange(field.stringValue)
            } else {
                ownsEditing = false
                field.removeClickMonitor()
                parent.address.isEditing = false
                parent.address.clear()
                field.alignment = .center
                field.stringValue = parent.displayText
            }
        }

        private var currentField: OmniboxTextField? { _field }
        weak var _field: OmniboxTextField?

        func controlTextDidEndEditing(_ notification: Notification) {
            focusChanged(false)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? OmniboxTextField else { return }
            _field = field
            // Only the person typing or pasting counts. Putting the address into the field as it takes focus also reports a change,
            // and counting that as "edited" is what stopped the whole address from staying selected.
            if NSApp.currentEvent?.type == .keyDown { field.userEdited = true; field.wantsFullSelection = false }
            parent.address.text = field.stringValue
            parent.onTextChange(field.stringValue)
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            _field = notification.object as? OmniboxTextField
            focusChanged(true)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            _field = control as? OmniboxTextField
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit(textView.string)
                control.window?.makeFirstResponder(nil)
                if parent.address.isEditing { focusChanged(false) }   // never rely on the resign callback alone
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                control.window?.makeFirstResponder(nil)
                if parent.address.isEditing { focusChanged(false) }   // restores the display text
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onMoveSelection(1)
                return true
            case #selector(NSResponder.moveUp(_:)):
                parent.onMoveSelection(-1)
                return true
            default:
                return false
            }
        }
    }
}
