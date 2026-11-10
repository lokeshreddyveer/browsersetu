import Foundation

extension DownloadProtocolID {
    static let bittorrent: Self = "bittorrent"
}

/// Peer-to-peer networking is off until the person turns it on, and every further capability is a separate, explicit choice. Saved per profile; no secret in it.
struct TorrentSettings: Codable, Equatable, Sendable {
    /// Nothing contacts a tracker or a peer until this is on.
    var enabled = false
    var maxActiveTorrents = 3
    var maxPeersPerTorrent = 30
    var maxPeersTotal = PeerBudget.defaultTotal
    /// Send pieces to peers while downloading (what keeps a swarm healthy and keeps others willing to send to you). It is not seeding: nothing is shared once the download is done.
    var shareWhileDownloading = true
    var downloadLimit: Int64?
    var uploadLimit: Int64?
    /// Looking for peers on the public DHT as well as through trackers. Optional so settings saved before it existed still read; off until the person turns it on.
    var useDHT: Bool?
    var dhtEnabled: Bool { get { useDHT ?? false } set { useDHT = newValue } }
    /// BEP 11 peer exchange: on unless turned off (it only ever happens with peers already connected, and never for a private torrent).
    var usePEX: Bool?
    var pexEnabled: Bool { get { usePEX ?? true } set { usePEX = newValue } }
    /// BEP 14 local discovery: off until the person allows it.
    var useLocalDiscovery: Bool?
    var localDiscoveryEnabled: Bool { get { useLocalDiscovery ?? false } set { useLocalDiscovery = newValue } }
    /// Addresses and ranges never to connect to.
    var blockedPeers: [String]?
    /// How peers are reached: TCP, µTP or both (bounded fallback), and whether the stream is scrambled with MSE.
    var transportMode: TransportPreference?
    var encryptionMode: EncryptionPolicy?
    var transport: TransportPreference { get { transportMode ?? .automatic } set { transportMode = newValue } }
    var encryption: EncryptionPolicy { get { encryptionMode ?? .preferEncrypted } set { encryptionMode = newValue } }
    /// Accepting connections from peers: off until the person allows it, with a port of their choice (0 or none: the system picks one).
    var allowInbound: Bool?
    var inboundEnabled: Bool { get { allowInbound ?? false } set { allowInbound = newValue } }
    var listenPort: Int?
    /// Asking the router to forward the listening port (NAT-PMP): off until the person allows it, and only meaningful while incoming connections are on.
    var allowPortMapping: Bool?
    var portMappingEnabled: Bool { get { allowPortMapping ?? false } set { allowPortMapping = newValue } }

    /// Seeding (DX-06): sharing a finished torrent. Off by default and never turned on by finishing a download. All optional so settings saved before they existed still read.
    var seedMode: SeedingMode?
    var seedingMode: SeedingMode { get { seedMode ?? .off } set { seedMode = newValue } }
    /// Stop seeding a torrent once uploaded / size of its data reaches this (nil: no limit).
    var ratioTarget: Double?
    /// Stop after this many seconds of seeding (nil: no limit).
    var seedTimeLimit: Double?
    /// Upload speed for seeding torrents, bytes per second (nil: only the overall upload limit applies). Held per torrent.
    var seedUploadLimit: Int64?
    var uploadPeers: Int?
    var maxUploadPeers: Int { get { uploadPeers ?? 8 } set { uploadPeers = newValue } }
    var initialSeed: Bool?
    /// Initial (super) seeding: explicit choice, for a torrent whose whole data is verified.
    var initialSeeding: Bool { get { initialSeed ?? false } set { initialSeed = newValue } }

    static let uploadPeersRange = 1...50
    static let activeRange = 1...10
    static let peersRange = 5...100
    static let totalRange = 10...300

    func normalized() -> TorrentSettings {
        var s = self
        s.maxActiveTorrents = min(max(s.maxActiveTorrents, Self.activeRange.lowerBound), Self.activeRange.upperBound)
        s.maxPeersPerTorrent = min(max(s.maxPeersPerTorrent, Self.peersRange.lowerBound), Self.peersRange.upperBound)
        s.maxPeersTotal = min(max(s.maxPeersTotal, Self.totalRange.lowerBound), Self.totalRange.upperBound)
        s.downloadLimit = BandwidthController.valid(s.downloadLimit)
        s.uploadLimit = BandwidthController.valid(s.uploadLimit)
        s.seedUploadLimit = BandwidthController.valid(s.seedUploadLimit)
        s.ratioTarget = s.ratioTarget.flatMap { $0.isFinite && $0 > 0 ? min(max($0, 0.1), 1000) : nil }
        s.seedTimeLimit = s.seedTimeLimit.flatMap { $0.isFinite && $0 > 0 ? min(max($0, 60), 3_650 * 86_400) : nil }
        if let n = s.uploadPeers { s.uploadPeers = min(max(n, Self.uploadPeersRange.lowerBound), Self.uploadPeersRange.upperBound) }
        return s
    }

    func encoded() -> String? { (try? JSONEncoder().encode(normalized())).flatMap { String(data: $0, encoding: .utf8) } }
    static func decode(_ text: String?) -> TorrentSettings {
        guard let text, text.utf8.count < 4096, let data = text.data(using: .utf8), let s = try? JSONDecoder().decode(TorrentSettings.self, from: data) else { return TorrentSettings() }
        return s.normalized()
    }
}

/// Speed limits for peer traffic. Separate controllers from the HTTP ones: a torrent's download and upload are paced where bytes are read from, and sent to, each peer.
enum TorrentBandwidth {
    static let download = BandwidthController()
    static let upload = BandwidthController()
}

/// How many torrents may run at once: its own pool in the scheduler, leased per task like every other resource.
final class TorrentSlots: ResourcePool, @unchecked Sendable {
    static let shared = TorrentSlots()
    static let poolName = "torrents"
    var name: String { Self.poolName }
    private let lock = NSLock()
    private var holders = Set<UUID>()
    private var limit = 3

    func setLimit(_ value: Int) { lock.lock(); limit = max(1, value); lock.unlock() }
    var open: Int { lock.lock(); defer { lock.unlock() }; return holders.count }
    func canGrant(_ amount: Int, scope: String?) -> Bool { lock.lock(); defer { lock.unlock() }; return holders.count + amount <= limit }
    func grant(_ amount: Int, scope: String?, task: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if holders.contains(task) { return true }
        guard holders.count + amount <= limit else { return false }
        holders.insert(task); return true
    }
    func release(task: UUID) { lock.lock(); holders.remove(task); lock.unlock() }
}

/// What a person sees before a torrent starts: nothing has been contacted to make this.
struct TorrentInspection: Sendable {
    var meta: TorrentMetainfo
    var privacyNotice: String
    var trackerHosts: [String]
}

enum TorrentError: Error, LocalizedError, Equatable {
    case disabled, notReady(String)
    var errorDescription: String? {
        switch self {
        case .disabled: "Peer-to-peer downloads are off. Turn them on in Settings → Downloads first: other people sharing the torrent will be able to see your network address."
        case .notReady(let why): why
        }
    }
}

/// Connects a torrent to the rest of the downloads system: the ledger owns its life, the scheduler decides when it runs, and the session owns the peers.
/// Hooks into the same coordinator paths as an HTTP download (admission, begin, progress, finish, fail); it adds no coordinator of its own.
@MainActor
final class TorrentRunner {
    static let sentinel = Data("{\"engine\":\"bittorrent\",\"v\":1}".utf8)

    private unowned let coordinator: DownloadCoordinator
    private var ledger: DownloadLedger { coordinator.ledger }
    private var sessions: [UUID: TorrentSession] = [:]
    private var storages: [UUID: TorrentStorage] = [:]
    var transports: PeerTransportFactory
    var tracker: TrackerAnnouncing
    private var silentStops = Set<UUID>()
    /// Torrents the person chose to download from web seeds only: they carry on when peer-to-peer is turned off, because they use none of it.
    private var httpOnlyTasks = Set<UUID>()
    private var networkSetup: () -> DownloadNetworkSetup = { DownloadNetworkSetup() }
    private var dhtStorage: DHTNode?
    private var lanStorage: LocalPeerDiscovery?

    /// Local discovery, made when first needed; it opens nothing until a torrent that may use it asks.
    var lan: LocalPeerDiscovery {
        if let lanStorage { return lanStorage }
        let network = networkSetup
        let listener = peerListener
        let node = LocalPeerDiscovery(transport: MulticastTransport(), policy: { [weak self] in
            let compute: @Sendable () -> DHTBlock? = {
                MainActor.assumeIsolated {
                    guard let self else { return DHTBlock(reason: "Local discovery is off.") }
                    return LANNetworkPolicy.block(setup: network(), enabled: self.settings.enabled, lanEnabled: self.settings.localDiscoveryEnabled, systemProxyActive: SystemProxy.isActive())
                }
            }
            return Thread.isMainThread ? compute() : DispatchQueue.main.sync(execute: compute)
        }, announcePort: { listener.status.state == .listening ? listener.status.tcpPort : nil }, isPrivateHash: { [privateHashes] in privateHashes.contains($0) })
        lanStorage = node
        return node
    }

    /// Whether a local peer learned from this source may still be used.
    private func peerSourceStillAllowed(_ key: String, task: UUID) -> Bool {
        switch key {
        case "dht-local": return hasConfiguredLocalBootstrap
        case "lpd": return settings.enabled && settings.localDiscoveryEnabled
        default: return localTrackerPermission.isPeerAuthorized(task: task, key: key)
        }
    }
    private let privateHashes = HashSet()

    final class HashSet: @unchecked Sendable {
        private let lock = NSLock(); private var set = Set<Data>()
        func insert(_ d: Data) { lock.lock(); set.insert(d); lock.unlock() }
        func contains(_ d: Data) -> Bool { lock.lock(); defer { lock.unlock() }; return set.contains(d) }
    }

