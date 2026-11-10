import SwiftUI

/// A skeleton: the shape of something that is on its way, with a slow band of light crossing it. For a tile, a row or a line that is waiting for its content.
///
/// - Shown only if the wait lasts: nothing appears for the first 0.2 seconds, so content that arrives at once (a cached icon) never flashes a skeleton.
/// - With Reduce Motion on, it is a still, slightly dimmed shape.
/// - The band is a gradient moving across, drawn only while the skeleton is on screen.
struct SkeletonShimmer: ViewModifier {
    var active: Bool
    var delay: Duration = .milliseconds(200)
    @State private var shown = false
    @State private var sweep = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .overlay {
                if active && shown {
                    GeometryReader { geo in
                        let band = LinearGradient(colors: [.clear, Color.white.opacity(scheme == .dark ? 0.16 : 0.38), .clear], startPoint: .leading, endPoint: .trailing)
                        Rectangle().fill(reduceMotion ? AnyShapeStyle(Color.white.opacity(0.10)) : AnyShapeStyle(band))
                            .frame(width: reduceMotion ? geo.size.width : geo.size.width * 0.6)
                            .offset(x: reduceMotion ? 0 : (sweep ? geo.size.width : -geo.size.width * 0.6))
                    }
                    .clipped()
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .onAppear { guard !reduceMotion else { return }; withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { sweep = true } }
                    .onDisappear { sweep = false }
                }
            }
            .task(id: active) {
                shown = false
                guard active else { return }
                try? await Task.sleep(for: delay)
                if !Task.isCancelled { withAnimation(.easeOut(duration: 0.2)) { shown = true } }
            }
            .accessibilityHidden(active)
    }
}

extension View {
    /// Marks a view as waiting for its content: see `SkeletonShimmer`.
    func skeleton(_ active: Bool) -> some View { modifier(SkeletonShimmer(active: active)) }
}
