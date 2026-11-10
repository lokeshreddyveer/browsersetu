import CryptoKit
import Foundation

struct PeerAddress: Hashable, Sendable { var host: String; var port: UInt16 }

/// One TCP-like byte stream to a peer. The real one is a `NWConnection`; tests use an in-memory peer. All callbacks come back on the session's queue.
protocol PeerTransport: AnyObject {
    func connect(_ done: @escaping (Error?) -> Void)
    func send(_ data: Data)
    /// One read at a time: the next is not requested until the caller asks, which is what lets a speed limit stop the sender instead of just delaying our attention.
    func receive(_ handler: @escaping (Data?, Error?) -> Void)
    func close()
}

protocol PeerTransportFactory: AnyObject {
    func make(_ address: PeerAddress, queue: DispatchQueue) -> PeerTransport
    /// The same, for a transport that needs the torrent's identity (the encryption handshake does).
    func make(_ address: PeerAddress, infoHash: Data, queue: DispatchQueue) -> PeerTransport
}

struct TrackerReply: Sendable { var peers: [PeerAddress]; var interval: TimeInterval; var warning: String?; var seeders: Int? = nil; var leechers: Int? = nil }

protocol TrackerAnnouncing: AnyObject, Sendable {
    func announce(_ tracker: URL, infoHash: Data, peerID: Data, uploaded: Int64, downloaded: Int64, left: Int64?, event: String?) async throws -> TrackerReply
}

/// Everything one torrent does on the network. One serial queue owns all of its state; nothing here blocks it (hashing and disk work run elsewhere and report back).
///
/// Connections are outgoing only: no port is opened for peers to reach, so there is nothing to attack from outside and nothing to forward. Peers come from the trackers the person's
/// torrent (or magnet link) names, and nowhere else: no DHT, peer exchange or local discovery, which also keeps private torrents inside the tracker's own rules.
final class TorrentSession: @unchecked Sendable {
    enum Event {
        case progress(completedBytes: Int64, totalBytes: Int64)
        case verifiedPiece(index: Int, checksum: String)
        case metadata(TorrentMetainfo)
        case finished
        case failed(String, retryable: Bool)
        /// The choice of files, their priorities or the order changed (to be saved with the task).
        case selectionChanged(TorrentSelection)
        /// A seeding session ended by itself (ratio or time reached, the files changed): peers were told, the tracker hears "stopped".
        case seedingEnded(SeedStopReason)
        /// Piece layers of a version 2 torrent were fetched from peers and checked against the files' roots: to be saved with the torrent.
        case layersInstalled([Data: Data])
    }

    /// What a seeding session (one with a `seedSource`) is held to. Counters carry over from earlier runs so a relaunch continues them.
    struct SeedingConfig: Sendable {
        var ratioTarget: Double?
        var timeLimit: TimeInterval?
        var initialSeeding = false
        /// Initial (super) seeding falls back to normal seeding when more than this many connected peers have shown a complete copy.
        var superSeedFallbackSeeds = 2
        /// A peer is offered another piece after this long even if its last one was not seen elsewhere.
        var superSeedTimeout: TimeInterval = 180
        /// How often the unchoked peers are rotated when more are waiting than there are upload slots.
        var chokeInterval: TimeInterval = 10
        var maxQueuedBlocksPerPeer = 32
        var priorUploaded: Int64 = 0, priorDownloaded: Int64 = 0
        var priorSeconds: TimeInterval = 0
    }

    struct Settings: Sendable {
        var maxPeers = 30
        var uploadSlots = 4
        var shareWhileDownloading = true
        var requestDepth = 8
        var requestTimeout: TimeInterval = 30
        var idleTimeout: TimeInterval = 120
        var handshakeTimeout: TimeInterval = 15
        /// A dial may go through a chain (encrypted, then plain, then the other transport); the session waits this many times one attempt before giving up on the peer.
        var fallbackAttemptFactor: Double = 3
        var maxHashFailuresPerPeer = 3
        var connectRetryLimit = 2
        /// Peers on loopback, private or link-local addresses are ignored unless the torrent's own tracker is on such a network: a tracker cannot send the browser to scan the local network.
        var allowLocalPeers = false
        /// BEP 11 peer exchange and BEP 6 Fast Extension (both on unless turned off); never for a private torrent (PEX).
        var pex = true
        var fastExtension = true
        var preferIPv6 = false
        var peerFilter = PeerFilter()
        /// Peers learned from one PEX message are taken at most this many, and a peer may send one every this many seconds at most.
        var pexInterval: TimeInterval = 60
        /// A magnet link that names trackers is looked up on the public DHT as well (only when the person allowed the DHT) once its own trackers have had this long to lead to a peer with the details. Before,
        /// such a link never used the DHT, so a link whose trackers were dead failed even with the DHT on.
        var dhtFallbackDelay: TimeInterval = 8
        /// A request for a piece of the torrent's details that gets no answer in this time is asked of another peer instead.
        var metadataRequestTimeout: TimeInterval = 8
    }

    struct Snapshot: Sendable {
        var peers = 0, connecting = 0, unchoked = 0
        var verifiedPieces = 0, totalPieces = 0
        var downloaded: Int64 = 0, uploaded: Int64 = 0
        var downRate = 0.0, upRate = 0.0
        var trackers: [String: String] = [:]
        /// One row for each tracker, with its tier and state, for the inspector.
        var trackerRows: [TrackerStatusRow] = []
        var rarestAvailability = 0
        var metadataProgress: Double?
        var recoveryNote: String?
        var dht: DHTStatus?
        var dhtPeers = 0
        /// What the connected peers are, from what the engine actually knows.
        var peersIPv4 = 0, peersIPv6 = 0, fastPeers = 0, pexPeers = 0, peersInbound = 0
        var peersBySource: [String: Int] = [:]          // "tracker", "dht", "pex", "lan": peers connected, by where they were first learned
        var pexAdded = 0
        var connectFailures = 0, policyBlocked = 0
        var lan: LANStatus?
        var inbound: PeerListenerStatus?
        /// DX-05: how pieces are being picked, whether the last stretch (duplicate requests) is on, and the web seeds.
        var mode: ScheduleMode = .automatic
        var endgame = false
        var duplicateRequests = 0
        var webSeeds: [WebSeedStatusRow] = []
        var selectedFiles = 0, totalFiles = 0
        /// Set only for a seeding session.
        var seeding: SeedingSnapshot?
    }

    // MARK: Inputs
    let infoHash: Data
    let peerID: Data
    private(set) var meta: TorrentMetainfo?
    private let trackers: [URL]
    private let storage: () -> TorrentStorage?
    private let alreadyHave: Set<Int>
    private let transports: PeerTransportFactory
    private let tracker: TrackerAnnouncing
    private let down: BandwidthController?
    private let up: BandwidthController?
    private let taskID: UUID
    private var settings: Settings
    private let isPrivate: Bool
    let queue: DispatchQueue
    private let io = DispatchQueue(label: "browsersetu.torrent.io", qos: .utility)
    var onEvent: ((Event) -> Void)?

    // MARK: State (queue-confined)
    private final class Peer {
        let id: Int
        let address: PeerAddress
        let transport: PeerTransport
        var handshaken = false
        var startedAt: TimeInterval
        var buffer = Data()
        var parser: PeerWire.Parser?
        var theyChokeUs = true, weChokeThem = true, weAreInterested = false, theyAreInterested = false
        var supportsExtensions = false
        var theirMetadataID: UInt8?
        var theirMetadataSize: Int?
        var lastReceived: TimeInterval
        var lastSent: TimeInterval
        var closed = false
        var hashFailures = 0
        var supportsFast = false
        var theirPexID: UInt8?
        var allowedFastForUs = Set<Int>(), allowedFastForThem = Set<Int>(), suggested = Set<Int>()
        var rejectedPieces: [Int: TimeInterval] = [:]
        var lastPexSent: TimeInterval = 0, lastPexReceived: TimeInterval = -1e9
        var pexSent = Set<PeerAddress>()
        var firstSource = "tracker"
        var bytesFrom: Int64 = 0
        var inbound = false
        /// Hash requests (BEP 52) this peer may still make: a small bucket that refills one a second.
        var hashTokens = 4.0, hashTokensAt: TimeInterval = 0, hashDrops = 0
        // Seeding (DX-06)
        struct Block: Hashable { var index: Int, begin: Int, length: Int }
        var queuedBlocks = Set<Block>()
        var unchokedAt: TimeInterval = 0
        var interestedSince: TimeInterval = 0
        var badRequests = 0
        var bytesTo: Int64 = 0
        var theirPieces: PieceBits?
        var offered: Int?
        var offeredAt: TimeInterval = 0
        var servedPieces = Set<Int>()
        var isComplete = false
        init(id: Int, address: PeerAddress, transport: PeerTransport, now: TimeInterval) { self.id = id; self.address = address; self.transport = transport; startedAt = now; lastReceived = now; lastSent = now }
    }

    private var peers: [Int: Peer] = [:]
    private var nextPeerID = 1
    private var candidates: [PeerAddress] = []
    private var tried: [PeerAddress: Int] = [:]
    private var banned = Set<PeerAddress>()
    private var records: [PeerAddress: PeerRecord] = [:]
    /// Which connected peers vouched for an address through PEX (by peer id): a "dropped" from one of them takes away only that one's word, and the address goes only when nobody vouches any more.
    private var pexVouchers: [PeerAddress: Set<Int>] = [:]
    private var connectFailures = 0, policyBlocked = 0, pexAdded = 0
    /// BEP 27: a torrent is private if its (now known) metadata says so.
    private var privateNow: Bool { isPrivate || meta?.isPrivate == true }
    /// Peer exchange needs a connected peer, known metadata, a public torrent and the setting; it never starts for a magnet whose privacy is not yet known.
    private var pexAllowed: Bool { settings.pex && !privateNow && meta != nil }
    /// Where each peer address was learned (tracker destination keys, "dht", "dht-local"): what lets a revoked permission or a private flag take away only the peers that depended on it.
    private var peerSources: [PeerAddress: Set<String>] = [:]
    private var dhtAcquired = false, dhtActive = false, dhtHandle: DHTLookupHandle?, dhtLookupAt: TimeInterval = -1e9
    private(set) var dhtPeersFound = 0
    private var dhtReacquireAt: TimeInterval = 0
    private var picker: TorrentPicker?
    // MARK: Selection and web seeds (DX-05)
    /// The person's choice of files and priorities, set by the runner before `start` (nil: the files the storage has chosen, all at Normal).
    var initialSelection: TorrentSelection?
    /// The full SHA-256 a version 2 magnet link promised, so metadata fetched from peers is checked against it (the 20 bytes used on the wire are only a prefix).
    var expectedInfoHashV2: Data?
    /// Version 2: hash requests sent to peers for piece layers we do not have yet, and the verified runs received so far (by pieces root, then index).
    private var layerAsked: [String: TimeInterval] = [:]
    private var layerRuns: [Data: [Int: [Data]]] = [:]
    private var layersAskedAt: TimeInterval = 0
    /// False for a torrent the person chose to download from its web seeds only (HTTP): no tracker, DHT, local discovery, peer connection or incoming connection is started, and nothing is
    /// announced. Everything else (the pieces, their checks, priorities, the files) is the same.
    var peerNetworkEnabled = true
    private var selection: TorrentSelection?
    /// Fetches pieces from web seeds; nil means web seeds are not used (none, or the tests that do not want them).
    var webSeedFetcher: WebSeedFetching?
    /// Web seed addresses a magnet link carried (`ws=`), used as well as the torrent's own.
    var magnetWebSeeds: [URL] = []
    private var seeds: [WebSeedState] = []
    private var seedTasks: [Int: Task<Void, Never>] = [:]
    /// A change of the choice is being carried out (storage first, then the picker): another waits, so the two can never disagree.
    private var selecting = false
    /// At most this many web seed requests at once, so a long list cannot open a flood of connections.
    static let maxSeedRequests = 4
    private var running = false
    private var finishing = false
    private var timer: DispatchSourceTimer?
    /// The trackers in their tiers, and everything known about each (BEP 12). One announce at a time for each tier.
    private var book: TrackerBook
    private var completedAtStart = false
    /// The announces in flight, so stopping the torrent stops them (a UDP tracker may otherwise keep waiting and resending).
    private var announceTasks: [URL: Task<Void, Never>] = [:]
    private var downloaded: Int64 = 0, uploaded: Int64 = 0
    private var rateMark: (at: TimeInterval, down: Int64, up: Int64)?
    private var downRate = 0.0, upRate = 0.0
    private var waitingReads = Set<Int>()
    private var metadataBuffer: Data?
    private var metadataGot = Set<Int>()
    private var metadataRequested: [Int: Int] = [:]          // piece -> peer
    private var metadataRequestedAt: [Int: TimeInterval] = [:]
    /// Peers that refused or ignored a piece request: not asked for that piece again.
    private var metadataRefusedBy: [Int: Set<Int>] = [:]
    private var firstTickAt: TimeInterval?
    private var lastTickAt: TimeInterval = 0
    private var metadataSenders: [Int: PeerAddress] = [:]     // piece -> who sent it
    private var wrote = Set<Int>()
    private var notedProgress: Int64 = -1
    private var recoveryNote: String?
    private var uploadsWaiting = 0
    /// Set when the session is stopped because peer-to-peer was turned off.
    private var silent = false
    /// The "completed" announces, run one after another; a "stopped" waits behind them so the tracker hears the two in order.
    private var completionTask: Task<Void, Never>?
    private var scrapeTasks: [URL: Task<Void, Never>] = [:]

