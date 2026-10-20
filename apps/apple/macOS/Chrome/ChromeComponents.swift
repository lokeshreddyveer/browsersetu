import AppKit
import SetuPrivacyCore
import SwiftUI

// MARK: - Surfaces

extension Color {
    /// The window's own colour: toolbar, tab strip and sidebar share it, so the page reads as one card on top.
    static var chrome: Color { ThemeState.chrome ?? adaptive(dark: 0.095, light: 0.905) }
    /// A raised surface on the chrome: the selected tab or row.
    static var raised: Color { ThemeState.raised ?? adaptive(dark: 0.20, light: 1.0) }
    /// The selected tab: white at 18% in dark, 80% in light, so the window's tint shows through.
    static var selectedTab: Color {
        dynamic(dark: (1, 0.18), light: (1, 0.80))
    }
    /// The address field's fill: the text colour at 15% in dark, 8% in light.
    static var fieldFill: Color {
        dynamic(dark: (1, 0.15), light: (0, 0.08))
    }

    private static func adaptive(dark: CGFloat, light: CGFloat) -> Color {
        dynamic(dark: (dark, 1), light: (light, 1))
    }

    /// A grey that follows the light or dark appearance, as (white, alpha) pairs.
    private static func dynamic(dark: (CGFloat, CGFloat), light: (CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: dark.0, alpha: dark.1) : NSColor(white: light.0, alpha: light.1)
        })
    }
}

extension Color {
    init(tint: PageTint) { self.init(red: tint.red, green: tint.green, blue: tint.blue) }
}

/// A group of toolbar buttons sharing one soft capsule, like the system's grouped toolbar items.
struct GlassCapsule: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 2)
            .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.06)))
            .overlay(Capsule(style: .continuous).strokeBorder(Color.primary.opacity(contrast == .increased ? 0.35 : 0.08), lineWidth: 0.5))
    }
}

extension View {
    func glassCapsule() -> some View { modifier(GlassCapsule()) }
}

/// The page's own colour behind the toolbar and tab row, as Safari does it. How much of it shows depends on what is already there: a chosen theme keeps most of its own
/// colour (so the theme is still the theme), and a colour that would fight the window's light or dark look (a white page in a dark window) is only a faint wash, so the
/// buttons and text on the bar stay easy to read.
enum ToolbarTint {
    static func strength(for tint: PageTint, dark: Bool, themed: Bool) -> Double {
        let luminance = 0.2126 * tint.red + 0.7152 * tint.green + 0.0722 * tint.blue
        let base = themed ? 0.30 : 0.50
        let clashes = dark ? luminance > 0.62 : luminance < 0.38
        return clashes ? min(base, 0.14) : base
    }
}

struct ToolbarTintLayer: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if model.tintToolbar, !tab.isBlank, let tint = tab.tint {
                Color(tint: tint).opacity(ToolbarTint.strength(for: tint, dark: scheme == .dark, themed: model.themeIsActive))
            } else {
                Color.clear
            }
        }
        .motion(.easeOut(duration: 0.25), value: tab.tint)
        .allowsHitTesting(false)
    }
}

/// The spacing between the window's edge and what sits inside it. One value, so the whole window can be tightened together.
enum WindowInset {
    /// The gap around the page card (and around the floating sidebar).
    static let gap: CGFloat = 4
    /// How far below the window's top edge the folded pill sits. Clear of the border and the rounded corners.
    static let pillTop: CGFloat = 10
}

enum Radius {
    static let page: CGFloat = 12
    static let control: CGFloat = 8
    static let field: CGFloat = 10
    static let tab: CGFloat = 9
    static let floating: CGFloat = 14
    /// Toolbar buttons are 28pt, so this makes the hover shape a circle.
    static let toolbarButton: CGFloat = 14
    /// Sidebar rows, tiles and the address field.
    static let item: CGFloat = 14
    /// The expanded address field and the floating address bar.
    static let breakout: CGFloat = 15
}

