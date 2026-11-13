import AppKit
import SwiftUI

/// The sidebar of the Sidebar layout, where there is no top bar at all: the window's traffic lights sit at the top left of this panel and
/// everything else is here, top to bottom: navigation, the address field, pinned sites, the workspace, the open tabs, then the library
/// buttons. The page sits beside it as one rounded card.
struct SidebarLayoutPanel: View {
    @EnvironmentObject var model: BrowserModel
    /// Height of the header row: the traffic lights live in it.
    let topInset: CGFloat
    /// The Floating layout has its own pill for the address and navigation, so there the sidebar is only the pin, workspace, tabs and library.
    var showsAddress = true
    /// The Hybrid arrangement: vertical tabs under a separate toolbar. The header carries only the collapse button (the window buttons are on its left, always on screen), pinned tabs are rows, and the footer is the same customizable one as the Sidebar layout's.
    var hybrid = false
    /// Workspace Deck: every workspace is listed at the top of the sidebar (the selected one highlighted), instead of the compact selector.
    var workspaceDeck = false

    /// The traffic lights are hidden in this layout (they come back when the pointer is in the window's top-left corner), so nothing is
    /// reserved for them: the buttons start at the edge.
    private var lightsInset: CGFloat { ((hybrid || lightsShown) && model.sidebarPosition == .left && !model.windowFullScreen) ? LayoutMetrics.sidebarLights : 0 }
    @State private var lightsShown = TrafficLightsState.shown
    /// Knows whether the tab in front has scrolled out of view, to offer the way back to it.
    @StateObject private var locator = TabVisibilityCoordinator()
    /// The panel's own height, read only when it changes, so the Essentials can take less room in a short window.
    @State private var panelHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            if showsAddress, let tab = model.active {
                MacOmnibox(tab: tab, address: model.addressBar, showReload: false, shield: true)
                    .padding(.horizontal, 10).padding(.bottom, 10)
            }
            // The workspace, one row below the address field: its name and a menu of the others. (It used to be a list of every workspace, three rows tall, with the same switcher again in the footer.)
            if workspaceDeck { WorkspaceDeckList(maxRows: panelHeight > 0 && panelHeight < SidebarEssentialsBlock.shortPanel ? 3 : 6).padding(.horizontal, 10) } else { SidebarWorkspaceHeader(hybrid: hybrid).padding(.horizontal, 10) }
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1).padding(.horizontal, 12).padding(.vertical, 6)
            // Fixed above the list: the search row and the Essentials (at most two rows, or one in a short window, scrolling inside themselves when there are more).
            // Pinned tabs, open tabs and groups are the one scrolling area below them.
            if !model.sidebarShowsDownloads {
                SearchTabsRow().padding(.horizontal, 12)
                SidebarEssentialsBlock(rows: panelHeight > 0 && panelHeight < SidebarEssentialsBlock.shortPanel ? 1 : 2).padding(.horizontal, 12)
            }
            Group {
                if model.sidebarShowsDownloads { SidebarDownloads().transition(.opacity) }
                else if model.tabSearchVisible { TabSearchPanel().transition(.opacity) }
                else { tabsArea.transition(.opacity) }
            }
            .motion(.easeInOut(duration: 0.18), value: model.sidebarShowsDownloads)
            .motion(.easeInOut(duration: 0.18), value: model.tabSearchVisible)
            SidebarFooter()
        }
        .inactiveWindowDimming()
        .background { if model.isPrivateWindow { PrivateWindowTintLayer() } }
        .background(GeometryReader { g in Color.clear.preference(key: SidebarPanelHeightKey.self, value: g.size.height) })
        .onPreferenceChange(SidebarPanelHeightKey.self) { panelHeight = $0 }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 2) {
            Color.clear.frame(width: lightsInset, height: 1)
            // The sidebar's own button, in the corner: it hides the sidebar to the window edge and docks it again (the Floating layout keeps its pin at the other end).
            if showsAddress || hybrid { SidebarToggleButton() }
            Spacer(minLength: 0)
            if showsAddress, let tab = model.active {
                ChromeButton(symbol: "chevron.left", help: "Back", identifier: "back-button") { tab.goBack() }.disabled(!tab.canGoBack)
                    .contextMenu { NavHistoryItems(tab: tab, back: true) }
                ChromeButton(symbol: "chevron.right", help: "Forward", identifier: "forward-button") { tab.goForward() }.disabled(!tab.canGoForward)
                    .contextMenu { NavHistoryItems(tab: tab, back: false) }
                ChromeButton(symbol: tab.isLoading ? "xmark" : "arrow.clockwise", help: tab.isLoading ? "Stop" : "Reload", identifier: "reload-button") {
                    tab.isLoading ? tab.stop() : tab.reload()
                }
                .disabled(tab.isBlank)
            }
            if hybrid || showsAddress {
                Menu {
                    Button("Collapse to Icons", systemImage: "sidebar.squares.left") { model.sidebarRail = true }
                    Divider()
                    SidebarContextMenu()
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain)
                .help("Sidebar options").accessibilityLabel("Sidebar options").accessibilityIdentifier("sidebar-options")
            } else if !showsAddress { SidebarPinButton() }
        }
        .padding(.horizontal, 8)
        .frame(height: topInset)
        .background(WindowDragRegion())
        .onAppear { lightsShown = TrafficLightsState.shown }
        .onReceive(NotificationCenter.default.publisher(for: .trafficLightsVisibility)) { note in
            animated(.easeOut(duration: 0.2)) { lightsShown = (note.userInfo?["shown"] as? Bool) ?? false }
        }
    }

    // MARK: Search, pinned, open tabs, groups

    /// Every tab of this workspace, whichever group it is in: the groups are sections here, so they can all be seen at once.
    private var workspaceTabs: [TabController] {
        model.listedTabs(inWorkspace: model.activeWorkspace).filter { !model.separatesPrivate || $0.isPrivate == model.privateMode }
    }

    private var tabsArea: some View {
        let all = workspaceTabs
        let pinned = all.filter(\.pinned)
        let open = all.filter { !$0.pinned && $0.group.isEmpty }
        // The order the arrow keys walk: pinned tabs, the open tabs as listed, then each open group's tabs.
        let order: [UInt64] = pinned.map(\.id) + model.stackedVisible(model.treeVisible(open)).map(\.id)
            + model.groupNames.filter { !collapsed.contains($0) }.flatMap { name in model.stackedVisible(model.treeVisible(all.filter { !$0.pinned && $0.group == name })).map(\.id) }
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    pinnedSection(pinned)
                    openSection(open)
                    groupsSection(all)
                }
                .padding(.horizontal, 12).padding(.top, 2).padding(.bottom, 14)
                .motion(.easeOut(duration: 0.18), value: all.map(\.id))
                .motion(.easeOut(duration: 0.18), value: collapsed)
            }
            .tracksTabVisibility(locator, in: TabListSpace.name)
            .tabLocator(locator) { reveal(proxy, animate: true) }
            // The list opens with the selected tab in view (with many tabs it used to start at the top, the tab far below), and keeps it in view when another is chosen from elsewhere.
            .onAppear { DispatchQueue.main.async { reveal(proxy, animate: false) } }
            .onChange(of: model.activeID) { _, _ in reveal(proxy, animate: true, onlyIfHidden: true) }
            // Arrow keys move a ring through the rows, and the list follows it.
            .environment(\.tabStripFocus, $focusedTab)
            .environment(\.tabStripOrder, order)
            .environment(\.tabStripVertical, true)
            .onChange(of: focusedTab) { _, id in if let id { animated(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } } }
        }
    }

    @FocusState private var focusedTab: UInt64?

    /// Scrolls the selected tab (or its Essentials tile) into view. `onlyIfHidden` leaves the list alone while the tab is on screen, so choosing a visible row does not move the list.
    private func reveal(_ proxy: ScrollViewProxy, animate: Bool, onlyIfHidden: Bool = false) {
        guard let active = model.active else { return }
        if onlyIfHidden, locator.location == .visible { return }
        // A tab inside a folded group cannot be scrolled to; the group is opened first.
        if !active.group.isEmpty, collapsed.contains(active.group) { model.collapsedGroups.remove(active.group) }
        func scroll() {
            // An Essential is in the fixed block above the list, not in it.
            if model.essentialRecord(for: active) == nil { proxy.scrollTo(active.id, anchor: .center) }
        }
        if animate { animated(.easeInOut(duration: 0.3)) { scroll() } } else { scroll() }
    }

    // Pinned

    private func pinnedSection(_ pinned: [TabController]) -> some View { pinnedTiles(pinned) }

    private func pinnedTiles(_ pinned: [TabController]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SidebarSectionLabel("Pinned")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                ForEach(pinned) { SidebarPinnedTile(tab: $0, selected: $0.id == model.activeID).environment(\.tabDropPins, true).trackedWhenSelected($0.id == model.activeID, in: TabListSpace.name) }
                SidebarPinCurrentTile()
            }
        }
        // A tab dropped anywhere on the pinned section (a gap, the label, the last tile) is pinned.
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let dragged = UInt64(raw) else { return false }
            return model.acceptDroppedTabToPin(dragged)
        }
    }

    // Open tabs

    private func openSection(_ open: [TabController]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SidebarSectionLabel("Open Tabs") { _ = model.newTab() } help: { "New Tab" }
            VStack(spacing: 2) {
                ForEach(model.stackedVisible(model.treeVisible(open))) { SidebarTabRow(tab: $0, selected: $0.id == model.activeID).trackedWhenSelected($0.id == model.activeID, in: TabListSpace.name) }
            }
            .environment(\.tabDropUnpins, true)
        }
        // A tab dragged here from another window comes into this one.
        .acceptsDroppedTabs(model)
    }

    // Groups

    /// Folded groups: the model's, so a fold is kept across a rail, a peek, a workspace switch and a relaunch, and matches the horizontal strips.
    private var collapsed: Set<String> { model.collapsedGroups }

    @ViewBuilder private func groupsSection(_ all: [TabController]) -> some View {
        if !model.groupNames.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                SidebarSectionLabel("Tab Groups") { promptNewGroup(model: model) } help: { "New Tab Group" }
                ForEach(model.groupNames, id: \.self) { name in
                    let members = all.filter { !$0.pinned && $0.group == name }
                    let isCollapsed = collapsed.contains(name)
                    SidebarGroupHeader(name: name, count: members.count, collapsed: isCollapsed, containsActive: members.contains { $0.id == model.activeID }) {
                        if isCollapsed { model.collapsedGroups.remove(name) } else { model.collapsedGroups.insert(name) }
                    }
                    if !isCollapsed {
                        VStack(spacing: 2) {
                            // The same tree nesting and stack folding as the open tabs: a tab looks the same in a group as outside it.
                            ForEach(model.stackedVisible(model.treeVisible(members))) { SidebarTabRow(tab: $0, selected: $0.id == model.activeID).trackedWhenSelected($0.id == model.activeID, in: TabListSpace.name) }
                        }
                        .padding(.leading, 12)
                        .environment(\.tabDropUnpins, true)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
    }
}

/// The sidebar button in the corner of the Sidebar layout: a sidebar glyph (not a pin) that hides the sidebar to the window edge, and docks it open again. The same action as the pin it replaces
/// (`toggleSidebarPin`), under the same accessibility identifiers.
struct SidebarToggleButton: View {
    @EnvironmentObject var model: BrowserModel
    @State private var hovering = false

    private var docked: Bool { model.sidebarIsPinned }

    var body: some View {
        Button { model.toggleSidebarPin() } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(docked ? Color.primary.opacity(0.75) : Theme.accent)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .motion(.easeOut(duration: 0.15), value: docked)
        .help(docked ? "Hide the sidebar. It comes back at the window edge." : "Keep the sidebar open.")
        .accessibilityLabel(docked ? "Hide sidebar" : "Show sidebar")
        .accessibilityValue(docked ? "Open" : "Hidden at the window edge")
        .accessibilityIdentifier(docked ? "hide-sidebar" : "pin-sidebar")
    }
}

/// The current workspace as one row: its icon and name, how many tabs it holds, and a menu to switch, add, rename or delete.
struct SidebarWorkspaceHeader: View {
    @EnvironmentObject var model: BrowserModel
    /// Hybrid: a secondary click opens the same actions, and deleting a workspace asks first (its tabs are kept, in Personal).
    var hybrid = false
    @State private var hovering = false

    private var title: String { model.activeWorkspace.isEmpty ? "Personal" : model.activeWorkspace }
    private var icon: String { model.activeWorkspace.isEmpty ? "person.fill" : (model.workspaces.first { $0.name == model.activeWorkspace }?.icon ?? "person") }

    /// Switch, create and manage: the one list of actions, used by the menu and by a secondary click.
    @ViewBuilder private var workspaceActions: some View {
            Button { model.switchWorkspace("") } label: {
                if model.activeWorkspace.isEmpty { Label("Personal", systemImage: "checkmark") } else { Text("Personal") }
            }
            ForEach(model.workspaces) { workspace in
                Button { model.switchWorkspace(workspace.name) } label: {
                    if model.activeWorkspace == workspace.name { Label(workspace.name, systemImage: "checkmark") } else { Text(workspace.name) }
                }
            }
            Divider()
            Button("New Workspace…") { promptNewWorkspace(model: model) }
            if !model.activeWorkspace.isEmpty {
                Button("Rename…") { promptRenameWorkspace(model: model, name: model.activeWorkspace) }
                Button("Delete…", role: .destructive) { confirmDeleteWorkspace(model: model, name: model.activeWorkspace) }
            }
    }

    var body: some View {
        Menu {
            workspaceActions
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 13, weight: .medium)).symbolRenderingMode(.hierarchical).frame(width: 20).foregroundStyle(Theme.accent)
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                Text("\(model.workspaceTabCount(model.activeWorkspace))").font(.system(size: 11)).foregroundStyle(.tertiary)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9).frame(maxWidth: .infinity).frame(height: 34)
            .modifier(SidebarFill(selected: false, hovering: hovering, radius: 10, rest: 0, hover: 0.07, selection: 0))
            .contentShape(Rectangle())
        }
        // The plain button style lets the label take the whole row (the borderless menu style shrank it to its text and centred it).
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .frame(maxWidth: .infinity)
        .onHover { hovering = $0 }
        .contextMenu { workspaceActions }
        .motion(.easeOut(duration: 0.14), value: hovering)
        .help("Workspace: \(title)")
        .accessibilityLabel("Workspace \(title)")
        .accessibilityIdentifier("workspace-menu")
    }
}

