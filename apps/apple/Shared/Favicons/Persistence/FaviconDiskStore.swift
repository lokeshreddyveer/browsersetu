import Foundation

/// One profile's icons on disk: a versioned index and content-addressed PNG files.
///
///     <profile>/favicons/
///         index.json            FaviconIndex (records, resources, failures); written atomically
///         blobs/<sha256>.png    one small PNG per distinct icon, shared by every site that shows it
///
/// Not thread-safe by itself: it is owned by `FaviconService` (an actor) and used only from there.
///
/// Guarantees:
///  - a blob is written before the index that names it, and the index is replaced atomically, so a crash leaves either the old state or the new one;
///  - an index that cannot be read, or that is newer than this build understands, is moved aside (`index.corrupt-<time>.json`, the last three kept) and replaced by an empty one, never overwritten in place;
///  - at start, blobs nothing refers to are removed, and records whose blob is missing are dropped;
///  - the budget (records and bytes) is enforced by evicting the least recently used record, ties broken by key, so the same history always evicts the same icons.
final class FaviconDiskStore {
    let directory: URL
    let budget: FaviconBudget
    private(set) var index = FaviconIndex()
    private(set) var quarantined = false
    private var dirty = false
    private let blobDirectory: URL
    private let indexURL: URL
    private let fileManager = FileManager.default

    init(directory: URL, budget: FaviconBudget = .standard) {
        self.directory = directory
        self.budget = budget
        blobDirectory = directory.appendingPathComponent("blobs", isDirectory: true)
        indexURL = directory.appendingPathComponent("index.json")
        load()
    }

    // MARK: Reading

    func record(_ key: IconKey) -> IconRecord? { index.records[key.host] }
    func failure(_ key: IconKey) -> IconFailure? { index.failures[key.host] }
    var recordCount: Int { index.records.count }
    var totalBytes: Int { index.resources.values.reduce(0) { $0 + $1.bytes } }
    var hasUnsavedChanges: Bool { dirty }

    func resourceData(_ id: String) -> Data? {
        guard index.resources[id] != nil else { return nil }
        return try? Data(contentsOf: blobURL(id))
    }

    func resourceMeta(_ id: String) -> IconResourceMeta? { index.resources[id] }

    // MARK: Writing

    /// Stores PNG bytes (once, however many sites show them) and returns their identity.
    @discardableResult
    func put(png: Data, width: Int, height: Int, now: Date) -> IconResourceID {
        let id = IconResourceID(data: png)
        if index.resources[id.hex] == nil || !fileManager.fileExists(atPath: blobURL(id.hex).path) {
            try? fileManager.createDirectory(at: blobDirectory, withIntermediateDirectories: true)
            try? png.write(to: blobURL(id.hex), options: .atomic)
            index.resources[id.hex] = IconResourceMeta(bytes: png.count, pixelWidth: width, pixelHeight: height, mimeType: "image/png", createdAt: now)
        }
        dirty = true
        return id
    }

    func setRecord(_ record: IconRecord) {
        let old = index.records[record.key]
        index.records[record.key] = record
        index.failures[record.key] = nil
        dirty = true
        if let old { releaseIfUnreferenced([old.resource, old.darkResource].compactMap { $0 }) }
        evictIfNeeded()
    }

    func touch(_ key: IconKey, now: Date) {
        guard var record = index.records[key.host] else { return }
        record.lastUsed = now
        index.records[key.host] = record
        dirty = true
    }

    /// Remembers that a site had no usable icon; the next try waits longer each time, to at most a day.
    func recordFailure(_ key: IconKey, reason: String, now: Date) {
        let previous = index.failures[key.host]?.count ?? 0
        let count = previous + 1
        let delay = min(24 * 3600.0, 600.0 * pow(2.0, Double(min(count - 1, 10))))
        index.failures[key.host] = IconFailure(key: key.host, failedAt: now, retryAfter: now.addingTimeInterval(delay), count: count, reason: reason)
        // Bounded: the failure list never outgrows the record budget.
        if index.failures.count > budget.maxRecords {
            let victims = index.failures.values.sorted { ($0.failedAt, $0.key) < ($1.failedAt, $1.key) }.prefix(index.failures.count - budget.maxRecords)
            for victim in victims { index.failures[victim.key] = nil }
        }
        dirty = true
    }

    func remove(_ key: IconKey) {
        let old = index.records.removeValue(forKey: key.host)
        index.failures[key.host] = nil
        dirty = true
        if let old { releaseIfUnreferenced([old.resource, old.darkResource].compactMap { $0 }) }
    }

    /// Every icon of a host, whatever its port (the site's data was removed).
    func removeHost(_ host: String) {
        let matches: (String) -> Bool = { $0 == host || $0.hasPrefix(host + ":") }
        for (key, record) in index.records where matches(key) {
            index.records[key] = nil
            releaseIfUnreferenced([record.resource, record.darkResource].compactMap { $0 })
        }
        for key in index.failures.keys where matches(key) { index.failures[key] = nil }
        dirty = true
    }

