import AppKit
import SwiftUI

// MARK: - Edge reveal

/// Decides when the auto-hidden sidebar appears and when it goes. It is told, many times a second, whether the pointer is on the
/// window's edge or on the sidebar itself (see `PeekPointerTracker`): one small zone on the edge reveals the sidebar after a short
/// dwell, it stays while the pointer is on it or any menu or popover is open, and it hides a moment after the pointer leaves.
@MainActor
final class SidebarPeek: ObservableObject {
    @Published private(set) var revealed = false
    /// How long the pointer must rest on the edge before the sidebar appears, so a pass-through flick never reveals it.
    var dwell: TimeInterval
    /// How long the sidebar stays after the pointer has left it.
    var linger: TimeInterval

    init(dwell: TimeInterval = 0.06, linger: TimeInterval = 0.15) {
        self.dwell = dwell
        self.linger = linger
    }

    private var edgeInside = false
    private var panelInside = false
    private var menuDepth = 0
    private var holds = 0
    private var isEditing = false
    private var pending: DispatchWorkItem?

    func edge(_ inside: Bool) { edgeInside = inside; update() }
    func panel(_ inside: Bool) {
        panelInside = inside
        if inside { edgeInside = false }
        update()
    }
    func menu(_ open: Bool) { menuDepth = max(0, menuDepth + (open ? 1 : -1)); update() }
    func hold(_ open: Bool) { holds = max(0, holds + (open ? 1 : -1)); update() }
    func editing(_ value: Bool) { isEditing = value; update() }

    /// Where the pointer is right now. Only a change does anything, so it is cheap to call often.
    func pointer(inEdge: Bool, inPanel: Bool) {
        if inEdge != edgeInside { edge(inEdge) }
        if inPanel != panelInside { panel(inPanel) }
    }

    /// Show the sidebar briefly so the user can see where it lives (done after leaving full screen).
    func flash(_ duration: TimeInterval = 0.8) {
        pending?.cancel()
        revealed = true
        schedule(after: duration) { [weak self] in self?.update() }
    }

    func reset() {
        pending?.cancel()
        edgeInside = false; panelInside = false
        menuDepth = 0; holds = 0; isEditing = false
        revealed = false
    }

    private func update() {
        pending?.cancel()
        let inside = edgeInside || panelInside
        if inside {
            guard !revealed else { return }
            schedule(after: dwell) { [weak self] in
                guard let self else { return }
                // The sidebar now covers the edge; the pointer tracker reports it as being on the sidebar from here.
                self.edgeInside = false
                self.revealed = true
                self.update()
            }
        } else if revealed && menuDepth == 0 && holds == 0 && !isEditing {
            schedule(after: linger) { [weak self] in self?.revealed = false }
        }
    }

    private func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}

/// Which zone the pointer is in, from its position in the window. Pure, so it can be tested without a window.
enum PeekGeometry {
    /// How far past the window's own edge the pointer may travel (toward the screen edge) while still counting as on the sidebar.
    static let overshoot: CGFloat = 200
    static let verticalOvershoot: CGFloat = 100

    /// `pointer` is in window coordinates (origin at the bottom left, as AppKit reports it). Before the sidebar is shown only the
    /// edge strip counts; once it is shown only the sidebar's own area (and a margin beyond the window) counts.
    static func zones(pointer: CGPoint, windowSize: CGSize, onLeft: Bool, edgeWidth: CGFloat, panelWidth: CGFloat, revealed: Bool)
        -> (inEdge: Bool, inPanel: Bool) {
        let distance = onLeft ? pointer.x : windowSize.width - pointer.x       // from the sidebar's own edge; negative is beyond it
        if revealed {
            let withinHeight = pointer.y >= -verticalOvershoot && pointer.y <= windowSize.height + verticalOvershoot
            return (false, withinHeight && distance <= panelWidth && distance >= -overshoot)
        }
        let withinWindow = pointer.y >= 0 && pointer.y <= windowSize.height
        return (withinWindow && distance <= edgeWidth && distance >= -2, false)
    }
}

/// Feeds the pointer's position to the peek about twenty times a second while the sidebar can appear. It reads the position
/// straight from the window, so it does not depend on view tracking areas, which SwiftUI can rebuild or lose.
struct PeekPointerTracker: NSViewRepresentable {
    let enabled: Bool
    let onLeft: Bool
    let edgeWidth: CGFloat
    let panelWidth: CGFloat
    let peek: SidebarPeek

    final class TrackerView: NSView {
        var config: PeekPointerTracker?
        private var timer: Timer?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            timer?.invalidate(); timer = nil
            guard window != nil else { return }
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            // Also while a menu is open or a drag is running, so the sidebar is never judged on stale information.
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        deinit { timer?.invalidate() }

        private func tick() {
            guard let config, config.enabled, let window else { return }
            // Away from this window (another app, another window in front): the pointer is not on the sidebar.
            guard NSApp.isActive, window.isKeyWindow else { config.peek.pointer(inEdge: false, inPanel: false); return }
            let size = window.contentView?.bounds.size ?? window.frame.size
            let zones = PeekGeometry.zones(pointer: window.mouseLocationOutsideOfEventStream, windowSize: size, onLeft: config.onLeft,
                                           edgeWidth: config.edgeWidth, panelWidth: config.panelWidth, revealed: config.peek.revealed)
            config.peek.pointer(inEdge: zones.inEdge, inPanel: zones.inPanel)
        }
    }

    func makeNSView(context: Context) -> TrackerView { let view = TrackerView(); view.config = self; return view }
    func updateNSView(_ view: TrackerView, context: Context) { view.config = self }
}

/// A thin strip that reports the pointer entering and leaving but never intercepts clicks meant for the page.
struct EdgeHoverZone: NSViewRepresentable {
    let onChange: (Bool) -> Void

