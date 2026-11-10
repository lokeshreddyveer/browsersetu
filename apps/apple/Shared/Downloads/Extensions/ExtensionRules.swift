import Foundation

/// What a download extension is: a file of rules. A rule says "for addresses like this, suggest that" and nothing else. There is no code to run, so there is nothing to escape from;
/// the limits here (rule count, template size, time) are what keep a rule file from being a burden, and the checks at the end keep what it suggests inside what it declared.
struct ExtensionRuleSet: Equatable, Sendable {
    static let maxBytes = 64 * 1024
    static let maxRules = 100
    static let maxTemplate = 512
    static let maxResources = 20

    enum Token: Equatable, Sendable {
        case url, scheme, host, path, segment(Int), last, query(String), fragment, setting(String)
    }
    enum Part: Equatable, Sendable { case literal(String), token(Token) }

    struct Template: Equatable, Sendable {
        var parts: [Part]
        var tokens: [Token] { parts.compactMap { if case .token(let t) = $0 { t } else { nil } } }

        static func parse(_ text: String, knownSettings: Set<String>) -> Template? {
            guard text.utf8.count <= ExtensionRuleSet.maxTemplate, !text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
            var parts: [Part] = [], literal = "", i = text.startIndex
            while i < text.endIndex {
                if text[i] == "{" {
                    guard let close = text[i...].firstIndex(of: "}") else { return nil }
                    let name = String(text[text.index(after: i)..<close])
                    guard let token = token(named: name, knownSettings: knownSettings) else { return nil }
                    if !literal.isEmpty { parts.append(.literal(literal)); literal = "" }
                    parts.append(.token(token)); i = text.index(after: close)
                } else if text[i] == "}" { return nil }
                else { literal.append(text[i]); i = text.index(after: i) }
            }
            if !literal.isEmpty { parts.append(.literal(literal)) }
            return Template(parts: parts)
        }

