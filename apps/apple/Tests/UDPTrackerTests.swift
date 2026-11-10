import XCTest
@testable import Browser_Setu

/// BEP 15 packet formats, retransmission, connection ids, and the policy around a UDP tracker. The transport is scripted here; the independent-tracker run lives in `UDPTrackerInteropTests`.
final class ScriptedUDP: UDPDatagramTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var sent: [Data] = []
    private var pending: [Data] = []
    private(set) var closed = false
    /// Called with each datagram sent; whatever it returns is what the "tracker" says back.
    var responder: (Data, Int) -> [Data] = { _, _ in [] }
    /// How long a receive with nothing to deliver really waits (so a test of silence does not take 15 seconds).
    var silence: TimeInterval = 0.002

    func send(_ datagram: Data) async throws {
        lock.lock(); sent.append(datagram); let n = sent.count; lock.unlock()
        let replies = responder(datagram, n)
        lock.lock(); pending.append(contentsOf: replies); lock.unlock()
    }

    func receive(timeout: TimeInterval) async throws -> Data? {
        try Task.checkCancellation()
        lock.lock(); let next = pending.isEmpty ? nil : pending.removeFirst(); let wasClosed = closed; lock.unlock()
        if wasClosed { throw CancellationError() }
        if let next { return next }
        try await Task.sleep(nanoseconds: UInt64(min(timeout, silence) * 1_000_000_000))
        return nil
    }

    func close() { lock.lock(); closed = true; lock.unlock() }
    /// A new socket to the same scripted tracker: what the real factory gives each announce.
    func reopen() { lock.lock(); closed = false; lock.unlock() }
    var packets: [Data] { lock.lock(); defer { lock.unlock() }; return sent }
}

final class ScriptedFactory: UDPTransportFactory, @unchecked Sendable {
    let transport: ScriptedUDP
    private let lock = NSLock()
    private(set) var opened: [(String, UInt16)] = []
    init(_ t: ScriptedUDP) { transport = t }
    func open(ipv4: String, port: UInt16) throws -> UDPDatagramTransport { lock.lock(); opened.append((ipv4, port)); lock.unlock(); transport.reopen(); return transport }
}

struct FixedResolver: HostAddressResolving {
    var table: [String: [String]]
    func addresses(for host: String) async -> [String]? { table[host] }
}

final class UDPTrackerTests: XCTestCase {
    static let infoHash = Data((0..<20).map { UInt8($0) })
    static let peer = Data((100..<120).map { UInt8($0) })
    let url = URL(string: "udp://203.0.113.9:6969/announce")!

    private func be32(_ v: UInt32) -> Data { var d = Data(); d.appendBE(v); return d }
    private func be64(_ v: UInt64) -> Data { var d = Data(); d.appendBE(v); return d }

    /// A tracker that follows BEP 15: answers a connect with `connectionID`, and an announce that carries that id with `peers`.
    private func tracker(_ t: ScriptedUDP, connectionID: UInt64 = 0x1122334455667788, peers: [(UInt8, UInt8, UInt8, UInt8, UInt16)] = [(198, 51, 100, 7, 51413)], accept: @escaping (UInt64) -> Bool = { _ in true }) {
        t.responder = { packet, _ in
            let tid = packet.beUInt32(at: packet.count == 16 ? 12 : 12)
            if packet.count == 16 { return [self.be32(0) + self.be32(tid) + self.be64(connectionID)] }
            guard packet.count == 98, accept(packet.beUInt64(at: 0)) else { return [] }
            var d = self.be32(1) + self.be32(tid) + self.be32(1800) + self.be32(3) + self.be32(9)
            for p in peers { d.append(contentsOf: [p.0, p.1, p.2, p.3, UInt8(p.4 >> 8), UInt8(p.4 & 0xFF)]) }
            return [d]
        }
    }

