import SwiftUI

struct PhoneRootView: View {
    @EnvironmentObject var model: BrowserModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// The live speed lives in the Dynamic Island while the browser is in front.
    @StateObject private var speedActivity = SpeedLiveActivityController()
    @StateObject private var keyboard = KeyboardLift()
    /// Redraws this screen when the room for the status bar or the home indicator becomes known or changes.
    @ObservedObject private var windowInsets = WindowInsets.shared
    /// The vertical list of tabs that the left pill opens while the dock is folded.
    @State private var verticalTabsOpen = false

    /// An iPhone is always the phone layout. Its size class is "regular" in landscape on the larger models, which used to bring up the iPad sidebar.
    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }
    private var compactWidth: Bool { isPhone || sizeClass == .compact }
    /// On a narrow iPad (upright) the sidebar steps aside while a panel is docked, so the page keeps room.
    private var showsTabRail: Bool { isPhone && model.phoneUsesTabRail && !model.overviewVisible }
    private var showsSidebar: Bool { !isPhone && sizeClass == .regular && model.sidebarVisible && !(model.dockedPanel != nil && UIScreen.main.bounds.width < 1000) }
    /// While a page is read, the address bar and toolbar slide away and the page runs edge to edge.
    private var barsHidden: Bool { model.chromeCollapsed && model.canCollapseChrome }
    /// The Floating layout on iPhone: no bars at all, only the dock at the bottom and the search button at the top right.
    private var floatingMode: Bool { model.topBarHidden }
    /// Either way the bars are out of the picture and the dock stands in for them.
    private var showsDock: Bool { floatingMode }
    /// While a page is read the dock is only a small pill; scrolling back, or a tap on it, opens it again.
    private var dockCompact: Bool { showsDock && model.canCollapseDock && model.chromeCollapsed && !model.floatingAddressVisible }

    /// Held on its own strip under the page. The page is short in landscape, so the dock must not float over it.
    /// The home-indicator strip the page runs under when the bars are away.
    private static var topSafeInset: CGFloat { WindowInsets.shared.top }

    private static var bottomSafeInset: CGFloat { WindowInsets.shared.bottom }

    /// Room kept clear of the page for the whole dock, measured from the home-indicator edge (the page already stops there): the dock's height and a small gap.
    /// It must not read the window's own safe area while laying out: that made the whole screen come up blank.
    private var pageReservedBottom: CGFloat {
        // Only for a page with its own bar along the bottom, and kept the same when the dock folds into its pill: the page changing size while you scroll made its content jump.
        guard showsDock, model.activeFixedBottom, !landscape, !dockOnItsOwnStrip, !model.floatingAddressVisible else { return 0 }
        return PhoneChrome.height + PhoneChrome.dockLift + 8
    }

    private var landscape: Bool { isPhone && verticalSizeClass == .compact }
    /// The iPhone's bar layouts: no bar fixed to an edge. ONE sheet of glass floats over the page, which runs to the screen's edge behind it (see `PhoneBarSheet`), and the same
    /// sheet shrinks into a small capsule while a page is read. Landscape and the iPad keep their own bars.
    private var floatingBars: Bool { isPhone && model.phoneSpec.style == .attached }
    /// Where the sheet is: where the layout puts it, upright or on its side. Turned on its side every bar layout is the slim Compact bar, since the screen is short.
    private var sheetAtBottom: Bool { model.phoneBarAtBottom }

    /// How far up from the bottom of the screen the toasts sit: clear of the bar sheet when it is down there, as before otherwise.
    private var barClearanceBottom: CGFloat {
        guard floatingBars, sheetAtBottom, !barsHidden else { return 92 }
        return floatingRoom + Self.bottomSafeInset + 12
    }
    /// And how far down from the top for the pills that offer a saved sign-in or a blocked pop-up.
    private var barClearanceTop: CGFloat {
        guard floatingBars, !sheetAtBottom, !barsHidden else { return 58 }
        return floatingRoom + Self.topSafeInset + 10
    }

    /// How far up from the bottom the back-to-top pill sits: just clear of the bar when the bar is down there, folded or open, else just above the home area.
    private var backToTopLift: CGFloat {
        guard floatingBars, sheetAtBottom else { return 16 }
        if barsHidden { return PhoneBarSheet.foldedHeight + 6 + 10 }
        return PhoneBarSheet.height(sheetKind) + (sheetKind == .card ? 0 : 6) + 10
    }

    /// How much of the page's foot a bar at the bottom takes: the page view ends above it, so the footers and bottom tab bars of a site sit clear of it and are never hidden behind it.
    private var pageBottomRoom: CGFloat {
        guard floatingBars, sheetAtBottom, !barsHidden, model.active != nil else { return 0 }
        let editing = model.addressBar.isEditing
        // With the keyboard up the bar sits on it, so no room is kept for the home indicator.
        let home = editing ? 0 : Self.bottomSafeInset
        switch sheetKind {
        case .card: return (editing ? 72 : PhoneBarSheet.height(.card)) + home
        case .compact: return PhoneBarSheet.height(.compact) + 6 + home
        }
    }

    private var sheetKind: PhoneBarSheet.Kind { model.phoneSpec.compactBar || landscape ? .compact : .card }

    /// How much room the sheet takes (its tallest), with its gap.
    private var floatingRoom: CGFloat { PhoneBarSheet.height(sheetKind) + (sheetKind == .card ? 4 : 14) }

    /// Room the page keeps clear for the sheet while it is open, so the last of a page can be scrolled above it and a site's own fixed bars sit clear of it.
    private var floatingInsets: (top: CGFloat, bottom: CGFloat) {
        guard floatingBars, !barsHidden, model.active != nil else { return (0, 0) }
        let room = floatingRoom
        // A bar at the bottom shrinks the page view instead (see `pageBottomRoom`): WebKit does not move a site's fixed footers clear of room given only as an inset.
        return sheetAtBottom ? (0, 0) : (room, 0)
    }

    /// The page takes over the edge the sheet floats at.
    private var floatEdges: Edge.Set {
        guard floatingBars else { return [] }
        return .vertical
    }

    @ViewBuilder private func barOrStrip(_ tab: TabController, edge: VerticalEdge) -> some View {
        Group {
            if floatingBars { Color.clear.frame(height: 0) } else if barsHidden { PhoneBarStrip(tab: tab, atBottom: edge == .bottom) } else { PhoneAddressArea(tab: tab) }
        }
        .transition(.move(edge: edge == .top ? .top : .bottom).combined(with: .opacity))
    }
    /// Turned on its side, the old dock goes to the top; Immersive's pill stays at the bottom, where it is upright.
    private var pillOnTop: Bool { landscape && !model.floatingAddressVisible && !model.phoneSpec.fanOut }
    private var dockOnItsOwnStrip: Bool { landscape && floatingMode && !dockCompact && !model.floatingAddressVisible && model.active != nil }
    /// In landscape the toolbar is a strip along the TOP, as in Safari: height is scarce, and the thumbs rest on the sides.

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                if showsSidebar { IPadSidebar().transition(.move(edge: .leading).combined(with: .opacity)); Divider() }
                if showsTabRail { PhoneTabRail(extraTop: floatingBars && !barsHidden && !sheetAtBottom ? floatingRoom : 0, extraBottom: floatingBars && !barsHidden && sheetAtBottom ? floatingRoom : 0).transition(.move(edge: .leading).combined(with: .opacity)) }
                mainColumn
                if let docked = model.dockedPanel, !isPhone {
                    DockedPanelView(sheet: docked).transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .motion(.easeOut(duration: 0.22), value: model.dockedPanel)
            if model.overviewVisible {
                TabOverview().transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            // A download is never silent: progress while it runs, a card when it is done.
            if model.showSetup { SetupAssistantView().transition(.opacity).zIndex(10) }
            GlanceLayer(glance: model.glance)
            if let tip = model.layoutTip { LayoutTipCard(preset: tip).zIndex(11) }
            VStack(spacing: 8) { PendingLoginPill(); PopupBlockedPill() }
                .padding(.top, barClearanceTop)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            NoticeToast()
                .padding(.bottom, barClearanceBottom + 40)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            DownloadToast(coordinator: model.downloads)
                .padding(.horizontal, 12).padding(.bottom, barClearanceBottom)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            // The bar layouts: one sheet of glass over the page, open or (scrolling) shrunk into a small capsule.
            if floatingBars, let tab = model.active, !model.floatingAddressVisible {
                PhoneBarSheet(tab: tab, address: model.addressBar, kind: sheetKind, folded: barsHidden, atBottom: sheetAtBottom)
                    // The dock runs edge to edge; the Compact bar hovers, with a margin all round.
                    .padding(.horizontal, sheetKind == .card ? 0 : 12)
                    .padding(sheetAtBottom ? .bottom : .top, sheetKind == .card ? 0 : 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: sheetAtBottom ? .bottom : .top)
                    .zIndex(4)
            }
            // Where the page runs under the status bar, the clock stays readable: a soft veil that fades out over the page, as in Safari.
            if isPhone, !landscape, model.active != nil, (floatingBars && sheetAtBottom) || model.phoneSpec.fanOut {
                Rectangle().fill(.ultraThinMaterial)
                    .frame(height: Self.topSafeInset + 6)
                    .mask(LinearGradient(colors: [.black.opacity(0.6), .black.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea().allowsHitTesting(false).zIndex(3)
            }
            // The way back to the top of a long page: a small pill at the left, just above the bar (and moving with it as it folds and opens), for a few seconds.
            if isPhone, model.backToTopVisible, !model.overviewVisible, !model.floatingAddressVisible, model.active != nil {
                BackToTopPill()
                    .padding(.leading, 14)
                    .padding(.bottom, backToTopLift)
                    .animation(.spring(response: 0.42, dampingFraction: 0.86), value: barsHidden)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .zIndex(6)
            }
            // The Enhanced Player panel, when asked for from the menu: above the bar, over the page, never covering the video unless the person puts it there.
            if isPhone, model.playerPanelVisible, !model.overviewVisible {
                EnhancedPlayerPanel(player: model.player) { model.hidePlayer() }
                    .padding(.horizontal, 12)
                    .padding(.bottom, backToTopLift)
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(7)
            }
            // "Show device network speed": a small readout over the page while the app is in front (the Dynamic Island shows it once you leave). At the top, or at the bottom
            // when the address bar is up there; it never takes a tap.
            if model.showSpeedPill, isPhone, !model.floatingAddressVisible, !model.overviewVisible, !landscape {
                let atTop = model.phoneBarAtBottom || floatingMode
                SpeedPill(height: 20)
                    .padding(atTop ? .top : .bottom, 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: atTop ? .top : .bottom)
                    .transition(.opacity)
                    .zIndex(5)
            }
        }
        .background { Group { if model.themeIsActive { ChromeBackdrop() } else { Color(.systemBackground) } }.ignoresSafeArea() }
        .downloadFlight(model.downloads)
        .ignoresSafeArea(.keyboard, edges: showsDock ? .bottom : [])
        .scrollIndicators(.hidden)
        .motion(.easeOut(duration: 0.18), value: model.overviewVisible)
        .motion(.spring(response: 0.42, dampingFraction: 0.9), value: showsDock)
        .motion(.spring(response: 0.4, dampingFraction: 0.88), value: barsHidden)
        .onChange(of: floatingInsets.top, initial: true) { _, top in model.phoneTopInset = top }
        .onChange(of: floatingInsets.bottom, initial: true) { _, bottom in
            #if DEBUG
            debugLog("ROOM bottom=\(bottom) floatingBars=\(floatingBars) active=\(model.active != nil) hidden=\(barsHidden)")
            #endif
            model.phoneBottomInset = bottom
        }
        .motion(.spring(response: 0.4, dampingFraction: 0.88), value: showsSidebar)
        .motion(.spring(response: 0.4, dampingFraction: 0.88), value: showsTabRail)
        .sheet(item: $model.sheet) { SheetContainer(sheet: $0) }
        .sheet(item: $model.storeOffer) { StoreOfferSheet(info: $0) }
        .sheet(item: $model.privacySheet) { PrivacySheetView(kind: $0, privacy: model.privacy) }
        .preferredColorScheme(model.appearance.colorScheme ?? (model.themeIsActive ? model.activeTheme.scheme?.colorScheme : nil))
        .tint(Theme.accent)
        .onChange(of: sizeClass) { _, c in if c == .regular, !isPhone { model.sidebarVisible = true } }
        .onChange(of: scenePhase, initial: true) { _, phase in speedActivity.update(wanted: model.showSpeedPill, phase: phase, popups: model.speedPopups); model.speedActivityStatus = speedActivity.status }
        .onChange(of: model.showSpeedPill) { _, on in speedActivity.update(wanted: on, phase: scenePhase, popups: model.speedPopups); model.speedActivityStatus = speedActivity.status }
        .onChange(of: model.speedPopups) { _, on in speedActivity.update(wanted: model.showSpeedPill, phase: scenePhase, popups: on) }
        .onChange(of: model.showSetup) { _, showing in if !showing { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { model.maybeShowLayoutTip() } } }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { model.maybeShowLayoutTip() }
            #if DEBUG
            // Development only: turn the phone on its side for a screenshot.
            if ProcessInfo.processInfo.environment["BS_LANDSCAPE"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
                }
            }
            if ProcessInfo.processInfo.environment["BS_TABS_LIST"] == "1" { DispatchQueue.main.asyncAfter(deadline: .now() + 10) { verticalTabsOpen = true } }
            #endif
            if sizeClass == .regular, !isPhone { model.sidebarVisible = true }
            model.showSpeedHandler = { Task { await speedActivity.flash() } }
        }
    }

    private var mainColumn: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                RecoveryBanner()
                // One motion: the strip's height, its fade and the page growing into the room all use the same curve and length.
                if landscape, floatingMode, let tab = model.active {
                    PhoneDock(tab: tab, editable: false)
                        .frame(maxWidth: 900)
                        .padding(.horizontal, PhoneChrome.margin)
                        .padding(.vertical, 3)
                        .opacity(dockOnItsOwnStrip ? 1 : 0)
                        .frame(height: dockOnItsOwnStrip ? PhoneChrome.height + 6 : 0, alignment: .top)
                        .clipped()
                        .allowsHitTesting(dockOnItsOwnStrip)
                }
                // On its side the phone shows the open tabs as chips under the address strip; it goes with the strip while a page is read.
                if landscape, floatingMode, model.visibleTabs.count > 1, dockOnItsOwnStrip {
                    PhoneTabStrip().transition(.opacity)
                }
                if !model.phoneBarAtBottom || landscape, let tab = model.active, !showsDock, !model.floatingAddressVisible {
                    barOrStrip(tab, edge: .top)
                }
                if let tab = model.active {
                    ZStack {
                        EngineViewHost(view: tab.hostView).id(tab.id)
                            .tabErrorOverlay(tab)
                            .transition(model.tabSlide == 0 ? .opacity : .push(from: model.tabSlide > 0 ? .trailing : .leading))
                        if tab.isBlank {
                            StartPageView(isPrivate: tab.isPrivate)
                                // A floating toolbar covers the foot of the page, so the page leaves room for it.
                                .environment(\.startTopInset, floatingBars && !sheetAtBottom ? floatingRoom + Self.topSafeInset : 0)
                                .environment(\.startBottomInset, floatingBars && sheetAtBottom ? 0 : (showsDock && !landscape && pageReservedBottom == 0 ? max(PhoneChrome.height, 100) + PhoneChrome.dockLift + Self.bottomSafeInset + 14 : 0))
                        }
                        // With the dock in charge, suggestions appear in the search panel instead.
                        if !showsDock {
                            PhoneSuggestions(address: model.addressBar, position: sheetAtBottom ? .bottom : .top)
                                // With the compact layouts the row floats over the page's own edge, so what the search finds sits clear of it.
                                .padding(.bottom, 0)
                                .padding(.top, floatingBars && !sheetAtBottom ? floatingRoom + Self.topSafeInset - 2 : 0)
                        }
                    }
                    .padding(.bottom, pageBottomRoom)
                    .animation(.easeInOut(duration: 0.25), value: pageBottomRoom)
                    .clipped()
                    .overlay(alignment: .bottom) {
                        WebStoreBanner()
                            .padding(.bottom, showsDock && !landscape && pageReservedBottom == 0 ? PhoneChrome.height + PhoneChrome.dockLift + Self.bottomSafeInset + 12 : 12)
                    }
                    // In landscape the page runs under the sides of the screen (the notch side and the home-indicator side), so there are
                    // no black strips; WebKit keeps the text itself clear of them. The foot of the page runs under the home indicator too, so no dark band is left under it.
                    .ignoresSafeArea(.container, edges: landscape ? [.horizontal, .bottom] : [])
                    .motion(.easeInOut(duration: 0.26), value: model.activeID)
                    // Over the page's top edge, never behind the status bar: with the bars away the dock shows it instead.
                    .overlay(alignment: .top) { if !showsDock { LoadingBar(tab: tab).id(tab.id) } }
                } else {
                    Color.platformBackground
                }
                if model.phoneBarAtBottom, !landscape, let tab = model.active, !showsDock, !model.floatingAddressVisible {
                    barOrStrip(tab, edge: .bottom)
                }
            }
            // With the bars away the page still starts below the status bar (a site's own top bar would otherwise sit under the clock) and ends above the dock
            // (a site's own bottom tabs would otherwise be hidden by it). It runs under the home-indicator strip, which the dock's own room includes. When the dock
            // folds into its small pill, the page takes that room back.
            .ignoresSafeArea(.container, edges: showsDock && !dockOnItsOwnStrip ? (model.phoneSpec.fanOut ? .vertical : (model.activeFixedTop ? .bottom : .vertical)) : floatEdges)
            // The strip behind the clock takes the page's own colour, so a dark site does not get a white band above it. It belongs to the page's area only.
            .background(alignment: .top) {
                if showsDock, model.activeFixedTop, model.tintToolbar, let tab = model.active { PageTopStrip(tab: tab) }
            }
            .padding(.bottom, pageReservedBottom)
            .motion(.spring(response: 0.4, dampingFraction: 0.88), value: pageReservedBottom)
            // The strip behind the clock takes the page's own colour, so a dark site does not get a white band above it.
            .motion(.easeInOut(duration: 0.3), value: dockOnItsOwnStrip)
            // While the dock's address pill is being typed in, the page is dimmed and a tap on it ends the search. The dimming sits BELOW the dock, never
            // above it: drawn above, it received every touch meant for the text field (placing the cursor, a long press for Cut, Copy and Paste, dragging
            // the selection handles) and ended the search instead, so the address could be typed but never copied or pasted into.
            // Nothing is drawn over the status bar: the page shows through it, with no tint and no blur.
            if model.floatingAddressVisible, showsDock {
                Color.black.opacity(0.28).ignoresSafeArea().contentShape(Rectangle())
                    .onTapGesture { model.cancelSearch() }
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
            if floatingMode, !dockOnItsOwnStrip, let tab = model.active {
                // The dock is always at the bottom, where the thumb is: whole, or folded into one small pill.
                ZStack(alignment: landscape && !model.floatingAddressVisible ? .top : .bottom) {
                    // Both stay in place and morph together, so there is never a blank moment: the bar shrinks toward the right edge while it fades, and
                    // the round favicon button grows out of the same corner a beat later; coming back is the same in reverse.
                    PhoneDock(tab: tab)
                        .frame(maxWidth: 560)
                        .padding(.horizontal, PhoneChrome.margin)
                        .opacity(dockCompact ? 0 : 1)
                        .motion(.easeInOut(duration: dockCompact ? 0.16 : 0.26).delay(dockCompact ? 0 : 0.06), value: dockCompact)
                        .scaleEffect(dockCompact ? 0.3 : 1, anchor: .trailing)
                        .motion(.spring(response: 0.42, dampingFraction: 0.84), value: dockCompact)
                        .allowsHitTesting(!dockCompact)
                        .accessibilityHidden(dockCompact)
                    PhoneCompactPill(tab: tab, tabsOpen: $verticalTabsOpen)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, PhoneChrome.margin)
                        .opacity(dockCompact ? 1 : 0)
                        .motion(.easeInOut(duration: dockCompact ? 0.24 : 0.14).delay(dockCompact ? 0.08 : 0), value: dockCompact)
                        .scaleEffect(dockCompact ? 1 : 0.4, anchor: .trailing)
                        .motion(.spring(response: 0.42, dampingFraction: 0.78), value: dockCompact)
                        .allowsHitTesting(dockCompact)
                        .accessibilityHidden(!dockCompact)
                    // The mirror of it on the left: the tabs, as a vertical list.
                    PhoneTabsPill(isOpen: $verticalTabsOpen)
                        .overlay(alignment: .top) {
                            // New tab, floating above the tabs pill once the screen has been still; it goes while the page moves or the list is open.
                            PhoneFloatingExtra(symbol: "plus", label: "New tab", identifier: "compact-new-tab",
                                               visible: model.phoneSpec.newTabPill && !model.phoneSpec.fanOut && !model.pageIsScrolling && !verticalTabsOpen) { _ = model.newTab() }
                        }
                        .opacity(model.phoneSpec.tabsPill && !model.phoneSpec.fanOut ? 1 : 0).allowsHitTesting(model.phoneSpec.tabsPill && !model.phoneSpec.fanOut)
                        .accessibilityHidden(!model.phoneSpec.tabsPill || model.phoneSpec.fanOut)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, PhoneChrome.margin)
                        .opacity(dockCompact ? 1 : 0)
                        .motion(.easeInOut(duration: dockCompact ? 0.24 : 0.14).delay(dockCompact ? 0.08 : 0), value: dockCompact)
                        .scaleEffect(dockCompact ? 1 : 0.4, anchor: .leading)
                        .motion(.spring(response: 0.42, dampingFraction: 0.78), value: dockCompact)
                        .allowsHitTesting(dockCompact)
                        .accessibilityHidden(!dockCompact)
                }
                .padding(pillOnTop ? .top : .bottom, pillOnTop ? 4 : (model.floatingAddressVisible ? keyboard.height + 8 : PhoneChrome.dockLift))
                .frame(maxHeight: .infinity, alignment: pillOnTop ? .top : .bottom)
                .motion(landscape ? .easeInOut(duration: 0.3) : .spring(response: 0.4, dampingFraction: 0.86), value: dockCompact)
                // In place and quick: when search opens the bar fades into the editing field instead of flying away.
                .transition(.opacity)
            }
            if verticalTabsOpen {
                PhoneVerticalTabs(isOpen: $verticalTabsOpen).zIndex(20)
            }
        }
        .motion(.spring(response: 0.34, dampingFraction: 0.88), value: verticalTabsOpen)
        // The list belongs to the folded dock: when the dock opens again, or the address bar does, the list is gone.
        .onChange(of: model.phoneTabsListRequest) { _, _ in verticalTabsOpen = true }
        // The page is told how much room the status bar and the home indicator take. If that room only became known after the page was first told, tell it again, or a site's
        // fixed header sits behind the clock.
        .onChange(of: windowInsets.top) { _, _ in model.active?.applyBottomInset(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { model.active?.applyBottomInset() } }
        .onChange(of: windowInsets.bottom) { _, _ in model.active?.applyBottomInset(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { model.active?.applyBottomInset() } }
        .onChange(of: model.activeID) { _, _ in DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { model.active?.applyBottomInset() } }
        .onChange(of: model.activeID) { _, _ in model.resetBackToTop(); model.hidePlayer() }
        .onChange(of: model.active?.url) { _, _ in model.resetBackToTop() }
        .onChange(of: dockCompact) { _, compact in if !compact { verticalTabsOpen = false } }
        .modifier(SystemTranslation())
        .overlay {
            if model.floatingAddressVisible, showsDock {
                // The dock's own address pill is the field; only what the search finds is drawn here, just above it. Nothing here may cover the pill.
                GeometryReader { geo in
                    let below = keyboard.height + PhoneChrome.height + 16
                    ZStack(alignment: .bottom) {
                        PhoneSuggestionsCard(address: model.addressBar, anchoredTop: false, maxHeight: max(80, geo.size.height - below - geo.safeAreaInsets.top - 8))
                            .padding(.horizontal, PhoneChrome.margin)
                            .padding(.bottom, below)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            } else if model.floatingAddressVisible, let tab = model.active {
                ZStack(alignment: model.searchPanelAtBottomNow ? .bottom : .top) {
                    // The page behind is dimmed, and a tap on it ends the search and puts everything back.
                    Color.black.opacity(0.28).ignoresSafeArea().contentShape(Rectangle())
                        .onTapGesture { model.cancelSearch() }
                        .transition(.opacity)
                    PhoneSearchPanel(tab: tab)
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: model.searchPanelAtBottomNow ? .bottom : .top)))
                }
            }
        }
        .motion(.spring(response: 0.34, dampingFraction: 0.88), value: model.floatingAddressVisible)
    }
}

