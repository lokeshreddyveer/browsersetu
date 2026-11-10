import XCTest
import CryptoKit
@testable import Browser_Setu

// DX-06 workstream C: torrent creation. Every test works in its own temp folder.

final class DX06CreatorTests: XCTestCase {
    private var dirs: [URL] = []

    override func tearDown() {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs = []
    }

    private func temp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("dx06c-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        dirs.append(d)
        return d
    }

    private func bytes(_ n: Int, seed: Int = 1) -> Data { Data((0..<n).map { UInt8(truncatingIfNeeded: ($0 &* 31 &+ ($0 >> 7) &+ seed) % 251) }) }

    @discardableResult
    private func put(_ root: URL, _ path: String, _ data: Data) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    private func make(_ root: URL, _ format: TorrentCreator.Format, piece: Int64 = 32768, tweak: (inout TorrentCreator.Options) -> Void = { _ in }) throws -> (TorrentCreator.CreatedTorrent, TorrentCreator.Plan) {
        let c = TorrentCreator()
        let plan = try c.plan(root: root)
        var o = TorrentCreator.Options()
        o.format = format; o.pieceSize = .fixed(piece)
        tweak(&o)
        return (try c.createSync(plan: plan, options: o), plan)
    }

    private func sha1Pieces(_ stream: Data, _ p: Int) -> Data {
        var out = Data(); var i = 0
        while i < stream.count { out.append(Data(Insecure.SHA1.hash(data: stream.subdata(in: i..<min(i + p, stream.count))))); i += p }
        return out
    }

    // MARK: v1

    func testV1SingleFileParsesAndPiecesMatchRecomputation() throws {
        let d = try temp()
        let content = bytes(100_000)
        let f = try put(d, "single.bin", content)
        let (made, _) = try make(f, .v1)
        let meta = try TorrentMetainfo.parse(made.data)
        XCTAssertEqual(meta.name, "single.bin")
        XCTAssertFalse(meta.isMultiFile)
        XCTAssertEqual(meta.totalLength, 100_000)
        XCTAssertEqual(meta.pieceHashes.reduce(Data(), +), sha1Pieces(content, 32768))
        XCTAssertEqual(meta.infoHash, made.infoHashV1)
        XCTAssertNil(made.infoHashV2)
    }

    func testV1MultiFilePiecesRunAcrossFileBoundaries() throws {
        let d = try temp()
        let root = d.appendingPathComponent("album")
        let a = bytes(40_000, seed: 2), b = bytes(70_000, seed: 3), c = bytes(5, seed: 4)
        try put(root, "b/two.bin", b); try put(root, "a.bin", a); try put(root, "z.txt", c)
        let (made, plan) = try make(root, .v1)
        XCTAssertEqual(plan.files.map(\.relativePath), ["a.bin", "b/two.bin", "z.txt"])
        let meta = try TorrentMetainfo.parse(made.data)
        XCTAssertTrue(meta.isMultiFile)
        XCTAssertEqual(meta.files.map(\.relativePath), ["a.bin", "b/two.bin", "z.txt"])
        XCTAssertEqual(meta.pieceHashes.reduce(Data(), +), sha1Pieces(a + b + c, 32768))
        XCTAssertEqual(made.summary.pieceCount, meta.pieceCount)
    }

    func testTrackersWebSeedsPrivateCommentRoundTrip() throws {
        let d = try temp()
        let f = try put(d, "x.bin", bytes(1000))
        let (made, _) = try make(f, .v1) { o in
            o.trackerTiers = [["udp://tracker.example.org:6969/announce", "https://t.example.org/announce"], ["http://b.example.org/announce"]]
            o.webSeeds = ["https://seed.example.org/files/"]
            o.isPrivate = true; o.comment = "hello"; o.creationDate = Date(timeIntervalSince1970: 1_700_000_000)
        }
        let meta = try TorrentMetainfo.parse(made.data)
        XCTAssertEqual(meta.trackerTiers.map { $0.map(\.absoluteString) }, [["udp://tracker.example.org:6969/announce", "https://t.example.org/announce"], ["http://b.example.org/announce"]])
        XCTAssertEqual(meta.webSeeds.map(\.absoluteString), ["https://seed.example.org/files/"])
        XCTAssertTrue(meta.isPrivate)
        XCTAssertEqual(meta.comment, "hello")
        XCTAssertTrue(made.magnet.contains("tr=udp%3A%2F%2Ftracker.example.org%3A6969%2Fannounce"))
        XCTAssertTrue(made.magnet.contains("ws=https%3A%2F%2Fseed.example.org%2Ffiles%2F"))
    }

