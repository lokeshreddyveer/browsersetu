import SwiftUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import UniformTypeIdentifiers

// MARK: - A theme

struct RGB: Codable, Equatable, Hashable {
    var r: Double, g: Double, b: Double
    init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
    init(hex: UInt32) { self.init(Double((hex >> 16) & 255) / 255, Double((hex >> 8) & 255) / 255, Double(hex & 255) / 255) }
    var color: Color { Color(red: r, green: g, blue: b) }
    var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    /// Toward white (positive) or black (negative).
    func shifted(_ amount: Double) -> RGB {
        amount >= 0 ? RGB(r + (1 - r) * amount, g + (1 - g) * amount, b + (1 - b) * amount)
                    : RGB(r * (1 + amount), g * (1 + amount), b * (1 + amount))
    }
}

/// Something drawn over the theme's background, kept faint and still: it sets a mood without moving or getting in the way.
enum ThemeDecoration: String, Codable, CaseIterable {
    case none, fog, stars, grid, scanlines, embers, moon
    /// These move: they are drawn again about thirty times a second, unless motion is off (the Animation setting, Reduce Motion or Low Power Mode).
    case aurora, rain, snow, fireflies, waves, twinkle

    var isAnimated: Bool { [.aurora, .rain, .snow, .fireflies, .waves, .twinkle].contains(self) }
}

/// A look for the whole browser: the accent, the colour of the window and sidebar, the opening page's background and, if it needs one, a fixed
/// light or dark appearance. Every one is drawn in code (no downloaded art), so each works offline and weighs nothing.
struct BrowserTheme: Identifiable, Equatable {
    let id: String
    let name: String
    let note: String
    let accent: RGB
    /// The window, toolbar and sidebar colour. Nil leaves the system's own.
    let chrome: RGB?
    let top: RGB
    let bottom: RGB
    let glow: RGB
    let scheme: AppearanceMode?
    let decoration: ThemeDecoration
    /// Where the gallery files it: the moods, the classic palettes, or the person's own.
    var family = "Mood"

    static let midnight = BrowserTheme(id: "midnight", name: "Midnight", note: "The default", accent: RGB(0.05, 0.50, 0.60), chrome: nil,
                                       top: RGB(0.045, 0.055, 0.095), bottom: RGB(0.055, 0.058, 0.068), glow: RGB(0.067, 0.106, 0.188), scheme: nil, decoration: .none)