    final class ZoneView: NSView {
        var onChange: (Bool) -> Void = { _ in }
        private var area: NSTrackingArea?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let new = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
            addTrackingArea(new)
            area = new
            if let window, window.isKeyWindow {
                let inside = visibleRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
                DispatchQueue.main.async { [weak self] in self?.onChange(inside) }
            }
        }
        override func mouseEntered(with event: NSEvent) { onChange(true) }
        override func mouseExited(with event: NSEvent) { onChange(false) }
    }

    func makeNSView(context: Context) -> ZoneView { let v = ZoneView(); v.onChange = onChange; return v }
    func updateNSView(_ view: ZoneView, context: Context) { view.onChange = onChange }
}

// MARK: - Sidebar surface

extension View {
    /// Quiet, solid sidebar surface (no translucency over the page; honours Reduce Transparency by construction).
    func sidebarSurface() -> some View {
        background(WindowBackdrop())
    }
}

/// The window's own colour. In the sidebar layout it is the system's behind-window blur with a light tint, so the
/// desktop shows through the sidebar and the margin around the page card; NSVisualEffectView drops to a solid
/// colour by itself when Reduce Transparency is on. Every other layout keeps the solid chrome colour.
struct WindowBackdrop: View {
    @EnvironmentObject var model: BrowserModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency || model.themeIsActive {
            // A chosen theme paints the whole window in its own colour. The system's blur lets the desktop show through and washes the colour out, most of all above
            // the page, so a theme is drawn solid everywhere.
            Color.chrome
        } else if model.singleToolbar || model.topBarHidden {
            ZStack {
                BlurBackdrop()
                Color.chrome.opacity(0.55)
            }
        } else {
            // The system's header material behind the toolbar, tinted so it stays calm.
            ZStack {
                BlurBackdrop(material: .headerView)
                Color.chrome.opacity(0.7)
            }
        }
    }
}

private struct BlurBackdrop: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// MARK: - Expanded sidebar

struct SidebarContent: View {
    @EnvironmentObject var model: BrowserModel
    /// Space above the content for the window's traffic lights.
    let topInset: CGFloat

    var body: some View {
        if model.singleToolbar { sidebarLayout }
        else if model.topBarHidden { SidebarLayoutPanel(topInset: topInset, showsAddress: false).accessibilityElement(children: .contain).accessibilityIdentifier("sidebar") }
        else { standard }
    }

    /// The Sidebar layout has its own design: see `SidebarLayoutPanel`.
    private var sidebarLayout: some View {
        SidebarLayoutPanel(topInset: topInset)
            .overlay(alignment: .top) {
                // With no top bar, suggestions drop down from the address field inside the sidebar.
                SuggestionsOverlay(address: model.addressBar)
                    .padding(.top, topInset + 40).padding(.horizontal, 8)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("sidebar")
    }

    private var standard: some View {
        VStack(spacing: 0) {
            // Pin and collapse only mean something where the sidebar can hide itself or shrink to icons: the vertical-tabs layouts and
            // Floating. In Classic it is a panel the toolbar's button opens and closes, so there is nothing to pin, and no header.
            if managesItself { header } else { Color.clear.frame(height: 6) }
            if model.singleToolbar, let tab = model.active { addressRow(tab) }
            // In the Sidebar layout the order is the address field, pinned tabs, then the workspace and its tabs.
            if !model.singleToolbar { SidebarWorkspaceBar() }
            Group {
                if model.sidebarShowsDownloads { SidebarDownloads().transition(.opacity) }
                else if model.tabSearchVisible { TabSearchPanel().transition(.opacity) }
                else if model.effectiveTabLayout == .sidebar { VerticalTabsList().transition(.opacity) }
                else { LibraryList().transition(.opacity) }
            }
            .motion(.easeInOut(duration: 0.18), value: model.sidebarShowsDownloads)
            .motion(.easeInOut(duration: 0.18), value: model.tabSearchVisible)
            if !model.sidebarShowsDownloads { SearchTabsRow() }
            SidebarFooter()
        }
        .overlay(alignment: .top) {
            // With no top bar, suggestions drop down from the address bar inside the sidebar.
            if model.singleToolbar {
                SuggestionsOverlay(address: model.addressBar)
                    .padding(.top, topInset + 40).padding(.horizontal, 8)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar")
    }

    private var managesItself: Bool { model.effectiveTabLayout == .sidebar || model.topBarHidden || model.singleToolbar }

    /// Traffic lights sit at the leading edge of a left sidebar; in single-toolbar mode navigation sits beside them.
    private var lightsInset: CGFloat { (model.sidebarPosition == .left && !model.windowFullScreen) ? 72 : 0 }

    private var header: some View {
        HStack(spacing: 4) {
            if model.singleToolbar, let tab = model.active {
                Color.clear.frame(width: lightsInset, height: 1)
                NavigationButtons(tab: tab, showForward: true, alwaysReload: true, hideReload: true)
            }
            Spacer(minLength: 0)
            // The icon rail is for the other layouts; in Floating the sidebar only comes and goes, or is pinned open.
            if !model.topBarHidden {
                ChromeButton(symbol: "sidebar.squares.left", help: "Collapse to Icons") { model.sidebarRail = true }
            }
            SidebarPinButton()
        }
        .padding(.horizontal, 8)
        .frame(height: topInset)
        .background(WindowDragRegion())
    }

    private func addressRow(_ tab: TabController) -> some View {
        // One field: the site's icon, its name, then the protection shield and reload at the end; the loading line runs along its bottom.
        MacOmnibox(tab: tab, address: model.addressBar, showReload: true, shield: true)
            .padding(.horizontal, 6).padding(.bottom, 8)
    }
}

/// Pins the sidebar open, or lets it hide at the window edge. Pinned shows a filled pin on an accent tile; unpinned shows an outline pin.
/// The choice is saved and wins over auto-hide, also after the app is reopened.
struct SidebarPinButton: View {
    @EnvironmentObject var model: BrowserModel
    @State private var hovering = false

    private var pinned: Bool { model.sidebarVisible && !model.sidebarRail }

    var body: some View {
        Button { model.toggleSidebarPin() } label: {
            Image(systemName: pinned ? "pin.fill" : "pin")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(pinned ? Theme.accent : Color.secondary)
                .rotationEffect(.degrees(pinned ? 0 : 45))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(pinned ? Theme.accent.opacity(0.16) : Color.primary.opacity(hovering ? 0.08 : 0)))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .motion(.easeOut(duration: 0.15), value: pinned)
        .help(pinned ? "Pinned open. Click to let the sidebar hide at the window edge." : "Click to pin the sidebar open.")
        .accessibilityLabel(pinned ? "Unpin sidebar" : "Pin sidebar")
        .accessibilityValue(pinned ? "Pinned open" : "Auto-hides")
        .accessibilityIdentifier(pinned ? "hide-sidebar" : "pin-sidebar")
    }
}

/// The workspace name with its menu (switch, create, rename, manage), and, once there is more than one workspace, a row of small
/// icons to switch with one click.
struct SidebarWorkspaceBar: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        HStack(spacing: 6) {
            WorkspaceMenu()
            if !model.workspaces.isEmpty { WorkspaceDots().transition(.opacity) }
        }
        .padding(.horizontal, 6).padding(.bottom, 8)
        .motion(.easeOut(duration: 0.18), value: model.workspaces.count)
    }
}

/// "Search Tabs", just above the footer: a row that turns into the searchable list of open tabs.
struct SearchTabsRow: View {
    @EnvironmentObject var model: BrowserModel
    @State private var hovering = false

