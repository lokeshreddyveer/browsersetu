import Foundation

// Automatic download detection: what kinds of downloadable things a page links to, counted per kind for the toolbar and listed in a popover. This file is the pure part (a model and a classifier);
// it reads no page and fetches nothing. The page is read by the existing link scan, video and audio come from the existing media observer, and every download goes through the existing engines.

enum ResourceCategory: String, CaseIterable, Identifiable, Sendable {
    case video, audio, image, document, code, config, archive, torrent, installer, data, feed, cloud, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .video: "Video"; case .audio: "Audio"; case .image: "Images"; case .document: "Documents"; case .code: "Source code"; case .config: "Configuration files"
        case .archive: "Archives"; case .torrent: "Torrents and magnet links"; case .installer: "Applications and installers"; case .data: "Data files"; case .feed: "Feeds"
        case .cloud: "Cloud downloads"; case .other: "Other files"
        }
    }
    var symbol: String {
        switch self {
        case .video: "play.rectangle.on.rectangle"; case .audio: "waveform"; case .image: "photo.on.rectangle"; case .document: "doc.text"; case .code: "chevron.left.forwardslash.chevron.right"
        case .config: "gearshape"; case .archive: "archivebox"; case .torrent: "link.circle"; case .installer: "shippingbox"; case .data: "cylinder.split.1x2"; case .feed: "dot.radiowaves.up.forward"
        case .cloud: "icloud.and.arrow.down"; case .other: "doc"
        }
    }
    /// Video and audio are opened in the media picker, which keeps quality, language and subtitle choices; everything else is listed in a popover.
    var usesMediaPicker: Bool { self == .video || self == .audio }
}

enum ResourceConfidence: Int, Comparable, Sendable { case low = 0, medium, high
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    var label: String { self == .high ? "Likely" : (self == .medium ? "Probable" : "Uncertain") }
}

enum ResourceMethod: String, Sendable { case link, downloadAttribute, magnet, media }

/// What the page offered, as far as is known. `confirmed` is only ever set from a real response (a size and type that came back), never from an address.
enum ResourceAvailability: Equatable, Sendable { case detected, confirmed(size: Int64?, mime: String?), notAFile(String) }

struct DetectedResource: Identifiable, Equatable, Sendable {
    /// Normalised address (or info hash). Two different files never share one; the same file linked twice is one.
    let id: String
    var category: ResourceCategory
    var url: String
    var filename: String
    var ext: String
    var pageHost: String?
    var frameOrigin: String?
    var method: ResourceMethod
    var confidence: ResourceConfidence
    var availability: ResourceAvailability = .detected
    /// The address carries a credential or token: it is used, never shown or exported.
    var signed: Bool = false
    /// A video entry the page links to (a watch page, reel or short), not a media file: it has to be opened and resolved before there is anything to download.
    var provider: MediaProviderID? = nil
    var needsResolution: Bool { provider != nil || isManifest }
    /// A stream playlist: fetching it gives text, not the video. It goes to the stream route (the link collection), never to a plain download.
    var isManifest: Bool { ext == "m3u8" || ext == "mpd" }
    var host: String? { URL(string: url)?.host }
    var isPeerToPeer: Bool { category == .torrent }
    var sizeText: String? { if case .confirmed(let s?, _) = availability { return DownloadStats.bytes(s) }; return nil }
}

enum ResourceClassifier {
    // MARK: Tables

