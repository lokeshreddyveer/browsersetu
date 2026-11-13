import SwiftUI

/// "One Row" is Safari's compact toolbar: one slim line holding the sidebar button, back and forward, every tab, and the share, new-tab and
/// overview buttons. The selected tab is the address field. Click it to type, ⌘L focuses it, Esc leaves it; the other tabs shrink to
/// their icon and title as more are opened, and show a close button when the pointer is over them.
struct InlineBar: View {
    @EnvironmentObject var model: BrowserModel
    /// The row's tabs do not all fit (measured by `InlineTabs`): the All Tabs menu is shown.
    @State private var rowOverflowing = false
    let leadingInset: CGFloat
    /// The width this bar has, so it can fold its optional buttons into More when the window is narrow.
    let width: CGFloat

    static let height: CGFloat = LayoutMetrics.toolbarHeight
    /// The strip that holds the tabs, and the gap between it and the selected tab's field, as in Safari.
    static let content: CGFloat = 30
    static let inset: CGFloat = 2
    var body: some View {
        // The same fold rule as the standard toolbar: below about 720 points the optional buttons move into More, so the tabs and the address field keep room.
        // At full width nothing changes, and One Row still keeps its three buttons.
        // Counts only the buttons that are switched on (as the standard toolbar does), so hidden ones take no room.
        let priority = ToolbarPriority(fitting: width, leadingInset: leadingInset, extras: model.toolbarExtrasCount, visible: model.toolbarVisibility)
        HStack(spacing: 10) {
            Color.clear.frame(width: leadingInset - 4, height: 1)
            // The toolbar settings apply here too: a button switched off in Settings is not drawn (each stays in More and the menus).
            if model.showsOnToolbar(.sidebar) {
                ChromeButton(symbol: "sidebar.left", help: "Toggle Sidebar", identifier: "sidebar-button") { model.toggleSidebar() }
            }
            if let tab = model.active, model.shows(.backForward) {
                HStack(spacing: 0) { NavigationButtons(tab: tab, showForward: priority.showForward, hideReload: true) }
            }
            InlineTabs(address: model.addressBar, overflowing: $rowOverflowing)
            HStack(spacing: 0) {
                // Pinned extension actions and the added toolbar buttons fold into their menus with the other optional buttons, so the row keeps its room.
                ExtensionActionButtons(center: model.extensionCenter, limit: priority.showOptional ? 4 : 0)
                if priority.showOptional { ToolbarExtras() }
                if priority.showOptional, model.shows(.share) {
                    if let url = model.active?.url, model.active?.isBlank == false {
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                            .buttonStyle(ChromeButtonStyle()).help("Share").accessibilityLabel("Share")
                    } else {
                        ChromeButton(symbol: "square.and.arrow.up", help: "Share", identifier: "share-button") {}.disabled(true)
                    }
                }
                if model.shows(.bookmark) && priority.showBookmark {
                    ChromeButton(symbol: model.activeBookmarked ? "star.fill" : "star", help: "Bookmark This Page", identifier: "bookmark-button",
                                 tint: model.activeBookmarked ? .yellow : nil) { model.toggleBookmark() }
                        .disabled(model.active?.isBlank ?? true)
                }
                if model.shows(.media) && priority.showDownloads { MediaToolbarButton() }
                if model.shows(.downloads) && priority.showDownloads { DownloadsToolbarButton(coordinator: model.downloads) }
                if priority.showOptional {
                    if model.shows(.newTab) { ChromeButton(symbol: "plus", help: "New Tab", identifier: "new-tab-button") { model.newTab() } }
                    if model.shows(.tabOverview) {
                        ChromeButton(symbol: "square.on.square", help: "Show Tab Overview", identifier: "overview-button") {
                            model.overviewVisible ? model.hideOverview() : model.showOverview()
                        }
                    }
                }
                // A row too full to show every tab gets the same All Tabs list as the other strips.
                if rowOverflowing { StripOverflowMenu() }
                MoreMenu(priority: priority)
            }
        }
        .padding(.trailing, 8)
        .frame(height: Self.height)
        // As the other bars: faded and without colour while the window is not in front.
        .inactiveWindowDimming()
        .background(WindowDragRegion())
        .accessibilityIdentifier("inline-bar")
    }
}