struct PhoneAddressArea: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var landscapePhone: Bool { UIDevice.current.userInterfaceIdiom == .phone && verticalSizeClass == .compact }

    var body: some View {
        Group {
            if landscapePhone {
                // As in Safari on its side: one slim row along the top. Back and forward, the address, then share, tabs and more.
                PhoneLandscapeBar(tab: tab, address: model.addressBar)
            } else if sizeClass == .regular && UIDevice.current.userInterfaceIdiom == .pad {
                // A wide screen has room for everything on one line: the controls, then the address field.
                HStack(spacing: 14) {
                    if !model.addressBar.isEditing { PhoneToolbar(tab: tab).frame(width: 400).transition(.opacity) }
                    PhoneAddressBar(tab: tab, address: model.addressBar)
                        .modifier(TabSwipe(allowsOverview: !model.addressBar.isEditing))
                }
            } else {
                // The address field above the buttons, in one container. Editing happens here, in place: the buttons make room and the field takes the card.
                VStack(spacing: 4) {
                    PhoneAddressBar(tab: tab, address: model.addressBar)
                        .modifier(TabSwipe(allowsOverview: !model.addressBar.isEditing))
                    if !model.addressBar.isEditing { PhoneToolbar(tab: tab).transition(.opacity.combined(with: .move(edge: .bottom))) }
                }
            }
        }
        .modifier(AttachedBarSurface(landscape: landscapePhone))
        .motion(.spring(response: 0.34, dampingFraction: 0.88), value: model.addressBar.isEditing)
    }
}

