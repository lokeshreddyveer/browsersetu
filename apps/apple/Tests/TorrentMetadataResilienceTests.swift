import XCTest
@testable import Browser_Setu

/// The magnet-details search, as a person's link meets it: peers that never answer, peers that refuse, and trackers that lead nowhere. Real wire protocol against in-memory peers (FakePeer).
final class TorrentMetadataResilienceTests: XCTestCase {
    final class Box: @unchecked Sendable {
        private let lock = NSLock(); private var m: TorrentMetainfo?; private var f: String?
        func set(_ e: TorrentSession.Event) { lock.lock(); defer { lock.unlock() }; if case .metadata(let x) = e { m = x }; if case .failed(let why, _) = e { f = why } }
        var meta: TorrentMetainfo? { lock.lock(); defer { lock.unlock() }; return m }
        var failure: String? { lock.lock(); defer { lock.unlock() }; return f }
    }
    private let taskID = UUID()
    private func addr(_ n: Int) -> PeerAddress { PeerAddress(host: "10.0.0.\(n)", port: 6881) }
    private func until(_ seconds: Double = 8, _ cond: @escaping () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 20_000_000) }
        return cond()
    }
    private func run(_ t: TorrentFixture.Built, trackers: [URL] = [URL(string: "http://tracker.test/announce")!], peers: [PeerAddress], behaviours: [String: FakePeer.Behaviour], dht: DHTDiscovering? = nil,
                     tweak: (inout TorrentSession.Settings) -> Void = { _ in }) -> (TorrentSession, Box) {
        let factory = FakePeers { a, q in FakePeer(queue: q, stream: t.stream, meta: nil, infoHash: t.meta.infoHash, behaviour: behaviours[a.host] ?? FakePeer.Behaviour()) }
        var settings = TorrentSession.Settings.testing; tweak(&settings)
        let box = Box()
        let session = TorrentSession(infoHash: t.meta.infoHash, meta: nil, trackers: trackers, storage: { nil }, alreadyHave: [], transports: factory, tracker: FakeTracker(peers: peers), download: nil, upload: nil, taskID: taskID, settings: settings)
        session.dht = dht
        session.onEvent = { box.set($0) }
        return (session, box)
    }
    private func fixture() throws -> TorrentFixture.Built { try TorrentFixture.build(files: [(["a.bin"], 60_000)], infoExtra: ["x": .bytes(Data(repeating: 1, count: 40_000))]) }      // about three 16 KiB pieces of details

    func testAPeerThatNeverAnswersDoesNotStallTheDetails() async throws {
        let t = try fixture()
        var silent = FakePeer.Behaviour(); silent.serveMetadata = t.info; silent.silentOnMetadata = true
        var good = FakePeer.Behaviour(); good.serveMetadata = t.info
        let (s, box) = run(t, peers: [addr(1), addr(2)], behaviours: ["10.0.0.1": silent, "10.0.0.2": good]) { $0.metadataRequestTimeout = 0.6 }
        s.start()
        let ok = await until { box.meta != nil }
        XCTAssertTrue(ok, "the pieces the silent peer was asked for go to the other peer after the timeout; failure: \(box.failure ?? "-")")
        XCTAssertEqual(box.meta?.infoHash, t.meta.infoHash)
        s.stop()
    }

    func testAPeerThatRefusesIsNotAskedAgainAndTheOtherPeerIs() async throws {
        let t = try fixture()
        var refuser = FakePeer.Behaviour(); refuser.serveMetadata = t.info; refuser.rejectMetadata = true
        var good = FakePeer.Behaviour(); good.serveMetadata = t.info
        let (s, box) = run(t, peers: [addr(1), addr(2)], behaviours: ["10.0.0.1": refuser, "10.0.0.2": good])
        s.start()
        let ok = await until { box.meta != nil }
        XCTAssertTrue(ok, "a reject moves the piece to another peer at once; failure: \(box.failure ?? "-")")
        s.stop()
    }

    func testATrackerThatLeadsNowhereLetsTheDHTFindThePeerAfterAShortWait() async throws {
        let t = try fixture()
        var good = FakePeer.Behaviour(); good.serveMetadata = t.info
        let dht = FakeDHT(); dht.peers = [addr(7)]
        let (s, box) = run(t, peers: [], behaviours: ["10.0.0.7": good], dht: dht) { $0.dhtFallbackDelay = 0.5 }
        s.start()
        let ok = await until { box.meta != nil }
        XCTAssertTrue(ok, "a magnet that names a (dead) tracker is looked up on the DHT after the delay; failure: \(box.failure ?? "-")")
        XCTAssertGreaterThanOrEqual(dht.lookups, 1)
        s.stop()
    }

    func testTheDHTIsNotAskedAboutATorrentWhoseTrackerLooksPrivate() async throws {
        let t = try fixture()
        var good = FakePeer.Behaviour(); good.serveMetadata = t.info
        let dht = FakeDHT(); dht.peers = [addr(7)]
        let tracker = URL(string: "http://tracker.test/announce?passkey=0123456789abcdef")!
        let (s, box) = run(t, trackers: [tracker], peers: [], behaviours: ["10.0.0.7": good], dht: dht) { $0.dhtFallbackDelay = 0.3 }
        s.start()
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertEqual(dht.acquiredCount, 0); XCTAssertEqual(dht.lookups, 0)
        XCTAssertNil(box.meta)
        s.stop()
        XCTAssertTrue(TorrentSession.looksLikePrivateTracker(URL(string: "https://t.example/0123456789abcdef0123456789abcdef/announce")!))
        XCTAssertFalse(TorrentSession.looksLikePrivateTracker(URL(string: "udp://tracker.opentrackr.org:1337/announce")!))
        XCTAssertFalse(TorrentSession.looksLikePrivateTracker(URL(string: "https://torrent.ubuntu.com/announce")!))
    }

    @MainActor
    func testTheProbeStatusIsReadableAndTheFailureMessageSaysWhatWasFound() {
        var st = MetadataProbeStatus(dhtOn: true)
        st.trackersTotal = 3; st.trackersAnswered = 1; st.peersConnected = 4; st.peersConnecting = 2; st.dhtNodes = 38; st.dhtPeers = 5; st.elapsed = 61
        XCTAssertEqual(st.summary, "1 of 3 trackers answered · 4 peers connected, 2 connecting · DHT: 38 nodes, 5 peers found")
        let msg = TorrentRunner.noDetailsMessage(st)
        XCTAssertTrue(msg.contains("In 61 seconds") && msg.contains("1 of 3 trackers answered") && msg.contains("no active peers"), msg)
        var none = MetadataProbeStatus(dhtOn: false); none.trackersTotal = 2
        let m2 = TorrentRunner.noDetailsMessage(none)
        XCTAssertTrue(m2.contains("None of the link's trackers answered") && m2.contains("turn it on"), m2)
    }
}
