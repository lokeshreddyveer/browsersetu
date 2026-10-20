import AppKit
import SwiftUI

private struct HoldBrowserChromeKey: EnvironmentKey {
    static let defaultValue: (Bool) -> Void = { _ in }
}
extension EnvironmentValues {
    var holdBrowserChrome: (Bool) -> Void {
        get { self[HoldBrowserChromeKey.self] }
        set { self[HoldBrowserChromeKey.self] = newValue }
    }
}

/// Everything about the window's layout that moves things around, so one animation covers all of it.
private struct LayoutSignature: Equatable {
    var preset: LayoutPreset
    var visible: Bool
    var rail: Bool
    var position: SidebarPosition
}

struct MacRootView: View {
    @EnvironmentObject var model: BrowserModel
    @Environment(\.openSettings) private var openSettings
    @StateObject private var peek = SidebarPeek()
    @StateObject private var toolbarPeek = SidebarPeek(linger: 1.0)

    private var onLeft: Bool { model.sidebarPosition == .left }
    private var pinned: Bool { model.sidebarVisible && !model.focusMode }
    private var peekEnabled: Bool {
        !model.focusMode && (model.sidebarRail || !model.sidebarVisible) &&
            (model.sidebarAutoHide || model.effectiveTabLayout == .sidebar)
    }
    private var topInset: CGFloat { model.singleToolbar ? 46 : (columnBar ? 40 : 36) }
    private var toolbarInset: CGFloat { model.windowFullScreen ? 10 : 84 }
    private var topBarVisible: Bool { !model.focusMode && !model.singleToolbar && !model.autoHidesToolbar && !model.topBarHidden }
    /// The Floating layout: no bar, just the pill and the search button over the page.
    private var floatingLayout: Bool { model.topBarHidden && !model.focusMode }
    /// Tabs slide in when the pointer reaches the edge, and stay a moment after it leaves so they are easy to use.
    private var peekLinger: TimeInterval { model.topBarHidden ? 0.25 : 0.15 }
    private var peekZoneWidth: CGFloat { model.topBarHidden ? 12 : 6 }
    /// A little longer in the Floating layout, so brushing the edge while scrolling does not pull the tabs out.
    private var peekDwell: TimeInterval { model.topBarHidden ? 0.1 : 0.06 }
    /// The search panel grows out of the Search button, so it opens from the same corner.
    private var searchAnchor: UnitPoint { model.topBarHidden ? (model.sidebarPosition == .left ? .topTrailing : .topLeading) : .top }
    /// With vertical tabs and a separate toolbar, the sidebar runs the full height of the window and the toolbar
    /// sits above the page only. With a horizontal strip the toolbar spans the window, as usual.
    private var columnBar: Bool { topBarVisible && model.effectiveTabLayout == .sidebar }
    private var fullWidthBar: Bool { topBarVisible && model.effectiveTabLayout != .sidebar }
    /// The toolbar is folded into the pill, and the page runs to the top of the window.
    private var foldedAway: Bool { model.chromeCollapsed && model.canCollapseChrome }
    /// While reading in the Floating layout the pill slides up out of the way (the Search pill stays).
    private var pillScrolledAway: Bool { floatingLayout && model.canFoldPill && model.chromeCollapsed }
    private var barHeight: CGFloat { model.singleRow ? InlineBar.height : 40 + (model.effectiveTabLayout == .compact ? (model.density == .compact ? 28 : 32) : model.density.stripHeight) }
    private var cardLeading: CGFloat { pinned && onLeft ? 0 : WindowInset.gap }
    private var cardTrailing: CGFloat { pinned && !onLeft ? 0 : WindowInset.gap }

    var body: some View {
        content.scrollIndicators(.hidden)
    }

