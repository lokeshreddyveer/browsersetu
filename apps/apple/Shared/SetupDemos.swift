import SwiftUI

// One animated picture for each setup step, in the style of the layout step: a miniature window (or two devices) and a mouse pointer that does what a person would do.
// Each loops, fades between loops, stands still under Reduce Motion, and stops drawing when hidden (see `SetupDemoStage`).

private typealias K = SetupDemoKit

/// The page every window shows: a hero block, two lines and three cards.
private struct DemoPage: View {
    let w: CGFloat, h: CGFloat
    let pal: MiniPalette
    var swap: CGFloat = 0
    var body: some View {
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
}

/// The title row of a window: its three buttons and a few tabs, the first active.
private func titleRow(_ w: CGFloat, _ h: CGFloat, _ pal: MiniPalette, tabs: Int = 3, extra: CGFloat = 0) -> some View {
    HStack(spacing: h * 0.04) {
        MiniDots(h: h, p: pal)
        MiniTab(w: w * 0.17, h: h * 0.075, p: pal, active: true)
        ForEach(1..<max(tabs, 1), id: \.self) { _ in MiniTab(w: w * 0.14, h: h * 0.075, p: pal) }
        if extra > 0.01 { MiniTab(w: w * 0.14 * extra, h: h * 0.075, p: pal, active: extra >= 0.5) }
        Spacer(minLength: 0)
    }
    .padding(.horizontal, h * 0.05).frame(height: h * 0.13)
}

// MARK: - Look

/// The pointer switches the window from dark to light and back, then picks a theme colour.
struct SetupLookDemo: View {
    private let hues: [Double] = [0.53, 0.60, 0.74, 0.07, 0.34]

    var body: some View {
        SetupDemoStage(restT: 0.45) { w, h, t, _ in
            let light = K.ease(t, 0.20, 0.30) - K.ease(t, 0.52, 0.62)
            let pick = K.ease(t, 0.72, 0.78)                       // 0: the first colour, 1: the fourth
            let hue = hues[0] + (hues[3] - hues[0]) * Double(pick)
            let accent = Color(hue: hue, saturation: 0.55, brightness: 0.62 + 0.2 * Double(light))
            let bg = Color(white: 0.13 + 0.84 * Double(light))
            let line = Color(white: 0.34 + 0.34 * Double(1 - light)).opacity(0.5)
            let segIndex = 2 - K.ease(t, 0.20, 0.26) + K.ease(t, 0.52, 0.58)
            let segX: (CGFloat) -> CGFloat = { w * (0.25 + 0.5 * ($0 + 0.5) / 3) }
            let dotX: (Int) -> CGFloat = { w * (0.30 + 0.10 * CGFloat($0)) }
            let at = K.place(t, [(0, CGPoint(x: w * 0.82, y: h * 0.4)), (0.12, CGPoint(x: w * 0.82, y: h * 0.4)), (0.19, CGPoint(x: segX(1), y: h * 0.86)), (0.45, CGPoint(x: segX(1), y: h * 0.86)),
                                (0.51, CGPoint(x: segX(2), y: h * 0.86)), (0.66, CGPoint(x: segX(2), y: h * 0.86)), (0.73, CGPoint(x: dotX(3), y: h * 0.70)), (0.92, CGPoint(x: w * 0.82, y: h * 0.4)), (0.96, CGPoint(x: w * 0.82, y: h * 0.4))])
            ZStack(alignment: .topLeading) {
                Rectangle().fill(bg)
                VStack(alignment: .leading, spacing: h * 0.04) {
                    HStack(spacing: h * 0.04) {
                        HStack(spacing: h * 0.028) { ForEach(0..<3, id: \.self) { _ in Circle().fill(line).frame(width: h * 0.032, height: h * 0.032) } }
                        RoundedRectangle(cornerRadius: h * 0.022, style: .continuous).fill(accent).frame(width: w * 0.17, height: h * 0.075)
                        RoundedRectangle(cornerRadius: h * 0.022, style: .continuous).fill(line.opacity(0.5)).frame(width: w * 0.14, height: h * 0.075)
                        Spacer(minLength: 0)
                    }
                    .padding(.top, h * 0.04)
                    RoundedRectangle(cornerRadius: h * 0.03, style: .continuous).fill(accent.opacity(0.32)).frame(height: h * 0.20)
                    Capsule().fill(line).frame(width: w * 0.5, height: h * 0.034)
                    Capsule().fill(line.opacity(0.6)).frame(width: w * 0.36, height: h * 0.028)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, h * 0.05)
                // the theme colours
                HStack(spacing: w * 0.045) {
                    ForEach(0..<5, id: \.self) { i in
                        let selected = (i == 0 && pick < 0.5) || (i == 3 && pick >= 0.5)
                        Circle().fill(Color(hue: hues[i], saturation: 0.55, brightness: 0.7)).frame(width: h * 0.075, height: h * 0.075)
                            .overlay(Circle().strokeBorder(Color(white: 0.95 - 0.8 * Double(light)), lineWidth: selected ? 1.5 : 0).padding(-3))
                    }
                }
                .position(x: w * 0.5, y: h * 0.70)
                // the appearance switch
                ZStack {
                    Capsule().fill(Color(white: 0.5).opacity(0.22)).frame(width: w * 0.5, height: h * 0.12)
                    Capsule().fill(accent).frame(width: w * 0.5 / 3 - 3, height: h * 0.12 - 4).position(x: segX(segIndex), y: h * 0.86)
                    HStack(spacing: 0) {
                        ForEach(["System", "Light", "Dark"], id: \.self) { name in
                            Text(name).font(.system(size: h * 0.055, weight: .semibold, design: .rounded)).foregroundStyle(name == (segIndex < 0.5 ? "System" : (segIndex < 1.5 ? "Light" : "Dark")) ? Color.white : Color(white: 0.85 - 0.6 * Double(light)).opacity(0.8)).frame(maxWidth: .infinity)
                        }
                    }
                    .frame(width: w * 0.5).position(x: w * 0.5, y: h * 0.86)
                }
                K.pointer(at, ripple: K.ripple(t, [0.20, 0.52, 0.74]), accent: accent)
            }
        }
    }
}

// MARK: - Panels

/// The pointer opens Bookmarks the way the person chose: a column beside the page, a tab of its own, or a card over a dimmed page.
struct SetupPanelsDemo: View {
    let mode: PanelMode