    static let video: Set<String> = ["mp4", "m4v", "mkv", "mov", "avi", "webm", "wmv", "flv", "mpg", "mpeg", "3gp", "ogv", "m3u8", "mpd"]
    static let audio: Set<String> = ["mp3", "m4a", "flac", "wav", "ogg", "oga", "aac", "opus", "aiff", "aif", "wma", "mid", "midi"]
    static let image: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "svg", "avif", "ico", "psd", "dng", "cr2", "nef", "arw"]
    static let document: Set<String> = ["pdf", "epub", "mobi", "azw3", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp", "rtf", "txt", "pages", "numbers", "key", "tex", "djvu"]
    static let code: Set<String> = ["html", "htm", "css", "scss", "sass", "less", "js", "mjs", "cjs", "jsx", "tsx", "ts", "php", "py", "java", "swift", "kt", "kts", "rs", "go", "c", "h", "cpp", "cc", "cxx", "hpp",
                                    "cs", "rb", "sh", "bash", "zsh", "ps1", "psm1", "sql", "lua", "pl", "r", "scala", "dart", "vue", "svelte", "ipynb", "md", "markdown", "m", "mm", "gradle"]
    static let config: Set<String> = ["json", "xml", "yaml", "yml", "toml", "ini", "cfg", "conf", "env", "properties", "plist", "tf", "tfvars", "hcl", "lock", "editorconfig", "gitignore", "gitattributes"]
    static let configNames: Set<String> = ["dockerfile", "makefile", "package.json", "package-lock.json", "cargo.toml", "cargo.lock", "go.mod", "go.sum", "gemfile", "podfile", "package.swift",
                                           "requirements.txt", "pyproject.toml", "build.gradle", "pom.xml", "docker-compose.yml", "docker-compose.yaml", "composer.json", "tsconfig.json"]
    static let archive: Set<String> = ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst", "lz", "lzma", "z", "cab", "iso", "img", "cpio"]
    static let installer: Set<String> = ["dmg", "pkg", "exe", "msi", "deb", "rpm", "apk", "ipa", "appimage", "appx", "msix", "xpi", "crx", "vsix", "snap", "flatpak"]
    static let data: Set<String> = ["sqlite", "sqlite3", "db", "mdb", "accdb", "csv", "tsv", "parquet", "ndjson", "jsonl", "dump", "bak", "avro", "arrow"]
    static let feed: Set<String> = ["rss", "atom", "opml", "xspf"]
    /// Extensions a web server uses for pages it generates. A link to one is a page, not a source file; it is a download only if the page marks it so.
    static let serverSide: Set<String> = ["php", "asp", "aspx", "jsp", "jspx", "cgi", "cfm", "pl", "do", "action", "php3", "php4", "php5", "phtml"]
    /// Hosts of file-sharing services whose links open the service's own download page.
    static let cloudHosts: [String] = ["drive.google.com", "docs.google.com", "dropbox.com", "mega.nz", "mega.io", "onedrive.live.com", "1drv.ms", "box.com", "mediafire.com", "wetransfer.com", "we.tl", "icloud.com", "pcloud.com", "sendspace.com"]
    /// The most distinct resources kept for one page.
    static let maxPerPage = 500

    static func category(forExtension e: String) -> ResourceCategory? {
        if video.contains(e) { return .video }; if audio.contains(e) { return .audio }; if image.contains(e) { return .image }; if archive.contains(e) { return .archive }
        if installer.contains(e) { return .installer }; if document.contains(e) { return .document }; if feed.contains(e) { return .feed }; if e == "torrent" { return .torrent }
        if data.contains(e) { return .data }; if config.contains(e) { return .config }; if code.contains(e) { return .code }
        return nil
    }

    /// An extension whose meaning depends on context (".ts" is TypeScript or MPEG transport stream; ".md" is Markdown; ".h" a header): found by name, never certain.
    static let ambiguous: Set<String> = ["ts", "md", "h", "m", "r", "z", "img", "db", "key", "pl", "go", "c", "lock", "env", "do"]

    /// The paths file-sharing services use for a shared file or folder.
    static func isShareShape(_ url: URL) -> Bool {
        let p = url.path.lowercased()
        let prefixes = ["/s/", "/sh/", "/scl/", "/file/", "/folder/", "/f/", "/d/", "/u/", "/download", "/view", "/file/d/", "/drive/folders/", "/s!", "/t/", "/shares/", "/s"]
        if url.host?.lowercased().hasSuffix("1drv.ms") == true || url.host?.lowercased() == "we.tl" || url.host?.lowercased().hasSuffix("mediafire.com") == true { return p.count > 3 }
        if (url.host ?? "").lowercased().hasSuffix("mega.nz") || (url.host ?? "").lowercased().hasSuffix("mega.io") { return url.fragment?.hasPrefix("!") == true || p.hasPrefix("/file/") || p.hasPrefix("/folder/") }
        return prefixes.dropLast().contains { p.hasPrefix($0) } && !p.hasPrefix("/forms/") && !p.hasPrefix("/pricing")
    }

    /// A query that carries a credential or an expiring token. Such an address is used as it is and never shown.
    static func looksSigned(_ url: URL) -> Bool {
        guard let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return url.user != nil }
        let keys: Set<String> = ["signature", "sig", "token", "expires", "x-amz-signature", "x-amz-credential", "x-goog-signature", "se", "sv", "key", "access_token", "policy", "hdnts", "auth"]
        return url.user != nil || q.contains { keys.contains($0.name.lowercased()) }
    }

    // MARK: Classifying a link

    /// What a link on a page is, or nil when it is not a user-facing resource (an ordinary page, a script the page needs, an unsupported scheme). `marked` is the page's own `download` attribute.
    static func classify(link raw: String, marked: Bool, pageHost: String?, frameOrigin: String? = nil) -> DetectedResource? {
        let text = LinkClassifier.canonicalText(raw)
        let lower = text.lowercased()
        if lower.hasPrefix("magnet:") || lower.hasPrefix("ed2k:") {
            let r = LinkClassifier.classify(text)
            guard r.kind.isSupported else { return nil }
            return DetectedResource(id: r.identity, category: .torrent, url: text, filename: r.name, ext: lower.hasPrefix("magnet:") ? "magnet" : "ed2k", pageHost: pageHost, frameOrigin: frameOrigin, method: .magnet, confidence: .high)
        }
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://"), let url = URL(string: text), let host = url.host, !host.isEmpty else { return nil }
        let id = LinkClassifier.normalizedKey(url)
        let name = (url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent)
        let file = name == "/" ? "" : name
        let ext = (file as NSString).pathExtension.lowercased()
        let signed = looksSigned(url)
        // A wiki's File:Name.ext address is a page about a file, not the file (see LinkClassifier.isNamespacePage).
        if LinkClassifier.isNamespacePage(url), !marked { return nil }

        if cloudHosts.contains(where: { host.lowercased() == $0 || host.lowercased().hasSuffix("." + $0) }), isShareShape(url) {
            // Only a link into a file-sharing service's share or file path, not its home, pricing or sign-in pages.
            return DetectedResource(id: id, category: .cloud, url: text, filename: host, ext: "", pageHost: pageHost, frameOrigin: frameOrigin, method: marked ? .downloadAttribute : .link, confidence: .medium, signed: signed)
        }
        // A video card: a link to a provider's watch page, reel or short. Shown at once as a discovered video; whether it can be downloaded is decided only when it is opened.
        if let m = ProviderRecognizer.recognize(url), m.mediaID != nil, [.video, .short, .reel].contains(m.kind), !m.isEmbed {
            return DetectedResource(id: id, category: .video, url: text, filename: m.provider.displayName + " " + m.kind.rawValue, ext: "", pageHost: pageHost, frameOrigin: frameOrigin, method: .link, confidence: .medium, signed: signed, provider: m.provider)
        }
        // A page the server generates is a page. Its extension says nothing about the file a download would give.
        if serverSide.contains(ext) {
            guard marked else { return nil }
            return DetectedResource(id: id, category: .other, url: text, filename: file, ext: ext, pageHost: pageHost, frameOrigin: frameOrigin, method: .downloadAttribute, confidence: .low, signed: signed)
        }
        let lowerName = file.lowercased()
        if configNames.contains(lowerName) {
            return DetectedResource(id: id, category: .config, url: text, filename: file, ext: ext, pageHost: pageHost, frameOrigin: frameOrigin, method: marked ? .downloadAttribute : .link, confidence: .medium, signed: signed)
        }
        // A page-linked "html" file is usually just another page: only a marked link, or one in a path that names a file, counts.
        if let cat = category(forExtension: ext) {
            if cat == .code, ["html", "htm"].contains(ext), !marked { return nil }
            let conf: ResourceConfidence = marked ? .high : (ambiguous.contains(ext) || ext == "m3u8" || ext == "mpd" ? .low : .medium)
            return DetectedResource(id: id, category: cat, url: text, filename: file, ext: ext, pageHost: pageHost, frameOrigin: frameOrigin, method: marked ? .downloadAttribute : .link, confidence: conf, signed: signed)
        }
        // An unknown ending is a download only when the page says so.
        if marked { return DetectedResource(id: id, category: .other, url: text, filename: file.isEmpty ? host : file, ext: ext, pageHost: pageHost, frameOrigin: frameOrigin, method: .downloadAttribute, confidence: .medium, signed: signed) }
        return nil
    }

    // MARK: The server's answer

    /// What a real response (its type and disposition) says, which wins over an address. A page served where a file was promised is not a file.
    static func refine(_ r: DetectedResource, mime rawMime: String?, disposition: String?, size: Int64?) -> DetectedResource {
        var r = r
        let mime = rawMime?.lowercased().split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let attachment = (disposition ?? "").lowercased().hasPrefix("attachment")
        if mime == "text/html" || mime == "application/xhtml+xml", !attachment, r.category != .code, r.category != .cloud {
            r.availability = .notAFile("The address returned a web page, not a file.")
            return r
        }
        if let cat = category(forMIME: mime), cat != r.category, !(r.category == .code && cat == .document) { r.category = cat; r.confidence = .high }
        r.availability = .confirmed(size: size, mime: mime.isEmpty ? nil : mime)
        return r
    }

    static func category(forMIME m: String) -> ResourceCategory? {
        if m.hasPrefix("video/") || m == "application/vnd.apple.mpegurl" || m == "application/x-mpegurl" || m == "application/dash+xml" { return .video }
        if m.hasPrefix("audio/") { return .audio }
        if m.hasPrefix("image/") { return .image }
        switch m {
        case "application/pdf", "application/epub+zip", "application/msword", "application/rtf", "text/plain", "text/rtf", "application/vnd.ms-excel", "application/vnd.ms-powerpoint",
             "application/vnd.openxmlformats-officedocument.wordprocessingml.document", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "application/vnd.openxmlformats-officedocument.presentationml.presentation": return .document
        case "application/zip", "application/x-zip-compressed", "application/gzip", "application/x-gzip", "application/x-tar", "application/x-7z-compressed", "application/vnd.rar", "application/x-rar-compressed", "application/x-bzip2", "application/zstd": return .archive
        case "application/x-bittorrent": return .torrent
        case "application/vnd.apple.installer+xml", "application/x-apple-diskimage", "application/vnd.android.package-archive", "application/x-msdownload", "application/x-msi", "application/vnd.debian.binary-package": return .installer
        case "application/json", "application/xml", "text/xml", "application/yaml", "application/x-yaml", "text/yaml", "application/toml": return .config
        case "text/csv", "application/vnd.sqlite3", "application/x-sqlite3", "application/parquet": return .data
        case "application/rss+xml", "application/atom+xml", "application/feed+json": return .feed
        case "text/javascript", "application/javascript", "text/css", "application/x-sh", "text/x-python", "text/x-swift", "text/markdown", "text/x-java-source", "text/x-c", "text/x-rust": return .code
        default: return nil
        }
    }
}

