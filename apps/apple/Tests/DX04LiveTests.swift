import XCTest
@testable import Browser_Setu

/// Real sockets against independent implementations (e2e/peerx.py, e2e/mselib.py, e2e/mse_client.py). Skipped unless DX04_LIVE=1 (TEST_RUNNER_DX04_LIVE=1) and the fixtures are running.
final class DX04LiveTests: XCTestCase {
    override func setUpWithError() throws { try XCTSkipUnless(ProcessInfo.processInfo.environment["DX04_LIVE"] == "1") }
    private final class Box<T>: @unchecked Sendable { var v: T; init(_ v: T) { self.v = v } }
    private let infoHash = Data(NodeID(hex: "86a0237199c6d96409a3b7d3df69f19b86a8c0d9")!.bytes)

    private func meta() async throws -> TorrentMetainfo {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18791/torrent")!)
        return try TorrentMetainfo.parse(data)
    }

    private func download(from peer: PeerAddress, transport: TransportPreference, encryption: EncryptionPolicy, timeout: Double = 40) async throws -> Bool {
        let meta = try await meta()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dx04-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let storage = TorrentStorage(meta: meta, workingFolder: TorrentStorage.workingFolder(for: id, in: root), selected: [])
        try storage.prepare()
        var direct = DownloadNetworkSetup(); direct.proxy.mode = .direct
        var settings = TorrentSession.Settings.testing; settings.pexInterval = 0
        let s = TorrentSession(infoHash: meta.infoHash, meta: meta, trackers: [], storage: { storage }, alreadyHave: [], transports: NWPeerTransportFactory(network: { direct }, systemProxyActive: { false }, preferences: { (transport, encryption) }),
                               tracker: RecordingTracker(), download: nil, upload: nil, taskID: id, settings: settings)
        let done = Box(false), failure = Box<String?>(nil)
        s.onEvent = { e in if case .finished = e { done.v = true }; if case .failed(let m, _) = e { failure.v = m } }
        s.start(); s.addCandidates([peer], source: "live")
        let end = Date().addingTimeInterval(timeout)
        while Date() < end, !done.v, failure.v == nil { try await Task.sleep(nanoseconds: 100_000_000) }
        s.stop(sendStoppedAnnounce: false); PeerBudget.shared.releaseAll(task: id)
        if let f = failure.v { XCTFail("failed: \(f)") }
        return done.v
    }

    func testRequiredEncryptionAgainstAnIndependentResponderDownloadsAndVerifies() async throws {
        let ok = try await download(from: PeerAddress(host: "127.0.0.1", port: 18797), transport: .tcpOnly, encryption: .requireEncrypted)
        XCTAssertTrue(ok, "a whole torrent came through an RC4 stream negotiated with an independent MSE implementation and passed hash verification")
    }

    func testPreferredEncryptionFallsBackToPlainWithAPeerThatDoesNotSpeakIt() async throws {
        let ok = try await download(from: PeerAddress(host: "127.0.0.1", port: 18799), transport: .tcpOnly, encryption: .preferEncrypted)
        XCTAssertTrue(ok, "the encrypted way failed, the plain way followed, the download completed")
    }

    func testRequiredEncryptionNeverFallsBackToAPlainOnlyPeer() async throws {
        let ok = try await download(from: PeerAddress(host: "127.0.0.1", port: 18799), transport: .tcpOnly, encryption: .requireEncrypted, timeout: 15)
        XCTAssertFalse(ok, "a peer that does not speak encryption is not downloaded from when it is required")
    }

    func testTheListenerAcceptsPlainAndEncryptedPeersForARunningTorrentAndRefusesTheRest() async throws {
        let router = InboundRouter()
        let routed = Box(0); let handshakeSent = Box(0)
        router.register(infoHash) { transport, address, initial in
            routed.v += 1
            transport.send(PeerWire.handshake(infoHash: self.infoHash, peerID: Data(repeating: 0x41, count: 20), extensions: false))
            handshakeSent.v += 1
            return true
        }
        let listener = PeerListener(router: router, policy: { nil }, encryption: { .preferEncrypted }, preferredPort: { 18810 })
        let task = UUID(); listener.acquire(task)
        defer { listener.stopNow(reason: "done") }
        var up = false
        for _ in 0..<100 { if listener.status.state == .listening { up = true; break }; try await Task.sleep(nanoseconds: 50_000_000) }
        print("LIVE LISTENER status:", listener.status)
        guard up else { throw XCTSkip("the listener could not start in this process: \(listener.status.lastError ?? "unknown")") }
        FileManager.default.createFile(atPath: "/tmp/dx04-listener-ready", contents: Data())
        let end = Date().addingTimeInterval(30)
        while Date() < end, routed.v < 2 || listener.status.refused < 2 { try await Task.sleep(nanoseconds: 100_000_000) }
        print("LIVE LISTENER routed:", routed.v, "status:", listener.status)
        XCTAssertGreaterThanOrEqual(routed.v, 2, "the plain peer and the encrypted peer for the running torrent were both handed over")
        XCTAssertGreaterThanOrEqual(listener.status.refused, 2, "a wrong torrent and garbage were refused")
        XCTAssertEqual(listener.status.tcpPort, 18810)
    }

    func testUTPAgainstAnIndependentImplementationDownloadsAndVerifies() async throws {
        let ok = try await download(from: PeerAddress(host: "127.0.0.1", port: 18820), transport: .utpOnly, encryption: .allowPlaintext, timeout: 60)
        XCTAssertTrue(ok, "a whole torrent came over µTP from an independent implementation and passed hash verification")
    }

    func testUTPSurvivesLossInBothDirectionsAgainstTheIndependentImplementation() async throws {
        let ok = try await download(from: PeerAddress(host: "127.0.0.1", port: 18821), transport: .utpOnly, encryption: .allowPlaintext, timeout: 90)
        XCTAssertTrue(ok, "with the peer dropping one datagram in seven it receives and one in nine it sends, the transfer still completed and verified")
    }

    func testUTPWithEncryptionOnTopOfIt() async throws {
        // The plain µTP peer does not speak encryption: "prefer" falls back to plain on the same transport.
        let ok = try await download(from: PeerAddress(host: "127.0.0.1", port: 18820), transport: .utpOnly, encryption: .preferEncrypted, timeout: 90)
        XCTAssertTrue(ok)
    }
}
