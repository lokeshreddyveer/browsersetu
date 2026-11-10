import SwiftUI

/// Where the Downloads button is, in the window, so a download that just began can fly to it. Marked on the button; read once at the top of the window.
struct DownloadsAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = nextValue() ?? value }
}

extension View {
    func marksDownloadsButton() -> some View { anchorPreference(key: DownloadsAnchorKey.self, value: .bounds) { $0 } }

    /// A small animation from where the person acted toward the Downloads button when they start a download. Not for queued, scheduled or resumed downloads, and
    /// at most one every couple of seconds however many start at once. With Reduce Motion (or animation off) nothing moves.
    func downloadFlight(_ coordinator: DownloadCoordinator) -> some View {
        overlayPreferenceValue(DownloadsAnchorKey.self) { anchor in
            DownloadFlightLayer(coordinator: coordinator, anchor: anchor).allowsHitTesting(false)
        }
    }
}

/// The pure rule for when a flight may start.
enum DownloadFlightPolicy {
    static let minimumGap: TimeInterval = 2.0
    static func allows(now: Date, lastFlight: Date) -> Bool { now.timeIntervalSince(lastFlight) >= minimumGap }
}

private struct DownloadFlightLayer: View {
    @ObservedObject var coordinator: DownloadCoordinator
    let anchor: Anchor<CGRect>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lastFlight = Date.distantPast
    @State private var flight: Flight?

    private struct Flight: Identifiable { let id = UUID(); let start: CGPoint? }

    var body: some View {
        GeometryReader { proxy in
            if let flight, let anchor {
                let target = proxy[anchor]
                FlightDot(from: clamp(flight.start ?? defaultStart(proxy.size), in: proxy.size), to: CGPoint(x: target.midX, y: target.midY))
                    .id(flight.id)
            }
        }
        .onChange(of: coordinator.userStarts) { _, _ in begin() }
    }

    private func begin() {
        guard !reduceMotion, MotionStyle.current != .off, anchor != nil, DownloadFlightPolicy.allows(now: Date(), lastFlight: lastFlight) else { return }
        lastFlight = Date()
        let started = Flight(start: Self.pointerInWindow())
        flight = started
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            if flight?.id == started.id { flight = nil }
        }
    }

    private func defaultStart(_ size: CGSize) -> CGPoint { CGPoint(x: size.width / 2, y: size.height * 0.62) }

    private func clamp(_ p: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: min(max(p.x, 12), max(12, size.width - 12)), y: min(max(p.y, 12), max(12, size.height - 12)))
    }

    /// Where the pointer is in the window (the Mac); nil on a touch screen.
    private static func pointerInWindow() -> CGPoint? {
        #if os(macOS)
        guard let window = NSApp.keyWindow, let content = window.contentView else { return nil }
        let p = window.mouseLocationOutsideOfEventStream
        guard content.bounds.contains(NSPoint(x: p.x, y: p.y)) else { return nil }
        return CGPoint(x: p.x, y: content.bounds.height - p.y)
        #else
        return nil
        #endif
    }
}

/// A small disc with a down arrow that leaves `from`, falls in an arc to `to`, shrinks and fades as it arrives. Horizontal and vertical movement use different
/// curves, which bends the path.
private struct FlightDot: View {
    let from: CGPoint
    let to: CGPoint
    @State private var arrived = false

    var body: some View {
        Circle().fill(Theme.accent)
            .frame(width: 22, height: 22)
            .overlay(Image(systemName: "arrow.down").font(.system(size: 11, weight: .bold)).foregroundStyle(.white))
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            .scaleEffect(arrived ? 0.45 : 1)
            .opacity(arrived ? 0.15 : 1)
            .offset(y: arrived ? to.y - from.y : 0)
            .animation(.easeIn(duration: 0.55), value: arrived)
            .offset(x: arrived ? to.x - from.x : 0)
            .animation(.easeOut(duration: 0.55), value: arrived)
            .position(from)
            .onAppear { arrived = true }
            .accessibilityHidden(true)
    }
}