/// What one page offers, by category. Bounded; built from a list of resources and (for video and audio) the media observer's own counts.
struct PageResourceSummary: Equatable, Sendable {
    var items: [ResourceCategory: [DetectedResource]] = [:]
    /// Video and audio come from the media picker's own classification (so the toolbar never promises more than the picker offers): detected, and openable.
    var mediaDetected: [ResourceCategory: Int] = [:]
    var mediaOpenable: [ResourceCategory: Int] = [:]
    var truncated = false
    static let empty = PageResourceSummary()

    /// For video and audio: the picker's own count of players and files, or the page's file links if more, plus the video entries the page lists that still have to be opened (cards, playlists).
    func detected(_ c: ResourceCategory) -> Int {
        guard c.usesMediaPicker else { return items[c]?.count ?? 0 }
        let list = items[c] ?? []
        return max(mediaDetected[c] ?? 0, list.filter { !$0.needsResolution }.count) + list.filter(\.needsResolution).count
    }
    /// What can be downloaded now: never a video entry that has not been resolved.
    func openable(_ c: ResourceCategory) -> Int {
        guard c.usesMediaPicker else { return detected(c) }
        let files = (items[c] ?? []).filter { r in if r.needsResolution { return false }; if case .notAFile = r.availability { return false }; return true }
        return max(mediaOpenable[c] ?? 0, files.count)
    }
    var categories: [ResourceCategory] { ResourceCategory.allCases.filter { detected($0) > 0 } }
    var isEmpty: Bool { categories.isEmpty }

