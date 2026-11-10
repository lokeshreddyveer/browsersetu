import XCTest
@testable import Browser_Setu

// MARK: Wire formats: Fast Extension (BEP 6), PEX (BEP 11), peer records and filters

final class DX03WireTests: XCTestCase {
    func testHandshakeAdvertisesAndReadsTheFastBit() throws {
        let h = PeerWire.handshake(infoHash: Data(count: 20), peerID: Data(count: 20), extensions: true, fast: true)
        let parsed = try PeerWire.parseHandshake(h)
        XCTAssertTrue(parsed.supportsFast); XCTAssertTrue(parsed.supportsExtensions)
        XCTAssertFalse(try PeerWire.parseHandshake(PeerWire.handshake(infoHash: Data(count: 20), peerID: Data(count: 20), extensions: true)).supportsFast)
    }

    func testTheFiveFastMessagesRoundTripAndTheirLengthsAreChecked() throws {
        var parser = PeerWire.Parser(pieceCount: 100)
        let all: [PeerWire.Message] = [.suggest(7), .haveAll, .haveNone, .allowedFast(9), .rejectRequest(index: 3, begin: 16384, length: 16384)]
        var data = Data(); for m in all { data.append(PeerWire.encode(m)) }
        XCTAssertEqual(try parser.feed(data), all)
        XCTAssertEqual([UInt8](PeerWire.encode(.haveAll)), [0, 0, 0, 1, 0x0E])
        XCTAssertEqual([UInt8](PeerWire.encode(.rejectRequest(index: 1, begin: 2, length: 3)))[4], 0x10)
        for bad in [Data([0, 0, 0, 2, 0x0D, 1]), Data([0, 0, 0, 2, 0x0E, 1]), Data([0, 0, 0, 5, 0x10, 0, 0, 0, 0]), Data([0, 0, 0, 3, 0x11, 0, 0])] {
            var p = PeerWire.Parser(pieceCount: 100)
            XCTAssertThrowsError(try p.feed(bad))
        }
    }

    func testTheAllowedFastSetMatchesTheSpecificationsExample() {
        // BEP 6: 1313 pieces, IP 80.4.4.200, info-infoHash all 0xAA, k = 7.
        let set = PeerWire.allowedFastSet(ipv4: [80, 4, 4, 200], infoHash: Data(repeating: 0xAA, count: 20), pieceCount: 1313, k: 7)
        XCTAssertEqual(set, [1059, 431, 808, 1217, 287, 376, 1188])
        XCTAssertEqual(PeerWire.allowedFastSet(ipv4: [80, 4, 4, 200], infoHash: Data(repeating: 0xAA, count: 20), pieceCount: 1313, k: 9), [1059, 431, 808, 1217, 287, 376, 1188, 353, 508])
        XCTAssertEqual(PeerWire.allowedFastSet(ipv4: [1, 2, 3, 4], infoHash: Data(repeating: 1, count: 20), pieceCount: 3).count, 3, "never more than there are pieces")
        XCTAssertTrue(PeerWire.allowedFastSet(ipv4: [1, 2, 3], infoHash: Data(count: 20), pieceCount: 10).isEmpty)
    }

    func testPexRoundTripsIPv4AndIPv6WithFlags() throws {
        let added = [PeerWire.PexPeer(address: PeerAddress(host: "198.51.100.7", port: 51413), flags: 0x10), PeerWire.PexPeer(address: PeerAddress(host: "2606:4700::7", port: 6881), flags: 0x02)]
        let dropped = [PeerAddress(host: "203.0.113.9", port: 1234)]
        let parsed = try XCTUnwrap(PeerWire.parsePex(PeerWire.pexMessage(added: added, dropped: dropped)))
        XCTAssertEqual(Set(parsed.added.map(\.address)), Set(added.map(\.address)))
        XCTAssertEqual(parsed.added.first { $0.address.host == "198.51.100.7" }?.flags, 0x10)
        XCTAssertEqual(parsed.added.first { $0.address.isIPv6 }?.flags, 0x02)
        XCTAssertEqual(parsed.dropped, dropped)
    }

