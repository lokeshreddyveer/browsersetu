import XCTest
@testable import Browser_Setu

/// Real sockets against independent implementations written from the specifications (e2e/webseed.py for BEP 19 and BEP 17, e2e/swarm.py and e2e/peerx.py for peers). Skipped unless DX05_LIVE=1
/// (TEST_RUNNER_DX05_LIVE=1) and the fixtures are running. The web seed is on the loopback address, which the app refuses to contact from a torrent file unless approved, so these tests give
/// the fetcher the approval a person would give (`authorized: { _ in true }`); everything else is the app's real HTTP path.
final class DX05LiveTests: XCTestCase {
    override func setUpWithError() throws { try XCTSkipUnless(ProcessInfo.processInfo.environment["DX05_LIVE"] == "1") }
    private let seedPort = 18820
    private var root: URL!
    private let id = UUID()

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dx05live-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() { PeerBudget.shared.releaseAll(task: id); try? FileManager.default.removeItem(at: root); super.tearDown() }

    private func fetch(_ path: String) async throws -> Data { try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(seedPort)\(path)")!).0 }

    private func expected(_ meta: TorrentMetainfo, _ file: Int) -> Data {
        let stream = Data((0..<Int(meta.totalLength)).map { UInt8(truncatingIfNeeded: ($0 * 7 + ($0 >> 8)) % 256) })
        let f = meta.files[file]
        return stream.subdata(in: Int(f.offset)..<Int(f.offset + f.length))
    }

    private func run(_ meta: TorrentMetainfo, selection: TorrentSelection, timeout: Double = 30) async throws -> (placed: URL?, session: TorrentSession) {
        var setup = DownloadNetworkSetup(); setup.proxy.mode = .direct
        let storage = TorrentStorage(meta: meta, workingFolder: TorrentStorage.workingFolder(for: id, in: root), selected: selection.selected(in: meta))
        try storage.prepare()
        let client = HTTPTrackerClient(network: { setup }, authorized: { _ in true }, systemProxyActive: { false })
        let session = TorrentSession(infoHash: meta.infoHash, meta: meta, trackers: [], storage: { storage }, alreadyHave: [], transports: NWPeerTransportFactory(network: { setup }, systemProxyActive: { false }),
                                     tracker: RecordingTracker(), download: nil, upload: nil, taskID: id, settings: .testing)
        let done = Box(false), failure = Box<String?>(nil)
        session.onEvent = { e in if case .finished = e { done.v = true }; if case .failed(let m, _) = e { failure.v = m } }
        session.initialSelection = selection
        session.webSeedFetcher = HTTPWebSeedFetcher(client: client)
        session.start()
        let end = Date().addingTimeInterval(timeout)
        while Date() < end, !done.v, failure.v == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        session.stop()
        if let f = failure.v { XCTFail("failed: \(f)") }
        guard done.v else { return (nil, session) }
        return (try storage.finish(into: root.appendingPathComponent("out")), session)
    }
    private final class Box<T>: @unchecked Sendable { var v: T; init(_ v: T) { self.v = v } }

    private func log() async throws -> [[String: Any]] {
        String(decoding: try await fetch("/_log"), as: UTF8.self).split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    func testBEP19OnlyTheChosenFileIsDownloadedFromAnIndependentWebSeed() async throws {
        _ = try await fetch("/_reset")
        var meta = try TorrentMetainfo.parse(try await fetch("/torrent"))
        meta.httpSeeds = []
        XCTAssertEqual(meta.webSeeds.count, 1)
        var sel = TorrentSelection.only([1], in: meta); sel.priorities[1] = .high          // a/two.bin
        let result = try await run(meta, selection: sel)
        let placed = try XCTUnwrap(result.placed, "the torrent finished")
        XCTAssertEqual(try Data(contentsOf: placed.appendingPathComponent("a/two.bin")), expected(meta, 1), "the chosen file is exact")
        XCTAssertFalse(FileManager.default.fileExists(atPath: placed.appendingPathComponent("a/one.bin").path)); XCTAssertFalse(FileManager.default.fileExists(atPath: placed.appendingPathComponent("three.bin").path))
        // two.bin is bytes 70000..120000 of the stream: pieces 2 and 3. Piece 2 starts with the end of one.bin (65536..69999), piece 3 ends with the start of three.bin (120001..131071).
        let entries = try await log()
        let ranges = entries.filter { $0["kind"] as? String == "range" }.map { "\($0["file"]!) \($0["a"]!)-\($0["b"]!)" }
        print("LIVE BEP19 ranges:", ranges)
        XCTAssertTrue(ranges.contains("a/one.bin 65536-69999"), "the end of one.bin, which piece 2 holds, was fetched to check the piece")
        XCTAssertTrue(ranges.contains("three.bin 0-11070"), "the start of three.bin, which piece 3 holds")
        XCTAssertFalse(ranges.contains { $0.hasPrefix("a/one.bin 0-") }, "pieces that hold only one.bin were not fetched")
        XCTAssertEqual(entries.filter { $0["kind"] as? String == "whole" }.count, 0, "no whole files")
        XCTAssertEqual(result.session.snapshot.webSeeds.first?.kind, "web seed")
    }

    func testBEP17AnIndependentHTTPSeedServesPiecesAndPrioritiesDecideTheOrder() async throws {
        _ = try await fetch("/_reset")
        var meta = try TorrentMetainfo.parse(try await fetch("/torrent"))
        meta.webSeeds = []
        XCTAssertEqual(meta.httpSeeds.count, 1)
        var sel = TorrentSelection.all(meta); sel.priorities[2] = .maximum          // three.bin first
        let result = try await run(meta, selection: sel)
        let placed = try XCTUnwrap(result.placed)
        for (i, f) in meta.files.enumerated() { XCTAssertEqual(try Data(contentsOf: placed.appendingPathComponent(f.relativePath)), expected(meta, i), f.relativePath) }
        let pieces = try await log().filter { $0["kind"] as? String == "hoffman" }.map { $0["piece"] as! Int }
        print("LIVE BEP17 piece order:", pieces)
        XCTAssertEqual(Set(pieces), Set(0..<meta.pieceCount))
        XCTAssertEqual(Array(pieces.prefix(2)), [3, 4], "the Maximum file's pieces first")
        XCTAssertEqual(result.session.snapshot.webSeeds.first?.kind, "HTTP seed")
    }

    /// Two independent peers (e2e/swarm.py's seeder on 18792 and e2e/peerx.py on 18795) serve one torrent. The picker's last stretch must be seen, every piece must be verified exactly once, and the files must be exact.
    func testEndgameWithIndependentPeersFinishesWithEveryPieceVerifiedOnce() async throws {
        let torrentURL = URL(string: "http://127.0.0.1:18791/torrent")!
        let meta = try TorrentMetainfo.parse(try await URLSession.shared.data(from: torrentURL).0)
        var setup = DownloadNetworkSetup(); setup.proxy.mode = .direct
        let storage = TorrentStorage(meta: meta, workingFolder: TorrentStorage.workingFolder(for: id, in: root), selected: [])
        try storage.prepare()
        // Slowed to about 80 KB/s so the last stretch lasts long enough to happen on a fast local link (the file is 300 KB).
        let slow = BandwidthController(); slow.setTaskLimit(80_000, for: id)
        let session = TorrentSession(infoHash: meta.infoHash, meta: meta, trackers: [], storage: { storage }, alreadyHave: [], transports: NWPeerTransportFactory(network: { setup }, systemProxyActive: { false }),
                                     tracker: RecordingTracker(), download: slow, upload: nil, taskID: id, settings: .testing)
        let done = Box(false), verified = Box<[Int]>([]), failure = Box<String?>(nil)
        session.onEvent = { e in
            if case .finished = e { done.v = true }
            if case .verifiedPiece(let i, _) = e { verified.v.append(i) }
            if case .failed(let m, _) = e { failure.v = m }
        }
        session.start()
        session.addCandidates([PeerAddress(host: "127.0.0.1", port: 18792), PeerAddress(host: "127.0.0.1", port: 18795)], source: "live")
        var sawEndgame = false
        let end = Date().addingTimeInterval(40)
        while Date() < end, !done.v, failure.v == nil { if session.snapshot.endgame { sawEndgame = true }; try await Task.sleep(nanoseconds: 5_000_000) }
        session.stop()
        XCTAssertNil(failure.v); XCTAssertTrue(done.v, "finished")
        XCTAssertEqual(verified.v.sorted(), Array(0..<meta.pieceCount), "every piece verified exactly once: no duplicate write or completion")
        let placed = try storage.finish(into: root.appendingPathComponent("out"))
        let content = Data((0..<300_000).map { UInt8(truncatingIfNeeded: ($0 * 11 + ($0 >> 8)) % 256) })
        XCTAssertEqual(try Data(contentsOf: placed), content)
        let duplicates = session.snapshot.duplicateRequests
        print("LIVE ENDGAME seen:", sawEndgame, "duplicate requests sent:", duplicates, "pieces:", verified.v.count)
        XCTAssertTrue(sawEndgame || duplicates > 0, "the last stretch was reached")
    }
}
