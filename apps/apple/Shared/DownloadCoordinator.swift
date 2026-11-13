import CryptoKit
import Foundation
import Combine
#if os(macOS)
import AppKit
#endif

/// A download that stopped part-way (the connection dropped, say) and can carry on from where it got to, if the server allows.
struct InterruptedDownload: Identifiable {
    let id: UUID
    var filename: String
    var resumeData: Data
    var source: URL?
    /// What carrying on really means for this one (from its bytes, or from the start). The wording and the button follow it.
    var recovery: DownloadRecoveryClass = .resumable
}

struct ActiveDownload: Identifiable {
    let id: UUID
    var filename: String
    var fraction: Double
    var completedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    /// Smoothed transfer rate; zero until two samples have arrived.
    var bytesPerSecond: Double = 0
    var lastSample: Date = Date()
    /// The same moment on the monotonic clock: speed is measured on this, so a change of the system clock cannot make it jump or go negative.
    var lastSampleUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    var lastBytes: Int64 = 0
    var warnedDisk = false

    /// "48 of 78 MB · 6.1 MB/s · about 5 s left", with whatever parts are known.
    var detail: String { DownloadStats.detail(completed: completedBytes, total: totalBytes, rate: bytesPerSecond) }
}

/// Engine-neutral download bookkeeping. Engines report events; this decides where files go.
@MainActor
final class DownloadCoordinator: ObservableObject {
    @Published private(set) var active: [UUID: ActiveDownload] = [:] {
        didSet {
            #if os(iOS)
            if oldValue.isEmpty != active.isEmpty { DownloadBackgroundTask.shared.coordinator = self; DownloadBackgroundTask.shared.update(hasActive: !active.isEmpty) }
            #endif
        }
    }
    /// Counts the downloads the person started themselves. The window animates a small flight to the Downloads button when it goes up; queued, scheduled and
    /// resumed downloads never raise it, so background work does not animate.
    @Published private(set) var userStarts = 0
    private var flightsQuietUntil = Date.distantPast
    /// Downloads that begin within a few seconds of this (a schedule or a resume starting them) are not the person's action.
    func quietFlights(for seconds: TimeInterval = 4) { flightsQuietUntil = Date().addingTimeInterval(seconds) }
    @Published private(set) var completed: [URL] = []
    @Published private(set) var interrupted: [UUID: InterruptedDownload] = [:]
    /// The failures the person has already seen (the downloads list was opened). A failure not in here marks the Downloads buttons, whatever else was dismissed or
    /// cleared meanwhile. Shared by the toolbar's and the footer's.
    @Published private(set) var seenFailureIDs: Set<UUID> = []
    var hasUnseenFailure: Bool { failures.contains { !seenFailureIDs.contains($0.id) } }
    func markFailuresSeen() { seenFailureIDs.formUnion(failures.map(\.id)) }
    /// Set by the engine: starts a download again from its resume data.
    var resumer: ((Data) -> Void)?
    /// Preferred over `resumer` when set: also tells the engine which task is being resumed, so the resumed download keeps its identity.
    var resumerWithID: ((Data, UUID) -> Void)?
    /// What each kind of engine can do, so a control is shown only when it will work.
    let engines = DownloadEngineRegistry()
    /// The one record of every task and the only writer of the task database.
    private(set) var ledger = DownloadLedger(profile: "default") { didSet { hookLedger() } }
    /// Fires when a task is created, changes state or fields, or is removed. The Downloads lists listen to this (and to the live progress) instead of asking the database.
    let tasksChanged = PassthroughSubject<Void, Never>()
    private func hookLedger() { ledger.onChange = { [weak self] in self?.tasksChanged.send() } }
    /// The browser profile these downloads belong to; set before `store`.
    var profileName = "default" { didSet { if store == nil, oldValue != profileName { ledger = DownloadLedger(profile: profileName) } } }
    /// Tasks started again from an address (a scheduled one, a retry, "Try Again") keep their identity: the id waits here for the engine's next admission of that address.
    private var reservedIDs: [String: UUID] = [:]
    /// The standalone HTTP engine and the code that runs it (created when first used).
    private(set) lazy var http = HTTPDownloadRunner(coordinator: self)
    /// BitTorrent downloads (off until the person turns peer-to-peer on).
    /// eD2k downloads (off until the person turns them on).
    private(set) lazy var ed2k: ED2KRunner = { hasED2KRunner = true; return ED2KRunner(coordinator: self) }()
    var ed2kSettings = ED2KSettings() { didSet { applyED2KSettings() } }
    var ed2kStarted: Bool { hasED2KRunner }
    private var hasED2KRunner = false
    /// Streaming (HLS and DASH) downloads: segments fetched through the same policy and budget as every other download.
    private(set) lazy var media: MediaRunner = { hasMediaRunner = true; return MediaRunner(coordinator: self) }()
    var mediaStarted: Bool { hasMediaRunner }
    /// Taking chosen files out of a ZIP archive on a website, as a task.
    /// Saved FTP / FTPS / SFTP / WebDAV servers of this profile (secrets in the Keychain), and the runner that fetches their files as ordinary tasks.
    /// Tests only: where saved servers' secrets go instead of the Keychain (must be set before `remotes` is first used).
    var remoteSecretOverride: AccountSecretStore?
    private(set) lazy var remotes: RemoteConnectionStore = RemoteConnectionStore(profile: profileName, folder: store ?? FileManager.default.temporaryDirectory.appendingPathComponent("bs-remote-\(UUID().uuidString.prefix(8))"),
                                                                                  isPrivate: store == nil, secrets: remoteSecretOverride ?? KeychainAccountSecretStore(profile: profileName))
    private(set) lazy var remoteFiles: RemoteFileRunner = { hasRemoteFileRunner = true; return RemoteFileRunner(coordinator: self) }()
    var remoteFilesStarted: Bool { hasRemoteFileRunner }
    private var hasRemoteFileRunner = false
    private var sha512Watch: AnyCancellable?
    private(set) lazy var remoteZip: RemoteZipRunner = { hasRemoteZipRunner = true; return RemoteZipRunner(coordinator: self) }()
    var remoteZipStarted: Bool { hasRemoteZipRunner }
    private var hasRemoteZipRunner = false
    /// Other sources for downloads (mirrors), per task. Created when first used.
    private(set) lazy var mirrors: MirrorStore = MirrorStore(coordinator: self, file: store?.appendingPathComponent("mirrors.json"))
    /// One file of a Metalink description becomes one download, with its other addresses as sources. The description is a stranger's document: its addresses are page-derived, so the
    /// download is held to the page rules and its sources are tried one at a time, never combined. Starts nothing until its time comes, like any scheduled download.
    @discardableResult
    func addFromMetalink(_ file: MetalinkFile, origin: DownloadRequestOrigin = .page, at start: Date = Date()) -> UUID? {
        guard let first = file.urls.first.flatMap(URL.init(string:)),
              let id = scheduleDownload(url: first, at: start, filename: file.name, expectedSHA256: file.sha256, origin: origin) else { return nil }
        if let size = file.size { ledger.update(id) { $0.engineMetadata["expectedSize"] = String(size) } }
        if let s = file.sha512, file.sha256 == nil { ledger.update(id) { $0.engineMetadata["sha512"] = s } }          // checked when the file is complete (see verifyPendingSHA512)
        mirrors.add(Array(file.urls.dropFirst()), to: id)
        return id
    }

    /// This profile's download packages (named groupings of tasks in this ledger). Created when first used, from the profile's own task folder.
    private(set) lazy var packages: PackageStore = PackageStore(coordinator: self, file: store?.appendingPathComponent("packages.json"))
    /// This profile's feed subscriptions and the feed items already handled (local, in the profile's own folder; nothing for a private session, which has no coordinator store).
    private(set) lazy var feeds: FeedStore = FeedStore(profile: profileName, file: store?.appendingPathComponent("feeds.json"))
    private var hasMediaRunner = false
    private(set) lazy var torrents: TorrentRunner = { hasTorrentRunner = true; return TorrentRunner(coordinator: self) }()
    var torrentSettings = TorrentSettings() { didSet { applyTorrentSettings() } }
    /// Whether the torrent runner has been made (it is only made when a torrent is used, so a profile that never uses one never creates it).
    var torrentsStarted: Bool { hasTorrentRunner }
    private var hasTorrentRunner = false
    /// Set by the engine: whether it has a page to start downloads from right now. Without one, nothing is started and nothing is thrown away.
    var hasHost: (() -> Bool)?
    /// Downloads that stopped for good, with why: shown in the list until the person dismisses them. Only in memory, and never for a private download.
    @Published private(set) var failures: [DownloadFailure] = []
    // MARK: Network (Phase 8)
    /// Speed, connections, proxy and network-condition choices for this profile. Setting it applies everything at once; see `applyNetworkSettings`.
    var networkSettings = DownloadNetworkSettings() { didSet { applyNetworkSettings() } }
    /// Where a proxy password is kept (the Keychain; replaced in tests).
    var proxyCredentials: ProxyCredentialStore = KeychainProxyCredentialStore()
    /// Why new downloads are being held by the network policy right now, if they are. Never set by the person's own pause.
    @Published private(set) var networkHold: NetworkHold?
    /// Downloads the network policy stopped (not the person): only these are started again when the hold lifts.
    var policyPaused = Set<UUID>()
    var proxyPasswordCache: (profile: String, value: String?)?
    /// What the system says about the connection (replaced in tests).
    var networkPath: () -> PathInfo = { NetworkConditions.shared.info }
    func setNetworkHold(_ hold: NetworkHold?) { networkHold = hold }

    /// What to do when a file with the same name is already in the folder.
    var duplicatePolicy = DuplicatePolicy.keepBoth
    /// What the person decided for downloads whose name is taken, when the policy is to ask: those to replace (the old file goes to the Trash), nothing else is replaced.
    private var replaceChosen = Set<UUID>()
    enum DuplicateChoice { case keepBoth, replace, skip }
    /// Asks the person what to do about a name that is taken. Replaced in tests; by default a dialog.
    var duplicateAsker: (_ filename: String) async -> DuplicateChoice = { name in
        let pressed = await Dialogs.choose(title: "“\(name)” is already in your Downloads", message: "Keep both, replace the old file (it goes to the Trash), or skip this download?", buttons: ["Keep Both", "Replace", "Skip"])
        return pressed == 1 ? .replace : (pressed == 2 ? .skip : .keepBoth)
    }
    /// How downloads are named: "{name}" is the name the site gave (without its ending), "{host}" the site, "{date}" and "{time}" when it was fetched.
    var nameTemplate = "{name}"
    private var sourceURLs: [UUID: URL] = [:]
    /// Addresses whose pieces went wrong: they are fetched the ordinary way from then on.
    private(set) var noPieces = Set<String>()
    /// Sort new downloads into folders by kind (Images, Documents, Archives…) inside the downloads folder.
    var organize = false
    /// Fetch large files in several pieces at once (see PieceDownload.swift).
    var segmentedEnabled = true
    /// A folder named for the profile, inside the downloads folder, when downloads are kept apart by profile.
    var profileFolder: String?
    /// Sort new downloads into a folder named after the site they came from.
    var organizeByDomain = false
    /// Recent download events (start, finish, failure, warnings) for "Copy Download Diagnostics".
    private(set) var events: [String] = []
    /// Raised once per download when the disk looks too full for it.
    var onLowDisk: ((_ filename: String, _ needed: Int64, _ available: Int64) -> Void)?
    /// The user's rules by site and kind; the first match names the folder, ahead of sorting by kind.
    var rules: [DownloadRule] = []
    /// `isPrivate`: the download came from a private (or scratch) tab, so nothing about it may be written down.
    var onFinished: ((_ source: URL?, _ filename: String, _ isPrivate: Bool) -> Void)?

