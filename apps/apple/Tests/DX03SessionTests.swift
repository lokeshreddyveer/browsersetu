import XCTest
@testable import Browser_Setu

/// A peer the test controls byte for byte: it records what the session sends and delivers whatever the test feeds it.
final class ScriptedPeer: PeerTransport, @unchecked Sendable {
    let address: PeerAddress
    private let lock = NSLock()
    private var handler: ((Data?, Error?) -> Void)?
    private var queued: [Data] = []
    private var outbox = Data()
    private(set) var closed = false
    var connectError: Error?
    private(set) var messages: [PeerWire.Message] = []
    private(set) var theirHandshake: PeerWire.Handshake?
    private let queue: DispatchQueue
    init(_ address: PeerAddress, queue: DispatchQueue) { self.address = address; self.queue = queue }

    func connect(_ done: @escaping (Error?) -> Void) { let e = connectError; queue.async { done(e) } }
    func send(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        outbox.append(data)
        if theirHandshake == nil, outbox.count >= PeerWire.handshakeLength { theirHandshake = try? PeerWire.parseHandshake(outbox); outbox.removeFirst(PeerWire.handshakeLength) }
        guard theirHandshake != nil else { return }
        var parser = PeerWire.Parser(pieceCount: 4096)
        if let m = try? parser.feed(outbox) { messages += m; outbox = Data() }
    }
    func receive(_ h: @escaping (Data?, Error?) -> Void) { lock.lock(); handler = h; let next = queued.isEmpty ? nil : queued.removeFirst(); lock.unlock(); if let next { h(next, nil) } }
    func close() { lock.lock(); closed = true; lock.unlock() }

    func deliver(_ data: Data) {
        lock.lock(); let h = handler; handler = nil; if h == nil { queued.append(data) }; lock.unlock()
        if let h { queue.async { h(data, nil) } }
    }
    func say(_ m: PeerWire.Message) { deliver(PeerWire.encode(m)) }
    /// The pending read, taken so a test can end the connection from the peer's side.
    func takeHandler() -> ((Data?, Error?) -> Void)? { lock.lock(); defer { lock.unlock() }; let h = handler; handler = nil; return h }
    func handshake(infoHash: Data, fast: Bool, extensions: Bool = true, id: String = "-SC0001-") {
        deliver(PeerWire.handshake(infoHash: infoHash, peerID: Data((id + String(repeating: "x", count: 20)).utf8.prefix(20)), extensions: extensions, fast: fast))
    }
    func queueForTest(_ work: @escaping () -> Void) { queue.async(execute: work) }
    var sentMessages: [PeerWire.Message] { lock.lock(); defer { lock.unlock() }; return messages }
    var gotHandshake: PeerWire.Handshake? { lock.lock(); defer { lock.unlock() }; return theirHandshake }
}

final class ScriptedPeers: PeerTransportFactory, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var made: [ScriptedPeer] = []
    var connectError: Error?
    func make(_ address: PeerAddress, queue: DispatchQueue) -> PeerTransport {
        let p = ScriptedPeer(address, queue: queue); p.connectError = connectError
        lock.lock(); made.append(p); lock.unlock(); return p
    }
    func peer(_ host: String) -> ScriptedPeer? { lock.lock(); defer { lock.unlock() }; return made.last { $0.address.host == host } }
    func count(_ host: String) -> Int { lock.lock(); defer { lock.unlock() }; return made.filter { $0.address.host == host }.count }
    var total: Int { lock.lock(); defer { lock.unlock() }; return made.count }
}

final class DX03SessionTests: TorrentSessionTestCase {
    private var t: TorrentFixture.Built!
    private let pub = ["198.51.100.11", "198.51.100.12", "198.51.100.13", "198.51.100.14"]

