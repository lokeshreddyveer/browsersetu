import XCTest
@testable import Browser_Setu

/// DX-06 against independent tools written from the specifications (e2e/dx06: mktorrent2.py, verify_torrent.py, webseed2.py, leech.py). Skipped unless DX06_LIVE=1 (TEST_RUNNER_DX06_LIVE=1) and the
/// helper script has copied the sample torrents and content into the test container and started the servers. The web seed and the leechers are on loopback, which the app refuses to contact
/// from a torrent unless approved, so the fetcher is given the approval a person would give; everything else is the app's real code path (real transports, real sockets).
final class DX06LiveTests: XCTestCase {
    override func setUpWithError() throws { try XCTSkipUnless(ProcessInfo.processInfo.environment["DX06_LIVE"] == "1") }
    private var base: URL { FileManager.default.temporaryDirectory.appendingPathComponent("dx06-live", isDirectory: true) }
    private let id = UUID()
    private final class Box<T>: @unchecked Sendable { var v: T; init(_ v: T) { self.v = v } }

    override func tearDown() { PeerBudget.shared.releaseAll(task: id); super.tearDown() }

    private func torrentData(_ name: String) throws -> Data { try Data(contentsOf: base.appendingPathComponent(name)) }

    // MARK: Our parser against torrents made by the independent creator

    /// (file, version, v1 hex, v2 hex), as printed by the independent creator.
    private let expected: [(String, TorrentMetainfo.Version, String?, String?)] = [
        ("dx06pack-v1-32768.torrent", .v1, "f6390a95d7862ebd660ca71e66290e3f35531be2", nil),
        ("dx06pack-v1-16384.torrent", .v1, "f4aaa4c25109fab5b32aa0a42027a0a29e658296", nil),
        ("dx06pack-v2-32768.torrent", .v2, nil, "f5a6e681eb1f2052829a1e9f608d4728839db785b5a884a52c345dab52c06ef4"),
        ("dx06pack-v2-16384.torrent", .v2, nil, "4aae6f312e418610d6af580607f659be9c5a46f48875f1e3a4131af9e5faf9c9"),
        ("dx06pack-hybrid-32768.torrent", .hybrid, "9d327b078f9be9e57a62106fcc13c14fa5a7e5fb", "97087d3e69cad00c812c398e9b1025682a778aae548ba597d40eddfc38e0f451"),
        ("dx06pack-hybrid-16384.torrent", .hybrid, "cc5700a1674aaa7155d17582ae4709ee67274180", "e1f3bc77c65f86ae97afd5387a53e9d5d2851db1bef6b183af99df51e7e8fc8e"),
    ]

    func testTheIndependentTorrentsParseWithTheSameHashesAndTheSameFiles() throws {
        for (file, version, v1, v2) in expected {
            let meta = try TorrentMetainfo.parse(try torrentData(file))
            XCTAssertEqual(meta.version, version, file)
            if let v1 { XCTAssertEqual(meta.infoHashHex, v1, "\(file) v1 hash") }
            if let v2 { XCTAssertEqual(meta.infoHashV2Hex, v2, "\(file) v2 hash"); XCTAssertEqual(meta.infoHashV2.map(Merkle.truncated), Optional(Data(hexString: String(v2.prefix(40)))), "\(file) truncated") }
            if version == .v2 { XCTAssertEqual(meta.infoHash, Data(hexString: String(v2!.prefix(40))), "a v2-only torrent is known on the wire by the truncated SHA-256") }
            XCTAssertEqual(Set(meta.visibleFiles.map(\.relativePath)), ["blk.bin", "blk1.bin", "empty.bin", "nested/a/forty.bin", "nested/b/big.bin", "nested/hundred.bin", "one.bin"], file)
            XCTAssertEqual(meta.contentLength, 372_771, "\(file): padding is not content")
            XCTAssertTrue(meta.visibleFiles.map(\.relativePath).contains("nested/b/big.bin"), file)
            XCTAssertEqual(meta.missingLayerRoots.count, 0, "\(file): the layers came with the torrent file")
        }
    }

    // MARK: Downloading from an independent web seed

