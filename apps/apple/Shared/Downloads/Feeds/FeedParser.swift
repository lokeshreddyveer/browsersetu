import Foundation

// DX-10: reading a feed. RSS 2.0, Atom 1.0 and JSON Feed 1.x (the three formats podcasts and blogs use), with the podcast extras (enclosures, iTunes duration/episode/season).
// Everything in a feed is untrusted text: sizes, depth and counts are bounded, external entities are never resolved, only http(s) addresses are kept, and nothing here connects anywhere.

struct FeedEnclosure: Codable, Equatable, Hashable, Sendable {
    var url: URL
    var type: String?
    var length: Int64?
}

struct DownloadFeedItem: Codable, Equatable, Identifiable, Sendable {
    /// Stable identity inside its feed: the item's own id (guid / Atom id / JSON id), else its first enclosure's address, else its link. Never the position, so a refresh does not renumber anything.
    var id: String
    var title: String
    var published: Date?
    var summary: String
    var link: URL?
    var enclosures: [FeedEnclosure]
    /// Podcast extras, when the feed says them.
    var duration: TimeInterval?
    var episode: Int?
    var season: Int?
}

struct DownloadFeed: Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case rss, atom, json, playlist }
    var kind: Kind
    var title: String
    var siteURL: URL?
    var items: [DownloadFeedItem]
    /// A further page of the same feed (Atom `rel="next"`, JSON Feed `next_url`).
    var next: URL?
    /// More items were in the feed than are kept.
    var truncated = false
    var warnings: [String] = []
    /// A playlist read from an extractor page by page: there may be more entries beyond the ones listed.
    var more = false
    /// Entries a playlist listed that cannot be used (removed, private, protected, or with an unusable address).
    var unavailable = 0
}

enum FeedError: Error, Equatable, LocalizedError {
    case notAFeed, tooLarge, malformed(String), isAStream
    var errorDescription: String? {
        switch self {
        case .notAFeed: "That address is not an RSS, Atom or JSON feed."
        case .tooLarge: "The feed is too large to read safely."
        case .malformed(let why): "The feed could not be read (\(why))."
        case .isAStream: "This is a streaming playlist (HLS), not a list of separate files. Open it with Choose & Download… to pick a quality."
        }
    }
}

enum FeedLimits {
    static let maxBytes = 5_000_000
    static let maxItems = 1000
    static let maxEnclosuresPerItem = 8
    static let maxTitle = 300
    static let maxSummary = 600
    static let maxDepth = 32
    static let maxElements = 200_000
    static let maxURLLength = 4096
    /// No size or length a feed states is believed beyond these (they are untrusted numbers): 1 PiB and 100 days.
    static let maxBytesStated: Int64 = 1 << 50
    static let maxSeconds: Double = 8_640_000
}

enum DownloadFeedParser {
    static func parse(_ data: Data, from base: URL) throws -> DownloadFeed {
        guard data.count <= FeedLimits.maxBytes else { throw FeedError.tooLarge }
        let first = data.first(where: { ![0x20, 0x09, 0x0A, 0x0D, 0xEF, 0xBB, 0xBF].contains($0) })
        if first == UInt8(ascii: "{") { return try parseJSON(data, base: base) }
        let head = String(decoding: data.prefix(64), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if head.hasPrefix("#extm3u") || head.hasPrefix("[playlist]") || head.hasPrefix("#ext-x-") { return try parsePlaylistFile(data, base: base) }
        return try parseXML(data, base: base)
    }

    // MARK: Shared helpers

    static func size(_ v: Int64?) -> Int64? { v.flatMap { $0 >= 0 && $0 <= FeedLimits.maxBytesStated ? $0 : nil } }
    static func seconds(_ v: Double?) -> TimeInterval? { v.flatMap { $0.isFinite && $0 >= 0 && $0 <= FeedLimits.maxSeconds ? $0 : nil } }

    static func clean(_ s: String, max: Int) -> String {
        let scalars = s.unicodeScalars.filter { ($0.value >= 0x20 || $0 == "\n" || $0 == "\t") && $0.value != 0x7F && !(0x202A...0x202E).contains($0.value) && !(0x2066...0x2069).contains($0.value) }
        let text = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text.prefix(max))
    }