    /// Deduplicated by identity, in page order, never more than the limit.
    static func make(_ found: [DetectedResource], truncated: Bool = false) -> PageResourceSummary {
        var s = PageResourceSummary(truncated: truncated)
        var at: [String: (ResourceCategory, Int)] = [:]; var total = 0
        for r in found {
            // The same file linked twice is one item; if one of the links is marked as a download, that one's detail wins.
            if let (cat, i) = at[r.id] { if r.confidence > (s.items[cat]?[i].confidence ?? .low) { s.items[cat]?[i] = r }; continue }
            total += 1
            if total > ResourceClassifier.maxPerPage { s.truncated = true; break }
            at[r.id] = (r.category, s.items[r.category, default: []].count)
            s.items[r.category, default: []].append(r)
        }
        return s
    }
}

/// Which categories the toolbar shows. Detection itself is a read of the page's own links; turning it off stops the scan, and a category turned off is not counted or shown.
enum ResourceDetectionSettings {
    static let enabledKey = "bs.detect.enabled"
    static let hiddenKey = "bs.detect.hidden"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    static var hidden: Set<ResourceCategory> {
        parse(UserDefaults.standard.string(forKey: hiddenKey) ?? "")
    }
    /// Stored as a comma-separated list so a setting can bind to it directly.
    static func parse(_ raw: String) -> Set<ResourceCategory> { Set(raw.split(separator: ",").compactMap { ResourceCategory(rawValue: String($0)) }) }
    static func setHidden(_ c: ResourceCategory, _ hide: Bool) {
        var h = hidden; if hide { h.insert(c) } else { h.remove(c) }
        UserDefaults.standard.set(h.map(\.rawValue).sorted().joined(separator: ","), forKey: hiddenKey)
    }
    /// Every kind is shown unless turned off in Settings.
    static func isShown(_ c: ResourceCategory) -> Bool { !hidden.contains(c) }
}

