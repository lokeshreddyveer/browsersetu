import Foundation
import Network
import Darwin

// MARK: A DHT node (BEP 5, BEP 32): queries out, queries in, lookups, bootstrap, persistence
//
// One node per app, shared by every torrent that may use it. It does nothing, opens nothing and contacts no one until a torrent that is allowed to use the DHT asks (`acquire`), and it closes everything
// when the last one lets go, when peer-to-peer or the DHT is switched off, or when the network setup cannot carry it (a proxy cannot carry UDP: the node stays off and says why). It is a node of
// its own sockets (see `NWDHTTransport`): every datagram it reads says where it came from, and an answer counts only if it comes from the address the question went to.

struct DHTBlock: Sendable, Equatable { var reason: String; var needsSettings = false }

struct DHTStatus: Sendable, Equatable {
    enum State: String, Sendable { case off = "Off", starting = "Starting", ready = "Ready", unreachable = "No nodes reachable", blocked = "Blocked" }
    var state: State = .off
    var nodes4 = 0, nodes6 = 0
    var lookups = 0
    var peersFound = 0
    var lastError: String?
    var needsSettings = false
}

protocol DHTDatagramTransport: AnyObject {
    var onReceive: ((Data, DHTEndpoint) -> Void)? { get set }
    var supportsIPv6: Bool { get }
    func start() throws
    func send(_ data: Data, to endpoint: DHTEndpoint)
    func close()
}

protocol DHTNodeStore: AnyObject {
    func load() -> [DHTNodeInfo]
    func save(_ nodes: [DHTNodeInfo])
}

final class DHTLookupHandle: @unchecked Sendable {
    let cancel: () -> Void
    init(cancel: @escaping () -> Void) { self.cancel = cancel }
}

protocol DHTDiscovering: AnyObject, Sendable {
    func acquire(_ task: UUID)
    func release(_ task: UUID)
    /// Looks for peers of `infoHash`. `onPeers` gets numeric peers, IPv4 and IPv6 (and whether they came from a node the person configured on their own network).
    @discardableResult
    func lookupPeers(infoHash: Data, task: UUID, onPeers: @escaping @Sendable ([PeerAddress], Bool) -> Void, onFinish: @escaping @Sendable () -> Void) -> DHTLookupHandle
    var status: DHTStatus { get }
}

final class DHTNode: DHTDiscovering, @unchecked Sendable {
    struct Config: Sendable {
        var k = DHTRoutingTable.k
        var alpha = 3
        var queryTimeout: TimeInterval = 3
        var lookupTimeout: TimeInterval = 40
        var maxOutstanding = 128
        var maxConcurrentLookups = 4
        var maxQueriesPerLookup = 80
        var maxCandidates = 64
        var storedHashes = 200, peersPerHash = 100, peerTTL: TimeInterval = 1800
        var inboundPerIP = 8, inboundWindow: TimeInterval = 10, inboundGlobalPerSecond = 200
        var bootstrapRetry: TimeInterval = 60, saveEvery: TimeInterval = 600
        var persistedNodes = 100
        static let defaultBootstrap = ["router.bittorrent.com:6881", "dht.transmissionbt.com:6881", "router.utorrent.com:6881"]
    }

    private let queue = DispatchQueue(label: "browsersetu.dht")
    private let transport: DHTDatagramTransport
    private let config: Config
    private let policy: @Sendable () -> DHTBlock?
    private let sendGate: @Sendable () -> String?
    private let store: DHTNodeStore?
    private let resolver: HostAddressResolving
    private let bootstrapList: @Sendable () -> (hosts: [String], explicit: Bool)
    private let isPrivateHash: @Sendable (Data) -> Bool
    private let clock: @Sendable () -> TimeInterval
    private let pathGeneration: @Sendable () -> Int
    private var seenGeneration = 0
    private let tokens: DHTTokens

    // State below belongs to `queue`.
    private var table: DHTRoutingTable
    private var users = Set<UUID>()
    private var running = false
    private var timer: DispatchSourceTimer?
    private var pending: [Data: Pending] = [:]
    private var lookups: [UUID: Lookup] = [:]
    private var waiting: [Lookup] = []
    private var localAllowed = Set<DHTEndpoint>()
    private var peerStore: [NodeID: [(endpoint: DHTEndpoint, expires: TimeInterval)]] = [:]
    private var perIP: [[UInt8]: (start: TimeInterval, count: Int)] = [:]
    private var globalWindow: (start: TimeInterval, count: Int) = (0, 0)
    private var bootstrapping = false, bootstrapAt: TimeInterval = -1e9, lastSave: TimeInterval = 0, lastRefresh: TimeInterval = 0
    private var state = DHTStatus.State.off
    private var lastError: String?, needsSettings = false
    private var peersFound = 0
    private(set) var droppedSpoofed = 0, droppedMalformed = 0, droppedRateLimited = 0

