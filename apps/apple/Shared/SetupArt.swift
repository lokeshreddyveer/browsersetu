import SwiftUI

// The artwork of the first-run assistant: one small set of vector drawings, made of shapes, so it follows the theme's accent and the light or dark scheme, needs no image files, and stays sharp at any size.
// One look throughout: soft gradient bodies, a thin light edge, a quiet shadow, the accent for the one thing each picture is about.

// MARK: - Shapes

/// A shield: flat top, sides that curve in to a point.
struct SetupShield: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = r.width, h = r.height
        p.move(to: CGPoint(x: r.minX + w * 0.5, y: r.minY))
        p.addCurve(to: CGPoint(x: r.minX + w, y: r.minY + h * 0.16), control1: CGPoint(x: r.minX + w * 0.68, y: r.minY + h * 0.10), control2: CGPoint(x: r.minX + w * 0.86, y: r.minY + h * 0.14))
        p.addCurve(to: CGPoint(x: r.minX + w * 0.5, y: r.minY + h), control1: CGPoint(x: r.minX + w, y: r.minY + h * 0.60), control2: CGPoint(x: r.minX + w * 0.74, y: r.minY + h * 0.86))
        p.addCurve(to: CGPoint(x: r.minX, y: r.minY + h * 0.16), control1: CGPoint(x: r.minX + w * 0.26, y: r.minY + h * 0.86), control2: CGPoint(x: r.minX, y: r.minY + h * 0.60))
        p.addCurve(to: CGPoint(x: r.minX + w * 0.5, y: r.minY), control1: CGPoint(x: r.minX + w * 0.14, y: r.minY + h * 0.14), control2: CGPoint(x: r.minX + w * 0.32, y: r.minY + h * 0.10))
        p.closeSubpath()
        return p
    }
}

struct SetupCheck: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + r.width * 0.22, y: r.minY + r.height * 0.54))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.44, y: r.minY + r.height * 0.74))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.80, y: r.minY + r.height * 0.30))
        return p
    }
}

// MARK: - Surfaces

private extension View {
    /// The body of an illustration piece: a soft vertical gradient with a thin lit edge.
    func artBody<S: InsettableShape>(_ shape: S, tint: Color, strength: Double = 0.30) -> some View {
        let fill = LinearGradient(colors: [tint.opacity(strength + 0.20), tint.opacity(strength * 0.50)], startPoint: .top, endPoint: .bottom)
        let edge = LinearGradient(colors: [Color.white.opacity(0.70), Color.white.opacity(0.06)], startPoint: .top, endPoint: .bottom)
        // A soft sheen across the upper half and a faint shade below it, the way light falls on a raised, slightly glassy piece.
        let sheen = LinearGradient(stops: [.init(color: Color.white.opacity(0.30), location: 0), .init(color: Color.white.opacity(0.0), location: 0.55)], startPoint: .top, endPoint: .bottom)
        let shade = LinearGradient(colors: [Color.clear, Color.black.opacity(0.14)], startPoint: .center, endPoint: .bottom)
        return self
            .background(shape.fill(fill))
            .overlay(shape.fill(shade))
            .overlay(shape.inset(by: 0.5).fill(sheen))
            .overlay(shape.strokeBorder(edge, lineWidth: 0.9))
            // Two shadows, a tight dark one and a wide one tinted with the piece's own colour.
            .shadow(color: Color.black.opacity(0.18), radius: 3, y: 2)
            .shadow(color: tint.opacity(0.35), radius: 18, y: 10)
    }
}

