import Foundation

public enum FilterAction: String, Codable, CaseIterable, Sendable { case block, allow }
public enum FilterScope: String, Codable, CaseIterable, Sendable { case exact, domainAndSubdomains
    public var label: String { self == .exact ? "Exact" : "Domain + subdomains" }
}
public enum FilterTier: String, Codable, Sendable { case user, subscription }
public enum FilteringIssue: Error, LocalizedError {
    case invalidDomain, unsupportedSyntax, capacity, empty, tooLarge
    public var errorDescription: String? {
        switch self {
        case .invalidDomain: return "Enter a valid registrable hostname. Public suffixes, IP addresses and wildcards are not allowed."
        case .unsupportedSyntax: return "This format contains unsupported filtering syntax. Import hosts, domain lists or ||domain^ rules."
        case .capacity: return "This ruleset exceeds VayuSetu’s source-domain or compiled-rule safety budget. The previous ruleset is preserved."
        case .empty: return "No supported domain rules were found."
        case .tooLarge: return "Choose a UTF-8 filter list no larger than 8 MB."
        }
    }
}
public enum FilterDomain {
    private static let suffixes = Set(PublicSuffixData.rules.split(separator: "\n").map { raw -> String in
        let value = String(raw); let prefix = value.hasPrefix("*.") ? "*." : value.hasPrefix("!") ? "!" : ""
        let domain = String(value.dropFirst(prefix.count))
        return prefix + (URL(string: "https://" + domain)?.host?.lowercased() ?? domain)
    })
    public static func normalize(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !value.isEmpty, !value.contains(where: { $0.isWhitespace }), !value.contains("/"), !value.contains(":"), !value.contains("*"), !value.contains("@"), !value.contains("%"),
              // URL(string:) is lenient: "example.com##.ad" would otherwise normalize to the host "example.com" and block the whole site.
              !value.contains(where: { "#?&=,;()'\"<>\\{}[]|^$!`~".contains($0) }),
              let url = URL(string: "https://" + value), let host = url.host?.lowercased(), host.utf8.count <= 253 else { throw FilteringIssue.invalidDomain }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0.count <= 63 && $0.first != "-" && $0.last != "-" && $0.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) }),
              !parts.allSatisfy({ UInt8($0) != nil }) else { throw FilteringIssue.invalidDomain }
        // PSL exception rules take precedence over wildcard and ordinary suffix rules.
        for start in parts.indices {
            let suffix = parts[start...].joined(separator: ".")
            if suffixes.contains("!" + suffix) { return host }
            if start == 0 && suffixes.contains(suffix) { throw FilteringIssue.invalidDomain }
            if start == 1 && suffixes.contains("*." + suffix) { throw FilteringIssue.invalidDomain }
        }
        return host
    }
}
public struct FilterRule: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let domain: String
    public let action: FilterAction
    public let scope: FilterScope
    public let tier: FilterTier
    public let source: String
    public let enabled: Bool?
    public init(id: String = UUID().uuidString, domain: String, action: FilterAction, scope: FilterScope = .domainAndSubdomains, tier: FilterTier = .user, source: String = "User", enabled: Bool = true) throws {
        self.id = id; self.domain = try FilterDomain.normalize(domain); self.action = action; self.scope = scope; self.tier = tier; self.source = source; self.enabled = enabled
    }
    /// For rules read back from storage: the domain was normalized when the rule was first made, so skip the (slow) validation.
    public init(trustedID id: String, domain: String, action: FilterAction, scope: FilterScope, tier: FilterTier, source: String, enabled: Bool? = true) {
        self.id = id; self.domain = domain; self.action = action; self.scope = scope; self.tier = tier; self.source = source; self.enabled = enabled
    }
    public func matches(_ host: String) -> Bool { host == domain || (scope == .domainAndSubdomains && host.hasSuffix("." + domain)) }
}
public struct FilterMatch: Sendable {
    public let rule: FilterRule
    public var explanation: String { "\(rule.action == .allow ? "Allow" : "Block") · \(rule.tier == .user ? "User rule" : rule.source) · \(rule.scope.label). User rules take precedence over subscriptions; the most specific rule wins within its tier." }
}
public enum RuleEngine {
    // Ascending precedence is also the Safari rule order: later rules override earlier ones.
    public static func ordered(_ rules: [FilterRule]) -> [FilterRule] {
        rules.filter { $0.enabled != false }.sorted {
            if $0.tier != $1.tier { return $0.tier == .subscription }
            if $0.scope != $1.scope { return $0.scope == .domainAndSubdomains }
            if $0.domain.count != $1.domain.count { return $0.domain.count < $1.domain.count }
            if $0.action != $1.action { return $0.action == .block }
            if $0.source != $1.source { return $0.source > $1.source }
            return $0.id > $1.id
        }
    }
    public static func match(_ input: String, rules: [FilterRule]) throws -> FilterMatch? {
        let host = try FilterDomain.normalize(input)
        return ordered(rules.filter { $0.matches(host) }).last.map { FilterMatch(rule: $0) }
    }
}
public struct FilterParseResult: Sendable { public let rules: [FilterRule]; public let rejected: Int
    public init(rules: [FilterRule], rejected: Int) { self.rules = rules; self.rejected = rejected } }
