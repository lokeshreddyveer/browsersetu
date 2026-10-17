import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension Image {
    init?(platformData data: Data) {
        #if os(macOS)
        guard let image = NSImage(data: data) else { return nil }
        self.init(nsImage: image)
        #else
        guard let image = UIImage(data: data) else { return nil }
        self.init(uiImage: image)
        #endif
    }
}

// MARK: - Start page

struct SiteTile: View {
    let url: String
    let title: String
    var size: CGFloat = 54
    /// Observed so a tile switches from its letter to the site's icon the moment the icon arrives.
    @ObservedObject private var icons = FaviconStore.shared

    var body: some View {
        if let icon = icons.image(forURL: url) {
            Image(platform: icon).resizable().interpolation(.high).scaledToFit()
                .padding(size * 0.14)
                .frame(width: size, height: size)
                .background(Color(white: 0.96), in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
        } else {
            letterTile
        }
    }

    private var letterTile: some View {
        Text(tileLetter(title: title, url: url))
            .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Theme.tileColor(for: displayHost(URL(string: url)) + title),
                        in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
    }
}

// MARK: - Tab menus

/// Context-menu items shared by the tab strip, sidebar and overview.
struct TabMenuItems: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController

    var body: some View {
        Button(tab.pinned ? "Unpin Tab" : "Pin Tab") { model.togglePin(tab) }
        SendTabMenu(tab: tab)
        Button(tab.isLocked ? "Unlock Tab" : "Lock Tab") { model.toggleLock(tab) }
        Button("Duplicate Tab") { model.duplicateTab(tab) }.disabled(tab.isBlank)
        Button("Put Tab to Sleep") { Task { await model.hibernate(tab) } }
            .disabled(tab.id == model.activeID || tab.isDiscarded || tab.isPrivate || tab.isBlank)
        if model.duplicateCount(of: tab) > 0 {
            Button("Close \(model.duplicateCount(of: tab)) Duplicate Tab\(model.duplicateCount(of: tab) == 1 ? "" : "s")") { model.closeDuplicates(of: tab) }
        }
        #if os(macOS)
        if tab.id != model.activeID {
            if model.splitTabID != nil, tab.id != model.splitTabID, tab.id != model.thirdSplitTabID, tab.id != model.fourthSplitTabID {
                Button("Add to Split View as a Panel") { model.addThirdPanel(with: tab) }
                Button("Replace the Second Panel") { model.openSplit(with: tab) }
            } else { Button("Open in Split View") { model.openSplit(with: tab) } }
        }
        Menu("Move to Window") {
            Button("New Window") { model.moveTabToNewWindow(tab.id) }.disabled(model.tabs.count < 2 && model.isSecondary)
            if !model.otherWindows.isEmpty {
                Divider()
                ForEach(Array(model.otherWindows.enumerated()), id: \.offset) { index, other in
                    Button("\(index + 1). \(other.title)") { model.moveTab(tab.id, to: other.model) }
                }
            }
        }
        #endif
        if !tab.isPrivate && !model.workspaces.isEmpty {
            Menu("Move to Workspace") {
                Button("Personal") { model.moveTab(tab, toWorkspace: "") }.disabled(tab.workspace.isEmpty)
                ForEach(model.workspaces) { ws in
                    Button(ws.name) { model.moveTab(tab, toWorkspace: ws.name) }.disabled(tab.workspace == ws.name)
                }
            }
        }
        if !tab.isPrivate {
            Menu("Move to Group") {
                Button("No Group") { model.moveTab(tab, to: "") }.disabled(tab.group.isEmpty)
                ForEach(model.groupNames, id: \.self) { name in
                    Button(name) { model.moveTab(tab, to: name) }.disabled(tab.group == name)
                }
                Divider()
                Button("New Group…") { promptNewGroup(moving: tab) }
            }
            Button(model.isFavorite(tab.url?.absoluteString ?? "") ? "Remove from Favorites" : "Add to Favorites") {
                if let url = tab.url?.absoluteString { model.toggleFavorite(url: url, title: tab.displayTitle) }
            }
            .disabled(tab.isBlank)
        }
        Divider()
        TabDetailsMenu(tab: tab)
        Divider()
        Button("Close Tab") { model.closeTab(id: tab.id) }
        Button("Close Other Tabs") { model.closeOtherTabs(except: tab.id) }
    }

