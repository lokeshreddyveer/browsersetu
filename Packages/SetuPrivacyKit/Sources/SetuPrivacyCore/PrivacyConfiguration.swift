import Foundation

public enum ProtectionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case light, balanced, strict
    /// Reachable from Settings only: you choose the lists and extra protections yourself.
    case custom
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }

    /// The lists each level turns on: the same sets VayuSetu uses. Each level holds everything the one below it blocks, and more.
    /// (Strict swaps HaGeZi Multi for the stronger Pro++, which already contains the device-telemetry lists.)
    public var listNames: [String] {
        let light = ["HaGeZi Light", "Peter Lowe’s ad servers"]
        let balanced = ["HaGeZi Multi", "EasyList", "Peter Lowe’s ad servers", "Anti-Malware (DandelionSprout)", "uBlock badware risks",
                        "NoCoin (cryptojacking)", "Cookie notices (Fanboy)"]
        let strict = balanced.filter { $0 != "HaGeZi Multi" } + ["HaGeZi Pro++", "EasyPrivacy", "Dan Pollock’s hosts", "Smart TV tracking",
                        "Fanboy Annoyances", "Fanboy Social", "Scams (Blocklist Project)", "Ransomware (Blocklist Project)",
                        "Scam blocklist (DurableNapkin)", "Crypto miners & scams (Blocklist Project)"]
        switch self {
        case .light: return light
        case .balanced: return balanced
        case .strict: return strict
        case .custom: return []
        }
    }

    /// Download addresses of this level's lists, from the catalogue.
    public var listURLs: [String] {
        listNames.compactMap { name in FilterCatalog.all.first { $0.name == name }?.url }
    }

    /// The three levels offered in the popover.
    public static let levels: [ProtectionMode] = [.light, .balanced, .strict]

    public var summary: String {
        switch self {
        case .light: "Core ads and trackers. Fewest broken sites."
        case .balanced: "Recommended. Ads, malware, miners and cookie banners."
        case .strict: "Maximum. Adds trackers, telemetry, scams, popups and social widgets. A few sites may break."
        case .custom: "You choose the lists and the extra protections. Downloaded lists apply only in this mode."
        }
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        // "standard" was this level's name before the popover was simplified; "custom" no longer exists.
        self = (value == "standard" || value == "custom") ? .balanced : (ProtectionMode(rawValue: value) ?? .balanced)
    }
}

/// A rule the user wrote. Domains are validated with the same public-suffix logic VayuSetu uses.
public struct UserRule: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var domain: String
    public var action: FilterAction
    public var scope: FilterScope

    public init(id: String = UUID().uuidString, domain: String, action: FilterAction, scope: FilterScope = .domainAndSubdomains) throws {
        self.id = id
        self.domain = try FilterDomain.normalize(domain)
        self.action = action
        self.scope = scope
    }
}

/// What the last successful download of a list produced. Stored with the configuration; the text itself lives in the cache.
public struct ListState: Codable, Equatable, Sendable {
    public var contentHash: String
    public var updatedAt: Date
    public var ruleCount: Int
    public var unsupported: Int
    public init(contentHash: String, updatedAt: Date, ruleCount: Int, unsupported: Int) {
        self.contentHash = contentHash; self.updatedAt = updatedAt; self.ruleCount = ruleCount; self.unsupported = unsupported
    }
}