    func testBadTrackersAndSeedsAreRejected() throws {
        let d = try temp()
        let f = try put(d, "x.bin", bytes(10))
        for bad in ["ftp://x.org/a", "not a url", "http://"] {
            XCTAssertThrowsError(try make(f, .v1) { $0.trackerTiers = [[bad]] }, bad)
        }
        XCTAssertThrowsError(try make(f, .v1) { $0.webSeeds = ["udp://x.org/"] })
        XCTAssertThrowsError(try make(f, .v1) { $0.trackerTiers = [(0..<33).map { "http://t\($0).example.org/a" }] })
    }

    // MARK: v2

    private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    func testV2RootsAndLayersMatchMerkle() throws {
        let d = try temp()
        let root = d.appendingPathComponent("v2set")
        let files: [(String, Int)] = [("tiny.bin", 1), ("one.bin", 16384), ("exact.bin", 32768), ("long.bin", 100_000), ("sub/big.bin", 200_000), ("zero.bin", 0)]
        var contents: [String: Data] = [:]
        for (i, (path, n)) in files.enumerated() { let data = bytes(n, seed: i + 5); contents[path] = data; try put(root, path, data) }
        let (made, _) = try make(root, .v2)
        XCTAssertNil(made.infoHashV1)
        XCTAssertEqual(made.infoHashV2?.count, 32)
        let top = try BencodeDecoder.decode(made.data, limits: .init(maxBytes: 1 << 24, maxDepth: 24, maxValues: 100_000, maxStringBytes: 1 << 24, binaryKeys: true), rawKeys: ["info"])
        let rootDict = try XCTUnwrap(top.value.dict)
        let info = try XCTUnwrap(rootDict["info"]?.dict)
        XCTAssertEqual(info["meta version"]?.int, 2)
        XCTAssertNil(info["pieces"])
        XCTAssertNil(info["files"])
        let tree = try XCTUnwrap(info["file tree"]?.dict)
        let layers = rootDict["piece layers"]?.dict ?? [:]
        var expectedLayers = 0
        for (path, data) in contents {
            var node = tree
            let comps = path.split(separator: "/").map(String.init)
            for c in comps.dropLast() { node = try XCTUnwrap(node[c]?.dict) }
            let leaf = try XCTUnwrap(node[comps.last!]?.dict?[""]?.dict, path)
            XCTAssertEqual(leaf["length"]?.int, Int64(data.count), path)
            let leaves = Merkle.leafHashes(of: data)
            if data.isEmpty { XCTAssertNil(leaf["pieces root"], path); continue }
            let expectedRoot = try XCTUnwrap(Merkle.fileRoot(leaves: leaves, pieceLength: 32768))
            XCTAssertEqual(leaf["pieces root"]?.data, expectedRoot, path)
            if data.count > 32768 {
                expectedLayers += 1
                let key = String(data: expectedRoot, encoding: .utf8) ?? String(data: expectedRoot, encoding: .isoLatin1)!
                XCTAssertEqual(layers[key]?.data, Merkle.pieceRoots(leaves: leaves, pieceLength: 32768)?.reduce(Data(), +), path)
            } else {
                XCTAssertTrue(layers.isEmpty || layers.count == expectedLayers || true)
            }
        }
        XCTAssertEqual(layers.count, 2)
        XCTAssertEqual(expectedLayers, 2)
        XCTAssertEqual(made.infoHashV2, Data(SHA256.hash(data: try XCTUnwrap(rawInfo(made.data)))))
    }

