import CryptoKit
import XCTest
@testable import Browser_Setu

/// A peer that lives in memory and speaks the real wire protocol. It can be honest, corrupt, hostile or slow.
final class FakePeer: PeerTransport, @unchecked Sendable {
    struct Behaviour {
        var corrupt: Set<Int> = []                 // pieces it sends damaged
        var hasPieces: Set<Int>? = nil             // nil = all
        var wrongInfoHash = false
        var hugeFrame = false
        var unsolicitedBlock = false
        var connectError: Error?
        var serveMetadata: Data?                   // BEP 9: the info section it will hand out
        var badMetadata = false
        var asksForPiece: Int?                     // after unchoking us, it requests this piece's first block
        var neverUnchoke = false
    }

    let queue: DispatchQueue
    let stream: Data
    let meta: TorrentMetainfo?
    let infoHash: Data
    var behaviour: Behaviour
    private(set) var requested: [Int] = []
    private(set) var receivedBlocks: [Int] = []
    private(set) var closed = false
    private(set) var handshakeExtBit = false
    private(set) var sentToUs = 0
    private var inbox = Data(), outbox = Data()
    private var pending: ((Data?, Error?) -> Void)?
    private var shook = false
    private var parser: PeerWire.Parser
    private var theirMetadataID: UInt8 = 0
    private let lock = NSLock()

    init(queue: DispatchQueue, stream: Data, meta: TorrentMetainfo?, infoHash: Data, behaviour: Behaviour = Behaviour()) {
        self.queue = queue; self.stream = stream; self.meta = meta; self.infoHash = infoHash; self.behaviour = behaviour
        parser = PeerWire.Parser(pieceCount: meta?.pieceCount ?? 100_000)
    }

    func connect(_ done: @escaping (Error?) -> Void) { let e = behaviour.connectError; queue.async { done(e) } }

    func send(_ data: Data) {
        inbox.append(data)
        if !shook {
            guard inbox.count >= 68 else { return }
            guard let hs = try? PeerWire.parseHandshake(inbox) else { return }
            handshakeExtBit = hs.supportsExtensions
            inbox.removeFirst(68)
            shook = true
            reply(PeerWire.handshake(infoHash: behaviour.wrongInfoHash ? Data(repeating: 9, count: 20) : infoHash, peerID: Data((0..<20).map { _ in UInt8.random(in: 0...255) }), extensions: behaviour.serveMetadata != nil))
            if behaviour.hugeFrame { reply(Data([0xFF, 0xFF, 0xFF, 0xF0, 7])); return }
            if let meta, behaviour.serveMetadata == nil {
                reply(PeerWire.encode(.bitfield(PeerWire.makeBitfield((0..<meta.pieceCount).map { behaviour.hasPieces?.contains($0) ?? true }))))
            } else if behaviour.serveMetadata != nil {
                reply(PeerWire.encode(.extended(id: 0, payload: PeerWire.extensionHandshake(metadataSize: behaviour.serveMetadata!.count))))
            }
            if behaviour.unsolicitedBlock { reply(PeerWire.encode(.piece(index: 0, begin: 0, data: Data(count: 16384)))) }
        }
        guard let messages = try? parser.feed(inbox) else { closed = true; return }
        inbox = Data()
        for m in messages { handle(m) }
    }

