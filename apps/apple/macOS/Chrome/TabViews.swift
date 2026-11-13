import AppKit
import SwiftUI

/// The horizontal strip's keyboard focus, shared with its tabs so the arrow keys can move between them. Only the Classic strip provides it; the other tab presentations leave it nil and keep their behavior.
struct TabStripFocusKey: EnvironmentKey {
    static let defaultValue: FocusState<UInt64?>.Binding? = nil
}
extension EnvironmentValues {
    var tabStripFocus: FocusState<UInt64?>.Binding? {
        get { self[TabStripFocusKey.self] }
        set { self[TabStripFocusKey.self] = newValue }
    }
    /// The order the keyboard walks the tabs in, when it is not the order of the tab list (the Sidebar shows pinned tabs, then open tabs, then groups). Nil: the model's order, as before.
    var tabStripOrder: [UInt64]? {
        get { self[TabStripOrderKey.self] }
        set { self[TabStripOrderKey.self] = newValue }
    }
    /// A vertical list: Up and Down move between the tabs as Left and Right do in a strip. Off everywhere else.
    var tabStripVertical: Bool {
        get { self[TabStripVerticalKey.self] }
        set { self[TabStripVerticalKey.self] = newValue }
    }
}
struct TabStripOrderKey: EnvironmentKey { static let defaultValue: [UInt64]? = nil }
struct TabDropPinsKey: EnvironmentKey { static let defaultValue = false }
struct TabDropUnpinsKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// Pinned tiles in a list that pins by drop: a tab dropped on one is placed there and becomes pinned. Off everywhere else (a tab dropped on a tab only moves).
    var tabDropPins: Bool {
        get { self[TabDropPinsKey.self] }
        set { self[TabDropPinsKey.self] = newValue }
    }
    /// Regular rows in a list that unpins by drop: a pinned tab dropped on one is placed there and is no longer pinned.
    var tabDropUnpins: Bool {
        get { self[TabDropUnpinsKey.self] }
        set { self[TabDropUnpinsKey.self] = newValue }
    }
}
struct TabStripVerticalKey: EnvironmentKey { static let defaultValue = false }

// MARK: - Shared pieces

/// Favicon slot: a spinner while loading, the private mark in private tabs, otherwise the site's icon (`SiteTile`: the cached favicon from `FaviconStore`, or a
/// letter tile while there is none).
struct TabFavicon: View {
    @ObservedObject var tab: TabController
    var size: CGFloat = 16

    var body: some View {
        ZStack {
            if let panel = tab.panelSheet {
                Image(systemName: panel == .bookmarks ? "book.fill" : panel == .history ? "clock.fill" : "arrow.down.circle.fill").font(.system(size: size * 0.8)).foregroundStyle(Theme.accent)
            } else if tab.isSettingsPage {
                Image(systemName: "gearshape.fill").font(.system(size: size * 0.8)).foregroundStyle(Theme.accent)
            } else if tab.isLoading {
                ProgressView().controlSize(.mini).scaleEffect(0.8)
            } else if tab.isPrivate {
                Image(systemName: "eye.slash.fill").font(.system(size: size * 0.7)).foregroundStyle(Theme.privateAccent)
            } else if tab.isShowingError {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: size * 0.7)).foregroundStyle(.orange)
            } else {
                SiteTile(url: tab.url?.absoluteString ?? "", title: tab.title, size: size).opacity(tab.isBlank ? 0.35 : 1)
            }
        }
        .frame(width: size, height: size)
        // A small red dot while the page is using the camera or the microphone.
        .overlay(alignment: .topTrailing) {
            if tab.usesCamera || tab.usesMicrophone {
                Circle().fill(Color.red).frame(width: max(6, size * 0.4), height: max(6, size * 0.4))
                    .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
                    .offset(x: 3, y: -3)
                    .transition(.scale.combined(with: .opacity))
                    .help(tab.usesCamera ? "This page is using your camera" : "This page is using your microphone")
            }
        }
        .motion(.easeOut(duration: 0.18), value: tab.usesCamera || tab.usesMicrophone)
        .accessibilityHidden(true)
    }
}

/// The picture that follows the pointer while a tab is dragged: the site mark and name on a glass card with an accent edge.
struct TabDragCard: View {
    @ObservedObject var tab: TabController
    var body: some View {
        HStack(spacing: 8) {
            SiteTile(url: tab.url?.absoluteString ?? "", title: tab.title, size: 20)
            Text(tab.displayTitle).font(.system(size: 13, weight: .medium)).lineLimit(1).frame(maxWidth: 180, alignment: .leading)
        }
        .padding(.horizontal, 12).frame(height: 36)
        .themedFill(in: Capsule(), fallback: .regularMaterial)
        .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.9), lineWidth: 1.5))
        .shadow(color: Theme.accent.opacity(0.35), radius: 10, y: 4)
        .padding(10)
    }
}

struct TabCloseButton: View {
    @EnvironmentObject var model: BrowserModel
    let action: () -> Void
    /// How strong the cross is at rest, and the wash behind it. The defaults are every other layout's; One Row's selected tab asks for a little more so it can be found on the field.
    var restOpacity: Double = 0.55
    var restWash: Double = 0
    @State private var hovering = false
    var body: some View {
        // The second click of a double-click is not a second Close: when the first one closes a tab the next tab slides under the pointer, and its Close would be hit by the same double-click. The system's own click
        // count tells them apart (no timer of our own); a key press has no click count, so it is always taken.
        Button {
            if let event = NSApp.currentEvent, event.type == .leftMouseUp || event.type == .leftMouseDown, event.clickCount >= 2 { return }
            action()
        } label: {
            Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(hovering ? 0.95 : restOpacity))
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.16 : restWash)))
                // Drawn at 16 pt, but taken in a 24 pt square: a small glyph needs a comfortable target.
                .contentShape(Rectangle().inset(by: -4))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Close Tab")
        .accessibilityLabel("Close tab")
        .opacity(model.hideTabCloseButtons ? 0 : 1)
        .allowsHitTesting(!model.hideTabCloseButtons)
        .accessibilityHidden(model.hideTabCloseButtons)
        .motion(.easeOut(duration: 0.16), value: model.hideTabCloseButtons)
    }
}