    /// Palettes people already know from editors and terminals, drawn here as whole-browser themes.
    static let palettes: [BrowserTheme] = [
        BrowserTheme(id: "dracula", name: "Dracula", note: "Purple, pink and a dark slate", accent: RGB(hex: 0xBD93F9), chrome: RGB(hex: 0x21222C),
                     top: RGB(hex: 0x282A36), bottom: RGB(hex: 0x1E1F29), glow: RGB(hex: 0x44475A), scheme: .dark, decoration: .none, family: "Palette"),
        BrowserTheme(id: "nord", name: "Nord", note: "Arctic blues, calm and low contrast", accent: RGB(hex: 0x88C0D0), chrome: RGB(hex: 0x272C36),
                     top: RGB(hex: 0x2E3440), bottom: RGB(hex: 0x242933), glow: RGB(hex: 0x434C5E), scheme: .dark, decoration: .none, family: "Palette"),
        BrowserTheme(id: "gruvbox", name: "Gruvbox Dark", note: "Warm retro browns and yellow", accent: RGB(hex: 0xFABD2F), chrome: RGB(hex: 0x1D2021),
                     top: RGB(hex: 0x282828), bottom: RGB(hex: 0x1D2021), glow: RGB(hex: 0x504945), scheme: .dark, decoration: .none, family: "Palette"),
        BrowserTheme(id: "gruvboxlight", name: "Gruvbox Light", note: "The same warmth on cream", accent: RGB(hex: 0xD65D0E), chrome: RGB(hex: 0xEBDBB2),
                     top: RGB(hex: 0xFBF1C7), bottom: RGB(hex: 0xEBDBB2), glow: RGB(hex: 0xF2E5BC), scheme: .light, decoration: .none, family: "Palette"),
        BrowserTheme(id: "solarized", name: "Solarized Dark", note: "Deep teal with a soft blue", accent: RGB(hex: 0x268BD2), chrome: RGB(hex: 0x00212B),
                     top: RGB(hex: 0x002B36), bottom: RGB(hex: 0x001E26), glow: RGB(hex: 0x073642), scheme: .dark, decoration: .none, family: "Palette"),
        BrowserTheme(id: "solarizedlight", name: "Solarized Light", note: "Sand and blue", accent: RGB(hex: 0x268BD2), chrome: RGB(hex: 0xEEE8D5),
                     top: RGB(hex: 0xFDF6E3), bottom: RGB(hex: 0xEEE8D5), glow: RGB(hex: 0xF5EBCB), scheme: .light, decoration: .none, family: "Palette"),
        BrowserTheme(id: "catppuccin", name: "Catppuccin Mocha", note: "Soft pastel on a warm dark", accent: RGB(hex: 0xCBA6F7), chrome: RGB(hex: 0x181825),
                     top: RGB(hex: 0x1E1E2E), bottom: RGB(hex: 0x11111B), glow: RGB(hex: 0x313244), scheme: .dark, decoration: .none, family: "Palette"),
        BrowserTheme(id: "tokyonight", name: "Tokyo Night", note: "Neon blues over a deep indigo", accent: RGB(hex: 0x7AA2F7), chrome: RGB(hex: 0x16161E),
                     top: RGB(hex: 0x1A1B26), bottom: RGB(hex: 0x13141C), glow: RGB(hex: 0x292E42), scheme: .dark, decoration: .none, family: "Palette"),
        BrowserTheme(id: "rosepine", name: "Rosé Pine", note: "Dusky rose and iris", accent: RGB(hex: 0xC4A7E7), chrome: RGB(hex: 0x16141F),
                     top: RGB(hex: 0x191724), bottom: RGB(hex: 0x12101B), glow: RGB(hex: 0x26233A), scheme: .dark, decoration: .none, family: "Palette"),
        BrowserTheme(id: "onedark", name: "One Dark", note: "The editor classic", accent: RGB(hex: 0x61AFEF), chrome: RGB(hex: 0x21252B),
                     top: RGB(hex: 0x282C34), bottom: RGB(hex: 0x1B1F27), glow: RGB(hex: 0x3E4451), scheme: .dark, decoration: .none, family: "Palette"),
    ]

    /// Themes whose background moves. Each is drawn in code, so it works offline and weighs nothing; it stands still when motion is off or the battery is low.
    static let animated: [BrowserTheme] = [
        BrowserTheme(id: "aurora", name: "Aurora", note: "Slow ribbons of green and violet light", accent: RGB(hex: 0x3DDC97), chrome: RGB(hex: 0x0A1218),
                     top: RGB(hex: 0x050D14), bottom: RGB(hex: 0x07141C), glow: RGB(hex: 0x0B2A2C), scheme: .dark, decoration: .aurora, family: "Animated"),
        BrowserTheme(id: "rainynight", name: "Rainy Night", note: "Rain falling past a blue window", accent: RGB(hex: 0x7AA2F7), chrome: RGB(hex: 0x0E1118),
                     top: RGB(hex: 0x0A0C13), bottom: RGB(hex: 0x0F121B), glow: RGB(hex: 0x1A2438), scheme: .dark, decoration: .rain, family: "Animated"),
        BrowserTheme(id: "snowfall", name: "Snowfall", note: "Soft snow drifting down", accent: RGB(hex: 0xBFD7FF), chrome: RGB(hex: 0x131824),
                     top: RGB(hex: 0x0F1420), bottom: RGB(hex: 0x1A2030), glow: RGB(hex: 0x2E3A52), scheme: .dark, decoration: .snow, family: "Animated"),
        BrowserTheme(id: "fireflies", name: "Fireflies", note: "Small lights drifting in a dark meadow", accent: RGB(hex: 0xE6F25C), chrome: RGB(hex: 0x0A130C),
                     top: RGB(hex: 0x07110A), bottom: RGB(hex: 0x0A170D), glow: RGB(hex: 0x14291A), scheme: .dark, decoration: .fireflies, family: "Animated"),
        BrowserTheme(id: "deepsea", name: "Deep Sea", note: "Slow waves along the bottom", accent: RGB(hex: 0x4CC9F0), chrome: RGB(hex: 0x06141E),
                     top: RGB(hex: 0x03121C), bottom: RGB(hex: 0x05202E), glow: RGB(hex: 0x0A3A50), scheme: .dark, decoration: .waves, family: "Animated"),
        BrowserTheme(id: "starrynight", name: "Starry Night", note: "Stars that twinkle", accent: RGB(hex: 0xC3A6FF), chrome: RGB(hex: 0x0B0A18),
                     top: RGB(hex: 0x06050F), bottom: RGB(hex: 0x0C0A1A), glow: RGB(hex: 0x1C1640), scheme: .dark, decoration: .twinkle, family: "Animated"),
    ]

