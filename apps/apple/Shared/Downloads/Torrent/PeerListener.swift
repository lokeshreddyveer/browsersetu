import Foundation
import Network

// MARK: Incoming connections: one listener for the app, routed to the torrents that want them
//
// There is one listener (TCP) and one UDP socket (µTP, and DHT queries), owned here, not one per torrent. Nothing listens until the person has allowed incoming connections and a torrent is running; the
// listener is closed when the last torrent stops, when peer-to-peer or the setting is turned off, or when the network setup cannot carry it. A connection is accepted only if it starts a handshake for a
// torrent that is running, within limits; anything else is closed at once. The listener is not a general server: it speaks BitTorrent and nothing else.

final class InboundRouter: @unchecked Sendable {
    typealias Accept = (PeerTransport, PeerAddress, Data) -> Bool
    private let lock = NSLock()
    private var handlers: [Data: Accept] = [:]
    func register(_ infoHash: Data, accept: @escaping Accept) { lock.lock(); handlers[infoHash] = accept; lock.unlock() }
    func unregister(_ infoHash: Data) { lock.lock(); handlers[infoHash] = nil; lock.unlock() }
    var infoHashes: [Data] { lock.lock(); defer { lock.unlock() }; return Array(handlers.keys) }
    func route(_ infoHash: Data, transport: PeerTransport, address: PeerAddress, initial: Data) -> Bool {
        lock.lock(); let h = handlers[infoHash]; lock.unlock()
        return h?(transport, address, initial) ?? false
    }
}

struct PeerListenerStatus: Sendable, Equatable {
    enum State: String, Sendable { case off = "Off", starting = "Starting", listening = "Listening", failed = "Not available", blocked = "Blocked" }
    var state: State = .off
    var tcpPort: UInt16?, udpPort: UInt16?
    var accepted = 0, refused = 0
    /// A peer from the open internet has actually connected in: until then reachability is only suspected, never claimed.
    var confirmedInbound = false
    var lastError: String?
    var needsSettings = false
    /// What the router said, when the person asked it to open the port.
    var mapping = PortMappingStatus()
    /// The port a tracker is told: the router's external port when it opened one, else the listening port.
    var announcePort: UInt16? { mapping.state == .mapped ? (mapping.externalPort ?? tcpPort) : tcpPort }
}

/// What the person's settings say about incoming connections: off until allowed; with a proxy chosen it stays off, because incoming connections would go around it.
enum InboundNetworkPolicy {
    static func block(setup: DownloadNetworkSetup, enabled: Bool, inbound: Bool, systemProxyActive: Bool) -> DHTBlock? {
        guard enabled, inbound else { return DHTBlock(reason: "Incoming connections are off.") }
        if DownloadProxy.problem(setup.proxy) != nil { return DHTBlock(reason: "The proxy settings cannot be used, so incoming connections were not started.", needsSettings: true) }
        if DownloadProxy.configuration(for: setup.proxy, password: setup.proxyPassword) != nil || (setup.proxy.mode == .system && systemProxyActive) {
            return DHTBlock(reason: "Incoming connections would go around the proxy you chose, so they were not started. Choose “No proxy” in Settings → Downloads to use them.", needsSettings: true)
        }
        return nil
    }
}

final class PeerListener: @unchecked Sendable {
    struct Config: Sendable {
        var maxInbound = 20
        var perAddress = 3
        var acceptsPerSecond = 5
        var handshakeTimeout: TimeInterval = 15
        var dhtPerSecond = 60
        var maxDHTConnections = 64
        var dhtIdle: TimeInterval = 10
        var udpPerSecond = 30
        var maxPendingUDP = 32
        var pendingPerAddress = 2
        var udpClassify: TimeInterval = 5
    }

    private let queue = DispatchQueue(label: "browsersetu.listener")
    private let router: InboundRouter
    private let config: Config
    private let policy: @Sendable () -> DHTBlock?
    private let encryption: @Sendable () -> EncryptionPolicy
    private let preferredPort: @Sendable () -> UInt16
    private let clock: @Sendable () -> TimeInterval
    /// Non-nil while the network the person chose to refuse (metered, Low Data Mode) is the one in use: nothing is accepted and no DHT question is answered then.
    private let gate: @Sendable () -> String?
    private let mapper: PortMapper?
    private let mappingEnabled: @Sendable () -> Bool
    /// Where a datagram that is not µTP goes (the DHT's KRPC): the data, who sent it, and a way to answer it.
    var dhtInbound: (@Sendable (Data, DHTEndpoint, @escaping (Data) -> Void) -> Void)?