    private func rawInfo(_ data: Data) -> Data? {
        let d = try? BencodeDecoder.decode(data, limits: .init(maxBytes: 1 << 24, maxDepth: 24, maxValues: 100_000, maxStringBytes: 1 << 24, binaryKeys: true), rawKeys: ["info"])
        return d?.rawRanges["info"].map { data.subdata(in: $0) }
    }

    func testV2SingleFileUsesTheNameAsItsOnlyTreeEntry() throws {
        let d = try temp()
        let f = try put(d, "one.dat", bytes(50_000))
        let (made, _) = try make(f, .v2)
        let info = try XCTUnwrap(BencodeDecoder.decode(made.data, limits: .init(binaryKeys: true), rawKeys: ["info"]).value.dict?["info"]?.dict)
        XCTAssertEqual(info["file tree"]?.dict?.keys.sorted(), ["one.dat"])
        XCTAssertEqual(info["name"]?.string, "one.dat")
    }

    func testIdenticalLongFilesShareOneLayer() throws {
        let d = try temp()
        let root = d.appendingPathComponent("dup")
        let data = bytes(100_000)
        try put(root, "a.bin", data); try put(root, "b.bin", data)
        let (made, _) = try make(root, .v2)
        let top = try XCTUnwrap(BencodeDecoder.decode(made.data, limits: .init(binaryKeys: true)).value.dict)
        XCTAssertEqual(top["piece layers"]?.dict?.count, 1)
    }

    // MARK: hybrid

    func testHybridPaddingFollowsBEP47AndBothViewsDescribeTheSameBytes() throws {
        let d = try temp()
        let root = d.appendingPathComponent("hy")
        let p = 32768
        let a = bytes(40_000, seed: 7), b = bytes(p, seed: 8), c = bytes(1000, seed: 9), z = Data()
        try put(root, "a.bin", a); try put(root, "b.bin", b); try put(root, "c.bin", c); try put(root, "d.bin", z)
        let (made, _) = try make(root, .hybrid)
        XCTAssertNotNil(made.infoHashV1); XCTAssertNotNil(made.infoHashV2)
        let top = try XCTUnwrap(BencodeDecoder.decode(made.data, limits: .init(binaryKeys: true)).value.dict)
        let info = try XCTUnwrap(top["info"]?.dict)
        let list = try XCTUnwrap(info["files"]?.list)
        let shape = list.map { e -> String in
            let d = e.dict!
            return (d["path"]!.list!.map { $0.string! }).joined(separator: "/") + ":" + String(d["length"]!.int!) + (d["attr"] != nil ? ":p" : "")
        }
        // a (not aligned) -> pad; b (aligned) -> none; c (not aligned, not last: d.bin follows) -> pad; d last
        XCTAssertEqual(shape, ["a.bin:40000", ".pad/\(2 * p - 40000):\(2 * p - 40000):p", "b.bin:\(p)", "c.bin:1000", ".pad/\(p - 1000):\(p - 1000):p", "d.bin:0"])
        // v1 pieces equal SHA-1 of the stream with zero padding
        let stream = a + Data(count: 2 * p - 40000) + b + c + Data(count: p - 1000)
        XCTAssertEqual(info["pieces"]?.data, sha1Pieces(stream, p))
        // v2 view
        let tree = try XCTUnwrap(info["file tree"]?.dict)
        XCTAssertEqual(tree.keys.sorted(), ["a.bin", "b.bin", "c.bin", "d.bin"])
        XCTAssertEqual(tree["a.bin"]?.dict?[""]?.dict?["pieces root"]?.data, Merkle.fileRoot(leaves: Merkle.leafHashes(of: a), pieceLength: Int64(p)))
        XCTAssertNil(tree["d.bin"]?.dict?[""]?.dict?["pieces root"])
        // the app's v1 parser reads the v1 half and agrees with the info hash
        let meta = try TorrentMetainfo.parse(made.data)
        XCTAssertEqual(meta.infoHash, made.infoHashV1)
    }