    /// Plain text from a description that may hold markup: tags dropped, the common entities decoded, spaces collapsed.
    static func plain(_ html: String, max: Int = FeedLimits.maxSummary) -> String {
        var out = "", inTag = false
        for ch in html.prefix(max * 6) {
            if ch == "<" { inTag = true; out.append(" "); continue }
            if ch == ">" { inTag = false; continue }
            if !inTag { out.append(ch) }
        }
        for (e, c) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " ")] { out = out.replacingOccurrences(of: e, with: c) }
        let collapsed = out.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }).joined(separator: " ")
        return clean(collapsed, max: max)
    }

    /// An absolute http(s) address from a reference in the feed, or nil (other schemes, empty, very long).
    static func resolve(_ ref: String?, against base: URL) -> URL? {
        guard let ref = ref?.trimmingCharacters(in: .whitespacesAndNewlines), !ref.isEmpty, ref.count <= FeedLimits.maxURLLength,
              !ref.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }),
              let url = URL(string: ref, relativeTo: base)?.absoluteURL, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    static func date(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty, raw.count < 64 else { return nil }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: raw) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: raw) { return d }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        for fmt in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm Z", "dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            f.dateFormat = fmt
            if let d = f.date(from: raw) { return d }
        }
        return nil
    }

    /// `3600`, `61:05` or `1:01:05` (the forms podcasts use) in seconds.
    static func duration(_ raw: String?) -> TimeInterval? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty, raw.count < 16 else { return nil }
        let parts = raw.split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        return seconds(parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 })
    }

    static func finish(_ items: [DownloadFeedItem], _ truncated: Bool) -> ([DownloadFeedItem], Bool) {
        var seen = Set<String>(), out: [DownloadFeedItem] = []
        for item in items { if seen.insert(item.id).inserted { out.append(item) } }
        if out.count > FeedLimits.maxItems { return (Array(out.prefix(FeedLimits.maxItems)), true) }
        return (out, truncated)
    }

    static func identity(id: String?, enclosures: [FeedEnclosure], link: URL?, title: String) -> String {
        if let id = id.map({ clean($0, max: 500) }), !id.isEmpty { return id }
        func stable(_ u: URL) -> String { FeedURLIdentity.stable(u) }
        if let e = enclosures.first { return stable(e.url) }
        if let link { return stable(link) }
        return "title:" + title
    }

    // MARK: JSON Feed

    private static func parseJSON(_ data: Data, base: URL) throws -> DownloadFeed {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw FeedError.malformed("not valid JSON") }
        guard let version = root["version"] as? String, version.contains("jsonfeed.org") else { throw FeedError.notAFeed }
        func str(_ v: Any?, _ max: Int) -> String { (v as? String).map { clean($0, max: max) } ?? "" }
        var items: [DownloadFeedItem] = []
        var truncated = false
        for case let o as [String: Any] in (root["items"] as? [Any] ?? []) {
            if items.count >= FeedLimits.maxItems + 1 { truncated = true; break }
            var enclosures: [FeedEnclosure] = []
            var duration: TimeInterval?
            for case let a as [String: Any] in (o["attachments"] as? [Any] ?? []).prefix(FeedLimits.maxEnclosuresPerItem) {
                guard let url = resolve(a["url"] as? String, against: base) else { continue }
                enclosures.append(FeedEnclosure(url: url, type: (a["mime_type"] as? String).map { clean($0, max: 100) }, length: size((a["size_in_bytes"] as? NSNumber)?.int64Value)))
                if duration == nil, let d = seconds((a["duration_in_seconds"] as? NSNumber)?.doubleValue) { duration = d }
            }
            let link = resolve(o["url"] as? String, against: base) ?? resolve(o["external_url"] as? String, against: base)
            let title = str(o["title"], FeedLimits.maxTitle)
            let summary = (o["summary"] as? String).map { plain($0) } ?? (o["content_text"] as? String).map { plain($0) } ?? (o["content_html"] as? String).map { plain($0) } ?? ""
            let idValue: String? = (o["id"] as? String) ?? (o["id"] as? NSNumber)?.stringValue
            items.append(DownloadFeedItem(id: identity(id: idValue, enclosures: enclosures, link: link, title: title), title: title.isEmpty ? (link?.lastPathComponent ?? "Untitled") : title,
                                  published: date(o["date_published"] as? String), summary: summary, link: link, enclosures: enclosures, duration: duration, episode: nil, season: nil))
        }
        let (kept, cut) = finish(items, truncated)
        return DownloadFeed(kind: .json, title: str(root["title"], FeedLimits.maxTitle), siteURL: resolve(root["home_page_url"] as? String, against: base), items: kept,
                    next: resolve(root["next_url"] as? String, against: base), truncated: cut)
    }

    // MARK: M3U and PLS: a playlist of separate items

    /// HLS tags that make an `.m3u8` a stream of segments or renditions, never a list of files to collect.
    static let streamTags = ["#ext-x-stream-inf", "#ext-x-targetduration", "#ext-x-media-sequence", "#ext-x-media:", "#ext-x-endlist", "#ext-x-i-frame-stream-inf", "#ext-x-map", "#ext-x-key"]

    private static func parsePlaylistFile(_ data: Data, base: URL) throws -> DownloadFeed {
        let text = String(decoding: data, as: UTF8.self)
        let lower = text.prefix(200_000).lowercased()
        if streamTags.contains(where: { lower.contains($0) }) { throw FeedError.isAStream }
        var items: [DownloadFeedItem] = [], truncated = false
        var pendingTitle: String?, pendingDuration: TimeInterval?, pending = [Int: (url: String?, title: String?)]()
        func add(_ ref: String, title: String?, duration: TimeInterval?) {
            guard let url = resolve(ref, against: base) else { return }
            if items.count >= FeedLimits.maxItems + 1 { truncated = true; return }
            let t = clean(title ?? "", max: FeedLimits.maxTitle)
            let name = t.isEmpty ? (url.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? url.lastPathComponent) : t
            items.append(DownloadFeedItem(id: url.absoluteString, title: name.isEmpty ? "Untitled" : name, published: nil, summary: "", link: nil,
                                          enclosures: [FeedEnclosure(url: url, type: nil, length: nil)], duration: duration, episode: nil, season: nil))
        }
        if text.lowercased().contains("[playlist]") {
            // PLS: File1=, Title1=, Length1=
            for rawLine in text.split(whereSeparator: \.isNewline).prefix(FeedLimits.maxItems * 4) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard let eq = line.firstIndex(of: "="), let digits = Optional(line[..<eq].drop(while: { !$0.isNumber })), let n = Int(digits), n > 0, n <= FeedLimits.maxItems + 1 else { continue }
                let key = line[..<eq].lowercased(), value = String(line[line.index(after: eq)...])
                var e = pending[n] ?? (nil, nil)
                if key.hasPrefix("file") { e.url = value } else if key.hasPrefix("title") { e.title = value }
                pending[n] = e
            }
            for n in pending.keys.sorted() { if let e = pending[n], let u = e.url { add(u, title: e.title, duration: nil) } }
        } else {
            // M3U: #EXTINF:<seconds>,<title> before each address
            for rawLine in text.split(whereSeparator: \.isNewline).prefix(FeedLimits.maxItems * 3) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }
                if line.hasPrefix("#") {
                    if line.uppercased().hasPrefix("#EXTINF:") {
                        let body = line.dropFirst(8), comma = body.firstIndex(of: ",")
                        pendingDuration = Double(body[..<(comma ?? body.endIndex)].split(separator: " ").first ?? "").flatMap { $0 > 0 ? $0 : nil }
                        pendingTitle = comma.map { String(body[body.index(after: $0)...]) }
                    }
                    continue
                }
                add(line, title: pendingTitle, duration: pendingDuration); pendingTitle = nil; pendingDuration = nil
            }
        }
        guard !items.isEmpty else { throw FeedError.notAFeed }
        let (kept, cut) = finish(items, truncated)
        return DownloadFeed(kind: .playlist, title: base.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? "Playlist", siteURL: nil, items: kept, next: nil, truncated: cut)
    }

    // MARK: RSS and Atom

    private static func parseXML(_ data: Data, base: URL) throws -> DownloadFeed {
        let reader = FeedXMLReader(base: base)
        // Control characters are not allowed in XML, and real feeds do contain them (copied text, a stray BEL): they are removed rather than rejecting the whole feed. Safe on UTF-8, whose
        // multi-byte characters never contain a byte below 0x20.
        let cleaned = data.contains(where: { $0 < 0x20 && $0 != 0x09 && $0 != 0x0A && $0 != 0x0D }) ? Data(data.filter { $0 >= 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }) : data
        let parser = XMLParser(data: cleaned)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        let ok = parser.parse()
        if reader.tooComplex { throw FeedError.malformed("too many or too deeply nested elements") }
        guard let kind = reader.kind else { throw reader.sawRoot ? FeedError.notAFeed : FeedError.malformed("not valid XML") }
        if !ok && reader.items.isEmpty { throw FeedError.malformed("not valid XML") }
        let (kept, cut) = finish(reader.items, reader.truncated)
        return DownloadFeed(kind: kind, title: clean(reader.feedTitle, max: FeedLimits.maxTitle), siteURL: reader.siteURL, items: kept, next: reader.next, truncated: cut,
                    warnings: ok ? [] : ["The feed ends unexpectedly; the items before that point are shown."])
    }
}

