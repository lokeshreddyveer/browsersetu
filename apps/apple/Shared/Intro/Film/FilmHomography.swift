import SwiftUI
import QuartzCore

// Perspective: a live SwiftUI view (the screen's content, in its own flat coordinates) mapped onto the four corners of the laptop's screen in the artwork. A homography, expressed as a CATransform3D so that
// SwiftUI's projectionEffect can apply it. Corners are in the order top-left, top-right, bottom-right, bottom-left.

enum FilmHomography {
    /// The 3x3 projective map taking the rectangle (0,0,w,h) to the quad, as (a, b, c, d, e, f, g, h): x' = (a x + b y + c) / (g x + h y + 1), y' = (d x + e y + f) / (g x + h y + 1).
    static func solve(from size: CGSize, to q: [CGPoint]) -> [Double]? {
        guard q.count == 4, size.width > 0, size.height > 0 else { return nil }
        let src = [(0.0, 0.0), (Double(size.width), 0.0), (Double(size.width), Double(size.height)), (0.0, Double(size.height))]
        var m = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
        for i in 0..<4 {
            let (x, y) = src[i], u = Double(q[i].x), v = Double(q[i].y)
            m[2 * i] = [x, y, 1, 0, 0, 0, -x * u, -y * u, u]
            m[2 * i + 1] = [0, 0, 0, x, y, 1, -x * v, -y * v, v]
        }
        // Gaussian elimination with partial pivoting
        for c in 0..<8 {
            var p = c
            for r in (c + 1)..<8 where abs(m[r][c]) > abs(m[p][c]) { p = r }
            if abs(m[p][c]) < 1e-12 { return nil }
            m.swapAt(c, p)
            let d = m[c][c]
            for k in c..<9 { m[c][k] /= d }
            for r in 0..<8 where r != c {
                let f = m[r][c]
                if f != 0 { for k in c..<9 { m[r][k] -= f * m[c][k] } }
            }
        }
        return (0..<8).map { m[$0][8] }
    }

    static func apply(_ h: [Double], _ p: CGPoint) -> CGPoint {
        let x = Double(p.x), y = Double(p.y)
        let w = h[6] * x + h[7] * y + 1
        return CGPoint(x: (h[0] * x + h[1] * y + h[2]) / w, y: (h[3] * x + h[4] * y + h[5]) / w)
    }

    /// The same map as a CATransform3D (row-vector convention), for projectionEffect.
    static func transform3D(_ h: [Double]) -> CATransform3D {
        var t = CATransform3DIdentity
        t.m11 = CGFloat(h[0]); t.m12 = CGFloat(h[3]); t.m14 = CGFloat(h[6])
        t.m21 = CGFloat(h[1]); t.m22 = CGFloat(h[4]); t.m24 = CGFloat(h[7])
        t.m41 = CGFloat(h[2]); t.m42 = CGFloat(h[5]); t.m44 = 1
        return t
    }
}