/// Selected tabs are raised rounded cards; hovered ones get a quiet wash; idle ones sit flat on the chrome.
private struct TabBackground: ViewModifier {
    let selected: Bool
    let hovering: Bool
    let radius: CGFloat
    var outlined = false
    /// With Increase Contrast on, the selected tab gets an outline and the hover wash is stronger, so neither depends on a faint fill.
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        let high = contrast == .increased
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(selected ? Color.selectedTab : (hovering ? Color.primary.opacity(high ? 0.16 : 0.07) : Color.clear))
            )
            .overlay {
                if high && selected && outlined {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.primary.opacity(0.55), lineWidth: 1).allowsHitTesting(false)
                }
            }
            .motion(.easeOut(duration: 0.16), value: selected)
            .motion(.easeOut(duration: 0.12), value: hovering)
    }
}

private extension View {
    func tabBackground(selected: Bool, hovering: Bool, radius: CGFloat = Radius.tab, outlined: Bool = false) -> some View {
        modifier(TabBackground(selected: selected, hovering: hovering, radius: radius, outlined: outlined))
    }
}

/// Knows whether a tab is being dragged, from the mouse itself: a preview must not appear (or stay) while a tab is dragged. It only watches drag movement and the button coming up; it never acts on a click.
@MainActor private enum TabDragWatch {
    static var hoveredCancel: (id: UInt64, cancelPreview: () -> Void)?
    /// True from the first drag movement of a pressed mouse until the button is released.
    static var dragging = false { didSet { if dragging != oldValue { NotificationCenter.default.post(name: .tabDragChanged, object: nil, userInfo: ["dragging": dragging]) } } }
    private static var monitor: Any?
    static func install() {
        guard monitor == nil else { return }
        // A plain pointer move also ends it: the system drag session can take the mouse-up, which would otherwise leave "dragging" set.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .mouseMoved, .keyDown]) { event in
            MainActor.assumeIsolated {
                // Escape closes a hover preview first (the top layer), and is still passed on.
                if event.type == .keyDown { if event.keyCode == 53 { hoveredCancel?.cancelPreview() } }
                else if event.type == .leftMouseDragged { if !dragging { dragging = true; hoveredCancel?.cancelPreview() } } else { dragging = false }
            }
            return event
        }
    }
}

/// Where a tab is on screen, so the preview can be placed under it.
private final class PreviewAnchorBox { weak var view: NSView? }
private struct PreviewAnchor: NSViewRepresentable {
    let box: PreviewAnchorBox
    func makeNSView(context: Context) -> NSView { let v = NSView(); v.setAccessibilityElement(false); box.view = v; return v }
    func updateNSView(_ view: NSView, context: Context) { box.view = view }
}

/// A panel that can never become the key or main window: showing the preview must not take the keyboard from the browser window. (The preview used to be a popover, which does; the window's next click
/// then only brought the window back and the tab under the pointer never heard it.) It ignores the mouse, so every click goes through it.
private final class TabPreviewPanelWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The one hover preview: a small card under the tab, in a panel attached to the browser window.
@MainActor private final class TabPreviewPresenter {
    static let shared = TabPreviewPresenter()
    private var panel: TabPreviewPanelWindow?
    private var owner: UInt64?

    enum Side { case below, trailing, leading }

    func show(tab: TabController, beside anchor: NSView?, side: Side) {
        guard let anchor, let window = anchor.window else { return }
        ChromeTrace.log("PREVIEW show tab \(tab.id)")
        hide()
        let host = NSHostingView(rootView: TabPreviewCard(tab: tab)
            .accessibilityElement(children: .contain).accessibilityIdentifier("tab-preview")
            .background(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.regularMaterial),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)))
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let panel = TabPreviewPanelWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.contentView = host
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.ignoresMouseEvents = true; panel.isReleasedWhenClosed = false
        panel.level = window.level; panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.appearance = window.effectiveAppearance
        // Under the tab, centred on it, and kept inside the window's screen.
        let frame = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        var origin: NSPoint
        switch side {
        case .below: origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY - size.height - 6)
        case .trailing: origin = NSPoint(x: frame.maxX + 6, y: frame.midY - size.height / 2)
        case .leading: origin = NSPoint(x: frame.minX - size.width - 6, y: frame.midY - size.height / 2)
        }
        if let screen = window.screen ?? NSScreen.main {
            // Kept inside the window where it fits (the part of it on screen), otherwise inside the screen; on all four sides.
            let screenArea = screen.visibleFrame
            let windowArea = window.frame.intersection(screenArea)
            let area = windowArea.width >= size.width + 16 && windowArea.height >= size.height + 16 ? windowArea : screenArea
            origin.x = min(max(origin.x, area.minX + 8), area.maxX - size.width - 8)
            origin.y = min(max(origin.y, area.minY + 8), area.maxY - size.height - 8)
        }
        panel.setFrameOrigin(origin)
        window.addChildWindow(panel, ordered: .above)
        self.panel = panel; owner = tab.id
    }

    func hide(owner id: UInt64? = nil) {
        if let id, owner != id { return }
        guard let panel else { return }
        ChromeTrace.log("PREVIEW hide owner \(owner.map(String.init) ?? "none")")
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.panel = nil; owner = nil
    }
}

/// Keeps a window from starting a window drag while the pointer is over a tab in the title bar band. `NSWindow.isMovable` is window-wide state, so this is the only owner of it for tabs: it remembers what the window had,
/// counts the tabs that want it still, and gives it back when the last one lets go, when the window or app stops being the active one, when the window closes, and after any mouse-up whose pointer is no longer over a tab
/// that held it (a drag that ended elsewhere, or was cancelled, sends no hover exit).
@MainActor
final class TitleBarTabHold {
    static let shared = TitleBarTabHold()
    private struct WeakView { weak var view: NSView? }
    private struct Held { weak var window: NSWindow?; var original: Bool; var owners: [UInt64: WeakView] }
    private var held: [ObjectIdentifier: Held] = [:]
    private var observers: [NSObjectProtocol] = []
    private var mouseUp: Any?

    /// How far from the top of the window a tab can be and still count as being in the title bar band.
    private static let band: CGFloat = 60

    /// Windows currently held still (for tests and diagnostics).
    var heldCount: Int { held.count }

    /// Returns whether the hold is in force.
    @discardableResult
    func hold(owner: UInt64, view: NSView) -> Bool {
        guard let window = view.window, let content = window.contentView else { return false }
        let inWindow = view.convert(view.bounds, to: nil)
        guard content.bounds.height - inWindow.maxY < Self.band else { return false }
        let key = ObjectIdentifier(window)
        if held[key] == nil {
            held[key] = Held(window: window, original: window.isMovable, owners: [:])
            window.isMovable = false
        }
        held[key]?.owners[owner] = WeakView(view: view)
        install()
        return true
    }

    func release(owner: UInt64) {
        for key in Array(held.keys) {
            held[key]?.owners[owner] = nil
            if held[key]?.owners.isEmpty == true { restore(key) }
        }
    }