/// One pass over an RSS or Atom document. Only the elements that matter are collected; everything else is skipped without being kept.
private final class FeedXMLReader: NSObject, XMLParserDelegate {
    let base: URL
    var kind: DownloadFeed.Kind?
    var feedTitle = ""
    var siteURL: URL?
    var next: URL?
    var items: [DownloadFeedItem] = []
    var truncated = false
    var tooComplex = false
    /// A document element was seen (so it is XML, just not a feed).
    var sawRoot = false

    private var path: [String] = []
    private var elements = 0
    private var text = ""
    private var inItem = false
    // The item being read.
    private var title = "", guid = "", pubDate = "", summary = "", content = "", linkText = ""
    private var atomLinks: [(rel: String, href: String, type: String?, length: String?)] = []
    private var enclosures: [FeedEnclosure] = []
    private var duration = "", episode = "", season = ""

    init(base: URL) { self.base = base }

    private func local(_ name: String) -> String {
        // Namespaced names keep their prefix ("itunes:duration", "content:encoded"); the rest are plain.
        name.lowercased()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        elements += 1
        if elements > FeedLimits.maxElements || path.count >= FeedLimits.maxDepth { tooComplex = true; parser.abortParsing(); return }
        let name = local(elementName)
        if path.isEmpty {
            sawRoot = true
            switch name { case "rss", "rdf:rdf": kind = .rss; case "feed": kind = .atom; default: kind = nil }
            if kind == nil { parser.abortParsing(); return }
        }
        path.append(name)
        text = ""
        if (name == "item" && kind == .rss) || (name == "entry" && kind == .atom) {
            if items.count >= FeedLimits.maxItems + 1 { truncated = true; parser.abortParsing(); return }
            inItem = true
            title = ""; guid = ""; pubDate = ""; summary = ""; content = ""; linkText = ""; atomLinks = []; enclosures = []; duration = ""; episode = ""; season = ""
        }
        if name == "enclosure", inItem, kind == .rss, enclosures.count < FeedLimits.maxEnclosuresPerItem, let url = DownloadFeedParser.resolve(attributeDict["url"], against: base) {
            enclosures.append(FeedEnclosure(url: url, type: attributeDict["type"].map { DownloadFeedParser.clean($0, max: 100) }, length: DownloadFeedParser.size(attributeDict["length"].flatMap { Int64($0) })))
        }
        if name == "media:content", inItem, enclosures.isEmpty, let url = DownloadFeedParser.resolve(attributeDict["url"], against: base) {
            enclosures.append(FeedEnclosure(url: url, type: attributeDict["type"].map { DownloadFeedParser.clean($0, max: 100) }, length: DownloadFeedParser.size(attributeDict["filesize"].flatMap { Int64($0) })))
        }
        if name == "link", kind == .atom {
            let rel = attributeDict["rel"] ?? "alternate"
            if inItem { atomLinks.append((rel, attributeDict["href"] ?? "", attributeDict["type"], attributeDict["length"])) }
            else if rel == "alternate", siteURL == nil { siteURL = DownloadFeedParser.resolve(attributeDict["href"], against: base) }
            else if rel == "next" { next = DownloadFeedParser.resolve(attributeDict["href"], against: base) }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { if text.utf8.count < 200_000 { text += string } }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { if text.utf8.count < 200_000 { text += String(decoding: CDATABlock, as: UTF8.self) } }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = local(elementName)
        defer { if !path.isEmpty { path.removeLast() }; text = "" }
        let parent = path.count >= 2 ? path[path.count - 2] : ""
        if inItem {
            switch name {
            case "title" where parent == "item" || parent == "entry": title = text
            case "guid", "id": if parent == "item" || parent == "entry" { guid = text }
            case "pubdate", "published", "dc:date": if parent == "item" || parent == "entry" { pubDate = text }
            case "updated": if pubDate.isEmpty, parent == "entry" { pubDate = text }
            case "description", "summary": if parent == "item" || parent == "entry" { summary = text }
            case "content:encoded", "content": if parent == "item" || parent == "entry" { content = text }
            case "link": if kind == .rss, parent == "item" { linkText = text }
            case "itunes:duration": duration = text
            case "itunes:episode": episode = text
            case "itunes:season": season = text
            case "item" where kind == .rss, "entry" where kind == .atom: finishItem()
            default: break
            }
        } else if parent == "channel" || parent == "feed" {
            if name == "title", feedTitle.isEmpty { feedTitle = text }
            if name == "link", kind == .rss, siteURL == nil { siteURL = DownloadFeedParser.resolve(text, against: base) }
        }
    }

    private func finishItem() {
        inItem = false
        var link: URL?
        var encl = enclosures
        if kind == .rss { link = DownloadFeedParser.resolve(linkText, against: base) }
        else {
            link = atomLinks.first(where: { $0.rel == "alternate" }).flatMap { DownloadFeedParser.resolve($0.href, against: base) }
            for l in atomLinks where l.rel == "enclosure" && encl.count < FeedLimits.maxEnclosuresPerItem {
                if let url = DownloadFeedParser.resolve(l.href, against: base) { encl.append(FeedEnclosure(url: url, type: l.type.map { DownloadFeedParser.clean($0, max: 100) }, length: DownloadFeedParser.size(l.length.flatMap { Int64($0) }))) }
            }
        }
        let t = DownloadFeedParser.clean(title, max: FeedLimits.maxTitle)
        let body = !summary.isEmpty ? summary : content
        items.append(DownloadFeedItem(id: DownloadFeedParser.identity(id: guid, enclosures: encl, link: link, title: t), title: t.isEmpty ? (link?.lastPathComponent ?? "Untitled") : t,
                              published: DownloadFeedParser.date(pubDate), summary: DownloadFeedParser.plain(body), link: link, enclosures: encl,
                              duration: DownloadFeedParser.duration(duration), episode: Int(episode.trimmingCharacters(in: .whitespaces)), season: Int(season.trimmingCharacters(in: .whitespaces))))
    }
}

// MARK: Finding feeds on a page

/// Feeds on a page, found by the browser's existing `FeedDiscovery` (the reader's code), asked to include JSON Feed and plain http addresses for this use; and a check for whether bytes are a feed.
enum DownloadFeedDiscovery {
    struct Found: Equatable, Sendable { var url: URL; var title: String? }