    private var content: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    if model.focusMode { FocusBand().padding(.leading, toolbarInset) }
                    else if fullWidthBar {
                        // The page's room changes once, at the start, instead of every frame (resizing a web page 30 times a second is what made the fold
                        // stutter). The bar itself slides and fades over it on one smooth curve.
                        Color.clear
                            .frame(height: foldedAway ? 0 : barHeight)
                            .transaction { $0.animation = nil }
                            .overlay(alignment: .top) {
                                VStack(spacing: 0) { TopBar(leadingInset: toolbarInset); tabRow }
                                    .background { if let tab = model.active { ToolbarTintLayer(tab: tab) } }
                                    .frame(height: barHeight, alignment: .top)
                                    .offset(y: foldedAway ? -barHeight : 0)
                                    .opacity(foldedAway ? 0 : 1)
                                    .allowsHitTesting(!foldedAway)
                                    .accessibilityHidden(foldedAway)
                            }
                            .zIndex(1)
                    }
                    else if columnBar || model.topBarHidden || model.singleToolbar { EmptyView() }
                    else { WindowDragRegion().frame(height: model.windowFullScreen ? 0 : 28) }
                    ZStack(alignment: onLeft ? .leading : .trailing) {
                        HStack(spacing: 0) {
                            if pinned && onLeft { sidebar(geometry.size.width).transition(.move(edge: .leading).combined(with: .opacity)) }
                            MainColumn(barInset: columnBar ? ((pinned && onLeft) ? 0 : toolbarInset) : nil,
                                       cardLeading: cardLeading, cardTrailing: cardTrailing)
                            if pinned && !onLeft { sidebar(geometry.size.width).transition(.move(edge: .trailing).combined(with: .opacity)) }
                        }
                        if peekEnabled {
                            // Reads where the pointer is straight from the window: it does not rely on view tracking areas.
                            PeekPointerTracker(enabled: true, onLeft: onLeft,
                                               edgeWidth: model.sidebarRail ? CGFloat(sidebarRailWidth) : peekZoneWidth,
                                               panelWidth: CGFloat(model.sidebarWidth) + WindowInset.gap + 8, peek: peek)
                                .frame(width: 0, height: 0)
                            if peek.revealed { PeekSidebar(peek: peek, topInset: floatingLayout ? 46 : topInset) }
                        }
                    }
                }
                if !model.focusMode && model.autoHidesToolbar && !model.floatingAddressVisible && !model.paletteVisible {
                    EdgeHoverZone { toolbarPeek.edge($0) }.frame(height: 6)
                    if toolbarPeek.revealed {
                        VStack(spacing: 0) {
                            TopBar(leadingInset: toolbarInset)
                            if model.effectiveTabLayout != .sidebar { tabRow }
                        }
                            .background(Color.chrome)
                            .background(EdgeHoverZone { toolbarPeek.panel($0) })
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                if (topBarVisible || toolbarPeek.revealed) && !model.floatingAddressVisible {
                    SuggestionsOverlay(address: model.addressBar)
                        .frame(width: model.singleRow ? max(model.inlineField.width, 440)
                               : ToolbarPriority(fitting: geometry.size.width, leadingInset: toolbarInset, extras: model.toolbarExtrasCount).fieldWidth(window: geometry.size.width, leadingInset: toolbarInset))
                        .frame(maxWidth: .infinity, alignment: model.singleRow ? .leading : .center)
                        .padding(.leading, model.singleRow ? min(model.inlineField.x, max(8, geometry.size.width - 448)) : 0)
                        .padding(.top, model.singleRow ? InlineBar.height : 40)
                }
                if model.singleToolbar && !model.focusMode && !foldedAway {
                    // No top bar: a strip above the page still drags the window.
                    WindowDragStrip().frame(height: 10).frame(maxHeight: .infinity, alignment: .top)
                }
                if foldedAway || floatingLayout {
                    WindowDragStrip().frame(height: 12).frame(maxHeight: .infinity, alignment: .top)
                    if floatingLayout && model.pillCollapsed {
                        PillHandle()
                            .padding(.top, 4)
                            .frame(maxHeight: .infinity, alignment: .top)
                            .transition(.scale(scale: 0.6, anchor: .top).combined(with: .opacity))
                            .zIndex(4)
                    } else if !pillScrolledAway {
                        if floatingLayout && model.floatingAddressVisible {
                            // The address pill itself becomes the search field, in the same place; there is no second pill.
                            FloatingSearchPill(onRight: false, expandedWidth: max(260, min(480, geometry.size.width - 260)))
                                .padding(.top, WindowInset.pillTop - 1)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                                .transition(.opacity)
                                .zIndex(6)
                        } else {
                            FloatingPill()
                                .padding(.top, WindowInset.pillTop)
                                .frame(maxHeight: .infinity, alignment: .top)
                                .transition(.move(edge: .top).combined(with: .opacity))
                                .zIndex(4)
                        }
                    }
                }
                if floatingLayout && !model.pillCollapsed {
                    // On the side away from the tabs sidebar, so the two never meet: the right when the tabs are on the left.
                    let onRight = model.sidebarPosition == .left
                    // Extensions stand in a vertical strip against the window's edge, away from the tabs sidebar, level with the top of the page.
                    if !model.floatingAddressVisible {
                        FloatingExtensions(onRight: onRight)
                            .padding(.top, 52)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: onRight ? .topTrailing : .topLeading)
                            .transition(.opacity)
                            .zIndex(4)
                    }
                }
                VStack(spacing: 8) { PendingLoginPill(); PopupBlockedPill() }
                    .padding(.top, 56)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .zIndex(5)
                NoticeToast()
                    .padding(.bottom, 22)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .zIndex(6)
                DownloadToast(coordinator: model.downloads)
                    .padding(.trailing, 14).padding(.bottom, model.showSpeedPill ? 40 : 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .zIndex(5)
                if model.showSpeedPill && !model.focusMode {
                    // Out of the way in the bottom right corner; taps and scrolls pass through it to the page.
                    SpeedPill(height: 20)
                        .padding(.trailing, 12).padding(.bottom, 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .transition(.opacity)
                        .zIndex(4)
                }
                if model.floatingAddressVisible && !floatingLayout {
                    FloatingAddressBar().zIndex(5).transition(.opacity)
                }
                // Whenever something essential would only appear at a window edge, a small handle on screen leads to all of it.
                if !model.focusMode, model.layoutState(width: geometry.size.width).needsHandle {
                    LayoutHandle().padding(.top, 3).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).zIndex(3).transition(.opacity)
                }
            }
            .onAppear { model.windowWidth = geometry.size.width }
            .onChange(of: geometry.size.width) { _, width in model.windowWidth = width }
        }
        .ignoresSafeArea(.container, edges: .top)
        // Behind the title bar too: a background does not reach into the safe area by itself, and the strip above the toolbar showed the system's grey instead of the theme.
        .background(WindowBackdrop().ignoresSafeArea())
        .background(WindowObserver { model.windowFullScreen = $0 })
        .background(TrafficLightsController(hidden: foldedAway || floatingLayout || model.singleToolbar))
        .onAppear {
            peek.linger = peekLinger
            peek.dwell = peekDwell
            WindowDoubleClick.handler = { model.handleTopBarDoubleClick() }
        }
        .onChange(of: model.layoutPreset) { _, _ in peek.linger = peekLinger; peek.dwell = peekDwell }
        .motion(.easeInOut(duration: 0.26), value: foldedAway)
        .motion(.spring(response: 0.4, dampingFraction: 0.9), value: pillScrolledAway)
        .motion(.spring(response: 0.38, dampingFraction: 0.86), value: model.pillCollapsed)
        .onAppear {
            SettingsRouter.opener = { openSettings() }
            SettingsRouter.inlineOpener = { [weak model] in
                guard let model, model.settingsInTab else { return false }
                model.showSettingsTab()
                return true
            }
        }
        .modifier(SystemTranslation())
        // Downloads show their progress on the Dock icon.
        .onReceive(model.downloads.$active) { active in
            if active.isEmpty { NSApp.dockTile.badgeLabel = nil }
            else {
                let average = active.values.map(\.fraction).reduce(0, +) / Double(active.count)
                NSApp.dockTile.badgeLabel = "\(Int((average * 100).rounded()))%"
            }
        }
        // Layout changes (a preset, the sidebar pinned, collapsed to icons, moved) glide instead of jumping.
        .motion(.spring(response: 0.4, dampingFraction: 0.88), value: LayoutSignature(preset: model.layoutPreset, visible: model.sidebarVisible,
                                                                                    rail: model.sidebarRail, position: model.sidebarPosition))
        .motion(.easeOut(duration: 0.2), value: model.focusMode)
        .environment(\.holdBrowserChrome, { hold in peek.hold(hold); toolbarPeek.hold(hold) })
        .sheet(item: $model.sheet) { SheetContainer(sheet: $0) }
        // A link, a file or some text from another app, dropped on the window, opens.
        .dropDestination(for: URL.self) { urls, _ in model.openDropped(urls: urls) }
        .dropDestination(for: String.self) { texts, _ in texts.first.map { model.openDropped(text: $0) } ?? false }
        .sheet(item: $model.storeOffer) { StoreOfferSheet(info: $0) }
        .sheet(item: $model.privacySheet) { PrivacySheetView(kind: $0, privacy: model.privacy) }
        .preferredColorScheme(model.appearance.colorScheme ?? (model.themeIsActive ? model.activeTheme.scheme?.colorScheme : nil))
        .tint(Theme.accent)
        .motion(.easeOut(duration: 0.22), value: peek.revealed)
        .motion(.easeOut(duration: 0.18), value: toolbarPeek.revealed)
        .onChange(of: peekEnabled) { _, enabled in if !enabled { peek.reset() } }
        .onChange(of: model.windowFullScreen) { old, new in if old && !new && peekEnabled { peek.flash() } }
        .onChange(of: model.autoHidesToolbar) { _, _ in toolbarPeek.reset() }
        .onChange(of: model.floatingAddressVisible) { _, visible in
            if visible { toolbarPeek.reset(); peek.reset() }
        }
        .onReceive(model.addressBar.$isEditing.removeDuplicates()) { toolbarPeek.editing($0) }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            peek.menu(true); toolbarPeek.menu(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            peek.menu(false); toolbarPeek.menu(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            peek.reset(); toolbarPeek.reset()
        }
        .frame(minWidth: 520, idealWidth: 1200, minHeight: 360, idealHeight: 800)
    }

    private func sidebar(_ windowWidth: CGFloat) -> some View {
        SidebarContainer(topInset: topInset, availableWidth: min(model.sidebarWidth, windowWidth * 0.42))
            .contextMenu { SidebarContextMenu() }
            .accessibilityHidden(peek.revealed)
    }

    @ViewBuilder private var tabRow: some View {
        switch model.effectiveTabLayout {
        case .separate: HorizontalTabStrip().contextMenu { ToolbarContextMenu() }
        case .compact: CompactTabStrip().contextMenu { ToolbarContextMenu() }
        case .sidebar: EmptyView()
        }
    }
}