/// Fine film grain over a smooth gradient, drawn once (it never animates), so large soft gradients do not band and look less synthetic.
struct SetupGrain: View {
    var opacity = 0.06
    var body: some View {
        Canvas { ctx, size in
            var g = SplitMix(seed: 7)
            let count = Int(size.width * size.height / 90)
            for _ in 0..<min(count, 9000) {
                let x = g.next() * size.width, y = g.next() * size.height
                let v = g.next() > 0.5 ? 1.0 : 0.0
                ctx.fill(Path(CGRect(x: x, y: y, width: 1, height: 1)), with: .color(Color(white: v).opacity(g.next() * 0.9)))
            }
        }
        .drawingGroup()
        .opacity(opacity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
    private struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> Double {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
    }
}

// MARK: - Window diagrams (the layout and panel choices)

/// The colours of a miniature window, from the scheme and whether its choice is the selected one.
struct MiniPalette {
    let scheme: ColorScheme
    let selected: Bool
    var ink: Color { Color.primary.opacity(scheme == .dark ? 0.36 : 0.28) }
    var faint: Color { Color.primary.opacity(scheme == .dark ? 0.15 : 0.11) }
    var hot: Color { Theme.accent.opacity(selected ? 1 : 0.72) }
    var hotSoft: Color { Theme.accent.opacity(selected ? 0.30 : 0.20) }
    var window: Color { scheme == .dark ? Color.white.opacity(0.075) : Color(white: 0.93) }
    var page: Color { scheme == .dark ? Color(white: 0.145) : Color.white }
    var line: Color { Color.primary.opacity(scheme == .dark ? 0.20 : 0.16) }
}

/// The three window buttons, drawn neutral so they never compete with the accent.
struct MiniDots: View {
    let h: CGFloat
    let p: MiniPalette
    var body: some View {
        HStack(spacing: h * 0.028) { ForEach(0..<3, id: \.self) { _ in Circle().fill(p.ink.opacity(0.75)).frame(width: h * 0.032, height: h * 0.032) } }
    }
}

/// The page inside a window: a hero block, two lines and three small cards, so a layout reads as a real page and not as empty space.
struct MiniPage: View {
    let w: CGFloat
    let h: CGFloat
    let p: MiniPalette
    var body: some View {
        VStack(alignment: .leading, spacing: h * 0.035) {
            RoundedRectangle(cornerRadius: h * 0.025, style: .continuous).fill(p.hotSoft).frame(height: h * 0.17)
            Capsule().fill(p.ink).frame(width: w * 0.52, height: h * 0.034)
            Capsule().fill(p.faint).frame(width: w * 0.38, height: h * 0.028)
            HStack(spacing: w * 0.025) { ForEach(0..<3, id: \.self) { _ in RoundedRectangle(cornerRadius: h * 0.02, style: .continuous).fill(p.faint).frame(height: h * 0.10) } }
            Spacer(minLength: 0)
        }
        .padding(h * 0.045)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(p.page)
    }
}

/// A small tab: the active one is filled with the accent.
struct MiniTab: View {
    let w: CGFloat
    let h: CGFloat
    let p: MiniPalette
    var active = false
    var body: some View {
        RoundedRectangle(cornerRadius: h * 0.022, style: .continuous).fill(active ? p.hot : p.faint).frame(width: w, height: h)
    }
}

/// The window itself: rounded, hairline-edged, filled, with whatever its layout puts inside.
struct MiniWindowFrame<Content: View>: View {
    let p: MiniPalette
    @ViewBuilder let content: (CGFloat, CGFloat) -> Content
    var body: some View {
        GeometryReader { geo in
            let shape = RoundedRectangle(cornerRadius: geo.size.height * 0.085, style: .continuous)
            content(geo.size.width, geo.size.height)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .background(p.window)
                .clipShape(shape)
                .overlay(shape.strokeBorder(p.line, lineWidth: 0.8))
        }
    }
}

/// A miniature of the browser window in one of its layouts: what sits where. Used large beside the layout step and small on each choice.
struct SetupWindowGlyph: View {
    let preset: LayoutPreset
    var selected = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = MiniPalette(scheme: scheme, selected: selected)
        MiniWindowFrame(p: p) { w, h in
            switch preset {
            case .sidebar:
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: h * 0.05) {
                        MiniDots(h: h, p: p).padding(.bottom, h * 0.015)
                        Capsule().fill(p.hot).frame(height: h * 0.075)                                                   // the address, in the sidebar
                        VStack(spacing: h * 0.03) {
                            ForEach(0..<4, id: \.self) { i in
                                RoundedRectangle(cornerRadius: h * 0.02, style: .continuous).fill(i == 0 ? p.hotSoft : p.faint).frame(height: h * 0.085)
                                    .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: h * 0.012, style: .continuous).fill(i == 0 ? p.hot : p.ink).frame(width: h * 0.04, height: h * 0.04).padding(.leading, h * 0.03) }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(h * 0.05).frame(width: w * 0.30, alignment: .topLeading).frame(maxHeight: .infinity)
                    Rectangle().fill(p.line).frame(width: 0.6)
                    MiniPage(w: w * 0.70, h: h, p: p)
                }
            case .classic:
                VStack(spacing: 0) {
                    HStack(spacing: h * 0.04) {
                        MiniDots(h: h, p: p)
                        MiniTab(w: w * 0.17, h: h * 0.075, p: p, active: true)
                        ForEach(0..<3, id: \.self) { _ in MiniTab(w: w * 0.14, h: h * 0.075, p: p) }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, h * 0.05).frame(height: h * 0.13)
                    HStack(spacing: h * 0.035) {
                        Circle().fill(p.ink).frame(width: h * 0.04, height: h * 0.04); Circle().fill(p.ink).frame(width: h * 0.04, height: h * 0.04)
                        Capsule().fill(p.faint).overlay(Capsule().strokeBorder(p.hot, lineWidth: 1)).frame(width: w * 0.50, height: h * 0.07)
                        Spacer(minLength: 0)
                        Circle().fill(p.ink).frame(width: h * 0.04, height: h * 0.04)
                    }
                    .padding(.horizontal, h * 0.06).frame(height: h * 0.11)
                    MiniPage(w: w, h: h * 0.76, p: p)
                }
            case .minimal:
                VStack(spacing: 0) {
                    HStack(spacing: h * 0.03) {
                        MiniDots(h: h, p: p)
                        MiniTab(w: w * 0.12, h: h * 0.06, p: p, active: true)
                        ForEach(0..<5, id: \.self) { _ in MiniTab(w: w * 0.09, h: h * 0.06, p: p) }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, h * 0.05).frame(height: h * 0.115)
                    MiniPage(w: w, h: h * 0.885, p: p)
                }
            case .floating:
                ZStack(alignment: .top) {
                    MiniPage(w: w, h: h, p: p)
                    HStack { MiniDots(h: h, p: p); Spacer() }.padding(h * 0.05).frame(maxHeight: .infinity, alignment: .top)
                    Capsule().fill(p.hot).frame(width: w * 0.28, height: h * 0.075).padding(.top, h * 0.045)
                        .overlay { Capsule().fill(Color.white.opacity(0.85)).frame(width: w * 0.11, height: h * 0.018).padding(.top, h * 0.045) }
                    HStack { Capsule().fill(p.ink).frame(width: w * 0.016, height: h * 0.30); Spacer() }.frame(maxHeight: .infinity).padding(.leading, h * 0.03)
                }
            case .inline, .custom:
                VStack(spacing: 0) {
                    HStack(spacing: h * 0.035) {
                        MiniDots(h: h, p: p)
                        Circle().fill(p.ink).frame(width: h * 0.04, height: h * 0.04)
                        Capsule().fill(p.faint).overlay(Capsule().strokeBorder(p.hot, lineWidth: 1)).frame(width: w * 0.34, height: h * 0.07)
                        MiniTab(w: w * 0.11, h: h * 0.06, p: p, active: true)
                        MiniTab(w: w * 0.09, h: h * 0.06, p: p)
                        MiniTab(w: w * 0.09, h: h * 0.06, p: p)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, h * 0.05).frame(height: h * 0.13)
                    MiniPage(w: w, h: h * 0.87, p: p)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// A miniature of where Bookmarks, History and Downloads open.
struct SetupPanelGlyph: View {
    let mode: PanelMode
    var selected = false
    @Environment(\.colorScheme) private var scheme

    /// Three rows of a list: a small square and a line.
    private func rows(_ h: CGFloat, _ p: MiniPalette, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: h * 0.04) {
            ForEach(0..<4, id: \.self) { i in
                HStack(spacing: h * 0.03) {
                    RoundedRectangle(cornerRadius: h * 0.012, style: .continuous).fill(i == 0 ? p.hot : p.ink).frame(width: h * 0.04, height: h * 0.04)
                    Capsule().fill(i == 0 ? p.hot.opacity(0.55) : p.faint).frame(width: width * (i == 0 ? 0.80 : 0.64), height: h * 0.035)
                }
            }
        }
    }

    var body: some View {
        let p = MiniPalette(scheme: scheme, selected: selected)
        MiniWindowFrame(p: p) { w, h in
            VStack(spacing: 0) {
                HStack(spacing: h * 0.04) {
                    MiniDots(h: h, p: p)
                    MiniTab(w: w * 0.17, h: h * 0.075, p: p, active: mode != .tab)
                    if mode == .tab { MiniTab(w: w * 0.17, h: h * 0.075, p: p, active: true) }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, h * 0.05).frame(height: h * 0.13)
                ZStack {
                    switch mode {
                    case .dock:
                        HStack(spacing: 0) {
                            MiniPage(w: w * 0.62, h: h * 0.87, p: p)
                            Rectangle().fill(p.line).frame(width: 0.6)
                            VStack(alignment: .leading, spacing: h * 0.04) {
                                Capsule().fill(p.hot).frame(width: w * 0.14, height: h * 0.04)
                                rows(h, p, width: w * 0.30)
                                Spacer(minLength: 0)
                            }
                            .padding(h * 0.05).frame(width: w * 0.38, alignment: .topLeading).frame(maxHeight: .infinity).background(p.hotSoft.opacity(0.55))
                        }
                    case .tab:
                        VStack(alignment: .leading, spacing: h * 0.05) {
                            Capsule().fill(p.hot).frame(width: w * 0.20, height: h * 0.04)
                            rows(h, p, width: w * 0.62)
                            Spacer(minLength: 0)
                        }
                        .padding(h * 0.07).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(p.page)
                    case .float:
                        MiniPage(w: w, h: h * 0.87, p: p)
                        Color.black.opacity(scheme == .dark ? 0.32 : 0.14)
                        RoundedRectangle(cornerRadius: h * 0.045, style: .continuous).fill(p.page)
                            .overlay(RoundedRectangle(cornerRadius: h * 0.045, style: .continuous).strokeBorder(p.hot, lineWidth: 1))
                            .overlay(alignment: .topLeading) {
                                VStack(alignment: .leading, spacing: h * 0.04) { Capsule().fill(p.hot).frame(width: w * 0.12, height: h * 0.035); rows(h, p, width: w * 0.30) }.padding(h * 0.05)
                            }
                            .frame(width: w * 0.48, height: h * 0.50).shadow(color: .black.opacity(0.28), radius: h * 0.04, y: h * 0.02)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - The picture beside each step

/// The large illustration of a step. Calm by design: one slow drift of light behind it (still with Reduce Motion), nothing else moves.
struct SetupIllustration: View {
    enum Kind { case welcome, look, layout, panels, search, protection, passwords, importData, sync, media, done }
    let kind: Kind
    var layout: LayoutPreset = .classic
    var panel: PanelMode = .dock
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The glow and the confetti are drawn behind and over the picture but take no room: a wider layout would push the pane's other content out of it.
        art.frame(width: 230, height: 230)
            .background { SetupAmbient(reduceMotion: reduceMotion).frame(width: 230, height: 230) }
            .overlay { if kind == .done { SetupConfetti().frame(width: 480, height: 480).fixedSize() } }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var art: some View {
        switch kind {
        case .welcome: welcome
        case .look: SetupLookDemo().frame(width: 256, height: 160).shadow(color: .black.opacity(scheme == .light ? 0.16 : 0.45), radius: 22, y: 12)
        case .layout: SetupLayoutDemo(preset: layout).frame(width: 256, height: 160).shadow(color: .black.opacity(scheme == .light ? 0.16 : 0.45), radius: 22, y: 12)
        case .panels: SetupPanelsDemo(mode: panel).frame(width: 256, height: 160).shadow(color: .black.opacity(scheme == .light ? 0.16 : 0.45), radius: 22, y: 12)
        case .search: SetupSearchDemo().frame(width: 256, height: 160).shadow(color: .black.opacity(scheme == .light ? 0.16 : 0.45), radius: 22, y: 12)
        case .protection: SetupProtectionDemo().frame(width: 256, height: 160).shadow(color: .black.opacity(scheme == .light ? 0.16 : 0.45), radius: 22, y: 12)
        case .passwords: SetupPasswordsDemo().frame(width: 256, height: 160).shadow(color: .black.opacity(scheme == .light ? 0.16 : 0.45), radius: 22, y: 12)
        case .importData: SetupImportDemo()
        case .sync: SetupSyncDemo()
        case .media: SetupMediaDemo()
        case .done: done
        }
    }

    private var accent: Color { Theme.accent }

    /// The mark: a lit orb with a shield in it, rings that spread out once and then breathe, and three small lights that circle it.
    private var welcome: some View { SetupWelcomeArt(accent: accent) }

    /// A disc that is light on one side and dark on the other, with the theme colours beneath it.
    private var done: some View { SetupDoneArt(accent: accent) }
}

// MARK: - Motion pieces

/// Drives a view's entrance: false at first, true a moment later, with a spring. With Reduce Motion it is true at once and nothing moves.
private struct SetupEntrance: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var shown: Bool
    func body(content: Content) -> some View {
        content.onAppear {
            if reduceMotion { shown = true } else { withAnimation(.spring(response: 0.7, dampingFraction: 0.62)) { shown = true } }
        }
    }
}

/// The welcome picture: the orb springs in, the shield and its check draw themselves, rings spread out and then breathe, three lights circle.
struct SetupWelcomeArt: View {
    let accent: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var shown = false
    @State private var drawn = false
    @State private var visible = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || !visible || scenePhase != .active)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let breathe = reduceMotion ? 0 : sin(t * 0.8 - Double(i) * 0.7) * 0.025
                    Circle().strokeBorder(accent.opacity(0.34 - Double(i) * 0.09), lineWidth: 1)
                        .frame(width: 120 + CGFloat(i) * 46, height: 120 + CGFloat(i) * 46)
                        .scaleEffect(shown ? 1 + breathe : 0.55).opacity(shown ? 1 : 0)
                        .animation(reduceMotion ? nil : .spring(response: 0.9, dampingFraction: 0.7).delay(0.12 * Double(i)), value: shown)
                }
                // the orb: it springs in, the shield pops up and the check draws itself
                Circle().fill(RadialGradient(colors: [accent.opacity(0.95), accent.opacity(0.40)], center: .init(x: 0.35, y: 0.25), startRadius: 4, endRadius: 80)).frame(width: 118, height: 118)
                    .overlay(Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.7), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
                    .shadow(color: accent.opacity(0.55), radius: 26, y: 8)
                    .scaleEffect(shown ? 1 : 0.4)
                SetupShield().fill(Color.white.opacity(0.92)).frame(width: 46, height: 54).shadow(color: .black.opacity(0.2), radius: 3, y: 2)
                    .scaleEffect(shown ? 1 : 0.2).opacity(shown ? 1 : 0)
                SetupCheck().trim(from: 0, to: drawn ? 1 : 0).stroke(accent, style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round)).frame(width: 30, height: 30).offset(y: -1)
                ForEach(0..<3, id: \.self) { i in
                    let radius = 60 + CGFloat(i) * 23
                    let a = Double(i) * 2.1 + 0.5 + t * (0.32 - Double(i) * 0.07)
                    Circle().fill(Color.white.opacity(0.9)).frame(width: 7 - CGFloat(i), height: 7 - CGFloat(i)).shadow(color: .white.opacity(0.8), radius: 4)
                        .offset(x: cos(a) * radius, y: sin(a) * radius).opacity(shown ? 1 : 0)
                }
            }
        }
        .modifier(SetupEntrance(shown: $shown))
        .onAppear {
            visible = true
            if reduceMotion { drawn = true } else { withAnimation(.easeOut(duration: 0.55).delay(0.45)) { drawn = true } }
        }
        .onDisappear { visible = false }
    }
}

/// The last picture: the orb springs in, its check draws itself, rays spread, and a ring of light pulses outward. The confetti is a separate layer.
struct SetupDoneArt: View {
    let accent: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var shown = false
    @State private var drawn = false
    @State private var visible = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || !visible || scenePhase != .active)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            ZStack {
                // Two rings of light that leave the orb one after the other, again and again.
                ForEach(0..<2, id: \.self) { i in
                    let phase = reduceMotion ? 0 : (t * 0.45 + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
                    Circle().strokeBorder(accent.opacity(0.55 * (1 - phase)), lineWidth: 2).frame(width: 130, height: 130).scaleEffect(1 + phase * 0.9).opacity(shown ? 1 : 0)
                }
                ForEach(0..<12, id: \.self) { i in
                    Capsule().fill(accent.opacity(0.6)).frame(width: 4, height: i % 2 == 0 ? 16 : 9)
                        .offset(y: shown ? -92 : -60).rotationEffect(.degrees(Double(i) * 30 + (reduceMotion ? 0 : t * 6))).opacity(shown ? 1 : 0)
                        .animation(reduceMotion ? nil : .spring(response: 0.8, dampingFraction: 0.6).delay(0.25 + Double(i) * 0.02), value: shown)
                }
                Circle().fill(RadialGradient(colors: [accent.opacity(0.95), accent.opacity(0.45)], center: .init(x: 0.35, y: 0.25), startRadius: 4, endRadius: 90)).frame(width: 130, height: 130)
                    .overlay(Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.7), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
                    .shadow(color: accent.opacity(0.55), radius: 26, y: 8)
                    .scaleEffect(shown ? 1 : 0.3)
                SetupCheck().trim(from: 0, to: drawn ? 1 : 0).stroke(.white, style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round)).frame(width: 64, height: 64)
            }
        }
        .modifier(SetupEntrance(shown: $shown))
        .onAppear {
            visible = true
            if reduceMotion { drawn = true } else { withAnimation(.easeOut(duration: 0.5).delay(0.4)) { drawn = true } }
        }
        .onDisappear { visible = false }
    }
}

