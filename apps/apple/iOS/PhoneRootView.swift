import SwiftUI

struct PhoneRootView: View {
    @EnvironmentObject var model: BrowserModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// The live speed lives in the Dynamic Island while the browser is in front.
    @StateObject private var speedActivity = SpeedLiveActivityController()
    @StateObject private var keyboard = KeyboardLift()

    /// An iPhone is always the phone layout. Its size class is "regular" in landscape on the larger models, which used to bring up the iPad sidebar.
    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }
    private var compactWidth: Bool { isPhone || sizeClass == .compact }
    /// On a narrow iPad (upright) the sidebar steps aside while a panel is docked, so the page keeps room.
    private var showsSidebar: Bool { !isPhone && sizeClass == .regular && model.sidebarVisible && !(model.dockedPanel != nil && UIScreen.main.bounds.width < 1000) }
    /// While a page is read, the address bar and toolbar slide away and the page runs edge to edge.
    private var barsHidden: Bool { model.chromeCollapsed && model.canCollapseChrome }
    /// The Floating layout on iPhone: no bars at all, only the dock at the bottom and the search button at the top right.
    private var floatingMode: Bool { model.topBarHidden }
    /// Either way the bars are out of the picture and the dock stands in for them.
    private var showsDock: Bool { barsHidden || floatingMode }
    /// While a page is read the dock is only a small pill; scrolling back, or a tap on it, opens it again.
    private var dockCompact: Bool { showsDock && model.canCollapseDock && model.chromeCollapsed && !model.floatingAddressVisible }

    /// Held on its own strip under the page. The page is short in landscape, so the dock must not float over it.
    /// The home-indicator strip the page runs under when the bars are away.
    private static var bottomSafeInset: CGFloat {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.keyWindow?.safeAreaInsets.bottom ?? 0
    }

    /// Room kept clear of the page for the whole dock, measured from the home-indicator edge (the page already stops there): the dock's height and a small gap.
    /// It must not read the window's own safe area while laying out: that made the whole screen come up blank.
    private var pageReservedBottom: CGFloat {
        // Only for a page with its own bar along the bottom, and kept the same when the dock folds into its pill: the page changing size while you scroll made its content jump.
        guard showsDock, model.activeFixedBottom, !landscape, !dockOnItsOwnStrip, !model.floatingAddressVisible else { return 0 }
        return PhoneChrome.height + PhoneChrome.dockLift + 8
    }

    private var landscape: Bool { isPhone && verticalSizeClass == .compact }
    private var dockOnItsOwnStrip: Bool { landscape && showsDock && !dockCompact && !model.floatingAddressVisible && model.active != nil }
    /// In landscape the toolbar is a strip along the TOP, as in Safari: height is scarce, and the thumbs rest on the sides.

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                if showsSidebar { IPadSidebar().transition(.move(edge: .leading).combined(with: .opacity)); Divider() }
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
            VStack(spacing: 8) { PendingLoginPill(); PopupBlockedPill() }
                .padding(.top, 58)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            NoticeToast()
                .padding(.bottom, 150)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            DownloadToast(coordinator: model.downloads)
                .padding(.horizontal, 12).padding(.bottom, 92)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .background { Group { if model.themeIsActive { ChromeBackdrop() } else { Color(.systemBackground) } }.ignoresSafeArea() }
        .ignoresSafeArea(.keyboard, edges: showsDock ? .bottom : [])
        .scrollIndicators(.hidden)
        .motion(.easeOut(duration: 0.18), value: model.overviewVisible)
        .motion(.spring(response: 0.42, dampingFraction: 0.9), value: showsDock)
        .motion(.spring(response: 0.4, dampingFraction: 0.88), value: showsSidebar)
        .sheet(item: $model.sheet) { SheetContainer(sheet: $0) }
        .sheet(item: $model.storeOffer) { StoreOfferSheet(info: $0) }
        .sheet(item: $model.privacySheet) { PrivacySheetView(kind: $0, privacy: model.privacy) }
        .preferredColorScheme(model.appearance.colorScheme ?? (model.themeIsActive ? model.activeTheme.scheme?.colorScheme : nil))
        .tint(Theme.accent)
        .onChange(of: sizeClass) { _, c in if c == .regular, !isPhone { model.sidebarVisible = true } }
        .onChange(of: scenePhase, initial: true) { _, phase in speedActivity.update(wanted: model.showSpeedPill, phase: phase, popups: model.speedPopups); model.speedActivityStatus = speedActivity.status }
        .onChange(of: model.showSpeedPill) { _, on in speedActivity.update(wanted: on, phase: scenePhase, popups: model.speedPopups); model.speedActivityStatus = speedActivity.status }
        .onChange(of: model.speedPopups) { _, on in speedActivity.update(wanted: model.showSpeedPill, phase: scenePhase, popups: on) }
        .onAppear {
            if sizeClass == .regular, !isPhone { model.sidebarVisible = true }
            model.showSpeedHandler = { Task { await speedActivity.flash() } }
        }
    }

    private var mainColumn: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                RecoveryBanner()
                // One motion: the strip's height, its fade and the page growing into the room all use the same curve and length.
                if landscape, showsDock, let tab = model.active {
                    PhoneDock(tab: tab, editable: false)
                        .frame(maxWidth: 560)
                        .padding(.horizontal, PhoneChrome.margin)
                        .padding(.vertical, 3)
                        .opacity(dockOnItsOwnStrip ? 1 : 0)
                        .frame(height: dockOnItsOwnStrip ? PhoneChrome.height + 6 : 0, alignment: .top)
                        .clipped()
                        .allowsHitTesting(dockOnItsOwnStrip)
                }
                if model.addressBarPosition == .top || landscape, let tab = model.active, !showsDock {
                    PhoneAddressArea(tab: tab).transition(.move(edge: .top).combined(with: .opacity))
                }
                if let tab = model.active {
                    ZStack {
                        EngineViewHost(view: tab.hostView).id(tab.id)
                            .transition(model.tabSlide == 0 ? .opacity : .push(from: model.tabSlide > 0 ? .trailing : .leading))
                        if tab.isBlank {
                            StartPageView(isPrivate: tab.isPrivate)
                                // A floating toolbar covers the foot of the page, so the page leaves room for it.
                                .environment(\.startBottomInset, showsDock && !landscape && pageReservedBottom == 0 ? PhoneChrome.height + PhoneChrome.dockLift + Self.bottomSafeInset + 14 : 0)
                        }
                        // With the dock in charge, suggestions appear in the search panel instead.
                        if !showsDock { PhoneSuggestions(address: model.addressBar, position: model.addressBarPosition) }
                    }
                    .clipped()
                    .overlay(alignment: .bottom) {
                        WebStoreBanner()
                            .padding(.bottom, showsDock && !landscape && pageReservedBottom == 0 ? PhoneChrome.height + PhoneChrome.dockLift + Self.bottomSafeInset + 12 : 12)
                    }
                    // In landscape the page runs under the sides of the screen (the notch side and the home-indicator side), so there are
                    // no black strips; WebKit keeps the text itself clear of them.
                    .ignoresSafeArea(.container, edges: landscape ? .horizontal : [])
                    .motion(.easeInOut(duration: 0.26), value: model.activeID)
                    // Over the page's top edge, never behind the status bar: with the bars away the dock shows it instead.
                    .overlay(alignment: .top) { if !showsDock { LoadingBar(tab: tab).id(tab.id) } }
                } else {
                    Color.platformBackground
                }
                if model.addressBarPosition == .bottom, !landscape, let tab = model.active, !showsDock {
                    PhoneAddressArea(tab: tab).transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            // With the bars away the page still starts below the status bar (a site's own top bar would otherwise sit under the clock) and ends above the dock
            // (a site's own bottom tabs would otherwise be hidden by it). It runs under the home-indicator strip, which the dock's own room includes. When the dock
            // folds into its small pill, the page takes that room back.
            .ignoresSafeArea(.container, edges: showsDock && !dockOnItsOwnStrip ? (model.activeFixedTop ? .bottom : .vertical) : [])
            // The strip behind the clock takes the page's own colour, so a dark site does not get a white band above it. It belongs to the page's area only.
            .background(alignment: .top) {
                if showsDock, model.activeFixedTop, model.tintToolbar, let tab = model.active { PageTopStrip(tab: tab) }
            }
            .padding(.bottom, pageReservedBottom)
            .motion(.spring(response: 0.4, dampingFraction: 0.88), value: pageReservedBottom)
            // The strip behind the clock takes the page's own colour, so a dark site does not get a white band above it.
            .motion(.easeInOut(duration: 0.3), value: dockOnItsOwnStrip)
            if showsDock, !dockOnItsOwnStrip, let tab = model.active {
                // The dock is always at the bottom, where the thumb is: whole, or folded into one small pill.
                ZStack(alignment: landscape && !model.floatingAddressVisible ? .top : .bottom) {
                    if dockCompact {
                        PhoneCompactPill(tab: tab)
                            .transition(landscape ? .opacity : .scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
                    } else {
                        PhoneDock(tab: tab)
                            .frame(maxWidth: 560)
                            .padding(.horizontal, PhoneChrome.margin)
                            .transition(.opacity)
                    }
                }
                .padding(landscape && !model.floatingAddressVisible ? .top : .bottom, landscape && !model.floatingAddressVisible ? 4 : (model.floatingAddressVisible ? keyboard.height + 8 : PhoneChrome.dockLift))
                .frame(maxHeight: .infinity, alignment: landscape && !model.floatingAddressVisible ? .top : .bottom)
                .motion(landscape ? .easeInOut(duration: 0.3) : .spring(response: 0.4, dampingFraction: 0.86), value: dockCompact)
                // In place and quick: when search opens the bar fades into the editing field instead of flying away.
                .transition(.opacity)
            }
        }
        .modifier(SystemTranslation())
        .overlay {
            if model.floatingAddressVisible, showsDock {
                // The dock's own address pill is the field; only the dimming and what the search finds are drawn here, just above it.
                GeometryReader { geo in
                    let below = keyboard.height + PhoneChrome.height + 16
                    ZStack(alignment: .bottom) {
                        Color.black.opacity(0.28).ignoresSafeArea().contentShape(Rectangle())
                            .onTapGesture { model.cancelSearch() }
                            .transition(.opacity)
                        PhoneSuggestionsCard(address: model.addressBar, anchoredTop: false, maxHeight: max(80, geo.size.height - below - geo.safeAreaInsets.top - 8))
                            .padding(.horizontal, PhoneChrome.margin)
                            .padding(.bottom, below)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            } else if model.floatingAddressVisible, let tab = model.active {
                ZStack(alignment: model.searchPanelAtBottom ? .bottom : .top) {
                    // The page behind is dimmed, and a tap on it ends the search and puts everything back.
                    Color.black.opacity(0.28).ignoresSafeArea().contentShape(Rectangle())
                        .onTapGesture { model.cancelSearch() }
                        .transition(.opacity)
                    PhoneSearchPanel(tab: tab)
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: model.searchPanelAtBottom ? .bottom : .top)))
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
                VStack(spacing: 8) {
                    PhoneAddressBar(tab: tab, address: model.addressBar)
                        .modifier(TabSwipe(allowsOverview: !model.addressBar.isEditing))
                    if !model.addressBar.isEditing { PhoneToolbar(tab: tab).transition(.opacity.combined(with: .move(edge: .bottom))) }
                }
            }
        }
        .padding(.horizontal, landscapePhone ? 8 : 12).padding(.vertical, landscapePhone ? 3 : 8)
        .themedBar(fallback: .bar)
        .motion(.spring(response: 0.34, dampingFraction: 0.88), value: model.addressBar.isEditing)
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
                Button { model.showOverview() } label: {
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
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            ShieldButton(privacy: model.privacy, host: tab.url?.host, showLabel: false)
            Image(systemName: tab.isPrivate ? "eye.slash.fill" : (tab.isBlank ? "magnifyingglass" : (tab.isSecure ? "lock.fill" : "exclamationmark.triangle.fill")))
                .font(.footnote).foregroundStyle(tab.isPrivate ? Theme.privateAccent : (tab.isSecure || tab.isBlank ? .secondary : .orange))
            TextField("Search or enter address", text: $address.text)
                .textFieldStyle(.plain).focused($focused)
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
            } else if tab.isLoading {
                Button { tab.stop() } label: { Image(systemName: "xmark").accessibilityLabel("Stop loading") }.foregroundStyle(.secondary).transition(.opacity)
            } else if !tab.isBlank {
                Button { tab.reload() } label: { Image(systemName: "arrow.clockwise").accessibilityLabel("Reload") }.foregroundStyle(.secondary).transition(.opacity)
            }
        }
        .motion(.easeOut(duration: 0.2), value: address.isEditing)
        .motion(.easeOut(duration: 0.18), value: tab.isLoading)
        .padding(.horizontal, compact ? 10 : 12).padding(.vertical, compact ? 6 : 10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: compact ? 12 : 16, style: .continuous))
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
            address.text = ""; focused = true
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
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        HStack {
            if sizeClass == .regular, UIDevice.current.userInterfaceIdiom != .phone {
                button("sidebar.left", disabled: false, label: "Toggle sidebar") { model.sidebarVisible.toggle() }
                Spacer()
            }
            if model.shows(.backForward) {
                button("chevron.left", disabled: !tab.canGoBack, label: "Back") { tab.goBack() }
                Spacer()
                button("chevron.right", disabled: !tab.canGoForward, label: "Forward") { tab.goForward() }
                Spacer()
            }
            if model.shows(.share) {
                if let url = tab.url, !tab.isBlank {
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up").frame(width: 44, height: 32) }
                } else {
                    button("square.and.arrow.up", disabled: true, label: "Share") {}
                }
                Spacer()
            }
            if model.shows(.bookmark) {
                button(model.activeBookmarked ? "star.fill" : "star", disabled: tab.isBlank, label: "Bookmark") { model.toggleBookmark() }
                Spacer()
            }
            if model.shows(.newTab) { button("plus", disabled: false, label: "New tab") { model.newTab() }; Spacer() }
            if model.shows(.downloads) { button("arrow.down.circle", disabled: false, label: "Downloads") { model.sheet = .downloads }; Spacer() }
            if model.shows(.tabOverview) {
                Button { model.showOverview() } label: {
                    Text("\(model.visibleTabs.count)").font(.footnote.bold())
                        .frame(width: 24, height: 24)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(lineWidth: 1.5))
                        .frame(width: 44, height: 32)
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
            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 32).accessibilityLabel("More") }
        }
    }

    private func button(_ symbol: String, disabled: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).fontWeight(look.weight.weight).frame(width: 44, height: 32) }
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
            ZStack {
                Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { address.isEditing = false }
                VStack {
                    if position == .top { SuggestionsList(address: address).padding(10); Spacer() }
                    else { Spacer(); SuggestionsList(address: address).padding(10) }
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
    let shape: S
    func body(content: Content) -> some View {
        content
            // Deep black in every theme, so what is on it is white; a light catching the top edge, and a soft shadow that lifts it
            // off the page.
            .environment(\.colorScheme, .dark)
            // Everything inside is cut to the rounded edge, so nothing pokes past the corners.
            .clipShape(shape)
            .background(Obsidian.fill, in: shape)
            .overlay(shape.strokeBorder(Obsidian.edge, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 10, y: 3)
    }
}

private extension View {
    func phoneGlassCapsule() -> some View { modifier(GlassBackground(shape: Capsule(style: .continuous))) }
}

/// The dock folded away while a page is read: one small glass pill with the site. A tap opens the dock again.
struct PhoneCompactPill: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController

    private var label: String {
        guard !tab.isBlank else { return "Search" }
        let host = displayHost(tab.url)
        return host.isEmpty ? tab.displayTitle : host
    }

    var body: some View {
        Button { model.expandChrome() } label: {
            HStack(spacing: 6) {
                if tab.isLoading { ProgressView().controlSize(.mini) }
                else {
                    Image(systemName: tab.isPrivate ? "eye.slash.fill" : (tab.isSecure ? "lock.fill" : "globe"))
                        .font(.system(size: 9, weight: .semibold))
                }
                Text(label).lineLimit(1).truncationMode(.middle).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 10)
            .frame(height: 23)
            .frame(maxWidth: 132)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .phoneGlassCapsule()
        .overlay(alignment: .bottom) { LoadingBar(tab: tab, height: 2).id(tab.id).padding(.horizontal, 14).padding(.bottom, 2) }
        .accessibilityLabel("\(label). Show the toolbar")
        .accessibilityIdentifier("compact-pill")
        .modifier(TabSwipe())
    }
}

/// Swiping a bar sideways moves to the next or previous tab: the bar follows the finger a little, and the page slides in from that side.
/// Swiping up opens the tab overview where that is allowed. Settings › Gestures turns it off.
struct TabSwipe: ViewModifier {
    @EnvironmentObject var model: BrowserModel
    var allowsOverview = false
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
                        guard model.swipeAddressPill else { return }
                        let dx = value.translation.width, dy = value.translation.height
                        if abs(dx) > abs(dy), abs(dx) > 56 {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            model.swipeToTab(dx < 0 ? 1 : -1)
                        } else if allowsOverview, dy < -56, abs(dy) > abs(dx) { model.showOverview() }
                    }
            )
    }
}