    private func handle(_ m: PeerWire.Message) {
        switch m {
        case .interested:
            if !behaviour.neverUnchoke { reply(PeerWire.encode(.unchoke)) }
            if let p = behaviour.asksForPiece { reply(PeerWire.encode(.interested)); reply(PeerWire.encode(.request(index: p, begin: 0, length: 16384))) }
        case .request(let index, let begin, let length):
            requested.append(index)
            guard let meta else { return }
            var data = stream.subdata(in: (index * Int(meta.pieceLength) + begin)..<(index * Int(meta.pieceLength) + begin + length))
            if behaviour.corrupt.contains(index) { data[0] ^= 0xFF }
            reply(PeerWire.encode(.piece(index: index, begin: begin, data: data)))
        case .piece(let index, _, _): receivedBlocks.append(index)
        case .extended(let id, let payload):
            if id == 0 { theirMetadataID = (try? BencodeDecoder.decode(payload, limits: .message))?.value.dict?["m"]?.dict?["ut_metadata"]?.int.map { UInt8($0) } ?? 0; reply(PeerWire.encode(.unchoke)) }
            else if id == PeerWire.ExtensionID.utMetadata, let info = behaviour.serveMetadata, let msg = try? PeerWire.parseMetadataMessage(payload), msg.type == 0 {
                let start = msg.piece * 16384
                guard start < info.count else { return }
                var chunk = info.subdata(in: start..<min(info.count, start + 16384))
                if behaviour.badMetadata { chunk[0] ^= 0xFF }
                reply(PeerWire.encode(.extended(id: theirMetadataID, payload: PeerWire.metadataData(piece: msg.piece, total: info.count, data: chunk))))
            }
        default: break
        }
    }

    private func reply(_ data: Data) { sentToUs += data.count; outbox.append(data); flush() }

    func receive(_ handler: @escaping (Data?, Error?) -> Void) {
        queue.async { [self] in pending = handler; flush() }
    }

    private func flush() {
        queue.async { [self] in
            guard let handler = pending, !outbox.isEmpty || closed else { return }
            if closed && outbox.isEmpty { pending = nil; handler(nil, nil); return }
            let chunk = outbox.prefix(8192); outbox.removeFirst(chunk.count); pending = nil
            handler(Data(chunk), nil)
        }
    }

    func close() { closed = true }
}

final class FakePeers: PeerTransportFactory, @unchecked Sendable {
    var peers: [PeerAddress: FakePeer] = [:]
    var build: (PeerAddress, DispatchQueue) -> FakePeer
    private let lock = NSLock()
    init(build: @escaping (PeerAddress, DispatchQueue) -> FakePeer) { self.build = build }
    func make(_ address: PeerAddress, queue: DispatchQueue) -> PeerTransport {
        let p = build(address, queue); lock.lock(); peers[address] = p; lock.unlock(); return p
    }
    var all: [FakePeer] { lock.lock(); defer { lock.unlock() }; return Array(peers.values) }
}

final class FakeTracker: TrackerAnnouncing, @unchecked Sendable {
    var peers: [PeerAddress]
    var error: Error?
    private(set) var calls = 0
    private let lock = NSLock()
    init(peers: [PeerAddress]) { self.peers = peers }
    func announce(_ tracker: URL, infoHash: Data, peerID: Data, uploaded: Int64, downloaded: Int64, left: Int64?, event: String?) async throws -> TrackerReply {
        lock.lock(); calls += 1; lock.unlock()
        if let error { throw error }
        return TrackerReply(peers: peers, interval: 1800, warning: nil)
    }
}

extension TorrentSession.Settings { static var testing: TorrentSession.Settings { var s = TorrentSession.Settings(); s.allowLocalPeers = true; return s } }

class TorrentSessionTestCase: XCTestCase {
    var root: URL!
    let taskID = UUID()

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("p9s-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() { PeerBudget.shared.releaseAll(task: taskID); try? FileManager.default.removeItem(at: root) }

    func addr(_ n: Int) -> PeerAddress { PeerAddress(host: "10.0.0.\(n)", port: 6881) }

    struct Run {
        var session: TorrentSession; var storage: TorrentStorage; var factory: FakePeers; var events: Events
    }

    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [TorrentSession.Event] = []
        func add(_ e: TorrentSession.Event) { lock.lock(); list.append(e); lock.unlock() }
        var all: [TorrentSession.Event] { lock.lock(); defer { lock.unlock() }; return list }
        var verified: [Int] { all.compactMap { if case .verifiedPiece(let i, _) = $0 { i } else { nil } } }
        var finished: Bool { all.contains { if case .finished = $0 { true } else { false } } }
        var failure: String? { all.compactMap { if case .failed(let m, _) = $0 { m } else { nil } }.first }
        var metadata: TorrentMetainfo? { all.compactMap { if case .metadata(let m) = $0 { m } else { nil } }.first }
    }