    private func promptNewGroup(moving tab: TabController) {
        let model = model
        Task { @MainActor in
            if let name = await Dialogs.promptText(title: "New Tab Group", message: "Name this group.", placeholder: ""), !name.isEmpty {
                model.createGroup(name, moving: tab)
            }
        }
    }
}

func promptNewGroup(model: BrowserModel) {
    Task { @MainActor in
        if let name = await Dialogs.promptText(title: "New Tab Group", message: "Name this group.", placeholder: ""), !name.isEmpty {
            model.createGroup(name)
            model.selectGroup(name.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

// MARK: - Group chips

struct GroupChips: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("Tabs", count: model.tabCount(inGroup: ""), selected: model.activeGroup.isEmpty) { model.selectGroup("") }
                ForEach(model.groupNames, id: \.self) { name in
                    chip(name, count: model.tabCount(inGroup: name), selected: model.activeGroup == name) { model.selectGroup(name) }
                        .contextMenu {
                            Button("Rename…") { rename(name) }
                            Button("Delete Group", role: .destructive) { model.deleteGroup(name) }
                        }
                }
                Button { promptNewGroup(model: model) } label: {
                    Label("New Group", systemImage: "plus").font(.callout)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                }
                .buttonStyle(.plain).foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 2)
        }
    }

    private func chip(_ title: String, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                Text("\(count)").font(.caption2).foregroundStyle(.secondary)
            }
            .font(.callout.weight(selected ? .semibold : .regular))
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(selected ? Theme.accent.opacity(0.18) : Color.primary.opacity(0.06), in: Capsule())
            .foregroundStyle(selected ? Theme.accent : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func rename(_ old: String) {
        let model = model
        Task { @MainActor in
            if let name = await Dialogs.promptText(title: "Rename Group", message: "New name for “\(old)”.", placeholder: old), !name.isEmpty {
                model.renameGroup(old, to: name)
            }
        }
    }
}

// MARK: - Tab overview

/// The tabs ticked in the overview's select mode.
@MainActor final class OverviewSelection: ObservableObject {
    @Published var active = false
    @Published var ids: Set<UInt64> = []
    func toggle(_ id: UInt64) { if ids.contains(id) { ids.remove(id) } else { ids.insert(id) } }
    func end() { active = false; ids = [] }
}

private struct OverviewSelectionKey: EnvironmentKey { static let defaultValue: OverviewSelection? = nil }
extension EnvironmentValues {
    var overviewSelection: OverviewSelection? {
        get { self[OverviewSelectionKey.self] }
        set { self[OverviewSelectionKey.self] = newValue }
    }
}

/// A tick in the corner of a tab while the overview is choosing tabs.
struct SelectionMark: View {
    @ObservedObject var selection: OverviewSelection
    let id: UInt64
    var body: some View {
        if selection.active {
            Image(systemName: selection.ids.contains(id) ? "checkmark.circle.fill" : "circle")
                .accessibilityLabel(selection.ids.contains(id) ? "Selected" : "Not selected")
                .font(.title3).symbolRenderingMode(.palette)
                .foregroundStyle(selection.ids.contains(id) ? Color.white : Color.secondary, selection.ids.contains(id) ? Theme.accent : Color.clear)
                .padding(8).transition(.opacity)
        }
    }
}

#if os(iOS)
/// Swipe a tab in the overview sideways to close it: it follows the finger, fades, and leaves when let go past a short distance.
struct SwipeToClose: ViewModifier {
    @EnvironmentObject var model: BrowserModel
    let tab: TabController
    @State private var dx: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .offset(x: dx)
            .accessibilityAction(named: "Close tab") { model.closeTab(id: tab.id) }
            .opacity(1 - min(abs(dx) / 320, 0.6))
            .motion(.interactiveSpring(), value: dx)
            .simultaneousGesture(
                DragGesture(minimumDistance: 24)
                    .onChanged { value in
                        if abs(value.translation.width) > abs(value.translation.height) { dx = value.translation.width }
                    }
                    .onEnded { value in
                        if abs(value.translation.width) > 110, abs(value.translation.width) > abs(value.translation.height) {
                            animated(.easeOut(duration: 0.2)) { dx = value.translation.width > 0 ? 500 : -500 }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { model.closeTab(id: tab.id) }
                        } else {
                            animated(.easeOut(duration: 0.2)) { dx = 0 }
                        }
                    }
            )
    }
}
#endif

