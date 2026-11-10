import SwiftUI

// The floating player: when a video starts playing, its controls appear on the page in a small panel that can be dragged anywhere inside the window, stays where it was put,
// and is closed with its cross. Behind it nothing is dimmed or blurred; the panel itself takes the colours of the theme and of the page.

/// Where the panel sits, as a point inside the window (the centre of the panel as fractions of the window's width and height), so it keeps its place when the window is resized.
struct FloatingPlayerLayout: Equatable {
    var x: Double
    var y: Double

    static let standard = FloatingPlayerLayout(x: 0.5, y: 0.84)
    static let margin: Double = 10
    /// How solid the panel's surface is: fully, so nothing of the page behind it (its text, a caption) can interfere with the controls. Still in the theme's and the page's colours, nothing blurred.
    static let surfaceOpacity: Double = 1.0
    /// Within this distance of an edge a dropped panel settles against it, so "against the corner" is easy to do and looks tidy.
    static let snapDistance: Double = 16

    init(x: Double, y: Double) { self.x = x; self.y = y }

    /// "0.5,0.84"; anything else is the standard place.
    init(stored: String?) {
        let parts = (stored ?? "").split(separator: ",").compactMap { Double($0) }
        if parts.count == 2, parts.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) { self.init(x: parts[0], y: parts[1]) } else { self = .standard }
    }
    var stored: String { String(format: "%.4f,%.4f", x, y) }

    /// The top-left corner for a panel of `size` in a window of `container`, always fully inside it (a panel larger than the room is pinned to the top-left margin).
    func origin(panel: CGSize, in container: CGSize) -> CGPoint {
        let m = Self.margin
        let maxX = max(m, Double(container.width - panel.width) - m), maxY = max(m, Double(container.height - panel.height) - m)
        let left = x * Double(container.width) - Double(panel.width) / 2, top = y * Double(container.height) - Double(panel.height) / 2
        return CGPoint(x: min(max(left, m), maxX), y: min(max(top, m), maxY))
    }

    /// The layout for a panel whose top-left corner was dragged to `origin`, kept inside the window and settled against an edge when it is close to one.
    static func dropped(origin: CGPoint, panel: CGSize, in container: CGSize, snap: Bool = true) -> FloatingPlayerLayout {
        guard container.width > 0, container.height > 0 else { return .standard }
        let m = margin
        let maxX = max(m, Double(container.width - panel.width) - m), maxY = max(m, Double(container.height - panel.height) - m)
        var left = min(max(Double(origin.x), m), maxX), top = min(max(Double(origin.y), m), maxY)
        if snap {
            if left - m < snapDistance { left = m } else if maxX - left < snapDistance { left = maxX }
            if top - m < snapDistance { top = m } else if maxY - top < snapDistance { top = maxY }
        }
        return FloatingPlayerLayout(x: (left + Double(panel.width) / 2) / Double(container.width), y: (top + Double(panel.height) / 2) / Double(container.height))
    }
}

enum FloatingPlayerRules {
    /// The panel opens when playback starts (not when a page that is already playing is switched to), if the person wants that and it is not already open.
    static func shouldOpen(wasPlaying: Bool, isPlaying: Bool, autoShow: Bool, alreadyOpen: Bool) -> Bool {
        autoShow && !alreadyOpen && isPlaying && !wasPlaying
    }

    /// Switching to another tab: the panel goes unless that tab is playing something it can control.
    static func shouldCloseOnTabChange(open: Bool, newTabIsPlaying: Bool) -> Bool { open && !newTabIsPlaying }

    /// Light text on a dark panel and the other way round, from the panel's own colour.
    static func isDark(red: Double, green: Double, blue: Double) -> Bool {
        0.2126 * red + 0.7152 * green + 0.0722 * blue < 0.5
    }
}

#if os(macOS)
import AppKit

private struct PanelSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// Sits over the page. Opens the panel when the front tab starts playing, and holds it wherever the person drops it.
struct FloatingPlayerLayer: View {
    @EnvironmentObject var model: BrowserModel
    @State private var panelSize = CGSize(width: 380, height: 300)
    @State private var dragOrigin: CGPoint?