    var body: some View {
        Button {
            model.tabSearchVisible.toggle()
            if !model.tabSearchVisible { model.tabSearchQuery = "" }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).frame(width: 18)
                Text("Search Tabs").font(.system(size: 13))
                Spacer()
                Text(model.shortcuts.combo(for: .searchTabs)?.display ?? "").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .foregroundStyle(model.tabSearchVisible ? Theme.accent : Color.primary.opacity(0.8))
            .padding(.horizontal, 10).frame(height: model.density.smallRowHeight + 4)
            .background(RoundedRectangle(cornerRadius: Radius.tab, style: .continuous)
                .fill(Color.primary.opacity(model.tabSearchVisible ? 0.10 : (hovering ? 0.06 : 0.03))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, 6).padding(.bottom, 4)
        .help("Search open tabs")
        .accessibilityIdentifier("search-tabs-button")
    }
}

/// The searchable list of open tabs. ↑ and ↓ move, Return switches to the highlighted tab (opening its workspace if needed), Esc closes.
struct TabSearchPanel: View {
    @EnvironmentObject var model: BrowserModel
    @FocusState private var focused: Bool
    @State private var selection = 0

    private var results: [TabController] {
        let words = model.tabSearchQuery.split(whereSeparator: \.isWhitespace).map(String.init)
        let pool = model.tabs.filter { $0.isPrivate == model.activeIsPrivate && !$0.isBlank || $0.id == model.activeID }
        let matches = words.isEmpty ? pool : pool.filter { tab in
            let haystack = tab.displayTitle + " " + (tab.url?.absoluteString ?? "")
            return words.allSatisfy { haystack.localizedCaseInsensitiveContains($0) }
        }
        // This workspace's tabs first.
        return matches.filter { $0.workspace == model.activeWorkspace } + matches.filter { $0.workspace != model.activeWorkspace }
    }

    var body: some View {
        let list = results
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("Search open tabs", text: $model.tabSearchQuery)
                    .textFieldStyle(.plain).font(.system(size: 13)).focused($focused)
                    .accessibilityIdentifier("tab-search-field")
                    .onSubmit { activate(list) }
                Button { close() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary).accessibilityLabel("Close") }
                    .buttonStyle(.plain).help("Close")
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: Radius.tab, style: .continuous).fill(Color.primary.opacity(0.08)))
            .padding(.horizontal, 6)
            .onKeyPress(.upArrow) { selection = max(0, selection - 1); return .handled }
            .onKeyPress(.downArrow) { selection = min(max(0, list.count - 1), selection + 1); return .handled }
            .onKeyPress(.escape) { close(); return .handled }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { index, tab in
                            row(tab, selected: index == selection).id(tab.id)
                                .onTapGesture { selection = index; activate(list) }
                        }
                        if list.isEmpty {
                            Text("No open tab matches “\(model.tabSearchQuery)”.").font(.system(size: 12)).foregroundStyle(.secondary).padding(12)
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .onChange(of: selection) { _, new in if list.indices.contains(new) { proxy.scrollTo(list[new].id) } }
            }
        }
        .onAppear { focused = true; selection = 0 }
        .onChange(of: model.tabSearchQuery) { _, _ in selection = 0 }
        .accessibilityIdentifier("tab-search")
    }

    private func row(_ tab: TabController, selected: Bool) -> some View {
        HStack(spacing: 9) {
            TabFavicon(tab: tab, size: 16).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.displayTitle).font(.system(size: 13)).lineLimit(1)
                Text(displayHost(tab.url) + (tab.workspace == model.activeWorkspace ? "" : " · \(tab.workspace.isEmpty ? "Personal" : tab.workspace)"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if tab.id == model.activeID { Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(Theme.accent) }
        }
        .padding(.horizontal, 9).frame(height: model.density.searchResultHeight)
        .background(RoundedRectangle(cornerRadius: Radius.tab, style: .continuous).fill(selected ? Theme.accent.opacity(0.18) : Color.clear))
        .contentShape(Rectangle())
    }

    private func activate(_ list: [TabController]) {
        guard list.indices.contains(selection) else { return }
        let tab = list[selection]
        if tab.workspace != model.activeWorkspace { model.switchWorkspace(tab.workspace) }
        model.select(tab.id)
        close()
    }

    private func close() {
        model.tabSearchVisible = false
        model.tabSearchQuery = ""
    }
}