    static let all: [BrowserTheme] = [
        midnight,
        BrowserTheme(id: "pureblack", name: "Pure Black", note: "True black everywhere, for OLED screens", accent: RGB(hex: 0x4DA3FF), chrome: RGB(hex: 0x000000),
                     top: RGB(hex: 0x000000), bottom: RGB(hex: 0x000000), glow: RGB(hex: 0x000000), scheme: .dark, decoration: .none),
        BrowserTheme(id: "slime", name: "Slime Night", note: "Green ooze under a creeping fog", accent: RGB(hex: 0x7CFF3A), chrome: RGB(hex: 0x0A1409),
                     top: RGB(hex: 0x0B1A0C), bottom: RGB(hex: 0x050A05), glow: RGB(hex: 0x1F5A1A), scheme: .dark, decoration: .fog),
        BrowserTheme(id: "bloodmoon", name: "Blood Moon", note: "A red moon over a black sky", accent: RGB(hex: 0xFF3B4E), chrome: RGB(hex: 0x120609),
                     top: RGB(hex: 0x1C0709), bottom: RGB(hex: 0x070203), glow: RGB(hex: 0x5A0F18), scheme: .dark, decoration: .moon),
        BrowserTheme(id: "haunted", name: "Haunted Hallway", note: "Violet mist and long shadows", accent: RGB(hex: 0xB07CFF), chrome: RGB(hex: 0x0D0916),
                     top: RGB(hex: 0x150C26), bottom: RGB(hex: 0x06040C), glow: RGB(hex: 0x3A1D6B), scheme: .dark, decoration: .fog),
        BrowserTheme(id: "pumpkin", name: "Pumpkin Patch", note: "Warm embers on a dark field", accent: RGB(hex: 0xFF8A1F), chrome: RGB(hex: 0x130B05),
                     top: RGB(hex: 0x1F1006), bottom: RGB(hex: 0x080402), glow: RGB(hex: 0x6B3406), scheme: .dark, decoration: .embers),
        BrowserTheme(id: "arcade", name: "Neon Arcade", note: "Magenta and cyan on black", accent: RGB(hex: 0xFF2BD6), chrome: RGB(hex: 0x08060F),
                     top: RGB(hex: 0x120622), bottom: RGB(hex: 0x03020A), glow: RGB(hex: 0x1B2E7A), scheme: .dark, decoration: .grid),
        BrowserTheme(id: "synthwave", name: "Synthwave", note: "Sunset purple, hot pink", accent: RGB(hex: 0xFF6AC1), chrome: RGB(hex: 0x120628),
                     top: RGB(hex: 0x2A0B52), bottom: RGB(hex: 0x0B0418), glow: RGB(hex: 0x7A1F6B), scheme: .dark, decoration: .grid),
        BrowserTheme(id: "space", name: "Deep Space", note: "Quiet stars", accent: RGB(hex: 0x6FA8FF), chrome: RGB(hex: 0x05070F),
                     top: RGB(hex: 0x070B1C), bottom: RGB(hex: 0x020309), glow: RGB(hex: 0x14245A), scheme: .dark, decoration: .stars),
        BrowserTheme(id: "aurora", name: "Aurora", note: "Northern green and teal", accent: RGB(hex: 0x3DF2B0), chrome: RGB(hex: 0x06120F),
                     top: RGB(hex: 0x07261F), bottom: RGB(hex: 0x030A09), glow: RGB(hex: 0x0F6B55), scheme: .dark, decoration: .stars),
        BrowserTheme(id: "glitch", name: "Glitch", note: "Scan lines and electric green", accent: RGB(hex: 0x00FFB3), chrome: RGB(hex: 0x050807),
                     top: RGB(hex: 0x07100D), bottom: RGB(hex: 0x020403), glow: RGB(hex: 0x0A4A3A), scheme: .dark, decoration: .scanlines),
        BrowserTheme(id: "paper", name: "Paper", note: "Warm, light and quiet", accent: RGB(hex: 0xC2410C), chrome: RGB(hex: 0xF3EEE4),
                     top: RGB(hex: 0xFAF6EE), bottom: RGB(hex: 0xEDE6D8), glow: RGB(hex: 0xF4D9B0), scheme: .light, decoration: .none),
        BrowserTheme(id: "arctic", name: "Arctic", note: "Cool, bright and clean", accent: RGB(hex: 0x2563EB), chrome: RGB(hex: 0xE8EFF7),
                     top: RGB(hex: 0xF4F8FD), bottom: RGB(hex: 0xDCE7F4), glow: RGB(hex: 0xBFD7F5), scheme: .light, decoration: .none),
    ]
}

