import Foundation

/// The readable part of a page: a title and the headings, paragraphs, quotes, lists and pictures of its main article.
struct ReadableArticle: Equatable, Codable {
    enum Block: Equatable, Codable {
        case heading(Int, String)
        case paragraph(String)
        case quote(String)
        case code(String)
        case listItem(String)
        case image(url: String, caption: String)
    }
    var title: String
    var site: String
    var blocks: [Block]

    /// Reads the plain data the page script returns. Anything unexpected is dropped, so a hostile page cannot shape the output.
    static func from(_ raw: Any?) -> ReadableArticle? {
        guard let dict = raw as? [String: Any], let rawBlocks = dict["blocks"] as? [[String: Any]] else { return nil }
        var blocks: [Block] = []
        for item in rawBlocks.prefix(800) {
            guard let tag = item["t"] as? String, let value = item["v"] as? String, !value.isEmpty, value.count < 20_000 else { continue }
            switch tag {
            case "h1", "h2": blocks.append(.heading(2, value))
            case "h3", "h4": blocks.append(.heading(3, value))
            case "p": blocks.append(.paragraph(value))
            case "blockquote": blocks.append(.quote(value))
            case "pre": blocks.append(.code(value))
            case "li": blocks.append(.listItem(value))
            case "img":
                if let url = URL(string: value), url.scheme?.lowercased() == "https" { blocks.append(.image(url: url.absoluteString, caption: item["a"] as? String ?? "")) }
            default: break
            }
        }
        guard blocks.contains(where: { if case .paragraph = $0 { return true } else { return false } }) else { return nil }
        return ReadableArticle(title: (dict["title"] as? String) ?? "", site: (dict["site"] as? String) ?? "", blocks: blocks)
    }
}

/// The page the reader shows: plain, readable type on a calm background that follows light and dark. It holds no script, and
/// its policy lets in nothing but the article's own pictures.
enum ReaderHTML {
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// `text`, escaped, with each of `highlights` wrapped in a yellow mark wherever it appears.
    static func escapeMarking(_ text: String, highlights: [String]) -> String {
        guard !highlights.isEmpty else { return escape(text) }
        var ranges: [Range<String.Index>] = []
        for phrase in highlights where !phrase.isEmpty {
            var from = text.startIndex
            while from < text.endIndex, let found = text.range(of: phrase, range: from..<text.endIndex) {
                ranges.append(found); from = found.upperBound
            }
        }
        guard !ranges.isEmpty else { return escape(text) }
        ranges.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for range in ranges {
            if let last = merged.last, range.lowerBound < last.upperBound { merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound) }
            else { merged.append(range) }
        }
        var out = "", cursor = text.startIndex
        for range in merged {
            out += escape(String(text[cursor..<range.lowerBound]))
            out += "<mark>" + escape(String(text[range])) + "</mark>"
            cursor = range.upperBound
        }
        return out + escape(String(text[cursor...]))
    }

    static func page(for article: ReadableArticle, highlights: [String] = [], style: ReaderStyle = .current) -> String {
        var body = ""
        var inList = false
        func closeList() { if inList { body += "</ul>\n"; inList = false } }
        for block in article.blocks {
            if case .listItem(let text) = block {
                if !inList { body += "<ul>\n"; inList = true }
                body += "<li>\(escapeMarking(text, highlights: highlights))</li>\n"
                continue
            }
            closeList()
            switch block {
            case .heading(let level, let text): body += "<h\(level)>\(escapeMarking(text, highlights: highlights))</h\(level)>\n"
            case .paragraph(let text): body += "<p>\(escapeMarking(text, highlights: highlights))</p>\n"
            case .quote(let text): body += "<blockquote>\(escapeMarking(text, highlights: highlights))</blockquote>\n"
            case .code(let text): body += "<pre>\(escape(text))</pre>\n"
            case .image(let url, let caption): body += "<figure><img src=\"\(escape(url))\" alt=\"\(escape(caption))\"></figure>\n"
            case .listItem: break
            }
        }
        closeList()
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https:; style-src 'unsafe-inline'">
        <meta name="color-scheme" content="light dark">
        <title>\(escape(article.title))</title>
        <style>
        \(style.css)
        </style></head>
        <body><main>
        <div class="site">\(escape(article.site))</div>
        <h1>\(escape(article.title))</h1>
        \(body)</main></body></html>
        """
    }
}
