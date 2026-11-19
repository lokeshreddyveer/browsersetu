import SwiftUI

// The Browser Setu mark and name. The mark is the app icon's artwork (`SetuIcon` in the asset catalogs, the same image as `AppIcon`); the name is set in type.

// "Setu" is Sanskrit for bridge or causeway: Rama Setu is the causeway of stones laid across the sea. The mark is that causeway, a row of stones arching over deep-teal water, with a saffron sun rising behind it.
// Saffron is the old colour of the sun, fire and purity; turmeric ("the golden one") the colour of blessing; the sea is deep teal.
enum SetuPalette {
    static let seaTop = Color(red: 0.075, green: 0.36, blue: 0.40)      // #135C66
    static let seaBottom = Color(red: 0.03, green: 0.17, blue: 0.22)    // #082B38
    static let saffronTop = Color(red: 1.0, green: 0.74, blue: 0.25)    // #FFBD40
    static let saffronBottom = Color(red: 0.96, green: 0.49, blue: 0.16) // #F57D29
    static let cream = Color(red: 1.0, green: 0.95, blue: 0.84)         // #FFF2D6
    static let saffron = LinearGradient(colors: [saffronTop, saffronBottom], startPoint: .top, endPoint: .bottom)
}

/// The Browser Setu icon (the app icon's artwork: an ocean globe with an orbit and an arrow), for beside the name and in the intro film. It is the same image the app
/// icon uses (`SetuIcon` in the asset catalog), clipped to the icon's rounded square so the artwork's pale margin never shows on a dark background.
struct SetuMark: View {
    var size: CGFloat = 28
    /// Kept for the film's call site; the icon artwork has one colour scheme, so it no longer changes anything.
    var teal = false

    var body: some View {
        Image("SetuIcon")
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .scaledToFit()
            // The artwork's own rounded square sits about 1.5 % inside its edges; this clips just inside it.
            .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous).inset(by: size * 0.02))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The icon with the name, in English, set in New York (the system serif): "Browser" regular with a little tracking, "Setu" bold in saffron.
/// `latin: false` leaves the name out, where the page already says it.
struct SetuLockup: View {
    var size: CGFloat = 14
    var latin = true
    /// The round icon beside the name. Off where only the name is wanted (the Setup screen).
    var showsMark = true
    var body: some View {
        HStack(spacing: size * 0.55) {
            if showsMark { SetuMark(size: size * (latin ? 2.7 : 4.2)) }
            if latin {
                HStack(spacing: size * 0.24) {
                    Text("Browser").font(.system(size: size * 1.4, weight: .regular, design: .serif)).tracking(size * 0.02).foregroundStyle(.primary.opacity(0.88))
                    Text("Setu").font(.system(size: size * 1.4, weight: .bold, design: .serif)).tracking(size * 0.02).foregroundStyle(SetuPalette.saffron)
                }
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Browser Setu")
    }
}

/// Soft arches rising from the bottom of a page, like a bridge seen from below. Very quiet: it is a texture, not a picture.
struct SetuArcs: View {
    var body: some View {
        GeometryReader { g in
            Path { p in
                for i in 0..<4 {
                    let f = CGFloat(i)
                    let half = g.size.width * (0.62 - 0.11 * f), rise = g.size.height * (0.46 - 0.085 * f)
                    p.move(to: CGPoint(x: g.size.width / 2 - half, y: g.size.height))
                    p.addQuadCurve(to: CGPoint(x: g.size.width / 2 + half, y: g.size.height), control: CGPoint(x: g.size.width / 2, y: g.size.height - rise * 2))
                }
            }
            .stroke(Theme.accent.opacity(0.10), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// An empty favourites row: ghost tiles joined by a dotted arch, the first one waiting for a site.
struct SetuGhostTiles: View {
    var tile: CGFloat = 46
    var body: some View {
        let gap = tile * 0.42
        ZStack {
            Path { p in
                let total = tile * 5 + gap * 4
                p.move(to: CGPoint(x: tile / 2, y: -2)); p.addQuadCurve(to: CGPoint(x: total - tile / 2, y: -2), control: CGPoint(x: total / 2, y: -tile * 0.9))
            }
            .stroke(Theme.accent.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2, 5]))
            HStack(spacing: gap) {
                ForEach(0..<5, id: \.self) { i in
                    RoundedRectangle(cornerRadius: tile * 0.28, style: .continuous)
                        .strokeBorder(Color.primary.opacity(i == 0 ? 0.45 : 0.22), style: StrokeStyle(lineWidth: 1.3, dash: [4, 4]))
                        .background(RoundedRectangle(cornerRadius: tile * 0.28, style: .continuous).fill(Color.primary.opacity(i == 0 ? 0.08 : 0.04)))
                        .overlay { if i == 0 { Image(systemName: "plus").font(.system(size: tile * 0.34, weight: .semibold)).foregroundStyle(Theme.accent) } }
                        .frame(width: tile, height: tile)
                }
            }
            .padding(.top, tile * 0.26)
        }
        .frame(height: tile * 1.5)
        .accessibilityHidden(true)
    }
}