    private let space = "floatingPlayerArea"

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.clear.allowsHitTesting(false)
                if let tab = model.active { PlaybackWatcher(tab: tab).id(tab.id) }
                if model.floatingPlayerOpen {
                    let origin = dragOrigin ?? model.floatingPlayerLayout.origin(panel: panelSize, in: geo.size)
                    FloatingPlayerCard(drag: drag(in: geo.size), reset: { place(.standard, animated: true) })
                        .background(GeometryReader { Color.clear.preference(key: PanelSizeKey.self, value: $0.size) })
                        .onPreferenceChange(PanelSizeKey.self) { if $0.width > 0 { panelSize = $0 } }
                        .offset(x: origin.x, y: origin.y)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottom)))
                }
            }
            .coordinateSpace(name: space)
        }
        .motion(.easeOut(duration: 0.18), value: model.floatingPlayerOpen)
        .onChange(of: model.activeID) { _, _ in
            if FloatingPlayerRules.shouldCloseOnTabChange(open: model.floatingPlayerOpen, newTabIsPlaying: model.active?.playingAudio ?? false) { model.closeFloatingPlayer() }
        }
    }

    private func place(_ layout: FloatingPlayerLayout, animated: Bool) {
        if animated { withAnimation(.easeOut(duration: 0.2)) { model.floatingPlayerLayout = layout } } else { model.floatingPlayerLayout = layout }
    }

    private func drag(in container: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(space))
            .onChanged { value in
                let start = model.floatingPlayerLayout.origin(panel: panelSize, in: container)
                let base = dragStart ?? start
                dragStart = base
                dragOrigin = CGPoint(x: base.x + value.translation.width, y: base.y + value.translation.height)
            }
            .onEnded { value in
                let base = dragStart ?? model.floatingPlayerLayout.origin(panel: panelSize, in: container)
                let end = CGPoint(x: base.x + value.translation.width, y: base.y + value.translation.height)
                dragStart = nil
                dragOrigin = nil
                withAnimation(.easeOut(duration: 0.16)) { model.floatingPlayerLayout = .dropped(origin: end, panel: panelSize, in: container) }
            }
    }

    @State private var dragStart: CGPoint?
}

/// Opens the panel on the rising edge of the front tab's playback.
private struct PlaybackWatcher: View {
    @ObservedObject var tab: TabController
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Color.clear.frame(width: 0, height: 0).allowsHitTesting(false)
            .onChange(of: tab.playingAudio) { was, now in
                if FloatingPlayerRules.shouldOpen(wasPlaying: was, isPlaying: now, autoShow: model.autoShowPlayer, alreadyOpen: model.floatingPlayerOpen) { model.openFloatingPlayer() }
            }
    }
}

/// The panel: a slim handle to drag it by, and the player controls on a surface in the colours of the theme and the page.
struct FloatingPlayerCard<Drag: Gesture>: View {
    @EnvironmentObject var model: BrowserModel
    let drag: Drag
    let reset: () -> Void

    private var surface: (color: Color, dark: Bool) {
        if let tint = model.active?.tint {
            // The page's own colour, pulled toward the theme's so a bright page does not leave a glaring panel.
            let base = ThemeState.raised.flatMap { NSColor($0).usingColorSpace(.sRGB) }
            let r = base.map { 0.55 * tint.red + 0.45 * Double($0.redComponent) } ?? tint.red
            let g = base.map { 0.55 * tint.green + 0.45 * Double($0.greenComponent) } ?? tint.green
            let b = base.map { 0.55 * tint.blue + 0.45 * Double($0.blueComponent) } ?? tint.blue
            return (Color(red: r, green: g, blue: b), FloatingPlayerRules.isDark(red: r, green: g, blue: b))
        }
        if let raised = ThemeState.raised, let c = NSColor(raised).usingColorSpace(.sRGB) {
            return (raised, FloatingPlayerRules.isDark(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent)))
        }
        return (Color(nsColor: .windowBackgroundColor), NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }

    var body: some View {
        let look = surface
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        VStack(spacing: 0) {
            // The handle: drag to move, double-click to bring the panel back to its usual place.
            Capsule().fill(Color.primary.opacity(0.28)).frame(width: 38, height: 4)
                .frame(maxWidth: .infinity).frame(height: 20).contentShape(Rectangle())
                .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
                .gesture(drag)
                .simultaneousGesture(TapGesture(count: 2).onEnded { reset() })
                .accessibilityLabel("Move the player controls")
                .accessibilityHint("Drag to move. Double-click to put it back in its usual place.")
            EnhancedPlayerPanel(player: model.player, showsChrome: false) { model.closeFloatingPlayer() }
                .padding(.horizontal, 6).padding(.bottom, 6)
        }
        .frame(width: 372)
        // Almost solid: at 0.88 the page's own text showed through behind the title and the buttons. Still no blur, and still in the theme's and the page's colours.
        .background(look.color.opacity(FloatingPlayerLayout.surfaceOpacity), in: shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
        .environment(\.colorScheme, look.dark ? .dark : .light)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Player controls")
    }
}
#endif