    private var users = Set<UUID>()
    private var tcp: NWListener?, udp: NWListener?
    private var timer: DispatchSourceTimer?
    private var active: [ObjectIdentifier: (address: String, started: TimeInterval, connection: NWConnection)] = [:]
    private var dhtConns: [ObjectIdentifier: (started: TimeInterval, connection: NWConnection)] = [:]
    private var dhtWindow: (start: TimeInterval, count: Int) = (0, 0)
    private var udpPending: [ObjectIdentifier: (address: String, started: TimeInterval, connection: NWConnection)] = [:]
    private var udpWindow: (start: TimeInterval, count: Int) = (0, 0)
    private var closers: [ObjectIdentifier: () -> Void] = [:]          // ends the transport (µTP timers, cipher state) as well as the socket
    private var retryScheduled = false
    private var acceptedWindow: (start: TimeInterval, count: Int) = (0, 0)
    private var state = PeerListenerStatus()
    private let statusLock = NSLock()
    private var published = PeerListenerStatus()
    var status: PeerListenerStatus { statusLock.lock(); var s = published; statusLock.unlock(); if let mapper { s.mapping = mapper.status }; return s }

    init(router: InboundRouter, config: Config = Config(), policy: @escaping @Sendable () -> DHTBlock?, encryption: @escaping @Sendable () -> EncryptionPolicy = { .preferEncrypted },
         preferredPort: @escaping @Sendable () -> UInt16 = { 0 }, gate: @escaping @Sendable () -> String? = { nil }, mapper: PortMapper? = nil, mappingEnabled: @escaping @Sendable () -> Bool = { false }, clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.router = router; self.config = config; self.policy = policy; self.encryption = encryption; self.preferredPort = preferredPort; self.gate = gate; self.mapper = mapper; self.mappingEnabled = mappingEnabled; self.clock = clock
    }

    func acquire(_ task: UUID) { queue.async { [self] in users.insert(task); startIfNeeded() } }
    func release(_ task: UUID) { queue.async { [self] in users.remove(task); if users.isEmpty { shutdown(nil) } } }
    func stopNow(reason: String) { queue.async { [self] in users = []; shutdown(DHTBlock(reason: reason)) } }

    // MARK: Starting and stopping

