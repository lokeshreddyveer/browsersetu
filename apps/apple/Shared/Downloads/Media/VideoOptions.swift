import Foundation
import AVFoundation
import AudioToolbox

// The download-first layer over the existing media engines: what a person is told about one video before choosing, and which outputs the machine can really produce. Nothing here fetches
// anything or makes a file; the choices it lists are carried out by the existing stream picker (MediaAddModel), the HTTP engine and the assembler.

/// What this Mac can write. Probed, not assumed: an option is offered only if the system reports it can be made.
enum LocalEncoders {
    /// Audio-only MP4 (AAC in M4A), which the assembler writes without re-encoding when the source already holds AAC.
    static var m4a: Bool { AVAssetExportSession.allExportPresets().contains(AVAssetExportPresetAppleM4A) }

    /// Whether the system has an encoder for a codec (AudioToolbox lists the encoders it ships). macOS ships an MP3 decoder but no MP3 encoder, so MP3 comes from the bundled LAME library.
    static func canEncode(_ format: AudioFormatID) -> Bool {
        var size: UInt32 = 0
        guard AudioFormatGetPropertyInfo(kAudioFormatProperty_EncodeFormatIDs, 0, nil, &size) == noErr, size > 0 else { return false }
        var ids = [AudioFormatID](repeating: 0, count: Int(size) / MemoryLayout<AudioFormatID>.size)
        guard AudioFormatGetProperty(kAudioFormatProperty_EncodeFormatIDs, 0, nil, &size, &ids) == noErr else { return false }
        return ids.contains(format)
    }
    /// MP3: the system's own encoder if it ever has one, else the bundled LAME library (Mac build).
    static var mp3: Bool { canEncode(kAudioFormatMPEGLayer3) || MP3Encoder.isAvailable }
}

/// Where a video is, from "the page lists it" to "it can be fetched". Separate from whether a file was ever made.
enum VideoResolutionState: Equatable, Sendable {
    case discovered                         // listed by the page; nothing has been looked at
    case analyzing
    case formatsAvailable(Int)              // how many outputs can be made
    case authorizationRequired(String)
    case unavailable(String)

    var label: String {
        switch self {
        case .discovered: "Not analyzed yet"
        case .analyzing: "Analyzing…"
        case .formatsAvailable(let n): n == 1 ? "1 option" : "\(n) options"
        case .authorizationRequired: "Authorization required"
        case .unavailable: "Unavailable"
        }
    }
    var detail: String? {
        switch self { case .authorizationRequired(let s), .unavailable(let s): s; default: nil }
    }
}

/// One thing a person can choose to save, and whether it can be made.
struct OutputOption: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case original, video, audioOriginal, audioM4A, audioMP3 }
    var kind: Kind
    var title: String
    /// "Source quality" or "Converted": whether the pixels or samples are the source's own.
    var provenance: String
    var detail: String?
    /// nil: it can be made. Otherwise the reason it cannot, shown instead of hiding the option.
    var unavailableReason: String?
    /// The source's own id for the format this uses (the extractor's format id, or a stream rendition's id), unchanged from discovery to download.
    var formatID: String? = nil
    var id: String { kind.rawValue + "|" + title }
    var isAvailable: Bool { unavailableReason == nil }
}

enum VideoOptions {
    /// "4K" only for a source that really is that tall; nothing is ever named above the pixels it has.
    static func heightName(_ h: Int?) -> String? {
        guard let h, h > 0 else { return nil }
        switch h { case 2160...: return "4K (\(h)p)"; case 1440...: return "1440p"; case 1080...: return "1080p"; case 720...: return "720p"; case 480...: return "480p"; default: return "\(h)p" }
    }

    /// The list for a candidate: the same planner every other list uses (a stream with a read manifest lists its real renditions).
    static func options(for c: MediaCandidate, encoders: (m4a: Bool, mp3: Bool) = (LocalEncoders.m4a, LocalEncoders.mp3)) -> [OutputOption] {
        guard let source = NormalizedMediaSource(candidate: c) else { return [] }
        if c.kind.isStream && c.manifest == nil { return [] }
        return DownloadPlanner.options(for: source, manifest: c.manifest, encoders: encoders).map(\.option)
    }

    /// The state a candidate is in, derived from what is known and never from a domain name alone.
    static func state(for c: MediaCandidate) -> VideoResolutionState {
        switch c.state {
        case .inspecting: return .analyzing
        case .authorizationRequired(let why): return .authorizationRequired(why)
        case .unsupported(let why), .failed(let why): return .unavailable(why)
        case .expired: return .unavailable("The link has expired. Find the media again.")
        case .stale: return .unavailable("The page has changed since this was found.")
        case .discovered, .recognized, .inspected: break
        }
        if !c.canOpen { return .unavailable(ProviderPolicy.note(for: c) ?? "This cannot be downloaded.") }
        let n = options(for: c).filter(\.isAvailable).count
        return (c.kind.isStream && c.manifest == nil) || c.kind == .unknown || n == 0 ? .discovered : .formatsAvailable(n)
    }
}