    func testPexRefusesMalformedAndBoundsWhatItReads() {
        XCTAssertNil(PeerWire.parsePex(Data("junk".utf8)))
        let odd = BencodeDecoder.encode(.dict(["added": .bytes(Data(count: 7))]))
        XCTAssertEqual(PeerWire.parsePex(odd)?.added.count, 0, "not a whole number of entries: ignored whole")
        let many = BencodeDecoder.encode(.dict(["added": .bytes(Data((0..<(6 * 200)).map { UInt8($0 % 250 + 1) }))]))
        XCTAssertLessThanOrEqual(PeerWire.parsePex(many)?.added.count ?? 0, PeerWire.maxPexPeers)
        let sent = PeerWire.pexMessage(added: (0..<80).map { PeerWire.PexPeer(address: PeerAddress(host: "198.51.100.\($0 + 1)", port: 6881), flags: 0) }, dropped: [])
        XCTAssertLessThanOrEqual(PeerWire.parsePex(sent)?.added.count ?? 0, PeerWire.maxPexPeers, "and what it sends is bounded too")
    }

    func testTheExtensionHandshakeAdvertisesPexOnlyWhenAsked() throws {
        func m(_ d: Data) -> [String: Bencode]? { (try? BencodeDecoder.decode(d, limits: .message))?.value.dict?["m"]?.dict }
        XCTAssertNil(m(PeerWire.extensionHandshake(metadataSize: nil))?["ut_pex"])
        XCTAssertEqual(m(PeerWire.extensionHandshake(metadataSize: nil, pex: true))?["ut_pex"]?.int, Int64(PeerWire.ExtensionID.utPex))
    }

    func testCanonicalAddressesMakeOnePeerOfManySpellings() {
        XCTAssertEqual(PeerAddress(host: "::ffff:198.51.100.5", port: 1).canonical, PeerAddress(host: "198.51.100.5", port: 1))
        XCTAssertEqual(PeerAddress(host: "2606:4700:0:0:0:0:0:7", port: 1).canonical, PeerAddress(host: "2606:4700::7", port: 1))
        XCTAssertEqual(PeerAddress(host: "fe80::1%en0", port: 1).canonical.host, "fe80::1%en0", "a scope id is kept")
        XCTAssertTrue(PeerAddress(host: "2606:4700::7", port: 1).isIPv6); XCTAssertFalse(PeerAddress(host: "198.51.100.5", port: 1).isIPv6)
    }

    func testThePeerFilterBlocksAddressesAndRanges() {
        let f = PeerFilter(["198.51.100.0/24", "203.0.113.9", "2606:4700::/32", "nonsense", "1.2.3.4/99"])
        XCTAssertTrue(f.blocks("198.51.100.77")); XCTAssertFalse(f.blocks("198.51.101.1"))
        XCTAssertTrue(f.blocks("203.0.113.9")); XCTAssertFalse(f.blocks("203.0.113.10"))
        XCTAssertTrue(f.blocks("2606:4700:1::5")); XCTAssertFalse(f.blocks("2607::1"))
        XCTAssertEqual(f.ranges.count, 3, "an entry that is not an address or range is ignored")
        XCTAssertTrue(PeerFilter(["::ffff:198.51.100.0/120"]).blocks("198.51.100.9"), "an IPv4-mapped entry means the IPv4 range")
        XCTAssertEqual(PeerFilter((0..<500).map { "10.0.\($0 % 250).0/24" }).ranges.count, PeerFilter.maxEntries)
    }

    func testPeerRecordsBackOffAndRankByWhatPeersGave() {
        var r = PeerRecord()
        r.failed(at: 100); XCTAssertEqual(r.nextAttempt, 115)
        r.failed(at: 200); XCTAssertEqual(r.nextAttempt, 230)
        for _ in 0..<20 { r.failed(at: 1000) }
        XCTAssertLessThanOrEqual(r.nextAttempt - 1000, PeerRecord.maxBackoff)
        r.succeeded(); XCTAssertEqual(r.nextAttempt, 0); XCTAssertEqual(r.failures, 0)
        var good = PeerRecord(); good.bytesReceived = 1_000_000; good.piecesVerified = 3
        var bad = PeerRecord(); bad.failed(at: 1); bad.failed(at: 2)
        XCTAssertGreaterThan(good.score, PeerRecord().score); XCTAssertGreaterThan(PeerRecord().score, bad.score)
    }
}

