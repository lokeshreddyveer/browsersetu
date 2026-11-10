import SwiftUI

/// The bar layouts on an iPhone, as ONE sheet of glass floating over the page, which runs to the edge of the screen behind it. There is never a sheet on a sheet: the address is
/// not a field inside a card, it is the card's own top line. And the same sheet is what shrinks: scroll and it gathers itself, in place, into a small capsule with just the site,
/// and when you scroll back, or tap it, it opens out again. The glass follows the theme.
///
///  - card: the address on top, a row of buttons under it (the Bottom Bar and the Top Bar layouts).
///  - compact: back, the address and the menu on one slim line (Compact Bottom and Compact Top).
struct PhoneBarSheet: View {
    enum Kind { case card, compact }

    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController
    @ObservedObject var address: AddressBarController
    let kind: Kind
    let folded: Bool
    let atBottom: Bool
    @ObservedObject private var icons = FaviconStore.shared
    @ObservedObject private var look = LookState.shared
    /// With the keyboard up the sheet sits on top of it, so the room kept for the home indicator or the status bar is gone.
    @State private var keyboardUp = false
    /// The room for the status bar and the home indicator. Read again after the window exists (at the first draw it can still be zero) and when the phone is turned.
    @ObservedObject private var insets = WindowInsets.shared

    static func height(_ kind: Kind) -> CGFloat {
        switch kind {
        case .card: 134
        case .compact: 48
        }
    }
    static let foldedHeight: CGFloat = 30
    static let foldedWidth: CGFloat = 190

    private var label: String {
        guard !tab.isBlank else { return "Search" }
        let host = displayHost(tab.url)
        return host.isEmpty ? tab.displayTitle : host
    }

