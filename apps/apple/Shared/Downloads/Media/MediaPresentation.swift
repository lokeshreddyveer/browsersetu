import Foundation
import CryptoKit

// DX-08: the decisions around a streaming download that are not parsing, fetching or putting files together. Each is a small pure function so it can be tested alone:
// which quality and which languages to take, whether the finished file can hold them, whether a piece that arrived is the kind of piece it should be, in what order to fetch
// the pieces of several tracks, how long to wait before trying again, and whether a freshly read manifest still describes the same thing as the plan it would continue.

// MARK: - Choosing

enum MediaQualityPolicy: Equatable, Sendable {
    /// The best stream the finished file can hold.
    case auto
    /// The highest advertised bitrate that can be downloaded (a stream the MP4 cannot hold only if nothing else is).
    case highest
    case lowest
    /// Exactly this stream.
    case explicit(String)
    /// The best stream not taller than this.
    case atMost(height: Int)
    /// The best stream with this video codec ("h264", "hevc", "av1", "vp9", "dolby vision").
    case codec(String)
}

struct MediaSelectionRequest: Equatable, Sendable {
    var quality: MediaQualityPolicy = .auto
    /// The language wanted first, then further tracks wanted as well.
    var audioLanguages: [String] = []
    var subtitleLanguages: [String] = []
    var includeForcedSubtitles = false
    /// If the chosen stream cannot be had, a compatible one (same kind of stream and sound, equal or lower bitrate) may stand in.
    var allowQualityFallback = true
}

struct MediaSelectionResult: Equatable, Sendable {
    var choice: MediaChoice
    /// Said to the person: a stand-in used, a language that was not there.
    var notes: [String] = []
    /// The streams that may replace the chosen video if its playlist cannot be had, best first. Empty when fallback is not allowed.
    var fallbacks: [String] = []
}