/// The page sits in a rounded card inset from the window edges. Focus mode drops the card and goes edge to edge.
struct PageCard: ViewModifier {
    let enabled: Bool
    var leading: CGFloat = WindowInset.gap
    var trailing: CGFloat = WindowInset.gap
    var top: CGFloat = 0
    func body(content: Content) -> some View {
        if enabled {
            content
                .clipShape(RoundedRectangle(cornerRadius: Radius.page, style: .continuous))
                .hairline(RoundedRectangle(cornerRadius: Radius.page, style: .continuous), opacity: 0.10, width: 0.5)
                .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
                .padding(.leading, leading).padding(.trailing, trailing).padding(.bottom, WindowInset.gap).padding(.top, top)
        } else {
            content
        }
    }
}

// MARK: - Buttons

/// One icon button for the whole window: 28 pt hit target, 13 pt symbol, quiet hover and pressed feedback.
struct ChromeButtonStyle: ButtonStyle {
    /// Symbol size; the hit target grows with it.
    var iconSize: CGFloat = 13

    func makeBody(configuration: Configuration) -> some View {
        ChromeButtonBody(configuration: configuration, iconSize: iconSize)
    }

    private struct ChromeButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let iconSize: CGFloat
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: iconSize, weight: IconWeight.current.weight))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(enabled ? Color.primary.opacity(0.85) : Color.primary.opacity(0.28))
                .frame(width: iconSize > 13 ? 32 : 28, height: iconSize > 13 ? 32 : 28)
                .background(
                    RoundedRectangle(cornerRadius: Radius.toolbarButton, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : (hovering && enabled ? 0.09 : 0)))
                )
                .overlay(RoundedRectangle(cornerRadius: Radius.toolbarButton, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(focused ? 0.9 : 0), lineWidth: 2).allowsHitTesting(false))
                .contentShape(RoundedRectangle(cornerRadius: Radius.toolbarButton, style: .continuous))
                .motion(.easeOut(duration: 0.12), value: hovering)
                .motion(.easeOut(duration: 0.08), value: configuration.isPressed)
                .motion(.easeOut(duration: 0.12), value: focused)
                .onHover { hovering = $0 }
        }
    }
}

struct ChromeButton: View {
    let symbol: String
    let help: String
    var identifier: String?
    var tint: Color?
    var iconSize: CGFloat = 13
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).foregroundStyle(tint ?? .primary)
        }
        .buttonStyle(ChromeButtonStyle(iconSize: iconSize))
        .focusable()
        .focusEffectDisabled()
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier(identifier ?? help)
    }
}

// MARK: - VayuSetu shield (an independent control: icon only, status lives in its popover)

struct ShieldPill: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var privacy: PrivacyController
    let host: String?
    /// Drawn inside the address field: no capsule of its own, smaller.
    var inField = false
    @Environment(\.holdBrowserChrome) private var holdChrome
    @State private var showPopover = false
    @State private var hovering = false

    private var state: ProtectionState { privacy.state(forHost: host) }

    private var tint: Color {
        switch state {
        case .active: .green                 // reserved for verified protection
        case .partial, .error: .orange
        case .disabled, .exception: .secondary
        case .updating: .secondary
        }
    }

    var body: some View {
        Button { showPopover.toggle() } label: {
            Image(systemName: state.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: inField ? 24 : 30, height: inField ? 22 : 26)
                .background(Capsule(style: .continuous).fill(Color.primary.opacity(hovering || showPopover ? 0.12 : (inField ? 0 : 0.08))))
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(state.headline)
        .accessibilityLabel(state.headline)
        .accessibilityValue(state.detail ?? state.statusWord)
        .accessibilityHint("Opens privacy protection level")
        .accessibilityIdentifier("shield-button")
        .onChange(of: showPopover) { _, shown in holdChrome(shown) }
        .onDisappear { if showPopover { holdChrome(false) } }
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            PrivacyPopover(privacy: privacy, host: host, dismiss: { showPopover = false }, blocked: model.blockedStats, blockedOnPage: model.active?.blockedOnPage ?? 0, onRepair: { model.sheet = .repair }, onHistory: { model.privacySheet = .history }, onSite: { model.privacySheet = .site })
                .environmentObject(model)
        }
        #if DEBUG
        .onChange(of: model.privacyPopoverRequested) { _, requested in if requested { showPopover = true } }
        #endif
    }
}

