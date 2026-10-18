import SwiftUI

// MARK: - Shared pieces

/// Favicon slot: a spinner while loading, the private mark in private tabs, otherwise a local letter tile.
/// (No icon is fetched from the network.)
struct TabFavicon: View {
    @ObservedObject var tab: TabController
    var size: CGFloat = 16

    var body: some View {
        ZStack {
            if let panel = tab.panelSheet {
                Image(systemName: panel == .bookmarks ? "book.fill" : panel == .history ? "clock.fill" : "arrow.down.circle.fill").font(.system(size: size * 0.8)).foregroundStyle(Theme.accent)
            } else if tab.isSettingsPage {
                Image(systemName: "gearshape.fill").font(.system(size: size * 0.8)).foregroundStyle(Theme.accent)
            } else if tab.isLoading {
                ProgressView().controlSize(.mini).scaleEffect(0.8)
            } else if tab.isPrivate {
                Image(systemName: "eye.slash.fill").font(.system(size: size * 0.7)).foregroundStyle(Theme.privateAccent)
            } else if tab.isShowingError {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: size * 0.7)).foregroundStyle(.orange)
            } else {
                SiteTile(url: tab.url?.absoluteString ?? "", title: tab.title, size: size).opacity(tab.isBlank ? 0.35 : 1)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The picture that follows the pointer while a tab is dragged: the site mark and name on a glass card with an accent edge.
struct TabDragCard: View {
    @ObservedObject var tab: TabController
    var body: some View {
        HStack(spacing: 8) {
            SiteTile(url: tab.url?.absoluteString ?? "", title: tab.title, size: 20)
            Text(tab.displayTitle).font(.system(size: 13, weight: .medium)).lineLimit(1).frame(maxWidth: 180, alignment: .leading)
        }
        .padding(.horizontal, 12).frame(height: 36)
        .themedFill(in: Capsule(), fallback: .regularMaterial)
        .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.9), lineWidth: 1.5))
        .shadow(color: Theme.accent.opacity(0.35), radius: 10, y: 4)
        .padding(10)
    }
}

struct TabCloseButton: View {
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(hovering ? 0.9 : 0.55))
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.14 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Close Tab")
        .accessibilityLabel("Close tab")
    }
}

/// Selected tabs are raised rounded cards; hovered ones get a quiet wash; idle ones sit flat on the chrome.
private struct TabBackground: ViewModifier {
    let selected: Bool
    let hovering: Bool
    let radius: CGFloat
    var outlined = false
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(selected ? Color.selectedTab : (hovering ? Color.primary.opacity(0.07) : Color.clear))
                    .shadow(color: .black.opacity(selected ? 0.10 : 0), radius: 1, y: 0.8)
            )
            .overlay {
                if selected && outlined {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                        .transition(.opacity)
                }
            }
            .motion(.easeOut(duration: 0.16), value: selected)
            .motion(.easeOut(duration: 0.12), value: hovering)
    }
}

private extension View {
    func tabBackground(selected: Bool, hovering: Bool, radius: CGFloat = Radius.tab, outlined: Bool = false) -> some View {
        modifier(TabBackground(selected: selected, hovering: hovering, radius: radius, outlined: outlined))
    }
}

