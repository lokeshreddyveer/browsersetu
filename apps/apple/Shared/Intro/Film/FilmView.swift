import SwiftUI

// The compositor. One pure function of the frame: the ground, the artwork layers (each with its own parallax), the live screen content mapped onto the screen quad with true perspective, the hands, the brand.
// It never contains artwork of its own. With production artwork it draws the images named in the manifest; with FilmSource.testPlates it draws diagnostic plates (grids, labels, "TEST PLATE"), for engineering tests only.

struct FilmView: View {
    var frame: Double
    var source: FilmSource

    private var key: String { FilmAvailability.compositionKey }
    private var composition: FilmManifest.Composition? {
        switch source {
        case .production(let m): return m.compositions[key]
        case .testPlates: return FilmTestPlates.composition(key)
        case .unavailable: return nil
        }
    }
    private var isTest: Bool { if case .testPlates = source { return true } else { return false } }

    var body: some View {
        GeometryReader { geo in
            if let comp = composition {
                let master = CGSize(width: comp.master[0], height: comp.master[1])
                let cam = FilmCamera.state(atFrame: frame, master: master)
                let t = frame / FilmSpec.fps
                ZStack(alignment: .topLeading) {
                    Ground(t: t)
                    layers(comp, cam, geo.size, master, upTo: 1)
                    screen(comp, cam, geo.size, master)
                    layers(comp, cam, geo.size, master, from: 2)
                    Brand(t: t, portrait: key == "portrait")
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .clipped()
            }
        }
        .background(IntroPalette.ink)
    }

    // MARK: layers (artwork or test plates), each at its own parallax

    private func sorted(_ comp: FilmManifest.Composition) -> [FilmManifest.Layer] { comp.layers.sorted { $0.z < $1.z } }

    @ViewBuilder private func layers(_ comp: FilmManifest.Composition, _ cam: CameraState, _ size: CGSize, _ master: CGSize, upTo: Int? = nil, from: Int? = nil) -> some View {
        let handsBlend = Track([.init(frame: 56, value: 0), .init(frame: 70, value: 1, ease: .easeInOut)]).value(at: frame)
        ForEach(sorted(comp).filter { l in (upTo.map { l.z <= $0 } ?? true) && (from.map { l.z >= $0 } ?? true) }, id: \.id) { l in
            let depth = FilmAssetContract.depths[l.depth]?.rawValue ?? 1
            let T = FilmCamera.transform(cam, depth: depth, window: size, master: master)
            let f = CGRect(x: l.frame[0], y: l.frame[1], width: l.frame[2], height: l.frame[3])
            let r = f.applying(T)
            // the person breathes: a slow movement of a couple of master pixels
            let breath = l.role == "person" || l.role.hasPrefix("hands") ? 2.0 * sin(2 * .pi * frame / FilmSpec.fps / 4.0) * T.a : 0
            let opacity = l.role == "handsA" ? 1 - handsBlend : (l.role == "handsB" ? handsBlend : 1)
            Group {
                if isTest { FilmTestPlateView(role: l.role, master: master, frameInMaster: f, quad: comp.screenQuad, frame: frame) }
                else { Image(l.file).resizable().interpolation(.high) }
            }
            .frame(width: r.width, height: r.height)
            .opacity(opacity)
            .position(x: r.midX, y: r.midY + breath)
        }
    }

    // MARK: the screen: the live page, perspective-mapped onto the quad

    @ViewBuilder private func screen(_ comp: FilmManifest.Composition, _ cam: CameraState, _ size: CGSize, _ master: CGSize) -> some View {
        let T = FilmCamera.transform(cam, depth: FilmCamera.Depth.laptop.rawValue, window: size, master: master)
        let quad = comp.screenQuad.map { CGPoint(x: $0[0], y: $0[1]).applying(T) }
        let local = CGSize(width: comp.screenSize[0], height: comp.screenSize[1])
        if let h = FilmHomography.solve(from: local, to: quad) {
            ZStack {
                FilmScreenContent(frame: frame, size: local)
                // the screen's own light, spilling onto what is around it
                Canvas { ctx, s in
                    let g = CGPoint(x: s.width / 2, y: s.height / 2)
                    ctx.fill(Path(CGRect(origin: .zero, size: s)), with: .radialGradient(Gradient(colors: [IntroPalette.accentLight.opacity(0.10), .clear]), center: g, startRadius: 0, endRadius: s.width * 0.7))
                }.frame(width: local.width, height: local.height).blendMode(.plusLighter).allowsHitTesting(false)
            }
            .frame(width: local.width, height: local.height)
            .compositingGroup()
            .projectionEffect(ProjectionTransform(FilmHomography.transform3D(h)))
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
    }
}

/// The screen's live content (a pure function of the frame).
struct FilmScreenContent: View {
    var frame: Double
    var size: CGSize
    var body: some View {
        Canvas { ctx, s in InvisibleWeb.drawScreen(&ctx, s, frame / FilmSpec.fps) }
            .frame(width: size.width, height: size.height)
    }
}

/// The brand ground the setup screens use: near black, two glows, a little dust.
struct Ground: View {
    var t: Double
    var body: some View {
        Canvas { ctx, size in
            let full = CGRect(origin: .zero, size: size)
            ctx.fill(Path(full), with: .color(IntroPalette.ink))
            let fade = InvisibleWeb.smooth(InvisibleWeb.prog(t, 0, 0.8))
            ctx.fill(Path(full), with: .radialGradient(Gradient(colors: [IntroPalette.purple.opacity(0.5 * fade), .clear]), center: CGPoint(x: size.width * 0.8, y: size.height * 0.2), startRadius: 0, endRadius: max(size.width, size.height) * 0.55))
            ctx.fill(Path(full), with: .radialGradient(Gradient(colors: [IntroPalette.tealGlow.opacity(0.5 * fade), .clear]), center: CGPoint(x: size.width * 0.22, y: size.height * 0.85), startRadius: 0, endRadius: max(size.width, size.height) * 0.5))
        }
    }
}

/// Scene 5: the room dissolves to the near black of the setup screens, then the mark, the name and the two lines. The hand-off to setup is the same ground, so there is no black frame.
struct Brand: View {
    var t: Double
    var portrait: Bool
    var body: some View {
        Canvas { ctx, size in
            let dissolve = InvisibleWeb.smooth(InvisibleWeb.prog(t, FilmCue.dissolve.0, FilmCue.dissolve.1))
            if dissolve > 0 { ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(IntroPalette.ink.opacity(dissolve))) }
            InvisibleWeb.closing(&ctx, size, portrait ? InvisibleWeb.portrait : InvisibleWeb.landscape, t, mark: ctx.resolveSymbol(id: "mark"))
        } symbols: { SetuMark(size: 96, teal: true).tag("mark") }
        .allowsHitTesting(false)
    }
}

/// Diagnostic plates for engineering tests: unmistakably not artwork.
struct FilmTestPlateView: View {
    var role: String
    var master: CGSize
    var frameInMaster: CGRect
    var quad: [[Double]]
    var frame: Double
    var body: some View {
        Canvas { ctx, size in
            let k = size.width / frameInMaster.width
            ctx.scaleBy(x: k, y: k)
            ctx.translateBy(x: -frameInMaster.minX, y: -frameInMaster.minY)
            let ink = IntroPalette.ink
            func label(_ s: String, _ p: CGPoint, _ size: Double = 22) { ctx.draw(ctx.resolve(Text(s).font(.system(size: size, weight: .bold, design: .monospaced)).foregroundColor(IntroPalette.accentLight)), at: p, anchor: .leading) }
            switch role {
            case "room":
                ctx.fill(Path(CGRect(origin: .zero, size: master)), with: .color(ink.opacity(0.6)))
                for x in stride(from: 0.0, through: Double(master.width), by: 160) { ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: Double(master.height))) }, with: .color(IntroPalette.accent.opacity(0.18)), lineWidth: 1) }
                for y in stride(from: 0.0, through: Double(master.height), by: 160) { ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: Double(master.width), y: y)) }, with: .color(IntroPalette.accent.opacity(0.18)), lineWidth: 1) }
                label("TEST PLATE · room · parallax 0.55", CGPoint(x: 40, y: 40))
            case "laptop":
                let q = quad.map { CGPoint(x: $0[0], y: $0[1]) }
                var poly = Path(); poly.move(to: q[0]); for p in q.dropFirst() { poly.addLine(to: p) }; poly.closeSubpath()
                ctx.stroke(poly.strokedPath(StrokeStyle(lineWidth: 14)), with: .color(Color(red: 0.2, green: 0.21, blue: 0.25)))
                for (i, p) in q.enumerated() { ctx.fill(Path(ellipseIn: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)), with: .color(IntroPalette.accentLight)); label(["TL", "TR", "BR", "BL"][i], CGPoint(x: p.x + 14, y: p.y - 14), 18) }
                label("TEST PLATE · laptop + screen quad · parallax 1.0", CGPoint(x: 40, y: 80))
            case "person":
                let r = CGRect(x: 150, y: Double(master.height) * 0.28, width: 520, height: Double(master.height) * 0.72)
                ctx.fill(Path(roundedRect: r, cornerRadius: 40), with: .color(Color.black.opacity(0.55)))
                ctx.stroke(Path(roundedRect: r, cornerRadius: 40), with: .color(IntroPalette.accentLight.opacity(0.4)), style: StrokeStyle(lineWidth: 3, dash: [12, 8]))
                label("TEST PLATE · person · parallax 1.45", CGPoint(x: r.minX + 20, y: r.minY + 30))
            case "handsA", "handsB":
                let a = role == "handsA"
                let c = CGPoint(x: a ? 900 : 960, y: Double(master.height) * 0.76)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 46, y: c.y - 28, width: 92, height: 56)), with: .color((a ? IntroPalette.accent : IntroPalette.purple).opacity(0.85)))
                label(a ? "A keys" : "B pad", CGPoint(x: c.x - 40, y: c.y), 18)
            default: break
            }
            // never mistaken for artwork
            ctx.rotate(by: .degrees(-12))
            ctx.draw(ctx.resolve(Text("NOT ARTWORK").font(.system(size: 54, weight: .heavy)).foregroundColor(Color.white.opacity(0.05))), at: CGPoint(x: Double(master.width) * 0.5, y: Double(master.height) * 0.7), anchor: .center)
        }
    }
}