/// The surface of the attached bar, as Safari's: a bar fixed to its edge, full width, in the theme's surface, with a hairline toward the page. Its colour runs on under the
/// status bar or the home indicator, so nothing of the page shows through the safe area.
struct AttachedBarSurface: ViewModifier {
    @EnvironmentObject var model: BrowserModel
    let landscape: Bool
    func body(content: Content) -> some View {
        let atBottom = model.phoneBarAtBottom && !landscape
        content
            .padding(.horizontal, landscape ? 8 : 12).padding(.vertical, landscape ? 3 : 8)
            .frame(maxWidth: .infinity)
            .barSurface(atBottom: atBottom)
    }
}

extension View {
    /// The one surface of the attached bar and its folded strip.
    func barSurface(atBottom: Bool) -> some View {
        background {
            Rectangle().fill(.clear).themedBar(fallback: .bar).ignoresSafeArea(edges: atBottom ? .bottom : .top)
        }
        .overlay(alignment: atBottom ? .top : .bottom) { Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 0.5) }
    }
}

/// The phone's bar when it is held on its side: a single slim row, like Safari's.
struct PhoneLandscapeBar: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController
    @ObservedObject var address: AddressBarController

    var body: some View {
        HStack(spacing: 2) {
            if !address.isEditing {
                if model.shows(.backForward) {
                    item("chevron.left", disabled: !tab.canGoBack, label: "Back") { tab.goBack() }
                    item("chevron.right", disabled: !tab.canGoForward, label: "Forward") { tab.goForward() }
                }
            }
            // As in Safari on its side: the address sits in the middle at a reasonable width, back and forward to its left, share, new tab and tabs to its right.
            // While it is being edited it takes the whole row.
            if !address.isEditing { Spacer(minLength: 0) }
            PhoneAddressBar(tab: tab, address: address, compact: true)
                .modifier(TabSwipe(allowsOverview: !address.isEditing))
                .frame(maxWidth: address.isEditing ? .infinity : 520)
                .padding(.horizontal, 4)
            if !address.isEditing { Spacer(minLength: 0) }
            if !address.isEditing {
                if let url = tab.url, !tab.isBlank { ShareLink(item: url) { Image(systemName: "square.and.arrow.up").frame(width: 40, height: 30) }.accessibilityLabel("Share") }
                Button { _ = model.newTab() } label: { Image(systemName: "plus").frame(width: 36, height: 30) }.accessibilityLabel("New tab")
                Button { model.openTabsView() } label: {
                    Text("\(model.visibleTabs.count)").font(.footnote.bold()).frame(width: 22, height: 22)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(lineWidth: 1.5)).frame(width: 40, height: 30)
                }
                .accessibilityLabel("Tab overview")
                PhoneMoreMenu(tab: tab).transition(.opacity)
            }
        }
        .motion(.easeOut(duration: 0.2), value: address.isEditing)
    }

    private func item(_ symbol: String, disabled: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 36, height: 30) }
            .disabled(disabled).accessibilityLabel(label)
            .contextMenu { if symbol == "chevron.left" { NavHistoryItems(tab: tab, back: true) } else { NavHistoryItems(tab: tab, back: false) } }
    }
}

