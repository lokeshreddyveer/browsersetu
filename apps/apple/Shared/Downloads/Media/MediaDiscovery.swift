import Foundation

// Phase 18: finding media on the page that is open, when the person asks. Finding is not downloading, and seeing an address is not proof that it can be downloaded: a candidate says
// how sure we are (seen, recognised, inspected) and what is known to be unsupported. Nothing here opens a connection except an inspection the person starts for one candidate.

/// What the page script reports for one element. Addresses and mime types only: no page text, no form values, no cookies.
struct MediaPageHit: Equatable, Sendable {
    var href: String?
    var element: String          // video, audio, source, link
    var type: String
    var duration: Double?
    /// The element has encrypted-media keys attached (the page plays protected content).
    var drm: Bool
    /// The element plays from a blob: address (MediaSource or an in-memory file).
    var blob: Bool
    // DX-07 (all optional, so the Phase 18 page read still builds a hit with the five fields above):
    /// The frame it was found in, as WebKit described it.
    var frame: MediaFrameRef? = nil
    var player: MediaPlayerRef? = nil
    var poster: String? = nil
    var tracks: [MediaTrackRef] = []
    var width: Int? = nil
    var height: Int? = nil
    /// Whether the element has a video picture, when its metadata has loaded (nil: not known yet).
    var hasVideo: Bool? = nil
    var method: MediaDiscoveryMethod = .pageScan
    var playing: Bool? = nil
    var title: String? = nil
}

struct MediaPageSnapshot: Equatable, Sendable {
    var hits: [MediaPageHit]
    var truncated: Bool
    /// The page could not be read (the script failed or the page's process went away); not the same as a page with no media.
    var failed = false
}

enum MediaMechanism: String, Sendable { case videoElement, audioElement, sourceElement, pageLink
    var label: String {
        switch self { case .videoElement: "Video element"; case .audioElement: "Audio element"; case .sourceElement: "Source element"; case .pageLink: "Link on the page" }
    }
}

enum MediaCandidateKind: Equatable, Sendable {
    case directVideo, directAudio, hls, dash, blob, protected, unknown
    var label: String {
        switch self {
        case .directVideo: "Video file"; case .directAudio: "Audio file"; case .hls: "HLS stream"; case .dash: "DASH stream"
        case .blob: "In-page stream"; case .protected: "Protected"; case .unknown: "Media"
        }
    }
    var isStream: Bool { self == .hls || self == .dash }
}

/// How far we know something. "Download supported" is only ever claimed for what has been recognised as a kind this app downloads, and for a stream only after it was inspected.
enum MediaCandidateState: Equatable, Sendable {
    case discovered
    case recognized
    case inspecting
    case inspected
    case authorizationRequired(String)
    case unsupported(String)
    case failed(String)
    case stale
    /// The address says it has stopped working (or the site refused it as expired). The page can be read again for a fresh one.
    case expired

    var label: String {
        switch self {
        case .discovered: "Seen"
        case .recognized: "Recognised"
        case .inspecting: "Looking…"
        case .inspected: "Choices available"
        case .authorizationRequired: "Sign-in needed"
        case .unsupported: "Not supported"
        case .failed: "Could not be read"
        case .stale: "Out of date"
        case .expired: "Expired"
        }
    }
    var detail: String? {
        switch self {
        case .authorizationRequired(let t), .unsupported(let t), .failed(let t): t
        case .stale: "The page has changed since this was found. Find media again."
        case .expired: "This address has expired. Find media again while the page is open to get a fresh one."
        default: nil
        }
    }
}