    private func download(_ file: String, timeout: Double = 40) async throws -> (placed: URL?, meta: TorrentMetainfo) {
        let meta = try TorrentMetainfo.parse(try torrentData(file))
        var setup = DownloadNetworkSetup(); setup.proxy.mode = .direct
        let work = base.appendingPathComponent("work-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let storage = TorrentStorage(meta: meta, workingFolder: TorrentStorage.workingFolder(for: id, in: work), selected: [])
        try storage.prepare()
        let client = HTTPTrackerClient(network: { setup }, authorized: { _ in true }, systemProxyActive: { false })
        let session = TorrentSession(infoHash: meta.infoHash, meta: meta, trackers: [], storage: { storage }, alreadyHave: [], transports: NWPeerTransportFactory(network: { setup }, systemProxyActive: { false }),
                                     tracker: RecordingTracker(), download: nil, upload: nil, taskID: id, settings: .testing)
        let done = Box(false), failure = Box<String?>(nil)
        session.onEvent = { e in if case .finished = e { done.v = true }; if case .failed(let m, _) = e { failure.v = m } }
        session.webSeedFetcher = HTTPWebSeedFetcher(client: client)
        session.start()
        let end = Date().addingTimeInterval(timeout)
        while Date() < end, !done.v, failure.v == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        session.stop()
        if let f = failure.v { XCTFail("\(file) failed: \(f)") }
        guard done.v else { XCTFail("\(file) did not finish"); return (nil, meta) }
        return (try storage.finish(into: work.appendingPathComponent("out")), meta)
    }

    private func assertSameAsContent(_ placed: URL, _ meta: TorrentMetainfo, _ label: String) throws {
        for f in meta.visibleFiles {
            let got = meta.isMultiFile ? placed.appendingPathComponent(f.relativePath) : placed
            let want = base.appendingPathComponent("dx06pack").appendingPathComponent(f.relativePath)
            XCTAssertEqual(try Data(contentsOf: got), try Data(contentsOf: want), "\(label): \(f.relativePath)")
        }
        let names = (try? FileManager.default.subpathsOfDirectory(atPath: placed.path)) ?? []
        XCTAssertFalse(names.contains { $0.contains(".pad") }, "\(label): no padding file is published")
    }

    func testV1V2AndHybridDownloadFromAnIndependentWebSeedWithEveryPieceChecked() async throws {
        for file in ["dx06pack-v1-32768.torrent", "dx06pack-v2-32768.torrent", "dx06pack-hybrid-32768.torrent", "dx06pack-v2-16384.torrent", "dx06pack-hybrid-16384.torrent"] {
            let r = try await download(file)
            guard let placed = r.placed else { continue }
            try assertSameAsContent(placed, r.meta, file)
            print("LIVE DOWNLOAD ok:", file)
        }
    }

    // MARK: Seeding to independent leechers

    /// Dials a leecher the helper script started listening on `port`, seeds the finished sample content to it, and returns once it has had what it asked for (or the time ran out).
    private func seed(_ file: String, port: Int, wantBytes: Int64, seconds: Double) async throws -> Int64 {
        let meta = try TorrentMetainfo.parse(try torrentData(file))
        var setup = DownloadNetworkSetup(); setup.proxy.mode = .direct
        let location = base.appendingPathComponent("dx06pack", isDirectory: true)
        let source = SeedingSource(meta: meta, location: location, chosen: Set(meta.files.map(\.index)), verifiedPieces: Set(0..<meta.pieceCount))
        let session = TorrentSession(infoHash: meta.infoHash, meta: meta, trackers: [], storage: { nil }, alreadyHave: [], transports: NWPeerTransportFactory(network: { setup }, systemProxyActive: { false }),
                                     tracker: RecordingTracker(), download: nil, upload: nil, taskID: id, settings: .testing)
        session.seedSource = source
        session.start()
        session.addCandidates([PeerAddress(host: "127.0.0.1", port: UInt16(port))], source: "live")
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, session.snapshot.uploaded < wantBytes { try await Task.sleep(nanoseconds: 50_000_000) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let sent = session.snapshot.uploaded
        session.stop()
        try await Task.sleep(nanoseconds: 300_000_000)
        PeerBudget.shared.releaseAll(task: id)
        return sent
    }

    func testSeedingToIndependentLeechersServesOnlyVerifiedPiecesAndRefusesBadRequests() async throws {
        let v1 = try await seed("dx06pack-v1-32768.torrent", port: 47301, wantBytes: 372_771, seconds: 30)
        print("LIVE SEED v1 uploaded:", v1)
        XCTAssertEqual(v1, 372_771, "the whole v1 torrent was uploaded to the independent leecher")
        let v2 = try await seed("dx06pack-v2-32768.torrent", port: 47302, wantBytes: 372_771, seconds: 30)
        print("LIVE SEED v2 uploaded:", v2)
        XCTAssertEqual(v2, 372_771, "the v2 torrent (known on the wire by the truncated SHA-256) was uploaded")
        let h = try await seed("dx06pack-hybrid-32768.torrent", port: 47303, wantBytes: 491_521, seconds: 30)
        print("LIVE SEED hybrid uploaded:", h)
        XCTAssertEqual(h, 491_521, "the hybrid torrent was uploaded, padding as zeros")
        // One bad kind of request per connection (the seeder is entitled to close on the first). What the leecher saw is in its own report.
        for (i, kind) in ["index", "oversize", "zero", "begin", "overrun", "unoffered"].enumerated() {
            let sent = try await seed("dx06pack-v1-32768.torrent", port: 47311 + i, wantBytes: .max, seconds: 8)
            print("LIVE SEED bad-request", kind, "uploaded:", sent)
        }
    }
}

private extension Data {
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var out = Data(), i = hexString.startIndex
        while i < hexString.endIndex { let n = hexString.index(i, offsetBy: 2); guard let b = UInt8(hexString[i..<n], radix: 16) else { return nil }; out.append(b); i = n }
        self = out
    }
}