    /// Forgets everything. An empty index (marked as having read the old cache in) is written by the next flush, not just removed: a relaunch must not
    /// read the old shared cache in again and bring every cleared icon back.
    func removeAll() {
        index = FaviconIndex()
        index.legacyImported = true
        try? fileManager.removeItem(at: blobDirectory)
        dirty = true
    }

    /// Drops the least recently used records until both budgets hold. Returns the keys it dropped.
    @discardableResult
    func evictIfNeeded() -> [String] {
        var dropped: [String] = []
        while index.records.count > budget.maxRecords || totalBytes > budget.maxBytes, let victim = index.records.values.min(by: { ($0.lastUsed, $0.key) < ($1.lastUsed, $1.key) }) {
            index.records[victim.key] = nil
            dropped.append(victim.key)
            releaseIfUnreferenced([victim.resource, victim.darkResource].compactMap { $0 })
            dirty = true
        }
        return dropped
    }

    // MARK: Persistence

    /// Writes the index if anything changed. The temporary file and the rename make it all-or-nothing.
    func flush() {
        guard dirty else { return }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(index) else { return }
        do { try data.write(to: indexURL, options: .atomic); dirty = false } catch { /* disk full or the folder is gone: stay dirty, try again at the next flush */ }
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(FaviconIndex.self, from: data), decoded.schemaVersion <= FaviconIndex.currentVersion else {
            quarantine()
            return
        }
        index = decoded
        sweep()
    }

    /// An unreadable (or too new) index is set aside for a person to find, and the profile starts with an empty one.
    private func quarantine() {
        // Kept under its own name (the last three), so a second problem does not overwrite the evidence of the first.
        let stamp = Int(Date().timeIntervalSince1970)
        try? fileManager.moveItem(at: indexURL, to: directory.appendingPathComponent("index.corrupt-\(stamp).json"))
        if let names = try? fileManager.contentsOfDirectory(atPath: directory.path).filter({ $0.hasPrefix("index.corrupt-") }).sorted(), names.count > 3 {
            for name in names.prefix(names.count - 3) { try? fileManager.removeItem(at: directory.appendingPathComponent(name)) }
        }
        quarantined = true
        index = FaviconIndex()
        sweep()
    }

    /// After a crash or a quarantine: blobs nothing refers to go, and records whose blob is gone go too.
    private func sweep() {
        var changed = false
        for (id, _) in index.resources where !fileManager.fileExists(atPath: blobURL(id).path) {
            index.resources[id] = nil
            changed = true
        }
        for (key, record) in index.records {
            if index.resources[record.resource] == nil { index.records[key] = nil; changed = true }
            else if let dark = record.darkResource, index.resources[dark] == nil { index.records[key]?.darkResource = nil; changed = true }
        }
        let referenced = referencedResources()
        for id in index.resources.keys where !referenced.contains(id) { index.resources[id] = nil; changed = true }
        if let files = try? fileManager.contentsOfDirectory(atPath: blobDirectory.path) {
            for name in files where name.hasSuffix(".png") && !referenced.contains(String(name.dropLast(4))) { try? fileManager.removeItem(at: blobDirectory.appendingPathComponent(name)) }
        }
        if changed { dirty = true }
    }

    private func referencedResources() -> Set<String> {
        var set = Set<String>()
        for record in index.records.values { set.insert(record.resource); if let dark = record.darkResource { set.insert(dark) } }
        return set
    }

    private func releaseIfUnreferenced(_ ids: [String]) {
        let referenced = referencedResources()
        for id in ids where !referenced.contains(id) {
            index.resources[id] = nil
            try? fileManager.removeItem(at: blobURL(id))
        }
    }

    private func blobURL(_ id: String) -> URL { blobDirectory.appendingPathComponent(id + ".png") }

    // MARK: Migration from the old shared cache

    /// Reads the old per-host PNG files (`<Caches>/SiteIcons/<host>.png`, shared by every profile) into this profile once.
    /// The old files are left where they are: this reads them, it does not delete anything. Returns how many icons were taken in.
    @discardableResult
    func importLegacy(from legacy: URL, now: Date, lifetime: TimeInterval = 14 * 24 * 3600) -> Int {
        guard !index.legacyImported else { return 0 }
        index.legacyImported = true
        dirty = true
        guard let files = try? fileManager.contentsOfDirectory(at: legacy, includingPropertiesForKeys: [.contentModificationDateKey]) else { return 0 }
        var imported = 0
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).prefix(3_000) where file.pathExtension == "png" {
            let host = file.deletingPathExtension().lastPathComponent
            guard let key = IconKey(host: host), index.records[key.host] == nil, let data = try? Data(contentsOf: file),
                  case .success(let decoded) = IconDecoder.decode(data) else { continue }
            let fetched = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            let id = put(png: decoded.png, width: decoded.sourceWidth, height: decoded.sourceHeight, now: now)
            index.records[key.host] = IconRecord(key: key.host, resource: id.hex, darkResource: nil, sourceHost: key.host, sourceDigest: "legacy", kind: .hostDefault,
                                                 fetchedAt: fetched, validatedAt: fetched, expiresAt: fetched.addingTimeInterval(lifetime), etag: nil, lastModified: nil, lastUsed: fetched)
            imported += 1
        }
        evictIfNeeded()
        return imported
    }
}