    private let statusLock = NSLock()
    private var published = DHTStatus()
    var status: DHTStatus { statusLock.lock(); defer { statusLock.unlock() }; return published }

    /// `nodeFault`: the node did not answer (as opposed to us not asking: no network, a full queue), which is what counts against it.
    typealias Completion = (_ values: [String: Bencode]?, _ nodeFault: Bool) -> Void
    struct Pending { var endpoint: DHTEndpoint; var nodeID: NodeID?; var deadline: TimeInterval; var completion: Completion }

    final class Lookup {
        let id = UUID(), task: UUID, target: NodeID, wantsPeers: Bool
        var candidates: [DHTNodeInfo] = []
        var asked = Set<NodeID>(), answered = Set<NodeID>(), failed = Set<NodeID>()
        var inflight = 0, queries = 0
        var seen = Set<DHTEndpoint>()
        var deadline: TimeInterval = 0
        var finished = false
        let onPeers: @Sendable ([PeerAddress], Bool) -> Void
        let onFinish: @Sendable () -> Void
        init(task: UUID, target: NodeID, wantsPeers: Bool, onPeers: @escaping @Sendable ([PeerAddress], Bool) -> Void, onFinish: @escaping @Sendable () -> Void) {
            self.task = task; self.target = target; self.wantsPeers = wantsPeers; self.onPeers = onPeers; self.onFinish = onFinish
        }
    }

    init(transport: DHTDatagramTransport, id: NodeID = .random(), config: Config = Config(), policy: @escaping @Sendable () -> DHTBlock?, sendGate: @escaping @Sendable () -> String? = { nil },
         store: DHTNodeStore? = nil, resolver: HostAddressResolving = SystemHostResolver(),
         bootstrap: @escaping @Sendable () -> (hosts: [String], explicit: Bool) = { (Config.defaultBootstrap, false) },
         isPrivateHash: @escaping @Sendable (Data) -> Bool = { _ in false }, clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         pathGeneration: @escaping @Sendable () -> Int = { NetworkPathGate.shared.generation }) {
        self.pathGeneration = pathGeneration
        self.transport = transport; self.config = config; self.policy = policy; self.sendGate = sendGate; self.store = store; self.resolver = resolver
        bootstrapList = bootstrap; self.isPrivateHash = isPrivateHash; self.clock = clock
        tokens = DHTTokens(now: clock); table = DHTRoutingTable(own: id, now: clock())
        transport.onReceive = { [weak self] data, from in self?.queue.async { self?.receive(data, from: from) } }
    }

    var nodeID: NodeID { queue.sync { table.own } }

    // MARK: Using it

    func acquire(_ task: UUID) { queue.async { [self] in users.insert(task); startIfNeeded() } }
    func release(_ task: UUID) {
        queue.async { [self] in
            users.remove(task)
            waiting.removeAll { $0.task == task }          // before the running ones are finished, so none of this task's is promoted
            for l in Array(lookups.values) where l.task == task { finish(l) }
            if users.isEmpty { shutdown(reason: nil) }
        }
    }

    @discardableResult
    func lookupPeers(infoHash: Data, task: UUID, onPeers: @escaping @Sendable ([PeerAddress], Bool) -> Void, onFinish: @escaping @Sendable () -> Void) -> DHTLookupHandle {
        let target = NodeID(infoHash)
        let lookup = target.map { Lookup(task: task, target: $0, wantsPeers: true, onPeers: onPeers, onFinish: onFinish) }
        queue.async { [self] in
            guard let lookup else { onFinish(); return }
            guard users.contains(task) else { onFinish(); return }          // only a torrent that holds the node may use it
            if running { begin(lookup) } else { onFinish() }
        }
        return DHTLookupHandle { [weak self] in self?.queue.async { if let lookup { self?.finish(lookup, notify: false) } } }
    }

