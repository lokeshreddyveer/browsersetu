import Foundation

// Phase 16: one place that says what a piece of text or an address is. It reads; it never connects, never creates a task, and never decides to download. The parsers it relies on
// for torrents and eD2k are the ones the previews already use.

enum LinkKind: Equatable, Sendable {
    /// An http(s) address whose path looks like a file (an archive, a disk image, a video…). Looking like one proves nothing: it is only "probably a file".
    case httpResource
    /// An http(s) address to a `.torrent` file. Whether it really holds torrent metadata is decided by the torrent parser when it is opened.
    case torrentURL
    case magnet
    case ed2kFile
    case localTorrent
    /// An http(s) address to an HLS (.m3u8) or MPEG-DASH (.mpd) playlist. Reading it is a separate step the person starts; whether it holds a stream this can download is only known then.
    case streamManifest
    /// An http(s) address with no file-like ending: a page, or possibly a download endpoint. Not known either way.
    case webpage
    /// Understood, but not something this can handle (its reason is shown).
    case unsupported(String)
    /// Not a usable link at all (its reason is shown).
    case invalid(String)

    var isPeerToPeer: Bool { self == .magnet || self == .ed2kFile || self == .torrentURL || self == .localTorrent }
    var isSupported: Bool {
        switch self { case .unsupported, .invalid: false; default: true }
    }
    var label: String {
        switch self {
        case .httpResource: "File"
        case .torrentURL: "Torrent file"
        case .magnet: "Magnet"
        case .ed2kFile: "eD2k"
        case .localTorrent: "Torrent file (this Mac)"
        case .streamManifest: "Stream playlist"
        case .webpage: "Web address"
        case .unsupported: "Unsupported"
        case .invalid: "Not a link"
        }
    }
}

/// How it came to be in the collection. Only the person's own acts make a link something they may add; what a program or an extension suggested is shown but never added from here.
enum LinkProvenance: String, Codable, Sendable {
    case pasted, clipboard, page, navigation, extensionSuggestion, automationProposal
    var mayBeAddedFromHere: Bool { self != .extensionSuggestion && self != .automationProposal }
}

struct LinkMetadata: Equatable, Sendable {
    var filename: String?
    var size: Int64?
    var acceptsRanges: Bool?
}

/// What is known about whether the thing is really there. "Not checked" is the honest default: syntax alone proves nothing.
enum LinkCheck: Equatable, Sendable {
    case notChecked
    case checking
    case checked(LinkMetadata)
    /// The server (or this window) does not allow a look; not the same as "unavailable".
    case notCheckable(String)
    case failed(String)
}

struct DetectedLink: Identifiable, Equatable, Sendable {
    /// The link's identity: one value per thing, however it was spelled. Used to drop duplicates.
    let id: String
    /// The text as found. It may carry a signed query; it is used to add the link and is never shown, logged or exported.
    let original: String
    /// What may be shown and written down: no user name, password, query or fragment.
    let display: String
    let kind: LinkKind
    var name: String
    let host: String?
    let provenance: LinkProvenance
    let profile: String
    let isPrivate: Bool
    var check: LinkCheck = .notChecked
    var group: String?
    /// A name chosen for the file by whoever found the link (a podcast episode's title), used instead of the server's or the address's. Nil for an ordinary link.
    var suggestedFilename: String?
    /// Small facts kept with the download in the list (feed title, publication date, episode), bounded by the ledger's own limits.
    var metadata: [String: String] = [:]

    /// The person may add it from the collection: it is understood, it came from their own act, and (for peer-to-peer) the preview will still ask before anything is contacted.
    var canAdd: Bool { kind.isSupported && provenance.mayBeAddedFromHere }
    var needsApproval: Bool { kind.isPeerToPeer }
    var protocolLabel: String { kind.label }
}

enum LinkClassifier {
    /// Longest text looked at for one link.
    static let maxLength = 8192

    /// File-name endings that suggest a downloadable file. A hint for sorting, never a claim.
    static let fileExtensions: Set<String> = [
        "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "dmg", "pkg", "iso", "img", "exe", "msi", "deb", "rpm", "apk", "ipa", "appimage",
        "pdf", "epub", "mobi", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "csv", "txt", "rtf", "odt",
        "mp3", "m4a", "flac", "wav", "ogg", "aac", "mp4", "m4v", "mkv", "mov", "avi", "webm", "wmv", "flv", "ts",
        "jpg", "jpeg", "png", "gif", "webp", "avif", "heic", "tiff", "tif", "bmp", "svg", "psd",
    ]

    struct Result: Equatable, Sendable {
        var kind: LinkKind
        var identity: String
        var name: String
        var host: String?
        var display: String
    }