/// Asks before a workspace is deleted. Nothing is closed: its tabs move to Personal (that is what `deleteWorkspace` does), and only the workspace's own name, icon and theme go.
@MainActor func confirmDeleteWorkspace(model: BrowserModel, name: String) {
    let count = model.tabs.filter { $0.workspace == name }.count
    let alert = NSAlert()
    alert.messageText = "Delete the workspace “\(name)”?"
    alert.informativeText = count == 0 ? "The workspace is empty. Its name, icon and theme are removed."
        : "Its \(count) tab\(count == 1 ? "" : "s") stay open and move to Personal. The workspace's name, icon and theme are removed."
    alert.addButton(withTitle: "Delete")
    alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.hasDestructiveAction = true
    if alert.runModal() == .alertFirstButtonReturn { model.deleteWorkspace(name) }
}

/// A named workspace row can be dragged (Personal cannot move).
private struct WorkspaceRowDrag: ViewModifier {
    let name: String
    func body(content: Content) -> some View {
        if name.isEmpty { content } else { content.draggable(BrowserModel.workspaceDragPrefix + name) }
    }
}

/// Arrow keys move between the workspace rows, Return or Space opens one, Option-arrows reorder (not Personal, which stays first).
private struct WorkspaceRowKeys: ViewModifier {
    let name: String
    let focus: FocusState<String?>.Binding?
    let neighbours: (previous: String?, next: String?)
    let choose: () -> Void
    let moveUp: () -> Void
    let moveDown: () -> Void
    let movable: Bool

