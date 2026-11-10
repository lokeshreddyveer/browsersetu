import Foundation
import Network

// MARK: UDP trackers (BEP 15)
//
// The protocol, from https://www.bittorrent.org/beps/bep_0015.html (all numbers big-endian):
//
//   connect request   (16 bytes):  int64 protocol_id = 0x41727101980 | int32 action = 0 | int32 transaction_id
//   connect response  (16 bytes):  int32 action = 0 | int32 transaction_id | int64 connection_id
//   announce request  (98 bytes):  int64 connection_id | int32 action = 1 | int32 transaction_id | 20 info_hash | 20 peer_id | int64 downloaded | int64 left
//                                  | int64 uploaded | int32 event | int32 ip | int32 key | int32 num_want | int16 port
//   announce response (20 + 6n):   int32 action = 1 | int32 transaction_id | int32 interval | int32 leechers | int32 seeders | n x (4 bytes IPv4 + 2 bytes port)
//   error response    (8 + text):  int32 action = 3 | int32 transaction_id | message
//
// A connection id is valid for one minute. A request that gets no answer is sent again after 15 * 2^n seconds (n = 0, 1, 2, ...); here n stops at 2 so a dead tracker costs under two
// minutes, not the hour the protocol's last step would. Events: none 0, completed 1, started 2, stopped 3.
//
// What this client does not do, on purpose: reach a tracker through a proxy (a proxy that was asked for cannot carry UDP, and sending around it is never done), listen for anything
// (the "port" it announces is 0, because no connection is accepted), or use IPv6 (the reply's peer list would change shape; IPv4 only for now).

/// One datagram socket to one tracker address. A seam so the protocol can be tested without a network; the real one is `NWUDPTransport`.
protocol UDPDatagramTransport: AnyObject, Sendable {
    func send(_ datagram: Data) async throws
    /// Waits up to `timeout` seconds for one datagram from the tracker. Nil when none came in time.
    func receive(timeout: TimeInterval) async throws -> Data?
    func close()
}

protocol UDPTransportFactory: Sendable {
    /// `ipv4` is a numeric address, already checked: the name was resolved once, here, so what was checked is what is connected to.
    func open(ipv4: String, port: UInt16) throws -> UDPDatagramTransport
    /// The same, held to the person's expensive-network and low-data-mode choices.
    func open(ipv4: String, port: UInt16, refuseExpensive: Bool, refuseConstrained: Bool) throws -> UDPDatagramTransport
}

extension UDPTransportFactory {
    func open(ipv4: String, port: UInt16, refuseExpensive: Bool, refuseConstrained: Bool) throws -> UDPDatagramTransport { try open(ipv4: ipv4, port: port) }
}

final class UDPTrackerClient: TrackerAnnouncing, TrackerScraping, @unchecked Sendable {
    enum Failure: Error, LocalizedError, Equatable {
        case unsupported(String), refused(String), badReply(String), timeout, proxy(String), blocked(String), busy, unreachable
        var errorDescription: String? {
            switch self {
            case .unsupported(let why): why
            case .refused(let why): "The tracker said: \(why.prefix(120))"
            case .badReply(let why): "The tracker's answer was not understood (\(why))"
            case .timeout: "The tracker did not answer"
            case .proxy(let why): why
            case .blocked(let why): why
            case .busy: "Too many tracker requests at once"
            case .unreachable: "The tracker could not be reached"
            }
        }
    }

    struct Timing: Sendable {
        /// BEP 15: the first wait is 15 seconds and each repeat doubles it.
        var base: TimeInterval = 15
        /// How many times a request is sent: waits of base, 2 x base, 4 x base.
        var attempts = 3
        /// How long a send may wait for the network before it is given up on.
        var sendLimit: TimeInterval = 10
    }

    static let protocolID: UInt64 = 0x41727101980
    /// The largest datagram taken seriously: an announce answer with 200 peers is 1,220 bytes.
    static let maxDatagram = 2048
    static let maxPeers = HTTPTrackerClient.maxPeers
    /// Sockets open at once across every torrent.
    static let maxConcurrent = 8
    /// Datagrams that are not the answer (wrong transaction, wrong action) tolerated while waiting for one, so a flood cannot keep this busy.
    static let maxStrays = 16