    /// The text the rest of the app understands. An eD2k link's bars may arrive escaped (%7C) from a web page; the eD2k parser, and the preview, want the bars.
    static func canonicalText(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.lowercased().hasPrefix("ed2k:") ? t.replacingOccurrences(of: "%7C", with: "|", options: .caseInsensitive) : t
    }

    static func classify(_ raw: String) -> Result {
        let text = canonicalText(raw)
        func invalid(_ why: String) -> Result { Result(kind: .invalid(why), identity: "invalid:" + Data(text.utf8).sha256Hex.prefix(16), name: "Not a link", host: nil, display: DiagnosticRedactor.text(String(text.prefix(60))) ?? "") }
        guard !text.isEmpty else { return invalid("Nothing to read.") }
        guard text.count <= maxLength else { return invalid("The text is too long to be a link.") }
        guard !text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || $0 == " " }) else { return invalid("A link has no spaces or control characters.") }
        guard let colon = text.firstIndex(of: ":") else { return invalid("It does not start with a scheme such as https:") }
        let scheme = text[..<colon].lowercased()

        switch scheme {
        case "magnet":
            do {
                let m = try MagnetLink.parse(text)
                return Result(kind: .magnet, identity: "btih:" + m.infoHashHex, name: m.displayName ?? "Magnet link", host: nil, display: "magnet:?xt=urn:btih:" + m.infoHashHex)
            } catch MagnetLink.Failure.unsupportedVersion2Only {
                return Result(kind: .unsupported("A version 2 only torrent"), identity: "magnet-v2:" + Data(text.utf8).sha256Hex.prefix(16), name: "Magnet link", host: nil, display: "magnet:?…")
            } catch { return invalid((error as? LocalizedError)?.errorDescription ?? "Not a valid magnet link.") }
        case "ed2k":
            do {
                switch try ED2KLink.parse(text) {
                case .file(let f):
                    return Result(kind: .ed2kFile, identity: "ed2k:\(f.hashHex):\(f.size)", name: f.name, host: nil, display: f.canonical)
                case .server, .serverList:
                    return Result(kind: .unsupported("A server link: recognised, never fetched"), identity: "ed2k-server:" + Data(text.utf8).sha256Hex.prefix(16), name: "eD2k server", host: nil, display: "ed2k://|server|…")
                }
            } catch { return invalid((error as? LocalizedError)?.errorDescription ?? "Not a valid eD2k link.") }
        case "http", "https":
            guard let url = URL(string: text), let host = url.host, !host.isEmpty else { return invalid("The web address has no website name.") }
            let key = normalizedKey(url)
            let last = url.lastPathComponent
            let ext = (last as NSString).pathExtension.lowercased()
            let display = DiagnosticRedactor.url(text) ?? "\(scheme)://\(host)"
            let shown = last.removingPercentEncoding ?? last
            // A name that is really a token in the path (a signed link) is not shown.
            let name = last.isEmpty || last == "/" ? host : (DiagnosticRedactor.text(shown, limit: 120) == shown && !(DiagnosticRedactor.url("https://h/" + last) ?? "").hasSuffix("/…") ? shown : host)
            if ext == "torrent" { return Result(kind: .torrentURL, identity: key, name: name, host: host.lowercased(), display: display) }
            if ext == "m3u8" || ext == "mpd" { return Result(kind: .streamManifest, identity: key, name: name, host: host.lowercased(), display: display) }
            if fileExtensions.contains(ext) { return Result(kind: .httpResource, identity: key, name: name, host: host.lowercased(), display: display) }
            return Result(kind: .webpage, identity: key, name: name, host: host.lowercased(), display: display)
        case "file":
            guard let url = URL(string: text), url.isFileURL else { return invalid("Not a usable file address.") }
            if url.pathExtension.lowercased() == "torrent" { return Result(kind: .localTorrent, identity: "file:" + url.standardizedFileURL.path, name: url.lastPathComponent, host: nil, display: url.lastPathComponent) }
            return Result(kind: .unsupported("Only .torrent files on this Mac can be opened"), identity: "file:" + url.standardizedFileURL.path, name: url.lastPathComponent, host: nil, display: url.lastPathComponent)
        default:
            // javascript:, data:, blob:, ftp: and every other scheme: recognised as a scheme, not something to act on.
            let unsafe: Set<String> = ["javascript", "data", "blob", "vbscript"]
            let why = unsafe.contains(scheme) ? "A \(scheme): address is never opened as a download" : "\(scheme): addresses are not supported"
            return Result(kind: .unsupported(why), identity: "scheme:" + scheme + ":" + Data(text.utf8).sha256Hex.prefix(16), name: String(scheme), host: nil, display: "\(scheme):…")
        }
    }

    /// One spelling for one address. Case of the scheme and host, a default port, a fragment and the case of percent-escapes do not make a different address; the path and the query otherwise
    /// stay exactly as given, because a different query can be a different file (and a signed one is a different link).
    static func normalizedKey(_ url: URL) -> String {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        c.scheme = c.scheme?.lowercased()
        c.host = c.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if (c.scheme == "http" && c.port == 80) || (c.scheme == "https" && c.port == 443) { c.port = nil }
        c.fragment = nil
        // A different user name or password is a different request, so it is part of the identity (never shown).
        let credential = [c.user, c.password].compactMap { $0 }.joined(separator: ":")
        c.user = nil; c.password = nil
        var path = c.percentEncodedPath
        if path.isEmpty { path = "/" }
        c.percentEncodedPath = normalizeEscapes(path)
        if let q = c.percentEncodedQuery { c.percentEncodedQuery = normalizeEscapes(q) }
        let base = c.string ?? url.absoluteString
        return credential.isEmpty ? base : base + "#as:" + Data(credential.utf8).sha256Hex.prefix(12)
    }

    /// The identity of a resource without any account in it. The download list keeps addresses without their user name and password, so a stored task can only be compared by this key.
    static func resourceKey(_ url: URL) -> String {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return normalizedKey(url) }
        c.user = nil; c.password = nil
        return c.url.map(normalizedKey) ?? normalizedKey(url)
    }

    static func hasCredentials(_ url: URL) -> Bool {
        let c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return !(c?.user ?? "").isEmpty || !(c?.password ?? "").isEmpty
    }

    /// The keys of the downloads that are still going (private ones are never listed).
    static func liveKeys(_ records: some Sequence<DownloadTaskRecord>) -> Set<String> {
        Set(records.filter { !$0.state.isFinal && !$0.isPrivate }.compactMap { $0.source.url.flatMap(URL.init(string:)).map(resourceKey) })
    }

    /// Whether this address is already being downloaded. An address with an account in it is never called a duplicate: the stored task no longer says which account it used, so
    /// "the same file for another account" could not be told from "the same download twice", and wrongly skipping a link is worse than a second try.
    static func isLive(_ url: URL, in live: Set<String>) -> Bool { !hasCredentials(url) && live.contains(resourceKey(url)) }

    /// %7e and %7E are the same; %41 is "A" (an unreserved letter that never needed escaping); everything else keeps its escape, upper-cased.
    static func normalizeEscapes(_ s: String) -> String {
        let bytes = Array(s.utf8)
        var out = [UInt8](); var i = 0
        func hex(_ b: UInt8) -> UInt8? { switch b { case 48...57: b - 48; case 65...70: b - 55; case 97...102: b - 87; default: nil } }
        while i < bytes.count {
            if bytes[i] == 0x25, i + 2 < bytes.count, let h = hex(bytes[i + 1]), let l = hex(bytes[i + 2]) {
                let v = h * 16 + l
                let unreserved = (v >= 0x30 && v <= 0x39) || (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A) || v == 0x2D || v == 0x2E || v == 0x5F || v == 0x7E
                if unreserved { out.append(v) } else { out.append(0x25); out.append(contentsOf: String(format: "%02X", v).utf8) }
                i += 3
            } else { out.append(bytes[i]); i += 1 }
        }
        return String(decoding: out, as: UTF8.self)
    }
}

