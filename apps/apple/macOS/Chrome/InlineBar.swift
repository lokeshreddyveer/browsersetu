import SwiftUI

/// "One Row" is Safari's compact toolbar: one slim line holding the sidebar button, back and forward, every tab, and the share, new-tab and
/// overview buttons. The selected tab is the address field. Click it to type, ⌘L focuses it, Esc leaves it; the other tabs shrink to
/// their icon and title as more are opened, and show a close button when the pointer is over them.
struct InlineBar: View {
    @EnvironmentObject var model: BrowserModel
    let leadingInset: CGFloat

    static let height: CGFloat = 40
    /// The strip that holds the tabs, and the gap between it and the selected tab's field, as in Safari.
    static let content: CGFloat = 30
    static let inset: CGFloat = 2
    /// Not used by the suggestions any more; kept so the bar can still be measured by tests.
    static let trailingReserve: CGFloat = 130

    static func fieldWidth(window: CGFloat) -> CGFloat { min(520, max(240, window * 0.4)) }

    var body: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: leadingInset - 4, height: 1)
            ChromeButton(symbol: "sidebar.left", help: "Toggle Sidebar", identifier: "sidebar-button") { model.sidebarVisible.toggle() }
            if let tab = model.active {
                HStack(spacing: 0) { NavigationButtons(tab: tab, showForward: true, hideReload: true) }
            }
            InlineTabs(address: model.addressBar)
            HStack(spacing: 0) {
                ExtensionActionButtons(center: model.extensionCenter)
                ToolbarExtras()
                if let url = model.active?.url, model.active?.isBlank == false {
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                        .buttonStyle(ChromeButtonStyle()).help("Share").accessibilityLabel("Share")
                }
                if model.shows(.bookmark) {
                    ChromeButton(symbol: model.activeBookmarked ? "star.fill" : "star", help: "Bookmark This Page", identifier: "bookmark-button",
                                 tint: model.activeBookmarked ? .yellow : nil) { model.toggleBookmark() }
                        .disabled(model.active?.isBlank ?? true)
                }
                if model.shows(.downloads) { DownloadsToolbarButton(coordinator: model.downloads) }
                // One Row always keeps these three, as it always has.
                ChromeButton(symbol: "plus", help: "New Tab", identifier: "new-tab-button") { model.newTab() }
                ChromeButton(symbol: "square.on.square", help: "Show Tab Overview", identifier: "overview-button") {
                    model.overviewVisible ? model.hideOverview() : model.showOverview()
                }
                MoreMenu(priority: ToolbarPriority(width: 1000))
            }
        }
        .padding(.trailing, 8)
        .frame(height: Self.height)
        .background(WindowDragRegion())
        .accessibilityIdentifier("inline-bar")
    }
}

/// The tab strip. The selected tab takes the room it needs for its address field; the rest share what is left, never narrower than an icon.
struct InlineTabs: View {
    @EnvironmentObject var model: BrowserModel
    /// Watched so the strip makes room for the field as soon as typing starts.
    @ObservedObject var address: AddressBarController
    private let iconCell: CGFloat = 34
    private let maxCell: CGFloat = 260
    private let titleThreshold: CGFloat = 96

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
        let active = max(equal, min(max(230, wanted), total - others * iconCell))
        let share = min(maxCell, max(iconCell, (total - active) / others))
        return (0..<count).map { $0 == activeIndex ? active : share }
    }

    var body: some View {
        GeometryReader { geo in
            let tabs = model.visibleTabs
            let activeIndex = tabs.firstIndex { $0.id == model.activeID }
            let widths = Self.widths(total: geo.size.width, count: tabs.count, activeIndex: activeIndex, iconCell: iconCell, maxCell: maxCell, editing: address.isEditing)
            let contentWidth = widths.reduce(0, +)
            // Worked out from the widths, not read from the animated view, so the suggestions line up with where the field will be.
            let span: InlineFieldSpan = {
                guard let activeIndex, activeIndex < widths.count else { return InlineFieldSpan(x: geo.frame(in: .global).minX, width: 320) }
                return InlineFieldSpan(x: geo.frame(in: .global).minX + widths[..<activeIndex].reduce(0, +) + InlineBar.inset,
                                       width: widths[activeIndex] - InlineBar.inset * 2)
            }()
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                            ZStack {
                                if tab.id == model.activeID {
                                    MacOmnibox(tab: tab, address: model.addressBar, showReload: true, shield: true, tabField: true)
                                        .padding(.horizontal, InlineBar.inset)
                                        .transition(.opacity)
                                } else {
                                    InlineTabCell(tab: tab, width: widths.indices.contains(index) ? widths[index] : 0, showsDivider: index > 0 && tabs[index - 1].id != model.activeID)
                                        .transition(.opacity)
                                }
                            }
                            .frame(width: widths.indices.contains(index) ? widths[index] : 0)
                            .transition(.opacity)
                            .id(tab.id)
                        }
                    }
                    .frame(minWidth: min(contentWidth, geo.size.width), alignment: .leading)
                    .motion(.smooth(duration: 0.26), value: widths)
                    .motion(.smooth(duration: 0.2), value: model.activeID)
                    .motion(.smooth(duration: 0.26), value: tabs.map(\.id))
                }
                .onChange(of: model.activeID) { _, id in animated(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) } }
            }
            .frame(height: InlineBar.content)
            .background(RoundedRectangle(cornerRadius: InlineBar.content / 3, style: .continuous).fill(Color.primary.opacity(0.07)))
            .clipShape(RoundedRectangle(cornerRadius: InlineBar.content / 3, style: .continuous))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .onAppear { publish(span) }
            .onChange(of: span) { _, new in publish(new) }
        }
        .acceptsDroppedTabs(model)
        .accessibilityIdentifier("tab-bar")
    }

    private func publish(_ span: InlineFieldSpan) {
        if span != model.inlineField { model.inlineField = span }
    }
}

struct InlineTabCell: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController
    let width: CGFloat
    let showsDivider: Bool
    @State private var hovering = false

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
            HStack { TabCloseButton { model.closeTab(id: tab.id) }; Spacer(minLength: 0) }.padding(.leading, 5)
                .opacity(hovering && !tab.isLocked ? 1 : 0).scaleEffect(hovering ? 1 : 0.7).allowsHitTesting(hovering && !tab.isLocked)
        }
        .frame(maxWidth: .infinity)
        .frame(height: InlineBar.content - InlineBar.inset * 2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hovering ? 0.10 : 0)))
        .padding(.horizontal, 2)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.primary.opacity(0.16)).frame(width: 1, height: 14).opacity(showsDivider && !hovering ? 1 : 0)
        }
        .contentShape(Rectangle())
        .motion(.easeOut(duration: 0.16), value: hovering)
        .onHover { hovering = $0 }
        .help(tab.displayTitle)
        .tabInteractions(tab)
    }
}
