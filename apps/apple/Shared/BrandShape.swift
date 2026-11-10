import SwiftUI

/// A minimal SVG path interpreter (absolute M L H V C Q Z only, which is all the brand artwork uses), scaled from a square design grid of `unit` points to whatever rect it is given.
/// `transform` is applied in design-grid units first, so artwork drawn on another grid (the continents are on a 256 grid) can be placed on this one.
struct SVGShape: Shape {
    var d: String
    var unit: CGFloat = 256
    var transform: CGAffineTransform = .identity

    func path(in rect: CGRect) -> Path {
        var p = Path()
        var nums: [CGFloat] = []
        var cmd: Character = "M"
        var cur = CGPoint.zero
        func flush() {
            switch cmd {
            case "M": if nums.count >= 2 { cur = CGPoint(x: nums[0], y: nums[1]); p.move(to: cur) }
            case "L": if nums.count >= 2 { cur = CGPoint(x: nums[0], y: nums[1]); p.addLine(to: cur) }
            case "H": if let x = nums.first { cur.x = x; p.addLine(to: cur) }
            case "V": if let y = nums.first { cur.y = y; p.addLine(to: cur) }
            case "C": if nums.count >= 6 { cur = CGPoint(x: nums[4], y: nums[5]); p.addCurve(to: cur, control1: CGPoint(x: nums[0], y: nums[1]), control2: CGPoint(x: nums[2], y: nums[3])) }
            case "Q": if nums.count >= 4 { cur = CGPoint(x: nums[2], y: nums[3]); p.addQuadCurve(to: cur, control: CGPoint(x: nums[0], y: nums[1])) }
            case "Z": p.closeSubpath()
            default: break
            }
            nums.removeAll()
        }
        var token = ""
        func endNumber() { if !token.isEmpty, let v = Double(token) { nums.append(CGFloat(v)) }; token = "" }
        let commands: Set<Character> = ["M", "L", "H", "V", "C", "Q", "Z"]
        for ch in d {
            if commands.contains(ch) {
                endNumber(); flush(); cmd = ch
                if ch == "Z" { flush() }
            } else if ch == "," || ch == " " {
                endNumber()
            } else if ch == "-" {
                endNumber(); token = "-"
            } else {
                token.append(ch)
            }
        }
        endNumber(); flush()
        let s = rect.width / unit
        return p.applying(transform).applying(CGAffineTransform(scaleX: s, y: s)).applying(CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }
}