    private func client(_ t: ScriptedUDP, proxy: DownloadNetworkSettings.Proxy = .init(), resolver: HostAddressResolving = FixedResolver(table: [:]), attempts: Int = 3, base: TimeInterval = 0.01,
                        now: @escaping @Sendable () -> Date = { Date() }) -> (UDPTrackerClient, ScriptedFactory) {
        let factory = ScriptedFactory(t)
        var setup = DownloadNetworkSetup(); setup.proxy = proxy
        return (UDPTrackerClient(network: { setup }, factory: factory, resolver: resolver, timing: .init(base: base, attempts: attempts), now: now), factory)
    }

    private func announce(_ c: UDPTrackerClient, _ u: URL? = nil, event: String? = "started") async throws -> TrackerReply {
        try await c.announce(u ?? url, infoHash: Self.infoHash, peerID: Self.peer, uploaded: 5, downloaded: 7, left: 1000, event: event)
    }

    // MARK: Packet formats and a good exchange

    func testTheConnectAndAnnouncePacketsFollowBEP15() async throws {
        let t = ScriptedUDP(); tracker(t)
        let (c, factory) = client(t)
        let reply = try await announce(c)
        let sent = t.packets
        XCTAssertEqual(sent.count, 2)
        // connect: 16 bytes, protocol id, action 0, a transaction id
        XCTAssertEqual(sent[0].count, 16); XCTAssertEqual(sent[0].beUInt64(at: 0), 0x41727101980); XCTAssertEqual(sent[0].beUInt32(at: 8), 0)
        // announce: 98 bytes at the offsets the BEP gives
        let a = sent[1]
        XCTAssertEqual(a.count, 98)
        XCTAssertEqual(a.beUInt64(at: 0), 0x1122334455667788, "the connection id the tracker gave")
        XCTAssertEqual(a.beUInt32(at: 8), 1, "action: announce")
        XCTAssertEqual(a.subdata(in: 16..<36), Self.infoHash); XCTAssertEqual(a.subdata(in: 36..<56), Self.peer)
        XCTAssertEqual(a.beUInt64(at: 56), 7, "downloaded"); XCTAssertEqual(a.beUInt64(at: 64), 1000, "left"); XCTAssertEqual(a.beUInt64(at: 72), 5, "uploaded")
        XCTAssertEqual(a.beUInt32(at: 80), 2, "event: started"); XCTAssertEqual(a.beUInt32(at: 84), 0, "ip: the tracker's own view")
        XCTAssertEqual(a.beUInt32(at: 92), 50, "num_want")
        XCTAssertEqual(UInt16(a[96]) << 8 | UInt16(a[97]), 0, "no inbound connections are accepted, so no port is claimed")
        XCTAssertNotEqual(sent[0].beUInt32(at: 12), a.beUInt32(at: 12), "a new transaction id for each request")
        XCTAssertEqual(reply.peers, [PeerAddress(host: "198.51.100.7", port: 51413)]); XCTAssertEqual(reply.interval, 1800)
        XCTAssertEqual(reply.seeders, 9); XCTAssertEqual(reply.leechers, 3)
        XCTAssertEqual(factory.opened.first?.0, "203.0.113.9"); XCTAssertEqual(factory.opened.first?.1, 6969)
        XCTAssertTrue(t.closed, "the socket is closed afterwards"); XCTAssertEqual(c.openSockets, 0)
    }

    func testTheEventsMapToTheNumbersInTheBEP() {
        XCTAssertEqual(UDPTrackerClient.eventCode(nil), 0); XCTAssertEqual(UDPTrackerClient.eventCode("completed"), 1)
        XCTAssertEqual(UDPTrackerClient.eventCode("started"), 2); XCTAssertEqual(UDPTrackerClient.eventCode("stopped"), 3)
        XCTAssertEqual(UDPTrackerClient.eventCode("nonsense"), 0)
    }