    /// Gives every window back, whatever is still hovering (the pointer takes it again on its next move).
    func releaseAll() { for key in Array(held.keys) { restore(key) } }

    private func restore(_ key: ObjectIdentifier) {
        guard let entry = held.removeValue(forKey: key) else { return }
        entry.window?.isMovable = entry.original
        if held.isEmpty { uninstall() }
    }

    private func install() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification, NSWindow.didChangeScreenNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { _ in MainActor.assumeIsolated { TitleBarTabHold.shared.releaseAll() } })
        }
        mouseUp = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { event in
            DispatchQueue.main.async { TitleBarTabHold.shared.reconcile() }
            return event
        }
    }

    private func uninstall() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let mouseUp { NSEvent.removeMonitor(mouseUp) }
        mouseUp = nil
    }

    /// After a mouse-up: keep a hold only for a tab the pointer is still over.
    private func reconcile() {
        for key in Array(held.keys) {
            guard var entry = held[key], let window = entry.window else { restore(key); continue }
            let point = window.mouseLocationOutsideOfEventStream
            entry.owners = entry.owners.filter { _, box in
                guard let view = box.view, view.window === window else { return false }
                return view.convert(view.bounds, to: nil).contains(point)
            }
            held[key] = entry
            if entry.owners.isEmpty { restore(key) }
        }
    }
}

private struct TabInteractions: ViewModifier {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController
    @Environment(\.tabStripFocus) private var stripFocus
    @Environment(\.tabStripOrder) private var stripOrder
    @Environment(\.tabStripVertical) private var stripVertical
    @Environment(\.tabDropPins) private var dropPins
    @Environment(\.tabDropUnpins) private var dropUnpins
    @State private var dropTargeted = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var showPreview = false
    @State private var pointerInside = false
    @State private var anchorBox = PreviewAnchorBox()
    /// A Reversed layout puts the tabs in the title bar's drag band, where the window server starts a window drag on mouse-down at the same time as the tab's own drag, so a tab could not be reordered. It follows
    /// `isMovable`, but only if that is already off when the press begins, so the window is held still while the pointer is over a tab (not over empty strip space or the room beside the lights, which still drag it).
    /// `isMovable` belongs to the whole window, so the hold is shared and counted (`TitleBarTabHold`), applies only to a tab drawn in the top band, and is lifted on every way the pointer can stop being over the tab.
    private func holdWindowStill(_ hold: Bool) {
        if hold {
            guard model.layoutPreset.tabsOnTop || model.layoutPreset == .inline, let view = anchorBox.view else { return }
            _ = TitleBarTabHold.shared.hold(owner: tab.id, view: view)
        } else {
            TitleBarTabHold.shared.release(owner: tab.id)
        }
    }

    /// Ends a pending or shown preview: the delayed task is cancelled, so it cannot show it later.
    private func cancelPreview() {
        hoverTask?.cancel(); hoverTask = nil
        if showPreview { showPreview = false }
        TabPreviewPresenter.shared.hide(owner: tab.id)
    }

