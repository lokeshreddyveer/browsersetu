import AppKit
import SwiftUI

/// Where the pointer must be for the window buttons to come back while the toolbar is folded away.
enum TrafficLightZone {
    /// A generous corner, larger than the buttons themselves, so reaching for them never feels like aiming.
    static let size = CGSize(width: 120, height: 46)

    /// `point` is in window coordinates (origin at the bottom left), as `mouseLocationOutsideOfEventStream` gives.
    static func contains(_ point: CGPoint, windowHeight: CGFloat) -> Bool {
        point.x >= 0 && point.x <= size.width && point.y >= windowHeight - size.height && point.y <= windowHeight
    }
}

/// Fades the red, yellow and green window buttons out while `hidden` is true, and brings them back whenever the pointer
/// is in the top-left corner. Nothing about the window itself changes: it can still be moved, closed and zoomed.
extension Notification.Name {
    /// Posted when the window's traffic lights fade in or out in a layout that hides them.
    static let trafficLightsVisibility = Notification.Name("BrowserSetu.trafficLightsVisibility")
}

/// Whether the lights are showing in a layout that hides them, for a view that appears after they did.
@MainActor enum TrafficLightsState { static var shown = false }

struct TrafficLightsController: NSViewRepresentable {
    let hidden: Bool

    final class ControlView: NSView {
        var folded = false { didSet { if folded != oldValue { apply() } } }
        private var monitor: Any?
        private var inCorner = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard let window else { return }
            window.acceptsMouseMovedEvents = true
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .mouseExited]) { [weak self] event in
                MainActor.assumeIsolated { self?.pointerMoved() }
                return event
            }
            apply()
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

        private var buttons: [NSButton] {
            [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window?.standardWindowButton($0) }
        }

        private func pointerMoved() {
            guard let window else { return }
            // Only the window in front reacts: a second window's corner is not "hovered" because the pointer is somewhere in the other one.
            let inside = window.isKeyWindow && TrafficLightZone.contains(window.mouseLocationOutsideOfEventStream, windowHeight: window.frame.height)
            if inside != inCorner { inCorner = inside; apply() }
        }

        private func apply() {
            let show = !folded || inCorner
            // The sidebar header makes room for the lights while they are showing, so nothing is drawn under them.
            TrafficLightsState.shown = show && folded
            NotificationCenter.default.post(name: .trafficLightsVisibility, object: nil, userInfo: ["shown": show && folded])
            // Unhiding the buttons makes AppKit lay the title bar out again, which puts them back on its own line: the shared line is applied once that has happened.
            if show, let window { DispatchQueue.main.async { [weak window] in if let window { TrafficLightLine.apply(to: window) } } }
            for button in buttons {
                if show { button.isHidden = false }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
                    button.animator().alphaValue = show ? 1 : 0
                } completionHandler: { [weak self, weak button] in
                    // Fully faded buttons stop taking clicks, unless they were brought back meanwhile.
                    MainActor.assumeIsolated { if let self, let button, self.folded && !self.inCorner { button.isHidden = true } }
                }
            }
        }
    }

    func makeNSView(context: Context) -> ControlView { let view = ControlView(); view.folded = hidden; return view }
    func updateNSView(_ view: ControlView, context: Context) { view.folded = hidden }
}

/// A strip along the top that moves the window when dragged and zooms it on a double click.
struct WindowDragStrip: NSViewRepresentable {
    final class StripView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            // In the Floating layout this strip is the only top edge there is, so it switches layouts too: otherwise there
            // would be no double-click way back out of it.
            if event.clickCount == 2 { MainActor.assumeIsolated { WindowDoubleClick.perform(in: window) } } else { super.mouseDown(with: event) }
        }
    }
    func makeNSView(context: Context) -> NSView { StripView() }
    func updateNSView(_ view: NSView, context: Context) {}
}

