import Foundation

/// The one place that decides what a download is called, from everything known about it. It builds on `DownloadFilename` (Content-Disposition parsing, sanitizing, reserved and unsafe names,
/// truncation) and `FileNaming` (free-name choice), and adds the part that was spread across callers: which of several candidate names wins, and which ending the file gets.
///
/// Precedence depends on what is being saved.
///  - An ordinary file keeps the name it was published with: the person's own name, then the server's Content-Disposition, then the page's `download` attribute, then the address's last part;
///    titles (embedded metadata, the page's title) only stand in when none of those says anything useful.
///  - Extracted media is called by what it is: the person's name, then the extractor's real media title, then Content-Disposition, `download` attribute, the media's embedded title, the page title,
///    and last the address (a stream's address is usually `master.m3u8` or `index.m3u8`, which names nothing).
/// A generic name ("download", "index", "master", "videoplayback"…) loses to any specific candidate. The ending always comes from the actual output format when it is known, never from an
/// address suffix (`.php`, `.m3u8`, `.mpd`), and never doubles.
enum FilenameResolver {
    enum Context: Sendable { case ordinaryFile, extractedMedia }
    enum Source: String, Sendable { case user, mediaTitle, contentDisposition, downloadAttribute, embeddedTitle, pageTitle, url, fallback }

    struct Inputs: Sendable {
        var user: String?
        var mediaTitle: String?
        var contentDisposition: String?
        var downloadAttribute: String?
        var embeddedTitle: String?
        var pageTitle: String?
        var url: URL?
        var mimeType: String?
        init(user: String? = nil, mediaTitle: String? = nil, contentDisposition: String? = nil, downloadAttribute: String? = nil, embeddedTitle: String? = nil, pageTitle: String? = nil, url: URL? = nil, mimeType: String? = nil) {
            self.user = user; self.mediaTitle = mediaTitle; self.contentDisposition = contentDisposition; self.downloadAttribute = downloadAttribute
            self.embeddedTitle = embeddedTitle; self.pageTitle = pageTitle; self.url = url; self.mimeType = mimeType
        }
    }

    struct Resolved: Equatable, Sendable {
        var name: String
        var source: Source
        /// Looks like a document but ends in something that runs; saved as named, and the person is told (as for any download).
        var suspicious: Bool
    }

    /// Stems that name nothing: what a player or server calls the thing it serves. Any specific candidate beats these.
    static let genericStems: Set<String> = ["download", "downloads", "file", "files", "video", "videos", "audio", "media", "movie", "clip", "index", "default", "main", "master", "playlist", "manifest",
                                            "stream", "chunklist", "media_0", "play", "player", "get", "watch", "embed", "view", "videoplayback", "output", "content", "data", "untitled", "blob", "init", "segment",
                                            "hls", "dash", "m3u8", "mpd"]

    /// A name for a stream from its address alone (the add-download form's starting name): the file name, else the folder it is in, when they say something; else where it came from. No dots in the
    /// fallback (a dot in a name would be taken for an ending: "127.0.0.1" must not become "127.0.0").
    static func streamName(from url: URL) -> String {
        let file = (url.lastPathComponent as NSString).deletingPathExtension
        let folder = url.deletingLastPathComponent().lastPathComponent
        for candidate in [file, folder] where !candidate.isEmpty && candidate != "/" && !genericStems.contains(candidate.lowercased()) {
            if let name = DownloadFilename.sanitize(candidate), !name.isEmpty { return name }
        }
        if let host = url.host, !host.isEmpty { return DownloadFilename.sanitize("Stream from " + host.replacingOccurrences(of: ".", with: "-")) ?? "Stream" }
        return "Stream"
    }
    /// Endings that describe how a media file travels, not what it is called: removed from a name before the real ending is put on (so `clip.m3u8` becomes `clip.mp4`, never `clip.m3u8.mp4`).
    static let mediaEndings: Set<String> = ["mp4", "m4v", "m4a", "m4s", "mov", "mkv", "webm", "mka", "ogg", "ogv", "oga", "opus", "mp3", "aac", "flac", "wav", "aiff", "ts", "m2ts", "flv", "3gp", "avi", "wmv", "wma",
                                            "m3u8", "m3u", "mpd", "ism", "f4m"]
    /// Endings of the page that serves a file (`watch.php`): removed only from a name taken from an ADDRESS, never from a title or a name the person typed ("Learn.PHP" keeps its last word).
    static let webEndings: Set<String> = ["php", "asp", "aspx", "jsp", "cgi", "html", "htm"]