    private func moveFocus(_ direction: TabChipRules.Direction) -> KeyPress.Result {
        guard let stripFocus else { return .ignored }
        // At the first or last tab the key does nothing, but it is still taken: passed on, it would move the keyboard out of the strip.
        guard let target = TabChipRules.neighbor(of: tab.id, in: stripOrder ?? model.visibleTabs.map(\.id), direction) else { return .handled }
        stripFocus.wrappedValue = target
        return .handled
    }

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            // A tab put to sleep (or ended by its page process) looks quieter until it is opened again.
            .opacity(tab.isDiscarded ? 0.62 : 1)
            .onDisappear { holdWindowStill(false) }
            // Resting the pointer on a tab shows a preview card after a short delay; moving away or pressing hides it.
            .onHover { inside in
                pointerInside = inside
                holdWindowStill(inside)
                if inside {
                    TabDragWatch.hoveredCancel = (tab.id, { cancelPreview() })
                    TabDragWatch.install()
                } else if TabDragWatch.hoveredCancel?.id == tab.id { TabDragWatch.hoveredCancel = nil }
                cancelPreview()
                guard inside, model.hoverPreviews, !tab.isInternalPage else { return }
                let id = tab.id
                hoverTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(Int(model.hoverDelay * 1000)))
                    // The delay can outlast the situation that started it: ask again before showing.
                    guard !Task.isCancelled, TabChipRules.previewMayAppear(settingOn: model.hoverPreviews, tabExists: model.tabs.contains { $0.id == id }, isInternalPage: tab.isInternalPage,
                                                                           pointerInside: pointerInside, appActive: NSApp.isActive, dragging: TabDragWatch.dragging,
                                                                           modalUIVisible: model.paletteVisible || model.overviewVisible || model.sheet != nil) else { return }
                    showPreview = true
                    let side: TabPreviewPresenter.Side = model.effectiveTabLayout == .sidebar ? (model.sidebarPosition == .left ? .trailing : .leading) : .below
                    TabPreviewPresenter.shared.show(tab: tab, beside: anchorBox.view, side: side)
                }
            }
            .background(PreviewAnchor(box: anchorBox))
            // The preview ends with whatever made it meaningful: the app or window leaving the front, a menu opening, another workspace, layout or profile, the setting turning off, the tab leaving.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in cancelPreview() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in cancelPreview() }
            .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in cancelPreview() }
            .onChange(of: model.paletteVisible) { _, _ in cancelPreview() }
            .onChange(of: model.overviewVisible) { _, _ in cancelPreview() }
            .onChange(of: model.sheet?.id) { _, _ in cancelPreview() }
            .onChange(of: model.activeWorkspace) { _, _ in cancelPreview() }
            .onChange(of: model.layoutPreset) { _, _ in cancelPreview() }
            .onChange(of: model.profileName) { _, _ in cancelPreview() }
            .onChange(of: model.hoverPreviews) { _, on in if !on { cancelPreview() } }
            .onDisappear { cancelPreview(); if TabDragWatch.hoveredCancel?.id == tab.id { TabDragWatch.hoveredCancel = nil } }
            .onTapGesture { cancelPreview(); model.select(tab.id) }
            // Off unless chosen: the first click still selects at once, the second closes.
            .simultaneousGesture(TapGesture(count: 2).onEnded { if model.doubleClickClosesTab, !tab.isLocked, !AudioBadge.tappedJustNow { model.closeTab(id: tab.id) } })
            .keyboardFocusRing(radius: 8)
            .focusable()
            .focusEffectDisabled()
            .modifier(StripFocus(id: tab.id, binding: stripFocus))
            .onKeyPress(.return) { model.select(tab.id); return .handled }
            .onKeyPress(.space) { model.select(tab.id); return .handled }
            // Arrow keys move between the tabs of the Classic strip only, and only while a tab itself has the keyboard (the address bar and the page never reach this).
            .onKeyPress(.upArrow) { stripVertical ? moveFocus(.previous) : .ignored }
            .onKeyPress(.downArrow) { stripVertical ? moveFocus(.next) : .ignored }
            .onKeyPress(.leftArrow) { moveFocus(.previous) }
            .onKeyPress(.rightArrow) { moveFocus(.next) }
            .onKeyPress(.home) { moveFocus(.first) }
            .onKeyPress(.end) { moveFocus(.last) }
            .accessibilityAction { model.select(tab.id) }
            .accessibilityActions {
                if !tab.isLocked { Button("Close tab") { model.closeTab(id: tab.id) } }
                if tab.playingAudio || tab.muted { Button(tab.muted ? "Unmute tab" : "Mute tab") { tab.setMuted(!tab.muted) } }
                if model.canMoveTab(tab, by: -1) { Button(stripVertical ? "Move tab up" : "Move tab left") { model.moveTabAlong(tab, by: -1) } }
                if model.canMoveTab(tab, by: 1) { Button(stripVertical ? "Move tab down" : "Move tab right") { model.moveTabAlong(tab, by: 1) } }
            }
            .contextMenu { TabMenuItems(tab: tab) }
            // A middle click closes the tab, as in the sidebar.
            .overlay(MiddleClickCatcher { if !tab.isLocked { model.closeTab(id: tab.id) } })
            // What you carry is a small card of its own: the site's mark, its name and a glow in the accent colour.
            .draggable(String(tab.id)) { TabDragCard(tab: tab) }
            // The tab it will land in front of lifts and lights up in the accent colour.
            .overlay {
                RoundedRectangle(cornerRadius: Radius.tab, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: 1.5)
                    .background(RoundedRectangle(cornerRadius: Radius.tab, style: .continuous).fill(Theme.accent.opacity(0.14)))
                    .opacity(dropTargeted ? 1 : 0).allowsHitTesting(false)
            }
            .scaleEffect(dropTargeted ? 1.03 : 1)
            .motion(.spring(response: 0.25, dampingFraction: 0.75), value: dropTargeted)
            .dropDestination(for: String.self) { items, _ in
                guard let raw = items.first, let dragged = UInt64(raw), dragged != tab.id else { return false }
                guard model.acceptDroppedTab(dragged, before: tab.id) else { return false }
                if let moved = model.tabs.first(where: { $0.id == dragged }) {
                    if dropPins, tab.pinned, !moved.pinned { model.togglePin(moved) }
                    else if dropUnpins, !tab.pinned, moved.pinned { model.togglePin(moved) }
                }
                return true
            } isTargeted: { dropTargeted = $0 }
            // A link or address dropped on a tab opens in a new tab beside it.
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first, url.scheme == "http" || url.scheme == "https" else { return false }
                model.openTab(url: url, isPrivate: tab.isPrivate)
                return true
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(tab.spokenTitle)
            .accessibilityValue(TabChipRules.spokenState(locked: tab.isLocked, pinned: tab.pinned, playing: tab.playingAudio, muted: tab.muted, asleep: tab.isDiscarded, isPrivate: tab.isPrivate) ?? "")
            .accessibilityAddTraits(tab.id == model.activeID ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier("tab-chip")
    }
}

/// Ties a tab to the strip's focus (when it has one): the tab shows a focus ring while it holds the keyboard. Without a strip focus it does nothing.
private struct StripFocus: ViewModifier {
    let id: UInt64
    let binding: FocusState<UInt64?>.Binding?
    /// The ring is for the keyboard: a tab that took focus because it was clicked (it is then the active tab) shows no outline. A focus change with no mouse press behind it (the keyboard, or the strip restoring focus
    /// after Return) keeps or shows it.
    @State private var viaKeyboard = false
    func body(content: Content) -> some View {
        if let binding {
            content
                .focused(binding, equals: id)
                .onChange(of: binding.wrappedValue == id) { _, focused in
                    guard focused, let type = NSApp.currentEvent?.type else { return }
                    if [.leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown].contains(type) { viaKeyboard = false }
                    else if [.keyDown, .keyUp, .flagsChanged].contains(type) { viaKeyboard = true }
                }
                .overlay { if binding.wrappedValue == id && viaKeyboard { Capsule().strokeBorder(Theme.accent, lineWidth: 2).allowsHitTesting(false).transition(.opacity) } }
        } else {
            content
        }
    }
}

extension View {
    func tabInteractions(_ tab: TabController) -> some View { modifier(TabInteractions(tab: tab)) }
}

// MARK: - Horizontal strip

struct HorizontalTab: View {
    /// Room kept at each side of the title group: the Close button (5 pt in, 16 pt wide) stays clear of the title, and nothing more. It was 26, which left about 49 pt for a title in the
    /// narrowest tab (measured: titles read "Page…"); at 22 the same tab gives the title 8 pt more.
    static let contentInset: CGFloat = 22
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController
    let selected: Bool
    let width: CGFloat
    @State private var hovering = false

    var body: some View {
        // The title (with its icon) is centred in the tab; the close button waits at the leading edge.
        ZStack {
            HStack(spacing: 5) {
                TabFavicon(tab: tab, size: 14)
                Text(tab.displayTitle)
                    .font(.system(size: 12, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.62))
                    .lineLimit(1).truncationMode(.tail)
            }
            .padding(.horizontal, Self.contentInset)
            HStack {
                if tab.isLocked {
                    // Closing is refused for a locked tab, so no Close control: a quiet lock stands where it would be (the tab menu unlocks it).
                    Image(systemName: "lock.fill").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 16, height: 16).help("Locked").accessibilityHidden(true)
                } else if TabChipRules.showsCloseButton(locked: false, selected: selected, hovering: hovering) {
                    TabCloseButton { model.closeTab(id: tab.id) }
                }
                Spacer(minLength: 0)
                // At the trailing edge, so the centred title does not move when sound starts or stops.
                AudioBadge(tab: tab)
            }
            .padding(.leading, 5).padding(.trailing, 6)
        }
        .frame(width: width, height: model.density.stripPillHeight)
        .tabBackground(selected: selected, hovering: hovering, radius: model.density.stripPillHeight / 2, outlined: true)
        .stripGroupMarker(tab, model: model)
        .transition(.scale(scale: 0.88).combined(with: .opacity))
        .onHover { hovering = $0 }
        .modifier(TabTooltip(title: tab.displayTitle))
        .tabInteractions(tab)
    }
}

