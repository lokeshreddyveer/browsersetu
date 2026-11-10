import SwiftUI

// The Browser Setu mark and name. "Setu" is Sanskrit and Hindi for bridge, so the mark is a shield holding a bridge: a deck, the arch that meets it at its middle, two piers.
// Drawn from paths (the editable source is docs/brand/browser-setu-mark.svg, the same geometry), so it is sharp at any size, takes the accent colour, and needs no image file.

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

/// The Browser Setu icon, for beside the name (24 to 48 pt). Three layers: a saffron protective ring, the world (deep-blue ocean, golden continents, India facing us), and a large shield with a lock.
/// Land is Natural Earth (public domain). Source: docs/brand/browser-setu-icon-bubble.svg, same geometry. A vector: sharp on any display, in light and dark.
struct SetuMark: View {
    var size: CGFloat = 28
    /// The film's own colours (ice teal, deep teal, highlight) in place of the app icon's gold and blue.
    var teal = false
    private static let tealMap: [UInt32: UInt32] = [0xFFE08C: 0xDFF3F8, 0xF6A73A: 0x8FD0E3, 0xE8782A: 0x397E96, 0x2F86D8: 0x397E96, 0x125AA8: 0x1F5870, 0x0A2C66: 0x10303F, 0xFFE3A0: 0xDFF3F8, 0xF4B94D: 0x8FD0E3, 0xE48F2C: 0x397E96, 0x143E90: 0x1F5870, 0x081F58: 0x0E2A38]

    private static func hex(_ v: UInt32, _ a: Double = 1) -> Color { Color(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255, opacity: a) }
    private func shape(_ d: String, _ t: CGAffineTransform = .identity) -> SVGShape { SVGShape(d: d, unit: 128, transform: t) }
    private let shieldPath = "M64 29C76 34.5 87 34.5 94 40C94 68 82 90 64 103C46 90 34 68 34 40C41 34.5 52 34.5 64 29Z"
    private let landTransform = CGAffineTransform(translationX: -128, y: -94).concatenating(CGAffineTransform(scaleX: 0.703, y: 0.703)).concatenating(CGAffineTransform(translationX: 64, y: 64))

    var body: some View {
        let u = size / 128
        func hex(_ v: UInt32, _ a: Double = 1) -> Color { Self.hex(teal ? (Self.tealMap[v] ?? v) : v, a) }
        let cream = hex(0xFFF4DC)
        return ZStack {
            // 1. the protective ring
            Circle().strokeBorder(LinearGradient(colors: [hex(0xFFE08C), hex(0xF6A73A), hex(0xE8782A)], startPoint: .top, endPoint: .bottom), lineWidth: 5 * u).frame(width: 124 * u, height: 124 * u).position(x: 64 * u, y: 64 * u)
            Circle().fill(Color.white.opacity(0.07)).frame(width: 113 * u, height: 113 * u).position(x: 64 * u, y: 64 * u)
            // 2. the world
            Circle().fill(RadialGradient(colors: [hex(0x2F86D8), hex(0x125AA8), hex(0x0A2C66)], center: .init(x: 0.35, y: 0.28), startRadius: 0, endRadius: 85 * u)).frame(width: 90 * u, height: 90 * u).position(x: 64 * u, y: 64 * u)
            ZStack {
                shape(SetuLandData.path, landTransform).fill(LinearGradient(colors: [hex(0xFFE3A0), hex(0xF4B94D), hex(0xE48F2C)], startPoint: UnitPoint(x: 0.2, y: 0.17), endPoint: UnitPoint(x: 0.8, y: 0.83)))
                Circle().fill(RadialGradient(colors: [.white.opacity(0.45), .white.opacity(0)], center: .init(x: 0.3, y: 0.2), startRadius: 0, endRadius: 50 * u)).frame(width: 90 * u, height: 90 * u).position(x: 64 * u, y: 64 * u)
            }
            .frame(width: size, height: size).mask(Circle().frame(width: 90 * u, height: 90 * u).position(x: 64 * u, y: 64 * u))
            Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1.2 * u).frame(width: 90 * u, height: 90 * u).position(x: 64 * u, y: 64 * u)
            // 3. protection, large, over the world (smaller below 44 pt, so the continents still show)
            Group {
            shape(shieldPath).fill(LinearGradient(colors: [hex(0x143E90), hex(0x081F58)], startPoint: .top, endPoint: .bottom)).opacity(0.78)
            shape(shieldPath).stroke(cream, style: StrokeStyle(lineWidth: 3 * u, lineJoin: .round))
            shape("M55.5 70V63.8C55.5 59.1 59.3 55.3 64 55.3C68.7 55.3 72.5 59.1 72.5 63.8V70").stroke(cream, style: StrokeStyle(lineWidth: 4.2 * u, lineCap: .round))
            RoundedRectangle(cornerRadius: 4.6 * u, style: .continuous).fill(cream).frame(width: 28 * u, height: 22 * u).position(x: 64 * u, y: 79.5 * u)
            Circle().fill(hex(0x0A2C66)).frame(width: 6.6 * u, height: 6.6 * u).position(x: 64 * u, y: 77.6 * u)
            shape("M62.5 79H65.5L66.4 85H61.6Z").fill(hex(0x0A2C66))
            }
            .frame(width: size, height: size).scaleEffect(size < 44 ? 0.74 : 1, anchor: UnitPoint(x: 0.5, y: 0.5))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The icon with the name, in English, set in New York (the system serif): "Browser" regular with a little tracking, "Setu" bold in saffron.
/// `latin: false` leaves the name out, where the page already says it.
struct SetuLockup: View {
    var size: CGFloat = 14
    var latin = true
    var body: some View {
        HStack(spacing: size * 0.55) {
            SetuMark(size: size * (latin ? 2.7 : 4.2))
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