struct MediaCandidate: Identifiable, Equatable, Sendable {
    /// One per media address, however many elements on the page point at it. Qualities of one stream are its representations, never separate candidates.
    let id: String
    let profile: String
    let isPrivate: Bool
    let pageKey: String
    /// The site of the page it was found on (never the full address).
    let pageHost: String?
    var mechanism: MediaMechanism
    var kind: MediaCandidateKind
    /// The address as found. It may carry a signed query, so it is used to inspect or download and is never displayed, logged or exported.
    var url: String?
    var display: String
    var name: String
    var mime: String
    var duration: Double?
    var state: MediaCandidateState
    var manifest: MediaManifest?
    let firstSeen: Date
    var lastObserved: Date
    // DX-07 provenance and detail. Every one is only what was observed; unknown stays nil.
    /// The players that use this source (a source two players share is one item with two players).
    var players: [MediaPlayerRef] = []
    var method: MediaDiscoveryMethod = .pageScan
    var poster: String? = nil
    var tracks: [MediaTrackRef] = []
    var videoWidth: Int? = nil
    var videoHeight: Int? = nil
    /// Whether the element has a picture (nil: not known). False with a video element means an audio-only file.
    var hasVideo: Bool? = nil
    var playing: Bool? = nil
    var expiresAt: Date? = nil
    /// The address a refreshed candidate now has; nil until it is refreshed. The identity (`id`) stays, so a selection survives a refresh.
    var currentKey: String? = nil
    var navigation: Int = 0

    var host: String? { url.flatMap(URL.init(string:))?.host }
    /// What identifies the source now (the address it has today).
    var key: String { currentKey ?? id }
    var tabID: String { pageKey.split(separator: "|", maxSplits: 1).first.map(String.init) ?? "" }
    var confidence: MediaConfidence { MediaConfidence(method: method) }
    /// The frames the players live in (the origins WebKit reported, never the page's own claim).
    var frameOrigins: [String] { var seen = Set<String>(); return players.map(\.frame.origin).filter { seen.insert($0).inserted } }
    var isEmbedded: Bool { !players.isEmpty && players.allSatisfy { !$0.frame.isMain } }
    /// "1080p" for what is playing, when the picture size is known.
    var qualityLabel: String? { hasVideo == false ? "Audio only" : MediaQualityLabel.label(width: videoWidth, height: videoHeight) }
    func isExpired(now: Date = Date()) -> Bool { if case .expired = state { return true }; return expiresAt.map { $0 <= now } ?? false }
    /// The person may start it (or, for a stream, look at its choices) right now.
    var canOpen: Bool {
        guard kind != .blob, kind != .protected else { return false }
        if isExpired() { return false }
        switch state { case .recognized, .inspected, .discovered: return url != nil; default: return false }
    }
    /// Whether a download of this is known to be possible: a stream must have been inspected and hold something downloadable.
    var downloadSupported: Bool {
        switch kind {
        case .directVideo, .directAudio: return state == .recognized
        case .hls, .dash: return state == .inspected && (manifest?.hasDownloadableStream ?? false)
        default: return false
        }
    }
}

/// What a resource is, from the strongest evidence available: its declared type when that is specific, else its extension (weak evidence), else unknown.
enum MediaRole: Equatable, Sendable { case video, audio, hls, dash, subtitle, poster, segment, unrelated, unknown }