/// Pinned tabs are icon tiles at the start of the strip.
struct PinnedTab: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        TabFavicon(tab: tab, size: 16)
            .frame(width: 36, height: model.density.stripPillHeight)
            .tabBackground(selected: selected, hovering: hovering, radius: model.density.stripPillHeight / 2, outlined: true)
            .overlay(alignment: .bottomTrailing) {
                if tab.isLocked { Image(systemName: "lock.fill").font(.system(size: 7, weight: .bold)).foregroundStyle(.secondary).padding(.trailing, 5).padding(.bottom, 2).accessibilityHidden(true) }
            }
            .onHover { hovering = $0 }
            .modifier(TabTooltip(title: tab.displayTitle))
            .tabInteractions(tab)
    }
}

/// An open tab in the Minimal layout that is not selected: its icon, which turns into a close button when the pointer is on it.
struct CompactTab: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController
    @State private var hovering = false

    /// The favicon is the whole target and stays where it is: pointing at it only washes the cell, so a click always means "select". (It used to turn into a Close button under the pointer, which closed
    /// the tab when the click was meant to open it.) Closing is by middle click, the tab menu, Cmd-W after selecting it, or the accessibility action; the selected tab has its own Close button.
    var body: some View {
        TabFavicon(tab: tab, size: 16)
            .frame(width: 36, height: model.density.stripPillHeight)
            .tabBackground(selected: false, hovering: hovering, radius: model.density.stripPillHeight / 2, outlined: true)
            .stripGroupMarker(tab, model: model)
            // A tab playing sound shows the shared mute control in its corner (it mutes; it never selects or closes the tab).
            .overlay(alignment: .topTrailing) { AudioBadge(tab: tab).scaleEffect(0.85).offset(x: 3, y: -3) }
            .overlay(alignment: .bottomTrailing) {
                if tab.isLocked { Image(systemName: "lock.fill").font(.system(size: 7, weight: .bold)).foregroundStyle(.secondary).padding(.trailing, 5).padding(.bottom, 2).accessibilityHidden(true) }
            }
            .onHover { hovering = $0 }
            .modifier(TabTooltip(title: tab.displayTitle))
            .tabInteractions(tab)
    }
}

struct HorizontalTabStrip: View {
    @EnvironmentObject var model: BrowserModel
    @FocusState private var focusedTab: UInt64?
    /// The tabs no longer fit at their narrowest: the All Tabs menu is shown.
    @State private var overflowing = false
    /// The narrowest a regular tab gets before the strip scrolls. 120 left about 49 pt for the title (measured at 520 and 640 pt windows: "Page I…", "Page…"); 132 with the
    /// slimmer inset gives about 69 pt, enough for a short title such as "Page Inbox".
    static let minTab: CGFloat = 132
    static let gap: CGFloat = 4
    /// Tabs share the whole row, so a few tabs are wide.
    static let maxTab: CGFloat = 800

    var body: some View {
        GeometryReader { geo in
            let tabs = model.visibleTabs
            let pinned = tabs.filter(\.pinned)
            // Every group inline: its label, then its tabs (none while it is collapsed).
            let items = model.stripItems(tabs.filter { !$0.pinned })
            let regular = items.compactMap { item -> TabController? in if case .tab(let t) = item { t } else { nil } }
            let labels = items.count - regular.count
            let plusWidth: CGFloat = 32
            let reserved = CGFloat(pinned.count) * (36 + Self.gap) + plusWidth + 16 + CGFloat(labels) * (StripGroupLabel.estimatedWidth + Self.gap)
            let available = geo.size.width - reserved
            let raw = regular.isEmpty ? Self.maxTab : (available - CGFloat(regular.count) * Self.gap) / CGFloat(regular.count)
            let tabWidth = min(Self.maxTab, max(Self.minTab, raw))

            HStack(spacing: Self.gap) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Self.gap) {
                            ForEach(pinned) { PinnedTab(tab: $0, selected: $0.id == model.activeID).id($0.id) }
                            if !pinned.isEmpty && !regular.isEmpty { Capsule().fill(Color.primary.opacity(0.14)).frame(width: 1, height: 14).padding(.horizontal, 3) }
                            ForEach(items) { item in
                                switch item {
                                case .tab(let tab): HorizontalTab(tab: tab, selected: tab.id == model.activeID, width: tabWidth).id(tab.id)
                                case .group(let name, let count, let collapsed): StripGroupLabel(name: name, count: count, collapsed: collapsed, height: model.density.stripPillHeight).id(item.id)
                                }
                            }
                        }
                        .motion(.spring(response: 0.34, dampingFraction: 0.86), value: items.map(\.id))
                        .motion(.spring(response: 0.34, dampingFraction: 0.86), value: pinned.map(\.id))
                        .padding(.leading, 8).padding(.trailing, 2)
                    }
                    // Never any scroller, whatever the system's scroll-bar setting: with always-visible scroll bars (a mouse attached) the strip's own room was cut by the scroller's height and the row sat about 8 pt high.
                    .scrollIndicators(.never)
                    .onChange(of: model.activeID) { _, id in if let id { animated(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } } }
                    // The tab the arrow keys reach is brought into view; if the focused tab leaves the strip, the keyboard goes to the tab in front.
                    .onChange(of: focusedTab) { _, id in if let id { animated(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } } }
                    .onChange(of: model.visibleTabs.map(\.id)) { _, ids in
                        if let focused = focusedTab, !ids.contains(focused) { focusedTab = model.activeID }
                    }
                    // The tab in front stays in view when the window is resized (the row can become too narrow for it) and when the strip first appears (a restored window, a layout change).
                    .onChange(of: geo.size.width) { _, _ in if let id = model.activeID { proxy.scrollTo(id) } }
                    .onAppear { if let id = model.activeID { proxy.scrollTo(id) } }
                    // A tab dragged to either end of a strip that does not fit scrolls it that way.
                    .modifier(StripEdgeScroll(ids: tabs.map(\.id), proxy: proxy))
                }
            }
            .frame(height: geo.size.height)
            .inactiveWindowDimming()
            .onChange(of: raw < Self.minTab, initial: true) { _, full in if overflowing != full { overflowing = full } }
            // The arrow keys walk the tabs as drawn (a collapsed group's tabs are not on screen).
            .environment(\.tabStripOrder, pinned.map(\.id) + regular.map(\.id))
        }
        .frame(height: model.density.stripHeight)
        // On the strip itself, before the insets are added: an identifier set outside it would replace the group chip's, the All Tabs menu's and New Tab's own.
        .accessibilityIdentifier("tab-bar")
        // When the tabs no longer fit, every one stays one click away (not only by scrolling); then New Tab.
        .stripSide(.trailing) {
            HStack(spacing: 2) { if overflowing { StripOverflowMenu() }; newTabButton }.padding(.trailing, 6).inactiveWindowDimming()
        }
        // The Essentials sit at the left end of the strip; the tabs share the width that is left.
        .stripSide(.leading) { StripLeadingGroup(essentialsSize: 26) }
        .background(WindowDragRegion())
        .acceptsDroppedTabs(model)
        .environment(\.tabStripFocus, $focusedTab)
    }

    private var newTabButton: some View {
        ChromeButton(symbol: "plus", help: "New Tab", identifier: "new-tab-inline") { model.newTab() }
            .scaleEffect(0.9)
    }
}