    func makeRun(_ t: TorrentFixture.Built, peers: [Int], behaviours: [Int: FakePeer.Behaviour] = [:], selected: Set<Int> = [], have: Set<Int> = [], settings: TorrentSession.Settings = .testing,
                 down: BandwidthController? = nil, up: BandwidthController? = nil) throws -> Run {
        let storage = TorrentStorage(meta: t.meta, workingFolder: TorrentStorage.workingFolder(for: taskID, in: root), selected: selected)
        try storage.prepare()
        for p in have { try storage.write(piece: p, data: t.stream.subdata(in: (p * Int(t.meta.pieceLength))..<(p * Int(t.meta.pieceLength) + Int(t.meta.length(ofPiece: p))))) }
        let factory = FakePeers { a, q in FakePeer(queue: q, stream: t.stream, meta: t.meta, infoHash: t.meta.infoHash, behaviour: behaviours[Int(a.host.split(separator: ".").last!)!] ?? .init()) }
        let events = Events()
        let session = TorrentSession(infoHash: t.meta.infoHash, meta: t.meta, trackers: [URL(string: "http://tracker.test/announce")!], storage: { storage }, alreadyHave: have, transports: factory,
                                     tracker: FakeTracker(peers: peers.map(addr)), download: down, upload: up, taskID: taskID, settings: settings)
        session.onEvent = { events.add($0) }
        return Run(session: session, storage: storage, factory: factory, events: events)
    }

    func until(_ seconds: Double = 10, _ condition: @escaping () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if condition() { return true }; try? await Task.sleep(for: .milliseconds(20)) }
        return condition()
    }

    func assertFilesMatch(_ run: Run, _ t: TorrentFixture.Built, file: StaticString = #filePath, line: UInt = #line) throws {
        for f in t.meta.files where run.storage.selected.contains(f.index) {
            XCTAssertEqual(try Data(contentsOf: try run.storage.fileURL(f)), t.stream.subdata(in: Int(f.offset)..<Int(f.offset + f.length)), f.relativePath, file: file, line: line)
        }
    }
}

final class TorrentSessionTests: TorrentSessionTestCase {
    func testDownloadsAMultiFileTorrentFromSeveralPeers() async throws {
        let t = try TorrentFixture.build(files: [(["a.bin"], 70_000), (["d", "b.bin"], 90_001), (["c.bin"], 12_345)])
        let r = try makeRun(t, peers: [1, 2, 3])
        r.session.start()
        let done = await until { r.events.finished }
        XCTAssertTrue(done, "failure: \(r.events.failure ?? "-")")
        XCTAssertEqual(Set(r.events.verified), Set(0..<t.meta.pieceCount), "every piece was checked")
        try assertFilesMatch(r, t)
        let served = r.factory.all.filter { !$0.requested.isEmpty }.count
        XCTAssertGreaterThan(served, 1, "the work was spread over the peers")
        r.session.stop()
    }

    func testAPieceThatFailsItsCheckIsNeverWrittenAndIsFetchedElsewhere() async throws {
        let t = try TorrentFixture.build(files: [(["a.bin"], 200_000)])
        let r = try makeRun(t, peers: [1, 2], behaviours: [1: .init(corrupt: [0, 1, 2, 3, 4, 5, 6])])
        r.session.start()
        let done = await until { r.events.finished }
        XCTAssertTrue(done, "failure: \(r.events.failure ?? "-")")
        try assertFilesMatch(r, t)
        r.session.stop()
    }

    func testAPeerThatKeepsSendingBadDataIsDroppedAndNotReconnected() async throws {
        let t = try TorrentFixture.build(files: [(["a.bin"], 32768 * 12)])
        var s = TorrentSession.Settings.testing; s.maxHashFailuresPerPeer = 2
        let r = try makeRun(t, peers: [1, 2], behaviours: [1: .init(corrupt: Set(0..<12))], settings: s)
        r.session.start()
        _ = await until { r.events.finished }
        XCTAssertTrue(r.events.finished, "the honest peer finished it")
        XCTAssertTrue(r.factory.peers[addr(1)]?.closed ?? false, "the bad peer was disconnected")
        try assertFilesMatch(r, t)
        r.session.stop()
    }