/// The person's own theme: two background colours, an accent, and optionally a photo.
struct CustomTheme: Codable, Equatable {
    var accent = RGB(hex: 0x4F8CFF)
    var top = RGB(hex: 0x121826)
    var bottom = RGB(hex: 0x07090F)
    var hasPhoto = false
    /// A moving backdrop for the custom theme (nil is still).
    var decoration: ThemeDecoration?
    /// How dark the photo is made under the text, 0 to 0.8.
    var photoDim = 0.35
    var isLight: Bool { top.luminance > 0.6 }

    var theme: BrowserTheme {
        BrowserTheme(id: "custom", name: "Custom", note: "Your colours and photo", accent: accent, chrome: top.shifted(isLight ? -0.04 : -0.35),
                     top: top, bottom: bottom, glow: accent.shifted(-0.55), scheme: isLight ? .light : .dark, decoration: decoration ?? .none)
    }
}

/// What the interface reads, set when the theme changes: colours that cannot be asked of the model from deep inside a view.
enum ThemeState {
    nonisolated(unsafe) static var chrome: Color?
    nonisolated(unsafe) static var raised: Color?
}

// MARK: - Drawing

/// The background of a theme: the gradient, a soft glow, the mood, and the photo if there is one.
struct ThemeBackdrop: View {
    let theme: BrowserTheme
    var photo: Data?
    var photoDim = 0.35

    var body: some View {
        ZStack {
            LinearGradient(colors: [theme.top.color, theme.bottom.color], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [theme.glow.color.opacity(0.75), .clear], center: .init(x: 0.5, y: 0.38), startRadius: 0, endRadius: 560)
            if let photo, let image = Image(platformData: photo) {
                image.resizable().scaledToFill().overlay(Color.black.opacity(photoDim))
            }
            Decoration(kind: theme.decoration, tint: theme.accent.color)
        }
        .clipped()
        .ignoresSafeArea()
    }

    private struct Decoration: View {
        let kind: ThemeDecoration
        let tint: Color
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        /// Moving backdrops pause for Reduce Motion, for the Animation setting Off and for Low Power Mode, and draw one still frame instead.
        private var moving: Bool { kind.isAnimated && !reduceMotion && MotionStyle.current != .off && !ProcessInfo.processInfo.isLowPowerModeEnabled }

