import SwiftUI

// The camera: (zoom, centre) over the master design space, as keyed segments with zero velocity at every boundary (docs/intro-frame-spec.md, section 3), and the per-layer parallax that turns it into depth.

struct CameraState: Equatable { var zoom: Double; var centre: CGPoint }

enum FilmCamera {
    struct Segment { var from: Int; var to: Int; var zoom: (Double, Double); var centre: (CGPoint, CGPoint); var ease: CubicBezier }

    static func segments(for master: CGSize) -> [Segment] {
        let mid = CGPoint(x: master.width / 2, y: master.height / 2)
        let a = CGPoint(x: master.width * (1040.0 / 1920), y: master.height * (480.0 / 1080)), b = CGPoint(x: master.width * (1040.0 / 1920), y: master.height * (470.0 / 1080))
        return [
            Segment(from: 0, to: 120, zoom: (1.00, 1.95), centre: (mid, a), ease: .easeInOut),
            Segment(from: 120, to: 228, zoom: (1.95, 2.10), centre: (a, b), ease: .settle),
            Segment(from: 228, to: 432, zoom: (2.10, 2.10), centre: (b, b), ease: .linear),
            Segment(from: 432, to: 471, zoom: (2.10, 1.70), centre: (b, b), ease: .pullBack),
            Segment(from: 471, to: 531, zoom: (1.70, 1.55), centre: (b, b), ease: .toBrand),
            Segment(from: 531, to: 540, zoom: (1.55, 1.55), centre: (b, b), ease: .linear),
        ]
    }

    static func state(atFrame f: Double, master: CGSize = FilmSpec.master) -> CameraState {
        let segs = segments(for: master)
        let seg = segs.first { f >= Double($0.from) && f < Double($0.to) } ?? segs.last!
        let x = min(1, max(0, (f - Double(seg.from)) / Double(seg.to - seg.from)))
        let k = seg.ease.value(x)
        return CameraState(zoom: seg.zoom.0 + (seg.zoom.1 - seg.zoom.0) * k,
                           centre: CGPoint(x: seg.centre.0.x + (seg.centre.1.x - seg.centre.0.x) * k, y: seg.centre.0.y + (seg.centre.1.y - seg.centre.0.y) * k))
    }

    /// Parallax: how much of the camera a layer follows. The reference plane (the laptop and its screen) is 1.
    enum Depth: Double { case room = 0.55, laptop = 1.0, person = 1.45, foreground = 1.7 }

    /// The master-space -> window transform for a layer: the responsive fit (aspect-fill) composed with the camera, scaled by the layer's parallax.
    static func transform(_ cam: CameraState, depth: Double, window: CGSize, master: CGSize = FilmSpec.master) -> CGAffineTransform {
        let fit = max(window.width / master.width, window.height / master.height)
        let mid = CGPoint(x: master.width / 2, y: master.height / 2)
        let z = 1 + (cam.zoom - 1) * depth
        let focus = CGPoint(x: mid.x + (cam.centre.x - mid.x) * depth, y: mid.y + (cam.centre.y - mid.y) * depth)
        return CGAffineTransform(translationX: window.width / 2, y: window.height / 2).scaledBy(x: fit * z, y: fit * z).translatedBy(x: -focus.x, y: -focus.y)
    }
}