    var body: some View {
        SetupDemoStage(restT: 0.34) { w, h, t, pal in
            let open = K.ease(t, 0.24, 0.36) - K.ease(t, 0.74, 0.84)
            let star = CGPoint(x: w * 0.9, y: h * 0.19)
            let at = K.place(t, [(0, CGPoint(x: w * 0.5, y: h * 0.62)), (0.10, CGPoint(x: w * 0.5, y: h * 0.62)), (0.22, star), (0.30, star), (0.58, CGPoint(x: w * 0.4, y: h * 0.7)), (0.70, star), (0.96, CGPoint(x: w * 0.5, y: h * 0.62))])
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    titleRow(w, h, pal, extra: mode == .tab ? open : 0)
                    HStack(spacing: h * 0.035) {
                        Circle().fill(pal.ink).frame(width: h * 0.04, height: h * 0.04); Circle().fill(pal.ink).frame(width: h * 0.04, height: h * 0.04)
                        Capsule().fill(pal.faint).frame(height: h * 0.075)
                        Image(systemName: "star.fill").font(.system(size: h * 0.07)).foregroundStyle(open > 0.4 ? pal.hot : pal.ink)
                    }
                    .padding(.horizontal, h * 0.06).frame(height: h * 0.11)
                    ZStack(alignment: .topTrailing) {
                        DemoPage(w: w, h: h * 0.76, pal: pal).frame(width: mode == .dock ? w * (1 - 0.36 * open) : w, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
                        if mode == .dock { list(w * 0.36, h * 0.76, pal).offset(x: w * 0.36 * (1 - open)) }
                        if mode == .tab { list(w, h * 0.76, pal).opacity(Double(open)) }
                    }
                    .clipped()
                }
                if mode == .float {
                    Color.black.opacity(0.30 * Double(open))
                    list(w * 0.5, h * 0.5, pal).clipShape(RoundedRectangle(cornerRadius: h * 0.05, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: h * 0.05, style: .continuous).strokeBorder(pal.hot, lineWidth: 1))
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                        .scaleEffect(0.8 + 0.2 * open).opacity(Double(open)).position(x: w * 0.5, y: h * 0.56)
                }
                K.pointer(at, ripple: K.ripple(t, [0.24, 0.72]), accent: pal.hot)
            }
        }
    }