    func testPeersThatCannotBePeersAreLeftOutAndTheListIsBounded() async throws {
        let t = ScriptedUDP()
        tracker(t, peers: [(0, 0, 0, 0, 6881), (255, 255, 255, 255, 6881), (1, 2, 3, 4, 0), (5, 6, 7, 8, 6881)])
        let (c, _) = client(t)
        let reply = try await announce(c)
        XCTAssertEqual(reply.peers, [PeerAddress(host: "5.6.7.8", port: 6881)])
        var list: [(UInt8, UInt8, UInt8, UInt8, UInt16)] = []
        for i in 0..<300 { list.append((UInt8(10 + i / 250), 1, UInt8(i % 250), 9, UInt16(2000 + i))) }
        let many = ScriptedUDP(); tracker(many, peers: list)
        let (c2, _) = client(many)
        let big = try await announce(c2)
        XCTAssertEqual(big.peers.count, UDPTrackerClient.maxPeers)
    }

    // MARK: Bad and hostile answers

    func testAnAnswerWithTheWrongTransactionIdIsIgnoredAndTheRealOneStillWorks() async throws {
        let t = ScriptedUDP()
        t.responder = { packet, _ in
            let tid = packet.beUInt32(at: 12)
            let spoof = self.be32(packet.count == 16 ? 0 : 1) + self.be32(tid &+ 1) + self.be64(0xDEAD)
            if packet.count == 16 { return [spoof, self.be32(0) + self.be32(tid) + self.be64(42)] }
            XCTAssertEqual(packet.beUInt64(at: 0), 42, "the spoofed connection id was not used")
            return [self.be32(1) + self.be32(tid &+ 7) + Data(count: 12), self.be32(1) + self.be32(tid) + self.be32(900) + self.be32(0) + self.be32(1) + Data([9, 9, 9, 9, 0x1A, 0xE1])]
        }
        let reply = try await announce(client(t).0)
        XCTAssertEqual(reply.peers, [PeerAddress(host: "9.9.9.9", port: 6881)])
    }

    func testOnlyWrongAnswersEndInATimeoutNotInAcceptedData() async throws {
        let t = ScriptedUDP()
        t.responder = { packet, _ in [self.be32(0) + self.be32(packet.beUInt32(at: 12) &+ 1) + self.be64(1)] }
        do { _ = try await announce(client(t).0); XCTFail("accepted a reply for another transaction") } catch UDPTrackerClient.Failure.timeout {}
    }

    func testAnActionThatWasNotAskedForIsNotAnAnswer() async throws {
        let t = ScriptedUDP()
        t.responder = { packet, _ in [self.be32(2) + self.be32(packet.beUInt32(at: 12)) + Data(count: 24)] }      // a scrape answer to a connect
        do { _ = try await announce(client(t).0); XCTFail() } catch UDPTrackerClient.Failure.timeout {}
    }

    func testAShortConnectAnswerIsRefused() async throws {
        let t = ScriptedUDP()
        t.responder = { packet, _ in [self.be32(0) + self.be32(packet.beUInt32(at: 12)) + Data([1, 2])] }       // right transaction, 10 bytes
        do { _ = try await announce(client(t).0); XCTFail() } catch UDPTrackerClient.Failure.badReply {}
    }

    func testTruncatedAndOversizedAnnounceAnswersAreRefused() async throws {
        for (label, tail) in [("short", Data(count: 4)), ("ragged peer list", Data(count: 12 + 4)), ("oversized", Data(count: 4000))] {
            let t = ScriptedUDP()
            t.responder = { packet, _ in
                let tid = packet.beUInt32(at: 12)
                if packet.count == 16 { return [self.be32(0) + self.be32(tid) + self.be64(1)] }
                return [self.be32(1) + self.be32(tid) + tail]
            }
            do { _ = try await announce(client(t).0); XCTFail("accepted \(label)") } catch UDPTrackerClient.Failure.badReply {} catch { XCTFail("\(label): \(error)") }
        }
    }

