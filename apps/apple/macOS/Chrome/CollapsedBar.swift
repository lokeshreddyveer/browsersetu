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
            let inside = TrafficLightZone.contains(window.mouseLocationOutsideOfEventStream, windowHeight: window.frame.height)
            if inside != inCorner { inCorner = inside; apply() }
        }

        private func apply() {
            let show = !folded || inCorner
            // The sidebar header makes room for the lights while they are showing, so nothing is drawn under them.
            TrafficLightsState.shown = show && folded
            NotificationCenter.default.post(name: .trafficLightsVisibility, object: nil, userInfo: ["shown": show && folded])
            for button in buttons {
                if show { button.isHidden = false }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
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

    var body: some View {
        Button { model.pillCollapsed = false } label: {
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 16)
                .environment(\.colorScheme, .dark)
                .background(Obsidian.fill.opacity(0.94), in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous).strokeBorder(Obsidian.edge, lineWidth: 0.6))
                .shadow(color: .black.opacity(0.35), radius: 5, y: 1)
                .scaleEffect(hovering ? 1.08 : 1)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .motion(.spring(response: 0.3, dampingFraction: 0.8), value: hovering)
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
        .background(Obsidian.fill.opacity(0.94), in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(Obsidian.edge, lineWidth: hovering ? 0.9 : 0.6))
        .shadow(color: .black.opacity(hovering ? 0.5 : 0.38), radius: hovering ? 13 : 9, y: 3)
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
        .accessibilityLabel(permanent ? "Open search. \(label)" : "Show toolbar and tabs. \(label)")
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
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
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
        Button("Downloads") { model.sheet = .downloads }
        Button("Settings…") { SettingsRouter.open() }
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