struct PhoneAddressBar: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController
    @ObservedObject var address: AddressBarController
    /// Used by the search panel, which opens because the user asked to type.
    var focusOnAppear = false
    /// A shorter field, for the slim bar of a phone held on its side.
    var compact = false
    /// The compact layouts: the field is a glass capsule floating over the page, like Safari's, instead of a grey field inside a bar.
    var glass = false
    /// Inside a capsule that is already the surface: the field adds none of its own.
    var bare = false
    /// The reload / stop button inside the field. The bar layouts give it a button of its own instead.
    var showsReload = true
    @FocusState private var focused: Bool

    private var statusIcon: some View {
        Image(systemName: tab.isPrivate ? "eye.slash.fill" : (tab.isBlank ? "magnifyingglass" : (tab.isSecure ? "lock.fill" : "exclamationmark.triangle.fill")))
            .font(.footnote).foregroundStyle(tab.isPrivate ? Theme.privateAccent : (tab.isSecure || tab.isBlank ? .secondary : .orange))
    }

    var body: some View {
        HStack(spacing: 8) {
            ShieldButton(privacy: model.privacy, host: tab.url?.host, showLabel: false)
            if !bare || tab.isPrivate { statusIcon }
            TextField("Search or enter address", text: $address.text)
                .textFieldStyle(.plain).focused($focused)
                // A page that is not secure shows its address in orange, in place of a second warning icon.
                .foregroundStyle(bare && !tab.isSecure && !tab.isBlank && !tab.isPrivate && !address.isEditing ? Color.orange : Color.primary)
                .multilineTextAlignment(address.isEditing ? .leading : .center)
                .autocorrectionDisabled().textInputAutocapitalization(.never).keyboardType(.webSearch)
                .submitLabel(.go)
                .accessibilityIdentifier("omnibox")
                .onSubmit {
                    let text = address.text
                    focused = false
                    address.isEditing = false
                    address.clear()
                    model.navigate(input: text)
                }
            if address.isEditing {
                Button("Cancel") { focused = false }.font(.callout).transition(.opacity.combined(with: .move(edge: .trailing)))
            } else if showsReload, tab.isLoading {
                Button { tab.stop() } label: { Image(systemName: "xmark").accessibilityLabel("Stop loading") }.foregroundStyle(.secondary).transition(.opacity)
            } else if showsReload, !tab.isBlank {
                Button { tab.reload() } label: { Image(systemName: "arrow.clockwise").accessibilityLabel("Reload") }.foregroundStyle(.secondary).transition(.opacity)
            }
        }
        .motion(.easeOut(duration: 0.2), value: address.isEditing)
        .motion(.easeOut(duration: 0.18), value: tab.isLoading)
        .padding(.horizontal, bare ? (compact ? 16 : 8) : (glass ? 16 : (compact ? 10 : 12))).padding(.vertical, bare ? 8 : (glass ? 13 : (compact ? 6 : 10)))
        .modifier(AddressFieldSurface(glass: glass, compact: compact, bare: bare))
        .onAppear {
            sync()
            if focusOnAppear {
                DispatchQueue.main.async { focused = true }
                // ⌘K from a keyboard opens search already in command mode.
                if let prefill = model.pendingAddressPrefill {
                    model.pendingAddressPrefill = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { address.text = prefill; address.refresh(model: model) }
                }
            }
        }
        .onChange(of: tab.id) { _, _ in focused = false; sync() }
        .onChange(of: tab.url) { _, _ in if !address.isEditing { sync() } }
        .onChange(of: tab.isBlank) { _, _ in if !address.isEditing { sync() } }
        .onChange(of: focused) { _, f in
            if f {
                address.isEditing = true
                address.text = tab.isBlank ? "" : (tab.url?.absoluteString ?? "")
                selectWholeAddress(expecting: address.text)
            } else {
                address.isEditing = false
                address.clear()
                sync()
            }
        }
        .onChange(of: address.text) { _, _ in if address.isEditing { address.refresh(model: model) } }
        .onChange(of: model.omniboxFocusTick) { _, _ in
            // A second request (made when the bars had to slide in first) must not wipe what has been typed since.
            if !focused { address.text = "" }
            focused = true
            // ⌘K from a keyboard: the search opens already in command mode.
            if let prefill = model.pendingAddressPrefill {
                model.pendingAddressPrefill = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { address.text = prefill; address.refresh(model: model) }
            }
        }
    }

    private func sync() { address.text = tab.isBlank ? "" : displayHost(tab.url) }

    /// Tapping the address bar selects the whole address, so typing replaces it. UIKit places the cursor from the tap just after the
    /// field takes focus, so the selection is made a moment later, and again once the keyboard is up. Typing (the text no longer
    /// being the address that was put there) cancels it, so it can never replace what the user is writing.
    private func selectWholeAddress(expecting text: String) {
        guard !text.isEmpty else { return }
        for delay in [0.03, 0.15, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard address.isEditing, address.text == text else { return }
                UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
            }
        }
    }
}