    private func startIfNeeded() {
        guard tcp == nil else { return }
        if let block = policy() { publish(.blocked, block.reason, block.needsSettings); return }
        publish(.starting, nil)
        let wanted = preferredPort()
        do {
            let tcpL = try NWListener(using: .tcp, on: wanted == 0 ? .any : NWEndpoint.Port(rawValue: wanted)!)
            tcpL.newConnectionHandler = { [weak self] c in self?.queue.async { self?.acceptTCP(c) } }
            tcpL.stateUpdateHandler = { [weak self] s in self?.queue.async { self?.tcpState(s) } }
            tcp = tcpL; tcpL.start(queue: queue)
        } catch { publish(.failed, "The listener could not be created: \(error.localizedDescription)"); scheduleRetry(); return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t; t.resume()
    }

    private func tcpState(_ s: NWListener.State) {
        switch s {
        case .ready:
            state.tcpPort = tcp?.port?.rawValue
            // The UDP socket shares the TCP port number when the system allows it, as clients usually do.
            if udp == nil, let port = tcp?.port, let u = try? NWListener(using: .udp, on: port) {
                u.newConnectionHandler = { [weak self] c in self?.queue.async { self?.acceptUDP(c) } }
                u.stateUpdateHandler = { [weak self] st in self?.queue.async { if case .ready = st { self?.state.udpPort = self?.udp?.port?.rawValue; self?.publishState() } } }
                udp = u; u.start(queue: queue)
            }
            publish(.listening, nil)
            syncMapping()
        case .waiting(let e):
            publish(.starting, "Waiting for the network (\(e.localizedDescription)).")          // may become ready by itself; not given up on
        case .failed(let e):
            publish(.failed, "The system did not allow listening (\(e.localizedDescription)). The app needs the permission to accept incoming connections.")
            shutdownSockets()
            scheduleRetry()
        case .cancelled: break
        default: break
        }
    }

    /// A listener that failed is tried again later (the network may have come back), while torrents still want it; not in a tight loop.
    private func scheduleRetry() {
        guard !retryScheduled, !users.isEmpty else { return }
        retryScheduled = true
        queue.asyncAfter(deadline: .now() + 30) { [self] in
            retryScheduled = false
            if tcp == nil, !users.isEmpty { startIfNeeded() }
        }
    }

    /// The router is asked only while the listener has a port and the person allowed it; asking stops (and the mapping is released) otherwise.
    private func syncMapping() {
        guard let mapper else { return }
        if tcp != nil, let port = state.tcpPort, mappingEnabled() { mapper.start(port: port) } else { mapper.stop() }
    }

    private func shutdownSockets() {
        mapper?.stop()
        timer?.cancel(); timer = nil
        tcp?.cancel(); udp?.cancel(); tcp = nil; udp = nil
        for (_, c) in closers { c() }
        closers = [:]
        for (_, a) in active { a.connection.cancel() }
        for (_, d) in dhtConns { d.connection.cancel() }
        for (_, p) in udpPending { p.connection.cancel() }
        active = [:]; dhtConns = [:]; udpPending = [:]
        state.tcpPort = nil; state.udpPort = nil
    }

    private func shutdown(_ reason: DHTBlock?) {
        shutdownSockets()
        if let reason { publish(.blocked, reason.reason, reason.needsSettings) } else { publish(.off, nil) }
    }

    private func tick() {
        if let block = policy() { shutdown(block); return }          // switched off, or the network setup changed
        syncMapping()
        let t = clock()
        for (id, d) in dhtConns where t - d.started > config.dhtIdle { d.connection.cancel(); dhtConns[id] = nil }
        for (id, p) in udpPending where t - p.started > config.udpClassify { p.connection.cancel(); udpPending[id] = nil }
        for (id, a) in active where t - a.started > config.handshakeTimeout { closers[id]?(); closers[id] = nil; a.connection.cancel(); active[id] = nil }
    }

    // MARK: Accepting

    private func allow(_ address: String) -> Bool {
        if gate() != nil { state.refused += 1; publishState(); return false }
        let t = clock()
        if t - acceptedWindow.start >= 1 { acceptedWindow = (t, 0) }
        acceptedWindow.count += 1
        guard acceptedWindow.count <= config.acceptsPerSecond, active.count < config.maxInbound, active.values.filter({ $0.address == address }).count < config.perAddress else {
            state.refused += 1; publishState(); return false
        }
        return true
    }

    private func remote(_ c: NWConnection) -> PeerAddress? {
        guard case .hostPort(let host, let port) = c.endpoint else { return nil }
        var h = "\(host)"
        if let pct = h.firstIndex(of: "%"), !h.lowercased().hasPrefix("fe80") { h = String(h[..<pct]) }
        return PeerAddress(host: h, port: port.rawValue).canonical
    }

    private func acceptTCP(_ c: NWConnection) {
        guard let address = remote(c), allow(address.host) else { c.cancel(); return }
        let id = ObjectIdentifier(c)
        active[id] = (address.host, clock(), c)
        let transport = NWPeerTransport(accepted: c, queue: queue)
        transport.connect { [weak self] error in
            guard let self else { return }
            self.queue.async { if error != nil { c.cancel(); self.active[id] = nil } else { self.classify(transport, address: address, id: id, connection: c) } }
        }
    }

    private func acceptUDP(_ c: NWConnection) {
        // What this is (a µTP connection or a DHT question) is known from its first datagram. Until then it waits in a small table of its own, with its own limits, so a flood of
        // unknown sources cannot take the room meant for peers.
        let t = clock()
        if t - udpWindow.start >= 1 { udpWindow = (t, 0) }
        udpWindow.count += 1
        guard let address = remote(c), gate() == nil, udpWindow.count <= config.udpPerSecond, udpPending.count < config.maxPendingUDP,
              udpPending.values.filter({ $0.address == address.host }).count < config.pendingPerAddress else { c.cancel(); return }
        let id = ObjectIdentifier(c)
        udpPending[id] = (address.host, t, c)
        let channel = NWUDPChannel(accepted: c, queue: queue)
        channel.onReceive = { [weak self, weak channel] data in
            self?.queue.async {
                guard let self, let channel else { return }
                if self.dhtConns[id] != nil { self.answerDHT(data, address: address, id: id, channel: channel); return }
                guard self.udpPending[id] != nil else { return }
                self.udpPending[id] = nil
                if let syn = UTP.parse(data), syn.type == .syn {
                    guard self.allow(address.host) else { c.cancel(); return }
                    self.active[id] = (address.host, self.clock(), c)
                    let transport = UTPPeerTransport(channel: channel, queue: self.queue)
                    transport.accept(syn: syn) { self.queue.async { self.classify(transport, address: address, id: id, connection: c) } }
                } else if data.first == 0x64, self.dhtInbound != nil, self.dhtConns.count < self.config.maxDHTConnections {
                    // DHT questions have their own limits: they are many and small, and must not use up the room meant for peers.
                    self.dhtConns[id] = (self.clock(), c)
                    self.answerDHT(data, address: address, id: id, channel: channel)
                } else { c.cancel() }
            }
        }
        channel.start { [weak self] error in if error != nil { self?.queue.async { c.cancel(); self?.udpPending[id] = nil; self?.active[id] = nil; self?.dhtConns[id] = nil } } }
    }

    private func answerDHT(_ data: Data, address: PeerAddress, id: ObjectIdentifier, channel: NWUDPChannel) {
        let t = clock()
        if t - dhtWindow.start >= 1 { dhtWindow = (t, 0) }
        dhtWindow.count += 1
        guard dhtWindow.count <= config.dhtPerSecond, gate() == nil, data.first == 0x64, let dht = dhtInbound,
              let ep = DHTEndpoint(host: address.host.split(separator: "%").first.map(String.init) ?? address.host, port: address.port) else { return }
        dhtConns[id]?.started = t
        // A small question must not earn a large answer for a source that may have been forged: a reply much bigger than the question is not sent.
        let limit = data.count * 4 + 64
        dht(data, ep) { reply in if reply.count <= limit { channel.send(reply) } }
    }

    /// Reads the start of the stream to tell a plain BitTorrent handshake from the encryption handshake, then hands the connection to the torrent it asks for.
    private func classify(_ transport: PeerTransport, address: PeerAddress, id: ObjectIdentifier, connection: NWConnection) {
        var buffer = Data()
        var mse: MSEHandshake?
        closers[id] = { transport.close() }
        func finish(_ ok: Bool) { if !ok { transport.close(); connection.cancel(); if active[id] != nil { state.refused += 1; publishState() } }; active[id] = nil; closers[id] = nil }          // ended without being handed to a torrent: refused
        func route(_ hash: Data, _ t: PeerTransport, _ initial: Data) {
            if router.route(hash, transport: t, address: address, initial: initial) {
                state.accepted += 1
                if !HTTPRequestPolicy.classify(host: address.host.split(separator: "%").first.map(String.init) ?? address.host).isInternal { state.confirmedInbound = true }          // the open internet reached us
                publishState(); active[id] = nil; closers[id] = nil          // handed over: the torrent owns it now
            } else { finish(false) }          // a torrent that is not running, or is full
        }
        func step(_ data: Data) {
            buffer.append(data)
            guard active[id] != nil else { return }
            if mse == nil {
                guard buffer.count >= 20 else { return more() }
                if buffer[buffer.startIndex] == 19, Array(buffer.prefix(20)) == [19] + Array("BitTorrent protocol".utf8) {
                    guard encryption().acceptsPlainInbound else { return finish(false) }          // encryption is required: a plain peer is not taken
                    guard buffer.count >= 48 else { return more() }
                    return route(Data(buffer[(buffer.startIndex + 28)..<(buffer.startIndex + 48)]), transport, buffer)
                }
                guard let methods = encryption().inboundMethods else { return finish(false) }
                mse = MSEHandshake(role: .responder(infoHashes: { [router] in router.infoHashes }), allowed: methods)
            }
            switch mse!.feed(buffer) {
            case .more: buffer = Data(); let out = mse!.takeOutput(); if !out.isEmpty { transport.send(out) }; more()
            case .failed: finish(false)
            case .done(let outcome):
                let out = mse!.takeOutput(); if !out.isEmpty { transport.send(out) }
                route(outcome.infoHash, CipherPeerTransport(base: transport, outcome: outcome, queue: queue), outcome.initialPayload + outcome.leftover)
            }
        }
        func more() { transport.receive { [weak self] data, error in self?.queue.async { if let data, error == nil { step(data) } else { finish(false) } } } }
        more()
    }

    private func publishState() { publish(state.state, state.lastError, state.needsSettings) }
    private func publish(_ s: PeerListenerStatus.State, _ error: String?, _ settings: Bool = false) {
        state.state = s; state.lastError = error; state.needsSettings = settings
        statusLock.lock(); published = state; statusLock.unlock()
    }
}
