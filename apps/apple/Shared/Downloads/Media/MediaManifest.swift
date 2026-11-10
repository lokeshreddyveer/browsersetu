import Foundation

// Phase 17: what a streaming manifest says. These types and parsers read text and produce a description; they never fetch anything, never write anything, and say plainly what they
// cannot handle (live streams, encrypted or protected media, formats they do not know) instead of guessing.

extension DownloadProtocolID {
    /// A segmented streaming download (HLS or MPEG-DASH): a manifest, a set of chosen streams, and the segments they list.
    static let media: Self = "media"
}

enum MediaLimits {
    static let maxManifestBytes = 2_000_000
    static let maxLines = 200_000
    static let maxSegmentsPerStream = 20_000
    static let maxStreams = 200
    static let maxAttributeLength = 8192
    static let maxURLLength = 8192
    static let maxXMLDepth = 24
    static let maxXMLElements = 100_000
    static let maxTimelineEntries = 20_000
}

enum MediaFormat: String, Codable, Sendable { case hls, dash }
enum MediaContainer: String, Codable, Sendable {
    case fragmentedMP4, mpegTS, webVTT, unknown
    /// DX-08: a TTML / IMSC text file (a DASH text track). It is turned into WebVTT when the sidecar is written.
    case ttml
    var fileExtension: String { switch self { case .fragmentedMP4: "mp4"; case .mpegTS: "ts"; case .webVTT: "vtt"; case .ttml: "ttml"; case .unknown: "bin" } }
    var isText: Bool { self == .webVTT || self == .ttml }
}

struct MediaSegment: Codable, Equatable, Sendable {
    var url: String
    /// Both set, or neither: the part of the resource this segment is.
    var offset: Int64?
    var length: Int64?
    var duration: Double
    var discontinuity = false
    // DX-08. All optional, so a plan saved before they existed still reads.
    /// Which initialization segment this one needs, counting the stream's own `initSegment` as 0 and `extraInits` after it. nil means the stream's own.
    var initIndex: Int?
    /// Exact timing: `ticks` long, starting `startTicks` after the start of the presentation, both in 1/`scale` seconds.
    var ticks: Int64?
    var scale: Int64?
    var startTicks: Int64?
    /// HLS media sequence number / DASH segment number.
    var sequence: Int64?
    var discontinuitySequence: Int?
    var programDate: String?
}

struct MediaStream: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case video, audio, subtitle, muxed }
    var id: String
    var kind: Kind
    var label: String
    var language: String?
    var codecs: String?
    var bandwidth: Int?
    var width: Int?
    var height: Int?
    var container: MediaContainer = .unknown
    /// HLS: the playlist to read when this stream is chosen (a master playlist lists streams without their segments). nil when `segments` is already filled in.
    var playlistURL: String?
    var initSegment: MediaSegment?
    var segments: [MediaSegment] = []
    var duration: Double?
    /// Frames per second the manifest advertises (the maximum, for HLS), when it says.
    var frameRate: Double?
    /// HLS audio group a video stream expects, and the group an audio stream belongs to.
    var groupID: String?
    var isDefault = false
    /// Why this stream cannot be downloaded, if it cannot.
    var unsupported: String?
    // DX-08. All optional, so a plan saved before they existed still reads.
    var channels: Int?
    /// DASH Role / HLS characteristic: "main", "alternate", "commentary", "description", "forced-subtitle", ...
    var role: String?
    var forced: Bool?
    var autoSelect: Bool?
    var accessibility: Bool?
    var characteristics: String?
    /// "SDR", "HDR10", "HLG" when the manifest says so.
    var hdr: String?
    var averageBandwidth: Int?
    /// Initialization segments after the first (a stream whose parts need different ones).
    var extraInits: [MediaSegment]?
    /// Parts of one track, in order, share a `trackKey` and have a `part` number; set when a stream is cut at a discontinuity or period boundary.
    var trackKey: String?
    var part: Int?
    /// Where the part starts on the presentation timeline, in seconds, as the manifest declares it.
    var partStart: Double?
    /// Things to tell the person that are not reasons to refuse the stream.
    var notes: [String]?
    /// For a DASH representation with several BaseURLs: the address in use, and the others that serve the same files.
    var mirrors: [String: [String]]?

    var resolutionText: String? { width.flatMap { w in height.map { "\(w)×\($0)" } } }
    var frameRateText: String? { frameRate.map { $0 == $0.rounded() ? "\(Int($0)) fps" : String(format: "%.2f fps", $0) } }
    var bitrateText: String? { bandwidth.map { $0 >= 1_000_000 ? String(format: "%.1f Mbit/s", Double($0) / 1_000_000) : "\($0 / 1000) kbit/s" } }
    var isDownloadable: Bool { unsupported == nil }
}

struct MediaManifest: Codable, Equatable, Sendable {
    var format: MediaFormat
    var sourceURL: String
    var duration: Double?
    var videos: [MediaStream] = []       // video and muxed streams
    var audios: [MediaStream] = []
    var subtitles: [MediaStream] = []
    /// The whole manifest cannot be used: live, protected, or not understood.
    var unsupported: String?
    /// A fingerprint of the manifest text, to notice a different asset behind the same address later.
    var fingerprint: String
    /// Things in the manifest that were skipped or are worth knowing, in plain words.
    var warnings: [String] = []
}

enum MediaError: Error, Equatable, LocalizedError {
    case notAManifest, tooLarge, tooManyLines, malformed(String), unsafeURL(String), unsupported(String), tooManySegments

    var errorDescription: String? {
        switch self {
        case .notAManifest: "That is not a streaming playlist."
        case .tooLarge: "The playlist is too large to read safely."
        case .tooManyLines: "The playlist has too many lines to read safely."
        case .malformed(let why): "The playlist is malformed: \(why)."
        case .unsafeURL(let why): "The playlist points somewhere that is not allowed: \(why)."
        case .unsupported(let why): why
        case .tooManySegments: "The playlist lists too many segments to download safely."
        }
    }
}

enum MediaURL {
    /// A reference in a manifest, made absolute against the manifest's own address. Only http and https results are accepted: nothing else (file:, data:, javascript:) is ever fetched
    /// because a manifest asked for it, and an absurdly long reference is refused.
    static func resolve(_ reference: String, against base: URL) throws -> URL {
        let ref = reference.trimmingCharacters(in: .whitespaces)
        guard !ref.isEmpty, ref.count <= MediaLimits.maxURLLength, !ref.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { throw MediaError.unsafeURL("an empty, unreadable or very long reference") }
        guard let url = URL(string: ref, relativeTo: base)?.absoluteURL, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else {
            throw MediaError.unsafeURL("only http and https addresses are followed")
        }
        // A secure manifest does not hand the download to an insecure address.
        if base.scheme?.lowercased() == "https", scheme == "http" { throw MediaError.unsafeURL("a secure playlist pointed at an insecure address") }
        // A playlist on the internet cannot aim the download at this Mac or the local network (the usual way a download is turned into a request against something private).
        if HTTPRequestPolicy.classify(host: host).isInternal, !HTTPRequestPolicy.classify(host: base.host ?? "").isInternal { throw MediaError.unsafeURL("a playlist on the internet pointed inside your network") }
        return url
    }
}

// MARK: - HLS

enum HLSParser {
    /// A master or a media playlist. A master gives the choices; a media playlist given on its own is one stream.
    static func parse(_ text: String, base: URL) throws -> MediaManifest {
        let lines = try readLines(text)
        let fingerprint = Data(text.utf8).sha256Hex
        let isMaster = lines.contains { $0.hasPrefix("#EXT-X-STREAM-INF") || $0.hasPrefix("#EXT-X-MEDIA:") }
        if isMaster { return try parseMaster(lines, base: base, fingerprint: fingerprint) }
        var stream = try parseMedia(lines, base: base, label: "Stream")
        stream.id = "media"
        let live = stream.unsupported?.hasPrefix("Live") == true
        return MediaManifest(format: .hls, sourceURL: base.absoluteString, duration: stream.duration, videos: [stream], unsupported: live ? stream.unsupported : nil, fingerprint: fingerprint, warnings: stream.notes ?? [])
    }