    func body(content: Content) -> some View {
        if let focus {
            content
                .focusable().focusEffectDisabled().focused(focus, equals: name)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 2).opacity(focus.wrappedValue == name ? 1 : 0).allowsHitTesting(false))
                .onKeyPress(.upArrow, phases: [.down, .repeat]) { press in
                    if press.modifiers.contains(.option) { if movable { moveUp() }; return .handled }
                    if let previous = neighbours.previous { focus.wrappedValue = previous }; return .handled
                }
                .onKeyPress(.downArrow, phases: [.down, .repeat]) { press in
                    if press.modifiers.contains(.option) { if movable { moveDown() }; return .handled }
                    if let next = neighbours.next { focus.wrappedValue = next }; return .handled
                }
                .onKeyPress(.return) { choose(); return .handled }
                .onKeyPress(.space) { choose(); return .handled }
        } else { content }
    }
}

/// A small caps heading for a section of the sidebar, with an optional "+" at its end.
struct SidebarSectionLabel: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let title: String
    var action: (() -> Void)?
    var help: () -> String = { "" }
    @State private var hovering = false

    init(_ title: String, action: (() -> Void)? = nil, help: @escaping () -> String = { "" }) {
        self.title = title; self.action = action; self.help = help
    }

    var body: some View {
        HStack {
            Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.7).foregroundStyle(.secondary.opacity(contrast == .increased ? 1 : 0.85))
                .accessibilityLabel(title).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if let action {
                Button(action: action) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.primary.opacity(hovering ? 0.12 : 0)))
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .motion(.easeOut(duration: 0.14), value: hovering)
                .help(help())
                .accessibilityLabel(help())
                .accessibilityIdentifier(title.lowercased().replacingOccurrences(of: " ", with: "-") + "-add")
            }
        }
        .padding(.horizontal, 2)
    }
}

