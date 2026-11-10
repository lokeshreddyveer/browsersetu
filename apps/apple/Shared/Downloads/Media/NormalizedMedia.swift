import Foundation
import AVFoundation

// The shared description of media that has actually been found, whoever found it: a page's player, a provider's documented API, a stream playlist, an account export, an approved connector.
// An extractor's job ends by producing one of these; everything after (the choices shown, the download, the merge, the conversion, the check of the result) is done here and by the existing
// engines, with no code that depends on which website it was. A watch-page address, a thumbnail or a page of metadata is not one of these: with no accessible media there is nothing to normalize.

struct NormalizedRepresentation: Equatable, Sendable {
    enum Role: String, Sendable { case video, audio, muxed }
    var role: Role
    var url: URL
    /// File ending of the container ("mp4", "m4a", "webm"…), from the address or the declared type.
    var container: String
    var mime: String? = nil
    var codecs: String? = nil
    var width: Int? = nil
    var height: Int? = nil
    var frameRate: Double? = nil
    var bitrate: Int? = nil
    var language: String? = nil
    /// The extractor's own ranking of this track's language (higher: preferred, e.g. the original soundtrack over a dub). Used only to choose between otherwise equal sound tracks.
    var languagePreference: Int? = nil
    var channels: Int? = nil
    var bytes: Int64? = nil
    var expires: Date? = nil
    /// The extractor's own id for this format; the format the person picked is carried by it all the way to the download.
    var formatID: String? = nil
    /// Identity of this format among the others: the extractor's id, else its address.
    var pickKey: String { formatID ?? url.absoluteString }
    var label: String { [VideoOptions.heightName(height), frameRate.map { "\(Int($0.rounded())) fps" }, container.uppercased()].compactMap { $0 }.joined(separator: " · ") }
}

enum NormalizedFailure: Error, Equatable, LocalizedError, Sendable {
    case noMedia, notMedia(String), unsafeAddress(String), expired, needsAuthorization(String)
    var errorDescription: String? {
        switch self {
        case .noMedia: "Source not resolved: the extractor returned no accessible media."
        case .notMedia(let w): "That is not a media file (\(w))."
        case .unsafeAddress(let h): "The address \(h) is not one a web page may make this browser fetch."
        case .expired: "The source link has expired."
        case .needsAuthorization(let s): "Authorization is required: \(s)"
        }
    }
}

struct NormalizedMediaSource: Equatable, Sendable, Identifiable {
    enum Shape: Equatable, Sendable { case tracks([NormalizedRepresentation]), manifest(URL) }
    var title: String
    var provider: MediaProviderID?
    var pageHost: String?
    var isPrivate: Bool
    var shape: Shape
    /// Whether the extractor can supply a fresh link when this one expires.
    var canRenew = false
    /// The version of this description. A reader that does not know a newer version refuses it rather than guessing.
    static let currentSchemaVersion = 1
    var schemaVersion = NormalizedMediaSource.currentSchemaVersion
    /// What produced it: this browser's own reading of a page, a provider's documented route, a program that was asked, or an approved service.
    var origin: Origin = .native
    /// How a fresh link is obtained when this one runs out.
    var renewal: Renewal = .none
    /// What the source needs from the person's side before it can be fetched.
    var authContext: AuthContext = .none
    enum Origin: Equatable, Sendable { case native, provider(MediaProviderID), extractor(tool: String, version: String), connector(String) }
    enum Renewal: Equatable, Sendable { case none, provider(MediaProviderID), rerunExtractor }
    enum AuthContext: Equatable, Sendable { case none, providerToken, needsSignIn }
    var id: String {
        switch shape {
        case .tracks(let r): Data(([provider?.rawValue ?? "-"] + r.map { "\($0.role.rawValue)|\($0.container)|\($0.height ?? 0)|\($0.bytes ?? 0)|\(LinkClassifier.normalizedKey($0.url))" }).joined(separator: "\n").utf8).sha256Hex
        case .manifest(let u): Data(("manifest|" + LinkClassifier.normalizedKey(u)).utf8).sha256Hex
        }
    }