struct VerticalTabsList: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        let tabs = model.visibleTabs
        let pinned = tabs.filter(\.pinned)
        let regular = tabs.filter { !$0.pinned }
        ScrollView {
            VStack(alignment: .leading, spacing: model.density.rowSpacing) {
                // Pinned tabs: compact icon tiles above everything else. They belong to the workspace they were pinned in,
                // and stay pinned there until unpinned.
                if !pinned.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 38, maximum: 52), spacing: 6)], spacing: 6) {
                        ForEach(pinned) { PinnedTile(tab: $0, selected: $0.id == model.activeID) }
                    }
                    .padding(.bottom, 6)
                    Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5).padding(.horizontal, 4).padding(.bottom, 6)
                }
                if model.singleToolbar {
                    HStack(spacing: 4) {
                        WorkspaceMenu(flat: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.bottom, 2)
                }
                if !model.groupNames.isEmpty { groups }
                ForEach(model.stackedVisible(model.treeVisible(regular))) { VerticalTabRow(tab: $0, selected: $0.id == model.activeID) }
                Button { model.newTab() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .medium)).frame(width: 16)
                        Text("New Tab").font(.system(size: 13))
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9).frame(height: model.density.smallRowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("new-tab-row")
            }
            .padding(.horizontal, 6).padding(.bottom, 8)
            .animation(.easeOut(duration: 0.12), value: model.visibleTabs.map(\.id))
            .animation(.easeOut(duration: 0.18), value: model.density)
        }
        .acceptsDroppedTabs(model)
    }

    private var groups: some View {
        VStack(alignment: .leading, spacing: 1) {
            groupRow("All Tabs", group: "")
            ForEach(model.groupNames, id: \.self) { groupRow($0, group: $0) }
        }
        .padding(.bottom, 8)
    }

    private func groupRow(_ title: String, group: String) -> some View {
        Button { model.selectGroup(group) } label: {
            HStack(spacing: 8) {
                Image(systemName: group.isEmpty ? "square.on.square" : "folder.fill").font(.system(size: 11)).frame(width: 16)
                    .foregroundStyle(group.isEmpty ? Color.secondary : (model.groupColor(group)?.color ?? Color.secondary))
                Text(title).font(.system(size: 12)).foregroundStyle(model.activeGroup == group ? Color.primary : Color.secondary)
                Spacer()
                Text("\(model.tabCount(inGroup: group))").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9).frame(height: model.density.smallRowHeight - 4)
            .background(RoundedRectangle(cornerRadius: Radius.tab, style: .continuous).fill(Color.primary.opacity(model.activeGroup == group ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !group.isEmpty {
                Menu("Colour") {
                    ForEach(GroupColor.allCases) { c in
                        Button { model.setGroupColor(group, c) } label: {
                            if model.groupColor(group) == c { Label(c.title, systemImage: "checkmark") } else { Text(c.title) }
                        }
                    }
                    Divider()
                    Button("No Colour") { model.setGroupColor(group, nil) }
                }
                Button("Rename…") { renameGroup(group) }
                Button("Delete Group", role: .destructive) { model.deleteGroup(group) }
            }
        }
    }

    private func renameGroup(_ group: String) {
        let model = model
        Task { @MainActor in
            if let name = await Dialogs.promptText(title: "Rename Group", message: "New name for “\(group)”.", placeholder: group), !name.isEmpty {
                model.renameGroup(group, to: name)
            }
        }
    }
}

/// Shown instead of tab rows when tabs live in the horizontal strip, so tabs are never listed twice.
struct LibraryList: View {
    @EnvironmentObject var model: BrowserModel

    private var section: SidebarSection { model.sidebarSection == .history ? .history : .bookmarks }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: Binding(get: { section }, set: { model.sidebarSection = $0 })) {
                Text("Bookmarks").tag(SidebarSection.bookmarks)
                Text("History").tag(SidebarSection.history)
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 10).padding(.bottom, 8)
            if section == .history { HistoryView(embedded: true) } else { BookmarksView(embedded: true) }
        }
    }
}

/// The downloads, inside the sidebar in place of the tabs: what is coming in with its progress, then what has finished.
struct SidebarDownloads: View {
    @EnvironmentObject var model: BrowserModel
    var body: some View { SidebarDownloadsList(coordinator: model.downloads) }
}

private struct SidebarDownloadsList: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var coordinator: DownloadCoordinator
    @State private var items: [DownloadItem] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ChromeButton(symbol: "chevron.left", help: "Back to Tabs", identifier: "downloads-back") { model.sidebarShowsDownloads = false }
                Text("Downloads").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Clear") {
                    try? model.core.clearDownloads()
                    coordinator.clearCompleted()
                    reload()
                }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                .disabled(items.isEmpty)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    SidebarDownloadQueue(coordinator: coordinator)
                    ForEach(Array(coordinator.active.values)) { d in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(d.filename).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button { coordinator.cancel(d.id) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).accessibilityLabel("Cancel download") }
                                    .buttonStyle(.plain).help("Cancel")
                            }
                            ProgressView(value: d.fraction).controlSize(.small)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                    ForEach(Array(coordinator.interrupted.values)) { d in
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.arrow.circlepath").font(.system(size: 13)).foregroundStyle(.orange).frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(d.filename).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                                Text("Stopped part-way").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Button("Resume") { coordinator.resume(d.id) }.buttonStyle(.borderless).font(.system(size: 12))
                            Button { coordinator.dismissInterrupted(d.id) } label: { Image(systemName: "xmark").accessibilityLabel("Dismiss") }.buttonStyle(.borderless).help("Remove")
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                    }
                    ForEach(items, id: \.created) { d in
                        HStack(spacing: 10) {
                            Image(systemName: "doc").font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(d.filename).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                                Text(displayHost(URL(string: d.url))).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            if let file = DownloadCoordinator.locate(filename: d.filename) { DownloadFileActions(url: file) }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                    }
                }
                .padding(.vertical, 4)
            }
            .overlay {
                if items.isEmpty && coordinator.active.isEmpty && coordinator.interrupted.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle").font(.system(size: 26)).foregroundStyle(.tertiary)
                        Text("No downloads").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onChange(of: coordinator.completed) { _, _ in reload() }
        .onAppear(perform: reload)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar-downloads")
    }

    private func reload() { items = (try? model.core.listDownloads(limit: 200)) ?? [] }
}