    var body: some View {
        // Typing in the card takes away its row of buttons, so it is shorter while the address is edited.
        let open = kind == .card && address.isEditing ? 72 : Self.height(kind)
        GeometryReader { geo in
            if kind == .compact {
                // Safari's compact bar: a round back button, the address, a round menu button. Folding is one motion: the two buttons slide in under the address and fade, while the
                // address closes up into the small capsule with just the site, and opening is the same in reverse. Nothing is swapped for something else.
                pieces
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: atBottom ? .bottom : .top)
            } else {
            // The dock: attached to the screen's edge (not hovering), its outer corners rounded and its other edge running under the home indicator or the status bar. Open it is
            // as tall as its content plus that safe area; folded it gathers into the small capsule and lifts clear of the edge. One shape whose corners change, so it moves smoothly.
            // Only while the address is being typed AND the keyboard is really up does the sheet sit on the keyboard with no room kept for the home indicator.
            let safe = keyboardUp && address.isEditing && atBottom ? 0 : (atBottom ? insets.bottom : insets.top)
            let outer: CGFloat = folded ? Self.foldedHeight / 2 : 30, inner: CGFloat = folded ? Self.foldedHeight / 2 : 0
            let shape = UnevenRoundedRectangle(topLeadingRadius: atBottom ? outer : inner, bottomLeadingRadius: atBottom ? inner : outer,
                                               bottomTrailingRadius: atBottom ? inner : outer, topTrailingRadius: atBottom ? outer : inner, style: .continuous)
            ZStack {
                expanded
                    .padding(atBottom ? .bottom : .top, safe)
                    .opacity(folded ? 0 : 1)
                    .allowsHitTesting(!folded)
                    .accessibilityHidden(folded)
                foldedLabel
                    .opacity(folded ? 1 : 0)
                    .allowsHitTesting(folded)
                    .accessibilityHidden(!folded)
            }
            .frame(width: folded ? min(Self.foldedWidth, geo.size.width) : geo.size.width, height: folded ? Self.foldedHeight : open + safe)
            .floatingGlass(shape, solidity: folded ? 0.55 : 0.3)
            .offset(y: folded ? (atBottom ? -6 : 6) : (atBottom ? safe : -safe))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: atBottom ? .bottom : .top)
            }
        }
        // Room for the tallest it gets, so the sheet changing size never moves anything else.
        .frame(height: Self.height(kind))
        // The keyboard's real frame decides, not a show / hide pair that can be missed (leaving the app with the keyboard up, for one): it is up only while it covers the screen's foot.
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
            keyboardUp = frame.minY < UIScreen.main.bounds.height - 1
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in if !address.isEditing { keyboardUp = false } }
        .onChange(of: address.isEditing) { _, editing in if !editing { keyboardUp = false } }
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: folded)
        .animation(.spring(response: 0.34, dampingFraction: 0.88), value: address.isEditing)
    }

    // MARK: Open

    @ViewBuilder private var expanded: some View {
        switch kind {
        case .card: card
        case .compact: EmptyView()
        }
    }

    /// Our own dock, not Safari's: a recessed address field on top, and under it the five buttons you use most, each with its name. Everything else is in the menu.
    private var card: some View {
        VStack(spacing: 8) {
            PhoneAddressBar(tab: tab, address: address, compact: false, glass: false, bare: true, showsReload: false)
                .padding(.horizontal, 8)
                .frame(height: 48)
                .background(Color.primary.opacity(0.08), in: Capsule(style: .continuous))
                .padding(.horizontal, 16)
                .modifier(TabSwipe(allowsOverview: !address.isEditing))
            if !address.isEditing {
                HStack(spacing: 0) {
                    dockButton("chevron.left", "Back", disabled: !tab.canGoBack) { tab.goBack() }
                        .contextMenu { NavHistoryItems(tab: tab, back: true) }
                    dockButton("chevron.right", "Forward", disabled: !tab.canGoForward) { tab.goForward() }
                        .contextMenu { NavHistoryItems(tab: tab, back: false) }
                    dockButton(tab.isLoading ? "xmark" : "arrow.clockwise", tab.isLoading ? "Stop" : "Reload", disabled: tab.isBlank) { if tab.isLoading { tab.stop() } else { tab.reload() } }
                    if let url = tab.url, !tab.isBlank {
                        ShareLink(item: url) { dockLabel("square.and.arrow.up", "Share") }.buttonStyle(.plain)
                    } else {
                        dockButton("square.and.arrow.up", "Share", disabled: true) {}
                    }
                    Button { model.openTabsView() } label: {
                        VStack(spacing: 2) {
                            Text("\(model.visibleTabs.count)").font(.system(size: 12, weight: .bold))
                                .frame(width: 22, height: 22).overlay(RoundedRectangle(cornerRadius: 6).stroke(lineWidth: 1.6)).frame(height: 24)
                            Text("Tabs").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Tab overview")
                    VStack(spacing: 2) {
                        PhoneMoreMenu(tab: tab).frame(width: 40, height: 24)
                        Text("Menu").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .padding(.horizontal, 8)
                .transition(.opacity)
            }
        }
        .padding(.top, address.isEditing ? 14 : 14).padding(.bottom, address.isEditing ? 14 : 2)
    }

    private func dockLabel(_ symbol: String, _ name: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: symbol).font(.system(size: 19, weight: .regular)).frame(height: 24)
            Text(name).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
    }

    private func dockButton(_ symbol: String, _ name: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { dockLabel(symbol, name) }
            .buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.4 : 1).accessibilityLabel(name)
    }

    /// The Compact bar: back, the address, the menu. Both folds and opens as one shape.
    private var pieces: some View {
        let height = Self.height(.compact)
        let slot = folded ? 0 : height
        return HStack(spacing: folded ? 0 : 8) {
            if model.shows(.backForward), !address.isEditing {
                Button { tab.goBack() } label: { symbol("chevron.left", height) }
                    .buttonStyle(.plain).disabled(!tab.canGoBack).opacity(tab.canGoBack ? 1 : 0.4)
                    .contextMenu { NavHistoryItems(tab: tab, back: true) }.accessibilityLabel("Back")
                    .frame(width: slot, height: folded ? Self.foldedHeight : height).clipped()
                    .floatingGlassCapsule(solidity: 0.34)
                    .shadow(color: .black.opacity(0.16), radius: 10, y: 3)
                    .scaleEffect(folded ? 0.3 : 1).opacity(folded ? 0 : 1)
                    .allowsHitTesting(!folded)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            ZStack {
                PhoneAddressBar(tab: tab, address: address, compact: true, glass: false, bare: true, showsReload: true)
                    .modifier(TabSwipe(allowsOverview: !address.isEditing))
                    .opacity(folded ? 0 : 1).allowsHitTesting(!folded).accessibilityHidden(folded)
                foldedLabel
                    .opacity(folded ? 1 : 0).allowsHitTesting(folded).accessibilityHidden(!folded)
            }
            .frame(width: folded ? min(Self.foldedWidth, 400) : nil, height: folded ? Self.foldedHeight : height)
            // A thin line of progress along the foot of the address while the page loads.
            .overlay(alignment: .bottom) { if !folded { LoadingBar(tab: tab, height: 2).id(tab.id).padding(.horizontal, 22).padding(.bottom, 2) } }
            .floatingGlassCapsule(solidity: folded ? 0.55 : 0.34)
            .shadow(color: .black.opacity(0.16), radius: 10, y: 3)
            if !address.isEditing {
                PhoneMoreMenu(tab: tab).frame(width: slot, height: folded ? Self.foldedHeight : height).clipped().contentShape(Circle())
                    .floatingGlassCapsule(solidity: 0.34)
                    .shadow(color: .black.opacity(0.16), radius: 10, y: 3)
                    .scaleEffect(folded ? 0.3 : 1).opacity(folded ? 0 : 1)
                    .allowsHitTesting(!folded)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func symbol(_ name: String, _ size: CGFloat) -> some View {
        Image(systemName: name).font(.system(size: 17, weight: .medium)).frame(width: size, height: size).contentShape(Circle())
    }

    // MARK: Folded

    private var foldedLabel: some View {
        Menu {
            PhoneMenuContent(tab: tab)
        } label: {
            HStack(spacing: 6) {
                icon
                Text(label).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle).foregroundStyle(Color.primary).frame(maxWidth: 140)
            }
            .frame(width: Self.foldedWidth, height: Self.foldedHeight)
            .contentShape(Capsule())
        } primaryAction: {
            if !SwipeGuard.recent { UIImpactFeedbackGenerator(style: .light).impactOccurred(); model.expandChrome(userRequested: true) }
        }
        .menuOrder(.fixed)
        .buttonStyle(.plain)
        .overlay(alignment: atBottom ? .bottom : .top) { LoadingBar(tab: tab, height: 2).id(tab.id).padding(.horizontal, 14).padding(atBottom ? .bottom : .top, 2) }
        .modifier(TabSwipe(up: atBottom ? .openDock : .nothing))
        .accessibilityLabel("\(label). Show the toolbar")
        .accessibilityIdentifier("bar-capsule")
        .accessibilityAction(named: "Show the toolbar") { model.expandChrome(userRequested: true) }
    }

    @ViewBuilder private var icon: some View {
        if tab.isPrivate { Image(systemName: "eye.slash.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.privateAccent) }
        else if tab.isBlank { Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.primary) }
        else if let url = tab.url, let image = icons.image(forURL: url.absoluteString, points: 14) {
            Image(uiImage: image).resizable().scaledToFit().frame(width: 14, height: 14).clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        } else {
            Image(systemName: tab.isSecure ? "lock.fill" : "globe").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.primary)
        }
    }
}