    /// The bookmarks list: a heading and rows of a small square and a line.
    private func list(_ w: CGFloat, _ h: CGFloat, _ pal: MiniPalette) -> some View {
        VStack(alignment: .leading, spacing: h * 0.045) {
            Capsule().fill(pal.hot).frame(width: w * 0.4, height: h * 0.04)
            ForEach(0..<5, id: \.self) { i in
                HStack(spacing: h * 0.03) {
                    RoundedRectangle(cornerRadius: h * 0.015, style: .continuous).fill(i == 0 ? pal.hot : pal.ink).frame(width: h * 0.05, height: h * 0.05)
                    Capsule().fill(pal.faint).frame(width: w * (i == 0 ? 0.62 : 0.5), height: h * 0.04)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(h * 0.06).frame(width: w, height: h, alignment: .topLeading).background(pal.page)
    }
}

// MARK: - Search

/// The pointer clicks the address bar, a keyword chip pops in, suggestions drop down and one is chosen.
struct SetupSearchDemo: View {
    var body: some View {
        SetupDemoStage(restT: 0.52) { w, h, t, pal in
            let pill = CGPoint(x: w * 0.40, y: h * 0.19)
            let focus = K.ease(t, 0.18, 0.22) - K.ease(t, 0.70, 0.74)
            let chip = K.ease(t, 0.26, 0.32)
            let typed = Int(K.ease(t, 0.34, 0.48) * 6)
            let list = K.ease(t, 0.48, 0.56) - K.ease(t, 0.70, 0.76)
            let swap = K.ease(t, 0.70, 0.80)
            let row = CGPoint(x: w * 0.36, y: h * 0.36)
            let at = K.place(t, [(0, CGPoint(x: w * 0.8, y: h * 0.7)), (0.08, CGPoint(x: w * 0.8, y: h * 0.7)), (0.17, pill), (0.50, pill), (0.62, row), (0.74, row), (0.90, CGPoint(x: w * 0.8, y: h * 0.7)), (0.96, CGPoint(x: w * 0.8, y: h * 0.7))])
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    titleRow(w, h, pal)
                    HStack(spacing: h * 0.035) {
                        Circle().fill(pal.ink).frame(width: h * 0.04, height: h * 0.04); Circle().fill(pal.ink).frame(width: h * 0.04, height: h * 0.04)
                        Capsule().fill(pal.faint).overlay(Capsule().strokeBorder(pal.hot, lineWidth: 1 + focus * 1.2))
                            .overlay(alignment: .leading) {
                                HStack(spacing: h * 0.03) {
                                    Text("yt").font(.system(size: h * 0.06, weight: .bold, design: .rounded)).foregroundStyle(.white).padding(.horizontal, h * 0.035).frame(height: h * 0.055)
                                        .background(Capsule().fill(pal.hot)).scaleEffect(chip).opacity(Double(chip))
                                    K.typedDots(typed, size: h * 0.032, ink: pal.ink, total: 6)
                                }
                                .padding(.leading, h * 0.045)
                            }
                            .frame(width: w * 0.62, height: h * 0.075)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, h * 0.06).frame(height: h * 0.11)
                    DemoPage(w: w, h: h * 0.76, pal: pal, swap: swap)
                }
                // the suggestions under the address bar
                VStack(spacing: h * 0.02) {
                    ForEach(0..<3, id: \.self) { i in
                        HStack(spacing: h * 0.03) {
                            Image(systemName: i == 0 ? "play.rectangle.fill" : "magnifyingglass").font(.system(size: h * 0.05)).foregroundStyle(i == 0 ? pal.hot : pal.ink)
                            Capsule().fill(pal.faint).frame(width: w * (0.34 - 0.04 * CGFloat(i)), height: h * 0.035)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, h * 0.03).frame(height: h * 0.075)
                        .background(RoundedRectangle(cornerRadius: h * 0.02, style: .continuous).fill(i == 0 ? pal.hotSoft.opacity(Double(0.4 + 0.6 * K.ease(t, 0.58, 0.62))) : Color.clear))
                    }
                }
                .padding(h * 0.025).frame(width: w * 0.62)
                .background(RoundedRectangle(cornerRadius: h * 0.035, style: .continuous).fill(pal.page).shadow(color: .black.opacity(0.22), radius: 6, y: 3))
                .offset(x: h * 0.06 + h * 0.075 + h * 0.04, y: h * 0.255)
                .opacity(Double(list)).scaleEffect(y: 0.6 + 0.4 * list, anchor: .top)
                K.pointer(at, ripple: K.ripple(t, [0.18, 0.64]), accent: pal.hot)
            }
        }
    }
}

// MARK: - Protection

/// A page loads with ads and trackers; the shield blocks them one by one and its count goes up; the pointer opens what it blocked.
struct SetupProtectionDemo: View {
    var body: some View {
        SetupDemoStage(restT: 0.64) { w, h, t, pal in
            let bad = Color(red: 0.95, green: 0.45, blue: 0.30)
            let appear = K.ease(t, 0.10, 0.22)
            let blocked: [CGFloat] = [K.ease(t, 0.32, 0.40), K.ease(t, 0.40, 0.48), K.ease(t, 0.48, 0.56)]
            let tracker = K.ease(t, 0.56, 0.66)
            let count = Int(blocked.reduce(0, +).rounded(.down)) * 2 + Int(tracker * 3)
            let pop = K.ease(t, 0.78, 0.84) - K.ease(t, 0.92, 0.96)
            let badge = CGPoint(x: w * 0.9, y: h * 0.19)
            let at = K.place(t, [(0, CGPoint(x: w * 0.5, y: h * 0.7)), (0.10, CGPoint(x: w * 0.5, y: h * 0.7)), (0.70, CGPoint(x: w * 0.55, y: h * 0.62)), (0.77, badge), (0.90, badge), (0.96, CGPoint(x: w * 0.5, y: h * 0.7))])
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    titleRow(w, h, pal)
                    HStack(spacing: h * 0.035) {
                        Circle().fill(pal.ink).frame(width: h * 0.04, height: h * 0.04); Circle().fill(pal.ink).frame(width: h * 0.04, height: h * 0.04)
                        Capsule().fill(pal.faint).frame(height: h * 0.075)
                        HStack(spacing: 2) {
                            Image(systemName: "shield.fill").font(.system(size: h * 0.065)).foregroundStyle(pal.hot)
                            Text("\(count)").font(.system(size: h * 0.055, weight: .bold, design: .rounded)).foregroundStyle(pal.hot).frame(minWidth: h * 0.06)
                        }
                    }
                    .padding(.horizontal, h * 0.06).frame(height: h * 0.11)
                    ZStack(alignment: .topLeading) {
                        DemoPage(w: w, h: h * 0.76, pal: pal)
                        // the ads: they appear, then the shield blocks each
                        ForEach(0..<3, id: \.self) { i in
                            let rects: [CGRect] = [CGRect(x: w * 0.05, y: h * 0.50, width: w * 0.42, height: h * 0.14), CGRect(x: w * 0.55, y: h * 0.50, width: w * 0.38, height: h * 0.14), CGRect(x: w * 0.30, y: h * 0.05, width: w * 0.40, height: h * 0.07)]
                            let r = rects[i]
                            RoundedRectangle(cornerRadius: h * 0.02, style: .continuous).fill(bad.opacity(0.85))
                                .overlay(Text("AD").font(.system(size: h * 0.05, weight: .heavy, design: .rounded)).foregroundStyle(.white.opacity(0.9)))
                                .frame(width: r.width, height: r.height)
                                .scaleEffect(1 - 0.6 * blocked[i]).opacity(Double(appear * (1 - blocked[i])))
                                .position(x: r.midX, y: r.midY)
                            Image(systemName: "shield.fill").font(.system(size: h * 0.09)).foregroundStyle(pal.hot).scaleEffect(0.6 + 0.8 * blocked[i]).opacity(Double(blocked[i] * (1 - K.ease(t, 0.34 + 0.08 * Double(i), 0.46 + 0.08 * Double(i)) * 0.0) * (blocked[i] < 0.999 ? 1 : 0)))
                                .position(x: r.midX, y: r.midY)
                        }
                        // trackers: small dots that are zapped together
                        ForEach(0..<4, id: \.self) { i in
                            Circle().fill(bad).frame(width: h * 0.04, height: h * 0.04).opacity(Double(appear * (1 - tracker)))
                                .position(x: w * (0.14 + 0.24 * CGFloat(i)), y: h * 0.40)
                        }
                    }
                }
                // what it blocked, opened from the shield
                VStack(alignment: .leading, spacing: h * 0.03) {
                    Text("\(count) blocked").font(.system(size: h * 0.06, weight: .bold, design: .rounded)).foregroundStyle(pal.hot)
                    ForEach(0..<3, id: \.self) { _ in Capsule().fill(pal.faint).frame(width: w * 0.26, height: h * 0.03) }
                }
                .padding(h * 0.05).background(RoundedRectangle(cornerRadius: h * 0.04, style: .continuous).fill(pal.page).shadow(color: .black.opacity(0.25), radius: 7, y: 3))
                .scaleEffect(0.85 + 0.15 * pop, anchor: .topTrailing).opacity(Double(pop)).position(x: w * 0.78, y: h * 0.40)
                K.pointer(at, ripple: K.ripple(t, [0.78]), accent: pal.hot)
            }
        }
    }
}

