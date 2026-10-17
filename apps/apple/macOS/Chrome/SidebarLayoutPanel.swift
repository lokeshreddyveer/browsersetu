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

    /// The traffic lights are hidden in this layout (they come back when the pointer is in the window's top-left corner), so nothing is
    /// reserved for them: the buttons start at the edge.
    private var lightsInset: CGFloat { lightsShown ? 74 : 0 }
    @State private var lightsShown = TrafficLightsState.shown

    var body: some View {
        VStack(spacing: 0) {
            header
            if showsAddress, let tab = model.active {
                MacOmnibox(tab: tab, address: model.addressBar, showReload: false, shield: true)
                    .padding(.horizontal, 10).padding(.bottom, 10)
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
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 2) {
            Color.clear.frame(width: lightsInset, height: 1)
            Spacer(minLength: 0)
            if showsAddress, let tab = model.active {
                ChromeButton(symbol: "chevron.left", help: "Back", identifier: "back-button") { tab.goBack() }.disabled(!tab.canGoBack)
                ChromeButton(symbol: "chevron.right", help: "Forward", identifier: "forward-button") { tab.goForward() }.disabled(!tab.canGoForward)
                ChromeButton(symbol: tab.isLoading ? "xmark" : "arrow.clockwise", help: tab.isLoading ? "Stop" : "Reload", identifier: "reload-button") {
                    tab.isLoading ? tab.stop() : tab.reload()
                }
                .disabled(tab.isBlank)
            }
            SidebarPinButton()
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
        model.tabs.filter { $0.workspace == model.activeWorkspace && (!model.separatesPrivate || $0.isPrivate == model.privateMode) }
    }

    private var tabsArea: some View {
        let all = workspaceTabs
        let pinned = all.filter(\.pinned)
        let open = all.filter { !$0.pinned && $0.group.isEmpty }
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SearchTabsRow()
                workspacesSection
                pinnedSection(pinned)
                openSection(open)
                groupsSection(all)
            }
            .padding(.horizontal, 12).padding(.top, 2).padding(.bottom, 14)
            .animation(.easeOut(duration: 0.18), value: all.map(\.id))
            .animation(.easeOut(duration: 0.18), value: collapsed)
        }
    }

    // Workspaces

    private var workspacesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            SidebarSectionLabel("Workspaces") { promptNewWorkspace(model: model) } help: { "New Workspace" }
            SidebarWorkspaceRow(name: "", title: "Personal", icon: "person.fill")
            ForEach(model.workspaces) { SidebarWorkspaceRow(name: $0.name, title: $0.name, icon: $0.icon) }
        }
    }

    // Pinned

    private func pinnedSection(_ pinned: [TabController]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SidebarSectionLabel("Pinned")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                ForEach(pinned) { SidebarPinnedTile(tab: $0, selected: $0.id == model.activeID) }
                SidebarPinCurrentTile()
            }
        }
    }

    // Open tabs

    private func openSection(_ open: [TabController]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SidebarSectionLabel("Open Tabs") { _ = model.newTab() } help: { "New Tab" }
            VStack(spacing: 2) {
                ForEach(model.stackedVisible(model.treeVisible(open))) { SidebarTabRow(tab: $0, selected: $0.id == model.activeID) }
            }
        }
        // A tab dragged here from another window comes into this one.
        .acceptsDroppedTabs(model)
    }

    // Groups

    @State private var collapsed: Set<String> = []

    @ViewBuilder private func groupsSection(_ all: [TabController]) -> some View {
        if !model.groupNames.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                SidebarSectionLabel("Tab Groups") { promptNewGroup(model: model) } help: { "New Tab Group" }
                ForEach(model.groupNames, id: \.self) { name in
                    let members = all.filter { !$0.pinned && $0.group == name }
                    let isCollapsed = collapsed.contains(name)
                    SidebarGroupHeader(name: name, count: members.count, collapsed: isCollapsed) {
                        if isCollapsed { collapsed.remove(name) } else { collapsed.insert(name) }
                    }
                    if !isCollapsed {
                        VStack(spacing: 2) {
                            ForEach(members) { SidebarTabRow(tab: $0, selected: $0.id == model.activeID) }
                        }
                        .padding(.leading, 12)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
    }
}

/// A small caps heading for a section of the sidebar, with an optional "+" at its end.
struct SidebarSectionLabel: View {
    let title: String
    var action: (() -> Void)?
    var help: () -> String = { "" }
    @State private var hovering = false

    init(_ title: String, action: (() -> Void)? = nil, help: @escaping () -> String = { "" }) {
        self.title = title; self.action = action; self.help = help
    }

    var body: some View {
        HStack {
            Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.7).foregroundStyle(.secondary.opacity(0.85))
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
    @State private var hovering = false

    private var selected: Bool { model.activeWorkspace == name }

    var body: some View {
        Button { model.switchWorkspace(name) } label: {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 13, weight: .medium)).symbolRenderingMode(.hierarchical).frame(width: 20)
                    .foregroundStyle(selected ? Theme.accent : Color.secondary)
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 0)
                Text("\(model.tabs.filter { $0.workspace == name }.count)").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.75))
            .padding(.horizontal, 9).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Theme.accent.opacity(0.24) : Color.primary.opacity(hovering ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .motion(.easeOut(duration: 0.14), value: hovering)
        .motion(.easeOut(duration: 0.18), value: selected)
        .contextMenu {
            if !name.isEmpty {
                Button("Rename…") { promptRenameWorkspace(model: model, name: name) }
                Button("Delete", role: .destructive) { model.deleteWorkspace(name) }
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
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                .rotationEffect(.degrees(collapsed ? 0 : 90)).frame(width: 12)
            Image(systemName: "folder.fill").font(.system(size: 13, weight: .medium)).symbolRenderingMode(.hierarchical).foregroundStyle(model.groupColor(name)?.color ?? Color.secondary)
            Text(name).font(.system(size: 13, weight: .medium)).lineLimit(1)
            Spacer(minLength: 0)
            Text("\(count)").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8).frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(hovering ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { hovering = $0 }
        .motion(.easeOut(duration: 0.14), value: hovering)
        .motion(.easeOut(duration: 0.2), value: collapsed)
        .contextMenu {
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
            Button("Delete Group", role: .destructive) { model.deleteGroup(name) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(count) tabs, \(collapsed ? "closed" : "open")")
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
                .frame(maxWidth: .infinity).frame(height: 46)
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
            .frame(maxWidth: .infinity).frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Theme.accent.opacity(0.24) : Color.primary.opacity(hovering ? 0.11 : 0.06)))
            .accessibilityLabel(tab.displayTitle)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .motion(.easeOut(duration: 0.14), value: hovering)
            .motion(.easeOut(duration: 0.16), value: selected)
            .onHover { hovering = $0 }
            .help(tab.displayTitle)
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
            Spacer(minLength: 0)
            if tab.isLocked { Image(systemName: "lock.fill").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary) }
            else if tab.isLoading && !hovering { ProgressView().controlSize(.mini).scaleEffect(0.8).frame(width: 16, height: 16) }
            else { TabCloseButton { model.closeTab(id: tab.id) }.opacity(hovering ? 1 : 0).allowsHitTesting(hovering) }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        // A quiet filled selection, no outline: it reads as the current tab without looking like a button.
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(selected ? Theme.accent.opacity(0.20) : Color.primary.opacity(hovering ? 0.07 : 0)))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tab.displayTitle)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .motion(.easeOut(duration: 0.14), value: hovering)
        .motion(.easeOut(duration: 0.18), value: selected)
        .onHover { hovering = $0 }
        .transition(.move(edge: .leading).combined(with: .opacity))
        .help(tab.displayTitle)
        .tabInteractions(tab)
        // A middle click closes the tab, as in every other browser.
        .overlay(MiddleClickCatcher { if !tab.isLocked { model.closeTab(id: tab.id) } })
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