extension MediaManifest {
    func select(_ request: MediaSelectionRequest) -> MediaSelectionResult {
        var notes: [String] = []
        let usable = videos.filter(\.isDownloadable)
        let holdable = usable.filter { MediaCodecs.outputWarning($0) == nil }
        let pool = holdable.isEmpty ? usable : holdable
        func byBandwidth(_ list: [MediaStream]) -> [MediaStream] { list.sorted { ($0.bandwidth ?? 0) > ($1.bandwidth ?? 0) } }

        var video: MediaStream?
        var isExplicit = false
        if case .explicit = request.quality { isExplicit = true }
        switch request.quality {
        case .auto: video = pool.first
        case .highest: video = byBandwidth(pool).first
        case .lowest: video = byBandwidth(pool).last
        case .explicit(let id):
            if let exact = videos.first(where: { $0.id == id }), exact.isDownloadable { video = exact }
            else if request.allowQualityFallback, let wanted = videos.first(where: { $0.id == id }) ?? nil {
                video = Self.standIn(for: wanted, in: pool)
                if let v = video { notes.append("The quality you chose cannot be downloaded; \(v.label) is used instead.") }
            } else if request.allowQualityFallback {
                video = pool.first
                if let v = video { notes.append("The quality you chose is no longer offered; \(v.label) is used instead.") }
            }
        case .atMost(let height):
            let fits = byBandwidth(pool.filter { ($0.height ?? Int.max) <= height && $0.height != nil })
            if let best = fits.first { video = best }
            else { video = byBandwidth(pool).last; if let v = video { notes.append("Nothing is \(height)p or smaller; the smallest, \(v.label), is used.") } }
        case .codec(let name):
            func plain(_ t: String) -> String { t.lowercased().filter { $0.isLetter || $0.isNumber } }
            let want = plain(name)
            let matching = byBandwidth(pool.filter { plain(MediaCodecs.describe($0.codecs).video ?? "").contains(want) && !want.isEmpty })
            if let m = matching.first { video = m } else { video = pool.first; if let v = video { notes.append("No \(name) video is offered; \(v.label) is used.") } }
        }

        if isExplicit, video == nil { notes.append("The quality you chose is not available.") }
        var audio: String?, extra: [String] = []
        if let video, video.kind != .muxed {
            let candidates = audios.filter(\.isDownloadable)
            let sameGroup = candidates.filter { $0.groupID != nil && $0.groupID == video.groupID }
            let ordered = sameGroup.isEmpty ? candidates : sameGroup
            // Commentary and descriptive audio are chosen only when the person asked for them by name; never as the stand-in for a language.
            let plain = ordered.filter { $0.role == nil || $0.role == "main" || $0.role == "alternate" }
            let pickFrom = plain.isEmpty ? ordered : plain
            var taken: [MediaStream] = []
            for (n, lang) in request.audioLanguages.enumerated() {
                if let match = pickFrom.first(where: { MediaLanguage.matches(lang, $0.language) && !taken.contains($0) }) ?? candidates.first(where: { MediaLanguage.matches(lang, $0.language) && !taken.contains($0) && ($0.role == nil || $0.role == "main") }) {
                    taken.append(match)
                } else if n == 0 { notes.append("There is no \(lang) audio; the default audio is used.") }
                else { notes.append("There is no \(lang) audio to add.") }
            }
            if taken.isEmpty { if let d = pickFrom.first(where: \.isDefault) ?? pickFrom.first ?? candidates.first(where: \.isDefault) ?? candidates.first { taken = [d] } }
            audio = taken.first?.id
            extra = taken.dropFirst().map(\.id)
        } else if video == nil, !isExplicit {
            let pool = audios.filter(\.isDownloadable)
            let first = request.audioLanguages.first.flatMap { l in pool.first { MediaLanguage.matches(l, $0.language) } }
            if let l = request.audioLanguages.first, first == nil, !pool.isEmpty { notes.append("There is no \(l) audio; the default audio is used.") }
            audio = (first ?? pool.first(where: \.isDefault) ?? pool.first)?.id
        }

        var subs: [String] = []
        for lang in request.subtitleLanguages {
            if let m = subtitles.first(where: { $0.isDownloadable && MediaLanguage.matches(lang, $0.language) && $0.forced != true && !subs.contains($0.id) }) { subs.append(m.id) }
            else { notes.append("There are no \(lang) subtitles.") }
        }
        if request.includeForcedSubtitles {
            // Forced subtitles (translations of foreign speech) go with the audio that was chosen: those in that audio's language, or all of them when its language is not known.
            let audioLanguage = audio.flatMap { id in audios.first { $0.id == id }?.language }
            for f in subtitles where f.isDownloadable && f.forced == true && !subs.contains(f.id) && (audioLanguage == nil || MediaLanguage.matches(audioLanguage ?? "", f.language)) { subs.append(f.id) }
        }

        var fallbacks: [String] = []
        if request.allowQualityFallback, let video {
            fallbacks = Self.standIns(for: video, in: usable).map(\.id)
        }
        return MediaSelectionResult(choice: MediaChoice(video: video?.id, audio: audio, subtitles: subs, extraAudios: extra), notes: notes, fallbacks: fallbacks)
    }

    /// Streams that can take the place of `stream` without changing what is being saved: the same kind of stream (picture with its own sound, or picture with the same separate audio group),
    /// not a higher bitrate than the one they replace, best first.
    static func standIns(for stream: MediaStream, in list: [MediaStream]) -> [MediaStream] {
        list.filter { c in
            c.id != stream.id && c.isDownloadable && c.kind == stream.kind && c.groupID == stream.groupID
                && (c.bandwidth ?? 0) <= (stream.bandwidth ?? Int.max)
                && (stream.container == .unknown || c.container == .unknown || c.container == stream.container)
        }.sorted { ($0.bandwidth ?? 0) > ($1.bandwidth ?? 0) }
    }
    static func standIn(for stream: MediaStream, in list: [MediaStream]) -> MediaStream? { standIns(for: stream, in: list).first }
}

// MARK: - What the finished file can hold

