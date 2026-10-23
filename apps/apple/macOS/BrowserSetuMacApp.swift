import SwiftUI

@main
struct BrowserSetuMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @StateObject private var model = BrowserModel(engine: WebKitEngine(), root: Self.debugRoot)
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "SandboxProbe") { Self.runSandboxProbe() }
        #endif
        Self.turnOffSystemWindowRestoration()
    }

    /// Browser Setu brings back its own windows, each with its own tabs, from what it saved. macOS would bring back the same windows a second time, empty, and
    /// the two together grew the number of windows at every start. So the system's copy is switched off, and any it left from earlier runs is deleted.
    private static func turnOffSystemWindowRestoration() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "ApplePersistenceIgnoreState")
        defaults.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        if let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first, let id = Bundle.main.bundleIdentifier {
            try? FileManager.default.removeItem(at: library.appendingPathComponent("Saved Application State/\(id).savedState"))
        }
    }

    #if DEBUG
    /// Debug-only: reports what the real, normally launched app can touch, then exits.
    private static func runSandboxProbe() {
        let home = String(cString: getpwuid(getuid()).pointee.pw_dir)
        var lines = ["home: \(NSHomeDirectory())", "pid: \(getpid())"]
        for sub in ["Documents", "Desktop", "Library/Mail", "Library/Safari", "Downloads"] {
            let count = (try? FileManager.default.contentsOfDirectory(atPath: home + "/" + sub).count) ?? -1
            lines.append("\(sub): \(count >= 0 ? "READABLE" : "blocked") (\(count) entries)")
        }
        let probe = home + "/browsersetu-probe-\(getpid())"
        let wrote = FileManager.default.createFile(atPath: probe, contents: Data("x".utf8))
        try? FileManager.default.removeItem(atPath: probe)
        lines.append("write outside container: \(wrote ? "ALLOWED" : "blocked")")
        try? lines.joined(separator: "\n").write(toFile: NSTemporaryDirectory() + "probe.txt", atomically: true, encoding: .utf8)
        exit(0)
    }
    #endif

    private static var debugRoot: String? {
        #if DEBUG
        // A bare name is created under the app's own temp directory (the sandbox forbids anything else).
        if let root = UserDefaults.standard.string(forKey: "UITestRoot") {
            return root.hasPrefix("/") ? root : NSTemporaryDirectory() + root
        }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return NSTemporaryDirectory() + "bs-test-host-" + UUID().uuidString
        }
        return nil
        #else
        nil
        #endif
    }

    var body: some Scene {
        // One window per `BrowserModel`: the first window owns the browser's shared services, further windows share them.
        WindowGroup("Browser Setu", id: "browser") {
            BrowserWindowHost(primary: model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 800)
        .onChange(of: scenePhase) { _, phase in if phase != .active { model.saveNow() } }
        .commands { BrowserCommands(primary: model) }

        Settings {
            MacSettingsView().environmentObject(model).scrollIndicators(.hidden)
        }
    }
}

/// One browser window. The first claims the app's main model; each later one makes its own model that shares the database, engine, privacy rules and extensions.
struct BrowserWindowHost: View {
    @StateObject private var holder: WindowModelHolder
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    init(primary: BrowserModel) { _holder = StateObject(wrappedValue: WindowModelHolder(primary: primary)) }

    var body: some View {
        let model = holder.model
        MacRootView()
            .environmentObject(model)
            .focusedSceneObject(model)
            .background(WindowLifetime(model: model))
            .task {
                model.windows.onNeedWindow = { [weak model] in model?.windows.requestWindow(); openWindow(id: "browser") }
                model.onWindowShouldClose = { dismiss() }
                if model.isSecondary {
                    model.startSecondaryWindow()
                } else {
                    await model.start()
                    #if DIRECT_BUILD
                    AppUpdater.shared.start()
                    #endif
                    // The extra windows the last session had are opened again, each taking its tabs back.
                    for _ in model.windows.pendingRestores { model.windows.requestWindow(); openWindow(id: "browser") }
                }
            }
            .onOpenURL { model.handleExternal($0) }
            // A link another app opens belongs to a window that is already there; SwiftUI is told this window can take it so it does not make a new one.
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
            .handoff(model)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.downloads.suspendAllBeforeQuit(); model.saveNow() }
    }
}

