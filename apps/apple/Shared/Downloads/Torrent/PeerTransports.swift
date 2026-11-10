import Foundation
import Network

// MARK: What carries a peer's bytes: TCP, µTP, with or without MSE, and in what order they are tried
//
// The BitTorrent protocol, the piece scheduler and everything the session does are written against `PeerTransport` (an ordered byte stream). Each transport here gives that and nothing more, so
// choosing between them never reaches the engine. A transport that fails to connect may be followed by the next the person's preferences allow, a bounded number of times; a refusal that is our own
// (a proxy that cannot carry the connection) is never retried another way around.

enum TransportPreference: String, Codable, CaseIterable, Sendable {
    case automatic, preferTCP, preferUTP, tcpOnly, utpOnly
    var title: String {
        switch self {
        case .automatic: "Automatic"; case .preferTCP: "Prefer TCP"; case .preferUTP: "Prefer µTP"; case .tcpOnly: "TCP only"; case .utpOnly: "µTP only"
        }
    }
}

enum EncryptionPolicy: String, Codable, CaseIterable, Sendable {
    case preferEncrypted, requireEncrypted, allowPlaintext, disabled
    var title: String {
        switch self {
        case .preferEncrypted: "Prefer encrypted"; case .requireEncrypted: "Require encrypted"; case .allowPlaintext: "Allow plain"; case .disabled: "Off"
        }
    }
    /// Whether an incoming connection that starts the encryption handshake is answered, and with what.
    var inboundMethods: MSE.Methods? {
        switch self {
        case .preferEncrypted, .allowPlaintext: [.rc4, .plaintext]
        case .requireEncrypted: [.rc4]
        case .disabled: nil
        }
    }
    /// Whether an incoming plain connection is accepted.
    var acceptsPlainInbound: Bool { self != .requireEncrypted }
}

enum PeerTransportKind: Equatable, Sendable { case tcp, utp }

extension PeerTransportFactory {
    /// Transports that need the torrent's identity (MSE does) get it here; the rest ignore it.
    func make(_ address: PeerAddress, infoHash: Data, queue: DispatchQueue) -> PeerTransport { make(address, queue: queue) }
}

// MARK: Trying one way after another

/// Connects by the first way; if that fails for a reason that is the peer's or the network's (not our own policy), by the next, up to the bounded list. Reads and writes go to whichever connected.
final class FallbackPeerTransport: PeerTransport {
    struct Attempt { var label: String; var group = ""; var make: () -> PeerTransport }
    private let attempts: [Attempt]
    private let queue: DispatchQueue
    private var current: PeerTransport?
    private var index = 0
    private var closed = false
    private(set) var connectedLabel: String?
    private(set) var tried: [String] = []
    var attemptLabels: [String] { attempts.map(\.label) }

    init(attempts: [Attempt], queue: DispatchQueue) { self.attempts = attempts; self.queue = queue }

    func connect(_ done: @escaping (Error?) -> Void) {
        guard !attempts.isEmpty else { queue.async { done(URLError(.cannotConnectToHost)) }; return }
        next(done, last: nil)
    }

    private func next(_ done: @escaping (Error?) -> Void, last: Error?) {
        guard !closed else { done(URLError(.cancelled)); return }
        guard index < attempts.count else { done(last ?? URLError(.cannotConnectToHost)); return }
        let attempt = attempts[index]; index += 1
        tried.append(attempt.label)
        let t = attempt.make(); current = t
        t.connect { [weak self] error in
            guard let self else { return }
            if let error {
                t.close()
                if self.closed { done(error); return }
                if TorrentSession.isProxyProblem(error) { done(error); return }          // our own refusal: not tried another way
                // A failure to connect at all says nothing about the encryption: the other ways over the same transport are skipped. A failed encryption handshake is what the plain way is for.
                if !(error is MSEPeerTransport.Failure) { while self.index < self.attempts.count, self.attempts[self.index].group == attempt.group { self.index += 1 } }
                self.next(done, last: error)
            } else { self.connectedLabel = attempt.label; done(nil) }
        }
    }

    func send(_ data: Data) { current?.send(data) }
    func receive(_ handler: @escaping (Data?, Error?) -> Void) { if let current { current.receive(handler) } else { handler(nil, URLError(.cancelled)) } }
    func close() { closed = true; current?.close() }
}

// MARK: A stream with a cipher on it

/// What is left of MSE once the handshake is done: bytes out are encrypted, bytes in are decrypted, in order. Bytes that arrived with the end of the handshake are handed out first.
final class CipherPeerTransport: PeerTransport {
    private let base: PeerTransport
    private var encrypt: RC4?, decrypt: RC4?
    private var leftover: Data
    private let queue: DispatchQueue
    private(set) var selected: MSE.Selected

    init(base: PeerTransport, outcome: MSE.Outcome, queue: DispatchQueue) {
        self.base = base; encrypt = outcome.encrypt; decrypt = outcome.decrypt; leftover = outcome.leftover; selected = outcome.selected; self.queue = queue
    }

