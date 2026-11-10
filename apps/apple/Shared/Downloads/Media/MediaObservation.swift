import Foundation

// DX-07: what the browser learns, while a page is open, about the media it plays. This file is the pure half: it describes an observation, checks one that arrived from a page, and keeps
// the observations of one tab bounded. It reads no page, opens no connection and writes nothing; the page-side script (Engines/WebKit/MediaPageObserver.swift) and the existing
// MediaDiscoveryStore (Phase 18) are the other halves. There is no second discovery model: observations become the same `MediaPageHit`s the Phase 18 page read produces.
//
// Trust: a page can send anything, so nothing in a message is believed beyond its own shape. The frame's origin and whether it is the main frame are never read from the message: they are
// given by WebKit (WKFrameInfo) and passed in as `MediaFrameFacts`. The frame token in a message only tells two frames of the same origin apart; it is made by the browser's own script in
// its isolated world, which the page cannot reach.

/// How a candidate was found. Ordered by how much it proves: a source a media element is playing right now is stronger than a link, which is stronger than a guess.
enum MediaDiscoveryMethod: String, Sendable, CaseIterable {
    case mediaElement          // HTMLMediaElement.currentSrc / src: what the element is playing
    case mediaEvent            // an element's own event (loadedmetadata, durationchange…) reported its state
    case sourceElement         // a <source> inside an element, declared but not necessarily the one chosen
    case manifestReference     // a streaming playlist a player was seen to load (Resource Timing)
    case resourceTiming        // another resource the page loaded that is media
    case pageMetadata          // declared by the page (poster, track)
    case navigationResponse    // seen in a navigation response WebKit reported
    case userSelected          // the person chose a link
    case pageScan              // the Phase 18 read of the page on request

    /// Higher is stronger evidence.
    var strength: Int {
        switch self {
        case .mediaElement: 90
        case .mediaEvent: 80
        case .manifestReference: 70
        case .navigationResponse: 65
        case .userSelected: 60
        case .sourceElement: 55
        case .pageScan: 50
        case .resourceTiming: 40
        case .pageMetadata: 20
        }
    }
    var label: String {
        switch self {
        case .mediaElement, .mediaEvent: "Playing in the page"
        case .sourceElement: "Declared by the page"
        case .manifestReference: "Loaded by the player"
        case .resourceTiming: "Loaded by the page"
        case .pageMetadata: "Page metadata"
        case .navigationResponse: "Page response"
        case .userSelected: "Chosen link"
        case .pageScan: "Read from the page"
        }
    }
}

/// How sure the evidence makes us.
enum MediaConfidence: Int, Comparable, Sendable {
    case weak = 0, fair = 1, strong = 2
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    init(method: MediaDiscoveryMethod) { self = method.strength >= 80 ? .strong : (method.strength >= 50 ? .fair : .weak) }
    var label: String { switch self { case .strong: "Confirmed"; case .fair: "Likely"; case .weak: "Possible" } }
}

/// A frame as WebKit says it is. `origin` and `isMain` come from the engine, never from the page.
struct MediaFrameFacts: Equatable, Sendable {
    var origin: String
    var isMain: Bool
}

/// A frame a player lives in: the token tells frames of one origin apart (it is made per document, so a frame that navigates is a new one).
struct MediaFrameRef: Equatable, Hashable, Sendable {
    var token: String
    var origin: String
    var isMain: Bool
}

/// One player (a video or audio element) in one frame of one document.
struct MediaPlayerRef: Equatable, Hashable, Sendable {
    var frame: MediaFrameRef
    var player: Int
    var key: String { "\(frame.token):\(player)" }
}

/// A subtitle, caption or other track a player declares.
struct MediaTrackRef: Equatable, Sendable {
    var kind: String           // subtitles, captions, descriptions, chapters, metadata
    var language: String?
    var label: String?
    /// The track file's address. Used only to offer it; never shown (it may carry a signed query).
    var href: String?
}

