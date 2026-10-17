import Foundation

/// Safari rules read from an Adblock Plus style list that a plain domain list cannot express: page-element hiding
/// (`##.ad-banner`) and URL-pattern rules (`||example.com/ads/*$third-party,script`). Each rule is kept as compact JSON text,
/// ready to be placed in a Safari content-blocker package. Anything Safari cannot do (scriptlets, regex rules, redirects,
/// extended selectors) is counted as unsupported, never turned into a different rule.
public struct ContentRuleSet: Codable, Equatable, Sendable {
    /// URL-pattern blocks.
    public var blocks: [String] = []
    /// `css-display-none` rules.
    public var hides: [String] = []
    /// URL-pattern exceptions (`ignore-previous-rules`); they must come after everything they cancel.
    public var allows: [String] = []
    public var unsupported = 0
    public init() {}
    public var count: Int { blocks.count + hides.count + allows.count }
    public var isEmpty: Bool { count == 0 }
    public mutating func append(_ other: ContentRuleSet) { blocks += other.blocks; hides += other.hides; allows += other.allows }
}

public enum ABPContentParser {
    /// Selectors that only some ad blockers understand; Safari would reject or misapply them.
    private static let extendedSelectorMarkers = [":-abp-", ":xpath(", ":matches-css", ":contains(", ":has-text(", ":upward(", ":nth-ancestor(", ":remove(", ":style(", ":watch-attr", ":min-text-length", ":others(", ":matches-path", ":has(", "+js("]
    private static let unsupportedOptions = ["redirect", "redirect-rule", "removeparam", "csp", "important", "badfilter", "denyallow", "header", "replace", "permissions", "cname", "inline-script", "inline-font", "generichide", "genericblock", "elemhide", "specifichide", "urlblock", "content", "jsonprune", "xhr-sec"]
    public static let selectorsPerRule = 80
    /// Per list. Safari takes tens of thousands of rules per extension, and the list shares that with the domain rules.
    public static let limit = 30_000