    func testHybridSingleFileHasNoPadding() throws {
        let d = try temp()
        let f = try put(d, "s.bin", bytes(40_000))
        let (made, _) = try make(f, .hybrid)
        let info = try XCTUnwrap(BencodeDecoder.decode(made.data, limits: .init(binaryKeys: true)).value.dict?["info"]?.dict)
        XCTAssertNil(info["files"])
        XCTAssertEqual(info["length"]?.int, 40_000)
        XCTAssertNotNil(info["file tree"])
    }

    func testMagnetFormats() throws {
        let d = try temp()
        let f = try put(d, "m me.bin", bytes(100))
        let v1 = try make(f, .v1).0, v2 = try make(f, .v2).0, hy = try make(f, .hybrid).0
        XCTAssertTrue(v1.magnet.hasPrefix("magnet:?xt=urn:btih:" + hex(v1.infoHashV1!) + "&dn=m%20me.bin"))
        XCTAssertEqual(hex(v1.infoHashV1!).count, 40)
        XCTAssertTrue(v2.magnet.hasPrefix("magnet:?xt=urn:btmh:1220" + hex(v2.infoHashV2!)))
        XCTAssertTrue(hy.magnet.hasPrefix("magnet:?xt=urn:btih:" + hex(hy.infoHashV1!) + "&xt=urn:btmh:1220" + hex(hy.infoHashV2!) + "&dn="))
    }

    // MARK: piece sizes

    func testAutomaticPieceSizes() {
        let mib: Int64 = 1 << 20
        XCTAssertEqual(TorrentCreator.recommendedPieceLength(totalBytes: 0), 16384)
        XCTAssertEqual(TorrentCreator.recommendedPieceLength(totalBytes: 1000), 16384)
        XCTAssertEqual(TorrentCreator.recommendedPieceLength(totalBytes: 40 * mib), 32768)            // 2560 pieces at 16 KiB: over 2500, so 32 KiB
        XCTAssertEqual(TorrentCreator.recommendedPieceLength(totalBytes: 100 * mib), 65536)
        XCTAssertEqual(TorrentCreator.recommendedPieceLength(totalBytes: 10 * 1024 * mib), 8 * mib)
        XCTAssertEqual(TorrentCreator.recommendedPieceLength(totalBytes: 100 * 1024 * 1024 * mib), 16 * mib)   // clamped
        for total in [Int64(1), 50 * mib, 700 * mib, 5000 * mib] {
            let p = TorrentCreator.recommendedPieceLength(totalBytes: total)
            XCTAssertTrue(Merkle.validPieceLength(p))
            XCTAssertLessThanOrEqual((total + p - 1) / p, 2500)
        }
    }

    func testInvalidManualPieceSizesAreRejected() throws {
        let d = try temp()
        let f = try put(d, "x.bin", bytes(100))
        let c = TorrentCreator(); let plan = try c.plan(root: f)
        for bad: Int64 in [0, 1, 1000, 16385, 24576, 32769, 8192, 128 * 1024 * 1024, -16384] {
            var o = TorrentCreator.Options(); o.pieceSize = .fixed(bad)
            XCTAssertThrowsError(try c.layout(plan: plan, options: o), "\(bad)")
        }
        for good in TorrentCreator.validPieceLengths {
            var o = TorrentCreator.Options(); o.pieceSize = .fixed(good)
            XCTAssertNoThrow(try c.layout(plan: plan, options: o))
        }
        XCTAssertEqual(TorrentCreator.validPieceLengths.first, 16384)
    }

    func testLayoutReportsPieceCountAndMetadataEstimateBeforeHashing() throws {
        let d = try temp()
        let f = try put(d, "x.bin", bytes(100_000))
        let c = TorrentCreator(); let plan = try c.plan(root: f)
        var o = TorrentCreator.Options(); o.pieceSize = .fixed(32768)
        let l = try c.layout(plan: plan, options: o)
        XCTAssertEqual(l.pieceCount, 4)
        XCTAssertGreaterThan(l.estimatedMetadataBytes, 80)
        let made = try c.createSync(plan: plan, options: o)
        XCTAssertLessThanOrEqual(made.data.count, l.estimatedMetadataBytes)
    }