    func testATrackerErrorIsReportedWithItsMessage() async throws {
        let t = ScriptedUDP()
        t.responder = { packet, _ in [self.be32(3) + self.be32(packet.beUInt32(at: 12)) + Data("torrent not registered\nwith control\u{7}chars".utf8)] }
        do { _ = try await announce(client(t).0); XCTFail() } catch let UDPTrackerClient.Failure.refused(why) {
            XCTAssertTrue(why.hasPrefix("torrent not registered"), why); XCTAssertFalse(why.contains("\n")); XCTAssertFalse(why.contains("\u{7}"))
        }
    }

    func testAFloodOfStrayAnswersDoesNotKeepItBusy() async throws {
        let t = ScriptedUDP()
        t.responder = { packet, _ in (0..<100).map { _ in self.be32(0) + self.be32(packet.beUInt32(at: 12) &+ 1) + self.be64(1) } }
        do { _ = try await announce(client(t).0); XCTFail() } catch UDPTrackerClient.Failure.badReply {}
    }

    // MARK: Timing, retransmission, connection ids

    func testASilentTrackerIsAskedExactlyTheBoundedNumberOfTimes() async throws {
        let t = ScriptedUDP()
        do { _ = try await announce(client(t, attempts: 3).0); XCTFail() } catch UDPTrackerClient.Failure.timeout {}
        XCTAssertEqual(t.packets.count, 3, "connect sent 3 times, never an endless loop")
        XCTAssertTrue(t.packets.allSatisfy { $0 == t.packets[0] }, "a repeat is the same request")
        XCTAssertEqual(UDPTrackerClient.Timing().base, 15, "BEP 15: 15 seconds, doubling")
    }

    func testALostFirstPacketIsSentAgainAndTheExchangeSucceeds() async throws {
        let t = ScriptedUDP(); tracker(t)
        let inner = t.responder
        t.responder = { packet, n in n == 1 ? [] : inner(packet, n) }
        _ = try await announce(client(t).0)
        XCTAssertEqual(t.packets.count, 3)
    }

    func testEachExchangeAsksForItsOwnConnectionId() async throws {
        // A connection id belongs to the socket it was asked from, so a second announce (on a new socket) never reuses the first one's.
        let t = ScriptedUDP(); tracker(t)
        let (c, _) = client(t)
        _ = try await announce(c); XCTAssertEqual(t.packets.count, 2, "connect + announce")
        _ = try await announce(c, event: nil); XCTAssertEqual(t.packets.count, 4, "connect + announce again")
    }

    func testCancellingStopsTheWaitAndClosesTheSocket() async throws {
        let t = ScriptedUDP(); t.silence = 5
        let (c, _) = client(t, base: 5)
        let task = Task { try await self.announce(c) }
        try await Task.sleep(nanoseconds: 80_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail() } catch is CancellationError {} catch { XCTAssertTrue(t.closed, "\(error)") }
        XCTAssertTrue(t.closed); XCTAssertEqual(c.openSockets, 0)
    }

    func testOnlyAFewSocketsAreOpenAtOnce() async throws {
        let t = ScriptedUDP(); t.silence = 5
        let (c, _) = client(t, base: 5)
        var tasks: [Task<TrackerReply, Error>] = []
        for _ in 0..<UDPTrackerClient.maxConcurrent { tasks.append(Task { try await self.announce(c) }) }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(c.openSockets, UDPTrackerClient.maxConcurrent)
        do { _ = try await announce(c); XCTFail() } catch UDPTrackerClient.Failure.busy {}
        tasks.forEach { $0.cancel() }
        for task in tasks { _ = try? await task.value }
        XCTAssertEqual(c.openSockets, 0)
    }

    // MARK: Policy