/// The utilities, always in the same places: profile and library on the left, Settings on the right. Pinned tabs and workspaces live
/// above, never down here.
struct SidebarFooter: View {
    @EnvironmentObject var model: BrowserModel
    @State private var arranging = false

    var body: some View {
        VStack(spacing: 4) {
            if model.singleToolbar && !model.workspaces.isEmpty { WorkspaceDots().frame(maxWidth: .infinity).padding(.top, 2) }
            if model.sidebarShowsExtensions && model.extensionCenter.hasExtensions {
                SidebarExtensionList(center: model.extensionCenter)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if !model.webPanels.isEmpty {
                HStack(spacing: 6) {
                    ForEach(model.webPanels) { panel in
                        Button { model.toggleWebPanel(panel.id) } label: {
                            SiteTile(url: panel.url, title: panel.name, size: 22)
                                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.accent, lineWidth: model.openPanelID == panel.id ? 2 : 0).padding(-2))
                        }
                        .buttonStyle(.plain).help("Web panel: \(panel.name)").accessibilityLabel("Web panel \(panel.name)")
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).padding(.top, 2)
            }
            if arranging { editor } else { utilities }
        }
        .motion(.easeOut(duration: 0.22), value: arranging)
    }

    /// Which of the chosen buttons apply right now (the star needs a page, the extensions button needs an extension).
    private var applicable: [SidebarFooterItem] {
        model.sidebarFooter.filter { item in
            switch item {
            case .bookmarkThis: model.singleToolbar
            case .extensions: model.extensionCenter.hasExtensions
            default: true
            }
        }
    }