    /// Ends everything now (peer-to-peer or the DHT was switched off): lookups, pending questions, timers, sockets.
    func stopNow(reason: String) { queue.async { [self] in users = []; shutdown(reason: DHTBlock(reason: reason)) } }

    // MARK: Start, stop, policy

    private func startIfNeeded() {
        guard !running else { return }
        if let block = policy() { publish(state: .blocked, error: block.reason, settings: block.needsSettings); return }
        do { try transport.start() } catch { publish(state: .unreachable, error: "The DHT could not open its network socket."); return }
        running = true; lastSave = clock(); lastRefresh = clock(); seenGeneration = pathGeneration()
        if let store { for n in store.load().prefix(config.persistedNodes) where n.endpoint.isRoutable { table.insert(n, heard: true, now: clock()) } }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t; t.resume()
        publish(state: .starting, error: nil)
        startBootstrap()
    }

    private func shutdown(reason: DHTBlock?) {
        if running { saveNodes() }
        running = false; bootstrapping = false
        timer?.cancel(); timer = nil
        let queued = waiting; waiting = []          // first: finishing a running lookup must not start a queued one
        for l in queued { l.onFinish() }
        for l in Array(lookups.values) { finish(l, notify: true) }
        let calls = pending.values.map(\.completion); pending = [:]
        transport.close()
        for c in calls { c(nil, false) }
        if let reason { publish(state: .blocked, error: reason.reason, settings: reason.needsSettings) } else { publish(state: .off, error: nil) }
    }

    // MARK: Network

    private func send(_ data: Data, to endpoint: DHTEndpoint) {
        if let why = sendGate() { publish(state: state, error: why); return }
        if endpoint.isIPv6 && !transport.supportsIPv6 { return }
        guard endpoint.isRoutable || localAllowed.contains(endpoint) else { return }          // no datagram goes to a private or reserved address unless the person configured it
        transport.send(data, to: endpoint)
    }

    private func ask(_ method: String, args: [String: Bencode], to node: DHTNodeInfo?, endpoint: DHTEndpoint? = nil, completion: @escaping Completion) {
        guard let endpoint = endpoint ?? node?.endpoint, pending.count < config.maxOutstanding else { completion(nil, false); return }
        if let why = sendGate() { publish(state: state, error: why); completion(nil, false); return }          // not asked: not the node's fault
        var tid = Data((0..<4).map { _ in UInt8.random(in: 0...255) })
        while pending[tid] != nil { tid = Data((0..<4).map { _ in UInt8.random(in: 0...255) }) }
        var a = args; a["id"] = .bytes(table.own.data)
        if transport.supportsIPv6, method == "find_node" || method == "get_peers" { a["want"] = .list([.bytes(Data("n4".utf8)), .bytes(Data("n6".utf8))]) }
        pending[tid] = Pending(endpoint: endpoint, nodeID: node?.id, deadline: clock() + config.queryTimeout, completion: completion)
        send(KRPC.query(tid: tid, method: method, args: a), to: endpoint)
    }

    private func receive(_ data: Data, from: DHTEndpoint) {
        guard running else { return }
        guard let message = KRPC.parse(data) else { droppedMalformed += 1; return }
        switch message {
        case .response(let tid, let values):
            guard let p = pending[tid], p.endpoint == from else { droppedSpoofed += 1; return }          // not a question we asked, or answered from somewhere else
            if let expected = p.nodeID, NodeID(values["id"]?.data ?? Data()) != expected { droppedSpoofed += 1; return }
            pending[tid] = nil
            if let id = NodeID(values["id"]?.data ?? Data()), from.isRoutable || localAllowed.contains(from) {
                if from.isInternal { localAllowed.insert(from) }
                table.insert(DHTNodeInfo(id: id, endpoint: from), now: clock())
            }
            publishTable()
            p.completion(values, false)
        case .error(let tid, _, let text):
            guard let p = pending[tid], p.endpoint == from else { droppedSpoofed += 1; return }
            pending[tid] = nil; lastError = "A node refused: \(text)"; p.completion(nil, false)
        case .query(let tid, let method, let args, _):
            handleQuery(tid: tid, method: method, args: args, from: from)
        }
    }

    // MARK: Answering other nodes