    private let network: () -> DownloadNetworkSetup
    private let factory: UDPTransportFactory
    private let resolver: HostAddressResolving
    private let timing: Timing
    private let key = UInt32.random(in: 0...UInt32.max)

    private let lock = NSLock()
    private var inFlight = 0
    private let now: @Sendable () -> Date

    init(network: @escaping () -> DownloadNetworkSetup = { DownloadNetworkSetup() }, factory: UDPTransportFactory = NWUDPTransportFactory(), resolver: HostAddressResolving = SystemHostResolver(),
         timing: Timing = Timing(), now: @escaping @Sendable () -> Date = { Date() }, authorized: @escaping @Sendable (URL) -> Bool = { _ in false }, systemProxyActive: @escaping @Sendable () -> Bool = { SystemProxy.isActive() }) {
        self.network = network; self.factory = factory; self.resolver = resolver; self.timing = timing; self.now = now; self.authorized = authorized; self.systemProxyActive = systemProxyActive
    }
    /// Whether a person (or their own request) approved this destination, for a tracker whose name resolves to a local address.
    private let authorized: @Sendable (URL) -> Bool
    private let systemProxyActive: @Sendable () -> Bool

    // MARK: Announce

    func announce(_ tracker: URL, infoHash: Data, peerID: Data, uploaded: Int64, downloaded: Int64, left: Int64?, event: String?) async throws -> TrackerReply {
        guard infoHash.count == 20, peerID.count == 20 else { throw Failure.badReply("the torrent or peer identity has the wrong length") }
        return try await withConnection(to: tracker) { transport, endpoint in
            let request = AnnounceRequest(infoHash: infoHash, peerID: peerID, downloaded: max(0, downloaded), left: max(0, left ?? 1), uploaded: max(0, uploaded), event: Self.eventCode(event), key: self.key, port: TrackerScope.listenPort)
            return try await self.withConnectionID(transport, endpoint) { id in try await self.announceOnce(transport, connectionID: id, request) }
        }
    }

    /// BEP 15 scrape (action 2): how many seeders, downloaders and completed downloads the tracker knows of for this torrent. Counts the tracker did not give stay unknown.
    func scrape(_ tracker: URL, infoHash: Data) async throws -> TrackerScrape {
        guard infoHash.count == 20 else { throw Failure.badReply("the torrent identity has the wrong length") }
        return try await withConnection(to: tracker) { transport, endpoint in
            try await self.withConnectionID(transport, endpoint) { id in try await self.scrapeOnce(transport, connectionID: id, infoHash: infoHash) }
        }
    }

    /// Everything that comes before the first packet, for announce and scrape alike: the address, the proxy rule, the destination check, the socket limit, and a socket that closes when
    /// the work ends or is cancelled.
    private func withConnection<T>(to tracker: URL, _ body: @escaping (UDPDatagramTransport, String) async throws -> T) async throws -> T {
        guard tracker.scheme?.lowercased() == "udp" else { throw Failure.unsupported("\(tracker.scheme ?? "These") trackers are not handled here") }
        guard let host = tracker.host, !host.isEmpty, host.utf8.count <= 253, let port = tracker.port, (1...65535).contains(port) else { throw Failure.unsupported("This tracker address has no usable host and port") }

        // A proxy that was asked for cannot carry this traffic, so the tracker is skipped rather than reached around it.
        let setup = network()
        do { try DownloadProxy.requireUsable(setup.proxy) } catch { throw Failure.proxy((error as? LocalizedError)?.errorDescription ?? "The proxy settings could not be used.") }
        if DownloadProxy.configuration(for: setup.proxy, password: setup.proxyPassword) != nil {
            throw Failure.proxy("UDP trackers cannot be reached through a proxy, so this one was not contacted. Choose “No proxy” in Settings → Downloads to use it.")
        }
        // "Use my Mac's settings" while the Mac uses a proxy is the same: a UDP tracker would go around it, so it is not contacted until the person chooses otherwise.
        if setup.proxy.mode == .system, systemProxyActive() {
            throw Failure.proxy("Your Mac uses a proxy and UDP trackers cannot go through one, so this tracker was not contacted. Choose “No proxy” in Settings → Downloads to use it.")
        }

        let address = try await resolveChecked(host, approved: authorized(tracker))
        guard reserve() else { throw Failure.busy }
        defer { release() }
        let transport: UDPDatagramTransport
        do { transport = try factory.open(ipv4: address, port: UInt16(port), refuseExpensive: setup.refuseExpensive, refuseConstrained: setup.refuseConstrained) } catch { throw Failure.unreachable }
        defer { transport.close() }
        return try await withTaskCancellationHandler { try await body(transport, "\(address):\(port)") } onCancel: { transport.close() }
    }