struct MediaObservation: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case hello, player, gone, resources, frames, bye }
    var kind: Kind
    var frame: MediaFrameRef
    var player: Int?
    var tag = "video"
    var current: String?
    var attributeSource: String?
    var declared: [(href: String, type: String)] = []
    var type = ""
    var duration: Double?
    var width: Int?
    var height: Int?
    var loaded = false
    var poster: String?
    var tracks: [MediaTrackRef] = []
    var blob = false
    var drm = false
    var playing: Bool?
    var title: String?
    var resources: [(url: String, initiator: String)] = []
    /// For `.frames`: how many frames (iframe elements) this document holds, and how many of those are sandboxed so that scripts cannot run in them.
    var frameCount = 0
    var sandboxedCount = 0

    static func == (a: Self, b: Self) -> Bool {
        a.kind == b.kind && a.frame == b.frame && a.player == b.player && a.tag == b.tag && a.current == b.current && a.attributeSource == b.attributeSource
            && a.declared.elementsEqual(b.declared, by: { $0 == $1 }) && a.type == b.type && a.duration == b.duration && a.width == b.width && a.height == b.height && a.loaded == b.loaded
            && a.poster == b.poster && a.tracks == b.tracks && a.blob == b.blob && a.drm == b.drm && a.playing == b.playing && a.title == b.title
            && a.resources.elementsEqual(b.resources, by: { $0 == $1 }) && a.frameCount == b.frameCount && a.sandboxedCount == b.sandboxedCount
    }
}

enum MediaObservationParser {
    static let maxText = 8192
    static let maxDeclared = 20
    static let maxTracks = 20
    static let maxResources = 20
    static let maxPlayerNumber = 1_000_000

    private static func text(_ any: Any?, limit: Int = maxText) -> String? {
        guard let s = any as? String, !s.isEmpty, s.utf8.count <= limit else { return nil }
        return s
    }
    private static func finite(_ any: Any?) -> Double? {
        guard let n = any as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }
    private static func whole(_ any: Any?, max: Int) -> Int? {
        guard let d = finite(any), d >= 0, d <= Double(max), d == d.rounded() else { return nil }
        return Int(d)
    }
    private static func flag(_ any: Any?) -> Bool? {
        guard let n = any as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    /// Checks a message from a page. `facts` is what WebKit says about the frame that sent it. Anything malformed, oversized or out of range is refused (nil), never repaired.
    static func parse(_ body: Any, frame facts: MediaFrameFacts) -> MediaObservation? {
        guard let d = body as? [String: Any], let t = d["t"] as? String, let token = text(d["f"], limit: 64), token.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        // Any "origin" the page put in the message is ignored on purpose.
        let frame = MediaFrameRef(token: token, origin: facts.origin, isMain: facts.isMain)
        switch t {
        case "hello":
            return MediaObservation(kind: .hello, frame: frame)
        case "gone":
            guard let p = whole(d["p"], max: maxPlayerNumber) else { return nil }
            var o = MediaObservation(kind: .gone, frame: frame); o.player = p
            return o
        case "bye":
            return MediaObservation(kind: .bye, frame: frame)
        case "frames":
            guard let n = whole(d["n"], max: 10_000), let blocked = whole(d["b"], max: 10_000), blocked <= n else { return nil }
            var o = MediaObservation(kind: .frames, frame: frame); o.frameCount = n; o.sandboxedCount = blocked
            return o
        case "res":
            guard let list = d["r"] as? [[String: Any]], list.count <= maxResources else { return nil }
            var o = MediaObservation(kind: .resources, frame: frame)
            for item in list { if let u = text(item["u"]) { o.resources.append((url: u, initiator: text(item["i"], limit: 32) ?? "")) } }
            return o.resources.isEmpty ? nil : o
        case "player":
            guard let p = whole(d["p"], max: maxPlayerNumber), let tag = d["tag"] as? String, tag == "video" || tag == "audio" else { return nil }
            var o = MediaObservation(kind: .player, frame: frame); o.player = p; o.tag = tag
            o.current = text(d["cur"]); o.attributeSource = text(d["src"])
            if let list = d["srcs"] as? [[String: Any]] {
                guard list.count <= maxDeclared else { return nil }
                for item in list { if let u = text(item["u"]) { o.declared.append((href: u, type: text(item["t"], limit: 100) ?? "")) } }
            }
            o.type = text(d["type"], limit: 100) ?? ""
            if let dur = finite(d["dur"]), dur > 0, dur < 1e9 { o.duration = dur }
            o.width = whole(d["w"], max: 20_000); o.height = whole(d["h"], max: 20_000)
            o.loaded = flag(d["loaded"]) ?? false
            o.poster = text(d["poster"])
            if let list = d["tracks"] as? [[String: Any]] {
                guard list.count <= maxTracks else { return nil }
                for item in list {
                    o.tracks.append(MediaTrackRef(kind: text(item["k"], limit: 24) ?? "subtitles", language: text(item["l"], limit: 140), label: text(item["n"], limit: 480), href: text(item["u"])))
                }
            }
            o.blob = flag(d["blob"]) ?? false
            o.drm = flag(d["drm"]) ?? false
            o.playing = flag(d["playing"])
            o.title = text(d["title"], limit: 800)
            return o
        default:
            return nil
        }
    }
}

/// The observations of one tab, bounded. A tab owns one (so a closed tab takes its observations with it), and a committed navigation empties it: a frame that was not announced since then is
/// not believed, so a late message from the page that was left is dropped.
final class MediaObservationBuffer {
    static let maxFrames = 100
    static let maxPlayers = 300
    static let maxPlayersPerFrame = 100
    static let maxResources = 100
    static let burst = 60.0
    static let refillPerSecond = 30.0