/// The floating control pill at the top centre. One capsule, read left to right the way the toolbar would be:
/// back and forward, the site, then reload, the protection shield and the tab count. In the Floating layout it is always there and
/// the site name opens search; when the toolbar has been folded away while reading, the site name brings the toolbar back.
/// How solid the dark pill and handles are: opaque with Increase Contrast or Reduce Transparency, with a clearer edge.
struct ObsidianLook {
    var contrast: ColorSchemeContrast
    var reduceTransparency: Bool
    var solid: Bool { contrast == .increased || reduceTransparency }
    func fill(_ opacity: Double) -> Color { Obsidian.fill.opacity(solid ? 1 : opacity) }
    var edgeWidth: CGFloat { contrast == .increased ? 1.4 : 0.6 }
    var edgeColor: AnyShapeStyle { contrast == .increased ? AnyShapeStyle(Color.white.opacity(0.75)) : AnyShapeStyle(Obsidian.edge) }
}

/// The floating control pill for whichever tab is in front.
struct FloatingPill: View {
    @EnvironmentObject var model: BrowserModel
    var body: some View {
        if let tab = model.active { FloatingPillContent(tab: tab).id(tab.id) }
    }
}

/// What is left of the pill when it is folded away: a small handle at the top. A click opens everything again.
struct PillHandle: View {
    @EnvironmentObject var model: BrowserModel
    @State private var hovering = false
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let look = ObsidianLook(contrast: contrast, reduceTransparency: reduceTransparency)
        Button { model.pillCollapsed = false } label: {
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 24)
                .environment(\.colorScheme, .dark)
                .background(look.fill(0.94), in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous).strokeBorder(look.edgeColor, lineWidth: look.edgeWidth))
                .shadow(color: .black.opacity(0.35), radius: 5, y: 1)
                .scaleEffect(hovering ? 1.08 : 1)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .motion(.spring(response: 0.3, dampingFraction: 0.8), value: hovering)
        .inactiveWindowDimming()
        .help("Show the toolbar")
        .accessibilityLabel("Show the toolbar")
        .accessibilityIdentifier("pill-handle")
    }
}

struct FloatingPillContent: View {
    @EnvironmentObject var model: BrowserModel
    /// Observed, so back, forward, reload and the loading state always show the tab as it is now.
    @ObservedObject var tab: TabController
    @State private var hovering = false
    @State private var dwell: DispatchWorkItem?
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var look: ObsidianLook { ObsidianLook(contrast: contrast, reduceTransparency: reduceTransparency) }

    /// The Floating layout keeps the pill on screen all the time; otherwise it only stands in for a folded toolbar.
    private var permanent: Bool { model.topBarHidden }

    private var label: String {
        guard !tab.isBlank else { return "New Tab" }
        let host = displayHost(tab.url)
        return host.isEmpty ? tab.displayTitle : host
    }

    private func primary() {
        if permanent { model.openSearch() } else { model.expandChrome() }
    }