/// Everything beside the sidebar: toolbar, tabs, page, and the overlays that float over the page.
struct MainColumn: View {
    @EnvironmentObject var model: BrowserModel
    /// Non-nil when the toolbar sits in this column (vertical tabs with a separate toolbar); the value is the inset
    /// reserved for the window's traffic lights.
    let barInset: CGFloat?
    let cardLeading: CGFloat
    let cardTrailing: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                if let barInset { TopBar(leadingInset: barInset) }
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        RecoveryBanner()
                        if model.findVisible { FindBar().transition(.move(edge: .top).combined(with: .opacity)) }
                        if let tab = model.active {
                            ContentPanels(active: tab)
                                .overlay(alignment: .top) { LoadingBar(tab: tab).id(tab.id) }
                                // A card at the foot of the page, clear of every toolbar layout.
                                .overlay(alignment: .bottom) { WebStoreBanner().padding(.bottom, 16).motion(.easeOut(duration: 0.2), value: model.storePageExtensionID) }
                        } else {
                            Color.platformBackground
                        }
                    }
                    if let docked = model.dockedPanel {
                        DockedPanelView(sheet: docked).transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .motion(.easeOut(duration: 0.22), value: model.dockedPanel)
                .modifier(PageCard(enabled: !model.focusMode, leading: cardLeading, trailing: cardTrailing,
                                   top: barInset == nil ? WindowInset.gap : 0))
            }
            if let id = model.openPanelID, let panel = model.webPanels.first(where: { $0.id == id }), let tab = model.tabs.first(where: { $0.id == model.panelTabID }) {
                WebPanelView(panel: panel, tab: tab).transition(.move(edge: .trailing).combined(with: .opacity)).zIndex(2)
            }
            if let floating = model.floatingPanel {
                FloatingPanelView(sheet: floating).transition(.opacity).zIndex(5)
            }
            if model.overviewVisible { TabOverview().transition(.opacity.combined(with: .scale(scale: 0.98))).zIndex(3) }
            if model.showSetup { SetupAssistantView().transition(.opacity).zIndex(10) }
            if model.paletteVisible { CommandPalette().transition(.opacity).zIndex(4) }
        }
        .motion(.easeOut(duration: 0.16), value: model.overviewVisible)
        .motion(.spring(response: 0.34, dampingFraction: 0.88), value: model.floatingPanel)
        .motion(.spring(response: 0.32, dampingFraction: 0.9), value: model.findVisible)
        .motion(.easeOut(duration: 0.14), value: model.activeID)
        .motion(.easeOut(duration: 0.12), value: model.paletteVisible)
        .motion(.easeOut(duration: 0.12), value: model.floatingAddressVisible)
    }

    /// Horizontal presentation only. Vertical tabs live in the sidebar, so nothing is drawn twice.
    @ViewBuilder private var tabRow: some View {
        switch model.effectiveTabLayout {
        case .separate: HorizontalTabStrip().contextMenu { ToolbarContextMenu() }
        case .compact: CompactTabStrip().contextMenu { ToolbarContextMenu() }
        case .sidebar: EmptyView()
        }
    }
}

