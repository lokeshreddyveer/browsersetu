import Foundation

// Phase 19: the two small parsers the Website Explorer needs, both tolerant of bad input and bounded.

// MARK: - robots.txt (RFC 9309)

/// The rules of one robots.txt that apply to this crawler. Longest matching rule wins; on a tie, allow wins; no match means allowed. `*` matches any run of characters and a
/// trailing `$` anchors the end.
struct RobotsRules: Equatable, Sendable {
    struct Rule: Equatable, Sendable { var allow: Bool; var pattern: String }
    static let token = "browsersetu"
    static let maxBytes = 500 * 1024

    var rules: [Rule] = []
    var crawlDelay: TimeInterval?
    /// The file could not be had at all (server error, no answer): the RFC says to assume everything is disallowed.
    var disallowAll = false

    static let allowAll = RobotsRules()
    static let denyAll = RobotsRules(disallowAll: true)

    /// What a robots.txt request's answer means: found (parse it), not there (4xx: no restrictions), or unreachable (5xx, no answer: assume none allowed).
    static func forStatus(_ status: Int?, body: Data?) -> RobotsRules {
        guard let status else { return .denyAll }
        switch status {
        case 200..<300: return parse(body.map { String(decoding: $0.prefix(maxBytes), as: UTF8.self) } ?? "")
        case 400..<500: return .allowAll
        default: return .denyAll
        }
    }

    static func parse(_ text: String) -> RobotsRules {
        struct Group { var agents: [String] = []; var rules: [Rule] = []; var delay: TimeInterval? }
        var groups: [Group] = []
        var current: Group?
        var lastWasAgent = false
        for rawLine in text.split(whereSeparator: \.isNewline).prefix(20_000) {
            var line = String(rawLine)
            if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]) }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let field = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch field {
            case "user-agent":
                if !lastWasAgent { if let g = current { groups.append(g) }; current = Group() }
                // The product token alone is compared ("BrowserSetu/1.0" is BrowserSetu).
                current?.agents.append(String(value.lowercased().split(separator: "/").first ?? "")); lastWasAgent = true
            case "allow", "disallow":
                lastWasAgent = false
                // A rule before any user-agent line belongs to no group and is ignored. An empty Disallow allows everything: it adds no rule.
                guard current != nil, !value.isEmpty else { continue }
                current?.rules.append(Rule(allow: field == "allow", pattern: String(value.prefix(2048))))
            case "crawl-delay":
                if let d = Double(value), d >= 0, d.isFinite { current?.delay = min(d, 30) }
            default: break          // other lines (Sitemap and the like) neither belong to a group nor end one
            }
        }
        if let g = current { groups.append(g) }
        // The group that names this crawler wins; otherwise the `*` group; otherwise there are no rules.
        let named = groups.filter { $0.agents.contains(token) }
        let star = groups.filter { $0.agents.contains("*") }
        let chosen = named.isEmpty ? star : named
        return RobotsRules(rules: chosen.flatMap(\.rules), crawlDelay: chosen.compactMap(\.delay).first)
    }

    func allows(_ url: URL) -> Bool {
        if disallowAll { return false }
        if url.path == "/robots.txt" { return true }
        // The path as it was written (escapes intact): `URL.path` would decode %2F into a slash and change what a rule means.
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var path = (parts?.percentEncodedPath).flatMap { $0.isEmpty ? nil : $0 } ?? "/"
        if let q = parts?.percentEncodedQuery { path += "?" + q }
        path = Self.normalise(path)
        var best: (length: Int, allow: Bool)?
        for rule in rules where Self.matches(Self.normalise(rule.pattern), path) {
            let len = rule.pattern.count
            if best == nil || len > best!.length || (len == best!.length && rule.allow && !best!.allow) { best = (len, rule.allow) }
        }
        return best?.allow ?? true
    }

    /// Percent-escapes compared without regard to the case of their hex digits.
    private static func normalise(_ s: String) -> String {
        var out = "", i = s.startIndex
        while i < s.endIndex {
            if s[i] == "%", s.distance(from: i, to: s.endIndex) >= 3 { out += s[i..<s.index(i, offsetBy: 3)].uppercased(); i = s.index(i, offsetBy: 3) }
            else { out.append(s[i]); i = s.index(after: i) }
        }
        return out
    }

    /// Whether `pattern` matches the start of `path` (all of it when the pattern ends in `$`).
    static func matches(_ pattern: String, _ path: String) -> Bool { match(pattern, path).matched }

    /// The matcher, with the number of comparison steps it took. Greedy single-star backtracking (never exponential): the steps are at most
    /// (pattern length + 1) x (path length + 1). Bytes are compared, which is what percent-encoded addresses are made of.
    static func match(_ pattern: String, _ path: String) -> (matched: Bool, steps: Int) {
        var p = Array(pattern.utf8), anchored = false
        if p.last == UInt8(ascii: "$") { anchored = true; p.removeLast() }
        let s = Array(path.utf8), star8 = UInt8(ascii: "*")
        var pi = 0, si = 0, star = -1, mark = 0, steps = 0
        while si < s.count {
            steps += 1
            if pi < p.count, p[pi] == star8 { star = pi; mark = si; pi += 1 }
            else if pi < p.count, p[pi] == s[si] { pi += 1; si += 1 }
            else if pi == p.count, !anchored { return (true, steps) }
            else if star >= 0 { pi = star + 1; mark += 1; si = mark }
            else { return (false, steps) }
        }
        while pi < p.count, p[pi] == star8 { pi += 1; steps += 1 }
        return (pi == p.count, steps)
    }
}