    var body: some View {
        HStack(spacing: 0) {
            PillControl(symbol: "chevron.left", label: "Back", enabled: tab.canGoBack) { tab.goBack() }
                .contextMenu { NavHistoryItems(tab: tab, back: true) }
            if tab.canGoForward {
                PillControl(symbol: "chevron.right", label: "Forward", enabled: true) { tab.goForward() }
                    .contextMenu { NavHistoryItems(tab: tab, back: false) }
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            siteButton
            PillControl(symbol: tab.isLoading ? "xmark" : "arrow.clockwise", label: tab.isLoading ? "Stop" : "Reload",
                        enabled: !tab.isBlank) {
                if tab.isLoading { tab.stop() } else { tab.reload() }
            }
            if permanent {
                ShieldPill(privacy: model.privacy, host: tab.url?.host, inField: true)
                PillControl(symbol: "chevron.up", label: "Hide the toolbar", enabled: true) { model.pillCollapsed = true }
                Menu { PillMenu() } label: {
                    Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 26)
                        .overlay(alignment: .topTrailing) {
                            if model.downloads.hasUnseenFailure { Circle().fill(.red).frame(width: 7, height: 7).offset(x: -3, y: 4) }
                        }
                        .contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("More").accessibilityLabel(model.downloads.hasUnseenFailure ? "More, a download failed" : "More")
                .accessibilityIdentifier("pill-more")
                if model.tabs.count > 1 {
                    Button { model.overviewVisible ? model.hideOverview() : model.showOverview() } label: {
                        Text("\(model.tabs.count)").font(.system(size: 10.5, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.primary.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 4)
                    .help("Show all tabs")
                    .accessibilityLabel("Show all \(model.tabs.count) tabs")
                    .accessibilityIdentifier("pill-tabs")
                }
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 3)
        .frame(height: 30)
        // The deep black the iPhone uses: white text on near-black, a light along the top edge, a soft shadow.
        .environment(\.colorScheme, .dark)
        .background(look.fill(0.94), in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(look.edgeColor, lineWidth: hovering ? max(0.9, look.edgeWidth) : look.edgeWidth))
        .shadow(color: .black.opacity(hovering ? 0.5 : 0.38), radius: hovering ? 13 : 9, y: 3)
        .inactiveWindowDimming()
        .overlay(alignment: .bottom) {
            LoadingBar(tab: tab, height: 2).id(tab.id).padding(.horizontal, 16).padding(.bottom, 1.5)
        }
        .scaleEffect(hovering ? 1.015 : 1)
        .frame(maxWidth: 480)
        .motion(.spring(response: 0.3, dampingFraction: 0.8), value: hovering)
        .contextMenu { PillMenu() }
        .onHover { inside in
            hovering = inside
            dwell?.cancel()
            // A folded toolbar comes back when the pointer rests on its pill; the Floating layout's pill only reacts to clicks.
            guard inside, !permanent else { return }
            let work = DispatchWorkItem { model.expandChrome() }
            dwell = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
    }

    /// The site's name. In the Floating layout this is not a search field: it only names the site, and clicking it opens the very same
    /// search as the Search button.
    private var siteButton: some View {
        Button(action: primary) {
            HStack(spacing: 7) {
                if tab.isLoading {
                    ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 12, height: 12)
                } else {
                    Image(systemName: tab.isPrivate ? "eye.slash.fill"
                          : (tab.isBlank ? "plus.square" : (tab.isSecure ? "lock.fill" : "globe")))
                        .font(.system(size: 9.5, weight: .semibold))
                }
                Text(label).lineLimit(1).truncationMode(.middle)
                if !permanent {
                    if model.tabs.count > 1 {
                        Text("\(model.tabs.count)").font(.system(size: 10.5, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.12)))
                    }
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                        .opacity(hovering ? 1 : 0.55)
                }
            }
            .padding(.horizontal, 4)
            .frame(minWidth: 70, minHeight: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(permanent ? "Open search (⌘L)" : "Show the toolbar and tabs")
        .accessibilityLabel((tab.isPrivate ? "Private tab. " : "") + (permanent ? "Open search. \(label)" : "Show toolbar and tabs. \(label)"))
        .accessibilityIdentifier("collapsed-pill")
    }
}

/// A round icon button inside the pill.
private struct PillControl: View {
    let symbol: String
    let label: String
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(enabled ? Color.primary : Color.primary.opacity(0.3))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(hovering && enabled ? 0.12 : 0)))
                .keyboardFocusRing(radius: 13)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!enabled)
        .motion(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier("pill-" + symbol)
    }
}

/// Everything the toolbar would have offered, one right-click away.
struct PillMenu: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Button("Back") { model.active?.goBack() }.disabled(!(model.active?.canGoBack ?? false))
        Button("Forward") { model.active?.goForward() }.disabled(!(model.active?.canGoForward ?? false))
        Button("Reload") { model.active?.reload() }.disabled(model.active?.isBlank ?? true)
        Divider()
        Button(model.activeBookmarked ? "Remove Bookmark" : "Bookmark This Page") { model.toggleBookmark() }.disabled(model.active?.isBlank ?? true)
        Button("Copy Link") {
            if let url = model.active?.url?.absoluteString { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url, forType: .string) }
        }
        .disabled(model.active?.isBlank ?? true)
        if let url = model.active?.url, model.active?.isBlank == false { ShareLink("Share…", item: url) }
        Divider()
        Button("New Tab") { model.newTab() }
        Button("Show All Tabs") { model.showOverview() }
        if model.hasEdgeTabs { Button("Show Tabs at the Edge") { model.toggleEdgeTabs() } }
        Button("Bookmarks") { AppCommands.perform("cmd-library-show-bookmarks", model) }
        Button("History") { AppCommands.perform("cmd-library-show-history", model) }
        Button("Downloads") { model.sheet = .downloads }
        Button("Settings…") { SettingsRouter.open() }
        Divider()
        Button("Restore Standard Layout") { model.restoreStandardLayout() }
    }
}