/// The tab strip. The selected tab takes the room it needs for its address field; the rest share what is left, never narrower than an icon.
struct InlineTabs: View {
    @EnvironmentObject var model: BrowserModel
    /// Watched so the strip makes room for the field as soon as typing starts.
    @ObservedObject var address: AddressBarController
    /// Set when the tabs (the field's minimum, an icon each for the rest, the group labels) are wider than the room the row has.
    @Binding var overflowing: Bool
    private let iconCell: CGFloat = 34
    private let maxCell: CGFloat = 260
    private let titleThreshold: CGFloat = 96
    /// The field the selected tab shows is never narrower than this (or the row, if smaller): the other tabs give way to it and the row scrolls.
    static let minField: CGFloat = 200
    @FocusState private var focusedTab: UInt64?
    @State private var lastFocused: UInt64?
    @Environment(\.colorSchemeContrast) private var contrast

    /// Widths for every tab: the active one first, the others sharing the rest.
    static func widths(total: CGFloat, count: Int, activeIndex: Int?, iconCell: CGFloat, maxCell: CGFloat, editing: Bool = false) -> [CGFloat] {
        guard count > 0 else { return [] }
        if count == 1 { return [min(total, 720)] }
        // No tab is marked active for a moment (one is closing, or the list is changing): every tab still gets a width.
        guard let activeIndex else { return Array(repeating: min(maxCell, max(iconCell, total / CGFloat(count))), count: count) }
        let others = CGFloat(count - 1)
        // Safari gives every tab the same width. The selected one is never narrower than a field can be read in, and the rest give way.
        let equal = total / CGFloat(count)
        // While typing, the field opens up so a whole address can be read; the other tabs give way to their icons.
        let wanted = editing ? max(equal, min(560, total * 0.6)) : min(230, equal)
        let active = max(min(total, minField), equal, min(max(230, wanted), total - others * iconCell))
        let share = min(maxCell, max(iconCell, (total - active) / others))
        return (0..<count).map { $0 == activeIndex ? active : share }
    }

