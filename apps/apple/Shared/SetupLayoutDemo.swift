import SwiftUI

/// The picture of the layout step: the layout that is chosen, shown in use. A mouse pointer moves around a miniature window and does what a person would do in that layout:
/// types in the address bar, opens a tab, brings the sidebar in from the edge, opens the floating pill. It loops, fading between loops, and starts again when another layout is chosen.
///
/// Reduce Motion: one still frame in which the layout is mid-use. It draws only while it is on screen and the app is active.
struct SetupLayoutDemo: View {
    let preset: LayoutPreset

    var body: some View {
        SetupDemoStage { w, h, t, pal in scene(w: w, h: h, t: t, pal: pal) }
            .id(preset)          // another layout restarts the demo
    }

    private typealias K = SetupDemoKit

    /// The page: a hero block that changes colour when "a new page loads", two lines and three cards.
    private func page(_ w: CGFloat, _ h: CGFloat, _ pal: MiniPalette, swap: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: h * 0.035) {
            ZStack {
                RoundedRectangle(cornerRadius: h * 0.025, style: .continuous).fill(pal.hotSoft).opacity(Double(1 - swap))
                RoundedRectangle(cornerRadius: h * 0.025, style: .continuous).fill(Color.purple.opacity(0.28)).opacity(Double(swap))
            }
            .frame(height: h * 0.17)
            Capsule().fill(pal.ink).frame(width: w * (0.52 - 0.14 * swap), height: h * 0.034)
            Capsule().fill(pal.faint).frame(width: w * 0.38, height: h * 0.028)
            HStack(spacing: w * 0.025) { ForEach(0..<3, id: \.self) { _ in RoundedRectangle(cornerRadius: h * 0.02, style: .continuous).fill(pal.faint).frame(height: h * 0.10) } }
            Spacer(minLength: 0)
        }
        .padding(h * 0.045)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(pal.page)
    }

    /// A row of dots that fills in as an address is typed.
    private func typedDots(_ count: Int, _ h: CGFloat, _ pal: MiniPalette) -> some View {
        HStack(spacing: h * 0.026) { ForEach(0..<8, id: \.self) { i in Circle().fill(pal.ink).frame(width: h * 0.032, height: h * 0.032).opacity(i < count ? 1 : 0) } }
    }

    // MARK: The scenes

    @ViewBuilder private func scene(w: CGFloat, h: CGFloat, t: Double, pal: MiniPalette) -> some View {
        switch preset {
        case .classic: classic(w, h, t, pal)
        case .sidebar: sidebar(w, h, t, pal)
        case .minimal: minimal(w, h, t, pal)
        case .floating: floating(w, h, t, pal)
        case .inline, .custom: oneRow(w, h, t, pal)
        }
    }

    /// Tabs on top and a toolbar under them: click the address bar, type, the page loads, a new tab opens.
    private func classic(_ w: CGFloat, _ h: CGFloat, _ t: Double, _ pal: MiniPalette) -> some View {
        let pill = CGPoint(x: w * 0.34, y: h * 0.185)
        let plus = CGPoint(x: w * 0.62, y: h * 0.065)
        let at = K.place(t, [(0, CGPoint(x: w * 0.78, y: h * 0.72)), (0.10, CGPoint(x: w * 0.78, y: h * 0.72)), (0.24, pill), (0.62, pill), (0.74, plus), (0.90, plus), (0.96, CGPoint(x: w * 0.78, y: h * 0.72))])
        let focus = K.ease(t, 0.24, 0.28) - K.ease(t, 0.60, 0.64)
        let typed = Int(K.ease(t, 0.30, 0.52) * 8)
        let swap = K.ease(t, 0.54, 0.62)
        let load = K.ease(t, 0.52, 0.60) * (1 - K.ease(t, 0.60, 0.66))
        let newTab = K.ease(t, 0.78, 0.88)
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                HStack(spacing: h * 0.04) {
                    MiniDots(h: h, p: pal)
                    MiniTab(w: w * 0.17, h: h * 0.075, p: pal, active: newTab < 0.5)
                    MiniTab(w: w * 0.14, h: h * 0.075, p: pal)
                    MiniTab(w: w * 0.14, h: h * 0.075, p: pal)
                    if newTab > 0.01 { MiniTab(w: w * 0.14 * newTab, h: h * 0.075, p: pal, active: newTab >= 0.5) }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, h * 0.05).frame(height: h * 0.13)
                HStack(spacing: h * 0.035) {
                    Circle().fill(pal.ink).frame(width: h * 0.04, height: h * 0.04); Circle().fill(pal.ink).frame(width: h * 0.04, height: h * 0.04)
                    Capsule().fill(pal.faint).overlay(Capsule().strokeBorder(pal.hot, lineWidth: 1 + focus * 1.2))
                        .overlay(alignment: .leading) { K.typedDots(typed, size: h * 0.032, ink: pal.ink).padding(.leading, h * 0.05) }
                        .frame(width: w * 0.50, height: h * 0.075)
                    Spacer(minLength: 0)
                    Circle().fill(pal.ink).frame(width: h * 0.04, height: h * 0.04)
                }
                .padding(.horizontal, h * 0.06).frame(height: h * 0.11)
                ZStack(alignment: .topLeading) {
                    page(w, h * 0.76, pal, swap: swap)
                    Rectangle().fill(pal.hot).frame(width: w * load, height: 2)
                }
            }
            K.pointer(at, ripple: K.ripple(t, [0.24, 0.76]), accent: pal.hot)
        }
    }

    /// The sidebar comes in from the left edge when the pointer goes there, a tab is chosen, the sidebar goes away again.
    private func sidebar(_ w: CGFloat, _ h: CGFloat, _ t: Double, _ pal: MiniPalette) -> some View {
        let sidebarW = w * 0.36
        let show = K.ease(t, 0.14, 0.26) - K.ease(t, 0.70, 0.82)
        let row = K.ease(t, 0.44, 0.50)
        let swap = K.ease(t, 0.48, 0.56)
        let rowY = h * 0.5
        let at = K.place(t, [(0, CGPoint(x: w * 0.66, y: h * 0.55)), (0.08, CGPoint(x: w * 0.66, y: h * 0.55)), (0.16, CGPoint(x: 3, y: h * 0.50)), (0.34, CGPoint(x: sidebarW * 0.45, y: rowY)), (0.46, CGPoint(x: sidebarW * 0.45, y: rowY)), (0.64, CGPoint(x: w * 0.66, y: h * 0.55)), (0.96, CGPoint(x: w * 0.66, y: h * 0.55))])
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                HStack(spacing: h * 0.04) { MiniDots(h: h, p: pal); Spacer(minLength: 0) }.padding(.horizontal, h * 0.05).frame(height: h * 0.10)
                page(w, h * 0.9, pal, swap: swap)
            }
            // the sidebar, slid in over the page
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: h * 0.03) {
                    Capsule().fill(pal.hot).frame(height: h * 0.075)
                    ForEach(0..<4, id: \.self) { i in
                        let active: CGFloat = i == 0 ? 1 - row : (i == 2 ? row : 0)
                        RoundedRectangle(cornerRadius: h * 0.02, style: .continuous).fill(pal.faint).overlay(RoundedRectangle(cornerRadius: h * 0.02, style: .continuous).fill(pal.hotSoft).opacity(Double(active)))
                            .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: h * 0.012, style: .continuous).fill(active > 0.5 ? pal.hot : pal.ink).frame(width: h * 0.04, height: h * 0.04).padding(.leading, h * 0.03) }
                            .frame(height: h * 0.085)
                    }
                    Spacer(minLength: 0)
                }
                .padding(h * 0.05).padding(.top, h * 0.08)
                .frame(width: sidebarW).frame(maxHeight: .infinity)
                .background(pal.window)
                .overlay(alignment: .trailing) { Rectangle().fill(pal.line).frame(width: 0.6) }
                .shadow(color: .black.opacity(0.25 * Double(show)), radius: 10, x: 4)
                Spacer(minLength: 0)
            }
            .offset(x: -sidebarW * (1 - show))
            .opacity(Double(min(1, show * 6)))
            K.pointer(at, ripple: K.ripple(t, [0.46]), accent: pal.hot)
        }
    }

    /// Compact tabs only: click a tab, the page changes; the active tab opens up to show its address.
    private func minimal(_ w: CGFloat, _ h: CGFloat, _ t: Double, _ pal: MiniPalette) -> some View {
        let s1 = h * 0.232 + w * 0.12 + h * 0.03
        let x3 = s1 + 2 * (w * 0.09 + h * 0.03) + w * 0.045
        let click = K.ease(t, 0.26, 0.32)
        let swap = K.ease(t, 0.32, 0.42)
        let open = K.ease(t, 0.46, 0.56) - K.ease(t, 0.78, 0.88)
        let at = K.place(t, [(0, CGPoint(x: w * 0.7, y: h * 0.6)), (0.10, CGPoint(x: w * 0.7, y: h * 0.6)), (0.24, CGPoint(x: x3, y: h * 0.065)), (0.70, CGPoint(x: x3 + w * 0.05, y: h * 0.065)), (0.80, CGPoint(x: w * 0.7, y: h * 0.6)), (0.96, CGPoint(x: w * 0.7, y: h * 0.6))])
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                HStack(spacing: h * 0.03) {
                    MiniDots(h: h, p: pal)
                    MiniTab(w: w * 0.12, h: h * 0.06, p: pal, active: click < 0.5)
                    MiniTab(w: w * 0.09, h: h * 0.06, p: pal)
                    MiniTab(w: w * 0.09, h: h * 0.06, p: pal)
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: h * 0.022, style: .continuous).fill(click >= 0.5 ? pal.hot : pal.faint)
                        if open > 0.2 { K.typedDots(Int(open * 8), size: h * 0.032, ink: pal.ink).padding(.leading, h * 0.035).opacity(Double(open)) }
                    }
                    .frame(width: w * 0.09 + w * 0.22 * open, height: h * 0.06)
                    MiniTab(w: w * 0.09, h: h * 0.06, p: pal)
                    MiniTab(w: w * 0.09, h: h * 0.06, p: pal)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, h * 0.05).frame(height: h * 0.115)
                page(w, h * 0.885, pal, swap: swap)
            }
            K.pointer(at, ripple: K.ripple(t, [0.28]), accent: pal.hot)
        }
    }

    /// No top bar: a pill shows the site. Click it and it opens into an address field with suggestions; later the tabs slide in from the left edge.
    private func floating(_ w: CGFloat, _ h: CGFloat, _ t: Double, _ pal: MiniPalette) -> some View {
        let open = K.ease(t, 0.22, 0.32) - K.ease(t, 0.72, 0.80)
        let typed = Int(K.ease(t, 0.32, 0.50) * 8)
        let suggestions = K.ease(t, 0.50, 0.58) - K.ease(t, 0.70, 0.76)
        let pick = K.ease(t, 0.60, 0.64)
        let swap = K.ease(t, 0.68, 0.76)
        let panel = K.ease(t, 0.84, 0.92) - K.ease(t, 0.96, 1.0)
        let pillW = w * (0.26 + 0.38 * open)
        let at = K.place(t, [(0, CGPoint(x: w * 0.72, y: h * 0.62)), (0.10, CGPoint(x: w * 0.72, y: h * 0.62)), (0.20, CGPoint(x: w * 0.5, y: h * 0.10)), (0.54, CGPoint(x: w * 0.5, y: h * 0.10)), (0.62, CGPoint(x: w * 0.46, y: h * 0.27)), (0.74, CGPoint(x: w * 0.5, y: h * 0.60)), (0.82, CGPoint(x: w * 0.5, y: h * 0.60)), (0.88, CGPoint(x: 3, y: h * 0.50)), (0.96, CGPoint(x: 3, y: h * 0.50))])
        return ZStack(alignment: .topLeading) {
            page(w, h, pal, swap: swap)
            HStack { MiniDots(h: h, p: pal); Spacer() }.padding(h * 0.05)
            // the pill, opening into the address field
            VStack(spacing: h * 0.02) {
                Capsule().fill(pal.hot).frame(width: pillW, height: h * 0.085)
                    .overlay { if open > 0.2 { K.typedDots(typed, size: h * 0.032, ink: pal.ink).colorMultiply(.white).opacity(Double(open)) } else { Capsule().fill(Color.white.opacity(0.85)).frame(width: w * 0.10, height: h * 0.018) } }
                    .shadow(color: pal.hot.opacity(0.35), radius: 5, y: 2)
                if suggestions > 0.02 {
                    VStack(spacing: h * 0.02) {
                        ForEach(0..<3, id: \.self) { i in
                            RoundedRectangle(cornerRadius: h * 0.02, style: .continuous).fill(i == 1 ? pal.hotSoft.opacity(Double(0.4 + 0.6 * pick)) : pal.faint).frame(height: h * 0.07)
                        }
                    }
                    .padding(h * 0.03).frame(width: pillW).background(RoundedRectangle(cornerRadius: h * 0.035, style: .continuous).fill(pal.page).shadow(color: .black.opacity(0.2), radius: 6, y: 3))
                    .opacity(Double(suggestions)).scaleEffect(y: 0.6 + 0.4 * suggestions, anchor: .top)
                }
            }
            .frame(maxWidth: .infinity, alignment: .top).padding(.top, h * 0.055)
            // the tabs, slid in from the left edge
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: h * 0.03) {
                    ForEach(0..<3, id: \.self) { i in RoundedRectangle(cornerRadius: h * 0.02, style: .continuous).fill(i == 0 ? pal.hotSoft : pal.faint).frame(height: h * 0.085) }
                    Spacer(minLength: 0)
                }
                .padding(h * 0.05).padding(.top, h * 0.14).frame(width: w * 0.28).frame(maxHeight: .infinity).background(pal.window)
                .shadow(color: .black.opacity(0.25 * Double(panel)), radius: 10, x: 4)
                Spacer(minLength: 0)
            }
            .offset(x: -w * 0.28 * (1 - panel)).opacity(Double(min(1, panel * 6)))
            K.pointer(at, ripple: K.ripple(t, [0.22, 0.64]), accent: pal.hot)
        }
    }

    /// Everything on one line: tabs beside the address field. Click the field, type, the page loads, a tab is added.
    private func oneRow(_ w: CGFloat, _ h: CGFloat, _ t: Double, _ pal: MiniPalette) -> some View {
        let pill = CGPoint(x: w * 0.36, y: h * 0.065)
        let plus = CGPoint(x: w * 0.78, y: h * 0.065)
        let at = K.place(t, [(0, CGPoint(x: w * 0.7, y: h * 0.62)), (0.10, CGPoint(x: w * 0.7, y: h * 0.62)), (0.22, pill), (0.60, pill), (0.72, plus), (0.90, plus), (0.96, CGPoint(x: w * 0.7, y: h * 0.62))])
        let focus = K.ease(t, 0.22, 0.26) - K.ease(t, 0.58, 0.62)
        let typed = Int(K.ease(t, 0.28, 0.50) * 8)
        let swap = K.ease(t, 0.52, 0.60)
        let newTab = K.ease(t, 0.76, 0.86)
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                HStack(spacing: h * 0.035) {
                    MiniDots(h: h, p: pal)
                    Circle().fill(pal.ink).frame(width: h * 0.04, height: h * 0.04)
                    Capsule().fill(pal.faint).overlay(Capsule().strokeBorder(pal.hot, lineWidth: 1 + focus * 1.2))
                        .overlay(alignment: .leading) { K.typedDots(typed, size: h * 0.032, ink: pal.ink).padding(.leading, h * 0.05) }
                        .frame(width: w * 0.34, height: h * 0.075)
                    MiniTab(w: w * 0.11, h: h * 0.06, p: pal, active: newTab < 0.5)
                    MiniTab(w: w * 0.09, h: h * 0.06, p: pal)
                    MiniTab(w: w * 0.09, h: h * 0.06, p: pal)
                    if newTab > 0.01 { MiniTab(w: w * 0.09 * newTab, h: h * 0.06, p: pal, active: newTab >= 0.5) }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, h * 0.05).frame(height: h * 0.13)
                page(w, h * 0.87, pal, swap: swap)
            }
            K.pointer(at, ripple: K.ripple(t, [0.24, 0.74]), accent: pal.hot)
        }
    }
}
