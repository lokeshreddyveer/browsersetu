import Foundation

/// The single owner of favicon resolution for one profile. Everything that learns, finds, refreshes or forgets an icon goes through here.
///
///     discovery (page links) ──▶ IconCandidateRanker ──▶ FaviconService ──▶ IconFetching (network, shared request policy)
///                                                              │                    │
///                                                              ▼                    ▼
///                                                      FaviconDiskStore       IconDecoder (off the actor)
///
/// It is an actor, so its state (the index, the requests in flight) has one owner and needs no locks. The work that takes time happens off it:
/// the network (suspension points) and decoding (a detached task).
///
/// What it guarantees:
///  - one fetch per site at a time: a second request for the same site waits for the first and shares its answer,
///  - at most `maxConcurrentFetches` fetches at once across all sites,
///  - an icon is stored under the site of the PAGE THAT NAMED IT (the page address is captured when the links are read), never under whatever the tab shows later,
///  - a fresh icon is not fetched again; an expired one is asked about conditionally (ETag, Last-Modified) and costs no body when unchanged,
///  - a site with no usable icon is not asked again at once: the wait doubles from ten minutes to a day,
///  - a failure that says nothing about the site (offline, slow, cancelled) is never remembered against it,
///  - an icon that was good and now fails keeps being served, and is tried again in an hour.
actor FaviconService {
    static let defaultLifetime: TimeInterval = 14 * 24 * 3600
    static let minimumLifetime: TimeInterval = 3600
    static let maximumLifetime: TimeInterval = 30 * 24 * 3600
    static let retryAfterStaleFailure: TimeInterval = 3600

    private let directoryURL: URL
    private let budget: FaviconBudget
    /// Opened on first use, on this actor, so creating a service on the main thread reads no file.
    private var opened: FaviconDiskStore?
    private var store: FaviconDiskStore {
        if let opened { return opened }
        let made = FaviconDiskStore(directory: directoryURL, budget: budget)
        opened = made
        if made.quarantined { log.add(.quarantined, host: "", detail: "index", at: now()) }
        return made
    }
    private let fetcher: IconFetching
    private let now: @Sendable () -> Date
    private let maxConcurrentFetches: Int
    private var inFlight: [IconKey: Task<IconResolution, Never>] = [:]
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var flushTask: Task<Void, Never>?
    private var log = FaviconDiagnosticsLog()
    /// Bumped by `clear()`. Work that began under an older one stores nothing.
    private var clearEpoch = 0
    /// Bumped for a site when its icon is removed, with the same meaning.
    private var removals: [IconKey: Int] = [:]
    /// A closed service (its profile was left) writes nothing, ever again.
    private var closed = false
    /// What the browser's protection blocks (see `IconBlocklist`): an icon on a blocked third-party host is not fetched.
    private var blocklist = IconBlocklist.empty
    /// How many times the network was asked, for tests and diagnostics.
    private(set) var fetchCount = 0

    init(directory: URL, budget: FaviconBudget = .standard, fetcher: IconFetching = NetworkIconFetcher(), maxConcurrentFetches: Int = 3, now: @escaping @Sendable () -> Date = { Date() }) {
        directoryURL = directory
        self.budget = budget
        self.fetcher = fetcher
        self.now = now
        self.maxConcurrentFetches = max(1, maxConcurrentFetches)
    }

    var directory: URL { directoryURL }

    func setBlocklist(_ list: IconBlocklist) { blocklist = list }

    // MARK: Reading (cheap, no network)

    /// The stored PNG for a site, for the appearance asked for, or nil. Marks the icon as used.
    func lookup(_ key: IconKey, scheme: IconColorScheme = .light) -> Data? {
        guard let record = store.record(key) else { return nil }
        let id = (scheme == .dark ? record.darkResource : nil) ?? record.resource
        guard let data = store.resourceData(id) else { return nil }
        store.touch(key, now: now())          // noted in memory; written with the next change, when the app goes to the background or when it quits
        return data
    }

    /// Both appearances of a site's icon in one read: the light one, and the dark one when the site made one. A view that needs either asks once.
    func lookupVariants(_ key: IconKey) -> (light: Data, dark: Data?)? {
        guard let record = store.record(key), let light = store.resourceData(record.resource) else { return nil }
        let dark = record.darkResource.flatMap { store.resourceData($0) }
        store.touch(key, now: now())
        return (light, dark)
    }

    func hasIcon(_ key: IconKey) -> Bool { store.record(key) != nil }
    func isFresh(_ key: IconKey) -> Bool { store.record(key)?.isFresh(at: now()) ?? false }
    func isBackedOff(_ key: IconKey) -> Bool { store.record(key) == nil && (store.failure(key)?.retryAfter ?? .distantPast) > now() }
    var recordCount: Int { store.recordCount }
    var storedBytes: Int { store.totalBytes }
    func diagnostics() -> [FaviconDiagnosticEvent] { log.events }

    // MARK: Resolving

    /// Makes sure the page's site has an icon: from the store when it is fresh, otherwise from the page's declared icons and the site's /favicon.ico.
    @discardableResult
    func resolve(pageURL: URL, declared: [IconCandidate]) async -> IconResolution {
        guard !closed, let scheme = pageURL.scheme?.lowercased(), scheme == "https" || scheme == "http", let key = IconKey(url: pageURL) else { return .noIcon }
        let time = now()
        if let record = store.record(key), record.isFresh(at: time) {
            store.touch(key, now: time)
            log.add(.cacheHit, host: key.host, at: time)
            return .cached
        }
        if store.record(key) == nil, let failure = store.failure(key), failure.retryAfter > time {
            log.add(.backedOff, host: key.host, detail: failure.reason, at: time)
            return .backedOff
        }
        if let running = inFlight[key] { return await running.value }
        let task = Task { await self.fetchAndStore(key: key, pageURL: pageURL, declared: declared) }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    /// Stops the work for a site (a tab closed, a profile left). A cancelled fetch stores nothing.
    func cancel(host: String) { if let key = IconKey(host: host) { inFlight[key]?.cancel() } }
    func cancelAll() { for task in inFlight.values { task.cancel() } }

    /// True while nothing has cleared or removed what this work was started for, and it has not been cancelled.
    private func stillWanted(_ key: IconKey, epoch: Int, removal: Int) -> Bool {
        !Task.isCancelled && !closed && epoch == clearEpoch && removal == (removals[key] ?? 0)
    }

    private func fetchAndStore(key: IconKey, pageURL: URL, declared: [IconCandidate]) async -> IconResolution {
        let ordered = IconCandidateRanker.ordered(declared, pageURL: pageURL)
        guard !ordered.isEmpty else { return .noIcon }
        let epoch = clearEpoch, removal = removals[key] ?? 0
        log.add(.candidateOrder, host: key.host, detail: "\(ordered.count)", at: now())
        let existing = store.record(key)
        let origin = HTTPRequestPolicy.origin(of: pageURL)
        var transient = false
        var lastReason = "none"

        for candidate in ordered {
            guard stillWanted(key, epoch: epoch, removal: removal) else { return .noIcon }
            if blocklist.blocks(iconHost: candidate.url.host ?? "", pageHost: pageURL.host ?? "") {
                log.add(.candidateBlocked, host: key.host, at: now())
                lastReason = "blocked"
                continue
            }
            let digest = Self.digest(of: candidate.url)
            let conditional = (existing?.sourceDigest == digest) ? existing : nil
            let result = await fetchLimited(IconFetchRequest(url: candidate.url, pageHost: pageURL.host ?? "", etag: conditional?.etag, lastModified: conditional?.lastModified, pageOrigin: origin))
            guard stillWanted(key, epoch: epoch, removal: removal) else { return .noIcon }
            switch result {
            case .notModified(let hints):
                guard var record = conditional else { continue }
                let time = now()
                record.validatedAt = time
                record.expiresAt = time.addingTimeInterval(Self.lifetime(for: hints))
                record.etag = hints.etag ?? record.etag
                record.lastModified = hints.lastModified ?? record.lastModified
                record.lastUsed = time
                store.setRecord(record)
                scheduleFlush()
                log.add(.revalidated, host: key.host, at: time)
                return .revalidated
            case .failed(let failure):
                transient = transient || failure.isTransient
                lastReason = failure.rawValue
                log.add(.fetchFailed, host: key.host, detail: failure.rawValue, at: now())
            case .fresh(let body):
                switch await Self.decode(body.data) {
                case .failure(let failure):
                    lastReason = failure.rawValue
                    log.add(.decodeFailed, host: key.host, detail: failure.rawValue, at: now())
                case .success(let output):
                    // Everything that takes time (the dark variant's fetch and decode) is done before anything is stored, and the check that nothing was cleared
                    // meanwhile comes after the last wait. From `put` to `setRecord` there is no suspension, so no other work can slip between the file and its record.
                    let dark = await darkOutput(for: pageURL, declared: declared, origin: origin)
                    guard stillWanted(key, epoch: epoch, removal: removal) else { return .noIcon }
                    let time = now()
                    let id = store.put(png: output.png, width: output.sourceWidth, height: output.sourceHeight, now: time)
                    let darkID = dark.map { store.put(png: $0.png, width: $0.sourceWidth, height: $0.sourceHeight, now: time).hex }
                    store.setRecord(IconRecord(key: key.host, resource: id.hex, darkResource: darkID, sourceHost: candidate.url.host?.lowercased() ?? key.host, sourceDigest: digest, kind: candidate.kind,
                                               fetchedAt: time, validatedAt: time, expiresAt: time.addingTimeInterval(Self.lifetime(for: body.hints)),
                                               etag: body.hints.etag, lastModified: body.hints.lastModified, lastUsed: time))
                    for dropped in store.evictIfNeeded() { log.add(.evicted, host: dropped, at: time) }
                    scheduleFlush()
                    log.add(.stored, host: key.host, detail: candidate.source.rawValue, at: time)
                    return .refreshed
                }
            }
        }
        // Nothing worked.
        if transient { return .offline }
        guard stillWanted(key, epoch: epoch, removal: removal) else { return .noIcon }
        let time = now()
        if var record = existing {
            // A good icon is kept. It is asked about again in an hour, not forgotten.
            record.expiresAt = time.addingTimeInterval(Self.retryAfterStaleFailure)
            store.setRecord(record)
            scheduleFlush()
            log.add(.staleKept, host: key.host, detail: lastReason, at: time)
            return .staleKept
        }
        store.recordFailure(key, reason: lastReason, now: time)
        scheduleFlush()
        return .noIcon
    }

    private func darkOutput(for page: URL, declared: [IconCandidate], origin: String) async -> IconDecoder.Output? {
        for candidate in IconCandidateRanker.darkVariants(declared) {
            if blocklist.blocks(iconHost: candidate.url.host ?? "", pageHost: page.host ?? "") { continue }
            guard case .fresh(let body) = await fetchLimited(IconFetchRequest(url: candidate.url, pageHost: page.host ?? "", pageOrigin: origin)),
                  case .success(let output) = await Self.decode(body.data) else { continue }
            return output
        }
        return nil
    }

    // MARK: Forgetting

    func remove(host: String) {
        guard !closed, let base = IconKey(host: host)?.host else { return }
        for key in inFlight.keys where key.host == base || key.host.hasPrefix(base + ":") { removals[key, default: 0] += 1; inFlight[key]?.cancel() }
        if let key = IconKey(host: base) { removals[key, default: 0] += 1 }
        store.removeHost(base)
        scheduleFlush()
    }

    /// Everything this profile knows about icons, in memory and on disk.
    func clear() {
        guard !closed else { return }
        clearEpoch += 1
        cancelAll()
        inFlight.removeAll()
        store.removeAll()
        store.flush()
        flushTask?.cancel(); flushTask = nil
        log.removeAll()
        log.add(.cleared, host: "", at: now())
    }

    /// Stops everything for good: pending work is cancelled, what is unsaved is written, and from now on nothing is written, so a service whose profile was left
    /// (or deleted) cannot recreate its folder or overwrite the next service's files.
    func close() {
        guard !closed else { return }
        cancelAll()
        flushTask?.cancel(); flushTask = nil
        opened?.flush()
        closed = true
    }

    @discardableResult
    func importLegacy(from legacy: URL) -> Int {
        guard !closed else { return 0 }
        let count = store.importLegacy(from: legacy, now: now())
        if count > 0 { log.add(.imported, host: "", detail: "\(count)", at: now()); scheduleFlush() }
        return count
    }

    /// Writes any pending change now (at quit, and in tests).
    func flush() {
        flushTask?.cancel(); flushTask = nil
        guard !closed, let opened else { return }
        opened.flush()
    }

    /// A change to the index is written half a second later (a burst of icons is one write). Reads only note a use in memory, so scrolling a long list writes nothing.
    private func scheduleFlush() {
        guard flushTask == nil, !closed else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    // MARK: Limits and helpers

    private func fetchLimited(_ request: IconFetchRequest) async -> IconFetchResult {
        await acquire()
        fetchCount += 1
        let result = await fetcher.fetch(request)
        release()
        return result
    }

    private func acquire() async {
        if running < maxConcurrentFetches { running += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { running -= 1 } else { waiters.removeFirst().resume() }
    }

    nonisolated static func decode(_ data: Data) async -> Result<IconDecoder.Output, IconDecoder.Failure> {
        await Task.detached(priority: .utility) { IconDecoder.decode(data) }.value
    }

    static func lifetime(for hints: IconCacheHints) -> TimeInterval {
        if hints.noStore { return minimumLifetime }
        return min(maximumLifetime, max(minimumLifetime, hints.maxAge ?? defaultLifetime))
    }

    static func digest(of url: URL) -> String { IconResourceID(data: Data(IconCandidateRanker.normalised(url).utf8)).hex }
}