        var body: some View {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moving)) { timeline in
                canvas(t: moving ? timeline.date.timeIntervalSinceReferenceDate : 4)
            }
            .allowsHitTesting(false)
        }

        private func canvas(t: Double) -> some View {
            Canvas { context, size in
                switch kind {
                case .none: break
                case .aurora:
                    var layer = context
                    layer.addFilter(.blur(radius: 38))
                    let colors: [Color] = [tint, Color(red: 0.35, green: 0.45, blue: 0.95), Color(red: 0.75, green: 0.35, blue: 0.85)]
                    for band in 0..<3 {
                        let b = Double(band)
                        let baseY: Double = size.height * (0.28 + 0.14 * b)
                        var path = Path()
                        path.move(to: CGPoint(x: -20, y: size.height))
                        var x = -20.0
                        while x <= size.width + 20 {
                            let slow: Double = sin(x / 170 + t * 0.35 + b * 1.9) * 38
                            let fast: Double = sin(x / 90 - t * 0.5 + b) * 16
                            path.addLine(to: CGPoint(x: x, y: baseY + slow + fast))
                            x += 16
                        }
                        path.addLine(to: CGPoint(x: size.width + 20, y: size.height))
                        path.closeSubpath()
                        let fade = Gradient(colors: [colors[band].opacity(0.30), .clear])
                        layer.fill(path, with: .linearGradient(fade, startPoint: CGPoint(x: 0, y: baseY - 50), endPoint: CGPoint(x: 0, y: baseY + 260)))
                    }
                case .rain:
                    var seed: UInt64 = 5
                    func next() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) }
                    for _ in 0..<80 {
                        let x = next() * size.width, speed = 380 + next() * 320, offset = next() * size.height, length = 10 + next() * 14
                        let y: Double = (offset + t * speed).truncatingRemainder(dividingBy: size.height + 40) - 20
                        var drop = Path()
                        drop.move(to: CGPoint(x: x, y: y))
                        drop.addLine(to: CGPoint(x: x - 2, y: y + length))
                        context.stroke(drop, with: .color(tint.opacity(0.22)), lineWidth: 1)
                    }
                case .snow:
                    var seed: UInt64 = 9
                    func next() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) }
                    for _ in 0..<90 {
                        let x0 = next() * size.width, speed = 22 + next() * 40, offset = next() * size.height
                        let r = 1.2 + next() * 2.4, sway = next() * 30, phase = next() * 6.28, alpha = 0.35 + next() * 0.4
                        let y: Double = (offset + t * speed).truncatingRemainder(dividingBy: size.height + 20) - 10
                        let x: Double = x0 + sin(t * 0.6 + phase) * sway
                        context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)), with: .color(.white.opacity(alpha)))
                    }
                case .fireflies:
                    var seed: UInt64 = 13
                    func next() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) }
                    for _ in 0..<30 {
                        let cx = next() * size.width, cy = size.height * (0.3 + next() * 0.7), radius = 20 + next() * 60
                        let speed = 0.15 + next() * 0.3, phase = next() * 6.28, rate = 0.8 + next()
                        let x: Double = cx + cos(t * speed + phase) * radius
                        let y: Double = cy + sin(t * speed * 1.3 + phase) * radius * 0.6
                        let pulse: Double = 0.5 + 0.5 * sin(t * rate + phase)
                        context.fill(Path(ellipseIn: CGRect(x: x - 7, y: y - 7, width: 14, height: 14)), with: .color(tint.opacity(0.10 * pulse)))
                        context.fill(Path(ellipseIn: CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3)), with: .color(tint.opacity(0.35 + 0.5 * pulse)))
                    }
                case .waves:
                    for layer in 0..<4 {
                        let l = Double(layer)
                        var path = Path()
                        path.move(to: CGPoint(x: 0, y: size.height))
                        var x = 0.0
                        while x <= size.width + 12 {
                            let wavelength: Double = 140 + 30 * l
                            let swing: Double = sin(x / wavelength + t * (0.5 + 0.15 * l) + l * 1.3) * (14 + 4 * l)
                            path.addLine(to: CGPoint(x: x, y: size.height * (0.70 + 0.06 * l) + swing))
                            x += 12
                        }
                        path.addLine(to: CGPoint(x: size.width, y: size.height))
                        path.closeSubpath()
                        context.fill(path, with: .color(tint.opacity(0.07 + 0.03 * l)))
                    }
                case .twinkle:
                    var seed: UInt64 = 7
                    func next() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) }
                    for _ in 0..<110 {
                        let x = next() * size.width, y = next() * size.height, r = 0.6 + next() * 1.4
                        let base = 0.25 + next() * 0.5, rate = 0.6 + next() * 1.8, phase = next() * 6.28
                        let alpha: Double = base * (0.45 + 0.55 * (0.5 + 0.5 * sin(t * rate + phase)))
                        context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)), with: .color(.white.opacity(alpha)))
                    }
                case .fog:
                    for i in 0..<6 {
                        let t = Double(i)
                        // Written in small steps: the compiler on older Xcode versions gives up on this as one expression.
                        let across: Double = 0.05 + 0.18 * t
                        let wave: Double = 0.55 + 0.07 * sin(t * 1.7)
                        let x: Double = size.width * across - 140
                        let y: Double = size.height * wave - 90
                        let rect = CGRect(x: x, y: y, width: 360, height: 180)
                        context.fill(Path(ellipseIn: rect), with: .color(tint.opacity(0.07)))
                    }
                case .stars:
                    var seed: UInt64 = 7
                    func next() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) }
                    for _ in 0..<90 {
                        let x = next() * size.width, y = next() * size.height, r = 0.5 + next() * 1.2
                        context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)), with: .color(.white.opacity(0.25 + next() * 0.5)))
                    }
                case .grid:
                    let horizon = size.height * 0.62
                    var path = Path()
                    for i in 0...14 {
                        let x = size.width * Double(i) / 14
                        path.move(to: CGPoint(x: size.width / 2 + (x - size.width / 2) * 0.08, y: horizon)); path.addLine(to: CGPoint(x: x * 1.0 + (x - size.width / 2) * 1.2, y: size.height))
                    }
                    for j in 1...8 {
                        let y = horizon + (size.height - horizon) * pow(Double(j) / 8, 2)
                        path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    context.stroke(path, with: .color(tint.opacity(0.18)), lineWidth: 0.8)
                case .scanlines:
                    var y = 0.0
                    while y < size.height { context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(tint.opacity(0.05))); y += 4 }
                case .embers:
                    var seed: UInt64 = 21
                    func next() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) }
                    for _ in 0..<40 {
                        let x = next() * size.width, y = size.height * (0.35 + next() * 0.65), r = 1 + next() * 2.2
                        context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)), with: .color(tint.opacity(0.15 + next() * 0.45)))
                    }
                case .moon:
                    let d = min(size.width, size.height) * 0.42
                    context.fill(Path(ellipseIn: CGRect(x: size.width * 0.5 - d / 2, y: size.height * 0.2 - d / 2, width: d, height: d)), with: .color(tint.opacity(0.10)))
                    context.fill(Path(ellipseIn: CGRect(x: size.width * 0.5 - d * 0.32, y: size.height * 0.2 - d * 0.32, width: d * 0.64, height: d * 0.64)), with: .color(tint.opacity(0.14)))
                }
            }
        }
    }
}

