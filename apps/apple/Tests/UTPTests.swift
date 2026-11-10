import XCTest
@testable import Browser_Setu

// MARK: A simulated network: two ends, a clock the test owns, loss, reordering and a bottleneck

final class UTPNetwork {
    var now: UInt64 = 1_000_000
    var latency: UInt64 = 20_000                     // µs, each way
    var jitter: UInt64 = 0                           // extra random µs (reorders datagrams)
    var lossToB = 0.0, lossToA = 0.0
    var dropNextToB: Set<Int> = []                   // 1-based indexes of datagrams to B that are lost
    var bytesPerSecond: Double?                      // a bottleneck from A to B, with a queue
    private var bottleneckFree: UInt64 = 0
    private(set) var toBCount = 0, toACount = 0, bytesToB = 0
    private var inFlight: [(at: UInt64, data: Data, toB: Bool)] = []
    var a: UTPConnection!, b: UTPConnection?
    var bReceived = Data(), aReceived = Data()
    var aClosed: UTPFailure??, bClosed: UTPFailure??
    var bUnread = 0
    var rng = SystemRandomNumberGenerator()
    var tamper: ((Data, Bool) -> Data?)?

    init(tuning: UTPConnection.Tuning = .init()) {
        self.tuning = tuning
        a = UTPConnection(tuning: tuning, clock: { [unowned self] in self.now })
        a.sendDatagram = { [unowned self] d in self.send(d, toB: true) }
        a.onData = { [unowned self] d in self.aReceived.append(d) }
        a.onClosed = { [unowned self] f in self.aClosed = .some(f) }
    }
    private let tuning: UTPConnection.Tuning

    private func makeB(from syn: UTP.Packet) {
        let c = UTPConnection(tuning: tuning, clock: { [unowned self] in self.now })
        c.sendDatagram = { [unowned self] d in self.send(d, toB: false) }
        c.onData = { [unowned self] d in self.bReceived.append(d) }
        c.onClosed = { [unowned self] f in self.bClosed = .some(f) }
        c.unreadBytes = { [unowned self] in self.bUnread }
        b = c
        c.accept(syn)
    }

    private func send(_ d: Data, toB: Bool) {
        if toB { toBCount += 1 } else { toACount += 1 }
        let index = toB ? toBCount : toACount
        if toB, dropNextToB.contains(index) { return }
        if Double.random(in: 0..<1, using: &rng) < (toB ? lossToB : lossToA) { return }
        var delay = latency + (jitter > 0 ? UInt64.random(in: 0...jitter, using: &rng) : 0)
        if toB, let rate = bytesPerSecond {
            let service = UInt64(Double(d.count) / rate * 1_000_000)
            bottleneckFree = max(bottleneckFree, now) + service
            delay += bottleneckFree - now
            bytesToB += d.count
        }
        var out = d
        if let tamper { guard let t = tamper(d, toB) else { return }; out = t }
        inFlight.append((now + delay, out, toB))
    }

    func step(_ micros: UInt64 = 5_000) {
        now += micros
        let due = inFlight.filter { $0.at <= now }.sorted { $0.at < $1.at }
        inFlight.removeAll { $0.at <= now }
        for p in due {
            if p.toB {
                if b == nil, let syn = UTP.parse(p.data), syn.type == .syn { makeB(from: syn) } else { b?.receive(p.data) }
            } else { a.receive(p.data) }
        }
        a.tick(); b?.tick()
    }

    @discardableResult
    func run(seconds: Double = 120, until done: () -> Bool) -> Bool {
        let end = now + UInt64(seconds * 1_000_000)
        while now < end { if done() { return true }; step() }
        return done()
    }
}

final class UTPPacketTests: XCTestCase {
    private func packet(_ type: UTP.PacketType = .data, payload: Data = Data("hi".utf8), sack: Data? = nil) -> UTP.Packet {
        UTP.Packet(type: type, connectionID: 0x1234, timestamp: 0xAABBCCDD, timestampDifference: 7, window: 65535, seq: 0xFFFE, ack: 3, sack: sack, payload: type == .data ? payload : Data())
    }

