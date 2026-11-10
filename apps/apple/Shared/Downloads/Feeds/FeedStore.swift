import Foundation
import UniformTypeIdentifiers

// DX-10: feeds as a source of downloads. Local-first: subscriptions and the list of items already handled are a small JSON file in the profile's download folder (like packages); there is no
// account, no server, and nothing is checked or downloaded unless the person asks (a manual refresh, or "Download"). A private session keeps nothing at all.

struct FeedSubscription: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var url: URL
    var title: String
    var addedAt = Date()
    var lastChecked: Date?
    /// Items already downloaded or deliberately skipped (their stable ids, oldest first), so a refresh shows only what is new. Bounded.
    var seen: [String] = []
}

@MainActor
final class FeedStore: ObservableObject {
    static let maxSubscriptions = 100
    static let maxSeen = 3000
    static let maxFileBytes = 4_000_000

    @Published private(set) var subscriptions: [FeedSubscription] = []
    private let file: URL?
    let profile: String
    let isPrivate: Bool

    init(profile: String, file: URL?, isPrivate: Bool = false) {
        self.profile = profile; self.isPrivate = isPrivate
        self.file = isPrivate ? nil : file
        load()
    }

    private struct Disk: Codable { var version = 1; var profile: String; var subscriptions: [FeedSubscription] }

    private func load() {
        guard let file, let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0, size <= Self.maxFileBytes,
              let data = try? Data(contentsOf: file), let disk = try? JSONDecoder().decode(Disk.self, from: data), disk.version == 1, disk.profile == profile else { return }
        var seenURLs = Set<String>()
        subscriptions = disk.subscriptions.filter { s in
            guard let scheme = s.url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
            return seenURLs.insert(LinkClassifier.normalizedKey(s.url)).inserted
        }.prefix(Self.maxSubscriptions).map { var s = $0; s.seen = Array(s.seen.suffix(Self.maxSeen)); s.title = DownloadFeedParser.clean(s.title, max: FeedLimits.maxTitle); return s }
    }

    private func save() {
        guard let file else { return }
        guard let data = try? JSONEncoder().encode(Disk(profile: profile, subscriptions: subscriptions)) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    func subscription(for url: URL) -> FeedSubscription? {
        let key = LinkClassifier.normalizedKey(url)
        return subscriptions.first { LinkClassifier.normalizedKey($0.url) == key }
    }

    /// Subscribing is only keeping the address, its name and what has been handled: no schedule, no background work. Returns the existing subscription if there already is one.
    @discardableResult
    func subscribe(_ url: URL, title: String) -> FeedSubscription? {
        if let existing = subscription(for: url) { return existing }
        guard !isPrivate, subscriptions.count < Self.maxSubscriptions else { return nil }
        let s = FeedSubscription(url: url, title: DownloadFeedParser.clean(title.isEmpty ? (url.host ?? "Feed") : title, max: FeedLimits.maxTitle))
        subscriptions.append(s); save()
        return s
    }

    func unsubscribe(_ id: UUID) { subscriptions.removeAll { $0.id == id }; save() }

    func markChecked(_ id: UUID, title: String? = nil) {
        guard let i = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        subscriptions[i].lastChecked = Date()
        if let title, !title.isEmpty { subscriptions[i].title = DownloadFeedParser.clean(title, max: FeedLimits.maxTitle) }
        save()
    }

    func markSeen(_ ids: [String], in subscriptionID: UUID) {
        guard let i = subscriptions.firstIndex(where: { $0.id == subscriptionID }), !ids.isEmpty else { return }
        var seen = subscriptions[i].seen
        var known = Set(seen)
        for id in ids where known.insert(id).inserted { seen.append(id) }
        subscriptions[i].seen = Array(seen.suffix(Self.maxSeen))
        save()
    }

    func isSeen(_ itemID: String, in subscriptionID: UUID) -> Bool { subscriptions.first { $0.id == subscriptionID }?.seen.contains(itemID) ?? false }
}

// MARK: Loading

enum FeedLoader {
    struct Loaded: Sendable { var feed: DownloadFeed; var url: URL; var alternatives: [DownloadFeedDiscovery.Found]; var validators: MediaFetcher.DocumentValidators? = nil }
    enum Outcome: Sendable { case loaded(Loaded), notModified }