/// One open tab as a row, for the list view of the tab overview.
struct TabListRow: View {
    @EnvironmentObject var model: BrowserModel
    @Environment(\.overviewSelection) private var selection
    @ObservedObject var tab: TabController
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            SiteTile(url: tab.url?.absoluteString ?? "", title: tab.displayTitle, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if tab.isPrivate { Image(systemName: "eye.slash.fill").font(.caption).foregroundStyle(Theme.privateAccent) }
                    if tab.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                    Text(tab.displayTitle).font(.callout.weight(.medium)).lineLimit(1)
                }
                Text(displayHost(tab.url)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button { model.closeTab(id: tab.id) } label: { Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.secondary).frame(width: 30, height: 30).accessibilityLabel("Close") }
                .buttonStyle(.plain).accessibilityLabel("Close tab")
        }
        .padding(.horizontal, 12).padding(.vertical, model.density.listRowPadding - 1)
        .themedFill(in: RoundedRectangle(cornerRadius: 14, style: .continuous), fallback: .background.secondary)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(selected ? (tab.isPrivate ? Theme.privateAccent : Theme.accent) : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle())
        .overlay(alignment: .leading) { if let selection { SelectionMark(selection: selection, id: tab.id) } }
        .onTapGesture {
            if let selection, selection.active { selection.toggle(tab.id) } else { model.select(tab.id); model.hideOverview() }
        }
        .contextMenu { TabMenuItems(tab: tab) }
        // Press and hold, then drag onto another tab to put the dragged one in front of it.
        .draggable(String(tab.id))
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let dragged = UInt64(raw), dragged != tab.id else { return false }
            return model.acceptDroppedTab(dragged, before: tab.id)
        }
        #if os(iOS)
        .modifier(SwipeToClose(tab: tab))
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tab-row")
    }
}

struct TabCard: View {
    @EnvironmentObject var model: BrowserModel
    @Environment(\.overviewSelection) private var selection
    @ObservedObject var tab: TabController
    let selected: Bool

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                preview
                    .frame(maxWidth: .infinity).frame(height: 130)
                    .clipped()
                Button { model.closeTab(id: tab.id) } label: {
                    Image(systemName: "xmark.circle.fill").font(.title3).accessibilityLabel("Close tab")
                        .symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.55))
                }
                .buttonStyle(.plain).padding(6)
                .accessibilityLabel("Close tab")
            }
            HStack(spacing: 6) {
                if tab.isPrivate { Image(systemName: "eye.slash.fill").font(.caption).foregroundStyle(Theme.privateAccent) }
                if tab.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                Text(tab.displayTitle).font(.callout).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .themedFill(in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous), fallback: .background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
            .stroke(selected ? (tab.isPrivate ? Theme.privateAccent : Theme.accent) : Color.primary.opacity(0.10),
                    lineWidth: selected ? 2.5 : 1))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
        .contentShape(Rectangle())
        .overlay(alignment: .topLeading) { if let selection { SelectionMark(selection: selection, id: tab.id) } }
        .onTapGesture {
            if let selection, selection.active { selection.toggle(tab.id); return }
            model.select(tab.id)
            model.hideOverview()
        }
        .contextMenu { TabMenuItems(tab: tab) }
        // Press and hold, then drag onto another tab to put the dragged one in front of it.
        .draggable(String(tab.id))
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let dragged = UInt64(raw), dragged != tab.id else { return false }
            return model.acceptDroppedTab(dragged, before: tab.id)
        }
        #if os(iOS)
        .modifier(SwipeToClose(tab: tab))
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tab-card")
    }

    @ViewBuilder private var preview: some View {
        if model.tabPreviews, let data = tab.snapshot, let image = Image(platformData: data) {
            // The picture fills the column and is cropped to it; sized as an overlay so its own width never widens the card.
            Color.clear.overlay(alignment: .top) { image.resizable().scaledToFill() }.clipped()
        } else {
            ZStack {
                (tab.isPrivate ? Theme.privateAccent : Theme.accent).opacity(0.10)
                if tab.isBlank {
                    Image(systemName: tab.isPrivate ? "eye.slash" : "safari").font(.largeTitle).foregroundStyle(.secondary)
                } else {
                    SiteTile(url: tab.url?.absoluteString ?? "", title: tab.title, size: 56)
                }
            }
        }
    }
}