private struct TabInteractions: ViewModifier {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController
    @State private var dropTargeted = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var showPreview = false
    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            // Resting the pointer on a tab shows a preview card after a short delay; moving away or pressing hides it.
            .onHover { inside in
                hoverTask?.cancel()
                guard inside, model.hoverPreviews, !tab.isInternalPage else { showPreview = false; return }
                hoverTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(Int(model.hoverDelay * 1000)))
                    if !Task.isCancelled { showPreview = true }
                }
            }
            .popover(isPresented: $showPreview, arrowEdge: model.effectiveTabLayout == .sidebar ? (model.sidebarPosition == .left ? .trailing : .leading) : .bottom) {
                TabPreviewCard(tab: tab).allowsHitTesting(false)
            }
            .onTapGesture { showPreview = false; model.select(tab.id) }
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.return) { model.select(tab.id); return .handled }
            .onKeyPress(.space) { model.select(tab.id); return .handled }
            .accessibilityAction { model.select(tab.id) }
            .accessibilityAction(named: Text("Close tab")) { model.closeTab(id: tab.id) }
            .contextMenu { TabMenuItems(tab: tab) }
            // A middle click closes the tab, as in the sidebar.
            .overlay(MiddleClickCatcher { if !tab.isLocked { model.closeTab(id: tab.id) } })
            // What you carry is a small card of its own: the site's mark, its name and a glow in the accent colour.
            .draggable(String(tab.id)) { TabDragCard(tab: tab) }
            // The tab it will land in front of lifts and lights up in the accent colour.
            .overlay {
                RoundedRectangle(cornerRadius: Radius.tab, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: 1.5)
                    .background(RoundedRectangle(cornerRadius: Radius.tab, style: .continuous).fill(Theme.accent.opacity(0.14)))
                    .opacity(dropTargeted ? 1 : 0).allowsHitTesting(false)
            }
            .scaleEffect(dropTargeted ? 1.03 : 1)
            .motion(.spring(response: 0.25, dampingFraction: 0.75), value: dropTargeted)
            .dropDestination(for: String.self) { items, _ in
                guard let raw = items.first, let dragged = UInt64(raw), dragged != tab.id else { return false }
                return model.acceptDroppedTab(dragged, before: tab.id)
            } isTargeted: { dropTargeted = $0 }
            // A link or address dropped on a tab opens in a new tab beside it.
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first, url.scheme == "http" || url.scheme == "https" else { return false }
                model.openTab(url: url, isPrivate: tab.isPrivate)
                return true
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(tab.displayTitle)
            .accessibilityAddTraits(tab.id == model.activeID ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier("tab-chip")
    }
}

extension View {
    func tabInteractions(_ tab: TabController) -> some View { modifier(TabInteractions(tab: tab)) }
}

// MARK: - Horizontal strip

struct HorizontalTab: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController
    let selected: Bool
    let width: CGFloat
    @State private var hovering = false

    var body: some View {
        // The title (with its icon) is centred in the tab; the close button waits at the leading edge.
        ZStack {
            HStack(spacing: 5) {
                TabFavicon(tab: tab, size: 14)
                Text(tab.displayTitle)
                    .font(.system(size: 12, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.62))
                    .lineLimit(1).truncationMode(.tail)
                AudioBadge(tab: tab)
            }
            .padding(.horizontal, 26)
            HStack {
                if selected || hovering { TabCloseButton { model.closeTab(id: tab.id) } }
                Spacer(minLength: 0)
            }
            .padding(.leading, 5)
        }
        .frame(width: width, height: model.density.stripPillHeight)
        .tabBackground(selected: selected, hovering: hovering, radius: model.density.stripPillHeight / 2, outlined: true)
        .transition(.scale(scale: 0.88).combined(with: .opacity))
        .onHover { hovering = $0 }
        .modifier(TabTooltip(title: tab.displayTitle))
        .tabInteractions(tab)
    }
}

/// Pinned tabs are icon tiles at the start of the strip.
struct PinnedTab: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        TabFavicon(tab: tab, size: 16)
            .frame(width: 36, height: model.density.stripPillHeight)
            .tabBackground(selected: selected, hovering: hovering, radius: model.density.stripPillHeight / 2, outlined: true)
            .onHover { hovering = $0 }
            .modifier(TabTooltip(title: tab.displayTitle))
            .tabInteractions(tab)
    }
}