/// Settings, sheets and lists take on the theme too: its background behind the cards, in place of the system's plain grey or black.
struct ThemedSurface: ViewModifier {
    @EnvironmentObject var model: BrowserModel

    func body(content: Content) -> some View {
        if model.themeIsActive {
            content
                .scrollContentBackground(.hidden)
                .background(ThemeBackdrop(theme: model.activeTheme, photo: model.themePhoto, photoDim: model.customTheme.photoDim))
        } else {
            content
        }
    }
}

extension View {
    func themedSurface() -> some View { modifier(ThemedSurface()) }
}

// MARK: - The model

extension BrowserModel {
    var activeTheme: BrowserTheme {
        if themeID == "custom" { return customTheme.theme }
        if themeID.hasPrefix("user-") { return userTheme(id: themeID) ?? .midnight }
        return (BrowserTheme.all + BrowserTheme.palettes + BrowserTheme.animated).first { $0.id == themeID } ?? .midnight
    }

    var themeIsActive: Bool { themeID != "midnight" }

    private var themeFolder: URL { profileFolder.appendingPathComponent("themes", isDirectory: true) }
    private var photoURL: URL { themeFolder.appendingPathComponent("background.jpg") }

    var themePhoto: Data? { themeID == "custom" && customTheme.hasPhoto ? (try? Data(contentsOf: photoURL)) : nil }

    /// Makes the interface take on the chosen theme at once.
    func applyTheme() {
        let theme = activeTheme
        if themeIsActive, let chrome = theme.chrome {
            ThemeState.chrome = chrome.color
            ThemeState.raised = chrome.shifted(theme.scheme == .light ? 0.5 : 0.10).color
        } else {
            ThemeState.chrome = nil
            ThemeState.raised = nil
        }
        applyWorkspaceTheme()
        applySystemAppearance()
    }

    /// Alerts, popovers, menus and sheets are drawn by the system, outside the SwiftUI views, so they follow the app's own light or dark setting,
    /// which comes from the person's choice or, failing that, from the theme.
    func applySystemAppearance() {
        let scheme = appearance.colorScheme ?? (themeIsActive ? activeTheme.scheme?.colorScheme : nil)
        #if canImport(AppKit)
        NSApp?.appearance = scheme == .dark ? NSAppearance(named: .darkAqua) : (scheme == .light ? NSAppearance(named: .aqua) : nil)
        #else
        let style: UIUserInterfaceStyle = scheme == .dark ? .dark : (scheme == .light ? .light : .unspecified)
        for case let windowScene as UIWindowScene in UIApplication.shared.connectedScenes { windowScene.windows.forEach { $0.overrideUserInterfaceStyle = style } }
        #endif
    }

    func chooseTheme(_ id: String) { themeID = id }