    func connect(_ done: @escaping (Error?) -> Void) { queue.async { done(nil) } }          // already connected
    func send(_ data: Data) { if encrypt != nil { base.send(Data(encrypt!.process([UInt8](data)))) } else { base.send(data) } }
    func receive(_ handler: @escaping (Data?, Error?) -> Void) {
        if !leftover.isEmpty { let d = leftover; leftover = Data(); queue.async { handler(d, nil) }; return }
        base.receive { [weak self] data, error in
            guard let self, let data else { handler(nil, error); return }
            handler(self.decrypt != nil ? Data(self.decrypt!.process([UInt8](data))) : data, nil)
        }
    }
    func close() { base.close() }
}

/// The outgoing side of MSE over any transport: connects the base, runs the handshake (10 seconds at most), then behaves as the base with the cipher the two ends agreed.
final class MSEPeerTransport: PeerTransport {
    enum Failure: Error, LocalizedError, Equatable {
        case handshake(String), timeout
        var errorDescription: String? { switch self { case .handshake(let w): "The encrypted handshake failed (\(w))."; case .timeout: "The encrypted handshake took too long." } }
    }
    private let base: PeerTransport
    private let infoHash: Data
    private let methods: MSE.Methods
    private let queue: DispatchQueue
    private let timeout: TimeInterval
    private var cipher: CipherPeerTransport?
    private var finished = false

    init(base: PeerTransport, infoHash: Data, methods: MSE.Methods, queue: DispatchQueue, timeout: TimeInterval = 10) {
        self.base = base; self.infoHash = infoHash; self.methods = methods; self.queue = queue; self.timeout = timeout
    }

    func connect(_ done: @escaping (Error?) -> Void) {
        base.connect { [weak self] error in
            guard let self else { return }
            if let error { done(error); return }
            let handshake = MSEHandshake(role: .initiator(infoHash: self.infoHash, initialPayload: Data()), allowed: self.methods)
            self.base.send(handshake.takeOutput())
            self.queue.asyncAfter(deadline: .now() + self.timeout) { [weak self] in
                guard let self, !self.finished else { return }
                self.finished = true; self.base.close(); done(Failure.timeout)
            }
            self.pump(handshake, done)
        }
    }

    private func pump(_ handshake: MSEHandshake, _ done: @escaping (Error?) -> Void) {
        base.receive { [weak self] data, error in
            guard let self, !self.finished else { return }
            guard let data else { self.finished = true; self.base.close(); done(Failure.handshake(error?.localizedDescription ?? "the connection ended")); return }          // after connecting, any failure here is the handshake's
            switch handshake.feed(data) {
            case .more: let out = handshake.takeOutput(); if !out.isEmpty { self.base.send(out) }; self.pump(handshake, done)
            case .failed(let why): self.finished = true; self.base.close(); done(Failure.handshake(why))
            case .done(let outcome):
                let out = handshake.takeOutput(); if !out.isEmpty { self.base.send(out) }
                self.finished = true
                self.cipher = CipherPeerTransport(base: self.base, outcome: outcome, queue: self.queue)
                done(nil)
            }
        }
    }

    func send(_ data: Data) { cipher?.send(data) }
    func receive(_ handler: @escaping (Data?, Error?) -> Void) { if let cipher { cipher.receive(handler) } else { handler(nil, URLError(.cancelled)) } }
    func close() { finished = true; base.close() }
}

// MARK: µTP over UDP

/// A datagram channel to one remote address: a connected UDP socket, so only that peer's datagrams reach it (and the person's metered-network choices apply).
protocol UTPChannel: AnyObject {
    var onReceive: ((Data) -> Void)? { get set }
    func start(_ ready: @escaping (Error?) -> Void)
    func send(_ data: Data)
    func close()
}

final class NWUDPChannel: UTPChannel {
    var onReceive: ((Data) -> Void)?
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var closed = false

    init?(address: PeerAddress, refuseExpensive: Bool, refuseConstrained: Bool, queue: DispatchQueue) {
        guard let port = NWEndpoint.Port(rawValue: address.port), !address.host.isEmpty else { return nil }
        let p = NWParameters.udp
        p.prohibitExpensivePaths = refuseExpensive; p.prohibitConstrainedPaths = refuseConstrained
        connection = NWConnection(host: NWEndpoint.Host(address.host), port: port, using: p)
        self.queue = queue
    }

    /// For a connection a listener already holds (an incoming µTP peer).
    init(accepted: NWConnection, queue: DispatchQueue) { connection = accepted; self.queue = queue }

