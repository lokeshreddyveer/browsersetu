import Foundation

#if os(macOS)
import AppKit
// Every command of the menu bar, once, as data. The in-app command palette and the "All Menu Commands" part of the More menu are made from this list, so a command that is in the
// menu bar can always be reached inside the window too. A test reads the menu bar's source and fails if a command is added there without being added here.

struct AppCommand: Identifiable {
    let id: String
    let section: String
    let title: String
    let symbol: String
    let shortcut: ShortcutAction?
    let isEnabled: @MainActor (BrowserModel) -> Bool
    let run: @MainActor (BrowserModel) -> Void
}

@MainActor
enum AppCommands {
    static var sections: [String] { var seen = Set<String>(); return all.map(\.section).filter { seen.insert($0).inserted } }
    static func commands(in section: String) -> [AppCommand] { all.filter { $0.section == section } }

    static let all: [AppCommand] = generated + extras

    private static let byID: [String: AppCommand] = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    static func command(id: String) -> AppCommand? { byID[id] }
    static func isEnabled(_ id: String, _ model: BrowserModel) -> Bool { byID[id]?.isEnabled(model) ?? false }

    /// The one way a command is run, from the menu bar, the command palette, the More menu and Page Tools alike: a command that is not available right now does not run (returns false).
    @discardableResult
    static func perform(_ command: AppCommand, _ model: BrowserModel) -> Bool {
        guard command.isEnabled(model) else { return false }
        command.run(model)
        return true
    }

    @discardableResult
    static func perform(_ id: String, _ model: BrowserModel) -> Bool {
        guard let command = byID[id] else { return false }
        return perform(command, model)
    }