// MARK: - Window dragging (the title bar is hidden, so empty toolbar space moves the window)

/// What a double-click on an empty part of the top of the window does. The window installs one handler; without one, or when
/// the handler declines, the window zooms as macOS windows normally do.
@MainActor
enum WindowDoubleClick {
    static var handler: (() -> Bool)?

    static func perform(in window: NSWindow?) {
        if handler?() == true { return }
        window?.performZoom(nil)
    }
}

struct WindowDragRegion: NSViewRepresentable {
    final class DragView: NSView {
        /// Single clicks, drags and clicks on controls pass straight through (this view must never sit in front of a text field).
        /// Only the second click of a double-click is caught, and only where nothing in front of this view took it.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent, event.type == .leftMouseDown, event.clickCount == 2 else { return nil }
            return super.hitTest(point)
        }
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { MainActor.assumeIsolated { WindowDoubleClick.perform(in: window) } } else { super.mouseDown(with: event) }
        }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}
}

/// Reports full-screen changes so the toolbar can give back the space the traffic lights used.
struct WindowObserver: NSViewRepresentable {
    let onFullScreen: (Bool) -> Void

    final class ObserverView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        var onFullScreen: (Bool) -> Void = { _ in }
        private var tokens: [NSObjectProtocol] = []
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach { NotificationCenter.default.removeObserver($0) }; tokens = []
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            DispatchQueue.main.async { [weak self, weak window] in
                self?.onFullScreen(window?.styleMask.contains(.fullScreen) ?? false)
            }
            for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                tokens.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] _ in
                    MainActor.assumeIsolated { self?.onFullScreen(window?.styleMask.contains(.fullScreen) ?? false) }
                })
            }
        }
        deinit { tokens.forEach { NotificationCenter.default.removeObserver($0) } }
    }
    func makeNSView(context: Context) -> ObserverView { let view = ObserverView(); view.onFullScreen = onFullScreen; return view }
    func updateNSView(_ view: ObserverView, context: Context) { view.onFullScreen = onFullScreen }

}

// MARK: - Omnibox

