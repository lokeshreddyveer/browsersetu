import SwiftUI

/// One of the round buttons that spring out of the folded address pill (the Immersive layout). It sits behind the pill, centred on it, and moves out to its place on the arc
/// when it is shown; it never takes a tap while it is tucked in.
struct PhoneFanButton: View {
    let symbol: String
    let label: String
    let identifier: String
    let visible: Bool
    /// Where it comes to rest, from the middle of the pill.
    let target: CGSize
    let delay: Double
    let action: () -> Void
    static let size: CGFloat = 38
    /// From the middle of the pill to the middle of a button: close enough that the three read as part of the pill, far enough apart not to touch.
    static let radius: CGFloat = 56

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.primary)
                .frame(width: Self.size, height: Self.size).contentShape(Circle().inset(by: -3))
        }
        .buttonStyle(.plain)
        .floatingGlassCapsule(solidity: 0.4)
        .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
        .fanPlacement(visible: visible, target: target, delay: delay)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

/// The tabs button of the fan: the same menu and list as the tabs pill, smaller.
struct PhoneFanTabs: View {
    @Binding var isOpen: Bool
    let visible: Bool
    let target: CGSize
    let delay: Double

    var body: some View {
        PhoneTabsPill(isOpen: $isOpen, size: PhoneFanButton.size)
            .fanPlacement(visible: visible, target: target, delay: delay)
            .accessibilityIdentifier("fan-tabs")
    }
}

/// Where a fan button is for one value, `progress`: 0 tucked into the pill (small, see-through, at its middle), 1 out at its place on the arc. Position, size and fade all follow that
/// one number, so they always agree with each other; a spring that overshoots 1 carries the button a little past its place and settles it back, as a real thing would.
struct FanPlacement: ViewModifier, Animatable {
    var progress: CGFloat
    let target: CGSize
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        // Out along an arc, not a straight line: each button starts a little further round the pill and swings into its place as it grows out, so the three move like one hand opening.
        let radius = hypot(target.width, target.height)
        let end = atan2(-target.height, target.width)
        let angle = end + 0.55 * (1 - progress)
        let p = min(max(progress, 0), 1.1)
        return content
            .offset(x: cos(angle) * radius * p, y: -sin(angle) * radius * p)
            .scaleEffect(0.45 + 0.55 * min(max(progress, 0), 1.06))
            .opacity(Double(min(1, max(0, progress * 2.4))))
    }
}

extension View {
    /// Tucked into the pill or out at its place on the arc. Out is one soft spring with a very short stagger; in is quicker, so the buttons are never in the way of a scroll.
    func fanPlacement(visible: Bool, target: CGSize, delay: Double) -> some View {
        self
            .modifier(FanPlacement(progress: visible ? 1 : 0, target: target))
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
            .animation(visible ? .spring(response: 0.4, dampingFraction: 0.74).delay(delay) : .easeIn(duration: 0.16), value: visible)
    }
}