    // MARK: Seeding state (DX-06)
    /// Set before `start` to make this a seeding session: the verified bytes are read from their final place and the download machinery is idle. Never set for a download.
    var seedSource: SeedingSource?
    var seedConfig = SeedingConfig()
    private var seeding: Bool { seedSource != nil }
    private var seedStart: TimeInterval = 0
    private var superSeeding = false
    private var superSeedFellBack: String?
    private var superSeen: [Int: Set<Int>] = [:]          // piece -> peers (ids) that reported having it
    private var offerCount: [Int: Int] = [:]
    private var completeSeen = 0
    private var lastChokeRound: TimeInterval = 0
    private var seedEnded = false
    private var seedElapsedAtStop: TimeInterval = 0
    private var lastAudit: TimeInterval = -1e9

    init(infoHash: Data, meta: TorrentMetainfo?, trackers: [URL], trackerTiers: [[URL]]? = nil, storage: @escaping () -> TorrentStorage?, alreadyHave: Set<Int>, transports: PeerTransportFactory, tracker: TrackerAnnouncing,
         download: BandwidthController?, upload: BandwidthController?, taskID: UUID, settings: Settings = Settings(), queue: DispatchQueue = DispatchQueue(label: "browsersetu.torrent.session")) {
        self.infoHash = infoHash; self.meta = meta; self.trackers = trackers; book = TrackerBook(tiers: trackerTiers ?? trackers.map { [$0] }); self.storage = storage; self.alreadyHave = alreadyHave; self.transports = transports; self.tracker = tracker
        down = download; up = upload; self.taskID = taskID; self.settings = settings; self.queue = queue
        isPrivate = meta?.isPrivate ?? false
        var id = Data("-BS0001-".utf8); id.append(contentsOf: (0..<12).map { _ in UInt8.random(in: 0...255) })
        peerID = id
    }

    /// Runs a tracker request with this session's identity attached, so the network layer applies this task's own approvals and its origin's rules.
    private func scoped<T>(_ work: @escaping () async throws -> T) async throws -> T {
        let id = taskID, origin = requestOrigin
        let st = inboundStatus?()
        let port: UInt16 = (st?.state == .listening) ? (st?.announcePort ?? 0) : 0
        return try await TrackerScope.$task.withValue(id) { try await TrackerScope.$origin.withValue(origin) { try await TrackerScope.$listenPort.withValue(port) { try await work() } } }
    }

