import XCTest
@testable import Browser_Setu

/// A leecher that lives in memory and speaks the real wire protocol, driven by the test: it answers the handshake, records every message the session sends, and sends whatever the test injects.
final class SeedLeecher: PeerTransport, @unchecked Sendable {
    let queue: DispatchQueue
    let infoHash: Data
    let fast: Bool
    var onShake: ((SeedLeecher) -> Void)?
    var onMessage: ((PeerWire.Message, SeedLeecher) -> Void)?
    var didRequest = false
    private let lock = NSLock()
    private var inbox = Data(), outbox = Data()
    private var pending: ((Data?, Error?) -> Void)?
    private var shook = false
    private var parser: PeerWire.Parser
    private var list: [PeerWire.Message] = []
    private var isClosed = false
    private var ext = false

    init(queue: DispatchQueue, meta: TorrentMetainfo, fast: Bool) {
        self.queue = queue; infoHash = meta.infoHash; self.fast = fast
        parser = PeerWire.Parser(pieceCount: meta.pieceCount)
    }

    var messages: [PeerWire.Message] { lock.lock(); defer { lock.unlock() }; return list }
    var closed: Bool { lock.lock(); defer { lock.unlock() }; return isClosed }
    var handshakeExtensionBit: Bool { lock.lock(); defer { lock.unlock() }; return ext }
    var blocks: [(index: Int, begin: Int, data: Data)] {
        var out: [(index: Int, begin: Int, data: Data)] = []
        for m in messages { if case .piece(let i, let b, let d) = m { out.append((index: i, begin: b, data: d)) } }
        return out
    }
    var haves: [Int] { messages.compactMap { if case .have(let i) = $0 { i } else { nil } } }
    var rejects: [Int] { messages.compactMap { if case .rejectRequest(let i, _, _) = $0 { i } else { nil } } }
    func count(_ m: PeerWire.Message) -> Int { messages.filter { $0 == m }.count }
    /// Whether the last thing the session said about choking was "unchoke".
    var unchokedNow: Bool {
        for m in messages.reversed() { if m == .unchoke { return true }; if m == .choke { return false } }
        return false
    }

    func connect(_ done: @escaping (Error?) -> Void) { queue.async { done(nil) } }

    func send(_ data: Data) {
        lock.lock(); let closedNow = isClosed; lock.unlock()
        if closedNow { return }
        inbox.append(data)
        if !shook {
            guard inbox.count >= 68, let hs = try? PeerWire.parseHandshake(inbox) else { return }
            lock.lock(); ext = hs.supportsExtensions; lock.unlock()
            inbox.removeFirst(68)
            shook = true
            reply(PeerWire.handshake(infoHash: infoHash, peerID: Data((0..<20).map { _ in UInt8.random(in: 0...255) }), extensions: false, fast: fast))
            onShake?(self)
        }
        guard let messages = try? parser.feed(inbox) else { lock.lock(); isClosed = true; lock.unlock(); return }
        inbox = Data()
        lock.lock(); list.append(contentsOf: messages); lock.unlock()
        for m in messages { onMessage?(m, self) }
    }

    /// Sends a message to the session (in order with everything else).
    func inject(_ m: PeerWire.Message) { queue.async { [self] in reply(PeerWire.encode(m)) } }
    private func reply(_ data: Data) { outbox.append(data); flush() }

    func receive(_ handler: @escaping (Data?, Error?) -> Void) { queue.async { [self] in pending = handler; flush() } }

    private func flush() {
        queue.async { [self] in
            guard let handler = pending else { return }
            lock.lock(); let c = isClosed; lock.unlock()
            if c && outbox.isEmpty { pending = nil; handler(nil, nil); return }
            guard !outbox.isEmpty else { return }
            let chunk = outbox.prefix(8192); outbox.removeFirst(chunk.count); pending = nil
            handler(Data(chunk), nil)
        }
    }

    func close() { lock.lock(); isClosed = true; lock.unlock() }
}

final class SeedPeers: PeerTransportFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var made: [Int: SeedLeecher] = [:]
    let build: (Int, DispatchQueue) -> SeedLeecher
    init(build: @escaping (Int, DispatchQueue) -> SeedLeecher) { self.build = build }
    func make(_ address: PeerAddress, queue: DispatchQueue) -> PeerTransport {
        let n = Int(address.host.split(separator: ".").last!)!
        let p = build(n, queue); lock.lock(); made[n] = p; lock.unlock(); return p
    }
    func make(_ address: PeerAddress, infoHash: Data, queue: DispatchQueue) -> PeerTransport { make(address, queue: queue) }
    subscript(n: Int) -> SeedLeecher? { lock.lock(); defer { lock.unlock() }; return made[n] }
    var all: [SeedLeecher] { lock.lock(); defer { lock.unlock() }; return made.sorted { $0.key < $1.key }.map(\.value) }
}

final class SeedTracker: TrackerAnnouncing, @unchecked Sendable {
    struct Call { var event: String?; var left: Int64?; var uploaded: Int64 }
    var peers: [PeerAddress]
    private let lock = NSLock()
    private var list: [Call] = []
    init(peers: [PeerAddress]) { self.peers = peers }
    func announce(_ tracker: URL, infoHash: Data, peerID: Data, uploaded: Int64, downloaded: Int64, left: Int64?, event: String?) async throws -> TrackerReply {
        lock.lock(); list.append(Call(event: event, left: left, uploaded: uploaded)); lock.unlock()
        return TrackerReply(peers: peers, interval: 1800, warning: nil)
    }
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return list }
}