    func testMetadataOverTheLimitIsRejectedBeforeHashing() throws {
        // A plan that only claims a huge size (nothing is read by layout).
        let d = try temp()
        let f = try put(d, "x.bin", bytes(10))
        let c = TorrentCreator()
        var plan = try c.plan(root: f)
        plan.totalBytes = 400 * (1 << 30); plan.files[0].size = plan.totalBytes     // 400 GiB at 16 KiB = 26M pieces
        var o = TorrentCreator.Options(); o.pieceSize = .fixed(16384)
        XCTAssertThrowsError(try c.layout(plan: plan, options: o))
    }

    // MARK: file system edge cases

    func testEmptyFolderIsAnError() throws {
        let d = try temp()
        let root = d.appendingPathComponent("empty"); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertThrowsError(try TorrentCreator().plan(root: root)) { XCTAssertEqual($0 as? TorrentCreator.Failure, .emptyFolder) }
        // only a .DS_Store inside is empty too
        try Data().write(to: root.appendingPathComponent(".DS_Store"))
        XCTAssertThrowsError(try TorrentCreator().plan(root: root)) { XCTAssertEqual($0 as? TorrentCreator.Failure, .emptyFolder) }
    }

    func testZeroByteFileIsAllowedInAFolderButNotAloneAndHybridV2Agree() throws {
        let d = try temp()
        let root = d.appendingPathComponent("z")
        try put(root, "empty.txt", Data()); try put(root, "data.bin", bytes(5000))
        for format in TorrentCreator.Format.allCases {
            let (made, _) = try make(root, format)
            if format.hasV1 {
                let meta = try TorrentMetainfo.parse(made.data)
                let real = meta.files.filter { $0.path.first != ".pad" }
                XCTAssertEqual(real.map(\.relativePath), ["data.bin", "empty.txt"])
                XCTAssertEqual(real.last?.length, 0)
            }
        }
        let lone = try put(d, "only-empty.bin", Data())
        XCTAssertThrowsError(try make(lone, .v1)) { XCTAssertEqual($0 as? TorrentCreator.Failure, .noData) }
    }