// MARK: - Compact strip

/// A single slim row: the selected tab shows its title, the others show only their icon.
struct CompactTabStrip: View {
    @EnvironmentObject var model: BrowserModel
    @FocusState private var focusedTab: UInt64?

    var body: some View {
        if model.singleRow { EmptyView() } else { strip.chromeTrace("CompactTabStrip").transition(.identity) }
    }

    /// The width of all the tabs, and of the room they scroll in: the All Tabs menu is there exactly when the first is more than the second.
    @State private var contentWidth: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0
    private var overflowing: Bool { viewportWidth > 0 && contentWidth > viewportWidth + 1 }

    private var strip: some View {
        HStack(spacing: 2) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(model.stripItems(model.visibleTabs)) { item in
                            switch item {
                            case .tab(let tab):
                                Group {
                                    if tab.id == model.activeID && !tab.pinned {
                                        HorizontalTab(tab: tab, selected: true, width: 170)
                                    } else if tab.pinned {
                                        PinnedTab(tab: tab, selected: tab.id == model.activeID)
                                    } else {
                                        CompactTab(tab: tab)
                                    }
                                }
                                .id(tab.id)
                            case .group(let name, let count, let collapsed):
                                StripGroupLabel(name: name, count: count, collapsed: collapsed, height: model.density.stripPillHeight).id(item.id)
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .background(GeometryReader { g in Color.clear.preference(key: StripContentWidthKey.self, value: g.size.width) })
                    // The arrow keys walk the tabs as drawn (a collapsed group's tabs are not on screen).
                    .environment(\.tabStripOrder, model.stripShownTabs(model.visibleTabs).map(\.id))
                }
                // The selected tab is always brought into view (it was not: with many tabs it sat off screen), when it changes, when the row changes, and when the window is resized.
                .onAppear { if let id = model.activeID { proxy.scrollTo(id) } }
                .onChange(of: model.activeID) { _, id in
                    if let id { animated(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
                    // Selecting a compact tab swaps it for the wider selected-tab view, which ends the keyboard focus that was on it: put it back, so the arrow keys keep working after Return.
                    if let focused = focusedTab { focusedTab = nil; DispatchQueue.main.async { focusedTab = focused } }
                }
                .onChange(of: model.visibleTabs.map(\.id)) { _, ids in
                    if let focused = focusedTab, !ids.contains(focused) { focusedTab = model.activeID }
                    if let id = model.activeID { proxy.scrollTo(id) }
                }
                .onChange(of: model.windowWidth) { _, _ in if let id = model.activeID { proxy.scrollTo(id) } }
                .onChange(of: focusedTab) { _, id in if let id { animated(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } } }
                .modifier(StripEdgeScroll(ids: model.visibleTabs.map(\.id), proxy: proxy))
            }
            .background(GeometryReader { g in Color.clear.preference(key: StripViewportWidthKey.self, value: g.size.width) })
        }
        .onPreferenceChange(StripContentWidthKey.self) { contentWidth = $0 }
        .onPreferenceChange(StripViewportWidthKey.self) { viewportWidth = $0 }
        .inactiveWindowDimming()
        .frame(height: model.density.stripHeight)
        // On the strip itself, before the insets are added (as in Classic): an identifier set outside it would replace the group chip's, All Tabs' and New Tab's own.
        .accessibilityIdentifier("tab-bar")
        .stripSide(.trailing) {
            HStack(spacing: 2) {
                // Measured: the tabs are wider than the room they scroll in.
                if overflowing { StripOverflowMenu() }
                ChromeButton(symbol: "plus", help: "New Tab", identifier: "new-tab-inline") { model.newTab() }.scaleEffect(0.85)
            }
            .inactiveWindowDimming()
        }
        // The same group chip as Classic: with a group chosen, the strip shows only its tabs, and this is the visible way to see which group and to leave it.
        .stripSide(.leading) { StripLeadingGroup(essentialsSize: 24) }
        .background(WindowDragRegion())
        .acceptsDroppedTabs(model)
        .environment(\.tabStripFocus, $focusedTab)
    }
}

// MARK: - Vertical rows (sidebar)

/// The small arrow on a tab that has tabs opened from it: it folds and unfolds that branch of the tree.
struct TreeFoldButton: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController
    var body: some View {
        if model.hasTreeChildren(tab) {
            let folded = model.collapsedTreeTabs.contains(tab.id)
            Button { animated(.easeOut(duration: 0.18)) { model.toggleTreeBranch(tab) } } label: {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(folded ? 0 : 90)).frame(width: 12, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel(folded ? "Show tabs opened from this one" : "Hide tabs opened from this one")
        }
    }
}

/// The count on the first tab of a stack of one website's tabs; it folds and unfolds the stack.
struct StackBadge: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController
    var body: some View {
        if let head = model.stackHead(tab) {
            Button { animated(.easeOut(duration: 0.18)) { model.toggleStack(head.key) } } label: {
                HStack(spacing: 3) {
                    Text("\(head.count)").font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold)).rotationEffect(.degrees(head.folded ? 0 : 90))
                }
                .padding(.horizontal, 6).frame(height: 16)
                .background(Capsule().fill(Theme.accent.opacity(0.2))).foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain).help(head.folded ? "Show the \(head.count) tabs from this site" : "Fold the \(head.count) tabs from this site")
            .accessibilityLabel(head.folded ? "Show stacked tabs" : "Fold stacked tabs")
        }
    }
}

