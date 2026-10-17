import Foundation

/// "When a site opens, do this": keep it in a private tab, in a container, or file it into a group or workspace. One list of rules, checked for every normal page load.
struct SiteOpenRule: Codable, Equatable, Identifiable {
    enum Action: Codable, Equatable {
        case privateTab
        case container(String)
        case group(String)
        case workspace(String)

        var title: String {
            switch self {
            case .privateTab: "Open in a private tab"
            case .container(let name): "Open in the container “\(name)”"
            case .group(let name): "Put in the group “\(name)”"
            case .workspace(let name): "Put in the workspace “\(name)”"
            }
        }
    }
    var host: String
    var action: Action
    var id: String { host.lowercased() + "|" + action.title }

    /// The rule covers the host itself and every site under it.
    func matches(host other: String?) -> Bool {
        guard let other = other?.lowercased(), !host.isEmpty else { return false }
        let mine = host.lowercased()
        return other == mine || other.hasSuffix("." + mine)
    }

    /// A host typed by the person, cut down to just the host name: "https://www.Example.com/x" becomes "example.com". Anything that is not a plain host name is refused.
    static func cleanHost(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.contains("://") { text = URL(string: text)?.host ?? "" }
        if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }
        if let colon = text.firstIndex(of: ":") { text = String(text[..<colon]) }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-.")
        guard text.count <= 253, text.contains("."), !text.hasPrefix("."), !text.hasSuffix("."), !text.contains(".."), text.allSatisfy({ allowed.contains($0) }) else { return nil }
        return text
    }
}

/// What to do about a page that is about to load in a tab.
enum SiteOpenOutcome: Equatable {
    /// Load it in a new tab with these properties instead, and leave this tab as it is.
    case openElsewhere(isPrivate: Bool, container: String?)
    case moveToGroup(String)
    case moveToWorkspace(String)
}

enum SiteOpenRules {
    static let maxRules = 100

    /// The first rule that applies and is not already satisfied, so a tab that already meets a rule is left alone (this is also what stops a loop). The rules are looked at in
    /// the order the person made them; a rule for a more specific host is looked at before a broader one.
    static func outcome(forHost host: String?, rules: [SiteOpenRule], tabIsPrivate: Bool, tabContainer: String?, tabGroup: String, tabWorkspace: String) -> SiteOpenOutcome? {
        let applicable = rules.filter { $0.matches(host: host) }.sorted { $0.host.count > $1.host.count }
        for rule in applicable {
            switch rule.action {
            case .privateTab: if !tabIsPrivate { return .openElsewhere(isPrivate: true, container: nil) }
            case .container(let name): if !tabIsPrivate, tabContainer != name { return .openElsewhere(isPrivate: false, container: name) }
            case .group(let name): if !tabIsPrivate, tabGroup != name { return .moveToGroup(name) }
            case .workspace(let name): if !tabIsPrivate, tabWorkspace != name { return .moveToWorkspace(name) }
            }
        }
        return nil
    }

    /// A rule is allowed only if what it names exists (a container or group or workspace) and the list is not full.
    static func canAdd(_ rule: SiteOpenRule, to rules: [SiteOpenRule], containers: [String], groups: [String], workspaces: [String]) -> Bool {
        guard rules.count < maxRules, SiteOpenRule.cleanHost(rule.host) == rule.host, !rules.contains(where: { $0.id == rule.id }) else { return false }
        switch rule.action {
        case .privateTab: return true
        case .container(let name): return containers.contains(name)
        case .group(let name): return !name.isEmpty
        case .workspace(let name): return workspaces.contains(name)
        }
    }
}