struct MacOmnibox: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController
    @ObservedObject var address: AddressBarController
    /// The centred address bar has its own focus counter so it never competes with an in-sidebar one.
    var floating = false
    /// No background, border or swell: the field sits inside a pill that provides them (the Floating layout's Search pill).
    var bare = false
    /// Top-bar field: reload/stop and the shield live inside it at the trailing edge.
    var showReload = false
    var shield = false
    /// The active tab of the One Row layout: Safari's compact bar, where the selected tab is the address field.
    var tabField = false
    @Environment(\.holdBrowserChrome) private var holdChrome
    @Environment(\.colorSchemeContrast) private var contrast
    @ObservedObject private var siteIcons = FaviconStore.shared
    @State private var showInfo = false
    @State private var hovering = false
    @State private var arrangingBar = false

    /// In the sidebar layout the field is a taller, rounder block and its icon only shows on hover, as the page's
    /// domain is the only thing that matters at rest.
    private var inSidebar: Bool { model.singleToolbar && !floating }
    private var height: CGFloat { tabField ? 26 : (bare ? 26 : (floating ? 32 : (inSidebar ? 36 : 30))) }
    private var radius: CGFloat { tabField ? 8 : (floating ? height / 2 : (inSidebar ? Radius.item : height / 2)) }

    private var icon: String {
        if tab.isPrivate { return "eye.slash.fill" }
        if tab.isBlank { return "magnifyingglass" }
        return tab.isSecure ? "lock.fill" : "exclamationmark.triangle.fill"
    }

    private var iconColor: Color {
        if tab.isPrivate { return Theme.privateAccent }
        if tab.isBlank || tab.isSecure { return .secondary }
        return .orange
    }

    var body: some View {
        Group { if bare { row.accessibilityElement(children: .contain) } else { chromed } }
            // On a new tab the page has its own search field, so the address pill and the Search pill step aside until something is typed.
            .opacity(hiddenOnStartPage ? 0 : 1)
            .allowsHitTesting(!hiddenOnStartPage)
            .accessibilityHidden(hiddenOnStartPage)
            .motion(.easeOut(duration: 0.18), value: hiddenOnStartPage)
    }

    private var hiddenOnStartPage: Bool { tab.isBlank && !tabField && !address.isEditing && !model.floatingAddressVisible }

    private var chromed: some View {
        row
        .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.fieldFill.opacity(address.isEditing ? 0.7 : (hovering ? 1.15 : 1))))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(Color.primary.opacity(address.isEditing ? 0 : (contrast == .increased ? 0.4 : (inSidebar ? 0.10 : 0.07))), lineWidth: 0.5).allowsHitTesting(false))
        .overlay(alignment: .bottom) {
            // In the sidebar the field is also the page's progress bar.
            if inSidebar { LoadingBar(tab: tab, height: 2).id(tab.id).padding(.horizontal, 12).allowsHitTesting(false) }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .onHover { hovering = $0 }
        // Safari lets the field swell a little when it takes focus.
        .scaleEffect(address.isEditing && !inSidebar && !floating ? 1.02 : 1)
        .motion(.spring(response: 0.28, dampingFraction: 0.8), value: address.isEditing)
        .accessibilityElement(children: .contain)
    }

    private var row: some View {
        HStack(spacing: 7) {
            if model.addressBarItems.contains(.siteInfo) {
            Button { showInfo.toggle() } label: {
                if inSidebar, !tab.isBlank, !tab.isPrivate, let image = tab.url.flatMap({ FaviconStore.shared.image(forURL: $0.absoluteString, points: 15) }) {
                    // The site's own icon, shown at the start of the field.
                    Image(nsImage: image).frame(width: 16, height: 16)
                } else {
                    Image(systemName: icon).font(.system(size: 11, weight: .medium)).foregroundStyle(iconColor).frame(width: 16)
                }
            }
            .buttonStyle(.plain)
            .opacity(1)
            .motion(.easeOut(duration: 0.15), value: hovering)
            .help(tab.identity.map { $0.headline + ". " + $0.detail } ?? "Site Information")
            .accessibilityLabel(tab.identity.map { "Site information. " + $0.headline } ?? "Site information")
            .onChange(of: showInfo) { _, shown in holdChrome(shown) }
            .onDisappear { if showInfo { holdChrome(false) } }
            .popover(isPresented: $showInfo, arrowEdge: .bottom) { SiteInfoView(tab: tab).environmentObject(model) }
            }

            OmniboxField(
                displayText: tab.isBlank ? "" : displayHost(tab.url),
                editText: tab.isBlank ? "" : (tab.url?.absoluteString ?? ""),
                placeholder: "Search or enter address",
                focusTick: floating ? model.floatingFocusTick : model.omniboxFocusTick,
                focusOnMount: floating,
                address: address,
                completionSites: { model.completionSites() },
                onTextChange: { _ in address.refresh(model: model) },
                onSubmit: { text in
                    if let picked = address.selectedSuggestion {
                        model.accept(picked)
                    } else {
                        address.clear()
                        model.navigate(input: text)
                    }
                },
                onMoveSelection: { address.moveSelection($0) })
            .frame(height: 20)

            if address.isEditing && !floating && !inSidebar && !tabField {
                // While typing, the controls give way to the search engine choice and the key that sends it.
                SearchEngineMenu(compact: true)
                Text("↩").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.1)))
                    .accessibilityHidden(true)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
            // The buttons at the end of the field are the ones chosen in Settings, in that order (right-click the bar to change them).
            ForEach(model.addressBarItems.filter { $0 != .siteInfo }) { item in trailing(item) }
        }
        .motion(.easeOut(duration: 0.2), value: tab.identity)
        .motion(.easeOut(duration: 0.2), value: model.addressBarItems)
        .padding(.horizontal, bare ? 2 : 10)
        .frame(height: height)
        .contextMenu { addressBarMenu }
        .popover(isPresented: $arrangingBar, arrowEdge: .bottom) {
            ButtonArranger(kind: "address", heading: "Address Bar Buttons", items: $model.addressBarItems, all: AddressBarItem.allCases, defaults: AddressBarItem.defaults,
                           title: { $0.title }, symbol: { $0.symbol })
        }
    }

    /// One of the buttons at the end of the field. Each still keeps to what its layout allows (the shield and reload are only in the top bar), and none shows while the address is being typed.
    @ViewBuilder private func trailing(_ item: AddressBarItem) -> some View {
        switch item {
        case .siteInfo: EmptyView()
        case .certificateName:
            if let label = tab.identity?.shortLabel, !address.isEditing, !inSidebar, !floating, !tabField, !tab.isPrivate {
                // A site whose certificate names a checked organisation shows who it is, quietly, beside the padlock's address.
                Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.green.opacity(0.85)).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: 140).help(tab.identity?.detail ?? "").accessibilityLabel(tab.identity?.headline ?? "")
                    .transition(.opacity)
            }
        case .shield:
            if shield && !address.isEditing {
                ShieldPill(privacy: model.privacy, host: tab.url?.host, inField: true)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        case .bookmarkStar:
            if !address.isEditing, !tab.isBlank {
                fieldButton(model.activeBookmarked ? "star.fill" : "star", "Bookmark This Page", tint: model.activeBookmarked ? .yellow : nil) { model.toggleBookmark() }
            }
        case .share:
            if !address.isEditing, !tab.isBlank, let url = tab.url {
                ShareLink(item: url) { Image(systemName: "square.and.arrow.up").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).frame(width: 22, height: 22) }
                    .buttonStyle(.plain).help("Share").accessibilityLabel("Share")
            }
        case .copyLink:
            if !address.isEditing, !tab.isBlank, let url = tab.url {
                fieldButton("link", "Copy Link") { copyToPasteboard(url.absoluteString); model.notice = "Link copied." }
            }
        case .pageActions:
            if !address.isEditing, !tab.isBlank {
                Menu {
                    ForEach(PageAction.allCases) { action in
                        Button { model.togglePageAction(action, on: tab) } label: {
                            if tab.pageActions.contains(action) { Label(action.title, systemImage: "checkmark") } else { Label(action.title, systemImage: action.symbol) }
                        }
                    }
                    Divider()
                    Button("Reset This Page") { model.clearPageActions(on: tab) }.disabled(tab.pageActions.isEmpty)
                } label: {
                    Image(systemName: "wand.and.stars").font(.system(size: 11, weight: .semibold)).foregroundStyle(tab.pageActions.isEmpty ? Color.secondary : Theme.accent).frame(width: 22, height: 22)
                }
                .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain).fixedSize().help("Page Actions").accessibilityLabel("Page actions")
            }
        case .reload:
            if showReload && !address.isEditing {
                Button { tab.isLoading ? tab.stop() : tab.reload() } label: {
                    Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise")
                        .accessibilityLabel(tab.isLoading ? "Stop loading" : "Reload")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(tab.isLoading ? "Stop" : "Reload")
                .accessibilityLabel(tab.isLoading ? "Stop" : "Reload")
                .accessibilityIdentifier("reload-button")
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
    }

    private func fieldButton(_ symbol: String, _ help: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint ?? Color.secondary).frame(width: 22, height: 22).contentShape(Circle())
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(help)
    }

    /// Right-click the bar (outside the text): tick the buttons to show in it.
    @ViewBuilder private var addressBarMenu: some View {
        ForEach(AddressBarItem.allCases) { item in
            Button {
                animated(.easeOut(duration: 0.2)) {
                    if model.addressBarItems.contains(item) { model.addressBarItems.removeAll { $0 == item } }
                    else { model.addressBarItems.append(item) }
                }
            } label: {
                if model.addressBarItems.contains(item) { Label(item.title, systemImage: "checkmark") } else { Label(item.title, systemImage: item.symbol) }
            }
        }
        Divider()
        Button("Reset to Default") { animated(.easeOut(duration: 0.2)) { model.addressBarItems = AddressBarItem.defaults } }
        Button("Arrange Buttons…") { arrangingBar = true }
    }
}