enum MediaClassifier {
    static let subtitleExtensions: Set<String> = ["vtt", "srt", "ttml", "dfxp", "ass", "ssa", "sbv"]
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "avif", "bmp", "svg"]
    static let segmentExtensions: Set<String> = ["ts", "m4s", "cmfv", "cmfa", "cmft", "mts"]
    private static let vagueTypes: Set<String> = ["", "application/octet-stream", "binary/octet-stream", "text/plain", "text/html", "application/x-unknown", "application/unknown"]

    /// The role of an address with an optional declared type. A specific type wins over the extension; a vague or wrong-looking one (text/html for a .mp4) falls back to the extension.
    static func role(url: String, type rawType: String) -> MediaRole {
        let type = rawType.lowercased().split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let path = URL(string: url).map { $0.path } ?? url
        let ext = (path as NSString).pathExtension.lowercased()
        switch type {
        case "application/vnd.apple.mpegurl", "application/x-mpegurl", "audio/mpegurl", "audio/x-mpegurl": return .hls
        case "application/dash+xml": return .dash
        case "text/vtt", "application/x-subrip", "application/ttml+xml", "text/srt": return .subtitle
        default: break
        }
        if ext == "m3u8" { return .hls }          // a playlist is a playlist whatever type a server gave it
        if ext == "mpd" { return .dash }
        if segmentExtensions.contains(ext) { return .segment }          // a piece of a stream whatever its type says (fMP4 pieces are video/mp4 or audio/mp4)
        if type == "video/mp2t" { return .segment }
        if type.hasPrefix("image/") { return .poster }
        if type.hasPrefix("video/") { return .video }
        if type.hasPrefix("audio/") { return .audio }
        if vagueTypes.contains(type) || type.hasPrefix("text/") || type.hasPrefix("application/") {
            if ext == "m3u8" { return .hls }
            if ext == "mpd" { return .dash }
            if subtitleExtensions.contains(ext) { return .subtitle }
            if imageExtensions.contains(ext) { return .poster }
            if segmentExtensions.contains(ext) { return .segment }
            if videoExtensions.contains(ext) { return .video }
            if audioExtensions.contains(ext) { return .audio }
            if ["js", "css", "json", "html", "htm", "woff", "woff2", "xml", "txt", "map", "wasm"].contains(ext) { return .unrelated }
        }
        return .unknown
    }

    static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "webm", "mkv", "avi", "ogv", "mpg", "mpeg", "3gp", "flv", "wmv"]
    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "ogg", "oga", "opus", "wav", "flac", "weba"]

    struct Result: Equatable { var kind: MediaCandidateKind; var state: MediaCandidateState }

    /// Decides what a found address is from its text, its element and its declared type. Reads nothing from the network.
    static func classify(_ hit: MediaPageHit) -> Result {
        if hit.drm { return Result(kind: .protected, state: .unsupported("This page plays protected (DRM) media. It is never downloaded or bypassed.")) }
        if hit.blob || hit.href?.lowercased().hasPrefix("blob:") == true {
            return Result(kind: .blob, state: .unsupported("This page plays media from memory (a blob: or MediaSource stream). That is not DRM: the page reports no encryption. It is simply not a file at an address. If the player loaded a stream playlist, that playlist is listed separately and can be downloaded; media the page builds only in memory has no address to fetch."))
        }
        guard let href = hit.href, let url = URL(string: href), let scheme = url.scheme?.lowercased() else {
            return Result(kind: .unknown, state: .unsupported("The address could not be read."))
        }
        guard scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else {
            return Result(kind: .unknown, state: .unsupported("Only web addresses (http and https) are downloaded."))
        }
        if !HTTPRequestPolicy.pageMayReach(host: host) {
            return Result(kind: .unknown, state: .unsupported("This address is on your own network. Use Add Download for an address you mean to reach."))
        }
        // Declared type first, extension as weaker evidence (role). What the element is and what it showed (a picture or none) settle the ambiguous case of a container that holds either.
        switch role(url: href, type: hit.type) {
        case .hls: return Result(kind: .hls, state: .recognized)
        case .dash: return Result(kind: .dash, state: .recognized)
        case .video:
            // An audio element, or a video element whose loaded metadata showed no picture, is playing sound: the same .mp4 is audio there.
            if hit.element == "audio" || hit.hasVideo == false { return Result(kind: .directAudio, state: .recognized) }
            return Result(kind: .directVideo, state: .recognized)
        case .audio: return Result(kind: .directAudio, state: .recognized)
        case .subtitle: return Result(kind: .unknown, state: .unsupported("A subtitle file belongs to a video; it is offered with that video, not on its own."))
        case .poster: return Result(kind: .unknown, state: .unsupported("This is a picture (a poster or thumbnail), not media."))
        case .segment: return Result(kind: .unknown, state: .unsupported("This is one piece of a stream. Choose the stream's playlist instead."))
        case .unrelated: return Result(kind: .unknown, state: .unsupported("This is not media."))
        case .unknown: break
        }
        // An element playing something with no telling extension or type: it is media (the page says so) but its kind is not known until it is fetched, which is not done here.
        if hit.element == "video" || hit.element == "audio" { return Result(kind: hit.element == "audio" || hit.hasVideo == false ? .directAudio : .directVideo, state: .discovered) }
        return Result(kind: .unknown, state: .unsupported("This is not a kind of media this app recognises."))
    }
}

@MainActor
final class MediaDiscoveryStore: ObservableObject {
    static let maxCandidates = 200
    static let maxConcurrentInspections = 2
    static let maxPlayersPerCandidate = 50