    static func resolve(_ inputs: Inputs, context: Context, outputExtension: String? = nil) -> Resolved {
        var ordered: [(Source, String?)] = []
        let cd = inputs.contentDisposition.flatMap(DownloadFilename.filename(fromContentDisposition:))
        let urlName = inputs.url.flatMap(basename(of:))
        switch context {
        case .extractedMedia:
            ordered = [(.user, inputs.user), (.mediaTitle, inputs.mediaTitle), (.contentDisposition, cd), (.downloadAttribute, inputs.downloadAttribute),
                       (.embeddedTitle, inputs.embeddedTitle), (.pageTitle, inputs.pageTitle), (.url, urlName)]
        case .ordinaryFile:
            ordered = [(.user, inputs.user), (.contentDisposition, cd), (.downloadAttribute, inputs.downloadAttribute), (.url, urlName),
                       (.mediaTitle, inputs.mediaTitle), (.embeddedTitle, inputs.embeddedTitle), (.pageTitle, inputs.pageTitle)]
        }
        // The first candidate that is usable and says something; failing that the first usable one; failing that "download".
        var firstUsable: (Source, String)?
        var chosen: (Source, String)?
        for (source, raw) in ordered {
            guard let raw, let clean = DownloadFilename.sanitize(raw) else { continue }
            if firstUsable == nil { firstUsable = (source, clean) }
            if source == .user || !isGeneric(clean) { chosen = (source, clean); break }
        }
        let pick = chosen ?? firstUsable ?? (.fallback, "download")
        var name = pick.1
        if pick.0 == .url, outputExtension != nil {          // an address's page ending says nothing about the file that is made
            let ns = name as NSString
            if webEndings.contains(ns.pathExtension.lowercased()), !ns.deletingPathExtension.isEmpty { name = ns.deletingPathExtension }
        }
        if let ext = outputExtension { name = applying(extension: ext, to: name) }
        else if pick.0 == .url || pick.0 == .fallback, let mime = inputs.mimeType { name = addingExtension(forMIME: mime, to: name) }
        return Resolved(name: DownloadFilename.truncated(name), source: pick.0, suspicious: DownloadFilename.isSuspicious(name))
    }

    /// `name` with its ending set to `ext`: a media or playlist ending already on it is replaced (never doubled), any other dot stays part of the title ("Lecture 1.5" → "Lecture 1.5.mp4").
    static func applying(extension ext: String, to name: String) -> String {
        let want = ext.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard !want.isEmpty, want.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return name }
        var stem = name
        // Repeated endings ("clip.mp4.mp4", "x.m3u8.mp4") collapse to one.
        while true {
            let ns = stem as NSString
            let e = ns.pathExtension.lowercased()
            guard !e.isEmpty, mediaEndings.contains(e) || e == want, ns.deletingPathExtension.isEmpty == false else { break }
            stem = ns.deletingPathExtension
        }
        return stem + "." + want
    }

    /// The name without a trailing media/playlist ending: what callers pass on when they add the real ending themselves.
    static func stem(of name: String) -> String {
        var stem = name
        while true {
            let ns = stem as NSString
            let e = ns.pathExtension.lowercased()
            guard !e.isEmpty, mediaEndings.contains(e), !ns.deletingPathExtension.isEmpty else { break }
            stem = ns.deletingPathExtension
        }
        return stem
    }

    /// A name that says nothing: exactly one of the generic words, with at most a small counter after it ("video (3)", "master_2"). Numbers on their own ("1984", "000123.pdf") and a word with a real
    /// number ("Video 2024") are specific names.
    static func isGeneric(_ name: String) -> Bool {
        var stem = ((name as NSString).deletingPathExtension).lowercased()
        if genericStems.contains(stem) { return true }
        // One trailing counter of one or two digits, with its separator and brackets ("video (3)", "master_2").
        if stem.hasSuffix(")") { stem.removeLast() }
        var digits = 0
        while let last = stem.last, last.isASCII, last.isNumber, digits < 3 { stem.removeLast(); digits += 1 }
        guard (1...2).contains(digits) else { return false }
        while let last = stem.last, last == "(" || last == " " || last == "_" || last == "-" { stem.removeLast() }
        return genericStems.contains(stem)
    }

    /// The last part of an address, decoded, ignoring the query and fragment (`/a/b/Report%202026.pdf?token=1` → `Report 2026.pdf`).
    static func basename(of url: URL) -> String? {
        let last = url.pathComponents.last(where: { $0 != "/" }) ?? ""
        let decoded = last.removingPercentEncoding ?? last
        return decoded.isEmpty ? nil : decoded
    }

    private static func addingExtension(forMIME mime: String, to name: String) -> String {
        DownloadFilename.derive(contentDisposition: nil, url: URL(string: "https://x.invalid/" + (name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "download")), mimeType: mime).name
    }

    /// A free name in `dir` for `name`, in the form downloads use everywhere ("Title (1).mp4").
    static func freeName(_ name: String, in dir: URL, taken: Set<String> = []) -> String {
        FileNaming.unique(name, style: .parenthesized) { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) || taken.contains($0) }
    }
}