enum LinkExtractor {
    static let maxInputBytes = 1_000_000
    static let maxCandidates = 2000

    private static let pattern = try! NSRegularExpression(pattern: #"(?i)(?:https?|ftp)://[^\s<>"'`]+|magnet:\?[^\s<>"'`]+|ed2k://[^\s<>"'`]+|file:///[^\s<>"'`]+"#)

    /// Every thing in `text` that looks like a link, in order, without repeats, trimmed of the punctuation prose puts after a link. Reads at most a megabyte and returns at most
    /// `maxCandidates`; it does not follow, open or check any of them.
    static func candidates(in text: String, limit: Int = maxCandidates) -> (links: [String], truncated: Bool) {
        let bounded = String(decoding: text.utf8.prefix(maxInputBytes), as: UTF8.self)
        let ns = bounded as NSString
        var seen = Set<String>(), out: [String] = []
        var truncated = bounded.utf8.count < text.utf8.count
        for m in pattern.matches(in: bounded, range: NSRange(location: 0, length: ns.length)) {
            var s = ns.substring(with: m.range)
            while let last = s.last, ".,;:!?)]}>\u{201D}\u{2019}".contains(last) { s.removeLast() }
            guard !s.isEmpty, seen.insert(s).inserted else { continue }
            if out.count >= limit { truncated = true; break }
            out.append(s)
        }
        return (out, truncated)
    }
}