/// The card that appears when the pointer rests on a tab.
struct TabPreviewCard: View {
    @ObservedObject var tab: TabController
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let data = tab.snapshot, let image = Image(platformData: data) {
                Color.clear.frame(width: 240, height: 140)
                    .overlay(alignment: .top) { image.resizable().scaledToFill() }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            Text(tab.displayTitle).font(.system(size: 12, weight: .semibold)).lineLimit(2).frame(width: 240, alignment: .leading)
            Text(tab.url?.host ?? "").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(10)
    }
}

struct VerticalTabRow: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            // A tab opened from another sits one step in from it when the tab tree is on, with a fold arrow where it has tabs under it.
            if model.tabTree { Color.clear.frame(width: CGFloat(model.treeDepth(of: tab)) * 14, height: 1) }
            TreeFoldButton(tab: tab)
            TabFavicon(tab: tab)
            Text(tab.displayTitle)
                .font(.system(size: 13, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.68))
                .lineLimit(1).truncationMode(.tail)
            StackBadge(tab: tab)
            AudioBadge(tab: tab)
            Spacer(minLength: 0)
            if tab.isLocked { Image(systemName: "lock.fill").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).help("Locked") }
            else if hovering || selected { TabCloseButton { model.closeTab(id: tab.id) } }
        }
        .padding(.horizontal, 8)
        .frame(height: model.density.tabRowHeight)
        .tabBackground(selected: selected, hovering: hovering, radius: Radius.item)
        .transition(.scale(scale: 0.95).combined(with: .opacity))
        .onHover { hovering = $0 }
        .modifier(TabTooltip(title: tab.displayTitle))
        .tabInteractions(tab)
    }
}

/// Pinned tabs in the sidebar: a grid of icon tiles.
struct PinnedTile: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController
    let selected: Bool
    var large = false
    @State private var hovering = false

    var body: some View {
        TabFavicon(tab: tab, size: large ? 24 : 20)
            .frame(maxWidth: .infinity).frame(height: large ? 48 : model.density.pinnedTileHeight)
            .tabBackground(selected: selected, hovering: hovering, radius: large ? Radius.item : 12)
            .background(RoundedRectangle(cornerRadius: large ? Radius.item : 12, style: .continuous).fill(selected ? Color.clear : Color.fieldFill))
            .onHover { hovering = $0 }
            .modifier(TabTooltip(title: tab.displayTitle))
            .tabInteractions(tab)
    }
}


/// The page-title tooltip, only when the hover preview card is off: with both, hovering a tab shows two things at once.
struct TabTooltip: ViewModifier {
    @EnvironmentObject var model: BrowserModel
    let title: String
    func body(content: Content) -> some View { content.help(model.hoverPreviews ? "" : title) }
}


extension Notification.Name {
    /// A tab drag started or ended (`userInfo["dragging"]`).
    static let tabDragChanged = Notification.Name("BrowserSetu.tabDragChanged")
}

/// The two ends of a horizontal tab strip: thin drop zones just outside the scrolling tabs (they never cover a tab, so they take no clicks from one). A tab
/// dragged onto either one scrolls the strip that way, one tab at a time, with a soft accent edge to show it; letting go there does nothing.
struct StripEdgeScroll: ViewModifier {
    let ids: [UInt64]
    let proxy: ScrollViewProxy

    func body(content: Content) -> some View {
        HStack(spacing: 0) {
            StripEdgeZone(ids: ids, proxy: proxy, leading: true)
            content
            StripEdgeZone(ids: ids, proxy: proxy, leading: false)
        }
    }
}

private struct StripEdgeZone: View {
    let ids: [UInt64]
    let proxy: ScrollViewProxy
    let leading: Bool
    @EnvironmentObject var model: BrowserModel
    @State private var targeted = false
    @State private var cursor: Int?
    @State private var timer: Timer?

    var body: some View {
        LinearGradient(colors: [Theme.accent.opacity(targeted ? 0.35 : 0), .clear], startPoint: leading ? .leading : .trailing, endPoint: leading ? .trailing : .leading)
            .frame(width: 12)
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { _, _ in stop(); return false } isTargeted: { on in on ? start() : stop() }
            .accessibilityHidden(true)
            .onDisappear { stop() }
    }

    private func start() {
        stop()
        targeted = true
        cursor = ids.firstIndex(of: model.activeID ?? 0) ?? (leading ? ids.count - 1 : 0)
        timer = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: true) { _ in MainActor.assumeIsolated { step() } }
        step()
    }

    private func step() {
        guard !ids.isEmpty, let current = cursor else { return }
        let next = min(ids.count - 1, max(0, current + (leading ? -1 : 1)))
        cursor = next
        animated(.easeOut(duration: 0.18)) { proxy.scrollTo(ids[next], anchor: leading ? .leading : .trailing) }
    }

    private func stop() { timer?.invalidate(); timer = nil; targeted = false; cursor = nil }
}

/// A full tab strip's list of every tab in it, in order (the one in front marked): the way to reach a tab scrolled out of sight without a trackpad.
struct StripOverflowMenu: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Menu {
            ForEach(model.visibleTabs) { tab in
                Button { model.select(tab.id) } label: {
                    if tab.id == model.activeID { Label(tab.displayTitle, systemImage: "checkmark") }
                    else if tab.pinned { Label(tab.displayTitle, systemImage: "pin") }
                    else { Text(tab.displayTitle) }
                }
            }
        } label: {
            // The spoken name and identifier sit on the label: a menu button takes its name from its label, and one set on the Menu came out empty.
            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 22, height: 22).contentShape(Rectangle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("All tabs, \(model.visibleTabs.count)")
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("All Tabs")
        .accessibilityIdentifier("tab-overflow-menu")
    }
}


/// What sits at the start of every horizontal tab strip (Classic, Minimal, One Row and the Reversed layouts): the group chip, then the Essentials, each with
/// room of its own and a hairline before the tabs, so the group the strip is showing reads as a heading for the tabs, not as one of them.
struct StripLeadingGroup: View {
    @EnvironmentObject var model: BrowserModel
    let essentialsSize: CGFloat

    private var hasGroupChip: Bool { !model.groupNames.isEmpty || !model.activeGroup.isEmpty }

    var body: some View {
        HStack(spacing: 10) {
            ClassicGroupChip()
            if hasGroupChip && !model.essentials.isEmpty && !model.isGuest {
                Rectangle().fill(Color.primary.opacity(0.14)).frame(width: 1, height: 16)
            }
            EssentialsInline(size: essentialsSize)
        }
        .padding(.leading, 10)
        .inactiveWindowDimming()
        // Clear room between the chip and the first tab, with the same hairline the Essentials use.
        .padding(.trailing, hasGroupChip && model.essentials.isEmpty ? 6 : 0)
        .overlay(alignment: .trailing) {
            if hasGroupChip && (model.essentials.isEmpty || model.isGuest) {
                Rectangle().fill(Color.primary.opacity(0.14)).frame(width: 1, height: 16)
            }
        }
        .padding(.trailing, hasGroupChip ? 6 : 0)
    }
}