/// The search button: a labelled glass capsule with the shortcut on it, at the top of the window on the side away from the
/// tabs sidebar. It opens the address bar. It floats over the page, so it stays where it is while the page scrolls.
/// The Search pill, and the address field it becomes. One component: a capsule of one fixed height that only grows in width, toward the
/// window's middle, while it is being used. The suggestions are a separate card below it that fades in; nothing else moves.
struct FloatingSearchPill: View {
    @EnvironmentObject var model: BrowserModel
    /// The side the pill is anchored to; it grows away from it.
    var onRight = true
    var expandedWidth: CGFloat = 400
    @State private var hovering = false
    @State private var closeTask: DispatchWorkItem?
    @State private var engineMenuOpen = false

    static let collapsedWidth: CGFloat = 108
    static let height: CGFloat = 30
    private var expanded: Bool { model.floatingAddressVisible }

    var body: some View {
        ZStack {
            collapsedFace.opacity(expanded ? 0 : 1)
            if expanded, let tab = model.active {
                HStack(spacing: 6) {
                    SearchEngineMenu(compact: true)
                    MacOmnibox(tab: tab, address: model.addressBar, floating: true, bare: true)
                    ShieldPill(privacy: model.privacy, host: tab.url?.host, inField: true)
                }
                .padding(.leading, 8).padding(.trailing, 6)
                .transition(.opacity)
            }
        }
        .frame(width: expanded ? expandedWidth : Self.collapsedWidth, height: Self.height)
        // Only the width and the faces' opacity animate: this modifier covers what is above it, and nothing below.
        .motion(.spring(response: 0.34, dampingFraction: 0.92), value: expanded)
        .environment(\.colorScheme, .dark)
        .background(Capsule(style: .continuous).fill(Obsidian.fill.opacity(0.96)))
        .overlay(Capsule(style: .continuous).strokeBorder(expanded ? Theme.accent.opacity(0.7) : Color.clear, lineWidth: 1).allowsHitTesting(false))
        .overlay(Capsule(style: .continuous).strokeBorder(Obsidian.edge, lineWidth: hovering && !expanded ? 0.9 : 0.6).allowsHitTesting(false))
        .shadow(color: .black.opacity(0.38), radius: 9, y: 3)
        .contentShape(Capsule(style: .continuous))
        .onTapGesture { if !expanded { model.openSearch() } }
        .onHover { hovering = $0 }
        .help("Search or enter an address (⌘L)")
        .overlay(alignment: onRight ? .topTrailing : .topLeading) { suggestions }
        .onReceive(model.addressBar.$isEditing.dropFirst().removeDuplicates()) { editing in
            closeTask?.cancel()
            guard !editing else { return }
            // Collapse once editing has really ended: Return, Escape, or a click elsewhere. A short wait first, because choosing a
            // search engine from its menu briefly takes the focus off the field and must not close it.
            let work = DispatchWorkItem {
                if !engineMenuOpen && !model.addressBar.isEditing { model.floatingAddressVisible = false }
            }
            closeTask = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in if expanded { engineMenuOpen = true } }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            guard engineMenuOpen else { return }
            engineMenuOpen = false
            // Back to typing, with the text as it was.
            if !model.addressBar.isEditing { model.floatingFocusTick += 1 }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(expanded ? "floating-address-bar" : "floating-search-pill")
    }