struct PhoneToolbar: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject private var look = LookState.shared
    @ObservedObject var tab: TabController
    /// Taller buttons, for the bar layouts' sheet.
    var tall = false
    /// The card's own row: back, forward, share, tabs and the menu, evenly spaced. Bookmark, new tab and downloads are in the menu.
    var clean = false
    private var rowHeight: CGFloat { tall ? 44 : 32 }
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        HStack {
            if sizeClass == .regular, UIDevice.current.userInterfaceIdiom != .phone {
                button("sidebar.left", disabled: false, label: "Toggle sidebar") { model.sidebarVisible.toggle() }
                Spacer()
            }
            if clean || model.shows(.backForward) {
                button("chevron.left", disabled: !tab.canGoBack, label: "Back") { tab.goBack() }
                Spacer()
                button("chevron.right", disabled: !tab.canGoForward, label: "Forward") { tab.goForward() }
                Spacer()
            }
            if clean || model.shows(.share) {
                if let url = tab.url, !tab.isBlank {
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up").frame(width: 44, height: rowHeight) }
                } else {
                    button("square.and.arrow.up", disabled: true, label: "Share") {}
                }
                Spacer()
            }
            if !clean, model.shows(.bookmark) {
                button(model.activeBookmarked ? "star.fill" : "star", disabled: tab.isBlank, label: "Bookmark") { model.toggleBookmark() }
                Spacer()
            }
            if !clean, model.shows(.newTab) { button("plus", disabled: false, label: "New tab") { model.newTab() }; Spacer() }
            if !clean, model.shows(.downloads) { button("arrow.down.circle", disabled: false, label: "Downloads") { model.sheet = .downloads }.marksDownloadsButton(); Spacer() }
            if clean || model.shows(.tabOverview) {
                Button { model.openTabsView() } label: {
                    Text("\(model.visibleTabs.count)").font(.footnote.bold())
                        .frame(width: 24, height: 24)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(lineWidth: 1.5))
                        .frame(width: 44, height: rowHeight)
                }
                .accessibilityLabel("Tab overview")
                Spacer()
            }
        Menu {
                Button("New Tab", systemImage: "plus") { model.newTab() }
                Button("New Private Tab", systemImage: "eye.slash") { model.openTab(url: nil, isPrivate: true) }
                Button(model.activeBookmarked ? "Remove Bookmark" : "Add Bookmark", systemImage: "star") { model.toggleBookmark() }.disabled(tab.isBlank)
                Button("Add to Favorites", systemImage: "heart") {
                    if let u = tab.url?.absoluteString { model.toggleFavorite(url: u, title: tab.displayTitle) }
                }.disabled(tab.isBlank || tab.isPrivate)
                SendTabMenu(tab: tab)
                Divider()
                Button("Bookmarks", systemImage: "book") { model.sheet = .bookmarks }
                Button("History", systemImage: "clock") { model.sheet = .history }
                Button("Downloads", systemImage: "arrow.down.circle") { model.sheet = .downloads }
                Button("Settings", systemImage: "gearshape") { model.sheet = .settings }
            } label: { Image(systemName: "ellipsis").frame(width: 44, height: rowHeight).accessibilityLabel("More") }
        }
    }

    private func button(_ symbol: String, disabled: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).fontWeight(look.weight.weight).frame(width: 44, height: rowHeight) }
            .disabled(disabled).accessibilityLabel(label)
            // Press and hold Back or Forward for the pages behind or ahead.
            .contextMenu { if symbol == "chevron.left" { NavHistoryItems(tab: tab, back: true) } else if symbol == "chevron.right" { NavHistoryItems(tab: tab, back: false) } }
    }
}

struct PhoneSuggestions: View {
    @ObservedObject var address: AddressBarController
    let position: AddressBarPosition

    var body: some View {
        if address.isEditing && !address.suggestions.isEmpty {
            // Joined to the bar it belongs to (just above it at the bottom, just below it at the top) on the same surface, with nothing dimmed over the page: one control,
            // not a dialog. A tap on the page beside it ends the editing.
            ZStack {
                Color.clear.contentShape(Rectangle()).ignoresSafeArea().onTapGesture { address.isEditing = false }
                VStack {
                    if position == .top { PhoneSuggestionsCard(address: address, anchoredTop: true).padding(.horizontal, PhoneChrome.margin); Spacer() }
                    else { Spacer(); PhoneSuggestionsCard(address: address).padding(.horizontal, PhoneChrome.margin) }
                }
            }
        }
    }
}

/// One set of measurements for everything the iPhone floats over the page, so the controls always line up.
enum PhoneChrome {
    static let height: CGFloat = 40          // every pill is this tall
    static let target: CGFloat = 38          // the smallest thing a thumb is asked to hit
    static let gap: CGFloat = 6              // between pills
    static let margin: CGFloat = 12          // from the screen's sides
    static let icon: CGFloat = 15            // symbols inside the pills
    /// How far the bottom pills sit above the safe area's edge. Negative: they dip down beside the home indicator, close to the
    /// bottom of the screen, as Safari's bar does. Both the full dock and the folded pill use it.
    @MainActor static var dockLift: CGFloat { -8 }
}

/// The glass every floating piece is made of: the same material, hairline and shadow, so the dock, the search button and the search
/// panel read as one family.
private struct GlassBackground<S: InsettableShape>: ViewModifier {
    /// Watched so the surface follows a change of theme at once.
    @EnvironmentObject var model: BrowserModel
    let shape: S
    func body(content: Content) -> some View {
        // The one surface every iPhone layout floats over the page (the dock, the pills, the bar's card, suggestions, the tab list). Deep black with white on it in the
        // default theme; in any other theme it takes that theme's raised colour (lighter and see-through over a moving backdrop), and a light theme gets dark text.
        let themed = model.themeIsActive ? ThemeState.raised : nil
        let light = model.themeIsActive && model.activeTheme.scheme == .light
        content
            .environment(\.colorScheme, light ? .light : .dark)
            // Everything inside is cut to the rounded edge, so nothing pokes past the corners.
            .clipShape(shape)
            .background(themed.map { AnyShapeStyle($0.opacity(ThemeState.animated ? 0.62 : 0.96)) } ?? AnyShapeStyle(Obsidian.fill), in: shape)
            .overlay(shape.strokeBorder(light ? AnyShapeStyle(Color.black.opacity(0.12)) : AnyShapeStyle(Obsidian.edge), lineWidth: 0.5))
            .shadow(color: .black.opacity(light ? 0.18 : 0.3), radius: 10, y: 3)
    }
}

/// The surface of the bar layouts, as Safari's in iOS 26: see-through glass over the page, not a solid fill. Always the app's own theme: a theme's raised colour tints it and a light
/// theme gets dark text; with no theme it is plain glass that follows the light or dark appearance. From iOS 26 it is the system's Liquid Glass; before that, a blurred material.
private struct FloatingGlass<S: InsettableShape>: ViewModifier {
    @EnvironmentObject var model: BrowserModel
    let shape: S
    /// How much of the surface is a plain wash of the theme's (or the system's) colour, for legibility over busy pages: a little when open, more when it is the small capsule.
    var solidity = 0.18

    func body(content: Content) -> some View {
        let tint = model.themeIsActive ? ThemeState.raised : nil
        let scheme: ColorScheme? = model.themeIsActive ? (model.activeTheme.scheme == .light ? .light : .dark) : nil
        Group {
            if #available(iOS 26, *) {
                content.glassEffect(Glass.regular.tint((tint ?? Color(uiColor: .systemBackground)).opacity(tint == nil ? solidity : min(0.9, solidity + 0.12))), in: shape)
            } else {
                content
                    .clipShape(shape)
                    .background(.ultraThinMaterial, in: shape)
                    .background(tint.map { AnyShapeStyle($0.opacity(0.4)) } ?? AnyShapeStyle(Color.clear), in: shape)
                    .overlay(shape.strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
            }
        }
        .environment(\.colorScheme, scheme ?? colorSchemeFallback)
    }

    @Environment(\.colorScheme) private var colorSchemeFallback
}

extension View {
    func floatingGlass<S: InsettableShape>(_ shape: S, solidity: Double = 0.18) -> some View { modifier(FloatingGlass(shape: shape, solidity: solidity)) }
    func floatingGlassCapsule(solidity: Double = 0.18) -> some View { modifier(FloatingGlass(shape: Capsule(style: .continuous), solidity: solidity)) }
    func floatingGlassCard(cornerRadius: CGFloat = 30, solidity: Double = 0.18) -> some View { modifier(FloatingGlass(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), solidity: solidity)) }
    func phoneGlassCapsule() -> some View { modifier(GlassBackground(shape: Capsule(style: .continuous))) }
    /// The same surface as a rounded card (the bar layouts' one card, the vertical tab list).
    func phoneGlassCard(cornerRadius: CGFloat = 26) -> some View { modifier(GlassBackground(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))) }
}