struct MediaOutputVerdict: Equatable, Sendable {
    var fileExtension: String
    /// Reasons it cannot be done at all.
    var blockers: [String] = []
    /// Reasons to tell the person, though it can be done.
    var warnings: [String] = []
    /// Files that will be written beside the main one.
    var sidecars: [String] = []
    var audioTrackCount = 0
}

enum MediaCompatibility {
    /// Decided before anything is downloaded, from what the manifest says.
    static func check(_ streams: [MediaStream]) -> MediaOutputVerdict {
        let media = streams.filter { !$0.container.isText && $0.kind != .subtitle }
        let text = streams.filter { $0.container.isText || $0.kind == .subtitle }
        var v = MediaOutputVerdict(fileExtension: "mp4")
        let containers = Set(media.map(\.container))
        if media.isEmpty { v.fileExtension = "vtt"; if text.count > 1 { v.blockers.append("Choose one subtitle track when downloading subtitles alone.") } }
        else if containers == [.fragmentedMP4] { v.fileExtension = media.allSatisfy({ $0.kind == .audio }) ? "m4a" : "mp4" }          // sound only: an M4A file
        else if containers == [.mpegTS] {
            v.fileExtension = "ts"
            if Set(media.compactMap { $0.trackKey ?? $0.id }).count > 1 { v.blockers.append("Separate video and audio in MPEG transport streams cannot be combined into one file.") }
        } else { v.blockers.append("These streams use formats that cannot be combined into one file.") }
        let trackKeys = Set(media.map { $0.trackKey ?? $0.id })
        for key in trackKeys {
            if let s = media.first(where: { ($0.trackKey ?? $0.id) == key }), let w = MediaCodecs.outputWarning(s), s.container == .fragmentedMP4 { v.warnings.append(w) }
        }
        v.audioTrackCount = Set(media.filter { $0.kind == .audio }.map { $0.trackKey ?? $0.id }).count + (media.contains { $0.kind == .muxed } ? 1 : 0)
        for s in text where media.isEmpty == false { v.sidecars.append("\(s.label) subtitles (.\(MediaSubtitleNaming.suffix(for: s)).vtt)") }
        return v
    }
}

// MARK: - Whether a piece is the right kind of piece

enum MediaSegmentCheck {
    private static let initBoxes: Set<String> = ["ftyp", "moov", "styp", "free", "skip"]
    private static let mediaBoxes: Set<String> = ["styp", "moof", "sidx", "emsg", "prft", "free", "skip", "ftyp", "moov", "mdat"]

    /// Looks at the first bytes of a piece that has arrived. nil when it looks right; otherwise why it is not.
    static func problem(head: Data, container: MediaContainer, isInit: Bool) -> String? {
        guard !head.isEmpty else { return "it is empty" }
        let lead = String(decoding: head.prefix(64), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let looksLikeMarkup = lead.hasPrefix("<!doctype") || lead.hasPrefix("<html") || lead.hasPrefix("<head") || lead.hasPrefix("<?xml") && container != .ttml
        switch container {
        case .fragmentedMP4:
            if looksLikeMarkup || lead.hasPrefix("{") { return "it is a web page or an error message, not media" }
            guard head.count >= 8 else { return "it is too short to be media" }
            let size = head.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            let type = String(decoding: head[head.startIndex + 4 ..< head.startIndex + 8], as: UTF8.self)
            guard size == 0 || size == 1 || size >= 8 else { return "it does not start with a valid MP4 box" }
            if !(isInit ? initBoxes : mediaBoxes).contains(type) { return "it does not start like \(isInit ? "an initialization segment" : "an MP4 media segment") (\(type.filter { $0.isLetter || $0.isNumber }.prefix(4)))" }
            return nil
        case .mpegTS:
            if looksLikeMarkup || lead.hasPrefix("{") { return "it is a web page or an error message, not media" }
            let b = [UInt8](head.prefix(377))
            guard b[0] == 0x47 else { return "it does not start with a transport stream sync byte" }
            if b.count > 188, b[188] != 0x47 { return "it is not made of 188-byte transport stream packets" }
            if b.count > 376, b[376] != 0x47 { return "it is not made of 188-byte transport stream packets" }
            return nil
        case .webVTT:
            let text = String(decoding: head.prefix(16), as: UTF8.self)
            return text.hasPrefix("WEBVTT") || text.hasPrefix("\u{FEFF}WEBVTT") ? nil : "it does not start with WEBVTT"
        case .ttml:
            let text = String(decoding: head.prefix(4096), as: UTF8.self)
            return text.contains("<tt") ? nil : "it is not a TTML document"
        case .unknown:
            return nil
        }
    }

    /// SHA-256 of a file, read in pieces so a large segment is never held in memory.
    static func digest(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func head(of file: URL, count: Int = 4096) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: count)) ?? Data()
    }
}

