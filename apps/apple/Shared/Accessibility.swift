import SwiftUI

/// Text that follows the person's text size setting (iPhone and iPad) but never grows past `limit` times its design size, because the bars and rows around it have fixed heights.
/// On the Mac, where the system has no text-size slider, it is the plain size.
struct ScaledFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let base: CGFloat
    private let weight: Font.Weight
    private let design: Font.Design
    private let limit: CGFloat

    init(_ size: CGFloat, weight: Font.Weight, design: Font.Design, limit: CGFloat) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: .body)
        base = size; self.weight = weight; self.design = design; self.limit = limit
    }

    func body(content: Content) -> some View {
        content.font(.system(size: min(size, base * limit), weight: weight, design: design))
    }
}

extension View {
    func scaledFont(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default, limit: CGFloat = 1.5) -> some View {
        modifier(ScaledFont(size, weight: weight, design: design, limit: limit))
    }

    /// A hairline outline that gets stronger when the person asks for more contrast (Increase Contrast on the Mac, Darker Colors on iPhone).
    func hairline<S: InsettableShape>(_ shape: S, opacity: Double = 0.12, width: CGFloat = 0.5) -> some View {
        modifier(HairlineBorder(shape: shape, opacity: opacity, width: width))
    }
}

struct HairlineBorder<S: InsettableShape>: ViewModifier {
    let shape: S
    let opacity: Double
    let width: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let more = contrast == .increased
        content.overlay(shape.strokeBorder(Color.primary.opacity(more ? max(opacity, 0.55) : opacity), lineWidth: more ? max(width, 1) : width))
    }
}

/// A clear ring around a control when the keyboard has moved focus to it (Tab with Full Keyboard Access on the Mac, an external keyboard on iPad), and nothing for a mouse
/// or finger. Put it on the inside of a button's label and switch the button's own focus effect off, so there is one ring, in the browser's accent colour.
struct KeyboardFocusRing: ViewModifier {
    let radius: CGFloat
    @Environment(\.isFocused) private var focused

    func body(content: Content) -> some View {
        content
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.accent, lineWidth: 2).padding(-3).opacity(focused ? 1 : 0).allowsHitTesting(false))
            .motion(.easeOut(duration: 0.12), value: focused)
    }
}

extension View {
    func keyboardFocusRing(radius: CGFloat = 8) -> some View { modifier(KeyboardFocusRing(radius: radius)) }
}