// MARK: Local Service Discovery (BEP 14)

final class FakeLAN: LANDatagramTransport, @unchecked Sendable {
    var onReceive: ((Data, String) -> Void)?
    private let lock = NSLock()
    private(set) var started = 0, closed = 0
    private(set) var sent: [(Data, Bool)] = []
    var failStart = false
    func start() throws { lock.lock(); started += 1; lock.unlock(); if failStart { throw POSIXError(.EACCES) } }
    func send(_ data: Data, ipv6: Bool) { lock.lock(); sent.append((data, ipv6)); lock.unlock() }
    func close() { lock.lock(); closed += 1; lock.unlock() }
    func hear(_ data: Data, from: String) { onReceive?(data, from) }
    var sentCount: Int { lock.lock(); defer { lock.unlock() }; return sent.count }
}

final class DX03LANTests: XCTestCase {
    private let infoHash = Data((1...20).map { UInt8($0) })
    private func announcement(_ infoHash: Data, port: Int = 51413, cookie: String = "x") -> Data { LocalServiceDiscovery.encode(infoHashes: [infoHash], port: UInt16(port), cookie: cookie, ipv6: false) }
    private final class Box<T>: @unchecked Sendable { var v: T; init(_ v: T) { self.v = v } }
    private func until(_ s: Double = 3, _ c: @escaping () -> Bool) async -> Bool { let end = Date().addingTimeInterval(s); while Date() < end { if c() { return true }; try? await Task.sleep(nanoseconds: 20_000_000) }; return c() }

    func testAnnouncementsEncodeAsTheSpecificationShowsAndParseBack() throws {
        let text = String(decoding: LocalServiceDiscovery.encode(infoHashes: [infoHash], port: 6881, cookie: "c1", ipv6: false), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("BT-SEARCH * HTTP/1.1\r\nHost: 239.192.152.143:6771\r\nPort: 6881\r\nInfohash: 0102030405060708090a0b0c0d0e0f1011121314\r\n"))
        XCTAssertTrue(text.hasSuffix("cookie: c1\r\n\r\n\r\n"))
        XCTAssertTrue(String(decoding: LocalServiceDiscovery.encode(infoHashes: [infoHash], port: 1, cookie: "c", ipv6: true), as: UTF8.self).contains("Host: [ff15::efc0:988f]:6771"))
        let parsed = try XCTUnwrap(LocalServiceDiscovery.parse(Data(text.utf8)))
        XCTAssertEqual(parsed, LocalServiceDiscovery.Announcement(port: 6881, infoHashes: [infoHash], cookie: "c1"))
    }

    func testMalformedAnnouncementsAreRefused() {
        XCTAssertNil(LocalServiceDiscovery.parse(Data("GET / HTTP/1.1\r\n\r\n".utf8)))
        XCTAssertNil(LocalServiceDiscovery.parse(Data("BT-SEARCH * HTTP/1.1\r\nPort: 0\r\nInfohash: \(infoHash.map { String(format: "%02x", $0) }.joined())\r\n\r\n".utf8)), "port 0")
        XCTAssertNil(LocalServiceDiscovery.parse(Data("BT-SEARCH * HTTP/1.1\r\nPort: 99999\r\nInfohash: \(infoHash.map { String(format: "%02x", $0) }.joined())\r\n\r\n".utf8)))
        XCTAssertNil(LocalServiceDiscovery.parse(Data("BT-SEARCH * HTTP/1.1\r\nPort: 5\r\nInfohash: nothex\r\n\r\n".utf8)), "no valid info-infoHash")
        XCTAssertNil(LocalServiceDiscovery.parse(Data(count: LocalServiceDiscovery.maxDatagram + 1)))
        XCTAssertNil(LocalServiceDiscovery.parse(Data([0xFF, 0xFE, 0xFD])))
    }