    let profile: String
    /// A private session's candidates live in memory only, are never inspected or downloaded here, and are dropped when the session ends.
    let isPrivate: Bool
    @Published private(set) var candidates: [MediaCandidate] = []
    @Published private(set) var pageKey: String?
    @Published private(set) var notice: String?
    @Published private(set) var searching = false
    /// Embedded frames of the open page that could not be looked into (a sandboxed frame that may not run scripts, say). Said plainly instead of guessed at.
    @Published var unobservedFrames = 0
    /// The navigation count of the tab's observation buffer when this list was last filled from it (a single-page route change leaves it unchanged, a new document changes it).
    var observedNavigation: Int?
    private var inspections: [String: Task<Void, Never>] = [:]
    private var generation = 0

    init(profile: String, isPrivate: Bool) { self.profile = profile; self.isPrivate = isPrivate }

    struct Report: Equatable { var added = 0, duplicates = 0, unsupported = 0, truncated = false, refreshed = 0 }

    func beginSearch() { searching = true; notice = nil }
    func endSearch() { searching = false }

    /// Takes what the page script found. A different page replaces the earlier page's candidates; the same page adds new ones and refreshes the rest. `removeMissing: false` is for a live
    /// observation, which only adds and updates (what is gone is removed by `removePlayers`, because an observation does not list everything).
    @discardableResult
    func ingest(_ snapshot: MediaPageSnapshot, pageKey: String, pageHost: String?, now: Date = Date(), removeMissing: Bool = true) -> Report {
        var report = Report()
        if snapshot.failed { notice = "This page could not be read. Try again."; return report }
        let samePage = self.pageKey == pageKey
        if !samePage { cancelInspections(); candidates = []; generation += 1 }
        self.pageKey = pageKey
        var seen = Set<String>()
        var anonymousCount: [String: Int] = [:]
        var index = Dictionary(candidates.enumerated().map { ($1.key, $0) }, uniquingKeysWith: { first, _ in first })
        for hit in snapshot.hits {
            let result = MediaClassifier.classify(hit)
            let url = hit.href.flatMap(URL.init(string:))
            let anonymous = hit.blob || result.kind == .blob || (result.kind == .protected && url == nil)
            // An in-page stream has no address. Seen by an observer, it is named by its player (frame and element); seen by the page read, by its kind and its place among the others.
            let ordinal = anonymousCount[hit.element, default: 0]
            if anonymous { anonymousCount[hit.element] = ordinal + 1 }
            let id = anonymous ? (hit.player.map { "inpage:\($0.key)" } ?? "inpage:\(hit.element):\(ordinal)") : (url.map(LinkClassifier.normalizedKey) ?? "unreadable:\(hit.element):\(index.count)")
            seen.insert(id)
            if let at = index[id] {
                merge(hit, result: result, into: at, now: now)
                if let ref = hit.player { detach(ref, except: at); index = Dictionary(candidates.enumerated().map { ($1.key, $0) }, uniquingKeysWith: { first, _ in first }) }
                report.duplicates += 1
                continue
            }
            // The same player now plays a different address (a refreshed signed address, or the next episode): when the old one had stopped working and this is plainly the same item,
            // the candidate is kept and given the new address; otherwise it is a different item and the old one stays as it was.
            if let ref = hit.player, !anonymous, index[id] == nil, let at = candidates.firstIndex(where: { $0.players == [ref] && ($0.isExpired(now: now) || $0.state == .stale) && $0.kind == result.kind && Self.sameItem($0.duration, hit.duration) }) {
                let oldKey = candidates[at].key
                candidates[at].currentKey = id
                candidates[at].url = hit.href
                candidates[at].display = hit.href.flatMap { DiagnosticRedactor.url($0) } ?? "In-page media"
                candidates[at].state = result.state
                candidates[at].manifest = nil
                candidates[at].expiresAt = url.flatMap { MediaExpiry.expiry(of: $0) }
                index[oldKey] = nil; index[id] = at
                seen.insert(candidates[at].id)
                merge(hit, result: result, into: at, now: now)
                report.refreshed += 1
                continue
            }
            guard candidates.count < Self.maxCandidates else { report.truncated = true; break }
            let mechanism: MediaMechanism = hit.element == "video" ? .videoElement : hit.element == "audio" ? .audioElement : hit.element == "source" ? .sourceElement : .pageLink
            let name = hit.title ?? url.map { u -> String in
                let last = u.lastPathComponent.removingPercentEncoding ?? u.lastPathComponent
                let shown = DiagnosticRedactor.text(last, limit: 100) == last && !last.isEmpty && last != "/" ? last : (u.host ?? "Media")
                return shown
            } ?? hit.element.capitalized
            var candidate = MediaCandidate(id: id, profile: profile, isPrivate: isPrivate, pageKey: pageKey, pageHost: pageHost, mechanism: mechanism, kind: result.kind,
                                           url: anonymous ? nil : hit.href,
                                           display: hit.href.flatMap { DiagnosticRedactor.url($0) } ?? "In-page media", name: name, mime: hit.type, duration: hit.duration,
                                           state: result.state, manifest: nil, firstSeen: now, lastObserved: now)
            candidate.navigation = generation
            candidate.method = hit.method
            candidate.expiresAt = url.flatMap { MediaExpiry.expiry(of: $0) }
            if let e = candidate.expiresAt, e <= now, case .unsupported = result.state {} else if let e = candidate.expiresAt, e <= now { candidate.state = .expired }
            candidates.append(candidate)
            index[id] = candidates.count - 1
            merge(hit, result: result, into: candidates.count - 1, now: now, isNew: true)
            if let ref = hit.player { detach(ref, except: candidates.count - 1); index = Dictionary(candidates.enumerated().map { ($1.key, $0) }, uniquingKeysWith: { first, _ in first }) }
            report.added += 1
            if case .unsupported = result.state { report.unsupported += 1 }
        }
        // On a second look at the same page, what is no longer there goes (and so does any look at it that was running).
        if samePage, removeMissing {
            let gone = Set(candidates.map(\.id)).subtracting(seen)
            if !gone.isEmpty { for id in gone { inspections[id]?.cancel(); inspections[id] = nil }; candidates.removeAll { gone.contains($0.id) } }
        }
        markExpired(now: now)
        report.truncated = report.truncated || snapshot.truncated
        notice = candidates.isEmpty ? "No downloadable media was found on this page." : (report.truncated ? "The page has more media than the limit (\(Self.maxCandidates))." : nil)
        return report
    }