/// One workspace in the list. The open one is highlighted; a click switches to it.
struct SidebarWorkspaceRow: View {
    @EnvironmentObject var model: BrowserModel
    let name: String
    let title: String
    let icon: String
    /// Keyboard focus among the rows (the Deck's list), with the rows either side for the arrow keys. Absent where the row is used alone.
    var focus: FocusState<String?>.Binding? = nil
    var neighbours: (previous: String?, next: String?) = (nil, nil)
    @State private var hovering = false
    /// A tab is being dragged over this row.
    @State private var dropTargeted = false

    private var selected: Bool { model.activeWorkspace == name }
    /// A workspace with its own accent shows it on its icon, so each is recognised before it is opened (the open one uses the live accent).
    private var ownAccent: Color? { model.workspaces.first { $0.name == name }?.accent.flatMap { AccentChoice(rawValue: $0)?.color } }

    var body: some View {
        Button { if !selected { model.switchWorkspace(name) } } label: {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 13, weight: .medium)).symbolRenderingMode(.hierarchical).frame(width: 20)
                    .foregroundStyle(selected ? Theme.accent : (ownAccent ?? Color.secondary))
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular)).lineLimit(1).layoutPriority(1)
                Spacer(minLength: 0)
                Text("\(model.workspaceTabCount(name))").font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                // The open workspace is marked by more than colour.
                if selected { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accent) }
            }
            .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.75))
            .padding(.horizontal, 9).frame(height: model.density.smallRowHeight + 2)
            .modifier(SidebarFill(selected: selected, hovering: hovering || dropTargeted, radius: 10, rest: 0, hover: 0.06, selection: 0.24))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.accent, lineWidth: 1.5).opacity(dropTargeted ? 1 : 0).allowsHitTesting(false))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(WorkspaceRowKeys(name: name, focus: focus, neighbours: neighbours, choose: { if !selected { model.switchWorkspace(name) } },
                                   moveUp: { model.moveWorkspace(name, by: -1) }, moveDown: { model.moveWorkspace(name, by: 1) }, movable: !name.isEmpty))
        // Drag a workspace row to reorder (Personal stays first); drop a tab here to move it to this workspace.
        .modifier(WorkspaceRowDrag(name: name))
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first else { return false }
            if raw.hasPrefix(BrowserModel.workspaceDragPrefix) {
                model.moveWorkspace(String(raw.dropFirst(BrowserModel.workspaceDragPrefix.count)), before: name)
                return true
            }
            guard let dragged = UInt64(raw) else { return false }
            return model.acceptDroppedTabToWorkspace(dragged, workspace: name)
        } isTargeted: { dropTargeted = $0 }
        .help(title)
        .accessibilityLabel("\(title), \(model.workspaceTabCount(name)) tabs")
        .accessibilityAddTraits(selected ? .isSelected : [])      // the current workspace is announced and findable, not only drawn
        .onHover { hovering = $0 }
        .motion(.easeOut(duration: 0.14), value: hovering)
        .motion(.easeOut(duration: 0.18), value: selected)
        .contextMenu {
            if !selected { Button("Open") { model.switchWorkspace(name) } }
            if !name.isEmpty {
                Button("Rename…") { promptRenameWorkspace(model: model, name: name) }
                Button("Move Up") { model.moveWorkspace(name, by: -1) }
                Button("Move Down") { model.moveWorkspace(name, by: 1) }
            }
            Button("Appearance and Layout…") { SettingsRouter.open(.tabs) }
            if !name.isEmpty {
                Divider()
                Button("Delete…", role: .destructive) { confirmDeleteWorkspace(model: model, name: name) }
            }
        }
    }
}