    /// Up to seven buttons sit in the row; any more are under a "…" button at its end, so the row never gets too cramped.
    private var utilities: some View {
        let items = applicable
        let shown = items.count > 7 ? Array(items.prefix(6)) : items
        let rest = items.count > 7 ? Array(items.dropFirst(6)) : []
        return HStack(spacing: 0) {
            ForEach(shown) { item in
                button(for: item)
                    // Drag a button onto another to put it before that one, right here.
                    .draggable("footer:\(item.rawValue)")
                    .dropDestination(for: String.self) { payload, _ in
                        guard let raw = payload.first, raw.hasPrefix("footer:"), let dragged = SidebarFooterItem(rawValue: String(raw.dropFirst(7))), dragged != item,
                              var list = Optional(model.sidebarFooter), let target = list.firstIndex(of: item) else { return false }
                        animated(.easeOut(duration: 0.2)) {
                            list.removeAll { $0 == dragged }
                            list.insert(dragged, at: min(target, list.count))
                            model.sidebarFooter = list
                        }
                        return true
                    }
            }
            if !rest.isEmpty {
                Menu {
                    ForEach(rest) { item in Button { perform(item) } label: { Label(item.title, systemImage: item.symbol) } }
                } label: { FooterItemLabel(symbol: "ellipsis.circle", label: "More", tint: nil) }
                    .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain).frame(maxWidth: .infinity)
                    .accessibilityLabel("More buttons")
            }
        }
        .contentShape(Rectangle())
        .contextMenu { footerMenu }
        .padding(.horizontal, 6).padding(.vertical, 4)
    }

    // MARK: Customize mode: the row itself becomes editable, with the other buttons in a tray above it, as in Zen and Firefox.

    private var available: [SidebarFooterItem] { SidebarFooterItem.allCases.filter { !model.sidebarFooter.contains($0) } }

    private func editTile(_ item: SidebarFooterItem, inRow: Bool) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: item.symbol).font(.system(size: 14, weight: .regular)).foregroundStyle(inRow ? Theme.accent : Color.secondary)
                .frame(width: 34, height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(inRow ? 0.10 : 0.06)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(inRow ? Theme.accent.opacity(0.5) : Color.primary.opacity(0.1), style: StrokeStyle(lineWidth: 1, dash: inRow ? [3, 3] : [])))
            Button {
                animated(.easeOut(duration: 0.2)) { if inRow { model.sidebarFooter.removeAll { $0 == item } } else { model.sidebarFooter.append(item) } }
            } label: {
                Image(systemName: inRow ? "xmark" : "plus").font(.system(size: 7, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 14, height: 14).background(Circle().fill(inRow ? Color.red.opacity(0.85) : Theme.accent))
            }
            .buttonStyle(.plain).offset(x: 4, y: -4)
            .accessibilityLabel(inRow ? "Remove \(item.title)" : "Add \(item.title)")
        }
        .help(item.title)
        .draggable("footer:\(item.rawValue)") {
            Image(systemName: item.symbol).font(.system(size: 14)).frame(width: 36, height: 34)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.accent, lineWidth: 1.5))
        }
        .dropDestination(for: String.self) { payload, _ in
            guard inRow, let dragged = footerItem(from: payload.first) else { return false }
            place(dragged, before: item)
            return true
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.title)
    }

    private func footerItem(from payload: String?) -> SidebarFooterItem? {
        guard let payload, payload.hasPrefix("footer:") else { return nil }
        return SidebarFooterItem(rawValue: String(payload.dropFirst(7)))
    }

    private func place(_ dragged: SidebarFooterItem, before target: SidebarFooterItem?) {
        animated(.easeOut(duration: 0.2)) {
            var list = model.sidebarFooter
            list.removeAll { $0 == dragged }
            if let target, let index = list.firstIndex(of: target) { list.insert(dragged, at: index) } else { list.append(dragged) }
            model.sidebarFooter = list
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Customize buttons").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Reset") { animated(.easeOut(duration: 0.2)) { model.sidebarFooter = SidebarFooterItem.defaults } }
                    .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(.secondary).disabled(model.sidebarFooter == SidebarFooterItem.defaults)
                Button("Done") { animated(.easeOut(duration: 0.22)) { arranging = false } }
                    .buttonStyle(.plain).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.accent).keyboardShortcut(.defaultAction)
            }
            Text("Drag a button into the row, along it to reorder, or out to take it away.").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            // What can be added; dropping a button here takes it out of the row.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 38), spacing: 6)], alignment: .leading, spacing: 8) {
                ForEach(available) { item in editTile(item, inRow: false) }
            }
            .padding(8).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
            .dropDestination(for: String.self) { payload, _ in
                guard let dragged = footerItem(from: payload.first) else { return false }
                animated(.easeOut(duration: 0.2)) { model.sidebarFooter.removeAll { $0 == dragged } }
                return true
            }
            // The row itself: what is in the sidebar now.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 38), spacing: 6)], alignment: .leading, spacing: 8) {
                ForEach(model.sidebarFooter) { item in editTile(item, inRow: true) }
            }
            .padding(8).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent.opacity(0.08)))
            .dropDestination(for: String.self) { payload, _ in
                guard let dragged = footerItem(from: payload.first) else { return false }
                place(dragged, before: nil)
                return true
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    @ViewBuilder private func button(for item: SidebarFooterItem) -> some View {
        switch item {
        case .profile:
            Menu {
                Picker("Profile", selection: Binding(get: { model.profileName }, set: { model.switchProfile($0) })) {
                    ForEach(model.profiles, id: \.self) { Text($0).tag($0) }
                }
                Divider()
                Button("Manage Profiles…") { SettingsRouter.open(.profiles) }
            } label: { FooterItemLabel(symbol: "person.crop.circle", label: "Profile", tint: nil) }
                .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain).frame(maxWidth: .infinity)
                .help("Profile: \(model.profileName)")
                .accessibilityLabel("Profile \(model.profileName)")
                .accessibilityIdentifier("profile-button")
        case .bookmarkThis:
            FooterItem(symbol: model.activeBookmarked ? "star.fill" : "star", label: "Save", identifier: "bookmark-button",
                       tint: model.activeBookmarked ? .yellow : nil) { perform(item) }
                .disabled(model.active?.isBlank ?? true)
        case .downloads:
            FooterItem(symbol: item.symbol, label: item.title, identifier: "downloads-button", tint: model.dockedPanel == .downloads ? Theme.accent : nil) { perform(item) }
        case .extensions:
            FooterItem(symbol: item.symbol, label: item.title, identifier: "extensions-menu", tint: model.sidebarShowsExtensions ? Theme.accent : nil) { perform(item) }
        case .breakMode:
            FooterItem(symbol: model.breakActive ? "pause.circle.fill" : item.symbol, label: model.breakActive ? "End Break" : item.title, identifier: "break-button",
                       tint: model.breakActive ? Theme.accent : nil) { perform(item) }
        default:
            FooterItem(symbol: item.symbol, label: item.title, identifier: "footer-\(item.rawValue)") { perform(item) }
        }
    }

    private func perform(_ item: SidebarFooterItem) {
        switch item {
        case .history: model.sheet = .history
        case .downloads: model.sheet = .downloads
        case .bookmarks: model.sheet = .bookmarks
        case .bookmarkThis: model.toggleBookmark()
        case .readingList: model.sheet = .readingList
        case .extensions: withAnimation(.easeOut(duration: 0.2)) { model.sidebarShowsExtensions.toggle() }
        case .newTab: model.newTab()
        case .privateTab: model.openTab(url: nil, isPrivate: true)
        case .tabOverview: model.showOverview()
        case .find: model.showFind()
        case .palette: model.paletteVisible = true
        case .breakMode: model.toggleBreakMode()
        case .splitView: if model.splitTabID == nil { model.openSplitNewTab() } else { model.closeSplit() }
        case .timeline: model.sheet = .timeline
        case .sessions: model.sheet = .sessions
        case .dashboard: model.sheet = .dashboard
        case .settings: SettingsRouter.open()
        case .profile: break
        }
    }

    /// Right-click the row: tick the buttons to show.
    @ViewBuilder private var footerMenu: some View {
        ForEach(SidebarFooterItem.allCases) { item in
            Button {
                animated(.easeOut(duration: 0.2)) {
                    if model.sidebarFooter.contains(item) { model.sidebarFooter.removeAll { $0 == item } }
                    else { model.sidebarFooter.append(item) }
                }
            } label: {
                if model.sidebarFooter.contains(item) { Label(item.title, systemImage: "checkmark") } else { Label(item.title, systemImage: item.symbol) }
            }
        }
        Divider()
        Button("Reset to Default") { animated(.easeOut(duration: 0.2)) { model.sidebarFooter = SidebarFooterItem.defaults } }
        Button("Customize Buttons…") { animated(.easeOut(duration: 0.22)) { arranging = true } }
    }
}

/// A footer button: the icon alone; its name shows as a tooltip.
struct FooterItemLabel: View {
    let symbol: String
    let label: String
    let tint: Color?
    @State private var hovering = false