    private struct State { var obs: MediaObservation; var order: Int }
    private var frames: [String: MediaFrameRef] = [:]
    private var players: [String: State] = [:]
    private var resources: [String: (url: String, initiator: String, frame: MediaFrameRef, order: Int)] = [:]
    private var counter = 0
    private var declared: [String: (frames: Int, sandboxed: Int)] = [:]
    private var tokens = MediaObservationBuffer.burst
    private var tokensAt: TimeInterval = 0
    private(set) var navigation = 0
    private(set) var dropped = 0

    var isEmpty: Bool { players.isEmpty && resources.isEmpty }
    var playerCount: Int { players.count }
    var frameCount: Int { frames.count }
    /// Frames the page holds that this browser could not look into: the pages' iframes counted by their own documents, less the frames that announced themselves (a sandboxed frame without
    /// script permission never runs the observer, and WebKit does not let anything else read it). Frames the observer never reaches are named, not guessed at.
    var unobservedFrames: Int {
        let total = declared.values.reduce(0) { $0 + $1.frames }
        // A frame counts as observed once it has an origin of its own or has shown a player. A frame announcing itself with an opaque origin may be only the blank document a sandboxed frame starts
        // with, before its real (script-less) document replaces it.
        let withPlayers = Set(players.values.map { $0.obs.frame.token })
        let announced = frames.values.filter { !$0.isMain && (!Self.isOpaque($0.origin) || withPlayers.contains($0.token)) }.count
        return max(0, total - announced)
    }
    static func isOpaque(_ origin: String) -> Bool { origin.isEmpty || origin == "://" || origin.lowercased().hasPrefix("null") || origin.hasSuffix("://") }
    var sandboxedFrames: Int { declared.values.reduce(0) { $0 + $1.sandboxed } }

    /// A new document was committed in the main frame: everything seen so far belongs to the page that was left.
    func navigated() {
        navigation += 1
        frames = [:]; players = [:]; resources = [:]; declared = [:]
    }