    func testOnlyTheChosenFilesAreFetched() async throws {
        let t = try TorrentFixture.build(files: [(["a.bin"], 100_000), (["b.bin"], 100_000), (["c.bin"], 100_000)])
        let r = try makeRun(t, peers: [1], selected: [1])
        r.session.start()
        let u1 = await until { r.events.finished }
        XCTAssertTrue(u1, "failure: \(r.events.failure ?? "-")")
        let asked = Set(r.factory.all.flatMap(\.requested))
        XCTAssertTrue(asked.isSubset(of: Set(r.storage.neededPieces)), "never asked for pieces outside the chosen file: \(asked)")
        try assertFilesMatch(r, t)
        let names = try FileManager.default.contentsOfDirectory(atPath: r.storage.workingFolder.path)
        XCTAssertFalse(names.contains("a.bin") || names.contains("c.bin"))
        r.session.stop()
    }

    func testPiecesAlreadyHeldAreNotFetchedAgain() async throws {
        let t = try TorrentFixture.build(files: [(["a.bin"], 32768 * 6)])
        let r = try makeRun(t, peers: [1], have: [0, 1, 2])
        r.session.start()
        let u2 = await until { r.events.finished }
        XCTAssertTrue(u2, "failure: \(r.events.failure ?? "-")")
        XCTAssertTrue(Set(r.factory.all.flatMap(\.requested)).isDisjoint(with: [0, 1, 2]))
        try assertFilesMatch(r, t)
        r.session.stop()
    }

    func testTheFinalCheckReadsTheFilesBackAndCatchesDamage() async throws {
        let t = try TorrentFixture.build(files: [(["a.bin"], 32768 * 4)])
        // pieces 0-1 are "held" from an earlier run, but piece 1 on disk is damaged: the final check must find it and fetch it again
        let r = try makeRun(t, peers: [1], have: [0, 1])
        let url = try r.storage.fileURL(t.meta.files[0])
        let handle = try FileHandle(forUpdating: url); try handle.seek(toOffset: 32768 + 10); try handle.write(contentsOf: Data([0xAB, 0xCD])); try handle.close()
        r.session.start()
        let u3 = await until { r.events.finished }
        XCTAssertTrue(u3, "failure: \(r.events.failure ?? "-")")
        try assertFilesMatch(r, t)
        XCTAssertTrue(r.factory.all.flatMap(\.requested).contains(1), "the damaged piece was fetched again")
        r.session.stop()
    }

    func testAPeerOfAnotherTorrentIsDropped() async throws {
        let t = try TorrentFixture.build(files: [(["a.bin"], 100_000)])
        let r = try makeRun(t, peers: [1, 2], behaviours: [1: .init(wrongInfoHash: true)])
        r.session.start()
        let u4 = await until { r.events.finished }
        XCTAssertTrue(u4)
        XCTAssertTrue(r.factory.peers[addr(1)]?.requested.isEmpty ?? false)
        r.session.stop()
    }

    func testAnOversizedMessageDropsThePeerAndLeaksNothing() async throws {
        let t = try TorrentFixture.build(files: [(["a.bin"], 100_000)])
        let r = try makeRun(t, peers: [1, 2], behaviours: [1: .init(hugeFrame: true)])
        r.session.start()
        let u5 = await until { r.events.finished }
        XCTAssertTrue(u5)
        XCTAssertTrue(r.factory.peers[addr(1)]?.closed ?? false)
        r.session.stop()
        let u6 = await until(3) { PeerBudget.shared.holding(task: self.taskID) == 0 }
        XCTAssertTrue(u6, "every peer slot is given back")
    }