    func testOnlyALocalSourceForATorrentWeHoldIsHeardAndOnceEach() async {
        let lan = FakeLAN(); let found = Box<[PeerAddress]>([])
        let svc = LocalPeerDiscovery(transport: lan, policy: { nil })
        let task = UUID(); svc.register(task: task, infoHash: infoHash) { found.v += $0 }
        _ = await until { lan.started == 1 }
        lan.hear(announcement(infoHash), from: "192.168.1.20")
        lan.hear(announcement(infoHash), from: "192.168.1.20")                       // the same source again: not acted on twice
        lan.hear(announcement(Data(repeating: 9, count: 20)), from: "192.168.1.21")   // a torrent we do not hold
        lan.hear(announcement(infoHash), from: "198.51.100.5")                       // not a local address
        lan.hear(Data("garbage".utf8), from: "192.168.1.22")
        lan.hear(announcement(infoHash, port: 6881), from: "fe80::1%en0")            // IPv6 link-local with its interface
        _ = await until { found.v.count >= 2 }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(Set(found.v), [PeerAddress(host: "192.168.1.20", port: 51413), PeerAddress(host: "fe80::1%en0", port: 6881)])
        XCTAssertEqual(svc.droppedRateLimited, 1); XCTAssertEqual(svc.droppedNotLocal, 1); XCTAssertEqual(svc.droppedMalformed, 1)
        svc.stopNow(reason: "x")
    }

    func testOneAddressCannotFloodCandidatesAndThisComputerIsNotAPeer() async {
        let lan = FakeLAN(); let found = Box<[PeerAddress]>([])
        let svc = LocalPeerDiscovery(transport: lan, policy: { nil })
        svc.register(task: UUID(), infoHash: infoHash) { found.v += $0 }
        _ = await until { lan.started == 1 }
        for port in 40000..<40040 { lan.hear(announcement(infoHash, port: port), from: "192.168.1.50") }          // one host, forty ports
        lan.hear(announcement(infoHash, port: 5000), from: "127.0.0.1")
        lan.hear(announcement(infoHash, port: 5001), from: "::1")
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(found.v.count, 4, "at most a few from one address in a window")
        XCTAssertEqual(svc.droppedNotLocal, 2, "an announcement from this computer itself is not a peer")
        svc.stopNow(reason: "x")
    }

    func testItNeverHearsItselfAndNeverAcceptsAPrivateTorrent() async {
        let lan = FakeLAN(); let found = Box<[PeerAddress]>([])
        let hashCopy = infoHash
        let svc = LocalPeerDiscovery(transport: lan, policy: { nil }, announcePort: { 6881 }, isPrivateHash: { $0 == hashCopy })
        svc.register(task: UUID(), infoHash: infoHash) { found.v += $0 }
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(lan.started, 0, "a private torrent is not even registered, so nothing starts")
        XCTAssertEqual(lan.sentCount, 0, "and nothing is announced for it")
        let svc2 = LocalPeerDiscovery(transport: FakeLAN(), policy: { nil })
        let other = Data(repeating: 3, count: 20); let mine = FakeLAN()
        let s3 = LocalPeerDiscovery(transport: mine, policy: { nil }, announcePort: { 6881 })
        s3.register(task: UUID(), infoHash: other) { found.v += $0 }
        _ = await until(3) { mine.sentCount >= 2 }
        let ours = mine.sent.first.flatMap { LocalServiceDiscovery.parse($0.0) }
        XCTAssertNotNil(ours); mine.hear(mine.sent[0].0, from: "192.168.1.9")          // its own announcement, heard back
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(found.v.isEmpty); XCTAssertEqual(s3.droppedOwn, 1)
        svc2.stopNow(reason: "x"); s3.stopNow(reason: "x"); svc.stopNow(reason: "x")
    }

