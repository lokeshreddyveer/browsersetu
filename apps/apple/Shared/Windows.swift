import SwiftUI

/// The windows of one browser. Each window has its own `BrowserModel` (its tabs, selected tab, workspace, layout and sheets); they all share one database, one
/// WebKit engine, one set of privacy rules and one extension runtime, which belong to the first window.
@MainActor
final class WindowRegistry {
    private struct Box { weak var model: BrowserModel? }
    private var boxes: [Box] = []
    weak var primary: BrowserModel?
    weak var focused: BrowserModel?
    /// The first window has claimed the app's main model; later ones make their own.
    var primaryClaimed = false
    /// Set by the screen: opens one more window, which claims the next entry of `pendingRestores`.
    var onNeedWindow: (() -> Void)?
    /// Tabs the next window to open should take from the window that asked for it.
    var movingTabs: [UInt64] = []
    /// Tabs (by id) that belonged to each extra window when the app was last closed; the windows are opened again and take them back.
    var pendingRestores: [[UInt64]] = []

    var all: [BrowserModel] { boxes.compactMap(\.model) }
    var count: Int { all.count }
    func add(_ model: BrowserModel) { boxes.removeAll { $0.model == nil || $0.model === model }; boxes.append(Box(model: model)); if primary == nil { primary = model } }
    func remove(_ model: BrowserModel) { boxes.removeAll { $0.model == nil || $0.model === model }; if focused === model { focused = nil } }
    func others(of model: BrowserModel) -> [BrowserModel] { all.filter { $0 !== model } }

    func model(forTab id: UInt64) -> BrowserModel? { all.first { $0.tabs.contains { $0.id == id } } }
    var allTabs: [TabController] { all.flatMap(\.tabs) }
    func anotherWindowHasPrivateTabs(besides model: BrowserModel) -> Bool { others(of: model).contains { $0.tabs.contains(where: \.isPrivate) } }

    /// Settings that mean the same in every window. Everything else (layout, sidebar, focus mode, toolbar) belongs to one window.
    static let sharedSettingKeys: Set<String> = [
        "appearance", "accent", "theme", "theme_custom", "density", "workspaces", "dark_pages", "dark_sites", "website_appearance", "site_appearance", "site_zoom",
        "site_styles", "site_notes", "bookmark_tags", "group_colors", "favorites_order", "search_template", "search_suggestions", "search_shortcuts", "homepage", "startup",
        "strip_tracking", "app_links", "app_link_sites", "permission_expiry", "show_favorites", "show_continue", "show_frequent", "show_greeting", "show_recently_closed",
        "start_background", "shortcuts", "organize_downloads", "download_concurrent", "save_logins", "spotlight_bookmarks",
    ]

    /// Tells the other windows that a setting changed, so what they show follows (their own layouts are left alone).
    func settingChanged(_ key: String, in source: BrowserModel) {
        guard Self.sharedSettingKeys.contains(key), count > 1 else { return }
        for other in others(of: source) { other.reloadSharedSettings() }
    }
}

extension BrowserModel {
    /// The windows other than this one, with what each is showing, for "Move Tab to Window".
    var otherWindows: [(model: BrowserModel, title: String)] {
        windows.others(of: self).map { ($0, $0.active?.displayTitle.nonEmpty ?? "Window") }
    }

    /// Re-reads the shared settings from the database, then puts back what belongs to this window alone: its layout, its workspace and group, its closed tabs.
    func reloadSharedSettings() {
        let workspace = activeWorkspace, group = activeGroup, closed = closedTabs
        #if os(macOS)
        let layout = layoutSnapshot()
        #endif
        loadUISettings()
        activeWorkspace = workspaces.contains { $0.name == workspace } ? workspace : ""
        activeGroup = group
        closedTabs = closed
        #if os(macOS)
        apply(layout)
        #endif
        objectWillChange.send()
    }