    func setCustomTheme(_ value: CustomTheme) {
        customTheme = value
        saveSetting("theme_custom", (try? String(data: JSONEncoder().encode(value), encoding: .utf8)) ?? "{}")
        if themeID == "custom" { applyTheme() }
    }

    func loadThemeSettings() {
        loadUserThemes()
        customTheme = (get("theme_custom").flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(CustomTheme.self, from: $0) }) ?? CustomTheme()
    }

    private func get(_ key: String) -> String? { (try? core.getSetting(key: key)) ?? nil }

    /// A photo for the background: shrunk, kept in this profile's folder, never sent anywhere.
    func setThemePhoto(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let jpeg = Self.shrunkJPEG(data, longSide: 1800) else { notice = "That picture could not be used."; return }
        try? FileManager.default.createDirectory(at: themeFolder, withIntermediateDirectories: true)
        guard (try? jpeg.write(to: photoURL, options: .atomic)) != nil else { return }
        var value = customTheme
        value.hasPhoto = true
        // The photo picks the accent, kept visible against the background; "Match Accent to Photo" does it again after a hand-picked one.
        if let found = ThemeColor.dominantAccent(from: jpeg) { value.accent = found.readable(against: value.top) }
        setCustomTheme(value)
        if themeID != "custom" { themeID = "custom" }
        objectWillChange.send()
    }

    private var startImageURL: URL { themeFolder.appendingPathComponent("start.jpg") }

    func loadStartImage() { startImageData = try? Data(contentsOf: startImageURL) }

    /// A picture for the start page background, chosen from this device: shrunk, kept in this profile's folder, never sent anywhere.
    func setStartImage(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let jpeg = Self.shrunkJPEG(data, longSide: 2200) else { notice = "That picture could not be used."; return }
        try? FileManager.default.createDirectory(at: themeFolder, withIntermediateDirectories: true)
        guard (try? jpeg.write(to: startImageURL, options: .atomic)) != nil else { notice = "The picture could not be saved."; return }
        startImageData = jpeg
        startBackground = .image
    }

    func removeStartImage() {
        try? FileManager.default.removeItem(at: startImageURL)
        startImageData = nil
        if startBackground == .image { startBackground = .gradient }
    }

    func removeThemePhoto() {
        try? FileManager.default.removeItem(at: photoURL)
        var value = customTheme
        value.hasPhoto = false
        setCustomTheme(value)
        objectWillChange.send()
    }

    static func shrunkJPEG(_ data: Data, longSide: CGFloat) -> Data? {
        #if canImport(AppKit)
        guard let image = NSImage(data: data), let rep = image.representations.first else { return nil }
        let w = CGFloat(rep.pixelsWide), h = CGFloat(rep.pixelsHigh)
        let scale = min(1, longSide / max(w, h))
        let size = NSSize(width: max(1, w * scale), height: max(1, h * scale))
        let out = NSImage(size: size)
        out.lockFocus(); image.draw(in: NSRect(origin: .zero, size: size)); out.unlockFocus()
        guard let tiff = out.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
        #else
        guard let image = UIImage(data: data) else { return nil }
        let scale = min(1, longSide / max(image.size.width, image.size.height))
        let size = CGSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
        return UIGraphicsImageRenderer(size: size).jpegData(withCompressionQuality: 0.82) { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        #endif
    }
}

// MARK: - Settings