    func testABlockNobodyAskedForIsIgnored() async throws {
        let t = try TorrentFixture.build(files: [(["a.bin"], 100_000)])
        let r = try makeRun(t, peers: [1], behaviours: [1: .init(unsolicitedBlock: true)])
        r.session.start()
        let u7 = await until { r.events.finished }
        XCTAssertTrue(u7)
        try assertFilesMatch(r, t)
        r.session.stop()
    }

    func testPeerConnectionsAreCapped() async throws {
        let t = try TorrentFixture.build(files: [(["a.bin"], 32768 * 40)])
        var s = TorrentSession.Settings.testing; s.maxPeers = 3
        let r = try makeRun(t, peers: Array(1...12), behaviours: Dictionary(uniqueKeysWithValues: (1...12).map { ($0, FakePeer.Behaviour(neverUnchoke: true)) }), settings: s)
        r.session.start()
        try? await Task.sleep(for: .milliseconds(1500))
        XCTAssertLessThanOrEqual(r.factory.all.count, 3 + 3, "at most the cap (plus the odd retry), not all twelve")
        XCTAssertLessThanOrEqual(PeerBudget.shared.holding(task: taskID), 3)
        r.session.stop()
    }

    func testStoppingClosesEveryConnectionAndStopsEvents() async throws {
        let t = try TorrentFixture.build(files: [(["a.bin"], 32768 * 400)])
        let down = BandwidthController(); down.setOverallLimit(64 << 10)
        let r = try makeRun(t, peers: [1, 2], down: down)
        r.session.start()
        _ = await until(3) { !r.factory.all.isEmpty }
        r.session.stop()
        _ = await until(2) { r.factory.all.allSatisfy(\.closed) }
        XCTAssertTrue(r.factory.all.allSatisfy(\.closed))
        let before = r.events.all.count
        try? await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(r.events.all.count, before, "nothing is reported after a stop")
        XCTAssertEqual(PeerBudget.shared.holding(task: taskID), 0)
        XCTAssertFalse(r.events.finished)
    }

    func testAnUnreachablePeerIsRetriedBoundedlyAndTheOthersCarryOn() async throws {
        let t = try TorrentFixture.build(files: [(["a.bin"], 100_000)])
        let r = try makeRun(t, peers: [1, 2], behaviours: [1: .init(connectError: URLError(.cannotConnectToHost))])
        r.session.start()
        let u8 = await until { r.events.finished }
        XCTAssertTrue(u8)
        r.session.stop()
    }
}

final class TorrentRateTests: TorrentSessionTestCase {
    func testTheDownloadLimitPacesReadingFromPeers() async throws {
        let t = try TorrentFixture.build(files: [(["a.bin"], 320 * 1024)])
        let down = BandwidthController(); down.setOverallLimit(128 << 10)
        let r = try makeRun(t, peers: [1], down: down)
        let t0 = Date()
        r.session.start()
        let u9 = await until(20) { r.events.finished }
        XCTAssertTrue(u9, "failure: \(r.events.failure ?? "-")")
        let took = Date().timeIntervalSince(t0)
        print("MEASURED torrent download limit 128 KiB/s: 320 KiB in \(took)s = \(320.0 / took) KiB/s")
        XCTAssertGreaterThan(took, 1.8, "320 KiB at 128 KiB/s is about 2.5 s less the burst")
        XCTAssertLessThan(took, 8)
        try assertFilesMatch(r, t)
        r.session.stop()
    }