    func testHeaderIsTwentyBytesInTheSpecifiedOrder() {
        let d = UTP.encode(packet(.state))
        XCTAssertEqual(d.count, 20)
        XCTAssertEqual([UInt8](d.prefix(4)), [0x21, 0x00, 0x12, 0x34], "type 2, version 1, no extension, connection id")
        XCTAssertEqual([UInt8](d[4..<8]), [0xAA, 0xBB, 0xCC, 0xDD])
        XCTAssertEqual([UInt8](d[16..<20]), [0xFF, 0xFE, 0x00, 0x03], "seq then ack")
        XCTAssertEqual(UTP.encode(UTP.Packet(type: .syn, connectionID: 1, timestamp: 0, timestampDifference: 0, window: 0, seq: 1, ack: 0))[0], 0x41)
    }

    func testPacketsRoundTripWithAndWithoutSelectiveAck() {
        for p in [packet(.data), packet(.fin), packet(.state), packet(.reset), packet(.state, sack: Data([0b101, 0, 0, 0]))] { XCTAssertEqual(UTP.parse(UTP.encode(p)), p) }
    }

    func testMalformedPacketsAreRefused() {
        XCTAssertNil(UTP.parse(Data(count: 19)))
        XCTAssertNil(UTP.parse(Data(count: UTP.maxDatagram + 1)))
        var d = UTP.encode(packet(.state)); d[0] = 0x22                       // version 2
        XCTAssertNil(UTP.parse(d))
        d[0] = 0x51; XCTAssertNil(UTP.parse(d), "type 5 does not exist")
        var ext = UTP.encode(packet(.state)); ext[1] = 1; ext.append(contentsOf: [0, 4, 1, 2])          // says 4 bytes, has 2
        XCTAssertNil(UTP.parse(ext))
        var odd = UTP.encode(packet(.state)); odd[1] = 1; odd.append(contentsOf: [0, 3, 1, 2, 3])
        XCTAssertNil(UTP.parse(odd), "a selective ACK is a multiple of four bytes")
        var loop = UTP.encode(packet(.state)); loop[1] = 9; for _ in 0..<8 { loop.append(contentsOf: [9, 0]) }
        XCTAssertNil(UTP.parse(loop), "a chain of extensions is bounded")
        var withPayload = UTP.encode(packet(.state)); withPayload.append(1)
        XCTAssertNil(UTP.parse(withPayload), "a STATE carries no data")
        var unknown = UTP.encode(packet(.state)); unknown[1] = 77; unknown.append(contentsOf: [0, 2, 9, 9])
        XCTAssertNotNil(UTP.parse(unknown), "an unknown extension is skipped by its length")
    }

    func testSequenceOrderWrapsAround() {
        XCTAssertTrue(UTP.before(65535, 1)); XCTAssertFalse(UTP.before(1, 65535)); XCTAssertFalse(UTP.before(5, 5)); XCTAssertTrue(UTP.before(10, 11))
    }
}