    private func allowInbound(_ from: DHTEndpoint) -> Bool {
        let t = clock()
        if t - globalWindow.start >= 1 { globalWindow = (t, 0) }
        globalWindow.count += 1
        if globalWindow.count > config.inboundGlobalPerSecond { droppedRateLimited += 1; return false }
        var entry = perIP[from.ip] ?? (t, 0)
        if t - entry.start >= config.inboundWindow { entry = (t, 0) }
        entry.count += 1
        if perIP.count > 512 { perIP = perIP.filter { t - $0.value.start < config.inboundWindow } }
        perIP[from.ip] = entry
        if entry.count > config.inboundPerIP { droppedRateLimited += 1; return false }
        return true
    }

    /// A DHT message that arrived on the listener (from a node we did not ask): a query is answered on the same connection; anything else is not for us.
    func handleInbound(_ data: Data, from: DHTEndpoint, reply: @escaping (Data) -> Void) {
        queue.async { [self] in
            guard running, case .query(let tid, let method, let args, _)? = KRPC.parse(data) else { return }
            handleQuery(tid: tid, method: method, args: args, from: from, respond: reply)
        }
    }

    private func handleQuery(tid: Data, method: String, args: [String: Bencode], from: DHTEndpoint, respond: ((Data) -> Void)? = nil) {
        // Only to addresses on the open internet, and within limits. A small question must never earn a large answer for someone who may have forged where it came from.
        guard from.isRoutable, allowInbound(from) else { return }
        func out(_ d: Data) { if let respond { respond(d) } else { send(d, to: from) } }
        func reply(_ values: [String: Bencode]) { var v = values; v["id"] = .bytes(table.own.data); out(KRPC.response(tid: tid, values: v)) }
        func fail(_ code: Int, _ text: String) { out(KRPC.error(tid: tid, code: code, text: text)) }
        let wantsV6 = (args["want"]?.list ?? []).contains { $0.string == "n6" } && transport.supportsIPv6
        func nodeFields(_ target: NodeID) -> [String: Bencode] {
            var out: [String: Bencode] = [:]
            let wantV4 = args["want"] == nil || (args["want"]?.list ?? []).contains { $0.string == "n4" } || !wantsV6
            if wantV4 || !from.isIPv6 { out["nodes"] = .bytes(DHTCompact.encodeNodes(table.closest(to: target, count: config.k, ipv6: false))) }
            if wantsV6 || from.isIPv6 { out["nodes6"] = .bytes(DHTCompact.encodeNodes(table.closest(to: target, count: config.k, ipv6: true))) }
            return out
        }
        switch method {
        case "ping": reply([:])
        case "find_node":
            guard let target = NodeID(args["target"]?.data ?? Data()) else { return fail(203, "bad target") }
            reply(nodeFields(target))
        case "get_peers":
            guard let hash = NodeID(args["info_hash"]?.data ?? Data()) else { return fail(203, "bad info_hash") }
            if isPrivateHash(hash.data) { return fail(201, "not available") }
            var out = nodeFields(hash)
            out["token"] = .bytes(tokens.issue(for: from.ip))
            let t = clock()
            if let list = peerStore[hash]?.filter({ $0.expires > t }), !list.isEmpty { out["values"] = .list(list.prefix(50).map { .bytes($0.endpoint.compact) }) }
            reply(out)
        case "announce_peer":
            guard let hash = NodeID(args["info_hash"]?.data ?? Data()), let token = args["token"]?.data else { return fail(203, "bad announce") }
            guard tokens.isValid(token, for: from.ip) else { return fail(203, "bad token") }
            if isPrivateHash(hash.data) { return fail(201, "not available") }
            let implied = args["implied_port"]?.int == 1
            let portValue = implied ? Int(from.port) : Int(args["port"]?.int ?? 0)
            guard (1...65535).contains(portValue), let endpoint = DHTEndpoint(ip: from.ip, port: UInt16(portValue)) else { return fail(203, "bad port") }
            if peerStore[hash] == nil, peerStore.count >= config.storedHashes { if let oldest = peerStore.min(by: { ($0.value.last?.expires ?? 0) < ($1.value.last?.expires ?? 0) })?.key { peerStore[oldest] = nil } }
            var list = (peerStore[hash] ?? []).filter { $0.endpoint != endpoint && $0.expires > clock() }
            list.append((endpoint, clock() + config.peerTTL))
            peerStore[hash] = Array(list.suffix(config.peersPerHash))
            reply([:])
        default: fail(204, "method unknown")
        }
    }

    // MARK: Bootstrap

