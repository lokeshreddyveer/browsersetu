import SwiftUI

// The film's contract (docs/intro-frame-spec.md): 9.0 s at 60 fps = 540 frames, on a 1920 x 1080 design space. This file is data and arithmetic only: no drawing, no artwork.

enum FilmSpec {
    static let fps = 60.0
    static let frames = 540
    static let duration = Double(frames) / fps           // 9.0 s
    static let master = CGSize(width: 1920, height: 1080)
    static let masterPortrait = CGSize(width: 1080, height: 1920)

    struct Scene: Equatable { let id: Int; let name: String; let frames: ClosedRange<Int> }
    static let scenes: [Scene] = [
        Scene(id: 1, name: "A person browsing", frames: 0...119),
        Scene(id: 2, name: "The unseen activity", frames: 120...227),
        Scene(id: 3, name: "Unwanted activity", frames: 228...311),
        Scene(id: 4, name: "Protection", frames: 312...431),
        Scene(id: 5, name: "Calm and brand", frames: 432...539),
    ]
    /// The frames to inspect (docs/intro-frame-spec.md, section 11).
    static let checkpoints = [0, 15, 30, 60, 90, 119, 120, 150, 180, 205, 227, 228, 255, 280, 311, 312, 340, 365, 390, 415, 431, 432, 470, 505, 530, 539]

    /// A fractional frame for a time in seconds, clamped to the film.
    static func frame(atTime t: Double) -> Double { min(Double(frames - 1), max(0, t * fps)) }
    static func time(ofFrame f: Double) -> Double { f / fps }
    static func scene(ofFrame f: Int) -> Scene? { scenes.first { $0.frames.contains(f) } }
}

/// Every moment the screen content reacts to, in seconds, from the frame table. One place, so the choreography is read from the spec and not scattered as numbers.
enum FilmCue {
    private static func s(_ f: Int) -> Double { Double(f) / FilmSpec.fps }
    // Scene 1
    static let screenLightUp = (s(0), s(20)), pageAppears = (s(21), s(55)), scroll1 = (s(56), s(90))
    // Scene 2: the page separates, requests emerge from named regions, the camera settles
    static let separate = (s(151), s(180)), requests = (s(181), s(205)), settle = (s(206), s(227))
    // Scene 3: one event at a time
    static let adGrows = (s(228), s(255)), tracker = (s(256), s(280)), link = (s(281), s(311)), popup = (s(296), s(311))
    // Scene 4: protection
    static let edgeTravels = (s(312), s(340)), boundaryCompletes = (s(341), s(365)), adRejected = (s(341), s(365))
    static let trackerFiltered = (s(366), s(378)), addressCleaned = (s(379), s(390)), popupRefused = (s(391), s(405)), warning = (s(391), s(415)), settleProtection = (s(416), s(431))
    // Scene 5
    static let calm = (s(432), s(470)), dissolve = (s(471), s(505)), brand = (s(506), s(530)), handoff = (s(531), s(539))
}

// MARK: easing

struct CubicBezier: Equatable {
    var x1: Double, y1: Double, x2: Double, y2: Double
    static let linear = CubicBezier(x1: 0, y1: 0, x2: 1, y2: 1)
    static let easeInOut = CubicBezier(x1: 0.45, y1: 0, x2: 0.20, y2: 1)
    static let settle = CubicBezier(x1: 0.30, y1: 0, x2: 0.30, y2: 1)
    static let pullBack = CubicBezier(x1: 0.40, y1: 0, x2: 0.20, y2: 1)
    static let toBrand = CubicBezier(x1: 0.45, y1: 0, x2: 0.55, y2: 1)

    /// y for an x in 0...1 (the curve is a function of x: solve for the parameter, then evaluate).
    func value(_ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        func bx(_ t: Double) -> Double { 3 * (1 - t) * (1 - t) * t * x1 + 3 * (1 - t) * t * t * x2 + t * t * t }
        func by(_ t: Double) -> Double { 3 * (1 - t) * (1 - t) * t * y1 + 3 * (1 - t) * t * t * y2 + t * t * t }
        var lo = 0.0, hi = 1.0, t = x
        for _ in 0..<40 { t = (lo + hi) / 2; if bx(t) < x { lo = t } else { hi = t } }
        return by(t)
    }
}

/// A value over frames: keys with the curve of the segment that starts at each key.
struct Track {
    struct Key { var frame: Double; var value: Double; var ease: CubicBezier = .linear }
    var keys: [Key]
    init(_ keys: [Key]) { self.keys = keys.sorted { $0.frame < $1.frame } }
    func value(at f: Double) -> Double {
        guard let first = keys.first, let last = keys.last else { return 0 }
        if f <= first.frame { return first.value }
        if f >= last.frame { return last.value }
        for i in 0..<(keys.count - 1) where f >= keys[i].frame && f <= keys[i + 1].frame {
            let span = keys[i + 1].frame - keys[i].frame
            let x = span > 0 ? (f - keys[i].frame) / span : 1
            return keys[i].value + (keys[i + 1].value - keys[i].value) * keys[i].ease.value(x)
        }
        return last.value
    }
}
