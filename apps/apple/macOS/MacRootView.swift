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
                        // The bar keeps its place in the layout and glides shut, so the page rises with it in one motion.
                        VStack(spacing: 0) { TopBar(leadingInset: toolbarInset); tabRow }
                            .background { if let tab = model.active { ToolbarTintLayer(tab: tab) } }
                            .frame(height: foldedAway ? 0 : barHeight, alignment: .top)
                            .clipped()
                            .opacity(foldedAway ? 0 : 1)
                            .allowsHitTesting(!foldedAway)
                            .accessibilityHidden(foldedAway)
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
                               : ToolbarPriority(fitting: geometry.size.width, leadingInset: toolbarInset).fieldWidth(window: geometry.size.width, leadingInset: toolbarInset))
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
        .background(WindowBackdrop())
        .background(WindowObserver { model.windowFullScreen = $0 })
        .background(TrafficLightsController(hidden: foldedAway || floatingLayout || model.singleToolbar))
        .onAppear {
            peek.linger = peekLinger
            peek.dwell = peekDwell
            WindowDoubleClick.handler = { model.handleTopBarDoubleClick() }
        }
        .onChange(of: model.layoutPreset) { _, _ in peek.linger = peekLinger; peek.dwell = peekDwell }
        .motion(.spring(response: 0.42, dampingFraction: 0.9), value: foldedAway)
        .motion(.spring(response: 0.4, dampingFraction: 0.9), value: pillScrolledAway)
        .motion(.spring(response: 0.38, dampingFraction: 0.86), value: model.pillCollapsed)
        .onAppear { SettingsRouter.opener = { openSettings() } }
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
        .sheet(item: $model.storeOffer) { StoreOfferSheet(info: $0) }
        .sheet(item: $model.privacySheet) { PrivacySheetView(kind: $0, privacy: model.privacy) }
        .alert("Browser Setu", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK") { model.notice = nil }
        } message: { Text(model.notice ?? "") }
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
            .accessibilityHidden(peek.revealed)
    }

    @ViewBuilder private var tabRow: some View {
        switch model.effectiveTabLayout {
        case .separate: HorizontalTabStrip()
        case .compact: CompactTabStrip()
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
                .modifier(PageCard(enabled: !model.focusMode, leading: cardLeading, trailing: cardTrailing,
                                   top: barInset == nil ? WindowInset.gap : 0))
            }
            if model.overviewVisible { TabOverview().transition(.opacity.combined(with: .scale(scale: 0.98))).zIndex(3) }
            if model.paletteVisible { CommandPalette().transition(.opacity).zIndex(4) }
        }
        .motion(.easeOut(duration: 0.16), value: model.overviewVisible)
        .motion(.spring(response: 0.32, dampingFraction: 0.9), value: model.findVisible)
        .motion(.easeOut(duration: 0.14), value: model.activeID)
        .motion(.easeOut(duration: 0.12), value: model.paletteVisible)
        .motion(.easeOut(duration: 0.12), value: model.floatingAddressVisible)
    }

    /// Horizontal presentation only. Vertical tabs live in the sidebar, so nothing is drawn twice.
    @ViewBuilder private var tabRow: some View {
        switch model.effectiveTabLayout {
        case .separate: HorizontalTabStrip()
        case .compact: CompactTabStrip()
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
        if let other = model.splitTab, other.id != active.id {
            Group {
                if model.splitOrientation == .sideBySide {
                    HSplitView { panel(active, focused: true); panel(other, focused: false) }
                } else {
                    VSplitView { panel(active, focused: true); panel(other, focused: false) }
                }
            }
            .overlay(alignment: .topTrailing) { SplitControls().padding(8) }
        } else {
            PageArea(tab: active).id(active.id).transition(.opacity)
        }
    }

    private func panel(_ tab: TabController, focused: Bool) -> some View {
        PageArea(tab: tab).id(tab.id)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(focused ? Theme.accent : Color.clear, lineWidth: 2).allowsHitTesting(false))
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { if !focused { model.swapSplit() } })
            .accessibilityLabel(focused ? "Active panel" : "Side panel")
    }
}

struct SplitControls: View {
    @EnvironmentObject var model: BrowserModel
    var body: some View {
        HStack(spacing: 4) {
            Button { model.splitOrientation = model.splitOrientation == .sideBySide ? .stacked : .sideBySide } label: {
                Image(systemName: model.splitOrientation == .sideBySide ? "rectangle.split.1x2" : "rectangle.split.2x1")
            }.help("Change Split Direction")
            Button { model.swapSplit() } label: { Image(systemName: "arrow.left.arrow.right") }.help("Swap Panels")
            Button { model.closeSplit() } label: { Image(systemName: "xmark") }.help("Close Split View")
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
            Button { model.findNext(backwards: true) } label: { Image(systemName: "chevron.up") }.help("Previous")
            Button { model.findNext() } label: { Image(systemName: "chevron.down") }.help("Next")
            Button("Done") { model.hideFind() }.keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.bar)
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
            if tab.isBlank { StartPageView(isPrivate: tab.isPrivate) }
        }
        .overlay(alignment: .bottomTrailing) { if model.workbench.showSizeHUD { SizeHUD() } }
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