// MARK: - HTML links

/// Reads the addresses out of a page's markup without a full HTML parser: tag by tag, tolerating broken markup, and bounded. Only addresses are read. Form fields, scripts,
/// styles and text are skipped, so nothing a person typed or a page keeps hidden can come out of here.
enum HTMLLinks {
    struct Link: Equatable, Sendable { var reference: String; var tag: String; var attribute: String }
    struct Page: Equatable, Sendable { var base: String?; var links: [Link]; var truncated: Bool }

    static let maxTags = 200_000
    static let maxLinks = 2000
    static let maxValue = 4096

    /// Tags whose address is read, and the attribute that holds it.
    private static let wanted: [String: [String]] = ["a": ["href"], "area": ["href"], "img": ["src", "srcset"], "video": ["src"], "audio": ["src"], "source": ["src", "srcset"],
                                                     "iframe": ["src"], "frame": ["src"], "embed": ["src"]]

    static func extract(_ html: String) -> Page {
        var links: [Link] = [], base: String?, truncated = false
        let c = Array(html.unicodeScalars)
        var i = 0, tags = 0
        func text(_ r: Range<Int>) -> String { var v = String.UnicodeScalarView(); v.append(contentsOf: c[r]); return String(v) }
        func isSpace(_ u: Unicode.Scalar) -> Bool { u == " " || u == "\n" || u == "\t" || u == "\r" }
        func startsWith(_ s: String, at: Int) -> Bool {
            let t = Array(s.unicodeScalars)
            guard at + t.count <= c.count else { return false }
            for k in 0..<t.count {
                var v = c[at + k].value; if v >= 65 && v <= 90 { v += 32 }
                if v != t[k].value { return false }
            }
            return true
        }
        while i < c.count {
            guard c[i] == "<" else { i += 1; continue }
            if startsWith("<!--", at: i) {
                var j = i + 4
                while j + 2 < c.count, !(c[j] == "-" && c[j + 1] == "-" && c[j + 2] == ">") { j += 1 }
                i = j + 3; continue
            }
            var j = i + 1
            if j < c.count, c[j] == "/" || c[j] == "!" || c[j] == "?" { while j < c.count, c[j] != ">" { j += 1 }; i = j + 1; continue }
            let nameStart = j
            while j < c.count, c[j].properties.isAlphabetic || (c[j].value >= 48 && c[j].value <= 57) { j += 1 }
            let name = text(nameStart..<j).lowercased()
            guard !name.isEmpty else { i += 1; continue }
            tags += 1
            if tags > maxTags { truncated = true; break }
            // Attributes, until the tag's closing '>' (a '>' inside quotes does not close it).
            var attrs: [String: String] = [:]
            while j < c.count, c[j] != ">" {
                while j < c.count, isSpace(c[j]) || c[j] == "/" { j += 1 }
                if j >= c.count || c[j] == ">" { break }
                let aStart = j
                while j < c.count, c[j] != "=", c[j] != ">", !isSpace(c[j]), c[j] != "/" { j += 1 }
                let attr = text(aStart..<j).lowercased()
                while j < c.count, isSpace(c[j]) { j += 1 }
                var value = ""
                if j < c.count, c[j] == "=" {
                    j += 1
                    while j < c.count, isSpace(c[j]) { j += 1 }
                    if j < c.count, c[j] == "\"" || c[j] == "'" {
                        let q = c[j]; j += 1; let vStart = j
                        while j < c.count, c[j] != q { j += 1 }
                        value = text(vStart..<min(j, vStart + maxValue)); j += 1
                    } else {
                        let vStart = j
                        while j < c.count, c[j] != ">", !isSpace(c[j]) { j += 1 }
                        value = text(vStart..<min(j, vStart + maxValue))
                    }
                }
                if !attr.isEmpty, attrs[attr] == nil, attrs.count < 24 { attrs[attr] = value }
                if j == aStart { j += 1 }                        // always move on, whatever the markup looks like
            }
            i = j + 1
            if name == "script" || name == "style" {
                var k = i
                while k < c.count { if c[k] == "<", startsWith("</\(name)", at: k) { break }; k += 1 }
                i = k; continue
            }
            if name == "base", base == nil, let h = attrs["href"] { base = decode(h) }
            guard let attributes = wanted[name] else { continue }
            for a in attributes {
                guard let raw = attrs[a], !raw.isEmpty else { continue }
                let value = a == "srcset" ? (raw.split(separator: ",").first.flatMap { $0.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) } ?? "") : raw
                let ref = decode(value.trimmingCharacters(in: .whitespacesAndNewlines))
                guard !ref.isEmpty, !ref.hasPrefix("#") else { continue }
                if links.count >= maxLinks { truncated = true; break }
                links.append(Link(reference: ref, tag: name, attribute: a))
            }
            if links.count >= maxLinks { truncated = true; break }
        }
        return Page(base: base, links: links, truncated: truncated)
    }

    static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        // "&amp;" last, so "&amp;quot;" becomes "&quot;" and no further.
        return s.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
    }
}
