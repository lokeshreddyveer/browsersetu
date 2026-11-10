import SwiftUI

// The first-launch film, as it was reviewed and kept: the world glows in the dark while the noise of the open internet circles it; a storm gathers; an arc of light sweeps up and around the world and the storm glides past it;
// the arc closes into a clear dome of hexagons; a browser window with a metal shield sits under it, calm; the name comes up. Everything is drawn in code, in the setup screens' colours (IntroPalette), and nothing of the browser is on screen
// while it plays. FirstLaunchIntro hosts it; the scene is a pure function of time, so any moment can be frozen for review (BS_INTRO_AT=<seconds>).

enum GlobeFilm {
    typealias C = IntroPalette

    // Timeline (seconds)
    static let duration = 5.8
    static let globeIn = (0.1, 1.0)
    static let sweep = (1.7, 3.4), fadeShell = (3.6, 4.5)
    static let stormIn = (1.0, 2.0), stormOut = (3.6, 4.5)
    static let dome = (3.4, 4.6), browser = (2.8, 3.6), wordmark = (4.4, 5.2)
    static var impact: Double { dome.0 }
    static let shellGap = [34.0, 46.0, 58.0, 70.0]

    // Geometry on a 1000 x 560 grid
    static let globeCentre = CGPoint(x: 500, y: 296)
    static let globeR: Double = 128
    static let domeR: Double = 158
    static let impactPoint = CGPoint(x: 500, y: 138)
    /// Light comes from the upper left.
    static let lightDir = CGPoint(x: -0.58, y: -0.62)

    // MARK: helpers