// MARK: - Passwords

/// A sign-in types itself, the pointer presses Sign in, the browser offers to save it, and the pointer chooses Save.
struct SetupPasswordsDemo: View {
    var body: some View {
        SetupDemoStage(restT: 0.62) { w, h, t, pal in
            let user = Int(K.ease(t, 0.14, 0.24) * 5)
            let secret = Int(K.ease(t, 0.30, 0.46) * 8)
            let offer = K.ease(t, 0.58, 0.66) - K.ease(t, 0.92, 0.97)
            let saved = K.ease(t, 0.80, 0.86)
            let signIn = CGPoint(x: w * 0.5, y: h * 0.78), saveButton = CGPoint(x: w * 0.40, y: h * 0.30)
            let at = K.place(t, [(0, CGPoint(x: w * 0.85, y: h * 0.6)), (0.08, CGPoint(x: w * 0.85, y: h * 0.6)), (0.13, CGPoint(x: w * 0.5, y: h * 0.50)), (0.28, CGPoint(x: w * 0.5, y: h * 0.50)), (0.30, CGPoint(x: w * 0.5, y: h * 0.62)),
                                (0.50, signIn), (0.56, signIn), (0.72, saveButton), (0.80, saveButton), (0.94, CGPoint(x: w * 0.85, y: h * 0.6))])
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    titleRow(w, h, pal, tabs: 1)
                    ZStack {
                        pal.page
                        VStack(spacing: h * 0.045) {
                            Circle().fill(pal.hotSoft).overlay(Image(systemName: "person.fill").font(.system(size: h * 0.075, weight: .semibold)).foregroundStyle(pal.hot)).frame(width: h * 0.17, height: h * 0.17)
                            RoundedRectangle(cornerRadius: h * 0.03, style: .continuous).fill(pal.faint).frame(height: h * 0.10)
                                .overlay(alignment: .leading) { K.typedDots(user, size: h * 0.032, ink: pal.ink, total: 5).padding(.leading, h * 0.04) }
                            RoundedRectangle(cornerRadius: h * 0.03, style: .continuous).fill(pal.faint).frame(height: h * 0.10)
                                .overlay(alignment: .leading) { K.typedDots(secret, size: h * 0.032, ink: pal.ink).padding(.leading, h * 0.04) }
                            Capsule().fill(pal.hot).frame(height: h * 0.085)
                        }
                        .padding(h * 0.07).frame(width: w * 0.52)
                        .background(RoundedRectangle(cornerRadius: h * 0.05, style: .continuous).fill(Color.primary.opacity(0.04)))
                    }
                }
                // the offer to keep it
                VStack(spacing: h * 0.035) {
                    HStack(spacing: h * 0.04) {
                        Image(systemName: saved > 0.5 ? "checkmark.circle.fill" : "lock.fill").font(.system(size: h * 0.08, weight: .semibold)).foregroundStyle(pal.hot)
                        VStack(alignment: .leading, spacing: h * 0.02) {
                            Capsule().fill(pal.ink).frame(width: w * 0.30, height: h * 0.035)
                            Capsule().fill(pal.faint).frame(width: w * 0.22, height: h * 0.028)
                        }
                    }
                    if saved < 0.5 {
                        HStack(spacing: h * 0.03) {
                            Capsule().fill(pal.hot).frame(width: w * 0.16, height: h * 0.07)
                            Capsule().fill(pal.faint).frame(width: w * 0.16, height: h * 0.07)
                        }
                    }
                }
                .padding(h * 0.05).background(RoundedRectangle(cornerRadius: h * 0.045, style: .continuous).fill(pal.page).shadow(color: .black.opacity(0.25), radius: 7, y: 3))
                .overlay(RoundedRectangle(cornerRadius: h * 0.045, style: .continuous).strokeBorder(pal.line, lineWidth: 0.7))
                .offset(y: -h * 0.12 * (1 - offer)).opacity(Double(offer)).position(x: w * 0.5, y: h * 0.30)
                K.pointer(at, ripple: K.ripple(t, [0.52, 0.76]), accent: pal.hot)
            }
        }
    }
}