    private func make(isPrivate: Bool = false, have: Set<Int> = [], settings: TorrentSession.Settings = .testing, pieces: Int = 8) throws -> (TorrentSession, ScriptedPeers, Events) {
        t = try TorrentFixture.build(files: [(["a.bin"], 32768 * pieces)], isPrivate: isPrivate)
        let storage = TorrentStorage(meta: t.meta, workingFolder: TorrentStorage.workingFolder(for: taskID, in: root), selected: [])
        try storage.prepare()
        for p in have { try storage.write(piece: p, data: t.stream.subdata(in: (p * 32768)..<((p + 1) * 32768))) }
        let factory = ScriptedPeers(); let events = Events()
        let s = TorrentSession(infoHash: t.meta.infoHash, meta: t.meta, trackers: [], storage: { storage }, alreadyHave: have, transports: factory, tracker: RecordingTracker(), download: nil, upload: nil, taskID: taskID, settings: settings)
        s.onEvent = { events.add($0) }
        return (s, factory, events)
    }
    private func connect(_ s: TorrentSession, _ f: ScriptedPeers, _ host: String, fast: Bool, extensions: Bool = true) async -> ScriptedPeer? {
        s.addCandidates([PeerAddress(host: host, port: 6881)], source: "test")
        _ = await until { f.peer(host)?.gotHandshake != nil }
        guard let p = f.peer(host) else { return nil }
        p.handshake(infoHash: t.meta.infoHash, fast: fast, extensions: extensions)
        try? await Task.sleep(nanoseconds: 150_000_000)
        return p
    }

    // Fast Extension

    func testWeAdvertiseFastAndASeedStartsWithHaveNoneAndTheAllowedFastSet() async throws {
        let (s, f, _) = try make(); s.start()
        let p = await connect(s, f, pub[0], fast: true)
        XCTAssertEqual(p?.gotHandshake?.supportsFast, true)
        XCTAssertTrue(p?.sentMessages.contains(.haveNone) == true)
        let expected = PeerWire.allowedFastSet(ipv4: [198, 51, 100, 11], infoHash: t.meta.infoHash, pieceCount: 8)
        XCTAssertEqual(p?.sentMessages.compactMap { if case .allowedFast(let i) = $0 { i } else { nil } }, expected)
        s.stop(sendStoppedAnnounce: false)
    }

    func testWithoutTheBitNoFastMessageIsSentAndOneReceivedIsAViolation() async throws {
        let (s, f, _) = try make(have: [0, 1]); s.start()
        let p = await connect(s, f, pub[0], fast: false)
        XCTAssertTrue(p?.sentMessages.contains { if case .bitfield = $0 { true } else { false } } == true)
        XCTAssertFalse(p?.sentMessages.contains { switch $0 { case .allowedFast, .haveAll, .haveNone: true; default: false } } == true)
        p?.say(.haveAll)
        let dropped = await until { p?.closed == true }
        XCTAssertTrue(dropped, "a Fast Extension message that was not agreed")
        s.stop(sendStoppedAnnounce: false)
    }

    func testAChokedPeerIsAskedOnlyForItsAllowedFastPieces() async throws {
        let (s, f, _) = try make(); s.start()
        let p = await connect(s, f, pub[0], fast: true)!
        p.say(.haveAll); p.say(.allowedFast(5))
        let asked = await until { p.sentMessages.contains { if case .request = $0 { true } else { false } } }
        XCTAssertTrue(asked, "choked, yet the allowed-fast piece is requested")
        let pieces = Set(p.sentMessages.compactMap { m -> Int? in if case .request(let i, _, _) = m { i } else { nil } })
        XCTAssertEqual(pieces, [5], "nothing else while choked")
        s.stop(sendStoppedAnnounce: false)
    }

    func testARejectedRequestIsGivenToAnotherPeerAndNotAskedAgainOfTheSame() async throws {
        let (s, f, _) = try make(pieces: 1); s.start()
        let a = await connect(s, f, pub[0], fast: true)!
        a.say(.haveAll); a.say(.unchoke)
        _ = await until { a.sentMessages.contains { if case .request = $0 { true } else { false } } }
        let asked = a.sentMessages.compactMap { m -> (Int, Int, Int)? in if case .request(let i, let b, let l) = m { (i, b, l) } else { nil } }
        XCTAssertFalse(asked.isEmpty)
        let b = await connect(s, f, pub[1], fast: true)!
        b.say(.haveAll); b.say(.unchoke)
        a.say(.rejectRequest(index: asked[0].0, begin: asked[0].1, length: asked[0].2))
        let given = await until { b.sentMessages.contains { if case .request(let i, let begin, _) = $0 { i == asked[0].0 && begin == asked[0].1 } else { false } } }
        XCTAssertTrue(given, "the refused block is asked of someone else")
        let again = a.sentMessages.filter { if case .request(let i, let begin, _) = $0 { i == asked[0].0 && begin == asked[0].1 } else { false } }.count
        XCTAssertEqual(again, 1, "and not asked of the peer that refused it")
        s.stop(sendStoppedAnnounce: false)
    }