/// A burst of confetti from the middle that rises, spreads, falls and fades once, in the accent and its neighbours. Nothing with Reduce Motion; it stops drawing when the window is hidden.
struct SetupConfetti: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var start = Date()
    @State private var visible = false

    private struct Piece { let angle, speed, spin, size, delay: Double; let color: Int; let kind: Int }
    /// The same pieces every time: a hash of the index, so the burst is composed, not random.
    private static let pieces: [Piece] = (0..<84).map { i in
        func r(_ k: Int) -> Double {
            var z = UInt64(i &* 7919 &+ k &* 104729) &+ 0x9E3779B97F4A7C15
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
        return Piece(angle: -Double.pi / 2 + (r(1) - 0.5) * 2.7, speed: 170 + r(2) * 230, spin: (r(3) - 0.5) * 16, size: 5 + r(4) * 6, delay: r(5) * 0.3, color: Int(r(6) * 7) % 7, kind: Int(r(7) * 3))
    }

    var body: some View {
        TimelineView(.animation(paused: reduceMotion || !visible || scenePhase != .active)) { context in
            let t = context.date.timeIntervalSince(start)
            Canvas { g, size in
                guard !reduceMotion else { return }
                let colors: [Color] = [Theme.accent, .purple, .cyan, .pink, .orange, .yellow, .mint]
                let centre = CGPoint(x: size.width / 2, y: size.height / 2 + 6)
                for p in Self.pieces {
                    let tt = t - p.delay
                    guard tt > 0, tt < 3.8 else { continue }
                    let reach = p.speed * (1 - exp(-tt * 1.2)) / 1.2
                    let x = centre.x + cos(p.angle) * reach
                    let y = centre.y + sin(p.angle) * reach + 0.5 * 110 * tt * tt
                    var c = g
                    c.translateBy(x: x, y: y)
                    c.rotate(by: .radians(p.spin * tt))
                    c.opacity = tt < 2.7 ? 1 : max(0, 1 - (tt - 2.7))
                    let flip = abs(cos(tt * 5 + p.spin))                       // a tumbling piece is thin when it is edge-on
                    let rect = CGRect(x: -p.size / 2, y: -p.size * 0.33 * flip, width: p.size, height: p.size * 0.66 * flip + 0.5)
                    let colour = colors[p.color]
                    switch p.kind {
                    case 0: c.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(colour))
                    case 1: c.fill(Path(ellipseIn: rect), with: .color(colour))
                    default: c.fill(Path(roundedRect: CGRect(x: -p.size * 0.12, y: -p.size / 2, width: p.size * 0.24, height: p.size), cornerRadius: 1), with: .color(colour))
                    }
                }
            }
        }
        .onAppear { start = Date(); visible = true }
        .onDisappear { visible = false }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Soft light behind an illustration: three blurred discs of the accent and its neighbours that drift very slowly. Still with Reduce Motion, and it stops drawing when the window is not shown.
struct SetupAmbient: View {
    let reduceMotion: Bool
    @State private var visible = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency {
            // Reduce Transparency: one still, unblurred wash instead of blurred moving discs.
            RadialGradient(colors: [Theme.accent.opacity(0.30), .clear], center: .center, startRadius: 0, endRadius: 150).allowsHitTesting(false)
        } else { moving }
    }

    private var moving: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: reduceMotion || !visible || scenePhase != .active)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            ZStack {
                disc(Theme.accent, 0.55, size: 330, x: sin(t / 7) * 22, y: cos(t / 9) * 16)
                disc(Color.purple, 0.32, size: 270, x: cos(t / 8) * 40 + 34, y: sin(t / 6) * 26 - 30)
                disc(Color.cyan, 0.28, size: 240, x: sin(t / 10) * 36 - 40, y: cos(t / 7) * 24 + 36)
            }
        }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .allowsHitTesting(false)
    }

    /// A soft light: a radial gradient that is fully clear at its own edge, so it needs no blur and has no edge to cut off.
    private func disc(_ c: Color, _ a: Double, size: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        Circle().fill(RadialGradient(colors: [c.opacity(a), c.opacity(a * 0.45), c.opacity(a * 0.12), .clear], center: .center, startRadius: 0, endRadius: size / 2))
            .frame(width: size, height: size).offset(x: x, y: y)
    }
}