    var body: some View {
        GeometryReader { geo in
            // Every group inline: its label (a fixed width), then its tabs unless it is collapsed. The tabs share what the labels leave.
            let items = model.stripItems(model.visibleTabs)
            let tabs = items.compactMap { item -> TabController? in if case .tab(let t) = item { t } else { nil } }
            let labelWidth = StripGroupLabel.estimatedWidth
            let labelCount = items.count - tabs.count
            let activeIndex = tabs.firstIndex { $0.id == model.activeID }
            let widths = Self.widths(total: max(0, geo.size.width - 24 - CGFloat(labelCount) * labelWidth), count: tabs.count, activeIndex: activeIndex, iconCell: iconCell, maxCell: maxCell, editing: address.isEditing)
            let contentWidth = widths.reduce(0, +) + CGFloat(labelCount) * labelWidth
            let labelsBeforeActive: Int = {
                guard let activeID = model.activeID, let at = items.firstIndex(where: { $0.id == "t\(activeID)" }) else { return 0 }
                return items[..<at].filter { if case .group = $0 { true } else { false } }.count
            }()
            // Worked out from the widths, not read from the animated view, so the suggestions line up with where the field will be.
            let span: InlineFieldSpan = {
                guard let activeIndex, activeIndex < widths.count else { return InlineFieldSpan(x: geo.frame(in: .global).minX, width: 320) }
                return InlineFieldSpan(x: geo.frame(in: .global).minX + 12 + widths[..<activeIndex].reduce(0, +) + CGFloat(labelsBeforeActive) * labelWidth + InlineBar.inset,
                                       width: widths[activeIndex] - InlineBar.inset * 2)
            }()
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(items) { item in
                            switch item {
                            case .tab(let tab):
                                cell(index: tabs.firstIndex { $0.id == tab.id } ?? 0, tab: tab, tabs: tabs, widths: widths)
                                    .id(tab.id)
                            case .group(let name, let count, let collapsed):
                                StripGroupLabel(name: name, count: count, collapsed: collapsed, height: InlineBar.content - InlineBar.inset * 2)
                                    .frame(width: labelWidth).id(item.id)
                            }
                        }
                    }
                    .frame(minWidth: min(contentWidth, geo.size.width), alignment: .leading)
                    .motion(.smooth(duration: 0.26), value: widths)
                    .motion(.smooth(duration: 0.2), value: model.activeID)
                    .motion(.smooth(duration: 0.26), value: tabs.map(\.id))
                }
                .onChange(of: model.activeID) { _, id in animated(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) } }
                // The selected tab (the field) stays in view when the window is resized, tabs come and go, or the field opens up for typing.
                .onAppear { keepSelectedVisible(proxy, animated: false) }
                .onChange(of: geo.size.width) { _, _ in keepSelectedVisible(proxy, animated: false) }
                // Not while typing: a tab opening or closing in the background must not move the field under the cursor.
                .onChange(of: tabs.count) { _, _ in if !address.isEditing { keepSelectedVisible(proxy, animated: false) } }
                .onChange(of: contentWidth) { _, _ in keepSelectedVisible(proxy, animated: false) }
                .onChange(of: contentWidth > geo.size.width - 24 + 0.5, initial: true) { _, full in if overflowing != full { overflowing = full } }
                .onChange(of: address.isEditing) { _, _ in keepSelectedVisible(proxy, animated: true) }
                .onChange(of: focusedTab) { old, id in stripFocusChanged(from: old, to: id, proxy: proxy) }
                // A tab dragged to either end of a row that does not fit scrolls it that way.
                .modifier(StripEdgeScroll(ids: tabs.map(\.id), proxy: proxy))
            }
            .environment(\.tabStripFocus, $focusedTab)
            .frame(height: InlineBar.content)
            // A capsule round the whole row; the selected field and the tab chips inside it are capsules too, 2 points in, so the curves are concentric.
            .background(Capsule(style: .continuous).fill(Color.primary.opacity(contrast == .increased ? 0.14 : 0.07)))
            .clipShape(Capsule(style: .continuous))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .onAppear { publish(span) }
            .onChange(of: span) { _, new in if !address.isEditing { publish(new) } }
            // While typing, the suggestions follow the field as drawn (the widths settle and the row may have scrolled); at rest the computed span is enough.
            .onPreferenceChange(InlineFieldFrameKey.self) { frame in
                if address.isEditing, let frame, frame.width > 0 { publish(InlineFieldSpan(x: frame.minX, width: frame.width)) }
            }
        }
        // The Essentials sit to the left of the row of tabs; the row gets the width that is left.
        // The identifier first, then the inset: set after it, it would replace the group chip's own.
        .accessibilityIdentifier("tab-bar")
        // The group chip (which group the row shows, and the way out of it) and the Essentials sit to the left of the row of tabs.
        .stripSide(.leading) { StripLeadingGroup(essentialsSize: 28) }
        .acceptsDroppedTabs(model)
    }

    @ViewBuilder private func cell(index: Int, tab: TabController, tabs: [TabController], widths: [CGFloat]) -> some View {
        let width: CGFloat = widths.indices.contains(index) ? widths[index] : 0
        ZStack {
            if tab.id == model.activeID {
                MacOmnibox(tab: tab, address: model.addressBar, showReload: model.shows(.reload), shield: true, tabField: true)
                    // Where the field really is on screen (the row scrolls to keep it in view, which the widths alone do not say).
                    .background(GeometryReader { g in Color.clear.preference(key: InlineFieldFrameKey.self, value: g.frame(in: .global)) })
                    .padding(.horizontal, InlineBar.inset)
                    // The field is a text field, so its own click, drag and menu stay as they are; the rest of a tab's behaviour is added around it.
                    .overlay(MiddleClickCatcher { if !tab.isLocked { model.closeTab(id: tab.id) } })
                    .overlay(alignment: .topTrailing) { AudioBadge(tab: tab).scaleEffect(0.8).offset(x: -2, y: -4) }
                    .stripGroupMarker(tab, model: model)
                    // A tab dropped on the active tab goes in front of it, in its group (it used to fall through to "the end", out of every group).
                    .dropDestination(for: String.self) { items, _ in
                        guard let raw = items.first, let id = UInt64(raw) else { return false }
                        return model.acceptDroppedTab(id, before: tab.id)
                    }
                    .transition(.opacity)
            } else {
                InlineTabCell(tab: tab, width: width)
                    .transition(.opacity)
            }
        }
        .frame(width: width)
        .transition(.opacity)
    }

    private func keepSelectedVisible(_ proxy: ScrollViewProxy, animated animate: Bool) {
        guard let id = model.activeID else { return }
        if animate { animated(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) } } else { proxy.scrollTo(id, anchor: .center) }
        // The widths change in the same pass; once that layout has run the target is where it will stay, so ask again.
        DispatchQueue.main.async { if model.activeID == id { proxy.scrollTo(id, anchor: .center) } }
    }

    /// Keeps the focused cell in view. The selected tab is the field, which arrow keys do not enter, so focus steps over it in the same direction.
    private func stripFocusChanged(from old: UInt64?, to id: UInt64?, proxy: ScrollViewProxy) {
        guard var target = id else { return }
        let ids = model.stripShownTabs(model.visibleTabs).map(\.id)
        if target == model.activeID, let from = old ?? lastFocused, let a = ids.firstIndex(of: from), let b = ids.firstIndex(of: target) {
            let beyond = b + (b > a ? 1 : -1)
            target = ids.indices.contains(beyond) ? ids[beyond] : from
            focusedTab = target
        }
        lastFocused = target
        animated(.easeOut(duration: 0.15)) { proxy.scrollTo(target) }
    }

    private func publish(_ span: InlineFieldSpan) {
        if span != model.inlineField { model.inlineField = span }
    }
}

