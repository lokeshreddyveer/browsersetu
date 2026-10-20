import Foundation

/// What the app, its widgets and its share extension pass to each other through the shared App Group folder. Plain files, no network.
enum SharedStore {
    static let group = "group.com.browsersetu.shared"

    struct Link: Codable, Equatable, Identifiable {
        var title: String
        var url: String
        var id: String { url }
    }

    /// What a widget shows. Written by the app; read by the widgets.
    struct Snapshot: Codable, Equatable {
        var favorites: [Link] = []
        var reading: [Link] = []
        var blockedToday = 0
        var updated = Date()
    }

    /// Something another app handed over through the share sheet, waiting for the browser to act on it.
    struct InboxItem: Codable, Equatable, Identifiable {
        enum Kind: String, Codable { case open, readLater, send }
        var id = UUID()
        var kind: Kind
        var url: String
        var title: String
        var date = Date()
    }

    static var folder: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) }
    private static func file(_ name: String) -> URL? { folder?.appendingPathComponent(name) }

    /// Removes everything the widgets and the share sheet share with the app.
    static func eraseAll() {
        for name in ["snapshot.json", "inbox.json"] { if let url = file(name) { try? FileManager.default.removeItem(at: url) } }
    }

    static func readSnapshot() -> Snapshot? {
        guard let url = file("snapshot.json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    @discardableResult
    static func write(_ snapshot: Snapshot) -> Bool {
        guard let url = file("snapshot.json"), let data = try? JSONEncoder().encode(snapshot) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// Only a plain web address is taken; anything else is dropped. At most 20 items wait at once.
    static func append(_ item: InboxItem) -> Bool {
        guard let url = URL(string: item.url), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, let target = file("inbox.json") else { return false }
        let coordinator = NSFileCoordinator()
        var ok = false
        var error: NSError?
        coordinator.coordinate(writingItemAt: target, options: .forMerging, error: &error) { location in
            var list = (try? Data(contentsOf: location)).flatMap { try? JSONDecoder().decode([InboxItem].self, from: $0) } ?? []
            list.append(item)
            ok = (try? JSONEncoder().encode(Array(list.suffix(20))).write(to: location, options: .atomic)) != nil
        }
        return ok
    }

    /// Everything waiting, removed from the folder as it is returned.
    static func takeInbox() -> [InboxItem] {
        guard let target = file("inbox.json"), FileManager.default.fileExists(atPath: target.path) else { return [] }
        var taken: [InboxItem] = []
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: target, options: .forDeleting, error: &error) { location in
            taken = (try? Data(contentsOf: location)).flatMap { try? JSONDecoder().decode([InboxItem].self, from: $0) } ?? []
            try? FileManager.default.removeItem(at: location)
        }
        return taken
    }
}
