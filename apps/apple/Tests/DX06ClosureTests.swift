import XCTest
@testable import Browser_Setu

/// DX-06 targeted closure: file-safety of seeding reads, the creator's file opening and limits, one identity snapshot for read-back, and the v2/hybrid verification labels.
final class DX06ClosureTests: SeedTestCase {
    private func built() throws -> (t: TorrentFixture.Built, location: URL) {
        let t = try TorrentFixture.build(files: Self.standardFiles)
        let location = root.appendingPathComponent("loc-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try writeFiles(t, to: location)
        return (t, location)
    }

    func testAPipeSwappedInForAFileNeitherBlocksNorServes() throws {
        let (t, location) = try built()
        let source = SeedingSource(meta: t.meta, location: location, chosen: [0, 1], verifiedPieces: Set(0..<t.meta.pieceCount))
        let a = location.appendingPathComponent("a.bin")
        try FileManager.default.removeItem(at: a)
        XCTAssertEqual(mkfifo(a.path, 0o600), 0)
        let done = expectation(description: "read returned")
        var result: Result<Data, SeedingSource.ReadFailure>?
        DispatchQueue.global().async { result = source.read(piece: 0, begin: 0, length: 16_384); done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(result, .failure(.filesChanged))
        XCTAssertFalse(source.isServable(0))
    }

    func testALinkPutInPlaceOfAFileIsNotFollowed() throws {
        let (t, location) = try built()
        let source = SeedingSource(meta: t.meta, location: location, chosen: [0, 1], verifiedPieces: Set(0..<t.meta.pieceCount))
        let a = location.appendingPathComponent("a.bin"), elsewhere = root.appendingPathComponent("copy.bin")
        try FileManager.default.moveItem(at: a, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: a, withDestinationURL: elsewhere)
        XCTAssertEqual(source.read(piece: 0, begin: 0, length: 16_384), .failure(.filesChanged))
        XCTAssertFalse(source.isServable(0))
    }

    func testAFileReplacedByAnIdenticalLookingCopyIsRevoked() throws {
        let (t, location) = try built()
        let source = SeedingSource(meta: t.meta, location: location, chosen: [0, 1], verifiedPieces: Set(0..<t.meta.pieceCount))
        let a = location.appendingPathComponent("a.bin")
        let bytes = try Data(contentsOf: a)
        try FileManager.default.removeItem(at: a); try bytes.write(to: a)          // same bytes, new file
        XCTAssertEqual(source.read(piece: 0, begin: 0, length: 16_384), .failure(.filesChanged), "the identity (inode, time) is what was verified, not the bytes' look")
    }

    func testReadBackUsesOneSnapshotAndAChangeAfterItIsNotServed() throws {
        let (t, location) = try built()
        let baseline = SeedingSource(meta: t.meta, location: location, chosen: [0, 1], verifiedPieces: Set(0..<t.meta.pieceCount)).identitiesSnapshot
        let a = location.appendingPathComponent("a.bin")
        var bytes = try Data(contentsOf: a); bytes[5] ^= 1; try bytes.write(to: a)          // changed after the snapshot
        let checker = TorrentStorage(meta: t.meta, workingFolder: root.appendingPathComponent("unused"), selected: [])
        let source = SeedingSource.rehash(meta: t.meta, location: location, chosen: [0, 1], matches: { _, _ in true }, cancelled: { false }, progress: { _ in }, baseline: baseline)
        _ = checker
        XCTAssertNotNil(source)
        XCTAssertFalse(source!.isServable(0), "a.bin differs from the snapshot, so nothing in it is served even though the (permissive) checker accepted every piece")
        XCTAssertTrue(source!.isServable(4), "pieces only in the untouched file are still served")
    }

    func testCreatorCountsPaddingEntriesTowardTheFileLimit() throws {
        var options = TorrentCreator.Options(); options.format = .hybrid; options.pieceSize = .fixed(16_384)
        let n = TorrentMetainfo.Limit.maxFiles
        let files = (0..<n).map { TorrentCreator.Entry(components: ["f\($0)"], url: root.appendingPathComponent("f\($0)"), size: 1, modified: nil) }
        let plan = TorrentCreator.Plan(root: root, name: "many", isFolder: true, files: files, skipped: [], totalBytes: Int64(n))
        XCTAssertThrowsError(try TorrentCreator().layout(plan: plan, options: options)) { XCTAssertEqual($0 as? TorrentCreator.Failure, .tooManyFiles) }
        options.format = .v2
        XCTAssertNoThrow(try TorrentCreator().layout(plan: plan, options: options), "version 2 has no padding entries, so the same folder fits")
    }

    func testCreatorRefusesAFileThatBecameALinkAfterListing() throws {
        let folder = root.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let a = folder.appendingPathComponent("a.bin")
        try Data(repeating: 7, count: 40_000).write(to: a)
        let other = root.appendingPathComponent("other.bin"); try Data(repeating: 7, count: 40_000).write(to: other)
        let creator = TorrentCreator()
        let plan = try creator.plan(root: folder)
        try FileManager.default.removeItem(at: a)
        try FileManager.default.createSymbolicLink(at: a, withDestinationURL: other)
        var options = TorrentCreator.Options(); options.format = .hybrid
        XCTAssertThrowsError(try creator.createSync(plan: plan, options: options), "a link is never followed while hashing")
    }

    func testAVersion2PieceWithoutItsLayerIsNeverVerified() throws {
        let folder = root.appendingPathComponent("v2src", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let content = Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        try content.write(to: folder.appendingPathComponent("big.bin"))
        let creator = TorrentCreator()
        var options = TorrentCreator.Options(); options.format = .v2; options.pieceSize = .fixed(32_768)
        let created = try creator.createSync(plan: try creator.plan(root: folder), options: options)
        var meta = try TorrentMetainfo.parse(created.data)
        let withLayer = TorrentStorage(meta: meta, workingFolder: root.appendingPathComponent("w1"), selected: [])
        let piece = content.prefix(32_768)
        XCTAssertTrue(withLayer.matches(Data(piece), piece: 0), "with the layer the piece verifies")
        meta.pieceLayers = [:]
        let without = TorrentStorage(meta: meta, workingFolder: root.appendingPathComponent("w2"), selected: [])
        XCTAssertEqual(without.v2Verdict(Data(piece), piece: 0), .unavailable)
        XCTAssertFalse(without.matches(Data(piece), piece: 0), "a v2-only piece with no layer to check against cannot pass")
    }

    func testAHybridPieceWithoutItsLayerIsJudgedByVersion1AloneAndNeverCountsAsVersion2Verified() throws {
        let folder = root.appendingPathComponent("hsrc", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let content = Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0 &* 5) })
        try content.write(to: folder.appendingPathComponent("big.bin"))
        let creator = TorrentCreator()
        var options = TorrentCreator.Options(); options.format = .hybrid; options.pieceSize = .fixed(32_768)
        let created = try creator.createSync(plan: try creator.plan(root: folder), options: options)
        var meta = try TorrentMetainfo.parse(created.data)
        meta.pieceLayers = [:]
        let storage = TorrentStorage(meta: meta, workingFolder: root.appendingPathComponent("w3"), selected: [])
        let piece = Data(content.prefix(32_768))
        XCTAssertTrue(storage.matches(piece, piece: 0), "version 1 is the verifier here")
        XCTAssertEqual(storage.v2Verdict(piece, piece: 0), .unavailable, "and the version 2 side is reported as not checked, never as passed")
        var wrong = piece; wrong[0] ^= 1
        XCTAssertFalse(storage.matches(wrong, piece: 0))
    }

    func testAResumeRecordNeverPairsEditedBytesWithAnOldVerification() throws {
        let (t, location) = try built()
        let source = SeedingSource(meta: t.meta, location: location, chosen: [0, 1], verifiedPieces: Set(0..<t.meta.pieceCount))
        let a = location.appendingPathComponent("a.bin")
        var bytes = try Data(contentsOf: a); bytes[3] ^= 1; try bytes.write(to: a)          // edited after the pieces were verified
        let ids = source.resumeIdentities()
        XCTAssertNil(ids[0], "the edited file is not given a fresh identity")
        XCTAssertNotNil(ids[1], "the untouched file keeps its identity")
        XCTAssertFalse(source.servablePieces.contains(0))
    }
}