// MARK: - Fetching in a fair order

enum MediaScheduling {
    /// The order to fetch the pieces of several tracks in: every initialization segment first (nothing can be checked without them), then the tracks side by side, always taking the next
    /// piece of whichever track is furthest behind in proportion to its size. Video is not downloaded to the end before the first byte of audio.
    /// `sizes[k]` is the number of media segments of track k; `hasInit[k]` whether it has an initialization segment. The result names (track, index) with index -1 for the initialization segment.
    static func order(sizes: [Int], hasInit: [Bool]) -> [(stream: Int, index: Int)] {
        var out: [(stream: Int, index: Int)] = []
        out.reserveCapacity(sizes.reduce(0, +) + sizes.count)
        for (k, has) in hasInit.enumerated() where has { out.append((k, -1)) }
        var next = Array(repeating: 0, count: sizes.count)
        let total = sizes.reduce(0, +)
        for _ in 0..<total {
            var best: Int?
            var bestFraction = Double.infinity
            for k in sizes.indices where next[k] < sizes[k] {
                let f = Double(next[k]) / Double(sizes[k])
                if f < bestFraction { bestFraction = f; best = k }
            }
            guard let k = best else { break }
            out.append((k, next[k])); next[k] += 1
        }
        return out
    }
}

// MARK: - Trying again

enum MediaBackoff {
    /// How long to wait before the next try. A server's own Retry-After is followed exactly (up to two minutes); otherwise the wait doubles from a second to half a minute, spread by up to half
    /// so many pieces failing together do not all come back at the same instant.
    static func delay(attempt: Int, retryAfter: TimeInterval?, jitter: Double = Double.random(in: 0...1)) -> TimeInterval {
        if let retryAfter, retryAfter.isFinite { return min(max(0, retryAfter), 120) }
        let base = min(30, pow(2, Double(max(0, attempt))))
        return base * (0.5 + 0.5 * min(1, max(0, jitter)))
    }
}

/// Counts consecutive failures per host so a server that is down is given up on instead of being asked again and again by every piece.
final class MediaCircuit: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [String: Int] = [:]
    let limit: Int
    init(limit: Int = 12) { self.limit = limit }
    func record(host: String, success: Bool) {
        lock.lock(); defer { lock.unlock() }
        if success { failures[host] = nil } else { failures[host, default: 0] += 1 }
    }
    func isOpen(host: String) -> Bool { lock.lock(); defer { lock.unlock() }; return (failures[host] ?? 0) >= limit }
}

// MARK: - Parts