    /// The one DHT node of the app: made when first needed, and it opens nothing until a torrent that may use it asks (see `DHTNode`).
    var dht: DHTNode {
        if let dhtStorage { return dhtStorage }
        let network = networkSetup
        let node = DHTNode(transport: NWDHTTransport(choices: { let s = network(); return (s.refuseExpensive, s.refuseConstrained) }), policy: { [weak self] in
            let compute: @Sendable () -> DHTBlock? = {
                MainActor.assumeIsolated {
                    guard let self else { return DHTBlock(reason: "The DHT is off.") }
                    return DHTNetworkPolicy.block(setup: network(), enabled: self.settings.enabled, dhtEnabled: self.settings.dhtEnabled, systemProxyActive: SystemProxy.isActive())
                }
            }
            return Thread.isMainThread ? compute() : DispatchQueue.main.sync(execute: compute)
        }, sendGate: { let s = network(); return NetworkPathGate.shared.refusal(expensive: s.refuseExpensive, constrained: s.refuseConstrained) },
        store: DefaultsDHTNodeStore(), bootstrap: {
            if let own = UserDefaults.standard.stringArray(forKey: "downloads.dhtBootstrap"), !own.isEmpty { return (own, true) }          // the person's own list (or a test node), local addresses allowed
            return (DHTNode.Config.defaultBootstrap, false)
        }, isPrivateHash: { [privateHashes] in privateHashes.contains($0) })
        dhtStorage = node
        return node
    }

    private var networkSignature = ""
    private func currentNetworkSignature() -> String {
        let setup = networkSetup()
        return "\(setup.proxy.mode.rawValue)|\(setup.proxy.host)|\(setup.proxy.port)|\(setup.refuseExpensive)|\(setup.refuseConstrained)"
    }

    /// Called when the torrent settings or the network settings changed: what is meant to take effect at once is applied to the torrents already running.
    func settingsChanged() {
        let s = settings
        let signature = currentNetworkSignature()
        let networkMoved = !networkSignature.isEmpty && signature != networkSignature
        networkSignature = signature
        transportConfig.update(s)
        if !s.inboundEnabled { listenerStorage?.stopNow(reason: "Incoming connections are off.") }
        else { for (id, session) in sessions { attachInbound(session, id: id) } }
        let filter = PeerFilter(s.blockedPeers ?? [])
        for (id, session) in sessions {
            let isPrivate = privateHashes.contains(session.infoHash)
            session.applyLive(pex: s.pexEnabled, peerFilter: filter, lan: (s.localDiscoveryEnabled && !isPrivate) ? lan : nil, dht: (s.dhtEnabled && !isPrivate) ? dht : nil)
            if networkMoved { session.networkChanged() }
            _ = id
        }
        seedSettingsChanged(); if networkMoved { seedNetworkChanged() }
        for (_, session) in probes { session.applyLive(pex: false, peerFilter: filter, lan: nil, dht: s.dhtEnabled ? dht : nil); if networkMoved { session.networkChanged() } }
    }

    /// Whether a node the person named themselves on their own network is configured (what lets peers it returns be on the local network).
    var hasConfiguredLocalBootstrap: Bool { !(UserDefaults.standard.stringArray(forKey: "downloads.dhtBootstrap") ?? []).isEmpty }
    private var pendingRelease: [UUID: UUID] = [:]
    /// Details lookups in progress (they contact trackers and peers like a download does, so turning peer-to-peer off ends them too).
    private var probes: [UUID: TorrentSession] = [:]

    private func endProbe(_ id: UUID, announceStopped: Bool? = nil) {
        guard let session = probes.removeValue(forKey: id) else { return }
        session.stop(sendStoppedAnnounce: announceStopped ?? settings.enabled)
    }
    var sessionSettings = TorrentSession.Settings()
    /// For tests: a different place for the sidecar files' parent is never needed; the working folder is always inside the download folder.
    private var finishing = Set<UUID>()

    init(coordinator: DownloadCoordinator) {
        self.coordinator = coordinator
        let permission = LocalTrackerPermission.shared
        localTrackerPermission = permission
        transports = NWPeerTransportFactory()
        tracker = TrackerRouter(authorized: { permission.isAuthorized($0) })
        let weakSelf = coordinator
        let network: () -> DownloadNetworkSetup = { [weak weakSelf] in weakSelf?.http.engine.currentNetwork ?? DownloadNetworkSetup() }
        let box = TransportConfigBox(); box.update(coordinator.torrentSettings)
        transportConfig = box
        transports = NWPeerTransportFactory(network: network, preferences: { box.value })
        tracker = TrackerRouter(network: network, authorized: { permission.isAuthorized($0) })
        networkSetup = network
    }

