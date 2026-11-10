import Foundation
import AVFoundation
import CoreMedia

// Subtitles: reading SRT and WebVTT text, writing WebVTT, and taking the text subtitle tracks AVFoundation can read out of a file.
//
// Text only. Nothing is rendered or executed here; markup is reduced to the few tags WebVTT itself defines. Translation, transcription and picture-based subtitles (DVD, Blu-ray)
// are out of scope and are refused with that reason.

struct SubtitleCue: Equatable, Sendable {
    var start: Double
    var end: Double
    var text: String
}

enum SubtitleError: Error, Equatable, LocalizedError {
    case tooLarge, noCues, unsupported(String), badEncoding
    var errorDescription: String? {
        switch self {
        case .tooLarge: return "The subtitle file is too large to read safely."
        case .noCues: return "No subtitles were found in it."
        case .unsupported(let why): return why
        case .badEncoding: return "The subtitle file is not readable text."
        }
    }
}

enum SubtitleText {
    static let maxBytes = 8 * 1024 * 1024
    static let maxCues = 100_000
    static let maxCueCharacters = 4_000

    /// Text from a subtitle file: UTF-8 (with or without a byte-order mark) or UTF-16 with a mark. Anything else is refused rather than guessed.
    static func decode(_ data: Data) throws -> String {
        guard data.count <= maxBytes else { throw SubtitleError.tooLarge }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(decoding: data.dropFirst(3), as: UTF8.self) }
        if data.starts(with: [0xFF, 0xFE]) { guard let s = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) else { throw SubtitleError.badEncoding }; return s }
        if data.starts(with: [0xFE, 0xFF]) { guard let s = String(data: data.dropFirst(2), encoding: .utf16BigEndian) else { throw SubtitleError.badEncoding }; return s }
        guard let s = String(data: data, encoding: .utf8) else { throw SubtitleError.badEncoding }
        return s
    }

    /// "00:01:02,500" or "1:02.500" or "01:02:03.5" to seconds; nil when it is not a time.
    static func parseTime(_ raw: String) -> Double? {
        let s = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }
        var seconds = 0.0
        for (i, p) in parts.enumerated() {
            let isLast = i == parts.count - 1
            if isLast {
                guard let v = Double(p), v >= 0, v < 60 else { return nil }
                seconds = seconds * 60 + v
            } else {
                guard let v = Int(p), v >= 0, v < 100_000 else { return nil }
                seconds = seconds * 60 + Double(v)
            }
        }
        return seconds.isFinite ? seconds : nil
    }

    static func formatTime(_ seconds: Double) -> String {
        let clamped = seconds.isFinite ? min(max(0, seconds), 99.0 * 3600) : 0
        let ms = Int((clamped * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }

    /// Tags WebVTT defines for cue text.
    private static let allowedTags: Set<String> = ["b", "i", "u", "c", "v", "lang", "ruby", "rt"]

    /// Keeps `<b> <i> <u> <c> <v> <lang> <ruby> <rt>` (and their closers), turns a stray `<` or `&` into an entity, drops every other tag (so `<script>`, `<font>` or an SSA `{\\an8}` override never reach the output).
    static func sanitize(_ input: String) -> String {
        // Bounded first: the work below is proportional to the length, and a cue is never longer than the limit.
        let text = String(input.prefix(maxCueCharacters))
        var out = "", i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == "<" {
                // A tag starts with a letter (or a slash and a letter) straight after the "<", and ends at the next ">" with no other "<" or line break between. Anything else is a literal "<".
                let after = text.index(after: i)
                let startsLikeTag: Bool = {
                    guard after < text.endIndex else { return false }
                    if text[after].isLetter { return true }
                    if text[after] == "/", text.index(after: after) < text.endIndex { return text[text.index(after: after)].isLetter }
                    return false
                }()
                if startsLikeTag, let close = text[after...].prefix(80).firstIndex(of: ">"), !text[after..<close].contains("<"), !text[after..<close].contains("\n") {
                    let inner = String(text[after..<close])
                    let name = inner.drop(while: { $0 == "/" }).prefix(while: { $0.isLetter }).lowercased()
                    if allowedTags.contains(name) {
                        // Only the forms WebVTT defines: the name, a class suffix, or a voice/language annotation; never attributes.
                        let closing = inner.hasPrefix("/")
                        let safeRest = inner.drop(while: { $0 == "/" }).dropFirst(name.count).prefix(60).filter { $0.isLetter || $0.isNumber || " .-_".contains($0) }
                        let annotated = !closing && (name == "v" || name == "lang" || name == "c")
                        let rest = annotated ? String(safeRest.filter { name == "c" ? ($0 != " ") : true }) : ""
                        out += "<" + (closing ? "/" : "") + name + rest + ">"
                    }
                    i = text.index(after: close); continue
                }
                out += "&lt;"
            } else if c == "&" {
                let rest = text[i...].prefix(10)
                if let semi = rest.firstIndex(of: ";"), ["&amp;", "&lt;", "&gt;", "&nbsp;", "&lrm;", "&rlm;"].contains(String(rest[rest.startIndex...semi])) { out.append(c) } else { out += "&amp;" }
            } else if c == "{", let close = text[i...].prefix(40).firstIndex(of: "}"), text[text.index(after: i)...].first == "\\" {
                i = text.index(after: close); continue         // an SSA override such as {\an8}
            } else { out.append(c) }
            i = text.index(after: i)
        }
        var collapsed = String(out.prefix(maxCueCharacters)).replacingOccurrences(of: "-->", with: "->")
        while collapsed.contains("\n\n") { collapsed = collapsed.replacingOccurrences(of: "\n\n", with: "\n") }     // a blank line would end the cue in WebVTT
        return collapsed
    }

    /// Cues from SRT or WebVTT text. Order is kept; a cue whose end is not after its start is dropped.
    static func parse(_ text: String, offset: Double = 0) throws -> [SubtitleCue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [SubtitleCue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let at = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let halves = lines[at].components(separatedBy: "-->")
            guard halves.count == 2, let start = parseTime(halves[0]),
                  let end = parseTime(String(halves[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "")) else { continue }
            let body = lines[(at + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let shifted = (start + offset, end + offset)
            guard shifted.1 > shifted.0, shifted.0 >= 0 || shifted.1 > 0, !body.isEmpty else { continue }
            cues.append(SubtitleCue(start: max(0, shifted.0), end: shifted.1, text: sanitize(body)))
            if cues.count > maxCues { throw SubtitleError.tooLarge }
        }
        guard !cues.isEmpty else { throw SubtitleError.noCues }
        return cues
    }

    static func webVTT(_ cues: [SubtitleCue], language: String? = nil) -> String {
        var out = "WEBVTT\n"
        if let language, !language.isEmpty, language.range(of: "^[A-Za-z0-9-]{1,16}$", options: .regularExpression) != nil { out += "Language: \(language)\n" }
        out += "\n"
        for cue in cues { out += "\(formatTime(cue.start)) --> \(formatTime(cue.end))\n\(cue.text)\n\n" }
        return out
    }

    /// A 3GPP timed-text sample: a big-endian 16-bit length, then that many bytes of UTF-8 (or UTF-16 with a mark). Style boxes after the text are ignored.
    static func text(fromTimedTextSample bytes: Data) -> String? {
        guard bytes.count >= 2 else { return nil }
        let length = Int(bytes[bytes.startIndex]) << 8 | Int(bytes[bytes.startIndex + 1])
        guard length > 0, 2 + length <= bytes.count else { return nil }
        let body = bytes.subdata(in: (bytes.startIndex + 2)..<(bytes.startIndex + 2 + length))
        if body.starts(with: [0xFE, 0xFF]) { return String(data: body.dropFirst(2), encoding: .utf16BigEndian) }
        if body.starts(with: [0xFF, 0xFE]) { return String(data: body.dropFirst(2), encoding: .utf16LittleEndian) }
        return String(data: body, encoding: .utf8)
    }

    /// A safe name for the subtitle file: the video's name, the language, `.vtt`.
    static func fileName(base: String, language: String?) -> String {
        let cleanBase = DownloadFilename.sanitize(base) ?? "subtitles"
        let tag = language.flatMap { $0.range(of: "^[A-Za-z0-9-]{1,16}$", options: .regularExpression) != nil ? $0 : nil }
        return cleanBase + (tag.map { ".\($0)" } ?? "") + ".vtt"
    }

    /// Reads a text subtitle track of a local file as cues. Only 3GPP timed text (`tx3g`) and QuickTime text are read; anything else is refused with the reason.
    static func cues(fromTrack trackID: Int32, of url: URL) async throws -> (cues: [SubtitleCue], language: String?) {
        let asset = AVURLAsset(url: MediaAlias.url(for: url))
        let tracks = try await asset.load(.tracks)
        guard let track = tracks.first(where: { $0.trackID == trackID }) else { throw SubtitleError.unsupported("That subtitle track is not in the file.") }
        guard track.mediaType == .subtitle || track.mediaType == .text else { throw SubtitleError.unsupported("That track is not a subtitle track.") }
        let descriptions = try await track.load(.formatDescriptions)
        guard let desc = descriptions.first else { throw SubtitleError.unsupported("The subtitle format is not stated.") }
        let sub = CMFormatDescriptionGetMediaSubType(desc)
        guard sub == 0x74783367 /* tx3g */ || sub == 0x74657874 /* text */ else {
            throw SubtitleError.unsupported("\(MediaFactsReader.codecName(sub)) subtitles cannot be extracted: only plain timed-text tracks can.")
        }
        let language = try await track.load(.languageCode)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { throw SubtitleError.unsupported("The system cannot read this subtitle track.") }
        reader.add(output)
        guard reader.startReading() else { throw SubtitleError.unsupported(reader.error?.localizedDescription ?? "The system cannot read this subtitle track.") }
        var cues: [SubtitleCue] = []
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0, length <= 64 * 1024 else { continue }
            var data = Data(count: length)
            let status = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            guard status == kCMBlockBufferNoErr, let raw = text(fromTimedTextSample: data) else { continue }
            let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds, duration = CMSampleBufferGetDuration(sample).seconds
            guard start.isFinite, duration.isFinite, duration > 0 else { continue }
            let body = sanitize(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            if !body.isEmpty { cues.append(SubtitleCue(start: max(0, start), end: start + duration, text: body)) }
            if cues.count > maxCues { throw SubtitleError.tooLarge }
        }
        if reader.status == .failed { throw SubtitleError.unsupported(reader.error?.localizedDescription ?? "The subtitle track could not be read.") }
        guard !cues.isEmpty else { throw SubtitleError.noCues }
        return (cues, language.flatMap { $0 == "und" ? nil : $0 })
    }
}