/// A small round button that floats above one of the folded pills, centred on it, with a gap of its own. It is only there while `visible`: it grows in from the pill it
/// belongs to when the screen has been still for a moment, and shrinks back quickly (and stops taking touches) the moment the page moves, so it never sits in the way
/// of reading or of a scrolling thumb.
struct PhoneFloatingExtra: View {
    let symbol: String
    let label: String
    let identifier: String
    let visible: Bool
    let action: () -> Void
    static let size: CGFloat = 42
    static let gap: CGFloat = 10

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.primary)
                .frame(width: Self.size, height: Self.size).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .floatingGlassCapsule(solidity: 0.4)
        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
        .offset(y: -(Self.size + Self.gap))
        .opacity(visible ? 1 : 0)
        .scaleEffect(visible ? 1 : 0.55, anchor: .bottom)
        .allowsHitTesting(visible)
        .accessibilityHidden(!visible)
        .motion(visible ? .spring(response: 0.36, dampingFraction: 0.8) : .easeOut(duration: 0.12), value: visible)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

/// The dock folded away while a page is read: one small glass pill with the site. A tap opens the dock again.
struct PhoneCompactPill: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController
    /// The tabs list the fan's tabs button opens (the Immersive layout).
    var tabsOpen: Binding<Bool>? = nil

    @ObservedObject private var icons = FaviconStore.shared
    /// Turned on its side the pill sits at the top, so its buttons open downward, never off the screen.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var pillAtTop: Bool { verticalSizeClass == .compact && !model.phoneSpec.fanOut }

    private var label: String {
        guard !tab.isBlank else { return "Search" }
        let host = displayHost(tab.url)
        return host.isEmpty ? tab.displayTitle : host
    }

    /// Just the site's icon, in a small round button at the right edge: the page keeps the whole screen. A tap opens the address bar there and then; a long press
    /// offers the usual quick actions. While the page is being scrolled it is the only thing here. Once the screen has been still for a moment, a reload button floats in
    /// above it, and slips away again as soon as the page moves. It stays folded however the page is scrolled: only a tap on it brings the bar back.
    var body: some View {
        addressMenu
            .frame(width: 48, height: 48)
            .floatingGlassCapsule(solidity: 0.5)
            .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
            .modifier(TabSwipe(up: .openDock))
            .overlay(alignment: .top) { if !model.phoneSpec.fanOut { reloadExtra } }
            .overlay { if model.phoneSpec.fanOut, let tabsOpen { fan(tabsOpen) } }
            // The way back to the whole dock never depends on a gesture setting: VoiceOver and Switch Control get it as a named action.
            .accessibilityAction(named: "Show the toolbar") { model.expandChrome(userRequested: true) }
    }

    /// New tab straight up, your tabs straight to the left, and reload between them: each springs out of the pill along an arc once the screen has been still, and goes back into
    /// it as soon as the page moves or the tabs list is open.
    private func fan(_ tabsOpen: Binding<Bool>) -> some View {
        let shown = !model.pageIsScrolling && !tabsOpen.wrappedValue
        let r = PhoneFanButton.radius, d = r * 0.7071
        return ZStack {
            if model.phoneSpec.newTabPill {
                PhoneFanButton(symbol: "plus", label: "New tab", identifier: "fan-new-tab", visible: shown, target: CGSize(width: 0, height: pillAtTop ? r : -r), delay: 0) { _ = model.newTab() }
            }
            PhoneFanButton(symbol: tab.isLoading ? "xmark" : "arrow.clockwise", label: tab.isLoading ? "Stop loading" : "Reload", identifier: "fan-reload",
                           visible: shown && !tab.isBlank, target: CGSize(width: -d, height: pillAtTop ? d : -d), delay: 0.035) {
                guard !SwipeGuard.recent else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                if tab.isLoading { tab.stop() } else { tab.reload() }
            }
            if model.phoneSpec.tabsPill {
                PhoneFanTabs(isOpen: tabsOpen, visible: shown, target: CGSize(width: -r, height: 0), delay: 0.07)
            }
        }
    }

    private var reloadExtra: some View {
        PhoneFloatingExtra(symbol: tab.isLoading ? "xmark" : "arrow.clockwise", label: tab.isLoading ? "Stop loading" : "Reload", identifier: "compact-reload",
                           visible: !model.pageIsScrolling && !tab.isBlank) {
            guard !SwipeGuard.recent else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if tab.isLoading { tab.stop() } else { tab.reload() }
        }
    }

    private var addressMenu: some View {
        // A tap opens the address bar; a press and hold opens the same menu as the three dots (⋮). Done as one menu with a primary action rather than a context menu on a
        // button: the context menu's lifted preview fought the pill's own animation and the swipe, and flickered.
        Menu {
            PhoneMenuContent(tab: tab)
        } label: {
            icon
                .frame(width: 48, height: 48)
                .overlay {
                    // While the page loads, a thin ring around the button fills as it goes.
                    if tab.isLoading { Circle().trim(from: 0, to: max(0.04, tab.progress)).stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90)).padding(3) }
                }
                .contentShape(Circle())
        } primaryAction: {
            if !SwipeGuard.recent { model.openSearchPanel() }
        }
        .menuOrder(.fixed)
        .buttonStyle(.plain)
        .accessibilityLabel("\(label). Open the address bar")
        .accessibilityIdentifier("compact-pill")
    }

    @ViewBuilder private var icon: some View {
        if tab.isPrivate { Image(systemName: "eye.slash.fill").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.privateAccent) }
        else if tab.isBlank { Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary) }
        else if let url = tab.url, let image = icons.image(forURL: url.absoluteString, points: 26) {
            Image(uiImage: image).resizable().scaledToFit().frame(width: 26, height: 26).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            Image(systemName: tab.isSecure ? "lock.fill" : "globe").font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary)
        }
    }
}

/// A swipe that starts on the address pill also lifts the finger over its button. The button must not take that as a tap: it opened the keyboard
/// every time a swipe changed tabs.
enum SwipeGuard {
    nonisolated(unsafe) private static var last = Date.distantPast
    static func stamp() { last = Date() }
    static var recent: Bool { Date().timeIntervalSince(last) < 0.45 }
}

/// Swiping a bar sideways moves to the next or previous tab: the bar follows the finger a little, and the page slides in from that side.
/// Swiping up opens the tab overview where that is allowed. Settings › Gestures turns it off.
struct TabSwipe: ViewModifier {
    /// What a swipe up does on this pill: the tab overview (the open dock), or open the dock (a folded pill, where scrolling no longer does).
    enum Up { case overview, openDock, nothing }
    @EnvironmentObject var model: BrowserModel
    var allowsOverview = false
    /// A swipe up on a folded pill opens the dock; the overview is then in the tabs pill's menu and list.
    var up: Up? = nil
    /// A swipe down on the open dock's address pill folds it into the pills, as scrolling does.
    var downFolds = false
    @GestureState private var drag: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .offset(x: model.swipeAddressPill ? drag * 0.3 : 0)
            .accessibilityAction(named: "Next tab") { model.swipeToTab(1) }
            .accessibilityAction(named: "Previous tab") { model.swipeToTab(-1) }
            .motion(.interactiveSpring(), value: drag)
            .simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .updating($drag) { value, state, _ in
                        if abs(value.translation.width) > abs(value.translation.height) { state = value.translation.width }
                    }
                    .onEnded { value in
                        SwipeGuard.stamp()
                        guard model.swipeAddressPill else { return }
                        let dx = value.translation.width, dy = value.translation.height
                        if abs(dx) > abs(dy), abs(dx) > 56 {
                            UISelectionFeedbackGenerator().selectionChanged()
                            model.swipeToTab(dx < 0 ? 1 : -1)
                        } else if abs(dy) > abs(dx), dy < -56 {
                            switch up ?? (allowsOverview ? .overview : .nothing) {
                            case .overview: UIImpactFeedbackGenerator(style: .light).impactOccurred(); model.openTabsView()
                            case .openDock: UIImpactFeedbackGenerator(style: .light).impactOccurred(); model.expandChrome(userRequested: true)
                            case .nothing: break
                            }
                        } else if abs(dy) > abs(dx), dy > 56, downFolds {
                            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                            model.foldChrome()
                        }
                    }
            )
    }
}

/// The controls at the bottom of the screen: separate glass pills in a row, like Safari's compact bar. What is in them, and in what
/// order, is the user's choice (Settings › Toolbar): some buttons, then the address pill, then more buttons and the menu.
struct PhoneDock: View {
    @EnvironmentObject var model: BrowserModel
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ObservedObject var tab: TabController
    var editable = true