/// The floating address bar: ⌘L (and a new tab) opens it when the in-sidebar address bar is not on screen.
struct FloatingAddressBar: View {
    @EnvironmentObject var model: BrowserModel
    @State private var engineMenuOpen = false
    @State private var closeTask: DispatchWorkItem?

    /// In the Floating layout the panel opens where the Search button is, so it feels like the button itself opened up. Elsewhere
    /// it opens at the top centre.
    private var anchored: Bool { model.topBarHidden && !model.focusMode }
    private var onRight: Bool { model.sidebarPosition == .left }

    private var sidePadding: (leading: CGFloat, trailing: CGFloat) {
        guard anchored else { return (20, 20) }
        return onRight ? (0, WindowInset.pillTop + 2) : (model.windowFullScreen ? 10 : 84, 0)
    }

    var body: some View {
        // One glass panel: the field on top, the suggestions under it, the keys at the bottom. No dimmed backdrop (it would swallow
        // scrolling): clicking the page ends the editing, and that closes the panel.
        VStack(spacing: 0) {
            if let tab = model.active {
                HStack(spacing: 6) {
                    SearchEngineMenu(compact: true)
                    MacOmnibox(tab: tab, address: model.addressBar, floating: true)
                    ShieldPill(privacy: model.privacy, host: tab.url?.host)
                }
                .padding(.horizontal, 8).padding(.vertical, 7)
            }
            SuggestionsOverlay(address: model.addressBar, embedded: true)
        }
        .environment(\.colorScheme, .dark)
        .background(Obsidian.fill.opacity(0.97), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Obsidian.edge, lineWidth: 0.6))
        .shadow(color: .black.opacity(0.4), radius: 36, y: 20)
        .frame(maxWidth: anchored ? 440 : 620)
        .padding(.leading, sidePadding.leading).padding(.trailing, sidePadding.trailing)
        .padding(.top, anchored ? WindowInset.pillTop - 1 : 90)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: anchored ? (onRight ? .topTrailing : .topLeading) : .top)
        .motion(.spring(response: 0.32, dampingFraction: 0.88), value: model.addressBar.suggestions.count)
        // Done as soon as editing ends: Return, Escape, or clicking away. A short wait first: choosing a search engine from the menu
        // briefly takes the focus off the field, and that must not close the panel.
        .onReceive(model.addressBar.$isEditing.dropFirst().removeDuplicates()) { editing in
            closeTask?.cancel()
            guard !editing else { return }
            let work = DispatchWorkItem {
                if !engineMenuOpen && !model.addressBar.isEditing { model.floatingAddressVisible = false }
            }
            closeTask = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in engineMenuOpen = true }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            engineMenuOpen = false
            // Back to typing, with the text as it was.
            if !model.addressBar.isEditing { model.floatingFocusTick += 1 }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("floating-address-bar")
    }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(Color.primary.opacity(0.09)).frame(height: 0.5) }
}