    /// Two readings of one player are the same item unless their lengths are both known and differ.
    static func sameItem(_ a: Double?, _ b: Double?) -> Bool { guard let a, let b else { return true }; return abs(a - b) <= 1.0 }

    /// A player now shows this item, so it no longer shows what it showed before (a pre-roll that gave way to the main video). The earlier item goes when no other player or link still shows it
    /// and it was only ever seen playing.
    private func detach(_ ref: MediaPlayerRef, except keep: Int) {
        var drop = Set<String>()
        for i in candidates.indices where i != keep && candidates[i].players.contains(ref) {
            candidates[i].players.removeAll { $0 == ref }
            if candidates[i].players.isEmpty && candidates[i].method.strength >= MediaDiscoveryMethod.mediaEvent.strength { drop.insert(candidates[i].id) }
        }
        if !drop.isEmpty { remove(drop) }
    }

    /// Folds one more observation of a source into its candidate: what is newly known is added, what is known is never replaced by something less certain.
    private func merge(_ hit: MediaPageHit, result: MediaClassifier.Result, into at: Int, now: Date, isNew: Bool = false) {
        candidates[at].lastObserved = now
        if candidates[at].duration == nil { candidates[at].duration = hit.duration }
        // A stream being unsupported or protected in one place must stay so.
        if hit.drm, candidates[at].kind != .protected { candidates[at].kind = .protected; candidates[at].state = result.state }
        if let ref = hit.player, !candidates[at].players.contains(ref), candidates[at].players.count < Self.maxPlayersPerCandidate { candidates[at].players.append(ref) }
        if hit.method.strength > candidates[at].method.strength { candidates[at].method = hit.method }
        if candidates[at].poster == nil { candidates[at].poster = hit.poster }
        for t in hit.tracks where candidates[at].tracks.count < MediaObservationParser.maxTracks && !candidates[at].tracks.contains(t) { candidates[at].tracks.append(t) }
        if let w = hit.width, let h = hit.height, w > 0, h > 0 { candidates[at].videoWidth = w; candidates[at].videoHeight = h }
        if let v = hit.hasVideo { candidates[at].hasVideo = v }
        if let p = hit.playing { candidates[at].playing = p }
        if let t = hit.title, candidates[at].name == (candidates[at].url.flatMap(URL.init(string:))?.lastPathComponent ?? candidates[at].name) { candidates[at].name = t }
        // What the player showed can change the kind of a container that holds either (a loaded element with no picture is sound).
        if candidates[at].hasVideo == false, candidates[at].kind == .directVideo { candidates[at].kind = .directAudio }
        if candidates[at].state == .stale || candidates[at].state == .expired, candidates[at].isExpired(now: now) == false, !isNew { candidates[at].state = result.state }
    }