    static func prog(_ t: Double, _ a: Double, _ b: Double) -> Double { min(1, max(0, (t - a) / (b - a))) }
    static func prog(_ t: Double, _ r: (Double, Double)) -> Double { prog(t, r.0, r.1) }
    static func smooth(_ x: Double) -> Double { x * x * (3 - 2 * x) }
    static func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
    static func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }
    static func mix(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint { CGPoint(x: lerp(a.x, b.x, t), y: lerp(a.y, b.y, t)) }
    static func hash(_ i: Int, _ salt: Double) -> Double { let x = sin(Double(i) * 12.9898 + salt * 78.233) * 43758.5453; return x - floor(x) }

    static let landPath: Path = SVGShape(d: SetuLandData.path, unit: 256).path(in: CGRect(x: 0, y: 0, width: 256, height: 256))
    /// The continents on the scene grid, for a globe of radius globeR at globeCentre (computed once).
    static let landOnScene: Path = {
        let t = CGAffineTransform(translationX: globeCentre.x, y: globeCentre.y).scaledBy(x: globeR / 64, y: globeR / 64).translatedBy(x: -128, y: -94)
        return landPath.applying(t)
    }()

    // MARK: the whole film

    static func draw(_ ctx: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        let full = CGRect(origin: .zero, size: size)
        ctx.fill(Path(full), with: .color(C.ink))
        let fade = smooth(prog(t, 0, 0.7))
        ctx.fill(Path(full), with: .radialGradient(Gradient(colors: [C.purple.opacity(0.55 * fade), .clear]), center: CGPoint(x: size.width * 0.78, y: size.height * 0.22), startRadius: 0, endRadius: max(size.width, size.height) * 0.5))
        ctx.fill(Path(full), with: .radialGradient(Gradient(colors: [C.tealGlow.opacity(0.5 * fade), .clear]), center: CGPoint(x: size.width * 0.3, y: size.height * 0.78), startRadius: 0, endRadius: max(size.width, size.height) * 0.45))
        stars(&ctx, size, t)
        // two slow ribbons of light across the sky, so the upper left is not bare
        for (k, col) in [C.accent, C.purple].enumerated() {
            let sway = sin(t * 0.25 + Double(k) * 2) * 18
            var band = Path(); band.move(to: pt(-40, size.height * (0.34 + 0.1 * Double(k)) + sway))
            band.addCurve(to: pt(size.width * 0.78, size.height * (0.14 + 0.06 * Double(k)) - sway), control1: pt(size.width * 0.25, size.height * (0.12 + 0.12 * Double(k))), control2: pt(size.width * 0.5, size.height * (0.30 - 0.1 * Double(k))))
            ctx.drawLayer { l in l.addFilter(.blur(radius: 42)); l.stroke(band, with: .color(col.opacity(0.16 * fade)), style: StrokeStyle(lineWidth: 70, lineCap: .round)) }
        }

        // the scene, in planes under one slow camera: it pushes in a little and drifts sideways, and the nearer the plane the more it moves
        let camP = min(1, t / duration)
        let s = min(size.width / 1000, size.height / 560) * 0.94 * (1 + 0.06 * easeOut(camP))
        let drift = (camP - 0.5) * 20
        func plane(_ depth: Double, _ body: (inout GraphicsContext) -> Void) {
            var c = ctx
            c.translateBy(x: (size.width - 1000 * s) / 2 - drift * depth * s, y: (size.height - 560 * s) / 2)
            c.scaleBy(x: s, y: s)
            body(&c)
        }
        plane(0.5) { globe(&$0, t); network(&$0, t) }
        plane(0.8) { arc(&$0, t); storm(&$0, t) }
        plane(0.6) { protection(&$0, t) }
        plane(0.6) { browserWindow(&$0, t) }
        plane(0.4) { wordmarkLine(&$0, t) }
        plane(1.8) { foregroundDust(&$0, t) }
    }

    static func stars(_ ctx: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        for i in 0..<70 {
            let h = hash(i, 21), g = hash(i, 22) * 0.78, k = hash(i, 23)
            let tw = 0.55 + 0.45 * sin(t * (0.8 + k * 1.6) + Double(i))
            let r = 0.6 + k * 1.1
            ctx.fill(Path(ellipseIn: CGRect(x: h * size.width - r, y: g * size.height - r, width: r * 2, height: r * 2)), with: .color(C.accentLight.opacity(0.14 + 0.34 * tw * smooth(prog(t, 0, 1)))))
        }
    }

    // MARK: the world

    static func globe(_ ctx: inout GraphicsContext, _ t: Double) {
        let p = smooth(prog(t, globeIn))
        guard p > 0 else { return }
        var c = ctx
        c.opacity = p
        let g = globeCentre, r = globeR
        let grow = 0.93 + 0.07 * p
        c.translateBy(x: g.x, y: g.y); c.scaleBy(x: grow, y: grow); c.translateBy(x: -g.x, y: -g.y)
        let disc = Path(ellipseIn: CGRect(x: g.x - r, y: g.y - r, width: r * 2, height: r * 2))
        // the atmosphere: a soft halo outside the limb
        c.fill(Path(ellipseIn: CGRect(x: g.x - r * 1.3, y: g.y - r * 1.3, width: r * 2.6, height: r * 2.6)), with: .radialGradient(Gradient(stops: [.init(color: .clear, location: 0.0), .init(color: .clear, location: 0.74), .init(color: C.accent.opacity(0.30), location: 0.80), .init(color: C.accentLight.opacity(0.18), location: 0.86), .init(color: .clear, location: 1)]), center: g, startRadius: 0, endRadius: r * 1.3))
        // the ocean: deep, lit from the upper left
        let lit = CGPoint(x: g.x + lightDir.x * r * 0.55, y: g.y + lightDir.y * r * 0.55)
        c.fill(disc, with: .radialGradient(Gradient(colors: [Color(red: 0.20, green: 0.45, blue: 0.58), Color(red: 0.09, green: 0.24, blue: 0.36), Color(red: 0.04, green: 0.11, blue: 0.19), Color(red: 0.02, green: 0.05, blue: 0.09)]), center: lit, startRadius: 0, endRadius: r * 1.55))
        c.drawLayer { l in
            l.clip(to: disc)
            // the sea catches a broad, soft sheen
            l.drawLayer { s in s.addFilter(.blur(radius: 10)); s.fill(Path(ellipseIn: CGRect(x: g.x - r * 0.72, y: g.y - r * 0.78, width: r * 0.9, height: r * 0.5)), with: .color(Color.white.opacity(0.13))) }
            // continents: lit terrain with a darker body, then light on the coasts
            l.fill(landOnScene, with: .linearGradient(Gradient(colors: [Color(red: 0.55, green: 0.76, blue: 0.80), Color(red: 0.27, green: 0.52, blue: 0.60), Color(red: 0.13, green: 0.30, blue: 0.38)]), startPoint: pt(g.x - r * 0.7, g.y - r * 0.8), endPoint: pt(g.x + r * 0.7, g.y + r * 0.8)))
            l.drawLayer { tx in
                tx.clip(to: landOnScene)
                // terrain: soft patches of lighter and darker ground
                for i in 0..<46 {
                    let a = hash(i, 71) * 2 * .pi, d = sqrt(hash(i, 72)) * r, rr = 6 + hash(i, 73) * 16
                    let pos = pt(g.x + cos(a) * d, g.y + sin(a) * d)
                    tx.drawLayer { b in b.addFilter(.blur(radius: 5)); b.fill(Path(ellipseIn: CGRect(x: pos.x - rr, y: pos.y - rr * 0.7, width: rr * 2, height: rr * 1.4)), with: .color((i % 3 == 0 ? Color(red: 0.62, green: 0.80, blue: 0.78) : Color(red: 0.10, green: 0.26, blue: 0.32)).opacity(0.28))) }
                }
            }
            l.stroke(landOnScene, with: .color(C.accentLight.opacity(0.28)), lineWidth: 0.45)
            // clouds, thin and slowly drifting
            for i in 0..<26 {
                let a = hash(i, 81) * 2 * .pi, d = sqrt(hash(i, 82)) * r * 1.05, rr = 8 + hash(i, 83) * 20
                let drift = (t * (2.2 + hash(i, 84) * 2.4)).truncatingRemainder(dividingBy: r * 2.4)
                var x = g.x + cos(a) * d + drift; if x > g.x + r * 1.2 { x -= r * 2.4 }
                let pos = pt(x, g.y + sin(a) * d * 0.9)
                l.drawLayer { b in b.addFilter(.blur(radius: 6)); b.fill(Path(ellipseIn: CGRect(x: pos.x - rr * 0.8, y: pos.y - rr * 0.22, width: rr * 1.6, height: rr * 0.44)), with: .color(Color.white.opacity(0.07))) }
            }
            // night: the terminator darkens the far side, and the cities show there
            l.fill(disc, with: .radialGradient(Gradient(stops: [.init(color: .clear, location: 0), .init(color: .clear, location: 0.48), .init(color: Color.black.opacity(0.52), location: 0.9), .init(color: Color.black.opacity(0.7), location: 1)]), center: pt(g.x + lightDir.x * r * 0.35, g.y + lightDir.y * r * 0.35), startRadius: 0, endRadius: r * 1.5))
            l.drawLayer { n in
                n.clip(to: landOnScene)
                let centres = [(0.42, 0.30), (0.15, 0.55), (0.55, -0.05), (0.30, 0.15), (0.05, 0.38), (0.62, 0.38)]
                for i in 0..<320 {
                    let cl = centres[i % centres.count]
                    let x = g.x + (cl.0 + (hash(i, 91) - 0.5) * 0.34) * r, y = g.y + (cl.1 + (hash(i, 92) - 0.5) * 0.30) * r
                    let dx = (x - g.x) / r, dy = (y - g.y) / r
                    let night = -(dx * lightDir.x + dy * lightDir.y)
                    guard night > 0.05, dx * dx + dy * dy < 0.92 else { continue }
                    let sz = 0.7 + hash(i, 93) * 1.1
                    n.fill(Path(ellipseIn: CGRect(x: x - sz, y: y - sz, width: sz * 2, height: sz * 2)), with: .color(C.cream.opacity(min(1, night * 2.2 + 0.25) * (0.6 + 0.4 * hash(i, 94)))))
                }
            }
            // a lit rim along the sunward limb
            l.stroke(disc, with: .linearGradient(Gradient(colors: [C.accentLight.opacity(0.85), C.accentLight.opacity(0.1)]), startPoint: pt(g.x - r, g.y - r), endPoint: pt(g.x + r, g.y + r)), lineWidth: 3)
        }
        c.stroke(disc, with: .color(C.accentLight.opacity(0.4)), lineWidth: 0.8)
        // the orbit, drawn on, passing behind and in front
        let o = easeOut(prog(t, 0.5, 1.6))
        if o > 0 {
            for front in [false, true] {
                var ring = Path()
                let steps = 120
                for i in 0...steps {
                    let a = Double(i) / Double(steps) * 2 * .pi
                    if (sin(a) > 0) != front { continue }
                    let x = cos(a) * (r * 1.4), y = sin(a) * (r * 0.33)
                    let rot = -16.0 * .pi / 180
                    let px = g.x + x * cos(rot) - y * sin(rot), py = g.y + x * sin(rot) + y * cos(rot)
                    if ring.isEmpty { ring.move(to: pt(px, py)) } else { ring.addLine(to: pt(px, py)) }
                }
                c.drawLayer { l in l.opacity = o; l.addFilter(.blur(radius: 4)); l.stroke(ring, with: .color(C.accent.opacity(0.55)), lineWidth: 4) }
                c.opacity = p * o
                c.stroke(ring, with: .color(C.accentLight.opacity(front ? 0.8 : 0.32)), style: StrokeStyle(lineWidth: front ? 1.8 : 1.2, lineCap: .round, lineJoin: .round))
                c.opacity = p
            }
        }
    }

    /// The open internet, around the globe: small points of light and their short trails.
    static func network(_ ctx: inout GraphicsContext, _ t: Double) {
        let p = smooth(prog(t, 0.25, 1.2))
        guard p > 0 else { return }
        let g = globeCentre
        for i in 0..<34 {
            let k = hash(i, 51), r = globeR * (1.28 + 0.6 * hash(i, 52)), sp = (0.12 + 0.2 * hash(i, 53)) * (i % 2 == 0 ? 1 : -1)
            let a = hash(i, 54) * 2 * .pi + t * sp
            let squash = 0.42 + 0.3 * hash(i, 55)
            let pos = pt(g.x + cos(a) * r, g.y + sin(a) * r * squash)
            if sin(a) < 0, hypot(pos.x - g.x, pos.y - g.y) < globeR { continue }
            let rr = 1.1 + 1.7 * k
            ctx.fill(Path(ellipseIn: CGRect(x: pos.x - rr, y: pos.y - rr, width: rr * 2, height: rr * 2)), with: .color(C.accentLight.opacity((0.25 + 0.5 * k) * p)))
            let tail = pt(g.x + cos(a - sp * 0.5) * r, g.y + sin(a - sp * 0.5) * r * squash)
            ctx.stroke(Path { $0.move(to: tail); $0.addLine(to: pos) }, with: .linearGradient(Gradient(colors: [.clear, C.accentLight.opacity(0.35 * p)]), startPoint: tail, endPoint: pos), lineWidth: 1)
        }
    }

    // MARK: the arc of light, and the storm that glides past it

    static func arcPath(radius: Double, from a0: Double, span: Double) -> Path {
        var p = Path(); p.addArc(center: globeCentre, radius: radius, startAngle: .radians(a0), endAngle: .radians(a0 + span), clockwise: false); return p
    }

    static func sweepAmount(_ t: Double) -> Double { easeOut(prog(t, sweep)) }

    static func arc(_ ctx: inout GraphicsContext, _ t: Double) {
        let e = sweepAmount(t)
        let hold = 1 - smooth(prog(t, fadeShell))
        guard e > 0.001, hold > 0.01 else { return }
        let g = globeCentre
        // it starts on the left, slightly above, and goes over the top and down the far side
        let a0 = Double.pi * 1.12
        let span = 2 * .pi * 0.98 * e
        let contract = 1 - 0.1 * smooth(prog(t, fadeShell))
        var c = ctx
        c.opacity = hold
        // the soft shell: a translucent band swept out behind the head, faint at the tail so it has no blunt ends
        let mid = (shellGap.first! + shellGap.last!) / 2 * contract
        let bandW = (shellGap.last! - shellGap.first!) * contract
        let segs = 36
        for k in 0..<segs {
            let f0 = Double(k) / Double(segs), f1 = Double(k + 1) / Double(segs)
            let seg = arcPath(radius: globeR + mid, from: a0 + span * f0, span: span * (f1 - f0) + 0.004)
            let fall = smooth(min(1, f0 * 3.2)) * (0.55 + 0.45 * f1)
            c.drawLayer { l in l.addFilter(.blur(radius: 10)); l.stroke(seg, with: .color(C.accent.opacity(0.30 * fall)), style: StrokeStyle(lineWidth: bandW + 20, lineCap: .butt)) }
            c.stroke(seg, with: .color(C.accentLight.opacity(0.075 * fall)), style: StrokeStyle(lineWidth: bandW, lineCap: .butt))
        }
        // the fine concentric curves
        for (k, gap) in shellGap.enumerated() {
            let r = (globeR + gap) * contract
            let lag = Double(k) * 0.06
            let sp = max(0, 2 * .pi * 0.98 * easeOut(max(0, prog(t, sweep.0 + lag, sweep.1 + lag))))
            guard sp > 0.01 else { continue }
            let arc = arcPath(radius: r, from: a0, span: sp)
            let tailPt = pt(g.x + cos(a0) * r, g.y + sin(a0) * r), headPt = pt(g.x + cos(a0 + sp) * r, g.y + sin(a0 + sp) * r)
            c.stroke(arc, with: .linearGradient(Gradient(stops: [.init(color: C.accentLight.opacity(0.0), location: 0), .init(color: C.accentLight.opacity(0.75 - Double(k) * 0.12), location: 0.35), .init(color: C.accentLight.opacity(0.95 - Double(k) * 0.12), location: 1)]), startPoint: tailPt, endPoint: headPt), style: StrokeStyle(lineWidth: 1.6 - Double(k) * 0.18, lineCap: .round))
            c.fill(Path(ellipseIn: CGRect(x: headPt.x - 2.6, y: headPt.y - 2.6, width: 5.2, height: 5.2)), with: .color(C.cream.opacity(0.95 * (e < 0.995 ? 1 : 0))))
        }
        // a little geometry in the shell: ticks that appear behind the head, like the pattern of a cloth
        let ticks = 54
        for i in 0..<ticks {
            let f2 = Double(i) / Double(ticks)
            guard f2 * 2 * .pi * 0.98 <= span else { break }
            let ang = a0 + f2 * 2 * .pi * 0.98
            let r0 = (globeR + shellGap[0] + 4) * contract, r1 = (globeR + shellGap.last! - 4) * contract
            let len = i % 3 == 0 ? r1 : (r0 + r1) / 2
            c.stroke(Path { $0.move(to: pt(g.x + cos(ang) * r0, g.y + sin(ang) * r0)); $0.addLine(to: pt(g.x + cos(ang) * len, g.y + sin(ang) * len)) }, with: .color(C.accentLight.opacity(i % 3 == 0 ? 0.32 : 0.16)), lineWidth: 0.9)
        }
        // the light it throws on the world
        c.fill(Path(ellipseIn: CGRect(x: g.x - globeR * 1.5, y: g.y - globeR * 1.5, width: globeR * 3, height: globeR * 3)), with: .radialGradient(Gradient(stops: [.init(color: .clear, location: 0.55), .init(color: C.accentLight.opacity(0.10 * e), location: 0.8), .init(color: .clear, location: 1)]), center: g, startRadius: 0, endRadius: globeR * 1.5))
    }

    /// Where a particle is when it has fallen to height y: straight down until it meets the shell, then gliding out along it and down past the sides.
    static func driftPosition(_ x0: Double, _ y: Double, _ shelter: Double) -> CGPoint {
        let g = globeCentre, rs = globeR + shellGap.last! + 6
        let dx = x0 - g.x
        guard shelter > 0.3, abs(dx) < rs else { return pt(x0, y) }
        let contact = g.y - sqrt(rs * rs - dx * dx)
        guard y > contact else { return pt(x0, y) }
        let side = dx >= 0 ? 1.0 : -1.0
        let phi0 = asin(max(-1, min(1, dx / rs)))
        let phi = phi0 + side * (y - contact) * 1.1 / rs
        if abs(phi) <= .pi / 2 { return pt(g.x + rs * sin(phi), g.y - rs * cos(phi)) }
        return pt(g.x + side * rs, g.y + (abs(phi) - .pi / 2) * rs)
    }

    static func storm(_ ctx: inout GraphicsContext, _ t: Double) {
        let strength = smooth(prog(t, stormIn)) * (1 - smooth(prog(t, stormOut)))
        guard strength > 0.01 else { return }
        let shelter = smooth(prog(t, sweep.1 - 0.9, sweep.1))
        for i in 0..<110 {
            let x0 = hash(i, 41) * 1100 - 50, speed = 360 + hash(i, 42) * 240, len = 16 + hash(i, 43) * 26
            let phase = hash(i, 44) * 720
            let y = (phase + t * speed).truncatingRemainder(dividingBy: 720) - 100
            let head = driftPosition(x0, y, shelter), tail = driftPosition(x0, y - len, shelter)
            if head.y < -20 || head.y > 600 { continue }
            let a = (0.10 + 0.28 * hash(i, 45)) * strength
            ctx.stroke(Path { $0.move(to: tail); $0.addLine(to: head) }, with: .linearGradient(Gradient(colors: [.clear, C.accentLight.opacity(a)]), startPoint: tail, endPoint: head), style: StrokeStyle(lineWidth: 1.1 + hash(i, 46), lineCap: .round))
        }
    }

    // MARK: the dome: glass, with a lattice of hexagons that lights up from the top

    static func protection(_ ctx: inout GraphicsContext, _ t: Double) {
        let q = prog(t, dome)
        guard q > 0 else { return }
        let g = globeCentre, R = domeR
        let reveal = easeOut(q) * (R * 2 + 60)
        // as the dome closes, one calm ring spreads outward from the world
        let ring = prog(t, impact, impact + 1.1)
        if ring > 0, ring < 1 {
            let rr = lerp(R, R + 120, easeOut(ring))
            ctx.stroke(Path(ellipseIn: CGRect(x: g.x - rr, y: g.y - rr, width: rr * 2, height: rr * 2)), with: .color(C.accentLight.opacity(0.4 * (1 - ring))), lineWidth: 1.6 * (1 - ring) + 0.4)
        }
        let shell = Path(ellipseIn: CGRect(x: g.x - R, y: g.y - R, width: R * 2, height: R * 2))
        ctx.drawLayer { l in
            l.clip(to: shell)
            l.fill(shell, with: .radialGradient(Gradient(stops: [.init(color: .clear, location: 0.0), .init(color: C.accentLight.opacity(0.0), location: 0.72), .init(color: C.accentLight.opacity(0.22 * smooth(q)), location: 1)]), center: g, startRadius: 0, endRadius: R))
            let hr = 21.0, w = hr * sqrt(3), h = hr * 1.5
            var row = 0
            var y = g.y - R - h
            while y < g.y + R + h {
                var x = g.x - R - w + (row % 2 == 0 ? 0 : w / 2)
                while x < g.x + R + w {
                    let d = hypot(x - impactPoint.x, y - impactPoint.y)
                    let a = smooth(min(1, max(0, (reveal - d) / 70)))
                    if a > 0.01 {
                        var hex = Path()
                        for k in 0..<6 {
                            let ang = (Double(k) * 60 + 30) * .pi / 180
                            let v = pt(x + cos(ang) * (hr - 1.2), y + sin(ang) * (hr - 1.2))
                            if k == 0 { hex.move(to: v) } else { hex.addLine(to: v) }
                        }
                        hex.closeSubpath()
                        let pulse = 0.5 + 0.5 * sin(t * 1.4 - d * 0.02)
                        l.stroke(hex, with: .color(C.accentLight.opacity(a * (0.16 + 0.16 * pulse))), lineWidth: 0.9)
                        if (Int(x / w) + row) % 7 == 0 { l.fill(hex, with: .color(C.accent.opacity(a * 0.10 * pulse))) }
                    }
                    x += w
                }
                y += h; row += 1
            }
        }
        // the glass: a bright edge where the shell turns away, a specular highlight, and a slow sheen travelling around it
        let glass = smooth(q)
        ctx.drawLayer { l in
            l.clip(to: shell)
            l.stroke(shell, with: .color(C.accentLight.opacity(0.34 * glass)), lineWidth: 10)
            let ang = t * 0.9
            let sheenA = pt(g.x + cos(ang) * R, g.y + sin(ang) * R), sheenB = pt(g.x - cos(ang) * R, g.y - sin(ang) * R)
            l.fill(shell, with: .linearGradient(Gradient(stops: [.init(color: .clear, location: 0.0), .init(color: C.cream.opacity(0.07 * glass), location: 0.45), .init(color: .clear, location: 0.6)]), startPoint: sheenA, endPoint: sheenB))
        }
        var spec = Path(); spec.addArc(center: g, radius: R * 0.9, startAngle: .degrees(196), endAngle: .degrees(256), clockwise: false)
        ctx.drawLayer { l in l.addFilter(.blur(radius: 3)); l.stroke(spec, with: .color(Color.white.opacity(0.35 * glass)), style: StrokeStyle(lineWidth: 4, lineCap: .round)) }
        ctx.stroke(spec, with: .color(Color.white.opacity(0.55 * glass)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        // the rim spreads from the top around the globe
        let span = easeOut(q) * 180
        if span > 0.5 {
            var arc = Path()
            arc.addArc(center: g, radius: R, startAngle: .degrees(270 - span), endAngle: .degrees(270 + span), clockwise: false)
            ctx.drawLayer { l in l.addFilter(.blur(radius: 6)); l.stroke(arc, with: .color(C.accent.opacity(0.8)), lineWidth: 7) }
            ctx.stroke(arc, with: .color(C.accentLight.opacity(0.95)), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
        }
    }

    // MARK: the browser window with the shield, in the lower right of the world

    static func browserWindow(_ ctx: inout GraphicsContext, _ t: Double) {
        let p = easeOut(prog(t, browser))
        guard p > 0 else { return }
        var c = ctx
        c.opacity = p
        let g = globeCentre
        c.translateBy(x: g.x + 34, y: g.y + 36 + (1 - p) * 10)
        c.scaleBy(x: 0.82 * (0.94 + 0.06 * p), y: 0.82 * (0.94 + 0.06 * p))
        c.rotate(by: .radians(-0.035))
        let w = 204.0, h = 134.0
        let rect = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
        let frame = Path(roundedRect: rect, cornerRadius: 12)
        let ink = Color(red: 0.055, green: 0.085, blue: 0.125)
        c.drawLayer { l in l.addFilter(.blur(radius: 12)); l.fill(Path(roundedRect: rect.offsetBy(dx: 0, dy: 10), cornerRadius: 14), with: .color(Color.black.opacity(0.55))) }
        c.drawLayer { l in l.addFilter(.blur(radius: 9)); l.stroke(frame, with: .color(C.accent.opacity(0.5)), lineWidth: 4) }
        c.fill(frame, with: .linearGradient(Gradient(colors: [Color(red: 0.13, green: 0.19, blue: 0.26), ink]), startPoint: pt(0, -h / 2), endPoint: pt(0, h / 2)))
        c.drawLayer { l in
            l.clip(to: frame)
            l.fill(Path(CGRect(x: -w / 2, y: -h / 2, width: w, height: 22)), with: .color(Color.black.opacity(0.32)))
            for (i, col) in [Color(red: 0.93, green: 0.42, blue: 0.40), Color(red: 0.95, green: 0.74, blue: 0.30), Color(red: 0.36, green: 0.80, blue: 0.47)].enumerated() {
                l.fill(Path(ellipseIn: CGRect(x: -w / 2 + 8 + Double(i) * 9, y: -h / 2 + 8, width: 5.5, height: 5.5)), with: .color(col.opacity(0.85)))
            }
            var tab = Path(); tab.move(to: pt(-w / 2 + 44, -h / 2 + 22)); tab.addQuadCurve(to: pt(-w / 2 + 52, -h / 2 + 8), control: pt(-w / 2 + 46, -h / 2 + 8)); tab.addLine(to: pt(-w / 2 + 100, -h / 2 + 8)); tab.addQuadCurve(to: pt(-w / 2 + 108, -h / 2 + 22), control: pt(-w / 2 + 106, -h / 2 + 8)); tab.closeSubpath()
            l.fill(tab, with: .color(Color(red: 0.17, green: 0.25, blue: 0.33)))
            l.fill(Path(ellipseIn: CGRect(x: -w / 2 + 57, y: -h / 2 + 12.5, width: 6, height: 6)), with: .color(C.accentLight))
            l.fill(Path(roundedRect: CGRect(x: -w / 2 + 68, y: -h / 2 + 14.5, width: 26, height: 2.6), cornerRadius: 1.3), with: .color(C.cream.opacity(0.7)))
            l.fill(Path(roundedRect: CGRect(x: -w / 2 + 116, y: -h / 2 + 14.5, width: 22, height: 2.6), cornerRadius: 1.3), with: .color(C.cream.opacity(0.25)))
            l.fill(Path(CGRect(x: -w / 2, y: -h / 2 + 22, width: w, height: 22)), with: .color(Color(red: 0.17, green: 0.25, blue: 0.33)))
            for (k, dx) in [10.0, 24.0].enumerated() {
                var chev = Path(); let x = -w / 2 + dx, y = -h / 2 + 33
                if k == 0 { chev.move(to: pt(x + 2.5, y - 3.5)); chev.addLine(to: pt(x - 1.5, y)); chev.addLine(to: pt(x + 2.5, y + 3.5)) } else { chev.move(to: pt(x - 2.5, y - 3.5)); chev.addLine(to: pt(x + 1.5, y)); chev.addLine(to: pt(x - 2.5, y + 3.5)) }
                l.stroke(chev, with: .color(C.cream.opacity(0.7)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            }
            l.stroke(Path(ellipseIn: CGRect(x: -w / 2 + 34, y: -h / 2 + 29.5, width: 7, height: 7)), with: .color(C.cream.opacity(0.6)), lineWidth: 1.3)
            l.fill(Path(roundedRect: CGRect(x: -w / 2 + 50, y: -h / 2 + 26, width: w - 82, height: 14), cornerRadius: 7), with: .color(Color(red: 0.07, green: 0.11, blue: 0.16)))
            l.fill(Path(roundedRect: CGRect(x: -w / 2 + 60, y: -h / 2 + 31, width: 7, height: 6), cornerRadius: 1.5), with: .color(C.accentLight))
            l.fill(Path(roundedRect: CGRect(x: -w / 2 + 72, y: -h / 2 + 32.4, width: 52, height: 3), cornerRadius: 1.5), with: .color(C.cream.opacity(0.55)))
            for i in 0..<3 { l.fill(Path(ellipseIn: CGRect(x: w / 2 - 22 + Double(i) * 5.5, y: -h / 2 + 32, width: 2.6, height: 2.6)), with: .color(C.cream.opacity(0.6))) }
            // the page: the Start Page, quiet: a greeting, a search field, tiles
            l.fill(Path(CGRect(x: -w / 2, y: -h / 2 + 44, width: w, height: h - 44)), with: .linearGradient(Gradient(colors: [Color(red: 0.07, green: 0.16, blue: 0.24), Color(red: 0.04, green: 0.09, blue: 0.14)]), startPoint: pt(0, -h / 2 + 44), endPoint: pt(0, h / 2)))
            l.fill(Path(ellipseIn: CGRect(x: -60, y: -h / 2 + 40, width: 120, height: 60)), with: .radialGradient(Gradient(colors: [C.accent.opacity(0.3), .clear]), center: pt(0, -h / 2 + 62), startRadius: 0, endRadius: 70))
            l.fill(Path(roundedRect: CGRect(x: -34, y: -h / 2 + 54, width: 68, height: 4), cornerRadius: 2), with: .color(C.cream.opacity(0.45)))
            l.fill(Path(roundedRect: CGRect(x: -50, y: -h / 2 + 64, width: 100, height: 13), cornerRadius: 6.5), with: .color(Color.white.opacity(0.10)))
            l.stroke(Path(roundedRect: CGRect(x: -50, y: -h / 2 + 64, width: 100, height: 13), cornerRadius: 6.5), with: .color(C.accentLight.opacity(0.35)), lineWidth: 0.7)
            for i in 0..<5 {
                let x = -62 + Double(i) * 26
                l.fill(Path(roundedRect: CGRect(x: x, y: -h / 2 + 88, width: 20, height: 20), cornerRadius: 6), with: .color(Color.white.opacity(0.07)))
                l.fill(Path(ellipseIn: CGRect(x: x + 5.5, y: -h / 2 + 93.5, width: 9, height: 9)), with: .color((i % 2 == 0 ? C.accent : C.accentLight).opacity(0.55)))
            }
            var sheen = Path(); sheen.move(to: pt(-w / 2, -h / 2)); sheen.addLine(to: pt(-w * 0.05, -h / 2)); sheen.addLine(to: pt(-w / 2 + 40, h / 2)); sheen.addLine(to: pt(-w / 2, h / 2)); sheen.closeSubpath()
            l.fill(sheen, with: .linearGradient(Gradient(colors: [Color.white.opacity(0.10), .clear]), startPoint: pt(-w / 2, -h / 2), endPoint: pt(0, h / 4)))
        }
        c.stroke(frame, with: .linearGradient(Gradient(colors: [C.accentLight.opacity(0.85), C.accentLight.opacity(0.18)]), startPoint: pt(0, -h / 2), endPoint: pt(0, h / 2)), lineWidth: 1.2)
        c.stroke(Path(roundedRect: rect.insetBy(dx: 1.4, dy: 1.4), cornerRadius: 10.6), with: .color(Color.white.opacity(0.07)), lineWidth: 0.8)
        // the shield: metal, with a bevel, standing in front of the page
        let sp = easeOut(prog(t, dome.0 + 0.4, dome.1 + 0.2))
        var sc = c
        sc.opacity = p * sp
        sc.translateBy(x: 0, y: 12 + (1 - sp) * 8)
        sc.scaleBy(x: 0.86 + 0.14 * sp, y: 0.86 + 0.14 * sp)
        var shield = Path()
        shield.move(to: pt(0, -34)); shield.addCurve(to: pt(24, -26), control1: pt(8, -30), control2: pt(16, -30)); shield.addCurve(to: pt(0, 34), control1: pt(24, 8), control2: pt(14, 24)); shield.addCurve(to: pt(-24, -26), control1: pt(-14, 24), control2: pt(-24, 8)); shield.addCurve(to: pt(0, -34), control1: pt(-16, -30), control2: pt(-8, -30))
        sc.drawLayer { l in l.addFilter(.blur(radius: 8)); l.fill(shield, with: .color(C.accentLight.opacity(0.55))) }
        sc.drawLayer { l in l.addFilter(.blur(radius: 5)); l.fill(shield.offsetBy(dx: 0, dy: 5), with: .color(Color.black.opacity(0.5))) }
        sc.fill(shield, with: .linearGradient(Gradient(colors: [Color(red: 0.30, green: 0.58, blue: 0.70), Color(red: 0.12, green: 0.30, blue: 0.42), Color(red: 0.06, green: 0.16, blue: 0.26)]), startPoint: pt(-20, -34), endPoint: pt(16, 34)))
        sc.drawLayer { l in
            l.clip(to: shield)
            l.fill(Path(CGRect(x: -26, y: -36, width: 26, height: 72)), with: .color(Color.white.opacity(0.10)))
            l.fill(Path(ellipseIn: CGRect(x: -30, y: -44, width: 60, height: 30)), with: .radialGradient(Gradient(colors: [Color.white.opacity(0.35), .clear]), center: pt(-8, -30), startRadius: 0, endRadius: 28))
        }
        sc.stroke(shield, with: .linearGradient(Gradient(colors: [C.cream, C.accentLight.opacity(0.6)]), startPoint: pt(-20, -34), endPoint: pt(20, 34)), style: StrokeStyle(lineWidth: 2.4, lineJoin: .round))
        var shackle = Path(); shackle.move(to: pt(-6, -2)); shackle.addLine(to: pt(-6, -7)); shackle.addCurve(to: pt(6, -7), control1: pt(-6, -17), control2: pt(6, -17)); shackle.addLine(to: pt(6, -2))
        sc.stroke(shackle, with: .color(C.cream), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        sc.fill(Path(roundedRect: CGRect(x: -10, y: -3, width: 20, height: 16), cornerRadius: 3.2), with: .linearGradient(Gradient(colors: [Color.white, C.cream]), startPoint: pt(0, -3), endPoint: pt(0, 13)))
        sc.fill(Path(ellipseIn: CGRect(x: -2.4, y: 2.6, width: 4.8, height: 4.8)), with: .color(C.accentDark))
    }

    // MARK: the name

    static func wordmarkLine(_ ctx: inout GraphicsContext, _ t: Double) {
        let p = easeOut(prog(t, wordmark))
        guard p > 0 else { return }
        var c = ctx
        c.opacity = p
        let name = Text("Browser ").font(.system(size: 46, weight: .regular, design: .serif)).foregroundColor(C.cream.opacity(0.92))
            + Text("Setu").font(.system(size: 46, weight: .bold, design: .serif)).foregroundColor(C.accentLight)
        c.draw(c.resolve(name), at: pt(500, 530 + (1 - p) * 12), anchor: .center)
        let line = easeOut(prog(t, wordmark.0 + 0.2, wordmark.1 + 0.3))
        let half = 70.0 * line
        c.stroke(Path { $0.move(to: pt(500 - half, 552)); $0.addLine(to: pt(500 + half, 552)) }, with: .linearGradient(Gradient(colors: [.clear, C.accentLight.opacity(0.8), .clear]), startPoint: pt(500 - 70, 552), endPoint: pt(500 + 70, 552)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
    }

    /// Soft light dust drifting in front of everything: the nearest plane, which the camera moves past fastest.
    static func foregroundDust(_ ctx: inout GraphicsContext, _ t: Double) {
        let fade = smooth(prog(t, 0.4, 1.6))
        for i in 0..<30 {
            let h = hash(i, 11), g = hash(i, 12), k = hash(i, 13)
            let x = (h * 1100 - 50 + t * (6 + k * 10)).truncatingRemainder(dividingBy: 1100) - 50
            let y = 600 - ((g * 640 + t * (10 + k * 16)).truncatingRemainder(dividingBy: 640)) - 20
            let r = 2.2 + k * 4.5
            ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .radialGradient(Gradient(colors: [C.accentLight.opacity(0.2 * fade * (0.4 + k)), .clear]), center: CGPoint(x: x, y: y), startRadius: 0, endRadius: r))
        }
    }
}