    private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: Lifecycle

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            if let seed = seedSource {
                guard let meta else { running = false; return }
                picker = TorrentPicker(meta: meta, needed: [], alreadyHave: seed.servablePieces, selected: [])
                seedStart = now()
                superSeeding = seedConfig.initialSeeding && seed.servablePieces.count == meta.pieceCount          // only with the whole torrent verified
                seed.onRevoked = { [weak self] in self?.queue.async { self?.seedFilesChanged() } }
                let t = DispatchSource.makeTimerSource(queue: queue)
                t.schedule(deadline: .now() + 0.2, repeating: 1.0, leeway: .milliseconds(200))
                t.setEventHandler { [weak self] in self?.tick() }
                timer = t; t.resume()
                completedAtStart = true
                tick()
                return
            }
            if let meta, let storage = storage() {
                let chosen = (initialSelection ?? TorrentSelection.only(storage.selected, in: meta)).normalized(for: meta)
                selection = chosen
                let plan = TorrentPlan(chosen, meta: meta)
                picker = TorrentPicker(meta: meta, needed: plan.needed, alreadyHave: alreadyHave, selected: plan.selected, weights: plan.weights, order: Self.order(for: plan, meta: meta))
                seeds = webSeedFetcher == nil ? [] : WebSeedMapping.sources(meta: meta, magnetSeeds: magnetWebSeeds).map { WebSeedState(source: $0) }
                reportProgress(force: true)
            }
            // The timer runs even when everything is already marked done: the final check may find damage, and then peers are needed again.
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 0.2, repeating: 1.0, leeway: .milliseconds(200))
            t.setEventHandler { [weak self] in self?.tick() }
            timer = t; t.resume()
            completedAtStart = picker?.isComplete == true
            if picker?.isComplete == true { finalCheck(); return }
            tick()
        }
    }

    /// Stops everything. Called for pause, cancel and failure alike; the caller decides what the files should become.
    /// `sendStoppedAnnounce: false` is for peer-to-peer being turned off: nothing at all goes out to a tracker then, not even the courtesy "stopped" or a "completed" still waiting.
    func stop(sendStoppedAnnounce: Bool = true, completion: (() -> Void)? = nil) {
        queue.async { [self] in
            stopNow(sendStoppedAnnounce: sendStoppedAnnounce)
            io.async { completion?() }          // behind any piece still being written
        }
    }

    private func stopNow(sendStoppedAnnounce: Bool) {
        if running, seeding { seedElapsedAtStop = max(0, now() - seedStart) }
        running = false
        silent = !sendStoppedAnnounce
        timer?.cancel(); timer = nil
        for task in announceTasks.values { task.cancel() }
        announceTasks = [:]
        for task in scrapeTasks.values { task.cancel() }
        scrapeTasks = [:]
        for task in seedTasks.values { task.cancel() }
        seedTasks = [:]
        stopDHT(); stopLAN()
        if silent { completionTask?.cancel() }
        sendStopped()
        book.abandonAll()
        // A seeding peer is told it is choked before the connection goes, and what it was waiting for is dropped.
        for peer in peers.values { if seeding, peer.handshaken, !peer.weChokeThem { sendRaw(PeerWire.encode(.choke), to: peer) }; peer.queuedBlocks = [] }
        for peer in Array(peers.values) { drop(peer, reason: nil) }
        peers = [:]
        seedSource?.onRevoked = nil
    }

    var snapshot: Snapshot {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync {
            var s = Snapshot()
            s.peers = peers.values.filter(\.handshaken).count; s.connecting = peers.values.filter { !$0.handshaken }.count
            s.unchoked = peers.values.filter { !$0.theyChokeUs }.count
            s.verifiedPieces = picker?.verifiedPieces ?? 0; s.totalPieces = meta?.pieceCount ?? 0
            s.downloaded = downloaded; s.uploaded = uploaded; s.downRate = downRate; s.upRate = upRate
            s.trackerRows = book.statuses(at: now())
            s.trackers = Dictionary(s.trackerRows.map { ($0.name, $0.state.rawValue + ($0.lastError.map { ": \($0)" } ?? "")) }, uniquingKeysWith: { a, _ in a })
            s.rarestAvailability = picker?.availabilitySummary.rarest ?? 0
            if let m = metadataBuffer, let total = metadataTotal { s.metadataProgress = Double(metadataGot.count * PeerWire.metadataPieceSize) / Double(max(total, 1)); _ = m }
            s.recoveryNote = recoveryNote
            let live = peers.values.filter { $0.handshaken }
            s.peersIPv6 = live.filter { $0.address.isIPv6 }.count; s.peersIPv4 = live.count - s.peersIPv6
            s.fastPeers = live.filter { $0.supportsFast }.count; s.peersInbound = live.filter { $0.inbound }.count
            s.pexPeers = live.filter { $0.theirPexID != nil }.count
            for p in live {
                let labels = Set((peerSources[p.address] ?? ["tracker"]).map { $0.hasPrefix("dht") ? "dht" : ($0 == "pex" ? "pex" : ($0 == "lpd" ? "lan" : ($0 == "inbound" ? "inbound" : "tracker"))) })
                for l in labels { s.peersBySource[l, default: 0] += 1 }
            }
            s.pexAdded = pexAdded; s.connectFailures = connectFailures; s.policyBlocked = policyBlocked
            if dht != nil, dhtWanted { s.dht = dht?.status; s.dhtPeers = dhtPeersFound }
            if lan != nil, meta != nil, !privateNow { s.lan = lan?.status }
            s.inbound = inboundStatus?()
            s.mode = selection?.mode ?? .automatic
            s.endgame = picker?.isEndgame ?? false
            s.duplicateRequests = picker?.duplicateRequestsSent ?? 0
            s.webSeeds = seeds.map { st in
                WebSeedStatusRow(id: st.source.kind.rawValue + st.source.displayName, name: st.source.displayName, kind: st.source.kind.rawValue,
                                 state: st.disabled != nil ? "Not used" : (st.inFlight != nil ? "Receiving" : (st.retryAt > now() ? "Waiting" : "Ready")), bytes: st.bytes, pieces: st.pieces, lastError: st.disabled ?? st.lastError)
            }
            if let meta { s.totalFiles = meta.visibleFiles.count; s.selectedFiles = selection?.selected(in: meta).count ?? 0 }
            if let seed = seedSource {
                var x = SeedingSnapshot()
                x.uploadedTotal = seedConfig.priorUploaded + uploaded
                x.seconds = seedConfig.priorSeconds + (running ? max(0, now() - seedStart) : seedElapsedAtStop)
                x.ratio = SeedPolicy.ratio(uploaded: x.uploadedTotal, size: seed.sharedSize)
                x.uploadPeers = peers.values.filter { $0.handshaken && !$0.weChokeThem }.count
                x.superSeeding = superSeeding; x.superSeedFellBack = superSeedFellBack
                x.servablePieces = seed.servableCount; x.unavailablePieces = (meta?.pieceCount ?? 0) - x.servablePieces
                x.completePeersSeen = completeSeen
                s.seeding = x
                s.downloaded = seedConfig.priorDownloaded
            }
            return s
        }
    }

    // MARK: Ticking

    private func tick() {
        guard running, !finishing else { return }
        let t = now()
        if firstTickAt == nil { firstTickAt = t }
        lastTickAt = t
        updateRates(t)
        if seeding { seedTick(t); guard running else { return } }
        // handshakes, silence and slow requests
        for peer in Array(peers.values) {
            if !peer.handshaken, t - peer.startedAt > (peer.inbound ? settings.handshakeTimeout : settings.handshakeTimeout * settings.fallbackAttemptFactor) { records[peer.address, default: PeerRecord()].failed(at: t); drop(peer, reason: "handshake timeout"); continue }
            if peer.handshaken, t - peer.lastReceived > settings.idleTimeout { drop(peer, reason: "silent"); continue }
            if peer.handshaken, t - peer.lastSent > 60 { send(.keepAlive, to: peer) }
        }
        if let picker {
            for id in picker.expire(olderThan: settings.requestTimeout, now: t) {
                if id < 0 { seedTimedOut(-id - 1) } else if let p = peers[id] { fill(p) }
            }
            flushCancels()
        }
        webSeedTick()
        guard peerNetworkEnabled else { return }
        if meta?.version != .v1, meta != nil, t - layersAskedAt > 10, let storage = storage(), !storage.missingLayerRoots.isEmpty { layersAskedAt = t; for p in peers.values where p.handshaken { requestLayers(from: p) } }
        announceIfDue(t)
        retryMetadata(t)
        revalidateLocalPeers()
        sendPex(t)
        pruneRecords(t)
        dhtTick(t)
        lanTick()
        connectMore()
    }

    private func updateRates(_ t: TimeInterval) {
        if let mark = rateMark, t - mark.at >= 1 {
            let dt = t - mark.at
            downRate = 0.6 * downRate + 0.4 * Double(downloaded - mark.down) / dt
            upRate = 0.6 * upRate + 0.4 * Double(uploaded - mark.up) / dt
            rateMark = (t, downloaded, uploaded)
        } else if rateMark == nil { rateMark = (t, downloaded, uploaded) }
    }

    // MARK: Trackers

    private var left: Int64? {
        if seeding { return 0 }          // a seeder has everything it shares
        guard let picker, let storage = storage() else { return nil }
        return max(0, storage.selectedBytes - picker.completedBytes)
    }

    private func announceIfDue(_ t: TimeInterval) {
        guard running else { return }
        // For each tier with nothing in flight and its time come: one announce, to the first endpoint of the tier that is not waiting out a failure.
        for plan in book.due(at: t) {
            let (tier, url, event) = plan
            book.began(tier: tier, url: url)
            let (up, dn, remaining) = (uploaded, downloaded, left ?? 1)          // unknown (a magnet's details are still being fetched) is never reported as 0, which would claim to be a seeder
            announceTasks[url] = Task { [self] in
                do {
                    let tr = tracker, hash = infoHash, pid = peerID
                    let reply = try await scoped { try await tr.announce(url, infoHash: hash, peerID: pid, uploaded: up, downloaded: dn, left: remaining, event: event) }
                    queue.async { [self] in
                        announceTasks[url] = nil
                        guard running else { return }
                        book.answered(tier: tier, url: url, interval: max(60, min(reply.interval, 3600)), seeders: reply.seeders, leechers: reply.leechers, event: event, at: now())
                        let key = LocalTrackerPermission.key(url)
                        addCandidates(reply.peers, fromLocalTracker: localPeerSources.contains(key), source: key)
                        connectMore()
                    }
                } catch {
                    queue.async { [self] in
                        announceTasks[url] = nil
                        guard running else { return }          // stopped while it waited: nothing more is scheduled
                        if case UDPTrackerClient.Failure.busy = error { book.postponed(tier: tier, url: url, delay: 15, at: now()) }          // our own limit, not the tracker's failure
                        else { book.failed(tier: tier, url: url, reason: Self.describe(error), unsupported: Self.isUnsupported(error), needsSettings: Self.isProxyProblem(error), at: now()) }
                    }
                }
            }
        }
    }

    /// The torrent has been downloaded: each tracker that heard `started` hears `completed`, once, each on a request of its own that gives up after five seconds. Not sent for a torrent that was
    /// already complete when it began, and not at all once peer-to-peer has been turned off.
    private func announceCompleted() {
        guard peerNetworkEnabled else { return }
        guard !completedAtStart, !silent, completionTask == nil else { return }
        let targets = book.completionTargets()
        guard !targets.isEmpty else { return }
        targets.forEach { book.markCompletedSent($0) }
        let t = tracker, hash = infoHash, id = peerID, up = uploaded, dn = downloaded, task = taskID, origin = requestOrigin
        completionTask = Task.detached {
            for url in targets {
                if Task.isCancelled { return }
                await Self.bounded(seconds: 5) { _ = try? await TrackerScope.$task.withValue(task) { try await TrackerScope.$origin.withValue(origin) { try await t.announce(url, infoHash: hash, peerID: id, uploaded: up, downloaded: dn, left: 0, event: "completed") } } }
            }
        }
    }

    /// Runs `work`, giving up on it after `seconds` (or when the caller is cancelled).
    static func bounded(seconds: Double, _ work: @escaping @Sendable () async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await work() }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            await group.next()
            group.cancelAll()
        }
    }

    /// The torrent has stopped: each tracker that heard `started` hears `stopped`, once, after any `completed` has been sent, on a request that gives up after five seconds (the sockets are not held
    /// open for it). When peer-to-peer was turned off the trackers are only forgotten, not contacted.
    private func sendStopped() {
        guard peerNetworkEnabled else { return }
        let targets = book.stopTargets()
        guard !silent, !targets.isEmpty else { return }
        let t = tracker, hash = infoHash, id = peerID, completion = completionTask, task = taskID, origin = requestOrigin
        let (up, dn, remaining) = (uploaded, downloaded, left ?? 1)
        Task.detached {
            await completion?.value
            await withTaskGroup(of: Void.self) { group in
                for url in targets { group.addTask { await Self.bounded(seconds: 5) { _ = try? await TrackerScope.$task.withValue(task) { try await TrackerScope.$origin.withValue(origin) { try await t.announce(url, infoHash: hash, peerID: id, uploaded: up, downloaded: dn, left: remaining, event: "stopped") } } } } }
            }
        }
    }

    /// Asks the trackers for their counts. Only on request (the inspector's button): never as part of downloading. One request for each tier at most, and not again within a minute.
    func scrapeNow() {
        guard peerNetworkEnabled else { return }
        queue.async { [self] in
            guard running, let scraper = tracker as? TrackerScraping else { return }
            let t = now()
            for url in book.scrapeTargets(at: t) {
                book.scrapeStarted(url, at: t)
                scrapeTasks[url] = Task { [self] in
                    do {
                        let hash = infoHash
                        let result = try await scoped { try await scraper.scrape(url, infoHash: hash) }
                        queue.async { [self] in scrapeTasks[url] = nil; guard running else { return }; book.scraped(url, result, at: now()) }
                    } catch {
                        queue.async { [self] in scrapeTasks[url] = nil; guard running else { return }; book.scrapeFailed(url, note: Self.describe(error), at: now()) }
                    }
                }
            }
        }
    }

    /// A failure only the person can cure, in Settings: their proxy choice cannot carry this request.
    static func isProxyProblem(_ error: Error) -> Bool {
        if case UDPTrackerClient.Failure.proxy = error { return true }
        if case HTTPTrackerClient.Failure.proxy = error { return true }
        return false
    }

    static func describe(_ error: Error) -> String { (error as? LocalizedError)?.errorDescription ?? "unreachable" }

    /// A failure that retrying will not cure for this endpoint: it is not that kind of tracker. (A blocked address or a proxy that cannot be used can be put right by the person, so those are retried with the usual wait.)
    static func isUnsupported(_ error: Error) -> Bool {
        if case UDPTrackerClient.Failure.unsupported = error { return true }
        if case HTTPTrackerClient.Failure.unsupportedScheme = error { return true }
        return false
    }

    /// Tracker destinations a person allowed a page to use: peers on the local network are taken only from these (never from another tracker's list).
    var localPeerSources: Set<String> = []
    /// Where the request came from (a page's request is held to stricter network rules); set before `start`.
    var requestOrigin: DownloadRequestOrigin = .user
    /// Whether a local-network peer learned from this source may still be used (the person's approval can be taken back while a download runs).
    var localPeerStillAllowed: (String) -> Bool = { _ in true }
    /// The DHT, when the person allows it. Never used for a private torrent (BEP 27).
    var dht: DHTDiscovering?
    /// Local Service Discovery (BEP 14), when the person has allowed it. Never used for a private torrent, and only once the torrent's details are known.
    var lan: LANDiscovering?
    /// What the app's listener is doing, for the inspector (set when incoming connections are allowed).
    var inboundStatus: (() -> PeerListenerStatus)?
    private var lanRegistered = false
    private var lanRetryAt: TimeInterval = 0

    func addCandidates(_ addresses: [PeerAddress], fromLocalTracker: Bool = false, source: String? = nil) {
        guard peerNetworkEnabled else { return }
        queue.async { [self] in
            for original in addresses {
                let a = original.canonical
                guard !settings.peerFilter.blocks(a.host) else { continue }          // the person's own list of addresses never to connect to
                let isLocal = HTTPRequestPolicy.classify(host: a.host).isInternal
                guard !isLocal || settings.allowLocalPeers || fromLocalTracker else { continue }
                if peerSources.count >= 2000 { peerSources = peerSources.filter { e in candidates.contains(e.key) || peers.values.contains { $0.address == e.key } }; pexVouchers = pexVouchers.filter { peerSources[$0.key] != nil } }
                let tracked = candidates.contains(a) || peers.values.contains(where: { $0.address == a })
                // The source is remembered only for an address that is (or already was) taken, and the record is bounded.
                if let source, tracked || (candidates.count < 500 && !banned.contains(a)), peerSources[a] != nil || peerSources.count < 2000 || fromLocalTracker { peerSources[a, default: []].insert(source) }
                guard candidates.count < 500, !banned.contains(a), !tracked, a.port != 0, !a.host.isEmpty else { continue }
                candidates.append(a)
            }
            connectMore()
        }
    }

    /// Settings that are meant to take effect at once, for a torrent already running: PEX on or off, the people's list of blocked addresses, and whether the DHT and local discovery may be used.
    /// What a switch-off takes away is only what depended on it (see `peerPermitted`, `forgetSource`); everything else keeps going.
    func applyLive(pex: Bool, peerFilter: PeerFilter, lan: LANDiscovering?, dht: DHTDiscovering?) {
        guard peerNetworkEnabled else { return }          // a web-seed-only torrent never joins the peer networks, whatever the settings say
        queue.async { [self] in
            settings.pex = pex; settings.peerFilter = peerFilter
            if !pex { forgetSource("pex") }
            if lan == nil { stopLAN(); forgetSource("lpd") }
            self.lan = lan
            if dht == nil { stopDHT() }
            self.dht = dht
            revalidateLocalPeers()
            connectMore()
        }
    }

    /// The network setup changed (a proxy chosen or removed, the metered-network choices): connections made under the old one are closed, and candidates are tried again under the new one. Verified pieces stay.
    func networkChanged() {
        queue.async { [self] in
            for p in Array(peers.values) { drop(p, reason: "the network settings changed", retry: true) }
        }
    }

    /// A local-network peer is used only while something still authorises it: the person's own setting, or a source whose approval stands. Looked at before every connection and every second.
    private func peerPermitted(_ a: PeerAddress) -> Bool {
        guard HTTPRequestPolicy.classify(host: a.host).isInternal, !settings.allowLocalPeers else { return true }
        return (peerSources[a] ?? []).contains { localPeerStillAllowed($0) }
    }

    /// Takes away the candidates and connections that depended only on an approval that is gone. A peer another valid source also named stays.
    private func revalidateLocalPeers() {
        for a in candidates where !peerPermitted(a) { peerSources[a] = nil }
        candidates.removeAll { !peerPermitted($0) }
        for peer in Array(peers.values) where !peerPermitted(peer.address) { drop(peer, reason: "permission was removed") }
        for peer in Array(peers.values) where settings.peerFilter.blocks(peer.address.host) { drop(peer, reason: "the address is blocked") }
    }

    /// The DHT is not (or no longer) allowed for this torrent: what only it supplied goes, what a tracker also supplied stays.
    private func forgetSource(_ name: String) {
        for (a, s) in peerSources where s.contains(name) || (name == "dht" && s.contains("dht-local")) {
            var rest = s; rest.remove(name)
            // "dht-local" (a node the person configured on their own network) is the same source as "dht".
            if name == "dht" { rest.remove("dht-local") }
            peerSources[a] = rest.isEmpty ? nil : rest
            if name == "pex" { pexVouchers[a] = nil }
            if rest.isEmpty { candidates.removeAll { $0 == a }; for peer in Array(peers.values) where peer.address == a { drop(peer, reason: "its source is not allowed") } }
        }
    }

    // MARK: DHT

    /// Public discovery is for a torrent known not to be private. A magnet whose details are not yet known may use it only when it names no tracker (there is nothing else to find peers with) and the
    /// person has allowed the DHT: trackers are preferred, and a magnet that names some is not looked up on the public network before its details show whether it is private (BEP 27).
    private var dhtWanted: Bool {
        guard dht != nil, !isPrivate else { return false }
        if meta != nil || trackers.isEmpty { return true }
        // A magnet that names trackers: they are tried first. If they have not led to the details after a few seconds, the public DHT joins in (the person has allowed it), unless a tracker address looks like a
        // private tracker's (it carries a personal key): then the torrent may be private (BEP 27) and its hash is not put on the public network. A torrent that turns out private has its DHT peers forgotten.
        return lastTickAt - (firstTickAt ?? lastTickAt) >= settings.dhtFallbackDelay && !trackers.contains(where: Self.looksLikePrivateTracker)
    }

    /// A tracker address with a personal key in it (a query such as passkey=, or a long token in the path) belongs to a private tracker.
    static func looksLikePrivateTracker(_ url: URL) -> Bool {
        let keys: Set<String> = ["passkey", "authkey", "torrent_pass", "uid", "pid", "token", "key", "secret"]
        if URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { keys.contains($0.name.lowercased()) }) == true { return true }
        return url.pathComponents.contains { $0.count >= 24 && $0.allSatisfy { $0.isLetter || $0.isNumber } && $0.lowercased() != "announce" }
    }

    private func dhtTick(_ t: TimeInterval) {
        guard let dht, dhtWanted, running, !finishing else { if dhtAcquired { stopDHT() }; return }
        if picker?.isComplete == true { if dhtAcquired { stopDHT() }; return }
        if !dhtAcquired { dht.acquire(taskID); dhtAcquired = true; dhtReacquireAt = t }
        else if [.blocked, .off].contains(dht.status.state), t - dhtReacquireAt >= 30 { dht.acquire(taskID); dhtReacquireAt = t }          // it was switched off and has been allowed again: start it
        guard !dhtActive, t - dhtLookupAt >= (peers.count < 5 ? 60 : 900) else { return }
        dhtActive = true; dhtLookupAt = t
        dhtHandle = dht.lookupPeers(infoHash: infoHash, task: taskID, onPeers: { [weak self] found, local in
            self?.queue.async {
                guard let self, self.running, self.dhtWanted else { return }
                self.dhtPeersFound += found.count
                self.addCandidates(found, fromLocalTracker: local, source: local ? "dht-local" : "dht")
            }
        }, onFinish: { [weak self] in self?.queue.async { self?.dhtActive = false } })
    }

    private func lanTick() {
        guard let lan, meta != nil, !privateNow, running, !finishing, picker?.isComplete != true else { if lanRegistered { stopLAN() }; return }
        if lanRegistered {
            // Stopped by a policy change (or could not start): asked again now and then, so it comes back when it is allowed again.
            let t = now()
            if [.blocked, .unavailable].contains(lan.status.state), t - lanRetryAt >= 30 { lanRetryAt = t; lanRegistered = false } else { return }
        }
        lanRegistered = true
        lan.register(task: taskID, infoHash: infoHash) { [weak self] found in
            self?.queue.async {
                guard let self, self.running, !self.privateNow else { return }
                self.addCandidates(found, fromLocalTracker: true, source: "lpd")
            }
        }
    }

    private func stopLAN() { if lanRegistered { lan?.unregister(task: taskID); lanRegistered = false } }

    private func stopDHT() {
        dhtHandle?.cancel(); dhtHandle = nil; dhtActive = false
        if dhtAcquired { dht?.release(taskID); dhtAcquired = false }
    }

    // MARK: Connecting

    /// The best candidate that may be tried now: not waiting out a failure, then the one with the best record, an IPv6 address first only if the person prefers them.
    private func bestCandidate(_ t: TimeInterval) -> Int? {
        var best: (index: Int, key: (Double, Int))?
        for (i, a) in candidates.enumerated() {
            let r = records[a] ?? PeerRecord()
            guard r.nextAttempt <= t else { continue }
            let key = (r.score, (a.isIPv6 == settings.preferIPv6) ? 1 : 0)
            if best == nil || key.0 > best!.key.0 || (key.0 == best!.key.0 && key.1 > best!.key.1) { best = (i, key) }
        }
        return best?.index
    }

    private func pruneRecords(_ t: TimeInterval) {
        if records.count > 2000 {
            for (a, r) in records.sorted(by: { $0.value.lastAttempt < $1.value.lastAttempt }).prefix(500) where !candidates.contains(a) && !peers.values.contains(where: { $0.address == a }) { records[a] = nil }
        }
        // A candidate that keeps failing is given up on.
        candidates.removeAll { (records[$0]?.failures ?? 0) > settings.connectRetryLimit + 3 }
    }

    private func connectMore() {
        guard running, !finishing, peerNetworkEnabled else { return }
        if picker?.isComplete == true, !seeding { return }
        candidates.removeAll { !peerPermitted($0) || settings.peerFilter.blocks($0.host) }
        let t = now()
        while peers.count < settings.maxPeers, !candidates.isEmpty, let pick = bestCandidate(t), PeerBudget.shared.acquire(task: taskID) {
            let address = candidates.remove(at: pick)
            tried[address, default: 0] += 1
            records[address, default: PeerRecord()].lastAttempt = t
            let peer = Peer(id: nextPeerID, address: address, transport: transports.make(address, infoHash: infoHash, queue: queue), now: t)
            nextPeerID += 1
            peers[peer.id] = peer
            peer.transport.connect { [weak self, weak peer] error in
                guard let self, let peer else { return }
                self.queue.async {
                    guard !peer.closed else { return }
                    if let error {
                        // Our own refusal (a proxy that cannot carry the connection) says nothing about the peer.
                        if TorrentSession.isProxyProblem(error) { self.policyBlocked += 1; self.drop(peer, reason: "connect: \(error.localizedDescription)", retry: false); return }
                        self.connectFailures += 1
                        self.records[peer.address, default: PeerRecord()].failed(at: self.now())
                        self.drop(peer, reason: "connect: \(error.localizedDescription)", retry: true); return
                    }
                    self.sendRaw(PeerWire.handshake(infoHash: self.infoHash, peerID: self.peerID, extensions: self.meta == nil || self.pexAllowed, fast: self.settings.fastExtension), to: peer)
                    self.readNext(peer)
                }
            }
        }
    }

    private func drop(_ peer: Peer, reason: String?, retry: Bool = false) {
        guard !peer.closed else { return }
        peer.closed = true
        peer.transport.close()
        let wasKnown = peers.removeValue(forKey: peer.id) != nil
        if wasKnown { PeerBudget.shared.release(task: taskID, count: 1) }
        waitingReads.remove(peer.id)
        picker?.peerGone(peer.id)
        peer.queuedBlocks = []
        if superSeeding { for k in superSeen.keys { superSeen[k]?.remove(peer.id) } }
        if seeding, wasKnown { fillSlots() }
        let hadRequests = metadataRequested.values.contains(peer.id)
        for (piece, id) in metadataRequested where id == peer.id { metadataRequested[piece] = nil; metadataRequestedAt[piece] = nil }
        if hadRequests, meta == nil { for p in peers.values where p.id != peer.id { requestMetadata(from: p) } }          // its pieces go to the others at once
        if retry, !peer.inbound, !banned.contains(peer.address), tried[peer.address, default: 0] <= settings.connectRetryLimit { candidates.append(peer.address) }
        if running { connectMore() }
    }

    // MARK: Incoming peers

    /// A peer that connected to us and has already shown which torrent it wants (its handshake, or the start of it, is `initial`). Counted against the same budgets as one we connected to, and
    /// handled by the same code from here on; it is refused if the torrent is not running, is full, or the address is blocked.
    /// One address may hold only a few incoming connections at once: an incoming port is ephemeral, so the port does not tell two connections from one host apart.
    static let inboundPerHost = 3

    func adoptInbound(_ transport: PeerTransport, address: PeerAddress, initial: Data) -> Bool {
        guard peerNetworkEnabled else { return false }
        var accepted = false
        queue.sync {
            let a = address.canonical
            guard running, !finishing, peers.count < settings.maxPeers, !banned.contains(a), !settings.peerFilter.blocks(a.host),
                  !peers.values.contains(where: { $0.address == a }), peers.values.filter({ $0.inbound && $0.address.host == a.host }).count < Self.inboundPerHost, PeerBudget.shared.acquire(task: taskID) else { return }
            let isLocal = HTTPRequestPolicy.classify(host: a.host).isInternal
            if isLocal && !settings.allowLocalPeers { PeerBudget.shared.release(task: taskID, count: 1); return }          // a local peer that dialled in is still a local peer: it needs the same approval
            accepted = true
            let peer = Peer(id: nextPeerID, address: a, transport: transport, now: now())
            nextPeerID += 1
            peers[peer.id] = peer
            peer.inbound = true
            peerSources[a, default: []].insert("inbound")
            sendRaw(PeerWire.handshake(infoHash: infoHash, peerID: peerID, extensions: meta == nil || pexAllowed, fast: settings.fastExtension), to: peer)
            if !initial.isEmpty { handle(initial, from: peer) }
            if !peer.closed { readNext(peer) }
        }
        return accepted
    }

    // MARK: Reading

    private func readNext(_ peer: Peer) {
        guard running, !peer.closed else { return }
        peer.transport.receive { [weak self, weak peer] data, error in
            guard let self, let peer else { return }
            self.queue.async {
                guard !peer.closed, self.running else { return }
                if error != nil || data == nil { if !peer.handshaken { self.records[peer.address, default: PeerRecord()].failed(at: self.now()) }; self.drop(peer, reason: "closed", retry: !peer.handshaken); return }
                self.handle(data!, from: peer)
                guard !peer.closed else { return }
                // The next read is not asked for until the speed limit allows it: the connection backs up, and the sender slows down.
                let wait = self.down?.reserve(task: self.taskID, bytes: data!.count) ?? 0
                if wait > 0.002 { self.queue.asyncAfter(deadline: .now() + wait) { [weak self, weak peer] in if let self, let peer { self.readNext(peer) } } }
                else { self.readNext(peer) }
            }
        }
    }

    private func handle(_ data: Data, from peer: Peer) {
        peer.lastReceived = now()
        var incoming = data
        if !peer.handshaken {
            peer.buffer.append(data)
            guard peer.buffer.count >= PeerWire.handshakeLength else { if peer.buffer.count > PeerWire.handshakeLength { drop(peer, reason: "bad handshake") }; return }
            guard let hs = try? PeerWire.parseHandshake(peer.buffer) else { drop(peer, reason: "bad handshake"); return }
            guard hs.infoHash == infoHash else { drop(peer, reason: "wrong torrent"); return }
            guard hs.peerID != peerID else { drop(peer, reason: "ourselves"); banned.insert(peer.address); return }
            peer.handshaken = true
            records[peer.address, default: PeerRecord()].succeeded()
            peer.supportsExtensions = hs.supportsExtensions
            peer.supportsFast = hs.supportsFast && settings.fastExtension
            incoming = peer.buffer.dropFirst(PeerWire.handshakeLength)
            peer.buffer = Data()
            peer.parser = PeerWire.Parser(pieceCount: meta?.pieceCount ?? Int(Double(PeerWire.maxMetadataSize) / 20 * 8))
            startConversation(peer)
        }
        guard !incoming.isEmpty else { return }
        do {
            for item in try peer.parser!.feedAll(incoming) {
                switch item {
                case .message(let message): handle(message, from: peer)
                case .hash(let h): handleHash(h, from: peer)
                }
                if peer.closed { return }
            }
        } catch { drop(peer, reason: (error as? LocalizedError)?.errorDescription ?? "protocol error"); banned.insert(peer.address) }
    }

    private func startConversation(_ peer: Peer) {
        if seeding { startSeedConversation(peer); return }
        if meta == nil, peer.supportsExtensions {
            send(.extended(id: PeerWire.ExtensionID.handshake, payload: PeerWire.extensionHandshake(metadataSize: nil)), to: peer)
        } else if let picker {
            let flags = picker.have
            if peer.supportsFast {
                // BEP 6: one message says what we hold, in place of a bitfield.
                if flags.allSatisfy({ $0 }) { send(.haveAll, to: peer) } else if !flags.contains(true) { send(.haveNone, to: peer) } else { send(.bitfield(PeerWire.makeBitfield(flags)), to: peer) }
                if let meta, let ip = DHTEndpoint(host: peer.address.host, port: peer.address.port), !ip.isIPv6 {
                    let set = PeerWire.allowedFastSet(ipv4: ip.ip, infoHash: infoHash, pieceCount: meta.pieceCount)
                    peer.allowedFastForThem = Set(set)
                    for p in set { send(.allowedFast(p), to: peer) }
                }
            } else if flags.contains(true) { send(.bitfield(PeerWire.makeBitfield(flags)), to: peer) }
            if peer.supportsExtensions, pexAllowed { send(.extended(id: PeerWire.ExtensionID.handshake, payload: PeerWire.extensionHandshake(metadataSize: nil, pex: true)), to: peer) }
            // Reciprocity: peers who give us nothing back are choked by everyone else, so interested peers are let in.
        }
    }

    // MARK: Messages

    private func handle(_ message: PeerWire.Message, from peer: Peer) {
        switch message {
        case .keepAlive, .unknown: break
        case .cancel(let index, let begin, let length):
            peer.queuedBlocks.remove(Peer.Block(index: index, begin: begin, length: length))          // a block not yet sent is not sent (nothing is counted as uploaded for it)
        case .choke:
            peer.theyChokeUs = true
        case .unchoke:
            peer.theyChokeUs = false; peer.rejectedPieces = [:]; fill(peer)
        case .interested:
            if !peer.theyAreInterested { peer.interestedSince = now() }
            peer.theyAreInterested = true; unchokeIfRoom(peer)
        case .notInterested:
            peer.theyAreInterested = false
            if seeding { peer.queuedBlocks = []; if !peer.weChokeThem { chokePeer(peer) }; fillSlots() }
        case .have(let index):
            guard let picker, index < (meta?.pieceCount ?? 0) else { return }
            picker.peerHave(peer.id, index); updateInterest(peer); fill(peer)
            if seeding { seedNoteHave(peer, index) }
        case .bitfield(let field):
            guard let picker, let meta else { return }
            guard PeerWire.validBitfield(field, pieceCount: meta.pieceCount) else { drop(peer, reason: "bad bitfield"); banned.insert(peer.address); return }
            picker.peerBitfield(peer.id, field); updateInterest(peer); fill(peer)
            if seeding { for i in 0..<meta.pieceCount where field[i / 8] & (0x80 >> UInt8(i % 8)) != 0 { seedNoteHave(peer, i); if peer.closed { return } } }
        case .haveAll:
            guard peer.supportsFast else { drop(peer, reason: "Fast Extension message that was not agreed"); return }
            guard let picker, let meta else { return }          // details not known yet (a magnet): nothing to do with it, and not a fault
            picker.peerBitfield(peer.id, PeerWire.makeBitfield(Array(repeating: true, count: meta.pieceCount))); updateInterest(peer); fill(peer)
            if seeding { seedPeerIsComplete(peer) }
        case .haveNone:
            guard peer.supportsFast else { drop(peer, reason: "Fast Extension message that was not agreed"); return }
            guard let picker, let meta else { return }
            picker.peerBitfield(peer.id, Data(count: (meta.pieceCount + 7) / 8)); updateInterest(peer)
        case .suggest(let index):
            guard peer.supportsFast else { drop(peer, reason: "Fast Extension message that was not agreed"); return }
            guard let meta else { return }
            guard (0..<meta.pieceCount).contains(index) else { drop(peer, reason: "bad Fast Extension message"); return }
            if peer.suggested.count < 32 { peer.suggested.insert(index) }
            fill(peer)
        case .allowedFast(let index):
            guard peer.supportsFast else { drop(peer, reason: "Fast Extension message that was not agreed"); return }
            guard let meta else { return }
            guard (0..<meta.pieceCount).contains(index) else { drop(peer, reason: "bad Fast Extension message"); return }
            if peer.allowedFastForUs.count < 128 { peer.allowedFastForUs.insert(index) }
            fill(peer)
        case .rejectRequest(let index, let begin, let length):
            guard peer.supportsFast else { drop(peer, reason: "Fast Extension message that was not agreed"); return }
            guard let picker, let meta else { return }
            guard (0..<meta.pieceCount).contains(index), begin >= 0, length > 0, length <= PeerWire.blockSize else { drop(peer, reason: "bad Fast Extension message"); return }
            picker.rejected(from: peer.id, piece: index, begin: begin)
            if peer.rejectedPieces.count < 256 { peer.rejectedPieces[index] = now() + 30 }          // not asked of this peer for half a minute, then again
            for p in peers.values { fill(p) }          // the block is free again for whoever can give it
        case .request(let index, let begin, let length):
            serve(peer, index: index, begin: begin, length: length)
        case .piece(let index, let begin, let data):
            receivedBlock(peer, index: index, begin: begin, data: data)
        case .extended(let id, let payload):
            handleExtended(peer, id: id, payload: payload)
        }
    }

    private func updateInterest(_ peer: Peer) {
        guard let picker else { return }
        let want = picker.peerHasWanted(peer.id)
        if want != peer.weAreInterested { peer.weAreInterested = want; send(want ? .interested : .notInterested, to: peer) }
    }

    private func fill(_ peer: Peer) {
        guard running, !finishing, let picker, !peer.closed, peer.weAreInterested else { return }
        // A version 2 torrent cannot check the pieces of a file longer than a piece until that file's piece layer is known: it is fetched first (hash requests), and nothing is asked for before.
        if meta?.version == .v2, let storage = storage(), !storage.missingLayerRoots.isEmpty { requestLayers(from: peer); return }
        // Choked: only a Fast Extension peer's allowed-fast pieces may be asked for (BEP 6).
        if peer.theyChokeUs && !(peer.supportsFast && !peer.allowedFastForUs.isEmpty) { return }
        let room = settings.requestDepth - picker.inFlight(for: peer.id)
        let only: Set<Int>? = peer.theyChokeUs ? peer.allowedFastForUs : nil
        for r in picker.nextRequests(for: peer.id, limit: room, now: now(), only: only, prefer: peer.suggested, avoid: Set(peer.rejectedPieces.filter { $0.value > now() }.keys)) { send(.request(index: r.piece, begin: r.begin, length: r.length), to: peer) }
    }

    private func receivedBlock(_ peer: Peer, index: Int, begin: Int, data: Data) {
        guard let picker, !seeding else { return }          // a seeder asked for nothing
        downloaded += Int64(data.count)
        records[peer.address, default: PeerRecord()].bytesReceived += Int64(data.count)
        switch picker.received(from: peer.id, piece: index, begin: begin, data: data) {
        case .unexpected: break                       // late, duplicate or unasked-for: ignored
        case .accepted: fill(peer)
        case .pieceComplete(let i, let bytes, let contributors): verify(piece: i, data: bytes, contributors: contributors)
        }
        flushCancels()
    }

    /// Requests that became redundant (another peer's answer arrived first) or are no longer wanted (the choice of files changed) are cancelled, so nobody keeps sending what is not needed.
    private func flushCancels() {
        guard let picker else { return }
        for c in picker.takeCancels() { if let p = peers[c.peer], p.handshaken, !p.closed { send(.cancel(index: c.request.piece, begin: c.request.begin, length: c.request.length), to: p) } }
    }

    // MARK: Version 2 piece layers (BEP 52 hash request, hashes, hash reject)

    /// Asks one peer for the piece layers still missing. One request per run per peer at a time; a request unanswered for 20 seconds may be asked again (of this or another peer).
    private func requestLayers(from peer: Peer) {
        guard let meta, meta.version != .v1, let storage = storage(), peer.handshaken, !peer.closed else { return }          // a hybrid from a magnet link gets its version 2 layers too (to check that side as well); only a version 2 torrent waits for them
        let t = now()
        for root in storage.missingLayerRoots {
            guard let f = meta.files.first(where: { !$0.isPadding && $0.pieceRoot == root && $0.length > meta.pieceLength }) else { continue }
            for r in HashProof.requestsForPieceLayer(piecesRoot: root, fileLength: f.length, pieceLength: meta.pieceLength) {
                if layerRuns[root]?[r.index] != nil { continue }
                let key = root.map { String(format: "%02x", $0) }.joined() + ":" + String(r.index) + ":" + String(peer.id)
                if let at = layerAsked[key], t - at < 20 { continue }
                layerAsked[key] = t
                sendRaw(PeerWire.encodeHash(r), to: peer)
            }
        }
        if layerAsked.count > 4096 { layerAsked = layerAsked.filter { t - $0.value < 20 } }
    }

    private func handleHash(_ h: PeerWire.HashMessage, from peer: Peer) {
        guard let meta, meta.version != .v1 else { return }
        switch h.kind {
        case .request:
            // Answering costs CPU (the layer's tree is hashed), so a peer may ask only a few times a second; the rest are dropped, and a peer that keeps flooding is let go.
            let t = now()
            peer.hashTokens = min(4, peer.hashTokens + (t - peer.hashTokensAt) * 1.0); peer.hashTokensAt = t
            guard peer.hashTokens >= 1 else {
                // Over the rate: answered with a reject (the asker is not left waiting), and only a sustained flood is let go; the count falls back while the peer behaves.
                peer.hashDrops += 1
                var no = h; no.kind = .reject; no.hashes = []
                sendRaw(PeerWire.encodeHash(no), to: peer)
                if peer.hashDrops > 200 { drop(peer, reason: "too many hash requests") }
                return
            }
            peer.hashTokens -= 1
            if peer.hashDrops > 0, peer.hashTokens >= 3 { peer.hashDrops -= 1 }
            // Served from a layer we hold and have checked (never from anything else), by a seeding session as well as a downloading one. Anything we cannot answer is rejected, as the BEP requires an answer either way.
            var answer: PeerWire.HashMessage?
            if let f = meta.files.first(where: { !$0.isPadding && $0.pieceRoot == h.piecesRoot && $0.length > meta.pieceLength }), let layer = storage()?.knownPieceLayers[h.piecesRoot] ?? meta.pieceLayers[h.piecesRoot] {
                answer = HashProof.answer(h, layer: layer, fileLength: f.length, pieceLength: meta.pieceLength)
            }
            var reply = answer ?? h
            if answer == nil { reply.kind = .reject; reply.hashes = [] }
            sendRaw(PeerWire.encodeHash(reply), to: peer)
        case .hashes:
            guard let storage = storage(), let f = meta.files.first(where: { !$0.isPadding && $0.pieceRoot == h.piecesRoot && $0.length > meta.pieceLength }), storage.missingLayerRoots.contains(h.piecesRoot) else { return }
            // Only an answer to a request we made of THIS peer, for the piece layer, of the size we asked: anything else could put the run table out of step and stall the fetch.
            let wanted = HashProof.requestsForPieceLayer(piecesRoot: h.piecesRoot, fileLength: f.length, pieceLength: meta.pieceLength)
            let key = h.piecesRoot.map { String(format: "%02x", $0) }.joined() + ":" + String(h.index) + ":" + String(peer.id)
            guard h.baseLayer == HashProof.pieceLayerNumber(pieceLength: meta.pieceLength), wanted.contains(where: { $0.index == h.index && $0.length == h.length }), layerAsked[key] != nil,
                  let run = HashProof.verify(h, piecesRoot: h.piecesRoot, fileLength: f.length, pieceLength: meta.pieceLength) else { return }          // an unsolicited or wrong answer changes nothing
            layerAsked[key] = nil
            layerRuns[h.piecesRoot, default: [:]][h.index] = run
            guard (layerRuns[h.piecesRoot]?.count ?? 0) >= wanted.count else { return }
            if let layer = HashProof.assemblePieceLayer(runs: layerRuns[h.piecesRoot] ?? [:], piecesRoot: h.piecesRoot, fileLength: f.length, pieceLength: meta.pieceLength), storage.install(pieceLayer: layer, forRoot: h.piecesRoot) {
                layerRuns[h.piecesRoot] = nil
                onEvent?(.layersInstalled(storage.knownPieceLayers))
                if storage.missingLayerRoots.isEmpty { for p in peers.values { updateInterest(p); fill(p) } }
            } else {
                layerRuns[h.piecesRoot] = nil          // every run arrived and they do not make the file's layer: start that file's fetch again
            }
        case .reject:
            layerAsked = layerAsked.filter { !$0.key.hasSuffix(":" + String(peer.id)) }          // it cannot help; others are asked
        }
    }

    // MARK: Web seeds

    private func webSeedTick() {
        guard running, !finishing, let picker, let meta, let fetcher = webSeedFetcher, !seeds.isEmpty else { return }
        let t = now()
        var busy = seeds.filter { $0.inFlight != nil }.count
        for i in seeds.indices where busy < Self.maxSeedRequests && seeds[i].disabled == nil && seeds[i].inFlight == nil && seeds[i].retryAt <= t {
            let pseudo = -(i + 1)
            guard let piece = picker.claimWholePiece(for: pseudo, now: t) else { break }
            seeds[i].inFlight = piece; busy += 1
            let source = seeds[i].source
            seedTasks[i] = Task { [weak self] in
                guard let self else { return }
                do {
                    let data = try await self.scoped { try await fetcher.piece(piece, from: source, meta: meta) }
                    self.queue.async { self.seedDelivered(i, piece: piece, data: data) }
                } catch is CancellationError {
                } catch let failure as WebSeedFailure {
                    self.queue.async { self.seedFailed(i, piece: piece, failure) }
                } catch {
                    self.queue.async { self.seedFailed(i, piece: piece, .transient("The server did not answer.")) }
                }
            }
        }
    }

    private func seedDelivered(_ i: Int, piece: Int, data: Data) {
        guard running, i < seeds.count, seeds[i].inFlight == piece, let picker else { return }
        seedTasks[i] = nil
        downloaded += Int64(data.count); seeds[i].bytes += Int64(data.count)
        switch picker.receivedWholePiece(from: -(i + 1), piece: piece, data: data) {
        case .pieceComplete(let index, let bytes, let contributors):
            verify(piece: index, data: bytes, contributors: contributors)          // the seed stays busy until the piece is checked: a seed that sent bad data is not given another piece first
        default:
            seeds[i].inFlight = nil
            picker.peerGone(-(i + 1))          // the piece was finished by someone else (or the choice moved on): the claim is released, nothing is left asked of the seed
            webSeedTick()
        }
        flushCancels()
    }

    private func seedFailed(_ i: Int, piece: Int, _ failure: WebSeedFailure) {
        guard running, i < seeds.count, seeds[i].inFlight == piece else { return }
        seeds[i].inFlight = nil; seedTasks[i] = nil
        picker?.peerGone(-(i + 1))          // the piece is free for peers and other seeds
        let t = now()
        switch failure {
        case .busy(let seconds): seeds[i].retryAt = t + TimeInterval(seconds); seeds[i].lastError = "Busy, trying again in \(seconds) s."
        case .unusable(let why): seeds[i].disabled = why
        case .blocked(let why): seeds[i].disabled = why
        case .wrongData: seeds[i].disabled = "It sent data that did not match the torrent."
        case .transient(let why): seeds[i].transientFailure(why, now: t)
        }
        for p in peers.values { fill(p) }
    }

    private func seedWrongData(_ i: Int) {
        guard i >= 0, i < seeds.count else { return }
        seedTasks[i]?.cancel(); seedTasks[i] = nil          // anything else it was asked for is dropped, and the pieces it held go back to the peers
        seeds[i].inFlight = nil
        picker?.peerGone(-(i + 1))
        seeds[i].disabled = "It sent data that did not match the torrent."          // BEP 19: a server whose piece fails its check is discarded
    }

    private func seedTimedOut(_ i: Int) {
        guard i >= 0, i < seeds.count else { return }
        // Only a claim the seed is still working on is its fault; a stale one (the piece was finished by someone else) is just released.
        guard let piece = seeds[i].inFlight, picker?.owners(ofPiece: piece).contains(-(i + 1)) == true else { picker?.peerGone(-(i + 1)); return }
        seedTasks[i]?.cancel(); seedTasks[i] = nil
        seeds[i].inFlight = nil
        picker?.peerGone(-(i + 1))
        seeds[i].transientFailure("It was too slow.", now: now())
    }

    // MARK: Selection (DX-05)

    static func order(for plan: TorrentPlan, meta: TorrentMetainfo) -> TorrentPicker.Order {
        switch plan.mode {
        case .automatic: return .rarest
        case .sequential: return .sequential
        case .streaming:
            let window = max(4, min(64, Int((8 * 1024 * 1024) / max(meta.pieceLength, 1))))
            return .streaming(anchor: plan.anchorPiece ?? 0, window: window)
        }
    }

    /// Changes which files are wanted, their priorities, or the order, while the download runs. What was verified is kept; requests for pieces no longer wanted are cancelled; a file that
    /// is chosen after being skipped is filled from what is already held. Fails (and changes nothing) if no file would be left, or the files cannot be rearranged.
    func updateSelection(_ new: TorrentSelection, completion: ((Result<Void, Error>) -> Void)? = nil) {
        queue.async { [self] in
            guard let meta, let storage = storage(), let picker, running else { completion?(.failure(SelectionError.notReady)); return }
            guard !finishing else { completion?(.failure(SelectionError.finishing)); return }
            guard !selecting else { completion?(.failure(SelectionError.busy)); return }
            let chosen = new.normalized(for: meta)
            let plan = TorrentPlan(chosen, meta: meta)
            guard !plan.selected.isEmpty else { completion?(.failure(SelectionError.nothingChosen)); return }
            selecting = true
            io.async { [self] in
                var failure: Error?
                if plan.selected != storage.selected {          // decided here, on the thread that writes, against what storage really holds
                    // The verified pieces are asked for on the session queue, after every earlier write has been recorded there (the queue is in order), so no written piece is missed.
                    let verified = queue.sync { Set((0..<meta.pieceCount).filter { picker.have[$0] }) }
                    do { try storage.reselect(to: plan.selected, verified: verified) } catch { failure = error }
                }
                queue.async { [self] in
                    selecting = false
                    if let failure { completion?(.failure(failure)); return }
                    guard running, let picker = self.picker else { completion?(.failure(SelectionError.notReady)); return }
                    selection = chosen
                    let dropped = picker.configure(needed: plan.needed, selected: plan.selected, weights: plan.weights, order: Self.order(for: plan, meta: meta))
                    for o in dropped where o.peer >= 0 { if let p = peers[o.peer], p.handshaken, !p.closed { send(.cancel(index: o.request.piece, begin: o.request.begin, length: o.request.length), to: p) } }
                    for (i, st) in seeds.enumerated() where st.inFlight != nil && !plan.needed.contains(st.inFlight!) { seedTasks[i]?.cancel(); seedTasks[i] = nil; seeds[i].inFlight = nil; picker.peerGone(-(i + 1)) }
                    notedProgress = -1
                    reportProgress(force: true)
                    onEvent?(.selectionChanged(chosen))
                    if picker.isComplete { finalCheck() } else {
                        for p in peers.values where p.handshaken { updateInterest(p); fill(p) }
                        webSeedTick(); connectMore()
                    }
                    completion?(.success(()))
                }
            }
        }
    }

    enum SelectionError: Error, LocalizedError {
        case notReady, finishing, nothingChosen, busy
        var errorDescription: String? {
            switch self {
            case .busy: "The files are being changed; try again in a moment."
            case .notReady: "The torrent is not running, so its files cannot be changed now."
            case .finishing: "The torrent is being checked at the end; try again in a moment."
            case .nothingChosen: "At least one file must stay chosen."
            }
        }
    }

    /// Each file's priority and how much of it is in verified pieces.
    func fileProgress(_ completion: @escaping ([TorrentFileProgress]) -> Void) {
        queue.async { [self] in
            guard let meta, let picker else { completion([]); return }
            let bytes = picker.verifiedBytesByFile
            let sel = selection ?? TorrentSelection.all(meta)
            completion(meta.visibleFiles.map { f in TorrentFileProgress(index: f.index, path: f.path, length: f.length, priority: sel.priority(of: f.index), verified: min(f.length, bytes[f.index])) })
        }
    }

    /// The bytes of a file at an offset, only if every piece they lie in is verified (a player must never be handed bytes that were not checked). nil when they are not there yet; in the
    /// streaming order that also moves the playback position, so the pieces needed come next.
    func readVerified(file: Int, offset: Int64, length: Int, completion: @escaping (Data?) -> Void) {
        queue.async { [self] in
            guard let meta, let storage = storage(), let picker, file >= 0, file < meta.files.count, offset >= 0, length > 0, offset + Int64(length) <= meta.files[file].length else { completion(nil); return }
            let f = meta.files[file]
            let first = Int((f.offset + offset) / meta.pieceLength), last = Int((f.offset + offset + Int64(length) - 1) / meta.pieceLength)
            guard selection?.priority(of: file) ?? .skip > .skip else { completion(nil); return }
            guard (first...last).allSatisfy({ picker.have[$0] }) else {
                if selection?.mode == .streaming { setStreamPosition(file: file, byte: offset) }
                completion(nil); return
            }
            io.async { completion(storage.read(file: file, offset: offset, length: length)) }
        }
    }

    /// The same, waiting for the pieces to arrive (a reader asking for bytes ahead of the download). Gives up after `timeout` seconds, or when the task is cancelled.
    func waitForVerified(file: Int, offset: Int64, length: Int, timeout: TimeInterval = 30) async -> Data? {
        let end = Date().addingTimeInterval(timeout)
        while !Task.isCancelled, Date() < end {
            let data: Data? = await withCheckedContinuation { c in readVerified(file: file, offset: offset, length: length) { c.resume(returning: $0) } }
            if let data { return data }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return nil
    }

    /// Where playback is, for the streaming order: pieces from there are fetched first.
    func setStreamPosition(file: Int, byte: Int64) {
        queue.async { [self] in
            guard var sel = selection, sel.mode == .streaming, !selecting else { return }
            sel.streamFile = file; sel.streamPosition = max(0, byte)
            updateSelection(sel)
        }
    }

    // MARK: Pieces

    private func verify(piece index: Int, data: Data, contributors: Set<Int>) {
        guard let storage = storage() else { return }
        io.async { [self] in
            let ok = storage.matches(data, piece: index)
            var failure: String?
            if ok { do { try storage.write(piece: index, data: data) } catch { failure = (error as? LocalizedError)?.errorDescription ?? "The file could not be written." } }
            queue.async { [self] in
                guard running else { return }
                if let failure { fail(failure, retryable: false); return }
                guard let picker else { return }
                if ok {
                    picker.pieceVerified(index)
                    for id in contributors { if let p = peers[id] { records[p.address, default: PeerRecord()].piecesVerified += 1 } else if id < 0, -id - 1 < seeds.count { seeds[-id - 1].pieces += 1; seeds[-id - 1].failures = 0; seeds[-id - 1].lastError = nil; seeds[-id - 1].inFlight = nil } }
                    webSeedTick()
                    wrote.insert(index)
                    let hex = ((meta?.pieceHashes.indices.contains(index) == true ? meta?.pieceHashes[index] : nil) ?? Data()).map { String(format: "%02x", $0) }.joined()          // a version 2 torrent has no SHA-1 piece hashes
                    onEvent?(.verifiedPiece(index: index, checksum: hex))
                    for p in peers.values where p.handshaken { send(.have(index), to: p) }
                    for p in peers.values { updateInterest(p) }
                    reportProgress(force: false)
                    if picker.isComplete { finalCheck() }
                } else {
                    picker.pieceFailed(index)
                    for id in contributors where id < 0 { seedWrongData(-id - 1) }
                    for id in contributors { if let p = peers[id] { p.hashFailures += 1; if p.hashFailures >= settings.maxHashFailuresPerPeer { banned.insert(p.address); drop(p, reason: "sent bad data") } } }
                    for p in peers.values { fill(p) }
                }
            }
        }
    }

    private func reportProgress(force: Bool) {
        guard let picker, let storage = storage() else { return }
        let done = picker.completedBytes
        guard force || done != notedProgress else { return }
        notedProgress = done
        onEvent?(.progress(completedBytes: done, totalBytes: storage.selectedBytes))
    }

    /// Every wanted piece is read back from disk and checked once more before the download is called finished: what is on disk, not what was in memory, is what counts.
    private func finalCheck() {
        guard !finishing, let storage = storage(), let meta else { return }
        finishing = true
        let pieces = storage.neededPieces
        io.async { [self] in
            storage.sync()
            var bad: [Int] = []
            for p in pieces { if let d = storage.read(piece: p), storage.matches(d, piece: p) { continue }; bad.append(p) }
            queue.async { [self] in
                guard running else { return }          // stopped (paused, cancelled, failed) while the check ran: it reports nothing
                if bad.isEmpty {
                    // Finished only if what was checked is still everything that is wanted: the choice of files may have grown while the check ran (its new pieces were not in the list).
                    guard picker?.isComplete == true, storage.neededPieces == pieces else {
                        finishing = false
                        for p in peers.values { updateInterest(p); fill(p) }
                        webSeedTick(); connectMore()
                        return
                    }
                    running = false; timer?.cancel(); timer = nil; for p in peers.values { drop(p, reason: nil) }; announceCompleted(); onEvent?(.finished); _ = meta; return
                }
                // Something on disk does not match: those pieces are fetched again.
                finishing = false
                recoveryNote = "\(bad.count) piece\(bad.count == 1 ? "" : "s") failed the final check and are being fetched again"
                picker?.invalidate(bad)
                for p in peers.values { updateInterest(p); fill(p) }
                connectMore()
            }
        }
    }

    private func fail(_ message: String, retryable: Bool) {
        guard running || finishing else { return }
        running = false; timer?.cancel(); timer = nil
        for p in Array(peers.values) { drop(p, reason: nil) }
        onEvent?(.failed(message, retryable: retryable))
    }

    // MARK: Serving

    private func unchokeIfRoom(_ peer: Peer) {
        guard seeding || settings.shareWhileDownloading, !peer.closed, peer.weChokeThem, meta != nil else { return }
        if seeding && !peer.theyAreInterested { return }
        if peers.values.filter({ !$0.weChokeThem }).count < settings.uploadSlots { peer.weChokeThem = false; peer.unchokedAt = now(); send(.unchoke, to: peer) }
    }

    // MARK: Seeding (DX-06)

    /// What a seeder says to a new peer: what it holds (or nothing, when initial seeding hands pieces out one at a time), a few allowed-fast pieces it can actually give, and PEX where allowed.
    private func startSeedConversation(_ peer: Peer) {
        guard let picker, let meta else { return }
        let flags = picker.have
        if superSeeding {
            if peer.supportsFast { send(.haveNone, to: peer) }          // nothing announced: pieces are offered one by one with HAVE
        } else if peer.supportsFast {
            if flags.allSatisfy({ $0 }) { send(.haveAll, to: peer) } else if !flags.contains(true) { send(.haveNone, to: peer) } else { send(.bitfield(PeerWire.makeBitfield(flags)), to: peer) }
            if let ip = DHTEndpoint(host: peer.address.host, port: peer.address.port), !ip.isIPv6 {
                let set = PeerWire.allowedFastSet(ipv4: ip.ip, infoHash: infoHash, pieceCount: meta.pieceCount).filter { flags[$0] }
                peer.allowedFastForThem = Set(set)
                for p in set { send(.allowedFast(p), to: peer) }
            }
        } else if flags.contains(true) { send(.bitfield(PeerWire.makeBitfield(flags)), to: peer) }
        if peer.supportsExtensions, pexAllowed { send(.extended(id: PeerWire.ExtensionID.handshake, payload: PeerWire.extensionHandshake(metadataSize: nil, pex: true)), to: peer) }
        peer.theirPieces = PieceBits(capacity: meta.pieceCount)
        if superSeeding { superSeedPump() }
    }

    private func chokePeer(_ peer: Peer) {
        guard !peer.weChokeThem else { return }
        peer.weChokeThem = true
        send(.choke, to: peer)
        // What it had asked for is dropped (BEP 3); a Fast Extension peer is told so.
        if peer.supportsFast { for b in peer.queuedBlocks { send(.rejectRequest(index: b.index, begin: b.begin, length: b.length), to: peer) } }
        peer.queuedBlocks = []
    }

    /// Free upload slots go to the interested peers that have waited longest.
    private func fillSlots() {
        guard seeding, running else { return }
        let waiting = peers.values.filter { $0.handshaken && !$0.closed && $0.theyAreInterested && $0.weChokeThem }.sorted { $0.interestedSince < $1.interestedSince }
        for p in waiting { unchokeIfRoom(p) }
    }

    /// Every `chokeInterval`, when more peers wait than there are slots, the peer unchoked longest gives way to the one that has waited longest (nobody holds a slot for ever).
    private func rotateChoke(_ t: TimeInterval) {
        guard t - lastChokeRound >= seedConfig.chokeInterval else { return }
        lastChokeRound = t
        fillSlots()
        let waiting = peers.values.filter { $0.handshaken && !$0.closed && $0.theyAreInterested && $0.weChokeThem }.sorted { $0.interestedSince < $1.interestedSince }
        let holders = peers.values.filter { !$0.weChokeThem && !$0.closed }.sorted { $0.unchokedAt < $1.unchokedAt }
        guard let next = waiting.first, let oldest = holders.first, holders.count >= settings.uploadSlots else { return }
        chokePeer(oldest)
        oldest.interestedSince = t          // it goes to the back of the line, so the others get their turn
        unchokeIfRoom(next)
    }

    /// Live changes of a seeding session's limits (the person changed a setting).
    func updateSeeding(_ config: SeedingConfig, maxPeers: Int, uploadSlots: Int) {
        queue.async { [self] in
            guard seeding else { return }
            let keepPrior = (seedConfig.priorUploaded, seedConfig.priorDownloaded, seedConfig.priorSeconds)
            seedConfig = config
            (seedConfig.priorUploaded, seedConfig.priorDownloaded, seedConfig.priorSeconds) = keepPrior
            settings.maxPeers = maxPeers; settings.uploadSlots = uploadSlots
            if !config.initialSeeding, superSeeding { endSuperSeeding(reason: "Turned off.") }
            while peers.values.filter({ !$0.weChokeThem }).count > uploadSlots, let extra = peers.values.filter({ !$0.weChokeThem }).min(by: { $0.unchokedAt > $1.unchokedAt }) { chokePeer(extra) }
        }
    }

    private func seedTick(_ t: TimeInterval) {
        guard let seed = seedSource, let meta, !seedEnded else { return }
        if t - lastAudit >= 10 { lastAudit = t; seed.audit() }
        let total = seedConfig.priorUploaded + uploaded
        if let reason = SeedPolicy.stopReason(uploaded: total, size: seed.sharedSize, seconds: seedConfig.priorSeconds + (t - seedStart), ratioTarget: seedConfig.ratioTarget, timeLimit: seedConfig.timeLimit, servable: seed.servableCount) {
            endSeeding(reason); return
        }
        rotateChoke(t)
        if superSeeding {
            if seedConfig.initialSeeding == false || completeSeen > seedConfig.superSeedFallbackSeeds { endSuperSeeding(reason: completeSeen > seedConfig.superSeedFallbackSeeds ? "Other peers already have complete copies." : "Turned off.") }
            else if seed.servablePieces.allSatisfy({ !(superSeen[$0] ?? []).isEmpty }) { endSuperSeeding(reason: "Every piece has been seen on other peers.") }
            else { superSeedPump() }
        }
        _ = meta
    }

    /// The session ends itself: peers are choked and closed, pending reads are dropped, the tracker hears "stopped", and the owner is told why.
    private func endSeeding(_ reason: SeedStopReason) {
        guard running, !seedEnded else { return }
        seedEnded = true
        stopNow(sendStoppedAnnounce: true)
        onEvent?(.seedingEnded(reason))
    }

    private func seedFilesChanged() {
        guard running, let seed = seedSource, !seedEnded else { return }
        if seed.servableCount == 0 { endSeeding(.filesChanged); return }
        // Pieces that can no longer be given are refused if asked for (they stay announced to peers that already heard of them; there is no way to take a HAVE back).
        for p in peers.values { p.queuedBlocks = [] }
    }

    // MARK: Initial (super) seeding

    private func seedPeerIsComplete(_ peer: Peer) {
        guard !peer.isComplete else { return }
        peer.isComplete = true; completeSeen += 1
        // Two seeds have nothing to give each other.
        banned.insert(peer.address)
        drop(peer, reason: "both sides are complete")
    }

    private func seedNoteHave(_ peer: Peer, _ index: Int) {
        guard peer.theirPieces?.insert(index) == true else { return }
        if superSeeding { superSeen[index, default: []].insert(peer.id) }
        if peer.theirPieces?.isFull == true { seedPeerIsComplete(peer); return }
        if superSeeding { superSeedPump() }
    }

    /// Offers each peer one piece at a time: a piece no peer has reported, with HAVE. The next one comes only after the last was seen on ANOTHER peer, or after a timeout.
    private func superSeedPump() {
        guard superSeeding, let seed = seedSource, let meta else { return }
        let t = now()
        for p in peers.values.sorted(by: { $0.id < $1.id }) where p.handshaken && !p.closed && !p.isComplete {
            if let o = p.offered {
                let redistributed = (superSeen[o] ?? []).contains { $0 != p.id }
                guard redistributed || t - p.offeredAt >= seedConfig.superSeedTimeout else { continue }
            }
            var best: Int?
            for i in 0..<meta.pieceCount where !p.servedPieces.contains(i) && (superSeen[i] ?? []).isEmpty && seed.isServable(i) {
                if best == nil || (offerCount[i] ?? 0) < (offerCount[best!] ?? 0) { best = i; if (offerCount[i] ?? 0) == 0 { break } }
            }
            guard let piece = best else { continue }
            p.offered = piece; p.offeredAt = t; p.servedPieces.insert(piece); offerCount[piece, default: 0] += 1
            send(.have(piece), to: p)
        }
    }

    /// Back to normal seeding: whatever each peer was not told yet is announced.
    private func endSuperSeeding(reason: String) {
        guard superSeeding, let seed = seedSource else { return }
        superSeeding = false; superSeedFellBack = reason
        let all = seed.servablePieces.sorted()
        for p in peers.values where p.handshaken && !p.closed {
            for i in all where !p.servedPieces.contains(i) { send(.have(i), to: p) }
        }
    }

    private func serve(_ peer: Peer, index: Int, begin: Int, length: Int) {
        if seeding { serveSeeding(peer, index: index, begin: begin, length: length); return }
        func refuse() { if peer.supportsFast { send(.rejectRequest(index: index, begin: begin, length: length), to: peer) } }
        // A choked peer is served only an allowed-fast piece we hold (BEP 6).
        let permitted = settings.shareWhileDownloading && (!peer.weChokeThem || (peer.supportsFast && peer.allowedFastForThem.contains(index)))
        guard permitted, let picker, let meta, let storage = storage(),
              index >= 0, index < meta.pieceCount, picker.have[index], picker.needed.contains(index) || wrote.contains(index),
              begin >= 0, length > 0, length <= PeerWire.blockSize, begin + length <= Int(meta.length(ofPiece: index)), uploadsWaiting < 64 else { refuse(); return }
        uploadsWaiting += 1
        io.async { [self] in
            let block = storage.read(piece: index, begin: begin, length: length)
            queue.async { [self] in
                uploadsWaiting -= 1
                guard let block, !peer.closed, running else { if !peer.closed { refuse() }; return }
                // Uploads are paced like downloads: the block goes out when the upload limit allows.
                let wait = up?.reserve(task: taskID, bytes: block.count) ?? 0
                let go = { [weak self, weak peer] in
                    guard let self, let peer, !peer.closed, self.running else { return }
                    self.uploaded += Int64(block.count)
                    self.send(.piece(index: index, begin: begin, data: block), to: peer)
                }
                if wait > 0.002 { queue.asyncAfter(deadline: .now() + wait, execute: go) } else { go() }
            }
        }
    }

    /// A request to a seeder. Checked in this order, and nothing is read from disk unless every check passes: the numbers are in range and the block is at most 16 KiB (otherwise the peer is
    /// closed: no honest peer sends that), the peer may be served now (unchoked, or a piece allowed while choked), the piece is verified, still has its files, and (initial seeding) was offered to this peer.
    private func serveSeeding(_ peer: Peer, index: Int, begin: Int, length: Int) {
        guard let seed = seedSource, let meta, running, !seedEnded else { return }
        func refuse() { if peer.supportsFast { send(.rejectRequest(index: index, begin: begin, length: length), to: peer) } }
        guard index >= 0, index < meta.pieceCount, begin >= 0, length > 0, length <= PeerWire.blockSize, begin + length <= Int(meta.length(ofPiece: index)) else {
            drop(peer, reason: "invalid request"); return
        }
        let allowedWhileChoked = peer.supportsFast && peer.allowedFastForThem.contains(index)
        guard !peer.weChokeThem || allowedWhileChoked else { refuse(); return }
        guard seed.isServable(index), !superSeeding || peer.servedPieces.contains(index) else {
            peer.badRequests += 1
            if peer.badRequests >= 16 { drop(peer, reason: "asked for pieces that are not offered") } else { refuse() }
            return
        }
        let block = Peer.Block(index: index, begin: begin, length: length)
        guard peer.queuedBlocks.count < seedConfig.maxQueuedBlocksPerPeer, uploadsWaiting < 64 else { refuse(); return }
        guard peer.queuedBlocks.insert(block).inserted else { return }          // asked twice: answered once
        uploadsWaiting += 1
        io.async { [self] in
            let result = seed.read(piece: index, begin: begin, length: length)
            queue.async { [self] in
                uploadsWaiting -= 1
                guard running, !peer.closed, peer.queuedBlocks.contains(block) else { return }          // cancelled, choked or stopped while the disk was read: nothing is sent
                guard case .success(let data) = result else { peer.queuedBlocks.remove(block); refuse(); return }
                let wait = up?.reserve(task: taskID, bytes: data.count) ?? 0
                let go = { [weak self, weak peer] in
                    guard let self, let peer, !peer.closed, self.running, peer.queuedBlocks.remove(block) != nil else { return }          // a cancel during the wait stops it
                    self.uploaded += Int64(data.count); peer.bytesTo += Int64(data.count)
                    self.send(.piece(index: index, begin: begin, data: data), to: peer)
                }
                if wait > 0.002 { queue.asyncAfter(deadline: .now() + wait, execute: go) } else { go() }
            }
        }
    }

    // MARK: Metadata (BEP 9)

    private var metadataTotal: Int?

    private func handleExtended(_ peer: Peer, id: UInt8, payload: Data) {
        if id == PeerWire.ExtensionID.handshake {
            guard let dict = (try? BencodeDecoder.decode(payload, limits: .message))?.value.dict else { return }
            peer.theirMetadataID = dict["m"]?.dict?["ut_metadata"]?.int.flatMap { $0 > 0 && $0 < 256 ? UInt8($0) : nil }
            peer.theirMetadataSize = dict["metadata_size"]?.int.flatMap { $0 > 0 && $0 <= Int64(PeerWire.maxMetadataSize) ? Int($0) : nil }
            peer.theirPexID = dict["m"]?.dict?["ut_pex"]?.int.flatMap { $0 > 0 && $0 < 256 ? UInt8($0) : nil }
            if meta == nil, let size = peer.theirMetadataSize, peer.theirMetadataID != nil {
                if metadataBuffer == nil { metadataBuffer = Data(count: size); metadataTotal = size }
                if metadataTotal == size { requestMetadata(from: peer) }
            }
            return
        }
        if id == PeerWire.ExtensionID.utPex { receivedPex(peer, payload); return }
        guard id == PeerWire.ExtensionID.utMetadata, let message = try? PeerWire.parseMetadataMessage(payload) else { return }
        switch message.type {
        case 0: if let theirs = peer.theirMetadataID { send(.extended(id: theirs, payload: PeerWire.metadataReject(piece: message.piece)), to: peer) }     // we hold none to give
        case 2:
            // A refusal: that peer is not asked for this piece again, and another peer is asked at once.
            if metadataRequested[message.piece] == peer.id { metadataRefusedBy[message.piece, default: []].insert(peer.id) }
            metadataRequested[message.piece] = nil; metadataRequestedAt[message.piece] = nil
            if meta == nil { for p in peers.values { requestMetadata(from: p) } }
        case 1: receivedMetadata(peer, piece: message.piece, data: message.data)
        default: break
        }
    }

    // MARK: Peer exchange (BEP 11)

    /// Peers a connected peer tells us of go through the same door as every other source (`addCandidates`): the same checks, the same limits, the same revocation. Ignored entirely for a private torrent
    /// or while the torrent's privacy is not known, and when the peer sends them faster than they may be sent.
    private func receivedPex(_ peer: Peer, _ payload: Data) {
        guard pexAllowed else { return }
        let t = now()
        guard t - peer.lastPexReceived >= settings.pexInterval else { return }
        peer.lastPexReceived = t          // set before parsing: a stream of unreadable messages is as limited as a stream of good ones
        guard let message = PeerWire.parsePex(payload) else { return }
        let added = message.added.map(\.address)
        pexAdded += added.count
        addCandidates(added, fromLocalTracker: false, source: "pex")
        for address in added.map(\.canonical) where peerSources[address]?.contains("pex") == true {          // only for what was actually taken
            if pexVouchers[address] != nil || pexVouchers.count < 2000 { pexVouchers[address, default: []].insert(peer.id) }
        }
        for gone in message.dropped.map(\.canonical) {
            guard var vouchers = pexVouchers[gone], vouchers.remove(peer.id) != nil else { continue }          // this peer never vouched for it: its "dropped" means nothing to us
            if !vouchers.isEmpty { pexVouchers[gone] = vouchers; continue }          // someone else still says it is there
            pexVouchers[gone] = nil
            var rest = peerSources[gone] ?? []; rest.remove("pex")
            peerSources[gone] = rest.isEmpty ? nil : rest
            if rest.isEmpty { candidates.removeAll { $0 == gone } }          // nothing else supports it either
        }
    }

    /// Tells each peer that speaks PEX about the others we are connected to (public addresses only: a LAN address is never given to a stranger), a minute apart at most.
    private func sendPex(_ t: TimeInterval) {
        guard pexAllowed else { return }
        let live = peers.values.filter { $0.handshaken }
        for peer in live {
            guard let theirs = peer.theirPexID, t - peer.lastPexSent >= settings.pexInterval, t - peer.startedAt >= 5 else { continue }
            let publicLive = Set(live.filter { $0.id != peer.id }.map(\.address).filter { !HTTPRequestPolicy.classify(host: $0.host).isInternal })
            let added = Array(publicLive.subtracting(peer.pexSent).prefix(PeerWire.maxPexPeers))
            let dropped = Array(peer.pexSent.subtracting(publicLive).prefix(PeerWire.maxPexPeers))
            guard !added.isEmpty || !dropped.isEmpty else { continue }
            send(.extended(id: theirs, payload: PeerWire.pexMessage(added: added.map { PeerWire.PexPeer(address: $0, flags: 0x10) }, dropped: dropped)), to: peer)
            peer.pexSent.subtract(dropped); peer.pexSent.formUnion(added); peer.lastPexSent = t
        }
    }

    private func requestMetadata(from peer: Peer) {
        guard let total = metadataTotal, let theirs = peer.theirMetadataID else { return }
        let count = (total + PeerWire.metadataPieceSize - 1) / PeerWire.metadataPieceSize
        // At most 2 outstanding per peer (as libtorrent does), so the pieces spread over several peers; a piece this peer refused or ignored is not asked of it again.
        for piece in 0..<count where !metadataGot.contains(piece) && metadataRequested[piece] == nil && metadataRefusedBy[piece]?.contains(peer.id) != true && metadataRequested.values.filter({ $0 == peer.id }).count < 2 {
            metadataRequested[piece] = peer.id; metadataRequestedAt[piece] = now()
            send(.extended(id: theirs, payload: PeerWire.metadataRequest(piece: piece)), to: peer)
        }
    }

    /// While the details are not known: a request nobody answered in `metadataRequestTimeout` seconds goes to another peer (the silent one is asked last), and any piece without a request is
    /// offered to every peer that can serve it. Before, a peer that never answered, or one that dropped, left its pieces unrequested until some other event happened to trigger a request.
    private func retryMetadata(_ t: TimeInterval) {
        guard meta == nil, let total = metadataTotal else { return }
        var silent = Set<Int>()
        for (piece, at) in metadataRequestedAt where t - at >= settings.metadataRequestTimeout {
            if let id = metadataRequested[piece] { silent.insert(id) }
            metadataRequested[piece] = nil; metadataRequestedAt[piece] = nil
        }
        let count = (total + PeerWire.metadataPieceSize - 1) / PeerWire.metadataPieceSize
        guard (0..<count).contains(where: { !metadataGot.contains($0) && metadataRequested[$0] == nil }) else { return }
        // Peers that did not answer are asked last, so a piece moves to another peer when there is one, and is asked of the slow one again only when there is not.
        for p in peers.values where !silent.contains(p.id) { requestMetadata(from: p) }
        for p in peers.values where silent.contains(p.id) { requestMetadata(from: p) }
    }

    private func receivedMetadata(_ peer: Peer, piece: Int, data: Data) {
        guard meta == nil, let total = metadataTotal, metadataRequested[piece] == peer.id else { return }
        let start = piece * PeerWire.metadataPieceSize
        let expected = min(PeerWire.metadataPieceSize, total - start)
        guard start < total, data.count == expected else { drop(peer, reason: "bad metadata piece"); return }
        metadataBuffer!.replaceSubrange(start..<(start + expected), with: data)
        metadataGot.insert(piece); metadataRequested[piece] = nil; metadataRequestedAt[piece] = nil; metadataSenders[piece] = peer.address
        let count = (total + PeerWire.metadataPieceSize - 1) / PeerWire.metadataPieceSize
        if metadataGot.count == count {
            let assembled = metadataBuffer!
            // The promise made by the link: the hash of this section is the torrent's identity. Anything else is thrown away.
            guard TorrentMetainfo.infoMatches(assembled, session: infoHash, v2: expectedInfoHashV2), let parsed = try? TorrentMetainfo.parse(infoSection: assembled) else {
                // Any of them could have sent the bad part, so all who took part in this attempt are set aside.
                for address in metadataSenders.values { banned.insert(address) }
                for p in Array(peers.values) where banned.contains(p.address) { drop(p, reason: "metadata did not match") }
                metadataBuffer = nil; metadataGot = []; metadataRequested = [:]; metadataRequestedAt = [:]; metadataRefusedBy = [:]; metadataTotal = nil; metadataSenders = [:]
                return
            }
            meta = parsed
            if parsed.isPrivate { forgetSource("dht"); forgetSource("pex"); forgetSource("lpd"); stopDHT() }          // BEP 27: nothing the public network supplied is kept
            running = false; timer?.cancel(); timer = nil
            for p in Array(peers.values) { drop(p, reason: nil) }
            onEvent?(.metadata(parsed))
        } else {
            for p in peers.values { requestMetadata(from: p) }
        }
    }

    // MARK: Sending

    private func send(_ message: PeerWire.Message, to peer: Peer) { sendRaw(PeerWire.encode(message), to: peer) }

    private func sendRaw(_ data: Data, to peer: Peer) {
        guard !peer.closed else { return }
        peer.lastSent = now()
        peer.transport.send(data)
    }
}