/// Appearance › Themes: a gallery of looks for the whole browser, and an editor for your own.
struct ThemesSection: View {
    @EnvironmentObject var model: BrowserModel
    @State private var choosingPhoto = false

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12)]

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                gallery("Moods", BrowserTheme.all)
                gallery("Animated", BrowserTheme.animated)
                gallery("Classic palettes", BrowserTheme.palettes)
                if !model.userThemes.isEmpty { gallery("Yours", model.userThemes.compactMap(\.theme)) }
                gallery(nil, [model.customTheme.theme])
            }
            .padding(.vertical, 4)
            if model.themeID == "custom" { editor }
            ThemeToolsRows()
            if model.themeIsActive { Button("Back to the Default Look") { model.chooseTheme("midnight") } }
        } header: {
            Text("Themes")
        } footer: {
            Text("A theme changes the whole browser: its accent, the window and sidebar, and the opening page. Websites keep their own colours. Your photo stays on this device. Theme files hold colours only, so they are safe to share.")
        }
        .fileImporter(isPresented: $choosingPhoto, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { model.setThemePhoto(from: url) }
        }
    }

    @ViewBuilder private func gallery(_ title: String?, _ themes: [BrowserTheme]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(themes) { theme in
                    card(theme, selected: model.themeID == theme.id) { animated(.easeOut(duration: 0.2)) { model.chooseTheme(theme.id) } }
                        .contextMenu {
                            if theme.id != "custom" { Button("Edit as Custom") { model.editAsCustom(theme) } }
                            if theme.id.hasPrefix("user-") { Button("Delete Theme", role: .destructive) { model.deleteUserTheme(theme.id) } }
                        }
                }
            }
        }
    }

    private func card(_ theme: BrowserTheme, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack(alignment: .bottomLeading) {
                    ThemeBackdrop(theme: theme, photo: theme.id == "custom" ? model.themePhoto : nil, photoDim: model.customTheme.photoDim).frame(height: 62)
                    Capsule().fill(theme.accent.color).frame(width: 30, height: 6).padding(8)
                }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 16)).symbolRenderingMode(.palette)
                        .foregroundStyle(theme.accent.luminance > 0.6 ? Color.black : Color.white, theme.accent.color)
                        .padding(5).opacity(selected ? 1 : 0).scaleEffect(selected ? 1 : 0.6)
                }
                .motion(.easeOut(duration: 0.18), value: selected)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? theme.accent.color : Color.primary.opacity(0.12), lineWidth: selected ? 2 : 0.5))
                Text(theme.name).font(.system(size: 11.5, weight: selected ? .semibold : .regular)).lineLimit(1).foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(theme.name) theme\(selected ? ", selected" : "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var editor: some View {
        ColorPicker("Accent", selection: binding(\.accent))
        ColorPicker("Background, top", selection: binding(\.top))
        ColorPicker("Background, bottom", selection: binding(\.bottom))
        let ratio = model.customTheme.accent.contrast(with: model.customTheme.top)
        if ratio < 3 {
            HStack(spacing: 8) {
                Label("This accent is hard to see on this background.", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                Spacer()
                Button("Fix It") { var v = model.customTheme; v.accent = v.accent.readable(against: v.top); model.setCustomTheme(v) }.buttonStyle(.borderless)
            }
            .transition(.opacity)
        }
        Picker("Backdrop", selection: Binding(get: { model.customTheme.decoration ?? .none }, set: { var v = model.customTheme; v.decoration = $0 == .none ? nil : $0; model.setCustomTheme(v) })) {
            ForEach(ThemeDecoration.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
        }
        Button(model.customTheme.hasPhoto ? "Change Photo…" : "Choose a Photo…") { choosingPhoto = true }
        if model.customTheme.hasPhoto {
            Button("Match Accent to Photo") { if !model.matchAccentToPhoto() { model.notice = "That photo has no colour to take an accent from." } }
            HStack {
                Text("Darken photo")
                Slider(value: Binding(get: { model.customTheme.photoDim }, set: { var v = model.customTheme; v.photoDim = $0; model.setCustomTheme(v) }), in: 0...0.8)
            }
            Button("Remove Photo", role: .destructive) { model.removeThemePhoto() }
        }
    }

    private func binding(_ path: WritableKeyPath<CustomTheme, RGB>) -> Binding<Color> {
        Binding {
            model.customTheme[keyPath: path].color
        } set: { newColor in
            var value = model.customTheme
            value[keyPath: path] = RGB(from: newColor)
            model.setCustomTheme(value)
        }
    }
}

extension RGB {
    init(from color: Color) {
        #if canImport(AppKit)
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        self.init(Double(r), Double(g), Double(b))
        #endif
    }
}

// MARK: - Surfaces that follow the theme

extension View {
    /// A panel's own surface: the theme's raised colour when a theme with its own colours is in use, otherwise `fallback` (a system material or colour).
    func themedFill<S: InsettableShape, F: ShapeStyle>(in shape: S, fallback: F) -> some View {
        Group {
            if let raised = ThemeState.raised { background(raised.opacity(0.94), in: shape) } else { background(fallback, in: shape) }
        }
    }

    /// The same for a surface that fills its whole area (a bar, a drawer).
    func themedBar<F: ShapeStyle>(fallback: F) -> some View {
        Group {
            if let raised = ThemeState.raised { background(raised.opacity(0.94)) } else { background(fallback) }
        }
    }
}