    /// Runs `operation` with a fresh connection id. Every operation uses its own socket, and a connection id belongs to the address and port it was asked from (BEP 15), so one is never
    /// carried over to another socket: a tracker that checks would ignore it and the operation would wait out every retransmission.
    private func withConnectionID<T>(_ transport: UDPDatagramTransport, _ endpoint: String, _ operation: (UInt64) async throws -> T) async throws -> T {
        try await operation(try await connect(transport))
    }

    // MARK: Packets

    struct AnnounceRequest: Sendable {
        var infoHash: Data, peerID: Data
        var downloaded: Int64, left: Int64, uploaded: Int64
        var event: Int32, key: UInt32
        var numWant: Int32 = 50
        /// Zero unless the app accepts incoming connections (then the port it listens on).
        var port: UInt16 = 0
    }

    static func eventCode(_ event: String?) -> Int32 {
        switch event { case "completed": 1; case "started": 2; case "stopped": 3; default: 0 }
    }

    static func connectPacket(transaction: UInt32) -> Data {
        var d = Data(); d.appendBE(protocolID); d.appendBE(UInt32(0)); d.appendBE(transaction); return d
    }

    static func announcePacket(connectionID: UInt64, transaction: UInt32, _ r: AnnounceRequest) -> Data {
        var d = Data(); d.reserveCapacity(98)
        d.appendBE(connectionID); d.appendBE(UInt32(1)); d.appendBE(transaction)
        d.append(r.infoHash); d.append(r.peerID)
        d.appendBE(UInt64(r.downloaded)); d.appendBE(UInt64(r.left)); d.appendBE(UInt64(r.uploaded))
        d.appendBE(UInt32(bitPattern: r.event)); d.appendBE(UInt32(0)); d.appendBE(r.key); d.appendBE(UInt32(bitPattern: r.numWant)); d.appendBE(r.port)
        return d
    }

    enum Parsed { case connect(UInt64), announce(TrackerReply), scrape(TrackerScrape), error(String), stray }

    static func scrapePacket(connectionID: UInt64, transaction: UInt32, infoHash: Data) -> Data {
        var d = Data(); d.appendBE(connectionID); d.appendBE(UInt32(2)); d.appendBE(transaction); d.append(infoHash); return d
    }