/// An open tab in the Minimal layout that is not selected: its icon, which turns into a close button when the pointer is on it.
struct CompactTab: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController
    @State private var hovering = false

    var body: some View {
        ZStack {
            TabFavicon(tab: tab, size: 16).opacity(hovering && !tab.isLocked ? 0 : 1)
            if !tab.isLocked { TabCloseButton { model.closeTab(id: tab.id) }.opacity(hovering ? 1 : 0).allowsHitTesting(hovering) }
        }
        .frame(width: 36, height: model.density.stripPillHeight)
        .tabBackground(selected: false, hovering: hovering, radius: model.density.stripPillHeight / 2, outlined: true)
        .onHover { hovering = $0 }
        .motion(.easeOut(duration: 0.14), value: hovering)
        .modifier(TabTooltip(title: tab.displayTitle))
        .tabInteractions(tab)
    }
}

struct HorizontalTabStrip: View {
    @EnvironmentObject var model: BrowserModel
    static let minTab: CGFloat = 120
    /// Each tab is a separate capsule: Apple's rule for large controls is a radius of half the height.
    static let pillHeight: CGFloat = 28
    static let gap: CGFloat = 4
    static let height: CGFloat = 36
    /// Tabs share the whole row, so a few tabs are wide.
    static let maxTab: CGFloat = 800

    var body: some View {
        GeometryReader { geo in
            let tabs = model.visibleTabs
            let pinned = tabs.filter(\.pinned)
            let regular = tabs.filter { !$0.pinned }
            let plusWidth: CGFloat = 32
            let reserved = CGFloat(pinned.count) * (36 + Self.gap) + plusWidth + 16
            let available = geo.size.width - reserved
            let raw = regular.isEmpty ? Self.maxTab : (available - CGFloat(regular.count) * Self.gap) / CGFloat(regular.count)
            let tabWidth = min(Self.maxTab, max(Self.minTab, raw))

            HStack(spacing: Self.gap) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Self.gap) {
                            ForEach(pinned) { PinnedTab(tab: $0, selected: $0.id == model.activeID).id($0.id) }
                            if !pinned.isEmpty && !regular.isEmpty { Capsule().fill(Color.primary.opacity(0.14)).frame(width: 1, height: 14).padding(.horizontal, 3) }
                            ForEach(regular) { HorizontalTab(tab: $0, selected: $0.id == model.activeID, width: tabWidth).id($0.id) }
                        }
                        .motion(.spring(response: 0.34, dampingFraction: 0.86), value: regular.map(\.id))
                        .motion(.spring(response: 0.34, dampingFraction: 0.86), value: pinned.map(\.id))
                        .padding(.leading, 8).padding(.trailing, 2)
                    }
                    .onChange(of: model.activeID) { _, id in if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } } }
                }
                newTabButton.padding(.trailing, 6)
            }
            .frame(height: geo.size.height)
        }
        .frame(height: model.density.stripHeight)
        .background(WindowDragRegion())
        .acceptsDroppedTabs(model)
        .accessibilityIdentifier("tab-bar")
    }

    private var newTabButton: some View {
        ChromeButton(symbol: "plus", help: "New Tab", identifier: "new-tab-inline") { model.newTab() }
            .scaleEffect(0.9)
    }
}

// MARK: - Compact strip

/// A single slim row: the selected tab shows its title, the others show only their icon.
struct CompactTabStrip: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        if model.singleRow { EmptyView() } else { strip }
    }

    private var strip: some View {
        HStack(spacing: 2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(model.visibleTabs) { tab in
                        if tab.id == model.activeID && !tab.pinned {
                            HorizontalTab(tab: tab, selected: true, width: 170)
                        } else if tab.pinned {
                            PinnedTab(tab: tab, selected: tab.id == model.activeID)
                        } else {
                            CompactTab(tab: tab)
                        }
                    }
                }
                .padding(.horizontal, 6)
            }
            ChromeButton(symbol: "plus", help: "New Tab", identifier: "new-tab-inline") { model.newTab() }.scaleEffect(0.85)
        }
        .frame(height: model.density.stripHeight)
        .background(WindowDragRegion())
        .acceptsDroppedTabs(model)
        .accessibilityIdentifier("tab-bar")
    }
}

// MARK: - Vertical rows (sidebar)