/// The header of a tab group: its colour, name and number of tabs. A click (or a double-click) opens or closes it.
struct SidebarGroupHeader: View {
    @EnvironmentObject var model: BrowserModel
    let name: String
    let count: Int
    let collapsed: Bool
    /// The tab in front is inside this group (so a closed group still shows where you are).
    var containsActive = false
    let toggle: () -> Void
    @State private var hovering = false
    @State private var dropTargeted = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                .rotationEffect(.degrees(collapsed ? 0 : 90)).frame(width: 12)
            Image(systemName: "folder.fill").font(.system(size: 13, weight: .medium)).symbolRenderingMode(.hierarchical).foregroundStyle(model.groupColor(name)?.color ?? Color.secondary)
            Text(name).font(.system(size: 13, weight: .medium)).lineLimit(1)
            Spacer(minLength: 0)
            // A closed group that holds the tab in front says so: an accent dot, and the same in the spoken label.
            if collapsed && containsActive { Circle().fill(Theme.accent).frame(width: 6, height: 6) }
            Text("\(count)").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8).frame(height: model.density.smallRowHeight + 2)
        .modifier(SidebarFill(selected: false, hovering: hovering || dropTargeted, radius: 10, rest: 0, hover: dropTargeted ? 0.14 : 0.07, selection: 0))
        // The keyboard's place is drawn in the system focus colour, so it is never confused with the accent of the selected tab.
        .overlay { if focused { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 2).allowsHitTesting(false) } }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        // Reachable from the keyboard: Return and Space open or close it (no tab is selected by this).
        .focusable().focusEffectDisabled().focused($focused)
        .onKeyPress(.return) { toggle(); return .handled }
        .onKeyPress(.space) { toggle(); return .handled }
        .onKeyPress(.rightArrow) { if collapsed { toggle() }; return .handled }
        .onKeyPress(.leftArrow) { if !collapsed { toggle() }; return .handled }
        .accessibilityAction { toggle() }
        // A tab dropped on the header joins the group (a quiet tint shows where it will go).
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let dragged = UInt64(raw) else { return false }
            return model.acceptDroppedTab(dragged, intoGroup: name)
        } isTargeted: { dropTargeted = $0 }
        .onHover { hovering = $0 }
        .motion(.easeOut(duration: 0.14), value: hovering)
        .motion(.easeOut(duration: 0.2), value: collapsed)
        .contextMenu {
            Button(collapsed ? "Expand Group" : "Collapse Group") { toggle() }
            Button("New Tab in Group") { model.newTab(inGroup: name) }
            Divider()
            Menu("Colour") {
                ForEach(GroupColor.allCases) { c in
                    Button { model.setGroupColor(name, c) } label: {
                        if model.groupColor(name) == c { Label(c.title, systemImage: "checkmark") } else { Text(c.title) }
                    }
                }
                Divider()
                Button("No Colour") { model.setGroupColor(name, nil) }
            }
            Button("Rename…") {
                let model = model
                Task { @MainActor in
                    if let new = await Dialogs.promptText(title: "Rename Group", message: "New name for “\(name)”.", placeholder: name), !new.isEmpty { model.renameGroup(name, to: new) }
                }
            }
            Button("Ungroup (keeps the tabs)", role: .destructive) { model.deleteGroup(name) }
            let closable = model.closableTabs(inGroup: name).count
            Button("Close \(closable) Tab\(closable == 1 ? "" : "s") in Group", role: .destructive) { model.closeStripGroup(name) }.disabled(closable == 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(count) tab\(count == 1 ? "" : "s"), \(collapsed ? "closed" : "open")\(collapsed && containsActive ? ", contains the current tab" : "")")
        .accessibilityAddTraits(.isButton)
    }
}

