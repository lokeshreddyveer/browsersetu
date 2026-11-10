import SwiftUI
import Security

@main
struct BrowserSetuMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @StateObject private var model = BrowserModel(engine: WebKitEngine(), root: Self.debugRoot)
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // The app no longer runs in the App Sandbox: bring the earlier container's data across (copy only) before anything opens it. Never under tests or with a test root.
        if Self.debugRoot == nil, NSClassFromString("XCTestCase") == nil, UserDefaults.standard.string(forKey: "UITestRoot") == nil {
            if case .failed(let why) = SandboxMigration.runIfNeeded() {
                // Nothing is created in the new place until the old data has been copied: starting now would make a fresh, empty profile there.
                let alert = NSAlert()
                alert.messageText = "Your earlier Browser Setu data could not be copied yet"
                alert.informativeText = why + "\n\nYour earlier data has not been changed. Quit now and try again, or continue with a new, empty profile."
                alert.addButton(withTitle: "Quit"); alert.addButton(withTitle: "Continue With Empty Data")
                if alert.runModal() == .alertFirstButtonReturn { exit(0) }
            }
        }
        #if DEBUG
        // Debug only: `-SelfTestBundledExtractor <output file>` starts the bundled extractor the way the app does, writes what happened, and quits. It shows whether the tool works when the real app
        // (launched normally, not under a test runner) starts it. `-SelfTestExtractorURL <address>` also asks it about a page.
        if let out = UserDefaults.standard.string(forKey: "SelfTestBundledExtractor") {
            Task { @MainActor in
                var lines: [String] = []
                ExternalExtractor.trace = { msg in lines.append("[trace \(Date().timeIntervalSince1970)] \(msg)") }
                if let v = BundledExtractor.verify() {
                    lines.append("verified \(v.identity)")
                    lines.append(JSSolver.report().diagnostics)
                    lines.append("options \(BundledExtractor.extraArguments)")
                    do { let o = try await ExternalExtractor.run(v.url, arguments: ["--version"], timeout: 60, maxBytes: 4096); lines.append("version \(String(decoding: o, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))") }
                    catch { lines.append("version FAILED \(error)") }
                    if let u = UserDefaults.standard.string(forKey: "SelfTestExtractorURL").flatMap(URL.init(string:)) {
                        do { let src = try await ExternalExtractor.lookup(page: u, path: v.url.path, isPrivate: false, allowLocal: true, timeout: 90, expectedIdentity: v.identity)
                             if case .tracks(let r) = src.shape { lines.append("lookup OK \(r.map { "\($0.formatID ?? "?"):\($0.container):\($0.url.lastPathComponent)" })") } else { lines.append("lookup OK manifest") } }
                        catch { lines.append("lookup FAILED \(error)") }
                    }
                } else { lines.append("bundled tool missing or not verified") }
                try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
                exit(0)
            }
        }
        if let dir = UserDefaults.standard.string(forKey: "MediaToolsFixture") { MediaToolsDebug.configure(folder: URL(fileURLWithPath: dir)) }
        if let dir = UserDefaults.standard.string(forKey: "FFmpegToolsFixture") { MediaToolsDebug.configure(folder: URL(fileURLWithPath: dir), prefix: "FFmpegToolsFixture", store: .ffmpeg, resource: "BundledFFmpeg") }
        // Debug only: `-FFmpegDevTool <folder holding ffmpeg/>` uses the locally built media processing tool (pinned by its own digest, as the unit tests do) so a UI run can process real files.
        if let bin = UserDefaults.standard.string(forKey: "FFmpegDevTool") {
            let dir = URL(fileURLWithPath: bin).appendingPathComponent("ffmpeg", isDirectory: true)
            guard let digest = ManagedTool.treeDigest(of: dir) else { fatalError("-FFmpegDevTool: \(dir.path) is not a tool folder") }
            let pin = FileManager.default.temporaryDirectory.appendingPathComponent("bs-ffmpeg-devpin-\(UUID().uuidString).json")
            let json: [String: Any] = ["name": "ffmpeg", "version": "9.0.2", "sha256": "x", "sourceURL": "https://example.com/x.zip", "executable": "ffmpeg", "layout": "flat", "treeSHA256": digest, "signaturePolicy": "adhoc"]
            if let data = try? JSONSerialization.data(withJSONObject: json), (try? data.write(to: pin)) != nil {
                FFmpegTool.tool.manifestURL = pin; FFmpegTool.tool.helpersFolder = URL(fileURLWithPath: bin); FFmpegTool.tool.forgetCache()
            }
        }
        // Debug only: `-DenoDevTool <folder holding deno/>` pins a locally prepared Deno (by its own digest, for THIS yt-dlp) so a run can exercise the managed-Deno tier. Release builds have no such hook; the tier
        // itself still requires the app's own Team ID, a valid signature, the hardened runtime, this processor and a verified yt-dlp pairing.
        if let bin = UserDefaults.standard.string(forKey: "DenoDevTool"), let team = JSChallengeProvider.ownTeamID {
            let dir = URL(fileURLWithPath: bin).appendingPathComponent("deno", isDirectory: true)
            guard let digest = ManagedTool.treeDigest(of: dir) else { fatalError("-DenoDevTool: \(dir.path) is not a tool folder") }
            let version = UserDefaults.standard.string(forKey: "DenoDevVersion") ?? "2.9.8"
            let pin = FileManager.default.temporaryDirectory.appendingPathComponent("bs-deno-devpin-\(UUID().uuidString).json")
            let json: [String: Any] = ["name": "deno", "version": version, "sha256": "x", "sourceURL": "", "executable": "deno", "layout": "flat", "treeSHA256": digest,
                                       "architectures": [ManagedDeno.thisMacsArchitecture], "signaturePolicy": "teamID:\(team)", "forYtDlp": [BundledExtractor.manifest()?.version ?? ""]]
            if let data = try? JSONSerialization.data(withJSONObject: json), (try? data.write(to: pin)) != nil {
                ManagedDeno.tool.manifestURL = pin; ManagedDeno.tool.helpersFolder = URL(fileURLWithPath: bin); ManagedDeno.tool.forgetCache()
            }
        }
        // A debug run with the provider fixture starts with no fixture sign-in: the stand-in Vimeo token it saves in the Keychain would otherwise outlive the run and change the next one.
        if UserDefaults.standard.string(forKey: "ProviderFixture") != nil {
            SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: "com.browsersetu.provider.uitest.default", kSecAttrAccount: "vimeo"] as CFDictionary)
            SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: "com.browsersetu.provider.uitest.default", kSecAttrAccount: "vimeo", kSecUseDataProtectionKeychain: true] as CFDictionary)
        }
        #endif
        NoScrollBars.install()          // no scroll bars anywhere in the app's own interface (see NoScrollBars)
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "SandboxProbe") { Self.runSandboxProbe() }
        #endif
        Self.turnOffSystemWindowRestoration()
        LaunchHandling.handle()
        // Misspelled words are underlined in text boxes on pages until the person chooses otherwise (Edit › Spelling and Grammar). A registered default
        // never overrides a choice already made. Automatic correction stays off: it rewrites what is typed.
        UserDefaults.standard.register(defaults: ["WebContinuousSpellCheckingEnabled": true, "WebAutomaticSpellingCorrectionEnabled": false])
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
        Group { if let app = model.webApp { WebAppWindowView(app: app) } else { FirstLaunchGate { MacRootView() } } }
            .environmentObject(model)
            .focusedSceneObject(model)
            .background(WindowLifetime(model: model))
            // No scroll bars anywhere in the app's own interface: set once here, so every list, table, editor, sheet and popover of the window inherits it (a page keeps its own).
            .scrollIndicators(.hidden)
            .task {
                model.windows.onNeedWindow = { [weak model] in model?.windows.requestWindow(); openWindow(id: "browser") }
                model.onWindowShouldClose = { dismiss() }
                if model.isSecondary {
                    model.startSecondaryWindow()
                } else {
                    await model.start()
                    model.openLaunchWebApps()
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
        /// Kept here because a window's delegate is not retained by the window.
        private var closeGuard: PrivateWindowCloseGuard?

        /// A private window asks before closing while it still has downloads running (see PrivateWindowCloseGuard). Installed only for private windows.
        private func installCloseGuardIfPrivate() {
            guard let window, closeGuard == nil, MainActor.assumeIsolated({ model?.isPrivateWindow == true }) else { return }
            let guardian = PrivateWindowCloseGuard()
            guardian.original = window.delegate
            guardian.model = model
            closeGuard = guardian
            window.delegate = guardian
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach { NotificationCenter.default.removeObserver($0) }; tokens = []
            guard let window else { return }
            installCloseGuardIfPrivate()
            tokens.append(NotificationCenter.default.addObserver(forName: .privateWindowStarted, object: model, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.installCloseGuardIfPrivate() }
            })
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
            Button("Settings…") { AppCommands.perform("cmd-browser-setu-settings", model) } .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Window") { model.windows.requestWindow(); openWindow(id: "browser") }.keyboardShortcut("n", modifiers: .command)
            Button("New Guest Window") { AppCommands.perform("cmd-file-new-guest-window", model) } .keyboardShortcut("n", modifiers: [.command, .shift, .option])
            Button("Reopen Closed Window") { AppCommands.perform("cmd-file-reopen-closed-window", model) }.disabled(!AppCommands.isEnabled("cmd-file-reopen-closed-window", model))
            Button("Relaunch Without Extensions") { AppCommands.perform("cmd-file-relaunch-without-extensions", model) }
            Button("Move Tab to New Window") { AppCommands.perform("cmd-file-move-tab-to-new-window", model) }.disabled(!AppCommands.isEnabled("cmd-file-move-tab-to-new-window", model))
            Divider()
            Button("New Tab") { AppCommands.perform("cmd-file-new-tab", model) } .shortcut(.newTab, model.shortcuts)
            // ⇧⌘N follows the Settings choice; the explicit commands always do what they say. In "ask" mode ⇧⌘N asks and the two explicit commands keep their own keys.
            Button("New Private Window") { AppCommands.perform("cmd-file-new-private-window", model) } .shortcut(model.privateOpenMode == .window ? .newPrivate : .newPrivateWindow, model.shortcuts)
            Button("New Private Tab") { AppCommands.perform("cmd-file-new-private-tab", model) } .shortcut(model.privateOpenMode == .tab ? .newPrivate : .newPrivateTab, model.shortcuts)
            if model.privateOpenMode == .ask { Button("New Private…") { model.newPrivate() }.shortcut(.newPrivate, model.shortcuts) }
            Button("Open Location") { AppCommands.perform("cmd-file-open-location", model) } .shortcut(.openLocation, model.shortcuts)
            Button("Command Palette") { AppCommands.perform("cmd-file-command-palette", model) } .shortcut(.commandPalette, model.shortcuts)
            Divider()
            Button("Close Tab") { AppCommands.perform("cmd-file-close-tab", model) } .shortcut(.closeTab, model.shortcuts)
            Button("Reopen Closed Tab") { AppCommands.perform("cmd-file-reopen-closed-tab", model) } .shortcut(.reopenClosedTab, model.shortcuts).disabled(!AppCommands.isEnabled("cmd-file-reopen-closed-tab", model))
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…") { AppCommands.perform("cmd-file-print", model) } .shortcut(.print, model.shortcuts).disabled(!AppCommands.isEnabled("cmd-file-print", model))
            Button("Save Page as PDF") { AppCommands.perform("cmd-file-save-page-as-pdf", model) }.disabled(!AppCommands.isEnabled("cmd-file-save-page-as-pdf", model))
            Button("Take Screenshot") { AppCommands.perform("cmd-file-take-screenshot", model) }.disabled(!AppCommands.isEnabled("cmd-file-take-screenshot", model))
            Button("Take Full-Page Screenshot") { AppCommands.perform("cmd-file-take-full-page-screenshot", model) }.disabled(!AppCommands.isEnabled("cmd-file-take-full-page-screenshot", model))
            Button("Save Page for Later") { AppCommands.perform("cmd-file-save-page-for-later", model) }.disabled(!AppCommands.isEnabled("cmd-file-save-page-for-later", model))
        }
        CommandMenu("Navigate") {
            Button("Back") { AppCommands.perform("cmd-navigate-back", model) } .shortcut(.back, model.shortcuts)
            Button("Forward") { AppCommands.perform("cmd-navigate-forward", model) } .shortcut(.forward, model.shortcuts)
            Button("Reload") { AppCommands.perform("cmd-navigate-reload", model) } .shortcut(.reload, model.shortcuts)
            Button("Stop") { AppCommands.perform("cmd-navigate-stop", model) } .shortcut(.stop, model.shortcuts)
            Divider()
            Button("Next Tab") { AppCommands.perform("cmd-navigate-next-tab", model) } .shortcut(.nextTab, model.shortcuts)
            Button("Previous Tab") { AppCommands.perform("cmd-navigate-previous-tab", model) } .shortcut(.previousTab, model.shortcuts)
            Button("Switch to Recently Used Tab") { AppCommands.perform("cmd-navigate-switch-to-recently-used-tab", model) } .shortcut(.recentTab, model.shortcuts)
            Button("Switch Forward Through Recent Tabs") { AppCommands.perform("cmd-navigate-switch-forward-through-recent-tabs", model) } .shortcut(.recentTabReverse, model.shortcuts)
        }
        CommandGroup(after: .pasteboard) {
            Button("Paste and Go") { AppCommands.perform("cmd-edit-paste-and-go", model) } .shortcut(.pasteAndGo, model.shortcuts)
            Divider()
            Button("Find in Page…") { AppCommands.perform("cmd-edit-find-in-page", model) } .shortcut(.find, model.shortcuts)
            Button("Find Next") { AppCommands.perform("cmd-edit-find-next", model) } .shortcut(.findNext, model.shortcuts).disabled(!AppCommands.isEnabled("cmd-edit-find-next", model))
            Button("Find Previous") { AppCommands.perform("cmd-edit-find-previous", model) } .shortcut(.findPrevious, model.shortcuts).disabled(!AppCommands.isEnabled("cmd-edit-find-previous", model))
        }
        CommandMenu("Workspace") {
            Button("Personal") { AppCommands.perform("cmd-workspace-personal", model) } .keyboardShortcut("1", modifiers: [.control])
            ForEach(Array(model.workspaces.enumerated()), id: \.element.id) { index, ws in
                if index < 8 { Button(ws.name) { model.switchWorkspace(ws.name) }.keyboardShortcut(KeyEquivalent(Character("\(index + 2)")), modifiers: [.control]) }
                else { Button(ws.name) { model.switchWorkspace(ws.name) } }
            }
            Divider()
            Button("New Workspace…") { AppCommands.perform("cmd-workspace-new-workspace", model) }
        }
        CommandMenu("Split View") {
            Button("New Tab in Split View") { AppCommands.perform("cmd-split-view-new-tab-in-split-view", model) }
            Button("Add a Panel") { AppCommands.perform("cmd-split-view-add-a-panel", model) }.disabled(!AppCommands.isEnabled("cmd-split-view-add-a-panel", model))
            Button("Remove the Last Panel") { AppCommands.perform("cmd-split-view-remove-the-last-panel", model) }.disabled(!AppCommands.isEnabled("cmd-split-view-remove-the-last-panel", model))
            Button("Close Split View") { AppCommands.perform("cmd-split-view-close-split-view", model) }.disabled(!AppCommands.isEnabled("cmd-split-view-close-split-view", model))
            Button("Swap Panels") { AppCommands.perform("cmd-split-view-swap-panels", model) }.disabled(!AppCommands.isEnabled("cmd-split-view-swap-panels", model))
            Button("Change Direction") { AppCommands.perform("cmd-split-view-change-direction", model) }.disabled(!AppCommands.isEnabled("cmd-split-view-change-direction", model))
        }
        CommandMenu("Tools") {
            ToolsMenuItems(model: model)
        }
        // Its own menu, so it is easy to find; the same shortcuts as before.
        CommandMenu("Player") {
            Group {
                Button("Play or Pause") { AppCommands.perform("cmd-player-play-or-pause", model) } .keyboardShortcut(.space, modifiers: [.option])
                Button("Skip Back") { AppCommands.perform("cmd-player-skip-back", model) } .keyboardShortcut(.leftArrow, modifiers: [.option])
                Button("Skip Forward") { AppCommands.perform("cmd-player-skip-forward", model) } .keyboardShortcut(.rightArrow, modifiers: [.option])
                Button("Mute or Unmute") { AppCommands.perform("cmd-player-mute-or-unmute", model) } .keyboardShortcut("m", modifiers: [.option])
                Button("Theater Mode") { AppCommands.perform("cmd-player-theater-mode", model) } .keyboardShortcut("t", modifiers: [.option])
                Divider()
                Button("Player Controls…") { AppCommands.perform("cmd-player-player-controls", model) } .keyboardShortcut("v", modifiers: [.option])
            }
            .disabled(model.active?.isBlank ?? true)
        }
        CommandMenu("Library") {
            Button("Bookmark This Page") { AppCommands.perform("cmd-library-bookmark-this-page", model) } .shortcut(.bookmarkPage, model.shortcuts)
            Button("Show Bookmarks") { AppCommands.perform("cmd-library-show-bookmarks", model) } .shortcut(.showBookmarks, model.shortcuts)
            Button("Show History") { AppCommands.perform("cmd-library-show-history", model) } .shortcut(.showHistory, model.shortcuts)
            Button("Show Downloads") { AppCommands.perform("cmd-library-show-downloads", model) } .shortcut(.showDownloads, model.shortcuts)
            Button("LinkGrabber") { AppCommands.perform("cmd-library-linkgrabber", model) }
            Button("Collect Download Links from This Page") { AppCommands.perform("cmd-library-collect-download-links-from-this-page", model) }
            Button("Find Downloadable Media") { AppCommands.perform("cmd-library-find-downloadable-media", model) }.disabled(!AppCommands.isEnabled("cmd-library-find-downloadable-media", model))
            Button("Explore This Website…") { AppCommands.perform("cmd-library-explore-this-website", model) }.disabled(!AppCommands.isEnabled("cmd-library-explore-this-website", model))
            Button("Download Packages") { AppCommands.perform("cmd-library-download-packages", model) }
            Button("Open Archive from Address…") { AppCommands.perform("cmd-library-open-archive-from-address", model) }
            Button("Collect Images from This Page") { AppCommands.perform("cmd-library-collect-images-from-this-page", model) }.disabled(!AppCommands.isEnabled("cmd-library-collect-images-from-this-page", model))
            Button("Feeds & Podcasts…") { AppCommands.perform("cmd-library-feeds-and-podcasts", model) }
            Button("Remote Files…") { AppCommands.perform("cmd-library-remote-files", model) }
            Button("Repositories & Models…") { AppCommands.perform("cmd-library-repositories-and-models", model) }
            Button("Pause All Downloads") { AppCommands.perform("cmd-library-pause-all-downloads", model) }
            Button("Resume All Downloads") { AppCommands.perform("cmd-library-resume-all-downloads", model) }
            Divider()
            Button("Reading List…") { AppCommands.perform("cmd-library-reading-list", model) }
            Button("Add to Reading List") { AppCommands.perform("cmd-library-add-to-reading-list", model) }.disabled(!AppCommands.isEnabled("cmd-library-add-to-reading-list", model))
            Button("Highlight Selection") { AppCommands.perform("cmd-library-highlight-selection", model) }
            Button("Note for This Page…") { AppCommands.perform("cmd-library-note-for-this-page", model) }.disabled(!AppCommands.isEnabled("cmd-library-note-for-this-page", model))
            Button("Style for This Website…") { AppCommands.perform("cmd-library-style-for-this-website", model) }.disabled(!AppCommands.isEnabled("cmd-library-style-for-this-website", model))
            Button("QR Code for This Page…") { AppCommands.perform("cmd-library-qr-code-for-this-page", model) }.disabled(!AppCommands.isEnabled("cmd-library-qr-code-for-this-page", model))
            Button("Search My Pages…") { AppCommands.perform("cmd-library-search-my-pages", model) }
            Button("Shopping…") { AppCommands.perform("cmd-library-shopping", model) }
            Button("Repair This Page…") { AppCommands.perform("cmd-library-repair-this-page", model) }.disabled(!AppCommands.isEnabled("cmd-library-repair-this-page", model))
            Button("Install as Web App…") { AppCommands.perform("cmd-library-install-as-web-app", model) }.disabled(!AppCommands.isEnabled("cmd-library-install-as-web-app", model))
            Button("Send to Another Device…") { AppCommands.perform("cmd-library-send-to-another-device", model) }
            Button("Share Tabs…") { AppCommands.perform("cmd-library-share-tabs", model) }.disabled(!AppCommands.isEnabled("cmd-library-share-tabs", model))
            Button("Selection Actions…") { AppCommands.perform("cmd-library-selection-actions", model) }.disabled(!AppCommands.isEnabled("cmd-library-selection-actions", model))
            Button("Page Tools…") { AppCommands.perform("cmd-library-page-tools", model) }.disabled(!AppCommands.isEnabled("cmd-library-page-tools", model))
            Button("Copy Clean Link") { AppCommands.perform("cmd-library-copy-clean-link", model) }.disabled(!AppCommands.isEnabled("cmd-library-copy-clean-link", model))
            Button("Translate Page") { AppCommands.perform("cmd-library-translate-page", model) }.disabled(!AppCommands.isEnabled("cmd-library-translate-page", model))
            Divider()
            Button("Privacy Dashboard…") { AppCommands.perform("cmd-library-privacy-dashboard", model) }
            Button("Search Everything…") { AppCommands.perform("cmd-library-search-everything", model) } .keyboardShortcut("k", modifiers: [.command, .option])
            Button("Bookmark Tools…") { AppCommands.perform("cmd-library-bookmark-tools", model) }
            Button("Feeds and Tools…") { AppCommands.perform("cmd-library-feeds-and-tools", model) }
            Button("Saved Sessions…") { AppCommands.perform("cmd-library-saved-sessions", model) }
            Button("Session Time Machine…") { AppCommands.perform("cmd-library-session-time-machine", model) }
            Button("Tab Activity…") { AppCommands.perform("cmd-library-tab-activity", model) }
            Button("Close Duplicate Tabs") { AppCommands.perform("cmd-library-close-duplicate-tabs", model) }.disabled(!AppCommands.isEnabled("cmd-library-close-duplicate-tabs", model))
            Menu("Split View") {
                Toggle("Link Scrolling", isOn: Binding(get: { model.linkedPanes }, set: { model.setLinkedPanes($0) })).disabled(model.splitTabID == nil)
                Button("Compare the Two Pages…") { AppCommands.perform("cmd-library-compare-the-two-pages", model) }.disabled(!AppCommands.isEnabled("cmd-library-compare-the-two-pages", model))
                Button("Reopen Last Split Layout") { AppCommands.perform("cmd-library-reopen-last-split-layout", model) }.disabled(!AppCommands.isEnabled("cmd-library-reopen-last-split-layout", model))
            }
            Menu("Sort Tabs") {
                ForEach(TabSortOrder.allCases) { order in Button(order.title) { model.sortTabs(by: order) } }
            }
            Button("Mute All Tabs Playing Sound") { AppCommands.perform("cmd-library-mute-all-tabs-playing-sound", model) }.disabled(!AppCommands.isEnabled("cmd-library-mute-all-tabs-playing-sound", model))
            Button("Put Idle Groups to Sleep") { AppCommands.perform("cmd-library-put-idle-groups-to-sleep", model) }.disabled(!AppCommands.isEnabled("cmd-library-put-idle-groups-to-sleep", model))
            Menu("Snoozed and Scheduled Tabs") {
                if model.tabSchedules.isEmpty { Text("Nothing waiting") }
                ForEach(model.tabSchedules) { item in
                    Button("\(item.title) · \(item.when.formatted(date: .abbreviated, time: .shortened))\(item.repeats == .once ? "" : " · " + item.repeats.title) (Cancel)") { model.cancelSchedule(item.id) }
                }
            }
            Divider()
            Button("Reader") { AppCommands.perform("cmd-library-reader", model) } .shortcut(.readerMode, model.shortcuts)
            Menu("Reader Text") {
                Button("Larger") { AppCommands.perform("cmd-library-larger", model) }
                Button("Smaller") { AppCommands.perform("cmd-library-smaller", model) }
            }
            Menu("Copy Citation") {
                ForEach(PageCitation.Style.allCases) { style in Button(style.title) { model.copyCitation(style) } }
            }.disabled(model.active?.isBlank ?? true)
            Button("Copy Highlights with Citation") { AppCommands.perform("cmd-library-copy-highlights-with-citation", model) }.disabled(!AppCommands.isEnabled("cmd-library-copy-highlights-with-citation", model))
            Button("Translate Selected Text") { AppCommands.perform("cmd-library-translate-selected-text", model) }.disabled(!AppCommands.isEnabled("cmd-library-translate-selected-text", model))
            Button("Detect Page Language") { AppCommands.perform("cmd-library-detect-page-language", model) }.disabled(!AppCommands.isEnabled("cmd-library-detect-page-language", model))
            Button("Search This Site…") { AppCommands.perform("cmd-library-search-this-site", model) }.disabled(!AppCommands.isEnabled("cmd-library-search-this-site", model))
            Button("Summarize This Page…") { AppCommands.perform("cmd-library-summarize-this-page", model) }.disabled(!AppCommands.isEnabled("cmd-library-summarize-this-page", model))
            Menu("Video Speed") {
                ForEach(VideoControls.speeds, id: \.self) { rate in
                    Toggle(VideoControls.label(rate), isOn: Binding(get: { (model.activeVideoSpeed ?? 1) == rate }, set: { _ in model.setVideoSpeed(rate) }))
                }
            }.disabled(model.active?.isBlank ?? true)
            Button("Picture in Picture") { AppCommands.perform("cmd-library-picture-in-picture", model) }.disabled(!AppCommands.isEnabled("cmd-library-picture-in-picture", model))
            Button("Share Page…") { AppCommands.perform("cmd-library-share-page", model) } .shortcut(.sharePage, model.shortcuts).disabled(!AppCommands.isEnabled("cmd-library-share-page", model))
            Divider()
            Button("Search Tabs") { AppCommands.perform("cmd-library-search-tabs", model) } .shortcut(.searchTabs, model.shortcuts)
            Button("Find in All Tabs…") { AppCommands.perform("cmd-library-find-in-all-tabs", model) } .shortcut(.findAllTabs, model.shortcuts)
            Menu("Recently Closed") {
                ForEach(Array(model.closedTabs.enumerated().reversed().prefix(10)), id: \.offset) { index, closed in
                    Button(closed.title.isEmpty ? displayHost(closed.url) : closed.title) { model.reopenClosedTab(at: index) }
                }
            }
            .disabled(model.closedTabs.isEmpty)
        }
        CommandGroup(after: .sidebar) {
            Button("Toggle Sidebar") { AppCommands.perform("cmd-view-toggle-sidebar", model) } .shortcut(.toggleSidebar, model.shortcuts)
            Button("Show Tab Overview") { AppCommands.perform("cmd-view-show-tab-overview", model) } .shortcut(.tabOverview, model.shortcuts)
            Button("New Tab Group…") { AppCommands.perform("cmd-view-new-tab-group", model) }
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
            Button("Restore Standard Layout") { AppCommands.perform("cmd-view-restore-standard-layout", model) } .shortcut(.restoreLayout, model.shortcuts)
            Button("Zoom In") { AppCommands.perform("cmd-view-zoom-in", model) } .shortcut(.zoomIn, model.shortcuts)
            Button("Zoom Out") { AppCommands.perform("cmd-view-zoom-out", model) } .shortcut(.zoomOut, model.shortcuts)
            Button("Actual Size") { AppCommands.perform("cmd-view-actual-size", model) } .shortcut(.actualSize, model.shortcuts)
        }
    }
}
