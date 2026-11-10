import SwiftUI

// The article, and what reaches for it. An invented science magazine ("Cosmos Daily") shows an article, "How do black holes form?". While a person reads it, four unwanted things reach for the page:
// advertising panels, requests to tracking hosts, a link with tracking parameters, and a link whose destination is not what its text says; and a pop-up opens. Everything is on the stage's grid, relative to the page rect.

extension InvisibleWeb {

    // MARK: text

    static func text(_ c: inout GraphicsContext, _ s: String, _ p: CGPoint, size: Double, weight: Font.Weight = .regular, design: Font.Design = .default, color: Color, anchor: UnitPoint = .leading, tracking: Double = 0) {
        var t = Text(s).font(.system(size: size, weight: weight, design: design)).foregroundColor(color)
        if tracking != 0 { t = t.tracking(tracking) }
        c.draw(c.resolve(t), at: p, anchor: anchor)
    }

    static let mark = Color(red: 0.62, green: 0.50, blue: 0.80)      // the muted purple, lifted so it reads on the dark: "look here"
    static let hostNames = ["analytics.example", "pixel.example", "metrics.example", "adnet.example", "tagmgr.example"]
    static let baseAddress = "cosmosdaily.example/black-holes?topic=stars"
    static let trackedAddress = "cosmosdaily.example/black-holes?topic=stars&utm_source=ad&utm_campaign=spring&fbclid=2f9a"

    // MARK: the page's layout

    struct PageLayout {
        var chrome: CGRect, nav: CGRect, hero: CGRect
        var body: CGRect          // the visible window onto the scrolling article
        var side: CGRect          // the column (or strip) beside the text, where an advertisement is reserved
        var boundary: CGRect      // Browser Setu's window edge
        var panel: CGRect         // the pop-up
        var hosts: [CGPoint], sources: [CGPoint]
    }

    static func layout(_ st: Stage) -> PageLayout {
        let p = st.page
        let b = p.insetBy(dx: -6, dy: -6)
        if st.compact {
            let y0 = p.minY + 40
            let heroBottom = y0 + 32 + 170
            return PageLayout(chrome: CGRect(x: p.minX, y: p.minY, width: p.width, height: 40), nav: CGRect(x: p.minX, y: y0, width: p.width, height: 32),
                              hero: CGRect(x: p.minX, y: y0 + 32, width: p.width, height: 170),
                              body: CGRect(x: p.minX + 20, y: heroBottom + 12, width: p.width - 40, height: p.maxY - heroBottom - 190),
                              side: CGRect(x: p.minX + 20, y: p.maxY - 164, width: p.width - 40, height: 128), boundary: b,
                              panel: CGRect(x: p.midX - 150, y: p.midY - 110, width: 300, height: 240),
                              hosts: (0..<4).map { pt(p.minX + 52 + Double($0) * 104, p.maxY + 60) },
                              sources: [pt(p.midX, p.minY + 150), pt(p.maxX - 40, p.minY + 330), pt(p.midX, p.midY + 40), pt(p.maxX - 60, p.maxY - 100)])
        }
        let y0 = p.minY + 40
        let heroBottom = y0 + 34 + 150
        return PageLayout(chrome: CGRect(x: p.minX, y: p.minY, width: p.width, height: 40), nav: CGRect(x: p.minX, y: y0, width: p.width, height: 34),
                          hero: CGRect(x: p.minX, y: y0 + 34, width: p.width, height: 150),
                          body: CGRect(x: p.minX + 34, y: heroBottom + 12, width: 440, height: p.maxY - heroBottom - 12),
                          side: CGRect(x: p.minX + 508, y: heroBottom + 14, width: 238, height: 126), boundary: b,
                          panel: CGRect(x: p.midX - 175, y: p.midY - 96, width: 350, height: 214),
                          hosts: (0..<5).map { pt(p.maxX + 92, p.minY + 46 + Double($0) * 86) },
                          sources: [pt(p.minX + p.width * 0.72, y0 + 110), pt(p.minX + 470, heroBottom + 60), pt(p.minX + 628, heroBottom + 80), pt(p.minX + 330, heroBottom + 120), pt(p.maxX - 70, y0 + 17)])
    }

    // MARK: where the article is scrolled to