    public static func parse(_ data: Data, limit: Int = ABPContentParser.limit) -> ContentRuleSet {
        guard let text = String(data: data, encoding: .utf8) else { return ContentRuleSet() }
        var result = ContentRuleSet()
        var generic: [String] = []
        var scoped: [String: (domains: [String], negated: Bool, selectors: [String])] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") { continue }
            if let range = line.range(of: "##") , !line.contains("#@#") {
                if let hide = elementHide(domains: String(line[..<range.lowerBound]), selector: String(line[range.upperBound...])) {
                    if hide.domains.isEmpty { generic.append(hide.selector) } else {
                        let key = (hide.negated ? "~" : "") + hide.domains.joined(separator: ",")
                        scoped[key, default: (hide.domains, hide.negated, [])].selectors.append(hide.selector)
                    }
                } else { result.unsupported += 1 }
                continue
            }
            if line.contains("#?#") || line.contains("#@#") || line.contains("#$#") || line.contains("#%#") || line.contains("#@?#") { result.unsupported += 1; continue }
            switch networkRule(line) {
            case .skip: continue                                      // a plain ||domain^ is already a domain rule
            case .unsupported: result.unsupported += 1
            case .block(let json): if result.blocks.count < limit { result.blocks.append(json) }
            case .allow(let json): if result.allows.count < limit { result.allows.append(json) }
            }
        }
        // Group selectors: one rule can hide many selectors, which keeps the rule count (and Safari's compile time) down.
        for chunk in chunks(Array(Set(generic)).sorted(), selectorsPerRule) { if let rule = hideRule(selectors: chunk, domains: [], negated: false) { result.hides.append(rule) } }
        for (_, group) in scoped.sorted(by: { $0.key < $1.key }) {
            for chunk in chunks(Array(Set(group.selectors)).sorted(), selectorsPerRule) where result.hides.count < limit {
                if let rule = hideRule(selectors: chunk, domains: group.domains, negated: group.negated) { result.hides.append(rule) }
            }
        }
        return result
    }

    // MARK: Element hiding
    private static func elementHide(domains: String, selector: String) -> (domains: [String], negated: Bool, selector: String)? {
        let selector = selector.trimmingCharacters(in: .whitespaces)
        guard !selector.isEmpty, selector.count <= 300, !selector.contains("{"), !selector.contains("\\") else { return nil }
        for marker in extendedSelectorMarkers where selector.contains(marker) { return nil }
        guard safeSelector(selector) else { return nil }
        var positive: [String] = [], negative: [String] = []
        if !domains.isEmpty {
            for item in domains.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) {
                let isNegative = item.hasPrefix("~"); let name = isNegative ? String(item.dropFirst()) : item
                guard validDomain(name) else { return nil }
                if isNegative { negative.append(name) } else { positive.append(name) }
            }
        }
        // Safari allows either if-domain or unless-domain on a rule, not both.
        if !positive.isEmpty { return (positive.sorted(), false, selector) }
        if !negative.isEmpty { return (negative.sorted(), true, selector) }
        return ([], false, selector)
    }
    private static func hideRule(selectors: [String], domains: [String], negated: Bool) -> String? {
        var trigger: [String: Any] = ["url-filter": ".*"]
        if !domains.isEmpty { trigger[negated ? "unless-domain" : "if-domain"] = domains.map { "*" + $0 } }
        return json(["trigger": trigger, "action": ["type": "css-display-none", "selector": selectors.joined(separator: ", ")]])
    }

    // MARK: URL-pattern rules
    private enum Network { case skip, unsupported, block(String), allow(String) }
    private static func networkRule(_ original: String) -> Network {
        var line = original
        var isAllow = false
        if line.hasPrefix("@@") { isAllow = true; line = String(line.dropFirst(2)) }
        var options: [String] = []
        if let dollar = line.lastIndex(of: "$"), !line[line.index(after: dollar)...].contains("/") || line[line.index(after: dollar)...].contains("=") {
            let tail = String(line[line.index(after: dollar)...])
            // `$` can also be part of a pattern; accept it as options only when every part looks like an option.
            let parts = tail.split(separator: ",").map(String.init)
            if !parts.isEmpty, parts.allSatisfy({ looksLikeOption($0) }) { options = parts; line = String(line[..<dollar]) }
        }
        guard !line.isEmpty, !(line.hasPrefix("/") && line.hasSuffix("/") && line.count > 2) else { return .unsupported }   // regex rule
        var loadType: String?; var resourceTypes: [String] = []; var ifDomains: [String] = []; var unlessDomains: [String] = []; var caseSensitive = false
        for option in options {
            let negated = option.hasPrefix("~"); let name = negated ? String(option.dropFirst()) : option
            let key = name.split(separator: "=", maxSplits: 1).first.map(String.init) ?? name
            if unsupportedOptions.contains(key) { return .unsupported }
            switch key {
            case "third-party", "3p": loadType = negated ? "first-party" : "third-party"
            case "first-party", "1p": loadType = negated ? "third-party" : "first-party"
            case "match-case": caseSensitive = true
            case "domain":
                let value = name.dropFirst("domain=".count)
                for entry in value.split(separator: "|").map({ String($0).lowercased() }) {
                    let neg = entry.hasPrefix("~"); let host = neg ? String(entry.dropFirst()) : entry
                    guard validDomain(host) else { return .unsupported }
                    if neg { unlessDomains.append(host) } else { ifDomains.append(host) }
                }
            case "script", "image", "font", "media", "popup":
                if negated { return .unsupported }
                resourceTypes.append(key)
            case "stylesheet", "css": if negated { return .unsupported }; resourceTypes.append("style-sheet")
            case "xmlhttprequest", "xhr", "websocket", "ping", "other": if negated { return .unsupported }; resourceTypes.append("raw")
            case "subdocument", "document", "doc", "frame": return .unsupported
            default: return .unsupported
            }
        }
        if !ifDomains.isEmpty && !unlessDomains.isEmpty { return .unsupported }
        // A bare ||domain^ with no path and no options is exactly a domain rule; the domain parser already has it.
        if options.isEmpty, line.hasPrefix("||"), line.hasSuffix("^"), !line.dropFirst(2).dropLast().contains(where: { "/*^|?=&:".contains($0) }) { return .skip }
        guard let pattern = regex(for: line) else { return .unsupported }
        var trigger: [String: Any] = ["url-filter": pattern]
        if let loadType { trigger["load-type"] = [loadType] }
        if !resourceTypes.isEmpty { trigger["resource-type"] = Array(Set(resourceTypes)).sorted() }
        if !ifDomains.isEmpty { trigger["if-domain"] = ifDomains.sorted().map { "*" + $0 } }
        if !unlessDomains.isEmpty { trigger["unless-domain"] = unlessDomains.sorted().map { "*" + $0 } }
        if caseSensitive { trigger["url-filter-is-case-sensitive"] = true }
        guard let rule = json(["trigger": trigger, "action": ["type": isAllow ? "ignore-previous-rules" : "block"]]) else { return .unsupported }
        return isAllow ? .allow(rule) : .block(rule)
    }
    private static func looksLikeOption(_ part: String) -> Bool {
        let name = part.hasPrefix("~") ? String(part.dropFirst()) : part
        let key = name.split(separator: "=", maxSplits: 1).first.map(String.init) ?? name
        let known = ["third-party", "3p", "first-party", "1p", "match-case", "domain", "script", "image", "font", "media", "popup", "stylesheet", "css", "xmlhttprequest", "xhr", "websocket", "ping", "other", "subdocument", "document", "doc", "frame"] + unsupportedOptions
        return known.contains(key)
    }
    /// Adblock pattern -> the small regular-expression dialect WebKit accepts.
    private static func regex(for pattern: String) -> String? {
        var text = pattern
        var prefix = "", suffix = ""
        if text.hasPrefix("||") { prefix = "^https?://([^/]+\\.)?"; text.removeFirst(2) }
        else if text.hasPrefix("|") { prefix = "^"; text.removeFirst() }
        if text.hasSuffix("|") { suffix = "$"; text.removeLast() }
        guard !text.isEmpty, text.count <= 160 else { return nil }
        let literal = text.filter { $0 != "*" && $0 != "^" }
        guard literal.count >= 3 else { return nil }                       // too short: would match far too much
        var out = ""
        for ch in text {
            switch ch {
            case "*": out += ".*"
            case "^": out += "[/:?&=]"
            case ".", "+", "?", "(", ")", "[", "]", "{", "}", "|", "$", "\\": out += "\\" + String(ch)
            default:
                guard ch.isASCII, !ch.isWhitespace else { return nil }
                out.append(ch)
            }
        }
        // "||host^" ends the host; at the end of a pattern the separator may also be the end of the URL.
        if out.hasSuffix("[/:?&=]") && prefix.hasPrefix("^https") && suffix.isEmpty { /* separator is enough */ }
        return prefix + out + suffix
    }

    /// One bad selector makes WebKit reject the whole package, so only plain CSS this parser fully understands is accepted.
    private static let allowedPseudo: Set<String> = ["not", "first-child", "last-child", "nth-child", "nth-last-child", "nth-of-type", "first-of-type", "last-of-type", "only-child", "empty"]
    static func safeSelector(_ selector: String) -> Bool {
        var depthParen = 0, depthBracket = 0
        var quote: Character?
        var index = selector.startIndex
        while index < selector.endIndex {
            let ch = selector[index]
            if let q = quote { if ch == q { quote = nil } }
            else {
                switch ch {
                case "\"", "'": quote = ch
                case "(": depthParen += 1
                case ")": depthParen -= 1; if depthParen < 0 { return false }
                case "[": depthBracket += 1
                case "]": depthBracket -= 1; if depthBracket < 0 { return false }
                case ":":
                    if depthBracket > 0 { break }
                    let rest = selector[selector.index(after: index)...]
                    if rest.hasPrefix(":") { return false }                       // pseudo-element
                    let name = rest.prefix { $0.isLetter || $0 == "-" }
                    if !allowedPseudo.contains(String(name)) { return false }
                case "{", "}", ";", "@", "<": return false
                default: break
                }
            }
            index = selector.index(after: index)
        }
        return quote == nil && depthParen == 0 && depthBracket == 0 && !selector.hasPrefix(",") && !selector.hasSuffix(",")
    }
    private static func validDomain(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 253 && name.contains(".") && name.utf8.allSatisfy { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 46 }
    }
    private static func chunks<T>(_ values: [T], _ size: Int) -> [[T]] { stride(from: 0, to: values.count, by: size).map { Array(values[$0..<min($0 + size, values.count)]) } }
    private static func json(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
