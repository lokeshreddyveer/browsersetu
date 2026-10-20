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

    /// Returns the index of the pressed button; the first button is the default.
    static func choose(title: String, message: String, buttons: [String]) async -> Int {
        if let testHandler { return await testHandler(title, message, buttons) }
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

    static func promptText(title: String, message: String, placeholder: String) async -> String? {
        #if os(macOS)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = placeholder
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
        #else
        guard let top = topViewController() else { return nil }
        return await withCheckedContinuation { cont in
            let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
            a.addTextField { $0.text = placeholder }
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