    static func scroll(_ t: Double) -> Double {
        // a little while it is read, a little more as things reach, still while the boundary works, then peacefully
        let a = 8 * smooth(prog(t, FilmCue.scroll1.0 - 0.9, FilmCue.scroll1.1)), b = 16 * smooth(prog(t, FilmCue.separate.0, FilmCue.settle.1)), c = 118 * easeInOut(prog(t, FilmCue.calm.0, FilmSpec.duration))
        return a + b + c
    }

    /// The inline link in the article (the look-alike), where it is on the page at the moment (it moves with the scroll).
    static func linkRect(_ st: Stage, _ lay: PageLayout, _ t: Double) -> CGRect {
        let base = lay.body.minY + 14 + (st.compact ? 80 : 132)
        return CGRect(x: lay.body.minX, y: base - scroll(t), width: st.compact ? 190 : 214, height: 16)
    }

    // MARK: the page itself

    static func page(_ c: inout GraphicsContext, _ st: Stage, _ t: Double) {
        let p = st.page, lay = layout(st)
        let appear = smooth(prog(t, FilmCue.pageAppears.0, FilmCue.pageAppears.1))
        var l = c
        l.opacity = appear
        let screen = Path(roundedRect: p, cornerRadius: st.device == .laptop ? 6 : 28)
        l.drawLayer { g in
            g.clip(to: screen)
            // the browser the page is in: a plain grey one, nobody's brand
            let generic = 1 - smooth(prog(t, FilmCue.boundaryCompletes.0, FilmCue.boundaryCompletes.1))
            g.fill(Path(lay.chrome), with: .color(Color(red: 0.11, green: 0.115, blue: 0.14)))
            if generic > 0 {
                var q = g; q.opacity = generic
                for i in 0..<3 { q.fill(Path(ellipseIn: CGRect(x: p.minX + 14 + Double(i) * 12, y: p.minY + 16, width: 7.5, height: 7.5)), with: .color(Color.white.opacity(0.18))) }
                let addr = CGRect(x: p.minX + (st.compact ? 14 : 80), y: p.minY + 9, width: p.width - (st.compact ? 28 : 160), height: 22)
                q.fill(Path(roundedRect: addr, cornerRadius: 11), with: .color(Color.black.opacity(0.35)))
                text(&q, baseAddress, pt(addr.midX, addr.midY), size: st.compact ? 8.5 : 10.5, color: C.secondary, anchor: .center)
            }
            g.fill(Path(CGRect(x: p.minX, y: lay.chrome.maxY, width: p.width, height: p.height - lay.chrome.height)), with: .color(Color(red: 0.07, green: 0.075, blue: 0.095)))
            // the magazine's bar
            text(&g, "Cosmos Daily", pt(p.minX + (st.compact ? 20 : 34), lay.nav.midY), size: 15, weight: .bold, design: .serif, color: C.cream)
            if !st.compact { for (i, s) in ["Space", "Physics", "Earth", "Subscribe"].enumerated() { text(&g, s, pt(p.maxX - 330 + Double(i) * 70, lay.nav.midY), size: 11, color: i == 3 ? C.cream.opacity(0.95) : C.secondary) } }
            hero(&g, st, lay)
            // the article: scrolls under the hero
            g.drawLayer { b in
                b.clip(to: Path(CGRect(x: p.minX, y: lay.hero.maxY, width: p.width, height: p.maxY - lay.hero.maxY)))
                article(&b, st, lay, t)
            }
        }
    }