    private static let generated: [AppCommand] = [
        AppCommand(id: "cmd-browser-setu-settings", section: "Browser Setu", title: "Settings…", symbol: "gearshape", shortcut: nil, isEnabled: { _ in true }) { m in SettingsRouter.open() },
        AppCommand(id: "cmd-file-new-window", section: "File", title: "New Window", symbol: "macwindow", shortcut: nil, isEnabled: { _ in true }) { m in m.windows.onNeedWindow?() },
        AppCommand(id: "cmd-file-new-guest-window", section: "File", title: "New Guest Window", symbol: "person.crop.circle.badge.questionmark", shortcut: nil, isEnabled: { _ in true }) { m in m.openGuestWindow() },
        AppCommand(id: "cmd-file-reopen-closed-window", section: "File", title: "Reopen Closed Window", symbol: "arrow.uturn.backward.circle", shortcut: nil, isEnabled: { m in !(m.windows.closedWindows.isEmpty) }) { m in m.reopenClosedWindow() },
        AppCommand(id: "cmd-file-relaunch-without-extensions", section: "File", title: "Relaunch Without Extensions", symbol: "doc", shortcut: nil, isEnabled: { _ in true }) { m in ExtensionSafeMode.relaunch() },
        AppCommand(id: "cmd-file-move-tab-to-new-window", section: "File", title: "Move Tab to New Window", symbol: "doc", shortcut: nil, isEnabled: { m in !(m.activeID == nil || (m.isSecondary && m.tabs.count < 2) || m.isPrivateWindow) }) { m in if let id = m.activeID { m.moveTabToNewWindow(id) } },
        AppCommand(id: "cmd-file-new-tab", section: "File", title: "New Tab", symbol: "plus", shortcut: .newTab, isEnabled: { _ in true }) { m in m.newTab() },
        AppCommand(id: "cmd-file-new-private-window", section: "File", title: "New Private Window", symbol: "eye.slash.fill", shortcut: nil, isEnabled: { _ in true }) { m in m.openPrivateWindow() },
        AppCommand(id: "cmd-file-new-private-tab", section: "File", title: "New Private Tab", symbol: "eye.slash", shortcut: nil, isEnabled: { _ in true }) { m in m.openTab(url: nil, isPrivate: true) },
        AppCommand(id: "cmd-file-open-location", section: "File", title: "Open Location", symbol: "magnifyingglass", shortcut: .openLocation, isEnabled: { _ in true }) { m in m.focusAddressBar() },
        AppCommand(id: "cmd-file-command-palette", section: "File", title: "Command Palette", symbol: "command", shortcut: .commandPalette, isEnabled: { _ in true }) { m in m.paletteVisible.toggle() },
        AppCommand(id: "cmd-file-close-tab", section: "File", title: "Close Tab", symbol: "xmark", shortcut: .closeTab, isEnabled: { _ in true }) { m in
            #if os(macOS)
            // Close Tab has Command-W, which on a Mac closes whatever window is in front. When that window is not a browser window (Settings in its own window, a panel), it is that window that closes,
            // not a tab of some other window behind it.
            if let w = NSApp.keyWindow, w.identifier?.rawValue.hasPrefix("browser-AppWindow") != true, w.isVisible, w.styleMask.contains(.closable) { w.performClose(nil); return }
            #endif
            if let id = m.activeID { m.closeTab(id: id) } },
        AppCommand(id: "cmd-file-reopen-closed-tab", section: "File", title: "Reopen Closed Tab", symbol: "arrow.uturn.backward", shortcut: .reopenClosedTab, isEnabled: { m in !(m.closedTabs.isEmpty) }) { m in m.reopenClosedTab() },
        AppCommand(id: "cmd-file-print", section: "File", title: "Print…", symbol: "printer", shortcut: .print, isEnabled: { m in !(m.active?.isBlank ?? true) }) { m in m.printActive() },
        AppCommand(id: "cmd-file-save-page-as-pdf", section: "File", title: "Save Page as PDF", symbol: "doc.richtext", shortcut: nil, isEnabled: { m in !(m.active?.isBlank ?? true) }) { m in Task { await m.savePageAsPDF() } },
        AppCommand(id: "cmd-file-take-screenshot", section: "File", title: "Take Screenshot", symbol: "camera.viewfinder", shortcut: nil, isEnabled: { m in !(m.active?.isBlank ?? true) }) { m in Task { await m.takeScreenshot(fullPage: false) } },
        AppCommand(id: "cmd-file-take-full-page-screenshot", section: "File", title: "Take Full-Page Screenshot", symbol: "rectangle.expand.vertical", shortcut: nil, isEnabled: { m in !(m.active?.isBlank ?? true) }) { m in Task { await m.takeScreenshot(fullPage: true) } },
        AppCommand(id: "cmd-file-save-page-for-later", section: "File", title: "Save Page for Later", symbol: "doc", shortcut: nil, isEnabled: { m in !(m.active?.isBlank ?? true) }) { m in Task { await m.savePageForLater() } },
        AppCommand(id: "cmd-navigate-back", section: "Navigate", title: "Back", symbol: "chevron.left", shortcut: .back, isEnabled: { _ in true }) { m in m.active?.goBack() },
        AppCommand(id: "cmd-navigate-forward", section: "Navigate", title: "Forward", symbol: "chevron.right", shortcut: .forward, isEnabled: { _ in true }) { m in m.active?.goForward() },
        AppCommand(id: "cmd-navigate-reload", section: "Navigate", title: "Reload", symbol: "arrow.clockwise", shortcut: .reload, isEnabled: { _ in true }) { m in m.active?.reload() },
        AppCommand(id: "cmd-navigate-stop", section: "Navigate", title: "Stop", symbol: "xmark.circle", shortcut: .stop, isEnabled: { _ in true }) { m in m.active?.stop() },
        AppCommand(id: "cmd-navigate-next-tab", section: "Navigate", title: "Next Tab", symbol: "arrow.left.arrow.right", shortcut: .nextTab, isEnabled: { _ in true }) { m in m.selectAdjacent(1) },
        AppCommand(id: "cmd-navigate-previous-tab", section: "Navigate", title: "Previous Tab", symbol: "arrow.left.arrow.right", shortcut: .previousTab, isEnabled: { _ in true }) { m in m.selectAdjacent(-1) },
        AppCommand(id: "cmd-navigate-switch-to-recently-used-tab", section: "Navigate", title: "Switch to Recently Used Tab", symbol: "arrow.left.arrow.right", shortcut: .recentTab, isEnabled: { _ in true }) { m in m.cycleRecentTab(1) },
        AppCommand(id: "cmd-navigate-switch-forward-through-recent-tabs", section: "Navigate", title: "Switch Forward Through Recent Tabs", symbol: "arrow.left.arrow.right", shortcut: .recentTabReverse, isEnabled: { _ in true }) { m in m.cycleRecentTab(-1) },
        AppCommand(id: "cmd-edit-paste-and-go", section: "Edit", title: "Paste and Go", symbol: "pencil", shortcut: .pasteAndGo, isEnabled: { _ in true }) { m in if let text = NSPasteboard.general.string(forType: .string) {
                    m.addressBar.isEditing = false
                    m.addressBar.clear()
                    m.navigate(input: text)
                } },
        AppCommand(id: "cmd-edit-find-in-page", section: "Edit", title: "Find in Page…", symbol: "magnifyingglass", shortcut: .find, isEnabled: { _ in true }) { m in m.showFind() },
        AppCommand(id: "cmd-edit-find-next", section: "Edit", title: "Find Next", symbol: "pencil", shortcut: .findNext, isEnabled: { m in !(!m.findVisible) }) { m in m.findNext() },
        AppCommand(id: "cmd-edit-find-previous", section: "Edit", title: "Find Previous", symbol: "pencil", shortcut: .findPrevious, isEnabled: { m in !(!m.findVisible) }) { m in m.findNext(backwards: true) },
        AppCommand(id: "cmd-workspace-personal", section: "Workspace", title: "Personal", symbol: "square.grid.2x2", shortcut: nil, isEnabled: { _ in true }) { m in m.switchWorkspace("") },
        AppCommand(id: "cmd-workspace-new-workspace", section: "Workspace", title: "New Workspace…", symbol: "square.grid.2x2", shortcut: nil, isEnabled: { _ in true }) { m in promptNewWorkspace(model: m) },
        AppCommand(id: "cmd-split-view-new-tab-in-split-view", section: "Split View", title: "New Tab in Split View", symbol: "rectangle.split.2x1", shortcut: nil, isEnabled: { _ in true }) { m in m.openSplitNewTab() },
        AppCommand(id: "cmd-split-view-add-a-panel", section: "Split View", title: "Add a Panel", symbol: "rectangle.split.2x1", shortcut: nil, isEnabled: { m in !(m.splitTabID == nil || m.fourthSplitTabID != nil) }) { m in m.addThirdPanelNewTab() },
        AppCommand(id: "cmd-split-view-remove-the-last-panel", section: "Split View", title: "Remove the Last Panel", symbol: "rectangle.split.2x1", shortcut: nil, isEnabled: { m in !(m.thirdSplitTabID == nil) }) { m in m.removeThirdPanel() },
        AppCommand(id: "cmd-split-view-close-split-view", section: "Split View", title: "Close Split View", symbol: "rectangle.split.2x1", shortcut: nil, isEnabled: { m in !(m.splitTabID == nil) }) { m in m.closeSplit() },
        AppCommand(id: "cmd-split-view-swap-panels", section: "Split View", title: "Swap Panels", symbol: "rectangle.split.2x1", shortcut: nil, isEnabled: { m in !(m.splitTabID == nil) }) { m in m.swapSplit() },
        AppCommand(id: "cmd-split-view-change-direction", section: "Split View", title: "Change Direction", symbol: "rectangle.split.2x1", shortcut: nil, isEnabled: { m in !(m.splitTabID == nil) }) { m in m.splitOrientation = m.splitOrientation == .sideBySide ? .stacked : .sideBySide },
        AppCommand(id: "cmd-player-play-or-pause", section: "Player", title: "Play or Pause", symbol: "playpause", shortcut: nil, isEnabled: { m in !(m.active?.isBlank ?? true) }) { m in m.playerQuick(.play) },
        AppCommand(id: "cmd-player-skip-back", section: "Player", title: "Skip Back", symbol: "gobackward.10", shortcut: nil, isEnabled: { m in !(m.active?.isBlank ?? true) }) { m in m.playerQuick(.seekBy, -m.playerStep) },
        AppCommand(id: "cmd-player-skip-forward", section: "Player", title: "Skip Forward", symbol: "goforward.10", shortcut: nil, isEnabled: { m in !(m.active?.isBlank ?? true) }) { m in m.playerQuick(.seekBy, m.playerStep) },
        AppCommand(id: "cmd-player-mute-or-unmute", section: "Player", title: "Mute or Unmute", symbol: "speaker.slash", shortcut: nil, isEnabled: { m in !(m.active?.isBlank ?? true) }) { m in m.playerQuick(.mute) },
        AppCommand(id: "cmd-player-theater-mode", section: "Player", title: "Theater Mode", symbol: "rectangle.expand.vertical", shortcut: nil, isEnabled: { m in !(m.active?.isBlank ?? true) }) { m in m.playerQuick(.theater) },
        AppCommand(id: "cmd-player-player-controls", section: "Player", title: "Player Controls…", symbol: "play.rectangle", shortcut: nil, isEnabled: { m in !(m.active?.isBlank ?? true) }) { m in m.sheet = .pageTools },
        AppCommand(id: "cmd-library-bookmark-this-page", section: "Library", title: "Bookmark This Page", symbol: "star", shortcut: .bookmarkPage, isEnabled: { _ in true }) { m in m.toggleBookmark() },
        AppCommand(id: "cmd-library-show-bookmarks", section: "Library", title: "Show Bookmarks", symbol: "book", shortcut: .showBookmarks, isEnabled: { _ in true }) { m in m.sheet = .bookmarks },
        AppCommand(id: "cmd-library-show-history", section: "Library", title: "Show History", symbol: "clock", shortcut: .showHistory, isEnabled: { _ in true }) { m in m.sheet = .history },
        AppCommand(id: "cmd-library-show-downloads", section: "Library", title: "Show Downloads", symbol: "arrow.down.circle", shortcut: .showDownloads, isEnabled: { _ in true }) { m in m.sheet = .downloads },
        AppCommand(id: "cmd-library-linkgrabber", section: "Library", title: "LinkGrabber", symbol: "books.vertical", shortcut: nil, isEnabled: { _ in true }) { m in m.openLinkGrabber() },
        AppCommand(id: "cmd-library-collect-download-links-from-this-page", section: "Library", title: "Collect Download Links from This Page", symbol: "books.vertical", shortcut: nil, isEnabled: { _ in true }) { m in Task { await m.collectLinksFromCurrentPage() } },
        AppCommand(id: "cmd-library-find-downloadable-media", section: "Library", title: "Find Downloadable Media", symbol: "books.vertical", shortcut: nil, isEnabled: { m in !(m.active?.isBlank ?? true) }) { m in m.discoverMediaOnCurrentPage() },
        AppCommand(id: "cmd-library-explore-this-website", section: "Library", title: "Explore This Website…", symbol: "books.vertical", shortcut: nil, isEnabled: { m in !(m.active?.isBlank ?? true) }) { m in m.exploreCurrentSite() },
        AppCommand(id: "cmd-library-remote-files", section: "Library", title: "Remote Files…", symbol: "externaldrive.connected.to.line.below", shortcut: nil, isEnabled: { _ in true }) { m in m.openRemote() },
        AppCommand(id: "cmd-library-repositories-and-models", section: "Library", title: "Repositories & Models…", symbol: "shippingbox", shortcut: nil, isEnabled: { _ in true }) { m in
            m.openProviders(address: m.active?.url.flatMap { ProviderRoute.recognise($0) != nil ? $0.absoluteString : nil }, fromPrivate: m.active?.leavesNoTrace ?? false) },
        AppCommand(id: "cmd-library-feeds-and-podcasts", section: "Library", title: "Feeds & Podcasts…", symbol: "dot.radiowaves.up.forward", shortcut: nil, isEnabled: { _ in true }) { m in m.openFeeds() },
        AppCommand(id: "cmd-library-collect-images-from-this-page", section: "Library", title: "Collect Images from This Page", symbol: "photo.on.rectangle", shortcut: nil, isEnabled: { m in !(m.active?.isBlank ?? true) }) { m in Task { await m.collectImagesFromCurrentPage() } },
        AppCommand(id: "cmd-library-pause-all-downloads", section: "Library", title: "Pause All Downloads", symbol: "pause.circle", shortcut: nil, isEnabled: { _ in true }) { m in m.engine.downloads.pauseAll() },
        AppCommand(id: "cmd-library-resume-all-downloads", section: "Library", title: "Resume All Downloads", symbol: "play.circle", shortcut: nil, isEnabled: { _ in true }) { m in m.engine.downloads.resumeAll() },
        AppCommand(id: "cmd-library-download-packages", section: "Library", title: "Download Packages", symbol: "books.vertical", shortcut: nil, isEnabled: { _ in true }) { m in m.openPackages() },
        AppCommand(id: "cmd-library-open-archive-from-address", section: "Library", title: "Open Archive from Address…", symbol: "books.vertical", shortcut: nil, isEnabled: { _ in true }) { m in m.openRemoteZip() },
        AppCommand(id: "cmd-library-reading-list", section: "Library", title: "Reading List…", symbol: "books.vertical", shortcut: nil, isEnabled: { _ in true }) { m in m.sheet = .readingList },
        AppCommand(id: "cmd-library-add-to-reading-list", section: "Library", title: "Add to Reading List", symbol: "books.vertical", shortcut: nil, isEnabled: { m in !(m.active?.isBlank ?? true) }) { m in Task { await m.addToReadingList() } },
        AppCommand(id: "cmd-library-highlight-selection", section: "Library", title: "Highlight Selection", symbol: "books.vertical", shortcut: nil, isEnabled: { _ in true }) { m in Task { await m.highlightSelection() } },
        AppCommand(id: "cmd-library-note-for-this-page", section: "Library", title: "Note for This Page…", symbol: "books.vertical", shortcut: nil, isEnabled: { m in !(m.active?.isBlank ?? true) }) { m in m.sheet = .note },
        AppCommand(id: "cmd-library-style-for-this-website", section: "Library", title: "Style for This Website…", symbol: "books.vertical", shortcut: nil, isEnabled: { m in !(m.active?.isBlank ?? true) }) { m in m.sheet = .style },
        AppCommand(id: "cmd-library-qr-code-for-this-page", section: "Library", title: "QR Code for This Page…", symbol: "books.vertical", shortcut: nil, isEnabled: { m in !(m.active?.isBlank ?? true) }) { m in m.sheet = .qr },
        AppCommand(id: "cmd-library-search-my-pages", section: "Library", title: "Search My Pages…", symbol: "books.vertical", shortcut: nil, isEnabled: { _ in true }) { m in m.sheet = .pageSearch },
        AppCommand(id: "cmd-library-shopping", section: "Library", title: "Shopping…", symbol: "books.vertical", shortcut: nil, isEnabled: { _ in true }) { m in m.sheet = .shopping },
        AppCommand(id: "cmd-library-repair-this-page", section: "Library", title: "Repair This Page…", symbol: "books.vertical", shortcut: nil, isEnabled: { m in !(m.active?.isBlank ?? true) }) { m in m.sheet = .repair },
        AppCommand(id: "cmd-library-install-as-web-app", section: "Library", title: "Install as Web App…", symbol: "books.vertical", shortcut: nil, isEnabled: { m in !(m.active?.isBlank ?? true) }) { m in m.sheet = .webApps },
        AppCommand(id: "cmd-library-send-to-another-device", section: "Library", title: "Send to Another Device…", symbol: "books.vertical", shortcut: nil, isEnabled: { _ in true }) { m in m.sheet = .devices },
        AppCommand(id: "cmd-library-share-tabs", section: "Library", title: "Share Tabs…", symbol: "books.vertical", shortcut: nil, isEnabled: { m in !(m.active?.isBlank ?? true) }) { m in m.sheet = .shareTabs },
        AppCommand(id: "cmd-library-selection-actions", section: "Library", title: "Selection Actions…", symbol: "books.vertical", shortcut: nil, isEnabled: { m in !(m.active?.isBlank ?? true) }) { m in m.sheet = .selection },
        AppCommand(id: "cmd-library-page-tools", section: "Library", title: "Page Tools…", symbol: "books.vertical", shortcut: nil, isEnabled: { m in !(m.active?.isBlank ?? true) }) { m in m.sheet = .pageTools },
        AppCommand(id: "cmd-library-copy-clean-link", section: "Library", title: "Copy Clean Link", symbol: "books.vertical", shortcut: nil, isEnabled: { m in !(m.active?.isBlank ?? true) }) { m in m.copyCleanLink() },
        AppCommand(id: "cmd-library-translate-page", section: "Library", title: "Translate Page", symbol: "character.bubble", shortcut: nil, isEnabled: { m in !(m.active?.isBlank ?? true) }) { m in Task { await m.translateOnDevice() } },
        AppCommand(id: "cmd-library-privacy-dashboard", section: "Library", title: "Privacy Dashboard…", symbol: "books.vertical", shortcut: nil, isEnabled: { _ in true }) { m in m.sheet = .dashboard },
        AppCommand(id: "cmd-library-search-everything", section: "Library", title: "Search Everything…", symbol: "books.vertical", shortcut: nil, isEnabled: { _ in true }) { m in m.sheet = .workbench },
        AppCommand(id: "cmd-library-bookmark-tools", section: "Library", title: "Bookmark Tools…", symbol: "books.vertical", shortcut: nil, isEnabled: { _ in true }) { m in m.sheet = .bookmarkTools },
        AppCommand(id: "cmd-library-feeds-and-tools", section: "Library", title: "Feeds and Tools…", symbol: "books.vertical", shortcut: nil, isEnabled: { _ in true }) { m in m.sheet = .toolkit },
        AppCommand(id: "cmd-library-saved-sessions", section: "Library", title: "Saved Sessions…", symbol: "books.vertical", shortcut: nil, isEnabled: { _ in true }) { m in m.sheet = .sessions },
        AppCommand(id: "cmd-library-session-time-machine", section: "Library", title: "Session Time Machine…", symbol: "books.vertical", shortcut: nil, isEnabled: { _ in true }) { m in m.sheet = .timeMachine },
        AppCommand(id: "cmd-library-tab-activity", section: "Library", title: "Tab Activity…", symbol: "books.vertical", shortcut: nil, isEnabled: { _ in true }) { m in m.sheet = .timeline },
        AppCommand(id: "cmd-library-close-duplicate-tabs", section: "Library", title: "Close Duplicate Tabs", symbol: "books.vertical", shortcut: nil, isEnabled: { m in !(m.duplicateGroups().isEmpty) }) { m in m.closeDuplicateTabs() },
        AppCommand(id: "cmd-library-compare-the-two-pages", section: "Library", title: "Compare the Two Pages…", symbol: "books.vertical", shortcut: nil, isEnabled: { m in !(m.splitTabID == nil) }) { m in Task { await m.comparePanels() } },
        AppCommand(id: "cmd-library-reopen-last-split-layout", section: "Library", title: "Reopen Last Split Layout", symbol: "books.vertical", shortcut: nil, isEnabled: { m in !(m.lastSplit == nil) }) { m in m.reopenLastSplit() },
        AppCommand(id: "cmd-library-mute-all-tabs-playing-sound", section: "Library", title: "Mute All Tabs Playing Sound", symbol: "books.vertical", shortcut: nil, isEnabled: { m in !(!m.tabs.contains { $0.playingAudio }) }) { m in m.muteAllPlaying(true) },
        AppCommand(id: "cmd-library-put-idle-groups-to-sleep", section: "Library", title: "Put Idle Groups to Sleep", symbol: "books.vertical", shortcut: nil, isEnabled: { m in !(m.inactiveGroups().isEmpty) }) { m in Task { await m.sleepInactiveGroups() } },
        AppCommand(id: "cmd-library-reader", section: "Library", title: "Reader", symbol: "doc.plaintext", shortcut: .readerMode, isEnabled: { _ in true }) { m in Task { await m.active?.toggleReader() } },
        AppCommand(id: "cmd-library-larger", section: "Library", title: "Larger", symbol: "books.vertical", shortcut: nil, isEnabled: { _ in true }) { m in m.changeReaderSize(by: 2) },
        AppCommand(id: "cmd-library-smaller", section: "Library", title: "Smaller", symbol: "books.vertical", shortcut: nil, isEnabled: { _ in true }) { m in m.changeReaderSize(by: -2) },
        AppCommand(id: "cmd-library-copy-highlights-with-citation", section: "Library", title: "Copy Highlights with Citation", symbol: "books.vertical", shortcut: nil, isEnabled: { m in !(m.active?.readingItemID == nil) }) { m in m.copyHighlights() },
        AppCommand(id: "cmd-library-translate-selected-text", section: "Library", title: "Translate Selected Text", symbol: "books.vertical", shortcut: nil, isEnabled: { m in !(m.active?.isBlank ?? true) }) { m in Task { await m.translateSelection() } },
        AppCommand(id: "cmd-library-detect-page-language", section: "Library", title: "Detect Page Language", symbol: "books.vertical", shortcut: nil, isEnabled: { m in !(m.active?.isBlank ?? true) }) { m in Task { await m.detectPageLanguage() } },
        AppCommand(id: "cmd-library-search-this-site", section: "Library", title: "Search This Site…", symbol: "books.vertical", shortcut: nil, isEnabled: { m in !(m.active?.isBlank ?? true) }) { m in Task { await m.searchThisSite() } },
        AppCommand(id: "cmd-library-summarize-this-page", section: "Library", title: "Summarize This Page…", symbol: "books.vertical", shortcut: nil, isEnabled: { m in !(m.active?.isBlank ?? true) }) { m in m.sheet = .summary },
        AppCommand(id: "cmd-library-picture-in-picture", section: "Library", title: "Picture in Picture", symbol: "pip", shortcut: nil, isEnabled: { m in !(m.active?.isBlank ?? true) }) { m in m.togglePictureInPicture() },
        AppCommand(id: "cmd-library-share-page", section: "Library", title: "Share Page…", symbol: "square.and.arrow.up", shortcut: .sharePage, isEnabled: { m in !(m.active?.isBlank ?? true) }) { m in m.shareActivePage() },
        AppCommand(id: "cmd-library-search-tabs", section: "Library", title: "Search Tabs", symbol: "books.vertical", shortcut: .searchTabs, isEnabled: { _ in true }) { m in if m.tabSearchVisible { m.tabSearchVisible = false; m.tabSearchQuery = "" }
                else {
                    // The list lives in the sidebar, so it has to be on screen.
                    if !m.sidebarVisible { m.pinSidebar() }
                    m.sidebarShowsDownloads = false
                    m.tabSearchVisible = true
                } },
        AppCommand(id: "cmd-library-find-in-all-tabs", section: "Library", title: "Find in All Tabs…", symbol: "books.vertical", shortcut: .findAllTabs, isEnabled: { _ in true }) { m in m.sheet = .findAll },
        AppCommand(id: "cmd-view-toggle-sidebar", section: "View", title: "Toggle Sidebar", symbol: "sidebar.left", shortcut: .toggleSidebar, isEnabled: { _ in true }) { m in m.toggleSidebar() },
        AppCommand(id: "cmd-view-show-tab-overview", section: "View", title: "Show Tab Overview", symbol: "square.on.square", shortcut: .tabOverview, isEnabled: { _ in true }) { m in m.overviewVisible ? m.hideOverview() : m.showOverview() },
        AppCommand(id: "cmd-view-new-tab-group", section: "View", title: "New Tab Group…", symbol: "sidebar.left", shortcut: nil, isEnabled: { _ in true }) { m in promptNewGroup(model: m) },
        AppCommand(id: "cmd-view-restore-standard-layout", section: "View", title: "Restore Standard Layout", symbol: "sidebar.left", shortcut: .restoreLayout, isEnabled: { _ in true }) { m in m.restoreStandardLayout() },
        AppCommand(id: "cmd-view-zoom-in", section: "View", title: "Zoom In", symbol: "plus.magnifyingglass", shortcut: .zoomIn, isEnabled: { _ in true }) { m in m.active?.zoom(by: 0.1) },
        AppCommand(id: "cmd-view-zoom-out", section: "View", title: "Zoom Out", symbol: "minus.magnifyingglass", shortcut: .zoomOut, isEnabled: { _ in true }) { m in m.active?.zoom(by: -0.1) },
        AppCommand(id: "cmd-view-actual-size", section: "View", title: "Actual Size", symbol: "1.magnifyingglass", shortcut: .actualSize, isEnabled: { _ in true }) { m in m.active?.resetZoom() },
        AppCommand(id: "cmd-tools-daily-digest", section: "Tools", title: "Daily Digest", symbol: "newspaper", shortcut: nil, isEnabled: { _ in true }) { m in m.sheet = .digest },
        AppCommand(id: "cmd-tools-feeds-tasks-vault-clipboard", section: "Tools", title: "Feeds, Tasks, Vault, Clipboard…", symbol: "square.grid.2x2", shortcut: nil, isEnabled: { _ in true }) { m in m.sheet = .toolkit },
        AppCommand(id: "cmd-tools-reading-list", section: "Tools", title: "Reading List", symbol: "books.vertical", shortcut: nil, isEnabled: { _ in true }) { m in m.sheet = .readingList },
        AppCommand(id: "cmd-tools-screenshot-and-edit", section: "Tools", title: "Screenshot and Edit…", symbol: "camera.viewfinder", shortcut: nil, isEnabled: { m in !(m.active?.isBlank ?? true) }) { m in Task { await m.startScreenshot(fullPage: false) } },
        AppCommand(id: "cmd-tools-full-page-screenshot-and-edit", section: "Tools", title: "Full-Page Screenshot and Edit…", symbol: "rectangle.expand.vertical", shortcut: nil, isEnabled: { m in !(m.active?.isBlank ?? true) }) { m in Task { await m.startScreenshot(fullPage: true) } },
        AppCommand(id: "cmd-tools-pictures-to-pdf", section: "Tools", title: "Pictures to PDF…", symbol: "photo.on.rectangle.angled", shortcut: nil, isEnabled: { _ in true }) { m in m.sheet = .picturesToPDF },
        AppCommand(id: "cmd-tools-page-as-pdf-and-mark-up", section: "Tools", title: "Page as PDF and Mark Up", symbol: "doc.richtext", shortcut: nil, isEnabled: { m in !(m.active?.isBlank ?? true) }) { m in Task { await m.annotatePageScreenshot() } },
        AppCommand(id: "cmd-tools-auto-scroll-start-or-stop", section: "Tools", title: "Auto Scroll (start or stop)", symbol: "arrow.down.to.line", shortcut: nil, isEnabled: { m in !(m.active?.isBlank ?? true) }) { m in m.toggleAutoScroll() },
        AppCommand(id: "cmd-tools-edit-text-on-the-page-on-or-off", section: "Tools", title: "Edit Text on the Page (on or off)", symbol: "pencil.line", shortcut: nil, isEnabled: { m in !(m.active?.isBlank ?? true) }) { m in if let tab = m.active { m.pageMenu(.editPageText, target: PageMenuTarget(), in: tab) } },
        AppCommand(id: "cmd-tools-reopen-my-last-session", section: "Tools", title: "Reopen My Last Session", symbol: "clock.arrow.circlepath", shortcut: nil, isEnabled: { _ in true }) { m in m.reopenLastSession() },
        AppCommand(id: "cmd-tools-watch-this-page-for-changes", section: "Tools", title: "Watch This Page for Changes", symbol: "eye", shortcut: nil, isEnabled: { m in !(m.active?.isBlank ?? true) }) { m in Task { await m.toggleWatch() } },
        AppCommand(id: "cmd-tools-privacy-grade-for-this-site", section: "Tools", title: "Privacy Grade for This Site", symbol: "checkmark.shield", shortcut: nil, isEnabled: { m in !(m.active?.isBlank ?? true) }) { m in m.privacySheet = .site },
        AppCommand(id: "cmd-tools-all-commands", section: "Tools", title: "All Commands…", symbol: "command", shortcut: nil, isEnabled: { _ in true }) { m in m.openSearchPanel(prefill: ">") },
    ]