public enum FilterParser {
    /// OISD Big is about 5.5 MB; the per-file cap leaves headroom for list growth.
    public static let byteLimit = 8_000_000
    /// Per list. Safari's compiled budget (SafariRuleCompiler.ruleLimit) is separate and still 150,000.
    public static let domainLimit = 260_000
    /// Distinct rules across all enabled lists plus user rules together (the same domain in two lists counts once); a ceiling for memory in the app.
    public static let combinedLimit = 650_000
    public static func parse(_ data: Data, source: String) throws -> FilterParseResult {
        guard data.count <= byteLimit, let text = String(data: data, encoding: .utf8) else { throw FilteringIssue.tooLarge }
        var rules: [FilterRule] = []; var rejected = 0; var identities = Set<String>()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("!") || line.hasPrefix("[") { continue }
            // Page-element rules (`site.com##.ad`, `#@#`, `#?#`, `#$#`, `#%#`) are not domain rules; reading them as one would block the whole site.
            if line.contains("##") || line.contains("#@#") || line.contains("#?#") || line.contains("#$#") || line.contains("#%#") { rejected += 1; continue }
            var domain = line; var scope: FilterScope = .domainAndSubdomains; var action: FilterAction = .block
            if domain.hasPrefix("@@||") { action = .allow; domain = String(domain.dropFirst(2)) }
            if domain.hasPrefix("||"), domain.hasSuffix("^") { domain = String(domain.dropFirst(2).dropLast()) }
            else {
                let fields = line.split(whereSeparator: \.isWhitespace)
                if fields.first == "0.0.0.0" || fields.first == "127.0.0.1" || fields.first == "::" {
                    // Preserve exact-host semantics of every hostname in a hosts line.
                    for host in fields.dropFirst().prefix(while: { !$0.hasPrefix("#") }) {
                        if ["localhost", "localhost.localdomain", "broadcasthost"].contains(String(host)) { continue }
                        do {
                            let rule = try FilterRule(id: source + ":exact:" + host, domain: String(host), action: .block, scope: .exact, tier: .subscription, source: source)
                            if identities.insert(rule.id).inserted { rules.append(rule) }
                        } catch { rejected += 1 }
                    }
                    if rules.count > domainLimit { throw FilteringIssue.capacity }
                    continue
                }
                if fields.count != 1 || domain.contains("$") || domain.contains("^") || domain.contains("|") { rejected += 1; continue }
                scope = .domainAndSubdomains
            }
            do {
                let rule = try FilterRule(id: source + ":" + action.rawValue + ":" + scope.rawValue + ":" + domain, domain: domain, action: action, scope: scope, tier: .subscription, source: source)
                if identities.insert(rule.id).inserted { rules.append(rule) }
            } catch { rejected += 1 }
            if rules.count > domainLimit { throw FilteringIssue.capacity }
        }
        guard !rules.isEmpty else { throw FilteringIssue.empty }
        return FilterParseResult(rules: rules, rejected: rejected)
    }
}
public enum SafariRuleCompiler {
    /// Conservative app budget, not a claim about Safari's version-dependent maximum.
    public static let ruleLimit = 150_000
    /// What an extension with nothing to enforce publishes (WebKit rejects []). It must match no real URL. The earlier "^$" placeholder
    /// made Safari block every page, so this one names a reserved .invalid host that can never be visited.
    public static let placeholderFilter = "^https?://vayusetu-no-rules\\.invalid[:/]"
    public static var placeholder: Data {
        let rule: [[String: Any]] = [["trigger": ["url-filter": placeholderFilter], "action": ["type": "block"]]]
        return (try? JSONSerialization.data(withJSONObject: rule, options: [.sortedKeys])) ?? Data()
    }
    /// What the app sends Safari in one package. Well under `ruleLimit` because Safari compiles every rule into one automaton before it
    /// can answer, and tens of thousands of host rules already take noticeable time; DNS filtering carries the full lists.
    public static var fitBudget = 56_000
    public static func compile(_ rules: [FilterRule]) throws -> Data {
        guard rules.count <= ruleLimit else { throw FilteringIssue.capacity }
        let ordered = RuleEngine.ordered(rules)
        // WebKit rejects []; ^$ cannot match a real Safari URL.
        guard !ordered.isEmpty else { return placeholder }
        let objects: [[String: Any]] = ordered.map { rule in
            let escaped = rule.domain.replacingOccurrences(of: ".", with: "\\.")
            let prefix = rule.scope == .exact ? "" : "([^/]+\\.)?"
            // Matching is case-insensitive by default; "[:/]" ends the host at a port or the path.
            return ["trigger": ["url-filter": "^https?://" + prefix + escaped + "[:/]"], "action": ["type": rule.action == .allow ? "ignore-previous-rules" : "block"]]
        }
        let data = try JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys])
        guard data.count <= 25_000_000 else { throw FilteringIssue.capacity }
        return data
    }
    /// Whole resource classes Safari can refuse on every site. Blunt by nature: the UI warns that images and scripts break pages.
    public enum ResourceBlock: String, CaseIterable, Sendable, Codable { case font, image, script, https
        var safariType: String { rawValue }
        /// `https` is not a block: it asks Safari to upgrade http addresses to https.
        var json: String {
            self == .https ? "{\"action\":{\"type\":\"make-https\"},\"trigger\":{\"url-filter\":\"^http://\"}}" : "{\"action\":{\"type\":\"block\"},\"trigger\":{\"resource-type\":[\"\(safariType)\"],\"url-filter\":\".*\"}}"
        }
    }
    /// Result of fitting a ruleset into Safari's budget.
    public struct Fit: Sendable { public let data: Data; public let applied: Int; public let candidates: Int }

    /// Safari accepts a limited number of rules, DNS does not. Fit what Safari can take without changing what the rules mean:
    /// drop block rules already covered by a blocked parent domain, then, if still over budget, keep all user rules and allow rules
    /// and fill the rest with subscription blocks in order. `content` (page-element hiding and URL-pattern rules) goes in too and counts
    /// toward the same budget. Order in the package: resource blocks, URL blocks, element hiding, domain rules, exceptions.
    public static func fit(_ rules: [FilterRule], resourceBlocks: [ResourceBlock] = [], content: ContentRuleSet = ContentRuleSet()) throws -> Fit {
        let active = rules.filter { $0.enabled != false }
        let parents = Set(active.filter { $0.action == .block && $0.scope == .domainAndSubdomains }.map(\.domain))
        func covered(_ rule: FilterRule) -> Bool {
            guard rule.action == .block else { return false }
            let parts = rule.domain.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count > 2 else { return false }
            for start in 1..<(parts.count - 1) where parents.contains(parts[start...].joined(separator: ".")) { return true }
            return false
        }
        var kept = active.filter { !covered($0) }
        var content = content
        let fixed = resourceBlocks.count
        if content.count + fixed > fitBudget / 2 * 3 { content = trimmed(content, to: fitBudget / 2 * 3 - fixed) }
        let room = max(0, fitBudget - content.count - fixed)
        if kept.count > room {
            let must = kept.filter { $0.tier == .user || $0.action == .allow }
            let space = max(0, room - must.count)
            let blocks = kept.filter { $0.tier == .subscription && $0.action == .block }
            kept = must + blocks.prefix(space)
        }
        // The compiled package has a size budget too; shed subscription blocks (then element hiding) until it fits.
        while true {
            let domainPart: Data? = kept.isEmpty ? nil : try compile(kept)
            let pre = resourceBlocks.map(\.json) + content.blocks + content.hides
            if let data = stitch(pre: pre, domain: domainPart, post: content.allows), data.count <= 25_000_000 {
                return Fit(data: data, applied: kept.count + content.count + fixed, candidates: active.count + content.count + fixed)
            }
            let blocks = kept.filter { $0.tier == .subscription && $0.action == .block }
            if !blocks.isEmpty {
                let drop = Set(blocks.suffix(max(1, blocks.count / 10)).map(\.id)); kept.removeAll { drop.contains($0.id) }
            } else if !content.hides.isEmpty { content.hides.removeLast(max(1, content.hides.count / 10)) }
            else if !content.blocks.isEmpty { content.blocks.removeLast(max(1, content.blocks.count / 10)) }
            else { throw FilteringIssue.capacity }
        }
    }
    /// Keeps the same mix of URL blocks, hides and exceptions at a smaller total.
    static func trimmed(_ set: ContentRuleSet, to limit: Int) -> ContentRuleSet {
        guard set.count > limit, limit > 0 else { return limit <= 0 ? ContentRuleSet() : set }
        let ratio = Double(limit) / Double(set.count)
        var out = ContentRuleSet(); out.unsupported = set.unsupported
        out.blocks = Array(set.blocks.prefix(Int(Double(set.blocks.count) * ratio)))
        out.hides = Array(set.hides.prefix(Int(Double(set.hides.count) * ratio)))
        out.allows = Array(set.allows.prefix(Int(Double(set.allows.count) * ratio)))
        return out
    }
    /// Joins JSON rule text and an already compiled domain package into one array without parsing the large part.
    static func stitch(pre: [String], domain: Data?, post: [String]) -> Data? {
        var parts: [Data] = []
        if !pre.isEmpty { parts.append(Data(pre.joined(separator: ",").utf8)) }
        if let domain {
            guard domain.count >= 2, domain.first == 0x5B, domain.last == 0x5D else { return nil }
            let inner = domain.dropFirst().dropLast()
            if !inner.isEmpty { parts.append(Data(inner)) }
        }
        if !post.isEmpty { parts.append(Data(post.joined(separator: ",").utf8)) }
        guard !parts.isEmpty else { return placeholder }
        var out = Data("[".utf8)
        for (i, part) in parts.enumerated() { if i > 0 { out.append(0x2C) }; out.append(part) }
        out.append(0x5D)
        return out
    }
}
