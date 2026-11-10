import Foundation

// DX-08: exact time arithmetic and the one timeline model HLS and DASH share. Segment times are kept as whole numbers of ticks over a time scale and compared as fractions, so a long
// SegmentTimeline never drifts from repeated floating-point rounding. Every operation that could overflow says so (nil) instead of wrapping.

/// A non-negative-denominator fraction of a second, always reduced.
struct MediaRational: Equatable, Comparable, Hashable, Sendable {
    let n: Int64
    let d: Int64

    init?(_ n: Int64, _ d: Int64) {
        guard d != 0, n != Int64.min, d != Int64.min else { return nil }
        let g = Self.gcd(abs(n), abs(d))
        let sign: Int64 = d < 0 ? -1 : 1
        self.n = sign * n / max(1, g); self.d = abs(d) / max(1, g)
    }

    static let zero = MediaRational(0, 1)!
    var seconds: Double { Double(n) / Double(d) }

    static func gcd(_ a: Int64, _ b: Int64) -> Int64 { var (a, b) = (a, b); while b != 0 { (a, b) = (b, a % b) }; return a }

    static func + (a: MediaRational, b: MediaRational) -> MediaRational? { a.adding(b) }
    static func - (a: MediaRational, b: MediaRational) -> MediaRational? { a.adding(MediaRational(-b.n, b.d)!) }

    func adding(_ o: MediaRational) -> MediaRational? {
        let (l, o1) = n.multipliedReportingOverflow(by: o.d), (r, o2) = o.n.multipliedReportingOverflow(by: d), (den, o3) = d.multipliedReportingOverflow(by: o.d)
        guard !o1, !o2, !o3 else { return nil }
        let (sum, o4) = l.addingReportingOverflow(r)
        return o4 ? nil : MediaRational(sum, den)
    }
    func scaled(by k: Int64) -> MediaRational? {
        let (v, o) = n.multipliedReportingOverflow(by: k)
        return o ? nil : MediaRational(v, d)
    }
    static func < (a: MediaRational, b: MediaRational) -> Bool {
        let l = a.n.multipliedFullWidth(by: b.d), r = b.n.multipliedFullWidth(by: a.d)
        if l.high != r.high { return l.high < r.high }
        return l.low < r.low
    }

    /// The number of `unit`-tick intervals in this time, rounded up. nil on overflow or a non-positive unit.
    func ceilingTicks(scale: Int64) -> Int64? {
        guard scale > 0 else { return nil }
        let (num, o) = n.multipliedReportingOverflow(by: scale)
        guard !o else { return nil }
        let q = num / d, r = num % d
        return r > 0 ? q + 1 : q
    }
    func roundedTicks(scale: Int64) -> Int64? {
        guard scale > 0 else { return nil }
        let (num, o) = n.multipliedReportingOverflow(by: scale)
        guard !o else { return nil }
        return (num + d / 2) / d
    }

    /// "90.5" or "30" (decimal text of a duration) exactly, with at most nine fractional digits.
    static func decimal(_ text: String) -> MediaRational? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, let whole = Int64(parts[0].isEmpty ? "0" : String(parts[0])), whole >= 0 else { return nil }
        guard parts.count == 2 else { return MediaRational(whole, 1) }
        let frac = parts[1]
        guard !frac.isEmpty, frac.count <= 9, frac.allSatisfy(\.isNumber), let f = Int64(frac) else { return nil }
        var den: Int64 = 1
        for _ in 0..<frac.count { den *= 10 }
        guard let w = MediaRational(whole, 1).flatMap({ $0.scaled(by: den) }) else { return nil }
        let (sum, o) = w.n.addingReportingOverflow(f)
        return o ? nil : MediaRational(sum, den)
    }
}

/// What a timeline analysis found. Gaps and overlaps are in seconds on the presentation timeline.
struct MediaTimelineReport: Equatable, Sendable {
    struct Issue: Equatable, Sendable { var afterSegment: Int; var seconds: Double }
    var gaps: [Issue] = []
    var overlaps: [Issue] = []
    /// The end of the last segment, when the segments carry exact times (otherwise the sum of their durations).
    var end: Double = 0
    /// Sum of the segments' own durations.
    var covered: Double = 0
    var isContinuous: Bool { gaps.isEmpty && overlaps.isEmpty }
}

enum MediaTimeline {
    /// How far apart two neighbouring segments may be before it counts as a gap or an overlap. One tick of the segment time scale is the resolution of the manifest, and a stream
    /// that rounds each segment's length to milliseconds (HLS EXTINF commonly does) cannot be exact below that; so the larger of the two is allowed.
    static func tolerance(scale: Int64?) -> Double {
        max(0.001, scale.map { 1.0 / Double(max(1, $0)) } ?? 0)
    }

    /// Looks at one stream's segments in order. Segments with exact times (DASH) are compared as fractions; others (HLS) follow each other by definition, so only their total is reported.
    static func analyze(_ segments: [MediaSegment]) -> MediaTimelineReport {
        var r = MediaTimelineReport()
        r.covered = segments.reduce(0) { $0 + $1.duration }
        r.end = r.covered
        guard segments.allSatisfy({ $0.ticks != nil && $0.scale != nil && $0.startTicks != nil }), segments.count > 0 else { return r }
        var endOfPrevious: MediaRational?
        for (i, s) in segments.enumerated() {
            guard let ticks = s.ticks, let scale = s.scale, let start = s.startTicks, let from = MediaRational(start, scale), let length = MediaRational(ticks, scale), let to = from + length else { return r }
            if let prev = endOfPrevious {
                let gap = from - prev
                let tol = tolerance(scale: scale)
                if let gap, gap.seconds > tol { r.gaps.append(.init(afterSegment: i - 1, seconds: gap.seconds)) }
                else if let gap, gap.seconds < -tol { r.overlaps.append(.init(afterSegment: i - 1, seconds: -gap.seconds)) }
            }
            endOfPrevious = to
            r.end = to.seconds
        }
        return r
    }

    /// How far the length of what was downloaded may differ from what the manifest promised. Derived, not guessed: a playlist whose segment lengths are whole seconds can be off by half a
    /// second per segment (the rounding it applied), one with millisecond lengths by half a millisecond; an AAC frame is 1024 samples (about 23 ms at 44.1 kHz) and the container may add
    /// or trim two of them as priming; a video frame can be added or cut at either end.
    static func durationTolerance(segmentCount: Int, segments: [MediaSegment], frameRate: Double?) -> Double {
        let frame = 1.0 / max(1, min(frameRate ?? 24, 120))
        let whole = !segments.isEmpty && segments.allSatisfy { $0.ticks == nil && $0.duration == $0.duration.rounded() }
        return (whole ? 0.5 : 0.0005) * Double(max(segmentCount, 1)) + 2 * (1024.0 / 44_100.0) + 2 * frame
    }

    /// How far the audio and the video of one output may differ in length before the person is told: the same two audio frames and one video frame at either end.
    static func syncTolerance(frameRate: Double?) -> Double {
        let frame = 1.0 / max(1, min(frameRate ?? 24, 120))
        return 2 * (1024.0 / 44_100.0) + 2 * frame
    }
}