struct InlineTabCell: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController
    let width: CGFloat
    @State private var hovering = false
    @Environment(\.colorSchemeContrast) private var contrast

    private var showsTitle: Bool { width >= 96 && !tab.pinned }

    var body: some View {
        ZStack {
            HStack(spacing: 6) {
                TabFavicon(tab: tab, size: 14)
                if showsTitle {
                    Text(tab.displayTitle).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(Color.primary.opacity(0.75))
                }
            }
            .padding(.horizontal, showsTitle ? 26 : 0)
            // Close waits at the trailing edge of a cell that has room for a title, never over the icon, so a click on the icon only ever selects. Compact cells close from the menu, middle-click, Cmd-W or the overview.
            if showsTitle {
                HStack(spacing: 2) {
                    Spacer(minLength: 0)
                    // The speaker has its own slot at the trailing edge, so the title does not move when sound starts or stops.
                    AudioBadge(tab: tab)
                    if tab.isLocked {
                        Image(systemName: "lock.fill").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                            .frame(width: 16, height: 16).help("Locked").accessibilityHidden(true)
                    } else if TabChipRules.showsCloseButton(locked: false, selected: false, hovering: hovering) {
                        TabCloseButton { model.closeTab(id: tab.id) }
                    }
                }.padding(.trailing, 5)
            } else if tab.playingAudio || tab.muted {
                // An icon-only cell playing sound shows the speaker in its corner (it mutes; it never selects or closes the tab).
                AudioBadge(tab: tab).scaleEffect(0.8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).offset(x: 2, y: -3)
            } else if tab.isLocked {
                Image(systemName: "lock.fill").font(.system(size: 7, weight: .bold)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(.trailing, 5).padding(.bottom, 2)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: InlineBar.content - InlineBar.inset * 2)
        // A soft chip at rest, a little stronger under the pointer: the favicon is never a lone badge, and the chips need no dividers.
        .background(Capsule(style: .continuous).fill(Color.primary.opacity(contrast == .increased ? (hovering ? 0.22 : 0.12) : (hovering ? 0.12 : 0.05))))
        .overlay { if contrast == .increased { Capsule(style: .continuous).strokeBorder(Color.primary.opacity(0.35), lineWidth: 1).allowsHitTesting(false) } }
        .padding(.horizontal, 2)
        .contentShape(Rectangle())
        .motion(.easeOut(duration: 0.16), value: hovering)
        .onHover { hovering = $0 }
        .stripGroupMarker(tab, model: model)
        .modifier(TabTooltip(title: tab.displayTitle))
        .tabInteractions(tab)
    }
}


/// The One Row address field's frame on screen, read while it is being typed in.
struct InlineFieldFrameKey: PreferenceKey {
    static var defaultValue: CGRect? { nil }
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() ?? value }
}
