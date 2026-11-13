import AppKit
import Carbon.HIToolbox

/// The window the Dock menu and the Services menu act on: the first window that is not a guest or a secondary one.
@MainActor
private func frontModel() -> BrowserModel? {
    let all = BrowserModel.activeModels.allObjects
    return all.first(where: { !$0.isSecondary }) ?? all.first
}

/// Dock menu: what a right-click or long press on the Dock icon offers.
/// Full screen for the browser window in front: the key window when it can be full screen, otherwise the main window (a small panel can be key without being
/// the window the person means).
@MainActor
enum BrowserFullScreen {
    static func target() -> NSWindow? {
        [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }.first { $0.styleMask.contains(.resizable) && !($0 is NSPanel) }
            ?? NSApp.orderedWindows.first { $0.isVisible && $0.styleMask.contains(.resizable) && !($0 is NSPanel) }
    }
    static func toggle() { target()?.toggleFullScreen(nil) }
}

@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    /// ⌃⌘F goes to the browser window itself. AppKit's View-menu item (kept, so the menu is unchanged) sends it to the key window, and in the layouts with no
    /// toolbar (Floating, Canvas) that did not reach the browser window: full screen could be entered from the menu but not left with ⌃⌘F (a known SwiftUI
    /// symptom, developer.apple.com/forums/thread/725111). Typing in a field is not affected: only this exact combination is taken.
    private var fullScreenKeyMonitor: Any?
    func applicationWillFinishLaunching(_ notification: Notification) {
        fullScreenKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad, .capsLock])
            // Escape leaves full screen, as it does in Safari, Finder and Keynote, but only when nothing else is waiting for it: no panel, sheet, search, find, address
            // editing or half-open address field (each of those takes the Escape first, as before).
            if flags.isEmpty, event.keyCode == 53 {
                let leaves: Bool = MainActor.assumeIsolated {
                    guard let window = BrowserFullScreen.target(), window.styleMask.contains(.fullScreen), window.attachedSheet == nil, let m = frontModel() else { return false }
                    return !(m.overviewVisible || m.paletteVisible || m.findVisible || m.tabSearchVisible || m.floatingAddressVisible || m.sheet != nil || m.addressBar.isEditing)
                }
                guard leaves else { return event }
                MainActor.assumeIsolated { BrowserFullScreen.toggle() }
                return nil
            }
            // The F key by its position (keyCode 3), not by the character it types: with Control held that can arrive as a control code.
            guard flags == [.control, .command], event.keyCode == 3 else { return event }
            let target = MainActor.assumeIsolated({ BrowserFullScreen.target() })
            #if DEBUG
            NSLog("FSKEY fired: target=%@ key=%@ main=%@", String(describing: target?.title), String(describing: NSApp.keyWindow?.className), String(describing: NSApp.mainWindow?.className))
            #endif
            guard target != nil else { return event }
            // After this key event has finished (not inside it, while Control is still down), which is when AppKit accepts the change from every layout.
            DispatchQueue.main.async { MainActor.assumeIsolated { BrowserFullScreen.toggle() } }
            return nil
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = ServicesProvider.shared
        NSUpdateDynamicServices()
        MenuBarSearch.shared.installIfWanted()
        // Hidden working files a crashed or killed media-processing run left in the downloads folder (only files this feature named, whose process is gone).
        if NSClassFromString("XCTestCase") == nil {
            let launched = Date(), folder = DownloadCoordinator.directory
            DispatchQueue.global(qos: .utility).async { _ = FFmpegProcessing.sweepOrphans(in: folder, launchedBefore: launched) }
        }
        #if DIRECT_BUILD
        AgentBridge.shared.sync()
        #endif
    }

    /// Quitting: windows that close now are the app ending, not the person closing them, so what each held is kept for the next start.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        frontModel()?.windows.terminating = true
        SuggestionLearning.flushAll()          // what the address bar learned in the last two seconds is not lost
        return .terminateNow
    }

    /// A click on the Dock icon with no window open brings one window back: one, and one the app asked for.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { frontModel()?.windows.requestWindow() }
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        func add(_ title: String, _ symbol: String, _ action: @escaping @MainActor (BrowserModel) -> Void) {
            let item = ClosureMenuItem(title: title) { if let model = frontModel() { action(model) } }
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        add("New Tab", "plus") { _ = $0.newTab() }
        add("New Private Window", "eye.slash.fill") { $0.openPrivateWindow() }
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

// MARK: Menu-bar search

import SwiftUI
import Carbon.HIToolbox

/// A small search window in the menu bar: type, press Return, and the search opens in the browser. Off unless it is turned on in the Library menu.
@MainActor
final class MenuBarSearch: NSObject {
    static let shared = MenuBarSearch()
    private var item: NSStatusItem?
    private let popover = NSPopover()
    static let key = "MenuBarSearchOn"

    var isOn: Bool { UserDefaults.standard.bool(forKey: Self.key) }

    func setOn(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.key)
        on ? install() : remove()
    }

    func installIfWanted() { if isOn { install() } }

    // Control-Option-Space opens the search from any app. Carbon's hot keys need no permission and work in the sandbox.
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?

    private func registerHotKey() {
        guard hotKey == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MenuBarSearch.shared.showFromHotKey() }
            return noErr
        }, 1, &spec, nil, &hotKeyHandler)
        let id = EventHotKeyID(signature: OSType(0x42535354), id: 1)
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
    }

    private func unregisterHotKey() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        hotKey = nil; hotKeyHandler = nil
    }

    fileprivate func showFromHotKey() {
        NSApp.activate(ignoringOtherApps: true)
        if !popover.isShown { toggle() }
    }

    private func install() {
        guard item == nil else { return }
        registerHotKey()
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search with Browser Setu")
        status.button?.target = self
        status.button?.action = #selector(toggle)
        item = status
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 340, height: 300)
    }

    private func remove() {
        unregisterHotKey()
        popover.performClose(nil)
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    @objc private func toggle() {
        guard let button = item?.button, let model = frontModel() else { return }
        if popover.isShown { popover.performClose(nil); return }
        popover.contentViewController = NSHostingController(rootView: MenuBarSearchView(close: { [weak self] in self?.popover.performClose(nil) }).environmentObject(model))
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}

private struct MenuBarSearchView: View {
    @EnvironmentObject var model: BrowserModel
    let close: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search or enter address", text: $text).textFieldStyle(.plain).focused($focused).onSubmit(go)
            }
            .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.08)))
            Text("Favorites").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 8)], spacing: 8) {
                    ForEach(model.orderedFavorites.prefix(12), id: \.url) { fav in
                        Button { model.open(urlString: fav.url, newTab: true); NSApp.activate(ignoringOtherApps: true); close() } label: {
                            VStack(spacing: 4) { SiteTile(url: fav.url, title: fav.title, size: 36); Text(fav.title.isEmpty ? displayHost(URL(string: fav.url)) : fav.title).font(.caption2).lineLimit(1) }
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14)
        .onAppear { focused = true }
    }

    private func go() {
        let input = text.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else { return }
        _ = model.newTab()
        model.navigate(input: input)
        NSApp.activate(ignoringOtherApps: true)
        close()
    }
}
