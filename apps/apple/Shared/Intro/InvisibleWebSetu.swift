import SwiftUI

// Scene 3 to 5: Browser Setu's boundary, and the four protections, each a real feature (see docs/intro-the-invisible-web.md, section 2):
//   filter  requests to other hosts, and advertising panels, are stopped at the boundary   (content rules, the filter lists)
//   clean   tracking parameters peel off the address                                        (only the ones the link sanitizer strips: utm_*, fbclid, ...; "topic=" stays)
//   refuse  a pop-up is refused after it opens                                              (pop-up blocking)
//   warn    a look-alike destination meets a calm warning page                              (WebKit's fraudulent-website warning, which the app switches on)
// The boundary is drawn once, in a line of ice teal, and then almost vanishes: it lights only where something touches it.

extension InvisibleWeb {

    static func setuWindow(_ c: inout GraphicsContext, _ st: Stage, _ t: Double) {
        guard t > FilmCue.edgeTravels.0 - 0.05 else { return }
        let p = st.page, lay = layout(st)
        let cornerR = st.device == .laptop ? 8.0 : 30.0
        let frame = Path(roundedRect: lay.boundary, cornerRadius: cornerR + 4)
        // the line draws the window's outline; then it almost vanishes, and is a faint edge from here on
        let draw = easeInOut(prog(t, FilmCue.edgeTravels.0, FilmCue.boundaryCompletes.1))
        let calm = smooth(prog(t, FilmCue.boundaryCompletes.1, FilmCue.settleProtection.1))
        let glowAgain = smooth(prog(t, FilmCue.dissolve.0, FilmCue.dissolve.0 + 0.3)) * (1 - smooth(prog(t, FilmCue.dissolve.0 + 0.3, FilmCue.dissolve.1)))
        let strength = (1 - 0.75 * calm) + glowAgain * 0.75
        let outline = frame.trimmedPath(from: 0, to: draw)
        c.drawLayer { l in l.opacity = strength; l.addFilter(.blur(radius: 6)); l.stroke(outline, with: .color(C.accent.opacity(0.85)), style: StrokeStyle(lineWidth: 6, lineCap: .round)) }
        c.stroke(outline, with: .color(C.accentLight.opacity(strength)), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
        if draw < 1 {
            let head = pt(lay.boundary.minX + lay.boundary.width * draw, lay.boundary.minY)
            c.fill(Path(ellipseIn: CGRect(x: head.x - 3.5, y: head.y - 3.5, width: 7, height: 7)), with: .color(C.cream))
        }
        // Browser Setu's own chrome replaces the plain one
        let chromeA = smooth(prog(t, FilmCue.boundaryCompletes.0, FilmCue.boundaryCompletes.1))
        if chromeA > 0 { chrome(&c, st, lay, t, chromeA) }
        // filter: a count of what was stopped
        let countA = smooth(prog(t, FilmCue.boundaryCompletes.0, FilmCue.boundaryCompletes.0 + 0.3)) * (1 - smooth(prog(t, FilmCue.settleProtection.0, FilmCue.settleProtection.1)))
        if countA > 0 {
            var g = c; g.opacity = countA
            let count = Int(14 * easeOut(prog(t, FilmCue.adRejected.0, FilmCue.trackerFiltered.1)))
            let chip = st.compact ? CGRect(x: p.midX - 70, y: lay.boundary.maxY + 12, width: 140, height: 22) : CGRect(x: lay.boundary.maxX - 150, y: lay.boundary.maxY + 12, width: 150, height: 22)
            g.fill(Path(roundedRect: chip, cornerRadius: 11), with: .color(C.deep))
            g.stroke(Path(roundedRect: chip, cornerRadius: 11), with: .color(C.accentLight.opacity(0.7)), lineWidth: 0.9)
            text(&g, "\(count) requests filtered", pt(chip.midX, chip.midY), size: 9.5, weight: .semibold, color: C.cream, anchor: .center)
        }
        warning(&c, st, lay, t)
    }

    // MARK: the boundary lights where something touches it

    static func touch(_ c: inout GraphicsContext, _ at: CGPoint, since dt: Double, st: Stage) {
        guard dt >= 0, dt < 0.9 else { return }
        let k = dt / 0.9
        let b = layout(st).boundary
        let r = 8 + 26 * easeOut(k)
        c.fill(Path(ellipseIn: CGRect(x: at.x - r, y: at.y - r, width: r * 2, height: r * 2)), with: .radialGradient(Gradient(colors: [C.cream.opacity(0.9 * (1 - k)), C.accentLight.opacity(0.5 * (1 - k)), .clear]), center: at, startRadius: 0, endRadius: r))
        // a stretch of the boundary itself, brightening and fading
        let horizontal = abs(at.y - b.minY) < 3 || abs(at.y - b.maxY) < 3
        let half = 30 + 20 * easeOut(k)
        let seg = Path { p in
            if horizontal { p.move(to: pt(at.x - half, at.y)); p.addLine(to: pt(at.x + half, at.y)) }
            else { p.move(to: pt(at.x, at.y - half)); p.addLine(to: pt(at.x, at.y + half)) }
        }
        c.drawLayer { l in l.addFilter(.blur(radius: 4)); l.stroke(seg, with: .color(C.accent.opacity(0.9 * (1 - k))), style: StrokeStyle(lineWidth: 6, lineCap: .round)) }
        c.stroke(seg, with: .color(C.accentLight.opacity(1 - k)), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
    }

    // MARK: Browser Setu's window chrome

    static func chrome(_ c: inout GraphicsContext, _ st: Stage, _ lay: PageLayout, _ t: Double, _ a: Double) {
        let p = st.page, ch = lay.chrome
        var l = c
        l.opacity = a
        l.drawLayer { g in
            g.clip(to: Path(roundedRect: p, cornerRadius: st.device == .laptop ? 6 : 28))
            g.fill(Path(ch), with: .linearGradient(Gradient(colors: [Color(red: 0.12, green: 0.14, blue: 0.18), C.deep]), startPoint: pt(0, ch.minY), endPoint: pt(0, ch.maxY)))
            g.fill(Path(CGRect(x: ch.minX, y: ch.maxY - 1, width: ch.width, height: 1)), with: .color(C.accentLight.opacity(0.18)))
        }
        if st.device == .laptop {
            for (i, col) in [Color(red: 0.93, green: 0.42, blue: 0.40), Color(red: 0.95, green: 0.74, blue: 0.30), Color(red: 0.36, green: 0.80, blue: 0.47)].enumerated() {
                l.fill(Path(ellipseIn: CGRect(x: p.minX + 14 + Double(i) * 12, y: p.minY + 8, width: 7.5, height: 7.5)), with: .color(col.opacity(0.85)))
            }
        }
        if !st.compact {
            let tab = CGRect(x: p.minX + 70, y: p.minY + 4, width: 176, height: 15)
            l.fill(Path(roundedRect: tab, cornerRadius: 6), with: .color(Color.white.opacity(0.09)))
            l.fill(Path(ellipseIn: CGRect(x: tab.minX + 8, y: tab.midY - 3.5, width: 7, height: 7)), with: .color(C.accentLight))
            text(&l, "How do black holes form?", pt(tab.minX + 22, tab.midY), size: 9, weight: .medium, color: C.cream.opacity(0.9))
        }
        let rowY = p.minY + (st.compact ? 22 : 30)
        let addr = CGRect(x: p.minX + (st.compact ? 14 : 70), y: rowY - 9, width: p.width - (st.compact ? 28 : 140), height: 18)
        l.fill(Path(roundedRect: addr, cornerRadius: 9), with: .color(Color.black.opacity(0.38)))
        l.stroke(Path(roundedRect: addr, cornerRadius: 9), with: .color(C.accentLight.opacity(0.22)), lineWidth: 0.7)
        l.fill(Path(roundedRect: CGRect(x: addr.minX + 9, y: rowY - 2, width: 6, height: 5), cornerRadius: 1.2), with: .color(C.accentLight))
        l.stroke(Path { $0.move(to: pt(addr.minX + 10.2, rowY - 2)); $0.addQuadCurve(to: pt(addr.minX + 13.8, rowY - 2), control: pt(addr.minX + 12, rowY - 7)) }, with: .color(C.accentLight), lineWidth: 0.9)
        cleanedAddress(&l, st, pt(addr.minX + 22, rowY), t)
        let pillW = st.compact ? 20.0 : 86.0
        let pill = CGRect(x: addr.maxX - pillW - 4, y: rowY - 7, width: pillW, height: 14)
        l.fill(Path(roundedRect: pill, cornerRadius: 7), with: .color(C.accent.opacity(0.9)))
        if !st.compact { text(&l, "Protection on", pt(pill.midX + 6, pill.midY), size: 8, weight: .semibold, color: C.cream, anchor: .center) }
        l.fill(shieldPath(at: pt(pill.minX + 9, pill.midY), scale: 0.26), with: .color(C.cream))
        // refuse: the pop-up arrives here as a small chip
        let chipA = smooth(prog(t, FilmCue.popupRefused.0 + 0.1, FilmCue.popupRefused.1))
        if chipA > 0 {
            var cc = l; cc.opacity = chipA
            let chip = CGRect(x: pill.minX - (st.compact ? 80 : 98), y: rowY - 7, width: st.compact ? 74 : 92, height: 14)
            cc.fill(Path(roundedRect: chip, cornerRadius: 7), with: .color(C.purple))
            cc.stroke(Path(roundedRect: chip, cornerRadius: 7), with: .color(C.accentLight.opacity(0.5)), lineWidth: 0.7)
            text(&cc, "Pop-up blocked", pt(chip.midX, chip.midY), size: 8, weight: .medium, color: C.cream, anchor: .center)
        }
    }

    static func shieldPath(at o: CGPoint, scale s: Double) -> Path {
        var p = Path()
        p.move(to: pt(o.x, o.y - 34 * s)); p.addCurve(to: pt(o.x + 24 * s, o.y - 26 * s), control1: pt(o.x + 8 * s, o.y - 30 * s), control2: pt(o.x + 16 * s, o.y - 30 * s))
        p.addCurve(to: pt(o.x, o.y + 34 * s), control1: pt(o.x + 24 * s, o.y + 8 * s), control2: pt(o.x + 14 * s, o.y + 24 * s))
        p.addCurve(to: pt(o.x - 24 * s, o.y - 26 * s), control1: pt(o.x - 14 * s, o.y + 24 * s), control2: pt(o.x - 24 * s, o.y + 8 * s))
        p.addCurve(to: pt(o.x, o.y - 34 * s), control1: pt(o.x - 16 * s, o.y - 30 * s), control2: pt(o.x - 8 * s, o.y - 30 * s))
        return p
    }

    // MARK: clean: the tracking parameters come off the address, one by one (the legitimate one stays)

    static func cleanedAddress(_ l: inout GraphicsContext, _ st: Stage, _ at: CGPoint, _ t: Double) {
        let size = st.compact ? 6.4 : 9.0
        let base = baseAddress
        let tokens = st.compact ? ["&utm_source=ad", "&fbclid=2f9a"] : ["&utm_source=ad", "&utm_campaign=spring", "&fbclid=2f9a"]
        func width(_ s: String) -> Double { Double(l.resolve(Text(s).font(.system(size: size, design: .monospaced))).measure(in: CGSize(width: 2000, height: 40)).width) }
        // the last one comes off first
        let when = (0..<tokens.count).map { FilmCue.addressCleaned.0 + Double(tokens.count - 1 - $0) * 0.06 }
        text(&l, base, at, size: size, design: .monospaced, color: C.cream.opacity(0.92))
        var x = at.x + width(base)
        for (i, tok) in tokens.enumerated() {
            let off = easeInOut(prog(t, when[i], when[i] + 0.14))
            if off < 1 {
                var a = l
                a.opacity = 1 - off
                text(&a, tok, pt(x, at.y - 9 * off), size: size, design: .monospaced, color: C.cream.opacity(0.92))
            }
            x += width(tok)
        }
    }

    // MARK: warn: a look-alike destination, followed, meets a calm warning

    static func warning(_ c: inout GraphicsContext, _ st: Stage, _ lay: PageLayout, _ t: Double) {
        let p = st.page
        let link = linkRect(st, lay, t)
        let target = pt(link.minX + 60, link.midY + 4)
        let startAt = pt(p.midX + 80, p.midY + 90)
        let w0 = FilmCue.warning.0
        let pointerIn = easeInOut(prog(t, w0 - 0.27, w0 + 0.03)), pressed = prog(t, w0 + 0.04, w0 + 0.16)
        if pointerIn > 0, t < w0 + 0.4 {
            var a = c
            a.opacity = pointerIn * (1 - smooth(prog(t, w0 + 0.3, w0 + 0.4)))
            let at = pt(lerp(startAt.x, target.x, pointerIn), lerp(startAt.y, target.y, pointerIn))
            var arrow = Path(); arrow.move(to: at); arrow.addLine(to: pt(at.x, at.y + 17)); arrow.addLine(to: pt(at.x + 4.6, at.y + 13)); arrow.addLine(to: pt(at.x + 8, at.y + 20)); arrow.addLine(to: pt(at.x + 10.4, at.y + 19)); arrow.addLine(to: pt(at.x + 7, at.y + 12)); arrow.addLine(to: pt(at.x + 12, at.y + 12)); arrow.closeSubpath()
            a.fill(arrow, with: .color(.white)); a.stroke(arrow, with: .color(C.ink), lineWidth: 1)
            if pressed > 0, pressed < 1 {
                let r = 4 + 20 * easeOut(pressed)
                a.stroke(Path(ellipseIn: CGRect(x: target.x - r, y: target.y - r, width: r * 2, height: r * 2)), with: .color(C.accentLight.opacity(0.8 * (1 - pressed))), lineWidth: 1.6)
            }
        }
        let inA = easeOut(prog(t, w0 + 0.16, w0 + 0.33)), outA = smooth(prog(t, FilmCue.settleProtection.0 + 0.02, FilmCue.settleProtection.1))
        guard inA > 0, outA < 1 else { return }
        var w = c
        w.opacity = inA * (1 - outA)
        let size = st.compact ? CGSize(width: 300, height: 230) : CGSize(width: 340, height: 196)
        let card = CGRect(x: p.midX - size.width / 2, y: p.midY - size.height / 2 + (1 - inA) * 14, width: size.width, height: size.height)
        w.drawLayer { g in g.addFilter(.blur(radius: 18)); g.fill(Path(roundedRect: card.offsetBy(dx: 0, dy: 12), cornerRadius: 16), with: .color(Color.black.opacity(0.7))) }
        w.fill(Path(roundedRect: card, cornerRadius: 16), with: .linearGradient(Gradient(colors: [Color(red: 0.13, green: 0.145, blue: 0.19), C.deep]), startPoint: pt(0, card.minY), endPoint: pt(0, card.maxY)))
        w.stroke(Path(roundedRect: card, cornerRadius: 16), with: .color(C.accentLight.opacity(0.7)), lineWidth: 1.1)
        let ic = pt(card.midX, card.minY + 46)
        w.stroke(Path(ellipseIn: CGRect(x: ic.x - 17, y: ic.y - 17, width: 34, height: 34)), with: .color(C.accentLight), lineWidth: 1.8)
        w.stroke(Path { $0.move(to: pt(ic.x, ic.y - 8)); $0.addLine(to: pt(ic.x, ic.y + 2)) }, with: .color(C.accentLight), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
        w.fill(Path(ellipseIn: CGRect(x: ic.x - 1.7, y: ic.y + 6.3, width: 3.4, height: 3.4)), with: .color(C.accentLight))
        text(&w, "Deceptive website ahead", pt(card.midX, card.minY + 88), size: 17, weight: .semibold, design: .serif, color: C.cream, anchor: .center)
        text(&w, "This page may try to trick you into", pt(card.midX, card.minY + 112), size: 10.5, color: C.cream.opacity(0.72), anchor: .center)
        text(&w, "sharing private information.", pt(card.midX, card.minY + 127), size: 10.5, color: C.cream.opacity(0.72), anchor: .center)
        let press = smooth(prog(t, w0 + 0.4, w0 + 0.45))
        let back = CGRect(x: card.midX - 52, y: card.maxY - 40, width: 104, height: 26)
        w.fill(Path(roundedRect: back, cornerRadius: 13), with: .color(press > 0.5 ? C.accentLight : C.accent))
        text(&w, "Go back", pt(back.midX, back.midY), size: 11.5, weight: .semibold, color: press > 0.5 ? C.ink : C.cream, anchor: .center)
    }

    // MARK: Scene 5: the room has dissolved; the mark, the name and two lines on the near black the setup screens use

    static func closing(_ ctx: inout GraphicsContext, _ size: CGSize, _ st: Stage, _ t: Double, mark: GraphicsContext.ResolvedSymbol?) {
        guard t > FilmCue.dissolve.1 - 0.1 else { return }
        let u = min(size.width / st.grid.width, size.height / st.grid.height)
        let big = (st.compact ? 44.0 : 60.0) * u, line1 = (st.compact ? 22.0 : 30.0) * u, line2 = (st.compact ? 14.0 : 18.0) * u
        let cx = size.width / 2
        let markY = size.height * (st.compact ? 0.34 : 0.34), nameY = size.height * (st.compact ? 0.47 : 0.51)
        let b0 = FilmCue.brand.0, b1 = FilmCue.brand.1
        let a0 = easeOut(prog(t, b0, b0 + 0.3)), a1 = easeOut(prog(t, b0 + 0.08, b0 + 0.4)), a2 = easeOut(prog(t, b0 + 0.2, b1)), a3 = easeOut(prog(t, b0 + 0.3, b1 + 0.1))
        if let mark, a0 > 0 {
            var m = ctx
            m.opacity = a0
            m.translateBy(x: cx, y: markY); m.scaleBy(x: (0.8 + 0.2 * a0) * u * 1.25, y: (0.8 + 0.2 * a0) * u * 1.25)
            m.draw(mark, at: .zero)
        }
        var n = ctx; n.opacity = a1
        let name = Text("Browser ").font(.system(size: big, weight: .regular, design: .serif)).foregroundColor(C.cream) + Text("Setu").font(.system(size: big, weight: .bold, design: .serif)).foregroundColor(C.accentLight)
        n.draw(n.resolve(name), at: pt(cx, nameY + (1 - a1) * 10), anchor: .center)
        var l1 = ctx; l1.opacity = a2
        l1.draw(l1.resolve(Text("The web is yours.").font(.system(size: line1, weight: .regular, design: .serif)).foregroundColor(C.cream)), at: pt(cx, nameY + big * 0.95 + (1 - a2) * 8), anchor: .center)
        var l2 = ctx; l2.opacity = a3
        l2.draw(l2.resolve(Text("Keep the unwanted out.").font(.system(size: line2, weight: .regular)).foregroundColor(C.cream.opacity(0.72))), at: pt(cx, nameY + big * 0.95 + line1 * 1.45 + (1 - a3) * 8), anchor: .center)
        let rule = easeOut(prog(t, b0 + 0.1, b1 + 0.1)) * 60 * u
        ctx.stroke(Path { $0.move(to: pt(cx - rule, nameY + big * 0.55)); $0.addLine(to: pt(cx + rule, nameY + big * 0.55)) }, with: .linearGradient(Gradient(colors: [.clear, C.accentLight.opacity(0.8), .clear]), startPoint: pt(cx - 60 * u, 0), endPoint: pt(cx + 60 * u, 0)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
    }
}