@MainActor
final class WindowModelHolder: ObservableObject {
    let model: BrowserModel
    init(primary: BrowserModel) {
        if !primary.windows.primaryClaimed { primary.windows.primaryClaimed = true; model = primary }
        else {
            let extra = BrowserModel(sharing: primary)
            extra.isUnrequestedWindow = !primary.windows.claimRequest()
            model = extra
        }
    }
}

/// Tells the model which window is in front, and when its window is closed by the person.
struct WindowLifetime: NSViewRepresentable {
    let model: BrowserModel
    final class V: NSView {
        weak var model: BrowserModel?
        private var tokens: [NSObjectProtocol] = []
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach { NotificationCenter.default.removeObserver($0) }; tokens = []
            guard let window else { return }
            window.isRestorable = false
            // A window nobody asked for stays invisible while it waits to be closed, so it never flashes on screen.
            if model?.isUnrequestedWindow == true { window.alphaValue = 0; window.ignoresMouseEvents = true }
            tokens.append(NotificationCenter.default.addObserver(forName: .browserWindowRevealed, object: model, queue: .main) { [weak window] _ in
                MainActor.assumeIsolated { window?.alphaValue = 1; window?.ignoresMouseEvents = false }
            })
            tokens.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let model = self?.model { model.windows.focused = model } }
            })
            tokens.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.model?.windowWillClose() }
            })
        }
        deinit { tokens.forEach { NotificationCenter.default.removeObserver($0) } }
    }
    func makeNSView(context: Context) -> V { let v = V(); v.model = model; return v }
    func updateNSView(_ view: V, context: Context) { view.model = model }
}

