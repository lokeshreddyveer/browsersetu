import Foundation

/// An action asked for from outside the app: a link, Shortcuts, or the command line.
enum URLAction: Equatable {
    case open(URL, privateTab: Bool)
    case search(String)
    case command(String)
    case workflow(String)

    /// `browsersetu://open?url=…&private=1`, `…://search?q=…`, `…://command?id=…`, `…://workflow?name=…`. Anything else is refused.
    static func parse(_ url: URL) -> URLAction? {
        guard url.scheme?.lowercased() == "browsersetu", let name = url.host?.lowercased() else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ key: String) -> String? { items.first { $0.name == key }?.value.flatMap { $0.isEmpty ? nil : $0 } }
        switch name {
        case "open":
            guard let raw = value("url"), let target = URL(string: raw), ["http", "https"].contains(target.scheme?.lowercased() ?? ""), target.host != nil else { return nil }
            return .open(target, privateTab: value("private") == "1")
        case "search": return value("q").map { .search(String($0.prefix(500))) }
        case "command": return value("id").map { .command($0) }
        case "workflow": return value("name").map { .workflow($0) }
        default: return nil
        }
    }
}

/// One step of a workflow. Steps are a fixed list of safe operations, never code.
struct WorkflowStep: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case openURL, search, command, wait
        var title: String { switch self { case .openURL: "Open a page"; case .search: "Search"; case .command: "Run a command"; case .wait: "Wait" } }
    }
    var kind: Kind
    var value: String
    var id = UUID()
    enum CodingKeys: String, CodingKey { case kind, value }

    var isValid: Bool {
        switch kind {
        case .openURL: URL(string: value).map { ["http", "https"].contains($0.scheme?.lowercased() ?? "") && $0.host != nil } ?? false
        case .search, .command: !value.trimmingCharacters(in: .whitespaces).isEmpty
        case .wait: Double(value).map { $0 > 0 && $0 <= 30 } ?? false
        }
    }
}

struct Workflow: Codable, Equatable, Identifiable {
    var name: String
    var steps: [WorkflowStep]
    var id: String { name.lowercased() }
    static let maxSteps = 20
    var isValid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && !steps.isEmpty && steps.count <= Self.maxSteps && steps.allSatisfy(\.isValid) }
}

/// How often a watched page is looked at while the app is open. Without a schedule a watched page is checked only when you open it.
struct ScheduledCheck: Codable, Equatable, Identifiable {
    var key: String
    var url: String
    var everyMinutes: Int
    var lastRun: Double?
    var id: String { key }

    static let allowedIntervals = [30, 60, 360, 1440]
    func isDue(now: Date) -> Bool {
        guard let last = lastRun else { return true }
        return now.timeIntervalSince1970 - last >= Double(everyMinutes) * 60
    }
}

/// What a script may do with the scripting API, and what it has been allowed so far. Nothing is allowed until you say so.
enum ScriptCapability: String, Codable, CaseIterable, Identifiable {
    case readPage, openTabs, readTabs, runCommands
    var id: String { rawValue }
    var prompt: String {
        switch self {
        case .readPage: "read the text of the page you are on"
        case .openTabs: "open pages in new tabs"
        case .readTabs: "see the titles and addresses of your open tabs"
        case .runCommands: "run browser commands for you"
        }
    }
}

struct ScriptGrants: Codable, Equatable {
    /// Script name to what it may do.
    var allowed: [String: Set<ScriptCapability>] = [:]
    func isAllowed(_ script: String, _ capability: ScriptCapability) -> Bool { allowed[script]?.contains(capability) ?? false }
    mutating func allow(_ script: String, _ capability: ScriptCapability) { allowed[script, default: []].insert(capability) }
    mutating func revoke(_ script: String) { allowed[script] = nil }
}
