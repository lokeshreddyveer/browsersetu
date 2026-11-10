import SwiftUI

// The screen's content: the invented article page, what reaches for it, Browser Setu's boundary and the four protections, drawn live in the screen's own flat coordinates (1440 x 900 for the landscape
// composition, 900 x 1600 for portrait). The film engine maps this onto the laptop or phone screen in the artwork with true perspective (FilmView). Nothing here is artwork: no person, no laptop, no room.
// Cues come from the frame table (FilmCue). Page, intruders and protections are in InvisibleWebPage.swift and InvisibleWebSetu.swift.

enum InvisibleWeb {
    typealias C = IntroPalette

    enum Device { case laptop, tablet, phone }

    /// The page geometry the page, intruders and protections are authored on (legacy page units); `compact` is the single-column portrait page.
    struct Stage {
        var device: Device
        var grid: CGSize
        var page: CGRect
        var compact: Bool
    }

    static let landscape = Stage(device: .laptop, grid: CGSize(width: 1000, height: 560), page: CGRect(x: 110, y: 50, width: 780, height: 440), compact: false)
    static let portrait = Stage(device: .phone, grid: CGSize(width: 560, height: 1000), page: CGRect(x: 78, y: 150, width: 404, height: 700), compact: true)

    // MARK: easing

    static func prog(_ t: Double, _ a: Double, _ b: Double) -> Double { min(1, max(0, (t - a) / (b - a))) }
    static func smooth(_ x: Double) -> Double { x * x * (3 - 2 * x) }
    static func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
    static func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
    static func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }
    static func hash(_ i: Int, _ salt: Double) -> Double { let x = sin(Double(i) * 12.9898 + salt * 78.233) * 43758.5453; return x - floor(x) }

    // MARK: the screen scene

    /// Draws the screen's content at time t (seconds) into a context of the screen's own size.
    static func drawScreen(_ ctx: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        let st = size.height > size.width ? portrait : landscape
        let full = CGRect(origin: .zero, size: size)
        // the screen's own desktop, behind the browser window; it lights up first (frames 0-20)
        let lit = smooth(prog(t, FilmCue.screenLightUp.0, FilmCue.screenLightUp.1))
        ctx.fill(Path(full), with: .linearGradient(Gradient(colors: [Color(red: 0.05, green: 0.06, blue: 0.09).opacity(0.4 + 0.6 * lit), C.ink]), startPoint: pt(0, 0), endPoint: pt(0, size.height)))
        var c = ctx
        // legacy page units -> the screen's coordinates
        let s = st.compact ? 1.9 : 1.28
        let origin = st.compact ? pt(60, 160) : pt(112, 108)
        c.translateBy(x: origin.x, y: origin.y)
        c.scaleBy(x: s, y: s)
        c.translateBy(x: -st.page.minX, y: -st.page.minY)
        page(&c, st, t)
        intruders(&c, st, t)
        setuWindow(&c, st, t)
    }
}
