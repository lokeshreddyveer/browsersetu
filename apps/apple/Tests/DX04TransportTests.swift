import XCTest
@testable import Browser_Setu

/// An in-memory byte pipe: what one end sends the other reads; closing one ends the other.
final class PipeEnd: PeerTransport {
    weak var other: PipeEnd?
    var connectError: Error?
    private let lock = NSLock()
    private var handler: ((Data?, Error?) -> Void)?
    private enum Item { case data(Data), eof }
    private var queued: [Item] = []
    private(set) var closed = false
    private(set) var wire = Data()                       // everything this end has sent, as it went "over the network"
    let queue: DispatchQueue
    init(queue: DispatchQueue = DispatchQueue(label: "pipe")) { self.queue = queue }
    static func pair() -> (PipeEnd, PipeEnd) { let a = PipeEnd(), b = PipeEnd(); a.other = b; b.other = a; return (a, b) }

    func connect(_ done: @escaping (Error?) -> Void) { let e = connectError; queue.async { done(e) } }
    func send(_ data: Data) { lock.lock(); wire.append(data); lock.unlock(); other?.deliver(data) }
    func receive(_ h: @escaping (Data?, Error?) -> Void) {
        lock.lock()
        let next: Item? = queued.isEmpty ? nil : queued.removeFirst()
        if next == nil { handler = h }
        lock.unlock()
        if let next { queue.async { switch next { case .data(let d): h(d, nil); case .eof: h(nil, nil) } } }
    }
    func close() { lock.lock(); let was = closed; closed = true; lock.unlock(); if !was { other?.deliver(nil) } }
    fileprivate func deliver(_ data: Data?) {
        lock.lock(); let h = handler; handler = nil; if h == nil { queued.append(data.map { .data($0) } ?? .eof) }; lock.unlock()
        if let h { queue.async { h(data, nil) } }
    }
    var wireCopy: Data { lock.lock(); defer { lock.unlock() }; return wire }
}

private func until(_ seconds: Double = 5, _ c: @escaping () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { if c() { return true }; try? await Task.sleep(nanoseconds: 10_000_000) }
    return c()
}
private final class Box<T>: @unchecked Sendable { var v: T; init(_ v: T) { self.v = v } }

final class DX04FallbackTests: XCTestCase {
    private let q = DispatchQueue(label: "t")
    private func transport(_ label: String, fails: Error? = nil, log: Box<[String]>) -> FallbackPeerTransport.Attempt {
        FallbackPeerTransport.Attempt(label: label, group: String(label.prefix(3)), make: {
            let (a, _) = PipeEnd.pair(); a.connectError = fails; log.v.append(label); return a
        })
    }

    func testTheNextWayIsTriedOnlyAfterTheOneBeforeFailed() async {
        let log = Box<[String]>([]); let result = Box<Error??>(nil)
        let t = FallbackPeerTransport(attempts: [transport("tcp", fails: URLError(.cannotConnectToHost), log: log), transport("utp", log: log)], queue: q)
        t.connect { result.v = .some($0) }
        _ = await until { result.v != nil }
        XCTAssertEqual(log.v, ["tcp", "utp"]); if case .some(let e) = result.v { XCTAssertNil(e) }
        XCTAssertEqual(t.connectedLabel, "utp")
    }

    func testAnOwnPolicyRefusalIsNeverRetriedAnotherWay() async {
        let log = Box<[String]>([]); let result = Box<Error??>(nil)
        let t = FallbackPeerTransport(attempts: [transport("tcp", fails: HTTPTrackerClient.Failure.proxy("proxy"), log: log), transport("utp", log: log)], queue: q)
        t.connect { result.v = .some($0) }
        _ = await until { result.v != nil }
        XCTAssertEqual(log.v, ["tcp"], "a refusal that is ours is not worked around")
        if case .some(let e) = result.v { XCTAssertTrue(TorrentSession.isProxyProblem(e!)) }
    }

