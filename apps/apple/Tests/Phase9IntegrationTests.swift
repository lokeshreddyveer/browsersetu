import XCTest
@testable import Browser_Setu

@MainActor
final class TorrentIntegrationTests: XCTestCase {
    private var root: URL!
    private var downloads: URL!
    private var savedOverride: URL?
    private var made: [DownloadCoordinator] = []

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("p9i-\(UUID().uuidString)")
        downloads = root.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        savedOverride = DownloadCoordinator.directoryOverride
        DownloadCoordinator.directoryOverride = downloads
    }

    override func tearDown() async throws {
        for c in made { for (id, r) in c.ledger.records where !r.state.isFinal && r.state != .failed { c.cancel(id) } }
        try? await Task.sleep(for: .milliseconds(250))
        let reset = DownloadCoordinator(); reset.torrentSettings = TorrentSettings()
        TorrentBandwidth.download.setOverallLimit(nil); TorrentBandwidth.upload.setOverallLimit(nil)
        for c in made { if let s = c.store { DownloadTaskStore.close(folder: s) } }
        try? FileManager.default.removeItem(at: root)
        DownloadCoordinator.directoryOverride = savedOverride
        try await super.tearDown()
    }

    private func coordinator(enabled: Bool = true, tracker: FakeTracker? = nil, content: TorrentFixture.Built? = nil, peers: [Int] = [1, 2], settings: TorrentSettings? = nil) -> (DownloadCoordinator, FakeTracker) {
        let c = DownloadCoordinator()
        c.profileName = "default"
        c.store = root.appendingPathComponent("store-\(made.count)")
        c.hasHost = { false }
        c.duplicatePolicy = .keepBoth
        var s = settings ?? TorrentSettings(); s.enabled = enabled
        c.torrentSettings = s
        let fake = tracker ?? FakeTracker(peers: peers.map { PeerAddress(host: "10.0.0.\($0)", port: 6881) })
        c.torrents.tracker = fake
        c.torrents.sessionSettings.allowLocalPeers = true
        if let content {
            c.torrents.transports = FakePeers { _, q in FakePeer(queue: q, stream: content.stream, meta: content.meta, infoHash: content.meta.infoHash) }
        }
        made.append(c)
        return (c, fake)
    }

    private func wait(_ c: DownloadCoordinator, _ id: UUID, for states: Set<DownloadState>, seconds: Double = 20) async -> DownloadTaskRecord? {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if let r = c.ledger.record(id), states.contains(r.state) { return r }; try? await Task.sleep(for: .milliseconds(25)) }
        return c.ledger.record(id)
    }

    private func sample(name: String = "Album") throws -> TorrentFixture.Built {
        var t = try TorrentFixture.build(name: name, files: [(["one.bin"], 50_000), (["sub", "two.bin"], 90_000), (["three.bin"], 7_001)], announce: ["http://tracker.test/announce"])
        t.meta.trackers = [URL(string: "http://tracker.test/announce")!]
        return t
    }

    func testAMultiFileTorrentFlowsThroughTheLedgerAndEndsVerified() async throws {
        let t = try sample()
        let (c, _) = coordinator(content: t)
        let id = try await c.torrents.add(t.meta, selectedFiles: [])
        let done = await wait(c, id, for: [.completed, .failed])
        XCTAssertEqual(done?.state, .completed, "failure: \(done?.failure?.reason ?? "-")")
        XCTAssertEqual(done?.protocolID, .bittorrent)
        XCTAssertEqual(done?.file.integrity, .verified)
        let folder = downloads.appendingPathComponent("Album")
        XCTAssertEqual(done?.file.destinationPath, folder.path)
        for f in t.meta.files { XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(f.relativePath)), t.stream.subdata(in: Int(f.offset)..<Int(f.offset + f.length))) }
        XCTAssertEqual((try FileManager.default.contentsOfDirectory(atPath: downloads.path)).filter { $0.hasPrefix(".") }, [], "no working folder is left behind")
        XCTAssertEqual(PeerBudget.shared.open, 0); XCTAssertEqual(TorrentSlots.shared.open, 0)
        XCTAssertEqual(done?.transfer.totalBytes, 147_001)
    }

    func testNothingTouchesTheNetworkUntilPeerToPeerIsTurnedOn() async throws {
        let t = try sample()
        let (c, tracker) = coordinator(enabled: false, content: t)
        do { _ = try await c.torrents.add(t.meta, selectedFiles: []); XCTFail("must refuse") } catch { XCTAssertEqual(error as? TorrentError, .disabled) }
        do { _ = try await c.torrents.fetchDetails(of: try MagnetLink.parse("magnet:?xt=urn:btih:\(t.meta.infoHashHex)&tr=http%3A%2F%2Ftracker.test%2Fa")); XCTFail() } catch { XCTAssertEqual(error as? TorrentError, .disabled) }
        XCTAssertEqual(tracker.calls, 0)
        XCTAssertTrue(c.ledger.records.isEmpty, "a refused torrent leaves no task behind")
        XCTAssertTrue(coordinator(enabled: false).0.torrents.transports is NWPeerTransportFactory, "the real connections are the default")
    }

    func testLookingAtATorrentOrAMagnetLinkContactsNobody() throws {
        let t = try sample()
        let (c, tracker) = coordinator(content: t)
        let look = try c.torrents.inspect(torrentFile: t.torrent)
        XCTAssertEqual(look.meta.name, "Album"); XCTAssertEqual(look.meta.files.count, 3); XCTAssertEqual(look.trackerHosts, ["tracker.test"])
        XCTAssertTrue(look.privacyNotice.contains("network address"))
        _ = try MagnetLink.parse("magnet:?xt=urn:btih:\(t.meta.infoHashHex)")
        XCTAssertEqual(tracker.calls, 0)
        XCTAssertEqual((c.torrents.transports as? FakePeers)?.all.count, 0)
        let priv = try TorrentFixture.build(files: [(["a"], 10)], isPrivate: true)
        XCTAssertTrue(c.torrents.inspection(of: priv.meta).privacyNotice.contains("private"))
    }

    func testChosenFilesOnlyAndTheFolderHoldsOnlyThose() async throws {
        let t = try sample()
        let (c, _) = coordinator(content: t)
        let id = try await c.torrents.add(t.meta, selectedFiles: [1])
        let done = await wait(c, id, for: [.completed, .failed])
        XCTAssertEqual(done?.state, .completed, "failure: \(done?.failure?.reason ?? "-")")
        let folder = downloads.appendingPathComponent("Album")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("sub/two.bin").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("one.bin").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("three.bin").path))
        XCTAssertEqual(done?.transfer.totalBytes, 90_000, "the size shown is the size of what was chosen")
    }

    func testAFolderOfTheSameNameIsNotOverwritten() async throws {
        let t = try sample()
        try FileManager.default.createDirectory(at: downloads.appendingPathComponent("Album"), withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: downloads.appendingPathComponent("Album/mine.txt"))
        let (c, _) = coordinator(content: t)
        let id = try await c.torrents.add(t.meta, selectedFiles: [])
        let done = await wait(c, id, for: [.completed, .failed])
        XCTAssertEqual(done?.state, .completed)
        XCTAssertEqual(URL(fileURLWithPath: done?.file.destinationPath ?? "").lastPathComponent, "Album (1)", "the download folder's usual numbering for a name that is taken")
        XCTAssertEqual(try Data(contentsOf: downloads.appendingPathComponent("Album/mine.txt")), Data("keep".utf8))
    }

    func testPauseKeepsVerifiedPiecesAndResumeFinishes() async throws {
        let t = try TorrentFixture.build(name: "Slow", files: [(["a.bin"], 32768 * 20)], announce: ["http://tracker.test/announce"])
        var meta = t.meta; meta.trackers = [URL(string: "http://tracker.test/announce")!]
        var s = TorrentSettings(); s.downloadLimit = 128 << 10
        let (c, _) = coordinator(content: t, settings: s)
        let id = try await c.torrents.add(meta, selectedFiles: [])
        _ = await wait(c, id, for: [.running])
        try? await Task.sleep(for: .milliseconds(1500))
        c.pause(id)
        let paused = await wait(c, id, for: [.paused, .failed, .completed], seconds: 10)
        XCTAssertEqual(paused?.state, .paused, "failure: \(paused?.failure?.reason ?? "-")")
        XCTAssertEqual(PeerBudget.shared.holding(task: id), 0, "a paused torrent holds no peer connections")
        let kept = (c.ledger.store?.loadPieces(task: id) ?? []).filter { $0.state == .done }.count
        XCTAssertGreaterThan(kept, 0, "verified pieces are kept durably")
        TorrentBandwidth.download.setOverallLimit(nil)
        c.resume(id)
        let done = await wait(c, id, for: [.completed, .failed], seconds: 20)
        XCTAssertEqual(done?.state, .completed, "failure: \(done?.failure?.reason ?? "-")")
        XCTAssertEqual(try Data(contentsOf: downloads.appendingPathComponent("Slow/a.bin")), t.stream)
    }

    func testCancelRemovesTheWorkingFolderAndGivesBackEverything() async throws {
        let t = try TorrentFixture.build(name: "Gone", files: [(["a.bin"], 32768 * 40)], announce: ["http://tracker.test/announce"])
        var meta = t.meta; meta.trackers = [URL(string: "http://tracker.test/announce")!]
        var s = TorrentSettings(); s.downloadLimit = 64 << 10
        let (c, _) = coordinator(content: t, settings: s)
        let id = try await c.torrents.add(meta, selectedFiles: [])
        _ = await wait(c, id, for: [.running])
        try? await Task.sleep(for: .milliseconds(800))
        c.cancel(id)
        _ = await wait(c, id, for: [.cancelled], seconds: 10)
        try? await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual((try FileManager.default.contentsOfDirectory(atPath: downloads.path)), [], "nothing is left in the download folder")
        XCTAssertEqual(PeerBudget.shared.holding(task: id), 0); XCTAssertEqual(TorrentSlots.shared.open, 0)
        XCTAssertEqual(c.ledger.store?.loadPieces(task: id).count ?? 0, 0)
    }

    func testTheSchedulerLimitsHowManyTorrentsRunAtOnce() async throws {
        let a = try TorrentFixture.build(name: "A", files: [(["a.bin"], 32768 * 30)]), b = try TorrentFixture.build(name: "B", files: [(["b.bin"], 40_000)])
        var ma = a.meta, mb = b.meta; ma.trackers = [URL(string: "http://tracker.test/a")!]; mb.trackers = [URL(string: "http://tracker.test/b")!]
        var s = TorrentSettings(); s.maxActiveTorrents = 1; s.downloadLimit = 256 << 10
        let (c, _) = coordinator(settings: s)
        c.torrents.transports = FakePeers { _, q in
            // one fake swarm for both: serve whichever torrent is asked for
            FakePeer(queue: q, stream: a.stream, meta: a.meta, infoHash: a.meta.infoHash)
        }
        let first = try await c.torrents.add(ma, selectedFiles: [])
        XCTAssertEqual(TorrentSlots.shared.open, 1)
        let second = Task { try await c.torrents.add(mb, selectedFiles: []) }
        try? await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(TorrentSlots.shared.open, 1, "the second waits for the first's place")
        XCTAssertNil(c.ledger.records.values.first { $0.file.filename == "B" && $0.state == .running })
        c.cancel(first)
        _ = await wait(c, first, for: [.cancelled])
        let id2 = try await second.value
        XCTAssertNotNil(c.ledger.record(id2))
        c.cancel(id2)
    }

    func testPeerAndSlotLimitsAndSpeedLimitsFollowTheSettings() {
        var s = TorrentSettings(); s.maxActiveTorrents = 99; s.maxPeersPerTorrent = 1; s.maxPeersTotal = 5000; s.downloadLimit = 10; s.uploadLimit = 4_000_000
        let (c, _) = coordinator(settings: s)
        XCTAssertEqual(c.torrentSettings.normalized().maxActiveTorrents, 10); XCTAssertEqual(c.torrentSettings.normalized().maxPeersPerTorrent, 5)
        // The limits belong to this profile's tasks (owner = the coordinator), so they cannot govern another profile's torrents.
        XCTAssertEqual(TorrentBandwidth.download.overallLimit(owner: c.ownerID), BandwidthController.minimumRate)
        XCTAssertEqual(TorrentBandwidth.upload.overallLimit(owner: c.ownerID), 4_000_000)
        XCTAssertNil(TorrentBandwidth.download.overallLimit, "another profile's torrents are not limited by this one's setting")
        XCTAssertNil(BandwidthController.shared.overallLimit, "the web-download limit is a separate thing")
        c.torrentSettings = TorrentSettings()
        XCTAssertNil(TorrentBandwidth.download.overallLimit(owner: c.ownerID))
    }

    func testSettingsAreOffByDefaultAndRestoreFromTheirSavedForm() {
        XCTAssertFalse(TorrentSettings().enabled); XCTAssertTrue(TorrentSettings().shareWhileDownloading)
        var s = TorrentSettings(); s.enabled = true; s.maxPeersPerTorrent = 12; s.uploadLimit = 50_000
        XCTAssertEqual(TorrentSettings.decode(s.encoded()), s.normalized())
        XCTAssertEqual(TorrentSettings.decode("garbage"), TorrentSettings()); XCTAssertEqual(TorrentSettings.decode(nil), TorrentSettings())
    }

    func testEachProfilesCoordinatorHasItsOwnPeerToPeerSwitch() {
        let (a, _) = coordinator(enabled: true), (b, _) = coordinator(enabled: false)
        XCTAssertTrue(a.torrents.settings.enabled); XCTAssertFalse(b.torrents.settings.enabled)
        XCTAssertFalse(a.torrents === b.torrents)
    }

    func testTurningPeerToPeerOffStopsRunningTorrentsAtOnce() async throws {
        let t = try TorrentFixture.build(name: "Live", files: [(["a.bin"], 32768 * 40)], announce: ["http://tracker.test/announce"])
        var meta = t.meta; meta.trackers = [URL(string: "http://tracker.test/announce")!]
        var s = TorrentSettings(); s.downloadLimit = 64 << 10
        let (c, tracker) = coordinator(content: t, settings: s)
        let id = try await c.torrents.add(meta, selectedFiles: [])
        _ = await wait(c, id, for: [.running])
        try? await Task.sleep(for: .milliseconds(800))
        var off = c.torrentSettings; off.enabled = false
        c.torrentSettings = off
        let paused = await wait(c, id, for: [.paused, .failed], seconds: 10)
        XCTAssertTrue([.paused, .failed].contains(paused?.state), "state: \(String(describing: paused?.state))")
        XCTAssertEqual(PeerBudget.shared.holding(task: id), 0, "no connection is left open")
        let calls = tracker.calls
        try? await Task.sleep(for: .milliseconds(1500))
        XCTAssertEqual(tracker.calls, calls, "nothing is announced after the switch is turned off")
    }

    func testTheEngineReportsWhatItCanAndCannotDo() {
        let caps = DownloadEngineRegistry().capabilities(of: .bittorrent)
        for c: DownloadEngineCapabilities in [.pause, .resume, .multiFile, .upload, .enforcesSpeedLimit, .pieces] { XCTAssertTrue(caps.contains(c)) }
        XCTAssertFalse(caps.contains(.resolveMetadata), "a torrent is inspected before it starts, not resolved by the engine")
        XCTAssertFalse(DownloadEngineRegistry().capabilities(of: .http).contains(.multiFile))
        XCTAssertFalse(DownloadEngineRegistry().capabilities(of: .http).contains(.upload))
        XCTAssertTrue(BitTorrentTransferEngine.enforcement.isEnforced)
    }

    func testPeersAreOnlyEverDialledNeverListenedFor() {
        // the engine opens no listener: there is no server API in the peer transport at all
        let source = (try? String(contentsOfFile: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Shared/Downloads/Torrent/TorrentNetwork.swift").path, encoding: .utf8)) ?? ""
        XCTAssertFalse(source.isEmpty)
        XCTAssertFalse(source.contains("NWListener"), "no listening socket")
        XCTAssertFalse(source.contains("UPnP") || source.contains("NATPMP") || source.contains("portMapping"), "no automatic port mapping")
    }
}
