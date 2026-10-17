import CryptoKit
import Foundation

/// A validated, ready-to-compile rule set. `rulesJSON` is the WebKit/Safari content-blocker format.
public struct PolicySnapshot: Equatable, Sendable {
    public let rulesJSON: Data
    /// More lists of rules when the rules do not fit in one: WebKit takes up to about 150,000 per list but many lists per page.
    /// Each carries the website exceptions and the user's own rules, so they apply in every list.
    public let additionalRulesJSON: [Data]
    /// Content hash; also the compiled-list cache key.
    public let identifier: String
    public let domainBlockRules: Int
    public let urlBlockRules: Int
    public let elementHidingRules: Int
    public let userRules: Int
    public let siteExceptions: Int
    /// Rules left out to stay inside the compile budget.
    public let droppedForBudget: Int
    /// Syntax this engine cannot enforce (scriptlets, regex, redirects...). Counted, never silently turned into something else.
    public let unsupportedRules: Int
    /// Lists that could not be read or validated, with the reason.
    public let failedLists: [String: String]
    public let listNames: [String]
    public let strictExtras: [String]

    /// Every list to compile and attach, the first one first.
    public var allRulesJSON: [Data] { [rulesJSON] + additionalRulesJSON }

    public var totalRules: Int { domainBlockRules + urlBlockRules + elementHidingRules + userRules + siteExceptions + strictExtras.count }
}

/// Precedence, lowest to highest. A later rule overrides an earlier one in content-blocker order, so the output is
/// laid out in exactly this sequence:
///
///   1. Filter-list rules (bundled starter lists, and downloaded lists in Custom mode)
///   2. Website exceptions (`ignore-previous-rules` for pages on that site)
///   3. User allow/deny rules, most specific last
///
/// Mandatory browser security restrictions sit above all of this, but they are navigation policy enforced by the
/// Rust core before a request exists; a content-blocker rule can only block or hide, so it can never weaken them.
/// Default behaviour (no rule matches) is that the request loads.
///
/// Consequence worth knowing: a user *deny* rule still blocks on a site that has an exception, because user rules
/// outrank exceptions. This differs from VayuSetu's Safari planner, which appends site exceptions last.
public enum PolicyBuilder {
    public static let byteLimit = FilterParser.byteLimit
    /// Most rules in one compiled list, and the most lists: 3 x 100,000 covers the Strict level with room to spare.
    public static let rulesPerList = 100_000
    public static let maxLists = 3

    private static let thirdPartyCookies = #"{"action":{"type":"block-cookies"},"trigger":{"load-type":["third-party"],"url-filter":".*"}}"#
    /// WebKit classifies fetch/XHR/sendBeacon as "raw". Blocking all third-party raw requests would break many sites, so only
    /// requests whose path looks like a tracking endpoint are blocked. This is a heuristic and is described as one.
    static let trackingEndpointKeywords = ["beacon", "collect", "pixel", "telemetry", "analytics", "track"]
    private static let trackingEndpointRules: [String] = trackingEndpointKeywords.flatMap { keyword in
        ["[/?]", "$"].map { suffix in
            #"{"action":{"type":"block"},"trigger":{"load-type":["third-party"],"resource-type":["raw","ping"],"url-filter":"/\#(keyword)\#(suffix)"}}"#
        }
    }
    static let cookieLabel = "Third-party cookie blocking"
    static let endpointLabel = "Third-party tracking-endpoint requests"

