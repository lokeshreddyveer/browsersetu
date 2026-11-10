import Foundation

// DX-08: subtitles and captions. Only what the stream provides is written; nothing is generated. A text track is saved as a WebVTT file beside the video (the system's MP4 export can carry
// timed text only when it is already in the source in a form it reads, so the segments' WebVTT/TTML is never embedded; it is exported with its language in the file name instead).

enum WebVTT {
    /// `hh:mm:ss.mmm` or `mm:ss.mmm` to seconds. nil if it is not a timestamp.
    static func seconds(_ text: String) -> Double? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        guard let last = Double(parts[parts.count - 1].replacingOccurrences(of: ",", with: ".")), last >= 0, last < 60 || parts.count == 1 else { return nil }
        guard let m = Int(parts[parts.count - 2]), m >= 0, m < 60 || parts.count == 2 else { return nil }
        let h = parts.count == 3 ? Int(parts[0]) : 0
        guard let h, h >= 0 else { return nil }
        return Double(h) * 3600 + Double(m) * 60 + last
    }

    static func timestamp(_ seconds: Double) -> String {
        let total = seconds.isFinite ? min(max(0, seconds), 1e7) : 0          // a hostile value cannot trap the conversion
        let ms = Int((total * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }

    /// The `X-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:00.000` header: how much to add to this segment's cue times to put them on the media clock, in seconds.
    static func timestampMapOffset(in header: [Substring]) -> Double? {
        guard let line = header.first(where: { $0.hasPrefix("X-TIMESTAMP-MAP=") }) else { return nil }
        var mpegts: Double?, local: Double?
        for item in line.dropFirst("X-TIMESTAMP-MAP=".count).split(separator: ",", maxSplits: 1) {
            if item.hasPrefix("MPEGTS:") { mpegts = Double(item.dropFirst(7)) }
            else if item.hasPrefix("LOCAL:") { local = seconds(String(item.dropFirst(6))) }
        }
        guard let mpegts, let local, mpegts >= 0, mpegts <= 1e13, local.isFinite else { return nil }
        return mpegts / 90_000 - local
    }

    /// One cue line shifted: `start --> end settings`.
    static func shifted(cueLine line: String, by delta: Double) -> String {
        guard delta != 0, let arrow = line.range(of: " --> ") else { return line }
        let startText = String(line[..<arrow.lowerBound]).trimmingCharacters(in: .whitespaces)
        let rest = line[arrow.upperBound...]
        let endText = rest.prefix(while: { !$0.isWhitespace })
        let settings = rest.dropFirst(endText.count)
        guard let s = seconds(startText), let e = seconds(String(endText)) else { return line }
        return "\(timestamp(s + delta)) --> \(timestamp(e + delta))\(settings)"
    }

    /// Joins the segments of a segmented WebVTT track into one file: one header; every segment's cues put on one clock (by its timestamp map, relative to the first segment that has
    /// one); a cue that HLS repeats in each segment it overlaps written once.
    static func join(_ segments: [Data]) -> (text: String, notes: [String]) {
        var notes: [String] = []
        var seen = Set<String>()
        var blocks: [String] = []
        var baseline: Double?
        var mapped = 0
        for (n, data) in segments.enumerated() {
            guard var raw = String(data: data, encoding: .utf8) else { notes.append("Subtitle segment \(n + 1) is not UTF-8 text and was skipped."); continue }
            if raw.hasPrefix("\u{FEFF}") { raw.removeFirst() }
            let text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            guard text.hasPrefix("WEBVTT") else { notes.append("Subtitle segment \(n + 1) does not start with WEBVTT and was skipped."); continue }
            let parts = text.components(separatedBy: "\n\n")
            let header = parts.first?.split(separator: "\n", omittingEmptySubsequences: true) ?? []
            var delta = 0.0
            if let offset = timestampMapOffset(in: Array(header)) {
                mapped += 1
                if baseline == nil { baseline = offset }
                delta = offset - (baseline ?? offset)
            }
            for block in parts.dropFirst() {
                let trimmed = block.trimmingCharacters(in: .newlines)
                guard !trimmed.isEmpty else { continue }
                var lines = trimmed.components(separatedBy: "\n")
                if let at = lines.firstIndex(where: { $0.contains(" --> ") }) {
                    lines[at] = shifted(cueLine: lines[at], by: delta)
                } else if trimmed.hasPrefix("NOTE") { continue }
                let joined = lines.joined(separator: "\n")
                if seen.insert(joined).inserted { blocks.append(joined) }
            }
        }
        if mapped > 0 && mapped < segments.count { notes.append("Some subtitle segments have no timestamp map; their times are used as written.") }
        return ("WEBVTT\n\n" + blocks.joined(separator: "\n\n") + (blocks.isEmpty ? "" : "\n"), notes)
    }
}

/// TTML / IMSC text to WebVTT. Text, line breaks and timing are kept; styling, regions and positioning are not, and the result says so.
enum TTMLConverter {
    struct Cue { var start: Double; var end: Double; var text: String }

    private final class Reader: NSObject, XMLParserDelegate {
        var cues: [Cue] = []
        var failure: String?
        var frameRate = 30.0, tickRate: Double?
        var styled = false
        private var depth = 0, count = 0
        private var current: (begin: String?, end: String?, dur: String?, text: String)?
        private var pDepth = 0
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes a: [String: String]) {
            count += 1; depth += 1
            if count > MediaLimits.maxXMLElements || depth > MediaLimits.maxXMLDepth { failure = "the document is too large or too deeply nested"; parser.abortParsing(); return }
            let local = name.split(separator: ":").last.map(String.init) ?? name
            if a.keys.contains(where: { $0.hasPrefix("tts:") || $0.hasPrefix("itts:") }) { styled = true }
            switch local {
            case "tt":
                if let r = a["ttp:frameRate"].flatMap({ Double($0) }), r > 0, r <= 240 { frameRate = r }
                if let r = a["ttp:tickRate"].flatMap({ Double($0) }), r > 0 { tickRate = r }
            case "p": if current == nil { current = (a["begin"], a["end"], a["dur"], ""); pDepth = depth }
            case "br": current?.text += "\n"
            case "region", "style": styled = true
            default: break
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if current != nil, (current?.text.count ?? 0) < 4096 { current?.text += string } }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
            defer { depth -= 1 }
            guard (name.split(separator: ":").last.map(String.init) ?? name) == "p", depth == pDepth, let p = current else { return }
            current = nil
            guard let begin = p.begin.flatMap({ time($0) }) else { return }
            var end = p.end.flatMap { time($0) }
            if end == nil, let dur = p.dur.flatMap({ time($0) }) { end = begin + dur }
            guard let end, end > begin else { return }
            let lines = p.text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n").map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).joined(separator: " ") }
            let text = lines.filter { !$0.isEmpty }.joined(separator: "\n").replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            if !text.isEmpty { cues.append(Cue(start: begin, end: end, text: text)) }
            if cues.count > 200_000 { failure = "there are too many cues"; parser.abortParsing() }
        }
        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { if failure == nil { failure = parseError.localizedDescription } }

        /// clock-time (`hh:mm:ss.fff` or `hh:mm:ss:ff`) or offset-time (`12.5s`, `1200ms`, `30f`, `900000t`).
        func time(_ text: String) -> Double? {
            let t = text.trimmingCharacters(in: .whitespaces)
            if let v = timeUnchecked(t), v.isFinite, v <= 1e7 { return v }
            return nil
        }
        func timeUnchecked(_ t: String) -> Double? {
            if t.contains(":") {
                let p = t.split(separator: ":", omittingEmptySubsequences: false)
                guard p.count == 3 || p.count == 4, let h = Double(p[0]), let m = Double(p[1]), h >= 0, m >= 0, m < 60 else { return nil }
                guard let s = Double(p[2]), s >= 0, s < 61 else { return nil }
                let frames = p.count == 4 ? (Double(p[3]) ?? -1) : 0
                guard frames >= 0 else { return nil }
                return h * 3600 + m * 60 + s + frames / frameRate
            }
            for (suffix, scale) in [("ms", 0.001), ("h", 3600.0), ("m", 60.0), ("s", 1.0)] where t.hasSuffix(suffix) {
                guard let v = Double(t.dropLast(suffix.count)), v >= 0 else { return nil }
                return v * scale
            }
            if t.hasSuffix("f"), let v = Double(t.dropLast()), v >= 0 { return v / frameRate }
            if t.hasSuffix("t"), let v = Double(t.dropLast()), v >= 0, let rate = tickRate { return v / rate }
            return nil
        }
    }

    static func toWebVTT(_ data: Data) throws -> (text: String, notes: [String]) {
        guard data.count <= 20 * 1024 * 1024 else { throw MediaError.tooLarge }
        let head = String(decoding: data.prefix(4096), as: UTF8.self).lowercased()
        guard !head.contains("<!doctype"), !head.contains("<!entity") else { throw MediaError.unsupported("The subtitle file contains a document type declaration, which is refused for safety.") }
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        let reader = Reader(); parser.delegate = reader
        _ = parser.parse()
        if let f = reader.failure { throw MediaError.malformed("the subtitle file is not valid TTML (\(f))") }
        var notes: [String] = []
        if reader.styled { notes.append("Styling and positioning in the TTML subtitles were not kept.") }
        if reader.cues.isEmpty { notes.append("The TTML subtitle track has no cues.") }
        var out = "WEBVTT\n\n"
        for c in reader.cues.sorted(by: { $0.start < $1.start }) { out += "\(WebVTT.timestamp(c.start)) --> \(WebVTT.timestamp(c.end))\n\(c.text)\n\n" }
        return (out, notes)
    }
}

/// File names for subtitle files saved beside the video.
enum MediaSubtitleNaming {
    /// `Movie.te.vtt`, `Movie.en.forced.vtt`, `Movie.en.sdh.vtt`: the language first, then what kind it is.
    static func suffix(for s: MediaStream) -> String {
        var parts: [String] = []
        if let l = s.language.flatMap({ DownloadFilename.sanitize($0) }), !l.isEmpty { parts.append(l) } else { parts.append("subtitles") }
        if s.forced == true || s.role == "forced-subtitle" { parts.append("forced") }
        if s.accessibility == true { parts.append("sdh") }
        return parts.joined(separator: ".")
    }
}