    // MARK: The queue
    //
    // Who goes next, how many may run, what is held and what is due later is decided by `DownloadScheduler`. What is here is the glue: the tickets engines wait on, the lists the
    // panel shows, and the starting of a task from its address.

    @Published private(set) var waiting: [QueuedDownload] = []
    @Published private(set) var scheduled: [ScheduledDownload] = []
    /// While set and in the future, nothing new is started: what arrives meanwhile is remembered and started when the hold ends.
    @Published private(set) var heldUntil: Date?
    /// Starts that were due while the app was closed and are too old to go ahead on their own: the person decides.
    @Published private(set) var overdue: Set<UUID> = []
    /// How many may run at the same time; the rest wait their turn.
    var maxConcurrent = DownloadQueueRules.defaultConcurrent { didSet { scheduler.pump() } }
    /// Starts a download again from its address (the engine sets this). Used for scheduled downloads and for retries that have no resume data.
    var starter: ((URL) -> Void)?
    private var tickets: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var attempts: [String: Int] = [:]
    private var pendingRestarts: [UUID] = []
    private(set) var scheduler: DownloadScheduler!
    /// Names this coordinator (this profile) to the shared controllers, so a limit it sets applies to its own downloads only.
    let ownerID = UUID()
    private(set) lazy var adaptive = AdaptiveController(coordinator: self)
    /// This profile's website accounts. The engine asks its router for an Authorization header for each request it makes itself; never for a page-derived, automation, remote or private one.
    var accountStore: AccountStore? {
        didSet {
            http.engine.accounts = accountStore?.router
            accountStore?.onWithdrawn = { [weak self] host, port in self?.accountWithdrawn(host: host, port: port) }
        }
    }

    /// A credential was withdrawn (disconnected, deleted, or refused): transfers running with it are stopped now, rather than carrying on with a credential the person took away.
    func accountWithdrawn(host: String, port: Int?) {
        for (id, record) in ledger.records where record.engineMetadata["account"] == "1" && !record.state.isFinal {
            guard let url = record.source.asURL, url.host?.lowercased() == host, (url.port ?? 443) == (port ?? 443) else { continue }
            if record.state == .running || record.state == .starting || record.state == .resuming {
                if canPause(id) { pause(id) } else { cancel(id) }
                note("A download was stopped because its account was withdrawn")
            }
        }
    }

    /// A website refused the credential an account supplied: that account needs reconnecting, and nothing is retried with it.
    func accountCredentialRefused(for url: URL, code: String, origin: DownloadRequestOrigin, startedAt: Date? = nil) {
        // Only a request that carried the account's credential (the person's own) can say the credential was refused; an anonymous one from anything else says nothing about it.
        guard origin == .user, code == "http:401", let store = accountStore, case .use(let id, _) = store.router.decide(url, origin: .user) else { return }
        store.authorizationRefused(account: id, requestStarted: startedAt)
        note("An account's credentials were refused by the website; reconnect it in Settings")
    }
    private var systemObservers: [NSObjectProtocol] = []

    init(clock: SchedulerClock? = nil) {
        scheduler = DownloadScheduler(clock: clock ?? SystemSchedulerClock())
        scheduler.ownerID = ownerID
        scheduler.register(ConnectionBudget.shared)
        scheduler.register(TorrentSlots.shared)
        scheduler.register(ED2KSlots.shared)
        scheduler.slotLimit = { [weak self] in self?.maxConcurrent ?? 1 }
        // A task waiting out a retry delay gives its place back; it queues again, fairly, when the delay is over.
        scheduler.occupied = { [weak self] in guard let self else { return 0 }; return self.active.keys.filter { self.ledger.record($0)?.state != .retrying }.count }
        scheduler.onChange = { [weak self] in self?.publishQueue() }
        scheduler.onHoldChange = { [weak self] date in self?.heldUntil = date; self?.ledger.saveHold(date) }
        scheduler.onHoldExpired = { [weak self] in self?.holdEnded() }
        hookLedger()
        observeSystem()
        sha512Watch = tasksChanged.receive(on: DispatchQueue.main).sink { [weak self] in self?.verifyPendingSHA512() }
        NetworkConditions.shared.observe(self) { [weak self] _, new in self?.evaluateNetworkHold(new) }
    }

    deinit { systemObservers.forEach { NotificationCenter.default.removeObserver($0) } }

    // MARK: SHA-512 given by a Metalink document

    /// A finished download whose Metalink gave a SHA-512 (and no SHA-256): the file is hashed once, off the main thread, and the record says verified or mismatched. (Parallel sources are used only with a SHA-256,
    /// which the HTTP engine checks itself; this is the check for the rest.)
    private func verifyPendingSHA512() {
        for (id, r) in ledger.records where r.state == .completed && r.engineMetadata["sha512"] != nil && r.engineMetadata["sha512Checked"] == nil {
            ledger.update(id) { $0.engineMetadata["sha512Checked"] = "1" }
            guard let file = managedFile(of: id), let expected = r.engineMetadata["sha512"]?.lowercased() else { continue }
            Task { @MainActor [weak self] in
                let digest = await Task.detached(priority: .utility) { Self.sha512Hex(ofFileAt: file) }.value
                guard let self, self.ledger.record(id) != nil, let digest else { return }
                self.ledger.update(id) { $0.engineMetadata["sha512Computed"] = digest; $0.file.integrity = digest == expected ? .verified : .mismatch }
                self.note(digest == expected ? "\(file.lastPathComponent) matches its SHA-512" : "\(file.lastPathComponent) does NOT match the SHA-512 in its Metalink file")
            }
        }
    }