final class UTPConnectionTests: XCTestCase {
    private func payload(_ n: Int) -> Data { Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 8)) }) }
    private func connected(_ net: UTPNetwork) -> Bool { net.a.connect(); return net.run(seconds: 10) { net.a.state == .connected && net.b?.state == .connected } }

    func testHandshakeUsesTheConnectionIdsTheSpecificationDescribes() {
        let net = UTPNetwork(); var seen: [UTP.Packet] = []
        net.tamper = { d, _ in if let p = UTP.parse(d) { seen.append(p) }; return d }
        XCTAssertTrue(connected(net))
        XCTAssertEqual(seen[0].type, .syn); XCTAssertEqual(seen[0].seq, 1)
        let syn = seen[0], state = seen.first { $0.type == .state }!
        XCTAssertEqual(state.connectionID, syn.connectionID, "the answer carries the id the SYN carried")
        net.a.write(Data("x".utf8)); net.run(seconds: 2) { net.bReceived.count == 1 }
        XCTAssertEqual(seen.first { $0.type == .data }?.connectionID, syn.connectionID &+ 1, "after the SYN the initiator sends with id + 1")
        XCTAssertEqual(seen.first { $0.type == .data }?.seq, 2)
    }

    func testOrderedTransferBothWays() {
        let net = UTPNetwork(); XCTAssertTrue(connected(net))
        let up = payload(200_000), down = payload(50_000)
        net.a.write(up); net.b!.write(down)
        XCTAssertTrue(net.run { net.bReceived.count == up.count && net.aReceived.count == down.count })
        XCTAssertEqual(net.bReceived, up); XCTAssertEqual(net.aReceived, down)
    }

    func testLossAndReorderingStillDeliverEverythingInOrder() {
        let net = UTPNetwork(); net.lossToB = 0.08; net.lossToA = 0.05; net.jitter = 30_000
        XCTAssertTrue(connected(net))
        let data = payload(300_000); net.a.write(data)
        XCTAssertTrue(net.run(seconds: 600) { net.bReceived.count == data.count }, "received \(net.bReceived.count)")
        XCTAssertEqual(net.bReceived, data)
        XCTAssertGreaterThan(net.a.retransmissions, 0)
    }

    func testASingleLostPacketIsRecoveredFromSelectiveAcksNotATimeout() {
        let net = UTPNetwork(); XCTAssertTrue(connected(net))
        let first = net.toBCount
        net.dropNextToB = [first + 3]                  // the third data packet after the handshake
        let data = payload(40_000); net.a.write(data)
        let start = net.now
        XCTAssertTrue(net.run { net.bReceived.count == data.count })
        XCTAssertEqual(net.bReceived, data)
        XCTAssertEqual(net.a.retransmissions, 1, "exactly the one packet was resent")
        XCTAssertLessThan(Double(net.now - start) / 1_000_000, 0.45, "well before a retransmission timeout (at least half a second)")
    }

    func testTheWindowShrinksOnLossAndGrowsWhenTheLinkIsClear() {
        let clear = UTPNetwork(); XCTAssertTrue(connected(clear))
        clear.a.write(payload(400_000)); clear.run(seconds: 5) { clear.bReceived.count == 400_000 }
        let grown = clear.a.congestionWindow
        XCTAssertGreaterThan(grown, 4 * UTP.payloadSize, "no loss and no queueing: the window grows")
        let lossy = UTPNetwork(); lossy.lossToB = 0.1; XCTAssertTrue(connected(lossy))
        lossy.a.write(payload(400_000)); lossy.run(seconds: 600) { lossy.bReceived.count == 400_000 }
        XCTAssertLessThan(lossy.a.congestionWindow, grown, "loss held the window down")
    }

    func testAQueueingBottleneckKeepsTheDelayNearTheTargetInsteadOfFillingTheQueue() {
        let net = UTPNetwork(); net.bytesPerSecond = 125_000                // 1 Mbit/s with a queue that could grow without limit
        XCTAssertTrue(connected(net))
        let data = payload(300_000); net.a.write(data)
        var worstQueueMicros: UInt64 = 0
        let ok = net.run(seconds: 400) {
            worstQueueMicros = max(worstQueueMicros, UInt64(Double(net.a.bytesInFlight) / 125_000 * 1_000_000))
            return net.bReceived.count == data.count
        }
        XCTAssertTrue(ok); XCTAssertEqual(net.bReceived, data)
        XCTAssertLessThan(Double(worstQueueMicros) / 1_000_000, 1.0, "the sender did not push a standing queue of seconds into the link: \(worstQueueMicros) µs in flight")
    }

    func testTheReceiversWindowStopsTheSenderAndLetsItResume() {
        var t = UTPConnection.Tuning(); t.receiveLimit = 8 * UTP.payloadSize
        let net = UTPNetwork(tuning: t); XCTAssertTrue(connected(net))
        net.bUnread = 8 * UTP.payloadSize                       // the reader has not consumed anything: window zero
        net.a.write(payload(60_000))
        net.run(seconds: 3) { false }
        XCTAssertLessThan(net.bReceived.count, 20_000, "with a closed window almost nothing flows (\(net.bReceived.count))")
        net.bUnread = 0
        XCTAssertTrue(net.run(seconds: 60) { net.bReceived.count == 60_000 }, "and it resumes when the reader catches up")
    }

    func testGracefulCloseDeliversEverythingThenBothEndsCloseCleanly() {
        let net = UTPNetwork(); XCTAssertTrue(connected(net))
        let data = payload(30_000); net.a.write(data); net.a.close()
        XCTAssertTrue(net.run { net.aClosed != nil && net.bClosed != nil })
        XCTAssertEqual(net.bReceived, data)
        if case .some(let f) = net.aClosed { XCTAssertNil(f) }; if case .some(let f) = net.bClosed { XCTAssertNil(f) }
    }

    func testAResetEndsTheOtherSideAtOnce() {
        let net = UTPNetwork(); XCTAssertTrue(connected(net))
        net.a.reset()
        XCTAssertTrue(net.run(seconds: 2) { net.bClosed != nil })
        if case .some(let f) = net.bClosed { XCTAssertEqual(f, .reset) } else { XCTFail() }
        XCTAssertEqual(net.a.state, .closed)
    }

    func testALostSynIsSentAgainAndASilentPeerEndsInATimeout() {
        let net = UTPNetwork(); net.dropNextToB = [1]            // the first SYN is lost
        XCTAssertTrue(connected(net), "the SYN was sent again")
        XCTAssertGreaterThanOrEqual(net.a.retransmissions, 1)
        let dead = UTPNetwork(); dead.lossToB = 1.0
        dead.a.connect()
        XCTAssertTrue(dead.run(seconds: 60) { dead.aClosed != nil })
        if case .some(let f) = dead.aClosed { XCTAssertEqual(f, .timeout) } else { XCTFail() }
        XCTAssertLessThanOrEqual(dead.toBCount, 4, "a bounded number of attempts, not forever")
    }

    func testGarbageAndStrangersDoNotDisturbAnEstablishedConnection() {
        let net = UTPNetwork(); XCTAssertTrue(connected(net))
        let data = payload(20_000); net.a.write(data)
        for _ in 0..<50 { net.b!.receive(Data((0..<Int.random(in: 0...60)).map { _ in UInt8.random(in: 0...255) })) }
        var stranger = UTP.Packet(type: .data, connectionID: 9999, timestamp: 0, timestampDifference: 0, window: 100000, seq: 5, ack: 0); stranger.payload = Data("evil".utf8)
        net.b!.receive(UTP.encode(stranger))                       // another connection's id
        XCTAssertTrue(net.run { net.bReceived.count == data.count })
        XCTAssertEqual(net.bReceived, data, "nothing was injected")
        XCTAssertEqual(net.b!.state, .connected)
    }

    func testDuplicatedDatagramsAreHarmless() {
        let net = UTPNetwork(); XCTAssertTrue(connected(net))
        net.tamper = { d, toB in if toB { net.b?.receive(d) }; return d }          // every datagram to B is delivered twice
        let data = payload(60_000); net.a.write(data)
        XCTAssertTrue(net.run { net.bReceived.count >= data.count })
        XCTAssertEqual(net.bReceived, data)
    }

    func testTheSendQueueIsBoundedAndClosingStopsWrites() {
        var t = UTPConnection.Tuning(); t.maxSendQueue = 10_000
        let net = UTPNetwork(tuning: t); XCTAssertTrue(connected(net))
        net.a.write(payload(1_000_000 / 100))
        XCTAssertFalse(net.a.write(payload(10_001)), "past the bound the bytes are refused, not buffered without limit")
        net.a.close()
        XCTAssertFalse(net.a.write(payload(10)), "nothing is written after a close")
    }
}