/// In focus mode the toolbar is gone; this slim band keeps the connection state visible and gives the way back.
struct FocusBand: View {
    var body: some View {
        FocusChrome()
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(WindowDragRegion())
    }
}

/// One page, or two panels when a split view is open. Each panel owns its own live view.
struct ContentPanels: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var active: TabController

    var body: some View {
        let panels = model.orderedSplitPanels()
        if panels.count > 1 {
            SplitLayout(count: panels.count, horizontal: model.splitOrientation == .sideBySide) { index in
                panel(panels[index], focused: panels[index].id == active.id, count: panels.count)
            }
            .overlay(alignment: .topTrailing) { SplitControls().padding(8) }
        } else {
            PageArea(tab: active).id(active.id).transition(.opacity)
        }
    }

    private func panel(_ tab: TabController, focused: Bool, count: Int) -> some View {
        PageArea(tab: tab).id(tab.id)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(focused ? Theme.accent : Color.clear, lineWidth: 2).allowsHitTesting(false))
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { if !focused { model.swapSplit(with: tab.id) } })
            .accessibilityLabel(focused ? "Active panel" : (count > 2 ? "Panel \(model.orderedSplitPanels().firstIndex { $0.id == tab.id }.map { $0 + 1 } ?? 2) of \(count)" : "Side panel"))
            .transition(.opacity)
    }
}

/// The panels of a split view, laid out the way the count suggests: two share the window equally, three are one tall page and two stacked beside it, four are a grid of two by two.
/// Every share starts exactly equal; the divider between two panels can be dragged, and a double click on a divider puts the shares back. A page never gets less than a sixth.
struct SplitLayout<Panel: View>: View {
    let count: Int
    /// Side by side (the groups are columns) or stacked (the groups are rows).
    let horizontal: Bool
    @ViewBuilder let panel: (Int) -> Panel
    @State private var outer: [CGFloat] = []
    @State private var inner: [[CGFloat]] = []
    @State private var outerStart: [CGFloat]?
    @State private var innerStart: [CGFloat]?
    private let minimum: CGFloat = 1.0 / 6
    private let gap: CGFloat = 1

    /// Which panels share a column (or a row). Two: one each. Three: the first alone, the other two together. Four: two and two.
    static func groups(count: Int) -> [[Int]] {
        switch count {
        case 3: [[0], [1, 2]]
        case 4: [[0, 2], [1, 3]]
        default: (0..<max(count, 1)).map { [$0] }
        }
    }

    private var groups: [[Int]] { Self.groups(count: count) }
    private func equal(_ n: Int) -> [CGFloat] { Array(repeating: 1 / CGFloat(max(n, 1)), count: n) }
    private var outerShares: [CGFloat] { outer.count == groups.count ? outer : equal(groups.count) }
    private func innerShares(_ g: Int) -> [CGFloat] { inner.indices.contains(g) && inner[g].count == groups[g].count ? inner[g] : equal(groups[g].count) }