    nonisolated static func sha512Hex(ofFileAt url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA512()
        while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// What a task needs before it starts, besides a place. A download the app makes itself leases one connection; WebKit manages its own.
    func need(for protocolID: DownloadProtocolID, source: URL?) -> ResourceNeed {
        if protocolID == .ed2k { return ResourceNeed(requests: [.init(pool: ED2KSlots.poolName, amount: 1, scope: nil)]) }
        if protocolID == .bittorrent { return ResourceNeed(requests: [.init(pool: TorrentSlots.poolName, amount: 1, scope: nil)]) }
        guard protocolID == .http || protocolID == .remoteFile, let host = source?.host else { return .none }
        return ResourceNeed(requests: [.init(pool: ConnectionBudget.poolName, amount: 1, scope: host)])
    }

    private func publishQueue() {
        waiting = scheduler.ordered.enumerated().map { index, entry in
            QueuedDownload(id: entry.id, filename: entry.filename, priority: entry.priority, enqueued: entry.enqueuedAt, source: entry.source, position: index + 1,
                           isResume: entry.kind == .resume, isRetry: entry.kind == .retry)
        }
    }

    /// Where a task is in line (1 is next), or nil when it is not waiting for a place.
    func queuePosition(of id: UUID) -> Int? { scheduler.position(of: id) }

    /// One line on why a waiting download is not running yet, or nil when it is about to be.
    var queueNote: String? {
        switch scheduler.waitingReason {
        case .held: heldUntil == .distantFuture ? "The queue is paused" : "The queue is held until \(heldUntil.map { $0.formatted(date: .omitted, time: .shortened) } ?? "later")"
        case .noFreePlace: "Waiting for a free place"
        case .resourcesBusy: "Waiting for connections to free up"
        case .nothing: nil
        }
    }

    /// Called before a download's destination is chosen. Returns when it may start (true), or false when it has been put off (held for later) or cancelled while waiting.
    func admit(filename: String, source: URL?) async -> Bool { await admitTicket(filename: filename, source: source).admitted }

    private final class Flag { var value = false }

    /// The same, and the task's identity: the engine hands it back to `begin`, so the id the person's list shows is the one the task has from first request to last byte.
    func admitTicket(filename: String, source: URL?, isPrivate: Bool = false, protocolID: DownloadProtocolID = .webKit, priority: DownloadPriority? = nil, allowSchedule: Bool = true) async -> (admitted: Bool, id: UUID) {
        let id = takeReservedID(for: source) ?? UUID()
        let name = Self.safeName(filename)
        if ledger.record(id) == nil { ledger.create(id: id, protocolID: protocolID, source: source, filename: name, isPrivate: isPrivate); ledger.apply(.queued, to: id) }
        else if let state = ledger.record(id)?.state, state != .queued { ledger.apply(.queued, to: id) }
        let chosen = priority ?? ledger.record(id)?.priority ?? .normal
        if ledger.record(id)?.priority != chosen { ledger.update(id) { $0.priority = chosen } }
        if scheduler.isHeld, !allowSchedule {
            // Held, but this download cannot be started again later from its address (private, a POST, its own credentials, a place the person chose): it is not kept.
            ledger.apply(.cancelled, to: id)
            note("Not started: the queue is on hold and this download cannot be repeated later")
            return (false, id)
        }
        if scheduler.isHeld, DownloadSchedule.canSchedule(source), let source {
            let dueAt = heldUntil == .distantFuture ? nil : heldUntil
            scheduled.append(ScheduledDownload(id: id, url: source.absoluteString, filename: name, priority: chosen, dueAt: dueAt, heldByQueue: true))
            ledger.apply(.scheduled(at: dueAt), to: id)
            return (false, id)
        }
        let immediate = Flag()
        tickets.removeValue(forKey: id)?.resume(returning: false)          // an earlier caller still waiting for this id is released, not left waiting for ever
        scheduler.enqueue(id: id, kind: .start, filename: name, priority: chosen, need: need(for: protocolID, source: source), source: source, enqueuedAt: ledger.record(id)?.enqueuedAt) { [weak self] in
            guard let self else { return }
            if let ticket = self.tickets.removeValue(forKey: id) { ticket.resume(returning: true) } else { immediate.value = true }
        }
        if immediate.value {
            // A download the person just started (not one the queue, a schedule or a resume started later) is worth a small animation toward the Downloads button.
            if Date() >= flightsQuietUntil { userStarts += 1 }
            return (true, id)
        }
        let admitted = await withCheckedContinuation { tickets[id] = $0 }
        return (admitted, id)
    }

    /// The next admission of `url` is this task again (a restart keeps the task's identity).
    func reserveTaskID(_ id: UUID, for url: URL) { reservedIDs[url.absoluteString] = id }

    /// The task the next start of `url` belongs to, if one was reserved. Read-only: an engine uses it to find out which session the start must go through.
    func peekReservedID(for url: URL) -> UUID? { reservedIDs[url.absoluteString] }

    /// Set by the engine: why this task cannot be started or resumed right now because the web session it belongs to is not available (nil when it can). Never answered by
    /// borrowing another profile's page.
    var sessionGate: ((UUID?, URL?) -> String?)?

    /// A task cannot go on because its web session cannot be restored. It is marked "recovery required" with the reason, keeps whatever resume data it has, and is never
    /// retried as a plain request.
    func sessionUnavailable(_ id: UUID?, source: URL?, reason: String) {
        note(reason)
        guard let id, ledger.record(id) != nil else { return }
        if ledger.apply(.recoveryRequired(reason: reason), to: id) != nil { forgetRuntime(id); return }
        // Not a state that may move there (a task that has not started): it is closed with the reason instead of being left waiting.
        ledger.apply(.failed(DownloadFailureInfo(code: "session", reason: reason, retryable: false)), to: id, resumeData: .some(nil))
        forgetRuntime(id)
        failures.insert(DownloadFailure(id: id, filename: ledger.record(id)?.file.filename ?? "A download", source: nil, reason: reason, date: Date(), canRetry: false), at: 0)
        failures = Array(failures.prefix(DownloadFailure.limit))
    }

    private func takeReservedID(for source: URL?) -> UUID? {
        guard let key = source?.absoluteString else { return nil }
        return reservedIDs.removeValue(forKey: key)
    }

    /// The destination was chosen (or the download ended before that): the place held for it is no longer "reserved".
    private func settleReservation() { scheduler.settleReservation() }

    private func pump() { scheduler.pump() }

    func setPriority(_ id: UUID, _ priority: DownloadPriority) {
        scheduler.setPriority(id, priority)
        if ledger.record(id) != nil { ledger.update(id) { $0.priority = priority } }
        if let i = scheduled.firstIndex(where: { $0.id == id }) { scheduled[i].priority = priority }
    }

    /// Gives up on a download that has not started. A resume that is waiting for a place is only withdrawn: the download stays in the list, paused, as it was.
    func cancelWaiting(_ id: UUID) {
        let kind = scheduler.entries.first { $0.id == id }?.kind
        scheduler.remove(id)
        if kind == .resume { return }
        if kind == .retry { cancel(id); return }
        ledger.apply(.cancelled, to: id)
        tickets.removeValue(forKey: id)?.resume(returning: false)
    }

    // MARK: Pause, resume, schedule

    /// Stops every running download where it is (each keeps its place on disk) and holds the ones that are waiting.
    func pauseAll(then done: @escaping () -> Void = {}) {
        // Held first: a place freed by a download stopping must not be taken by one that was waiting.
        holdQueue(until: .distantFuture)
        suspendAll { done() }
    }

    func resumeAll() {
        holdQueue(until: nil)
        for id in Array(interrupted.keys) { resume(id) }
        startScheduledNow()
    }

    /// A timed hold ended by itself: what it put off starts. Downloads the person paused one by one stay paused, and ones scheduled for a later time of their own keep that time.
    private func holdEnded() { startScheduledNow() }

    /// Nothing new starts until this time; what arrives meanwhile is started then. nil lifts the hold.
    func holdQueue(until date: Date?) { scheduler.hold(until: date) }

    /// Starts what the queue's hold put off, and anything scheduled whose time has come, in priority order. A download scheduled for a later time of its own is left to its time.
    func startScheduledNow() {
        let now = scheduler.clock.now
        let ready = scheduled.filter { $0.heldByQueue || ($0.dueAt.map { $0 <= now } ?? true) }
        guard !ready.isEmpty else { return }
        quietFlights()
        var kept: [ScheduledDownload] = []
        for item in ready.sorted(by: { $0.priority > $1.priority }) {
            // The app's own engine needs no page open; a download made through a page does, and waits (listed) until there is one.
            if ![.http, .media, .remoteZip, .remoteFile].contains(ledger.record(item.id)?.protocolID ?? .webKit), let hasHost, !hasHost() { note("A scheduled download waits: no page is open to start it from"); kept.append(item); continue }
            scheduler.cancelTimer(item.id)
            overdue.remove(item.id)
            if !startScheduledItem(item) { kept.append(item) }          // nothing could start it yet: it stays listed, never silently dropped
        }
        let started = Set(ready.map(\.id)).subtracting(kept.map(\.id))
        scheduled.removeAll { started.contains($0.id) }
    }

    private func startScheduledItem(_ item: ScheduledDownload) -> Bool {
        guard let url = URL(string: item.url), DownloadSchedule.canSchedule(url) else { ledger.apply(.cancelled, to: item.id); return true }
        if ledger.record(item.id)?.protocolID == .http { http.restart(item.id); return true }       // the app's own engine starts it again itself
        // A stream or an archive put off by a held queue is started again from the plan saved with it, never as a plain download of its address.
        if ledger.record(item.id)?.protocolID == .media { media.restart(item.id); return true }
        if ledger.record(item.id)?.protocolID == .remoteZip { remoteZip.restart(item.id); return true }
        if ledger.record(item.id)?.protocolID == .remoteFile { remoteFiles.restart(item.id); return true }
        guard let starter else { return false }
        reservedIDs[url.absoluteString] = item.id          // the download keeps this task's identity when the engine admits it
        starter(url)
        return true
    }

    /// Starts one put-off download now (its time came, or the person asked).
    func startScheduled(_ id: UUID) {
        guard let i = scheduled.firstIndex(where: { $0.id == id }) else { return }
        if ![.http, .media, .remoteZip, .remoteFile].contains(ledger.record(id)?.protocolID ?? .webKit), let hasHost, !hasHost() {
            // Nothing to start it from yet: it stays listed and looks again shortly, instead of its one timer being spent.
            note("Could not start the scheduled download: no page is open to start it from")
            scheduler.schedule(id, due: scheduler.clock.now.addingTimeInterval(30)) { [weak self] in self?.scheduleCameDue(id) }
            return
        }
        let item = scheduled.remove(at: i)
        scheduler.cancelTimer(id)
        quietFlights()
        if startScheduledItem(item) { overdue.remove(id) } else { scheduled.insert(item, at: min(i, scheduled.count)) }
    }

    func removeScheduled(_ id: UUID) {
        scheduler.cancelTimer(id)
        scheduled.removeAll { $0.id == id }
        overdue.remove(id)
        ledger.apply(.cancelled, to: id)
    }

    /// Puts a scheduled start at a new time (replacing the old one: a task has one start time, never two).
    func reschedule(_ id: UUID, at date: Date) {
        guard let i = scheduled.firstIndex(where: { $0.id == id }) else { return }
        scheduled[i].dueAt = date
        overdue.remove(id)
        ledger.update(id) { $0.scheduledAt = date }
        armSchedule(scheduled[i])
    }

    /// A new download of `url` that starts at `date` (a past time means as soon as it can). The time is an absolute moment; it is what is saved.
    @discardableResult
    func scheduleDownload(url: URL, at date: Date, filename: String? = nil, priority: DownloadPriority = .normal, expectedSHA256: String? = nil, speedLimit: Int64? = nil, origin requested: DownloadRequestOrigin = .user, isPrivate: Bool = false) -> UUID? {
        guard DownloadSchedule.canSchedule(url) else { return nil }
        // This is for starts a person approved. Only their own typing is `.user`; anything else they approved (a link from a page, an automation proposal, a crawl result) runs as `.page`:
        // started because they said so, but held to the untrusted network rules. A caller cannot ask for more than `.user` or for anything outside these two.
        let origin: DownloadRequestOrigin = requested == .user ? .user : .page
        // The name the person typed is theirs (cleaned to a plain file name); without one, the server is asked when the download starts, and the address's last part is only a placeholder.
        let typed = filename.flatMap(DownloadFilename.sanitize)
        let name = typed ?? DownloadFilename.derive(contentDisposition: nil, url: url).name
        let record = ledger.create(protocolID: .http, source: url, filename: name, isPrivate: isPrivate, priority: priority)
        let sum = expectedSHA256.flatMap(DownloadIntegrityCheck.normalizedDigest)
        ledger.update(record.id) {
            $0.engineMetadata["origin"] = origin.rawValue; $0.scheduledAt = date
            if typed != nil { $0.engineMetadata["nameSource"] = "user" }
            if let sum { $0.engineMetadata["sha256"] = sum; $0.engineMetadata["sha256From"] = "user" }
            if let limit = BandwidthController.valid(speedLimit) { $0.engineMetadata["speedLimit"] = String(limit) }
        }
        guard ledger.apply(.scheduled(at: date), to: record.id) != nil else { ledger.remove(record.id); return nil }
        let item = ScheduledDownload(id: record.id, url: url.absoluteString, filename: name, priority: priority, dueAt: date)
        scheduled.append(item)
        armSchedule(item)
        return record.id
    }

    private func armSchedule(_ item: ScheduledDownload) {
        guard let due = item.dueAt else { return }
        scheduler.schedule(item.id, due: due) { [weak self] in self?.scheduleCameDue(item.id) }
    }

    private func scheduleCameDue(_ id: UUID) {
        // A held queue holds everything, including this; its release starts what is waiting.
        guard !scheduler.isHeld else { return }
        startScheduled(id)
    }

    /// After the app opened or the Mac woke: puts every put-off start in one of three places. Not yet due (a timer is set), due recently enough to go ahead (the person scheduled it and
    /// would expect it to have run), or too old (shown, and waits for the person). Only downloads the person scheduled are considered; nothing that crashed, failed or was cancelled.
    func restoreSchedules() {
        let now = scheduler.clock.now
        for item in scheduled {
            guard ledger.record(item.id)?.state == .scheduled else { continue }
            let recorded = DownloadRequestOrigin(rawValue: ledger.record(item.id)?.engineMetadata["origin"] ?? "user")
            let authorised = recorded == .user || recorded == .page
            guard authorised else { continue }
            switch SchedulePolicy.decide(dueAt: item.dueAt, now: now) {
            case .waitUntil: armSchedule(item)
            case .startNow where !scheduler.isHeld: startScheduled(item.id)
            case .startNow: break
            case .needsPerson: if item.dueAt != nil { overdue.insert(item.id) }
            }
        }
    }

    /// The Mac woke or its clock changed: every deadline is looked at again against the wall clock.
    func reconcileAfterWakeOrClockChange() {
        scheduler.reconcile()
        evaluateNetworkHold(networkPath())          // the connection may have changed while asleep
        restoreSchedules()
    }

    private func observeSystem() {
        #if os(macOS)
        let center = NSWorkspace.shared.notificationCenter
        systemObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcileAfterWakeOrClockChange() }
        })
        #endif
        systemObservers.append(NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcileAfterWakeOrClockChange() }
        })
    }

    // MARK: Retry

    /// A download failed. If a retry can help and it has not been tried too often, it is started again after a wait; returns whether one was planned. The wait is the one every
    /// engine uses (`DownloadRetry.delay`), and the timer is the scheduler's, one per task, so a retry cannot be started twice or outlive its task.
    @discardableResult
    func planRetry(for source: URL?, error: Error, resumeData: Data?, id: UUID, replayableByAddress: Bool = true) -> Bool {
        // A download made by a POST, or one that carried its own credentials, is never asked for again from its address alone: that would be a different request.
        guard replayableByAddress || (resumeData?.isEmpty == false), DownloadRetry.isRetryable(error), let source, DownloadSchedule.canSchedule(source) else { return false }
        let key = source.absoluteString
        let attempt = (attempts[key] ?? 0) + 1
        guard attempt <= DownloadRetry.maxAttempts else { attempts[key] = nil; return false }
        attempts[key] = attempt
        let delay = DownloadRetry.delay(afterAttempt: attempt, retryAfter: nil)
        let due = scheduler.clock.now.addingTimeInterval(delay)
        ledger.update(id) { $0.retryAt = due }
        scheduler.schedule(id, due: due, maxWait: DownloadScheduler.maxRetryWait) { [weak self] in
            guard let self else { return }
            // Cancelled while it waited: nothing restarts.
            if let state = self.ledger.record(id)?.state, state == .cancelled || state == .completed { return }
            if let resumeData, !resumeData.isEmpty, self.interrupted[id] != nil { self.resume(id) }
            else if replayableByAddress { self.reservedIDs[source.absoluteString] = id; self.starter?(source) }
            else { self.fail(id, source: source, error: error, willRetry: false, replayableByAddress: false) }   // never repeated as a plain GET
        }
        return true
    }

    func downloadSucceeded(source: URL?) { if let source { attempts[source.absoluteString] = nil } }

    private var destinations: [UUID: URL] = [:]
    /// Where a download that was just cancelled was writing. WebKit can write one more chunk, or report the failure, after the cancel has already been
    /// handled; the file it leaves is removed when that happens. Forgotten after ten seconds, or when a new download takes the same name.
    private var recentlyDiscarded: [UUID: URL] = [:]
    private var cancellers: [UUID: () -> Void] = [:]
    /// Downloads that came from a private tab: they are never listed in history, kept for resuming, or named in a notification.
    private var privateIDs = Set<UUID>()
    /// File names of private downloads in this session (memory only), so notes can leave them out.
    private var privateNames = Set<String>()
    private var privateNameOrder: [String] = []
    /// The names to keep out of diagnostics (which hold only the last 60 lines): the most recent few hundred, so a long session of private downloads cannot grow this without end.
    static let privateNameLimit = 500
    func rememberPrivateName(_ name: String) {
        guard privateNames.insert(name).inserted else { return }
        privateNameOrder.append(name)
        while privateNameOrder.count > Self.privateNameLimit { privateNames.remove(privateNameOrder.removeFirst()) }
    }
    var privateNameCount: Int { privateNames.count }
    /// Stops a download in a way that hands back its resume data, so quitting the app does not lose what was already fetched.
    private var suspenders: [UUID: (@escaping (Data?) -> Void) -> Void] = [:]

    /// A folder (inside the profile) where the task database lives, so downloads can be listed and resumed after the app was closed or quit.
    var store: URL? { didSet { attachStore() } }

    /// Opens the task database, brings the older JSON files in (once, without deleting them), and rebuilds what the lists show from the records.
    private func attachStore() {
        guard let store else { return }
        ledger = ledger.store == nil ? ledger : DownloadLedger(profile: profileName)
        ledger.authorizedRoots = { [Self.directory] + DownloadDestinationAccess.grantedRoots }
        ledger.onProblem = { [weak self] in self?.note($0) }
        _ = ledger.attach(folder: store, safeName: Self.legacySafeName)
        HTTPRecovery.reconcile(ledger)
        rebuildFromLedger()
        restoreQueueState()
        sweepSaveAsStaging()
        recoverHiddenReplacementBackups()
    }

    /// Staging folders of THIS profile left by tasks that no longer exist are deleted. Nothing is deleted unless the ledger opened properly (a damaged or newer database could look
    /// empty), and a folder whose task is alive, or known to this run, is never touched. Other profiles' folders are not looked at.
    private func sweepSaveAsStaging() {
        guard let outcome = ledger.store?.outcome, outcome == .opened || outcome == .created else { return }
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: saveAsStagingRoot, includingPropertiesForKeys: nil) else { return }
        for folder in folders {
            guard let id = UUID(uuidString: folder.lastPathComponent) else { continue }
            if let state = ledger.record(id)?.state, !state.isFinal { continue }
            if destinations[id] != nil || saveAsChoices[id] != nil { continue }
            try? fm.removeItem(at: folder)
        }
    }

    /// A replacement that was cut short after the swap but before the old content was dealt with leaves it as a hidden backup beside the new file. At start-up each one that belongs
    /// to a task this profile knows is made visible ("name (previous).ext"), so the person's old file is never lost to something they cannot see.
    private func recoverHiddenReplacementBackups() {
        let fm = FileManager.default
        for record in ledger.records.values {
            guard let path = record.engineMetadata[Self.saveAsTargetKey] else { continue }
            let target = URL(fileURLWithPath: path), folder = target.deletingLastPathComponent()
            guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names where name.hasPrefix(".\(target.lastPathComponent).replaced-") {
                let ext = (target.lastPathComponent as NSString).pathExtension, base = (target.lastPathComponent as NSString).deletingPathExtension
                let visible = FileNaming.unique(ext.isEmpty ? "\(base) (previous)" : "\(base) (previous).\(ext)", style: .parenthesized) { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
                if (try? fm.moveItem(at: folder.appendingPathComponent(name), to: folder.appendingPathComponent(visible))) != nil { note("Kept the previous \(target.lastPathComponent) as \(visible)") }
            }
        }
    }

    /// What the scheduler needs back after a relaunch, from what was saved: the hold the person set (a pause is still a pause), and the put-off starts, each decided by the same
    /// rule (see `SchedulePolicy`). Nothing is restored that the person did not ask to be started.
    private func restoreQueueState() {
        let now = scheduler.clock.now
        if let hold = ledger.loadHold() {
            if hold == .distantFuture || hold > now { scheduler.hold(until: hold) }
            else { ledger.saveHold(nil) }            // a timed hold that ended while the app was closed
        }
        // Put-off starts with no time of their own that are not under a hold were waiting in line when the app closed: the person had asked for them, and they go back in line.
        if !scheduler.isHeld {
            for item in scheduled where item.dueAt == nil && ledger.record(item.id)?.state == .scheduled { pendingRestarts.append(item.id) }
        }
        restoreSchedules()
        for id in pendingRestarts { startScheduled(id) }
        pendingRestarts = []
    }

    /// The interrupted, scheduled and failed lists are views of the records: nothing else holds them.
    private func rebuildFromLedger() {
        interrupted = [:]; scheduled = []
        var recovered: [DownloadFailure] = []
        for record in ledger.records.values.sorted(by: { ($0.queueOrder, $0.createdAt) < ($1.queueOrder, $1.createdAt) }) where !record.isPrivate {
            switch record.state {
            case .paused where record.transfer.resumeAvailable, .recoveryRequired where record.transfer.resumeAvailable:
                guard interrupted.count < 50, let resume = ledger.resumeData(for: record.id) else { continue }
                var item = InterruptedDownload(id: record.id, filename: DownloadCoordinator.safeName(record.file.filename), resumeData: resume, source: record.source.asURL)
                if record.protocolID == .http, case .recover(let kind) = DownloadRecovery.assess(record, facts: DownloadRecovery.facts(for: record, store: ledger.store, roots: [Self.directory])) { item.recovery = kind }
                interrupted[record.id] = item
            case .scheduled where DownloadURLRedactor.lostSecret(record.source.asURL):
                // A signed link kept across a relaunch has lost its secret: it is shown as needing a fresh link, never started from what is left of it.
                guard recovered.count < DownloadFailure.limit else { continue }
                recovered.append(DownloadFailure(id: record.id, filename: record.file.filename, source: record.source.asURL, reason: "This link carried a one-time token, which is not kept on disk. Copy a fresh link from the website.",
                                                 date: record.updatedAt, canRetry: false, recovery: .needsNewLink("This link carried a one-time token, which is not kept on disk. Copy a fresh link from the website.")))
            case .scheduled:
                guard scheduled.count < 200, let url = record.source.url, DownloadSchedule.canSchedule(URL(string: url)) else { continue }
                scheduled.append(ScheduledDownload(id: record.id, url: url, filename: record.file.filename, priority: record.priority, dueAt: record.scheduledAt,
                                                   heldByQueue: record.scheduledAt == nil || record.scheduledAt == ledger.loadHold()))
            case .recoveryRequired, .failed:
                // Stopped for good, or found part-way: shown with its reason, and tried again from its address if it has one.
                guard recovered.count < DownloadFailure.limit else { continue }
                var kind: DownloadRecoveryClass?
                if record.state == .recoveryRequired, case .recover(let found) = DownloadRecovery.assess(record, facts: DownloadRecovery.facts(for: record, store: ledger.store, roots: [Self.directory])) { kind = found }
                if kind == nil, DownloadURLRedactor.lostSecret(record.source.asURL) { kind = .needsNewLink("This link carried a one-time token, which is not kept on disk. Copy a fresh link from the website.") }
                recovered.append(DownloadFailure(id: record.id, filename: record.file.filename, source: record.source.asURL, reason: kind?.summary ?? record.failure?.reason ?? "It could not be downloaded.",
                                                 date: record.updatedAt, canRetry: DownloadSchedule.canSchedule(record.source.asURL) && kind?.canAct != false, recovery: kind))
            default: break
            }
        }
        failures = recovered.sorted { $0.date > $1.date }
        // Segment folders of streaming downloads this profile no longer has (a crash, a removed task) are cleaned up; the ones of tasks it still has are kept.
        MediaStore.sweep(profile: ledger.profile, keep: Set(ledger.records.values.filter { $0.protocolID == .media }.map(\.id)))
        RemoteZipStore.sweep(profile: ledger.profile, keep: Set(ledger.records.values.filter { $0.protocolID == .remoteZip }.map(\.id)))
    }

    /// Asks every running download to stop and keep its place. The result arrives through `interrupt`.
    func suspendAll(then done: @escaping () -> Void = {}) {
        let running = Array(suspenders)
        guard !running.isEmpty else { done(); return }
        var left = running.count
        for (id, suspend) in running {
            suspend { [weak self] data in
                Task { @MainActor in
                    if let data, !data.isEmpty { self?.interrupt(id, resumeData: data, source: self?.sourceURLs[id]) }
                    else if let self, self.ledger.record(id)?.state == .running, !self.http.isPastFinalisation(id) { self.fail(id, source: self.sourceURLs[id], error: DownloadCoordinator.couldNotKeepPlace, willRetry: false) }
                    left -= 1
                    if left == 0 { done() }
                }
            }
        }
    }

    /// For quitting: waits (briefly) for the downloads to hand back their place before the app goes away.
    func suspendAllBeforeQuit(timeout: TimeInterval = 1.5) {
        var finished = false
        suspendAll { finished = true }
        let end = Date().addingTimeInterval(timeout)
        while !finished, Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        ledger.flush()
    }

    /// Tests point downloads at a folder of their own, so they never touch the person's real Downloads. Nothing in the app sets this.
    static var directoryOverride: URL?

    static var directory: URL {
        if let directoryOverride { return directoryOverride }
        #if DEBUG
        // A test run (the app is its test host) that did not choose a folder must not read the person's real Downloads: macOS would ask permission for it, again for every new test build.
        if NSClassFromString("XCTestCase") != nil {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bs-test-downloads", isDirectory: true)
            try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            return scratch
        }
        #endif
        #if os(macOS)
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        #else
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
        #endif
    }

    /// Strips any path components so a hostile filename cannot escape the downloads folder.
    /// How names were cleaned before the one naming rule: kept for records written then, so an old record keeps naming the file that is on disk.
    static func legacySafeName(_ suggested: String) -> String {
        let name = (suggested as NSString).lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        return name.isEmpty ? "download" : name
    }

    static func safeName(_ suggested: String) -> String {
        // The one naming rule (both separators, control and direction-changing characters, ":", reserved names, length).
        DownloadFilename.sanitize(suggested) ?? "download"
    }

    /// The folder name a file of this kind goes into when downloads are sorted.
    static func category(forFilename name: String) -> String { DownloadCategory.folderName(forFilename: name) }

    /// Where a downloaded file is now: in the downloads folder, or in the kind-folder it was sorted into.
    static func locate(filename: String) -> URL? {
        let fm = FileManager.default
        let flat = directory.appendingPathComponent(filename)
        if fm.fileExists(atPath: flat.path) { return flat }
        let sorted = directory.appendingPathComponent(category(forFilename: filename), isDirectory: true).appendingPathComponent(filename)
        if fm.fileExists(atPath: sorted.path) { return sorted }
        // Folders from site rules, per-site or per-profile sorting: looked for up to two levels down.
        let top = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for dir in top where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let one = dir.appendingPathComponent(filename)
            if fm.fileExists(atPath: one.path) { return one }
            for inner in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            where (try? inner.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let two = inner.appendingPathComponent(filename)
                if fm.fileExists(atPath: two.path) { return two }
            }
        }
        return nil
    }

    /// A path that is free now and is not another download's destination either: a file that has not been written yet (a download in pieces is only put together at the
    /// end) does not exist, so two downloads of "invoice.pdf" used to get the same path and one deleted the other's file.
    static func uniqueURL(in dir: URL, name: String, avoiding taken: Set<URL> = []) -> URL {
        let free = FileNaming.unique(name, style: .parenthesized) { candidate in
            let url = dir.appendingPathComponent(candidate)
            return FileManager.default.fileExists(atPath: url.path) || taken.contains(url)
        }
        return dir.appendingPathComponent(free)
    }

    // MARK: Engine-facing events

    /// Starts tracking a download and returns the destination the engine must write to.
    /// The folder a download goes into: a folder the person chose for a matching rule, or the downloads folder with the profile's folder, then the rule's folder, the site, or the kind of
    /// file, in that order, then whatever folders the naming template adds. A chosen folder that cannot be opened is reported and the ordinary folder used instead.
    private func targetFolder(for name: String, sourceHost: String?, extra: [String] = [], create: Bool) -> URL {
        var folder = Self.directory
        func into(_ clean: String) {
            folder = folder.appendingPathComponent(clean, isDirectory: true)
            if create { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        }
        let rule = DownloadRouting.rule(for: name, from: sourceHost, profile: profileName, rules: rules)
        var external = false
        if let bookmark = rule?.bookmark {
            switch DownloadDestinationAccess.open(bookmark) {
            case .granted(let url): folder = url; external = true
            case .unavailable(let why): if create { note(why) }
            }
        }
        if !external, let profileFolder, let clean = DownloadRule.cleanFolder(profileFolder) { into(clean) }
        if let ruled = rule?.folder, let clean = DownloadRule.cleanFolder(ruled) { into(clean) }
        else if !external, rule == nil, organizeByDomain, let host = sourceHost, let clean = DownloadRule.cleanFolder(host) { into(clean) }
        else if !external, rule == nil, organize { into(Self.category(forFilename: name)) }
        for part in extra { if let clean = DownloadRule.cleanFolder(part) { into(clean) } }
        return folder
    }

    /// The name a file is saved under and the folders the template adds: what the site called it, run through the person's naming template.
    private func finalExpansion(_ suggestedName: String, sourceHost: String?) -> NamingTemplate.Expansion {
        NamingTemplate.expand(nameTemplate, filename: Self.safeName(suggestedName), host: sourceHost)
    }

    /// With the "skip" choice, a file already in the folder is not fetched again: returns true (and says so in the list) when this download should not go ahead.
    /// Called before the download takes a place, so it also gives back the place that was held for it.
    func skipDuplicate(suggestedName: String, sourceHost: String?, source: URL?, isPrivate: Bool, taskID: UUID? = nil) -> Bool {
        guard duplicatePolicy == .skip else { return false }
        guard duplicateExists(suggestedName: suggestedName, sourceHost: sourceHost, taskID: taskID) != nil else { return false }
        return skipBecauseDuplicate(suggestedName: suggestedName, sourceHost: sourceHost, isPrivate: isPrivate, taskID: taskID)
    }

    /// The file that would be overwritten, if there is one.
    /// The folders a package adds for this task (empty for a task in no package).
    func packageFolders(_ taskID: UUID?) -> [String] {
        guard let taskID, let path = ledger.record(taskID)?.engineMetadata["packageFolder"] else { return [] }
        return path.split(separator: "/").prefix(PackageFolderTemplate.maxParts).compactMap { PackageFolderTemplate.clean(String($0)) }
    }

    private func duplicateExists(suggestedName: String, sourceHost: String?, taskID: UUID? = nil) -> URL? {
        let x = finalExpansion(suggestedName, sourceHost: sourceHost)
        let existing = targetFolder(for: x.name, sourceHost: sourceHost, extra: packageFolders(taskID) + x.folders, create: false).appendingPathComponent(x.name)
        return FileManager.default.fileExists(atPath: existing.path) ? existing : nil
    }

    private func skipBecauseDuplicate(suggestedName: String, sourceHost: String?, isPrivate: Bool, taskID: UUID?) -> Bool {
        let name = finalExpansion(suggestedName, sourceHost: sourceHost).name
        settleReservation()
        if let taskID {
            ledger.apply(.cancelled, to: taskID)
            // A skipped task is over like any other: its place in the line and whatever connections it was leased are given back (it used to keep one until the app quit).
            forget(taskID)
        }
        note("Skipped \(name): already in the folder")
        if !isPrivate {
            failures.insert(DownloadFailure(id: UUID(), filename: name, source: nil, reason: "Already in your Downloads folder, so it was not downloaded again.", date: Date(), canRetry: false), at: 0)
            failures = Array(failures.prefix(DownloadFailure.limit))
        }
        pump()
        return true
    }

    /// A browser download ended (WebKit failed or cancelled it) while it was still waiting for a destination. The place held for it is given back and the task is closed, so
    /// no task is left "queued" for ever and the queue is not short of a slot. Nothing is written to the failure list: there was no transfer.
    func abandonAdmitted(_ id: UUID) {
        guard let state = ledger.record(id)?.state, !state.isFinal else { settleReservation(); return }
        ledger.apply(.cancelled, to: id)
        settleReservation()
    }

    /// True when the download should not go ahead. With "ask", the person is asked first: nothing is replaced or skipped without their answer, and no answer (or a dismissed dialog) keeps both.
    func askAboutDuplicate(suggestedName: String, sourceHost: String?, source: URL?, isPrivate: Bool, taskID: UUID? = nil) async -> Bool {
        guard duplicatePolicy == .ask else { return skipDuplicate(suggestedName: suggestedName, sourceHost: sourceHost, source: source, isPrivate: isPrivate, taskID: taskID) }
        guard let existing = duplicateExists(suggestedName: suggestedName, sourceHost: sourceHost, taskID: taskID) else { return false }
        switch await duplicateAsker(existing.lastPathComponent) {
        case .keepBoth: return false
        case .replace: if let taskID { replaceChosen.insert(taskID) }; return false
        case .skip: return skipBecauseDuplicate(suggestedName: suggestedName, sourceHost: sourceHost, isPrivate: isPrivate, taskID: taskID)
        }
    }

    func begin(suggestedName: String, sourceHost: String? = nil, sourceURL: URL? = nil, isPrivate: Bool = false, taskID: UUID? = nil, protocolID: DownloadProtocolID = .webKit,
               saveAs: SaveAsDestination.Choice? = nil, staged: Bool = false, cancel: @escaping () -> Void, suspend: ((@escaping (Data?) -> Void) -> Void)? = nil) -> (id: UUID, destination: URL) {
        adaptive.startIfNeeded()
        let expansion = finalExpansion(suggestedName, sourceHost: sourceHost)
        let name = expansion.name
        var folder: URL
        // A folder that, once links are followed, is not inside the downloads folder is never used (a symbolic link someone placed there must not carry a file out). It is checked
        // before anything is created, so nothing is made on the far side of such a link either.
        if !packageFolders(taskID).isEmpty, !DownloadPathPolicy.isAuthorized(targetFolder(for: name, sourceHost: sourceHost, extra: packageFolders(taskID) + expansion.folders, create: false).path, roots: managedRoots) {
            note("The package folder for \(name) was not inside the downloads folder, so it was saved in the usual place")
            folder = targetFolder(for: name, sourceHost: sourceHost, extra: expansion.folders, create: true)
        } else {
            folder = targetFolder(for: name, sourceHost: sourceHost, extra: packageFolders(taskID) + expansion.folders, create: true)
        }
        // A name another running download has already claimed (it is still being written in its hidden place) is not given out twice.
        var dest = Self.uniqueURL(in: folder, name: name, avoiding: Set(destinations.values).union(saveAsClaims.values))
        let id = taskID ?? UUID()
        var saveAs = saveAs
        // "Replace" (chosen in settings, or answered in the duplicate question) no longer moves the old file away when the download starts. The download is written to a place
        // of its own, and only a finished, checked file takes the old one's name, with the old one going to the Trash at that moment (and coming back if the move fails).
        // Whoever started the download, the old file is untouched until then, so a failed or cancelled download costs nothing.
        let replaceRequested = duplicatePolicy == .replace || (taskID.map { replaceChosen.remove($0) != nil } ?? false)
        if saveAs == nil, replaceRequested {
            let wanted = folder.appendingPathComponent(name)
            // Another download that is still writing or has just claimed this name is not a file the person agreed to replace: both are kept.
            if FileManager.default.fileExists(atPath: wanted.path), !Set(destinations.values).contains(wanted), !saveAsClaims.values.contains(wanted),
               let identity = SaveAsDestination.identity(of: wanted) {
                saveAs = SaveAsDestination.Choice(target: wanted, replaceExisting: true, expectedIdentity: identity)
            }
        }
        // A task that begins again under another policy forgets an earlier plan to replace.
        if saveAs == nil { saveAsChoices[id] = nil; saveAsClaims[id] = nil }
        // An ordinary download is kept out of sight the same way: written to a hidden place of this task alone and given its real name only when it is complete, so an unfinished file is
        // never sitting in the folder under the name of the finished one (where it could be opened, moved or mistaken for the whole file). Only where the final folder is on the same
        // volume as the staging place, so that publishing is one rename; anywhere else it is written in place, as before.
        if saveAs == nil, staged, Self.isOnSameVolume(folder, as: Self.directory) {
            saveAs = SaveAsDestination.Choice(target: dest, replaceExisting: false)
        }
        if let saveAs {
            // Save As: WebKit writes to a place that belongs to this task alone, and the finished file is moved to the chosen place only after it has been checked (see
            // `placeSaveAs`). The person's existing file is never touched while the transfer runs, fails or is cancelled. Two tasks never claim the same place.
            let staging = saveAsStagingRoot.appendingPathComponent(id.uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            dest = staging.appendingPathComponent(DownloadFilename.sanitize(saveAs.target.lastPathComponent) ?? "download")
            var choice = saveAs
            let claimed = Set(saveAsClaims.filter { $0.key != id }.values)
            if claimed.contains(choice.target) {
                choice = SaveAsDestination.Choice(target: Self.uniqueURL(in: choice.target.deletingLastPathComponent(), name: choice.target.lastPathComponent, avoiding: claimed), replaceExisting: false)
            }
            saveAsClaims[id] = choice.target
            saveAsChoices[id] = choice
        }
        if let sourceURL { sourceURLs[id] = sourceURL }
        destinations[id] = dest
        recentlyDiscarded = recentlyDiscarded.filter { $0.value != dest }   // a late cleanup of an old download must never touch this one's file
        cancellers[id] = cancel
        if isPrivate { privateIDs.insert(id); rememberPrivateName(dest.lastPathComponent) }
        if let suspend { suspenders[id] = suspend }
        active[id] = ActiveDownload(id: id, filename: dest.lastPathComponent, fraction: 0)
        // Only now is the place counted as running, so it is never counted as neither promised nor running (which would let the next in line start past the limit).
        settleReservation()
        if ledger.record(id) == nil { ledger.create(id: id, protocolID: protocolID, source: sourceURL, filename: dest.lastPathComponent, isPrivate: isPrivate); ledger.apply(.queued, to: id) }
        let kept = saveAsChoices[id]
        ledger.update(id) { $0.protocolID = protocolID; $0.isPrivate = isPrivate; $0.file.filename = dest.lastPathComponent; $0.file.destinationPath = dest.path
            // Where a Save As will finally go is kept with the task (a path and a yes/no), so it survives a relaunch; nothing from the session is.
            if let kept { $0.engineMetadata[Self.saveAsTargetKey] = kept.target.path; $0.engineMetadata[Self.saveAsReplaceKey] = kept.replaceExisting ? "1" : "0"; $0.engineMetadata["saveAsIdentity"] = kept.expectedIdentity }
            else { $0.engineMetadata[Self.saveAsTargetKey] = nil; $0.engineMetadata[Self.saveAsReplaceKey] = nil; $0.engineMetadata["saveAsIdentity"] = nil }
            if let sourceURL { $0.source = DownloadSourceRef(url: sourceURL) } }
        ledger.apply(.started, to: id)
        ledger.apply(.running, to: id)
        note(isPrivate ? "Started a private download" : "Started \(dest.lastPathComponent)\(sourceHost.map { " from \($0)" } ?? "")")          // diagnostics are copied into bug reports: a private download is not named in them
        return (id, dest)
    }

    func update(_ id: UUID, fraction: Double) {
        active[id]?.fraction = fraction
    }

    /// Progress with byte counts: keeps a smoothed speed and warns once if the disk cannot hold the file.
    func update(_ id: UUID, fraction: Double, completed: Int64, total: Int64) {
        guard var d = active[id] else { return }
        let now = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        // WebKit reports progress for every chunk, many times a second. Redrawing the panel, the toast and the Dock for each one keeps the main thread
        // busy for nothing, so the numbers are published four times a second at most.
        let dt = uptime - d.lastSampleUptime
        guard dt >= 0.25 || fraction >= 1 else { return }
        let instant = Double(max(0, completed - d.lastBytes)) / max(dt, 0.001)
        d.bytesPerSecond = d.bytesPerSecond == 0 ? instant : d.bytesPerSecond * 0.7 + instant * 0.3
        d.lastSample = now
        d.lastSampleUptime = uptime
        d.lastBytes = completed
        d.fraction = fraction
        d.completedBytes = completed
        d.totalBytes = max(0, total)
        // The free space is looked at once, when the size is first known.
        if !d.warnedDisk, total > 0 {
            d.warnedDisk = true
            if let free = DiskSpace.available(at: Self.directory), DiskSpace.isTight(needed: total - completed, available: free) {
                note("Low disk space for \(d.filename): needs \(DownloadStats.bytes(total)), \(DownloadStats.bytes(free)) free")
                onLowDisk?(d.filename, total, free)
            }
        }
        active[id] = d
        ledger.progress(id, completed: completed, total: total > 0 ? total : nil)
    }

    func note(_ line: String) {
        // Notes end up in diagnostics that are pasted into bug reports: the name of a private download is never in them, whichever code wrote the note.
        var line = line
        for name in privateNames where line.contains(name) { line = line.replacingOccurrences(of: name, with: "a private download") }
        events.append("\(ISO8601DateFormatter().string(from: Date())) \(line)")
        if events.count > 60 { events.removeFirst(events.count - 60) }
    }

    /// Plain-text summary a person can paste into a bug report. Holds file names and sites, no page content.
    var diagnostics: String {
        var lines = ["Browser Setu download diagnostics", "Folder: \(Self.directory.path)"]
        if let free = DiskSpace.available(at: Self.directory) { lines.append("Free space: \(DownloadStats.bytes(free))") }
        lines.append("Active: \(active.count), waiting: \(waiting.count), scheduled: \(scheduled.count), interrupted: \(interrupted.count)")
        lines.append("Concurrent limit: \(maxConcurrent)")
        for d in active.values { lines.append(privateIDs.contains(d.id) ? "• a private download \(Int(d.fraction * 100))%" : "• \(d.filename) \(Int(d.fraction * 100))% \(d.detail)") }
        lines.append("Recent events:")
        lines.append(contentsOf: events.suffix(40).map { "  " + $0 })
        return lines.joined(separator: "\n")
    }

    func finish(_ id: UUID, source: URL?, integrity known: DownloadIntegrity? = nil) {
        if let dest = destinations[id] {
            // Complete exactly once: a second report for the same task finds it already finished and does nothing.
            guard ledger.apply(.verifying, to: id) != nil else { forget(id); return }
            let record = ledger.record(id)
            var integrity = known ?? DownloadIntegrity.unknown
            if known == nil, let total = record?.transfer.totalBytes, total > 0, let size = (try? FileManager.default.attributesOfItem(atPath: dest.path))?[.size] as? Int64 {
                integrity = size == total ? .verified : .mismatch
                if integrity == .mismatch { note(privateIDs.contains(id) ? "A private download is \(size) bytes; the site said \(total)" : "\(dest.lastPathComponent) is \(size) bytes; the site said \(total)") }
            }
            // A Save As is moved to the place the person chose only now, after the transfer finished and was checked; until here their own file was never touched.
            // A file that came out the wrong size never takes the place of a good one: both are kept.
            let final = saveAsChoice(for: id).map { choice -> URL in
                var c = choice
                if integrity == .mismatch { c.replaceExisting = false }
                return placeSaveAs(id, staged: dest, choice: c)
            } ?? dest
            ledger.apply(.completed(integrity), to: id, resumeData: .some(nil))
            // The size the finished file really has, for a record that never learned it from the server (a page's download often arrives without a length).
            if ledger.record(id)?.transfer.totalBytes == nil, let size = (try? FileManager.default.attributesOfItem(atPath: final.path))?[.size] as? Int64, size > 0 {
                ledger.update(id) { $0.transfer.totalBytes = size; $0.transfer.completedBytes = size }
            }
            completed.insert(final, at: 0)
            note(privateIDs.contains(id) ? "Finished a private download" : "Finished \(final.lastPathComponent)")
            onFinished?(source, final.lastPathComponent, privateIDs.contains(id))
        }
        forget(id)
    }

    // MARK: Files this app made from other downloads

    /// Records a finished file this app produced from other downloads (joined, converted, sound taken out) as one completed download, so the history, the Downloads window and the Finder actions agree
    /// with the disk. Returns nil, recording nothing, when there is no regular file there. A private download's record is never written to disk.
    @discardableResult
    func recordProducedFile(_ file: URL, source: URL?, isPrivate: Bool) -> UUID? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: file.path), (attrs[.type] as? FileAttributeType) == .typeRegular else { return nil }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let id = ledger.create(protocolID: "processed", source: source, filename: file.lastPathComponent, isPrivate: isPrivate).id
        for event in [DownloadEvent.queued, .started, .running, .verifying] {
            guard ledger.apply(event, to: id) != nil else { ledger.remove(id); return nil }
        }
        ledger.update(id) { $0.file.destinationPath = file.path; $0.transfer.totalBytes = size; $0.transfer.completedBytes = size }
        guard ledger.apply(.completed(.verified), to: id, resumeData: .some(nil)) != nil else { ledger.remove(id); return nil }
        if isPrivate { privateIDs.insert(id); rememberPrivateName(file.lastPathComponent) }
        completed.insert(file, at: 0)
        return id
    }

    /// Takes the records of finished downloads off the list once their files were removed on purpose (the halves of a join, the source of a conversion), so nothing shows a deleted file as an
    /// accessible completed download. Only a record that is completed, whose file is really gone, is removed; anything else (still running, or a file that is still there) is left alone.
    func retireRecords(_ ids: [UUID]) {
        for id in ids {
            guard let r = ledger.record(id), r.state == .completed else { continue }
            if let p = r.file.destinationPath, FileManager.default.fileExists(atPath: p) { continue }
            ledger.remove(id)
            privateIDs.remove(id)
            // The recent-files list and the private-name bookkeeping must not keep naming a file that is gone.
            if let p = r.file.destinationPath { completed.removeAll { $0.path == p }; privateNames.remove(URL(fileURLWithPath: p).lastPathComponent) }
        }
    }

    /// True when both places are on one volume, so a file is published by renaming it (all at once) rather than by copying it.
    static func isOnSameVolume(_ a: URL, as b: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.volumeIdentifierKey]
        guard let x = (try? a.resourceValues(forKeys: keys))?.volumeIdentifier as? NSObject,
              let y = (try? b.resourceValues(forKeys: keys))?.volumeIdentifier as? NSObject else { return false }
        return x.isEqual(y)
    }

    static let saveAsTargetKey = "saveAsTarget"
    static let saveAsReplaceKey = "saveAsReplace"
    /// The task-owned staging folders of Save As downloads. Hidden, inside the app's own Downloads folder (so a resume is always authorized there).
    static var saveAsRoot: URL { directory.appendingPathComponent(".Browser Setu Save As", isDirectory: true) }
    /// Each profile stages in a folder of its own, so one profile's start-up clean-up can never touch another profile's unfinished downloads.
    var saveAsStagingRoot: URL { Self.saveAsRoot.appendingPathComponent(String(Data(profileName.utf8).sha256Hex.prefix(8)), isDirectory: true) }
    /// A file inside <root>/<profile>/<task>/: the only kind of place this ever moves a file out of, or deletes.
    static func isStagedFile(_ url: URL) -> Bool { url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() == saveAsRoot }
    private var saveAsClaims: [UUID: URL] = [:]
    private var saveAsChoices: [UUID: SaveAsDestination.Choice] = [:]

    private func saveAsChoice(for id: UUID) -> SaveAsDestination.Choice? {
        if let kept = saveAsChoices[id] { return kept }
        guard let meta = ledger.record(id)?.engineMetadata, let path = meta[Self.saveAsTargetKey] else { return nil }
        return SaveAsDestination.Choice(target: URL(fileURLWithPath: path), replaceExisting: meta[Self.saveAsReplaceKey] == "1", expectedIdentity: meta["saveAsIdentity"])
    }

    /// Puts the finished file where the person chose. If that cannot be done (the folder is gone or no longer writable, which is usual after a relaunch because the permission to write
    /// there ended with the app), the file is NOT sent anywhere unannounced: it is moved to the visible Downloads folder, the reason is recorded on the task and shown in the failure list.
    private func placeSaveAs(_ id: UUID, staged: URL, choice: SaveAsDestination.Choice) -> URL {
        // Only a file in a task-owned staging folder is ever moved, and only such a folder is ever removed. A download that was resumed or restarted under another policy wrote
        // straight to its final place: there is nothing to place, and nothing to delete.
        guard Self.isStagedFile(staged) else { return staged }
        let stagingFolder = staged.deletingLastPathComponent()
        func cleanUp() { try? FileManager.default.removeItem(at: stagingFolder) }
        switch SaveAsDestination.place(staged: staged, choice: choice) {
        case .placed(let url):
            ledger.update(id) { $0.file.destinationPath = url.path; $0.file.filename = url.lastPathComponent; $0.engineMetadata["saveAsPlacement"] = "placed" }
            cleanUp()
            return url
        case .placedKeepingOld(let url, let old):
            ledger.update(id) { $0.file.destinationPath = url.path; $0.file.filename = url.lastPathComponent; $0.engineMetadata["saveAsPlacement"] = "placed-kept-old" }
            note("The Trash could not be used, so the previous \(url.lastPathComponent) was kept as \(old.lastPathComponent)")
            cleanUp()
            return url
        case .keptBoth(let url):
            ledger.update(id) { $0.file.destinationPath = url.path; $0.file.filename = url.lastPathComponent; $0.engineMetadata["saveAsPlacement"] = "keptBoth" }
            note("\(choice.target.lastPathComponent) already existed, so the new file was saved as \(url.lastPathComponent)")
            cleanUp()
            return url
        case .failed(let why):
            let fallback = Self.uniqueURL(in: Self.directory, name: staged.lastPathComponent, avoiding: Set(destinations.values))
            let moved = (try? FileManager.default.moveItem(at: staged, to: fallback)) != nil
            // The staging folder is removed only if the file really left it. If the move to Downloads failed too, the finished file stays where it is, never deleted.
            let kept = moved ? fallback : staged
            if moved { cleanUp() }
            ledger.update(id) { $0.file.destinationPath = kept.path; $0.file.filename = kept.lastPathComponent; $0.engineMetadata["saveAsPlacement"] = moved ? "failed" : "failed-kept-in-staging" }
            let reason = moved ? "It could not be saved to \(choice.target.deletingLastPathComponent().lastPathComponent) (\(why)). It is in your Downloads folder instead."
                               : "It could not be saved to \(choice.target.deletingLastPathComponent().lastPathComponent) or to Downloads (\(why)). The finished file was kept in the app's own folder: \(kept.path)"
            note("\(kept.lastPathComponent): \(reason)")
            failures.insert(DownloadFailure(id: UUID(), filename: kept.lastPathComponent, source: nil, reason: reason, date: Date(), canRetry: false), at: 0)
            failures = Array(failures.prefix(DownloadFailure.limit))
            return kept
        }
    }

    /// Failed or cancelled: the partial file is removed.
    func discard(_ id: UUID, event: DownloadEvent? = .cancelled) {
        if let event, let state = ledger.record(id)?.state, !state.isFinal, state != .failed { ledger.apply(event, to: id, resumeData: .some(nil)) }
        let known = destinations[id]
        if let dest = known ?? recentlyDiscarded[id] {
            try? FileManager.default.removeItem(at: dest)
            // A Save As download's own staging folder goes with it. Only that folder: the person's chosen place was never written.
            if Self.isStagedFile(dest) { try? FileManager.default.removeItem(at: dest.deletingLastPathComponent()) }
        }
        if let known {
            recentlyDiscarded[id] = known
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(10))
                self?.recentlyDiscarded[id] = nil
            }
        }
        forget(id)
    }

    /// Stopped part-way with a way to carry on: kept in the list, with a Resume button, instead of being thrown away.
    func interrupt(_ id: UUID, resumeData: Data, source: URL?) {
        // A private download that stops part-way is dropped, not kept in a list on disk with its address.
        if let dest = destinations[id], !privateIDs.contains(id) {
            ledger.update(id) { $0.file.destinationPath = dest.path; if let source { $0.source = DownloadSourceRef(url: source) } }
            if ledger.apply(.paused(resumeAvailable: true), to: id, resumeData: .some(resumeData)) != nil {
                interrupted[id] = InterruptedDownload(id: id, filename: dest.lastPathComponent, resumeData: resumeData, source: source ?? sourceURLs[id])
            }
        } else if ledger.record(id) != nil { discard(id) }
        forgetRuntime(id)
    }

    func resume(_ id: UUID) {
        guard let item = interrupted[id] else { return }
        // A WebKit download goes on only through a page of the session it came from. Checked before anything is changed, so its resume data and its place in the list are kept.
        if ledger.record(id)?.protocolID == .webKit, let reason = sessionGate?(id, item.source) {
            note("Could not resume \(item.filename): \(reason)")
            if let state = ledger.record(id)?.state, state != .recoveryRequired { ledger.apply(.recoveryRequired(reason: reason), to: id) }
            return
        }
        // With no page to start it from the download stays where it is, with its Resume button, instead of being taken off the list and lost.
        // The app's own engine needs no page; only a download that WebKit made does.
        if ledger.record(id)?.protocolID != .http, ledger.record(id)?.protocolID != .bittorrent, ledger.record(id)?.protocolID != .ed2k, ledger.record(id)?.protocolID != .media, ledger.record(id)?.protocolID != .remoteZip, ledger.record(id)?.protocolID != .remoteFile, let hasHost, !hasHost() { note("Could not resume \(item.filename): no page is open to resume it from"); return }
        guard let record = ledger.record(id), record.transfer.resumeAvailable, DownloadStateMachine.canApply(.resumeRequested, to: record.state) else {
            note("Could not resume \(item.filename): it is not in a state that can be resumed"); return
        }
        // A resume is a start like any other: it takes a place in line, so the limit on downloads at once holds. (Asked twice, it is still one place.)
        guard !scheduler.contains(id) else { return }
        scheduler.enqueue(id: id, kind: .resume, filename: item.filename, priority: record.priority, need: need(for: record.protocolID, source: item.source), source: item.source,
                          enqueuedAt: scheduler.clock.now) { [weak self] in self?.startResume(id) }
    }

    /// The resume has its place: from here it is what it always was.
    private func startResume(_ id: UUID) {
        guard let item = interrupted[id] else { scheduler.release(task: id); return }
        // The task keeps its id. It must be allowed to resume (a paused one with its place kept); anything else is refused and left in the list.
        guard ledger.apply(.resumeRequested, to: id, resumeData: .some(nil)) != nil else { scheduler.release(task: id); note("Could not resume \(item.filename): it is not in a state that can be resumed"); return }
        quietFlights()
        interrupted[id] = nil
        // The resumed download writes where the first did, and reports under the same id.
        let record = ledger.record(id)
        if let path = record?.file.destinationPath, DownloadPathPolicy.isAuthorized(path, roots: [Self.directory]) { destinations[id] = URL(fileURLWithPath: path) }
        else { destinations[id] = Self.directory.appendingPathComponent(item.filename) }
        sourceURLs[id] = item.source
        active[id] = ActiveDownload(id: id, filename: item.filename, fraction: Double(record?.transfer.completedBytes ?? 0) / Double(max(1, record?.transfer.totalBytes ?? 1)),
                                    completedBytes: record?.transfer.completedBytes ?? 0, totalBytes: record?.transfer.totalBytes ?? 0)
        if record?.protocolID == .ed2k {
            cancellers[id] = { [weak self] in self?.ed2k.cancel(id) }
            suspenders[id] = { [weak self] done in self?.ed2k.pause(id, done: done) }
            ed2k.resume(id)
            return
        }
        if record?.protocolID == .remoteFile {
            cancellers[id] = { [weak self] in self?.remoteFiles.cancel(id) }
            suspenders[id] = { [weak self] done in self?.remoteFiles.pause(id, done: done) }
            remoteFiles.resume(id)
            return
        }
        if record?.protocolID == .remoteZip {
            cancellers[id] = { [weak self] in self?.remoteZip.cancel(id) }
            suspenders[id] = { [weak self] done in self?.remoteZip.pause(id, done: done) }
            remoteZip.resume(id)
            return
        }
        if record?.protocolID == .media {
            cancellers[id] = { [weak self] in self?.media.cancel(id) }
            suspenders[id] = { [weak self] done in self?.media.pause(id, done: done) }
            media.resume(id)
            return
        }
        if record?.protocolID == .bittorrent {
            cancellers[id] = { [weak self] in self?.torrents.cancel(id) }
            suspenders[id] = { [weak self] done in self?.torrents.pause(id, done: done) }
            torrents.resume(id)
            return
        }
        if record?.protocolID == .http {
            cancellers[id] = { [weak self] in self?.http.cancelFromCoordinator(id) }
            suspenders[id] = { [weak self] done in self?.http.pauseTransferPublic(id, done: done) }       // so it can be paused again
            http.resume(id, data: item.resumeData)
            return
        }
        if let resumerWithID { resumerWithID(item.resumeData, id) } else { resumer?(item.resumeData) }
        if resumerWithID == nil { ledger.apply(.resumed, to: id) }
    }

    /// The engine has the resumed download going again, under the task's own id; this gives it back its handles.
    func reattach(_ id: UUID, cancel: @escaping () -> Void, suspend: ((@escaping (Data?) -> Void) -> Void)? = nil) {
        cancellers[id] = cancel
        if let suspend { suspenders[id] = suspend }
        ledger.apply(.resumed, to: id)
    }

    /// Where a task's file is being written, for an engine that is told about a download it already has (a resumed one).
    func destination(of id: UUID?) -> URL? { id.flatMap { destinations[$0] } }

    func dismissInterrupted(_ id: UUID) {
        if ledger.record(id)?.protocolID == .ed2k { ed2k.cancel(id) }
        if ledger.record(id)?.protocolID == .media { media.cancel(id) }          // its fetched segments go with it
        if ledger.record(id)?.protocolID == .remoteZip { remoteZip.cancel(id) }
        if ledger.record(id)?.protocolID == .remoteFile { remoteFiles.cancel(id) }
        if ledger.record(id)?.protocolID == .bittorrent { torrents.cancel(id) }          // its working folder and checked pieces go with it
        interrupted[id] = nil
        ledger.apply(.cancelled, to: id, resumeData: .some(nil))
        ledger.remove(id)
    }

    /// Forgets what is only needed while a download runs; the record stays.
    private func forgetRuntime(_ id: UUID) {
        BandwidthController.shared.discard(task: id)          // its limit is saved with the task and applied again if it runs again
        scheduler.release(task: id)          // whatever it leased (connections), given back once, however it ended
        active[id] = nil
        destinations[id] = nil
        cancellers[id] = nil
        suspenders[id] = nil
        sourceURLs[id] = nil
        privateIDs.remove(id)
        pump()
    }

    private func forget(_ id: UUID) {
        scheduler.release(task: id)
        // A pending retry or scheduled start of a task that is over must not fire; one that is waiting to try again (state `retrying`) is exactly what the timer is for.
        if ledger.record(id)?.state != .retrying {
            scheduler.cancelTimer(id)
            // A task that is over must not still be waiting in line: it would be given a place and its connections later, with nothing to use or give them back.
            scheduler.remove(id)
        }
        saveAsClaims[id] = nil
        saveAsChoices[id] = nil
        active[id] = nil
        destinations[id] = nil
        cancellers[id] = nil
        suspenders[id] = nil
        sourceURLs[id] = nil
        privateIDs.remove(id)
        pump()
    }

    /// Cancels one download; the partial file is removed.
    func cancel(_ id: UUID) {
        if let record = ledger.record(id) {
            // A finished download is never cancelled: its file is the person's, and nothing here may delete it.
            if record.state == .completed { note("\(record.file.filename) had already finished, so it was kept"); return }
            // One whose file is already being put in place cannot be cancelled either: it completes, and is not reported cancelled.
            if record.state == .verifying || p2pIsFinishing(id) || (record.protocolID == .http && !http.requestCancel(id)) {
                note("\(record.file.filename) finished before it could be cancelled, so it was kept")
                return
            }
        }
        // The record says "cancelled" first, so what the engine reports as it stops cannot turn it into a failure or restart it.
        ledger.apply(.cancelled, to: id, resumeData: .some(nil))
        cancellers[id]?()
        discard(id)
    }

    func clearCompleted() { completed = [] }

    /// Cancels every in-flight download; each engine's cancel hook reports back through `discard`.
    func cancelAll() {
        for (id, cancel) in cancellers {
            cancel()
            discard(id)
        }
    }
}