/// The small arrow on a tab that has tabs opened from it: it folds and unfolds that branch of the tree.
struct TreeFoldButton: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController
    var body: some View {
        if model.hasTreeChildren(tab) {
            let folded = model.collapsedTreeTabs.contains(tab.id)
            Button { animated(.easeOut(duration: 0.18)) { model.toggleTreeBranch(tab) } } label: {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(folded ? 0 : 90)).frame(width: 12, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel(folded ? "Show tabs opened from this one" : "Hide tabs opened from this one")
        }
    }
}

/// The count on the first tab of a stack of one website's tabs; it folds and unfolds the stack.
struct StackBadge: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController
    var body: some View {
        if let head = model.stackHead(tab) {
            Button { animated(.easeOut(duration: 0.18)) { model.toggleStack(head.key) } } label: {
                HStack(spacing: 3) {
                    Text("\(head.count)").font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold)).rotationEffect(.degrees(head.folded ? 0 : 90))
                }
                .padding(.horizontal, 6).frame(height: 16)
                .background(Capsule().fill(Theme.accent.opacity(0.2))).foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain).help(head.folded ? "Show the \(head.count) tabs from this site" : "Fold the \(head.count) tabs from this site")
            .accessibilityLabel(head.folded ? "Show stacked tabs" : "Fold stacked tabs")
        }
    }
}

/// The card that appears when the pointer rests on a tab.
struct TabPreviewCard: View {
    @ObservedObject var tab: TabController
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let data = tab.snapshot, let image = Image(platformData: data) {
                Color.clear.frame(width: 240, height: 140)
                    .overlay(alignment: .top) { image.resizable().scaledToFill() }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            Text(tab.displayTitle).font(.system(size: 12, weight: .semibold)).lineLimit(2).frame(width: 240, alignment: .leading)
            Text(tab.url?.host ?? "").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(10)
    }
}

struct VerticalTabRow: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            // A tab opened from another sits one step in from it when the tab tree is on, with a fold arrow where it has tabs under it.
            if model.tabTree { Color.clear.frame(width: CGFloat(model.treeDepth(of: tab)) * 14, height: 1) }
            TreeFoldButton(tab: tab)
            TabFavicon(tab: tab)
            Text(tab.displayTitle)
                .font(.system(size: 13, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.68))
                .lineLimit(1).truncationMode(.tail)
            StackBadge(tab: tab)
            AudioBadge(tab: tab)
            Spacer(minLength: 0)
            if tab.isLocked { Image(systemName: "lock.fill").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).help("Locked") }
            else if hovering || selected { TabCloseButton { model.closeTab(id: tab.id) } }
        }
        .padding(.horizontal, 8)
        .frame(height: model.density.tabRowHeight)
        .tabBackground(selected: selected, hovering: hovering, radius: Radius.item)
        .transition(.scale(scale: 0.95).combined(with: .opacity))
        .onHover { hovering = $0 }
        .modifier(TabTooltip(title: tab.displayTitle))
        .tabInteractions(tab)
    }
}

/// Pinned tabs in the sidebar: a grid of icon tiles.
struct PinnedTile: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController
    let selected: Bool
    var large = false
    @State private var hovering = false

    var body: some View {
        TabFavicon(tab: tab, size: large ? 24 : 20)
            .frame(maxWidth: .infinity).frame(height: large ? 48 : model.density.pinnedTileHeight)
            .tabBackground(selected: selected, hovering: hovering, radius: large ? Radius.item : 12)
            .background(RoundedRectangle(cornerRadius: large ? Radius.item : 12, style: .continuous).fill(selected ? Color.clear : Color.fieldFill))
            .onHover { hovering = $0 }
            .modifier(TabTooltip(title: tab.displayTitle))
            .tabInteractions(tab)
    }
}


/// The page-title tooltip, only when the hover preview card is off: with both, hovering a tab shows two things at once.
struct TabTooltip: ViewModifier {
    @EnvironmentObject var model: BrowserModel
    let title: String
    func body(content: Content) -> some View { content.help(model.hoverPreviews ? "" : title) }
}
