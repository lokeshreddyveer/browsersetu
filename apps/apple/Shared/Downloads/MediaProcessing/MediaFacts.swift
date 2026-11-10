import Foundation
import AVFoundation
import CoreMedia
import CryptoKit

// What a local audio or video file is, read from the file itself.
//
// The container is found from the file's first bytes, never from its name; the tracks and codecs come from AVFoundation (the system's own decoder table), so a codec the
// system cannot open is reported as "not readable", never guessed at. A value the file does not state is `nil`: a missing frame rate is not 0 fps.

struct MediaTrackFacts: Equatable, Sendable, Identifiable {
    enum Kind: String, Sendable { case video, audio, subtitle, other }
    var id: Int32
    var kind: Kind
    /// Short name of the codec ("H.264", "AAC"), or the four letters when the system has no friendly name.
    var codec: String?
    var fourCC: String?
    var language: String?
    var durationSeconds: Double?
    var bitsPerSecond: Double?
    var width: Int?
    var height: Int?
    var frameRate: Double?
    var channels: Int?
    var sampleRate: Double?
    /// Clockwise degrees the picture must be turned for display: 90, 180 or 270; nil when the track states no turn (or an identity one).
    var rotation: Int?
    var isEnabled: Bool
    /// Whether the system can decode (or, for text, read) this track.
    var isDecodable: Bool
    var colorDescription: String?
}

struct MediaFacts: Equatable, Sendable {
    var fileSize: Int64
    /// From the first bytes: "MP4", "QuickTime", "MP3", "WAV" … nil when not recognised.
    var container: String?
    var durationSeconds: Double?
    var tracks: [MediaTrackFacts]
    var creationDate: Date?
    var title: String?
    var isPlayable: Bool
    var isProtected: Bool

    var video: [MediaTrackFacts] { tracks.filter { $0.kind == .video } }
    var audio: [MediaTrackFacts] { tracks.filter { $0.kind == .audio } }
    var subtitles: [MediaTrackFacts] { tracks.filter { $0.kind == .subtitle } }
    /// Picture size as it is shown (a turned picture swaps width and height).
    var displaySize: (width: Int, height: Int)? {
        guard let v = video.first, let w = v.width, let h = v.height else { return nil }
        return (v.rotation == 90 || v.rotation == 270) ? (h, w) : (w, h)
    }
}

enum MediaFactsError: Error, Equatable, LocalizedError {
    case notReadable(String), tooLarge, missing, notAFile
    var errorDescription: String? {
        switch self {
        case .notReadable(let why): return "This file could not be read as audio or video (\(why))."
        case .tooLarge: return "The file's details are unreasonably large, so it was not opened."
        case .missing: return "The file is not there."
        case .notAFile: return "This is not a plain file."
        }
    }
}

enum MediaFactsReader {
    /// Longest the system is given to read a file's tracks.
    static let timeout: TimeInterval = 20
    static let maxTracks = 64