// MARK: - Import

/// Three files (bookmarks, passwords, history) are dragged into the window one after another; what each holds fills in.
struct SetupImportDemo: View {
    private let items: [(symbol: String, tint: Color)] = [("star.fill", .orange), ("key.fill", Theme.accent), ("clock.fill", .purple)]

    var body: some View {
        SetupDemoStage(framed: false, size: CGSize(width: 256, height: 176)) { w, h, t, pal in
            let target = CGPoint(x: w * 0.66, y: h * 0.50)
            let starts = (0..<3).map { CGPoint(x: w * 0.12, y: h * (0.22 + 0.28 * CGFloat($0))) }
            let slots: [(Double, Double, Double)] = [(0.08, 0.22, 0.28), (0.34, 0.48, 0.54), (0.60, 0.74, 0.80)]    // grab, drop, done
            let held: Int? = (0..<3).first { t >= slots[$0].0 && t < slots[$0].2 }
            let keys: [(Double, CGPoint)] = [(0, CGPoint(x: w * 0.3, y: h * 0.9)), (0.05, starts[0])] + (0..<3).flatMap { i -> [(Double, CGPoint)] in
                let s = slots[i]; let next = i < 2 ? starts[i + 1] : CGPoint(x: w * 0.3, y: h * 0.9)
                return [(s.0 + 0.01, starts[i]), (s.1, target), (s.2, target), (s.2 + 0.05, next)]
            }
            let at = K.place(t, keys)
            ZStack(alignment: .topLeading) {
                MiniWindowFrame(p: pal) { ww, hh in
                    VStack(spacing: 0) {
                        titleRow(ww, hh, pal, tabs: 2)
                        VStack(alignment: .leading, spacing: hh * 0.05) {
                            ForEach(0..<3, id: \.self) { i in
                                let shown = K.ease(t, slots[i].1, slots[i].2)
                                HStack(spacing: hh * 0.04) {
                                    Image(systemName: items[i].symbol).font(.system(size: hh * 0.075, weight: .semibold)).foregroundStyle(items[i].tint)
                                    VStack(alignment: .leading, spacing: hh * 0.025) {
                                        Capsule().fill(pal.ink).frame(width: ww * (0.34 - 0.04 * CGFloat(i)), height: hh * 0.035)
                                        Capsule().fill(pal.faint).frame(width: ww * 0.5, height: hh * 0.028)
                                    }
                                }
                                .opacity(Double(shown)).offset(y: (1 - shown) * 6)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(hh * 0.08).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(pal.page)
                    }
                }
                .frame(width: w * 0.62, height: h * 0.74).position(x: target.x, y: target.y)
                .shadow(color: .black.opacity(0.3), radius: 14, y: 8)
                // the files waiting on the left, and the one being dragged
                ForEach(0..<3, id: \.self) { i in
                    let dragging = held == i
                    let past = t >= slots[i].2
                    let drop = K.ease(t, slots[i].1, slots[i].2)
                    let pos = dragging ? CGPoint(x: at.x + 6, y: at.y + 10) : starts[i]
                    file(items[i].symbol, items[i].tint, pal)
                        .scaleEffect(dragging ? 1.08 - 0.5 * drop : 1).opacity(past ? 0 : (dragging ? Double(1 - drop * 0.9) : 1))
                        .position(pos)
                }
                K.pointer(at, ripple: K.ripple(t, [slots[0].1, slots[1].1, slots[2].1]), accent: pal.hot)
            }
        }
    }

    private func file(_ symbol: String, _ tint: Color, _ pal: MiniPalette) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(pal.page).overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(pal.line, lineWidth: 0.8))
                .shadow(color: tint.opacity(0.35), radius: 6, y: 3)
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(tint)
        }
        .frame(width: 36, height: 44)
    }
}

