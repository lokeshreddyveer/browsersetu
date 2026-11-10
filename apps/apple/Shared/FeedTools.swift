import SwiftUI
import UniformTypeIdentifiers

/// A feed a page advertises, or a feed in an OPML list.
struct FoundFeed: Identifiable, Equatable {
    var title: String
    var url: String
    var id: String { url }
}

/// Finds the feeds a page advertises in its head (`<link rel="alternate" type="application/rss+xml" href="…">`). Works on the page's own text, on the device;
/// nothing is fetched until the person follows one.
enum FeedDiscovery {
    /// `includeJSON` and `allowHTTP` are for downloading from feeds (JSON Feed, and plain http addresses); the reader's own use keeps both off, exactly as before.
    static func feeds(inHTML html: String, baseURL: URL?, includeJSON: Bool = false, allowHTTP: Bool = false) -> [FoundFeed] {
        // Only the head matters; a page can be large.
        let head = html.range(of: "</head>", options: .caseInsensitive).map { String(html[..<$0.lowerBound]) } ?? String(html.prefix(60_000))
        guard let tag = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: [.caseInsensitive]) else { return [] }
        var found: [FoundFeed] = []
        var seen = Set<String>()
        for match in tag.matches(in: head, range: NSRange(head.startIndex..., in: head)) {
            guard let range = Range(match.range, in: head) else { continue }
            let attributes = attributes(of: String(head[range]))
            guard let rel = attributes["rel"]?.lowercased(), rel.split(separator: " ").contains("alternate"),
                  let type = attributes["type"]?.lowercased(), type.contains("rss") || type.contains("atom") || (includeJSON && type.contains("feed+json")),
                  let href = attributes["href"], let url = URL(string: href, relativeTo: baseURL)?.absoluteURL,
                  url.scheme?.lowercased() == "https" || (allowHTTP && url.scheme?.lowercased() == "http"), url.host != nil, seen.insert(url.absoluteString).inserted else { continue }
            found.append(FoundFeed(title: decode(attributes["title"] ?? "") , url: url.absoluteString))
        }
        return Array(found.prefix(10))
    }

    private static func attributes(of tag: String) -> [String: String] {
        guard let pattern = try? NSRegularExpression(pattern: "([a-zA-Z-]+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')") else { return [:] }
        var out: [String: String] = [:]
        for match in pattern.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
            guard let name = Range(match.range(at: 1), in: tag) else { continue }
            let value = [2, 3].compactMap { Range(match.range(at: $0), in: tag) }.first.map { String(tag[$0]) } ?? ""
            out[String(tag[name]).lowercased()] = value
        }
        return out
    }

    private static func decode(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
    }
}

/// OPML, the list format every feed reader imports and exports.
enum OPML {
    static func parse(_ data: Data) -> [FoundFeed] {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        parser.parse()
        return reader.feeds
    }

    static func export(_ feeds: [Feed]) -> String {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let rows = feeds.map { "    <outline type=\"rss\" text=\"\(escape($0.title))\" title=\"\(escape($0.title))\" xmlUrl=\"\(escape($0.url))\"/>" }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <head><title>Browser Setu feeds</title></head>
          <body>
        \(rows)
          </body>
        </opml>
        """
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var feeds: [FoundFeed] = []
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            guard name.lowercased() == "outline", let url = attributes["xmlUrl"] ?? attributes["xmlurl"], !url.isEmpty else { return }
            feeds.append(FoundFeed(title: attributes["title"] ?? attributes["text"] ?? "", url: url))
        }
    }
}

/// The OPML file offered to the export dialog.
struct OPMLDocument: FileDocument {
    static var readableContentTypes: [UTType] { [UTType(filenameExtension: "opml") ?? .xml] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws { text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}

@MainActor
extension BrowserModel {
    /// The feeds the page in front advertises, minus the ones already followed.
    func feedsOnActivePage() async -> [FoundFeed] {
        guard let tab = active, !tab.isBlank, let html = await tab.engine.pageSource() else { return [] }
        return FeedDiscovery.feeds(inHTML: html, baseURL: tab.url).filter { found in !feeds.contains { $0.url == found.url } }
    }

    /// Follows every feed in an OPML file, up to the 20 the reader holds. Returns a sentence about what happened.
    func importOPML(_ data: Data) async -> String {
        let listed = OPML.parse(data).compactMap { FeedFetcher.valid($0.url) }
        guard !listed.isEmpty else { return "That file has no feeds in it." }
        let followed = Set(feeds.map(\.url))
        let fresh = Array(NSOrderedSet(array: listed).array as? [URL] ?? listed).filter { !followed.contains($0.absoluteString) }
        let room = max(0, 20 - feeds.count)
        let wanted = Array(fresh.prefix(room))
        // All at once: one slow site does not hold up the others.
        let fetched = await withTaskGroup(of: (Int, (title: String, items: [FeedItem])?).self) { group in
            for (index, url) in wanted.enumerated() { group.addTask { (index, await FeedFetcher.fetch(url)) } }
            var results: [Int: (title: String, items: [FeedItem])] = [:]
            for await (index, result) in group { if let result { results[index] = result } }
            return results
        }
        var added = 0
        for (index, url) in wanted.enumerated() {
            if let result = fetched[index], addFetchedFeed(url, result) == nil { added += 1 }
        }
        let skipped = listed.count - added
        return "Followed \(added) feed\(added == 1 ? "" : "s")" + (skipped > 0 ? "; \(skipped) could not be added (already followed, not a feed, or over the limit of 20)." : ".")
    }

    var opmlText: String { OPML.export(feeds) }
}
