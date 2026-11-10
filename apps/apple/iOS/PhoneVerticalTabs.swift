import SwiftUI

/// While a page is read the dock folds into small floating pills. The address pill is on the right (PhoneCompactPill); this is its mirror on the left: a round
/// button with the number of tabs that opens the tabs as a vertical list. Tap opens the list; a long press offers a new tab, a private tab and the overview.
struct PhoneTabsPill: View {
    @EnvironmentObject var model: BrowserModel
    @Binding var isOpen: Bool

    /// How many tabs are open, when there is more than one.
    @ViewBuilder private var badge: some View {
        if model.visibleTabs.count > 1 {
            Text(model.visibleTabs.count > 99 ? "99+" : "\(model.visibleTabs.count)")
                .font(.system(size: 10, weight: .bold)).foregroundStyle(Color.white).lineLimit(1).minimumScaleFactor(0.7)
                .padding(.horizontal, 4).frame(minWidth: 16, minHeight: 16)
                .background(Theme.accent, in: Capsule())
        }
    }
    /// 48 as a pill of its own; smaller when it is one of the buttons that fan out of the address pill.
    var size: CGFloat = 48

    var body: some View {
        // A tap opens the list; a press and hold opens a menu. One menu with a primary action, not a context menu: the lifted preview of a context menu flickered here.
        Menu {
            Button("New Tab", systemImage: "plus") { _ = model.newTab() }
            Button("New Private Tab", systemImage: "eye.slash") { _ = model.openTab(url: nil, isPrivate: true) }
            if !model.phoneSpec.fanOut { Button("All Tabs", systemImage: "square.grid.2x2") { model.showOverview() } }
            Button("Reopen Closed Tab", systemImage: "arrow.uturn.backward") { model.reopenClosedTab() }.disabled(model.closedTabs.isEmpty)
        } label: {
            // The system's own tabs symbol (the two overlapping squares of Safari's tabs button), with a small badge for how many tabs are open.
            Group {
                if size < 44 {
                    let count = model.visibleTabs.count
                    let text = count > 99 ? "99+" : "\(count)"
                    // The count is drawn inside the button itself (a rounded square with the number), so there is no badge to collide with the buttons beside it.
                    Text(text).font(.system(size: count > 9 ? 12 : 14, weight: .bold)).lineLimit(1).minimumScaleFactor(0.6)
                        .frame(width: 24, height: 24).overlay(RoundedRectangle(cornerRadius: 7).stroke(lineWidth: 1.7))
                } else {
                    Image(systemName: "square.on.square").font(.system(size: 19, weight: .regular))
                }
            }
            .foregroundStyle(Color.primary)
            .frame(width: size, height: size)
            .contentShape(Circle())
        } primaryAction: {
            if !SwipeGuard.recent { UIImpactFeedbackGenerator(style: .light).impactOccurred(); isOpen = true }
        }
        .menuOrder(.fixed)
        .buttonStyle(.plain)
        .floatingGlassCapsule(solidity: 0.4)
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
        // The number is drawn over the button, outside its rounded edge: inside it the edge cut the number off, and only a blue dot was left.
        .overlay(alignment: .topTrailing) { if size >= 44 { badge.offset(x: 5, y: -5).allowsHitTesting(false) } }
        // Swipe it toward the page to open the list; swipe it up for all the tabs at once.
        .simultaneousGesture(
            DragGesture(minimumDistance: 20).onEnded { value in
                SwipeGuard.stamp()
                let dx = value.translation.width, dy = value.translation.height
                if abs(dx) > abs(dy), dx > 40 { UIImpactFeedbackGenerator(style: .light).impactOccurred(); isOpen = true }
                else if abs(dy) > abs(dx), dy < -40 { UIImpactFeedbackGenerator(style: .light).impactOccurred(); if model.phoneSpec.fanOut { isOpen = true } else { model.showOverview() } }
            }
        )
        .accessibilityLabel("Tabs, \(model.visibleTabs.count) open")
        .accessibilityIdentifier("compact-tabs")
    }
}