/// The last tile in the pinned grid: pins the page you are on.
struct SidebarPinCurrentTile: View {
    @EnvironmentObject var model: BrowserModel
    @State private var hovering = false

    var body: some View {
        Button { if let tab = model.active, !tab.pinned { model.togglePin(tab) } } label: {
            Image(systemName: "plus").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).frame(height: model.density.pinnedTileHeight - 4)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(hovering ? 0.28 : 0.16), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
        }
        .buttonStyle(.plain)
        .disabled(model.active == nil || model.active?.pinned == true || model.active?.isBlank == true)
        .onHover { hovering = $0 }
        .motion(.easeOut(duration: 0.14), value: hovering)
        .help("Pin This Page")
        .accessibilityLabel("Pin this page")
    }
}

/// A pinned site: a rounded tile with its icon. The selected one wears an accent ring.
struct SidebarPinnedTile: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        TabFavicon(tab: tab, size: 22)
            .frame(maxWidth: .infinity).frame(height: model.density.pinnedTileHeight - 4)
            .modifier(SidebarFill(selected: selected, hovering: hovering, radius: 8, rest: 0.06, hover: 0.11, selection: 0.24))
            .overlay(alignment: .topTrailing) { AudioBadge(tab: tab).scaleEffect(0.75).offset(x: 3, y: -3) }
            .overlay(alignment: .bottomTrailing) {
                if tab.isLocked { Image(systemName: "lock.fill").font(.system(size: 7, weight: .bold)).foregroundStyle(.secondary).padding(4).accessibilityHidden(true) }
            }
            .accessibilityLabel(tab.displayTitle)
            .accessibilityValue(TabChipRules.spokenState(locked: tab.isLocked, pinned: tab.pinned, playing: tab.playingAudio, muted: tab.muted, asleep: tab.isDiscarded, isPrivate: tab.isPrivate) ?? "")
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .motion(.easeOut(duration: 0.14), value: hovering)
            .motion(.easeOut(duration: 0.16), value: selected)
            .onHover { hovering = $0 }
            .modifier(TabTooltip(title: tab.displayTitle))
            .tabInteractions(tab)
    }
}