    func testAProxyThatWasAskedForMeansNoUDPAtAll() async throws {
        for mode in [DownloadNetworkSettings.Proxy.Mode.socks5, .http, .https] {
            let t = ScriptedUDP(); tracker(t)
            let (c, factory) = client(t, proxy: .init(mode: mode, host: "proxy.example.com", port: 1080, username: ""))
            do { _ = try await announce(c); XCTFail("\(mode) went around the proxy") } catch UDPTrackerClient.Failure.proxy {}
            XCTAssertTrue(factory.opened.isEmpty, "no socket was opened"); XCTAssertTrue(t.packets.isEmpty, "nothing was sent")
        }
        let t = ScriptedUDP(); tracker(t)
        _ = try await announce(client(t, proxy: .init(mode: .direct)).0)
    }

    func testANameThatPointsAtTheLocalNetworkIsNotContacted() async throws {
        let t = ScriptedUDP(); tracker(t)
        let (c, factory) = client(t, resolver: FixedResolver(table: ["tracker.example.com": ["10.0.0.5"], "mixed.example.com": ["203.0.113.4", "127.0.0.1"], "fine.example.com": ["203.0.113.4"]]))
        for host in ["tracker.example.com", "mixed.example.com"] {
            do { _ = try await announce(c, URL(string: "udp://\(host):6969")!); XCTFail(host) } catch UDPTrackerClient.Failure.blocked {}
        }
        XCTAssertTrue(factory.opened.isEmpty)
        _ = try await announce(c, URL(string: "udp://fine.example.com:6969")!)
        XCTAssertEqual(factory.opened.first?.0, "203.0.113.4", "it connects to the address that was checked")
    }

    func testALocalTrackerGivenByItsOwnAddressIsAllowedHere() async throws {
        let t = ScriptedUDP(); tracker(t)
        _ = try await announce(client(t).0, URL(string: "udp://127.0.0.1:18793")!)
    }

    func testUnusableTrackerAddressesAreRefusedWithoutAnySocket() async throws {
        let t = ScriptedUDP(); tracker(t)
        let (c, factory) = client(t, resolver: FixedResolver(table: [:]))
        for text in ["udp://tracker.example.com/announce", "udp://[2001:db8::1]:6969", "udp://:6969", "udp://203.0.113.9:0", "http://203.0.113.9:6969"] {
            guard let address = URL(string: text) else { continue }          // a string that is not even a URL never reaches the client
            do { _ = try await announce(c, address); XCTFail(text) } catch UDPTrackerClient.Failure.unsupported {} catch { XCTFail("\(text): \(error)") }
        }
        do { _ = try await announce(c, URL(string: "udp://nosuchname.example.com:6969")!); XCTFail() } catch UDPTrackerClient.Failure.unreachable {}
        XCTAssertTrue(factory.opened.isEmpty)
    }

    func testTheRouterSendsEachSchemeToItsOwnClient() async throws {
        final class Spy: TrackerAnnouncing, @unchecked Sendable {
            var seen: [URL] = []
            func announce(_ tracker: URL, infoHash: Data, peerID: Data, uploaded: Int64, downloaded: Int64, left: Int64?, event: String?) async throws -> TrackerReply { seen.append(tracker); return TrackerReply(peers: [], interval: 60, warning: nil) }
        }
        let http = Spy(), udp = Spy(), router = TrackerRouter(http: http, udp: udp)
        for text in ["udp://203.0.113.9:6969/announce", "http://t.example.com/announce", "https://t.example.com/announce", "UDP://203.0.113.9:1"] {
            _ = try await router.announce(URL(string: text)!, infoHash: Self.infoHash, peerID: Self.peer, uploaded: 0, downloaded: 0, left: 1, event: nil)
        }
        XCTAssertEqual(udp.seen.count, 2); XCTAssertEqual(http.seen.count, 2)
    }
}

final class Clock: @unchecked Sendable {
    private let lock = NSLock(); private var value: Date
    init(_ d: Date) { value = d }
    var now: Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ s: TimeInterval) { lock.lock(); value = value.addingTimeInterval(s); lock.unlock() }
}