/// A tab group's label in a horizontal strip, before its tabs, as Chrome and Edge draw it: a small rounded label in the group's colour (dark text on the light
/// colours, white on the rest), and a band of the same colour along the bottom that runs on under the group's tabs. Collapsed, it shows how many tabs it holds.
/// A click opens or collapses the group; a tab dropped on it joins the group; its menu has the group's commands.
struct StripGroupLabel: View {
    @EnvironmentObject var model: BrowserModel
    let name: String
    let count: Int
    let collapsed: Bool
    let height: CGFloat
    /// What the strip reserves for a label when it works out the tabs' width.
    static let estimatedWidth: CGFloat = 96
    @State private var hovering = false
    @State private var dropTargeted = false
    @Environment(\.colorSchemeContrast) private var contrast

    private var groupColor: GroupColor? { model.groupColor(name) ?? GroupColor.automatic(for: name) }
    private var fill: Color { groupColor?.color ?? Color.primary.opacity(0.16) }
    /// Text that reads on the fill: dark on yellow and orange, white on the other colours, the normal text colour on an uncoloured group.
    private var ink: Color {
        guard let groupColor else { return Color.primary.opacity(0.85) }
        return groupColor.prefersDarkText ? Color.black.opacity(0.85) : Color.white
    }
    private var labelHeight: CGFloat { max(20, height - 8) }

    var body: some View {
        Button { animated(.easeOut(duration: 0.2)) { model.toggleStripGroup(name) } } label: {
            HStack(spacing: 5) {
                Text(GroupPath.leaf(name)).font(.system(size: 11.5, weight: .semibold)).lineLimit(1).truncationMode(.tail).frame(maxWidth: 128, alignment: .leading)
                if collapsed {
                    Text("\(count)").font(.system(size: 10, weight: .bold)).monospacedDigit()
                        .padding(.horizontal, 5).frame(minWidth: 16, minHeight: 15)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(ink.opacity(0.18)))
                }
                if hovering || collapsed {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(.system(size: 7, weight: .bold)).opacity(0.75)
                        .transition(.opacity)
                }
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 9).frame(height: labelHeight)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(fill))
            .overlay {
                if contrast == .increased || dropTargeted {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(dropTargeted ? Theme.accent : Color.primary.opacity(0.6), lineWidth: dropTargeted ? 2 : 1)
                }
            }
            .scaleEffect(dropTargeted ? 1.05 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .frame(height: height)
            // The group's band starts under its label and runs on under its tabs (`stripGroupMarker`).
            .overlay(alignment: .bottom) { if !collapsed { GroupBand(color: groupColor?.color ?? Color.secondary).padding(.leading, 4).padding(.trailing, -4) } }
        }
        .buttonStyle(.plain)
        .padding(.leading, 6)          // a little room between a group and the tab before it
        .onHover { hovering = $0 }
        .motion(.easeOut(duration: 0.14), value: hovering)
        .motion(.easeOut(duration: 0.16), value: dropTargeted)
        .help(collapsed ? "\(name): \(count) tab\(count == 1 ? "" : "s"). Click to show them." : "\(name). Click to collapse the group. Drop a tab here to add it.")
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let id = UInt64(raw) else { return false }
            return model.acceptDroppedTab(id, intoGroup: name)
        } isTargeted: { dropTargeted = $0 }
        .contextMenu {
            Button(collapsed ? "Expand Group" : "Collapse Group") { model.toggleStripGroup(name) }
            Button("New Tab in Group") { model.newTab(inGroup: name) }
            Button("Show Only This Group") { model.selectGroup(name) }
            Divider()
            Button("Rename Group…") {
                let model = model, group = name
                Task { @MainActor in
                    if let new = await Dialogs.promptText(title: "Rename Group", message: "New name for “\(group)”.", placeholder: group), !new.isEmpty { model.renameGroup(group, to: new) }
                }
            }
            Menu("Group Colour") {
                ForEach(GroupColor.allCases) { color in
                    Button { model.setGroupColor(name, color) } label: { if model.groupColor(name) == color { Label(color.title, systemImage: "checkmark") } else { Text(color.title) } }
                }
                Divider()
                Button("No Colour") { model.setGroupColor(name, nil) }
            }
            Divider()
            Button("Ungroup") { model.deleteGroup(name) }
            let closable = model.closableTabs(inGroup: name).count
            Button("Close \(closable) Tab\(closable == 1 ? "" : "s") in Group", role: .destructive) { model.closeStripGroup(name) }.disabled(closable == 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Group \(GroupPath.leaf(name)), \(count) tab\(count == 1 ? "" : "s")")
        .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.toggleStripGroup(name) }
        .accessibilityIdentifier("strip-group-label")
    }
}

/// The band of a group's colour along the bottom of its label and tabs: one continuous line (each piece reaches over the gap to the next).
struct GroupBand: View {
    let color: Color
    var body: some View {
        RoundedRectangle(cornerRadius: 1.25, style: .continuous).fill(color).frame(height: 2.5).allowsHitTesting(false).accessibilityHidden(true)
    }
}

extension View {
    /// A tab in a group, in a strip that shows groups inline, carries the group's band along its bottom edge, reaching over the gap to its neighbours so the
    /// band reads as one line under the whole group.
    func stripGroupMarker(_ tab: TabController, model: BrowserModel) -> some View {
        overlay(alignment: .bottom) {
            if model.stripGroupsInline, !tab.group.isEmpty, !tab.pinned {
                GroupBand(color: (model.groupColor(tab.group) ?? GroupColor.automatic(for: tab.group)).color).padding(.horizontal, -3)
            }
        }
    }
}

extension View {
    /// Puts something beside a tab strip, at its start or end, taking its own room: the tabs scroll only within what is left (a safe-area inset let scrolled tabs
    /// slide under the group chip and the Essentials).
    func stripSide<Side: View>(_ edge: HorizontalEdge, @ViewBuilder _ side: () -> Side) -> some View {
        let piece = side()
        return HStack(spacing: 0) {
            if edge == .leading { piece }
            self
            if edge == .trailing { piece }
        }
    }
}


/// The width of a strip's tabs, and of the room they scroll in (read from the drawn views, not estimated).
struct StripContentWidthKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
struct StripViewportWidthKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
