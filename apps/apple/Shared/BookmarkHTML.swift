import Foundation

/// Bookmarks as the HTML file every browser can export and import (the "Netscape bookmark" format Safari, Chrome, Firefox and Brave use).
enum BookmarkHTML {
    struct Entry: Equatable {
        var url: String
        var title: String
        var folder: String
    }

    // MARK: Writing

    static func export(_ entries: [Entry]) -> String {
        var lines = [
            "<!DOCTYPE NETSCAPE-Bookmark-file-1>",
            "<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">",
            "<TITLE>Bookmarks</TITLE>",
            "<H1>Bookmarks</H1>",
            "<DL><p>",
        ]
        func link(_ e: Entry, indent: String) -> String { "\(indent)<DT><A HREF=\"\(escape(e.url))\">\(escape(e.title.isEmpty ? e.url : e.title))</A>" }
        for e in entries where e.folder.isEmpty { lines.append(link(e, indent: "    ")) }
        let folders = Array(Set(entries.map(\.folder).filter { !$0.isEmpty })).sorted()
        for folder in folders {
            lines.append("    <DT><H3>\(escape(folder))</H3>")
            lines.append("    <DL><p>")
            for e in entries where e.folder == folder { lines.append(link(e, indent: "        ")) }
            lines.append("    </DL><p>")
        }
        lines.append("</DL><p>")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Reading

    /// Every web bookmark in the file. Folders nest; the folder of a bookmark is its path ("News/Tech"). Only http and https links
    /// are taken: a bookmarks file must never smuggle in a `javascript:` or `file:` address.
    static func parse(_ html: String) -> [Entry] {
        let pattern = #"<\s*(/?)\s*(h3|a|dl)\b([^>]*)>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let text = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: text.length))

        var entries: [Entry] = []
        var path: [String] = []           // names of the folders we are inside
        var pendingFolder: String?        // a folder heading read, waiting for its <DL>
        var openLists: [Bool] = []        // for each open <DL>: did it add a folder name to `path`?

        for (i, match) in matches.enumerated() {
            let closing = text.substring(with: match.range(at: 1)) == "/"
            let tag = text.substring(with: match.range(at: 2)).lowercased()
            let attributes = text.substring(with: match.range(at: 3))
            let after = match.range.location + match.range.length
            let nextStart = i + 1 < matches.count ? matches[i + 1].range.location : text.length
            let inner = text.substring(with: NSRange(location: after, length: max(0, nextStart - after)))

            switch (tag, closing) {
            case ("h3", false):
                pendingFolder = decode(inner).trimmingCharacters(in: .whitespacesAndNewlines)
            case ("dl", false):
                if let name = pendingFolder { path.append(name); openLists.append(true) } else { openLists.append(false) }
                pendingFolder = nil
            case ("dl", true):
                if openLists.popLast() == true { path.removeLast() }
            case ("a", false):
                guard let href = attribute("href", in: attributes), let url = URL(string: decode(href)),
                      let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else { continue }
                let title = decode(inner).trimmingCharacters(in: .whitespacesAndNewlines)
                entries.append(Entry(url: url.absoluteString, title: title, folder: folderName(path)))
            default: break
            }
        }
        return entries
    }

    /// The browsers' own top-level containers are not folders worth keeping.
    private static let roots: Set<String> = ["bookmarks", "bookmarks bar", "bookmarks menu", "bookmarks toolbar", "favorites", "favourites",
                                              "other bookmarks", "mobile bookmarks", "reading list"]

    private static func folderName(_ path: [String]) -> String {
        var parts = path
        while let first = parts.first, roots.contains(first.lowercased()) || first.isEmpty { parts.removeFirst() }
        return parts.joined(separator: "/")
    }

    private static func attribute(_ name: String, in attributes: String) -> String? {
        let pattern = "\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = regex.firstMatch(in: attributes, range: NSRange(location: 0, length: (attributes as NSString).length)) else { return nil }
        for group in 1...3 where m.range(at: group).location != NSNotFound { return (attributes as NSString).substring(with: m.range(at: group)) }
        return nil
    }

    // MARK: Text

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func decode(_ text: String) -> String {
        var out = text
        for (entity, char) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&apos;", "'"), ("&nbsp;", " ")] {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }
}