struct TabOverview: View {
    @EnvironmentObject var model: BrowserModel
    @StateObject private var selection = OverviewSelection()
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var tabs: [TabController] {
        let matching = query.isEmpty ? model.visibleTabs : model.visibleTabs.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(query) || ($0.url?.absoluteString.localizedCaseInsensitiveContains(query) ?? false)
        }
        switch model.overviewSort {
        case .manual: return matching
        case .recent: return matching.sorted { $0.lastActive > $1.lastActive }
        case .title: return matching.sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
        case .website: return matching.sorted { (FaviconStore.key(forHost: $0.url?.host) ?? "~") < (FaviconStore.key(forHost: $1.url?.host) ?? "~") }
        }
    }

    /// The tabs under a heading each, one heading per website, when "Group by Website" is on.
    private var groups: [(host: String, tabs: [TabController])] {
        var order: [String] = []
        var buckets: [String: [TabController]] = [:]
        for tab in tabs {
            let key = FaviconStore.key(forHost: tab.url?.host) ?? "New tabs"
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(tab)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    private var viewMenu: some View {
        Menu {
            Picker("View", selection: $model.overviewStyle) {
                ForEach(OverviewStyle.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            Toggle("Group by Website", isOn: $model.overviewGrouped)
            Picker("Sort By", selection: $model.overviewSort) {
                ForEach(OverviewSort.allCases) { Text($0.title).tag($0) }
            }
        } label: { Image(systemName: model.overviewStyle.symbol) }
            .help("View and sort").accessibilityLabel("View options").accessibilityIdentifier("overview-options")
    }

    @ViewBuilder private func tabViews(_ list: [TabController]) -> some View {
        if model.overviewStyle == .grid {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 300), spacing: 14)], spacing: 14) {
                ForEach(list) { tab in TabCard(tab: tab, selected: tab.id == model.activeID) }
            }
        } else {
            LazyVStack(spacing: 6) {
                ForEach(list) { tab in TabListRow(tab: tab, selected: tab.id == model.activeID) }
            }
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                #if os(iOS)
                Picker("", selection: Binding(get: { model.privateMode }, set: { switchMode(private: $0) })) {
                    Text("Tabs").tag(false)
                    Text("Private").tag(true)
                }
                .pickerStyle(.segmented).frame(maxWidth: 220)
                #endif
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search Tabs", text: $query).textFieldStyle(.plain).focused($searchFocused)
                        .accessibilityIdentifier("tab-search")
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").accessibilityLabel("Clear") }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: Theme.pillRadius))
                .frame(maxWidth: 360)
                Spacer()
                if selection.active {
                    Button("All") { selection.ids = Set(tabs.map(\.id)) }.accessibilityIdentifier("overview-select-all")
                    Button("Close \(selection.ids.count)", role: .destructive) {
                        let doomed = selection.ids
                        animated(.easeOut(duration: 0.2)) { for id in doomed { model.closeTab(id: id) } }
                        selection.end()
                    }
                    .disabled(selection.ids.isEmpty).accessibilityIdentifier("overview-close-selected")
                }
                Button(selection.active ? "Cancel" : "Select") { animated(.easeInOut(duration: 0.2)) { if selection.active { selection.end() } else { selection.active = true } } }
                    .accessibilityIdentifier("overview-select")
                viewMenu
                Button { model.newTab(); model.hideOverview() } label: { Image(systemName: "plus").accessibilityLabel("New tab") }
                    .help("New Tab").accessibilityLabel("New tab")
                Button("Done") { model.hideOverview() }.keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("overview-done")
            }
            if !model.separatesPrivate || !model.privateMode {
                HStack(spacing: 10) { WorkspaceMenu().fixedSize(); GroupChips() }
            }
            ScrollView {
                if tabs.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "No Tabs" : "No Matching Tabs", systemImage: "square.on.square")
                        .padding(.top, 60)
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        if model.overviewGrouped {
                            ForEach(groups, id: \.host) { group in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(group.host).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                                        Spacer()
                                        Button {
                                            let ids = group.tabs.map(\.id)
                                            animated(.easeOut(duration: 0.2)) { for id in ids { model.closeTab(id: id) } }
                                        } label: {
                                            Text("Close \(group.tabs.count)").font(.footnote.weight(.medium))
                                        }
                                        .buttonStyle(.plain).foregroundStyle(Theme.accent)
                                        .help("Close all \(group.tabs.count) tabs from \(group.host)")
                                        .accessibilityLabel("Close all tabs from \(group.host)")
                                    }
                                    tabViews(group.tabs)
                                }
                            }
                        } else {
                            tabViews(tabs)
                        }
                    }
                    .padding(.bottom, 20)
                    .motion(.easeInOut(duration: 0.2), value: model.overviewStyle)
                    .motion(.easeInOut(duration: 0.2), value: model.overviewGrouped)
                }
            }
        }
        .padding(18)
        .environment(\.overviewSelection, selection)
        .modifier(OverlayBackground())
        #if os(macOS)
        .onExitCommand { model.hideOverview() }
        #endif
        .onAppear { query = "" }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tab-overview")
    }

    #if os(iOS)
    private func switchMode(private isPrivate: Bool) {
        model.privateMode = isPrivate
        if let first = model.visibleTabs.first { model.select(first.id) } else { model.openTab(url: nil, isPrivate: isPrivate) }
    }
    #endif
}