    static let maxPages = 5

    /// Reads a feed at `url`. If the address is a web page, the feed it advertises is read instead (the first one; the others are returned as `alternatives`). Following "next page" links is bounded.
    /// `origin` is `.user` for an address the person typed, `.page` for one found on a page (which may not name the local network).
    @MainActor
    static func load(_ url: URL, coordinator: DownloadCoordinator, origin: DownloadRequestOrigin, pages: Int = maxPages) async throws -> Loaded {
        guard case .loaded(let l) = try await load(url, coordinator: coordinator, origin: origin, pages: pages, ifChanged: nil) else { throw FeedError.notAFeed }
        return l
    }

    /// With `ifChanged` (the ETag / Last-Modified the server gave last time) a feed that has not changed costs one small request and no download: `.notModified`.
    @MainActor
    static func load(_ url: URL, coordinator: DownloadCoordinator, origin: DownloadRequestOrigin, pages: Int = maxPages, ifChanged: MediaFetcher.DocumentValidators?) async throws -> Outcome {
        // A typed address is the person's own (it may be on this Mac or their network). What a page or a feed then names (an advertised feed, a "next page") is not: it is fetched under the page rules,
        // unless it is on the same host the person typed.
        func rules(for target: URL) -> (DownloadRequestOrigin, Bool) { origin == .user && target.host?.lowercased() == url.host?.lowercased() ? (.user, false) : (.page, true) }
        let first = try await coordinator.media.fetchDocument(url, limit: FeedLimits.maxBytes, origin: origin, refuseInternal: origin != .user, ifChanged: ifChanged)
        guard case .fresh(var data, var final, let validators) = first else { return .notModified }
        var alternatives: [DownloadFeedDiscovery.Found] = []
        if !DownloadFeedDiscovery.looksLikeFeed(data) {
            let html = String(decoding: data.prefix(120_000), as: UTF8.self)          // the head of a page is at the start; a page is not scanned further
            alternatives = DownloadFeedDiscovery.links(inHTML: html, pageURL: final)
            guard let first = alternatives.first else { throw FeedError.notAFeed }
            let r = rules(for: first.url)
            (data, final) = try await coordinator.media.fetchDocument(first.url, limit: FeedLimits.maxBytes, origin: r.0, refuseInternal: r.1)
        }
        // Reading a large feed is work for a background thread, not for the window.
        let bytes = data, base = final
        var feed = try await Task.detached(priority: .userInitiated) { try DownloadFeedParser.parse(bytes, from: base) }.value
        var seenPages = Set([LinkClassifier.normalizedKey(final)])
        var page = 1
        while page < pages, let next = feed.next, feed.items.count < FeedLimits.maxItems, seenPages.insert(LinkClassifier.normalizedKey(next)).inserted {
            try Task.checkCancellation()
            let r = rules(for: next)
            guard let (more, moreFinal) = try? await coordinator.media.fetchDocument(next, limit: FeedLimits.maxBytes, origin: r.0, refuseInternal: r.1),
                  let nextFeed = try? await Task.detached(priority: .userInitiated, operation: { try DownloadFeedParser.parse(more, from: moreFinal) }).value else { feed.warnings.append("A further page of the feed could not be read."); break }
            var known = Set(feed.items.map(\.id))
            feed.items += nextFeed.items.filter { known.insert($0.id).inserted }
            feed.next = nextFeed.next
            page += 1
        }
        if feed.items.count > FeedLimits.maxItems { feed.items = Array(feed.items.prefix(FeedLimits.maxItems)); feed.truncated = true }
        return .loaded(Loaded(feed: feed, url: final, alternatives: alternatives, validators: (validators.isEmpty || !alternatives.isEmpty || page > 1) ? nil : validators))
    }
}

// MARK: From items to downloads

enum DiskPreflight {
    /// Room kept free beyond the files themselves (temporary files, other downloads, the system).
    static let margin: Int64 = 500_000_000