    /// Takes one observation. Returns whether the picture changed (false for a repeat, a message over the rate, or one from a frame that was never announced).
    @discardableResult
    func accept(_ o: MediaObservation, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        tokens = min(Self.burst, tokens + (now - tokensAt) * Self.refillPerSecond); tokensAt = now
        // Announcements and departures are few (a frame says hello once and bye once) and are never throttled, so a chatty frame cannot make another frame invisible; the number of frames is capped instead.
        let control = o.kind == .hello || o.kind == .gone || o.kind == .bye || o.kind == .frames
        if !control { guard tokens >= 1 else { dropped += 1; return false }; tokens -= 1 }
        counter += 1
        switch o.kind {
        case .hello:
            if frames[o.frame.token] == nil, frames.count >= Self.maxFrames {
                // A frame replaced without a goodbye must not hold its place forever: the oldest frame that shows no player makes room.
                let busy = Set(players.values.map { $0.obs.frame.token })
                guard let stale = frames.keys.first(where: { !busy.contains($0) && frames[$0]?.isMain == false }) else { dropped += 1; return false }
                removeFrame(stale)
            }
            let known = frames[o.frame.token] != nil
            frames[o.frame.token] = o.frame
            return !known
        case .bye:
            // The document in that frame is going away (it navigated, or the frame was removed): what it held goes with it.
            guard frames[o.frame.token] == o.frame else { return false }
            removeFrame(o.frame.token)
            return true
        case .frames:
            guard frames[o.frame.token] == o.frame else { dropped += 1; return false }
            let old = declared[o.frame.token]
            declared[o.frame.token] = (o.frameCount, o.sandboxedCount)
            return old?.frames != o.frameCount || old?.sandboxed != o.sandboxedCount
        case .gone:
            guard frames[o.frame.token] == o.frame, let p = o.player else { return false }
            return players.removeValue(forKey: MediaPlayerRef(frame: o.frame, player: p).key) != nil
        case .resources:
            guard frames[o.frame.token] == o.frame else { dropped += 1; return false }
            var changed = false
            for r in o.resources {
                let key = o.frame.token + "|" + r.url
                if resources[key] == nil {
                    if resources.count >= Self.maxResources, let oldest = resources.min(by: { $0.value.order < $1.value.order })?.key { resources[oldest] = nil }
                    resources[key] = (r.url, r.initiator, o.frame, counter); changed = true
                }
            }
            return changed
        case .player:
            // A frame must have announced itself since the last navigation, and the origin must be the one WebKit gave for it then.
            guard frames[o.frame.token] == o.frame, let p = o.player else { dropped += 1; return false }
            let key = MediaPlayerRef(frame: o.frame, player: p).key
            if let old = players[key] {
                guard old.obs != o else { return false }
                players[key] = State(obs: o, order: old.order)
                return true
            }
            guard players.filter({ $0.value.obs.frame.token == o.frame.token }).count < Self.maxPlayersPerFrame else { dropped += 1; return false }
            if players.count >= Self.maxPlayers, let oldest = players.min(by: { $0.value.order < $1.value.order })?.key { players[oldest] = nil }
            players[key] = State(obs: o, order: counter)
            return true
        }
    }

    /// The frame went away (its element was removed, or it navigated): its players go with it.
    func removeFrame(_ token: String) {
        frames[token] = nil
        players = players.filter { $0.value.obs.frame.token != token }
        resources = resources.filter { $0.value.frame.token != token }
        declared[token] = nil
    }

    /// The page read and the observer both see the media elements. Where the observer has players, its hits stand for the elements (they carry the frame and player); the page read adds what
    /// the observer cannot: links, and elements in frames it was not in. A blob or protected element the page read found is dropped when the observer saw that kind of element, so it is
    /// not listed twice under two names.
    static func merge(scan: [MediaPageHit], observed: [MediaPageHit]) -> [MediaPageHit] {
        guard !observed.isEmpty else { return scan }
        let observedTags = Set(observed.filter { $0.player != nil }.map { $0.element == "source" ? "video" : $0.element })
        let kept = scan.filter { !($0.href == nil && ($0.blob || $0.drm) && observedTags.contains($0.element)) }
        return observed + kept
    }

