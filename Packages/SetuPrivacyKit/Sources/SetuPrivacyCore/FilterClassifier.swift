import CryptoKit
import Foundation

// Reads an Adblock Plus / uBlock Origin style list line by line and sorts every line into what it becomes: a network block, an exception, page-element hiding,
// a procedural page rule, a scriptlet, or "unsupported" with the reason. It replaces the older ABPContentParser for downloaded lists (that file is imported
// unchanged from VayuSetu and is left alone) and adds: cosmetic exceptions (#@#), $badfilter, $important, $document / $subdocument, negated resource types,
// the regular expressions WebKit can express, procedural cosmetic filters (:has-text, :has, :upward, :xpath ...) and an allow-list of scriptlets.
// Nothing here turns a rule into something it is not: what WebKit cannot do is counted with its reason, never approximated.

/// What one list turned into, line by line.
public struct ListDiagnostics: Codable, Equatable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    /// Rule lines read (comments and blank lines are not counted).
    public var lines = 0
    /// URL-pattern rules compiled for WebKit's content blocker.
    public var network = 0
    /// Blocks written after the exceptions, so an exception cannot cancel them ($important).
    public var important = 0
    /// Exceptions applied: @@ rules and #@# cosmetic exceptions.
    public var exceptions = 0
    /// Page elements hidden by the content blocker (one per selector).
    public var cosmetic = 0
    /// Procedural cosmetic rules the browser's own page script runs.
    public var procedural = 0
    /// Scriptlets the browser's own page script runs.
    public var scriptlets = 0
    /// Plain host rules, which the domain parser compiles.
    public var domainRules = 0
    /// Rules switched off by a $badfilter line.
    public var disabledByBadfilter = 0
    public var unsupported = 0
    /// Why lines were not used, with how many.
    public var reasons: [String: Int] = [:]
    /// A few example lines for each reason.
    public var samples: [String: [String]] = [:]

    public init(name: String) { self.name = name }

    mutating func reject(_ reason: String, _ line: String) {
        unsupported += 1
        reasons[reason, default: 0] += 1
        if (samples[reason]?.count ?? 0) < 3 { samples[reason, default: []].append(String(line.prefix(140))) }
    }
}

public struct ProceduralOp: Codable, Equatable, Sendable {
    public var kind: String
    public var arg: String
}

/// A page rule the browser's own script runs, for pages whose host matches.
public struct ProceduralRule: Codable, Equatable, Sendable {
    public var domains: [String]
    public var excludeDomains: [String]
    /// A plain CSS selector (it may use :has, which the page's engine runs itself); empty when the rule starts from an :xpath().
    public var selector: String
    public var ops: [ProceduralOp]
    /// "hide", "remove" or "style".
    public var action: String
    public var style: String
}

public struct ScriptletRule: Codable, Equatable, Sendable {
    public var domains: [String]
    public var excludeDomains: [String]
    public var name: String
    public var args: [String]
}

public struct ScriptRuleSet: Codable, Equatable, Sendable {
    public var procedural: [ProceduralRule] = []
    public var scriptlets: [ScriptletRule] = []
    /// Websites where the person switched blocking off (or paused it). The page scripts do nothing there, as the network rules do nothing there.
    public var exceptions: [String] = []
    public init() {}
    public var isEmpty: Bool { procedural.isEmpty && scriptlets.isEmpty }
    public mutating func append(_ other: ScriptRuleSet) { procedural += other.procedural; scriptlets += other.scriptlets }
    /// Changes whenever what the page scripts would do changes.
    public var digest: String {
        guard !isEmpty, let data = try? JSONEncoder().encode(self) else { return "" }          // (the exceptions are part of what is encoded)
        return SHA256.hash(data: data).prefix(10).map { String(format: "%02x", $0) }.joined()
    }
}

public struct ClassifiedList {
    public var content = ContentRuleSet()
    public var important: [String] = []
    public var scripts = ScriptRuleSet()
    public var diagnostics: ListDiagnostics
    /// The list's text without the rules a $badfilter switched off, for the domain parser; nil when nothing was removed.
    public var domainText: Data?
}

public enum FilterClassifier {
    public static let importantLimit = 10_000
    public static let proceduralLimit = 5_000
    public static let scriptletLimit = 2_000
    static let selectorsPerRule = ABPContentParser.selectorsPerRule

    // MARK: Reasons (shown to the person, so they are written for them)

    static let rewritesResponse = "Needs a response or header to be rewritten, which WebKit's content blocker cannot do"
    static let needsStub = "Replaces a request with a stand-in resource ($redirect), which WebKit's content blocker cannot do"
    static let rewritesLink = "Rewrites a link's parameters ($removeparam), which is not done by content rules"
    static let regexTooComplex = "Regular expression uses more than WebKit's rule language allows"
    static let badSelector = "Selector WebKit could not be trusted to accept"
    static let unknownScriptlet = "Scriptlet that this browser does not provide"
    static let unsupportedProcedural = "Procedural filter this browser does not run"
    static let otherBlocker = "Script or style injection written for another blocker (not run on purpose)"
    static let unsupportedOption = "Option this browser does not support"
    static let tooBroad = "Pattern too short or too broad to be safe"
    static let badDomain = "Website pattern this browser cannot match (such as site.*)"
    static let proceduralException = "Exception for a procedural or extended rule"
    static let mixedDomains = "Both allowed and excluded websites in one option"