    /// Candidates whose address has said it stops working by now are marked, so nothing is started with them.
    func markExpired(now: Date = Date()) {
        for i in candidates.indices where candidates[i].state != .inspecting {
            if let e = candidates[i].expiresAt, e <= now {
                switch candidates[i].state { case .recognized, .discovered, .inspected, .failed: candidates[i].state = .expired; default: break }
            }
        }
    }

    /// The players of a frame (or all of them) went away: a candidate only they used goes with them; one that other players or links still show stays.
    func removePlayers(inFrame token: String? = nil, player: Int? = nil) {
        var drop = Set<String>()
        for i in candidates.indices where !candidates[i].players.isEmpty {
            let remaining = candidates[i].players.filter { ref in !((token == nil || ref.frame.token == token) && (player == nil || ref.player == player)) }
            if remaining.count != candidates[i].players.count {
                candidates[i].players = remaining
                if remaining.isEmpty && candidates[i].method.strength >= MediaDiscoveryMethod.mediaEvent.strength { drop.insert(candidates[i].id) }
            }
        }
        if !drop.isEmpty { remove(drop) }
    }

    /// The candidates, strongest evidence first, then in the order found. The list in the sheet is shown in this order.
    var ranked: [MediaCandidate] {
        let hidden = foldedVariantKeys
        return candidates.enumerated().filter { item in
            guard !hidden.isEmpty, item.element.kind.isStream, let u = item.element.url.flatMap(URL.init(string:)) else { return true }
            return !hidden.contains(LinkClassifier.normalizedKey(u))
        }.sorted { a, b in
            if a.element.confidence != b.element.confidence { return a.element.confidence > b.element.confidence }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// The addresses of the quality and audio playlists that a master playlist already read here names. A page's player fetches those itself, so without this each shows up as a separate
    /// "stream" next to the master. A row is folded away only on this proof (the master was read and lists exactly that address); a playlist found on its own, with no master read, stays.
    var foldedVariantKeys: Set<String> {
        var keys = Set<String>()
        for c in candidates where c.state == .inspected {
            guard let m = c.manifest, c.kind.isStream else { continue }
            let own = c.url.flatMap(URL.init(string:)).map(LinkClassifier.normalizedKey)
            for s in m.videos + m.audios + m.subtitles {
                guard let p = s.playlistURL, let u = URL(string: p) else { continue }
                let k = LinkClassifier.normalizedKey(u)
                if k != own { keys.insert(k) }
            }
        }
        return keys
    }

    /// The page the person is looking at is not the one these were found on.
    func markStale(currentPageKey: String?) {
        guard let currentPageKey, pageKey != nil, currentPageKey != pageKey else { return }
        cancelInspections()
        for i in candidates.indices { candidates[i].state = .stale }
    }

    func remove(_ ids: Set<String>) {
        for id in ids { inspections[id]?.cancel(); inspections[id] = nil }
        candidates.removeAll { ids.contains($0.id) }
    }

    func clear() { cancelInspections(); candidates = []; pageKey = nil; notice = nil; searching = false; generation += 1 }

    func cancelInspections() {
        for (id, task) in inspections { task.cancel(); if let i = candidates.firstIndex(where: { $0.id == id }), candidates[i].state == .inspecting { candidates[i].state = candidates[i].manifest == nil ? .recognized : .inspected } }
        inspections = [:]
    }

    // MARK: Inspecting one candidate (the person asked)

    typealias Inspect = (URL) async throws -> MediaManifest

    /// Reads the playlist of one stream so its choices can be shown. Only the playlist is fetched, never a segment. A result that arrives after the page changed or the
    /// candidate was removed is dropped. A private session's candidates are never fetched from here.
    func inspect(_ id: String, using inspect: @escaping Inspect) {
        guard let i = candidates.firstIndex(where: { $0.id == id }) else { return }
        let c = candidates[i]
        guard c.kind.isStream, c.state != .stale, let text = c.url, let url = URL(string: text) else { return }
        switch c.state { case .recognized, .failed, .discovered: break; default: return }          // looked at again only after a failure, on request
        guard !isPrivate else { candidates[i].state = .unsupported("Media from a private tab is not downloaded: downloads are kept in the ordinary list, and a private tab leaves nothing there."); return }
        guard inspections.count < Self.maxConcurrentInspections else { notice = "Wait for the current look to finish."; return }
        candidates[i].state = .inspecting
        let gen = generation
        inspections[id] = Task { [weak self] in
            // However this ends, the slot is given back; an answer that is dropped puts the candidate back to what it was.
            defer { Task { @MainActor [weak self] in
                guard let self else { return }
                self.inspections[id] = nil
                if let j = self.candidates.firstIndex(where: { $0.id == id }), self.candidates[j].state == .inspecting { self.candidates[j].state = self.candidates[j].manifest == nil ? .recognized : .inspected }
            } }
            do {
                let manifest = try await inspect(url)
                guard !Task.isCancelled, let self, self.generation == gen, let j = self.candidates.firstIndex(where: { $0.id == id }), self.candidates[j].state == .inspecting else { return }
                self.candidates[j].manifest = manifest
                self.candidates[j].duration = manifest.duration ?? self.candidates[j].duration
                if let why = manifest.unsupported { self.candidates[j].state = .unsupported(why) }
                else if !manifest.hasDownloadableStream { self.candidates[j].state = .unsupported("None of the streams in this playlist can be downloaded.") }
                else { self.candidates[j].state = .inspected }
            } catch {
                guard !Task.isCancelled, let self, self.generation == gen, let j = self.candidates.firstIndex(where: { $0.id == id }) else { return }
                self.candidates[j].state = Self.state(for: error)
            }
        }
    }

    /// A failure said as what it is, never one "unavailable".
    static func state(for error: Error) -> MediaCandidateState {
        if let e = error as? HTTPDownloadError {
            switch e.info.code {
            case "http:401": return .authorizationRequired("The site asks for a sign-in. Browser Setu does not hand your browser's session to a separate download, so this cannot be read from here.")
            case "http:403": return e.maybeExpired ? .expired : .failed("The site would not let this playlist be read.")
            case "http:404", "http:410": return .failed("The playlist is no longer there. The page may have changed: find the media again.")
            default: return .failed(e.info.reason)
            }
        }
        if let m = error as? MediaError {
            switch m {
            case .unsupported(let why): return .unsupported(why)
            case .notAManifest: return .unsupported("The address does not hold a stream playlist.")
            default: return .failed(m.errorDescription ?? "The playlist could not be read.")
            }
        }
        if let r = error as? HTTPRequestPolicy.Refusal { return .unsupported(r.reason) }
        return .failed((error as? LocalizedError)?.errorDescription ?? HTTPResponseRules.failure(for: error).info.reason)
    }

    // MARK: Where choosing one leads

    /// One policy: a direct file is the ordinary download, a stream goes to its choices, everything else is refused with the reason. Never starts anything by itself.
    func route(_ id: String) -> LinkRoute {
        guard let c = candidates.first(where: { $0.id == id }) else { return .refused("That media is no longer in the list.") }
        if isPrivate { return .refused("Media from a private tab is not downloaded: downloads are kept in the ordinary list, and a private tab leaves nothing there.") }
        if c.state == .stale { return .refused(MediaCandidateState.stale.detail ?? "Out of date.") }
        if c.isExpired() { return .refused(MediaCandidateState.expired.detail ?? "Expired.") }
        if case .unsupported(let why) = c.state { return .refused(why) }
        guard let text = c.url, let url = URL(string: text), DownloadSchedule.canSchedule(url) else { return .refused("That address cannot be downloaded.") }
        switch c.kind {
        case .directVideo, .directAudio: return .download(url)
        case .hls, .dash: return .mediaPreview(url)
        default: return .refused("This is not a kind of media this app downloads.")
        }
    }
}