    /// `downloaded` maps a catalogue URL to the cached list text.
    public static func build(configuration: PrivacyConfiguration, downloaded: [String: Data] = [:]) -> PolicySnapshot? {
        guard configuration.isEnabled else { return nil }
        let effective = configuration.effective

        var subscriptionRules: [FilterRule] = []
        var content = ContentRuleSet()
        var failed: [String: String] = [:]
        var names: [String] = []
        var unsupported = 0

        func addDomainList(id: String, name: String, data: Data) {
            do {
                let parsed = try FilterParser.parse(data, source: name)
                subscriptionRules += parsed.rules
                unsupported += parsed.rejected
                names.append(name)
            } catch {
                failed[name] = (error as? LocalizedError)?.errorDescription ?? "Could not be read."
            }
        }

        if effective.ads { addDomainList(id: BundledLists.ads.id, name: BundledLists.ads.name, data: Data(BundledLists.ads.text.utf8)) }
        if effective.tracking { addDomainList(id: BundledLists.tracking.id, name: BundledLists.tracking.name, data: Data(BundledLists.tracking.text.utf8)) }
        if effective.sessionRecording { addDomainList(id: BundledLists.sessionRecording.id, name: BundledLists.sessionRecording.name, data: Data(BundledLists.sessionRecording.text.utf8)) }

        for url in effective.downloadedLists {
            let name = FilterCatalog.entry(forURL: url)?.name ?? url
            guard let data = downloaded[url] else { failed[name] = "Not downloaded yet."; continue }
            guard data.count <= byteLimit else { failed[name] = FilteringIssue.tooLarge.errorDescription ?? "Too large."; continue }
            let abp = ABPContentParser.parse(data)
            content.append(abp)
            unsupported += abp.unsupported
            // A list may hold only page rules; that is fine as long as something was read.
            if let parsed = try? FilterParser.parse(data, source: name) {
                subscriptionRules += parsed.rules
                unsupported += parsed.rejected
                names.append(name)
            } else if !abp.isEmpty {
                names.append(name)
            } else {
                failed[name] = "No supported rules were found."
            }
        }

        // De-duplicate, then drop names already covered by a blocked parent domain (same idea as VayuSetu's fitter).
        var seen = Set<String>()
        var unique: [FilterRule] = []
        for rule in subscriptionRules where seen.insert(rule.domain + "|" + rule.scope.rawValue + "|" + rule.action.rawValue).inserted { unique.append(rule) }
        let parents = Set(unique.filter { $0.action == .block && $0.scope == .domainAndSubdomains }.map(\.domain))
        unique = unique.filter { rule in
            guard rule.action == .block else { return true }
            let parts = rule.domain.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count > 2 else { return true }
            return !(1..<(parts.count - 1)).contains { parents.contains(parts[$0...].joined(separator: ".")) }
        }

        // Budget: user rules and exceptions are never dropped; list rules fill what is left.
        let userRules = configuration.userRules.compactMap { rule in
            try? FilterRule(id: rule.id, domain: rule.domain, action: rule.action, scope: rule.scope, tier: .user, source: "User")
        }
        var extras: [String] = []
        var extraLabels: [String] = []
        if effective.thirdPartyCookies { extras.append(thirdPartyCookies); extraLabels.append(cookieLabel) }
        if effective.trackingEndpoints { extras += trackingEndpointRules; extraLabels.append(endpointLabel) }
        // The first list holds the page-pattern rules and as many host rules as fit beside them; the rest of the host rules fill more
        // lists. Nothing is thrown away unless it would take more than `maxLists` lists.
        var dropped = 0
        let exceptionJSON = configuration.siteExceptions.compactMap(siteException)
        let repeated = userRules.count + exceptionJSON.count
        let firstRoom = Self.rulesPerList - repeated
        if content.count + extras.count > firstRoom {
            let trimmedSet = SafariRuleCompiler.trimmed(content, to: max(0, firstRoom - extras.count))
            dropped += content.count - trimmedSet.count
            content = trimmedSet
        }
        let allows = unique.filter { $0.action == .allow }
        let blocks = unique.filter { $0.action == .block }
        let firstBlocks = max(0, firstRoom - content.count - extras.count - allows.count)
        let otherBlocks = max(1, Self.rulesPerList - repeated - allows.count)
        var blockChunks: [[FilterRule]] = [Array(blocks.prefix(firstBlocks))]
        var rest = Array(blocks.dropFirst(firstBlocks))
        while !rest.isEmpty && blockChunks.count < Self.maxLists {
            blockChunks.append(Array(rest.prefix(otherBlocks))); rest = Array(rest.dropFirst(otherBlocks))
        }
        dropped += rest.count
        unique = blockChunks.flatMap { $0 } + allows

        guard !unique.isEmpty || !content.isEmpty || !extras.isEmpty else { return nil }

        do {
            let userPart: Data? = userRules.isEmpty ? nil : try SafariRuleCompiler.compile(userRules)
            var lists: [Data] = []
            for (index, chunk) in blockChunks.enumerated() {
                let rules = chunk + allows
                if index > 0 && chunk.isEmpty { continue }
                let domainPart: Data? = rules.isEmpty ? nil : try SafariRuleCompiler.compile(rules)
                let pre = index == 0 ? content.blocks + content.hides + extras : []
                let post = (index == 0 ? content.allows : []) + exceptionJSON
                guard var combined = SafariRuleCompiler.stitch(pre: pre, domain: domainPart, post: post) else { return nil }
                if let userPart { combined = join(combined, userPart) }
                guard combined.count <= 25_000_000 else { return nil }
                lists.append(combined)
            }
            guard let combined = lists.first else { return nil }
            var hasher = SHA256()
            for list in lists { hasher.update(data: list) }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return PolicySnapshot(
                rulesJSON: combined, additionalRulesJSON: Array(lists.dropFirst()), identifier: "setu-" + digest.prefix(20),
                domainBlockRules: unique.count, urlBlockRules: content.blocks.count, elementHidingRules: content.hides.count,
                userRules: userRules.count, siteExceptions: exceptionJSON.count, droppedForBudget: dropped,
                unsupportedRules: unsupported, failedLists: failed, listNames: names,
                strictExtras: extraLabels)
        } catch {
            return nil
        }
    }

    /// `ignore-previous-rules` for every request made by pages on `domain` and its subdomains.
    static func siteException(_ domain: String) -> String? {
        SafariRulesetPlannerCompat.siteException(domain)
    }

    /// Concatenates two JSON arrays without parsing them.
    static func join(_ a: Data, _ b: Data) -> Data {
        guard a.count >= 2, b.count >= 2, a.first == 0x5B, b.first == 0x5B else { return a }
        if a.count == 2 { return b }
        if b.count == 2 { return a }
        var out = Data(a.dropLast())
        out.append(0x2C)
        out.append(contentsOf: b.dropFirst())
        return out
    }
}

/// The one VayuSetu planner function worth keeping verbatim in behaviour; the rest of that planner is specific to
/// Safari's six-extension, App-Group delivery and is not used here.
enum SafariRulesetPlannerCompat {
    static func siteException(_ domain: String) -> String? {
        let object: [String: Any] = ["trigger": ["url-filter": ".*", "if-domain": ["*" + domain]], "action": ["type": "ignore-previous-rules"]]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