public struct PrivacyConfiguration: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let maxUserRules = 5_000
    public static let maxSiteExceptions = 1_000
    public static let maxLists = 60

    public var version = PrivacyConfiguration.currentVersion
    public var mode: ProtectionMode = .balanced
    public var adBlocking = true
    public var antiTracking = true
    /// Custom mode only.
    public var customSessionRecordingHosts = false
    public var customThirdPartyCookies = false
    public var customTrackingEndpoints = false
    /// Catalogue list URLs the user enabled. Applied in Custom mode only.
    public var enabledListURLs: [String] = []
    public var listStates: [String: ListState] = [:]
    public var userRules: [UserRule] = []
    /// Registrable domains (and their subdomains) where protection is off.
    public var siteExceptions: [String] = []
    /// Off by default. When on, lists are refreshed at most once per `updateIntervalDays`, only at launch, never on a timer.
    public var automaticUpdates = false
    public var updateIntervalDays = 7
    public var lastUpdateAttempt: Date?
    public var lastSuccessfulUpdate: Date?

    public init() {}

    /// Master switch: with both protections off nothing is installed and no rule applies.
    public var isEnabled: Bool { adBlocking || antiTracking }

    public struct Effective: Equatable, Sendable {
        public var ads: Bool, tracking: Bool, sessionRecording: Bool, thirdPartyCookies: Bool, trackingEndpoints: Bool
        public var downloadedLists: [String]
    }

    public var effective: Effective {
        switch mode {
        case .light:
            // Ad hosts only: the smallest rule set. Anti-tracking is not part of this level.
            Effective(ads: adBlocking, tracking: false, sessionRecording: false, thirdPartyCookies: false, trackingEndpoints: false,
                      downloadedLists: adBlocking ? mode.listURLs : [])
        case .balanced:
            Effective(ads: adBlocking, tracking: antiTracking, sessionRecording: false, thirdPartyCookies: false, trackingEndpoints: false,
                      downloadedLists: isEnabled ? mode.listURLs : [])
        case .strict:
            Effective(ads: adBlocking, tracking: antiTracking, sessionRecording: antiTracking, thirdPartyCookies: antiTracking, trackingEndpoints: antiTracking,
                      downloadedLists: isEnabled ? mode.listURLs : [])
        case .custom:
            Effective(ads: adBlocking, tracking: antiTracking, sessionRecording: customSessionRecordingHosts && antiTracking,
                      thirdPartyCookies: customThirdPartyCookies && antiTracking, trackingEndpoints: customTrackingEndpoints && antiTracking,
                      downloadedLists: enabledListURLs)
        }
    }

    public func isException(host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        return siteExceptions.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    // MARK: Validation and persistence

    public enum ConfigurationError: Error, Equatable { case invalidDomain, duplicate, limit, invalidListURL }

    @discardableResult
    public mutating func addSiteException(_ input: String) throws -> String {
        let domain = try FilterDomain.normalize(input)
        guard !siteExceptions.contains(domain) else { throw ConfigurationError.duplicate }
        guard siteExceptions.count < Self.maxSiteExceptions else { throw ConfigurationError.limit }
        siteExceptions.append(domain)
        siteExceptions.sort()
        return domain
    }

    public mutating func removeSiteException(_ domain: String) { siteExceptions.removeAll { $0 == domain } }

    public mutating func addUserRule(domain: String, action: FilterAction, scope: FilterScope = .domainAndSubdomains) throws {
        let rule = try UserRule(domain: domain, action: action, scope: scope)
        guard !userRules.contains(where: { $0.domain == rule.domain && $0.action == rule.action && $0.scope == rule.scope }) else { throw ConfigurationError.duplicate }
        guard userRules.count < Self.maxUserRules else { throw ConfigurationError.limit }
        userRules.append(rule)
    }

    public mutating func setList(_ url: String, enabled: Bool) throws {
        guard let parsed = URL(string: url), parsed.scheme == "https", parsed.host != nil else { throw ConfigurationError.invalidListURL }
        if enabled {
            guard !enabledListURLs.contains(url) else { return }
            guard enabledListURLs.count < Self.maxLists else { throw ConfigurationError.limit }
            enabledListURLs.append(url)
        } else {
            enabledListURLs.removeAll { $0 == url }
        }
    }

    public func encoded() -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return (try? String(data: encoder.encode(self), encoding: .utf8)) ?? "{}"
    }

    public struct Decoded: Sendable { public let configuration: PrivacyConfiguration; public let wasRepaired: Bool }

    /// Malformed or newer-than-supported configuration is rejected and replaced with defaults; individual bad entries are dropped.
    public static func decode(_ text: String?) -> Decoded {
        guard let text, !text.isEmpty else { return Decoded(configuration: PrivacyConfiguration(), wasRepaired: false) }
        guard text.utf8.count <= 4_000_000, let data = text.data(using: .utf8) else { return Decoded(configuration: PrivacyConfiguration(), wasRepaired: true) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var config = try? decoder.decode(PrivacyConfiguration.self, from: data), config.version <= currentVersion else {
            return Decoded(configuration: PrivacyConfiguration(), wasRepaired: true)
        }
        var repaired = false
        let rules = config.userRules.compactMap { rule -> UserRule? in
            (try? FilterDomain.normalize(rule.domain)) == rule.domain ? rule : nil
        }
        if rules.count != config.userRules.count { repaired = true }
        config.userRules = Array(rules.prefix(maxUserRules))
        let sites = config.siteExceptions.compactMap { try? FilterDomain.normalize($0) }
        if sites.count != config.siteExceptions.count { repaired = true }
        config.siteExceptions = Array(Set(sites).sorted().prefix(maxSiteExceptions))
        let lists = config.enabledListURLs.filter { URL(string: $0)?.scheme == "https" }
        if lists.count != config.enabledListURLs.count { repaired = true }
        config.enabledListURLs = Array(lists.prefix(maxLists))
        config.updateIntervalDays = min(max(config.updateIntervalDays, 1), 90)
        return Decoded(configuration: config, wasRepaired: repaired)
    }
}