    func testAFailureToConnectSkipsTheEncryptionVariantOfTheSameTransportButAHandshakeFailureDoesNot() async {
        let log = Box<[String]>([]); let r1 = Box<Error??>(nil), r2 = Box<Error??>(nil)
        let refused = FallbackPeerTransport(attempts: [transport("tcp+mse", fails: URLError(.cannotConnectToHost), log: log), FallbackPeerTransport.Attempt(label: "tcp", group: "tcp+mse".prefix(3).description, make: { log.v.append("tcp"); return PipeEnd.pair().0 }), transport("utp", log: log)], queue: q)
        refused.connect { r1.v = .some($0) }
        _ = await until { r1.v != nil }
        XCTAssertEqual(log.v, ["tcp+mse", "utp"], "nothing was listening: trying the same port plain would be the same failure")
        log.v = []
        let handshakeFail = FallbackPeerTransport(attempts: [transport("tcp+mse", fails: MSEPeerTransport.Failure.handshake("x"), log: log), transport("tcp", log: log)], queue: q)
        handshakeFail.connect { r2.v = .some($0) }
        _ = await until { r2.v != nil }
        XCTAssertEqual(log.v, ["tcp+mse", "tcp"], "the peer does not speak encryption: the plain way follows")
    }

    func testEveryWayFailingEndsWithTheLastErrorAndNoMoreAttempts() async {
        let log = Box<[String]>([]); let result = Box<Error??>(nil)
        let t = FallbackPeerTransport(attempts: [transport("tcp", fails: URLError(.timedOut), log: log), transport("utp", fails: URLError(.cannotConnectToHost), log: log)], queue: q)
        t.connect { result.v = .some($0) }
        _ = await until { result.v != nil }
        XCTAssertEqual(log.v, ["tcp", "utp"])
        if case .some(let e) = result.v { XCTAssertEqual((e as? URLError)?.code, .cannotConnectToHost) } else { XCTFail() }
    }
}

final class DX04FactoryTests: XCTestCase {
    private let torrentHash = Data(repeating: 7, count: 20)
    private let q = DispatchQueue(label: "t")
    private func factory(proxy: DownloadNetworkSettings.Proxy.Mode = .direct, systemActive: Bool = false, mode: TransportPreference, enc: EncryptionPolicy) -> NWPeerTransportFactory {
        var setup = DownloadNetworkSetup(); setup.proxy.mode = proxy
        if proxy == .socks5 { setup.proxy.host = "p.example.com"; setup.proxy.port = 1080 }
        return NWPeerTransportFactory(network: { setup }, systemProxyActive: { systemActive }, preferences: { (mode, enc) })
    }
    private func made(_ f: NWPeerTransportFactory) -> PeerTransport { f.make(PeerAddress(host: "203.0.113.5", port: 6881), infoHash: torrentHash, queue: q) }

    func testAutomaticWithPreferredEncryptionTriesEncryptedThenPlainOnEachTransport() {
        let t = made(factory(mode: .automatic, enc: .preferEncrypted)) as? FallbackPeerTransport
        XCTAssertEqual(t?.attemptLabels, ["tcp+mse", "tcp", "utp+mse", "utp"])
    }

    func testRequireNeverIncludesAPlainWay() {
        let t = made(factory(mode: .automatic, enc: .requireEncrypted)) as? FallbackPeerTransport
        XCTAssertEqual(t?.attemptLabels, ["tcp+mse", "utp+mse"])
    }

    func testPreferUTPOrdersItFirstAndTCPOnlyHasNoUDP() {
        XCTAssertEqual((made(factory(mode: .preferUTP, enc: .allowPlaintext)) as? FallbackPeerTransport)?.attemptLabels, ["utp", "tcp"])
        XCTAssertTrue(made(factory(mode: .tcpOnly, enc: .allowPlaintext)) is NWPeerTransport, "one way: no composite")
        XCTAssertEqual((made(factory(mode: .tcpOnly, enc: .preferEncrypted)) as? FallbackPeerTransport)?.attemptLabels, ["tcp+mse", "tcp"])
    }

    func testAProxyKeepsUDPOutAndUTPOnlyExplainsWhy() async {
        XCTAssertTrue(made(factory(proxy: .socks5, mode: .automatic, enc: .allowPlaintext)) is NWPeerTransport, "µTP is not tried through a proxy")
        XCTAssertEqual((made(factory(proxy: .system, systemActive: true, mode: .automatic, enc: .preferEncrypted)) as? FallbackPeerTransport)?.attemptLabels, ["tcp+mse", "tcp"])
        let blocked = made(factory(proxy: .socks5, mode: .utpOnly, enc: .allowPlaintext))
        let result = Box<Error??>(nil)
        blocked.connect { result.v = .some($0) }
        _ = await until { result.v != nil }
        if case .some(let e) = result.v { XCTAssertTrue(TorrentSession.isProxyProblem(e!), "an explanation the inspector can offer Settings for") } else { XCTFail() }
    }
}

