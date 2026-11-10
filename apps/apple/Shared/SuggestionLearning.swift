import Foundation

/// What one destination has taught the address bar. Only the destination's name and counts: no titles, no search words from the page's address, no times of day.
struct LearnedDestination: Codable, Equatable {
    var visits = 0
    var lastSeen: TimeInterval = 0
    var selections = 0
    var workspaceVisits: [String: Int] = [:]
    /// What was typed when it was chosen (the first characters), and how often.
    var queries: [String: Int] = [:]
}

struct SuggestionLearningData: Codable, Equatable {
    var version = 1
    var destinations: [String: LearnedDestination] = [:]
}

/// The sites typed into the "never learn from" box.
enum SuggestionExclusions {
    static let limit = 30
    /// Names split at commas or spaces, lowercase, as bare host names (an address is cut down to its host), at most `limit`.
    static func parse(_ text: String) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for part in text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }) {
            var item = part.trimmingCharacters(in: .whitespaces).lowercased()
            if item.contains("://"), let host = URL(string: item)?.host { item = host }
            if item.hasPrefix("www.") { item.removeFirst(4) }
            let valid = !item.isEmpty && item.count <= 253 && item.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
            if valid, seen.insert(item).inserted { out.append(item) }
            if out.count == limit { break }
        }
        return out
    }
}

/// The address bar's memory of what you open and choose, kept in this profile's folder and nowhere else. It is bounded (the least useful destinations are
/// dropped), never written for private browsing, internal pages or sites you excluded, deleted with the profile, and cleared by Reset Learned Suggestions.
@MainActor
final class SuggestionLearning {
    static let maxDestinations = 1500
    static let maxQueriesPerDestination = 8
    static let maxWorkspacesPerDestination = 12
    static let maxQueryLength = 24

    private(set) var data = SuggestionLearningData()
    private let file: URL?
    private var saveTask: Task<Void, Never>?
    private static var stores: [String: SuggestionLearning] = [:]

    /// One memory per profile folder, shared by every window of the profile (two copies would overwrite each other's file).
    static func shared(folder: URL) -> SuggestionLearning {
        let key = folder.standardizedFileURL.path
        if let existing = stores[key] { return existing }
        let made = SuggestionLearning(folder: folder)
        stores[key] = made
        return made
    }

    /// The profile was deleted: its memory goes with it, in memory too, so a profile made later under the same name starts empty.
    static func forget(folder: URL) {
        let key = folder.standardizedFileURL.path
        stores[key]?.reset()
        stores[key] = nil
    }

    /// Every memory written out now (the app is closing).
    static func flushAll() { for store in stores.values { store.flush() } }

    /// `folder` nil keeps it in memory only (tests).
    init(folder: URL?) {
        file = folder?.appendingPathComponent("suggestion-learning.json")
        if let file, let bytes = try? Data(contentsOf: file), let loaded = try? JSONDecoder().decode(SuggestionLearningData.self, from: bytes), loaded.version == 1 {
            data = loaded
        }
    }

    // MARK: Recording

    func recordVisit(key: String, workspace: String, now: Date = Date()) {
        var item = data.destinations[key] ?? LearnedDestination()
        item.visits += 1
        item.lastSeen = now.timeIntervalSince1970
        item.workspaceVisits[workspace, default: 0] += 1
        trimWorkspaces(&item)
        data.destinations[key] = item
        pruneIfNeeded()
        scheduleSave()
    }

    func recordSelection(key: String, query: String, workspace: String, now: Date = Date()) {
        var item = data.destinations[key] ?? LearnedDestination()
        item.selections += 1
        item.lastSeen = now.timeIntervalSince1970
        let q = Self.normalized(query)
        if !q.isEmpty {
            item.queries[q, default: 0] += 1
            if item.queries.count > Self.maxQueriesPerDestination {
                // Keep the ones used most; of equal ones, the shorter.
                let kept = item.queries.sorted { ($0.value, -$0.key.count) > ($1.value, -$1.key.count) }.prefix(Self.maxQueriesPerDestination)
                item.queries = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
            }
        }
        data.destinations[key] = item
        pruneIfNeeded()
        scheduleSave()
    }

    // MARK: Reading

    func signals(for key: String, query: String, workspace: String) -> LearnedSignals {
        guard let item = data.destinations[key] else { return LearnedSignals() }
        let q = Self.normalized(query)
        var forQuery = 0
        if !q.isEmpty {
            for (stored, count) in item.queries where stored.hasPrefix(q) || q.hasPrefix(stored) { forQuery += count }
        }
        return LearnedSignals(workspaceVisits: item.workspaceVisits[workspace] ?? 0, totalVisits: item.visits, selectionsForQuery: forQuery, selectionsTotal: item.selections)
    }

    static func normalized(_ query: String) -> String {
        String(query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().prefix(maxQueryLength))
    }

    // MARK: Keeping it small

    private func trimWorkspaces(_ item: inout LearnedDestination) {
        guard item.workspaceVisits.count > Self.maxWorkspacesPerDestination else { return }
        let kept = item.workspaceVisits.sorted { $0.value > $1.value }.prefix(Self.maxWorkspacesPerDestination)
        item.workspaceVisits = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    /// Over the limit, the destinations seen longest ago with the least use go first; some room is cleared at once so this does not run on every page.
    private func pruneIfNeeded() {
        guard data.destinations.count > Self.maxDestinations else { return }
        let keep = Self.maxDestinations * 9 / 10
        let ranked = data.destinations.sorted { usefulness($0.value) > usefulness($1.value) }.prefix(keep)
        data.destinations = Dictionary(uniqueKeysWithValues: ranked.map { ($0.key, $0.value) })
    }

    private func usefulness(_ d: LearnedDestination) -> Double {
        let ageDays = max(0, (Date().timeIntervalSince1970 - d.lastSeen) / 86_400)
        return (Double(d.visits) + 3 * Double(d.selections)) * pow(0.5, ageDays / 30)
    }

    // MARK: Reset and saving

    func reset() {
        data = SuggestionLearningData()
        saveTask?.cancel()
        if let file { try? FileManager.default.removeItem(at: file) }
    }

    var isEmpty: Bool { data.destinations.isEmpty }

    /// Written a moment after the last change, off the main thread, in one piece.
    private func scheduleSave() {
        guard let file else { return }
        saveTask?.cancel()
        let snapshot = data
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let bytes = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? bytes.write(to: file, options: .atomic)
        }
    }

    /// Writes now (the app is closing).
    func flush() {
        guard let file, let bytes = try? JSONEncoder().encode(data) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? bytes.write(to: file, options: .atomic)
    }
}