    var body: some View {
        let layout = model.phoneLayout
        HStack(spacing: PhoneChrome.gap) {
            let editing = model.floatingAddressVisible && editable
            if !editing, !layout.beforeAddress.isEmpty { actions(layout.beforeAddress, includeMore: false).transition(.opacity) }
            PhoneAddressPill(tab: tab, editable: editable)
            if !editing { actions(layout.afterAddress, includeMore: true).transition(.opacity) }
        }
        // Upright it is a compact floating bar; on its side it spreads across the strip, as Safari's toolbar does.
        .frame(maxWidth: verticalSizeClass == .compact ? .infinity : 460)
        .motion(.spring(response: 0.34, dampingFraction: 0.86), value: layout)
        .motion(.spring(response: 0.34, dampingFraction: 0.88), value: model.floatingAddressVisible)
    }

    private func actions(_ list: [PhoneAction], includeMore: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(list) { action in DockActionButton(action: action, tab: tab) }
            if includeMore { PhoneMoreMenu(tab: tab) }
        }
        .motion(.spring(response: 0.3, dampingFraction: 0.85), value: tab.canGoForward)
        .padding(.horizontal, 2)
        .frame(height: PhoneChrome.height)
        .phoneGlassCapsule()
    }
}

/// One button of the toolbar. Forward only exists once there is somewhere to go forward to, as in Safari.
struct DockActionButton: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject private var look = LookState.shared
    let action: PhoneAction
    @ObservedObject var tab: TabController

    var body: some View {
        if action == .forward && !tab.canGoForward {
            EmptyView()
        } else if action == .tabs {
            Button { model.openTabsView() } label: {
                Text("\(max(model.tabs.count, 1))")
                    .scaledFont(11, weight: .semibold)
                    .frame(width: 21, height: 21)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary, lineWidth: 1.5))
                    .frame(width: PhoneChrome.target, height: PhoneChrome.target)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show all tabs")
            .accessibilityIdentifier("dock-tabs")
        } else {
            let on = action.isToggle && action.isOn(model, tab)
            Button { action.run(model, tab) } label: {
                Image(systemName: action.symbol(model, tab))
                    .font(.system(size: PhoneChrome.icon, weight: look.weight == .regular ? .medium : look.weight.weight))
                    .foregroundStyle(on ? Theme.accent : (action.isEnabled(model, tab) ? Color.primary : Color.primary.opacity(0.28)))
                    .frame(width: PhoneChrome.target, height: PhoneChrome.target)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!action.isEnabled(model, tab))
            .transition(.scale(scale: 0.6).combined(with: .opacity))
            .accessibilityLabel(action.title)
            .accessibilityIdentifier("dock-\(action.rawValue)")
        }
    }
}

/// The address pill: the site (as the user chose to show it), then reload. Tapping opens search; long-pressing offers the quick actions;
/// swiping it sideways switches tabs and swiping it up opens the tab overview.
struct PhoneAddressPill: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController
    /// False for the hidden landscape strip, so only one field ever exists.
    var editable = true
    @ObservedObject private var icons = FaviconStore.shared

    private var host: String { displayHost(tab.url) }
    private var titleText: String { tab.displayTitle }
    private var accessibilityText: String {
        guard !tab.isBlank else { return "Search or enter address" }
        return host.isEmpty ? titleText : host
    }

    var body: some View {
        Group {
            if model.floatingAddressVisible && editable {
                PhoneDockField(tab: tab, address: model.addressBar)
            } else {
                idlePill.modifier(TabSwipe(allowsOverview: true, downFolds: model.canCollapseDock))
            }
        }
        .frame(height: PhoneChrome.height)
        .phoneGlassCapsule()
        .overlay(alignment: .bottom) { LoadingBar(tab: tab, height: 2).id(tab.id).padding(.horizontal, 20).padding(.bottom, 3) }
    }

    private var idlePill: some View {
        HStack(spacing: 0) {
            // A tap opens the address bar; a press and hold opens the same menu as the three dots (⋮).
            Menu {
                PhoneMenuContent(tab: tab)
            } label: {
                HStack(spacing: 6) {
                    if model.showAddressIcon { icon.frame(width: 14) }
                    text
                }
                .padding(.leading, 12)
                .frame(maxWidth: .infinity, minHeight: PhoneChrome.height, alignment: .center)
                .contentShape(Rectangle())
            } primaryAction: {
                if !SwipeGuard.recent { model.openSearchPanel() }
            }
            .menuOrder(.fixed)
            .buttonStyle(.plain)
            .accessibilityLabel("Open search. \(accessibilityText)")
            .accessibilityIdentifier("collapsed-pill")
            // A blank page has nothing to reload.
            if !tab.isBlank { DockActionButton(action: .reload, tab: tab) }
        }
        .padding(.trailing, 2)
    }

    @ViewBuilder private var icon: some View {
        if tab.isLoading { ProgressView().controlSize(.mini) }
        else if !tab.isBlank, !tab.isPrivate, let image = tab.url.flatMap({ icons.image(forURL: $0.absoluteString, points: 14) }) {
            Image(platform: image).resizable().interpolation(.high).scaledToFit().frame(width: 14, height: 14)
        } else {
            Image(systemName: tab.isPrivate ? "eye.slash.fill" : (tab.isBlank ? "magnifyingglass" : (tab.isSecure ? "lock.fill" : "globe")))
                .font(.system(size: 12, weight: .semibold))
        }
    }

    @ViewBuilder private var text: some View {
        if tab.isBlank {
            Text("Search or enter address").lineLimit(1).foregroundStyle(Color.secondary).scaledFont(14, weight: .medium)
        } else {
            switch model.addressDisplay {
            case .domain:
                Text(host.isEmpty ? titleText : host).lineLimit(1).truncationMode(.middle).scaledFont(14, weight: .medium)
            case .title:
                Text(titleText).lineLimit(1).truncationMode(.tail).scaledFont(14, weight: .medium)
            case .titleAndDomain:
                VStack(alignment: .leading, spacing: 0) {
                    Text(titleText).lineLimit(1).truncationMode(.tail).scaledFont(12.5, weight: .semibold)
                    Text(host).lineLimit(1).scaledFont(10.5).foregroundStyle(.secondary)
                }
            }
        }
    }

}

/// The three dots (⋮): the actions the user has put in the menu, in sections, in their order.
struct PhoneMoreMenu: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController

    var body: some View {
        Menu {
            PhoneMenuContent(tab: tab)
        } label: {
            // Vertical dots (⋮), turned from the horizontal symbol.
            Image(systemName: "ellipsis")
                .rotationEffect(.degrees(90))
                .font(.system(size: PhoneChrome.icon, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: PhoneChrome.target, height: PhoneChrome.target)
                .contentShape(Rectangle())
        }
        .menuOrder(.fixed)
        .accessibilityLabel("More")
        .accessibilityIdentifier("dock-more")
    }
}

/// One entry of the More menu.
private struct MoreItem: View {
    @EnvironmentObject var model: BrowserModel
    let action: PhoneAction
    @ObservedObject var tab: TabController

    private var title: String {
        switch action {
        case .bookmark: model.activeBookmarked ? "Remove Bookmark" : "Add Bookmark"
        case .reader: tab.isReading ? "Exit Reader" : "Reader"
        case .desktopSite: "Desktop Site"
        case .javaScript: "JavaScript"
        default: action.title
        }
    }

    var body: some View {
        switch action {
        case .share:
            if let url = tab.url, !tab.isBlank { ShareLink(item: url) { Label(title, systemImage: action.symbol) } }
        case .recentlyClosed:
            Menu(title, systemImage: action.symbol) {
                ForEach(Array(model.closedTabs.enumerated().reversed().prefix(8)), id: \.offset) { index, closed in
                    Button(closed.title.isEmpty ? displayHost(closed.url) : closed.title) { model.reopenClosedTab(at: index) }
                }
            }
            .disabled(model.closedTabs.isEmpty)
        case .desktopSite:
            Toggle(isOn: Binding(get: { tab.desktopSite }, set: { _ in tab.toggleDesktopSite() })) { Label(title, systemImage: action.symbol) }
                .disabled(tab.isBlank)
        case .javaScript:
            Toggle(isOn: Binding(get: { tab.javaScriptOn }, set: { _ in tab.toggleJavaScript() })) { Label(title, systemImage: action.symbol) }
                .disabled(tab.isBlank)
        case .darkPages:
            Toggle(isOn: Binding(get: { model.shouldDarken(host: tab.url?.host) }, set: { _ in action.run(model, tab) })) { Label(title, systemImage: action.symbol) }
                .disabled(tab.isBlank)
        default:
            Button { action.run(model, tab) } label: { Label(title, systemImage: action.symbol(model, tab)) }
                .disabled(!action.isEnabled(model, tab))
        }
    }
}