    /// A media playlist fetched after a choice was made. A master playlist here would mean a playlist pointing at another one: refused, so the chain can never loop or grow.
    static func parseStream(_ text: String, base: URL, label: String) throws -> MediaStream {
        let lines = try readLines(text)
        if lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }) { throw MediaError.malformed("a playlist pointed at another master playlist") }
        return try parseMedia(lines, base: base, label: label)
    }

    private static func readLines(_ text: String) throws -> [String] {
        guard text.utf8.count <= MediaLimits.maxManifestBytes else { throw MediaError.tooLarge }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.count <= MediaLimits.maxLines else { throw MediaError.tooManyLines }
        guard lines.first == "#EXTM3U" || lines.first == "\u{FEFF}#EXTM3U" else { throw MediaError.notAManifest }
        return lines
    }

    /// `KEY=value,KEY="quoted, value"` into a dictionary. Bounded and tolerant: anything it cannot read is skipped.
    static func attributes(_ text: Substring) -> [String: String] {
        var out: [String: String] = [:]
        var key = "", value = "", inKey = true, quoted = false
        func flush() { if !key.isEmpty, out.count < 64 { out[key.trimmingCharacters(in: .whitespaces).uppercased()] = value }; key = ""; value = ""; inKey = true }
        for ch in text.prefix(MediaLimits.maxAttributeLength * 4) {
            if inKey { if ch == "=" { inKey = false } else if ch == "," { flush() } else { key.append(ch) } }
            else if ch == "\"" { quoted.toggle() }
            else if ch == ",", !quoted { flush() }
            else { value.append(ch) }
        }
        flush()
        return out
    }

    /// A quoted value that is never closed would swallow the rest of the line, so such a line is not read at all.
    static func unbalancedQuotes(_ line: String) -> Bool { line.reduce(0) { $1 == "\"" ? $0 + 1 : $0 } % 2 != 0 }

    /// What an EXT-X-KEY / EXT-X-SESSION-KEY means. nil: the media is in the clear. Otherwise why it cannot be saved. Classification only: no key is ever fetched.
    static func protection(_ a: [String: String]) -> String? {
        let method = a["METHOD"]?.uppercased() ?? ""
        if method == "NONE" { return nil }
        let format = (a["KEYFORMAT"] ?? "identity").lowercased()
        if method.hasPrefix("SAMPLE-AES") || format.contains("streamingkeydelivery") || format.contains("widevine") || format.contains("playready") || format.contains("fairplay") {
            return "Encrypted segments (\(method.isEmpty ? "unknown method" : method), copy protection / DRM) are not supported."
        }
        return "Encrypted segments (\(method.isEmpty ? "unknown method" : method)) are not supported."
    }

    private static func channelCount(_ text: String?) -> Int? {
        guard let first = text?.split(separator: "/").first, let n = Int(first), (1...32).contains(n) else { return nil }
        return n
    }

    private static func parseMaster(_ lines: [String], base: URL, fingerprint: String) throws -> MediaManifest {
        var videos: [MediaStream] = [], audios: [MediaStream] = [], subs: [MediaStream] = []
        var audioGroups: [String: [MediaStream]] = [:]
        var pending: [String: String]?
        var protected = false
        var warnings: [String] = []
        var usedIDs = Set<String>(), seenEntries = Set<String>(), seenVariants = Set<String>()
        var captions = 0, iframes = 0
        for line in lines {
            if line.hasPrefix("#EXT-X-MEDIA:") {
                if unbalancedQuotes(line) { warnings.append("A track entry with a broken quoted value was skipped."); continue }
                let a = attributes(line.dropFirst("#EXT-X-MEDIA:".count))
                guard let type = a["TYPE"]?.uppercased(), let group = a["GROUP-ID"] else { warnings.append("A track entry without a type or group was skipped."); continue }
                if type == "CLOSED-CAPTIONS" { captions += 1; continue }
                guard type == "AUDIO" || type == "SUBTITLES" else { continue }       // video renditions (camera angles) are not downloadable streams
                let uri = try a["URI"].map { try MediaURL.resolve($0, against: base).absoluteString }
                let name = a["NAME"] ?? a["LANGUAGE"] ?? "\(audios.count + subs.count)"
                // The same entry listed twice is one track.
                let entryKey = [type, group, name, a["LANGUAGE"] ?? "", uri ?? ""].joined(separator: "|")
                guard seenEntries.insert(entryKey).inserted else { warnings.append("A track listed twice (\(name)) was counted once."); continue }
                var id = "\(type.lowercased())-\(group)-\(name)", n = 2
                while !usedIDs.insert(id).inserted { id = "\(type.lowercased())-\(group)-\(name)-\(n)"; n += 1 }
                var s = MediaStream(id: id, kind: type == "AUDIO" ? .audio : .subtitle, label: a["NAME"] ?? a["LANGUAGE"] ?? type.capitalized, language: a["LANGUAGE"], codecs: nil)
                s.playlistURL = uri; s.groupID = group; s.isDefault = a["DEFAULT"]?.uppercased() == "YES"
                s.autoSelect = a["AUTOSELECT"]?.uppercased() == "YES"
                s.channels = channelCount(a["CHANNELS"])
                let traits = (a["CHARACTERISTICS"] ?? "").lowercased()
                if !traits.isEmpty { s.characteristics = String(traits.prefix(300)) }
                if traits.contains("describes-video") { s.role = "description" }
                if traits.contains("transcribes-spoken-dialog") || traits.contains("describes-music-and-sound") { s.accessibility = true }
                if type == "SUBTITLES" { s.forced = a["FORCED"]?.uppercased() == "YES"; s.role = s.forced == true ? "forced-subtitle" : s.role }
                if uri == nil { s.unsupported = "This audio is part of the video stream" }
                if type == "AUDIO" { audios.append(s); audioGroups[group, default: []].append(s) } else { subs.append(s) }
                if audios.count + subs.count > MediaLimits.maxStreams { throw MediaError.tooManySegments }
            } else if line.hasPrefix("#EXT-X-STREAM-INF:") {
                if pending != nil { warnings.append("A variant with no address was skipped.") }
                pending = unbalancedQuotes(line) ? ["__BAD": "1"] : attributes(line.dropFirst("#EXT-X-STREAM-INF:".count))
            } else if line.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") {
                iframes += 1                                  // trick-play only: classified, never offered as a video
            } else if line.hasPrefix("#EXT-X-SESSION-KEY") {
                if protection(attributes(line.drop(while: { $0 != ":" }).dropFirst())) != nil { protected = true }
            } else if !line.hasPrefix("#"), let a = pending {
                pending = nil
                if a["__BAD"] != nil { warnings.append("A variant with a broken quoted value was skipped."); continue }
                guard videos.count < MediaLimits.maxStreams else { throw MediaError.tooManySegments }
                let url = try MediaURL.resolve(line, against: base)
                let res = a["RESOLUTION"]?.split(separator: "x").compactMap { Int($0) }
                let bandwidth = a["BANDWIDTH"].flatMap { Int($0) }
                let variantKey = [url.absoluteString, a["BANDWIDTH"] ?? "", a["RESOLUTION"] ?? "", a["CODECS"] ?? "", a["AUDIO"] ?? ""].joined(separator: "|")
                guard seenVariants.insert(variantKey).inserted else { warnings.append("A variant listed twice was counted once."); continue }
                let group = a["AUDIO"]
                if let g = group, audioGroups[g] == nil, !lines.contains(where: { $0.hasPrefix("#EXT-X-MEDIA:") && $0.contains("GROUP-ID=\"\(g)\"") }) {
                    warnings.append("A variant names the audio group \"\(g)\", which the playlist does not define; it is treated as carrying its own sound.")
                }
                // A variant that names an audio group with its own playlists is video only: its sound is a separate stream chosen with it.
                let separateAudio = group.map { (audioGroups[$0] ?? []).contains { $0.playlistURL != nil } } ?? false
                var s = MediaStream(id: "video-\(videos.count)", kind: separateAudio ? .video : .muxed, label: res.map { $0.count == 2 ? "\($0[1])p" : "" }.flatMap { $0.isEmpty ? nil : $0 } ?? (bandwidth.map { "\($0 / 1000) kbit/s" } ?? "Stream \(videos.count + 1)"),
                                    language: nil, codecs: a["CODECS"], bandwidth: bandwidth, width: res?.first, height: res.flatMap { $0.count == 2 ? $0[1] : nil })
                s.playlistURL = url.absoluteString; s.groupID = separateAudio ? group : nil
                s.frameRate = a["FRAME-RATE"].flatMap { Double($0) }.flatMap { $0 > 0 && $0 <= 960 ? $0 : nil }
                s.averageBandwidth = a["AVERAGE-BANDWIDTH"].flatMap { Int($0) }
                switch a["VIDEO-RANGE"]?.uppercased() { case "PQ": s.hdr = "HDR10"; case "HLG": s.hdr = "HLG"; case "SDR": s.hdr = "SDR"; default: break }
                videos.append(s)
            }
        }
        if pending != nil { warnings.append("A variant with no address was skipped.") }
        if captions > 0 { warnings.append("Closed captions carried inside the video are not extracted.") }
        if iframes > 0 { warnings.append("Trick-play (I-frame) streams are not offered.") }
        guard !videos.isEmpty || !audios.isEmpty || !subs.isEmpty else { throw MediaError.malformed("it lists no streams") }
        // The audio listed for a variant's group is resolved when a variant is chosen; ones that belong to no variant are still offered.
        videos.sort { ($0.bandwidth ?? 0) > ($1.bandwidth ?? 0) }
        return MediaManifest(format: .hls, sourceURL: base.absoluteString, duration: nil, videos: videos, audios: audios.filter { $0.isDownloadable }, subtitles: subs.filter { $0.isDownloadable },
                             unsupported: protected ? "This stream is encrypted or protected, which is not supported." : nil, fingerprint: fingerprint, warnings: warnings)
    }

    /// One media playlist: its segments, in order.
    static func parseMedia(_ lines: [String], base: URL, label: String) throws -> MediaStream {
        var s = MediaStream(id: "media", kind: .muxed, label: label, language: nil, codecs: nil)
        var ended = false, playlistType: String?, discontinuity = false, gap = false, iframesOnly = false
        var pendingDuration: Double?, pendingRangeText: String?, pendingDate: String?
        var nextOffset: [String: Int64] = [:]
        var total = 0.0
        var unsupported: String?
        var inits: [MediaSegment] = []
        var currentInit: Int?
        var mediaSequence: Int64 = 0, discontinuitySequence = 0, targetDuration: Double?
        var notes: [String] = []
        func range(_ text: String, resource: String, track: Bool = true) -> (Int64?, Int64)? {
            let parts = text.split(separator: "@", omittingEmptySubsequences: false)
            guard parts.count <= 2, let length = parts.first.flatMap({ Int64($0) }), length > 0 else { return nil }
            // Without an offset the range starts where the previous one of the same resource ended; with nothing before it the playlist is not usable.
            guard let offset = parts.count > 1 ? Int64(parts[1]) : nextOffset[resource], offset >= 0 else { return nil }
            let (end, overflow) = offset.addingReportingOverflow(length)
            guard !overflow else { return nil }
            if track { nextOffset[resource] = end }
            return (offset, length)
        }
        for line in lines {
            if line.hasPrefix("#EXT-X-ENDLIST") { ended = true }
            else if line.hasPrefix("#EXT-X-PLAYLIST-TYPE:") { playlistType = String(line.dropFirst("#EXT-X-PLAYLIST-TYPE:".count)).uppercased() }
            else if line.hasPrefix("#EXT-X-TARGETDURATION:") { targetDuration = Double(line.dropFirst("#EXT-X-TARGETDURATION:".count)) }
            else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") { mediaSequence = Int64(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count).trimmingCharacters(in: .whitespaces)).flatMap { (0...1_000_000_000_000).contains($0) ? $0 : nil } ?? 0 }
            else if line.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE:") { discontinuitySequence = Int(line.dropFirst("#EXT-X-DISCONTINUITY-SEQUENCE:".count).trimmingCharacters(in: .whitespaces)).flatMap { (0...1_000_000_000).contains($0) ? $0 : nil } ?? 0 }
            else if line.hasPrefix("#EXT-X-I-FRAMES-ONLY") { iframesOnly = true }
            else if line.hasPrefix("#EXT-X-DEFINE") { unsupported = unsupported ?? "This playlist uses variables (EXT-X-DEFINE), which are not supported." }
            else if line.hasPrefix("#EXT-X-SKIP") { unsupported = unsupported ?? "This is a partial playlist update (live), which is not supported." }
            else if line.hasPrefix("#EXT-X-GAP") { gap = true }
            else if line.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:") { pendingDate = String(line.dropFirst("#EXT-X-PROGRAM-DATE-TIME:".count).prefix(40)) }
            else if line.hasPrefix("#EXT-X-KEY:") {
                if let why = HLSParser.protection(attributes(line.dropFirst("#EXT-X-KEY:".count))) { unsupported = unsupported ?? why }
            }
            else if line.hasPrefix("#EXT-X-MAP:") {
                let a = attributes(line.dropFirst("#EXT-X-MAP:".count))
                guard let uri = a["URI"] else { throw MediaError.malformed("an initialization segment has no address") }
                let url = try MediaURL.resolve(uri, against: base)
                var seg = MediaSegment(url: url.absoluteString, duration: 0)
                if let r = a["BYTERANGE"] { guard let parsed = range(r, resource: url.absoluteString, track: false), parsed.0 != nil else { throw MediaError.malformed("an initialization byte range is not usable") }; seg.offset = parsed.0; seg.length = parsed.1 }
                // A new initialization segment applies to the segments after it. Each run of segments with the same one is kept apart from the next when the file is put together.
                if let at = inits.firstIndex(of: seg) { currentInit = at } else {
                    guard inits.count < 64 else { throw MediaError.tooManySegments }
                    inits.append(seg); currentInit = inits.count - 1
                }
            }
            else if line.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE") { continue }
            else if line.hasPrefix("#EXT-X-DISCONTINUITY") { discontinuity = true }
            else if line.hasPrefix("#EXT-X-BYTERANGE:") { pendingRangeText = String(line.dropFirst("#EXT-X-BYTERANGE:".count)) }
            else if line.hasPrefix("#EXTINF:") {
                let d = line.dropFirst("#EXTINF:".count).split(separator: ",", maxSplits: 1).first.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                guard let d, d >= 0, d.isFinite, d <= 86_400 else { throw MediaError.malformed("a segment has no usable duration") }
                pendingDuration = d
            }
            else if !line.hasPrefix("#") {
                guard let d = pendingDuration else { throw MediaError.malformed("an address with no duration before it") }
                pendingDuration = nil
                guard s.segments.count < MediaLimits.maxSegmentsPerStream else { throw MediaError.tooManySegments }
                let url = try MediaURL.resolve(line, against: base)
                if discontinuity { discontinuitySequence += 1 }
                var seg = MediaSegment(url: url.absoluteString, duration: d, discontinuity: discontinuity)
                seg.sequence = mediaSequence + Int64(s.segments.count)
                seg.discontinuitySequence = discontinuitySequence
                seg.programDate = pendingDate; pendingDate = nil
                seg.initIndex = currentInit
                discontinuity = false
                if gap { gap = false; unsupported = unsupported ?? "This playlist has gaps (missing media), which cannot be downloaded." }
                if let target = targetDuration, d > target + 1 { notes.append("A segment is longer than the playlist's declared target duration.") }
                if let text = pendingRangeText { pendingRangeText = nil; if let r = range(text, resource: url.absoluteString) { seg.offset = r.0; seg.length = r.1 } else { throw MediaError.malformed("a byte range is not usable") } }
                s.segments.append(seg); total += d
            }
        }
        s.duration = total
        // Live: a playlist that is not finished. A recording of it cannot be completed by downloading what is listed now.
        if !ended && playlistType != "VOD" { unsupported = "Live streams are not supported yet: this playlist is not finished." }
        guard !s.segments.isEmpty else { throw MediaError.malformed("it lists no segments") }
        if iframesOnly { unsupported = unsupported ?? "This is a trick-play (I-frame only) playlist, not the full video." }
        // Initialization segments: the first is the stream's own; later ones are kept beside it and each segment says which it needs.
        if let first = inits.first {
            s.initSegment = first
            if inits.count > 1 { s.extraInits = Array(inits.dropFirst()) }
            if s.segments.contains(where: { $0.initIndex == nil }) { unsupported = unsupported ?? "This playlist has media before its first initialization segment, which is not supported." }
            if inits.count == 1 { for i in s.segments.indices { s.segments[i].initIndex = nil } }
        }
        let extensions = Set(s.segments.prefix(2000).compactMap { (try? MediaURL.resolve($0.url, against: base))?.pathExtension.lowercased() })
        let first = (try? MediaURL.resolve(s.segments[0].url, against: base))?.pathExtension.lowercased() ?? ""
        if s.initSegment != nil { s.container = .fragmentedMP4 }
        else if ["ts", "m2ts"].contains(first) { s.container = .mpegTS }
        else if ["vtt", "webvtt"].contains(first) { s.container = .webVTT }
        else if ["m4s", "mp4", "m4v", "m4a", "cmfv", "cmfa"].contains(first) { unsupported = unsupported ?? "These segments need an initialization segment that the playlist does not list." }
        else if ["aac", "mp3", "ac3", "ec3"].contains(first) { unsupported = unsupported ?? "Packed audio segments (.\(first)) are not supported yet." }
        else { unsupported = unsupported ?? "The segment format (.\(first)) is not supported." }
        if s.container == .mpegTS, extensions.contains(where: { !["ts", "m2ts"].contains($0) }) { unsupported = unsupported ?? "This playlist mixes segment formats, which is not supported." }
        if s.container == .webVTT { s.kind = .subtitle }          // text, not a picture: it is joined as a text file
        if !notes.isEmpty { s.notes = Array(Set(notes)).sorted() }
        s.unsupported = unsupported
        return s
    }
}