    private func startBootstrap() {
        guard running, !bootstrapping else { return }
        bootstrapping = true; bootstrapAt = clock()
        let (hosts, explicit) = bootstrapList()
        let resolver = resolver
        Task { [weak self] in
            var found: [DHTEndpoint] = []
            for entry in hosts.prefix(8) {
                guard let (host, port) = Self.split(entry) else { continue }
                if let ep = DHTEndpoint(host: host, port: port) { found.append(ep); continue }
                for a in (await resolver.addresses(for: host)) ?? [] { if let ep = DHTEndpoint(host: a, port: port) { found.append(ep) } }
            }
            self?.queue.async { self?.bootstrapResolved(found, explicit: explicit) }
        }
    }

    static func split(_ entry: String) -> (String, UInt16)? {
        guard let colon = entry.lastIndex(of: ":"), let port = UInt16(entry[entry.index(after: colon)...]), port != 0 else { return nil }
        return (String(entry[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]")), port)
    }

    private func bootstrapResolved(_ endpoints: [DHTEndpoint], explicit: Bool) {
        guard running else { return }
        // Public bootstrap hosts must resolve to public addresses. A local one is used only when the person named it themselves.
        let usable = endpoints.filter { $0.isRoutable || (explicit && $0.port != 0) }
        for ep in usable where ep.isInternal { localAllowed.insert(ep) }
        guard !usable.isEmpty else { bootstrapping = false; publish(state: .unreachable, error: "The DHT's bootstrap addresses could not be found."); return }
        let targets = Array(usable.prefix(8))
        var outstanding = targets.count
        for ep in targets {
            ask("find_node", args: ["target": .bytes(table.own.data)], to: nil, endpoint: ep) { [weak self] values, _ in
                self?.queue.async {
                    guard let self, self.running else { return }
                    outstanding -= 1
                    if let values { self.absorb(values, from: ep, into: nil); self.publish(state: .ready, error: nil) }
                    if outstanding == 0 {
                        self.bootstrapping = false
                        if self.table.count == 0 { self.publish(state: .unreachable, error: "No DHT node answered.") }
                    }
                }
            }
        }
    }

    // MARK: Lookups

    private func begin(_ l: Lookup) {
        guard running else { l.finished = true; l.onFinish(); return }
        if lookups.count >= config.maxConcurrentLookups { waiting.append(l); return }
        lookups[l.id] = l
        l.deadline = clock() + config.lookupTimeout
        l.candidates = table.closest(to: l.target, count: config.maxCandidates)
        publishTable()
        step(l)
    }

    private func step(_ l: Lookup) {
        guard !l.finished else { return }
        if l.queries == 0 && l.candidates.isEmpty { return }          // waiting for bootstrap: the tick tries again
        l.candidates.sort { $0.id.distance(to: l.target).lexicographicallyPrecedes($1.id.distance(to: l.target)) }
        let closest = l.candidates.prefix(config.k)
        while l.inflight < config.alpha, l.queries < config.maxQueriesPerLookup, let next = closest.first(where: { !l.asked.contains($0.id) }) {
            l.asked.insert(next.id); l.inflight += 1; l.queries += 1
            let args: [String: Bencode] = l.wantsPeers ? ["info_hash": .bytes(l.target.data)] : ["target": .bytes(l.target.data)]
            ask(l.wantsPeers ? "get_peers" : "find_node", args: args, to: next) { [weak self] values, fault in
                self?.queue.async { self?.answered(l, from: next, values, fault: fault) }
            }
        }
        if l.inflight == 0 { finish(l) }          // every one of the closest has been asked: nowhere closer to go
    }

    private func answered(_ l: Lookup, from node: DHTNodeInfo, _ values: [String: Bencode]?, fault: Bool) {
        guard !l.finished else { return }
        l.inflight -= 1
        guard let values else { l.failed.insert(node.id); l.candidates.removeAll { $0.id == node.id }; if fault { table.markFailed(node.id) }; publishTable(); step(l); return }
        l.answered.insert(node.id)
        let local = localAllowed.contains(node.endpoint)
        if l.wantsPeers, let list = values["values"]?.list {
            var found: [PeerAddress] = []
            for ep in DHTCompact.decodePeers(list) where l.seen.insert(ep).inserted {
                guard ep.port != 0, ep.isRoutable || (local && ep.isInternal) else { continue }
                found.append(ep.peerAddress)          // IPv4 and IPv6 alike: the peer transport connects over both
            }
            peersFound += found.count
            if !found.isEmpty { l.onPeers(found, local) }
        }
        absorb(values, from: node.endpoint, into: l)
        step(l)
    }

    /// The nodes an answer names: kept as candidates and as heard-of table entries, only if they are on the open internet (or the person's own configured node's neighbours are not trusted: only that node).
    private func absorb(_ values: [String: Bencode], from: DHTEndpoint, into l: Lookup?) {
        var found: [DHTNodeInfo] = []
        if let n = values["nodes"]?.data { found += DHTCompact.decodeNodes(n, ipv6: false) }
        if transport.supportsIPv6, let n = values["nodes6"]?.data { found += DHTCompact.decodeNodes(n, ipv6: true) }
        for n in found.prefix(32) where n.endpoint.isRoutable && n.id != table.own {
            table.insert(n, heard: true, now: clock())
            if let l, l.candidates.count < config.maxCandidates, !l.candidates.contains(where: { $0.id == n.id }), !l.failed.contains(n.id) { l.candidates.append(n) }
        }
        publishTable()
    }

    private func finish(_ l: Lookup, notify: Bool = true) {
        guard !l.finished else { return }
        l.finished = true
        lookups[l.id] = nil
        waiting.removeAll { $0.id == l.id }
        if notify { l.onFinish() }
        if running, let next = waiting.first { waiting.removeFirst(); begin(next) }
        publishTable()
    }

    // MARK: Time

    private func tick() {
        guard running else { return }
        if let block = policy() { shutdown(reason: block); return }          // switched off, or the network setup changed
        let t = clock()
        if pathGeneration() != seenGeneration {
            // The network changed (an interface came or went): sockets made on the old path are replaced, the questions that were waiting on them are over, and the table is asked again.
            let generation = pathGeneration()
            transport.close()
            let calls = pending.values.map(\.completion); pending = [:]
            for c in calls { c(nil, false) }
            // Only a successful restart counts as handled: if it failed, the next tick tries again.
            do { try transport.start() } catch { publish(state: .unreachable, error: "The DHT could not open its network socket."); return }
            seenGeneration = generation
            if !bootstrapping { startBootstrap() }
        }
        for (tid, p) in pending where p.deadline <= t { pending[tid] = nil; p.completion(nil, true) }
        for l in Array(lookups.values) {
            if t >= l.deadline { finish(l) } else if l.inflight == 0 { if l.queries == 0 && l.candidates.isEmpty { l.candidates = table.closest(to: l.target, count: config.maxCandidates) }; step(l) }
        }
        for key in Array(peerStore.keys) { peerStore[key] = peerStore[key]?.filter { $0.expires > t }; if peerStore[key]?.isEmpty == true { peerStore[key] = nil } }
        if !bootstrapping, table.count == 0, !users.isEmpty, t - bootstrapAt >= config.bootstrapRetry { startBootstrap() }          // re-bootstrap, e.g. after the network came back
        if t - lastRefresh >= 60, lookups.count < config.maxConcurrentLookups, let target = table.staleTargets(now: t).first {
            lastRefresh = t
            let l = Lookup(task: users.first ?? UUID(), target: target, wantsPeers: false, onPeers: { _, _ in }, onFinish: {})
            begin(l); table.touchBucket(of: target, now: t)
        }
        if t - lastSave >= config.saveEvery { lastSave = t; saveNodes() }
    }

    // MARK: Persistence and status

    private func saveNodes() {
        guard let store else { return }
        defer {}
        let good = table.allEntries.filter { $0.lastSeen != nil && $0.failures == 0 && $0.info.endpoint.isRoutable }.prefix(config.persistedNodes).map(\.info)
        if !good.isEmpty { store.save(Array(good)) }          // nothing answered yet: what was saved is kept, not replaced by an empty list
    }

    private func publishTable() { publish(state: state, error: lastError) }

    private func publish(state: DHTStatus.State, error: String?, settings: Bool = false) {
        self.state = state; if let error { lastError = error }; needsSettings = settings
        let all = table.allEntries
        let s = DHTStatus(state: state, nodes4: all.filter { !$0.info.endpoint.isIPv6 && $0.lastSeen != nil }.count, nodes6: all.filter { $0.info.endpoint.isIPv6 && $0.lastSeen != nil }.count,
                          lookups: lookups.count, peersFound: peersFound, lastError: state == .ready ? nil : lastError, needsSettings: settings)
        statusLock.lock(); published = s; statusLock.unlock()
    }
}

// MARK: Stored nodes

/// The routing table's good nodes, kept between runs in the profile's preferences: at most 100, each a numeric public address, checked again when read. No torrent, no peer and nothing about a
/// private session is ever written.
final class DefaultsDHTNodeStore: DHTNodeStore, @unchecked Sendable {
    private let defaults: UserDefaults, key: String
    init(defaults: UserDefaults = .standard, key: String = "downloads.dht.nodes.v1") { self.defaults = defaults; self.key = key }

    func load() -> [DHTNodeInfo] {
        guard let data = defaults.data(forKey: key), data.count < 64 * 1024,
              let list = try? JSONDecoder().decode([Stored].self, from: data) else { return [] }
        return list.prefix(200).compactMap { s in
            guard let id = NodeID(hex: s.id), let ep = DHTEndpoint(host: s.host, port: s.port), ep.isRoutable else { return nil }
            return DHTNodeInfo(id: id, endpoint: ep)
        }
    }
    func save(_ nodes: [DHTNodeInfo]) {
        guard let data = try? JSONEncoder().encode(nodes.prefix(100).map { Stored(id: $0.id.hex, host: $0.endpoint.host, port: $0.endpoint.port) }) else { return }
        defaults.set(data, forKey: key)
    }
    func clear() { defaults.removeObject(forKey: key) }
    private struct Stored: Codable { var id: String; var host: String; var port: UInt16 }
}

// MARK: The socket

/// The DHT's datagram transport: one UDP socket per remote node, kept in a bounded pool and closed when idle. Each is connected to its node, so the system hands it only datagrams from that node's
/// address and port: every datagram read says where it came from, and nothing else can reach it. (An unconnected socket that receives from anyone needs the app's `network.server` entitlement
/// under the sandbox, which this app does not have: with outgoing access only, such a socket can send but its answers never arrive. Questions from nodes that have not been asked anything
/// therefore cannot arrive either.) The person's metered-network and Low Data Mode choices are applied to each socket.
final class NWDHTTransport: DHTDatagramTransport, @unchecked Sendable {
    static let maxConnections = 64
    static let idleLimit: TimeInterval = 30
    var onReceive: ((Data, DHTEndpoint) -> Void)?
    private let queue = DispatchQueue(label: "browsersetu.dht.socket")
    private let choices: @Sendable () -> (expensive: Bool, constrained: Bool)
    private struct Link { var connection: NWConnection; var lastUsed: TimeInterval; var ready = false; var backlog: [Data] = [] }
    private var links: [DHTEndpoint: Link] = [:]
    private var started = false
    private var reaper: DispatchSourceTimer?
    var supportsIPv6: Bool { NetworkPathGate.shared.supportsIPv6 }

    init(choices: @escaping @Sendable () -> (expensive: Bool, constrained: Bool) = { (false, false) }) { self.choices = choices }

    func start() throws {
        queue.sync {
            guard !started else { return }
            started = true
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 10, repeating: 10)
            t.setEventHandler { [weak self] in self?.reapIdle() }
            reaper = t; t.resume()
        }
    }

    func send(_ data: Data, to endpoint: DHTEndpoint) {
        guard data.count <= KRPC.maxDatagram else { return }
        queue.async { [self] in
            guard started else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if var link = links[endpoint] {
                link.lastUsed = now
                if link.ready { link.connection.send(content: data, completion: .contentProcessed { _ in }) } else if link.backlog.count < 2 { link.backlog.append(data) }
                links[endpoint] = link
                return
            }
            if links.count >= Self.maxConnections, let oldest = links.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key { drop(oldest) }
            guard let port = NWEndpoint.Port(rawValue: endpoint.port) else { return }
            let host: NWEndpoint.Host
            if endpoint.isIPv6, let a = IPv6Address(Data(endpoint.ip)) { host = .ipv6(a) } else if let a = IPv4Address(Data(endpoint.ip)) { host = .ipv4(a) } else { return }
            let parameters = NWParameters.udp
            let c = choices()
            parameters.prohibitExpensivePaths = c.expensive
            parameters.prohibitConstrainedPaths = c.constrained
            let connection = NWConnection(host: host, port: port, using: parameters)
            links[endpoint] = Link(connection: connection, lastUsed: now, backlog: [data])
            connection.stateUpdateHandler = { [weak self] state in
                self?.queue.async {
                    guard let self, var link = self.links[endpoint], link.connection === connection else { return }
                    switch state {
                    case .ready:
                        link.ready = true
                        for d in link.backlog { connection.send(content: d, completion: .contentProcessed { _ in }) }
                        link.backlog = []; self.links[endpoint] = link
                        self.arm(endpoint, connection)
                    case .failed, .waiting, .cancelled: self.drop(endpoint)          // no route, or closed: not waited for
                    default: break
                    }
                }
            }
            connection.start(queue: queue)
        }
    }

    private func arm(_ endpoint: DHTEndpoint, _ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            self?.queue.async {
                guard let self, self.links[endpoint]?.connection === connection else { return }
                if let data, !data.isEmpty, data.count <= KRPC.maxDatagram { self.links[endpoint]?.lastUsed = ProcessInfo.processInfo.systemUptime; self.onReceive?(data, endpoint) }
                if error != nil { self.drop(endpoint); return }
                self.arm(endpoint, connection)
            }
        }
    }