// MARK: - Top bar

struct TopBar: View {
    @EnvironmentObject var model: BrowserModel
    /// Space reserved for the window's traffic lights when nothing else covers them.
    let leadingInset: CGFloat

    var body: some View {
        Group { if model.singleRow { InlineBar(leadingInset: leadingInset) } else { standard } }
            .contextMenu { ToolbarContextMenu() }
    }

    private var standard: some View {
        GeometryReader { geo in
            let priority = ToolbarPriority(fitting: geo.size.width, leadingInset: leadingInset, extras: model.toolbarExtrasCount)
            // Controls hug both edges and the address field sits in the middle of the window, not between the
            // two clusters, so it stays put as buttons come and go.
            ZStack {
                HStack(spacing: 2) {
                    Color.clear.frame(width: leadingInset, height: 1)
                    if model.shows(.sidebar) {
                        ChromeButton(symbol: "sidebar.left", help: "Toggle Sidebar", identifier: "sidebar-button") { model.sidebarVisible.toggle() }
                    }
                    if let tab = model.active, model.shows(.backForward) {
                        HStack(spacing: 0) { NavigationButtons(tab: tab, showForward: priority.showForward, hideReload: true) }
                            .glassCapsule()
                            .padding(.leading, 2)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 0) { trailing(priority) }.glassCapsule()
                }
                .padding(.trailing, 10)
                if let tab = model.active {
                    MacOmnibox(tab: tab, address: model.addressBar, showReload: true, shield: true)
                        .frame(width: priority.fieldWidth(window: geo.size.width, leadingInset: leadingInset))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .motion(.easeOut(duration: 0.2), value: priority)
        }
        .frame(height: 40)
        .background(WindowDragRegion())
    }

    @ViewBuilder private func trailing(_ priority: ToolbarPriority) -> some View {
        ExtensionActionButtons(center: model.extensionCenter)
        if priority.showOptional {
            ToolbarExtras()
            if model.shows(.share), let url = model.active?.url, model.active?.isBlank == false {
                ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                    .buttonStyle(ChromeButtonStyle()).help("Share").accessibilityLabel("Share")
            }
            if model.shows(.newTab) { ChromeButton(symbol: "plus", help: "New Tab", identifier: "new-tab-button") { model.newTab() } }
            if model.shows(.tabOverview) {
                ChromeButton(symbol: "square.on.square", help: "Show Tab Overview", identifier: "overview-button") {
                    model.overviewVisible ? model.hideOverview() : model.showOverview()
                }
            }
        }
        if model.shows(.bookmark), priority.showBookmark {
            ChromeButton(symbol: model.activeBookmarked ? "star.fill" : "star", help: "Bookmark This Page", identifier: "bookmark-button",
                         tint: model.activeBookmarked ? .yellow : nil) { model.toggleBookmark() }
                .disabled(model.active?.isBlank ?? true)
        }
        if model.shows(.downloads), priority.showDownloads {
            DownloadsToolbarButton(coordinator: model.downloads)
        }
        MoreMenu(priority: priority)
    }
}

/// One button per enabled extension that has a toolbar action. Clicking opens the extension's popup.
struct ExtensionActionButtons: View {
    @ObservedObject var center: ExtensionCenter
    /// The puzzle-piece menu that lists every extension; off where the layout shows it somewhere else.
    var showsMenu = true

    var body: some View {
        buttons
        if showsMenu { ExtensionsMenu(center: center) }
    }

    @ViewBuilder private var buttons: some View {
        ForEach(center.pinnedActions.prefix(4)) { item in
            ExtensionActionButton(center: center, item: item)
        }
    }
}

/// Remembers where its view is in the window, so a popup can be attached to it when it is clicked.
final class FrameBox { var rect: CGRect = .zero }

extension View {
    func reportsFrame(_ box: FrameBox) -> some View {
        background(GeometryReader { geometry in
            Color.clear
                .onAppear { box.rect = geometry.frame(in: .global) }
                .onChange(of: geometry.frame(in: .global)) { _, new in box.rect = new }
        })
    }
}

struct ExtensionActionButton: View {
    @ObservedObject var center: ExtensionCenter
    let item: ExtensionActionItem
    @State private var box = FrameBox()

    var body: some View {
        Group {
            Button { center.noteClick(box.rect); center.perform(actionFor: item.id) } label: {
                Group {
                    if let data = item.icon, let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().scaledToFit().frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "puzzlepiece.extension")
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if !item.badge.isEmpty {
                        Text(item.badge).font(.system(size: 8, weight: .bold)).padding(.horizontal, 3)
                            .background(Capsule().fill(Color.red)).foregroundStyle(.white).offset(x: 6, y: -6)
                    }
                }
            }
            .buttonStyle(ChromeButtonStyle())
            .disabled(!item.enabled)
            .help(item.label)
            .accessibilityLabel(item.label)
        }
        .reportsFrame(box)
    }
}

/// Every extension in one menu, as in Chrome: open it, pin it to the toolbar or unpin it, reach its settings. Works in every layout.
struct ExtensionsMenu: View {
    @ObservedObject var center: ExtensionCenter
    /// How the button looks: a toolbar button, or a sidebar footer item.
    var footer = false
    @State private var box = FrameBox()