    private static let rewriteOptions: Set<String> = ["csp", "replace", "header", "permissions", "cname", "jsonprune", "xmlprune", "json", "jq", "xml", "uritransform"]
    private static let stubOptions: Set<String> = ["redirect", "redirect-rule", "rewrite"]
    private static let linkOptions: Set<String> = ["removeparam", "queryprune"]
    private static let otherUnsupported: Set<String> = ["denyallow", "inline-script", "inline-font", "urlblock", "genericblock", "content", "xhr-sec", "to", "method", "strict1p", "strict3p", "specifichide", "shide", "ipaddress"]
    private static let knownOptions: Set<String> = Set<String>([
        "third-party", "3p", "first-party", "1p", "match-case", "domain", "from", "script", "image", "font", "media", "popup", "stylesheet", "css", "xmlhttprequest", "xhr", "fetch",
        "websocket", "ping", "other", "subdocument", "document", "doc", "frame", "all", "important", "badfilter", "generichide", "ghide", "elemhide", "ehide", "object", "object-subrequest", "empty", "mp4", "beacon", "webrtc", "csp_report", "inline-script",
    ]).union(rewriteOptions).union(stubOptions).union(linkOptions).union(otherUnsupported)

    /// The types a rule without types would otherwise cover, minus the ones named with `~`.
    private static let allTypes = ["font", "image", "media", "popup", "raw", "script", "style-sheet"]

    // MARK: Entry points