// MARK: - Failures, pausing one download, naming, and leftover pieces

enum DuplicatePolicy: String, CaseIterable, Identifiable {
    case keepBoth, ask, replace, skip
    var id: String { rawValue }
    var title: String {
        switch self {
        case .keepBoth: "Keep both (add a number)"
        case .ask: "Ask me each time"
        case .replace: "Replace (the old one goes to the Trash)"
        case .skip: "Skip (do not download it again)"
        }
    }
}

/// A download that stopped for good, and why.
struct DownloadFailure: Identifiable, Equatable {
    static let limit = 30
    let id: UUID
    var filename: String
    var source: URL?
    var reason: String
    var date: Date
    /// Whether "Try Again" can start it from its address.
    var canRetry: Bool
    /// For a download found part-way: what can be done about it. Nil for one that failed for another reason.
    var recovery: DownloadRecoveryClass?
}

extension DownloadCoordinator {
    /// A download that was asked to stop and keep its place, and had nothing to hand back.
    static let couldNotKeepPlace = NSError(domain: "BrowserSetu.Downloads", code: 1)

    /// What went wrong, in words a person can act on.
    static func reason(for error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed: return "The connection was lost."
            case NSURLErrorTimedOut: return "The server took too long to answer."
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return "The website could not be found."
            case NSURLErrorCannotConnectToHost: return "The website did not accept the connection."
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot: return "The connection to the website was not secure."
            case NSURLErrorUserAuthenticationRequired, NSURLErrorUserCancelledAuthentication: return "The website asked you to sign in."
            case NSURLErrorFileDoesNotExist, NSURLErrorResourceUnavailable: return "The file is no longer there."
            case NSURLErrorCancelled: return "It was cancelled."
            default: break
            }
        }
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileWriteOutOfSpaceError: return "There is not enough space on the disk."
            case NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError: return "Browser Setu is not allowed to save there."
            default: break
            }
        }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOSPC) { return "There is not enough space on the disk." }
        if let http = error as? HTTPDownloadError { return http.info.reason }
        if ns.domain == "BrowserSetu.Downloads", ns.code == 1 { return "It could not keep its place when stopped, so it was ended." }
        if let piece = error as? PieceDownloadError {
            switch piece {
            case .refused: return "The site would not send the file in pieces."
            case .wrongSize: return "The pieces did not add up to the right size."
            case .failed: return "The pieces could not be put together."
            }
        }
        return "It could not be downloaded."
    }

    /// A download ended with an error and will not be tried again: it is dropped, its partial file removed, and the reason kept where the person can see it. A download from a
    /// private tab leaves no record. `willRetry` means a new attempt is already planned, so nothing is reported yet.
    func fail(_ id: UUID?, filename: String? = nil, source: URL?, error: Error, willRetry: Bool, isPrivate: Bool = false, replayableByAddress: Bool = true) {
        let name = filename ?? id.flatMap { destinations[$0]?.lastPathComponent } ?? source?.lastPathComponent ?? "A download"
        let private_ = isPrivate || (id.map { privateIDs.contains($0) } ?? false)
        // What an engine reports as it stops after the person cancelled is not a failure.
        if let id, ledger.record(id)?.state == .cancelled, (error as NSError).code == NSURLErrorCancelled { discard(id, event: nil); return }
        if let id {
            // An HTTP failure already says what it is (its status, its reason); a bridged NSError code would only hide that.
            let info = (error as? HTTPDownloadError)?.info
                ?? DownloadFailureInfo(code: "\((error as NSError).domain):\((error as NSError).code)", reason: Self.reason(for: error), retryable: willRetry || DownloadRetry.isRetryable(error))
            if willRetry { ledger.apply(.retryPlanned, to: id) } else { ledger.apply(.failed(info), to: id, resumeData: .some(nil)) }
            discard(id, event: nil)
        }
        note("Failed \(private_ ? "a download" : name): \(Self.reason(for: error))")
        guard !willRetry, !private_ else { return }
        let reason = Self.reason(for: error)
        failures.insert(DownloadFailure(id: id ?? UUID(), filename: name, source: source, reason: reason, date: Date(), canRetry: replayableByAddress && (source.map { DownloadSchedule.canSchedule($0) } ?? false)), at: 0)
        failures = Array(failures.prefix(DownloadFailure.limit))
    }

    /// The pieces of a download went wrong: the same address is fetched again the ordinary way, once.
    func fallBackToPlainDownload(_ source: URL, newTaskID: UUID? = nil) {
        noPieces.insert(source.absoluteString)
        // The new attempt is a task of its own, with an identity the engine already tied to the right session, so it is never started by guessing from the address.
        if let newTaskID { reservedIDs[source.absoluteString] = newTaskID }
        note("Pieces failed for \(source.lastPathComponent); fetching it the normal way")
        if let hasHost, !hasHost() { fail(nil, source: source, error: PieceDownloadError.refused, willRetry: false); return }
        quietFlights()
        starter?(source)
    }

    func dismissFailure(_ id: UUID) {
        discardWorkingData(of: id)
        failures.removeAll { $0.id == id }; ledger.remove(id); mirrors.forget(task: id)
    }
    func clearFailures() {
        for failure in failures { discardWorkingData(of: failure.id); ledger.remove(failure.id) }
        failures = []
    }
    /// A failed download that is dismissed takes what it left on disk with it: fetched media segments, a torrent's working folder and checked pieces, an ED2K part file, a multipart HTTP file.
    /// (Without this the record is gone and nothing in the app can find the hidden data again.)
    private func discardWorkingData(of id: UUID) {
        switch ledger.record(id)?.protocolID {
        case .media: media.cancel(id)          // the segments a retryable failure kept can be large
        case .remoteZip: remoteZip.cancel(id)
        case .remoteFile: remoteFiles.cancel(id)
        case .bittorrent: torrents.cancel(id)
        case .ed2k: ed2k.cancel(id)
        case .http: http.cancelFromCoordinator(id)
        default: break
        }
    }
    /// scheme://host[:port] of an address, for the quarantine mark (never the path or a token).
    static func originOnly(of text: String?) -> String { text.flatMap(URL.init(string:)).map { HTTPRequestPolicy.origin(of: $0) } ?? "" }

    func retryFailure(_ id: UUID) {
        guard let failure = failures.first(where: { $0.id == id }), let source = failure.source, failure.canRetry else { return }
        let own = ledger.record(id)?.protocolID == .http
        if ledger.record(id)?.protocolID == .media { failures.removeAll { $0.id == id }; quietFlights(); media.restart(id); return }
        if ledger.record(id)?.protocolID == .remoteZip { failures.removeAll { $0.id == id }; quietFlights(); remoteZip.restart(id); return }
        if ledger.record(id)?.protocolID == .remoteFile { failures.removeAll { $0.id == id }; quietFlights(); remoteFiles.restart(id); return }
        if !own, let hasHost, !hasHost() { note("Could not retry \(failure.filename): no page is open to start it from"); return }
        failures.removeAll { $0.id == id }
        quietFlights()
        // The app's own engine starts the same task again by itself, with no page; the others go back through the page that makes them.
        if own { http.restart(id); return }
        if ledger.record(id) != nil { reservedIDs[source.absoluteString] = id }      // tried again as the same task
        starter?(source)
    }

    /// Stops one download and keeps what was fetched, so it can be resumed from the list. Only downloads the engine can hand back resume data for: the ones fetched in pieces cannot.
    func pause(_ id: UUID) {
        guard canPause(id), let suspend = suspenders[id], ledger.apply(.pauseRequested, to: id) != nil else { return }
        suspend { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty { self.interrupt(id, resumeData: data, source: self.sourceURLs[id]) }
                else {
                    // Nothing came back to resume from and the download has stopped: that is said, not silently dropped. (Unless the answer is that it finished: no failure then.)
                    if self.http.isPastFinalisation(id) || self.p2pIsFinishing(id) { return }
                    self.fail(id, source: self.sourceURLs[id], error: DownloadCoordinator.couldNotKeepPlace, willRetry: false)
                }
            }
        }
    }

    /// A control is offered only when the task's engine can do it and has the means right now.
    func canPause(_ id: UUID) -> Bool {
        guard suspenders[id] != nil, engines.can(.pause, ledger.record(id)?.protocolID ?? .webKit), ledger.record(id)?.state == .running else { return false }
        if p2pIsFinishing(id) { return false }                      // its files are being put in place: too late to pause, as for an HTTP download
        return ledger.record(id)?.protocolID == .http ? http.canPause(id) : true
    }

    /// A peer-to-peer download whose finished files are being moved into place. Pausing or cancelling now would act on files that are no longer where the task thinks.
    func p2pIsFinishing(_ id: UUID) -> Bool { (ed2kStarted && ed2k.isFinishing(id)) || (mediaStarted && media.isFinishing(id)) || (remoteZipStarted && remoteZip.isFinishing(id)) || (remoteFilesStarted && remoteFiles.isFinishing(id)) || (torrentsStarted && torrents.isFinishing(id)) }

    /// Where a finished file was actually put (it is renamed if its name was taken in the meantime).
    func updateDestination(_ id: UUID, to url: URL) {
        guard DownloadPathPolicy.isAuthorized(url.path, roots: [Self.directory]) else { note("A transfer reported a location outside the downloads folder; it was ignored"); return }
        destinations[id] = url
        ledger.update(id) { $0.file.destinationPath = url.path; $0.file.filename = url.lastPathComponent }
        active[id]?.filename = url.lastPathComponent
    }

    // MARK: Naming

    static let templateTokens = ["{name}", "{host}", "{date}", "{time}"]

    /// Nil when the template is fine; otherwise why not. See `NamingTemplate` for what a template may hold.
    static func templateProblem(_ template: String) -> String? { NamingTemplate.problem(template) }

    /// A file name made from the template (its folders, if it has any, are `NamingTemplate.expand`'s business). An invalid template leaves the name as the site gave it.
    static func applyTemplate(_ template: String, to filename: String, host: String?, now: Date = Date()) -> String {
        NamingTemplate.expand(template, filename: safeName(filename), host: host, now: now).name
    }

    // MARK: Leftovers

    /// A multi-piece download that was cut off by the app being killed leaves a hidden folder of pieces. Ones nobody has touched for a day are removed. Looks only in the
    /// downloads folder and the folders directly inside it, and only at hidden folders named like ours (".name.parts").
    @discardableResult
    func removeStalePieceFolders() -> Int { removeStalePieceFolders(in: Self.directory) }

    @discardableResult
    func removeStalePieceFolders(in root: URL, olderThan seconds: TimeInterval = 86_400, now: Date = Date()) -> Int {
        let fm = FileManager.default
        var removed = 0
        func sweep(_ dir: URL, depth: Int) {
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey], options: []) else { return }
            for url in entries {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
                guard values?.isDirectory == true else { continue }
                let name = url.lastPathComponent
                if name.hasPrefix("."), name.hasSuffix(".bsetu-extract") {
                    // What an archive was being opened into when the app stopped: only hidden folders of that exact shape, and only once they are old.
                    if now.timeIntervalSince(values?.contentModificationDate ?? now) > seconds, (try? fm.removeItem(at: url)) != nil { removed += 1 }
                } else if name.hasPrefix("."), name.hasSuffix(".parts"), name.count > 7 {
                    let modified = values?.contentModificationDate ?? now
                    if now.timeIntervalSince(modified) > seconds, !destinations.values.contains(where: { $0.deletingLastPathComponent() == dir && ".\($0.lastPathComponent).parts" == name }) {
                        if (try? fm.removeItem(at: url)) != nil { removed += 1 }
                    }
                } else if depth == 0, !name.hasPrefix(".") { sweep(url, depth: 1) }
            }
        }
        sweep(root, depth: 0)
        return removed
    }
}