    /// Moves a tab to another window. Nothing is reloaded: the same page, with its history and scroll position, simply appears in the other window.
    @discardableResult
    func moveTab(_ id: UInt64, to target: BrowserModel) -> Bool {
        guard target !== self, windows === target.windows, let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
        let tab = tabs.remove(at: index)
        let wasActive = id == activeID
        if splitTabID == id { splitTabID = nil }
        let meta = tabMeta.removeValue(forKey: id)
        saveTabMeta()
        if wasActive || active == nil {
            let neighbours = visibleTabs
            if let next = neighbours.first(where: { _ in true }) ?? tabs.first {
                select((neighbours.indices.contains(min(index, neighbours.count - 1)) && !neighbours.isEmpty ? neighbours[min(index, neighbours.count - 1)] : next).id)
            } else if isSecondary { activeID = nil } else { _ = newTab() }
        }
        target.adopt(tab, meta: meta)
        if isSecondary, tabs.isEmpty { onWindowShouldClose?() }
        saveSoon()
        windows.saveWindowLayout(in: self)
        return true
    }

    /// Takes a tab that another window gave up. It joins this window's current workspace and group, so it is shown here.
    func adopt(_ tab: TabController, meta: TabMeta?) {
        tab.reassign(to: self)
        if !activeWorkspace.isEmpty || tab.workspace != "" { try? core.setTabWorkspace(tabId: tab.id, workspace: activeWorkspace); tab.workspace = activeWorkspace }
        if tab.group != activeGroup, !tab.isPrivate { try? core.setTabGroup(tabId: tab.id, group: activeGroup); tab.group = activeGroup }
        tabs.append(tab)
        if let meta { tabMeta[tab.id] = meta; saveTabMeta() }
        select(tab.id)
        saveSoon()
    }

    /// A new extra window has appeared: it takes the tab it was opened for, or the tabs it held at the last quit, or starts with a blank tab.
    func startSecondaryWindow() {
        guard isSecondary, !hasStarted else { return }
        hasStarted = true
        if lifecycle == nil { let manager = TabLifecycle(model: self); manager.start(); lifecycle = manager }
        var wanted: [UInt64] = []
        if !windows.movingTabs.isEmpty { wanted = windows.movingTabs; windows.movingTabs = [] }
        else if !windows.pendingRestores.isEmpty { wanted = windows.pendingRestores.removeFirst() }
        var adopted = 0
        for id in wanted {
            guard let source = windows.model(forTab: id), source !== self else { continue }
            if source.moveTab(id, to: self) { adopted += 1 }
        }
        if adopted == 0 { _ = openTab(url: nil, isPrivate: false) }
        windows.saveWindowLayout(in: self)
    }

    /// The person closed this window: its tabs close with it (they can be reopened from Recently Closed), and the window leaves the list.
    /// This waits one turn of the run loop before it acts. When the whole app is quitting, every window closes at once and the process ends first, so the saved list of
    /// windows (and which tabs each held) is left as it was and the windows come back at the next start.
    func windowWillClose() {
        guard isSecondary else { return }
        Task { @MainActor [weak self] in
            guard let self, windows.all.contains(where: { $0 === self }) else { return }
            onWindowShouldClose = nil
            for tab in tabs { closeTab(id: tab.id, force: true) }
            windows.remove(self)
            windows.saveWindowLayout(in: self)
            lifecycle?.stop(); lifecycle = nil
        }
    }

    /// Opens a new window and moves the tab into it.
    func moveTabToNewWindow(_ id: UInt64) {
        guard tabs.contains(where: { $0.id == id }), tabs.count > 1 || !isSecondary else { return }
        windows.movingTabs = [id]
        windows.onNeedWindow?()
    }
}

extension WindowRegistry {
    /// The first window's tabs that other windows hold, remembered so a restart can give each window its tabs back.
    func saveWindowLayout(in model: BrowserModel) {
        guard let primary else { return }
        let groups = all.filter { $0 !== primary }.map { $0.tabs.map(\.id) }.filter { !$0.isEmpty }
        model.saveSetting("window_tabs", model.encodedMap(["groups": groups]))
    }

    func loadPendingRestores(from model: BrowserModel) {
        let stored = BrowserModel.decodeMap((try? model.core.getSetting(key: "window_tabs")) ?? nil, as: [[UInt64]].self)["groups"] ?? []
        pendingRestores = stored.prefix(8).map { $0 }
    }
}

private extension String { var nonEmpty: String? { isEmpty ? nil : self } }