    /// The container named by the first bytes of the file. Nothing is run or decoded.
    static func sniffContainer(_ head: Data) -> String? {
        let b = [UInt8](head.prefix(64))
        func has(_ s: String, at i: Int) -> Bool { let c = Array(s.utf8); return b.count >= i + c.count && Array(b[i..<i + c.count]) == c }
        if has("ftyp", at: 4) {
            let brand = b.count >= 12 ? String(decoding: b[8..<12], as: UTF8.self) : ""
            if brand.hasPrefix("qt") { return "QuickTime" }
            if brand.hasPrefix("M4A") || brand.hasPrefix("M4B") { return "MPEG-4 audio" }
            if brand.hasPrefix("heic") || brand.hasPrefix("heix") || brand.hasPrefix("mif1") || brand.hasPrefix("avif") { return "HEIF image" }
            if brand.hasPrefix("3gp") { return "3GPP" }
            return "MP4"
        }
        if has("moov", at: 4) || has("mdat", at: 4) || has("wide", at: 4) || has("free", at: 4) { return "QuickTime" }
        if has("RIFF", at: 0), has("WAVE", at: 8) { return "WAV" }
        if has("RIFF", at: 0), has("AVI ", at: 8) { return "AVI" }
        if has("FORM", at: 0), has("AIFF", at: 8) || has("AIFC", at: 8) { return "AIFF" }
        if has("caff", at: 0) { return "Core Audio" }
        if has("OggS", at: 0) { return "Ogg" }
        if has("fLaC", at: 0) { return "FLAC" }
        if has("ID3", at: 0) { return "MP3" }
        if b.count >= 4, b[0] == 0x1A, b[1] == 0x45, b[2] == 0xDF, b[3] == 0xA3 { return "Matroska/WebM" }
        if has("#EXTM3U", at: 0) { return "HLS playlist" }
        if b.count >= 2, b[0] == 0xFF, (b[1] & 0xF6) == 0xF0 { return "AAC (ADTS)" }
        if b.count >= 2, b[0] == 0xFF, (b[1] & 0xE0) == 0xE0, (b[1] & 0x06) != 0 { return "MP3" }
        if (b.count >= 4 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) || (b.count >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) || has("GIF8", at: 0) { return "Image" }
        return nil
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF), UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        let s = String(decoding: bytes, as: UTF8.self)
        return s.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F } ? s : String(format: "0x%08X", code)
    }

    static func codecName(_ code: FourCharCode) -> String {
        switch fourCC(code) {
        case "avc1", "avc3": return "H.264"
        case "hvc1", "hev1": return "HEVC"
        case "av01": return "AV1"
        case "vp09": return "VP9"
        case "mp4v": return "MPEG-4 Visual"
        case "apcn", "apch", "apcs", "apco", "ap4h", "ap4x": return "Apple ProRes"
        case "jpeg", "mjpa", "mjpb": return "Motion JPEG"
        case "aac ", "mp4a": return "AAC"
        case "alac": return "Apple Lossless"
        case ".mp3", "mp3 ": return "MP3"
        case "ac-3": return "Dolby Digital"
        case "ec-3": return "Dolby Digital Plus"
        case "lpcm": return "PCM"
        case "fLaC": return "FLAC"
        case "opus": return "Opus"
        case "tx3g": return "Timed text (3GPP)"
        case "wvtt": return "WebVTT"
        case "c608", "c708": return "Closed captions"
        case "text": return "Timed text (QuickTime)"
        default: return fourCC(code)
        }
    }

    static func rotation(of t: CGAffineTransform) -> Int? {
        if t.isIdentity { return nil }
        let degrees = Int((atan2(Double(t.b), Double(t.a)) * 180 / .pi).rounded())
        let normalized = ((degrees % 360) + 360) % 360
        return [90, 180, 270].contains(normalized) ? normalized : nil
    }

    /// Reads a local file. Bounded in time (`timeout`) and in the number of tracks, and ends early when the calling task is cancelled.
    static func read(_ url: URL) async throws -> MediaFacts {
        guard FileManager.default.fileExists(atPath: url.path) else { throw MediaFactsError.missing }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else { throw MediaFactsError.notAFile }
        let size = Int64(values?.fileSize ?? 0)
        let head: Data = {
            guard let h = try? FileHandle(forReadingFrom: url) else { return Data() }
            defer { try? h.close() }
            return (try? h.read(upToCount: 512)) ?? Data()
        }()
        let container = sniffContainer(head)
        // The system's loader is not trusted to react to cancellation, so the answer is a race between its result, the caller's cancellation and a time limit; whichever comes first wins.
        let race = FactsRace()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<MediaFacts, Error>) in
                guard race.start(c) else { return }
                let work = Task.detached { do { race.finish(.success(try await load(url, size: size, container: container))) } catch { race.finish(.failure(error)) } }
                race.attach(work)
                Task.detached { try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)); race.finish(.failure(MediaFactsError.notReadable("it took too long"))) }
            }
        } onCancel: { race.cancel() }
    }

    private final class FactsRace: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<MediaFacts, Error>?
        private var cancelled = false, finished = false
        private var work: Task<Void, Never>?
        /// False when the caller was cancelled before it began (the continuation is then already answered).
        func start(_ c: CheckedContinuation<MediaFacts, Error>) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if cancelled { c.resume(throwing: CancellationError()); finished = true; return false }
            continuation = c; return true
        }
        func attach(_ task: Task<Void, Never>) { lock.lock(); let stop = cancelled || finished; if !stop { work = task }; lock.unlock(); if stop { task.cancel() } }
        func finish(_ result: Result<MediaFacts, Error>) {
            lock.lock()
            guard !finished, let c = continuation else { lock.unlock(); return }
            finished = true; continuation = nil; let w = work; lock.unlock()
            w?.cancel()
            c.resume(with: result)
        }
        func cancel() {
            lock.lock(); cancelled = true; lock.unlock()
            finish(.failure(CancellationError()))
        }
    }

    private static func load(_ url: URL, size: Int64, container: String?) async throws -> MediaFacts {
        let asset = AVURLAsset(url: MediaAlias.url(for: url), options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks: [AVAssetTrack], duration: CMTime, playable: Bool, protected: Bool
        do {
            tracks = try await asset.load(.tracks)
            duration = try await asset.load(.duration)
            playable = try await asset.load(.isPlayable)
            protected = (try? await asset.load(.hasProtectedContent)) ?? false
        } catch is CancellationError { throw CancellationError() }
        catch { throw MediaFactsError.notReadable(error.localizedDescription) }
        guard tracks.count <= maxTracks else { throw MediaFactsError.tooLarge }
        var out: [MediaTrackFacts] = []
        for track in tracks {
            try Task.checkCancellation()
            out.append(await describe(track))
        }
        var created: Date?, title: String?
        if let items = try? await asset.load(.commonMetadata) {
            for item in items where item.commonKey == .commonKeyTitle && title == nil { title = try? await item.load(.stringValue) }
        }
        if let date = try? await asset.load(.creationDate) { created = try? await date.load(.dateValue) }
        let seconds: Double? = duration.isNumeric && duration.seconds.isFinite && duration.seconds >= 0 ? duration.seconds : nil
        return MediaFacts(fileSize: size, container: container, durationSeconds: seconds, tracks: out, creationDate: created, title: title.map { String($0.prefix(200)) }, isPlayable: playable, isProtected: protected)
    }

    private static func describe(_ track: AVAssetTrack) async -> MediaTrackFacts {
        let kind: MediaTrackFacts.Kind
        switch track.mediaType {
        case .video: kind = .video
        case .audio: kind = .audio
        case .subtitle, .text, .closedCaption: kind = .subtitle
        default: kind = .other
        }
        let descriptions = (try? await track.load(.formatDescriptions)) ?? []
        let desc = descriptions.first
        let sub: FourCharCode? = desc.map { CMFormatDescriptionGetMediaSubType($0) }
        let range = try? await track.load(.timeRange)
        let rate = try? await track.load(.estimatedDataRate)
        let language = try? await track.load(.languageCode)
        let enabled = (try? await track.load(.isEnabled)) ?? true
        let decodable = (try? await track.load(.isDecodable)) ?? false
        var facts = MediaTrackFacts(id: track.trackID, kind: kind, codec: sub.map(codecName), fourCC: sub.map(fourCC),
                                    language: language.flatMap { $0 == "und" ? nil : $0 },
                                    durationSeconds: range.flatMap { $0.duration.isNumeric && $0.duration.seconds.isFinite ? $0.duration.seconds : nil },
                                    bitsPerSecond: rate.flatMap { $0 > 0 && $0.isFinite ? Double($0) : nil },
                                    width: nil, height: nil, frameRate: nil, channels: nil, sampleRate: nil, rotation: nil, isEnabled: enabled, isDecodable: decodable, colorDescription: nil)
        if kind == .video {
            if let size = try? await track.load(.naturalSize), size.width > 0, size.height > 0, size.width < 100_000, size.height < 100_000 { facts.width = Int(size.width); facts.height = Int(size.height) }
            if let fps = try? await track.load(.nominalFrameRate), fps > 0, fps.isFinite { facts.frameRate = Double(fps) }
            if let t = try? await track.load(.preferredTransform) { facts.rotation = rotation(of: t) }
            if let d = desc, let ext = CMFormatDescriptionGetExtensions(d) as? [String: Any] {
                let p = ext[kCVImageBufferColorPrimariesKey as String] as? String, f = ext[kCVImageBufferTransferFunctionKey as String] as? String
                let parts = [p.map { "primaries \($0)" }, f.map { "transfer \($0)" }].compactMap { $0 }
                if !parts.isEmpty { facts.colorDescription = parts.joined(separator: ", ") }
            }
        }
        if kind == .audio, let d = desc, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(d)?.pointee {
            if asbd.mChannelsPerFrame > 0 { facts.channels = Int(asbd.mChannelsPerFrame) }
            if asbd.mSampleRate > 0 { facts.sampleRate = asbd.mSampleRate }
        }
        return facts
    }
}