/// The controls at the bottom of the screen: separate glass pills in a row, like Safari's compact bar. What is in them, and in what
/// order, is the user's choice (Settings › Toolbar): some buttons, then the address pill, then more buttons and the menu.
struct PhoneDock: View {
    @EnvironmentObject var model: BrowserModel
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
        .frame(maxWidth: 460)
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
            Button { model.showOverview() } label: {
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
                idlePill.modifier(TabSwipe(allowsOverview: true))
            }
        }
        .frame(height: PhoneChrome.height)
        .phoneGlassCapsule()
        .overlay(alignment: .bottom) { LoadingBar(tab: tab, height: 2).id(tab.id).padding(.horizontal, 20).padding(.bottom, 3) }
    }

    private var idlePill: some View {
        HStack(spacing: 0) {
            Button { model.openSearchPanel() } label: {
                HStack(spacing: 6) {
                    if model.showAddressIcon { icon.frame(width: 14) }
                    text
                }
                .padding(.leading, 12)
                .frame(maxWidth: .infinity, minHeight: PhoneChrome.height, alignment: .center)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open search. \(accessibilityText)")
            .accessibilityIdentifier("collapsed-pill")
            .contextMenu { quickActions }
            DockActionButton(action: .reload, tab: tab)
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

    @ViewBuilder private var quickActions: some View {
        Button("New Tab", systemImage: "plus") { model.newTab() }
        Button("Paste and Search", systemImage: "doc.on.clipboard") {
            if let text = UIPasteboard.general.string, !text.isEmpty { model.navigate(input: text) }
        }
        if let url = tab.url, !tab.isBlank {
            Button("Copy Link", systemImage: "link") { UIPasteboard.general.string = url.absoluteString }
            ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
            Button("Find in Page", systemImage: "text.magnifyingglass") { model.showFind() }
            Button("Reload", systemImage: "arrow.clockwise") { tab.reload() }
            Button("Scroll to Bottom", systemImage: "arrow.down.to.line") { tab.scrollToEdge(bottom: true) }
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
            Toggle(isOn: Binding(get: { model.isDarkSite(tab.url?.host) }, set: { _ in action.run(model, tab) })) { Label(title, systemImage: action.symbol) }
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
        let atBottom = model.searchPanelAtBottom
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