class SeedTestCase: TorrentSessionTestCase {
    struct SeedRig {
        var session: TorrentSession; var source: SeedingSource; var factory: SeedPeers; var events: Events; var tracker: SeedTracker
        var t: TorrentFixture.Built; var location: URL
    }

    static let standardFiles: [([String], Int)] = [(["a.bin"], 70_000), (["d", "b.bin"], 90_001)]          // 5 pieces of 32 KiB; piece 2 spans both files

    func writeFiles(_ t: TorrentFixture.Built, to location: URL) throws {
        for f in t.meta.files {
            var url = location
            for part in f.path { url.appendPathComponent(part) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try t.stream.subdata(in: Int(f.offset)..<Int(f.offset + f.length)).write(to: url)
        }
    }

    func fileURL(_ rig: SeedRig, _ index: Int) -> URL {
        var url = rig.location
        for part in rig.t.meta.files[index].path { url.appendPathComponent(part) }
        return url
    }

    /// A finished torrent on disk, a seeding session over it, and one scripted leecher for each peer number.
    func makeSeed(_ t: TorrentFixture.Built, peers: [Int], fast: Bool = true, verified: Set<Int>? = nil, chosen: Set<Int>? = nil, config: TorrentSession.SeedingConfig = .init(), settings: TorrentSession.Settings = .testing,
                  up: BandwidthController? = nil, mutate: ((URL) throws -> Void)? = nil, script: @escaping (Int, SeedLeecher) -> Void = { _, _ in }) throws -> SeedRig {
        let location = root.appendingPathComponent("final-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try writeFiles(t, to: location)
        let source = SeedingSource(meta: t.meta, location: location, chosen: chosen ?? Set(t.meta.files.map(\.index)), verifiedPieces: verified ?? Set(0..<t.meta.pieceCount))
        try mutate?(location)
        let factory = SeedPeers { n, q in let p = SeedLeecher(queue: q, meta: t.meta, fast: fast); script(n, p); return p }
        let events = Events()
        let tracker = SeedTracker(peers: peers.map(addr))
        let session = TorrentSession(infoHash: t.meta.infoHash, meta: t.meta, trackers: [URL(string: "http://tracker.test/announce")!], storage: { nil }, alreadyHave: [], transports: factory,
                                     tracker: tracker, download: nil, upload: up, taskID: taskID, settings: settings)
        session.seedSource = source
        session.seedConfig = config
        session.onEvent = { events.add($0) }
        return SeedRig(session: session, source: source, factory: factory, events: events, tracker: tracker, t: t, location: location)
    }

    /// Interested at once; asks for `requests` as soon as it is unchoked.
    static func eager(_ requests: [(Int, Int, Int)]) -> (Int, SeedLeecher) -> Void {
        { _, p in
            p.onShake = { p in p.inject(.interested) }
            p.onMessage = { m, p in
                if m == .unchoke, !p.didRequest { p.didRequest = true; for r in requests { p.inject(.request(index: r.0, begin: r.1, length: r.2)) } }
            }
        }
    }

    func slice(_ t: TorrentFixture.Built, piece: Int, begin: Int, length: Int) -> Data {
        let start = piece * Int(t.meta.pieceLength) + begin
        return t.stream.subdata(in: start..<(start + length))
    }

    func ended(_ rig: SeedRig, _ reason: SeedStopReason) -> Bool {
        rig.events.all.contains { if case .seedingEnded(let r) = $0 { r == reason } else { false } }
    }
}

final class DX06SeedTests: SeedTestCase {
    // MARK: Serving

    func testAFinishedTorrentSeedsToTwoPeersAndCountsWhatWasSent() async throws {
        let t = try TorrentFixture.build(files: Self.standardFiles)
        let reqs = [(0, 0, 16384), (1, 16384, 16384), (4, 16384, Int(t.meta.length(ofPiece: 4)) - 16384)]
        let r = try makeSeed(t, peers: [1, 2], script: Self.eager(reqs))
        r.session.start()
        let ok = await until { r.factory.all.count == 2 && r.factory.all.allSatisfy { $0.blocks.count == 3 } }
        XCTAssertTrue(ok, "both peers received their blocks")
        for p in r.factory.all {
            for b in p.blocks { XCTAssertEqual(b.data, slice(t, piece: b.index, begin: b.begin, length: b.data.count), "piece \(b.index) bytes are the torrent's") }
            XCTAssertTrue(p.messages.contains(.haveAll), "a complete seeder says so with one message (Fast Extension)")
        }
        let sent = Int64(2 * reqs.reduce(0) { $0 + $1.2 })
        XCTAssertEqual(r.session.snapshot.uploaded, sent)
        XCTAssertEqual(r.session.snapshot.seeding?.uploadedTotal, sent)
        let calls = r.tracker.calls
        XCTAssertFalse(calls.isEmpty)
        XCTAssertTrue(calls.allSatisfy { $0.left == 0 }, "a seeder announces that nothing is left")
        XCTAssertFalse(calls.contains { $0.event == "completed" }, "a seeding session does not announce a completion")
        r.session.stop()
    }

    func testANonFastPeerGetsABitfieldOfWhatCanBeShared() async throws {
        let t = try TorrentFixture.build(files: Self.standardFiles)
        let r = try makeSeed(t, peers: [1], fast: false, verified: [0, 1, 4])
        r.session.start()
        let ok = await until { r.factory[1]?.messages.contains { if case .bitfield = $0 { true } else { false } } == true }
        XCTAssertTrue(ok)
        guard case .bitfield(let field)? = r.factory[1]?.messages.first(where: { if case .bitfield = $0 { true } else { false } }) else { return XCTFail("no bitfield") }
        // pieces 0 and 1 lie in a.bin only and piece 4 in b.bin only; both files are chosen
        XCTAssertEqual(field, PeerWire.makeBitfield([true, true, false, false, true]))
        r.session.stop()
    }

    func testMorePeersAskingForTheSamePieceAreAllAnswered() async throws {
        let t = try TorrentFixture.build(files: Self.standardFiles)
        let r = try makeSeed(t, peers: [1, 2, 3], script: Self.eager([(0, 0, 16384)]))
        r.session.start()
        let ok = await until { r.factory.all.count == 3 && r.factory.all.allSatisfy { $0.blocks.count == 1 } }
        XCTAssertTrue(ok)
        XCTAssertEqual(Set(r.factory.all.map { $0.blocks[0].data }).count, 1, "the same bytes went to each")
        XCTAssertEqual(r.session.snapshot.uploaded, 3 * 16384)
        r.session.stop()
    }

    func testAskingTwiceForTheSameBlockIsAnsweredOnce() async throws {
        let t = try TorrentFixture.build(files: Self.standardFiles)
        let r = try makeSeed(t, peers: [1], script: Self.eager([(0, 0, 16384), (0, 0, 16384), (0, 0, 16384)]))
        r.session.start()
        _ = await until { r.factory[1]?.blocks.count ?? 0 >= 1 }
        try? await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(r.factory[1]?.blocks.count, 1)
        r.session.stop()
    }

    // MARK: Requests that must not be served

    func testInvalidRequestsCloseThePeerAndReadNothing() async throws {
        let t = try TorrentFixture.build(files: Self.standardFiles)
        let last = Int(t.meta.length(ofPiece: 4))
        let cases: [(String, (Int, Int, Int))] = [("piece out of range", (999, 0, 16384)), ("zero length", (0, 0, 0)), ("longer than 16 KiB", (0, 0, 32768)),
                                                  ("past the end of the piece", (0, 32768, 16384)), ("past the end of the short last piece", (4, 16384, last))]
        for (name, request) in cases {
            let r = try makeSeed(t, peers: [1], script: Self.eager([request]))
            r.session.start()
            let closed = await until(6) { r.factory[1]?.closed == true }
            XCTAssertTrue(closed, "\(name): the peer is closed")
            XCTAssertEqual(r.factory[1]?.blocks.count, 0, name)
            XCTAssertEqual(r.source.blockReads, 0, "\(name): nothing was read from the disk")
            XCTAssertEqual(r.session.snapshot.uploaded, 0, name)
            r.session.stop()
            _ = await until(2) { PeerBudget.shared.holding(task: self.taskID) == 0 }
            PeerBudget.shared.releaseAll(task: taskID)
        }
    }

    func testAPieceThatIsNotVerifiedIsRefusedWithoutReadingAndTheFilesAreUntouched() async throws {
        let t = try TorrentFixture.build(files: Self.standardFiles)
        let r = try makeSeed(t, peers: [1], verified: [0, 3, 4], script: Self.eager([(1, 0, 16384), (0, 0, 16384)]))
        r.session.start()
        let ok = await until { r.factory[1]?.blocks.count == 1 && r.factory[1]?.rejects.contains(1) == true }
        XCTAssertTrue(ok, "piece 0 is served and piece 1 is refused")
        XCTAssertEqual(r.factory[1]?.blocks.first?.index, 0)
        XCTAssertEqual(r.source.blockReads, 1, "only the served block touched the disk")
        XCTAssertFalse(r.factory[1]?.closed ?? true, "an honest peer asking for something we did not offer is not punished at once")
        r.session.stop()
    }

    func testARequestFromAChokedPeerIsNotAnswered() async throws {
        let t = try TorrentFixture.build(files: Self.standardFiles)
        // never interested, so never unchoked; it asks anyway (a peer without the Fast Extension has no allowed pieces)
        let r = try makeSeed(t, peers: [1], fast: false, script: { _, p in p.onShake = { p in p.inject(.request(index: 0, begin: 0, length: 16384)) } })
        r.session.start()
        _ = await until { r.factory[1]?.messages.isEmpty == false }
        try? await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(r.factory[1]?.blocks.count, 0)
        XCTAssertEqual(r.source.blockReads, 0)
        r.session.stop()
    }

    func testPiecesTouchingAFileThePersonDidNotChooseAreNotShared() async throws {
        let t = try TorrentFixture.build(files: Self.standardFiles)
        let r = try makeSeed(t, peers: [1], fast: false, chosen: [0])          // only a.bin: pieces 0 and 1 are wholly inside it, piece 2 also holds b.bin bytes
        XCTAssertEqual(r.source.servablePieces, [0, 1])
        r.session.start()
        let ok = await until { r.factory[1]?.messages.contains { if case .bitfield = $0 { true } else { false } } == true }
        XCTAssertTrue(ok)
        r.session.stop()
    }

    // MARK: Files that change

    func testAFileRemovedAfterCompletionStopsItsPiecesAndIsNotRecreated() async throws {
        let t = try TorrentFixture.build(files: Self.standardFiles)
        var bURL: URL!
        let r = try makeSeed(t, peers: [1], mutate: { location in bURL = location.appendingPathComponent("d/b.bin"); try FileManager.default.removeItem(at: bURL) },
                             script: Self.eager([(2, 0, 16384), (3, 0, 16384), (0, 0, 16384)]))
        r.session.start()
        let ok = await until { r.factory[1]?.blocks.count == 1 && Set(r.factory[1]?.rejects ?? []) == [2, 3] }
        XCTAssertTrue(ok, "piece 0 (a.bin only) is served; 2 and 3 (they use b.bin) are refused")
        XCTAssertEqual(r.factory[1]?.blocks.first?.index, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bURL.path), "nothing recreates the missing file")
        XCTAssertEqual(try Data(contentsOf: fileURL(r, 0)), t.stream.subdata(in: 0..<70_000), "the other file is untouched")
        XCTAssertFalse(r.source.isServable(2)); XCTAssertTrue(r.source.isServable(0))
        r.session.stop()
    }

    func testAFileChangedAfterCompletionIsNotServedAndIsLeftAsItIs() async throws {
        let t = try TorrentFixture.build(files: Self.standardFiles)
        var edited = Data()
        let r = try makeSeed(t, peers: [1], mutate: { location in
            let a = location.appendingPathComponent("a.bin")
            var d = try Data(contentsOf: a); d[100] ^= 0xFF; edited = d          // same size: only the modification time and content differ
            try d.write(to: a)
        }, script: Self.eager([(0, 0, 16384), (4, 0, 16384)]))
        r.session.start()
        let ok = await until { r.factory[1]?.blocks.count == 1 && r.factory[1]?.rejects.contains(0) == true }
        XCTAssertTrue(ok, "the piece in the changed file is refused, b.bin's piece is served")
        XCTAssertEqual(r.factory[1]?.blocks.first?.index, 4)
        XCTAssertEqual(try Data(contentsOf: fileURL(r, 0)), edited, "the changed file is not rewritten or removed")
        r.session.stop()
    }

    func testAModificationTimeChangeAloneRevokesTheFile() async throws {
        let t = try TorrentFixture.build(files: Self.standardFiles)
        let r = try makeSeed(t, peers: [1])
        XCTAssertTrue(r.source.isServable(0))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(500)], ofItemAtPath: fileURL(r, 0).path)
        XCTAssertFalse(r.source.audit())
        XCTAssertFalse(r.source.isServable(0)); XCTAssertFalse(r.source.isServable(2)); XCTAssertTrue(r.source.isServable(4))
    }

    func testALinkInPlaceOfAFileIsNeverFollowed() async throws {
        let t = try TorrentFixture.build(files: Self.standardFiles)
        let outside = root.appendingPathComponent("secret.bin")
        try Data(repeating: 7, count: 70_000).write(to: outside)
        let r = try makeSeed(t, peers: [1])
        let a = fileURL(r, 0)
        try FileManager.default.removeItem(at: a)
        try FileManager.default.createSymbolicLink(at: a, withDestinationURL: outside)
        XCTAssertEqual(r.source.read(piece: 0, begin: 0, length: 16384), .failure(.filesChanged))
        XCTAssertFalse(r.source.isServable(0))
    }

    func testWhenNothingCanBeSharedAnyMoreSeedingEnds() async throws {
        let t = try TorrentFixture.build(files: [(["only.bin"], 100_000)])
        let r = try makeSeed(t, peers: [1], script: Self.eager([(0, 0, 16384)]))
        r.session.start()
        _ = await until { r.factory[1]?.blocks.count == 1 }
        try FileManager.default.removeItem(at: fileURL(r, 0))
        r.factory[1]?.inject(.request(index: 1, begin: 0, length: 16384))
        let done = await until(6) { self.ended(r, .filesChanged) }
        XCTAssertTrue(done)
    }

    // MARK: Cancel, throttle, targets

    func testACancelledBlockIsNotSentAndNotCounted() async throws {
        let t = try TorrentFixture.build(files: Self.standardFiles)
        let up = BandwidthController(); up.setTaskLimit(32_768, for: taskID)
        let r = try makeSeed(t, peers: [1], up: up, script: { _, p in
            p.onShake = { p in p.inject(.interested) }
            p.onMessage = { m, p in
                guard m == .unchoke, !p.didRequest else { return }
                p.didRequest = true
                for piece in 0..<3 { for b in 0..<2 { p.inject(.request(index: piece, begin: b * 16384, length: 16384)) } }
                for piece in 1..<3 { for b in 0..<2 { p.inject(.cancel(index: piece, begin: b * 16384, length: 16384)) } }          // the last four are taken back at once
            }
        })
        r.session.start()
        _ = await until(10) { r.factory[1]?.blocks.count ?? 0 >= 2 }
        try? await Task.sleep(for: .seconds(3))
        let got = r.factory[1]?.blocks ?? []
        XCTAssertEqual(Set(got.map(\.index)), [0], "only piece 0's two blocks were sent; the cancelled ones never were")
        XCTAssertEqual(r.session.snapshot.uploaded, 2 * 16384, "cancelled blocks are not counted as uploaded")
        r.session.stop()
    }

    func testTheUploadLimitPacesWhatIsSent() async throws {
        let t = try TorrentFixture.build(files: Self.standardFiles)
        let up = BandwidthController(); up.setTaskLimit(32_768, for: taskID)
        let reqs = (0..<4).flatMap { piece in [(piece, 0, 16384), (piece, 16384, 16384)] }          // 128 KiB
        let r = try makeSeed(t, peers: [1], up: up, script: Self.eager(reqs))
        let t0 = Date()
        r.session.start()
        let ok = await until(20) { r.factory[1]?.blocks.count == 8 }
        let took = Date().timeIntervalSince(t0)
        XCTAssertTrue(ok)
        print("MEASURED seeding upload limit 32 KiB/s: 128 KiB in \(took)s")
        XCTAssertGreaterThan(took, 2.5, "128 KiB at 32 KiB/s is about 3.75 s less the burst")
        XCTAssertLessThan(took, 9)
        r.session.stop()
    }

    func testTheRatioTargetStopsSeedingCleanly() async throws {
        let t = try TorrentFixture.build(files: Self.standardFiles)
        var c = TorrentSession.SeedingConfig(); c.ratioTarget = 0.1          // 160 001 bytes shared: 16 000 uploaded is enough
        let r = try makeSeed(t, peers: [1], config: c, script: Self.eager([(0, 0, 16384), (0, 16384, 16384)]))
        r.session.start()
        let done = await until(8) { self.ended(r, .ratioReached) }
        XCTAssertTrue(done, "the ratio was reached")
        XCTAssertTrue(r.factory[1]?.closed ?? false, "the peer was closed")
        let stopped = await until(4) { r.tracker.calls.contains { $0.event == "stopped" } }
        XCTAssertTrue(stopped, "the tracker hears 'stopped'")
        let before = r.factory[1]?.blocks.count ?? 0
        try? await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(r.factory[1]?.blocks.count, before, "nothing is sent after the stop")
        XCTAssertEqual(PeerBudget.shared.holding(task: taskID), 0)
    }

    func testTheRatioCountsWhatWasUploadedBeforeARelaunch() async throws {
        let t = try TorrentFixture.build(files: Self.standardFiles)
        var c = TorrentSession.SeedingConfig(); c.ratioTarget = 1.0; c.priorUploaded = 160_001
        let r = try makeSeed(t, peers: [1], config: c)
        r.session.start()
        let done = await until(5) { self.ended(r, .ratioReached) }
        XCTAssertTrue(done, "the earlier upload counts toward the ratio")
    }

    func testTheTimeLimitStopsSeedingAndEarlierTimeCounts() async throws {
        let t = try TorrentFixture.build(files: Self.standardFiles)
        var c = TorrentSession.SeedingConfig(); c.timeLimit = 1.2
        let r = try makeSeed(t, peers: [1], config: c)
        r.session.start()
        let done = await until(8) { self.ended(r, .timeLimitReached) }
        XCTAssertTrue(done)
        var c2 = TorrentSession.SeedingConfig(); c2.timeLimit = 1000.5; c2.priorSeconds = 1000
        let r2 = try makeSeed(t, peers: [1], config: c2)
        r2.session.start()
        let done2 = await until(8) { self.ended(r2, .timeLimitReached) }
        XCTAssertTrue(done2, "time seeded before the relaunch is counted")
    }

    // MARK: Policy, privacy, resources

    func testSeedingIsOffByDefaultAndNeedsEveryPermission() {
        XCTAssertEqual(TorrentSettings().seedingMode, .off)
        let old = #"{"enabled":true,"maxActiveTorrents":3,"maxPeersPerTorrent":30,"maxPeersTotal":60,"shareWhileDownloading":true}"#
        let s = TorrentSettings.decode(old)
        XCTAssertEqual(s.seedingMode, .off); XCTAssertNil(s.ratioTarget); XCTAssertEqual(s.maxUploadPeers, 8); XCTAssertFalse(s.initialSeeding)
        XCTAssertNotNil(SeedPolicy.blockReason(enabled: true, mode: .off, authorized: true, proxyUnusable: false, pathRefusal: nil), "app-wide off always wins")
        XCTAssertNotNil(SeedPolicy.blockReason(enabled: true, mode: .completed, authorized: false, proxyUnusable: false, pathRefusal: nil), "a torrent needs its own consent")
        XCTAssertNotNil(SeedPolicy.blockReason(enabled: false, mode: .completed, authorized: true, proxyUnusable: false, pathRefusal: nil), "peer-to-peer off stops it")
        XCTAssertNotNil(SeedPolicy.blockReason(enabled: true, mode: .completed, authorized: true, proxyUnusable: true, pathRefusal: nil), "an unusable proxy stops it")
        XCTAssertNotNil(SeedPolicy.blockReason(enabled: true, mode: .completed, authorized: true, proxyUnusable: false, pathRefusal: "expensive network"), "a metered network the person refused stops it")
        XCTAssertNil(SeedPolicy.blockReason(enabled: true, mode: .completed, authorized: true, proxyUnusable: false, pathRefusal: nil))
        var round = TorrentSettings(); round.seedingMode = .whileDownloadingAndCompleted; round.ratioTarget = 2; round.seedTimeLimit = 7200; round.uploadPeers = 99; round.initialSeeding = true
        let back = TorrentSettings.decode(round.encoded())
        XCTAssertEqual(back.seedingMode, .whileDownloadingAndCompleted); XCTAssertEqual(back.ratioTarget, 2); XCTAssertEqual(back.maxUploadPeers, 50, "bounded"); XCTAssertTrue(back.initialSeeding)
    }

    func testPeerToPeerBeingTurnedOffEndsASessionWithoutTellingAnyTracker() async throws {
        let t = try TorrentFixture.build(files: Self.standardFiles)
        let r = try makeSeed(t, peers: [1], script: Self.eager([(0, 0, 16384)]))
        r.session.start()
        _ = await until { r.factory[1]?.blocks.count == 1 }
        r.session.stop(sendStoppedAnnounce: false)
        _ = await until(2) { r.factory[1]?.closed == true }
        try? await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(r.factory[1]?.closed ?? false)
        XCTAssertFalse(r.tracker.calls.contains { $0.event == "stopped" }, "nothing is sent to a tracker when peer-to-peer is turned off")
    }

    func testAPrivateTorrentOffersNoPeerExchangeAndAPublicOneDoes() async throws {
        let priv = try TorrentFixture.build(files: Self.standardFiles, isPrivate: true)
        let pub = try TorrentFixture.build(files: Self.standardFiles)
        let a = try makeSeed(priv, peers: [1])
        a.session.start()
        _ = await until { a.factory[1]?.messages.isEmpty == false }
        XCTAssertEqual(a.factory[1]?.handshakeExtensionBit, false, "no extension protocol (so no PEX) for a private torrent")
        a.session.stop()
        PeerBudget.shared.releaseAll(task: taskID)
        let b = try makeSeed(pub, peers: [1])
        b.session.start()
        _ = await until { b.factory[1]?.messages.isEmpty == false }
        XCTAssertEqual(b.factory[1]?.handshakeExtensionBit, true)
        b.session.stop()
    }

    func testOnlyAsManyPeersAsThereAreSlotsAreUnchokedAndTheyTakeTurns() async throws {
        let t = try TorrentFixture.build(files: Self.standardFiles)
        var s = TorrentSession.Settings.testing; s.uploadSlots = 2
        var c = TorrentSession.SeedingConfig(); c.chokeInterval = 0.4
        let r = try makeSeed(t, peers: [1, 2, 3, 4], config: c, settings: s, script: { _, p in p.onShake = { p in p.inject(.interested) } })
        r.session.start()
        let two = await until { r.factory.all.count == 4 && r.factory.all.filter { $0.unchokedNow }.count == 2 }
        XCTAssertTrue(two, "two slots are given")
        let turns = await until(8) { r.factory.all.allSatisfy { $0.count(.unchoke) >= 1 } }
        XCTAssertTrue(turns, "everyone who waits gets a turn")
        for _ in 0..<10 { XCTAssertLessThanOrEqual(r.factory.all.filter { $0.unchokedNow }.count, 2, "never more than the slots"); try? await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(r.factory.all.contains { $0.count(.choke) >= 1 }, "a peer that held a slot was choked to make room")
        r.session.stop()
    }

    func testASlotFreedByAPeerThatLosesInterestGoesToTheNextOne() async throws {
        let t = try TorrentFixture.build(files: Self.standardFiles)
        var s = TorrentSession.Settings.testing; s.uploadSlots = 1
        var c = TorrentSession.SeedingConfig(); c.chokeInterval = 1000
        let r = try makeSeed(t, peers: [1, 2], config: c, settings: s, script: { _, p in p.onShake = { p in p.inject(.interested) } })
        r.session.start()
        _ = await until { r.factory.all.count == 2 && r.factory.all.filter { $0.unchokedNow }.count == 1 }
        guard let holder = r.factory.all.first(where: { $0.unchokedNow }), let waiting = r.factory.all.first(where: { !$0.unchokedNow }) else { return XCTFail("one holds the slot") }
        holder.inject(.notInterested)
        let moved = await until { waiting.unchokedNow }
        XCTAssertTrue(moved)
        XCTAssertTrue(holder.count(.choke) >= 1)
        r.session.stop()
    }

    func testStoppingLeavesNoConnectionsTimersOrLateUploads() async throws {
        let t = try TorrentFixture.build(files: Self.standardFiles)
        let up = BandwidthController(); up.setTaskLimit(16_384, for: taskID)
        let reqs = (0..<4).flatMap { piece in [(piece, 0, 16384), (piece, 16384, 16384)] }
        let r = try makeSeed(t, peers: [1, 2], up: up, script: Self.eager(reqs))
        r.session.start()
        _ = await until { (r.factory[1]?.blocks.count ?? 0) >= 1 }
        r.session.stop()
        let closed = await until(3) { r.factory.all.allSatisfy(\.closed) }
        XCTAssertTrue(closed)
        let eventsBefore = r.events.all.count
        let blocksBefore = r.factory.all.map { $0.blocks.count }
        try? await Task.sleep(for: .seconds(2))
        XCTAssertEqual(r.factory.all.map { $0.blocks.count }, blocksBefore, "blocks waiting for the limit are not sent after a stop")
        XCTAssertEqual(r.events.all.count, eventsBefore)
        XCTAssertEqual(PeerBudget.shared.holding(task: taskID), 0)
        XCTAssertEqual(r.session.snapshot.peers, 0)
    }

    // MARK: Persistence

    func testSidecarsOfEarlierVersionsLoadAndSeedingFieldsRoundTrip() throws {
        let t = try TorrentFixture.build(files: Self.standardFiles)
        let folder = root.appendingPathComponent("side", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try TorrentRunner.saveSidecar(folder, meta: t.meta, selected: [0, 1], trackers: [])
        // a version 1 sidecar: only the three original fields
        try Data(#"{"selected":[0,1],"trackers":[]}"#.utf8).write(to: folder.appendingPathComponent(".state.json"))
        let old = TorrentRunner.loadSidecar(folder, expectedHash: t.meta.infoHashHex)
        XCTAssertEqual(old?.selected, [0, 1])
        XCTAssertNil(TorrentRunner.seedFields(folder)?.authorized, "an old sidecar authorizes nothing")
        XCTAssertTrue(TorrentRunner.updateSeedState(folder) { $0.authorized = true; $0.uploaded = 1234; $0.downloaded = 99; $0.seconds = 42.5; $0.ratioTarget = 2; $0.timeLimit = 3600; $0.initialSeeding = true })
        XCTAssertTrue(TorrentRunner.setResumeBlob(folder, Data("{\"opaque\":1}".utf8)))
        let f = TorrentRunner.seedFields(folder)
        XCTAssertEqual(f, TorrentRunner.SeedFields(authorized: true, uploaded: 1234, downloaded: 99, seconds: 42.5, ratioTarget: 2, timeLimit: 3600, initialSeeding: true))
        XCTAssertEqual(TorrentRunner.resumeBlob(folder), Data("{\"opaque\":1}".utf8), "the fast-resume record is stored verbatim")
        XCTAssertNotNil(TorrentRunner.loadSidecar(folder, expectedHash: t.meta.infoHashHex), "a version 3 sidecar still loads")
        // rewriting it for another reason (the choice of files) keeps the seeding fields and the record
        try TorrentRunner.saveSidecar(folder, meta: t.meta, selected: [0, 1], trackers: [])
        XCTAssertEqual(TorrentRunner.seedFields(folder)?.uploaded, 1234)
        XCTAssertEqual(TorrentRunner.resumeBlob(folder), Data("{\"opaque\":1}".utf8))
    }

    func testReadingBackAFinishedTorrentKeepsOnlyWhatChecksOut() throws {
        let t = try TorrentFixture.build(files: Self.standardFiles)
        let location = root.appendingPathComponent("rehash", isDirectory: true)
        try writeFiles(t, to: location)
        let b = location.appendingPathComponent("d/b.bin")
        var data = try Data(contentsOf: b); data[40_000] ^= 0xFF; try data.write(to: b)          // b.bin offset 40 000 = stream byte 110 000 = piece 3
        let checker = TorrentStorage(meta: t.meta, workingFolder: root.appendingPathComponent("unused"), selected: [])
        var last = 0.0
        let source = SeedingSource.rehash(meta: t.meta, location: location, chosen: [0, 1], matches: { checker.matches($0, piece: $1) }, cancelled: { false }, progress: { last = $0 })
        XCTAssertEqual(source?.servablePieces, [0, 1, 2, 4], "the damaged piece is not trusted")
        XCTAssertEqual(last, 1)
        XCTAssertNil(SeedingSource.rehash(meta: t.meta, location: location, chosen: [0, 1], matches: { _, _ in true }, cancelled: { true }, progress: { _ in }), "cancelled")
    }

    // MARK: Initial (super) seeding

    private func superScript(_ onShake: @escaping (Int, SeedLeecher) -> Void = { _, p in p.inject(.interested) }) -> (Int, SeedLeecher) -> Void {
        { n, p in p.onShake = { p in onShake(n, p) } }
    }

    func testInitialSeedingOffersOnePieceAtATimeAndWaitsForRedistribution() async throws {
        let t = try TorrentFixture.build(files: Self.standardFiles)
        var c = TorrentSession.SeedingConfig(); c.initialSeeding = true
        let r = try makeSeed(t, peers: [1, 2, 3], config: c, script: superScript())
        r.session.start()
        let offered = await until { r.factory.all.count == 3 && r.factory.all.allSatisfy { $0.haves.count == 1 } }
        XCTAssertTrue(offered, "each peer is offered exactly one piece")
        for p in r.factory.all {
            XCTAssertTrue(p.messages.contains(.haveNone), "no bitfield: the peer is told we have nothing")
            XCTAssertFalse(p.messages.contains(.haveAll))
            XCTAssertFalse(p.messages.contains { if case .bitfield = $0 { true } else { false } })
            XCTAssertFalse(p.messages.contains { if case .allowedFast = $0 { true } else { false } }, "no piece is promised before it is offered")
        }
        let pieces = r.factory.all.map { $0.haves[0] }
        XCTAssertEqual(Set(pieces).count, 3, "different pieces went to different peers")
        XCTAssertEqual(r.session.snapshot.seeding?.superSeeding, true)
        let (p1, p2, p3) = (r.factory[1]!, r.factory[2]!, r.factory[3]!)
        // peer 1 reports that it has its piece: that alone is not redistribution
        p1.inject(.have(p1.haves[0]))
        try? await Task.sleep(for: .milliseconds(1500))
        XCTAssertEqual(p1.haves.count, 1, "no second piece until the first was seen on another peer")
        // peer 2 reports that it has peer 1's piece: now peer 1 gets another
        p2.inject(.have(p1.haves[0]))
        let second = await until { p1.haves.count == 2 }
        XCTAssertTrue(second)
        XCTAssertNotEqual(p1.haves[0], p1.haves[1])
        // only the offered piece is served
        p3.inject(.request(index: p1.haves[0], begin: 0, length: 16384))          // offered to peer 1, not to peer 3
        p3.inject(.request(index: p3.haves[0], begin: 0, length: 16384))
        let served = await until { p3.blocks.count == 1 }
        XCTAssertTrue(served)
        XCTAssertEqual(p3.blocks.first?.index, p3.haves[0])
        XCTAssertEqual(p3.rejects.count, 1, "a piece that was not offered to this peer is refused")
        r.session.stop()
    }

    func testInitialSeedingOffersAnotherPieceAfterATimeoutAlone() async throws {
        let t = try TorrentFixture.build(files: Self.standardFiles)
        var c = TorrentSession.SeedingConfig(); c.initialSeeding = true; c.superSeedTimeout = 0.8
        let r = try makeSeed(t, peers: [1], config: c, script: superScript())
        r.session.start()
        let ok = await until(8) { (r.factory[1]?.haves.count ?? 0) >= 2 }
        XCTAssertTrue(ok, "a piece nobody passed on is not waited for forever")
        r.session.stop()
    }

    func testInitialSeedingFallsBackWhenOthersHaveCompleteCopies() async throws {
        let t = try TorrentFixture.build(files: Self.standardFiles)
        var c = TorrentSession.SeedingConfig(); c.initialSeeding = true; c.superSeedFallbackSeeds = 0
        let r = try makeSeed(t, peers: [1, 2, 3], config: c, script: superScript { n, p in if n == 3 { p.inject(.haveAll) } else { p.inject(.interested) } })
        r.session.start()
        let ok = await until(8) { r.session.snapshot.seeding?.superSeeding == false && r.factory[1]?.haves.count == t.meta.pieceCount }
        XCTAssertTrue(ok, "everything is announced to the remaining peers")
        XCTAssertEqual(Set(r.factory[1]?.haves ?? []), Set(0..<t.meta.pieceCount))
        XCTAssertNotNil(r.session.snapshot.seeding?.superSeedFellBack)
        XCTAssertTrue(r.factory[3]?.closed ?? false, "a peer that already has everything is of no use to a seeder")
        r.session.stop()
    }

    func testInitialSeedingFallsBackWhenEveryPieceHasBeenSeenElsewhere() async throws {
        let t = try TorrentFixture.build(files: Self.standardFiles)
        var c = TorrentSession.SeedingConfig(); c.initialSeeding = true
        let first = PeerWire.makeBitfield([true, true, true, false, false]), second = PeerWire.makeBitfield([false, false, false, true, true])
        let r = try makeSeed(t, peers: [1, 2, 3], config: c, script: superScript { n, p in
            if n == 2 { p.inject(.bitfield(first)) } else if n == 3 { p.inject(.bitfield(second)) } else { p.inject(.interested) }
        })
        r.session.start()
        let ok = await until(8) { r.session.snapshot.seeding?.superSeeding == false }
        XCTAssertTrue(ok, "no piece is left that no other peer has")
        r.session.stop()
    }

    func testInitialSeedingCanBeTurnedOffWhileRunning() async throws {
        let t = try TorrentFixture.build(files: Self.standardFiles)
        var c = TorrentSession.SeedingConfig(); c.initialSeeding = true
        let r = try makeSeed(t, peers: [1], config: c, script: superScript())
        r.session.start()
        _ = await until { r.factory[1]?.haves.count == 1 }
        c.initialSeeding = false
        r.session.updateSeeding(c, maxPeers: 30, uploadSlots: 4)
        let ok = await until(5) { r.factory[1]?.haves.count == t.meta.pieceCount }
        XCTAssertTrue(ok)
        XCTAssertEqual(r.session.snapshot.seeding?.superSeeding, false)
        r.session.stop()
    }

    func testInitialSeedingNeedsTheWholeTorrent() async throws {
        let t = try TorrentFixture.build(files: Self.standardFiles)
        var c = TorrentSession.SeedingConfig(); c.initialSeeding = true
        let r = try makeSeed(t, peers: [1], verified: [0, 1, 2, 3], config: c)          // piece 4 is missing
        r.session.start()
        _ = await until { r.factory[1]?.messages.isEmpty == false }
        XCTAssertEqual(r.session.snapshot.seeding?.superSeeding, false)
        r.session.stop()
    }
}