    func testFastPeersAreNotDroppedWhileAMagnetsDetailsAreStillBeingFetched() async throws {
        let built = try TorrentFixture.build(files: [(["a.bin"], 32768 * 4)])
        let storage = TorrentStorage(meta: built.meta, workingFolder: TorrentStorage.workingFolder(for: taskID, in: root), selected: [])
        try storage.prepare()
        let f = ScriptedPeers()
        let s = TorrentSession(infoHash: built.meta.infoHash, meta: nil, trackers: [URL(string: "http://a.example.com/announce")!], storage: { nil }, alreadyHave: [], transports: f, tracker: RecordingTracker(), download: nil, upload: nil, taskID: taskID, settings: .testing)
        s.start()
        s.addCandidates([PeerAddress(host: pub[0], port: 6881)], source: "test")
        _ = await until { f.peer(self.pub[0])?.gotHandshake != nil }
        let p = f.peer(pub[0])!
        XCTAssertEqual(p.gotHandshake?.supportsFast, true)
        p.handshake(infoHash: built.meta.infoHash, fast: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        for m in [PeerWire.Message.haveNone, .haveAll, .allowedFast(1), .suggest(2), .rejectRequest(index: 0, begin: 0, length: 16384)] { p.say(m) }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(p.closed, "with no details yet there is nothing to do with them, and that is not a fault")
        s.stop(sendStoppedAnnounce: false)
    }

    func testBadFastMessagesDropThePeer() async throws {
        for bad in [PeerWire.Message.suggest(999), .allowedFast(-1 & 0xFFFFFF), .rejectRequest(index: 999, begin: 0, length: 16384)] {
            let (s, f, _) = try make(); s.start()
            let p = await connect(s, f, pub[0], fast: true)!
            p.say(bad)
            let dropped = await until { p.closed }
            XCTAssertTrue(dropped, "\(bad)")
            s.stop(sendStoppedAnnounce: false)
        }
    }

    func testAChokedPeerGetsItsAllowedFastPieceAndARejectForAnythingElse() async throws {
        let (s, f, _) = try make(have: Set(0..<39), pieces: 40); s.start()           // everything but the last piece
        let p = await connect(s, f, pub[0], fast: true)!
        let fixture = t!
        let allowedSet = Set(PeerWire.allowedFastSet(ipv4: [198, 51, 100, 11], infoHash: fixture.meta.infoHash, pieceCount: 40))
        guard let inSet = allowedSet.first(where: { $0 < 39 }), let outSet = (0..<39).first(where: { !allowedSet.contains($0) }) else { return XCTFail("the set covers every piece we hold") }
        p.say(.request(index: inSet, begin: 0, length: 16384))
        p.say(.request(index: outSet, begin: 0, length: 16384))
        let both = await until { p.sentMessages.contains { if case .piece = $0 { true } else { false } } && p.sentMessages.contains { if case .rejectRequest = $0 { true } else { false } } }
        XCTAssertTrue(both)
        let served = p.sentMessages.compactMap { m -> Int? in if case .piece(let i, _, _) = m { i } else { nil } }
        XCTAssertTrue(served.contains(inSet), "the allowed-fast piece is served while choked")
        XCTAssertTrue(p.sentMessages.contains(.rejectRequest(index: outSet, begin: 0, length: 16384)), "choked and not allowed: refused, not ignored")
        s.stop(sendStoppedAnnounce: false)
    }

    // PEX

    private func extHandshake(pexID: Int) -> PeerWire.Message {
        .extended(id: 0, payload: BencodeDecoder.encode(.dict(["m": .dict(["ut_pex": .int(Int64(pexID))])])))
    }
    private func pex(_ added: [String], dropped: [String] = [], v6: [String] = []) -> PeerWire.Message {
        .extended(id: PeerWire.ExtensionID.utPex, payload: PeerWire.pexMessage(added: (added + v6).map { PeerWire.PexPeer(address: PeerAddress(host: $0, port: 6881), flags: 0x10) }, dropped: dropped.map { PeerAddress(host: $0, port: 6881) }))
    }

    func testPexPeersEnterTheSamePipelineAndAreDeduplicated() async throws {
        var settings = TorrentSession.Settings.testing; settings.pexInterval = 0
        let (s, f, _) = try make(settings: settings); s.start()
        let p = await connect(s, f, pub[0], fast: false)!
        XCTAssertTrue(p.gotHandshake?.supportsExtensions == true, "extensions are on so PEX can be negotiated")
        p.say(extHandshake(pexID: 7))
        p.say(pex([pub[1], pub[2], pub[1]], v6: ["2606:4700::9"]))
        let connected = await until { f.peer(self.pub[1]) != nil && f.peer(self.pub[2]) != nil && f.peer("2606:4700::9") != nil }
        XCTAssertTrue(connected, "IPv4 and IPv6 peers from PEX are connected to")
        XCTAssertEqual(f.count(pub[1]), 1, "named twice, connected once")
        s.addCandidates([PeerAddress(host: pub[2], port: 6881)], source: "dht")          // another source naming the same peer
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(f.count(pub[2]), 1)
        XCTAssertGreaterThanOrEqual(s.snapshot.pexAdded, 3)
        s.stop(sendStoppedAnnounce: false)
    }

    func testPexIsRateLimitedMalformedIgnoredAndLocalAddressesRefused() async throws {
        var settings = TorrentSession.Settings.testing; settings.allowLocalPeers = false
        let (s, f, _) = try make(settings: settings); s.start()
        let p = await connect(s, f, pub[0], fast: false)!
        p.say(extHandshake(pexID: 7))
        p.say(pex(["192.168.1.9", "127.0.0.1", pub[1]]))
        let first = await until { f.peer(self.pub[1]) != nil }
        XCTAssertTrue(first)
        XCTAssertNil(f.peer("192.168.1.9")); XCTAssertNil(f.peer("127.0.0.1"), "a peer cannot send us onto the local network")
        p.say(pex([pub[2]]))                                       // a second message at once: too soon
        p.say(.extended(id: PeerWire.ExtensionID.utPex, payload: Data("junk".utf8)))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(f.peer(pub[2]), "one PEX message a minute at most")
        XCTAssertFalse(p.closed, "malformed PEX is ignored, not fatal")
        s.stop(sendStoppedAnnounce: false)
    }

    func testPexDroppedPeersAreForgottenOnlyIfNothingElseNamedThem() async throws {
        var settings = TorrentSession.Settings.testing; settings.pexInterval = 0; settings.maxPeers = 1
        let (s, f, _) = try make(settings: settings); s.start()
        let p = await connect(s, f, pub[0], fast: false)!           // takes the only slot
        p.say(extHandshake(pexID: 7))
        p.say(pex([pub[1], pub[2]]))
        try await Task.sleep(nanoseconds: 200_000_000)
        s.addCandidates([PeerAddress(host: pub[2], port: 6881)], source: "dht")
        p.say(pex([], dropped: [pub[1], pub[2]]))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(f.peer(pub[1])); XCTAssertNil(f.peer(pub[2]))
        p.close(); p.say(.choke)
        s.stop(sendStoppedAnnounce: false)
    }

    func testAPrivateTorrentNeitherAdvertisesNorAcceptsPex() async throws {
        var settings = TorrentSession.Settings.testing; settings.pexInterval = 0
        let (s, f, _) = try make(isPrivate: true, settings: settings); s.start()
        let p = await connect(s, f, pub[0], fast: false, extensions: true)!
        XCTAssertEqual(p.gotHandshake?.supportsExtensions, false, "the extension protocol is not even offered, so no PEX is negotiated")
        p.say(extHandshake(pexID: 7)); p.say(pex([pub[1]]))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(f.peer(pub[1]), "peers from a private torrent's neighbours are never taken")
        s.stop(sendStoppedAnnounce: false)
    }

    func testPexOffInSettingsMeansNoPexEither() async throws {
        var settings = TorrentSession.Settings.testing; settings.pex = false; settings.pexInterval = 0
        let (s, f, _) = try make(settings: settings); s.start()
        let p = await connect(s, f, pub[0], fast: false)!
        XCTAssertEqual(p.gotHandshake?.supportsExtensions, false)
        p.say(pex([pub[1]]))
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertNil(f.peer(pub[1]))
        s.stop(sendStoppedAnnounce: false)
    }

    func testWeTellPexPeersAboutTheOthersButNeverAboutALANAddress() async throws {
        var settings = TorrentSession.Settings.testing; settings.pexInterval = 1
        let (s, f, _) = try make(settings: settings); s.start()
        let a = await connect(s, f, pub[0], fast: false)!
        let b = await connect(s, f, pub[1], fast: false)!
        let lan = await connect(s, f, "192.168.1.30", fast: false)!
        a.say(extHandshake(pexID: 9)); b.say(extHandshake(pexID: 9)); lan.say(extHandshake(pexID: 9))
        let told = await until(8) { a.sentMessages.contains { if case .extended(let id, _) = $0 { id == 9 } else { false } } }
        XCTAssertTrue(told)
        let payloads = a.sentMessages.compactMap { m -> PeerWire.PexMessage? in if case .extended(let id, let p) = m, id == 9 { PeerWire.parsePex(p) } else { nil } }
        let advertised = Set(payloads.flatMap(\.added).map(\.address.host))
        XCTAssertTrue(advertised.contains(pub[1])); XCTAssertFalse(advertised.contains(pub[0]), "never the peer itself"); XCTAssertFalse(advertised.contains("192.168.1.30"), "a LAN address is never given to a stranger")
        s.stop(sendStoppedAnnounce: false)
    }

    // IPv6, dedupe, backoff, counts

    func testIPv4MappedAndPlainAddressesAreOnePeerAndIPv6IsConnectedTo() async throws {
        let (s, f, _) = try make(); s.start()
        s.addCandidates([PeerAddress(host: "::ffff:198.51.100.11", port: 6881), PeerAddress(host: "198.51.100.11", port: 6881), PeerAddress(host: "2606:4700:0:0:0:0:0:5", port: 6881)], source: "test")
        _ = await until { f.total >= 2 }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(f.count("198.51.100.11"), 1); XCTAssertEqual(f.count("2606:4700::5"), 1)
        let v6 = f.peer("2606:4700::5")!
        v6.handshake(infoHash: t.meta.infoHash, fast: false)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(s.snapshot.peersIPv6, 1)
        s.stop(sendStoppedAnnounce: false)
    }

    func testAFailedConnectionBacksOffAndAPolicyRefusalIsNotCountedAgainstThePeer() async throws {
        let (s, f, _) = try make(); f.connectError = URLError(.cannotConnectToHost); s.start()
        s.addCandidates([PeerAddress(host: pub[0], port: 6881)], source: "test")
        _ = await until { f.count(self.pub[0]) >= 1 }
        try await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertEqual(f.count(pub[0]), 1, "not tried again straight away: it waits out its backoff")
        XCTAssertGreaterThanOrEqual(s.snapshot.connectFailures, 1)
        s.stop(sendStoppedAnnounce: false)
        let (s2, f2, _) = try make(); f2.connectError = HTTPTrackerClient.Failure.proxy("proxy"); s2.start()
        s2.addCandidates([PeerAddress(host: pub[1], port: 6881)], source: "test")
        _ = await until { s2.snapshot.policyBlocked >= 1 }
        XCTAssertEqual(s2.snapshot.policyBlocked, 1); XCTAssertEqual(s2.snapshot.connectFailures, 0, "our own refusal is not the peer's failure")
        s2.stop(sendStoppedAnnounce: false)
    }

    func testBlockedRangesNeverGetAConnection() async throws {
        var settings = TorrentSession.Settings.testing; settings.peerFilter = PeerFilter(["198.51.100.0/28"])
        let (s, f, _) = try make(settings: settings); s.start()
        s.addCandidates([PeerAddress(host: pub[0], port: 6881), PeerAddress(host: "203.0.113.5", port: 6881)], source: "test")
        _ = await until { f.peer("203.0.113.5") != nil }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(f.peer(pub[0])); XCTAssertNotNil(f.peer("203.0.113.5"))
        s.stop(sendStoppedAnnounce: false)
    }

    func testSnapshotCountsComeFromWhatIsConnected() async throws {
        let (s, f, _) = try make(); s.start()
        let a = await connect(s, f, pub[0], fast: true)!
        _ = await connect(s, f, pub[1], fast: false)!
        a.say(extHandshake(pexID: 3))
        try await Task.sleep(nanoseconds: 200_000_000)
        let snap = s.snapshot
        XCTAssertEqual(snap.peersIPv4, 2); XCTAssertEqual(snap.peersIPv6, 0); XCTAssertEqual(snap.fastPeers, 1); XCTAssertEqual(snap.peersBySource["tracker"], 2)
        s.stop(sendStoppedAnnounce: false)
    }

    func testPeerBudgetSharesFairlyBetweenTorrents() {
        let budget = PeerBudget(); budget.setLimit(20)
        let a = UUID(), b = UUID()
        var grabbedA = 0
        while budget.acquire(task: a) { grabbedA += 1 }
        XCTAssertEqual(grabbedA, 20, "alone, one torrent may use them all")
        XCTAssertFalse(budget.acquire(task: b), "b is refused: none are free")
        budget.release(task: a, count: 10)
        XCTAssertFalse(budget.acquire(task: a), "a is above its fair share while b waits")
        XCTAssertTrue(budget.acquire(task: b), "so the freed slots go to b")
        budget.releaseAll(task: a); budget.releaseAll(task: b)
    }

    // PEX provenance and settings that change while a torrent runs

    private func closeFromTheirSide(_ p: ScriptedPeer) {
        if let h = p.takeHandler() { p.queueForTest { h(nil, nil) } }
    }

    func testAPexDroppedFromOnePeerKeepsWhatAnotherPeerVouchesFor() async throws {
        var settings = TorrentSession.Settings.testing; settings.pexInterval = 0; settings.maxPeers = 2
        let (s, f, _) = try make(settings: settings); s.start()
        let a = await connect(s, f, pub[0], fast: false)!
        let b = await connect(s, f, pub[1], fast: false)!            // both slots taken: what they name waits as a candidate
        a.say(extHandshake(pexID: 7)); b.say(extHandshake(pexID: 7))
        let shared = "203.0.113.21", onlyA = "203.0.113.22", alsoDHT = "203.0.113.23"
        a.say(pex([shared, onlyA, alsoDHT])); b.say(pex([shared]))
        try await Task.sleep(nanoseconds: 250_000_000)
        s.addCandidates([PeerAddress(host: alsoDHT, port: 6881)], source: "dht")          // a source that is not PEX
        a.say(pex([], dropped: [shared, onlyA, alsoDHT]))
        try await Task.sleep(nanoseconds: 250_000_000)
        closeFromTheirSide(a)                                                              // a slot opens
        let took = await until { f.peer(shared) != nil }
        XCTAssertTrue(took, "b still vouches for it, so a's 'dropped' did not remove it")
        XCTAssertNil(f.peer(onlyA), "only a vouched for this one, and a took its word back")
        s.stop(sendStoppedAnnounce: false)
    }

    func testAnAddressLeavesOnlyAfterItsLastVoucherDropsIt() async throws {
        var settings = TorrentSession.Settings.testing; settings.pexInterval = 0; settings.maxPeers = 2
        let (s, f, _) = try make(settings: settings); s.start()
        let a = await connect(s, f, pub[0], fast: false)!
        let b = await connect(s, f, pub[1], fast: false)!
        a.say(extHandshake(pexID: 7)); b.say(extHandshake(pexID: 7))
        let x = "203.0.113.31"
        a.say(pex([x])); b.say(pex([x]))
        try await Task.sleep(nanoseconds: 250_000_000)
        a.say(pex([], dropped: [x])); try await Task.sleep(nanoseconds: 150_000_000)
        b.say(pex([], dropped: [x])); try await Task.sleep(nanoseconds: 250_000_000)
        closeFromTheirSide(a)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertNil(f.peer(x), "the last voucher dropped it: it is gone")
        s.stop(sendStoppedAnnounce: false)
    }

    func testAPeerThatNeverVouchedCannotRemoveAnAddress() async throws {
        var settings = TorrentSession.Settings.testing; settings.pexInterval = 0; settings.maxPeers = 2
        let (s, f, _) = try make(settings: settings); s.start()
        let a = await connect(s, f, pub[0], fast: false)!
        let b = await connect(s, f, pub[1], fast: false)!
        a.say(extHandshake(pexID: 7)); b.say(extHandshake(pexID: 7))
        let x = "203.0.113.41"
        a.say(pex([x]))
        try await Task.sleep(nanoseconds: 250_000_000)
        b.say(pex([], dropped: [x]))                          // b never said it was there
        try await Task.sleep(nanoseconds: 250_000_000)
        closeFromTheirSide(b)
        let took = await until { f.peer(x) != nil }
        XCTAssertTrue(took)
        s.stop(sendStoppedAnnounce: false)
    }

    func testTurningPexOffMidDownloadStopsItAtOnce() async throws {
        var settings = TorrentSession.Settings.testing; settings.pexInterval = 0
        let (s, f, _) = try make(settings: settings); s.start()
        let a = await connect(s, f, pub[0], fast: false)!
        a.say(extHandshake(pexID: 7))
        s.applyLive(pex: false, peerFilter: PeerFilter(), lan: nil, dht: nil)
        try await Task.sleep(nanoseconds: 150_000_000)
        a.say(pex(["203.0.113.51"]))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(f.peer("203.0.113.51"), "PEX was switched off: what a peer says now is not taken")
        s.stop(sendStoppedAnnounce: false)
    }

    func testAddingABlockedRangeMidDownloadClosesMatchingConnectionsAndKeepsTheRest() async throws {
        let (s, f, _) = try make(); s.start()
        let a = await connect(s, f, pub[0], fast: false)!
        let b = await connect(s, f, "203.0.113.9", fast: false)!
        s.applyLive(pex: true, peerFilter: PeerFilter(["198.51.100.0/24"]), lan: nil, dht: nil)
        let dropped = await until { a.closed }
        XCTAssertTrue(dropped, "a connected peer in a newly blocked range is closed")
        XCTAssertFalse(b.closed, "and an unrelated one is not touched")
        s.stop(sendStoppedAnnounce: false)
    }

    func testSwitchingLocalDiscoveryOffMidDownloadEndsPeersThatOnlyItSupplied() async throws {
        var settings = TorrentSession.Settings.testing; settings.allowLocalPeers = false
        let (s, f, _) = try make(settings: settings)
        s.localPeerStillAllowed = { _ in true }
        s.start()
        s.addCandidates([PeerAddress(host: "192.168.1.60", port: 6881)], fromLocalTracker: true, source: "lpd")
        s.addCandidates([PeerAddress(host: "192.168.1.61", port: 6881)], fromLocalTracker: true, source: "lpd")
        s.addCandidates([PeerAddress(host: "192.168.1.61", port: 6881)], fromLocalTracker: true, source: "http://192.168.1.2:80")
        _ = await until { f.peer("192.168.1.60") != nil && f.peer("192.168.1.61") != nil }
        s.localPeerStillAllowed = { $0 != "lpd" }
        s.applyLive(pex: true, peerFilter: PeerFilter(), lan: nil, dht: nil)
        let gone = await until { f.peer("192.168.1.60")?.closed == true }
        XCTAssertTrue(gone, "supplied only by local discovery: ended")
        XCTAssertEqual(f.peer("192.168.1.61")?.closed, false, "a local tracker also named it: it stays")
        s.stop(sendStoppedAnnounce: false)
    }

    func testChangingTheNetworkSettingsClosesConnectionsMadeUnderTheOldOnesAndTriesAgain() async throws {
        let (s, f, _) = try make(); s.start()
        let a = await connect(s, f, pub[0], fast: false)!
        s.networkChanged()
        let dropped = await until { a.closed }
        XCTAssertTrue(dropped)
        let again = await until { f.count(self.pub[0]) >= 2 }
        XCTAssertTrue(again, "the peer is tried again, now under the new settings")
        s.stop(sendStoppedAnnounce: false)
    }
}
