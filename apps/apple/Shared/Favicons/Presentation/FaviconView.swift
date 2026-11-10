import SwiftUI

/// A site's icon on a plate, with a placeholder until (or unless) there is one. The one way a surface draws an icon:
/// the plate, the corner shape, the padding, the appearance (a dark variant when the site made one) and the accessibility treatment are decided here, once.
///
/// It reads from `FaviconStore` and never fetches, decodes or saves anything itself.
struct FaviconView<Placeholder: View>: View {
    let url: String
    var size: CGFloat = 54
    var cornerRadius: CGFloat
    @ViewBuilder var placeholder: () -> Placeholder
    /// Observed so a placeholder becomes the icon the moment the icon arrives.
    @ObservedObject private var icons = FaviconStore.shared
    @Environment(\.colorScheme) private var scheme

    init(url: String, size: CGFloat = 54, cornerRadius: CGFloat, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url; self.size = size; self.cornerRadius = cornerRadius; self.placeholder = placeholder
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if let icon = icons.image(forURL: url, scheme: scheme == .dark ? .dark : .light) {
            // An icon the site made for dark backgrounds sits on a dark plate. Any other icon was drawn for a light page, so it keeps a light plate, a little softer in dark mode.
            let madeForDark = scheme == .dark && icons.hasDarkVariant(forURL: url)
            Image(platform: icon).resizable().interpolation(.high).scaledToFit()
                .padding(size * 0.14)
                .frame(width: size, height: size)
                .background(madeForDark ? Color(white: 0.16) : Color(white: scheme == .dark ? 0.90 : 0.96), in: shape)
                .overlay(shape.strokeBorder(madeForDark ? Color.white.opacity(0.14) : Color.black.opacity(scheme == .dark ? 0.30 : 0.08), lineWidth: 0.5))
                // Decorative: the name beside it already says which site this is.
                .accessibilityHidden(true)
        } else {
            // While the icon is being looked up the placeholder carries a skeleton; with no icon to wait for it is just the placeholder (a letter).
            placeholder().skeleton(icons.phase(forURL: url) == .loading)
        }
    }
}