/// The things a tab can be asked to do from the list, written once.
enum PhoneTabActions {
    /// Asks for a name of the person's own, shown instead of the page title (an empty answer goes back to the title).
    @MainActor static func rename(_ tab: TabController, in model: BrowserModel) {
        Task { @MainActor in
            if let text = await Dialogs.promptText(title: "Name This Tab", message: "A name of your own, shown instead of the page title.", placeholder: model.tabMeta[tab.id]?.name ?? tab.displayTitle) {
                model.setTabName(tab, text)
            }
        }
    }
}

/// The tabs as a vertical list that slides in from the left over the page.
///
/// - Pinned tabs come first, then each group (with its colour), then the rest; a search box appears once there are more than a handful of tabs.
/// - A tap goes to the tab. Swipe a row left to close it, or right to pin it or to rename it. Press and hold a row for everything a tab can do: rename, pin, lock,
///   duplicate, mute, send to another device, snooze, move to a group or workspace, add to Essentials, close the others, and more.
/// - The ⋯ menu has all tabs, reopen the last closed tab, close the others and clear the unpinned ones. A tap outside, a swipe to the left or Done closes the list.
struct PhoneVerticalTabs: View {
    @EnvironmentObject var model: BrowserModel
    @Binding var isOpen: Bool
    @State private var query = ""