    var body: some View {
        Image(systemName: symbol).font(.system(size: 14, weight: .regular)).symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint ?? Color.primary.opacity(0.8))
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
            .contentShape(Rectangle())
            .help(label)
            .onHover { hovering = $0 }
        .motion(.easeOut(duration: 0.14), value: hovering)
    }
}

/// The extensions in the sidebar, shown when the footer's puzzle-piece icon is clicked: one row each, with its icon and name. A click opens its
/// popup attached to that row; the pin button keeps it in the toolbar of the other layouts.
struct SidebarExtensionList: View {
    @ObservedObject var center: ExtensionCenter

    var body: some View {
        VStack(spacing: 2) {
            ForEach(center.extensions) { info in
                row(info, action: center.actions.first { $0.id == info.id })
            }
            Button { SettingsRouter.open(.extensions) } label: {
                Text("Manage Extensions…").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading).padding(.horizontal, 8).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
    }

    private func row(_ info: ExtensionInfo, action: ExtensionActionItem?) -> some View {
        ExtensionRow(center: center, info: info, action: action)
    }
}

struct ExtensionRow: View {
    @ObservedObject var center: ExtensionCenter
    let info: ExtensionInfo
    let action: ExtensionActionItem?
    @State private var box = FrameBox()
    @State private var hovering = false

    var body: some View {
        let usable = action != nil && action?.enabled == true && info.enabled
        HStack(spacing: 8) {
            Group {
                if let data = action?.icon, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFit().frame(width: 16, height: 16)
                } else {
                    Image(systemName: "puzzlepiece.extension").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 20)
            Text(info.name).font(.system(size: 12.5)).lineLimit(1)
            Spacer(minLength: 4)
            if let badge = action?.badge, !badge.isEmpty { Text(badge).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary) }
            if action != nil {
                Button { center.setPinned(info.id, !center.isPinned(info.id)) } label: {
                    Image(systemName: center.isPinned(info.id) ? "pin.fill" : "pin").font(.system(size: 10))
                        .foregroundStyle(center.isPinned(info.id) ? Theme.accent : Color.secondary)
                }
                .buttonStyle(.plain).opacity(hovering || center.isPinned(info.id) ? 1 : 0)
                .help(center.isPinned(info.id) ? "Unpin from toolbar" : "Pin to toolbar")
            }
        }
        .padding(.horizontal, 8).frame(minHeight: 30)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
        .contentShape(Rectangle())
        .opacity(usable || action == nil ? 1 : 0.5)
        .reportsFrame(box)
        .onHover { hovering = $0 }
        .onTapGesture { if usable { center.noteClick(box.rect); center.perform(actionFor: info.id) } }
        .help(info.name)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(info.name)
        .accessibilityAddTraits(.isButton)
    }
}

struct FooterItem: View {
    let symbol: String
    let label: String
    var identifier: String
    var tint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) { FooterItemLabel(symbol: symbol, label: label, tint: tint) }
            .buttonStyle(.plain)
            .help(label)
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
    }
}

/// One small button per workspace, as a footer switcher.
struct WorkspaceDots: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        HStack(spacing: 2) {
            dot(name: "", icon: "person", title: "Personal")
            ForEach(model.workspaces) { dot(name: $0.name, icon: $0.icon, title: $0.name) }
        }
    }

    private func dot(name: String, icon: String, title: String) -> some View {
        let active = model.activeWorkspace == name
        return Button { model.switchWorkspace(name) } label: {
            Image(systemName: icon).font(.system(size: 11, weight: .medium))
                .foregroundStyle(active ? Color.primary : Color.secondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.primary.opacity(active ? 0.12 : 0)))
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel("Workspace \(title)")
    }
}

// MARK: - Icon rail

struct SidebarRail: View {
    @EnvironmentObject var model: BrowserModel
    let topInset: CGFloat

    var body: some View {
        VStack(spacing: 6) {
            Color.clear.frame(height: topInset).background(WindowDragRegion())
            ChromeButton(symbol: "sidebar.squares.left", help: "Expand Sidebar") { model.sidebarRail = false }
            if model.effectiveTabLayout == .sidebar {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(model.visibleTabs) { RailTab(tab: $0, selected: $0.id == model.activeID) }
                    }
                    .padding(.vertical, 4)
                }
                ChromeButton(symbol: "plus", help: "New Tab") { model.newTab() }
            } else {
                Spacer()
            }
            Divider().padding(.horizontal, 10)
            ChromeButton(symbol: "book", help: "Bookmarks") { model.sheet = .bookmarks }
            ChromeButton(symbol: "clock", help: "History") { model.sheet = .history }
            ChromeButton(symbol: "gearshape", help: "Settings") { SettingsRouter.open() }.padding(.bottom, 8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar-rail")
    }
}

struct RailTab: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController
    let selected: Bool

    var body: some View {
        Button { model.select(tab.id) } label: {
            TabFavicon(tab: tab, size: 20).frame(width: 34, height: 34)
        }
            .buttonStyle(.plain)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(selected ? Color.raised : Color.clear).shadow(color: .black.opacity(selected ? 0.14 : 0), radius: 2, y: 1))
            .contentShape(Rectangle())
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("tab-chip")
            .contextMenu { TabMenuItems(tab: tab) }
            .help(tab.displayTitle)
            .accessibilityLabel(tab.displayTitle)
    }
}

// MARK: - Pinned sidebar (takes space in the layout)

struct SidebarContainer: View {
    @EnvironmentObject var model: BrowserModel
    let topInset: CGFloat
    var availableWidth: CGFloat = 250
    @State private var dragStart: Double?

    var body: some View {
        let width = model.sidebarRail ? sidebarRailWidth : availableWidth
        HStack(spacing: 0) {
            if model.sidebarPosition == .right { handle }
            Group {
                if model.sidebarRail { SidebarRail(topInset: topInset) } else { SidebarContent(topInset: topInset) }
            }
            .frame(width: width)
            .sidebarSurface()
            if model.sidebarPosition == .left { handle }
        }
    }