    var body: some View {
        GeometryReader { geo in
            let along = horizontal ? geo.size.width : geo.size.height
            let across = horizontal ? geo.size.height : geo.size.width
            let outerTotal = max(1, along - gap * CGFloat(groups.count - 1))
            let outerLayout = horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            let innerLayout = horizontal ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
            outerLayout {
                ForEach(Array(groups.enumerated()), id: \.offset) { g, members in
                    let innerTotal = max(1, across - gap * CGFloat(members.count - 1))
                    let size = outerShares[g] * outerTotal
                    innerLayout {
                        ForEach(Array(members.enumerated()), id: \.element) { m, index in
                            panel(index)
                                .frame(width: horizontal ? nil : innerShares(g)[m] * innerTotal, height: horizontal ? innerShares(g)[m] * innerTotal : nil)
                            if m < members.count - 1 { divider(vertical: horizontal, total: innerTotal) { delta in dragInner(group: g, at: m, by: delta) } onEnd: { innerStart = nil } }
                        }
                    }
                    .frame(width: horizontal ? size : nil, height: horizontal ? nil : size)
                    if g < groups.count - 1 { divider(vertical: !horizontal, total: outerTotal) { delta in dragOuter(at: g, by: delta) } onEnd: { outerStart = nil } }
                }
            }
        }
        .onChange(of: count) { _, _ in reset() }
        .onChange(of: horizontal) { _, _ in reset() }
    }

    private func reset() { animated(.easeOut(duration: 0.2)) { outer = []; inner = [] } }

    private func dragOuter(at g: Int, by delta: CGFloat) {
        let start = outerStart ?? outerShares
        outerStart = start
        let pair = start[g] + start[g + 1]
        let first = min(max(start[g] + delta, minimum), pair - minimum)
        var updated = start; updated[g] = first; updated[g + 1] = pair - first
        outer = updated
    }

    private func dragInner(group g: Int, at m: Int, by delta: CGFloat) {
        let start = innerStart ?? innerShares(g)
        innerStart = start
        let pair = start[m] + start[m + 1]
        let first = min(max(start[m] + delta, minimum), pair - minimum)
        var updated = start; updated[m] = first; updated[m + 1] = pair - first
        var all = inner.count == groups.count ? inner : groups.map { equal($0.count) }
        all[g] = updated
        inner = all
    }

    /// A hairline with a wider strip to grab. `vertical` means the line runs top to bottom (it separates side-by-side panels).
    private func divider(vertical: Bool, total: CGFloat, drag: @escaping (CGFloat) -> Void, onEnd: @escaping () -> Void) -> some View {
        Rectangle().fill(Color.primary.opacity(0.12))
            .frame(width: vertical ? gap : nil, height: vertical ? nil : gap)
            .overlay {
                Color.clear.frame(width: vertical ? 9 : nil, height: vertical ? nil : 9).contentShape(Rectangle())
                    .onHover { inside in if inside { (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in drag((vertical ? value.translation.width : value.translation.height) / total) }
                        .onEnded { _ in onEnd() })
                    .onTapGesture(count: 2) { reset() }
            }
            .accessibilityLabel("Panel divider")
            .accessibilityHint("Drag to resize. Double-click to make the panels equal.")
    }
}

struct SplitControls: View {
    @EnvironmentObject var model: BrowserModel
    var body: some View {
        HStack(spacing: 4) {
            Button { model.splitOrientation = model.splitOrientation == .sideBySide ? .stacked : .sideBySide } label: {
                Image(systemName: model.splitOrientation == .sideBySide ? "rectangle.split.1x2" : "rectangle.split.2x1")
            }.help("Change Split Direction")
            if model.fourthSplitTabID == nil {
                Button { model.addThirdPanelNewTab() } label: { Image(systemName: "rectangle.split.2x2").accessibilityLabel("Add a panel") }.help("Add a Panel (up to four)")
            }
            if model.thirdSplitTab != nil {
                Button { model.removeThirdPanel() } label: { Image(systemName: "rectangle.badge.minus").accessibilityLabel("Remove the last panel") }.help("Remove the Last Panel")
            }
            Button { model.setLinkedPanes(!model.linkedPanes) } label: {
                Image(systemName: model.linkedPanes ? "link.circle.fill" : "link").accessibilityLabel(model.linkedPanes ? "Unlink scrolling" : "Link scrolling")
            }.help(model.linkedPanes ? "Scrolling is linked. Click to unlink." : "Link Scrolling")
            Button { Task { await model.comparePanels() } } label: { Image(systemName: "doc.on.doc").accessibilityLabel("Compare pages") }.help("Compare the Two Pages")
            Button { model.swapSplit() } label: { Image(systemName: "arrow.left.arrow.right").accessibilityLabel("Swap panels") }.help("Swap Panels")
            Button { model.closeSplit() } label: { Image(systemName: "xmark").accessibilityLabel("Close split view") }.help("Close Split View")
        }
        .buttonStyle(.borderless)
        .padding(6)
        .surface(radius: 8)
        .opacity(0.9)
    }
}

struct FindBar: View {
    @EnvironmentObject var model: BrowserModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in page", text: $model.findText)
                .textFieldStyle(.plain).focused($focused)
                .onSubmit { model.findNext() }
                .onChange(of: model.findText) { _, _ in model.findNext() }
                .accessibilityIdentifier("find-field")
            if model.findFailed { Text("Not found").font(.caption).foregroundStyle(.red) }
            Button { model.findNext(backwards: true) } label: { Image(systemName: "chevron.up").accessibilityLabel("Previous match") }.help("Previous")
            Button { model.findNext() } label: { Image(systemName: "chevron.down").accessibilityLabel("Next match") }.help("Next")
            Button("Done") { model.hideFind() }.keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .themedBar(fallback: .bar)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}

struct FocusChrome: View {
    @EnvironmentObject var model: BrowserModel
    @State private var hovering = false