/// The default look in light: a soft daylight sky (cool white, with pale teal, lilac and warm glows), not the dark theme turned inside out.
struct DaylightBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.968, green: 0.975, blue: 0.988), Color(red: 0.926, green: 0.940, blue: 0.964)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(red: 0.60, green: 0.82, blue: 0.93).opacity(0.55), .clear], center: .init(x: 0.14, y: 0.10), startRadius: 0, endRadius: 640)
            RadialGradient(colors: [Color(red: 0.80, green: 0.75, blue: 0.97).opacity(0.45), .clear], center: .init(x: 0.90, y: 0.18), startRadius: 0, endRadius: 560)
            RadialGradient(colors: [Color(red: 0.99, green: 0.87, blue: 0.76).opacity(0.42), .clear], center: .init(x: 0.72, y: 1.0), startRadius: 0, endRadius: 640)
            SetupGrain(opacity: 0.05)
        }
        .accessibilityHidden(true)
    }
}


/// The raised row inside the setup card: in dark a faint lift of the text colour; in light a white sheet with a hairline and a whisper of shadow.
private struct SetupRowSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        if scheme == .light {
            content.background(shape.fill(Color.white.opacity(0.92)))
                .overlay(shape.strokeBorder(Color.black.opacity(0.07), lineWidth: 0.5))
                .shadow(color: Theme.accent.opacity(0.07), radius: 6, y: 2)
        } else {
            content.background(shape.fill(Color.primary.opacity(0.055)))
                .overlay(shape.strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
        }
    }
}
extension View { func setupRowSurface() -> some View { modifier(SetupRowSurface()) } }