    /// Reads one datagram as the answer to the request with this transaction id. A datagram that is not the answer (another transaction, an action that was not asked for) is `.stray`
    /// and ignored by the caller; one that is the answer but malformed throws.
    static func parse(_ datagram: Data, transaction: UInt32, expecting action: UInt32) throws -> Parsed {
        guard datagram.count <= maxDatagram else { throw Failure.badReply("it was too large") }
        guard datagram.count >= 8 else { throw Failure.badReply("it was too short") }
        let got = datagram.beUInt32(at: 0), tid = datagram.beUInt32(at: 4)
        guard tid == transaction else { return .stray }
        if got == 3 {
            let text = String(decoding: datagram.dropFirst(8).prefix(200), as: UTF8.self).filter { !$0.isNewline && $0.unicodeScalars.allSatisfy { $0.value >= 32 } }
            return .error(text.isEmpty ? "an error" : text)
        }
        guard got == action else { return .stray }          // an action nobody asked for (a scrape answer, say), with the right transaction id: not an answer
        if action == 0 {
            guard datagram.count >= 16 else { throw Failure.badReply("the connect answer was cut short") }
            return .connect(datagram.beUInt64(at: 8))
        }
        if action == 2 {
            // 8 bytes, then seeders, completed and leechers (4 each) for each info-hash that was asked about: one here.
            guard datagram.count >= 20 else { throw Failure.badReply("the scrape answer was cut short") }
            return .scrape(TrackerScrape(seeders: Int(datagram.beUInt32(at: 8)), completed: Int(datagram.beUInt32(at: 12)), leechers: Int(datagram.beUInt32(at: 16))))
        }
        guard datagram.count >= 20 else { throw Failure.badReply("the announce answer was cut short") }
        guard (datagram.count - 20) % 6 == 0 else { throw Failure.badReply("the peer list was cut short") }
        let interval = Int(datagram.beUInt32(at: 8)), leechers = Int(datagram.beUInt32(at: 12)), seeders = Int(datagram.beUInt32(at: 16))
        var peers: [PeerAddress] = []
        let bytes = [UInt8](datagram)
        var i = 20
        while i + 6 <= bytes.count, peers.count < maxPeers {
            let port = UInt16(bytes[i + 4]) << 8 | UInt16(bytes[i + 5])
            // 0.0.0.0, a zero port and the broadcast address are not peers.
            let any = bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 0 && bytes[i + 3] == 0
            let broadcast = bytes[i] == 255 && bytes[i + 1] == 255 && bytes[i + 2] == 255 && bytes[i + 3] == 255
            if port != 0, !any, !broadcast { peers.append(PeerAddress(host: "\(bytes[i]).\(bytes[i + 1]).\(bytes[i + 2]).\(bytes[i + 3])", port: port)) }
            i += 6
        }
        return .announce(TrackerReply(peers: peers, interval: TimeInterval(min(max(interval, 60), 7200)), warning: nil, seeders: seeders, leechers: leechers))
    }

    // MARK: Exchanges

    private func connect(_ transport: UDPDatagramTransport) async throws -> UInt64 {
        let transaction = UInt32.random(in: 0...UInt32.max)
        let reply = try await exchange(transport, packet: Self.connectPacket(transaction: transaction), transaction: transaction, action: 0)
        guard case .connect(let id) = reply else { throw Failure.badReply("the connect answer was not one") }
        return id
    }

    private func announceOnce(_ transport: UDPDatagramTransport, connectionID: UInt64, _ request: AnnounceRequest) async throws -> TrackerReply {
        let transaction = UInt32.random(in: 0...UInt32.max)
        let reply = try await exchange(transport, packet: Self.announcePacket(connectionID: connectionID, transaction: transaction, request), transaction: transaction, action: 1)
        guard case .announce(let result) = reply else { throw Failure.badReply("the announce answer was not one") }
        return result
    }

    private func scrapeOnce(_ transport: UDPDatagramTransport, connectionID: UInt64, infoHash: Data) async throws -> TrackerScrape {
        let transaction = UInt32.random(in: 0...UInt32.max)
        let reply = try await exchange(transport, packet: Self.scrapePacket(connectionID: connectionID, transaction: transaction, infoHash: infoHash), transaction: transaction, action: 2)
        guard case .scrape(let result) = reply else { throw Failure.badReply("the scrape answer was not one") }
        return result
    }

    /// A send that never completes (no route: the connection waits for a path) is given up on, so the socket and the tier are not held for as long as the person is offline.
    static func bounded(_ seconds: TimeInterval, onTimeout: @escaping @Sendable () -> Void = {}, _ work: @escaping @Sendable () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await work() }
            group.addTask { try await Task.sleep(nanoseconds: UInt64(max(0.001, seconds) * 1_000_000_000)); onTimeout(); throw Failure.unreachable }          // closing the socket is what ends a send that is waiting for a route
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    /// Sends the request and waits for its answer, sending it again after each wait that passes in silence (15 x 2^n seconds). Datagrams that are not the answer do not end the wait.
    private func exchange(_ transport: UDPDatagramTransport, packet: Data, transaction: UInt32, action: UInt32) async throws -> Parsed {
        for attempt in 0..<max(1, timing.attempts) {
            try Task.checkCancellation()
            try await Self.bounded(timing.sendLimit, onTimeout: { transport.close() }) { try await transport.send(packet) }
            let wait = timing.base * pow(2, Double(attempt))
            let deadline = Date().addingTimeInterval(wait)
            var strays = 0
            while true {
                try Task.checkCancellation()
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0, let datagram = try await transport.receive(timeout: remaining) else { break }
                switch try Self.parse(datagram, transaction: transaction, expecting: action) {
                case .stray:
                    strays += 1
                    if strays > Self.maxStrays { throw Failure.badReply("too many answers that were not for this request") }
                case .error(let why): throw Failure.refused(why)
                case let answer: return answer
                }
            }
        }
        throw Failure.timeout
    }