    private func drop(_ endpoint: DHTEndpoint) { if let l = links.removeValue(forKey: endpoint) { l.connection.cancel() } }

    private func reapIdle() {
        let now = ProcessInfo.processInfo.systemUptime
        for (ep, l) in links where now - l.lastUsed > Self.idleLimit { drop(ep) }
    }

    var openSockets: Int { queue.sync { links.count } }

    func close() {
        queue.sync {
            started = false
            reaper?.cancel(); reaper = nil
            for ep in Array(links.keys) { drop(ep) }
        }
    }
}

// MARK: The person's network choices

/// What the person's settings say about the DHT: it needs UDP, which no proxy carries, so with a proxy chosen (or the Mac's own proxy in use) it stays off and says how to change that.
enum DHTNetworkPolicy {
    static func block(setup: DownloadNetworkSetup, enabled: Bool, dhtEnabled: Bool, systemProxyActive: Bool) -> DHTBlock? {
        guard enabled, dhtEnabled else { return DHTBlock(reason: "The DHT is off.", needsSettings: false) }
        if DownloadProxy.problem(setup.proxy) != nil { return DHTBlock(reason: "The proxy settings cannot be used, so the DHT was not started.", needsSettings: true) }
        if DownloadProxy.configuration(for: setup.proxy, password: setup.proxyPassword) != nil {
            return DHTBlock(reason: "The DHT uses UDP, which a proxy cannot carry, so it was not started. Choose “No proxy” in Settings → Downloads to use it.", needsSettings: true)
        }
        if setup.proxy.mode == .system, systemProxyActive {
            return DHTBlock(reason: "Your Mac uses a proxy and the DHT's UDP cannot go through one, so it was not started. Choose “No proxy” in Settings → Downloads to use it.", needsSettings: true)
        }
        return nil
    }
}

