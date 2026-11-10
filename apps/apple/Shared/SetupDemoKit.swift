import SwiftUI

/// The pieces every animated picture in the setup assistant is made of: a looping clock, a pointer that moves between keyframes and clicks, and a stage that fades each loop
/// in and out. One implementation, used by every step, so the pictures move the same way.
enum SetupDemoKit {
    /// 0 before `a`, 1 after `b`, a smooth ramp between.
    static func ease(_ t: Double, _ a: Double, _ b: Double) -> CGFloat {
        let x = min(max((t - a) / (b - a), 0), 1)
        return CGFloat(x * x * (3 - 2 * x))
    }

    /// The pointer's place at time `t`, moving smoothly from one key to the next.
    static func place(_ t: Double, _ keys: [(Double, CGPoint)]) -> CGPoint {
        guard var previous = keys.first else { return .zero }
        if t <= previous.0 { return previous.1 }
        for key in keys.dropFirst() {
            if t <= key.0 {
                let f = ease(t, previous.0, key.0)
                return CGPoint(x: previous.1.x + (key.1.x - previous.1.x) * f, y: previous.1.y + (key.1.y - previous.1.y) * f)
            }
            previous = key
        }
        return previous.1
    }

    /// How far into a click's ripple `t` is (0...1), or -1 when no click is happening.
    static func ripple(_ t: Double, _ clicks: [Double]) -> CGFloat {
        for c in clicks where t >= c && t < c + 0.08 { return CGFloat((t - c) / 0.08) }
        return -1
    }

    struct PointerArrow: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            let s = r.height / 18
            func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: r.minX + CGFloat(x) * s, y: r.minY + CGFloat(y) * s) }
            p.move(to: pt(0, 0)); p.addLine(to: pt(0, 15.5)); p.addLine(to: pt(3.6, 12.2)); p.addLine(to: pt(6.2, 18)); p.addLine(to: pt(8.5, 17)); p.addLine(to: pt(6, 11.4)); p.addLine(to: pt(10.6, 11.4)); p.closeSubpath()
            return p
        }
    }

    static func pointer(_ at: CGPoint, ripple r: CGFloat, accent: Color) -> some View {
        ZStack {
            Circle().strokeBorder(accent, lineWidth: 1.6).frame(width: 24, height: 24)
                .scaleEffect(0.3 + max(r, 0) * 1.2).opacity(r >= 0 ? Double(1 - r) : 0).position(at)
            PointerArrow().fill(Color.white)
                .overlay(PointerArrow().stroke(Color.black.opacity(0.8), lineWidth: 1))
                .frame(width: 11, height: 16)
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                .position(x: at.x + 4.5, y: at.y + 7)
        }
        .allowsHitTesting(false)
    }

    /// A row of dots that fills in as something is typed.
    static func typedDots(_ count: Int, size: CGFloat, ink: Color, total: Int = 8) -> some View {
        HStack(spacing: size * 0.8) { ForEach(0..<total, id: \.self) { i in Circle().fill(ink).frame(width: size, height: size).opacity(i < count ? 1 : 0) } }
    }
}

/// A looping scene: gives `content` the time of the loop (0...1), fades the scene in and out at the loop's ends, stands still under Reduce Motion (at `restT`) and
/// stops drawing when it is off screen or the app is not active. Framed scenes are drawn inside a miniature window.
struct SetupDemoStage<Content: View>: View {
    var duration: Double = 5
    var restT: Double = 0.56
    var framed = true
    var size = CGSize(width: 256, height: 160)
    @ViewBuilder var content: (_ w: CGFloat, _ h: CGFloat, _ t: Double, _ pal: MiniPalette) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var scheme
    @State private var visible = false
    /// When this picture appeared. Its loop starts here, so a step that has just opened (or a layout that has just been chosen) shows its first action at once, not partway through a loop.
    @State private var started = Date()

    var body: some View {
        let pal = MiniPalette(scheme: scheme, selected: true)
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || !visible || scenePhase != .active)) { context in
            let t = reduceMotion ? restT : max(0, context.date.timeIntervalSince(started)).truncatingRemainder(dividingBy: duration) / duration
            let fade = reduceMotion ? 1.0 : Double(min(SetupDemoKit.ease(t, 0, 0.05), 1 - SetupDemoKit.ease(t, 0.95, 1)))
            if framed {
                MiniWindowFrame(p: pal) { w, h in content(w, h, t, pal).opacity(fade) }
            } else {
                content(size.width, size.height, t, pal).frame(width: size.width, height: size.height).opacity(fade)
            }
        }
        .onAppear { started = Date(); visible = true }
        .onDisappear { visible = false }
        .accessibilityHidden(true)
    }
}