extension PageResourceSummary {
    /// Page links classified, bounded, deduplicated; media counts joined from the media summary.
    @MainActor
    static func build(scan: PageLinkScan, media: MediaPageSummary, pageHost: String?) -> PageResourceSummary {
        var found = scan.links.compactMap { ResourceClassifier.classify(link: $0.href, marked: $0.marked, pageHost: pageHost) }
        // The page's pictures (an <img> is not a link, so a gallery of posters used to show nothing in the toolbar). After the links, so a link to the same file keeps its own detail; the list limit applies to all.
        for address in scan.images {
            guard let url = URL(string: address), url.scheme == "http" || url.scheme == "https", let host = url.host, !host.isEmpty, !LinkClassifier.isNamespacePage(url) else { continue }
            let name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
            let picture = ResourceClassifier.classify(link: address, marked: false, pageHost: pageHost)
                ?? DetectedResource(id: LinkClassifier.normalizedKey(url), category: .image, url: address, filename: name.isEmpty || name == "/" ? host : name, ext: (name as NSString).pathExtension.lowercased(),
                                    pageHost: pageHost, frameOrigin: nil, method: .link, confidence: .medium, signed: ResourceClassifier.looksSigned(url))
            found.append(picture)
        }
        var s = PageResourceSummary.make(found, truncated: scan.truncated)
        // A media item and a link to the same file are one thing; the picker's count is what the toolbar promises.
        if media.detected > 0 {
            s.mediaDetected[.audio] = media.audioDetected
            s.mediaOpenable[.audio] = media.audioOpenable
            s.mediaDetected[.video] = media.detected - media.audioDetected
            s.mediaOpenable[.video] = media.openable - media.audioOpenable
        }
        return s
    }
}
