import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Hosts an engine's native view (the engine view on each platform) inside SwiftUI.
struct EngineViewHost {
    let view: PlatformView
}

#if os(macOS)
extension EngineViewHost: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(view, to: container)
        return container
    }
    func updateNSView(_ container: NSView, context: Context) {
        // Only a page with no home is taken in here. A page that has been given to another window (a tab moved or dropped there) must be left alone: the window it
        // left is still updating for a moment, and taking the page back made it vanish from the window it was moved to.
        if view.superview == nil { attach(view, to: container) }
    }
    private func attach(_ child: NSView, to container: NSView) {
        child.removeFromSuperview()
        child.frame = container.bounds
        child.autoresizingMask = [.width, .height]
        container.addSubview(child)
    }
}
#else
extension EngineViewHost: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif

/// Native dialogs owned by the trusted shell; page content cannot style or replace them.
@MainActor
enum Dialogs {
    /// Test hook: replaces modal dialogs so permission prompts can be asserted headlessly.
    static var testHandler: ((_ title: String, _ message: String, _ buttons: [String]) async -> Int)?

    /// The permission dialog: a short question, a details table, the privacy note, an optional "remember" checkbox and the separate choice about local peers. Cancel is the default button.
    static func permission(_ p: LocalTrackerPermission.Prompt) async -> LocalTrackerPermission.Answer {
        if let testHandler {
            // Test handler: button 0 cancels; 1 allows; the bits 2 and 4 add "remember" and "peers" (so 3 = allow + remember, 5 = allow + peers, 7 = all).
            let i = await testHandler(p.title, p.intro + "\n" + p.details.map { "\($0.0): \($0.1)" }.joined(separator: "\n") + "\n" + p.risk, ["Cancel", p.allowTitle] + (p.rememberLabel != nil ? ["remember"] : []) + ["peers"])
            return LocalTrackerPermission.Answer(allowed: i >= 1, remember: i >= 1 && (i & 2) != 0 && p.rememberLabel != nil, peers: i >= 1 && (i & 4) != 0)
        }
        #if os(macOS)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = p.title
        alert.informativeText = p.intro
        alert.addButton(withTitle: "Cancel")                         // the default
        alert.addButton(withTitle: p.allowTitle)
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        let table = NSGridView(numberOfColumns: 2, rows: 0); table.columnSpacing = 14; table.rowSpacing = 4
        for (k, v) in p.details {
            let key = NSTextField(labelWithString: k); key.textColor = .secondaryLabelColor
            let val = NSTextField(wrappingLabelWithString: v); val.isSelectable = true
            table.addRow(with: [key, val])
        }
        table.column(at: 1).width = 300
        let risk = NSTextField(wrappingLabelWithString: p.risk); risk.font = .systemFont(ofSize: 11.5); risk.textColor = .secondaryLabelColor
        risk.preferredMaxLayoutWidth = 380
        stack.addArrangedSubview(table); stack.addArrangedSubview(risk)
        var remember: NSButton?
        if let label = p.rememberLabel { let b = NSButton(checkboxWithTitle: label, target: nil, action: nil); b.state = .off; b.setAccessibilityIdentifier("permission-remember"); stack.addArrangedSubview(b); remember = b }
        let peers = NSButton(checkboxWithTitle: p.peersLabel, target: nil, action: nil); peers.state = .off; peers.setAccessibilityIdentifier("permission-peers")
        stack.addArrangedSubview(peers)
        stack.frame = NSRect(x: 0, y: 0, width: 400, height: stack.fittingSize.height)
        alert.accessoryView = stack
        let allowed = alert.runModal() == .alertSecondButtonReturn
        return LocalTrackerPermission.Answer(allowed: allowed, remember: allowed && remember?.state == .on, peers: allowed && peers.state == .on)
        #else
        let i = await choose(title: p.title, message: p.intro + "\n\n" + p.risk, buttons: ["Cancel", p.allowTitle])
        return LocalTrackerPermission.Answer(allowed: i == 1)
        #endif
    }

    /// Returns the index of the pressed button; the first button is the default.
    static func choose(title: String, message: String, buttons: [String]) async -> Int {
        if let testHandler { return await testHandler(title, message, buttons) }
        #if DEBUG
        // Test seam (Debug builds only): a native UI test cannot read or press a modal alert's buttons, so it can ask for a button by its title.
        if let answer = UserDefaults.standard.string(forKey: "UITestDialogAnswer"), let i = buttons.firstIndex(of: answer) { return i }
        #endif
        #if os(macOS)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        buttons.forEach { alert.addButton(withTitle: $0) }
        let r = alert.runModal()
        return r.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        #else
        guard let top = topViewController() else { return buttons.count - 1 }
        return await withCheckedContinuation { cont in
            let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
            for (i, b) in buttons.enumerated() {
                a.addAction(UIAlertAction(title: b, style: i == buttons.count - 1 && buttons.count > 1 ? .cancel : .default) { _ in
                    cont.resume(returning: i)
                })
            }
            top.present(a, animated: true)
        }
        #endif
    }

    /// `prefill: false` shows `placeholder` as a hint that disappears when typing starts (it is never the answer); the default fills the field with it as a starting value, as renames do.
    static func promptText(title: String, message: String, placeholder: String, prefill: Bool = true) async -> String? {
        #if os(macOS)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        if prefill { field.stringValue = placeholder } else { field.placeholderString = placeholder }
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
        #else
        guard let top = topViewController() else { return nil }
        return await withCheckedContinuation { cont in
            let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
            a.addTextField { if prefill { $0.text = placeholder } else { $0.placeholder = placeholder } }
            a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in cont.resume(returning: nil) })
            a.addAction(UIAlertAction(title: "OK", style: .default) { _ in
                cont.resume(returning: a.textFields?.first?.text)
            })
            top.present(a, animated: true)
        }
        #endif
    }

    #if os(iOS)
    static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var vc = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let next = vc?.presentedViewController { vc = next }
        return vc
    }
    #endif
}

func openExternally(_ url: URL) {
    #if os(macOS)
    NSWorkspace.shared.open(url)
    #else
    UIApplication.shared.open(url)
    #endif
}

func revealInSystem(_ url: URL) {
    #if os(macOS)
    NSWorkspace.shared.activateFileViewerSelecting([url])
    #endif
}


/// A small tap felt on the iPhone for the things that matter (a tab opened, closed or pinned). Nothing on the Mac.
enum Haptics {
    /// The light tick of a selection changing, such as switching tab.
    @MainActor static func selection() {
        #if os(iOS)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }

    @MainActor static func tap() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }
}