    func start(_ ready: @escaping (Error?) -> Void) {
        var told = false
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: if !told { told = true; ready(nil) }; self.receiveLoop()
            case .failed(let e), .waiting(let e): if !told { told = true; ready(e) }; self.close()
            case .cancelled: if !told { told = true; ready(URLError(.cancelled)) }
            default: break
            }
        }
        if connection.state == .setup { connection.start(queue: queue) } else if connection.state == .ready { told = true; ready(nil); receiveLoop() }
    }

    private func receiveLoop() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty, data.count <= UTP.maxDatagram { self.onReceive?(data) }
            if error != nil { self.close(); return }
            self.receiveLoop()
        }
    }

    func send(_ data: Data) { guard !closed else { return }; connection.send(content: data, completion: .contentProcessed { _ in }) }
    func close() { guard !closed else { return }; closed = true; connection.cancel() }
}

/// A µTP connection as a `PeerTransport`: the state machine from UTP.swift, a 50 ms tick, and a small buffer for the reader.
final class UTPPeerTransport: PeerTransport {
    private let channel: UTPChannel
    private let connection: UTPConnection
    private let sessionQueue: DispatchQueue
    private let work = DispatchQueue(label: "browsersetu.utp")
    private var timer: DispatchSourceTimer?
    private var incoming = Data()
    private let incomingLock = NSLock()
    private var reader: ((Data?, Error?) -> Void)?
    private var ended: Error?
    private var connectDone: ((Error?) -> Void)?
    private var closed = false
    static let readBuffer = 256 * 1024

    init(channel: UTPChannel, queue: DispatchQueue, connection: UTPConnection? = nil) {
        self.channel = channel; sessionQueue = queue
        let start = DispatchTime.now().uptimeNanoseconds
        self.connection = connection ?? UTPConnection(clock: { (DispatchTime.now().uptimeNanoseconds - start) / 1000 + 1_000_000 })
        wire()
    }

    private func wire() {
        connection.sendDatagram = { [weak self] d in self?.channel.send(d) }
        connection.unreadBytes = { [weak self] in { guard let self else { return 0 }; self.incomingLock.lock(); defer { self.incomingLock.unlock() }; return self.incoming.count }() }
        connection.onData = { [weak self] d in
            guard let self else { return }
            self.sessionQueue.async { self.incomingLock.lock(); self.incoming.append(d); self.incomingLock.unlock(); self.flush() }
        }
        connection.onConnected = { [weak self] in
            guard let self else { return }
            self.sessionQueue.async { let d = self.connectDone; self.connectDone = nil; d?(nil) }
        }
        connection.onClosed = { [weak self] failure in
            guard let self else { return }
            self.sessionQueue.async {
                self.ended = failure ?? URLError(.networkConnectionLost)
                if let d = self.connectDone { self.connectDone = nil; d(failure ?? URLError(.cannotConnectToHost)) }
                self.flush()
            }
            if self.connection.state == .closed { self.stopTimer() }          // while lingering, the timer still runs so the linger ends and a repeated FIN is still answered
        }
        channel.onReceive = { [weak self] d in self?.work.async { self?.connection.receive(d) } }
    }

    func connect(_ done: @escaping (Error?) -> Void) {
        connectDone = done
        channel.start { [weak self] error in
            guard let self else { return }
            if let error { self.sessionQueue.async { let d = self.connectDone; self.connectDone = nil; d?(error) }; return }
            self.work.async { self.connection.connect(); self.startTimer() }
        }
    }

    /// For an incoming connection: the SYN has been seen; this answers it.
    func accept(syn: UTP.Packet, ready: @escaping () -> Void) { work.async { self.startTimer(); self.connection.accept(syn); ready() } }

    private func startTimer() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: work)
        t.schedule(deadline: .now() + 0.05, repeating: 0.05, leeway: .milliseconds(20))
        t.setEventHandler { [weak self] in guard let self else { return }; self.connection.tick(); if self.connection.state == .closed { self.timer?.cancel(); self.timer = nil } }
        timer = t; t.resume()
    }
    private func stopTimer() { work.async { [weak self] in self?.timer?.cancel(); self?.timer = nil } }

    func send(_ data: Data) {
        work.async { [weak self] in
            guard let self else { return }
            // A full send queue ends the connection: carrying on with bytes missing would hand the peer half a message.
            if !self.connection.write(data) { self.connection.reset(); self.sessionQueue.async { self.ended = URLError(.networkConnectionLost); self.flush() } }
        }
    }

    func receive(_ handler: @escaping (Data?, Error?) -> Void) { reader = handler; flush() }

    private func flush() {
        guard let h = reader else { return }
        incomingLock.lock(); let chunk = Data(incoming.prefix(64 * 1024)); incoming.removeFirst(chunk.count); incomingLock.unlock()
        if !chunk.isEmpty { reader = nil; h(chunk, nil) }
        else if let e = ended { reader = nil; h(nil, e is URLError ? e : nil) }
    }

    func close() {
        guard !closed else { return }
        closed = true
        work.async { [weak self] in self?.connection.reset(); self?.timer?.cancel(); self?.timer = nil; self?.channel.close() }
    }
}