    // MARK: Destination checks

    /// The name is resolved here, once, and the numeric address is what is connected to. A tracker named by a public-looking host that resolves to this machine or the local network is
    /// refused; one the person gave by a local address itself is allowed (the caller has already held a page's links to public trackers: `TorrentRunner.usableTrackers`).
    private func resolveChecked(_ host: String, approved: Bool = false) async throws -> String {
        let literalIsLocal = HTTPRequestPolicy.classify(host: host).isInternal
        let candidates: [String]
        if Self.isIPv4Literal(host) { candidates = [host] }
        else if host.contains(":") { throw Failure.unsupported("IPv6 UDP trackers are not supported yet") }
        else { candidates = (await resolver.addresses(for: host)) ?? [] }
        let v4 = candidates.filter(Self.isIPv4Literal)
        guard !v4.isEmpty else { throw Failure.unreachable }
        for address in v4 {
            let local = HTTPRequestPolicy.classify(host: address).isInternal
            if local && !literalIsLocal && !approved { throw Failure.blocked("This tracker's name points to a local address, so it was not contacted.") }
        }
        return v4[0]
    }

    static func isIPv4Literal(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) && Int($0).map { $0 <= 255 } == true }
    }

    // MARK: Bookkeeping

    private func reserve() -> Bool { lock.lock(); defer { lock.unlock() }; guard inFlight < Self.maxConcurrent else { return false }; inFlight += 1; return true }
    private func release() { lock.lock(); inFlight = max(0, inFlight - 1); lock.unlock() }

    /// For tests: how many sockets are open right now.
    var openSockets: Int { lock.lock(); defer { lock.unlock() }; return inFlight }
}

/// Chooses by the tracker's address scheme: HTTP and HTTPS go to the HTTP client, `udp` to the UDP client. The session talks to one `TrackerAnnouncing`, as before.
final class TrackerRouter: TrackerAnnouncing, TrackerScraping, @unchecked Sendable {
    let http: TrackerAnnouncing
    let udp: TrackerAnnouncing
    init(http: TrackerAnnouncing, udp: TrackerAnnouncing) { self.http = http; self.udp = udp }
    init(network: @escaping () -> DownloadNetworkSetup = { DownloadNetworkSetup() }, authorized: @escaping @Sendable (URL) -> Bool = { _ in false }) {
        http = HTTPTrackerClient(network: network, authorized: authorized); udp = UDPTrackerClient(network: network, authorized: authorized)
    }

    func announce(_ tracker: URL, infoHash: Data, peerID: Data, uploaded: Int64, downloaded: Int64, left: Int64?, event: String?) async throws -> TrackerReply {
        switch tracker.scheme?.lowercased() {
        case "udp": return try await udp.announce(tracker, infoHash: infoHash, peerID: peerID, uploaded: uploaded, downloaded: downloaded, left: left, event: event)
        default: return try await http.announce(tracker, infoHash: infoHash, peerID: peerID, uploaded: uploaded, downloaded: downloaded, left: left, event: event)
        }
    }
}

extension TrackerRouter {
    func scrape(_ tracker: URL, infoHash: Data) async throws -> TrackerScrape {
        let target: TrackerAnnouncing = tracker.scheme?.lowercased() == "udp" ? udp : http
        guard let scraper = target as? TrackerScraping else { throw UDPTrackerClient.Failure.unsupported("This tracker cannot be asked for counts") }
        return try await scraper.scrape(tracker, infoHash: infoHash)
    }
}