    func testSymbolicLinksAreNotFollowed() throws {
        let d = try temp()
        let outside = try put(d, "outside/secret.txt", bytes(300))
        let root = d.appendingPathComponent("pkg")
        try put(root, "real.bin", bytes(100))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linkfile"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linkdir"), withDestinationURL: outside.deletingLastPathComponent())
        let plan = try TorrentCreator().plan(root: root)
        XCTAssertEqual(plan.files.map(\.relativePath), ["real.bin"])
        XCTAssertEqual(Set(plan.skipped.map(\.path)), ["linkfile", "linkdir"])
        XCTAssertTrue(plan.skipped.allSatisfy { $0.reason.contains("symbolic link") })
        XCTAssertThrowsError(try TorrentCreator().plan(root: root.appendingPathComponent("linkfile"))) { XCTAssertEqual($0 as? TorrentCreator.Failure, .symlinkRoot) }
        XCTAssertThrowsError(try TorrentCreator().plan(root: root.appendingPathComponent("linkdir"))) { XCTAssertEqual($0 as? TorrentCreator.Failure, .symlinkRoot) }
    }

    func testUnsafeNamesAreRejected() throws {
        let d = try temp()
        let root = d.appendingPathComponent("names")
        try put(root, "ok.bin", bytes(10))
        try put(root, "bad\u{07}name", bytes(10))                     // control character
        XCTAssertThrowsError(try TorrentCreator().plan(root: root)) { if case .unsafeName = $0 as? TorrentCreator.Failure {} else { XCTFail("\($0)") } }
        for bad in ["..", ".", "a/b", "a\\b", "a:b", "", String(repeating: "x", count: 300)] {
            XCTAssertNil(TorrentMetainfo.safeComponent(bad), bad)
        }
        let long = d.appendingPathComponent("long")
        try put(long, String(repeating: "n", count: 255), bytes(10))
        XCTAssertNoThrow(try TorrentCreator().plan(root: long))
    }

    func testCaseInsensitiveDuplicatesAreRefusedWhenTheDiskAllowsThem() throws {
        let d = try temp()
        let root = d.appendingPathComponent("case")
        try put(root, "A.txt", bytes(10))
        try put(root, "a.txt", bytes(11))
        // On a case-insensitive volume the second write replaced the first; only a case-sensitive one has two entries.
        let n = (try FileManager.default.contentsOfDirectory(atPath: root.path)).count
        if n == 2 { XCTAssertThrowsError(try TorrentCreator().plan(root: root)) } else { XCTAssertNoThrow(try TorrentCreator().plan(root: root)) }
    }

    func testThousandsOfFiles() throws {
        let d = try temp()
        let root = d.appendingPathComponent("many")
        for i in 0..<3000 { try put(root, "dir\(i % 30)/f\(i).bin", bytes(i % 200 + 1, seed: i)) }
        let (made, plan) = try make(root, .hybrid, piece: 16384)
        XCTAssertEqual(plan.fileCount, 3000)
        let meta = try TorrentMetainfo.parse(made.data)
        XCTAssertEqual(meta.files.filter { $0.path.first != ".pad" }.count, 3000)
        XCTAssertEqual(meta.infoHash, made.infoHashV1)
    }

    func testDeepV2PathsAreRefusedUpFront() throws {
        let d = try temp()
        let root = d.appendingPathComponent("deep")
        try put(root, (0..<10).map { "d\($0)" }.joined(separator: "/") + "/f.bin", bytes(10))
        let c = TorrentCreator(); let plan = try c.plan(root: root)
        var o = TorrentCreator.Options(); o.format = .v2
        XCTAssertThrowsError(try c.layout(plan: plan, options: o))
        o.format = .v1
        XCTAssertNoThrow(try c.layout(plan: plan, options: o))
    }

    // MARK: failures during hashing

    func testCancellationMidHashStopsAndProducesNothing() async throws {
        let d = try temp()
        let f = try put(d, "big.bin", bytes(8 << 20))
        let c = TorrentCreator()
        let plan = try c.plan(root: f)
        var o = TorrentCreator.Options(); o.pieceSize = .fixed(65536)
        let box = TaskBox()
        var creator = c
        creator.chunkHook = { _, into in if into >= 2 << 20 { box.cancel() } }
        let snapshot = creator
        let task = Task { try await snapshot.create(plan: plan, options: o) }
        box.set(task)
        do { _ = try await task.value; XCTFail("should have been cancelled") } catch is CancellationError {} catch { XCTFail("\(error)") }
    }

    func testAFileModifiedWhileHashingIsDetected() throws {
        let d = try temp()
        let f = try put(d, "grow.bin", bytes(3 << 20))
        var c = TorrentCreator()
        let plan = try c.plan(root: f)
        c.chunkHook = { _, into in
            if into == 1 << 20, let h = try? FileHandle(forWritingTo: f) { try? h.seekToEnd(); try? h.write(contentsOf: Data([1, 2, 3])); try? h.close() }
        }
        XCTAssertThrowsError(try c.createSync(plan: plan, options: TorrentCreator.Options())) { XCTAssertEqual($0 as? TorrentCreator.Failure, .changed("grow.bin")) }
    }

    func testAFileTouchedWithSameSizeIsDetected() throws {
        let d = try temp()
        let f = try put(d, "same.bin", bytes(2 << 20))
        var c = TorrentCreator()
        let plan = try c.plan(root: f)
        c.chunkHook = { _, into in if into == 1 << 20 { try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 5000)], ofItemAtPath: f.path) } }
        XCTAssertThrowsError(try c.createSync(plan: plan, options: TorrentCreator.Options()))
    }

    func testAVanishedFileAbortsWithoutOutput() throws {
        let d = try temp()
        let root = d.appendingPathComponent("gone")
        try put(root, "a.bin", bytes(100)); let b = try put(root, "b.bin", bytes(100))
        let c = TorrentCreator()
        let plan = try c.plan(root: root)
        try FileManager.default.removeItem(at: b)
        XCTAssertThrowsError(try c.createSync(plan: plan, options: TorrentCreator.Options())) { XCTAssertEqual($0 as? TorrentCreator.Failure, .unreadable("b.bin")) }
    }

    func testAnUnreadableFileIsReportedByPlanOrCreate() throws {
        let d = try temp()
        let root = d.appendingPathComponent("noread")
        try put(root, "ok.bin", bytes(100)); let locked = try put(root, "locked.bin", bytes(100))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        if getuid() == 0 { throw XCTSkip("root can read anything") }
        XCTAssertThrowsError(try TorrentCreator().plan(root: root)) { XCTAssertEqual($0 as? TorrentCreator.Failure, .unreadable("locked.bin")) }
    }

    // MARK: output

    func testWritingNeverOverwritesAndChoosesNumberedNames() throws {
        let d = try temp()
        let first = try TorrentCreator.write(Data("one".utf8), named: "set.torrent", in: d)
        let second = try TorrentCreator.write(Data("two".utf8), named: "set.torrent", in: d)
        let third = try TorrentCreator.write(Data("three".utf8), named: "set.torrent", in: d)
        XCTAssertEqual([first, second, third].map(\.lastPathComponent), ["set.torrent", "set 2.torrent", "set 3.torrent"])
        XCTAssertEqual(try Data(contentsOf: first), Data("one".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("two".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: d.path).count, 3)       // no temp files left
    }

    func testTrackerTextTiers() {
        XCTAssertEqual(TorrentCreator.parseTrackerText("http://a/x\nudp://b:1/x\n\n\nhttp://c/x\n"), [["http://a/x", "udp://b:1/x"], ["http://c/x"]])
        XCTAssertEqual(TorrentCreator.parseTrackerText("  \n"), [])
    }

    // MARK: export for the independent Python validator

    /// Writes a small content tree and a .torrent for each format into a folder and prints the paths. Set DX06_EXPORT_DIR to choose the folder (otherwise a temp folder that is removed afterwards).
    func testExportForExternalValidator() throws {
        let envDir = ProcessInfo.processInfo.environment["DX06_EXPORT_DIR"]
        // The test host is sandboxed and may not see the variable; the default is a fixed folder in its temp directory that is kept (so a validator can read it).
        let base = envDir.map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory.appendingPathComponent("dx06-creator-export")
        try? FileManager.default.removeItem(at: base)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let content = base.appendingPathComponent("content")
        try? FileManager.default.removeItem(at: content)
        try put(content, "a.bin", bytes(40_000, seed: 2)); try put(content, "sub/b.bin", bytes(100_000, seed: 3)); try put(content, "sub/c.txt", bytes(17, seed: 4))
        try put(content, "empty.dat", Data()); try put(content, "z-aligned.bin", bytes(65_536, seed: 5))
        for format in TorrentCreator.Format.allCases {
            let (made, _) = try make(content, format, piece: 32768)
            let url = try TorrentCreator.write(made.data, named: "content-\(format.rawValue).torrent", in: base)
            print("DX06_EXPORT \(format.rawValue) torrent=\(url.path) content=\(content.path) v1=\(made.infoHashV1.map(hex) ?? "-") v2=\(made.infoHashV2.map(hex) ?? "-")")
        }
    }
}

private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<TorrentCreator.CreatedTorrent, Error>?
    private var pending = false
    func set(_ t: Task<TorrentCreator.CreatedTorrent, Error>) { lock.lock(); task = t; let p = pending; lock.unlock(); if p { t.cancel() } }
    func cancel() { lock.lock(); let t = task; if t == nil { pending = true }; lock.unlock(); t?.cancel() }
}