/// Magnet links and torrent files with UDP trackers.
@MainActor
final class UDPTrackerLinkTests: XCTestCase {
    private let hex = String(repeating: "ab", count: 20)

    func testUDPTrackersInAMagnetAreKeptDecodedAndWithoutDuplicates() throws {
        let magnet = try MagnetLink.parse("magnet:?xt=urn:btih:\(hex)&dn=x&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337&tr=http%3A%2F%2Ft.example.com%2Fannounce&tr=udp%3A%2F%2Fexodus.desync.com%3A6969%2Fannounce")
        XCTAssertEqual(magnet.trackers.map(\.absoluteString), ["udp://tracker.opentrackr.org:1337", "http://t.example.com/announce", "udp://exodus.desync.com:6969/announce"])
        XCTAssertEqual(magnet.trackers[0].host, "tracker.opentrackr.org"); XCTAssertEqual(magnet.trackers[0].port, 1337)
    }

    func testAMagnetWithOnlyUDPTrackersIsAccepted() throws {
        let magnet = try MagnetLink.parse("magnet:?xt=urn:btih:\(hex)&tr=udp%3A%2F%2F203.0.113.9%3A6969")
        XCTAssertEqual(magnet.trackers.count, 1)
    }

    func testMalformedTrackersAreDroppedSafely() throws {
        let magnet = try MagnetLink.parse("magnet:?xt=urn:btih:\(hex)&tr=udp%3A%2F%2F&tr=ftp%3A%2F%2Fx.example.com%2F&tr=javascript%3Aalert(1)&tr=udp%3A%2F%2F%2Fpath&tr=" + String(repeating: "a", count: 3000))
        XCTAssertEqual(magnet.trackers, [])
    }

    func testAnAnnounceListWithAUDPTrackerIsRecognised() throws {
        func s(_ t: String) -> String { "\(t.utf8.count):\(t)" }
        let info = "d6:lengthi10e4:name1:a12:piece lengthi16384e6:pieces20:" + String(repeating: "x", count: 20) + "e"
        let torrent = "d8:announce\(s("udp://203.0.113.9:6969/announce"))13:announce-listll\(s("udp://203.0.113.9:6969/announce"))e" + "l\(s("http://t.example.com/announce"))el\(s("udp://tracker.example.org:80"))ee4:info\(info)e"
        let meta = try TorrentMetainfo.parse(Data(torrent.utf8))
        XCTAssertEqual(meta.trackers.map(\.absoluteString), ["udp://203.0.113.9:6969/announce", "http://t.example.com/announce", "udp://tracker.example.org:80"], "UDP trackers kept, the repeated one once")
    }

    func testTheRunnerNoLongerHoldsUDPTrackersBackFromTheSession() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let runner = try String(contentsOf: root.appendingPathComponent("Shared/Downloads/Torrent/TorrentRunner.swift"))
        XCTAssertFalse(runner.contains("!= \"udp\""), "no filter keeps UDP trackers away from the session")
        XCTAssertTrue(runner.contains("TrackerRouter"))
    }

    func testAPagesLinkCannotUseALocalUDPTracker() {
        let local = URL(string: "udp://127.0.0.1:6969")!, lan = URL(string: "udp://192.168.1.1:6969/announce")!, pub = URL(string: "udp://tracker.example.com:6969")!
        XCTAssertEqual(TorrentRunner.usableTrackers([local, lan, pub], origin: .page), [pub])
        XCTAssertEqual(TorrentRunner.usableTrackers([local, lan, pub], origin: .user).count, 3)
        XCTAssertFalse(TorrentRunner.allowsLocalPeers(settingsAllow: false, trackers: [local], origin: .page))
        XCTAssertTrue(TorrentRunner.allowsLocalPeers(settingsAllow: false, trackers: [local], origin: .user))
    }
}