final class DX04MSETransportTests: XCTestCase {
    private let torrentHash = Data((1...20).map { UInt8($0) })
    private let plain = Data("BitTorrent protocol handshake and then some messages".utf8)

    /// The far end of the pipe, speaking the responder's side of the encryption handshake and then echoing what it reads.
    private func serveEncrypted(_ end: PipeEnd, received: Box<Data>, accept: MSE.Methods = [.rc4, .plaintext]) {
        let h = MSEHandshake(role: .responder(infoHashes: { [torrentHash = self.torrentHash] in [torrentHash] }), allowed: accept)
        var transport: CipherPeerTransport?
        func read() {
            let source: PeerTransport = transport.map { $0 as PeerTransport } ?? end
            source.receive { data, _ in
                guard let data else { return }
                if let transport { received.v.append(data); _ = transport; read(); return }
                switch h.feed(data) {
                case .more: let out = h.takeOutput(); if !out.isEmpty { end.send(out) }; read()
                case .failed: end.close()
                case .done(let o): let out = h.takeOutput(); if !out.isEmpty { end.send(out) }; transport = CipherPeerTransport(base: end, outcome: o, queue: end.queue); received.v.append(o.initialPayload + o.leftover); read()
                }
            }
        }
        read()
    }

    func testTheOutgoingHandshakeCompletesAndTheStreamOnTheWireIsNotThePlaintext() async throws {
        let (a, b) = PipeEnd.pair(); let got = Box(Data())
        serveEncrypted(b, received: got)
        let t = MSEPeerTransport(base: a, infoHash: torrentHash, methods: [.rc4, .plaintext], queue: a.queue)
        let done = Box<Error??>(nil)
        t.connect { done.v = .some($0) }
        _ = await until { done.v != nil }
        if case .some(let e) = done.v { XCTAssertNil(e) } else { return XCTFail() }
        t.send(plain)
        let arrived = await until { got.v == self.plain }
        XCTAssertTrue(arrived, "the far end reads exactly what was sent")
        XCTAssertFalse(a.wireCopy.range(of: plain) != nil, "and what crossed the pipe was not the plain text")
        XCTAssertFalse(a.wireCopy.range(of: Data("BitTorrent".utf8)) != nil)
    }

    func testAPlainPeerThatDoesNotSpeakEncryptionEndsTheHandshakeWithAnErrorNotAHang() async {
        let (a, b) = PipeEnd.pair()
        b.receive { _, _ in b.close() }                      // a plain peer: reads the first bytes, finds them not BitTorrent, hangs up
        let t = MSEPeerTransport(base: a, infoHash: torrentHash, methods: [.rc4], queue: a.queue)
        let done = Box<Error??>(nil)
        t.connect { done.v = .some($0) }
        _ = await until { done.v != nil }
        if case .some(let e) = done.v { XCTAssertTrue(e is MSEPeerTransport.Failure || e != nil) } else { XCTFail() }
    }

    func testASilentPeerTimesTheHandshakeOut() async {
        let (a, _) = PipeEnd.pair()
        let t = MSEPeerTransport(base: a, infoHash: torrentHash, methods: [.rc4], queue: a.queue, timeout: 0.3)
        let done = Box<Error??>(nil)
        t.connect { done.v = .some($0) }
        let finished = await until { done.v != nil }
        XCTAssertTrue(finished)
        if case .some(let e) = done.v { XCTAssertTrue((e as? MSEPeerTransport.Failure) == .timeout || e != nil) }
        XCTAssertTrue(a.closed, "the connection is closed, not left open")
    }

    func testRequireEncryptedFailsAgainstAPeerThatOnlyOffersPlain() async {
        let (a, b) = PipeEnd.pair(); let got = Box(Data())
        serveEncrypted(b, received: got, accept: [.plaintext])
        let t = MSEPeerTransport(base: a, infoHash: torrentHash, methods: [.rc4], queue: a.queue)
        let done = Box<Error??>(nil)
        t.connect { done.v = .some($0) }
        _ = await until { done.v != nil }
        if case .some(let e) = done.v { XCTAssertNotNil(e, "never carried on in the clear") } else { XCTFail() }
    }