// MARK: - MPEG-DASH

/// A bounded reading of a static on-demand MPD: one or several periods; SegmentTemplate (timeline, fixed duration), SegmentList and SegmentBase / single-file representations; fragmented MP4,
/// MPEG-TS and text. Anything else is named as unsupported. The XML is never allowed to define entities or load anything from elsewhere.
enum DASHParser {
    fileprivate struct Node { var name: String; var attrs: [String: String]; var children: [Node] = []; var text = "" }

    private final class Builder: NSObject, XMLParserDelegate {
        var stack: [Node] = [], root: Node?
        var count = 0, failure: String?
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes attrs: [String: String]) {
            count += 1
            if count > MediaLimits.maxXMLElements || stack.count >= MediaLimits.maxXMLDepth { failure = "the document is too large or too deeply nested"; parser.abortParsing(); return }
            stack.append(Node(name: name.split(separator: ":").last.map(String.init) ?? name, attrs: attrs))
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if !stack.isEmpty, stack[stack.count - 1].text.count < 8192 { stack[stack.count - 1].text += string } }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
            guard let node = stack.popLast() else { return }
            if stack.isEmpty { root = node } else { stack[stack.count - 1].children.append(node) }
        }
        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { if failure == nil { failure = parseError.localizedDescription } }
    }

    /// Where a representation's media is, resolved: the address in use and any alternates the manifest lists for the same files.
    fileprivate struct Bases { var primary: URL; var alternates: [URL] = []; var own = false }

    fileprivate struct Context {
        var rep: Node, set: Node, period: Node
        var base: URL
        var hasOwnBase: Bool
        var repID: String
        var bandwidth: Int
        var mime: String
        var codecs: String
        var periodStart: MediaRational
        var periodDuration: MediaRational?
    }

    fileprivate struct Filled {
        var segments: [MediaSegment] = []
        var initSegment: MediaSegment?
        var container: MediaContainer = .unknown
        var why: String?
    }

    static func parse(_ data: Data, base: URL) throws -> MediaManifest {
        guard data.count <= MediaLimits.maxManifestBytes else { throw MediaError.tooLarge }
        // A document type declaration is how entities are defined: a streaming manifest has no use for one, so one is refused before the parser sees it.
        // Read as a whole (it is bounded), and only as UTF-8: another encoding could hide the declaration from a text search.
        let bom = [UInt8](data.prefix(4))
        guard !(bom.starts(with: [0xFF, 0xFE]) || bom.starts(with: [0xFE, 0xFF]) || bom.prefix(4).contains(0)) else { throw MediaError.unsupported("The manifest is not UTF-8, which is not supported.") }
        let head = String(decoding: data, as: UTF8.self).lowercased()
        guard !head.contains("<!doctype"), !head.contains("<!entity") else { throw MediaError.unsupported("The manifest contains a document type declaration, which is refused for safety.") }
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        let builder = Builder(); parser.delegate = builder
        _ = parser.parse()
        if let f = builder.failure { throw MediaError.malformed(f) }
        guard let mpd = builder.root, mpd.name == "MPD" else { throw MediaError.notAManifest }
        let fingerprint = data.sha256Hex
        func fail(_ why: String) -> MediaManifest { MediaManifest(format: .dash, sourceURL: base.absoluteString, duration: nil, unsupported: why, fingerprint: fingerprint) }

        if mpd.attrs["type"]?.lowercased() == "dynamic" { return fail("Live streams are not supported yet: this manifest is dynamic.") }
        let periods = mpd.children.filter { $0.name == "Period" }
        guard !periods.isEmpty else { throw MediaError.malformed("it has no period") }
        guard periods.count <= 64 else { throw MediaError.tooManySegments }
        if periods.contains(where: { $0.attrs["xlink:href"] != nil }) { return fail("Periods that are loaded from another address are not supported.") }

        // Where each period sits on the presentation timeline, exactly.
        let total = isoRational(mpd.attrs["mediaPresentationDuration"])
        var timing: [(start: MediaRational, duration: MediaRational?)] = []
        var cursor: MediaRational? = .zero
        var warnings: [String] = []
        for (i, p) in periods.enumerated() {
            guard let start = isoRational(p.attrs["start"]) ?? cursor else { return fail("A period has no start time and the one before it has no length.") }
            var duration = isoRational(p.attrs["duration"])
            if duration == nil, i + 1 < periods.count, let next = isoRational(periods[i + 1].attrs["start"]) { duration = next - start }
            if duration == nil, i + 1 == periods.count, let total { duration = total - start }
            if let d = duration, d.n <= 0 { return fail("A period has no length.") }
            if let previous = timing.last, let end = previous.duration.flatMap({ previous.start + $0 }) {
                if start < end { return fail("Two periods overlap in time, which is not supported.") }
                if let gap = start - end, gap.n > 0 { warnings.append("There is a gap of \(String(format: "%.2f", gap.seconds)) seconds before period \(i + 1).") }
            }
            timing.append((start, duration))
            cursor = duration.flatMap { start + $0 }
        }
        let presentation = total ?? cursor
        var manifest = MediaManifest(format: .dash, sourceURL: base.absoluteString, duration: presentation?.seconds, fingerprint: fingerprint)

        let mpdBases = try bases(mpd, parent: Bases(primary: base))
        var protectedFound = false
        var totalSegments = 0
        func hasProtection(_ n: Node) -> Bool { n.name == "ContentProtection" || n.children.contains(where: hasProtection) }

        var slots: [String: Slot] = [:]
        var presence: [String: Set<Int>] = [:]
        var order: [String] = []
        /// What a representation is, decided the same way everywhere it is needed.
        func describe(_ rep: Node, _ set: Node, setIndex: Int, repIndex: Int) -> (mime: String, kind: MediaStream.Kind, known: Bool, isText: Bool, repID: String, base: String) {
            let attr: (String) -> String? = { rep.attrs[$0] ?? set.attrs[$0] }
            var mime = (attr("mimeType") ?? "").lowercased()
            let contentType = (attr("contentType") ?? "").lowercased(), codecs = (attr("codecs") ?? "").lowercased()
            if mime.isEmpty && contentType.isEmpty {
                // No type given: the codecs say what it is.
                let d = MediaCodecs.describe(attr("codecs"))
                if d.video != nil { mime = "video/mp4" } else if d.audio != nil { mime = "audio/mp4" }
            }
            let isText = mime.hasPrefix("text/") || mime.contains("ttml") || contentType == "text" || codecs.hasPrefix("stpp") || codecs == "wvtt"
            let isVideo = mime.hasPrefix("video/") || contentType == "video", isAudio = mime.hasPrefix("audio/") || contentType == "audio"
            let kind: MediaStream.Kind = isText ? .subtitle : (isVideo ? .video : (isAudio ? .audio : .subtitle))
            let known = isText || isVideo || isAudio
            let repID = rep.attrs["id"] ?? "\(setIndex)r\(repIndex)"
            return (mime, kind, known, isText, repID, "\(known ? kind.rawValue : "other")-\(repID)")
        }

        for (pi, period) in periods.enumerated() {
            let periodBases = try bases(period, parent: mpdBases)
            // Representation ids are meant to be unique within a period; when a manifest repeats one, the set it is in tells them apart.
            var seenBase = Set<String>(), repeatedBase = Set<String>()
            do {
                var si = 0
                for set in period.children where set.name == "AdaptationSet" {
                    si += 1; var ri = 0
                    for rep in set.children where rep.name == "Representation" { ri += 1; let b = describe(rep, set, setIndex: si, repIndex: ri).base; if !seenBase.insert(b).inserted { repeatedBase.insert(b) } }
                }
            }
            var setIndex = 0
            for set in period.children where set.name == "AdaptationSet" {
                setIndex += 1
                let setBases = try bases(set, parent: periodBases)
                let setProtected = set.children.contains(where: hasProtection)
                var repIndex = 0
                for rep in set.children where rep.name == "Representation" {
                    repIndex += 1
                    let attr: (String) -> String? = { rep.attrs[$0] ?? set.attrs[$0] }
                    let d = describe(rep, set, setIndex: setIndex, repIndex: repIndex)
                    let mime = d.mime, codecs = attr("codecs") ?? "", isText = d.isText, kind = d.kind, known = d.known, repID = d.repID
                    let key = repeatedBase.contains(d.base) ? "\(known ? kind.rawValue : "other")-\(setIndex)-\(repID)" : d.base
                    guard manifest.videos.count + manifest.audios.count + manifest.subtitles.count < MediaLimits.maxStreams || slots[key] != nil else { throw MediaError.tooManySegments }
                    let repBases = try bases(rep, parent: setBases)

                    var s: MediaStream
                    if let slot = slots[key] {
                        switch slot { case .video(let i): s = manifest.videos[i]; case .audio(let i): s = manifest.audios[i]; case .subtitle(let i): s = manifest.subtitles[i] }
                    } else {
                        guard pi == 0 else {
                            // A track that was not in the first period: not part of every period, so it cannot be a continuous track.
                            warnings.append("The track \(repID) appears only in some periods and is not offered.")
                            continue
                        }
                        s = MediaStream(id: key, kind: kind, label: "", language: attr("lang"), codecs: attr("codecs"), bandwidth: attr("bandwidth").flatMap { Int($0) },
                                        width: attr("width").flatMap { Int($0) }, height: attr("height").flatMap { Int($0) })
                        s.frameRate = attr("frameRate").flatMap { Self.rate($0) }
                        s.label = kind == .audio ? (attr("lang") ?? s.bitrateText ?? repID) : (kind == .subtitle ? (attr("lang") ?? repID) : (s.height.map { "\($0)p" } ?? s.bitrateText ?? repID))
                        let roles = set.children.filter { $0.name == "Role" }.compactMap { $0.attrs["value"]?.lowercased() }
                        if let r = roles.first(where: { $0 != "main" }) ?? roles.first { s.role = r }
                        s.isDefault = roles.contains("main")
                        s.forced = roles.contains("forced-subtitle") || roles.contains("forced_subtitle") ? true : nil
                        s.accessibility = (set.children.contains { $0.name == "Accessibility" } || roles.contains("caption") || roles.contains("description")) ? true : nil
                        s.channels = channelCount(rep: rep, set: set)
                        s.hdr = hdrLabel(rep: rep, set: set)
                        if let v = attr("scanType"), v.lowercased() == "interlaced" { s.notes = (s.notes ?? []) + ["Interlaced video."] }
                    }
                    presence[key, default: []].insert(pi)
                    if pi == 0 { order.append(key) }

                    if !known { s.unsupported = s.unsupported ?? "Tracks of this type in a DASH manifest are not downloaded yet."; place(&manifest, &slots, key, s, kind: .subtitle); continue }
                    if setProtected || rep.children.contains(where: hasProtection) { protectedFound = true; s.unsupported = s.unsupported ?? "This media is protected (DRM), which is not supported." }
                    else if s.unsupported == nil {
                        let ctx = Context(rep: rep, set: set, period: period, base: repBases.primary, hasOwnBase: repBases.own, repID: repID, bandwidth: s.bandwidth ?? 0, mime: mime, codecs: codecs,
                                          periodStart: timing[pi].start, periodDuration: timing[pi].duration)
                        let filled = try fill(ctx, isText: isText)
                        if let why = filled.why { s.unsupported = why }
                        else {
                            if pi == 0 { s.initSegment = filled.initSegment; s.container = filled.container }
                            else if s.container != filled.container { s.unsupported = "A period uses a different media format from the first, which is not supported." }
                            var segs = filled.segments
                            // Segments of a period belong with that period's own initialization segment, and a period boundary starts a new part of the file.
                            var all = [s.initSegment].compactMap { $0 } + (s.extraInits ?? [])
                            if let ini = filled.initSegment {
                                if pi > 0, s.initSegment == nil { s.unsupported = "A period has an initialization segment where the first has none, which is not supported." }
                                else if let at = all.firstIndex(of: ini) { for i in segs.indices { segs[i].initIndex = at } }
                                else { all.append(ini); for i in segs.indices { segs[i].initIndex = all.count - 1 } }
                                if all.count > 1 { s.extraInits = Array(all.dropFirst()) }
                            } else if pi > 0, s.initSegment != nil { s.unsupported = "A period has no initialization segment where the first has one, which is not supported." }
                            if pi > 0, !segs.isEmpty { segs[0].discontinuity = true }
                            if pi == 0, filled.initSegment != nil { for i in segs.indices { segs[i].initIndex = 0 } }
                            s.segments += segs
                            guard s.segments.count <= MediaLimits.maxSegmentsPerStream else { throw MediaError.tooManySegments }
                        }
                    }
                    if !repBases.alternates.isEmpty, repBases.own { s.mirrors = (s.mirrors ?? [:]).merging([repBases.primary.absoluteString: repBases.alternates.map(\.absoluteString)]) { _, new in new } }
                    place(&manifest, &slots, key, s, kind: kind)
                }
            }
        }
        // A track that was missing from some period cannot be put together; say so on that track.
        for key in order {
            guard let slot = slots[key], (presence[key]?.count ?? 0) != periods.count else { continue }
            switch slot {
            case .video(let i): manifest.videos[i].unsupported = manifest.videos[i].unsupported ?? "This track is not in every period of the presentation."
            case .audio(let i): manifest.audios[i].unsupported = manifest.audios[i].unsupported ?? "This track is not in every period of the presentation."
            case .subtitle(let i): manifest.subtitles[i].unsupported = manifest.subtitles[i].unsupported ?? "This track is not in every period of the presentation."
            }
        }
        // Timing facts that need all periods: totals, and exact gaps inside a track.
        func finish(_ list: inout [MediaStream]) {
            for i in list.indices {
                var s = list[i]
                if s.segments.allSatisfy({ $0.initIndex == 0 }) { for k in s.segments.indices { s.segments[k].initIndex = nil } }
                s.duration = s.segments.reduce(0) { $0 + $1.duration }
                if s.unsupported == nil, !s.segments.isEmpty {
                    let report = MediaTimeline.analyze(s.segments)
                    if !report.gaps.isEmpty { s.notes = (s.notes ?? []) + ["The timeline has \(report.gaps.count) gap(s) between segments."] }
                    if !report.overlaps.isEmpty { s.notes = (s.notes ?? []) + ["The timeline has \(report.overlaps.count) overlap(s) between segments."] }
                }
                list[i] = s
            }
        }
        finish(&manifest.videos); finish(&manifest.audios); finish(&manifest.subtitles)
        manifest.videos.sort { ($0.bandwidth ?? 0) > ($1.bandwidth ?? 0) }
        manifest.warnings = warnings
        if manifest.videos.isEmpty && manifest.audios.isEmpty { return fail("The manifest has no video or audio streams this can read.") }
        // Any protected stream makes the whole presentation unusable: taking the clear half (silent video, say) would not be what the person asked for.
        if protectedFound { manifest.unsupported = "This media is protected (DRM), which is not supported." }
        return manifest
    }

    private static func place(_ m: inout MediaManifest, _ slots: inout [String: Slot], _ key: String, _ s: MediaStream, kind: MediaStream.Kind) {
        if let slot = slots[key] {
            switch slot { case .video(let i): m.videos[i] = s; case .audio(let i): m.audios[i] = s; case .subtitle(let i): m.subtitles[i] = s }
            return
        }
        switch kind {
        case .audio: m.audios.append(s); slots[key] = .audio(m.audios.count - 1)
        case .subtitle: m.subtitles.append(s); slots[key] = .subtitle(m.subtitles.count - 1)
        default: m.videos.append(s); slots[key] = .video(m.videos.count - 1)
        }
    }
    private enum Slot { case video(Int), audio(Int), subtitle(Int) }

    // MARK: Small readings

    private static func channelCount(rep: Node, set: Node) -> Int? {
        for n in rep.children + set.children where n.name == "AudioChannelConfiguration" {
            let scheme = (n.attrs["schemeIdUri"] ?? "").lowercased(), value = n.attrs["value"] ?? ""
            if scheme.contains("dolby"), let mask = UInt32(value, radix: 16) { let c = mask.nonzeroBitCount; return c > 0 && c <= 32 ? c : nil }
            if let c = Int(value), (1...32).contains(c) { return c }
        }
        return nil
    }

    private static func hdrLabel(rep: Node, set: Node) -> String? {
        for n in rep.children + set.children where n.name == "EssentialProperty" || n.name == "SupplementalProperty" {
            guard (n.attrs["schemeIdUri"] ?? "").contains("TransferCharacteristics") else { continue }
            switch n.attrs["value"] { case "16": return "HDR10"; case "18": return "HLG"; case "1", "6", "13": return "SDR"; default: break }
        }
        return nil
    }

    /// The BaseURL list of a node, resolved against its parent's address. The first is used; the others are kept as alternates for the same files.
    private static func bases(_ node: Node, parent: Bases) throws -> Bases {
        let list = node.children.filter { $0.name == "BaseURL" }.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard let first = list.first else { return Bases(primary: parent.primary, alternates: parent.alternates, own: parent.own) }
        let primary = try MediaURL.resolve(first, against: parent.primary)
        let alternates = try list.dropFirst().prefix(4).map { try MediaURL.resolve($0, against: parent.primary) }.filter { $0 != primary }
        return Bases(primary: primary, alternates: alternates, own: true)
    }

    // MARK: Segments of one representation in one period

    private static func nodes(_ name: String, _ ctx: Context) -> [Node] { [ctx.period, ctx.set, ctx.rep].compactMap { $0.children.first { $0.name == name } } }       // least to most specific
    private static func merged(_ list: [Node]) -> [String: String] { var out: [String: String] = [:]; for n in list { out.merge(n.attrs) { _, new in new } }; return out }

    private static func expand(_ pattern: String, repID: String, bandwidth: Int, number: Int64?, time: Int64?) throws -> String {
        var out = "", i = pattern.startIndex
        while i < pattern.endIndex {
            if pattern[i] != "$" { out.append(pattern[i]); i = pattern.index(after: i); continue }
            guard let end = pattern[pattern.index(after: i)...].firstIndex(of: "$") else { throw MediaError.malformed("an unclosed $ in a segment pattern") }
            let token = String(pattern[pattern.index(after: i)..<end])
            if token.isEmpty { out.append("$"); i = pattern.index(after: end); continue }
            let parts = token.split(separator: "%", maxSplits: 1).map(String.init)
            let width = parts.count > 1 ? Int(parts[1].dropFirst().dropLast()) ?? 1 : 1          // "%05d" -> 5
            func pad(_ v: Int64) -> String { let t = String(v); return String(repeating: "0", count: max(0, min(width, 12) - t.count)) + t }
            switch parts[0] {
            case "": out.append("$")
            case "RepresentationID": out.append(repID)
            case "Bandwidth": out.append(String(bandwidth))
            case "Number": guard let number else { throw MediaError.malformed("$Number$ used with a time-based template") }; out.append(pad(number))
            case "Time": guard let time else { throw MediaError.malformed("$Time$ used without a timeline") }; out.append(pad(time))
            default: throw MediaError.malformed("an unknown segment pattern variable")
            }
            i = pattern.index(after: end)
        }
        return out
    }

    private static func range(_ text: String?) -> (offset: Int64, length: Int64)? {
        guard let parts = text?.split(separator: "-", omittingEmptySubsequences: false), parts.count == 2, let a = Int64(parts[0]), let b = Int64(parts[1]), a >= 0, b >= a else { return nil }
        let (len, o) = (b - a).addingReportingOverflow(1)
        return o ? nil : (a, len)
    }

    private static func containerFor(mime: String, codecs: String, hasInit: Bool, wholeFile url: URL?) -> (MediaContainer, String?) {
        let c = codecs.lowercased()
        if mime.contains("webm") { return (.unknown, "WebM media is not supported.") }
        if mime.contains("vtt") { return (.webVTT, nil) }
        if mime.contains("ttml") || (mime == "application/xml" && c.hasPrefix("stpp")) { return (.ttml, nil) }
        if c.hasPrefix("stpp") || c == "wvtt" { return (.unknown, "Text carried inside MP4 segments is not extracted yet.") }
        if mime.contains("mp2t") { return (.mpegTS, nil) }
        if mime.contains("mp4") || hasInit { return (.fragmentedMP4, nil) }
        if let ext = url?.pathExtension.lowercased() {
            if ["mp4", "m4v", "m4a", "m4s"].contains(ext) { return (.fragmentedMP4, nil) }
            if ext == "vtt" { return (.webVTT, nil) }
            if ["ttml", "xml", "dfxp"].contains(ext) { return (.ttml, nil) }
        }
        return (.unknown, "The media format (\(mime.isEmpty ? "unknown" : mime)) is not supported.")
    }

    fileprivate static func fill(_ ctx: Context, isText: Bool) throws -> Filled {
        var out = Filled()
        // The most specific level that has any segment description decides which kind it is.
        var kindName: String?
        for node in [ctx.rep, ctx.set, ctx.period] {
            if let k = ["SegmentTemplate", "SegmentList", "SegmentBase"].first(where: { name in node.children.contains { $0.name == name } }) { kindName = k; break }
        }
        let pStartFor: (Int64) -> Int64? = { scale in ctx.periodStart.roundedTicks(scale: scale) }

        switch kindName {
        case "SegmentTemplate":
            let list = nodes("SegmentTemplate", ctx), a = merged(list)
            guard let media = a["media"] else { out.why = "The segment template has no media pattern."; return out }
            guard let timescale = Int64(a["timescale"] ?? "1"), timescale > 0, timescale <= 1_000_000_000 else { out.why = "The segment template has a bad time scale."; return out }
            guard let startNumber = Int64(a["startNumber"] ?? "1"), (0...1_000_000_000).contains(startNumber) else { out.why = "The segment template has an unusable start number."; return out }
            guard let pto = Int64(a["presentationTimeOffset"] ?? "0"), pto >= 0 else { out.why = "The segment template has a bad presentation time offset."; return out }
            if let initPattern = a["initialization"] {
                out.initSegment = MediaSegment(url: try MediaURL.resolve(try expand(initPattern, repID: ctx.repID, bandwidth: ctx.bandwidth, number: nil, time: nil), against: ctx.base).absoluteString, duration: 0)
            }
            guard let periodStartTicks = pStartFor(timescale) else { out.why = "A period start is out of range."; return out }
            let timeline = list.reversed().compactMap { $0.children.first { $0.name == "SegmentTimeline" } }.first
            var segments: [MediaSegment] = []
            if let timeline {
                let entries = timeline.children.filter { $0.name == "S" }
                guard entries.count <= MediaLimits.maxTimelineEntries else { throw MediaError.tooManySegments }
                let periodEnd: Int64? = ctx.periodDuration?.ceilingTicks(scale: timescale).flatMap { v in pto.addingReportingOverflow(v).overflow ? nil : pto + v }
                var t: Int64 = 0
                var number = startNumber
                for (k, entry) in entries.enumerated() {
                    if let start = entry.attrs["t"].flatMap({ Int64($0) }) { t = start }
                    guard t >= 0 else { throw MediaError.malformed("a timeline value is out of range") }
                    guard let d = entry.attrs["d"].flatMap({ Int64($0) }), d > 0, d <= 86_400 * timescale else { throw MediaError.malformed("a timeline entry has no usable duration") }
                    guard let repeats = Int(entry.attrs["r"] ?? "0") else { throw MediaError.malformed("a timeline repeat count is not a number") }
                    var count: Int64
                    if repeats >= 0 { count = Int64(min(repeats, MediaLimits.maxSegmentsPerStream + 1)) + 1 }
                    else {
                        // A negative repeat runs to the next entry's start, or to the end of the period.
                        let bound: Int64? = (k + 1 < entries.count ? entries[k + 1].attrs["t"].flatMap { Int64($0) }.flatMap { $0 >= 0 ? $0 : nil } : nil) ?? periodEnd
                        guard let bound else { out.why = "A timeline that repeats until the end of the period needs that period's length, which the manifest does not give."; return out }
                        let span = bound - t
                        count = span > 0 ? (span - 1) / d + 1 : 0
                    }
                    guard count <= Int64(MediaLimits.maxSegmentsPerStream), Int64(segments.count) + count <= Int64(MediaLimits.maxSegmentsPerStream) else { throw MediaError.tooManySegments }
                    var made: Int64 = 0
                    while made < count {
                        let u = try MediaURL.resolve(try expand(media, repID: ctx.repID, bandwidth: ctx.bandwidth, number: number, time: t), against: ctx.base)
                        var seg = MediaSegment(url: u.absoluteString, duration: Double(d) / Double(timescale))
                        let (rel, o0) = t.subtractingReportingOverflow(pto)
                        let (global, o1) = periodStartTicks.addingReportingOverflow(rel)
                        seg.ticks = d; seg.scale = timescale; seg.startTicks = (o0 || o1) ? nil : global; seg.sequence = number
                        segments.append(seg)
                        let (next, overflow) = t.addingReportingOverflow(d)
                        guard !overflow else { throw MediaError.malformed("a timeline value is out of range") }
                        t = next; number += 1; made += 1
                    }
                }
            } else if let d = a["duration"].flatMap({ Int64($0) }), d > 0, d <= 86_400 * timescale {
                guard let length = ctx.periodDuration else { out.why = "A fixed-duration template needs the presentation duration, which the manifest does not give."; return out }
                guard let totalTicks = length.ceilingTicks(scale: timescale) else { out.why = "The presentation length is out of range."; return out }
                var count = (totalTicks + d - 1) / d
                var capped = false
                if let end = a["endNumber"].flatMap({ Int64($0) }), end >= startNumber, end - startNumber + 1 < count { count = end - startNumber + 1; capped = true }
                guard count > 0, count <= Int64(MediaLimits.maxSegmentsPerStream) else { throw MediaError.tooManySegments }
                for i in 0..<count {
                    let u = try MediaURL.resolve(try expand(media, repID: ctx.repID, bandwidth: ctx.bandwidth, number: startNumber + i, time: nil), against: ctx.base)
                    let ticks = (i == count - 1 && !capped) ? max(1, totalTicks - d * i) : d
                    var seg = MediaSegment(url: u.absoluteString, duration: Double(ticks) / Double(timescale))
                    seg.ticks = ticks; seg.scale = timescale; seg.startTicks = periodStartTicks + d * i; seg.sequence = startNumber + i
                    segments.append(seg)
                }
            } else { out.why = "The segment template has neither a timeline nor a duration."; return out }
            guard !segments.isEmpty else { out.why = "The representation lists no segments."; return out }
            out.segments = segments
            let (container, why) = containerFor(mime: ctx.mime, codecs: ctx.codecs, hasInit: out.initSegment != nil, wholeFile: nil)
            out.container = container; out.why = why
            if why == nil, container == .fragmentedMP4, out.initSegment == nil { out.why = "The media segments need an initialization segment that the manifest does not list." }

        case "SegmentList":
            let list = nodes("SegmentList", ctx), a = merged(list)
            guard let timescale = Int64(a["timescale"] ?? "1"), timescale > 0, timescale <= 1_000_000_000 else { out.why = "The segment list has a bad time scale."; return out }
            guard let periodStartTicks = pStartFor(timescale) else { out.why = "A period start is out of range."; return out }
            if let ini = list.reversed().compactMap({ $0.children.first { $0.name == "Initialization" } }).first {
                let target = try ini.attrs["sourceURL"].map { try MediaURL.resolve($0, against: ctx.base) } ?? ctx.base
                var seg = MediaSegment(url: target.absoluteString, duration: 0)
                if let text = ini.attrs["range"] { guard let r = range(text) else { throw MediaError.malformed("an initialization byte range is not usable") }; seg.offset = r.offset; seg.length = r.length }
                out.initSegment = seg
            }
            guard let urls = list.reversed().compactMap({ n -> [Node]? in let u = n.children.filter { $0.name == "SegmentURL" }; return u.isEmpty ? nil : u }).first else { out.why = "The segment list has no segments."; return out }
            guard urls.count <= MediaLimits.maxSegmentsPerStream else { throw MediaError.tooManySegments }
            // Lengths: an explicit timeline, or one fixed duration.
            var lengths: [Int64] = []
            if let timeline = list.reversed().compactMap({ $0.children.first { $0.name == "SegmentTimeline" } }).first {
                for e in timeline.children where e.name == "S" {
                    guard let d = e.attrs["d"].flatMap({ Int64($0) }), d > 0, d <= 86_400 * timescale, let r = Int(e.attrs["r"] ?? "0"), r >= 0, r <= MediaLimits.maxSegmentsPerStream else { out.why = "The segment list's timeline cannot be read."; return out }
                    guard lengths.count + r + 1 <= MediaLimits.maxSegmentsPerStream else { throw MediaError.tooManySegments }
                    lengths += Array(repeating: d, count: r + 1)
                }
            } else if let d = a["duration"].flatMap({ Int64($0) }), d > 0, d <= 86_400 * timescale { lengths = Array(repeating: d, count: urls.count) }
            else { out.why = "The segment list gives no durations."; return out }
            guard lengths.count >= urls.count else { out.why = "The segment list has more segments than durations."; return out }
            var t: Int64 = 0
            guard let start = Int64(a["startNumber"] ?? "1"), (0...1_000_000_000).contains(start) else { out.why = "The segment list has an unusable start number."; return out }
            for (i, u) in urls.enumerated() {
                let target = try u.attrs["media"].map { try MediaURL.resolve($0, against: ctx.base) } ?? ctx.base
                var seg = MediaSegment(url: target.absoluteString, duration: Double(lengths[i]) / Double(timescale))
                if let text = u.attrs["mediaRange"] { guard let r = range(text) else { throw MediaError.malformed("a media byte range is not usable") }; seg.offset = r.offset; seg.length = r.length }
                seg.ticks = lengths[i]; seg.scale = timescale; seg.startTicks = periodStartTicks + t; seg.sequence = start + Int64(i)
                out.segments.append(seg)
                let (next, overflow) = t.addingReportingOverflow(lengths[i]); guard !overflow else { throw MediaError.malformed("a timeline value is out of range") }
                t = next
            }
            let (container, why) = containerFor(mime: ctx.mime, codecs: ctx.codecs, hasInit: out.initSegment != nil, wholeFile: try? urls.first?.attrs["media"].map { try MediaURL.resolve($0, against: ctx.base) })
            out.container = container; out.why = why
            if why == nil, container == .fragmentedMP4, out.initSegment == nil, out.segments.count > 1 { out.why = "The media segments need an initialization segment that the manifest does not list." }

        default:
            // SegmentBase, or a representation that is just a BaseURL: the whole resource is the media (an on-demand file with its own index). It is fetched as one piece.
            guard ctx.hasOwnBase else { out.why = "This representation says where its media is in a form that cannot be located (no address)."; return out }
            guard let length = ctx.periodDuration else { out.why = "A single-file representation needs the presentation duration, which the manifest does not give."; return out }
            var seg = MediaSegment(url: ctx.base.absoluteString, duration: length.seconds)
            seg.scale = 1000; seg.ticks = length.roundedTicks(scale: 1000); seg.startTicks = ctx.periodStart.roundedTicks(scale: 1000)
            out.segments = [seg]
            let (container, why) = containerFor(mime: ctx.mime, codecs: ctx.codecs, hasInit: false, wholeFile: ctx.base)
            out.container = container; out.why = why
        }
        return out
    }

    /// "30" or "30000/1001" to frames per second.
    static func rate(_ text: String) -> Double? {
        let parts = text.split(separator: "/").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count <= 2, let n = parts.first ?? nil, n > 0 else { return nil }
        let value = parts.count == 2 ? (parts[1].flatMap { $0 > 0 ? n / $0 : nil }) : n
        return value.flatMap { $0 > 0 && $0 <= 960 ? $0 : nil }
    }

    /// "PT1H2M3.5S" to seconds. Days and larger units are accepted for D only; anything odd gives nil.
    static func isoDuration(_ text: String?) -> Double? {
        guard let text, text.hasPrefix("P"), text.count < 64 else { return nil }
        var total = 0.0, number = "", inTime = false
        for ch in text.dropFirst() {
            switch ch {
            case "T": inTime = true
            case "0"..."9", ".": number.append(ch)
            case "D" where !inTime: guard let v = Double(number) else { return nil }; total += v * 86400; number = ""
            case "H" where inTime: guard let v = Double(number) else { return nil }; total += v * 3600; number = ""
            case "M" where inTime: guard let v = Double(number) else { return nil }; total += v * 60; number = ""
            case "S" where inTime: guard let v = Double(number) else { return nil }; total += v; number = ""
            default: return nil
            }
        }
        return number.isEmpty && total.isFinite && total <= 10 * 365 * 86_400 ? total : nil
    }

    /// The same, exactly: whole units as integers and the seconds with their decimal fraction. nil for anything odd.
    static func isoRational(_ text: String?) -> MediaRational? {
        guard let text, text.hasPrefix("P"), text.count < 64 else { return nil }
        var total = MediaRational.zero, number = "", inTime = false
        for ch in text.dropFirst() {
            switch ch {
            case "T": inTime = true
            case "0"..."9", ".": number.append(ch)
            case "D" where !inTime, "H" where inTime, "M" where inTime, "S" where inTime:
                guard let v = MediaRational.decimal(number) else { return nil }
                let unit: Int64 = ch == "D" ? 86400 : (ch == "H" ? 3600 : (ch == "M" ? 60 : 1))
                guard let scaled = v.scaled(by: unit), let sum = total + scaled else { return nil }
                total = sum; number = ""
            default: return nil
            }
        }
        guard number.isEmpty, total.seconds <= 10 * 365 * 86_400 else { return nil }
        return total
    }
}