    /// The rules a $badfilter line switches off, as the keys other lines are compared with. Read across every list first, so a list can disable another's rule.
    public static func badfilterTargets(in data: Data) -> Set<String> {
        guard let text = String(data: data, encoding: .utf8), text.contains("badfilter") else { return [] }
        var out = Set<String>()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("!"), line.contains("badfilter") else { continue }
            let (pattern, options) = splitOptions(line)
            guard options.contains("badfilter") else { continue }
            out.insert(key(pattern, options.filter { $0 != "badfilter" }))
        }
        return out
    }

    private static func key(_ pattern: String, _ options: [String]) -> String { pattern.lowercased() + "$" + options.map { $0.lowercased() }.sorted().joined(separator: ",") }

    public static func parse(_ data: Data, name: String, disabled: Set<String> = [], limit: Int = ABPContentParser.limit) -> ClassifiedList {
        var out = ClassifiedList(diagnostics: ListDiagnostics(name: name))
        guard let text = String(data: data, encoding: .utf8) else { out.diagnostics.reject("The list is not readable text", name); return out }
        var hides: [HideItem] = []
        var hideExceptions: [String: (global: Bool, domains: Set<String>)] = [:]
        var scriptletExceptions: [(domains: [String], name: String)] = []
        var genericHideOff = Set<String>(), elemHideOff = Set<String>()
        var kept: [Substring] = []
        var removedAny = false

        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") { kept.append(raw); continue }
            out.diagnostics.lines += 1

            if let marker = cosmeticMarker(in: line) {
                let domainPart = String(line[..<marker.range.lowerBound]), body = String(line[marker.range.upperBound...])
                kept.append(raw)
                handleCosmetic(marker: marker.text, domainPart: domainPart, body: body, line: line, hides: &hides, hideExceptions: &hideExceptions,
                               scriptletExceptions: &scriptletExceptions, out: &out)
                continue
            }

            // Network rule.
            let (patternText, optionList) = splitOptions(line)
            let comparable = key(patternText, optionList.filter { $0 != "badfilter" })
            if optionList.contains("badfilter") { continue }                                                // it only switches another rule off
            if disabled.contains(comparable) { out.diagnostics.disabledByBadfilter += 1; removedAny = true; continue }
            kept.append(raw)
            switch network(line, limit: limit, out: &out, genericHideOff: &genericHideOff, elemHideOff: &elemHideOff) {
            case .domainRule: out.diagnostics.domainRules += 1
            case .done: break
            }
        }

        // Page-element hiding, with the exceptions applied.
        finalizeHides(hides, exceptions: hideExceptions, genericHideOff: genericHideOff, elemHideOff: elemHideOff, out: &out)
        // Scriptlet exceptions.
        if !scriptletExceptions.isEmpty {
            out.scripts.scriptlets = out.scripts.scriptlets.map { rule in
                var rule = rule
                for e in scriptletExceptions where e.name.isEmpty || e.name == rule.name {
                    if e.domains.isEmpty { rule.excludeDomains = ["*"] } else { rule.excludeDomains += e.domains }
                }
                return rule
            }.filter { $0.excludeDomains != ["*"] }
        }
        if removedAny { out.domainText = Data(kept.joined(separator: "\n").utf8) }
        return out
    }

    // MARK: Cosmetic lines

    private struct HideItem { var selector: String; var positive: [String]; var negative: [String] }

    private static func cosmeticMarker(in line: String) -> (range: Range<String.Index>, text: String)? {
        // The earliest "#" that starts one of the markers, and only when what comes before it is a plain list of websites.
        for marker in ["#@?#", "#@$#", "#?#", "#@#", "#$#", "#%#", "##"] {
            if let range = line.range(of: marker) {
                let before = line[..<range.lowerBound]
                if before.allSatisfy({ $0.isLetter || $0.isNumber || ".,~_*-".contains($0) }) { return (range, marker) }
            }
        }
        return nil
    }

    private static func parseDomains(_ text: String) -> (positive: [String], negative: [String])? {
        var positive: [String] = [], negative: [String] = []
        for item in text.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) where !item.isEmpty {
            let isNegative = item.hasPrefix("~")
            let name = isNegative ? String(item.dropFirst()) : item
            guard validDomain(name) else { return nil }
            if isNegative { negative.append(name) } else { positive.append(name) }
        }
        return (positive, negative)
    }

    private static func handleCosmetic(marker: String, domainPart: String, body: String, line: String, hides: inout [HideItem],
                                       hideExceptions: inout [String: (global: Bool, domains: Set<String>)],
                                       scriptletExceptions: inout [(domains: [String], name: String)], out: inout ClassifiedList) {
        guard let domains = parseDomains(domainPart) else { out.diagnostics.reject(badDomain, line); return }
        // Safari-style rules take either websites or exclusions; the allowed websites win, as in the older parser.
        let positive = domains.positive.sorted(), negative = domains.positive.isEmpty ? domains.negative.sorted() : []
        let selector = body.trimmingCharacters(in: .whitespaces)
        guard !selector.isEmpty else { out.diagnostics.reject(badSelector, line); return }

        switch marker {
        case "#$#", "#@$#", "#%#":
            out.diagnostics.reject(otherBlocker, line)
        case "##", "#?#":
            if selector.hasPrefix("+js(") { addScriptlet(selector, positive: positive, negative: negative, line: line, out: &out); return }
            switch classify(selector) {
            case .css:
                hides.append(HideItem(selector: selector, positive: positive, negative: negative))
            case .procedural(let base, let ops, let action, let style):
                guard out.scripts.procedural.count < proceduralLimit else { out.diagnostics.reject("More procedural rules than this browser runs at once", line); return }
                out.scripts.procedural.append(ProceduralRule(domains: positive, excludeDomains: negative, selector: base, ops: ops, action: action, style: style))
                out.diagnostics.procedural += 1
            case .rejected(let reason):
                out.diagnostics.reject(reason, line)
            }
        case "#@#", "#@?#":
            if selector.hasPrefix("+js(") {
                let inner = scriptletParts(selector)
                scriptletExceptions.append((positive, inner?.first.map(canonicalScriptlet) ?? ""))
                out.diagnostics.exceptions += 1
                return
            }
            guard case .css = classify(selector) else { out.diagnostics.reject(proceduralException, line); return }
            var entry = hideExceptions[selector] ?? (false, [])
            if positive.isEmpty { entry.global = true } else { entry.domains.formUnion(positive) }
            hideExceptions[selector] = entry
            out.diagnostics.exceptions += 1
        default:
            out.diagnostics.reject(unsupportedOption, line)
        }
    }

    private enum SelectorKind {
        case css
        case procedural(base: String, ops: [ProceduralOp], action: String, style: String)
        case rejected(String)
    }

    private static let proceduralOnly = [":has-text(", ":contains(", ":-abp-contains(", ":upward(", ":nth-ancestor(", ":xpath(", ":remove(", ":style(", ":matches-css("]
    private static let unsupportedMarkers = [":-abp-properties(", ":matches-css-before(", ":matches-css-after(", ":matches-path(", ":matches-attr(", ":min-text-length(", ":watch-attr(", ":others(", ":matches-media(", ":is-visible(", ":not-visible("]

    private static func classify(_ selector: String) -> SelectorKind {
        guard selector.count <= 300, !selector.contains("{"), !selector.contains("\\") else { return .rejected(badSelector) }
        for marker in unsupportedMarkers where selector.contains(marker) { return .rejected(unsupportedProcedural) }
        let hasProceduralOp = proceduralOnly.contains { selector.contains($0) }
        let usesHas = selector.contains(":has(") || selector.contains(":-abp-has(")
        if !hasProceduralOp && !usesHas { return ABPContentParser.safeSelector(selector) ? .css : .rejected(badSelector) }
        // The base is everything before the first procedural-only operator; the page's own engine runs it (it understands :has itself).
        var firstOp = selector.endIndex
        for marker in proceduralOnly { if let r = selector.range(of: marker), r.lowerBound < firstOp { firstOp = r.lowerBound } }
        let base = String(selector[..<firstOp]).replacingOccurrences(of: ":-abp-has(", with: ":has(").trimmingCharacters(in: .whitespaces)
        // A :has() base is checked as if it were :not(), which has the same shape.
        let checkable = base.replacingOccurrences(of: ":has(", with: ":not(")
        guard base.isEmpty || ABPContentParser.safeSelector(checkable) else { return .rejected(badSelector) }
        var ops: [ProceduralOp] = []
        var rest = String(selector[firstOp...])
        var action = "hide", style = ""
        while !rest.isEmpty {
            guard rest.hasPrefix(":"), let open = rest.firstIndex(of: "("), let close = matchingParen(in: rest, from: open) else { return .rejected(unsupportedProcedural) }
            let name = String(rest[rest.index(after: rest.startIndex)..<open])
            let arg = String(rest[rest.index(after: open)..<close])
            rest = String(rest[rest.index(after: close)...])
            guard arg.count <= 200 else { return .rejected(badSelector) }
            switch name {
            case "has-text", "contains", "-abp-contains":
                if arg.hasPrefix("/") && arg.count > 2 { guard regexLooksSafe(arg) else { return .rejected(badSelector) } }
                ops.append(ProceduralOp(kind: "has-text", arg: arg))
            case "upward": ops.append(ProceduralOp(kind: "upward", arg: arg))
            case "nth-ancestor": guard Int(arg) != nil else { return .rejected(unsupportedProcedural) }; ops.append(ProceduralOp(kind: "nth-ancestor", arg: arg))
            case "xpath": ops.append(ProceduralOp(kind: "xpath", arg: arg))
            case "matches-css": guard arg.contains(":") else { return .rejected(unsupportedProcedural) }; ops.append(ProceduralOp(kind: "matches-css", arg: arg))
            case "remove": guard arg.isEmpty, rest.isEmpty else { return .rejected(unsupportedProcedural) }; action = "remove"
            case "style":
                guard rest.isEmpty, safeStyle(arg) else { return .rejected(unsupportedProcedural) }
                action = "style"; style = arg
            default: return .rejected(unsupportedProcedural)
            }
        }
        if base.isEmpty && ops.first?.kind != "xpath" { return .rejected(unsupportedProcedural) }
        return .procedural(base: base, ops: ops, action: action, style: style)
    }

    private static func matchingParen(in text: String, from open: String.Index) -> String.Index? {
        var depth = 0
        var quote: Character?
        var index = open
        while index < text.endIndex {
            let ch = text[index]
            if let q = quote { if ch == q { quote = nil } }
            else if ch == "\"" || ch == "'" { quote = ch }
            else if ch == "(" { depth += 1 }
            else if ch == ")" { depth -= 1; if depth == 0 { return index } }
            index = text.index(after: index)
        }
        return nil
    }

    /// A style a procedural :style() may apply: only properties that change how an element is shown, and plain values.
    private static func safeStyle(_ css: String) -> Bool {
        let allowed: Set<String> = ["display", "visibility", "opacity", "height", "min-height", "max-height", "width", "max-width", "position", "overflow", "pointer-events", "filter",
                                    "margin", "margin-top", "margin-bottom", "padding", "padding-top", "padding-bottom", "z-index", "top", "bottom", "background", "background-color"]
        let parts = css.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty, parts.count <= 6 else { return false }
        for part in parts {
            let pair = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, allowed.contains(pair[0].lowercased()), pair[1].count <= 60,
                  pair[1].allSatisfy({ $0.isLetter || $0.isNumber || " .,%-#!()".contains($0) }), !pair[1].lowercased().contains("url(") else { return false }
        }
        return true
    }

    private static func regexLooksSafe(_ arg: String) -> Bool {
        guard arg.hasPrefix("/"), let close = arg.lastIndex(of: "/"), close > arg.startIndex else { return false }
        let body = String(arg[arg.index(after: arg.startIndex)..<close])
        guard !body.isEmpty, body.count <= 120, (try? NSRegularExpression(pattern: body)) != nil else { return false }
        // Nested quantifiers are what makes a regular expression slow on a long page.
        return body.range(of: #"[+*]\)?[+*]"#, options: .regularExpression) == nil && body.range(of: #"\([^)]*[+*][^)]*\)[+*]"#, options: .regularExpression) == nil
    }

    // MARK: Scriptlets

    private static let scriptletAliases: [String: String] = [
        "set": "set-constant", "set-constant": "set-constant",
        "aopr": "abort-on-property-read", "abort-on-property-read": "abort-on-property-read",
        "aopw": "abort-on-property-write", "abort-on-property-write": "abort-on-property-write",
        "nostif": "no-setTimeout-if", "no-settimeout-if": "no-setTimeout-if",
        "nosiif": "no-setInterval-if", "no-setinterval-if": "no-setInterval-if",
        "ra": "remove-attr", "remove-attr": "remove-attr",
        "rc": "remove-class", "remove-class": "remove-class",
    ]

    /// The scriptlets this browser provides, by their uBlock Origin names.
    public static let providedScriptlets = ["set-constant", "abort-on-property-read", "abort-on-property-write", "no-setTimeout-if", "no-setInterval-if", "remove-attr", "remove-class"]

    private static func canonicalScriptlet(_ name: String) -> String {
        var n = name.lowercased()
        if n.hasSuffix(".js") { n.removeLast(3) }
        if n.hasPrefix("ubo-") { n.removeFirst(4) }
        return scriptletAliases[n] ?? ""
    }

    private static func scriptletParts(_ selector: String) -> [String]? {
        guard selector.hasPrefix("+js("), selector.hasSuffix(")") else { return nil }
        let inner = String(selector.dropFirst(4).dropLast())
        var parts: [String] = [], current = ""
        var escaped = false
        for ch in inner {
            if escaped { current.append(ch); escaped = false }
            else if ch == "\\" { escaped = true }
            else if ch == "," { parts.append(current.trimmingCharacters(in: .whitespaces)); current = "" }
            else { current.append(ch) }
        }
        parts.append(current.trimmingCharacters(in: .whitespaces))
        return parts.filter { !$0.isEmpty }
    }

    private static func addScriptlet(_ selector: String, positive: [String], negative: [String], line: String, out: inout ClassifiedList) {
        guard let parts = scriptletParts(selector), let first = parts.first else { out.diagnostics.reject(unknownScriptlet, line); return }
        let name = canonicalScriptlet(first)
        guard !name.isEmpty else { out.diagnostics.reject(unknownScriptlet + " (\(first.prefix(40)))", line); return }
        let args = Array(parts.dropFirst().prefix(4)).map { String($0.prefix(200)) }
        guard !args.isEmpty else { out.diagnostics.reject(unknownScriptlet, line); return }
        guard out.scripts.scriptlets.count < scriptletLimit else { out.diagnostics.reject("More scriptlets than this browser runs at once", line); return }
        out.scripts.scriptlets.append(ScriptletRule(domains: positive, excludeDomains: negative, name: name, args: args))
        out.diagnostics.scriptlets += 1
    }

    // MARK: Hiding, with exceptions applied

    private static func finalizeHides(_ items: [HideItem], exceptions: [String: (global: Bool, domains: Set<String>)], genericHideOff: Set<String>, elemHideOff: Set<String>, out: inout ClassifiedList) {
        struct Group { var ifDomains: Bool; var domains: [String]; var selectors: Set<String> }
        var groups: [String: Group] = [:]
        func covers(_ domain: String, _ off: String) -> Bool { domain == off || domain.hasSuffix("." + off) }
        for item in items {
            let exception = exceptions[item.selector]
            if exception?.global == true { continue }
            var extra = (exception?.domains ?? []).union(elemHideOff)
            if item.positive.isEmpty { extra.formUnion(genericHideOff) }
            if !item.positive.isEmpty {
                let left = item.positive.filter { p in !extra.contains { covers(p, $0) } }
                guard !left.isEmpty else { continue }
                let k = "if:" + left.joined(separator: ",")
                groups[k, default: Group(ifDomains: true, domains: left, selectors: [])].selectors.insert(item.selector)
            } else {
                let unless = Array(Set(item.negative).union(extra)).sorted()
                let k = "unless:" + unless.joined(separator: ",")
                groups[k, default: Group(ifDomains: false, domains: unless, selectors: [])].selectors.insert(item.selector)
            }
        }
        for (_, group) in groups.sorted(by: { $0.key < $1.key }) {
            let sorted = group.selectors.sorted()
            for start in stride(from: 0, to: sorted.count, by: selectorsPerRule) {
                guard out.content.hides.count < ABPContentParser.limit else { return }
                let chunk = Array(sorted[start..<min(start + selectorsPerRule, sorted.count)])
                var trigger: [String: Any] = ["url-filter": ".*"]
                if !group.domains.isEmpty { trigger[group.ifDomains ? "if-domain" : "unless-domain"] = group.domains.map { "*" + $0 } }
                if let rule = json(["trigger": trigger, "action": ["type": "css-display-none", "selector": chunk.joined(separator: ", ")]]) {
                    out.content.hides.append(rule)
                    out.diagnostics.cosmetic += chunk.count
                }
            }
        }
    }

    // MARK: Network rules

    private enum NetworkResult { case domainRule, done }

    /// Splits a rule into its pattern and its options. A `$` only starts options when every part after it looks like one.
    static func splitOptions(_ original: String) -> (String, [String]) {
        if original.hasPrefix("@@") { let inner = splitOptionsInner(String(original.dropFirst(2))); return ("@@" + inner.0, inner.1) }
        return splitOptionsInner(original)
    }

    private static func splitOptionsInner(_ line: String) -> (String, [String]) {
        guard let dollar = line.lastIndex(of: "$") else { return (line, []) }
        let tail = String(line[line.index(after: dollar)...])
        if tail.contains("/") && !tail.contains("=") { return (line, []) }
        let parts = tail.split(separator: ",").map(String.init)
        guard !parts.isEmpty, parts.allSatisfy(looksLikeOption) else { return (line, []) }
        return (String(line[..<dollar]), parts)
    }

    private static func looksLikeOption(_ part: String) -> Bool {
        let name = part.hasPrefix("~") ? String(part.dropFirst()) : part
        let key = name.split(separator: "=", maxSplits: 1).first.map(String.init) ?? name
        return knownOptions.contains(key.lowercased())
    }

    private static func network(_ original: String, limit: Int, out: inout ClassifiedList, genericHideOff: inout Set<String>, elemHideOff: inout Set<String>) -> NetworkResult {
        var line = original
        var isAllow = false
        if line.hasPrefix("@@") { isAllow = true; line = String(line.dropFirst(2)) }
        let (pattern, options) = splitOptionsInner(line)
        line = pattern

        var loadType: String?
        var positiveTypes: [String] = [], negatedTypes: [String] = []
        var documentTypes = Set<String>()                         // "top-frame" / "child-frame"
        var ifDomains: [String] = [], unlessDomains: [String] = []
        var caseSensitive = false, important = false, genericOff = false, elemOff = false

        for option in options {
            let negated = option.hasPrefix("~")
            let name = (negated ? String(option.dropFirst()) : option).lowercased()
            let key = name.split(separator: "=", maxSplits: 1).first.map(String.init) ?? name
            if rewriteOptions.contains(key) { out.diagnostics.reject(rewritesResponse, original); return .done }
            if stubOptions.contains(key) { out.diagnostics.reject(needsStub, original); return .done }
            if linkOptions.contains(key) { out.diagnostics.reject(rewritesLink, original); return .done }
            if otherUnsupported.contains(key) { out.diagnostics.reject(unsupportedOption + " ($\(key))", original); return .done }
            switch key {
            case "third-party", "3p": loadType = negated ? "first-party" : "third-party"
            case "first-party", "1p": loadType = negated ? "third-party" : "first-party"
            case "match-case": caseSensitive = true
            case "important": important = true
            case "badfilter": break
            case "domain", "from":
                for entry in name.dropFirst(key.count + 1).split(separator: "|").map(String.init) {
                    let neg = entry.hasPrefix("~"); let host = neg ? String(entry.dropFirst()) : entry
                    guard validDomain(host) else { out.diagnostics.reject(badDomain, original); return .done }
                    if neg { unlessDomains.append(host) } else { ifDomains.append(host) }
                }
            case "script", "image", "font", "media", "popup": if negated { negatedTypes.append(key) } else { positiveTypes.append(key) }
            case "stylesheet", "css": if negated { negatedTypes.append("style-sheet") } else { positiveTypes.append("style-sheet") }
            case "xmlhttprequest", "xhr", "fetch", "websocket", "ping", "other", "beacon", "object", "object-subrequest", "csp_report", "webrtc", "empty", "mp4":
                if negated { negatedTypes.append("raw") } else { positiveTypes.append("raw") }
            case "document", "doc": if negated { break } else { documentTypes.insert("top-frame") }
            case "subdocument", "frame": if negated { break } else { documentTypes.insert("child-frame") }
            case "all": documentTypes.formUnion(["top-frame", "child-frame"]); positiveTypes += allTypes
            case "generichide", "ghide": genericOff = true
            case "elemhide", "ehide": elemOff = true
            default: out.diagnostics.reject(unsupportedOption + " ($\(key))", original); return .done
            }
        }
        if !ifDomains.isEmpty && !unlessDomains.isEmpty { out.diagnostics.reject(mixedDomains, original); return .done }

        // An exception that switches filtering off for a whole page: @@||example.com^$document, $generichide, $elemhide.
        if isAllow, (documentTypes.contains("top-frame") || genericOff || elemOff), let host = plainHost(line) {
            if genericOff { genericHideOff.insert(host) }
            if elemOff { elemHideOff.insert(host) }
            if documentTypes.contains("top-frame") {
                elemHideOff.insert(host)
                if let rule = json(["trigger": ["url-filter": ".*", "if-domain": ["*" + host]], "action": ["type": "ignore-previous-rules"]]), out.content.allows.count < limit {
                    out.content.allows.append(rule); out.diagnostics.exceptions += 1
                }
            } else { out.diagnostics.exceptions += 1 }
            return .done
        }
        if genericOff || elemOff { out.diagnostics.reject(unsupportedOption, original); return .done }

        // A bare ||domain^ with no options is exactly a domain rule; the domain parser has it.
        if options.isEmpty, line.hasPrefix("||"), line.hasSuffix("^"), !line.dropFirst(2).dropLast().contains(where: { "/*^|?=&:".contains($0) }) { return .domainRule }

        // Which resource types, and which loading contexts.
        var types = Array(Set(positiveTypes)).sorted()
        if types.isEmpty, !negatedTypes.isEmpty { types = allTypes.filter { !negatedTypes.contains($0) } }
        else if !negatedTypes.isEmpty { types = types.filter { !negatedTypes.contains($0) } }
        if !positiveTypes.isEmpty || !negatedTypes.isEmpty, types.isEmpty, documentTypes.isEmpty { out.diagnostics.reject(unsupportedOption, original); return .done }

        // The URL patterns: a /regex/ becomes one pattern per alternative it can be written as.
        var patterns: [String]
        if line.count > 2, line.hasPrefix("/"), line.hasSuffix("/") {
            guard let expanded = regexPatterns(String(line.dropFirst().dropLast())) else { out.diagnostics.reject(regexTooComplex, original); return .done }
            patterns = expanded
        } else {
            guard !line.isEmpty, let one = urlFilter(for: line) else { out.diagnostics.reject(tooBroad, original); return .done }
            patterns = [one]
        }

        func trigger(_ pattern: String, types: [String], context: String?) -> [String: Any] {
            var t: [String: Any] = ["url-filter": pattern]
            if let loadType { t["load-type"] = [loadType] }
            if !types.isEmpty { t["resource-type"] = types }
            if let context { t["load-context"] = [context] }
            if !ifDomains.isEmpty { t["if-domain"] = ifDomains.sorted().map { "*" + $0 } }
            if !unlessDomains.isEmpty { t["unless-domain"] = unlessDomains.sorted().map { "*" + $0 } }
            if caseSensitive { t["url-filter-is-case-sensitive"] = true }
            return t
        }
        var rules: [String] = []
        let action: [String: Any] = ["type": isAllow ? "ignore-previous-rules" : "block"]
        for pattern in patterns {
            if documentTypes.isEmpty || !types.isEmpty { if let r = json(["trigger": trigger(pattern, types: types, context: nil), "action": action]) { rules.append(r) } }
            for context in documentTypes.sorted() {
                if let r = json(["trigger": trigger(pattern, types: ["document"], context: context), "action": action]) { rules.append(r) }
            }
        }
        guard !rules.isEmpty else { out.diagnostics.reject(unsupportedOption, original); return .done }
        for rule in rules {
            if isAllow { if out.content.allows.count < limit { out.content.allows.append(rule); out.diagnostics.exceptions += 1 } }
            else if important { if out.important.count < importantLimit { out.important.append(rule); out.diagnostics.important += 1 } }
            else if out.content.blocks.count < limit { out.content.blocks.append(rule); out.diagnostics.network += 1 }
        }
        return .done
    }

    /// The host of a plain `||host^` pattern, or nil when the pattern says more than a website.
    private static func plainHost(_ pattern: String) -> String? {
        guard pattern.hasPrefix("||") else { return nil }
        var rest = String(pattern.dropFirst(2))
        if rest.hasSuffix("^") { rest.removeLast() }
        if rest.hasSuffix("/") { rest.removeLast() }
        let host = rest.lowercased()
        return validDomain(host) ? host : nil
    }

    /// Adblock pattern -> the small regular-expression dialect WebKit accepts.
    private static func urlFilter(for pattern: String) -> String? {
        var text = pattern
        var prefix = "", suffix = ""
        if text.hasPrefix("||") { prefix = "^https?://([^/]+\\.)?"; text.removeFirst(2) }
        else if text.hasPrefix("|") { prefix = "^"; text.removeFirst() }
        if text.hasSuffix("|") { suffix = "$"; text.removeLast() }
        guard !text.isEmpty, text.count <= 160 else { return nil }
        let literal = text.filter { $0 != "*" && $0 != "^" }
        guard literal.count >= 3 else { return nil }
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
        return prefix + out + suffix
    }

    // MARK: Regular-expression filters

    /// A filter written as /regex/ in the rule language WebKit allows: literals, `.`, `*` `+` `?` after one character or class, `[...]` classes, `\d` `\w` and escaped
    /// punctuation, a leading `^`, a trailing `$`, and alternatives in a group or at the top level, which become one rule each (up to eight). Anything else is refused: a
    /// pattern WebKit rejects would make it refuse the whole list.
    static func regexPatterns(_ body: String) -> [String]? {
        guard !body.isEmpty, body.count <= 200 else { return nil }
        // Alternatives at the top level, and one level of group with alternatives.
        guard let alternatives = expandAlternatives(body), !alternatives.isEmpty, alternatives.count <= 8 else { return nil }
        var out: [String] = []
        for alt in alternatives {
            guard let translated = translateRegex(alt) else { return nil }
            out.append(translated)
        }
        return out
    }

    private static func splitTopLevel(_ text: String) -> [String]? {
        var parts: [String] = [], current = ""
        var depth = 0, inClass = false, escaped = false
        for ch in text {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" { current.append(ch); escaped = true; continue }
            if inClass { current.append(ch); if ch == "]" { inClass = false }; continue }
            switch ch {
            case "[": inClass = true; current.append(ch)
            case "(": depth += 1; current.append(ch)
            case ")": depth -= 1; if depth < 0 { return nil }; current.append(ch)
            case "|": if depth == 0 { parts.append(current); current = "" } else { current.append(ch) }
            default: current.append(ch)
            }
        }
        guard depth == 0, !inClass else { return nil }
        parts.append(current)
        return parts
    }

    private static func expandAlternatives(_ body: String) -> [String]? {
        guard let top = splitTopLevel(body) else { return nil }
        var results: [String] = []
        for part in top {
            // One group with alternatives: a(b|c)d -> abd, acd.
            guard let open = firstUnescaped("(", in: part) else { results.append(part); continue }
            guard let close = matchingClose(in: part, from: open) else { return nil }
            let before = String(part[..<open])
            var inner = String(part[part.index(after: open)..<close])
            let after = String(part[part.index(after: close)...])
            if inner.hasPrefix("?:") { inner.removeFirst(2) }
            if inner.hasPrefix("?") { return nil }                                 // lookahead and friends
            if let next = after.first, "*+?{".contains(next) { return nil }       // a quantified group
            guard let options = splitTopLevel(inner), !options.contains(where: { $0.contains("(") }) else { return nil }
            guard let tail = expandAlternatives(after) else { return nil }
            for option in options { for t in tail { results.append(before + option + t) } }
        }
        return results.count <= 8 ? results : nil
    }

    private static func firstUnescaped(_ target: Character, in text: String) -> String.Index? {
        var escaped = false, inClass = false
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            if escaped { escaped = false }
            else if ch == "\\" { escaped = true }
            else if inClass { if ch == "]" { inClass = false } }
            else if ch == "[" { inClass = true }
            else if ch == target { return index }
            index = text.index(after: index)
        }
        return nil
    }

    private static func matchingClose(in text: String, from open: String.Index) -> String.Index? {
        var depth = 0, escaped = false, inClass = false
        var index = open
        while index < text.endIndex {
            let ch = text[index]
            if escaped { escaped = false }
            else if ch == "\\" { escaped = true }
            else if inClass { if ch == "]" { inClass = false } }
            else if ch == "[" { inClass = true }
            else if ch == "(" { depth += 1 }
            else if ch == ")" { depth -= 1; if depth == 0 { return index } }
            index = text.index(after: index)
        }
        return nil
    }

    private static func translateRegex(_ source: String) -> String? {
        var text = Array(source)
        var out = ""
        var literals = 0
        var i = 0
        if text.first == "^" { out += "^"; i = 1 }
        var anchoredEnd = false
        if text.last == "$", text.count > i { text.removeLast(); anchoredEnd = true }
        var lastWasAtom = false
        while i < text.count {
            let c = text[i]
            switch c {
            case "\\":
                guard i + 1 < text.count else { return nil }
                let n = text[i + 1]
                switch n {
                case "d": out += "[0-9]"; lastWasAtom = true
                case "w": out += "[a-zA-Z0-9_]"; lastWasAtom = true
                case ".", "/", "-", "?", "+", "*", "(", ")", "[", "]", "{", "}", "|", "$", "^", ":", "=", "&", "%", "_", "~", "!", "@", "#", ",", ";", "'", "\"": out += "\\" + String(n); lastWasAtom = true; literals += 1
                default: return nil                                                     // \b \s \D \1 and the like
                }
                i += 2
            case ".": out += "."; lastWasAtom = true; i += 1
            case "*", "+", "?":
                guard lastWasAtom else { return nil }
                // A lazy or possessive quantifier is not something WebKit has.
                if i + 1 < text.count, "?+".contains(text[i + 1]) { return nil }
                out.append(c); lastWasAtom = false; i += 1
            case "[":
                guard let end = text[(i + 1)...].firstIndex(of: "]"), end > i + 1 else { return nil }
                var body = String(text[(i + 1)..<end])
                var negate = ""
                if body.hasPrefix("^") { negate = "^"; body.removeFirst() }
                guard !body.isEmpty, body.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_./:=&%".contains($0)) }) else { return nil }
                out += "[" + negate + body + "]"; lastWasAtom = true; i = end + 1
            case "(", ")", "{", "}", "|", "^", "$": return nil
            default:
                guard c.isASCII, !c.isWhitespace else { return nil }
                out.append(c); lastWasAtom = true; literals += 1; i += 1
            }
        }
        if anchoredEnd { out += "$" }
        guard literals >= 3 else { return nil }                                          // would match far too much
        return out
    }

    // MARK: Helpers

    static func validDomain(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 253 && name.contains(".") && name.utf8.allSatisfy { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 46 }
    }

    private static func json(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