        private static func token(named n: String, knownSettings: Set<String>) -> Token? {
            switch n {
            case "url": return .url
            case "scheme": return .scheme
            case "host": return .host
            case "path": return .path
            case "last": return .last
            case "fragment": return .fragment
            default:
                if n.hasPrefix("path."), let k = Int(n.dropFirst(5)), (1...20).contains(k) { return .segment(k) }
                if n.hasPrefix("query."), n.count <= 40, n.dropFirst(6).allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }), n.count > 6 { return .query(String(n.dropFirst(6))) }
                if n.hasPrefix("setting."), knownSettings.contains(String(n.dropFirst(8))) { return .setting(String(n.dropFirst(8))) }
                return nil
            }
        }

        /// For an address template: the scheme and host must be written out, not filled in. The hosts an extension can suggest are then known from its files alone.
        var hasLiteralOrigin: Bool {
            guard case .literal(let first)? = parts.first, let r = first.range(of: "://") else { return false }
            return first[r.upperBound...].contains("/")
        }
        var literalOrigin: String? {
            guard hasLiteralOrigin, case .literal(let first)? = parts.first, let r = first.range(of: "://"), let slash = first[r.upperBound...].firstIndex(of: "/") else { return nil }
            return String(first[..<slash]) + "/"
        }
    }

    struct Resource: Equatable, Sendable {
        var url: Template
        var filename: Template?
        var mimeType: String?
        var size: Int64?
        var title: Template?
    }

    struct Rule: Equatable, Sendable {
        var id: String
        var match: ExtensionMatchPattern
        var resources: [Resource]
        var filename: Template?
        var category: DownloadCategory?
    }

    var rules: [Rule]

    enum Failure: Error, Equatable, LocalizedError {
        case tooLarge, notJSON, tooMany(String), invalid(String)
        var errorDescription: String? {
            switch self {
            case .tooLarge: "The extension's rule file is larger than is allowed."
            case .notJSON: "The extension's rule file is not valid JSON."
            case .tooMany(let what): "The extension's rule file has too many \(what)."
            case .invalid(let why): "The extension's rule file is not valid: \(why)."
            }
        }
    }

    /// Reads and checks a rule file against the manifest that declares it: every rule has to stay inside the addresses the extension may read and the hosts it may suggest.
    static func parse(_ data: Data, manifest: ExtensionManifest) throws -> ExtensionRuleSet {
        guard data.count <= maxBytes else { throw Failure.tooLarge }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw Failure.notJSON }
        guard let list = root["rules"] as? [[String: Any]] else { throw Failure.invalid("there is no list of rules") }
        guard list.count <= maxRules else { throw Failure.tooMany("rules") }
        let known = Set(manifest.settings.map(\.name))
        let readable = manifest.hostPermissions + manifest.optionalHostPermissions
        var seen = Set<String>(), rules: [Rule] = []
        for (n, r) in list.enumerated() {
            let id = (r["id"] as? String).map { String(ExtensionText.clean($0).prefix(40)) } ?? "rule\(n + 1)"
            guard seen.insert(id).inserted else { throw Failure.invalid("rule “\(id)” appears twice") }
            guard let m = r["match"] as? String, let match = ExtensionMatchPattern.parse(m) else { throw Failure.invalid("rule “\(id)” has no valid match pattern") }
            guard readable.contains(where: { $0.covers(match) }) else { throw Failure.invalid("rule “\(id)” matches addresses the extension did not ask permission to read") }
            var resources: [Resource] = []
            if let res = r["resolve"] as? [String: Any] {
                guard manifest.capabilities.contains(.resolve) else { throw Failure.invalid("rule “\(id)” suggests addresses but the extension did not declare that capability") }
                var items = [res]
                if let more = res["resources"] as? [[String: Any]] { guard more.count <= maxResources else { throw Failure.tooMany("resources in rule “\(id)”") }; items = more }
                for item in items { resources.append(try resource(item, rule: id, manifest: manifest, known: known)) }
            }
            var filename: Template?
            if let f = r["filename"] as? String {
                guard manifest.capabilities.contains(.filename) else { throw Failure.invalid("rule “\(id)” suggests a file name but the extension did not declare that capability") }
                guard let t = Template.parse(f, knownSettings: known) else { throw Failure.invalid("rule “\(id)” has an unusable file name template") }
                filename = t
            }
            var category: DownloadCategory?
            if let c = r["category"] as? String {
                guard manifest.capabilities.contains(.category) else { throw Failure.invalid("rule “\(id)” suggests a kind but the extension did not declare that capability") }
                guard let k = DownloadCategory.allCases.first(where: { $0.rawValue == c }) else { throw Failure.invalid("rule “\(id)” names an unknown kind") }
                category = k
            }
            guard !resources.isEmpty || filename != nil || category != nil else { throw Failure.invalid("rule “\(id)” suggests nothing") }
            rules.append(Rule(id: id, match: match, resources: resources, filename: filename, category: category))
        }
        return ExtensionRuleSet(rules: rules)
    }

    private static func resource(_ d: [String: Any], rule: String, manifest: ExtensionManifest, known: Set<String>) throws -> Resource {
        guard let u = d["url"] as? String, let url = Template.parse(u, knownSettings: known), url.hasLiteralOrigin, let origin = url.literalOrigin,
              let probe = URL(string: origin), let scheme = probe.scheme, let host = probe.host, ["http", "https"].contains(scheme.lowercased()) else {
            throw Failure.invalid("rule “\(rule)” has an address template whose scheme and host are not written out")
        }
        guard manifest.proposeHosts.contains(where: { $0.hostMatches(host.lowercased()) && ($0.scheme == "*" || $0.scheme == scheme.lowercased()) }) else {
            throw Failure.invalid("rule “\(rule)” suggests a host (\(host)) that the manifest does not list in proposeHosts")
        }
        var name: Template?
        if let f = d["filename"] as? String { guard let t = Template.parse(f, knownSettings: known) else { throw Failure.invalid("rule “\(rule)” has an unusable file name template") }; name = t }
        var title: Template?
        if let t = d["title"] as? String { guard let tt = Template.parse(t, knownSettings: known) else { throw Failure.invalid("rule “\(rule)” has an unusable title template") }; title = tt }
        var mime: String?
        if let m = d["mimeType"] as? String { guard m.range(of: #"^[a-z0-9.+-]{1,40}/[a-z0-9.+-]{1,60}\z"#, options: .regularExpression) != nil else { throw Failure.invalid("rule “\(rule)” has an unusable MIME type") }; mime = m }
        var size: Int64?
        if let s = d["size"] as? Int { guard (0...(1 << 40)).contains(s) else { throw Failure.invalid("rule “\(rule)” has an unusable size") }; size = Int64(s) }
        return Resource(url: url, filename: name, mimeType: mime, size: size, title: title)
    }
}

/// What an extension suggested. A suggestion is information: it can be shown, copied or declined, and it never starts anything.
struct ExtensionProposal: Equatable, Identifiable, Sendable {
    struct Resource: Equatable, Sendable {
        var url: URL
        var filename: String?
        var mimeType: String?
        var size: Int64?
        var title: String?
    }
    /// Who suggested it, kept with the suggestion for as long as it exists.
    struct Provenance: Equatable, Sendable { var extensionID: String; var extensionName: String; var version: String; var rule: String }

    var id: String { provenance.extensionID + "/" + provenance.rule }
    var provenance: Provenance
    var resources: [Resource]
    var filename: String?
    var category: DownloadCategory?
    /// The origin class any download made from this suggestion would carry: never the person's own.
    var origin: DownloadRequestOrigin { .browserExtension }
}

enum ExtensionRuleEngine {
    static let maxInputURL = 2048
    static let maxSettingValue = 256
    static let defaultBudget: TimeInterval = 0.05

    struct Outcome: Equatable, Sendable {
        var proposals: [ExtensionProposal] = []
        var dropped: [String] = []                     // what was left out and why (no addresses, so safe to show)
        var timedOut = false
    }

    /// Runs the rules of one extension against an address the person gave. Only what the extension was granted is used; every suggestion is checked again here before it leaves.
    static func evaluate(manifest: ExtensionManifest, rules: ExtensionRuleSet, input: URL, grantedCapabilities: Set<ExtensionManifest.Capability>, grantedHosts: [ExtensionMatchPattern],
                         settings: [String: String], clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, budget: TimeInterval = defaultBudget) -> Outcome {
        var out = Outcome()
        guard input.absoluteString.utf8.count <= maxInputURL, let scheme = input.scheme?.lowercased(), scheme == "http" || scheme == "https", input.host != nil else { out.dropped.append("the address is not usable"); return out }
        // The extension sees this address only if it was granted access to it.
        guard grantedHosts.contains(where: { $0.matches(input) }) else { return out }
        let started = clock()
        let ctx = Context(url: input, settings: settings)
        for rule in rules.rules {
            if clock() - started > budget { out.timedOut = true; out.dropped.append("ran out of time"); break }
            guard rule.match.matches(input), grantedHosts.contains(where: { $0.covers(rule.match) || $0.matches(input) }) else { continue }
            var proposal = ExtensionProposal(provenance: .init(extensionID: manifest.id, extensionName: manifest.name, version: manifest.version, rule: rule.id), resources: [], filename: nil, category: nil)
            if grantedCapabilities.contains(.resolve) {
                for r in rule.resources {
                    guard let urlText = expand(r.url, ctx, .url), let url = validated(urlText, proposeHosts: manifest.proposeHosts) else { out.dropped.append("a suggested address in “\(rule.id)” was not allowed"); continue }
                    let name = r.filename.flatMap { expand($0, ctx, .text) }.flatMap(DownloadFilename.sanitize)
                    let title = r.title.flatMap { expand($0, ctx, .text) }.map { String(ExtensionText.clean($0).prefix(120)) }
                    if !proposal.resources.contains(where: { $0.url == url }) && proposal.resources.count < ExtensionRuleSet.maxResources {
                        proposal.resources.append(.init(url: url, filename: name, mimeType: r.mimeType, size: r.size, title: title))
                    }
                }
            }
            if grantedCapabilities.contains(.filename), let f = rule.filename { proposal.filename = expand(f, ctx, .text).flatMap(DownloadFilename.sanitize) }
            if grantedCapabilities.contains(.category) { proposal.category = rule.category }
            if !proposal.resources.isEmpty || proposal.filename != nil || proposal.category != nil { out.proposals.append(proposal) }
        }
        return out
    }

    // MARK: Expansion

    private struct Context {
        let url: URL
        let settings: [String: String]
        let segments: [String]
        let query: [String: String]
        init(url: URL, settings: [String: String]) {
            self.url = url; self.settings = settings
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            segments = (comps?.path ?? "").split(separator: "/", omittingEmptySubsequences: true).map { String($0).removingPercentEncoding ?? String($0) }
            var q: [String: String] = [:]
            for item in comps?.queryItems ?? [] where q[item.name] == nil { q[item.name] = item.value ?? "" }
            query = q
        }
    }
    private enum Mode { case url, text }

    /// Nil when a value the template needs is not there (the rule then suggests nothing).
    private static func expand(_ t: ExtensionRuleSet.Template, _ c: Context, _ mode: Mode) -> String? {
        var out = ""
        for part in t.parts {
            switch part {
            case .literal(let s): out += s
            case .token(let token):
                guard let raw = value(of: token, c) else { return nil }
                if mode == .url, raw == "." || raw == ".." { return nil }          // a dot segment would change the path
                out += mode == .url ? encode(raw) : raw
            }
            if out.utf8.count > 4096 { return nil }
        }
        return out
    }

    private static func value(of token: ExtensionRuleSet.Token, _ c: Context) -> String? {
        switch token {
        case .url:
            // The address as given, without a name and password or a fragment: a suggestion never carries the person's credentials onward.
            var comps = URLComponents(url: c.url, resolvingAgainstBaseURL: false); comps?.user = nil; comps?.password = nil; comps?.fragment = nil
            return comps?.url?.absoluteString
        case .scheme: return c.url.scheme
        case .host: return c.url.host
        case .path: return c.segments.joined(separator: "/")
        case .segment(let n): return n <= c.segments.count ? c.segments[n - 1] : nil
        case .last: return c.segments.last
        case .query(let name): return c.query[name]
        case .fragment: return c.url.fragment
        case .setting(let name): return c.settings[name].map { String($0.prefix(maxSettingValue)) }
        }
    }

    /// Everything a value could use to change the shape of an address is encoded: it can fill in a name or a number, never a host, a path separator or a second parameter.
    private static func encode(_ s: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")          // ASCII only: anything else is percent-encoded
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    /// The final check on an address an extension suggested, independent of how the template was written.
    static func validated(_ text: String, proposeHosts: [ExtensionMatchPattern]) -> URL? {
        guard text.utf8.count <= 2048, let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil, !HostLiteral.isNumeric(host), !HTTPRequestPolicy.classify(host: host).isInternal, host.contains(".") else { return nil }
        guard proposeHosts.contains(where: { $0.matches(url) }) else { return nil }          // scheme, host AND path must be inside what the manifest listed
        return url
    }
}