/// The search panel: one glass card with the search engine, the address field and the suggestions, coming down from the top when the
/// address pill is tapped. It closes when editing ends.
/// Search on the iPhone: one editable field right above the keyboard, with what it finds stacked above it. No second field, no website icon, no
/// shield (a search is not a loaded site), and Cancel beside the field, not inside it. It uses the same address controller, URL reading, search
/// provider and navigation as every other address bar; only this field holds the editing.
struct PhoneSearchPanel: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController

    var body: some View {
        let atBottom = model.searchPanelAtBottomNow
        VStack(spacing: 10) {
            // Suggestions sit directly above the field, which sits directly above the keyboard, so the bar reads as one control.
            if atBottom { Spacer(minLength: 0) }
            PhoneSuggestionsCard(address: model.addressBar, anchoredTop: !atBottom)
            PhoneSearchField(tab: tab, address: model.addressBar)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: atBottom ? .bottom : .top)
        .padding(.horizontal, PhoneChrome.margin).padding(atBottom ? .bottom : .top, 6)
        .onReceive(model.addressBar.$isEditing.dropFirst().removeDuplicates()) { editing in
            if !editing { model.floatingAddressVisible = false }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("floating-address-bar")
    }
}

/// What the search finds, in a card. It watches the address controller itself: the panel around it does not, so without this the list never
/// appeared as results arrived. Anchored to the top it grows downward from under the status bar and scrolls when there is more than fits.
struct PhoneSuggestionsCard: View {
    @ObservedObject var address: AddressBarController
    var anchoredTop = false
    /// The room there is, so a short landscape screen scrolls the list instead of pushing it off the top.
    var maxHeight: CGFloat = .infinity

    var body: some View {
        if address.isEditing && !address.suggestions.isEmpty {
            ScrollView { SuggestionsList(address: address, embedded: true) }
                .scrollIndicators(.hidden)
                .modifier(GlassBackground(shape: RoundedRectangle(cornerRadius: 22, style: .continuous)))
                .frame(maxHeight: maxHeight)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(-1)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: anchoredTop ? .top : .bottom)))
        }
    }
}

struct PhoneSearchField: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController
    @ObservedObject var address: AddressBarController
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                TextField("Search or enter address", text: $address.text)
                    .textFieldStyle(.plain).font(.system(size: 16)).focused($focused)
                    .autocorrectionDisabled().textInputAutocapitalization(.never).keyboardType(.webSearch).submitLabel(.go)
                    .onSubmit(submit)
                    .accessibilityIdentifier("omnibox")
            }
            .padding(.horizontal, 12).frame(height: model.density == .compact ? 33 : 38)
            .themedFill(in: Capsule(), fallback: .regularMaterial)
            .hairline(Capsule(), opacity: 0.08, width: 0.5)
            Button { model.cancelSearch() } label: {
                Text("Cancel").scaledFont(15, weight: .medium).foregroundStyle(Color.primary.opacity(0.85))
                    .padding(.horizontal, 14).frame(height: model.density == .compact ? 33 : 38)
                    .themedFill(in: Capsule(), fallback: .regularMaterial)
                    .hairline(Capsule(), opacity: 0.08, width: 0.5)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("search-cancel")
        }
        .onAppear {
            address.isEditing = true
            // An address already there is selected, so typing replaces it; a blank tab starts empty with the cursor in the field.
            address.text = tab.isBlank ? "" : (tab.url?.absoluteString ?? "")
            if let prefill = model.pendingAddressPrefill { model.pendingAddressPrefill = nil; address.text = prefill; address.refresh(model: model) }
            DispatchQueue.main.async { focused = true; selectWholeAddress(expecting: address.text) }
        }
        .onChange(of: address.text) { _, _ in if address.isEditing { address.refresh(model: model) } }
        .onChange(of: model.omniboxFocusTick) { _, _ in focused = true }
    }

    private func submit() {
        let text = address.text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        if let picked = address.selectedSuggestion { model.accept(picked) } else { model.navigate(input: text) }
        model.cancelSearch()
    }

    /// UIKit places the cursor from the tap just after the field takes focus, so the selection is made a moment later, and again once the keyboard
    /// is up. Typing (the text no longer being what was put there) ends it, so it can never replace what the person is writing.
    private func selectWholeAddress(expecting text: String) {
        guard !text.isEmpty else { return }
        for delay in [0.03, 0.15, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard address.isEditing, address.text == text else { return }
                UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
            }
        }
    }
}


/// The dock's address pill while the user types: the same capsule, the same place, now holding the text field, with Cancel at its end. The
/// keyboard lifts the whole dock, so the bar the user tapped is the bar they type in. It shares the address controller and navigation of every
/// other address bar.
struct PhoneDockField: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController
    @ObservedObject var address: AddressBarController
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            TextField("Search or enter address", text: $address.text)
                .textFieldStyle(.plain).font(.system(size: 15)).focused($focused)
                .autocorrectionDisabled().textInputAutocapitalization(.never).keyboardType(.webSearch).submitLabel(.go)
                .onSubmit(submit)
                .accessibilityIdentifier("omnibox")
            Button { model.cancelSearch() } label: {
                Text("Cancel").scaledFont(14, weight: .medium).foregroundStyle(Color.primary.opacity(0.85))
                    .frame(minHeight: PhoneChrome.height).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("search-cancel")
        }
        .padding(.horizontal, 14)
        .onAppear {
            address.isEditing = true
            address.text = tab.isBlank ? "" : (tab.url?.absoluteString ?? "")
            if let prefill = model.pendingAddressPrefill { model.pendingAddressPrefill = nil; address.text = prefill; address.refresh(model: model) }
            DispatchQueue.main.async { focused = true; selectWholeAddress(expecting: address.text) }
        }
        .onChange(of: address.text) { _, _ in if address.isEditing { address.refresh(model: model) } }
        .onChange(of: model.omniboxFocusTick) { _, _ in focused = true }
        .onReceive(address.$isEditing.dropFirst().removeDuplicates()) { editing in
            if !editing { model.floatingAddressVisible = false }
        }
    }

    private func submit() {
        let text = address.text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        if let picked = address.selectedSuggestion { model.accept(picked) } else { model.navigate(input: text) }
        model.cancelSearch()
    }

    /// Selected once as the field takes focus (UIKit places the cursor just after), so typing replaces the address; typing ends it.
    private func selectWholeAddress(expecting text: String) {
        guard !text.isEmpty else { return }
        for delay in [0.03, 0.15, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard address.isEditing, address.text == text else { return }
                UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
            }
        }
    }
}


/// How far the keyboard rises above the bottom safe area, so the dock can sit right on top of it while the page stays where it is.
@MainActor
final class KeyboardLift: ObservableObject {
    @Published var height: CGFloat = 0
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                let screen = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen.bounds.height ?? frame.maxY
                let safe = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.keyWindow?.safeAreaInsets.bottom ?? 0
                let lift = max(0, screen - frame.minY - safe)
                let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
                animated(.easeOut(duration: duration)) { self.height = lift }
            }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}

/// The strip behind the clock, in the page's own colour, as long as the clock stays readable on it. The clock is white on a dark phone and black on a light one, so a page colour
/// too close to that is replaced by the plain dark or light the phone is using.
private struct PageTopStrip: View {
    @ObservedObject var tab: TabController
    @Environment(\.colorScheme) private var scheme
    private var chosen: Color? {
        guard !tab.isBlank, let tint = tab.tint else { return nil }
        let luminance = 0.2126 * tint.red + 0.7152 * tint.green + 0.0722 * tint.blue
        if scheme == .dark, luminance > 0.55 { return Color.black }       // white clock: needs a dark strip
        if scheme == .light, luminance < 0.45 { return Color.white }      // black clock: needs a light strip
        return Color(red: tint.red, green: tint.green, blue: tint.blue)
    }
    var body: some View {
        Group {
            if let chosen { chosen.transition(.opacity) }
        }
        .ignoresSafeArea(edges: .top)
        .motion(.easeInOut(duration: 0.25), value: tab.tint)
    }
}


/// The field of the compact layouts: a glass capsule, or (elsewhere) the grey field inside a bar.
struct AddressFieldSurface: ViewModifier {
    let glass: Bool
    let compact: Bool
    var bare = false
    func body(content: Content) -> some View {
        if bare {
            content
        } else if glass {
            content.floatingGlassCapsule()
        } else {
            content.background(.quaternary, in: RoundedRectangle(cornerRadius: compact ? 12 : 16, style: .continuous))
        }
    }
}