    private var handle: some View {
        Rectangle().fill(Color.clear).frame(width: 1)
            .overlay(
                Color.clear.frame(width: 8).contentShape(Rectangle())
                    .onHover { inside in if inside && !model.sidebarRail { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            guard !model.sidebarRail else { return }
                            if dragStart == nil { dragStart = model.sidebarWidth }
                            let delta = Double(value.translation.width) * (model.sidebarPosition == .left ? 1 : -1)
                            model.sidebarWidth = clampedSidebarWidth((dragStart ?? 250) + delta)
                        }
                        .onEnded { _ in dragStart = nil })
            )
            .accessibilityLabel("Resize sidebar")
    }
}

// MARK: - Overlay sidebar (revealed from the edge; floats above the page)

/// A strip on the sidebar's inner edge: drag it to make the sidebar wider or narrower. The width is saved and shared with the
/// pinned sidebar and Settings.
struct SidebarResizeHandle: View {
    @EnvironmentObject var model: BrowserModel
    @State private var dragStart: Double?

    var body: some View {
        Color.clear
            .frame(width: 12)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if dragStart == nil { dragStart = model.sidebarWidth }
                    let delta = Double(value.translation.width) * (model.sidebarPosition == .left ? 1 : -1)
                    model.sidebarWidth = clampedSidebarWidth((dragStart ?? 250) + delta)
                }
                .onEnded { _ in dragStart = nil })
            .accessibilityLabel("Resize sidebar")
            .accessibilityIdentifier("sidebar-resize-handle")
    }
}

struct PeekSidebar: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var peek: SidebarPeek
    let topInset: CGFloat

    var body: some View {
        let width = model.sidebarWidth
        // Floats over the page as a rounded card.
        SidebarContent(topInset: topInset)
        .frame(width: width)
        // Right-click works here as in the pinned sidebar, and the sidebar stays out while its menu is open.
        .contentShape(Rectangle())
        .contextMenu { SidebarContextMenu() }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in peek.menu(true) }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in peek.menu(false) }
        // The same surface as the Sidebar layout's pinned sidebar, so the two look exactly alike.
        .background(WindowBackdrop())
        .clipShape(RoundedRectangle(cornerRadius: Radius.floating, style: .continuous))
        .hairline(RoundedRectangle(cornerRadius: Radius.floating, style: .continuous), opacity: 0.10, width: 0.6)
        .overlay(alignment: model.sidebarPosition == .left ? .trailing : .leading) {
            // Straddles the edge, so it can be grabbed from either side of it.
            SidebarResizeHandle().padding(.vertical, 40).offset(x: model.sidebarPosition == .left ? 6 : -6)
        }
        .shadow(color: .black.opacity(0.30), radius: 18, x: model.sidebarPosition == .left ? 4 : -4, y: 4)
        // Close to the window's edge on every side: no wide dark rim, and no empty band where the traffic lights are
        // (they stay hidden in this layout until the pointer reaches the corner).
        .padding(.vertical, 2)
        .padding(model.sidebarPosition == .left ? .leading : .trailing, 2)
        // The sidebar slides in and out; it does not fade.
        .transition(.move(edge: model.sidebarPosition == .left ? .leading : .trailing))
    }
}


/// The queue controls, in the sidebar's compact style.
struct SidebarDownloadQueue: View {
    @ObservedObject var coordinator: DownloadCoordinator
    private var held: Bool { DownloadSchedule.isHeld(until: coordinator.heldUntil) }
    private var hasWork: Bool { !coordinator.active.isEmpty || !coordinator.waiting.isEmpty || !coordinator.interrupted.isEmpty || !coordinator.scheduled.isEmpty }

    var body: some View {
        if hasWork || held {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    if held { Button("Resume All") { coordinator.resumeAll() } } else { Button("Pause All") { coordinator.pauseAll() } }
                    Menu("Hold Until") {
                        Button("In an hour") { coordinator.holdQueue(until: Date().addingTimeInterval(3600)) }
                        Button("2:00 at night") { if let t = DownloadSchedule.nextOccurrence(hour: 2, minute: 0) { coordinator.holdQueue(until: t) } }
                        Button("7:00 in the morning") { if let t = DownloadSchedule.nextOccurrence(hour: 7, minute: 0) { coordinator.holdQueue(until: t) } }
                        Divider()
                        Button("Until I resume") { coordinator.holdQueue(until: .distantFuture) }
                    }.menuStyle(.borderlessButton).fixedSize()
                    Spacer(minLength: 0)
                }
                .buttonStyle(.borderless).font(.system(size: 12))
                if held { Text(coordinator.heldUntil == .distantFuture ? "Held until you resume" : "Held until \(coordinator.heldUntil.map { $0.formatted(date: .omitted, time: .shortened) } ?? "")").font(.system(size: 11)).foregroundStyle(.secondary) }
                ForEach(coordinator.waiting) { item in
                    HStack(spacing: 6) {
                        Image(systemName: "hourglass").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 18)
                        Text(item.filename).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        Menu(item.priority.title) { ForEach(DownloadPriority.allCases.reversed()) { p in Button(p.title) { coordinator.setPriority(item.id, p) } } }.menuStyle(.borderlessButton).fixedSize()
                        Button { coordinator.cancelWaiting(item.id) } label: { Image(systemName: "xmark").accessibilityLabel("Cancel download") }.buttonStyle(.borderless)
                    }
                }
                ForEach(coordinator.scheduled) { item in
                    HStack(spacing: 6) {
                        Image(systemName: "clock").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 18)
                        Text(item.filename).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        Button { coordinator.removeScheduled(item.id) } label: { Image(systemName: "xmark").accessibilityLabel("Remove from schedule") }.buttonStyle(.borderless)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }
}