/// One open tab: icon, title, and a close button while the pointer is on it. The selected tab is a tinted card.
struct SidebarTabRow: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            // A tab opened from another sits one step in from it when the tab tree is on.
            if model.tabTree { Color.clear.frame(width: CGFloat(model.treeDepth(of: tab)) * 14, height: 1) }
            TreeFoldButton(tab: tab)
            ZStack(alignment: .bottomTrailing) {
                TabFavicon(tab: tab, size: 16)
                if !tab.group.isEmpty, let color = model.groupColor(tab.group)?.color {
                    Circle().fill(color).frame(width: 7, height: 7).overlay(Circle().strokeBorder(Color.chrome, lineWidth: 1.5)).offset(x: 3, y: 3)
                }
            }
            .frame(width: 18)
            Text(tab.displayTitle)
                .font(.system(size: 13, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.74))
                .lineLimit(1).truncationMode(.tail)
            StackBadge(tab: tab)
            TabBadges(tab: tab)
            // A private tab in a window with normal tabs is marked, not only spoken.
            if tab.isPrivate && !model.isPrivateWindow { Image(systemName: "eye.slash.fill").font(.system(size: 9)).foregroundStyle(Theme.privateAccent).accessibilityHidden(true) }
            Spacer(minLength: 0)
            if tab.isLocked { Image(systemName: "lock.fill").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary) }
            else {
                // Close is at the trailing end, never over the icon: on the selected row at rest, on any row under the pointer; a locked row has the lock instead.
                let showsClose = TabChipRules.showsCloseButton(locked: false, selected: selected, hovering: hovering)
                TabCloseButton(action: { model.closeTab(id: tab.id) }, restOpacity: selected ? 0.75 : 0.55)
                    .opacity(showsClose ? 1 : 0).allowsHitTesting(showsClose)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: model.density.tabRowHeight)
        // A quiet filled selection, no outline: it reads as the current tab without looking like a button (with Increase Contrast on, an outline is added).
        .modifier(SidebarFill(selected: selected, hovering: hovering, radius: 8, rest: 0, hover: 0.07, selection: 0.20))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tab.displayTitle)
        .accessibilityValue(TabChipRules.spokenState(locked: tab.isLocked, pinned: tab.pinned, playing: tab.playingAudio, muted: tab.muted, asleep: tab.isDiscarded, isPrivate: tab.isPrivate) ?? "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .motion(.easeOut(duration: 0.14), value: hovering)
        .motion(.easeOut(duration: 0.18), value: selected)
        .onHover { hovering = $0 }
        .transition(.move(edge: .leading).combined(with: .opacity))
        .modifier(TabTooltip(title: tab.displayTitle))
        .tabInteractions(tab)
    }
}

/// Catches only the middle mouse button; every other event passes straight through to what is underneath.
struct MiddleClickCatcher: NSViewRepresentable {
    let action: () -> Void

    final class CatcherView: NSView {
        var action: (() -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let type = NSApp.currentEvent?.type, type == .otherMouseDown || type == .otherMouseUp else { return nil }
            return super.hitTest(point)
        }
        override func otherMouseUp(with event: NSEvent) { if event.buttonNumber == 2 { action?() } }
    }

    func makeNSView(context: Context) -> CatcherView { let v = CatcherView(); v.action = action; return v }
    func updateNSView(_ view: CatcherView, context: Context) { view.action = action }
}


struct SidebarPanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
private struct EssentialsContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The Essentials in the sidebar, kept above the scrolling list: only as tall as they need to be, up to `rows` rows of the grid's own tiles, and scrolling inside themselves beyond that
/// (twelve is the most there can be). It is a sibling of the main list, not inside it, so a wheel or trackpad scroll over it never moves the tabs, and the main list never traps it.
struct SidebarEssentialsBlock: View {
    @EnvironmentObject var model: BrowserModel
    let rows: Int
    /// Below this panel height the block shows one row, so the open tabs keep their room. Worked out from the fixed parts (header 40, workspace 34, separator 13, search about 44, footer
    /// about 48 = about 180 pt) plus the Essentials with two rows (about 125 pt with their label): 520 pt leaves about 215 pt, five or six rows of tabs; below it, one row.
    static let shortPanel: CGFloat = 520
    private let tile: CGFloat = 44, gap: CGFloat = 6
    @State private var contentHeight: CGFloat = 0

    private var cap: CGFloat { CGFloat(rows) * tile + CGFloat(rows - 1) * gap }
    private var overflows: Bool { contentHeight > cap + 1 }

    var body: some View {
        if !model.isGuest, !model.essentials.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SidebarSectionLabel("Essentials")
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        EssentialsGrid(separator: false)
                            .background(GeometryReader { g in Color.clear.preference(key: EssentialsContentHeightKey.self, value: g.size.height) })
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .scrollIndicators(overflows ? .visible : .hidden)
                    .frame(height: contentHeight > 0 ? min(contentHeight, cap) : cap)
                    .onPreferenceChange(EssentialsContentHeightKey.self) { contentHeight = $0 }
                    // The Essential in front is kept in view.
                    .onChange(of: model.activeID) { _, _ in
                        if let active = model.active, let record = model.essentialRecord(for: active) { proxy.scrollTo(record.id, anchor: .center) }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Essentials, \(model.essentials.count)")
                .accessibilityHint(overflows ? "More Essentials are below. Scroll to reach them." : "")
                .accessibilityIdentifier("essentials-block")
            }
            .padding(.bottom, 6)
        }
    }
}


