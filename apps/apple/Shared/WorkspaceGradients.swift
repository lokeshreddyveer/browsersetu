import SwiftUI

/// A colour as red, green and blue, 0 to 1. Plain numbers, so the contrast rules can be checked without a screen.
struct GradientColor: Equatable {
    var r: Double, g: Double, b: Double

    init(r: Double, g: Double, b: Double) { self.r = Self.clamp(r); self.g = Self.clamp(g); self.b = Self.clamp(b) }

    /// "#RRGGBB" or "RRGGBB".
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(r: Double((value >> 16) & 0xFF) / 255, g: Double((value >> 8) & 0xFF) / 255, b: Double(value & 0xFF) / 255)
    }

    var hex: String { String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded())) }
    private static func clamp(_ v: Double) -> Double { min(1, max(0, v)) }

    // Hue, saturation, brightness (each 0 to 1).
    var hsb: (h: Double, s: Double, b: Double) {
        let maxV = max(r, g, b), minV = min(r, g, b), d = maxV - minV
        var h = 0.0
        if d > 0 {
            if maxV == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if maxV == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
            h /= 6; if h < 0 { h += 1 }
        }
        return (h, maxV == 0 ? 0 : d / maxV, maxV)
    }

    init(h: Double, s: Double, b: Double) {
        let hue = (h - floor(h)) * 6, c = b * s, x = c * (1 - abs(hue.truncatingRemainder(dividingBy: 2) - 1)), m = b - c
        let (r1, g1, b1): (Double, Double, Double)
        switch Int(hue) {
        case 0: (r1, g1, b1) = (c, x, 0)
        case 1: (r1, g1, b1) = (x, c, 0)
        case 2: (r1, g1, b1) = (0, c, x)
        case 3: (r1, g1, b1) = (0, x, c)
        case 4: (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }
        self.init(r: r1 + m, g: g1 + m, b: b1 + m)
    }

    /// WCAG relative luminance.
    var luminance: Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// WCAG contrast ratio, 1 to 21.
    static func contrast(_ a: GradientColor, _ b: GradientColor) -> Double {
        let la = a.luminance, lb = b.luminance
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// This colour laid over `background` with the given opacity.
    func over(_ background: GradientColor, opacity: Double) -> GradientColor {
        GradientColor(r: r * opacity + background.r * (1 - opacity), g: g * opacity + background.g * (1 - opacity), b: b * opacity + background.b * (1 - opacity))
    }

    var color: Color { Color(red: r, green: g, blue: b) }
}

/// What the readability check found for one of the two looks.
struct GradientReadability: Equatable {
    /// The faintest text the sidebar draws (a secondary label) against the strongest tinted background the gradient makes.
    var textContrast: Double
    /// The accent colour taken from the gradient against the plain sidebar background.
    var accentContrast: Double
    var passes: Bool { textContrast >= GradientRules.textMinimum && accentContrast >= GradientRules.accentMinimum }
}

enum GradientRules {
    /// WCAG AA for normal text, and for a control or icon.
    static let textMinimum = 4.5
    static let accentMinimum = 3.0
    /// How strongly the gradient is laid over the sidebar: a tint, never a fill.
    static func washOpacity(dark: Bool) -> Double { dark ? 0.22 : 0.16 }
    /// The plain sidebar colour, as far as the check is concerned.
    static func base(dark: Bool) -> GradientColor { dark ? GradientColor(r: 0.12, g: 0.12, b: 0.13) : GradientColor(r: 0.96, g: 0.96, b: 0.97) }
    static func label(dark: Bool) -> GradientColor { dark ? GradientColor(r: 1, g: 1, b: 1) : GradientColor(r: 0, g: 0, b: 0) }
    /// A secondary label is the main one at this opacity.
    static let secondaryOpacity = 0.6
    /// The ranges a colour may have: lively but not neon, not so dark or so light that nothing reads on it.
    static let saturation: ClosedRange<Double> = 0.12...0.85
    static let brightness: ClosedRange<Double> = 0.35...0.92
}

/// A workspace's colour theme: two or three colours and an angle. Used as a faint wash at the top of the sidebar and on the workspace's icon tile, and its first
/// colour (made readable) is the workspace's accent unless the workspace has an accent of its own.
struct WorkspaceGradient: Codable, Equatable {
    var colors: [String]
    /// Degrees: 0 points up, 90 to the right, 180 down.
    var angle: Double

    static let maxColors = 3

    var rgb: [GradientColor] { colors.compactMap { GradientColor(hex: $0) } }

    /// The same gradient with every colour inside the allowed range, two or three colours, and the angle in 0 to 360. Colours that are not colours are dropped; with
    /// fewer than two left it returns nil.
    func validated() -> WorkspaceGradient? {
        let fixed = rgb.prefix(Self.maxColors).map { colour -> GradientColor in
            let c = colour.hsb
            return GradientColor(h: c.h, s: min(max(c.s, GradientRules.saturation.lowerBound), GradientRules.saturation.upperBound),
                       b: min(max(c.b, GradientRules.brightness.lowerBound), GradientRules.brightness.upperBound))
        }
        guard fixed.count >= 2 else { return nil }
        let normalized = angle.isFinite ? (angle.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) : 135
        return WorkspaceGradient(colors: fixed.map(\.hex), angle: normalized.rounded())
    }

    /// The colours as shown in the light or the dark look. In the dark look they are deeper, so they do not glare.
    func stops(dark: Bool) -> [GradientColor] { rgb.map { Self.adapt($0, dark: dark) } }

    static func adapt(_ colour: GradientColor, dark: Bool) -> GradientColor {
        guard dark else { return colour }
        let c = colour.hsb
        return GradientColor(h: c.h, s: min(1, c.s * 1.05), b: c.b * 0.72)
    }

    var startPoint: UnitPoint { let r = angle * .pi / 180; return UnitPoint(x: 0.5 - sin(r) / 2, y: 0.5 + cos(r) / 2) }
    var endPoint: UnitPoint { let r = angle * .pi / 180; return UnitPoint(x: 0.5 + sin(r) / 2, y: 0.5 - cos(r) / 2) }

    func linear(dark: Bool) -> LinearGradient {
        LinearGradient(colors: stops(dark: dark).map(\.color), startPoint: startPoint, endPoint: endPoint)
    }

    /// The first colour, moved lighter or darker until it can be seen against the sidebar (3 to 1), for the given look.
    func accent(dark: Bool) -> GradientColor? {
        guard var colour = stops(dark: dark).first else { return nil }
        let base = GradientRules.base(dark: dark)
        for _ in 0..<24 where GradientColor.contrast(colour, base) < GradientRules.accentMinimum {
            let c = colour.hsb
            colour = GradientColor(h: c.h, s: c.s, b: dark ? c.b + 0.05 : c.b - 0.05)
        }
        return colour
    }

    func readability(dark: Bool) -> GradientReadability {
        let base = GradientRules.base(dark: dark)
        let label = GradientRules.label(dark: dark)
        let worstText = stops(dark: dark).map { stop -> Double in
            let wash = stop.over(base, opacity: GradientRules.washOpacity(dark: dark))
            return GradientColor.contrast(label.over(wash, opacity: GradientRules.secondaryOpacity), wash)
        }.min() ?? 21
        let accentContrast = accent(dark: dark).map { GradientColor.contrast($0, base) } ?? 21
        return GradientReadability(textContrast: worstText, accentContrast: accentContrast)
    }

    /// Checked in both looks.
    var isReadable: Bool { readability(dark: false).passes && readability(dark: true).passes }
}

/// Makes palettes: a base hue and its complement (or the two colours either side of the complement), lively but inside the allowed ranges.
enum GradientGenerator {
    static func random(count: Int, using generator: inout some RandomNumberGenerator) -> WorkspaceGradient {
        let hue = Double.random(in: 0..<1, using: &generator)
        let hues: [Double]
        if count >= 3 {
            let spread = Double.random(in: 0.06...0.1, using: &generator)
            hues = [hue, hue + 0.5 - spread, hue + 0.5 + spread]                    // split complementary
        } else {
            hues = [hue, hue + 0.5 + Double.random(in: -0.04...0.04, using: &generator)]
        }
        let colours = hues.map { h in
            GradientColor(h: h, s: Double.random(in: 0.42...0.72, using: &generator), b: Double.random(in: 0.62...0.88, using: &generator)).hex
        }
        let angle = Double(Int.random(in: 2...22, using: &generator) * 15)
        return WorkspaceGradient(colors: colours, angle: angle).validated() ?? WorkspaceGradient(colors: colours, angle: angle)
    }

    static func random(count: Int) -> WorkspaceGradient {
        var system = SystemRandomNumberGenerator()
        return random(count: count, using: &system)
    }
}

extension Color {
    /// A colour that follows the light and dark look by itself.
    static func workspaceAdaptive(light: GradientColor, dark: GradientColor) -> Color {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
        })
        #else
        Color(uiColor: UIColor { trait in
            let c = trait.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
        })
        #endif
    }
}

extension GradientColor {
    /// From a SwiftUI colour (a colour picker's choice), in sRGB.
    init(_ color: Color) {
        #if os(macOS)
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .gray
        self.init(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent))
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        self.init(r: Double(r), g: Double(g), b: Double(b))
        #endif
    }
}