/// Tells whether the current network may be used under the person's metered-network and low-data choices (a socket cannot carry those choices itself the way a connection can).
final class NetworkPathGate: @unchecked Sendable {
    var supportsIPv6: Bool { lock.lock(); defer { lock.unlock() }; return path?.supportsIPv6 ?? false }
    /// The router's IPv4 address on the current network, when there is one.
    var gateway: String? {
        lock.lock(); defer { lock.unlock() }
        for g in path?.gateways ?? [] { if case .hostPort(let host, _) = g, case .ipv4(let a) = host { return "\(a)" } }
        return nil
    }
    /// Changes each time the network path changes (an interface came or went): lets a service that joined a group on the old path join again.
    var generation: Int { lock.lock(); defer { lock.unlock() }; return changes }
    private var changes = 0
    static let shared = NetworkPathGate()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var path: NWPath?
    private init() { monitor.pathUpdateHandler = { [weak self] p in self?.lock.lock(); self?.path = p; self?.changes += 1; self?.lock.unlock() }; monitor.start(queue: DispatchQueue(label: "browsersetu.dht.path")) }
    func refusal(expensive: Bool, constrained: Bool) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let path else { return nil }
        if path.status != .satisfied { return "The network is not available." }
        if expensive && path.isExpensive { return "Paused: this network is metered." }
        if constrained && path.isConstrained { return "Paused: Low Data Mode is on." }
        return nil
    }
}