    var body: some View {
        if center.hasExtensions {
            Group {
                if footer { menu.buttonStyle(.plain).frame(maxWidth: .infinity) } else { menu.buttonStyle(ChromeButtonStyle()) }
            }
            .reportsFrame(box)
        }
    }

    private var menu: some View {
        Menu {
                ForEach(center.extensions) { item in
                    Menu(item.name) {
                        if center.actions.contains(where: { $0.id == item.id }) {
                            Button("Open", systemImage: "puzzlepiece.extension") { center.noteClick(box.rect); center.perform(actionFor: item.id) }.disabled(!item.enabled)
                            Button(center.isPinned(item.id) ? "Unpin from Toolbar" : "Pin to Toolbar", systemImage: center.isPinned(item.id) ? "pin.slash" : "pin") {
                                center.setPinned(item.id, !center.isPinned(item.id))
                            }
                        }
                        if item.hasOptions && item.enabled { Button("Settings", systemImage: "gearshape") { center.openOptions(item.id) } }
                    }
                }
                Divider()
                Button("Manage Extensions…") { SettingsRouter.open(.extensions) }
            } label: {
                if footer { FooterItemLabel(symbol: "puzzlepiece.extension", label: "Extensions", tint: nil) }
                else { Image(systemName: "puzzlepiece.extension") }
            }
            .menuStyle(.button).menuIndicator(.hidden)
            .help("Extensions")
            .accessibilityLabel("Extensions")
            .accessibilityIdentifier("extensions-menu")
    }
}

struct NavigationButtons: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController
    let showForward: Bool
    var alwaysReload = false
    /// The top bar puts reload inside the address field instead.
    var hideReload = false