    /// The menu bar's toggles and the items it builds from a list, one command each.
    private static let extras: [AppCommand] = {
        var list: [AppCommand] = []
        for n in 1...9 {
            list.append(AppCommand(id: "cmd-view-select-tab-\(n)", section: "View", title: "Select Tab \(n)", symbol: "\(n).square", shortcut: nil, isEnabled: { m in m.tabs.count >= n }) { m in m.selectTab(number: n) })
        }
        for order in TabSortOrder.allCases {
            list.append(AppCommand(id: "cmd-library-sort-tabs-\(order.rawValue)", section: "Library", title: "Sort Tabs: \(order.title)", symbol: "arrow.up.arrow.down", shortcut: nil, isEnabled: { _ in true }) { m in m.sortTabs(by: order) })
        }
        for style in PageCitation.Style.allCases {
            list.append(AppCommand(id: "cmd-library-copy-citation-\(style.rawValue)", section: "Library", title: "Copy Citation: \(style.title)", symbol: "quote.opening", shortcut: nil, isEnabled: { m in !(m.active?.isBlank ?? true) }) { m in m.copyCitation(style) })
        }
        for rate in VideoControls.speeds {
            list.append(AppCommand(id: "cmd-player-speed-\(rate)", section: "Player", title: "Video Speed: \(VideoControls.label(rate))", symbol: "speedometer", shortcut: nil, isEnabled: { m in !(m.active?.isBlank ?? true) }) { m in m.setVideoSpeed(rate) })
        }
        // The menu shows this one only when ⇧⌘N is set to ask; here it is always available, and does what ⇧⌘N does (a window, a tab, or the question).
        list.append(AppCommand(id: "cmd-file-new-private", section: "File", title: "New Private…", symbol: "eye.slash", shortcut: .newPrivate, isEnabled: { _ in true }) { m in m.newPrivate() })
        list.append(AppCommand(id: "cmd-view-focus-mode", section: "View", title: "Enter or Exit Focus Mode", symbol: "rectangle.dashed", shortcut: .focusMode, isEnabled: { _ in true }) { m in m.toggleFocusMode() })
        list.append(AppCommand(id: "cmd-view-request-mobile-website", section: "View", title: "Request Mobile Website", symbol: "iphone", shortcut: nil, isEnabled: { m in !(m.active?.isBlank ?? true) }) { m in m.active?.toggleMobileSite() })
        list.append(AppCommand(id: "cmd-library-link-scrolling", section: "Library", title: "Link Scrolling", symbol: "link", shortcut: nil, isEnabled: { m in m.splitTabID != nil }) { m in m.setLinkedPanes(!m.linkedPanes) })
        list.append(AppCommand(id: "cmd-library-menu-bar-search", section: "Library", title: "Search from the Menu Bar (Control-Option-Space)", symbol: "magnifyingglass.circle", shortcut: nil, isEnabled: { _ in true }) { _ in MenuBarSearch.shared.setOn(!MenuBarSearch.shared.isOn) })
        list.append(AppCommand(id: "cmd-library-recently-closed", section: "Library", title: "Reopen the Most Recently Closed Tab", symbol: "arrow.uturn.backward", shortcut: nil, isEnabled: { m in !m.closedTabs.isEmpty }) { m in m.reopenClosedTab() })
        return list
    }()
}
#endif