    func testNothingIsAnnouncedWithoutAPortAndAnnouncesAreBounded() async {
        let quiet = FakeLAN()
        let s1 = LocalPeerDiscovery(transport: quiet, policy: { nil })
        s1.register(task: UUID(), infoHash: infoHash) { _ in }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(quiet.sentCount, 0, "no listening port, nothing to announce")
        let loud = FakeLAN()
        let s2 = LocalPeerDiscovery(transport: loud, policy: { nil }, announcePort: { 6881 })
        s2.register(task: UUID(), infoHash: infoHash) { _ in }
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertEqual(loud.sentCount, 2, "one announcement for the torrent, to the IPv4 and the IPv6 group, and no more for five minutes")
        s1.stopNow(reason: "x"); s2.stopNow(reason: "x")
    }

    func testPolicyKeepsItOffAndStopsItAtOnce() async {
        let blocked = FakeLAN()
        let s1 = LocalPeerDiscovery(transport: blocked, policy: { DHTBlock(reason: "off", needsSettings: true) })
        s1.register(task: UUID(), infoHash: infoHash) { _ in }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(blocked.started, 0); XCTAssertEqual(s1.status.state, .blocked); XCTAssertTrue(s1.status.needsSettings)
        let off = Box(false); let lan = FakeLAN()
        let s2 = LocalPeerDiscovery(transport: lan, policy: { off.v ? DHTBlock(reason: "x") : nil })
        s2.register(task: UUID(), infoHash: infoHash) { _ in }
        _ = await until { lan.started == 1 }
        off.v = true
        let closed = await until { lan.closed >= 1 }
        XCTAssertTrue(closed)
        XCTAssertEqual(s2.status.state, .blocked)
        s1.stopNow(reason: "x")
    }

    func testPolicyFunctionExplainsProxyAndRespectsTheSwitch() {
        var setup = DownloadNetworkSetup(); setup.proxy.mode = .direct
        XCTAssertNotNil(LANNetworkPolicy.block(setup: setup, enabled: true, lanEnabled: false, systemProxyActive: false))
        XCTAssertNotNil(LANNetworkPolicy.block(setup: setup, enabled: false, lanEnabled: true, systemProxyActive: false))
        XCTAssertNil(LANNetworkPolicy.block(setup: setup, enabled: true, lanEnabled: true, systemProxyActive: true), "an explicit No proxy")
        setup.proxy.mode = .system
        XCTAssertEqual(LANNetworkPolicy.block(setup: setup, enabled: true, lanEnabled: true, systemProxyActive: true)?.needsSettings, true)
        setup.proxy.mode = .socks5; setup.proxy.host = "p.example.com"; setup.proxy.port = 1080
        XCTAssertEqual(LANNetworkPolicy.block(setup: setup, enabled: true, lanEnabled: true, systemProxyActive: false)?.needsSettings, true)
    }

    func testTheNetworkChangingMakesItJoinAgainAndAFailedStartIsReported() async {
        let gen = Box(0); let lan = FakeLAN()
        let svc = LocalPeerDiscovery(transport: lan, policy: { nil }, pathGeneration: { gen.v })
        svc.register(task: UUID(), infoHash: infoHash) { _ in }
        _ = await until { lan.started == 1 }
        gen.v = 1
        let again = await until(4) { lan.started == 2 }
        XCTAssertTrue(again, "the group is joined again on the new network")
        svc.stopNow(reason: "x")
        let bad = FakeLAN(); bad.failStart = true
        let s2 = LocalPeerDiscovery(transport: bad, policy: { nil })
        s2.register(task: UUID(), infoHash: infoHash) { _ in }
        _ = await until { s2.status.state == .unavailable }
        XCTAssertEqual(s2.status.state, .unavailable)
    }

    func testTheLastTorrentLeavingClosesTheSocket() async {
        let lan = FakeLAN(); let svc = LocalPeerDiscovery(transport: lan, policy: { nil })
        let a = UUID(), b = UUID()
        svc.register(task: a, infoHash: infoHash) { _ in }; svc.register(task: b, infoHash: Data(repeating: 2, count: 20)) { _ in }
        _ = await until { lan.started == 1 }
        svc.unregister(task: a); try? await Task.sleep(nanoseconds: 100_000_000); XCTAssertEqual(lan.closed, 0)
        svc.unregister(task: b)
        let closed = await until { lan.closed == 1 }
        XCTAssertTrue(closed)
    }
}