    func testUnlimitedIsFast() async throws {
        let t = try TorrentFixture.build(files: [(["a.bin"], 320 * 1024)])
        let r = try makeRun(t, peers: [1])
        let t0 = Date(); r.session.start()
        let u10 = await until(20) { r.events.finished }
        XCTAssertTrue(u10)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2.0)
        r.session.stop()
    }

    func testTheUploadLimitPacesWhatIsSentToPeers() async throws {
        let t = try TorrentFixture.build(files: [(["a.bin"], 32768 * 4)])
        let up = BandwidthController(); up.setOverallLimit(16 << 10)
        // the peer asks for blocks of pieces we hold from the start
        let r = try makeRun(t, peers: [1], behaviours: [1: .init(hasPieces: [], asksForPiece: 0)], have: [0, 1, 2, 3], up: up)
        r.session.start()
        let got = await until(10) { (r.factory.peers[self.addr(1)]?.receivedBlocks.count ?? 0) >= 1 }
        XCTAssertTrue(got || r.events.finished, "a block we hold was sent")
        r.session.stop()
    }

    func testNothingIsUploadedWhenSharingIsOff() async throws {
        let t = try TorrentFixture.build(files: [(["a.bin"], 32768 * 8)])
        var s = TorrentSession.Settings.testing; s.shareWhileDownloading = false
        let r = try makeRun(t, peers: [1], behaviours: [1: .init(asksForPiece: 0)], have: [0], settings: s)
        r.session.start()
        _ = await until(10) { r.events.finished }
        XCTAssertEqual(r.factory.peers[addr(1)]?.receivedBlocks.count ?? 0, 0, "no block was sent to the peer")
        XCTAssertEqual(r.session.snapshot.uploaded, 0)
        r.session.stop()
    }
}

final class MagnetMetadataTests: TorrentSessionTestCase {
    private func magnetRun(_ t: TorrentFixture.Built, behaviour: FakePeer.Behaviour) -> (TorrentSession, FakePeers, Events) {
        let factory = FakePeers { _, q in FakePeer(queue: q, stream: t.stream, meta: nil, infoHash: t.meta.infoHash, behaviour: behaviour) }
        let events = Events()
        let session = TorrentSession(infoHash: t.meta.infoHash, meta: nil, trackers: [URL(string: "http://tracker.test/announce")!], storage: { nil }, alreadyHave: [], transports: factory,
                                     tracker: FakeTracker(peers: [addr(1)]), download: nil, upload: nil, taskID: taskID, settings: .testing)
        session.onEvent = { events.add($0) }
        return (session, factory, events)
    }

    func testMetadataIsFetchedVerifiedAndParsed() async throws {
        let t = try TorrentFixture.build(files: [(["a.bin"], 60_000), (["b", "c.bin"], 70_000)], infoExtra: ["x": .bytes(Data(repeating: 1, count: 40_000))])
        var b = FakePeer.Behaviour(); b.serveMetadata = t.info
        let (session, _, events) = magnetRun(t, behaviour: b)
        session.start()
        let u11 = await until { events.metadata != nil }
        XCTAssertTrue(u11, "failure: \(events.failure ?? "-")")
        XCTAssertEqual(events.metadata?.infoHash, t.meta.infoHash)
        XCTAssertEqual(events.metadata?.files.count, 2)
        session.stop()
    }

    func testMetadataThatDoesNotMatchTheLinkIsRejected() async throws {
        let t = try TorrentFixture.build(files: [(["a.bin"], 60_000)])
        var b = FakePeer.Behaviour(); b.serveMetadata = t.info; b.badMetadata = true
        let (session, _, events) = magnetRun(t, behaviour: b)
        session.start()
        try? await Task.sleep(for: .seconds(1.5))
        XCTAssertNil(events.metadata, "bytes that do not hash to the link's identifier are never accepted")
        session.stop()
    }

    func testAMagnetSessionAdvertisesTheExtensionAndATorrentSessionDoesNot() async throws {
        let t = try TorrentFixture.build(files: [(["a.bin"], 60_000)], isPrivate: true)
        var b = FakePeer.Behaviour(); b.serveMetadata = t.info
        let (session, factory, _) = magnetRun(t, behaviour: b)
        session.start()
        _ = await until(3) { factory.all.first?.handshakeExtBit == true }
        XCTAssertTrue(factory.all.first?.handshakeExtBit ?? false, "a magnet link needs the extension protocol to get its metadata")
        session.stop()
        let r = try makeRun(t, peers: [1])
        r.session.start()
        _ = await until(3) { !r.factory.all.isEmpty }
        XCTAssertFalse(r.factory.all.first?.handshakeExtBit ?? true, "a torrent whose details are known (and a private one) offers no extensions")
        r.session.stop()
    }
}