    /// The person's transport and encryption choices, kept where the connection code (off the main thread) can read them.
    final class TransportConfigBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: (TransportPreference, EncryptionPolicy) = (.automatic, .preferEncrypted)
        var value: (TransportPreference, EncryptionPolicy) { lock.lock(); defer { lock.unlock() }; return stored }
        func update(_ s: TorrentSettings) { lock.lock(); stored = (s.transport, s.encryption); lock.unlock() }
    }
    let transportConfig: TransportConfigBox
    let inboundRouter = InboundRouter()
    private var listenerStorage: PeerListener?

    /// The one listener of the app (nothing is opened until a torrent that may receive connections asks).
    var peerListener: PeerListener {
        if let listenerStorage { return listenerStorage }
        let network = networkSetup
        let box = transportConfig
        let l = PeerListener(router: inboundRouter, policy: { [weak self] in
            let compute: @Sendable () -> DHTBlock? = {
                MainActor.assumeIsolated {
                    guard let self else { return DHTBlock(reason: "Incoming connections are off.") }
                    return InboundNetworkPolicy.block(setup: network(), enabled: self.settings.enabled, inbound: self.settings.inboundEnabled, systemProxyActive: SystemProxy.isActive())
                }
            }
            return Thread.isMainThread ? compute() : DispatchQueue.main.sync(execute: compute)
        }, encryption: { box.value.1 }, preferredPort: { [weak self] in
            let read: @Sendable () -> UInt16 = { MainActor.assumeIsolated { UInt16(clamping: self?.settings.listenPort ?? 0) } }
            return Thread.isMainThread ? read() : DispatchQueue.main.sync(execute: read)
        }, gate: {
            let s = network()          // the person's metered-network and Low Data Mode choices apply to what is accepted and answered, as they do to what is dialled
            return NetworkPathGate.shared.refusal(expensive: s.refuseExpensive, constrained: s.refuseConstrained)
        }, mapper: PortMapper(gateway: { NetworkPathGate.shared.gateway }, open: { NWPortMapTransport(gateway: $0) }, upnp: { NWUPnPTransport() }), mappingEnabled: { [weak self] in
            let read: @Sendable () -> Bool = { MainActor.assumeIsolated { self?.settings.portMappingEnabled ?? false } }
            return Thread.isMainThread ? read() : DispatchQueue.main.sync(execute: read)
        })
        l.dhtInbound = { [weak self] data, from, reply in DispatchQueue.main.async { self?.dhtStorage?.handleInbound(data, from: from, reply: reply) } }
        listenerStorage = l
        return l
    }

    /// Sends a running torrent's incoming peers to it, and keeps the listener open while any such torrent runs.
    private func attachInbound(_ session: TorrentSession, id: UUID) {
        guard settings.inboundEnabled else { return }
        inboundRouter.register(session.infoHash) { [weak session] transport, address, initial in session?.adoptInbound(transport, address: address, initial: initial) ?? false }
        peerListener.acquire(id)
        session.inboundStatus = { [weak self] in self?.listenerStorage?.status ?? PeerListenerStatus() }
    }
    private func detachInbound(_ session: TorrentSession?, id: UUID) {
        if let session { inboundRouter.unregister(session.infoHash) }
        listenerStorage?.release(id)
    }

    var settings: TorrentSettings { coordinator.torrentSettings }

    // MARK: Looking (no network)

    func inspect(torrentFile data: Data) throws -> TorrentInspection { try inspection(of: TorrentMetainfo.parse(data)) }

    func inspection(of meta: TorrentMetainfo) -> TorrentInspection {
        let hosts = Array(Set(meta.trackers.compactMap { $0.host })).sorted()
        let notice = meta.isPrivate
            ? "This is a private torrent: it uses only its own tracker, and no other source of peers. Peers and the tracker will see your network address."
            : "Other people sharing this torrent will see your network address, and the trackers listed will too. Peers are found only through those trackers."
        return TorrentInspection(meta: meta, privacyNotice: notice, trackerHosts: hosts)
    }

    /// Asks the running torrent's trackers for their counts (on request only; see `TorrentSession.scrapeNow`).
    func requestScrape(for id: UUID) { sessions[id]?.scrapeNow() }

    // MARK: Where a request may reach

    /// The trackers a request of this origin may use. The person's own request may name a tracker on their own network; a magnet that came from a web page may not, so a page cannot make the
    /// browser send a request to a router, a printer or another machine on the local network by naming it as a tracker.
    static func usableTrackers(_ trackers: [URL], origin: DownloadRequestOrigin, granted: Set<String> = []) -> [URL] {
        origin == .user ? trackers : trackers.filter { !HTTPRequestPolicy.classify(host: $0.host ?? "").isInternal || granted.contains(LocalTrackerPermission.key($0)) }
    }

    /// The destinations a request is entitled to for as long as it runs: all of the person's own, and for a page's link only those the person approved.
    static func trustedKeys(_ trackers: [URL], origin: DownloadRequestOrigin) -> Set<String> {
        Set(trackers.filter { LocalTrackerPermission.isLocal($0) }.map(LocalTrackerPermission.key))          // only destinations that are local: a public name that resolves to the LAN is never vouched for
    }

    /// Permission for local-network trackers named by a page's link; see `LocalTrackerPermission`.
    let localTrackerPermission: LocalTrackerPermission

    /// The same rule for a torrent's tiers: each tier keeps only the trackers a request of this origin may use, and a tier left empty is dropped.
    static func usableTiers(_ tiers: [[URL]], origin: DownloadRequestOrigin, granted: Set<String> = []) -> [[URL]] {
        tiers.map { usableTrackers($0, origin: origin, granted: granted) }.filter { !$0.isEmpty }
    }

    /// Peers on a local network are used only for the person's own request whose own tracker is on one (or when the settings already allow them); never for a request from a page.
    static func allowsLocalPeers(settingsAllow: Bool, trackers: [URL], origin: DownloadRequestOrigin) -> Bool {
        settingsAllow || (origin == .user && trackers.contains { HTTPRequestPolicy.classify(host: $0.host ?? "").isInternal })
    }

    /// A magnet link names a torrent but does not describe it. Getting the description means contacting its trackers and peers, so it happens only when the person asks.
    func fetchDetails(of magnet: MagnetLink, timeout: TimeInterval = 60, origin: DownloadRequestOrigin = .user, isPrivateSession: Bool = false) async throws -> TorrentMetainfo {
        guard settings.enabled else { throw TorrentError.disabled }
        let outcome = await localTrackerPermission.authorize(magnet.trackers, origin: origin, source: nil, isPrivateSession: isPrivateSession) { await Dialogs.permission($0) }
        let granted = outcome.trackers
        guard settings.enabled else { throw TorrentError.disabled }          // turned off while the question was open
        let trackers = Self.usableTrackers(magnet.trackers, origin: origin, granted: granted)
        if !magnet.trackers.isEmpty, trackers.isEmpty { throw TorrentError.notReady("The only trackers this link names are on your own network, and you did not allow a web page to use them. Choose Get Details again to be asked, or paste the link into Add Download if you trust it.") }
        guard !magnet.trackers.isEmpty || settings.dhtEnabled else {
            throw TorrentError.notReady("This magnet link names no tracker. Turn on “Find peers on the public DHT” in Settings → Downloads to look for peers without one.")
        }
        let probe = UUID()
        // The same rule as for the download itself: peers on a local network are used only when the magnet's own tracker is on one, so a tracker out on the internet still cannot send the browser to a local address.
        var probeSettings = sessionSettings
        probeSettings.allowLocalPeers = sessionSettings.allowLocalPeers
        probeSettings.peerFilter = PeerFilter(settings.blockedPeers ?? [])          // blocked addresses are not contacted for details either
        localTrackerPermission.trust(task: probe, keys: Self.trustedKeys(trackers, origin: origin), peers: outcome.peers, isPrivate: isPrivateSession)
        defer { localTrackerPermission.release(task: probe) }
        return try await withCheckedThrowingContinuation { continuation in
            var finished = false
            let session = TorrentSession(infoHash: magnet.infoHash, meta: nil, trackers: trackers, storage: { nil }, alreadyHave: [], transports: transports,
                                         tracker: tracker, download: nil, upload: nil, taskID: probe, settings: probeSettings)
            session.expectedInfoHashV2 = magnet.infoHashV2          // metadata for a version 2 link is checked against the full SHA-256, not only its first 20 bytes
            session.localPeerSources = outcome.peers          // local peers only from a tracker whose peers were allowed
            session.requestOrigin = origin
            session.localPeerStillAllowed = { [weak self] key in self?.peerSourceStillAllowed(key, task: probe) ?? false }
            if settings.dhtEnabled { session.dht = dht }
            probes[probe] = session
            session.onEvent = { [weak session] event in
                DispatchQueue.main.async { [self] in
                    guard !finished else { return }
                    switch event {
                    case .metadata(let meta): finished = true; self.endProbe(probe); PeerBudget.shared.releaseAll(task: probe); continuation.resume(returning: meta)
                    case .failed(let why, _): finished = true; self.endProbe(probe); PeerBudget.shared.releaseAll(task: probe); continuation.resume(throwing: TorrentError.notReady(why))
                    default: break
                    }
                }
            }
            session.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [self] in
                guard !finished else { return }
                finished = true; self.endProbe(probe); PeerBudget.shared.releaseAll(task: probe)
                continuation.resume(throwing: TorrentError.notReady("No peer sent the torrent's details in time. Try again later, or use the .torrent file."))
            }
        }
    }

    // MARK: Starting

    /// Starts the download of the chosen files. The caller has shown the inspection and the person has agreed.
    @discardableResult
    func add(_ meta: TorrentMetainfo, selectedFiles: Set<Int>, origin: DownloadRequestOrigin = .user) async throws -> UUID {
        let chosen = selectedFiles.isEmpty ? Set(meta.files.map(\.index)) : selectedFiles.intersection(Set(meta.files.map(\.index)))
        return try await add(meta, selection: TorrentSelection.only(chosen, in: meta), origin: origin)
    }

    /// Starts a torrent with a choice of files, priorities and an order. `magnetSeeds`: web seed addresses the magnet link carried.
    func add(_ meta: TorrentMetainfo, selection: TorrentSelection, origin: DownloadRequestOrigin = .user, magnetSeeds: [URL] = [], httpOnly: Bool = false, allowLocalWebSeeds: Bool = false, seedingAuthorized: Bool = false) async throws -> UUID {
        // Web seeds only (HTTP): no tracker, DHT, peer or incoming connection. Allowed when peer-to-peer is off, but only when the person asked for it and the torrent has a web seed.
        let hasSeeds = !WebSeedMapping.sources(meta: meta, magnetSeeds: magnetSeeds).isEmpty
        guard settings.enabled || (httpOnly && hasSeeds) else { throw TorrentError.disabled }
        let httpOnly = httpOnly && hasSeeds
        let selection = selection.normalized(for: meta)
        let chosen = selection.selected(in: meta)
        guard !chosen.isEmpty else { throw TorrentError.notReady("Choose at least one file.") }
        let magnet = URL(string: Self.magnetText(for: meta))
        let ticket = await coordinator.admitTicket(filename: meta.name, source: nil, protocolID: .bittorrent)
        coordinator.ledger.update(ticket.id) { $0.engineMetadata["torrent"] = "1"; $0.engineMetadata["infoHash"] = meta.infoHashHex; $0.engineMetadata["origin"] = origin.rawValue
            // Only the person's explicit consent (shown by the caller) is recorded here; a torrent is never authorized to be shared by default.
            if seedingAuthorized { $0.engineMetadata["seedAuthorized"] = "1" } }
        guard ticket.admitted else { return ticket.id }
        let id = ticket.id
        if await coordinator.askAboutDuplicate(suggestedName: meta.name, sourceHost: nil, source: magnet, isPrivate: false, taskID: id) { return id }
        let started = coordinator.begin(suggestedName: meta.name, sourceHost: nil, sourceURL: magnet, isPrivate: false, taskID: id, protocolID: .bittorrent,
                                        cancel: { [weak self] in self?.cancel(id) }, suspend: { [weak self] done in self?.pause(id, done: done) })
        let work = TorrentStorage.workingFolder(for: id, in: started.destination.deletingLastPathComponent())
        let storage = TorrentStorage(meta: meta, workingFolder: work, selected: chosen)
        do {
            try storage.prepare()
            try Self.saveSidecar(work, meta: meta, selected: chosen, trackers: meta.trackers, selection: selection, magnetSeeds: magnetSeeds, httpOnly: httpOnly, allowLocalWebSeeds: allowLocalWebSeeds)
        } catch {
            storage.discard()
            fail(id, (error as? LocalizedError)?.errorDescription ?? "The download could not be prepared.", retryable: false)
            return id
        }
        // Every piece gets a durable record; a piece is marked done only after it has been checked and written.
        let pieces = (0..<meta.pieceCount).map { PieceRecord(index: $0, start: Int64($0) * meta.pieceLength, end: Int64($0) * meta.pieceLength + meta.length(ofPiece: $0) - 1) }
        try? ledger.store?.savePlan(task: id, pieces: pieces)
        ledger.update(id) { $0.transfer.totalBytes = storage.selectedBytes; $0.transfer.resumeAvailable = true; $0.engineMetadata["workDir"] = work.lastPathComponent
            $0.engineMetadata["files"] = String(meta.visibleFiles.count); $0.engineMetadata["selected"] = String(chosen.count); $0.engineMetadata["private"] = meta.isPrivate ? "1" : "0"
            $0.engineMetadata["httpOnly"] = httpOnly ? "1" : "0"; $0.engineMetadata["allowLocalWebSeeds"] = allowLocalWebSeeds ? "1" : "0" }
        ledger.saveResumeData(id, Self.sentinel)
        run(id, meta: meta, storage: storage, have: [], destination: started.destination, selection: selection, magnetSeeds: magnetSeeds, httpOnly: httpOnly, allowLocalWebSeeds: allowLocalWebSeeds)
        return id
    }

    private func run(_ id: UUID, meta: TorrentMetainfo, storage: TorrentStorage, have: Set<Int>, destination: URL, selection: TorrentSelection? = nil, magnetSeeds: [URL] = [], httpOnly: Bool = false, allowLocalWebSeeds: Bool = false) {
        var s = sessionSettings
        s.maxPeers = settings.maxPeersPerTorrent
        s.shareWhileDownloading = settings.shareWhileDownloading || (settings.seedingMode == .whileDownloadingAndCompleted && seedingAuthorized(id))
        s.pex = settings.pexEnabled; s.peerFilter = PeerFilter(settings.blockedPeers ?? [])
        // What the request was started from is kept with the task (a page's link is held to the page's limits, and still is after a relaunch).
        let origin = DownloadRequestOrigin(rawValue: ledger.record(id)?.engineMetadata["origin"] ?? "") ?? .user
        let isPrivate = ledger.record(id)?.isPrivate ?? false
        if networkSignature.isEmpty { networkSignature = currentNetworkSignature() }          // what later changes are compared with
        let granted = localTrackerPermission.granted(isPrivate: isPrivate)          // never asks from here: a download in the background cannot put up a question
        let peerGrants = origin == .user ? Set(meta.trackers.filter(LocalTrackerPermission.isLocal).map(LocalTrackerPermission.key)) : localTrackerPermission.grantedPeers(isPrivate: isPrivate)
        let trackers = Self.usableTrackers(meta.trackers, origin: origin, granted: granted)
        let usable = Self.usableTiers(meta.trackerTiers, origin: origin, granted: granted)
        let tiersForSession: [[URL]]? = usable.isEmpty ? nil : usable          // a torrent known only from its magnet link has no tiers: each tracker is its own
        s.allowLocalPeers = sessionSettings.allowLocalPeers          // only the person's own setting opens local peers to every tracker's list
        pendingRelease[id] = nil
        // Web seeds on the local network are used only if the person approved them when adding the torrent (the choice is kept with the task, so a relaunch honours it; nothing is asked in the background).
        let approvedSeeds: Set<String> = allowLocalWebSeeds ? Set(WebSeedMapping.sources(meta: meta, magnetSeeds: magnetSeeds).map(\.url).filter(LocalTrackerPermission.isLocal).map(LocalTrackerPermission.key)) : []
        localTrackerPermission.trust(task: id, keys: Self.trustedKeys(trackers, origin: origin).union(approvedSeeds), peers: peerGrants, isPrivate: isPrivate)
        if httpOnly { httpOnlyTasks.insert(id) } else { httpOnlyTasks.remove(id) }
        let session = TorrentSession(infoHash: meta.infoHash, meta: meta, trackers: trackers, trackerTiers: tiersForSession, storage: { storage }, alreadyHave: have,
                                     transports: transports, tracker: tracker, download: TorrentBandwidth.download, upload: TorrentBandwidth.upload, taskID: id, settings: s)
        session.localPeerSources = peerGrants.intersection(trackers.map(LocalTrackerPermission.key))          // local peers only from a tracker whose peers were allowed
        session.requestOrigin = origin
        session.initialSelection = selection
        // Web seeds and HTTP seeds go through the same HTTP path as tracker requests (address checks, redirects, the person's proxy and network choices).
        if let router = tracker as? TrackerRouter, let http = router.http as? HTTPTrackerClient {
            session.webSeedFetcher = HTTPWebSeedFetcher(client: http)
            session.magnetWebSeeds = magnetSeeds
        }
        session.localPeerStillAllowed = { [weak self] key in self?.peerSourceStillAllowed(key, task: id) ?? false }
        if meta.isPrivate { privateHashes.insert(meta.infoHash) }          // never answered or stored by our own DHT node, and never looked up
        if httpOnly { session.peerNetworkEnabled = false }
        if settings.dhtEnabled && !meta.isPrivate && !httpOnly { session.dht = dht }
        if settings.localDiscoveryEnabled && !meta.isPrivate && !httpOnly { session.lan = lan }
        sessions[id] = session; storages[id] = storage
        if !httpOnly { attachInbound(session, id: id) }
        session.onEvent = { [weak self] event in DispatchQueue.main.async { self?.handle(event, id: id, destination: destination) } }
        session.start()
    }

    // MARK: Events

    private func handle(_ event: TorrentSession.Event, id: UUID, destination: URL) {
        guard sessions[id] != nil else { return }
        switch event {
        case .progress(let done, let total):
            coordinator.update(id, fraction: total > 0 ? min(0.99, Double(done) / Double(total)) : 0, completed: done, total: total)
        case .verifiedPiece(let index, let checksum):
            ledger.store?.markPieceDone(task: id, index: index, checksum: checksum, session: 1)
        case .metadata: break
        case .selectionChanged(let new): selectionChanged(id, new)
        case .layersInstalled(let layers): if let storage = storages[id] { try? LayerStore.encode(layers).write(to: storage.workingFolder.appendingPathComponent(".layers"), options: .atomic) }
        case .seedingEnded: break
        case .finished: finish(id, destination: destination)
        case .failed(let why, let retryable): teardown(id); fail(id, why, retryable: retryable)
        }
    }

    private func finish(_ id: UUID, destination: URL) {
        guard !finishing.contains(id), let storage = storages[id] else { return }
        let name = destination.lastPathComponent
        let parent = destination.deletingLastPathComponent()
        // The place the files will go is checked before anything is moved: a finished download whose location the app would then refuse to record must not be put there.
        guard DownloadPathPolicy.isAuthorized(destination.path, roots: coordinator.managedRoots) else {
            teardown(id); fail(id, "This torrent's folder is outside the download folder, so nothing was moved.", retryable: false); return
        }
        guard let running = session(id) else { return }
        let carried = running.snapshot          // what was sent and received while downloading carries into the share ratio
        finishing.insert(id)
        running.stop { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                // A pause or cancel that came while the files were being checked wins: this finish is then stale and does nothing.
                guard self.sessions[id] === running, self.storages[id] === storage else { self.finishing.remove(id); return }
                do {
                    let placed = try storage.finish(into: parent, name: name)
                    self.coordinator.updateDestination(id, to: placed)
                    self.ledger.update(id) { $0.transfer.totalBytes = storage.selectedBytes; $0.transfer.completedBytes = storage.selectedBytes; $0.transfer.resumeAvailable = false }
                    self.teardown(id)
                    self.coordinator.finish(id, source: nil, integrity: .verified)
                    self.prepareSeeding(id, meta: storage.meta, chosen: storage.selected, placed: placed, verified: Set(storage.neededPieces), uploaded: carried.uploaded, downloaded: carried.downloaded)
                } catch {
                    self.teardown(id)
                    self.fail(id, (error as? LocalizedError)?.errorDescription ?? "The finished files could not be put in place.", retryable: false)
                }
                self.finishing.remove(id)
            }
        }
    }

    func isFinishing(_ id: UUID) -> Bool { finishing.contains(id) }

    private func session(_ id: UUID) -> TorrentSession? { sessions[id] }

    private func teardown(_ id: UUID) {
        let session = sessions[id], storage = storages[id]
        sessions[id] = nil; storages[id] = nil
        detachInbound(session, id: id)
        // Files are closed behind the session's last piece write, never under it (a closed number can be given to another file).
        if let session { session.stop(sendStoppedAnnounce: silentStops.remove(id) == nil) { storage?.closeAll() } } else { storage?.closeAll() }
        let token = UUID(); pendingRelease[id] = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self, permission = localTrackerPermission] in
            guard self?.pendingRelease[id] == token else { return }          // resumed in the meantime: the new run holds its own entry
            self?.pendingRelease[id] = nil; permission.release(task: id)
        }          // after the "stopped" announce has had its time
        PeerBudget.shared.releaseAll(task: id)
        TorrentBandwidth.download.discard(task: id); TorrentBandwidth.upload.discard(task: id)
    }

    private func fail(_ id: UUID, _ reason: String, retryable: Bool) {
        coordinator.fail(id, source: nil, error: HTTPDownloadError(info: DownloadFailureInfo(code: "torrent:failed", reason: reason, retryable: retryable)), willRetry: false)
    }

    // MARK: Pause, resume, cancel

    /// Peer-to-peer was turned off: every running torrent is paused (its verified pieces are kept) and nothing more is announced or connected.
    func stopAllBecauseDisabled() {
        for id in Array(probes.keys) { endProbe(id, announceStopped: false) }
        dhtStorage?.stopNow(reason: "Peer-to-peer is off.")
        listenerStorage?.stopNow(reason: "Peer-to-peer is off.")
        lanStorage?.stopNow(reason: "Peer-to-peer is off.")
        for run in Array(seedRuns.values) where run.session != nil || run.verifyTask != nil {
            endSeedSession(run, announceStopped: false)          // turned off: no tracker is told anything
            run.state = .paused("Peer-to-peer is off.")
        }
        for id in Array(sessions.keys) where !httpOnlyTasks.contains(id) {
            silentStops.insert(id)          // turned off: no tracker is told anything, the sessions only end
            if coordinator.canPause(id) { coordinator.pause(id) } else { teardown(id); fail(id, TorrentError.disabled.localizedDescription ?? "Peer-to-peer downloads are off.", retryable: true) }
        }
    }

    func pause(_ id: UUID, done: @escaping (Data?) -> Void) {
        guard let session = sessions[id] else { done(nil); return }
        let storage = storages[id]
        session.stop(sendStoppedAnnounce: silentStops.remove(id) == nil) { [weak self] in
            storage?.sync()
            DispatchQueue.main.async {
                self?.teardown(id)
                done(Self.sentinel)          // the verified pieces are the place that is kept
            }
        }
    }

    /// The only name a working folder ever has. A saved value that is anything else is not used as a path.
    nonisolated static func isWorkingFolderName(_ name: String) -> Bool {
        name.range(of: #"^\.[0-9A-Fa-f]{8}\.bsetu-torrent$"#, options: .regularExpression) != nil
    }

    func cancel(_ id: UUID) {
        let work = storages[id]?.workingFolder
        let saved = ledger.record(id)
        teardown(id)
        if let work { try? FileManager.default.removeItem(at: work) }
        else if let name = saved?.engineMetadata["workDir"], Self.isWorkingFolderName(name), let dest = saved?.file.destinationPath, DownloadPathPolicy.isAuthorized(dest, roots: coordinator.managedRoots) {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: dest).deletingLastPathComponent().appendingPathComponent(name))
        }
        ledger.store?.deletePieces(task: id)
    }

    /// Carries on from the verified pieces (after a pause, or after the app was closed). What the files hold is checked again at the end, whatever the records say.
    func resume(_ id: UUID) {
        let savedHTTPOnly = ledger.record(id)?.engineMetadata["httpOnly"] == "1"
        guard settings.enabled || savedHTTPOnly else { fail(id, TorrentError.disabled.localizedDescription ?? "Peer-to-peer downloads are off.", retryable: true); return }
        guard let record = ledger.record(id), let dest = record.file.destinationPath, let work = record.engineMetadata["workDir"], Self.isWorkingFolderName(work) else { fail(id, "The saved details of this torrent are missing.", retryable: false); return }
        let parent = URL(fileURLWithPath: dest).deletingLastPathComponent()
        guard DownloadPathPolicy.isAuthorized(dest, roots: coordinator.managedRoots) else { fail(id, "This torrent's folder is outside the download folders.", retryable: false); return }
        let folder = parent.appendingPathComponent(work, isDirectory: true)
        guard let side = Self.loadSidecar(folder, expectedHash: record.engineMetadata["infoHash"]) else { fail(id, "The saved details of this torrent are missing or damaged, so it cannot be continued.", retryable: false); return }
        let storage = TorrentStorage(meta: side.meta, workingFolder: folder, selected: side.selected)
        do { try storage.prepare() } catch { fail(id, (error as? LocalizedError)?.errorDescription ?? "The files could not be opened.", retryable: false); return }
        var have = Set((ledger.store?.loadPieces(task: id) ?? []).filter { $0.state == .done }.map(\.index))
        // A pause or crash in the middle of a change of files can leave verified bytes in the other place; they are found there and put back (by hash), and only pieces found in neither are fetched again.
        let healing = storage.reconcile(verified: have)
        for p in healing.missing { have.remove(p) }
        ledger.apply(.resumed, to: id)
        run(id, meta: side.meta, storage: storage, have: have, destination: URL(fileURLWithPath: dest), selection: side.selection, magnetSeeds: side.magnetSeeds, httpOnly: side.httpOnly, allowLocalWebSeeds: side.allowLocalWebSeeds)
    }

    // MARK: Sidecar (kept beside the files, inside the download folder)

    /// What is kept beside the files. Older sidecars have only `selected`, `trackers` and `tiers`; the rest are optional, so they still load (every chosen file at Normal, rarest first).
    private struct State: Codable, Sendable {
        var selected: [Int]; var trackers: [String]; var tiers: [[String]]? = nil
        var version: Int? = nil
        var priorities: [String: Int]? = nil
        var mode: String? = nil
        var streamFile: Int? = nil
        var streamPosition: Int64? = nil
        var webSeeds: [String]? = nil
        var httpSeeds: [String]? = nil
        var magnetSeeds: [String]? = nil
        var httpOnly: Bool? = nil
        var allowLocalWebSeeds: Bool? = nil
        // Version 3: seeding. All optional; v1/v2 sidecars load unchanged.
        /// The person's explicit consent to share THIS torrent. Restoring never sets it.
        var seedingAuthorized: Bool? = nil
        var uploaded: Int64? = nil
        var downloaded: Int64? = nil
        var seedingSeconds: Double? = nil
        var ratioTarget: Double? = nil
        var timeLimit: Double? = nil
        var initialSeeding: Bool? = nil
        /// Opaque: the fast-resume record (verified bitmap, file identities, time), stored and loaded verbatim. This code never looks inside.
        var resume: Data? = nil
    }

    private nonisolated static func readState(_ folder: URL) -> State? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(".state.json")), data.count <= 1_048_576 else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    private nonisolated static func writeState(_ state: State, to folder: URL) throws {
        // Written to a temporary name and renamed over the old file, so a crash in the middle leaves the old, whole file.
        let temp = folder.appendingPathComponent(".state.json.tmp")
        try JSONEncoder().encode(state).write(to: temp)
        let target = folder.appendingPathComponent(".state.json")
        if FileManager.default.fileExists(atPath: target.path) { _ = try FileManager.default.replaceItemAt(target, withItemAt: temp) } else { try FileManager.default.moveItem(at: temp, to: target) }
    }

    /// Changes only the seeding fields of a saved sidecar (read, change, atomic write). Returns false if there is none.
    @discardableResult
    nonisolated static func updateSeedState(_ folder: URL, _ change: (inout SeedFields) -> Void) -> Bool {
        guard var state = readState(folder) else { return false }
        var f = SeedFields(authorized: state.seedingAuthorized, uploaded: state.uploaded, downloaded: state.downloaded, seconds: state.seedingSeconds, ratioTarget: state.ratioTarget, timeLimit: state.timeLimit, initialSeeding: state.initialSeeding)
        change(&f)
        state.version = 3
        state.seedingAuthorized = f.authorized; state.uploaded = f.uploaded; state.downloaded = f.downloaded; state.seedingSeconds = f.seconds
        state.ratioTarget = f.ratioTarget; state.timeLimit = f.timeLimit; state.initialSeeding = f.initialSeeding
        return (try? writeState(state, to: folder)) != nil
    }

    nonisolated static func seedFields(_ folder: URL) -> SeedFields? {
        guard let s = readState(folder) else { return nil }
        return SeedFields(authorized: s.seedingAuthorized, uploaded: s.uploaded, downloaded: s.downloaded, seconds: s.seedingSeconds, ratioTarget: s.ratioTarget, timeLimit: s.timeLimit, initialSeeding: s.initialSeeding)
    }

    struct SeedFields: Equatable, Sendable {
        var authorized: Bool?, uploaded: Int64?, downloaded: Int64?, seconds: Double?, ratioTarget: Double?, timeLimit: Double?, initialSeeding: Bool?
    }

    /// The opaque fast-resume record kept in a sidecar (for the module that writes it).
    nonisolated static func resumeBlob(_ folder: URL) -> Data? { readState(folder)?.resume }
    nonisolated static func setResumeBlob(_ folder: URL, _ blob: Data?) -> Bool {
        guard var state = readState(folder) else { return false }
        state.version = 3; state.resume = blob
        return (try? writeState(state, to: folder)) != nil
    }

    /// The magnet text that names a torrent: its version 1 hash, its version 2 hash (`btmh`, a SHA-256 multihash), or both for a hybrid.
    nonisolated static func magnetText(for meta: TorrentMetainfo) -> String {
        switch meta.version {
        case .v1: return "magnet:?xt=urn:btih:" + meta.infoHashHex
        case .v2: return "magnet:?xt=urn:btmh:1220" + (meta.infoHashV2Hex ?? "")
        case .hybrid: return "magnet:?xt=urn:btih:" + meta.infoHashHex + "&xt=urn:btmh:1220" + (meta.infoHashV2Hex ?? "")
        }
    }

    nonisolated static func saveSidecar(_ folder: URL, meta: TorrentMetainfo, selected: Set<Int>, trackers: [URL], selection: TorrentSelection? = nil, magnetSeeds: [URL] = [], httpOnly: Bool = false, allowLocalWebSeeds: Bool = false) throws {
        try meta.rawInfo.write(to: folder.appendingPathComponent(".info"))
        // The piece layers of a version 2 torrent come from outside the info section (the .torrent file); they are kept once, here, and added to when peers supply more (`.layersInstalled`).
        let layersFile = folder.appendingPathComponent(".layers")
        if meta.version != .v1, !meta.pieceLayers.isEmpty, !FileManager.default.fileExists(atPath: layersFile.path) { try LayerStore.encode(meta.pieceLayers).write(to: layersFile, options: .atomic) }
        var state = State(selected: selected.sorted(), trackers: trackers.map(\.absoluteString), tiers: meta.trackerTiers.map { $0.map(\.absoluteString) })
        state.version = 3
        if let old = readState(folder) {          // a rewrite for another reason (the choice of files changed) keeps what seeding and fast resume saved
            state.seedingAuthorized = old.seedingAuthorized; state.uploaded = old.uploaded; state.downloaded = old.downloaded; state.seedingSeconds = old.seedingSeconds
            state.ratioTarget = old.ratioTarget; state.timeLimit = old.timeLimit; state.initialSeeding = old.initialSeeding; state.resume = old.resume
        }
        if let selection {
            state.priorities = Dictionary(uniqueKeysWithValues: selection.priorities.map { (String($0.key), $0.value.rawValue) })
            state.mode = selection.mode.rawValue; state.streamFile = selection.streamFile; state.streamPosition = selection.streamPosition
        }
        state.httpOnly = httpOnly; state.allowLocalWebSeeds = allowLocalWebSeeds
        state.webSeeds = meta.webSeeds.map(\.absoluteString); state.httpSeeds = meta.httpSeeds.map(\.absoluteString); state.magnetSeeds = magnetSeeds.map(\.absoluteString)
        try writeState(state, to: folder)
    }

    /// The choice changed while the torrent runs: it is saved (so a relaunch keeps it) and the size shown follows it.
    private func selectionChanged(_ id: UUID, _ new: TorrentSelection) {
        guard let storage = storages[id] else { return }
        try? Self.saveSidecar(storage.workingFolder, meta: storage.meta, selected: new.selected(in: storage.meta), trackers: storage.meta.trackers, selection: new,
                              magnetSeeds: sessions[id]?.magnetWebSeeds ?? [],
                              httpOnly: httpOnlyTasks.contains(id), allowLocalWebSeeds: ledger.record(id)?.engineMetadata["allowLocalWebSeeds"] == "1")
        ledger.update(id) { $0.transfer.totalBytes = storage.selectedBytes; $0.engineMetadata["selected"] = String(new.selected(in: storage.meta).count) }
    }

    /// Changes the files, their priorities or the order of a running torrent. Fails with a plain reason if it cannot (nothing chosen, the torrent is not running).
    func updateSelection(_ id: UUID, _ selection: TorrentSelection, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let session = sessions[id] else { completion(.failure(TorrentSession.SelectionError.notReady)); return }
        session.updateSelection(selection) { result in DispatchQueue.main.async { completion(result) } }
    }

    /// Playback is at this byte of a file: the streaming order takes the pieces from there first.
    func setStreamPosition(_ id: UUID, file: Int, byte: Int64) { sessions[id]?.setStreamPosition(file: file, byte: byte) }

    /// The verified bytes of a file of a running torrent (for a player), waiting for them to arrive.
    func verifiedBytes(_ id: UUID, file: Int, offset: Int64, length: Int, timeout: TimeInterval = 30) async -> Data? {
        guard let session = sessions[id] else { return nil }
        return await session.waitForVerified(file: file, offset: offset, length: length, timeout: timeout)
    }

    /// Every file's priority and verified bytes, for the inspector.
    func fileProgress(_ id: UUID, completion: @escaping ([TorrentFileProgress]) -> Void) {
        guard let session = sessions[id] else { completion([]); return }
        session.fileProgress { rows in DispatchQueue.main.async { completion(rows) } }
    }

    /// The saved choice of a torrent that is not running (paused or after a relaunch), for showing its files.
    func savedSelection(_ id: UUID) -> (meta: TorrentMetainfo, selection: TorrentSelection)? {
        guard let record = ledger.record(id), let dest = record.file.destinationPath, let work = record.engineMetadata["workDir"], Self.isWorkingFolderName(work),
              DownloadPathPolicy.isAuthorized(dest, roots: coordinator.managedRoots) else { return nil }
        let folder = URL(fileURLWithPath: dest).deletingLastPathComponent().appendingPathComponent(work, isDirectory: true)
        guard let side = Self.loadSidecar(folder, expectedHash: record.engineMetadata["infoHash"]) else { return nil }
        return (side.meta, side.selection)
    }

    /// The saved details, believed only as far as they can be checked: the info section must be the one this task is for, the files chosen must exist, and sizes and counts are bounded.
    nonisolated static func loadSidecar(_ folder: URL, expectedHash: String?) -> (meta: TorrentMetainfo, selected: Set<Int>, selection: TorrentSelection, magnetSeeds: [URL], httpOnly: Bool, allowLocalWebSeeds: Bool)? {
        func small(_ name: String, _ limit: Int) -> Data? {
            guard let size = (try? folder.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])), size.isSymbolicLink != true, (size.fileSize ?? Int.max) <= limit else { return nil }
            return try? Data(contentsOf: folder.appendingPathComponent(name))
        }
        guard let info = small(".info", TorrentMetainfo.Limit.maxInfoBytes), var meta = try? TorrentMetainfo.parse(infoSection: info),
              let state = small(".state.json", 1_048_576).flatMap({ try? JSONDecoder().decode(State.self, from: $0) }) else { return nil }
        if let expectedHash, expectedHash != meta.infoHashHex { return nil }
        // The saved priorities (newer sidecars), checked against the real file list; older ones had only the list of chosen files, which become Normal.
        var selection: TorrentSelection
        if let saved = state.priorities {
            var map: [Int: FilePriority] = [:]
            for (key, raw) in saved.prefix(TorrentMetainfo.Limit.maxFiles) { if let i = Int(key), let p = FilePriority(rawValue: raw) { map[i] = p } }
            selection = TorrentSelection(priorities: map, mode: state.mode.flatMap(ScheduleMode.init(rawValue:)) ?? .automatic)
            selection.streamFile = state.streamFile; selection.streamPosition = max(0, state.streamPosition ?? 0)
            selection = selection.normalized(for: meta)
        } else {
            selection = TorrentSelection.only(Set(state.selected), in: meta)
        }
        let valid = selection.selected(in: meta)
        guard !valid.isEmpty else { return nil }
        func seedURLs(_ list: [String]?) -> [URL] { (list ?? []).prefix(8).filter { $0.utf8.count <= TorrentMetainfo.Limit.maxTrackerURL }.compactMap { URL(string: $0) }.filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") && $0.host?.isEmpty == false } }
        meta.webSeeds = seedURLs(state.webSeeds); meta.httpSeeds = seedURLs(state.httpSeeds)
        // Piece layers fetched earlier (a version 2 torrent that began as a magnet link), each re-checked against its file's root.
        if meta.version != .v1, let layers = small(".layers", LayerStore.maxBytes) { meta.pieceLayers.merge(LayerStore.decode(layers, for: meta)) { mine, _ in mine } }
        let magnetSeeds = seedURLs(state.magnetSeeds)
        meta.trackers = Array(state.trackers.prefix(TorrentMetainfo.Limit.maxTrackers).compactMap { $0.utf8.count <= TorrentMetainfo.Limit.maxTrackerURL ? URL(string: $0) : nil }
            .filter { ["http", "https", "udp"].contains($0.scheme?.lowercased() ?? "") && $0.host?.isEmpty == false })
        // The tiers the torrent came with, so a resumed download fails over inside a tier as it did before it was paused.
        func ok(_ u: URL) -> Bool { ["http", "https", "udp"].contains(u.scheme?.lowercased() ?? "") && u.host?.isEmpty == false }
        meta.trackerTiers = Array((state.tiers ?? []).prefix(TorrentMetainfo.Limit.maxTrackers).map { tier in
            Array(tier.prefix(TorrentMetainfo.Limit.maxTrackers).compactMap { $0.utf8.count <= TorrentMetainfo.Limit.maxTrackerURL ? URL(string: $0) : nil }.filter(ok))
        }.filter { !$0.isEmpty })
        return (meta, valid, selection, magnetSeeds, state.httpOnly == true, state.allowLocalWebSeeds == true)
    }

    // MARK: Seeding (DX-06)

    /// One finished torrent that may be shared. Created when a download finishes (a small hidden folder beside the files keeps its details) or at launch from such a folder.
    final class SeedRun {
        let id: UUID, meta: TorrentMetainfo, location: URL, chosen: Set<Int>, folder: URL
        var state: SeedingInfo.State = .idle
        var session: TorrentSession?
        var source: SeedingSource?
        /// Pieces known verified without reading (just finished: the final check passed); nil means they must be read back and checked.
        var verified: Set<Int>?
        var verifyProgress: Double?
        var verifyTask: Task<Void, Never>?
        var generation = 0
        var uploaded: Int64 = 0, downloaded: Int64 = 0, seconds: TimeInterval = 0
        var ratioTarget: Double?, timeLimit: Double?, initialSeeding: Bool?
        var lastSnapshot: SeedingSnapshot?
        init(id: UUID, meta: TorrentMetainfo, location: URL, chosen: Set<Int>, folder: URL) { self.id = id; self.meta = meta; self.location = location; self.chosen = chosen; self.folder = folder }
    }

    private var seedRuns: [UUID: SeedRun] = [:]
    private var seedTimer: Timer?

    nonisolated static func isSeedFolderName(_ name: String) -> Bool {
        name.range(of: #"^\.[0-9A-Fa-f]{8}\.bsetu-seed$"#, options: .regularExpression) != nil
    }

    func seedingAuthorized(_ id: UUID) -> Bool { ledger.record(id)?.engineMetadata["seedAuthorized"] == "1" }

    /// The person's consent to share this torrent (the caller has shown the consent text). Does nothing while seeding is off app-wide, and starts nothing by itself then.
    func setSeedingAuthorized(_ id: UUID, _ on: Bool) {
        ledger.update(id) { $0.engineMetadata["seedAuthorized"] = on ? "1" : "0" }
        if let run = seedRuns[id] { if on { ensureSeedFolder(run) }; Self.updateSeedState(run.folder) { $0.authorized = on } }
        else if let work = storages[id]?.workingFolder { Self.updateSeedState(work) { $0.authorized = on } }
    }

    /// Why this torrent is not being shared right now, nil when it may be.
    func seedBlockReason(_ id: UUID) -> String? {
        let setup = networkSetup()
        let refusal = NetworkPathGate.shared.refusal(expensive: setup.refuseExpensive, constrained: setup.refuseConstrained)
        return SeedPolicy.blockReason(enabled: settings.enabled, mode: settings.seedingMode, authorized: seedingAuthorized(id), proxyUnusable: DownloadProxy.problem(setup.proxy) != nil, pathRefusal: refusal)
    }

    /// A download finished and its files are in place: keep what is needed to share it later, and start sharing only if the person allowed it for this torrent and seeding is on.
    private func prepareSeeding(_ id: UUID, meta: TorrentMetainfo, chosen: Set<Int>, placed: URL, verified: Set<Int>, uploaded: Int64, downloaded: Int64) {
        guard !httpOnlyTasks.contains(id) else { return }
        let folder = Self.seedFolder(for: id, beside: placed)
        let run = SeedRun(id: id, meta: meta, location: placed, chosen: chosen, folder: folder)
        run.uploaded = uploaded; run.downloaded = downloaded
        run.source = SeedingSource(meta: meta, location: placed, chosen: chosen, verifiedPieces: verified)          // the identity baseline is taken now, while the files are as verified
        seedRuns[id] = run
        if seedingAuthorized(id) { ensureSeedFolder(run) }
        else if meta.rawInfo.count <= 262_144 {
            // Not shared (yet): nothing is written beside the files. The details are kept with the task so the person can start sharing later.
            ledger.update(id) {
                $0.engineMetadata["seedInfo"] = meta.rawInfo.base64EncodedString()
                $0.engineMetadata["seedChosen"] = chosen.sorted().map(String.init).joined(separator: ",")
                $0.engineMetadata["seedTrackers"] = meta.trackers.map(\.absoluteString).joined(separator: "\n")
                $0.engineMetadata["seedCarried"] = "\(uploaded),\(downloaded)"
                if meta.version != .v1, !meta.pieceLayers.isEmpty { let layers = LayerStore.encode(meta.pieceLayers); if layers.count <= 200_000 { $0.engineMetadata["seedLayers"] = layers.base64EncodedString() } }          // a version 2 torrent's layers are not in its info section
            }
        }
        startSeedingIfAllowed(run)
    }

    nonisolated static func seedFolder(for id: UUID, beside placed: URL) -> URL {
        placed.deletingLastPathComponent().appendingPathComponent(".\(id.uuidString.prefix(8)).bsetu-seed", isDirectory: true)
    }

    /// Writes the small hidden folder that keeps a shared torrent's details (only for a torrent the person allowed to be shared).
    private func ensureSeedFolder(_ run: SeedRun) {
        let fm = FileManager.default
        ledger.update(run.id) { $0.engineMetadata["seedFolder"] = run.folder.lastPathComponent }          // recorded first, so a folder written earlier is still found after a relaunch
        guard !fm.fileExists(atPath: run.folder.appendingPathComponent(".state.json").path) else { return }
        do {
            try fm.createDirectory(at: run.folder, withIntermediateDirectories: true)
            try Self.saveSidecar(run.folder, meta: run.meta, selected: run.chosen, trackers: run.meta.trackers, selection: TorrentSelection.only(run.chosen, in: run.meta))
        } catch { try? fm.removeItem(at: run.folder); return }
        Self.updateSeedState(run.folder) { $0.authorized = true; $0.uploaded = run.uploaded; $0.downloaded = run.downloaded; $0.seconds = run.seconds; $0.ratioTarget = run.ratioTarget; $0.timeLimit = run.timeLimit; $0.initialSeeding = run.initialSeeding }
        ledger.update(run.id) { $0.engineMetadata["seedFolder"] = run.folder.lastPathComponent }
    }

    /// Finds the finished torrents that were being shared before the app was closed. Never authorizes anything: a torrent is shared again only if it was authorized and seeding is still on.
    func restoreSeeding() {
        for (id, record) in ledger.records where record.protocolID == .bittorrent && record.state == .completed && seedRuns[id] == nil { _ = restoreSeedRun(id, record) }
    }

    @discardableResult
    private func restoreSeedRun(_ id: UUID, _ record: DownloadTaskRecord) -> SeedRun? {
        guard let dest = record.file.destinationPath, DownloadPathPolicy.isAuthorized(dest, roots: coordinator.managedRoots) else { return nil }
        let location = URL(fileURLWithPath: dest)
        if let name = record.engineMetadata["seedFolder"], Self.isSeedFolderName(name) {
            let folder = location.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
            if let side = Self.loadSidecar(folder, expectedHash: record.engineMetadata["infoHash"]) {          // no usable folder: fall through to the details kept with the task
            let run = SeedRun(id: id, meta: side.meta, location: location, chosen: side.selected, folder: folder)
            if let f = Self.seedFields(folder) {
                run.uploaded = f.uploaded ?? 0; run.downloaded = f.downloaded ?? 0; run.seconds = f.seconds ?? 0
                run.ratioTarget = f.ratioTarget; run.timeLimit = f.timeLimit; run.initialSeeding = f.initialSeeding
            }
            seedRuns[id] = run
            startSeedingIfAllowed(run)
            return run
            }
        }
        // Finished without being shared: the details were kept with the task.
        let m = record.engineMetadata
        guard let b64 = m["seedInfo"], b64.utf8.count <= 400_000, let info = Data(base64Encoded: b64), var meta = try? TorrentMetainfo.parse(infoSection: info), meta.infoHashHex == m["infoHash"] else { return nil }
        let urls = (m["seedTrackers"] ?? "").split(separator: "\n").prefix(TorrentMetainfo.Limit.maxTrackers).compactMap { URL(string: String($0)) }
            .filter { ["http", "https", "udp"].contains($0.scheme?.lowercased() ?? "") && $0.host?.isEmpty == false }
        meta.trackers = urls; meta.trackerTiers = urls.map { [$0] }
        if meta.version != .v1, let l64 = m["seedLayers"], l64.utf8.count <= 300_000, let layers = Data(base64Encoded: l64) { meta.pieceLayers.merge(LayerStore.decode(layers, for: meta)) { mine, _ in mine } }
        let chosen = Set((m["seedChosen"] ?? "").split(separator: ",").compactMap { Int($0) }).intersection(Set(meta.files.map(\.index)))
        guard !chosen.isEmpty else { return nil }
        let run = SeedRun(id: id, meta: meta, location: location, chosen: chosen, folder: Self.seedFolder(for: id, beside: location))
        let carried = (m["seedCarried"] ?? "").split(separator: ",").compactMap { Int64($0) }
        if carried.count == 2 { run.uploaded = carried[0]; run.downloaded = carried[1] }
        seedRuns[id] = run
        startSeedingIfAllowed(run)
        return run
    }

    private func startSeedingIfAllowed(_ run: SeedRun) {
        guard run.session == nil, run.verifyTask == nil else { return }
        if !seedingAuthorized(run.id) || settings.seedingMode == .off { run.state = .idle; return }
        if let why = seedBlockReason(run.id) { run.state = .paused(why); return }
        launchSeeding(run)
    }

    private func launchSeeding(_ run: SeedRun) {
        if run.source != nil { writeResumeRecord(run); startSeedSession(run); return }
        if let verified = run.verified {
            run.source = SeedingSource(meta: run.meta, location: run.location, chosen: run.chosen, verifiedPieces: verified)
            writeResumeRecord(run)          // the evidence a later relaunch can rely on
            startSeedSession(run); return
        }
        // Fast resume: pieces whose files are exactly as they were when they were verified (same size, modification time, inode and device, and not changed since) are not read again; everything
        // else is read back and checked as before. No record, a damaged record or another torrent's record trusts nothing.
        let baseline = SeedingSource(meta: run.meta, location: run.location, chosen: run.chosen, verifiedPieces: Set(0..<run.meta.pieceCount)).identitiesSnapshot          // the one identity snapshot
        let trustedByRecord = trustedPiecesFromRecord(run, baseline: baseline)
        // No evidence that the files are what was verified: read them back, one piece at a time, and keep only what checks out.
        run.state = .verifying; run.verifyProgress = 0
        let gen = run.generation, meta = run.meta, location = run.location, chosen = run.chosen
        ensureSeedTimer()
        run.verifyTask = Task.detached(priority: .utility) { [weak self, weak run] in
            // The read-back is blocking work: it runs on its own serial queue (one verification at a time, the cooperative pool is never held) and stops at once when the task is cancelled.
            let flag = SeedVerifyFlag()
            let source: SeedingSource? = await withTaskCancellationHandler {
                await withCheckedContinuation { (cont: CheckedContinuation<SeedingSource?, Never>) in
                    Self.verifyQueue.async {
                        let checker = TorrentStorage(meta: meta, workingFolder: FileManager.default.temporaryDirectory.appendingPathComponent("unused-\(UUID().uuidString)"), selected: chosen)          // only for its hash check; touches no disk
                        cont.resume(returning: SeedingSource.rehash(meta: meta, location: location, chosen: chosen, trusted: trustedByRecord, matches: { checker.matches($0, piece: $1) }, cancelled: { flag.isSet },
                                                                    progress: { p in DispatchQueue.main.async { if let run, run.generation == gen { run.verifyProgress = p } } }, baseline: baseline))
                    }
                }
            } onCancel: { flag.set() }
            await MainActor.run {
                guard let self, let run, run.generation == gen else { return }
                run.verifyTask = nil; run.verifyProgress = nil
                guard let source else { run.state = .idle; return }
                run.source = source
                if source.servableCount == 0 { run.state = .ended(SeedStopReason.filesChanged.text); return }
                self.writeResumeRecord(run)
                self.startSeedingIfAllowed(run)
            }
        }
    }

    private nonisolated static let verifyQueue = DispatchQueue(label: "browsersetu.seed.verify", qos: .utility)

    nonisolated static func versionName(_ meta: TorrentMetainfo) -> String { meta.version.rawValue }

    /// Keeps the evidence for the pieces that are servable now: which are verified, and the identity of each file they lie in. Written beside the other saved details of a shared torrent.
    private func writeResumeRecord(_ run: SeedRun) {
        guard let source = run.source, FileManager.default.fileExists(atPath: run.folder.path) else { return }
        let meta = run.meta
        let base = Self.resumeBlob(run.folder).flatMap { ResumeRecord.decode($0, expecting: meta, torrentVersion: Self.versionName(meta), infoHashV2: meta.infoHashV2Hex) }
            ?? ResumeRecord.empty(for: meta, torrentVersion: Self.versionName(meta), infoHashV2: meta.infoHashV2Hex)
        let record = base.bumped(afterVerifying: source.servablePieces, identities: source.resumeIdentities(), meta: meta, isPaddingFile: { meta.files[$0].isPadding }, now: Date(),
                                 uploadedBytes: UInt64(max(0, run.uploaded)), downloadedBytes: UInt64(max(0, run.downloaded)), seedingSeconds: run.seconds, fullyVerified: source.servablePieces.count == meta.pieceCount)
        let blob = record.encoded()
        guard blob.count <= 300_000 else { return }          // the saved details have a smaller cap than the record; too big to keep means the next launch checks the files again
        _ = Self.setResumeBlob(run.folder, blob)
    }

    /// The pieces the saved record vouches for given how the files are now (see `ResumeTrust`); empty when there is nothing to rely on.
    private func trustedPiecesFromRecord(_ run: SeedRun, baseline: [Int: SeedingSource.Identity]) -> Set<Int> {
        let meta = run.meta
        guard let blob = Self.resumeBlob(run.folder), let record = ResumeRecord.decode(blob, expecting: meta, torrentVersion: Self.versionName(meta), infoHashV2: meta.infoHashV2Hex) else { return [] }
        let unchosen = Set(meta.files.map(\.index)).subtracting(run.chosen)
        var now: [Int: TorrentFileIdentity?] = [:]
        for f in meta.files where f.length > 0 && !f.isPadding && !unchosen.contains(f.index) {
            now[f.index] = baseline[f.index].map { TorrentFileIdentity(size: $0.size, mtimeNanos: $0.mtimeSec &* 1_000_000_000 &+ $0.mtimeNsec, inode: $0.inode, device: $0.device) }
        }
        let decision = ResumeTrust.evaluate(record: record, meta: meta, currentIdentities: now, unselectedFiles: unchosen, isPaddingFile: { meta.files[$0].isPadding },
                                            torrentVersion: Self.versionName(meta), infoHashV2: meta.infoHashV2Hex, trustLevel: .identityOnly)
        return decision.trusted
    }

    private func seedConfiguration(for run: SeedRun) -> TorrentSession.SeedingConfig {
        var c = TorrentSession.SeedingConfig()
        c.ratioTarget = run.ratioTarget ?? settings.ratioTarget
        c.timeLimit = run.timeLimit ?? settings.seedTimeLimit
        c.initialSeeding = run.initialSeeding ?? settings.initialSeeding
        c.priorUploaded = run.uploaded; c.priorDownloaded = run.downloaded; c.priorSeconds = run.seconds
        return c
    }

    private func seedPeerCaps() -> (peers: Int, slots: Int) {
        let slots = settings.maxUploadPeers
        return (min(settings.maxPeersPerTorrent, max(10, slots * 3)), slots)
    }

    private func startSeedSession(_ run: SeedRun) {
        guard run.session == nil, let source = run.source else { return }
        let id = run.id, meta = run.meta
        var s = sessionSettings
        let caps = seedPeerCaps()
        s.maxPeers = caps.peers; s.uploadSlots = caps.slots; s.shareWhileDownloading = true
        s.pex = settings.pexEnabled; s.peerFilter = PeerFilter(settings.blockedPeers ?? [])
        s.allowLocalPeers = sessionSettings.allowLocalPeers
        let origin = DownloadRequestOrigin(rawValue: ledger.record(id)?.engineMetadata["origin"] ?? "") ?? .user
        let isPrivate = meta.isPrivate
        if networkSignature.isEmpty { networkSignature = currentNetworkSignature() }
        let granted = localTrackerPermission.granted(isPrivate: isPrivate)
        let peerGrants = origin == .user ? Set(meta.trackers.filter(LocalTrackerPermission.isLocal).map(LocalTrackerPermission.key)) : localTrackerPermission.grantedPeers(isPrivate: isPrivate)
        let trackers = Self.usableTrackers(meta.trackers, origin: origin, granted: granted)
        let usable = Self.usableTiers(meta.trackerTiers, origin: origin, granted: granted)
        pendingRelease[id] = nil
        localTrackerPermission.trust(task: id, keys: Self.trustedKeys(trackers, origin: origin), peers: peerGrants, isPrivate: isPrivate)
        TransferOwnership.shared.assign(id, owner: coordinator.ownerID)          // the profile's overall upload limit governs this torrent
        TorrentBandwidth.upload.setTaskLimit(settings.seedUploadLimit, for: id)
        let session = TorrentSession(infoHash: meta.infoHash, meta: meta, trackers: trackers, trackerTiers: usable.isEmpty ? nil : usable, storage: { nil }, alreadyHave: [],
                                     transports: transports, tracker: tracker, download: nil, upload: TorrentBandwidth.upload, taskID: id, settings: s)
        session.localPeerSources = peerGrants.intersection(trackers.map(LocalTrackerPermission.key))
        session.requestOrigin = origin
        session.localPeerStillAllowed = { [weak self] key in self?.peerSourceStillAllowed(key, task: id) ?? false }
        session.seedSource = source
        session.seedConfig = seedConfiguration(for: run)
        if isPrivate { privateHashes.insert(meta.infoHash) }
        run.session = session; run.state = .seeding
        attachInbound(session, id: id)
        session.onEvent = { [weak self, weak session] event in DispatchQueue.main.async { self?.handleSeedEvent(event, id: id, from: session) } }
        session.start()
        ensureSeedTimer()
    }

    private func handleSeedEvent(_ event: TorrentSession.Event, id: UUID, from session: TorrentSession?) {
        guard case .seedingEnded(let reason) = event, let run = seedRuns[id], run.session != nil, session != nil, run.session === session else { return }
        endSeedSession(run, announceStopped: false)
        run.state = .ended(reason.text)
        setSeedingAuthorized(id, false)          // finished for good: a relaunch does not start it again
    }

    /// Takes the counters from the session, then stops it and gives back everything it held.
    private func endSeedSession(_ run: SeedRun, announceStopped: Bool) {
        run.verifyTask?.cancel(); run.verifyTask = nil; run.generation += 1; run.verifyProgress = nil
        let id = run.id
        if let session = run.session {
            if let snap = session.snapshot.seeding { run.uploaded = snap.uploadedTotal; run.seconds = snap.seconds; run.lastSnapshot = snap }
            run.session = nil
            detachInbound(session, id: id)
            if announceStopped { session.stop() } else { session.stop(sendStoppedAnnounce: false) }
            Self.updateSeedState(run.folder) { $0.uploaded = run.uploaded; $0.seconds = run.seconds }
        }
        run.source?.onRevoked = nil
        PeerBudget.shared.releaseAll(task: id)
        TorrentBandwidth.upload.discard(task: id)
        let token = UUID(); pendingRelease[id] = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self, permission = localTrackerPermission] in
            guard self?.pendingRelease[id] == token else { return }
            self?.pendingRelease[id] = nil; permission.release(task: id)
        }
        stopSeedTimerIfIdle()
    }

    /// The person starts sharing this torrent (the consent text was shown). Needs seeding to be on app-wide.
    @discardableResult
    func startSeeding(_ id: UUID) -> Bool {
        guard settings.seedingMode != .off, let run = seedRuns[id] ?? restoredRun(id) else { return false }
        setSeedingAuthorized(id, true)
        if run.session == nil { startSeedingIfAllowed(run) }
        return true
    }

    /// Withdraws every earlier consent except one (used when sharing is switched on app-wide, so only what the person just chose starts).
    func clearSeedingAuthorization(except keep: UUID) {
        for (id, record) in ledger.records where id != keep && record.engineMetadata["seedAuthorized"] == "1" {
            setSeedingAuthorized(id, false)
            if let run = seedRuns[id], run.session != nil || run.verifyTask != nil { endSeedSession(run, announceStopped: settings.enabled); run.state = .idle }
        }
    }

    private func restoredRun(_ id: UUID) -> SeedRun? {
        guard let record = ledger.record(id), record.protocolID == .bittorrent, record.state == .completed else { return nil }
        return seedRuns[id] ?? restoreSeedRun(id, record)
    }

    /// The person stops sharing this torrent. It stays stopped across launches until they start it again.
    func stopSeeding(_ id: UUID) {
        guard let run = seedRuns[id] else { return }
        endSeedSession(run, announceStopped: true)
        run.state = .stopped
        setSeedingAuthorized(id, false)
    }

    func setSeedLimits(_ id: UUID, ratio: Double?, timeLimit: Double?) {
        guard let run = seedRuns[id] else { return }
        run.ratioTarget = ratio; run.timeLimit = timeLimit
        Self.updateSeedState(run.folder) { $0.ratioTarget = ratio; $0.timeLimit = timeLimit }
        applySeedSettings(run)
    }

    func setInitialSeeding(_ id: UUID, _ on: Bool) {
        guard let run = seedRuns[id] else { return }
        run.initialSeeding = on
        Self.updateSeedState(run.folder) { $0.initialSeeding = on }
        applySeedSettings(run)
    }

    private func applySeedSettings(_ run: SeedRun) {
        guard let session = run.session else { return }
        let caps = seedPeerCaps()
        session.updateSeeding(seedConfiguration(for: run), maxPeers: caps.peers, uploadSlots: caps.slots)
        TorrentBandwidth.upload.setTaskLimit(settings.seedUploadLimit, for: run.id)
    }

    func seedInfo(_ id: UUID) -> SeedingInfo? {
        guard let run = restoredRun(id) else { return nil }
        let snap = run.session?.snapshot
        let s = snap?.seeding ?? run.lastSnapshot
        let uploaded = s?.uploadedTotal ?? run.uploaded
        let size = run.source?.sharedSize ?? run.meta.files.filter { run.chosen.contains($0.index) && !SeedingSource.isPadding($0) }.reduce(0) { $0 + $1.length }
        return SeedingInfo(state: run.state, authorized: seedingAuthorized(id), uploaded: uploaded, downloaded: run.downloaded, ratio: SeedPolicy.ratio(uploaded: uploaded, size: size),
                           seconds: s?.seconds ?? run.seconds, uploadPeers: s?.uploadPeers ?? 0, peers: snap?.peers ?? 0, upRate: snap?.upRate ?? 0, superSeeding: s?.superSeeding ?? false,
                           ratioTarget: run.ratioTarget ?? settings.ratioTarget, timeLimit: run.timeLimit ?? settings.seedTimeLimit, verifyProgress: run.verifyProgress,
                           servablePieces: s?.servablePieces ?? run.source?.servableCount ?? 0, totalPieces: run.meta.pieceCount)
    }

    /// A few seconds apart: the counters are saved, the network rules are looked at again, and a torrent whose download was removed from the list stops being shared.
    private func ensureSeedTimer() {
        guard seedTimer == nil else { return }
        seedTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.seedHousekeeping() } }
    }

    private func stopSeedTimerIfIdle() {
        if !seedRuns.values.contains(where: { if case .paused = $0.state { return true }; return $0.session != nil || $0.verifyTask != nil }) {          // a paused torrent still needs the timer to start again
            seedTimer?.invalidate(); seedTimer = nil
        }
    }

    func seedHousekeeping() {
        for run in Array(seedRuns.values) {
            guard let record = ledger.record(run.id), record.state == .completed else { endSeedSession(run, announceStopped: true); seedRuns[run.id] = nil; continue }
            if let session = run.session {
                if let snap = session.snapshot.seeding { Self.updateSeedState(run.folder) { $0.uploaded = snap.uploadedTotal; $0.seconds = snap.seconds } }
                if let why = seedBlockReason(run.id) { endSeedSession(run, announceStopped: settings.enabled); run.state = .paused(why) }
            } else if case .paused = run.state, run.verifyTask == nil { startSeedingIfAllowed(run) }
        }
        stopSeedTimerIfIdle()
    }

    /// Seeding settings changed (Settings, or the network): running sessions follow at once; off app-wide ends them politely.
    private func seedSettingsChanged() {
        for run in Array(seedRuns.values) {
            if run.session != nil {
                if let why = seedBlockReason(run.id) { endSeedSession(run, announceStopped: settings.enabled); run.state = settings.seedingMode == .off || !seedingAuthorized(run.id) ? .idle : .paused(why); continue }
                applySeedSettings(run)
                if settings.inboundEnabled, let s = run.session { attachInbound(s, id: run.id) }
                if let s = run.session { s.applyLive(pex: settings.pexEnabled, peerFilter: PeerFilter(settings.blockedPeers ?? []), lan: nil, dht: nil) }
            } else if run.verifyTask == nil { if case .ended = run.state { continue }; if run.state == .stopped { continue }; startSeedingIfAllowed(run) }          // a finished or stopped torrent keeps its message
            else if let why = seedBlockReason(run.id) { endSeedSession(run, announceStopped: false); run.state = settings.seedingMode == .off || !seedingAuthorized(run.id) ? .idle : .paused(why) }          // sharing was switched off or revoked while the files were being read back
        }
    }

    func seedNetworkChanged() { for run in seedRuns.values { run.session?.networkChanged() }; seedHousekeeping() }

    // MARK: For the dashboard

    struct Live: Sendable { var snapshot: TorrentSession.Snapshot; var files: Int; var selected: Int; var isPrivate: Bool }

    func live(_ id: UUID) -> Live? {
        guard let session = sessions[id], let storage = storages[id] else { return nil }
        return Live(snapshot: session.snapshot, files: storage.meta.visibleFiles.count, selected: storage.selected.count, isPrivate: storage.meta.isPrivate)
    }
}

/// The BitTorrent engine as the rest of the app sees it: what it can do, declared once. The work is done by `TorrentRunner` (which owns the task's life with the coordinator) and
/// `TorrentSession` (which owns the peers); this type is the contract the registry and the dashboard ask.
enum BitTorrentTransferEngine {
    static let protocolID: DownloadProtocolID = .bittorrent
    /// Pause and resume work from the verified pieces. There is no `resolveMetadata` (a torrent is inspected before it starts) and no `verify` after the fact beyond the final check, which is part of finishing.
    static let capabilities: DownloadEngineCapabilities = [.pause, .resume, .verify, .reportsTotalBytes, .pieces, .multiFile, .upload, .enforcesSpeedLimit]

    /// What the dashboard may say about speed limits for a torrent: they are held where data is read from and sent to each peer, so they are real limits.
    static let enforcement = BandwidthEnforcement.enforced
}


/// A flag one thread sets and another reads (cancels a blocking verification).
final class SeedVerifyFlag: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