    static func links(inHTML html: String, pageURL: URL, limit: Int = 20) -> [Found] {
        FeedDiscovery.feeds(inHTML: html, baseURL: pageURL, includeJSON: true, allowHTTP: true).prefix(limit).compactMap { f in
            DownloadFeedParser.resolve(f.url, against: pageURL).map { Found(url: $0, title: f.title.isEmpty ? nil : DownloadFeedParser.clean(f.title, max: FeedLimits.maxTitle)) }
        }
    }

    /// Whether the bytes are a feed itself (so an address the person typed can be a feed address directly).
    static func looksLikeFeed(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(2048), as: UTF8.self).lowercased()
        return head.contains("<rss") || head.contains("<feed") || head.contains("<rdf:rdf") || (head.contains("jsonfeed.org") && head.contains("{"))
            || head.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#extm3u") || head.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[playlist]")
    }
}


/// How an item with no id of its own is recognised by its address. A signed link's temporary parts (signature, expiry, token…) change on every fetch and must not make the same episode look new;
/// the parts that choose the resource (`?file=a` / `?file=b`, `?id=7`) must still tell different items apart. So only known temporary parameters are dropped, the rest are kept, sorted.
enum FeedURLIdentity {
    /// Names that only ever carry a signature or a login: dropped wherever they appear.
    private static let strong: Set<String> = ["signature", "sig", "token", "hdnts", "hmac", "key-pair-id", "access_token", "awsaccesskeyid", "s3token", "x-token", "skoid", "sktid", "skt", "ske", "sks", "skv", "nonce"]
    /// Short names that are also ordinary parameters (`e` is often an episode number): dropped only when the link is signed by one of the strong ones or a provider prefix.
    private static let ambiguous: Set<String> = ["expires", "expire", "expiry", "exp", "e", "st", "se", "sp", "sv", "sr", "sip", "spr", "policy", "auth", "ts", "timestamp", "_t", "validfrom", "validto", "verify"]
    private static let prefixes = ["x-amz-", "x-goog-", "x-ms-"]

    private static func isStrong(_ name: String) -> Bool { let n = name.lowercased(); return strong.contains(n) || prefixes.contains { n.hasPrefix($0) } }

    static func isTemporary(_ name: String, signed: Bool = true) -> Bool { isStrong(name) || (signed && ambiguous.contains(name.lowercased())) }

    static func stable(_ u: URL) -> String {
        let base = (u.host ?? "").lowercased() + u.path
        let all = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let signed = all.contains { isStrong($0.name) }
        let kept = all.filter { !isTemporary($0.name, signed: signed) }.map { "\($0.name)=\($0.value ?? "")" }.sorted()
        return String((kept.isEmpty ? base : base + "?" + kept.joined(separator: "&")).prefix(500))
    }
}