    private func close() { withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) { isOpen = false } }

    private struct TabSection: Identifiable {
        let id: String
        let title: String?
        let color: Color?
        let tabs: [TabController]
    }

    private var matching: [TabController] {
        let all = model.visibleTabs
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return all }
        return all.filter { $0.displayTitle.localizedCaseInsensitiveContains(q) || ($0.url?.absoluteString ?? "").localizedCaseInsensitiveContains(q) }
    }

    private var sections: [TabSection] {
        // With the tab tree on, the tabs under a folded branch are left out of the list (a search shows every match, folded or not).
        let list = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? model.treeVisible(matching) : matching
        var out: [TabSection] = []
        let pinned = list.filter(\.pinned)
        if !pinned.isEmpty { out.append(TabSection(id: "pinned", title: "Pinned", color: nil, tabs: pinned)) }
        let rest = list.filter { !$0.pinned }
        for name in model.groupNames {
            let inGroup = rest.filter { $0.group == name }
            if !inGroup.isEmpty { out.append(TabSection(id: "group-" + name, title: name, color: model.groupColor(name)?.color, tabs: inGroup)) }
        }
        let loose = rest.filter { $0.group.isEmpty || !model.groupNames.contains($0.group) }
        if !loose.isEmpty { out.append(TabSection(id: "tabs", title: out.isEmpty ? nil : "Tabs", color: nil, tabs: loose)) }
        return out
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // No scrim: the page behind keeps its brightness. A tap outside the panel still closes it (a clear, hit-testable layer).
                Color.clear.ignoresSafeArea().contentShape(Rectangle()).onTapGesture { close() }.accessibilityHidden(true)
                VStack(spacing: 0) {
                    header
                    if model.visibleTabs.count > 5 { searchField }
                    ScrollViewReader { proxy in
                        List {
                            ForEach(sections) { section in
                                // How far in each tab sits under the tab it was opened from, within this section (a tab whose parent is in another section starts at the edge).
                                let depths = model.tabTree && query.isEmpty ? TabOrganizing.depths(section.tabs.map { ($0.id, model.tabMeta[$0.id]?.parent) }) : [:]
                                SwiftUI.Section {
                                    ForEach(section.tabs) { tab in
                                        PhoneVerticalTabRow(tab: tab, current: tab.id == model.activeID, depth: depths[tab.id] ?? 0, onChoose: { model.select(tab.id); close() })
                                            .listRowInsets(EdgeInsets(top: 3, leading: 10, bottom: 3, trailing: 10))
                                            .listRowBackground(Color.clear)
                                            .listRowSeparator(.hidden)
                                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                                Button(role: .destructive) { model.closeTab(id: tab.id) } label: { Label("Close", systemImage: "xmark") }
                                            }
                                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                                Button { model.togglePin(tab) } label: { Label(tab.pinned ? "Unpin" : "Pin", systemImage: tab.pinned ? "pin.slash" : "pin") }.tint(.orange)
                                                Button { PhoneTabActions.rename(tab, in: model) } label: { Label("Rename", systemImage: "pencil") }.tint(.blue)
                                            }
                                    }
                                } header: {
                                    if let title = section.title {
                                        HStack(spacing: 6) {
                                            if let color = section.color { Circle().fill(color).frame(width: 8, height: 8) }
                                            else if section.id == "pinned" { Image(systemName: "pin.fill").font(.system(size: 10)) }
                                            Text(title).font(.system(size: 12, weight: .semibold)).textCase(nil)
                                        }
                                        .foregroundStyle(.secondary)
                                        .padding(.leading, 6)
                                    }
                                }
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .overlay { if sections.isEmpty { ContentUnavailableView.search(text: query) } }
                        // Opens at the tab that is in front, however far down the list it is.
                        .onAppear { if let id = model.activeID { DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) } } }
                    }
                }
                .frame(width: min(340, geo.size.width * 0.86))
                // As tall as its tabs need, up to the screen: a short list is a short card, not a tall one that is mostly empty.
                .frame(height: panelHeight(available: geo.size.height - 16))
                .phoneGlassCard(cornerRadius: 26)      // the same surface as the pills, so it follows the theme
                .padding(.leading, 8).padding(.vertical, 8)
                .frame(maxHeight: .infinity, alignment: .top)
                // Alongside the list's own scrolling, never against it: a gesture that competed with it made the list hitch.
                .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { if abs($0.translation.width) > abs($0.translation.height), $0.translation.width < -60 { close() } })
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Tabs")
                .accessibilityAction(.escape) { close() }
            }
        }
        .transition(.move(edge: .leading).combined(with: .opacity))
    }

    /// What the card needs for its header, its search box (when there are many tabs) and its rows, but no more than `available`.
    private func panelHeight(available: CGFloat) -> CGFloat {
        let rows = CGFloat(sections.reduce(0) { $0 + $1.tabs.count })
        let titles = sections.count > 1 ? CGFloat(sections.count) * 30 : 0
        let search: CGFloat = model.visibleTabs.count > 5 ? 52 : 0
        return min(available, max(160, 70 + search + titles + rows * 52 + 16))
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text("Tabs").font(.system(size: 17, weight: .bold))
            Text("\(model.visibleTabs.count)").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 2)
            Spacer()
            Button { _ = model.newTab(); close() } label: { Image(systemName: "plus").font(.system(size: 16, weight: .semibold)).frame(width: 36, height: 36) }
                .accessibilityLabel("New tab")
            Button { _ = model.openTab(url: nil, isPrivate: true); close() } label: { Image(systemName: "eye.slash").font(.system(size: 15, weight: .semibold)).frame(width: 36, height: 36) }
                .accessibilityLabel("New private tab")
            Menu {
                if !model.phoneSpec.fanOut { Button("All Tabs", systemImage: "square.grid.2x2") { close(); model.showOverview() } }
                Button("Reopen Closed Tab", systemImage: "arrow.uturn.backward") { model.reopenClosedTab() }.disabled(model.closedTabs.isEmpty)
                Divider()
                Button("Close Other Tabs", systemImage: "xmark.square") { if let id = model.activeID { model.closeOtherTabs(except: id) } }.disabled(model.visibleTabs.count < 2)
                Button("Clear Unpinned Tabs", systemImage: "trash", role: .destructive) { model.clearTabs() }.disabled(model.clearableTabs().count < 2)
            } label: { Image(systemName: "ellipsis.circle").font(.system(size: 17)).frame(width: 36, height: 36) }
                .accessibilityLabel("More")
            Button("Done") { close() }.font(.system(size: 15, weight: .semibold)).padding(.leading, 2)
        }
        .foregroundStyle(Color.primary)
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            TextField("Search tabs", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled().font(.system(size: 15))
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.primary.opacity(0.07), in: Capsule())
        .padding(.horizontal, 12).padding(.bottom, 6)
    }
}