enum MediaManifestReader {
    /// What kind of manifest this text is, decided from its content rather than its name.
    static func sniff(_ data: Data) -> MediaFormat? {
        let head = String(decoding: data.prefix(512), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if head.hasPrefix("#EXTM3U") { return .hls }
        if head.contains("<MPD") || (head.hasPrefix("<?xml") && String(decoding: data.prefix(4096), as: UTF8.self).contains("<MPD")) { return .dash }
        return nil
    }

    static func read(_ data: Data, from url: URL) throws -> MediaManifest {
        switch sniff(data) {
        case .hls: return try HLSParser.parse(String(decoding: data, as: UTF8.self), base: url)
        case .dash: return try DASHParser.parse(data, base: url)
        case nil: throw MediaError.notAManifest
        }
    }
}

// MARK: - What the codecs mean for the person

/// Names the codecs a manifest advertises and says whether the finished MP4 can be expected to hold them. This reads only what the manifest says; nothing is decoded or probed.
enum MediaCodecs {
    struct Description: Equatable { var video: String?; var audio: String?; var text: String?; var unknown: [String] }

    static func describe(_ codecs: String?) -> Description {
        var d = Description(unknown: [])
        for raw in (codecs ?? "").split(separator: ",") {
            let c = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if c.hasPrefix("avc1") || c.hasPrefix("avc3") { d.video = "H.264" }
            else if c.hasPrefix("hvc1") || c.hasPrefix("hev1") { d.video = "HEVC" }
            else if c.hasPrefix("dvh1") || c.hasPrefix("dvhe") { d.video = "Dolby Vision" }
            else if c.hasPrefix("av01") { d.video = "AV1" }
            else if c.hasPrefix("vp09") || c.hasPrefix("vp9") { d.video = "VP9" }
            else if c.hasPrefix("vp08") || c.hasPrefix("vp8") { d.video = "VP8" }
            else if c == "mp4a.40.2" { d.audio = "AAC-LC" }
            else if c == "mp4a.40.5" || c == "mp4a.40.29" { d.audio = "HE-AAC" }
            else if c.hasPrefix("mp4a.40") { d.audio = "AAC" }
            else if c == "ac-3" { d.audio = "Dolby Digital" }
            else if c == "ec-3" { d.audio = "Dolby Digital Plus" }
            else if c == "opus" { d.audio = "Opus" }
            else if c == "flac" { d.audio = "FLAC" }
            else if c == "wvtt" { d.text = "WebVTT" }
            else if c == "stpp" || c.hasPrefix("stpp.") { d.text = "TTML" }
            else if !c.isEmpty { d.unknown.append(c) }
        }
        return d
    }