    /// Free space for the downloads folder, for the volume's "important" uses (what the system would clear out of purgeable space to make room); 0 when it cannot be read.
    static func freeBytes(at folder: URL) -> Int64 {
        if let important = DiskSpace.available(at: folder) { return important }
        return Int64((try? folder.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity ?? 0)
    }

    /// nil when the sizes that are known fit (unknown sizes cannot be counted and do not block); otherwise a sentence saying how much is needed and how much there is.
    static func problem(needed: Int64, free: Int64) -> String? {
        guard needed > 0, free > 0, needed > free - margin else { return nil }          // (written so a huge stated size cannot overflow)
        let f = ByteCountFormatter(); f.countStyle = .file
        return "These files need about \(f.string(fromByteCount: needed)) and only \(f.string(fromByteCount: free)) is free. Choose fewer, or free some space."
    }
}

enum FeedCollection {
    /// The file ending for an enclosure: the address's own when it is a known file ending, else the one its declared type implies; nil when neither says.
    static func fileExtension(for enclosure: FeedEnclosure) -> String? {
        let ext = enclosure.url.pathExtension.lowercased()
        if LinkClassifier.fileExtensions.contains(ext) { return ext }
        if let mime = enclosure.type?.split(separator: ";").first.map({ String($0).trimmingCharacters(in: .whitespaces) }), let e = UTType(mimeType: mime)?.preferredFilenameExtension,
           e.count <= 8, e.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) { return e.lowercased() }
        return ext.isEmpty || ext.count > 8 ? nil : ext
    }

    /// One link per enclosure of the chosen items, each named after its episode/entry title with the right ending, grouped under the feed's name. A feed declares these as files, so they are file links
    /// even when the address has no file ending. Items without an enclosure are left out (there is nothing to download).
    static func links(for items: [DownloadFeedItem], feed: DownloadFeed, profile: String, isPrivate: Bool) -> [DetectedLink] {
        var out: [DetectedLink] = []
        var usedNames = Set<String>()
        for item in items {
            for (index, enclosure) in item.enclosures.enumerated() {
                let ext = fileExtension(for: enclosure)
                var title = item.title
                if index > 0 { title += " (\(index + 1))" }
                var name = FilenameResolver.resolve(.init(mediaTitle: title, url: enclosure.url, mimeType: enclosure.type), context: .extractedMedia, outputExtension: ext).name
                // Two entries with the same title in one batch get different names, so neither replaces the other.
                if !usedNames.insert(name.lowercased()).inserted { name = FileNaming.unique(name, style: .parenthesized) { usedNames.contains($0.lowercased()) }; usedNames.insert(name.lowercased()) }
                let c = LinkClassifier.classify(enclosure.url.absoluteString)
                var meta: [String: String] = ["feed": String(feed.title.prefix(120)), "itemKey": item.id + "#" + String(index)]
                if let p = item.published { meta["published"] = ISO8601DateFormatter().string(from: p) }
                if let e = item.episode { meta["episode"] = String(e) }
                if let s = item.season { meta["season"] = String(s) }
                var link = DetectedLink(id: LinkClassifier.normalizedKey(enclosure.url), original: enclosure.url.absoluteString, display: c.display, kind: .httpResource, name: name, host: enclosure.url.host,
                                        provenance: .page, profile: profile, isPrivate: isPrivate, group: feed.title)
                link.suggestedFilename = name
                link.metadata = meta
                out.append(link)
            }
        }
        return out
    }
}