enum MediaParts {
    /// Cuts a fragmented-MP4 stream into the parts that must be saved as separate files: wherever the timeline restarts (a discontinuity or a new period) or the initialization segment
    /// changes. Joining them in one file would mix timelines and codec setups. Other containers are returned as they are.
    static func expand(_ stream: MediaStream) -> [MediaStream] {
        let inits = [stream.initSegment].compactMap { $0 } + (stream.extraInits ?? [])
        var runs: [Range<Int>] = []
        if stream.container == .fragmentedMP4, !stream.segments.isEmpty {
            var begin = 0
            for i in 1..<max(1, stream.segments.count) {
                let s = stream.segments[i], p = stream.segments[i - 1]
                if s.discontinuity || s.initIndex != p.initIndex { runs.append(begin..<i); begin = i }
            }
            runs.append(begin..<stream.segments.count)
        }
        guard !runs.isEmpty else { return [stream] }
        var parts: [MediaStream] = []
        var cursor = 0.0
        for (n, run) in runs.enumerated() {
            var part = stream
            if runs.count > 1 { part.id = "\(stream.id)#\(n)"; part.trackKey = stream.id; part.part = n }
            part.segments = Array(stream.segments[run])
            let at = part.segments[0].initIndex ?? 0
            part.initSegment = inits.indices.contains(at) ? inits[at] : stream.initSegment
            part.extraInits = nil
            for i in part.segments.indices { part.segments[i].initIndex = nil; if i == 0 { part.segments[i].discontinuity = false } }
            part.partStart = part.segments[0].startTicks.flatMap { t in part.segments[0].scale.map { Double(t) / Double($0) } } ?? cursor
            let length = part.segments.reduce(0) { $0 + $1.duration }
            cursor += length
            part.duration = length
            parts.append(part)
        }
        return parts
    }
}

// MARK: - When a link has expired

enum MediaRefresh {
    /// A stable signature of what a plan describes (which tracks, how many segments, how long each is), independent of the addresses and their tokens.
    static func signature(_ streams: [MediaStream]) -> String {
        var text = ""
        for s in streams {
            text += "\(s.trackKey ?? s.id)|\(s.part ?? 0)|\(s.kind.rawValue)|\(s.container.rawValue)|\(s.segments.count)|"
            for seg in s.segments.prefix(20_000) { text += "\(Int((seg.duration * 1000).rounded())),\(seg.length ?? -1);" }
            text += "\n"
        }
        return Data(text.utf8).sha256Hex
    }

    enum Verdict: Equatable { case compatible, different(String) }

    /// Whether `fresh` (read from the same manifest address after a link stopped working) describes the same presentation as `old`, so the addresses in it can be used to carry on.
    static func compare(old: [MediaStream], fresh: [MediaStream]) -> Verdict {
        guard old.count == fresh.count else { return .different("it now has a different number of tracks") }
        for (a, b) in zip(old, fresh) {
            guard (a.trackKey ?? a.id) == (b.trackKey ?? b.id), a.part == b.part, a.kind == b.kind, a.container == b.container else { return .different("its tracks changed") }
            guard a.bandwidth == b.bandwidth, a.width == b.width, a.height == b.height, a.codecs == b.codecs, a.language == b.language else { return .different("a track is a different quality or language") }
            guard a.segments.count == b.segments.count else { return .different("a track has a different number of segments") }
            guard (a.initSegment == nil) == (b.initSegment == nil), a.initSegment?.length == b.initSegment?.length else { return .different("an initialization segment appeared or went") }
            for (x, y) in zip(a.segments, b.segments) {
                guard abs(x.duration - y.duration) < 0.002, x.length == y.length else { return .different("segment lengths changed") }
            }
        }
        return .compatible
    }

    /// The old plan's streams with the new addresses, after `compare` said they match. Only hosts the plan already used, or the manifest's own, are accepted: a refreshed link never moves the
    /// download to a server it was not already talking to.
    static func adopt(old: [MediaStream], fresh: [MediaStream], allowedHosts: Set<String>) -> [MediaStream]? {
        var used = allowedHosts
        for s in old { for seg in s.segments { if let h = URL(string: seg.url)?.host { used.insert(h.lowercased()) } }; if let h = s.initSegment.flatMap({ URL(string: $0.url)?.host }) { used.insert(h.lowercased()) } }
        var out = old
        for k in old.indices {
            for i in old[k].segments.indices {
                let n = fresh[k].segments[i]
                guard let host = URL(string: n.url)?.host?.lowercased(), used.contains(host) else { return nil }
                out[k].segments[i].url = n.url; out[k].segments[i].offset = n.offset; out[k].segments[i].length = n.length
            }
            if let ini = fresh[k].initSegment {
                guard let host = URL(string: ini.url)?.host?.lowercased(), used.contains(host) else { return nil }
                out[k].initSegment = ini
            }
        }
        return out
    }
}