private struct PhoneVerticalTabRow: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController
    @ObservedObject private var icons = FaviconStore.shared
    let current: Bool
    /// How far in it is drawn when the tab tree is on.
    var depth = 0
    let onChoose: () -> Void

    private var host: String { tab.url?.host?.replacingOccurrences(of: "www.", with: "") ?? "" }
    private var barColor: Color? { model.tabMeta[tab.id]?.color.flatMap(GroupColor.init(rawValue:))?.color }

    var body: some View {
        HStack(spacing: 8) {
            // A tab opened from another sits one step in from it, with a fold arrow where it has tabs under it, as on the Mac.
            if depth > 0 { Color.clear.frame(width: CGFloat(depth) * 16, height: 1) }
            if model.tabTree, !(model.hasTreeChildren(tab)) { Color.clear.frame(width: 22, height: 32) }       // the slot of the fold arrow, so tabs without children line up
            if model.hasTreeChildren(tab) {
                let folded = model.collapsedTreeTabs.contains(tab.id)
                Button { withAnimation(.easeOut(duration: 0.18)) { model.toggleTreeBranch(tab) } } label: {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(folded ? 0 : 90)).frame(width: 22, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(folded ? "Show tabs opened from this one" : "Hide tabs opened from this one")
            }
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(barColor ?? .clear).frame(width: 3, height: 30)
            Button(action: onChoose) {
                HStack(spacing: 10) {
                    ZStack {
                        icon.frame(width: 26, height: 26)
                        if tab.isLoading { ProgressView().controlSize(.mini).padding(4).background(.ultraThinMaterial, in: Circle()) }
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tab.isBlank ? "New Tab" : tab.displayTitle).font(.system(size: 14, weight: current ? .semibold : .medium)).lineLimit(1)
                        if !host.isEmpty { Text(host).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer(minLength: 0)
                    if tab.pinned { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(.secondary) }
                    if tab.isLocked { Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(.secondary) }
                    if let status = model.tabMeta[tab.id]?.status { Image(systemName: status.symbol).font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if tab.playingAudio || tab.muted {
                Button { tab.setMuted(!tab.muted) } label: {
                    Image(systemName: tab.muted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.system(size: 12)).foregroundStyle(Theme.accent).frame(width: 28, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.muted ? "Unmute" : "Mute")
            }
            Button { model.closeTab(id: tab.id) } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary).frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(tab.displayTitle)")
        }
        .padding(.leading, 6).padding(.trailing, 6).padding(.vertical, 6)
        .background(current ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        // Press and hold: Rename first, then the whole menu a tab has everywhere else (pin, lock, duplicate, mute, send, snooze, groups, workspaces, Essentials, close the others...).
        .contextMenu {
            Button("Rename…", systemImage: "pencil") { PhoneTabActions.rename(tab, in: model) }
            if let url = tab.url, !tab.isBlank {
                Button("Copy Link", systemImage: "link") { copyToPasteboard(url.absoluteString); model.notice = "Link copied." }
                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
            }
            Divider()
            TabMenuItems(tab: tab)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(current ? .isSelected : [])
        .accessibilityAction(named: "Rename") { PhoneTabActions.rename(tab, in: model) }
        .accessibilityAction(named: tab.pinned ? "Unpin" : "Pin") { model.togglePin(tab) }
    }

    @ViewBuilder private var icon: some View {
        if tab.isPrivate { Image(systemName: "eye.slash.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.privateAccent) }
        else if tab.isBlank { Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .semibold)) }
        else if let url = tab.url, let image = icons.image(forURL: url.absoluteString, points: 22) {
            Image(uiImage: image).resizable().scaledToFit().frame(width: 22, height: 22).clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            Image(systemName: "globe").font(.system(size: 14, weight: .semibold))
        }
    }
}