/// How many peer connections may be open at once across every torrent. A separate pool from the HTTP connection budget: a peer connection is not a download connection.
final class PeerBudget: @unchecked Sendable {
    static let shared = PeerBudget()
    static let defaultTotal = 60
    private let lock = NSLock()
    private var held: [UUID: Int] = [:]
    private var total = 0
    private var limit = PeerBudget.defaultTotal

    func setLimit(_ value: Int) { lock.lock(); limit = max(1, min(value, 500)); lock.unlock() }
    var open: Int { lock.lock(); defer { lock.unlock() }; return total }
    func holding(task: UUID) -> Int { lock.lock(); defer { lock.unlock() }; return held[task] ?? 0 }

    /// Tasks that asked and were refused: they count when the pool is shared out, so one torrent cannot hold every connection while another waits for one.
    private var waiting = Set<UUID>()

    func acquire(task: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let sharers = Set(held.keys).union(waiting).union([task]).count
        let fair = max(5, limit / max(1, sharers))
        guard total < limit, sharers == 1 || held[task, default: 0] < fair else { waiting.insert(task); return false }
        waiting.remove(task)
        total += 1; held[task, default: 0] += 1
        return true
    }

    func release(task: UUID, count: Int) {
        lock.lock(); defer { lock.unlock() }
        let n = min(count, held[task] ?? 0)
        guard n > 0 else { return }
        total -= n
        if (held[task] ?? 0) - n > 0 { held[task]! -= n } else { held[task] = nil }
    }

    func releaseAll(task: UUID) { lock.lock(); let n = held.removeValue(forKey: task) ?? 0; total -= n; waiting.remove(task); lock.unlock() }
}