    static func hero(_ g: inout GraphicsContext, _ st: Stage, _ lay: PageLayout) {
        let h = lay.hero
        g.fill(Path(h), with: .linearGradient(Gradient(colors: [Color(red: 0.05, green: 0.05, blue: 0.09), C.purple.opacity(0.8), Color(red: 0.06, green: 0.06, blue: 0.11)]), startPoint: pt(0, h.minY), endPoint: pt(0, h.maxY)))
        for i in 0..<46 {
            let x = h.minX + hash(i, 31) * h.width, y = h.minY + hash(i, 32) * h.height, r = 0.5 + 1.1 * hash(i, 33)
            g.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(C.cream.opacity(0.18 + 0.5 * hash(i, 34))))
        }
        // a black hole, lit from its disc, drawn from the brand's own teals and purples
        let c = pt(h.minX + h.width * (st.compact ? 0.72 : 0.73), h.midY + 2)
        let s = st.compact ? 0.7 : 1.0
        g.fill(Path(ellipseIn: CGRect(x: c.x - 150 * s, y: c.y - 70 * s, width: 300 * s, height: 140 * s)), with: .radialGradient(Gradient(colors: [C.accent.opacity(0.35), C.purple.opacity(0.2), .clear]), center: c, startRadius: 0, endRadius: 150 * s))
        g.drawLayer { d in
            d.addFilter(.blur(radius: 3))
            d.fill(Path(ellipseIn: CGRect(x: c.x - 118 * s, y: c.y - 15 * s, width: 236 * s, height: 30 * s)), with: .linearGradient(Gradient(colors: [C.accentDark.opacity(0.1), C.accentLight.opacity(0.95), C.accent.opacity(0.9), C.purple.opacity(0.2)]), startPoint: pt(c.x - 118 * s, c.y), endPoint: pt(c.x + 118 * s, c.y)))
        }
        // the light bent over the top and under the bottom of it
        g.stroke(Path(ellipseIn: CGRect(x: c.x - 44 * s, y: c.y - 44 * s, width: 88 * s, height: 88 * s)), with: .color(C.accentLight.opacity(0.55)), lineWidth: 2.2)
        g.fill(Path(ellipseIn: CGRect(x: c.x - 34 * s, y: c.y - 34 * s, width: 68 * s, height: 68 * s)), with: .color(Color.black))
        g.stroke(Path(ellipseIn: CGRect(x: c.x - 34 * s, y: c.y - 34 * s, width: 68 * s, height: 68 * s)), with: .color(C.cream.opacity(0.45)), lineWidth: 0.9)
        // the headline
        let hx = lay.hero.minX + (st.compact ? 20 : 34)
        text(&g, "PHYSICS", pt(hx, h.minY + 30), size: 9, weight: .bold, color: C.accentLight, tracking: 2)
        text(&g, "How do black holes", pt(hx, h.minY + (st.compact ? 70 : 74)), size: st.compact ? 22 : 32, weight: .semibold, design: .serif, color: C.cream)
        text(&g, "form?", pt(hx, h.minY + (st.compact ? 96 : 110)), size: st.compact ? 22 : 32, weight: .semibold, design: .serif, color: C.cream)
        text(&g, "By Mira Okafor · 6 min read", pt(hx, h.maxY - 18), size: 9.5, color: C.secondary)
    }

    static func article(_ b: inout GraphicsContext, _ st: Stage, _ lay: PageLayout, _ t: Double) {
        let y = lay.body.minY + 14 - scroll(t)
        let x = lay.body.minX, w = lay.body.width
        func bars(_ top: Double, _ n: Int, _ seed: Int) {
            for i in 0..<n {
                let last = i == n - 1
                let ww = last ? w * (0.45 + 0.3 * hash(seed + i, 3)) : w * (0.93 + 0.07 * hash(seed + i, 4))
                b.fill(Path(roundedRect: CGRect(x: x, y: top + Double(i) * 14, width: ww, height: 7), cornerRadius: 3.5), with: .color(C.secondary.opacity(0.34)))
            }
        }
        text(&b, "From a dying star to the densest place in the universe", pt(x, y + 4), size: st.compact ? 11.5 : 13.5, weight: .semibold, design: .serif, color: C.cream.opacity(0.95))
        bars(y + 26, 4, 10)
        // the link in the middle of the text: what the look-alike will hang on
        let lr = linkRect(st, lay, t)
        text(&b, "Download the full lecture (PDF)", pt(lr.minX, lr.midY), size: st.compact ? 10.5 : 11.5, weight: .medium, color: C.accentLight)
        b.fill(Path(CGRect(x: lr.minX, y: lr.maxY - 2, width: lr.width - 2, height: 0.8)), with: .color(C.accentLight.opacity(0.6)))
        bars(y + (st.compact ? 112 : 166), 4, 20)
        text(&b, "What happens at the edge", pt(x, y + (st.compact ? 196 : 250)), size: st.compact ? 11.5 : 13.5, weight: .semibold, design: .serif, color: C.cream.opacity(0.95))
        bars(y + (st.compact ? 218 : 272), 5, 30)
        bars(y + (st.compact ? 300 : 360), 4, 40)
        // the column beside the text: an empty place kept for an advertisement, then what to read next
        let s = lay.side
        if !st.compact {
            let ys = s.minY - scroll(t) + 14
            text(&b, "READ NEXT", pt(s.minX, ys + 150), size: 8.5, weight: .bold, color: C.secondary, tracking: 1.4)
            let items = ["Why the universe is expanding faster than it should", "The quiet science of neutron stars"]
            for (i, name) in items.enumerated() {
                let ry = ys + 166 + Double(i) * 62
                b.fill(Path(roundedRect: CGRect(x: s.minX, y: ry, width: 52, height: 48), cornerRadius: 7), with: .linearGradient(Gradient(colors: [i == 0 ? C.accent : C.purple, C.deep]), startPoint: pt(s.minX, ry), endPoint: pt(s.minX + 52, ry + 48)))
                text(&b, name, pt(s.minX + 62, ry + 14), size: 10.5, weight: .medium, color: C.cream.opacity(0.9))
                b.fill(Path(roundedRect: CGRect(x: s.minX + 62, y: ry + 28, width: 90, height: 6), cornerRadius: 3), with: .color(C.secondary.opacity(0.3)))
            }
        }
    }

    // MARK: what reaches for the page

    /// The point on the boundary nearest a point outside it.
    static func contactPoint(_ lay: PageLayout, near q: CGPoint) -> CGPoint {
        let b = lay.boundary
        return pt(min(max(q.x, b.minX), b.maxX), min(max(q.y, b.minY), b.maxY))
    }

    static func quad(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        let u = 1 - t
        return pt(u * u * a.x + 2 * u * t * c.x + t * t * b.x, u * u * a.y + 2 * u * t * c.y + t * t * b.y)
    }

    static func intruders(_ c: inout GraphicsContext, _ st: Stage, _ t: Double) {
        let p = st.page, lay = layout(st)
        let b = lay.boundary
        let live = t >= FilmCue.adRejected.0                                  // the boundary is up: things are stopped at it
        let compact = st.compact

        // 1. requests to other hosts: thin purple lines reach for the page; packets run along them
        let stopAt = compact ? b.maxY : b.maxX
        for (i, host) in lay.hosts.enumerated() {
            let src = lay.sources[i % lay.sources.count]
            let mid = compact ? pt((src.x + host.x) / 2, lerp(src.y, host.y, 0.55)) : pt(lerp(src.x, host.x, 0.55), (src.y + host.y) / 2 - 24)
            let reach = easeInOut(prog(t, FilmCue.requests.0 + 0.05 * Double(i), FilmCue.requests.1 + 0.2 + 0.03 * Double(i)))
            guard reach > 0 else { continue }
            let fadeOut = 1 - smooth(prog(t, FilmCue.trackerFiltered.0, FilmCue.trackerFiltered.1))
            var a = c
            a.opacity = reach.isZero ? 0 : (live ? fadeOut : 1)
            var path = Path(); path.move(to: host)
            let steps = 40
            for k in 1...steps { let f = Double(k) / Double(steps) * reach; path.addLine(to: quad(host, mid, src, f)) }
            a.drawLayer { g in
                if live { g.clip(to: Path(compact ? CGRect(x: -3000, y: stopAt, width: 8000, height: 3000) : CGRect(x: stopAt, y: -3000, width: 3000, height: 8000))) }
                g.stroke(path, with: .color(mark.opacity(0.75)), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
                for j in 0..<3 {
                    let f = ((t * 0.5 + Double(i) * 0.21 + Double(j) / 3).truncatingRemainder(dividingBy: 1)) * reach
                    let q = quad(host, mid, src, f)
                    g.fill(Path(ellipseIn: CGRect(x: q.x - 2.4, y: q.y - 2.4, width: 4.8, height: 4.8)), with: .color(C.cream.opacity(0.9)))
                }
                // the host
                let w = 96.0, h = 22.0
                let r = CGRect(x: host.x - w / 2, y: host.y - h / 2, width: w, height: h)
                g.fill(Path(roundedRect: r, cornerRadius: 11), with: .color(C.panel.opacity(0.95)))
                g.stroke(Path(roundedRect: r, cornerRadius: 11), with: .color(mark.opacity(0.7)), lineWidth: 0.9)
                text(&g, hostNames[i], pt(r.midX, r.midY), size: 8.5, weight: .medium, color: C.secondary, anchor: .center)
            }
            // where it meets the boundary, the boundary lights, once
            if live, i < 4 {
                let q = contactPoint(lay, near: src)
                let hit = compact ? pt(lerp(src.x, host.x, 0.5), stopAt) : pt(stopAt, lerp(src.y, host.y, 0.45))
                touch(&c, hit, since: t - (FilmCue.trackerFiltered.0 + 0.03 * Double(i)), st: st)
                _ = q
            }
        }

        // 2. advertising panels slide toward the page and are stopped at the boundary before they can appear
        let adIn = smooth(prog(t, FilmCue.adGrows.0, FilmCue.adGrows.0 + 0.3)), approach = easeInOut(prog(t, FilmCue.adGrows.0, FilmCue.adRejected.0))
        let dissolve = smooth(prog(t, FilmCue.adRejected.0, FilmCue.adRejected.1))
        if adIn > 0, dissolve < 1 {
            var a = c; a.opacity = adIn * (1 - dissolve)
            let size = compact ? CGSize(width: 210, height: 96) : CGSize(width: 232, height: 124)
            // panel one comes from the side (the side stays outside the boundary), panel two from above
            let one = CGRect(x: lerp(p.maxX + 340, b.maxX + 8, approach), y: lay.side.minY + (compact ? -40 : 0), width: size.width, height: size.height)
            let two = CGRect(x: p.minX + 120, y: lerp(p.minY - 250, b.minY - 8 - 44, approach), width: compact ? 250 : 380, height: 44)
            for (r, name, tag) in [(one, "ads.example · tile", "AD"), (two, "adnet.example · banner", "SPONSORED")] {
                let box = Path(roundedRect: r, cornerRadius: 9)
                a.drawLayer { g in g.addFilter(.blur(radius: 8)); g.fill(box, with: .color(mark.opacity(0.35))) }
                a.fill(box, with: .linearGradient(Gradient(colors: [Color(red: 0.20, green: 0.15, blue: 0.29).opacity(0.92), Color(red: 0.10, green: 0.09, blue: 0.16).opacity(0.92)]), startPoint: pt(r.minX, r.minY), endPoint: pt(r.maxX, r.maxY)))
                a.stroke(box, with: .color(mark.opacity(0.9)), lineWidth: 1)
                text(&a, tag, pt(r.minX + 12, r.minY + 14), size: 8, weight: .bold, color: mark, tracking: 1.4)
                text(&a, name, pt(r.minX + 12, r.midY + 6), size: 9.5, weight: .medium, color: C.cream.opacity(0.85))
            }
            if live {
                touch(&c, pt(b.maxX, one.midY), since: t - FilmCue.adRejected.0, st: st)
                touch(&c, pt(two.midX, b.minY), since: t - (FilmCue.adRejected.0 + 0.05), st: st)
                // as it dissolves, fine dust leaves along the boundary
                if dissolve > 0 {
                    for i in 0..<18 {
                        let f = Double(i) / 18
                        let from = pt(b.maxX + 2 + 20 * hash(i, 61) * dissolve, one.minY + f * one.height)
                        c.fill(Path(ellipseIn: CGRect(x: from.x - 1.4, y: from.y - 1.4, width: 2.8, height: 2.8)), with: .color(C.accentLight.opacity(0.7 * (1 - dissolve))))
                    }
                }
            }
        }

        // 3. a link with tracking parameters: the status bar of the page shows where it goes
        let tl = smooth(prog(t, FilmCue.tracker.0, FilmCue.tracker.0 + 0.2)) * (1 - smooth(prog(t, FilmCue.addressCleaned.0 - 0.15, FilmCue.addressCleaned.0)))
        if tl > 0, !compact {
            let sy = lay.side.minY - scroll(t) + 14 + 166
            var a = c; a.opacity = tl
            let r = CGRect(x: lay.side.minX - 4, y: sy - 4, width: lay.side.width, height: 56)
            a.stroke(Path(roundedRect: r, cornerRadius: 9), with: .color(mark.opacity(0.9)), style: StrokeStyle(lineWidth: 1.3, dash: [5, 3]))
            let bar = CGRect(x: p.minX, y: p.maxY - 22, width: p.width * 0.86, height: 22)
            a.fill(Path(bar), with: .color(Color.black.opacity(0.74)))
            text(&a, trackedAddress, pt(bar.minX + 10, bar.midY), size: 9.5, design: .monospaced, color: C.cream.opacity(0.85))
        }

        // 4. a link whose text says one thing and whose destination is another
        let ll = smooth(prog(t, FilmCue.link.0, FilmCue.link.0 + 0.25)) * (1 - smooth(prog(t, FilmCue.settleProtection.0, FilmCue.settleProtection.1)))
        if ll > 0 {
            let lr = linkRect(st, lay, t)
            var a = c; a.opacity = ll
            let r = lr.insetBy(dx: -5, dy: -4)
            a.stroke(Path(roundedRect: r, cornerRadius: 7), with: .color(mark.opacity(0.95)), style: StrokeStyle(lineWidth: 1.3, dash: [4, 3]))
            let tip = CGRect(x: lr.minX, y: lr.maxY + 12, width: 236, height: 38)
            a.fill(Path(roundedRect: tip, cornerRadius: 8), with: .color(Color(red: 0.10, green: 0.10, blue: 0.14)))
            a.stroke(Path(roundedRect: tip, cornerRadius: 8), with: .color(mark.opacity(0.7)), lineWidth: 0.9)
            text(&a, "Download the full lecture", pt(tip.minX + 12, tip.minY + 13), size: 9.5, weight: .semibold, color: C.cream)
            text(&a, "cosmosdaily-files.example/download", pt(tip.minX + 12, tip.minY + 27), size: 8.8, design: .monospaced, color: mark)
        }

        // 5. a pop-up opens over the article, until it is refused
        let inP = easeOut(prog(t, FilmCue.popup.0, FilmCue.popup.1)), out = easeInOut(prog(t, FilmCue.popupRefused.0, FilmCue.popupRefused.1))
        if inP > 0, out < 1 {
            var a = c
            a.opacity = min(1, inP * 1.4) * (1 - out * 0.2)
            let pr = lay.panel
            let centre = pt(pr.midX, pr.midY)
            let target = pt(compact ? p.maxX - 60 : p.maxX - 86, p.minY + 20)
            let pos = pt(lerp(centre.x, target.x, out), lerp(centre.y + (1 - inP) * 24, target.y, out))
            let k = lerp(0.9 + 0.1 * inP, 0.1, out)
            a.translateBy(x: pos.x, y: pos.y); a.scaleBy(x: k, y: k); a.translateBy(x: -centre.x, y: -centre.y)
            a.drawLayer { g in g.addFilter(.blur(radius: 16)); g.fill(Path(roundedRect: pr.offsetBy(dx: 0, dy: 10), cornerRadius: 14), with: .color(Color.black.opacity(0.7))) }
            a.fill(Path(roundedRect: pr, cornerRadius: 14), with: .linearGradient(Gradient(colors: [Color(red: 0.19, green: 0.14, blue: 0.27), Color(red: 0.09, green: 0.08, blue: 0.14)]), startPoint: pt(0, pr.minY), endPoint: pt(0, pr.maxY)))
            a.stroke(Path(roundedRect: pr, cornerRadius: 14), with: .color(mark.opacity(0.6)), lineWidth: 1)
            text(&a, "SPONSORED", pt(pr.minX + 18, pr.minY + 20), size: 8.5, weight: .bold, color: mark, tracking: 1.6)
            text(&a, "Get every story,", pt(pr.minX + 18, pr.minY + 62), size: 24, weight: .semibold, design: .serif, color: C.cream)
            text(&a, "free for a month", pt(pr.minX + 18, pr.minY + 90), size: 24, weight: .semibold, design: .serif, color: C.cream)
            a.fill(Path(roundedRect: CGRect(x: pr.minX + 18, y: pr.maxY - 52, width: pr.width - 36, height: 32), cornerRadius: 16), with: .color(mark.opacity(0.9)))
            text(&a, "Start now", pt(pr.midX, pr.maxY - 36), size: 12.5, weight: .semibold, color: C.ink, anchor: .center)
            a.stroke(Path { $0.move(to: pt(pr.maxX - 28, pr.minY + 14)); $0.addLine(to: pt(pr.maxX - 18, pr.minY + 24)); $0.move(to: pt(pr.maxX - 18, pr.minY + 14)); $0.addLine(to: pt(pr.maxX - 28, pr.minY + 24)) }, with: .color(C.secondary), lineWidth: 1.2)
        }
    }
}

extension CGRect { var center: CGPoint { CGPoint(x: midX, y: midY) } }