    var body: some View {
        ChromeButton(symbol: "chevron.left", help: "Back", identifier: "back-button") { tab.goBack() }.disabled(!tab.canGoBack)
            .contextMenu { NavHistoryItems(tab: tab, back: true) }
        // Forward only shows when there is somewhere to go forward to, as in Safari.
        if showForward && tab.canGoForward {
            ChromeButton(symbol: "chevron.right", help: "Forward", identifier: "forward-button") { tab.goForward() }
                .contextMenu { NavHistoryItems(tab: tab, back: false) }
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
        if (alwaysReload || model.shows(.reload)) && !hideReload {
            ChromeButton(symbol: tab.isLoading ? "xmark" : "arrow.clockwise", help: tab.isLoading ? "Stop" : "Reload", identifier: "reload-button") {
                tab.isLoading ? tab.stop() : tab.reload()
            }
        }
    }
}

// MARK: - More menu

struct MoreMenu: View {
    @EnvironmentObject var model: BrowserModel
    let priority: ToolbarPriority

    var body: some View {
        Menu {
            Section("Navigation") {
                Button("Back") { model.active?.goBack() }.disabled(!(model.active?.canGoBack ?? false))
                Button("Forward") { model.active?.goForward() }.disabled(!(model.active?.canGoForward ?? false))
                Button { model.newTab() } label: { Label("New Tab", systemImage: "plus") }
                Button { model.openTab(url: nil, isPrivate: true) } label: { Label("New Private Tab", systemImage: "eye.slash") }
                Button { model.showOverview() } label: { Label("Show Tab Overview", systemImage: "square.on.square") }
                Button { promptNewGroup(model: model) } label: { Label("New Tab Group…", systemImage: "folder.badge.plus") }
            }
            Section("Page") {
                Button { model.toggleBookmark() } label: {
                    Label(model.activeBookmarked ? "Remove Bookmark" : "Bookmark This Page", systemImage: model.activeBookmarked ? "star.fill" : "star")
                }
                .disabled(model.active?.isBlank ?? true)
                Button { model.showFind() } label: { Label("Find in Page…", systemImage: "magnifyingglass") }.disabled(model.active?.isBlank ?? true)
                Button { model.printActive() } label: { Label("Print…", systemImage: "printer") }.disabled(model.active?.isBlank ?? true)
                Button { Task { await model.savePageForLater() } } label: { Label("Save Page for Later", systemImage: "square.and.arrow.down") }.disabled(model.active?.isBlank ?? true)
                Button { model.active?.reload() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                if let url = model.active?.url, model.active?.isBlank == false {
                    ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
                }
            }
            Section("Workspace and Split View") {
                Menu { Button("Personal") { model.switchWorkspace("") }; ForEach(model.workspaces) { w in Button(w.name) { model.switchWorkspace(w.name) } }; Divider(); Button("New Workspace…") { promptNewWorkspace(model: model) } } label: {
                    Label("Workspace: " + (model.activeWorkspace.isEmpty ? "Personal" : model.activeWorkspace), systemImage: "square.grid.2x2")
                }
                Menu { SplitViewMenuItems() } label: { Label("Split View", systemImage: "rectangle.split.2x1") }
            }
            Section("Browser") {
                Button { model.sheet = .bookmarks } label: { Label("Bookmarks", systemImage: "book") }
                Button { model.sheet = .history } label: { Label("History", systemImage: "clock") }
                Button { model.sheet = .downloads } label: { Label("Downloads", systemImage: "arrow.down.circle") }
                Picker(selection: Binding(get: { model.profileName }, set: { model.switchProfile($0) })) {
                    ForEach(model.profiles, id: \.self) { Text($0).tag($0) }
                } label: { Label("Profile", systemImage: "person.crop.circle") }
            }
            Section("Layout") {
                Picker("Layout", selection: $model.layoutPreset) {
                    ForEach(LayoutPreset.allCases) { Text($0.title).tag($0) }
                }
                Button(model.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") { model.sidebarVisible.toggle() }
                Menu("Window Layout") { ForEach(WindowPreset.allCases) { preset in Button(preset.title) { model.applyWindowPreset(preset) } } }
                Button("Restore Standard Layout") { model.restoreStandardLayout() }
                Button("Layout Diagnostics…") { model.sheet = .layout }
            }
            Section("Application") {
                Button { SettingsRouter.open() } label: { Label("Settings…", systemImage: "gearshape") }
                Button { NSApp.orderFrontStandardAboutPanel(nil) } label: { Label("About BrowserSetu", systemImage: "info.circle") }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 13, weight: .medium)).frame(width: 32, height: 32).contentShape(Rectangle()).accessibilityLabel("More")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(ChromeButtonStyle())
        .fixedSize()
        .help("More")
        .accessibilityLabel("More")
        .accessibilityIdentifier("more-menu")
    }
}


extension ExtensionCenter {
    /// Remembers where the user just clicked, so the popup it opens hangs from that exact spot. The measured frame is the fallback (a menu item).
    func noteClick(_ frame: CGRect) {
        anchor = frame
        anchorDate = Date()
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        if let event = NSApp.currentEvent, event.window === window, [.leftMouseDown, .leftMouseUp].contains(event.type) {
            clickPoint = event.locationInWindow
        } else { clickPoint = nil }
    }
}
