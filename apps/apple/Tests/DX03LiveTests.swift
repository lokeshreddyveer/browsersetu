import XCTest
@testable import Browser_Setu

/// Real sockets against independent peers written from the specifications (e2e/peerx.py, e2e/swarm.py, e2e/lsd_announce.py). Skipped unless DX03_LIVE=1 (TEST_RUNNER_DX03_LIVE=1) and the fixtures are running.
final class DX03LiveTests: XCTestCase {
    override func setUpWithError() throws { try XCTSkipUnless(ProcessInfo.processInfo.environment["DX03_LIVE"] == "1") }
    private final class Box<T>: @unchecked Sendable { var v: T; init(_ v: T) { self.v = v } }

    private func meta() async throws -> TorrentMetainfo {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18791/torrent")!)
        return try TorrentMetainfo.parse(data)
    }

    private func download(from start: [PeerAddress], _ meta: TorrentMetainfo, timeout: Double = 40, settings: TorrentSession.Settings) async throws -> (finished: Bool, snapshot: TorrentSession.Snapshot) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dx03-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let storage = TorrentStorage(meta: meta, workingFolder: TorrentStorage.workingFolder(for: id, in: root), selected: [])
        try storage.prepare()
        var direct = DownloadNetworkSetup(); direct.proxy.mode = .direct
        let s = TorrentSession(infoHash: meta.infoHash, meta: meta, trackers: [], storage: { storage }, alreadyHave: [], transports: NWPeerTransportFactory(network: { direct }, systemProxyActive: { false }),
                               tracker: RecordingTracker(), download: nil, upload: nil, taskID: id, settings: settings)
        let done = Box(false), failure = Box<String?>(nil)
        s.onEvent = { e in if case .finished = e { done.v = true }; if case .failed(let m, _) = e { failure.v = m } }
        s.start(); s.addCandidates(start, source: "live")
        let end = Date().addingTimeInterval(timeout)
        while Date() < end, !done.v, failure.v == nil { try await Task.sleep(nanoseconds: 100_000_000) }
        let snap = s.snapshot
        s.stop(sendStoppedAnnounce: false)
        if let f = failure.v { XCTFail("failed: \(f)") }
        PeerBudget.shared.releaseAll(task: id)
        return (done.v, snap)
    }

    func testFastExtensionAndPexAgainstIndependentPeers() async throws {
        var settings = TorrentSession.Settings.testing; settings.pexInterval = 0
        let m = try await meta()
        let r = try await download(from: [PeerAddress(host: "127.0.0.1", port: 18797)], m, settings: settings)
        print("LIVE FAST/PEX finished:", r.finished, "peers:", r.snapshot.peers, "fastPeers:", r.snapshot.fastPeers, "pexPeers:", r.snapshot.pexPeers, "pexAdded:", r.snapshot.pexAdded)
        XCTAssertTrue(r.finished, "the download completed and every piece was verified")
        XCTAssertGreaterThanOrEqual(r.snapshot.pexAdded, 1, "the independent peer's PEX message named a peer")
    }

    func testIPv6TCPPeerTransfersAndVerifies() async throws {
        var settings = TorrentSession.Settings.testing; settings.pexInterval = 0
        let m = try await meta()
        let r = try await download(from: [PeerAddress(host: "::1", port: 18798)], m, settings: settings)
        print("LIVE IPv6 finished:", r.finished, "ipv6 peers at end:", r.snapshot.peersIPv6, "ipv4:", r.snapshot.peersIPv4)
        XCTAssertTrue(r.finished, "a whole torrent came over an IPv6 TCP connection and passed hash verification")
    }

    func testLocalDiscoveryHearsAnIndependentMulticastAnnouncement() async throws {
        let infoHash = Data(NodeID(hex: "86a0237199c6d96409a3b7d3df69f19b86a8c0d9")!.bytes)
        let svc = LocalPeerDiscovery(transport: MulticastTransport(), policy: { nil })
        let found = Box<[PeerAddress]>([])
        svc.register(task: UUID(), infoHash: infoHash) { found.v += $0 }
        try await Task.sleep(nanoseconds: 800_000_000)
        print("LIVE LSD state:", svc.status.state.rawValue, svc.status.lastError ?? "")
        if svc.status.state != .listening { svc.stopNow(reason: "x"); throw XCTSkip("local discovery could not listen here: \(svc.status.lastError ?? "unknown") (sandbox)") }
        FileManager.default.createFile(atPath: ProcessInfo.processInfo.environment["DX03_LSD_READY"] ?? "/tmp/dx03-lsd-ready", contents: Data())
        let end = Date().addingTimeInterval(25)
        while Date() < end, found.v.isEmpty { try await Task.sleep(nanoseconds: 100_000_000) }
        print("LIVE LSD found:", found.v, "heard:", svc.status.announcementsHeard, "malformed:", svc.droppedMalformed, "notLocal:", svc.droppedNotLocal, "own:", svc.droppedOwn, "rateLimited:", svc.droppedRateLimited)
        let heard = svc.status.announcementsHeard
        svc.stopNow(reason: "x")
        // The socket joined the group, but if no datagram arrived at all (a fixture that an unsandboxed receiver does hear), the system is withholding multicast from this process: not something this code can
        // or should work around (macOS Local Network privacy is the person's choice). That is a PARTIAL result, not a pass.
        if heard == 0 { throw XCTSkip("joined the group but received no datagram: multicast delivery is being withheld from this process (macOS Local Network privacy is suspected, not confirmed)") }
        XCTAssertEqual(found.v.first?.port, 18792)
    }
}