struct OverlayBackground: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if reduceTransparency { content.background(Color.platformBackground) } else { content.themedBar(fallback: .regularMaterial) }
    }
}

struct WorkspaceMenu: View {
    @EnvironmentObject var model: BrowserModel
    /// A plain header row with no fill and no chevron.
    var flat = false
    @State private var hovering = false

    private var currentIcon: String { model.workspaces.first { $0.name == model.activeWorkspace }?.icon ?? "person" }
    private var currentName: String { model.activeWorkspace.isEmpty ? "Personal" : model.activeWorkspace }

    var body: some View {
        Menu {
            Button { model.switchWorkspace("") } label: {
                Label("Personal", systemImage: model.activeWorkspace.isEmpty ? "checkmark" : "person")
            }
            ForEach(model.workspaces) { ws in
                Button { model.switchWorkspace(ws.name) } label: {
                    Label(ws.name, systemImage: ws.name == model.activeWorkspace ? "checkmark" : ws.icon)
                }
            }
            Divider()
            Button("New Workspace…") { promptNewWorkspace(model: model) }
            if !model.activeWorkspace.isEmpty {
                Button("Rename “\(model.activeWorkspace)”…") { promptRenameWorkspace(model: model, name: model.activeWorkspace) }
                Button("Delete “\(model.activeWorkspace)”", role: .destructive) { model.deleteWorkspace(model.activeWorkspace) }
            }
            Button("Manage Workspaces…") {
                #if os(macOS)
                SettingsRouter.open(.tabs)
                #else
                model.sheet = .settings
                #endif
            }
        } label: {
            HStack {
                Image(systemName: currentIcon).foregroundStyle(Theme.accent)
                Text(currentName).font(flat ? .system(size: 12.5, weight: .semibold) : .callout.weight(.medium))
                Spacer()
                if !flat { Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 10).padding(.vertical, flat ? 0 : 6)
            .frame(height: flat ? 32 : nil)
            .background(Color.primary.opacity(flat ? (hovering ? 0.07 : 0) : 0.07), in: RoundedRectangle(cornerRadius: flat ? 14 : 10, style: .continuous))
            .contentShape(Rectangle())
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        #endif
        .onHover { hovering = $0 }
        .accessibilityLabel("Workspace: \(currentName)")
    }
}

func promptRenameWorkspace(model: BrowserModel, name: String) {
    Task { @MainActor in
        if let new = await Dialogs.promptText(title: "Rename Workspace", message: "New name for “\(name)”.", placeholder: name), !new.isEmpty {
            model.renameWorkspace(name, to: new)
        }
    }
}

func promptNewWorkspace(model: BrowserModel) {
    Task { @MainActor in
        if let name = await Dialogs.promptText(title: "New Workspace", message: "Name this workspace.", placeholder: ""), !name.isEmpty {
            model.createWorkspace(name)
            model.switchWorkspace(name.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