    /// What the MP4 this app builds can be expected to hold (the system's own MP4 writer is used, without re-encoding). Nil means no concern; otherwise a short warning.
    static func outputWarning(_ stream: MediaStream) -> String? {
        let d = describe(stream.codecs)
        if let v = d.video, ["AV1", "VP9", "VP8"].contains(v) { return "\(v) video usually cannot be put in an MP4 without re-encoding, which this app does not do." }
        if let a = d.audio, ["Opus", "FLAC"].contains(a) { return "\(a) audio may not be accepted in an MP4." }
        if stream.container == .mpegTS { return "Saved as a .ts file, not an MP4." }
        return nil
    }

    /// One line for a list: "H.264 · AAC-LC".
    static func summary(_ stream: MediaStream) -> String? {
        let d = describe(stream.codecs)
        let parts = [d.video, d.audio, d.text].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Choices the person made once, applied as defaults. Only language preferences: a quality is never remembered (a stream's own choices differ).
struct MediaPreferences: Equatable, Sendable {
    var audioLanguage = ""          // "" means the stream's default
    var subtitleLanguage = ""       // "" means no subtitles
}

enum MediaChoiceProblem: Equatable {
    case nothingChosen, unsupportedStream(String), formatsCannotBeCombined, severalSubtitlesAlone
    var text: String {
        switch self {
        case .nothingChosen: "Choose at least one stream."
        case .unsupportedStream(let why): why
        case .formatsCannotBeCombined: "These streams use formats that cannot be combined into one file."
        case .severalSubtitlesAlone: "Choose one subtitle track when downloading subtitles alone."
        }
    }
}

extension MediaManifest {
    /// The best downloadable video that the output can hold, with the audio that goes with it. A stream whose codecs the MP4 cannot hold is chosen only if nothing else is.
    func defaultSelection(preferring prefs: MediaPreferences) -> MediaChoice {
        let usable = videos.filter(\.isDownloadable)
        let video = usable.first(where: { MediaCodecs.outputWarning($0) == nil }) ?? usable.first
        var audio: String?
        if let video, video.kind != .muxed {
            let pool = audios.filter(\.isDownloadable)
            func lang(_ s: MediaStream) -> Bool { MediaLanguage.matches(prefs.audioLanguage, s.language) }
            let sameGroup = pool.filter { $0.groupID != nil && $0.groupID == video.groupID }
            let ordered = (sameGroup.isEmpty ? pool : sameGroup)
            audio = (ordered.first(where: lang) ?? pool.first(where: lang) ?? ordered.first(where: \.isDefault) ?? ordered.first ?? pool.first(where: \.isDefault) ?? pool.first)?.id
        } else if video == nil {
            let pool = audios.filter(\.isDownloadable)
            audio = (pool.first(where: { MediaLanguage.matches(prefs.audioLanguage, $0.language) }) ?? pool.first(where: \.isDefault) ?? pool.first)?.id
        }
        var subs: [String] = []
        if let match = subtitles.first(where: { $0.isDownloadable && MediaLanguage.matches(prefs.subtitleLanguage, $0.language) }) { subs = [match.id] }
        return MediaChoice(video: video?.id, audio: audio, subtitles: subs)
    }

    /// Why a choice cannot be downloaded as it stands (empty when it can). Checked before anything is fetched.
    func problems(with choice: MediaChoice) -> [MediaChoiceProblem] {
        var out: [MediaChoiceProblem] = []
        if let unsupported { return [.unsupportedStream(unsupported)] }
        var picked: [MediaStream] = []
        if let v = choice.video { if let s = videos.first(where: { $0.id == v }) { picked.append(s) } }
        if picked.first?.kind != .muxed {
            for a in ([choice.audio].compactMap { $0 } + choice.extraAudios) { if let s = audios.first(where: { $0.id == a }), !picked.contains(where: { $0.id == s.id }) { picked.append(s) } }
        }
        let subs = choice.subtitles.compactMap { id in subtitles.first(where: { $0.id == id }) }
        if picked.isEmpty && subs.isEmpty { return [.nothingChosen] }
        for s in picked + subs { if let why = s.unsupported { out.append(.unsupportedStream(why)) } }
        if picked.isEmpty && subs.count > 1 { out.append(.severalSubtitlesAlone) }
        let containers = Set(picked.map(\.container).filter { $0 != .unknown })
        if containers.count > 1 || (containers == [.mpegTS] && picked.count > 1) { out.append(.formatsCannotBeCombined) }
        if choice.extraAudios.contains(where: { id in !audios.contains { $0.id == id } }) { out.append(.unsupportedStream("An audio track that was chosen is not in the list any more.")) }
        return out
    }
}

extension MediaManifest {
    /// A rough size from the advertised bitrates and the length, or nil when either is missing. Advertised, not measured: the real size differs.
    func estimatedBytes(for choice: MediaChoice) -> Int64? {
        guard let duration, duration.isFinite, duration > 0, duration <= 10 * 365 * 86_400 else { return nil }
        var bits = 0.0, any = false
        if let v = choice.video, let s = videos.first(where: { $0.id == v }), let b = s.bandwidth, b > 0 { bits += Double(b); any = true }
        // An HLS variant's BANDWIDTH already counts the audio that goes with it; a DASH representation's does not.
        if format == .dash, let a = choice.audio, let s = audios.first(where: { $0.id == a }), let b = s.bandwidth, b > 0 { bits += Double(b); any = true }
        if choice.video == nil, let a = choice.audio, let s = audios.first(where: { $0.id == a }), let b = s.bandwidth, b > 0 { bits += Double(b); any = true }
        for extra in choice.extraAudios { if let s = audios.first(where: { $0.id == extra }), let b = s.bandwidth, b > 0 { bits += Double(b) } }
        let bytes = bits * duration / 8
        return any && bytes.isFinite && bytes < 1e15 ? Int64(bytes) : nil
    }
}

enum MediaLanguage {
    private static let three: [String: String] = ["eng": "en", "spa": "es", "deu": "de", "ger": "de", "fra": "fr", "fre": "fr", "ita": "it", "por": "pt", "rus": "ru", "jpn": "ja", "zho": "zh", "chi": "zh", "kor": "ko", "ara": "ar", "hin": "hi", "nld": "nl", "dut": "nl", "swe": "sv", "pol": "pl", "tur": "tr"]
    /// The primary language of a tag ("en-US" and "eng" both give "en").
    static func primary(_ tag: String?) -> String? {
        guard let t = tag?.trimmingCharacters(in: .whitespaces).lowercased(), !t.isEmpty else { return nil }
        let first = t.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? t
        return three[first] ?? first
    }
    /// Whether a stream's language is the one asked for. An empty preference matches nothing.
    static func matches(_ preference: String, _ tag: String?) -> Bool {
        guard let want = primary(preference), let have = primary(tag) else { return false }
        return want == have
    }
}