    func testTheFallbackReachesAPlainPeerAfterTheEncryptedWayFails() async {
        let (a1, b1) = PipeEnd.pair(); b1.receive { _, _ in b1.close() }          // the encrypted attempt meets a peer that hangs up
        let (a2, b2) = PipeEnd.pair(); let got = Box(Data()); b2.receive { d, _ in if let d { got.v.append(d) } }
        let t = FallbackPeerTransport(attempts: [
            .init(label: "tcp+mse", group: "tcp", make: { MSEPeerTransport(base: a1, infoHash: self.torrentHash, methods: [.rc4], queue: a1.queue) }),
            .init(label: "tcp", group: "tcp", make: { a2 })], queue: a1.queue)
        let done = Box<Error??>(nil)
        t.connect { done.v = .some($0) }
        _ = await until { done.v != nil }
        if case .some(let e) = done.v { XCTAssertNil(e) } else { return XCTFail() }
        XCTAssertEqual(t.connectedLabel, "tcp")
        t.send(plain)
        _ = await until { got.v == self.plain }
        XCTAssertEqual(got.v, plain, "the same peer, plain, as the preference allows")
    }
}

/// Two in-memory datagram channels wired to each other.
final class LoopChannel: UTPChannel {
    var onReceive: ((Data) -> Void)?
    weak var peer: LoopChannel?
    var drop: ((Int) -> Bool)?
    private(set) var sent = 0
    private let queue: DispatchQueue
    init(queue: DispatchQueue) { self.queue = queue }
    func start(_ ready: @escaping (Error?) -> Void) { queue.async { ready(nil) } }
    func send(_ data: Data) { sent += 1; if drop?(sent) == true { return }; let p = peer; queue.asyncAfter(deadline: .now() + 0.002) { p?.onReceive?(data) } }
    func close() {}
}

final class DX04UTPTransportTests: XCTestCase {
    func testAnOutgoingAndAnIncomingUTPTransportCarryBytesBothWays() async throws {
        let q = DispatchQueue(label: "utp-test")
        let ca = LoopChannel(queue: q), cb = LoopChannel(queue: q); ca.peer = cb; cb.peer = ca
        let a = UTPPeerTransport(channel: ca, queue: q)
        let b = Box<UTPPeerTransport?>(nil)
        cb.onReceive = { data in
            guard b.v == nil, let syn = UTP.parse(data), syn.type == .syn else { return }
            let t = UTPPeerTransport(channel: cb, queue: q); b.v = t; t.accept(syn: syn) {}
        }
        let connected = Box<Error??>(nil)
        a.connect { connected.v = .some($0) }
        let ok = await until { connected.v != nil && b.v != nil }
        XCTAssertTrue(ok)
        if case .some(let e) = connected.v { XCTAssertNil(e) }
        let message = Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        a.send(message)
        let gotB = Box(Data()), gotA = Box(Data())
        func readB() { b.v!.receive { d, _ in if let d { gotB.v.append(d); readB() } } }
        func readA() { a.receive { d, _ in if let d { gotA.v.append(d); readA() } } }
        readB(); readA()
        let arrived = await until(10) { gotB.v.count == message.count }
        XCTAssertTrue(arrived); XCTAssertEqual(gotB.v, message)
        b.v!.send(Data("reply".utf8))
        _ = await until { gotA.v == Data("reply".utf8) }
        XCTAssertEqual(gotA.v, Data("reply".utf8))
        a.close()
    }

    func testAConnectToNobodyFailsInsteadOfWaitingForever() async {
        let q = DispatchQueue(label: "utp-test2")
        let ca = LoopChannel(queue: q), cb = LoopChannel(queue: q); ca.peer = cb; cb.peer = ca            // nobody answers on cb
        let a = UTPPeerTransport(channel: ca, queue: q)
        let done = Box<Error??>(nil)
        a.connect { done.v = .some($0) }
        let finished = await until(40) { done.v != nil }
        XCTAssertTrue(finished, "a SYN is sent a bounded number of times, then the connect fails")
        if case .some(let e) = done.v { XCTAssertNotNil(e) }
        XCTAssertLessThanOrEqual(ca.sent, 4)
    }
}