// MARK: The real socket

struct NWUDPTransportFactory: UDPTransportFactory {
    func open(ipv4: String, port: UInt16) throws -> UDPDatagramTransport { try open(ipv4: ipv4, port: port, refuseExpensive: false, refuseConstrained: false) }
    func open(ipv4: String, port: UInt16, refuseExpensive: Bool, refuseConstrained: Bool) throws -> UDPDatagramTransport {
        guard let p = NWEndpoint.Port(rawValue: port), IPv4Address(ipv4) != nil else { throw URLError(.badURL) }
        return NWUDPTransport(host: ipv4, port: p, refuseExpensive: refuseExpensive, refuseConstrained: refuseConstrained)
    }
}

/// A connected UDP socket: the system hands this connection only datagrams that come from the tracker's own address and port, which is the endpoint check for every answer.
final class NWUDPTransport: UDPDatagramTransport, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "browser-setu.udp-tracker")
    private let lock = NSLock()
    private var closed = false
    private var inbox: [Data] = []
    private var waiter: (@Sendable (Result<Data?, Error>) -> Void)?
    private var failure: Error?

    init(host: String, port: NWEndpoint.Port, refuseExpensive: Bool = false, refuseConstrained: Bool = false) {
        let parameters = NWParameters.udp
        parameters.prohibitExpensivePaths = refuseExpensive
        parameters.prohibitConstrainedPaths = refuseConstrained
        parameters.allowLocalEndpointReuse = false
        connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        connection.start(queue: queue)
        arm()
    }

    func send(_ datagram: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: datagram, completion: .contentProcessed { error in if let error { c.resume(throwing: error) } else { c.resume() } })
        }
    }

    /// One receive is armed at a time and re-armed as each datagram arrives; datagrams wait in a short queue until `receive` asks. (Arming a new receive for every wait would leave the
    /// earlier ones queued, and the system would hand an answer to a handler nobody listens to any more.)
    func receive(timeout: TimeInterval) async throws -> Data? {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data?, Error>) in
            lock.lock()
            if !inbox.isEmpty { let d = inbox.removeFirst(); lock.unlock(); c.resume(returning: d); return }
            if let failure { lock.unlock(); c.resume(throwing: failure); return }
            let once = Once()
            waiter = { result in if once.take() { c.resume(with: result) } }
            lock.unlock()
            queue.asyncAfter(deadline: .now() + max(0.001, timeout)) { [weak self] in
                guard let self else { return }
                if once.take() { self.lock.lock(); self.waiter = nil; self.lock.unlock(); c.resume(returning: nil) }
            }
        }
    }

    private func arm() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            self.lock.lock()
            var deliver: (@Sendable (Result<Data?, Error>) -> Void)?
            if let error { if !self.closed { self.failure = error }; deliver = self.waiter; self.waiter = nil; self.lock.unlock(); deliver?(.failure(error)); return }
            if let data, !data.isEmpty, data.count <= 2048 {            // an empty or oversized datagram is not an answer and is dropped here
                if let w = self.waiter { self.waiter = nil; deliver = w } else if self.inbox.count < 32 { self.inbox.append(data) }
                self.lock.unlock(); deliver?(.success(data))
            } else { self.lock.unlock() }
            self.arm()
        }
    }

    func close() { lock.lock(); let was = closed; closed = true; lock.unlock(); if !was { connection.cancel() } }
}

/// A flag that can be taken once, from any thread.
final class Once: @unchecked Sendable {
    private let lock = NSLock(); private var taken = false
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; if taken { return false }; taken = true; return true }
}

// MARK: Big-endian helpers

extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) { var v = value.bigEndian; Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) } }
    func beUInt32(at offset: Int) -> UInt32 { (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(self[startIndex + offset + $1]) } }
    func beUInt64(at offset: Int) -> UInt64 { (0..<8).reduce(UInt64(0)) { ($0 << 8) | UInt64(self[startIndex + offset + $1]) } }
}