    var body: some View {
        if let tab = model.active {
            HStack(spacing: 8) {
                Image(systemName: tab.isPrivate ? "eye.slash.fill" : (tab.isSecure ? "lock.fill" : "exclamationmark.triangle.fill"))
                    .foregroundStyle(tab.isPrivate ? Theme.privateAccent : (tab.isSecure ? Color.secondary : Color.orange))
                Text(tab.isBlank ? "New Tab" : displayHost(tab.url)).lineLimit(1)
                Button("Exit Focus Mode") { model.toggleFocusMode() }.buttonStyle(.borderless).foregroundStyle(Theme.accent)
                LayoutHandle()
            }
            .font(.caption)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .surface(radius: 12)
            .onHover { hovering = $0 }
            .accessibilityIdentifier("focus-chrome")
        }
    }
}

struct PageArea: View {
    @ObservedObject var tab: TabController
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        ZStack {
            EngineViewHost(view: tab.hostView)
            if tab.isSettingsPage { MacSettingsView(inline: true).settlesBeforeShowing().chromeFill().transition(.opacity) }
            else if let panel = tab.panelSheet { PanelTabView(sheet: panel, tab: tab).chromeFill().transition(.opacity) }
            else if tab.isBlank { StartPageView(isPrivate: tab.isPrivate).contextMenu { if !tab.isPrivate { StartPageContextMenu() } } }
        }
        .overlay(alignment: .bottomTrailing) { if model.workbench.showSizeHUD { SizeHUD() } }
        .overlay(alignment: .topLeading) {
            if model.isGuest {
                Label("Guest", systemImage: "person.fill.questionmark").font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5).background(Capsule().fill(Color.indigo.opacity(0.85))).padding(10).allowsHitTesting(false)
                    .accessibilityLabel("Guest window. Nothing is remembered.")
            }
        }
        .overlay(alignment: .top) {
            if let hint = model.gestureHint {
                Text(hint).font(.system(size: 13, weight: .medium)).foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.75))).padding(.top, 16).transition(.opacity).allowsHitTesting(false)
            }
        }
        .motion(.easeOut(duration: 0.12), value: model.gestureHint)
    }
}

/// The size of the page area, live, for looking at how a page responds as the window changes.
struct SizeHUD: View {
    var body: some View {
        GeometryReader { geo in
            Text("\(Int(geo.size.width)) × \(Int(geo.size.height))")
                .font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Color.black.opacity(0.7)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(10)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Command palette

struct CommandPalette: View {
    @EnvironmentObject var model: BrowserModel
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var items: [PaletteItem] { model.paletteItems(query: query) }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.15).ignoresSafeArea().onTapGesture { close() }
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search commands, tabs, bookmarks…", text: $query)
                        .textFieldStyle(.plain).font(.title3).focused($focused)
                        .onSubmit { run(selection) }
                        .onKeyPress(.downArrow) { selection = min(selection + 1, max(items.count - 1, 0)); return .handled }
                        .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
                        .onKeyPress(.escape) { close(); return .handled }
                        .accessibilityIdentifier("palette-field")
                }
                .padding(14)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                row(item, selected: index == selection).id(index)
                                    .onTapGesture { run(index) }
                            }
                            if items.isEmpty { Text("No results").foregroundStyle(.secondary).padding(20) }
                        }
                    }
                    .frame(maxHeight: 360)
                    .onChange(of: selection) { _, new in proxy.scrollTo(new) }
                }
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 20)
            .surface(radius: 18)
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.separator))
            .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
            .padding(.top, 90)
        }
        .onAppear {
            query = ""; selection = 0
            model.addressBar.isEditing = false
            model.addressBar.clear()
            // Wait until the overlay is mounted before transferring the field editor.
            DispatchQueue.main.async { focused = true }
        }
        .onChange(of: query) { _, _ in selection = 0 }
        .accessibilityElement(children: .contain)
    }

    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol).frame(width: 22).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                if !item.subtitle.isEmpty { Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            if !item.shortcut.isEmpty { Text(item.shortcut).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(selected ? Theme.accent.opacity(0.18) : .clear)
        .contentShape(Rectangle())
    }

    private func run(_ index: Int) {
        let list = items
        guard list.indices.contains(index) else { return }
        close()
        list[index].run()
    }

    private func close() { model.paletteVisible = false }
}