    /// The players seen, as the same hits the Phase 18 page read makes (so there is one path into the candidate list).
    func hits() -> [MediaPageHit] {
        var out: [MediaPageHit] = []
        for state in players.values.sorted(by: { $0.order < $1.order }) {
            let o = state.obs, ref = MediaPlayerRef(frame: o.frame, player: o.player ?? 0)
            let hasVideo: Bool? = o.tag == "audio" ? false : (o.loaded ? (o.width ?? 0) > 0 : nil)
            func hit(_ href: String?, _ element: String, _ method: MediaDiscoveryMethod, blob: Bool = false) -> MediaPageHit {
                MediaPageHit(href: href, element: element, type: o.type, duration: o.duration, drm: o.drm, blob: blob, frame: o.frame, player: ref, poster: o.poster, tracks: o.tracks,
                             width: o.width, height: o.height, hasVideo: hasVideo, method: method, playing: o.playing, title: o.title)
            }
            let chosen = o.current ?? o.attributeSource
            if let c = chosen, c.lowercased().hasPrefix("blob:") { out.append(hit(nil, o.tag, o.loaded ? .mediaEvent : .mediaElement, blob: true)) }
            else if let c = chosen { out.append(hit(c, o.tag, o.loaded ? .mediaEvent : .mediaElement)) }
            else if o.drm || o.blob { out.append(hit(nil, o.tag, .mediaElement, blob: true)) }
            else {
                // Nothing chosen yet (it starts when played, or the page has not set one): the declared sources are reported as what the page offers, not as playing.
                for s in o.declared where !s.href.lowercased().hasPrefix("blob:") {
                    var h = hit(s.href, "source", .sourceElement); h.type = s.type.isEmpty ? o.type : s.type
                    out.append(h)
                }
            }
        }
        let blobFrames = Set(players.values.filter { $0.obs.blob || ($0.obs.current ?? $0.obs.attributeSource ?? "").lowercased().hasPrefix("blob:") }.map { $0.obs.frame.token })
        for r in resources.values.sorted(by: { $0.order < $1.order }) {
            let role = MediaClassifier.role(url: r.url, type: "")
            guard role == .hls || role == .dash || role == .video || role == .audio else { continue }
            // Pieces a player fetches by script into a MediaSource look like files; with an in-page stream in the same frame only playlists are believed.
            if (role == .video || role == .audio) && blobFrames.contains(r.frame.token) { continue }
            out.append(MediaPageHit(href: r.url, element: "link", type: "", duration: nil, drm: false, blob: false, frame: r.frame, player: nil, poster: nil, tracks: [], width: nil, height: nil,
                                    hasVideo: nil, method: role == .hls || role == .dash ? .manifestReference : .resourceTiming, playing: nil, title: nil))
        }
        return out
    }
}

/// What a signed address says about when it stops working, when it says so in a form that is widely used. Nothing else is guessed: an address that says nothing has no expiry here.
enum MediaExpiry {
    /// The moment an address stops working, from the parameters that carry it (an absolute time, or a start plus a lifetime), or nil.
    static func expiry(of url: URL, now: Date = Date()) -> Date? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, !items.isEmpty else { return nil }
        var q: [String: String] = [:]
        for i in items { if let v = i.value, q[i.name.lowercased()] == nil { q[i.name.lowercased()] = v } }
        // Absolute epoch seconds (or milliseconds): Expires, exp, expire, expires, e, expiry.
        // The short names (exp, e) are also ordinary ids, so they count only beside a signature-like parameter.
        let signed = ["sig", "signature", "token", "hmac", "policy", "key-pair-id", "hdnts", "st", "hash", "md5", "auth"].contains { q[$0] != nil }
        for name in ["expires", "expire", "expiry", "x-expires", "exp", "e"] {
            if (name == "exp" || name == "e") && !signed { continue }
            if let v = q[name], let n = Double(v), n > 0 {
                let seconds = n > 100_000_000_000 ? n / 1000 : n
                if seconds >= 1_000_000_000, seconds < 10_000_000_000 { return Date(timeIntervalSince1970: seconds) }
            }
        }
        // AWS-style and Google-style signed addresses: a start time (20240131T120000Z) and a lifetime in seconds.
        for (date, life) in [("x-amz-date", "x-amz-expires"), ("x-goog-date", "x-goog-expires")] {
            if let d = q[date], let l = q[life], let seconds = Double(l), seconds >= 0, let start = compactDate(d) { return start.addingTimeInterval(seconds) }
        }
        // Azure shared-access signatures: se=<ISO 8601>.
        if let se = q["se"], let d = isoDate(se) { return d }
        return nil
    }

    static func isExpired(_ url: URL, now: Date = Date()) -> Bool { expiry(of: url, now: now).map { $0 <= now } ?? false }

    private static func compactDate(_ s: String) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.date(from: s)
    }
    private static func isoDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

/// A quality said as people say it, only from what was observed or advertised.
enum MediaQualityLabel {
    static func label(width: Int?, height: Int?) -> String? {
        guard let h = height, h > 0 else { return nil }
        // Common names by height (a 1920×800 film is still "1080p" by its width class; the name follows the larger of the two classes).
        let w = width ?? 0
        let classes: [(Int, Int, String)] = [(7680, 4320, "4320p"), (3840, 2160, "2160p"), (2560, 1440, "1440p"), (1920, 1080, "1080p"), (1280, 720, "720p"), (854, 480, "480p"), (640, 360, "360p"), (426, 240, "240p")]
        for (cw, ch, name) in classes where h >= ch || w >= cw { return name }
        return "\(h)p"
    }
}