// MARK: - Sync

/// A tab is opened on the laptop; a pulse of light carries it to the cloud and on to the phone, where it appears.
struct SetupSyncDemo: View {
    var body: some View {
        SetupDemoStage(restT: 0.62, framed: false, size: CGSize(width: 256, height: 190)) { w, h, t, pal in
            let laptop = CGRect(x: 8, y: 98, width: 124, height: 78), phone = CGRect(x: 192, y: 92, width: 46, height: 88)
            let cloud = CGPoint(x: 128, y: 40)
            let up = K.ease(t, 0.36, 0.52), down = K.ease(t, 0.58, 0.76)
            let newTab = K.ease(t, 0.26, 0.34)
            let arrived = K.ease(t, 0.76, 0.84)
            let from = CGPoint(x: laptop.midX, y: laptop.minY), to = CGPoint(x: phone.midX, y: phone.minY)
            let c1 = CGPoint(x: laptop.midX - 6, y: cloud.y + 24), c2 = CGPoint(x: phone.midX + 14, y: cloud.y + 28)
            let plus = CGPoint(x: laptop.minX + laptop.width * 0.62, y: laptop.minY + laptop.height * 0.065)
            let at = K.place(t, [(0, CGPoint(x: laptop.midX, y: laptop.maxY - 10)), (0.08, CGPoint(x: laptop.midX, y: laptop.maxY - 10)), (0.22, plus), (0.30, plus), (0.46, CGPoint(x: w * 0.5, y: h * 0.80)), (0.96, CGPoint(x: w * 0.5, y: h * 0.80))])
            ZStack(alignment: .topLeading) {
                // the arcs
                Path { p in p.move(to: from); p.addQuadCurve(to: CGPoint(x: cloud.x - 16, y: cloud.y + 16), control: c1) }.stroke(pal.hot.opacity(0.45), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 5]))
                Path { p in p.move(to: CGPoint(x: cloud.x + 16, y: cloud.y + 16)); p.addQuadCurve(to: to, control: c2) }.stroke(pal.hot.opacity(0.45), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 5]))
                // the pulses
                pulse(from: from, control: c1, to: CGPoint(x: cloud.x - 16, y: cloud.y + 16), s: up, pal)
                pulse(from: CGPoint(x: cloud.x + 16, y: cloud.y + 16), control: c2, to: to, s: down, pal)
                Image(systemName: "icloud.fill").font(.system(size: 46)).foregroundStyle(LinearGradient(colors: [pal.hot, pal.hot.opacity(0.62)], startPoint: .top, endPoint: .bottom))
                    .shadow(color: pal.hot.opacity(0.35 + 0.45 * Double(up * (1 - down))), radius: 10 + 10 * (up * (1 - down)), y: 5).position(cloud)
                // the laptop
                MiniWindowFrame(p: pal) { ww, hh in
                    VStack(spacing: 0) {
                        titleRow(ww, hh, pal, tabs: 2, extra: newTab)
                        DemoPage(w: ww, h: hh * 0.87, pal: pal)
                    }
                }
                .frame(width: laptop.width, height: laptop.height).position(x: laptop.midX, y: laptop.midY).shadow(color: .black.opacity(0.3), radius: 10, y: 6)
                // the phone, a new row arriving
                RoundedRectangle(cornerRadius: 11, style: .continuous).fill(pal.page).overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(pal.line, lineWidth: 1))
                    .overlay(alignment: .top) {
                        VStack(spacing: 5) {
                            Capsule().fill(pal.ink).frame(width: 12, height: 3).padding(.top, 5)
                            ForEach(0..<2, id: \.self) { _ in RoundedRectangle(cornerRadius: 3, style: .continuous).fill(pal.faint).frame(height: 12).padding(.horizontal, 6) }
                            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(pal.hot.opacity(0.6)).frame(height: 12).padding(.horizontal, 6).opacity(Double(arrived)).scaleEffect(0.8 + 0.2 * arrived)
                        }
                    }
                    .frame(width: phone.width, height: phone.height).position(x: phone.midX, y: phone.midY).shadow(color: .black.opacity(0.3), radius: 10, y: 6)
                K.pointer(at, ripple: K.ripple(t, [0.24]), accent: pal.hot)
            }
        }
    }

    /// A dot of light somewhere along a curve (0...1 along it), fading in at its start and out at its end.
    private func pulse(from a: CGPoint, control c: CGPoint, to b: CGPoint, s: CGFloat, _ pal: MiniPalette) -> some View {
        let u = 1 - s
        let p = CGPoint(x: u * u * a.x + 2 * u * s * c.x + s * s * b.x, y: u * u * a.y + 2 * u * s * c.y + s * s * b.y)
        let visible = s > 0.001 && s < 0.999
        return Circle().fill(pal.hot).frame(width: 9, height: 9).shadow(color: pal.hot.opacity(0.8), radius: 6).position(p).opacity(visible ? 1 : 0)
    }
}