/// Workspace Deck's navigator: every workspace as a row (icon, name, number of tabs), the selected one highlighted, with New Workspace and an overview of the
/// open tabs. Choosing a row switches workspace through the model (`switchWorkspace`); it never changes the profile or the data store. A long list scrolls inside
/// a bounded height so the tabs below keep their room.
struct WorkspaceDeckList: View {
    @EnvironmentObject var model: BrowserModel
    @FocusState private var focusedRow: String?
    /// How many workspaces show before the list scrolls: fewer in a short window, so the tabs below keep their room.
    var maxRows = 6

    @State private var filter = ""
    @State private var showFilter = false
    private var allRows: [(name: String, title: String, icon: String)] {
        [("", "Personal", "person.fill")] + model.workspaces.map { ($0.name, $0.name, $0.icon) }
    }
    /// With many workspaces a search field narrows the list; the open workspace always stays in it.
    private var rows: [(name: String, title: String, icon: String)] {
        let text = filter.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return allRows }
        return allRows.filter { $0.title.localizedCaseInsensitiveContains(text) || $0.name == model.activeWorkspace }
    }

    /// The rows above and below one, for the arrow keys.
    private func neighbours(of name: String) -> (previous: String?, next: String?) {
        guard let i = rows.firstIndex(where: { $0.name == name }) else { return (nil, nil) }
        return (i > 0 ? rows[i - 1].name : nil, i + 1 < rows.count ? rows[i + 1].name : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                SidebarSectionLabel("Workspaces") { promptNewWorkspace(model: model) } help: { "New Workspace" }
                // Search is always one click away (the field also shows by itself once there are many workspaces).
                Button { showFilter.toggle(); if !showFilter { filter = "" } } label: {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Find a Workspace").accessibilityLabel("Find a workspace").accessibilityIdentifier("workspace-search-button")
                Button { SettingsRouter.open(.tabs) } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Manage Workspaces…").accessibilityLabel("Manage workspaces")
            }
            if allRows.count > 8 || showFilter {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("Find a workspace", text: $filter).textFieldStyle(.plain).font(.system(size: 12))
                        .accessibilityIdentifier("workspace-filter")
                    if !filter.isEmpty { Button { filter = "" } label: { Image(systemName: "xmark.circle.fill").accessibilityLabel("Clear") }.buttonStyle(.plain).foregroundStyle(.secondary) }
                }
                .padding(.horizontal, 8).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
            }
            ScrollView(.vertical) {
                VStack(spacing: 2) {
                    ForEach(rows, id: \.name) { row in
                        SidebarWorkspaceRow(name: row.name, title: row.title, icon: row.icon, focus: $focusedRow, neighbours: neighbours(of: row.name))
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: min(CGFloat(rows.count) * 34, CGFloat(maxRows) * 34))
            Button { model.showOverview() } label: {
                Label("Overview of Open Tabs", systemImage: "square.grid.2x2").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 9).frame(height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("workspace-overview")
            Divider().padding(.vertical, 2)
            // The profile is a different thing from a workspace, so it has its own labelled row: workspaces share its cookies and sign-ins.
            Menu {
                ForEach(model.profiles, id: \.self) { name in
                    Button { model.switchProfile(name) } label: { Label(name, systemImage: name == model.profileName ? "checkmark" : model.profileStyle(name).symbol) }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: model.profileStyle(model.profileName).symbol).font(.system(size: 12)).frame(width: 20)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Profile").font(.system(size: 10)).foregroundStyle(.tertiary)
                        Text(model.profileName).font(.system(size: 12)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8)).foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary).padding(.horizontal, 9).frame(height: 34).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .help("Profile: \(model.profileName). Workspaces in this profile share its cookies and sign-ins.")
            .accessibilityLabel("Profile \(model.profileName). Workspaces share this profile's data.")
            .accessibilityIdentifier("deck-profile")
            // What the Essentials, pinned tabs, groups and open tabs below belong to.
            SidebarSectionLabel("\(model.activeWorkspace.isEmpty ? "Personal" : model.activeWorkspace) · Tabs") { _ = model.newTab() } help: { "New Tab" }
                .padding(.top, 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspaces")
        .accessibilityIdentifier("workspace-deck")
    }
}


/// The sidebar's row and tile background: a quiet fill (selection in the accent), and with Increase Contrast on a stronger fill and an outline, so neither the
/// selection nor the hover depends on a faint tint.
struct SidebarFill: ViewModifier {
    let selected: Bool
    let hovering: Bool
    let radius: CGFloat
    let rest: Double
    let hover: Double
    let selection: Double
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let high = contrast == .increased
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(shape.fill(selected ? Theme.accent.opacity(high ? min(1, selection * 1.8) : selection)
                                            : Color.primary.opacity(hovering ? (high ? hover * 2 : hover) : (high ? rest * 2 : rest))))
            .overlay { if high && (selected || hovering) { shape.strokeBorder(selected ? Theme.accent : Color.primary.opacity(0.5), lineWidth: 1).allowsHitTesting(false) } }
    }
}
