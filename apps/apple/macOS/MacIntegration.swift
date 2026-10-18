import AppKit

/// The window the Dock menu and the Services menu act on: the first window that is not a guest or a secondary one.
@MainActor
private func frontModel() -> BrowserModel? {
    let all = BrowserModel.liveModels.allObjects
    return all.first(where: { !$0.isSecondary }) ?? all.first
}

/// Dock menu: what a right-click or long press on the Dock icon offers.
@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = ServicesProvider.shared
        NSUpdateDynamicServices()
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        func add(_ title: String, _ symbol: String, _ action: @escaping @MainActor (BrowserModel) -> Void) {
            let item = ClosureMenuItem(title: title) { if let model = frontModel() { action(model) } }
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        add("New Tab", "plus") { _ = $0.newTab() }
        add("New Private Tab", "eye.slash") { _ = $0.openTab(url: nil, isPrivate: true) }
        add("New Guest Window", "person.crop.circle.badge.questionmark") { $0.openGuestWindow() }
        menu.addItem(.separator())
        add("Reopen Closed Tab", "arrow.uturn.backward") { $0.reopenClosedTab() }
        add("Downloads", "arrow.down.circle") { $0.sheet = .downloads }
        add("Session Time Machine", "clock.arrow.circlepath") { $0.sheet = .timeMachine }
        return menu
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void
    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("not used") }
    @objc private func fire() { run() }
}

/// Services menu: select text or a link in any app, then choose Services › Open in Browser Setu, or Search with Browser Setu.
final class ServicesProvider: NSObject {
    static let shared = ServicesProvider()

    @objc func openInBrowserSetu(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let text = pboard.string(forType: .string) else { error.pointee = "There was no text to open."; return }
        Task { @MainActor in
            guard let model = frontModel() else { return }
            let links = ClipboardTransforms.links(in: text)
            if links.isEmpty { model.navigate(input: text) } else { await model.openLinks(links, background: false) }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc func searchWithBrowserSetu(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let text = pboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { error.pointee = "There was no text to search for."; return }
        Task { @MainActor in
            guard let model = frontModel(), let url = model.searchURL(for: String(text.prefix(300))) else { return }
            _ = model.openTab(url: url, isPrivate: false)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