    private var collapsedFace: some View {
        Button { model.openSearch() } label: {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold))
                Text("Search").font(.system(size: 12.5, weight: .medium))
                Text("⌘L").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.1)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .allowsHitTesting(!expanded)
        .accessibilityLabel("Search or enter an address")
        .accessibilityIdentifier("floating-search-button")
    }

    /// Under the pill, aligned to the same edge and the same width: a separate card that fades in at its full size.
    @ViewBuilder private var suggestions: some View {
        if expanded {
            PillSuggestions(address: model.addressBar)
                .frame(width: expandedWidth)
                .offset(y: Self.height + 8)
        }
    }
}

/// Watches the address bar itself (the model does not republish its changes), and shows the card only while there is something to show.
private struct PillSuggestions: View {
    @ObservedObject var address: AddressBarController

    var body: some View {
        if address.isEditing && !address.suggestions.isEmpty {
            SuggestionsOverlay(address: address)
                .transition(.opacity)
        }
    }
}

// MARK: - A control that shows itself when the pointer comes near

/// Tells whether the pointer is near the view it is the background of. It reads the pointer from the window's own mouse-moved events and never takes a click or a hover from what is underneath.
struct PointerProximity: NSViewRepresentable {
    /// How far beyond the view's edges still counts as near.
    var margin: CGSize
    @Binding var near: Bool

    final class ProximityView: NSView {
        var margin = CGSize.zero
        var onChange: (Bool) -> Void = { _ in }
        private var monitor: Any?
        private var last = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard let window else { return }
            window.acceptsMouseMovedEvents = true
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .mouseExited, .leftMouseDragged]) { [weak self] event in
                MainActor.assumeIsolated { self?.update() }
                return event
            }
            update()
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

        private func update() {
            guard let window else { return }
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            let now = bounds.insetBy(dx: -margin.width, dy: -margin.height).contains(point)
            if now != last { last = now; onChange(now) }
        }
    }

    func makeNSView(context: Context) -> ProximityView {
        let view = ProximityView(); view.margin = margin
        view.onChange = { value in DispatchQueue.main.async { near = value } }
        return view
    }
    func updateNSView(_ view: ProximityView, context: Context) { view.margin = margin }
}

/// Invisible at rest, fading in when the pointer is near, while its menu is open, and always when VoiceOver is running (it must stay findable). It stays in place and in the accessibility tree the whole time.
struct FadesUntilPointerNear: ViewModifier {
    var margin = CGSize(width: 110, height: 44)
    /// How visible it is at rest. Above 0 it stays in the accessibility tree and within Full Keyboard Access (SwiftUI drops a fully transparent view from both).
    var restOpacity: Double = 0
    @State private var near = false
    @State private var menuOpen = false

    func body(content: Content) -> some View {
        let shown = near || menuOpen || NSWorkspace.shared.isVoiceOverEnabled
        content
            .opacity(shown ? 1 : restOpacity)
            .motion(.easeOut(duration: 0.18), value: shown)
            .background(PointerProximity(margin: margin, near: $near))
            .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in menuOpen = true }
            .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in menuOpen = false }
    }
}