// MARK: - Files named wrongly

/// AVFoundation chooses its reader from the file's extension, so a perfectly good MP4 saved as "video" or "movie.bin" "cannot be opened". The contents decide here: when the name does
/// not match what the first bytes say, the system is given a link, with the right extension, in a private temporary folder. The link is only ever read through; the file is not renamed,
/// copied or touched.
enum MediaAlias {
    static let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BrowserSetuMediaAliases-\(getuid())", isDirectory: true)

    private static func extensions(for container: String) -> (accepted: Set<String>, use: String)? {
        switch container {
        case "MP4": return (["mp4", "m4v"], "mp4")
        case "QuickTime": return (["mov", "qt"], "mov")
        case "MPEG-4 audio": return (["m4a", "m4b"], "m4a")
        case "3GPP": return (["3gp", "3g2"], "3gp")
        case "WAV": return (["wav", "wave"], "wav")
        case "AIFF": return (["aif", "aiff", "aifc"], "aiff")
        case "Core Audio": return (["caf"], "caf")
        case "MP3": return (["mp3"], "mp3")
        case "AAC (ADTS)": return (["aac", "adts"], "aac")
        default: return nil
        }
    }

    static func url(for url: URL) -> URL {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return url }
        let head = (try? handle.read(upToCount: 512)) ?? Data()
        try? handle.close()
        guard let container = MediaFactsReader.sniffContainer(head), let (accepted, use) = extensions(for: container), !accepted.contains(url.pathExtension.lowercased()) else { return url }
        let key = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        let link = folder.appendingPathComponent("\(key).\(use)")
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if (try? fm.destinationOfSymbolicLink(atPath: link.path)) == url.path { return link }
        try? fm.removeItem(at: link)
        do { try fm.createSymbolicLink(at: link, withDestinationURL: url); return link } catch { return url }
    }

    static func sweep() { try? FileManager.default.removeItem(at: folder) }
}
