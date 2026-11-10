import XCTest
@testable import Browser_Setu

// DX-06 integration: the boundaries between the parts that were built apart (creator, v2/hybrid parser and gate, seeding, fast resume, piece layers).

final class DX06IntegrationTests: XCTestCase {
    private var root: URL!
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent("dx06i-\(UUID().uuidString)"); try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func bytes(_ n: Int, seed: Int) -> Data { Data((0..<n).map { UInt8(truncatingIfNeeded: ($0 &* 31 &+ ($0 >> 7) &+ seed) % 251) }) }
    private func put(_ dir: URL, _ path: String, _ data: Data) throws {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    /// The torrent's whole byte stream as the pieces see it: real files, and zeros for padding.
    private func stream(_ meta: TorrentMetainfo, content: URL) throws -> Data {
        var out = Data()
        for f in meta.files { out.append(f.isPadding ? Data(count: Int(f.length)) : try Data(contentsOf: content.appendingPathComponent(f.relativePath))) }
        XCTAssertEqual(Int64(out.count), meta.totalLength)
        return out
    }

    // V + C: what the creator writes, the parser reads, and the one hash gate accepts the real data and refuses a flipped byte.
    func testCreatedV2AndHybridTorrentsParseAndVerifyRealPieces() throws {
        let content = root.appendingPathComponent("pack", isDirectory: true)
        try put(content, "a.bin", bytes(40_000, seed: 1)); try put(content, "sub/b.bin", bytes(100_000, seed: 2)); try put(content, "sub/c.txt", bytes(17, seed: 3)); try put(content, "z.bin", bytes(65_536, seed: 4))
        for format in [TorrentCreator.Format.v2, .hybrid, .v1] {
            let creator = TorrentCreator()
            let plan = try creator.plan(root: content)
            var o = TorrentCreator.Options(); o.format = format; o.pieceSize = .fixed(32768)
            let made = try creator.createSync(plan: plan, options: o)
            let meta = try TorrentMetainfo.parse(made.data)
            XCTAssertEqual(meta.version, format == .v2 ? .v2 : (format == .hybrid ? .hybrid : .v1))
            if let v1 = made.infoHashV1 { XCTAssertEqual(meta.infoHashHex, v1.map { String(format: "%02x", $0) }.joined()) }
            if let v2 = made.infoHashV2 { XCTAssertEqual(meta.infoHashV2, v2) }
            XCTAssertEqual(Set(meta.visibleFiles.map(\.relativePath)), ["a.bin", "sub/b.bin", "sub/c.txt", "z.bin"])
            let whole = try stream(meta, content: content)
            let storage = TorrentStorage(meta: meta, workingFolder: root.appendingPathComponent("w-\(format)"), selected: [])
            for p in 0..<meta.pieceCount {
                let start = p * Int(meta.pieceLength)
                let piece = whole.subdata(in: start..<(start + Int(meta.length(ofPiece: p))))
                XCTAssertTrue(storage.matches(piece, piece: p), "\(format) piece \(p)")
                var bad = piece; bad[bad.startIndex + bad.count / 2] ^= 0x01
                XCTAssertFalse(storage.matches(bad, piece: p), "\(format) piece \(p) with one flipped bit")
            }
        }
    }

    // V: a version 2 torrent known only from a magnet link gets its piece layers from peers: the answer a seeder gives is exactly what the fetcher accepts, and a wrong or partial one is not.
    func testAHashRequestIsAnsweredAndTheAnswerVerifiesAndAssemblesTheLayer() throws {
        let pieceLength: Int64 = 32768
        let data = bytes(300_000, seed: 9)
        let leaves = Merkle.leafHashes(of: data)
        let root = Merkle.fileRoot(leaves: leaves, pieceLength: pieceLength)!
        let layer = Merkle.pieceRoots(leaves: leaves, pieceLength: pieceLength)!.reduce(Data(), +)
        let requests = HashProof.requestsForPieceLayer(piecesRoot: root, fileLength: Int64(data.count), pieceLength: pieceLength)
        XCTAssertFalse(requests.isEmpty)
        var runs: [Int: [Data]] = [:]
        for r in requests {
            let reply = try XCTUnwrap(HashProof.answer(r, layer: layer, fileLength: Int64(data.count), pieceLength: pieceLength))
            let decoded = try PeerWire.decodeHash(Data(PeerWire.encodeHash(reply).dropFirst(4)))          // through the wire format
            runs[r.index] = try XCTUnwrap(HashProof.verify(decoded, piecesRoot: root, fileLength: Int64(data.count), pieceLength: pieceLength), "the answer verifies against the root")
            var forged = decoded; forged.hashes[0][0] ^= 1
            XCTAssertNil(HashProof.verify(forged, piecesRoot: root, fileLength: Int64(data.count), pieceLength: pieceLength), "a forged hash is refused")
        }
        XCTAssertEqual(HashProof.assemblePieceLayer(runs: runs, piecesRoot: root, fileLength: Int64(data.count), pieceLength: pieceLength), layer)
        var outOfRange = requests[0]; outOfRange.index = 1 << 20
        XCTAssertNil(HashProof.answer(outOfRange, layer: layer, fileLength: Int64(data.count), pieceLength: pieceLength), "a request beyond the tree is rejected")
        var wrongLayer = requests[0]; wrongLayer.baseLayer = 0
        XCTAssertNil(HashProof.answer(wrongLayer, layer: layer, fileLength: Int64(data.count), pieceLength: pieceLength), "only the piece layer is served")
    }

    func testSavedLayersAreReadBackOnlyIfTheyHashToTheirFilesRoot() throws {
        let content = root.appendingPathComponent("pack", isDirectory: true)
        try put(content, "big.bin", bytes(200_000, seed: 5))
        let creator = TorrentCreator()
        var o = TorrentCreator.Options(); o.format = .v2; o.pieceSize = .fixed(32768)
        let meta = try TorrentMetainfo.parse(try creator.createSync(plan: try creator.plan(root: content), options: o).data)
        XCTAssertFalse(meta.pieceLayers.isEmpty)
        XCTAssertEqual(LayerStore.decode(LayerStore.encode(meta.pieceLayers), for: meta), meta.pieceLayers)
        var damaged = meta.pieceLayers
        let key = damaged.keys.first!
        damaged[key]![0] ^= 0xFF
        XCTAssertTrue(LayerStore.decode(LayerStore.encode(damaged), for: meta).isEmpty, "a layer that no longer hashes to its root is dropped")
        XCTAssertTrue(LayerStore.decode(Data([0, 0, 0, 5, 1, 2]), for: meta).isEmpty, "garbage is ignored")
    }

    func testMagnetTextNamesTheTorrentTheWayItsVersionRequires() throws {
        let content = root.appendingPathComponent("pack", isDirectory: true)
        try put(content, "a.bin", bytes(50_000, seed: 6)); try put(content, "b.bin", bytes(70_000, seed: 7))
        for format in [TorrentCreator.Format.v1, .v2, .hybrid] {
            let creator = TorrentCreator()
            var o = TorrentCreator.Options(); o.format = format; o.pieceSize = .fixed(32768)
            let meta = try TorrentMetainfo.parse(try creator.createSync(plan: try creator.plan(root: content), options: o).data)
            let link = try MagnetLink.parse(TorrentRunner.magnetText(for: meta))
            XCTAssertEqual(link.infoHash, meta.infoHash, "\(format): the wire hash")
            XCTAssertEqual(link.infoHashV2, meta.infoHashV2, "\(format)")
        }
    }

    // S + R: fast-resume evidence lets a relaunch skip reading pieces whose files are unchanged, and only those.
    func testResumeEvidenceSkipsUnchangedFilesAndRereadsAChangedOne() throws {
        let t = try TorrentFixture.build(files: [(["a.bin"], 70_000), (["b.bin"], 70_000)], pieceLength: 32768)
        let location = root.appendingPathComponent("final", isDirectory: true)
        for f in t.meta.files { try put(location, f.relativePath, t.stream.subdata(in: Int(f.offset)..<Int(f.offset + f.length))) }
        let chosen = Set(t.meta.files.map(\.index))
        let first = SeedingSource(meta: t.meta, location: location, chosen: chosen, verifiedPieces: Set(0..<t.meta.pieceCount))
        let record = ResumeRecord.empty(for: t.meta).bumped(afterVerifying: first.servablePieces, identities: first.resumeIdentities(), meta: t.meta, now: Date().addingTimeInterval(5), fullyVerified: true)
        let decoded = try XCTUnwrap(ResumeRecord.decode(record.encoded(), expecting: t.meta, torrentVersion: "v1"))
        func evaluate() -> ResumeTrust.Decision {
            let probe = SeedingSource(meta: t.meta, location: location, chosen: chosen, verifiedPieces: [])
            let now = ResumeTrust.captureIdentities(meta: t.meta, skipping: []) { probe.path(of: t.meta.files[$0]) }
            return ResumeTrust.evaluate(record: decoded, meta: t.meta, currentIdentities: now, unselectedFiles: [], torrentVersion: "v1")
        }
        XCTAssertEqual(evaluate().trusted, Set(0..<t.meta.pieceCount), "nothing changed: everything is trusted, nothing is read")
        // b.bin is changed in place (same size), so its pieces — and only theirs — must be read again.
        let b = location.appendingPathComponent("b.bin")
        var changed = try Data(contentsOf: b); changed[100] ^= 0xFF
        Thread.sleep(forTimeInterval: 0.05)
        try changed.write(to: b)
        let after = evaluate()
        let bPieces = Set(t.meta.files[1].pieceRange(in: t.meta))
        XCTAssertTrue(after.trusted.isDisjoint(with: bPieces), "pieces of the changed file are not trusted")
        XCTAssertEqual(after.trusted, Set(0..<t.meta.pieceCount).subtracting(bPieces).subtracting(Set(t.meta.files[0].pieceRange(in: t.meta)).intersection(bPieces)))
        // The seeding source then reads only what is not vouched for, and finds the damaged piece.
        var reads = 0
        let rebuilt = SeedingSource.rehash(meta: t.meta, location: location, chosen: chosen, trusted: after.trusted, matches: { data, p in reads += 1; return TorrentStorage(meta: t.meta, workingFolder: self.root.appendingPathComponent("chk"), selected: []).matches(data, piece: p) }, cancelled: { false }, progress: { _ in })
        XCTAssertEqual(reads, Set(0..<t.meta.pieceCount).subtracting(after.trusted).count, "trusted pieces were not read")
        XCTAssertNotNil(rebuilt)
        XCTAssertFalse(rebuilt!.servablePieces.contains(Int((t.meta.files[1].offset + 100) / t.meta.pieceLength)), "the damaged piece is not served")
    }
}

private extension TorrentMetainfo.File {
    /// The pieces that hold at least one byte of this file.
    func pieceRange(in meta: TorrentMetainfo) -> ClosedRange<Int> {
        Int(offset / meta.pieceLength)...Int((offset + max(length, 1) - 1) / meta.pieceLength)
    }
}