/// The Floating layout's extension buttons: a vertical strip fixed to the window's edge, pinned extensions first and the menu last, in the same
/// dark material as the pill. Nothing when there are none.
struct FloatingExtensions: View {
    @EnvironmentObject var model: BrowserModel
    var onRight = true

    var body: some View {
        if model.extensionCenter.hasExtensions {
            let shape = UnevenRoundedRectangle(topLeadingRadius: onRight ? 12 : 0, bottomLeadingRadius: onRight ? 12 : 0,
                                               bottomTrailingRadius: onRight ? 0 : 12, topTrailingRadius: onRight ? 0 : 12, style: .continuous)
            VStack(spacing: 2) { ExtensionActionButtons(center: model.extensionCenter) }
                .padding(.vertical, 4).padding(.horizontal, 3)
                .environment(\.colorScheme, .dark)
                .background(shape.fill(Obsidian.fill.opacity(0.96)))
                .overlay(shape.strokeBorder(Obsidian.edge, lineWidth: 0.6).allowsHitTesting(false))
                .shadow(color: .black.opacity(0.3), radius: 7, x: onRight ? -2 : 2, y: 2)
        }
    }
}

/// A web panel: a small site beside the page, over its right edge.
struct WebPanelView: View {
    @EnvironmentObject var model: BrowserModel
    let panel: WebPanel
    @ObservedObject var tab: TabController

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                SiteTile(url: panel.url, title: panel.name, size: 18)
                Text(panel.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                Button { tab.reload() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Reload").accessibilityLabel("Reload panel")
                Button { model.moveWebPanelToTab() } label: { Image(systemName: "arrow.up.forward.square") }.buttonStyle(.borderless).help("Open as a tab").accessibilityLabel("Open panel as a tab")
                Button { model.toggleWebPanel(panel.id) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Close panel").accessibilityLabel("Close panel")
            }
            .padding(.horizontal, 12).frame(height: 38)
            Divider()
            EngineViewHost(view: tab.hostView)
        }
        .frame(width: 380)
        .themedBar(fallback: .regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.28), radius: 16, x: -4, y: 4)
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }
}


/// Bookmarks, History or Downloads as a card over a dimmed page: our own surface, not the system's sheet. Click outside or press Esc to close.
struct FloatingPanelView: View {
    @EnvironmentObject var model: BrowserModel
    let sheet: Sheet
    @State private var shown = false

    var body: some View {
        ZStack {
            Color.black.opacity(shown ? 0.38 : 0).ignoresSafeArea().contentShape(Rectangle())
                .onTapGesture { close() }
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Spacer()
                    pill("sidebar.right", "Dock beside the page") {
                        animated(.easeOut(duration: 0.2)) { model.panelMode = .dock; model.floatingPanel = nil; model.sheet = sheet }
                    }
                    pill("xmark", "Close") { close() }.keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 2)
                NavigationStack {
                    Group {
                        switch sheet {
                        case .bookmarks: BookmarksPanel()
                        case .history: HistoryPanel()
                        case .downloads: DownloadsPanel(coordinator: model.downloads)
                        default: EmptyView()
                        }
                    }
                    .tint(Theme.accent)
                }
                .settlesBeforeShowing()
            }
            .themedSurface()
            .frame(width: 580).frame(maxHeight: 600)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.panelFitsContent, true)
            .themedFill(in: RoundedRectangle(cornerRadius: 22, style: .continuous), fallback: .regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.4), radius: 40, y: 18)
            .scaleEffect(shown ? 1 : 0.96).opacity(shown ? 1 : 0)
            .padding(.vertical, 56).padding(.horizontal, 24)
        }
        .onAppear { animated(.spring(response: 0.34, dampingFraction: 0.88)) { shown = true } }
    }

    private func close() {
        animated(.easeOut(duration: 0.16)) { shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { model.floatingPanel = nil }
    }

    private func pill(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        PanelPill(symbol: symbol, label: label, action: action)
    }
}


/// A library panel filling a browser tab, with the same header buttons as the other modes.
struct PanelTabView: View {
    @EnvironmentObject var model: BrowserModel
    let sheet: Sheet
    @ObservedObject var tab: TabController

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Spacer()
                PanelPill(symbol: "sidebar.right", label: "Open beside the page from now on") {
                    animated(.easeOut(duration: 0.2)) { model.panelMode = .dock; model.closeTab(id: tab.id, force: true); model.sheet = sheet }
                }
                PanelPill(symbol: "xmark", label: "Close") { model.closeTab(id: tab.id, force: true) }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20).padding(.top, 14)
            NavigationStack {
                Group {
                    switch sheet {
                    case .bookmarks: BookmarksPanel()
                    case .history: HistoryPanel()
                    case .downloads: DownloadsPanel(coordinator: model.downloads)
                    default: EmptyView()
                    }
                }
                .tint(Theme.accent)
            }
            .settlesBeforeShowing()
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .themedSurface()
    }
}