/// Canvas's only permanent control: a small handle at the top of the page that stays faint until the pointer comes near it. Its menu reaches the address
/// (⌘L), the open tabs (⇧⌘A), a new tab, the Library and the way out of Canvas, so nothing depends on a hidden gesture.
struct CanvasHandle: View {
    @EnvironmentObject var model: BrowserModel
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Menu {
            Button("Open Address…") { model.focusAddressBar() }.keyboardShortcut("l", modifiers: .command)
            Button("Show Open Tabs") { model.showOverview() }
            Button("Search Commands…") { model.paletteVisible = true }
            // What the sidebar would show, on demand: Essentials, pinned tabs and groups.
            let essentials = model.essentials.filter { $0.profile == model.profileName }
            if !essentials.isEmpty {
                Menu("Essentials") { ForEach(essentials) { item in Button(item.title.isEmpty ? item.url : item.title) { model.openEssential(item.id) } } }
            }
            let listed = model.listedTabs(inWorkspace: model.activeWorkspace)
            let pinned = listed.filter(\.pinned)
            if !pinned.isEmpty {
                Menu("Pinned") { ForEach(pinned) { tab in Button(tab.displayTitle) { model.select(tab.id) } } }
            }
            let groups = model.groupNames.filter { name in listed.contains { $0.group == name } }
            if !groups.isEmpty {
                Menu("Groups") {
                    ForEach(groups, id: \.self) { name in
                        Menu(name) { ForEach(listed.filter { $0.group == name }) { tab in Button(tab.displayTitle) { model.select(tab.id) } } }
                    }
                }
            }
            Button("New Tab") { _ = model.newTab() }
            Divider()
            // The Library opens as it does in every layout (docked or floating panel, as chosen in Settings).
            Button("Bookmarks") { AppCommands.perform("cmd-library-show-bookmarks", model) }
            Button("History") { AppCommands.perform("cmd-library-show-history", model) }
            Button(model.downloads.hasUnseenFailure ? "Downloads (a download failed)" : "Downloads") { AppCommands.perform("cmd-library-show-downloads", model) }
            Button("Settings…") { AppCommands.perform("cmd-browser-setu-settings", model) }
            if model.workspaces.count > 1 {
                Menu("Workspaces") {
                    ForEach(model.workspaces) { w in
                        Button(w.name) { model.switchWorkspace(w.name) }.disabled(w.name == model.activeWorkspace)
                    }
                }
            }
            // Extensions have no toolbar here, so they are one menu away (the same list as the toolbar's puzzle-piece menu).
            if model.extensionCenter.hasExtensions {
                Menu("Extensions") {
                    ForEach(model.extensionCenter.extensions) { item in
                        if model.extensionCenter.actions.contains(where: { $0.id == item.id }) {
                            Button(item.name) { model.extensionCenter.perform(actionFor: item.id) }.disabled(!item.enabled)
                        }
                    }
                    Divider()
                    Button("Manage Extensions…") { SettingsRouter.open(.extensions) }
                }
            }
            Divider()
            Button("Leave Canvas") { model.leaveCanvas() }
            Button("Restore Standard Layout") { model.restoreStandardLayout() }.keyboardShortcut("0", modifiers: [.option, .shift, .command])
        } label: {
            HStack(spacing: 6) {
                // The same cue the Focus band gives: private, secure or not secure.
                let cue = model.active.map { $0.isPrivate ? "eye.slash.fill" : ($0.isSecure || $0.isBlank ? "globe" : "exclamationmark.triangle.fill") } ?? "globe"
                Image(systemName: cue).font(.system(size: 10, weight: .semibold))
                Text(model.active.map { displayHost($0.url) } ?? "Canvas").font(.system(size: 11, weight: .medium)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10).frame(height: 24)
            .environment(\.colorScheme, .dark)
            .background(ObsidianLook(contrast: contrast, reduceTransparency: reduceTransparency).fill(0.9), in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous).strokeBorder(ObsidianLook(contrast: contrast, reduceTransparency: reduceTransparency).edgeColor, lineWidth: ObsidianLook(contrast: contrast, reduceTransparency: reduceTransparency).edgeWidth))
            .keyboardFocusRing(radius: 12)
            .contentShape(Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .focusEffectDisabled()
        .fixedSize()
        // Faint, not gone: findable by the keyboard, VoiceOver and a glance, without drawing attention while reading.
        .modifier(FadesUntilPointerNear(restOpacity: 0.32))
        .inactiveWindowDimming()
        .help("Canvas: address, tabs and leaving Canvas")
        .accessibilityLabel("Canvas menu")
        .accessibilityIdentifier("canvas-handle")
    }
}
