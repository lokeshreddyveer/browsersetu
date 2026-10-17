import SwiftUI

/// What a loading indicator shows, as plain state so it can be tested: it starts small, only ever moves forward while a
/// page loads, runs to the end when the page is done, then fades out and resets.
struct LoadingProgress: Equatable {
    private(set) var fraction: Double = 0
    private(set) var visible = false

    /// The smallest bar worth showing: enough to read as "something is happening" the moment loading starts.
    static let minimum = 0.08

    mutating func begin(progress: Double) {
        visible = true
        fraction = max(fraction, min(1, max(progress, Self.minimum)))
    }

    /// WebKit's estimate can wobble; the bar never goes backwards.
    mutating func update(progress: Double) {
        guard visible else { return }
        fraction = max(fraction, min(1, progress))
    }

    mutating func finish() {
        guard visible else { return }
        fraction = 1
    }

    /// After the fade-out: ready for the next page.
    mutating func hide() {
        visible = false
        fraction = 0
    }
}

/// A slim, rounded bar with a soft glow in the accent colour (violet in a private tab). It is drawn where the layout wants it:
/// along the top edge of the page, or along the bottom edge of the floating pill. It never sits inside the address bar.
struct LoadingBar: View {
    @ObservedObject var tab: TabController
    var height: CGFloat = 2.5
    @State private var state = LoadingProgress()
    @State private var hideTask: DispatchWorkItem?

    private var color: Color { tab.isPrivate ? Theme.privateAccent : Theme.accent }

    var body: some View {
        GeometryReader { geo in
            Capsule(style: .continuous)
                .fill(LinearGradient(colors: [color.opacity(0.35), color, color], startPoint: .leading, endPoint: .trailing))
                .frame(width: max(height, geo.size.width * state.fraction), height: height)
                .shadow(color: color.opacity(0.6), radius: 3, y: 0)
                .opacity(state.visible ? 1 : 0)
        }
        .frame(height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .motion(.easeOut(duration: 0.45), value: state.fraction)
        .motion(.easeOut(duration: 0.3), value: state.visible)
        .onAppear { if tab.isLoading { begin() } }
        .onChange(of: tab.isLoading) { _, loading in loading ? begin() : finish() }
        .onChange(of: tab.progress) { _, progress in if tab.isLoading { state.update(progress: progress) } }
    }

    private func begin() {
        hideTask?.cancel()
        state.begin(progress: tab.progress)
    }

    private func finish() {
        state.finish()
        hideTask?.cancel()
        let work = DispatchWorkItem { state.hide() }
        hideTask = work
        // Let it run to the end and be seen before it fades.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
}