// MARK: - Media

/// The pointer chooses a format, then presses download; the ring fills and turns into a tick.
struct SetupMediaDemo: View {
    var body: some View {
        SetupDemoStage(restT: 0.7, framed: false, size: CGSize(width: 256, height: 176)) { w, h, t, pal in
            let chosen = K.ease(t, 0.26, 0.32)
            let ring = K.ease(t, 0.46, 0.80)
            let done = K.ease(t, 0.82, 0.88)
            let chip = CGPoint(x: w * 0.83, y: h * 0.34), badge = CGPoint(x: w * 0.10, y: h * 0.82)
            let at = K.place(t, [(0, CGPoint(x: w * 0.55, y: h * 0.45)), (0.08, CGPoint(x: w * 0.55, y: h * 0.45)), (0.22, chip), (0.36, chip), (0.46, badge), (0.84, badge), (0.94, CGPoint(x: w * 0.55, y: h * 0.45))])
            ZStack(alignment: .topLeading) {
                MiniWindowFrame(p: pal) { ww, hh in
                    VStack(spacing: 0) {
                        titleRow(ww, hh, pal, tabs: 1)
                        ZStack {
                            pal.page
                            VStack(spacing: hh * 0.05) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: hh * 0.04, style: .continuous).fill(LinearGradient(colors: [pal.hot.opacity(0.5), Color.purple.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    Circle().fill(.white.opacity(0.92)).frame(width: hh * 0.20, height: hh * 0.20).overlay(Image(systemName: "play.fill").font(.system(size: hh * 0.085, weight: .bold)).foregroundStyle(pal.hot).offset(x: hh * 0.008))
                                }
                                .frame(height: hh * 0.50)
                                Capsule().fill(pal.faint).frame(height: hh * 0.03).overlay(alignment: .leading) { GeometryReader { g in Capsule().fill(pal.hot).frame(width: g.size.width * 0.42) } }
                            }
                            .padding(hh * 0.07)
                        }
                    }
                }
                .frame(width: w * 0.72, height: h * 0.74).position(x: w * 0.44, y: h * 0.46).shadow(color: .black.opacity(0.3), radius: 14, y: 8)
                VStack(alignment: .leading, spacing: 6) {
                    formatChip("4K", selected: chosen < 0.5, pal); formatChip("1080p", selected: chosen >= 0.5, pal); formatChip("MP3", selected: false, pal)
                }
                .position(x: w * 0.83, y: h * 0.46)
                ZStack {
                    Circle().fill(LinearGradient(colors: [pal.hot, pal.hot.opacity(0.62)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Circle().trim(from: 0, to: ring).stroke(Color.white.opacity(0.95), style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90)).padding(4)
                    Image(systemName: done > 0.5 ? "checkmark" : "arrow.down").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                }
                .frame(width: 46, height: 46).shadow(color: pal.hot.opacity(0.5), radius: 10, y: 5).position(badge)
                K.pointer(at, ripple: K.ripple(t, [0.28, 0.48]), accent: pal.hot)
            }
        }
    }

    private func formatChip(_ text: String, selected: Bool, _ pal: MiniPalette) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(selected ? Color.white : Color.primary.opacity(0.75))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(selected ? AnyShapeStyle(pal.hot) : AnyShapeStyle(Color.primary.opacity(0.10))))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(selected ? 0 : 0.12), lineWidth: 0.7))
            .shadow(color: .black.opacity(0.14), radius: 4, y: 2)
    }
}