    static let imageEndings: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "svg", "avif", "bmp"]
    /// Containers the system's media engine can join and read; WebM is carried as it is, never joined or converted.
    static let systemContainers: Set<String> = ["mp4", "m4v", "mov", "m4a"]

    /// Only accessible media passes: an http(s) address a page may reach, not a picture or a page, not expired.
    func validate(now: Date = Date(), allowLocal: Bool = false) throws {
        guard schemaVersion <= Self.currentSchemaVersion else { throw NormalizedFailure.notMedia("a description from a newer version of this app") }
        switch shape {
        case .manifest(let u): try Self.checkAddress(u, allowLocal: allowLocal)
        case .tracks(let list):
            guard !list.isEmpty else { throw NormalizedFailure.noMedia }
            for r in list {
                try Self.checkAddress(r.url, allowLocal: allowLocal)
                if Self.imageEndings.contains(r.container) || r.mime?.lowercased().hasPrefix("image/") == true { throw NormalizedFailure.notMedia("a picture") }
                if r.mime?.lowercased().hasPrefix("text/") == true { throw NormalizedFailure.notMedia("a web page") }
                if let e = r.expires, e <= now { throw NormalizedFailure.expired }
            }
        }
    }
    /// `allowLocal` is true only for an address the person typed themselves (origin .user); anything an extractor or a page supplied may not reach the local network.
    static func checkAddress(_ u: URL, allowLocal: Bool) throws {
        guard let s = u.scheme?.lowercased(), s == "http" || s == "https", let h = u.host, !h.isEmpty else { throw NormalizedFailure.unsafeAddress(u.host ?? "?") }
        guard allowLocal || HTTPRequestPolicy.pageMayReach(host: h) else { throw NormalizedFailure.unsafeAddress(h) }
    }

    // MARK: What can honestly be offered

    /// The choices for this source, from the one planner (kept as a convenience for callers that only need the descriptions).
    func options(encoders: (m4a: Bool, mp3: Bool) = (LocalEncoders.m4a, LocalEncoders.mp3)) -> [OutputOption] {
        DownloadPlanner.options(for: self, encoders: encoders).map(\.option)
    }
}

extension NormalizedMediaSource {
    /// The container: the address's ending if it is a media ending, else what the declared type says, else a plain default. (A file served from "/play.php" is still the MP4 its type says.)
    static func container(ext: String, mime: String?, audio: Bool) -> String {
        if ResourceClassifier.video.contains(ext) || ResourceClassifier.audio.contains(ext) { return ext }
        switch (mime ?? "").lowercased().split(separator: ";").first.map(String.init) ?? "" {
        case "video/mp4": return "mp4"; case "video/webm": return "webm"; case "video/quicktime": return "mov"; case "video/x-m4v": return "m4v"
        case "audio/mp4", "audio/x-m4a": return "m4a"; case "audio/mpeg": return "mp3"; case "audio/webm": return "webm"; case "audio/ogg": return "ogg"
        default: return audio ? "m4a" : "mp4"
        }
    }
}

// MARK: - From what the existing extractors produce

extension NormalizedMediaSource {
    /// A provider-authorized source (Vimeo's owner-enabled links, PeerTube's public files…).
    init?(authorized s: AuthorizedMediaSource, isPrivate: Bool) {
        switch s.type {
        case .hls, .dash:
            self.init(title: s.title ?? "", provider: s.provider, pageHost: nil, isPrivate: isPrivate, shape: .manifest(s.url), canRenew: s.canRefresh)
            origin = .provider(s.provider); authContext = .providerToken; if s.canRefresh { renewal = .provider(s.provider) }
        case .directFile:
            let ext = s.url.pathExtension.lowercased()
            let c = ext.isEmpty ? ((s.contentType ?? "").contains("webm") ? "webm" : "mp4") : ext
            let audioOnly = (s.contentType ?? "").hasPrefix("audio/") || ResourceClassifier.audio.contains(c)
            self.init(title: s.title ?? "", provider: s.provider, pageHost: nil, isPrivate: isPrivate,
                      shape: .tracks([NormalizedRepresentation(role: audioOnly ? .audio : .muxed, url: s.url, container: c, mime: s.contentType, width: s.width, height: s.height, bytes: s.bytes, expires: s.expiresAt)]), canRenew: s.canRefresh)
            origin = .provider(s.provider); authContext = .providerToken; if s.canRefresh { renewal = .provider(s.provider) }
        case .accountArchive: return nil               // an archive of many items is not one media source
        }
    }

    /// A discovered media candidate the page's own player exposed (a file or a stream the media picker lists).
    init?(candidate c: MediaCandidate) {
        guard let text = c.url, let u = URL(string: text) else { return nil }
        let ext = u.pathExtension.lowercased()
        switch c.kind {
        case .hls, .dash: self.init(title: c.name, provider: nil, pageHost: c.pageHost, isPrivate: c.isPrivate, shape: .manifest(u))
        case .directVideo, .directAudio:
            self.init(title: c.name, provider: nil, pageHost: c.pageHost, isPrivate: c.isPrivate,
                      shape: .tracks([NormalizedRepresentation(role: c.kind == .directAudio ? .audio : .muxed, url: u, container: Self.container(ext: ext, mime: c.mime, audio: c.kind == .directAudio), mime: c.mime, width: c.videoWidth, height: c.videoHeight)]))
        default: return nil
        }
    }
}