struct BrowserCommands: Commands {
    @ObservedObject var primary: BrowserModel
    /// The commands act on the window in front, or the first one when none is.
    @FocusedObject private var focused: BrowserModel?
    @Environment(\.openWindow) private var openWindow
    private var model: BrowserModel { focused ?? primary }

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { SettingsRouter.open() }.keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Window") { model.windows.requestWindow(); openWindow(id: "browser") }.keyboardShortcut("n", modifiers: .command)
            Button("New Guest Window") { model.openGuestWindow() }.keyboardShortcut("n", modifiers: [.command, .shift, .option])
            Button("Reopen Closed Window") { model.reopenClosedWindow() }.disabled(model.windows.closedWindows.isEmpty)
            Button("Relaunch Without Extensions") { ExtensionSafeMode.relaunch() }
            Button("Move Tab to New Window") { if let id = model.activeID { model.moveTabToNewWindow(id) } }
                .disabled(model.activeID == nil || (model.isSecondary && model.tabs.count < 2))
            Divider()
            Button("New Tab") { model.newTab() }.shortcut(.newTab, model.shortcuts)
            Button("New Private Tab") { model.openTab(url: nil, isPrivate: true) }.shortcut(.newPrivateTab, model.shortcuts)
            Button("Open Location") { model.focusAddressBar() }.shortcut(.openLocation, model.shortcuts)
            Button("Command Palette") { model.paletteVisible.toggle() }.shortcut(.commandPalette, model.shortcuts)
            Divider()
            Button("Close Tab") { if let id = model.activeID { model.closeTab(id: id) } }.shortcut(.closeTab, model.shortcuts)
            Button("Reopen Closed Tab") { model.reopenClosedTab() }.shortcut(.reopenClosedTab, model.shortcuts)
                .disabled(model.closedTabs.isEmpty)
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…") { model.printActive() }.shortcut(.print, model.shortcuts)
                .disabled(model.active?.isBlank ?? true)
            Button("Save Page as PDF") { Task { await model.savePageAsPDF() } }
                .disabled(model.active?.isBlank ?? true)
            Button("Take Screenshot") { Task { await model.takeScreenshot(fullPage: false) } }
                .disabled(model.active?.isBlank ?? true)
            Button("Take Full-Page Screenshot") { Task { await model.takeScreenshot(fullPage: true) } }
                .disabled(model.active?.isBlank ?? true)
            Button("Save Page for Later") { Task { await model.savePageForLater() } }
                .disabled(model.active?.isBlank ?? true)
        }
        CommandMenu("Navigate") {
            Button("Back") { model.active?.goBack() }.shortcut(.back, model.shortcuts)
            Button("Forward") { model.active?.goForward() }.shortcut(.forward, model.shortcuts)
            Button("Reload") { model.active?.reload() }.shortcut(.reload, model.shortcuts)
            Button("Stop") { model.active?.stop() }.shortcut(.stop, model.shortcuts)
            Divider()
            Button("Next Tab") { model.selectAdjacent(1) }.shortcut(.nextTab, model.shortcuts)
            Button("Previous Tab") { model.selectAdjacent(-1) }.shortcut(.previousTab, model.shortcuts)
        }
        CommandGroup(after: .pasteboard) {
            Button("Paste and Go") {
                if let text = NSPasteboard.general.string(forType: .string) {
                    model.addressBar.isEditing = false
                    model.addressBar.clear()
                    model.navigate(input: text)
                }
            }
            .shortcut(.pasteAndGo, model.shortcuts)
            Divider()
            Button("Find in Page…") { model.showFind() }.shortcut(.find, model.shortcuts)
            Button("Find Next") { model.findNext() }.shortcut(.findNext, model.shortcuts).disabled(!model.findVisible)
            Button("Find Previous") { model.findNext(backwards: true) }.shortcut(.findPrevious, model.shortcuts).disabled(!model.findVisible)
        }
        CommandMenu("Workspace") {
            Button("Personal") { model.switchWorkspace("") }.keyboardShortcut("1", modifiers: [.control])
            ForEach(Array(model.workspaces.enumerated()), id: \.element.id) { index, ws in
                if index < 8 { Button(ws.name) { model.switchWorkspace(ws.name) }.keyboardShortcut(KeyEquivalent(Character("\(index + 2)")), modifiers: [.control]) }
                else { Button(ws.name) { model.switchWorkspace(ws.name) } }
            }
            Divider()
            Button("New Workspace…") { promptNewWorkspace(model: model) }
        }
        CommandMenu("Split View") {
            Button("New Tab in Split View") { model.openSplitNewTab() }
            Button("Add a Panel") { model.addThirdPanelNewTab() }.disabled(model.splitTabID == nil || model.fourthSplitTabID != nil)
            Button("Remove the Last Panel") { model.removeThirdPanel() }.disabled(model.thirdSplitTabID == nil)
            Button("Close Split View") { model.closeSplit() }.disabled(model.splitTabID == nil)
            Button("Swap Panels") { model.swapSplit() }.disabled(model.splitTabID == nil)
            Button("Change Direction") { model.splitOrientation = model.splitOrientation == .sideBySide ? .stacked : .sideBySide }
                .disabled(model.splitTabID == nil)
        }
        CommandMenu("Tools") {
            ToolsMenuItems(model: model)
        }
        CommandMenu("Library") {
            Button("Bookmark This Page") { model.toggleBookmark() }.shortcut(.bookmarkPage, model.shortcuts)
            Button("Show Bookmarks") { model.sheet = .bookmarks }.shortcut(.showBookmarks, model.shortcuts)
            Button("Show History") { model.sheet = .history }.shortcut(.showHistory, model.shortcuts)
            Button("Show Downloads") { model.sheet = .downloads }.shortcut(.showDownloads, model.shortcuts)
            Divider()
            Button("Reading List…") { model.sheet = .readingList }
            Button("Add to Reading List") { Task { await model.addToReadingList() } }.disabled(model.active?.isBlank ?? true)
            Button("Highlight Selection") { Task { await model.highlightSelection() } }
            Button("Note for This Page…") { model.sheet = .note }.disabled(model.active?.isBlank ?? true)
            Button("Style for This Website…") { model.sheet = .style }.disabled(model.active?.isBlank ?? true)
            Button("QR Code for This Page…") { model.sheet = .qr }.disabled(model.active?.isBlank ?? true)
            Button("Search My Pages…") { model.sheet = .pageSearch }
            Button("Shopping…") { model.sheet = .shopping }
            Button("Repair This Page…") { model.sheet = .repair }.disabled(model.active?.isBlank ?? true)
            Button("Send to Another Device…") { model.sheet = .devices }
            Button("Share Tabs…") { model.sheet = .shareTabs }.disabled(model.active?.isBlank ?? true)
            Button("Selection Actions…") { model.sheet = .selection }.disabled(model.active?.isBlank ?? true)
            Button("Page Tools…") { model.sheet = .pageTools }.disabled(model.active?.isBlank ?? true)
            Button("Copy Clean Link") { model.copyCleanLink() }.disabled(model.active?.isBlank ?? true)
            Button("Translate Page") { Task { await model.translateOnDevice() } }.disabled(model.active?.isBlank ?? true)
            Divider()
            Button("Privacy Dashboard…") { model.sheet = .dashboard }
            Button("Search Everything…") { model.sheet = .workbench }.keyboardShortcut("k", modifiers: [.command, .option])
            Button("Bookmark Tools…") { model.sheet = .bookmarkTools }
            Button("Feeds and Tools…") { model.sheet = .toolkit }
            Toggle("Search from the Menu Bar (Control-Option-Space)", isOn: Binding(get: { MenuBarSearch.shared.isOn }, set: { MenuBarSearch.shared.setOn($0) }))
            Button("Saved Sessions…") { model.sheet = .sessions }
            Button("Session Time Machine…") { model.sheet = .timeMachine }
            Button("Tab Activity…") { model.sheet = .timeline }
            Button("Close Duplicate Tabs") { model.closeDuplicateTabs() }.disabled(model.duplicateGroups().isEmpty)
            Menu("Split View") {
                Toggle("Link Scrolling", isOn: Binding(get: { model.linkedPanes }, set: { model.setLinkedPanes($0) })).disabled(model.splitTabID == nil)
                Button("Compare the Two Pages…") { Task { await model.comparePanels() } }.disabled(model.splitTabID == nil)
                Button("Reopen Last Split Layout") { model.reopenLastSplit() }.disabled(model.lastSplit == nil)
            }
            Menu("Sort Tabs") {
                ForEach(TabSortOrder.allCases) { order in Button(order.title) { model.sortTabs(by: order) } }
            }
            Button("Mute All Tabs Playing Sound") { model.muteAllPlaying(true) }.disabled(!model.tabs.contains { $0.playingAudio })
            Button("Put Idle Groups to Sleep") { Task { await model.sleepInactiveGroups() } }.disabled(model.inactiveGroups().isEmpty)
            Menu("Snoozed and Scheduled Tabs") {
                if model.tabSchedules.isEmpty { Text("Nothing waiting") }
                ForEach(model.tabSchedules) { item in
                    Button("\(item.title) · \(item.when.formatted(date: .abbreviated, time: .shortened))\(item.repeats == .once ? "" : " · " + item.repeats.title) (Cancel)") { model.cancelSchedule(item.id) }
                }
            }
            Divider()
            Button("Reader") { Task { await model.active?.toggleReader() } }.shortcut(.readerMode, model.shortcuts)
            Menu("Reader Text") {
                Button("Larger") { model.changeReaderSize(by: 2) }
                Button("Smaller") { model.changeReaderSize(by: -2) }
            }
            Menu("Copy Citation") {
                ForEach(PageCitation.Style.allCases) { style in Button(style.title) { model.copyCitation(style) } }
            }.disabled(model.active?.isBlank ?? true)
            Button("Copy Highlights with Citation") { model.copyHighlights() }.disabled(model.active?.readingItemID == nil)
            Button("Translate Selected Text") { Task { await model.translateSelection() } }.disabled(model.active?.isBlank ?? true)
            Button("Detect Page Language") { Task { await model.detectPageLanguage() } }.disabled(model.active?.isBlank ?? true)
            Button("Search This Site…") { Task { await model.searchThisSite() } }.disabled(model.active?.isBlank ?? true)
            Button("Summarize This Page…") { model.sheet = .summary }.disabled(model.active?.isBlank ?? true)
            Menu("Video Speed") {
                ForEach(VideoControls.speeds, id: \.self) { rate in
                    Toggle(VideoControls.label(rate), isOn: Binding(get: { (model.activeVideoSpeed ?? 1) == rate }, set: { _ in model.setVideoSpeed(rate) }))
                }
            }.disabled(model.active?.isBlank ?? true)
            Button("Picture in Picture") { model.togglePictureInPicture() }.disabled(model.active?.isBlank ?? true)
                .disabled(model.active?.isBlank ?? true)
            Button("Share Page…") { model.shareActivePage() }.shortcut(.sharePage, model.shortcuts)
                .disabled(model.active?.isBlank ?? true)
            Divider()
            Button("Search Tabs") {
                if model.tabSearchVisible { model.tabSearchVisible = false; model.tabSearchQuery = "" }
                else {
                    // The list lives in the sidebar, so it has to be on screen.
                    if !model.sidebarVisible { model.pinSidebar() }
                    model.sidebarShowsDownloads = false
                    model.tabSearchVisible = true
                }
            }
                .shortcut(.searchTabs, model.shortcuts)
            Button("Find in All Tabs…") { model.sheet = .findAll }.shortcut(.findAllTabs, model.shortcuts)
            Menu("Recently Closed") {
                ForEach(Array(model.closedTabs.enumerated().reversed().prefix(10)), id: \.offset) { index, closed in
                    Button(closed.title.isEmpty ? displayHost(closed.url) : closed.title) { model.reopenClosedTab(at: index) }
                }
            }
            .disabled(model.closedTabs.isEmpty)
        }
        CommandGroup(after: .sidebar) {
            Button("Toggle Sidebar") { model.sidebarVisible.toggle() }.shortcut(.toggleSidebar, model.shortcuts)
            Button("Show Tab Overview") { model.overviewVisible ? model.hideOverview() : model.showOverview() }
                .shortcut(.tabOverview, model.shortcuts)
            Button("New Tab Group…") { promptNewGroup(model: model) }
            Divider()
            ForEach(1...9, id: \.self) { n in
                Button("Select Tab \(n)") { model.selectTab(number: n) }.keyboardShortcut(KeyEquivalent(Character("\(n)")))
            }
        }
        #if DIRECT_BUILD
        CommandGroup(after: .appInfo) { CheckForUpdatesButton() }
        #endif
        CommandGroup(after: .toolbar) {
            Toggle("Request Mobile Website", isOn: Binding(get: { model.active?.mobileSite ?? false }, set: { _ in model.active?.toggleMobileSite() }))
                .disabled(model.active?.isBlank ?? true)
            Button(model.focusMode ? "Exit Focus Mode" : "Enter Focus Mode") { model.toggleFocusMode() }
                .shortcut(.focusMode, model.shortcuts)
            Button("Restore Standard Layout") { model.restoreStandardLayout() }
                .shortcut(.restoreLayout, model.shortcuts)
            Button("Zoom In") { model.active?.zoom(by: 0.1) }.shortcut(.zoomIn, model.shortcuts)
            Button("Zoom Out") { model.active?.zoom(by: -0.1) }.shortcut(.zoomOut, model.shortcuts)
            Button("Actual Size") { model.active?.resetZoom() }.shortcut(.actualSize, model.shortcuts)
        }
    }
}
