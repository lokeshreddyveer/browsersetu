import XCTest
import CryptoKit
@testable import Browser_Setu

// DX-06 workstream V: BitTorrent v2 and hybrid metadata, padding, v2 magnets, version-aware piece checks, the hash messages.
// The torrents here are built by the builder below from the Merkle rules (whose roots are cross-checked against the independent vectors of DX06MerkleTests), never by the parser under test.

enum V2Fx {
    struct Spec { var path: [String]; var data: Data }

    /// Same content formula as DX06MerkleTests, so roots can be compared with its independent vectors.
    static func content(_ n: Int, seed: Int = 0) -> Data { Data((0..<n).map { i in let j = i + seed; return UInt8(truncatingIfNeeded: (j * 7 + (j >> 8)) % 256) }) }
    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
    static func b(_ s: String) -> Bencode { .bytes(Data(s.utf8)) }

    static func insert(_ d: inout [String: Bencode], _ path: ArraySlice<String>, _ leaf: Bencode) {
        guard let first = path.first else { return }
        if path.count == 1 { d[first] = .dict(["": leaf]); return }
        var sub = d[first]?.dict ?? [:]
        insert(&sub, path.dropFirst(), leaf)
        d[first] = .dict(sub)
    }

    static func root(of data: Data, pl: Int64) -> Data? { Merkle.fileRoot(leaves: Merkle.leafHashes(of: data), pieceLength: pl) }

    /// The `file tree` and `piece layers` for these files.
    static func v2Parts(_ files: [Spec], pl: Int64) -> (tree: [String: Bencode], layers: [Data: Data]) {
        var tree: [String: Bencode] = [:]
        var layers: [Data: Data] = [:]
        for f in files {
            var leaf: [String: Bencode] = ["length": .int(Int64(f.data.count))]
            if !f.data.isEmpty {
                let leaves = Merkle.leafHashes(of: f.data)
                let r = Merkle.fileRoot(leaves: leaves, pieceLength: pl) ?? Data(count: 32)          // an invalid piece length has no roots: a placeholder lets the parser refuse the torrent
                leaf["pieces root"] = .bytes(r)
                if Int64(f.data.count) > pl, let roots = Merkle.pieceRoots(leaves: leaves, pieceLength: pl) { layers[r] = roots.reduce(Data(), +) }
            }
            insert(&tree, f.path[...], .dict(leaf))
        }
        return (tree, layers)
    }

    static func v2Info(name: String = "set", _ files: [Spec], pl: Int64 = 32768) -> (info: [String: Bencode], layers: [Data: Data]) {
        let parts = v2Parts(files, pl: pl)
        return (["name": b(name), "piece length": .int(pl), "meta version": .int(2), "file tree": .dict(parts.tree)], parts.layers)
    }

    /// A .torrent file's bytes. `piece layers` is keyed by raw hashes, so it is written by hand.
    static func torrent(info: [String: Bencode], layers: [Data: Data]) -> (torrent: Data, info: Data) {
        let infoBytes = BencodeDecoder.encode(.dict(info))
        var out = Data("d4:info".utf8)
        out.append(infoBytes)
        if !layers.isEmpty {
            out.append(Data("12:piece layers".utf8)); out.append(Data("d".utf8))
            for key in layers.keys.sorted(by: { Array($0).lexicographicallyPrecedes(Array($1)) }) {
                out.append(Data("32:".utf8)); out.append(key)
                out.append(Data("\(layers[key]!.count):".utf8)); out.append(layers[key]!)
            }
            out.append(Data("e".utf8))
        }
        out.append(Data("e".utf8))
        return (out, infoBytes)
    }

    /// A version 1 view with BEP 47 padding, optionally with the version 2 view beside it (a hybrid). `pads` false leaves the files unaligned.
    static func v1Info(name: String = "set", _ files: [Spec], pl: Int64 = 32768, pads: Bool = true, hybrid: Bool, padName: ((Int) -> [String])? = nil, trailingPad: Bool = false) -> (info: [String: Bencode], stream: Data) {
        var list: [Bencode] = []
        var stream = Data()
        for (i, f) in files.enumerated() {
            list.append(.dict(["length": .int(Int64(f.data.count)), "path": .list(f.path.map(b))]))
            stream.append(f.data)
            let rem = stream.count % Int(pl)
            if (i < files.count - 1 || trailingPad), pads, rem != 0, !f.data.isEmpty {
                let gap = Int(pl) - rem
                list.append(.dict(["length": .int(Int64(gap)), "attr": b("p"), "path": .list((padName?(gap) ?? [".pad", String(gap)]).map(b))]))
                stream.append(Data(count: gap))
            }
        }
        var hashes = Data()
        var offset = 0
        while offset < stream.count { let n = min(Int(pl), stream.count - offset); hashes.append(Data(Insecure.SHA1.hash(data: stream.subdata(in: offset..<(offset + n))))); offset += n }
        var info: [String: Bencode] = ["name": b(name), "piece length": .int(pl), "pieces": .bytes(hashes), "files": .list(list)]
        if hybrid {
            info["meta version"] = .int(2)
            info["file tree"] = .dict(v2Parts(files, pl: pl).tree)
        }
        return (info, stream)
    }

    static func tempFolder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("dx06v2-\(UUID().uuidString)", isDirectory: true) }

    /// The torrent's whole stream as it should be on the wire: files' bytes, zeros for padding.
    static func stream(_ meta: TorrentMetainfo, _ files: [Spec]) -> Data {
        var it = files.makeIterator()
        var out = Data()
        for f in meta.files { out.append(f.isPadding ? Data(count: Int(f.length)) : (it.next()?.data ?? Data())) }
        return out
    }

    static func piece(_ stream: Data, _ meta: TorrentMetainfo, _ i: Int) -> Data {
        let start = Int(Int64(i) * meta.pieceLength)
        return stream.subdata(in: start..<(start + Int(meta.length(ofPiece: i))))
    }
}

// MARK: Parsing, layout, identity

final class DX06V2ParseTests: XCTestCase {
    typealias Spec = V2Fx.Spec

    func testSingleFileV2MatchesTheIndependentRootAndIdentity() throws {
        let data = V2Fx.content(100_000)
        let (info, layers) = V2Fx.v2Info(name: "one.bin", [Spec(path: ["one.bin"], data: data)])
        let t = V2Fx.torrent(info: info, layers: layers)
        let meta = try TorrentMetainfo.parse(t.torrent)
        XCTAssertEqual(meta.version, .v2)
        XCTAssertFalse(meta.isMultiFile)
        XCTAssertEqual(meta.files.count, 1)
        XCTAssertEqual(meta.files[0].pieceRoot.map(V2Fx.hex), "a61f2da045dde32ea6426a18b0d05e483d7686473b1dacbd9cc24e56caa4770d", "root of the 100000-byte vector")
        XCTAssertEqual(meta.pieceCount, 4)
        XCTAssertEqual(meta.length(ofPiece: 3), 100_000 - 3 * 32768)
        XCTAssertEqual(meta.infoHashV2, Data(SHA256.hash(data: t.info)))
        XCTAssertEqual(meta.infoHash, Data(SHA256.hash(data: t.info)).prefix(20))
        XCTAssertEqual(meta.sessionInfoHash, meta.infoHashV2Truncated)
        XCTAssertEqual(meta.infoHashV2?.count, 32)
        XCTAssertTrue(meta.pieceHashes.isEmpty)
        XCTAssertEqual(meta.pieceLayers.count, 1)
        XCTAssertTrue(meta.missingLayerRoots.isEmpty)
        XCTAssertEqual(meta.rawInfo, t.info, "the info bytes are kept exactly as written")
        // The same bytes through the magnet-metadata path give the same torrent, minus the outer fields.
        let viaMagnet = try TorrentMetainfo.parse(infoSection: t.info)
        XCTAssertEqual(viaMagnet.infoHash, meta.infoHash)
        XCTAssertEqual(viaMagnet.missingLayerRoots, [meta.files[0].pieceRoot!], "a magnet link brings no layers")
    }

    func testMultiFileV2IsAlignedWithVirtualPaddingAndEveryPieceBelongsToOneFile() throws {
        let files = [Spec(path: ["a.bin"], data: V2Fx.content(40_000)), Spec(path: ["b", "c.bin"], data: V2Fx.content(1, seed: 5)),
                     Spec(path: ["d.bin"], data: V2Fx.content(32_768, seed: 9)), Spec(path: ["e.empty"], data: Data())]
        let (info, layers) = V2Fx.v2Info(files)
        let meta = try TorrentMetainfo.parse(V2Fx.torrent(info: info, layers: layers).torrent)
        XCTAssertTrue(meta.isMultiFile)
        XCTAssertEqual(meta.files.map(\.isPadding), [false, true, false, true, false, false])
        XCTAssertEqual(meta.files.map(\.offset), [0, 40_000, 65_536, 65_537, 98_304, 131_072])
        XCTAssertEqual(meta.files.filter(\.isPadding).map(\.length), [25_536, 32_767])
        XCTAssertEqual(meta.files.enumerated().map { $0.offset == $0.element.index }, [Bool](repeating: true, count: 6), "index is the position")
        XCTAssertEqual(meta.pieceCount, 4)
        XCTAssertEqual((0..<4).map { meta.length(ofPiece: $0) }, [32_768, 7_232, 1, 32_768], "a piece ends where its file ends")
        for p in 0..<meta.pieceCount {
            let segs = meta.segments(offset: Int64(p) * meta.pieceLength, length: meta.length(ofPiece: p))
            XCTAssertEqual(Set(segs.map(\.file)).count, 1, "piece \(p) lies in exactly one file")
            XCTAssertFalse(meta.files[segs[0].file].isPadding)
        }
        XCTAssertEqual(meta.visibleFiles.map(\.relativePath), ["a.bin", "b/c.bin", "d.bin", "e.empty"])
        XCTAssertEqual(meta.contentLength, 40_000 + 1 + 32_768)
        XCTAssertEqual(meta.pieceLayers.count, 1, "only a.bin is longer than a piece")
    }

    func testPaddingIsHiddenFromSelectionTreeAndPlan() throws {
        let files = [Spec(path: ["a.bin"], data: V2Fx.content(40_000)), Spec(path: ["b.bin"], data: V2Fx.content(10, seed: 3))]
        let (info, layers) = V2Fx.v2Info(files)
        let meta = try TorrentMetainfo.parse(V2Fx.torrent(info: info, layers: layers).torrent)
        XCTAssertEqual(meta.files.map(\.isPadding), [false, true, false])
        XCTAssertEqual(TorrentSelection.all(meta).priorities.keys.sorted(), [0, 2])
        var old = TorrentSelection(priorities: [0: .normal, 1: .high])          // an old saved choice that named the padding entry
        XCTAssertEqual(old.selected(in: meta), [0])
        XCTAssertEqual(old.normalized(for: meta).priorities.keys.sorted(), [0])
        old.setFolder([".pad"], to: .maximum, in: meta)
        XCTAssertEqual(old.priorities[1], .high, "a folder choice never touches padding")
        let tree = TorrentFileTree(meta)
        XCTAssertEqual(tree.fileCount, 2)
        let rows = tree.rows(expanded: [], selection: TorrentSelection.all(meta), filter: "", meta: meta)
        XCTAssertEqual(rows.map(\.name), ["a.bin", "b.bin"])
        XCTAssertTrue(tree.rows(expanded: [], selection: TorrentSelection.all(meta), filter: "pad", meta: meta).isEmpty)
        let plan = TorrentPlan(TorrentSelection.all(meta), meta: meta)
        XCTAssertEqual(plan.selectedBytes, 40_010)
        XCTAssertEqual(plan.needed, [0, 1, 2])
        XCTAssertEqual(TorrentFileTree.chosenBytes(TorrentSelection.all(meta), meta: meta), 40_010)
        // BEP 53 numbers count the real files for a version 2 torrent.
        XCTAssertEqual(MagnetSelection.apply([1], to: meta).selection.selected(in: meta), [2])
    }

    func testMissingBadAndWrongLayersAreRefusedForATorrentFile() throws {
        let data = V2Fx.content(100_000)
        let (info, layers) = V2Fx.v2Info([Spec(path: ["f"], data: data)])
        XCTAssertThrowsError(try TorrentMetainfo.parse(V2Fx.torrent(info: info, layers: [:]).torrent)) { XCTAssertEqual($0 as? TorrentMetainfo.Failure, .missingPieceLayer("f")) }
        var broken = layers
        let key = broken.keys.first!
        var layer = broken[key]!; layer[0] ^= 1; broken[key] = layer
        XCTAssertThrowsError(try TorrentMetainfo.parse(V2Fx.torrent(info: info, layers: broken).torrent)) { error in
            guard case TorrentMetainfo.Failure.invalid(let why)? = error as? TorrentMetainfo.Failure else { return XCTFail("\(error)") }
            XCTAssertTrue(why.contains("do not match"))
        }
        var short = layers; short[key] = layers[key]!.dropLast(32)
        XCTAssertThrowsError(try TorrentMetainfo.parse(V2Fx.torrent(info: info, layers: short).torrent))
        // A layer filed under another file's root is no help.
        let other = V2Fx.v2Info([Spec(path: ["g"], data: V2Fx.content(100_000, seed: 77))])
        var swapped: [Data: Data] = [:]; swapped[key] = other.layers.values.first!
        XCTAssertThrowsError(try TorrentMetainfo.parse(V2Fx.torrent(info: info, layers: swapped).torrent))
    }

    func testStrictValidationOfTheFileTree() throws {
        let one = [Spec(path: ["f"], data: V2Fx.content(100))]
        func parse(_ mutate: (inout [String: Bencode]) -> Void) throws -> TorrentMetainfo {
            var (info, layers) = V2Fx.v2Info(one)
            mutate(&info)
            layers = [:]
            return try TorrentMetainfo.parse(V2Fx.torrent(info: info, layers: layers).torrent)
        }
        XCTAssertNoThrow(try parse { _ in })
        XCTAssertThrowsError(try parse { $0["meta version"] = .int(3) }) { XCTAssertEqual($0 as? TorrentMetainfo.Failure, .unsupportedMetaVersion(3)) }
        XCTAssertThrowsError(try parse { $0["meta version"] = .int(1) }) { XCTAssertEqual($0 as? TorrentMetainfo.Failure, .unsupportedMetaVersion(1)) }
        XCTAssertThrowsError(try parse { $0["meta version"] = V2Fx.b("2") })
        XCTAssertThrowsError(try parse { $0["file tree"] = nil })
        XCTAssertThrowsError(try parse { $0["piece length"] = .int(24_576) }, "not a power of two")
        XCTAssertThrowsError(try parse { $0["piece length"] = .int(8192) }, "below 16 KiB")
        XCTAssertThrowsError(try parse { $0["name"] = V2Fx.b("..") })
        let leaf: Bencode = .dict(["length": .int(5), "pieces root": .bytes(Data(count: 32))])
        // the tree itself is a file
        XCTAssertThrowsError(try parse { $0["file tree"] = .dict(["": leaf]) }) { XCTAssertEqual(($0 as? TorrentMetainfo.Failure), .invalid("the file tree is itself a file")) }
        // a name that is both a file and a folder
        XCTAssertThrowsError(try parse { $0["file tree"] = .dict(["x": .dict(["": leaf, "y": .dict(["": leaf])])]) })
        // paths that must be refused
        for bad in ["..", ".", "a/b", ""] where bad != "" {
            XCTAssertThrowsError(try parse { $0["file tree"] = .dict([bad: .dict(["": leaf])]) }, bad)
        }
        // pieces root: wrong size, missing, present on an empty file
        XCTAssertThrowsError(try parse { $0["file tree"] = .dict(["x": .dict(["": .dict(["length": .int(5), "pieces root": .bytes(Data(count: 31))])])]) })
        XCTAssertThrowsError(try parse { $0["file tree"] = .dict(["x": .dict(["": .dict(["length": .int(5)])])]) })
        XCTAssertThrowsError(try parse { $0["file tree"] = .dict(["x": .dict(["": .dict(["length": .int(0), "pieces root": .bytes(Data(count: 32))])])]) })
        XCTAssertThrowsError(try parse { $0["file tree"] = .dict(["x": .dict(["": .dict(["length": .int(-1), "pieces root": .bytes(Data(count: 32))])])]) })
        // padding listed in a version 2 tree
        XCTAssertThrowsError(try parse { $0["file tree"] = .dict(["x": .dict(["": .dict(["length": .int(5), "attr": V2Fx.b("p"), "pieces root": .bytes(Data(count: 32))])])]) })
        // names that collide on a case-insensitive disk / after normalisation, and file-vs-folder after case folding
        XCTAssertThrowsError(try parse { $0["file tree"] = .dict(["A": .dict(["": leaf]), "a": .dict(["": leaf])]) })
        XCTAssertThrowsError(try parse { $0["file tree"] = .dict(["a": .dict(["": leaf]), "A": .dict(["b": .dict(["": leaf])])]) })
        // an empty folder, an empty tree, only empty files
        XCTAssertThrowsError(try parse { $0["file tree"] = .dict(["x": .dict([:])]) })
        XCTAssertThrowsError(try parse { $0["file tree"] = .dict([:]) })
        XCTAssertThrowsError(try parse { $0["file tree"] = .dict(["x": .dict(["": .dict(["length": .int(0)])])]) }) { XCTAssertEqual($0 as? TorrentMetainfo.Failure, .invalid("it is empty")) }
        // size limits
        let many = Dictionary(uniqueKeysWithValues: (0...TorrentMetainfo.Limit.maxFiles).map { ("f\($0)", Bencode.dict(["": .dict(["length": .int(0)])])) })
        XCTAssertThrowsError(try parse { $0["file tree"] = .dict(many) }) { XCTAssertEqual($0 as? TorrentMetainfo.Failure, .tooMany("files")) }
        XCTAssertThrowsError(try parse { $0["file tree"] = .dict(["x": .dict(["": .dict(["length": .int(Int64.max), "pieces root": .bytes(Data(count: 32))])])]) })
        // a path 24 folders deep
        var deep: Bencode = .dict(["": leaf])
        for i in 0..<24 { deep = .dict(["d\(i)": deep]) }
        XCTAssertThrowsError(try parse { $0["file tree"] = deep })
        XCTAssertThrowsError(try TorrentMetainfo.parse(Data("d4:infod4:name1:n12:piece lengthi16384e12:meta versioni2e9:file treedeee".utf8)), "an empty tree")
    }

    func testAVersion2FileWithBinaryLayerKeysStillRefusesNonTextNamesInInfo() {
        // The raw-hash keys of `piece layers` are accepted only there: a non-text key inside the info section is still refused.
        var bytes = Data("d4:infod4:name1:n12:piece lengthi16384e".utf8)
        bytes.append(Data("1:".utf8)); bytes.append(Data([0xFF])); bytes.append(Data("i1ee".utf8))
        bytes.append(Data("e".utf8))
        XCTAssertThrowsError(try TorrentMetainfo.parse(bytes))
    }
}

// MARK: Hybrid

final class DX06HybridTests: XCTestCase {
    typealias Spec = V2Fx.Spec
    let files = [Spec(path: ["a.bin"], data: V2Fx.content(40_000)), Spec(path: ["b", "c.bin"], data: V2Fx.content(70_000, seed: 11)), Spec(path: ["z.bin"], data: V2Fx.content(100, seed: 4))]

    private func build(_ v1: (info: [String: Bencode], stream: Data), files: [Spec]? = nil) -> Data {
        V2Fx.torrent(info: v1.info, layers: V2Fx.v2Parts(files ?? self.files, pl: 32768).layers).torrent
    }

    func testAHybridIsReadFromBothViewsAndKeepsTheVersion1Identity() throws {
        let v1 = V2Fx.v1Info(files, hybrid: true)
        let t = V2Fx.torrent(info: v1.info, layers: V2Fx.v2Parts(files, pl: 32768).layers)
        let meta = try TorrentMetainfo.parse(t.torrent)
        XCTAssertEqual(meta.version, .hybrid)
        XCTAssertEqual(meta.infoHash, Data(Insecure.SHA1.hash(data: t.info)), "v1 and hybrid go on the wire with the SHA-1 hash")
        XCTAssertEqual(meta.sessionInfoHash, meta.infoHash)
        XCTAssertEqual(meta.infoHashV2, Data(SHA256.hash(data: t.info)))
        XCTAssertEqual(meta.infoHashV2Truncated?.count, 20)
        XCTAssertEqual(meta.files.map(\.isPadding), [false, true, false, true, false])
        XCTAssertEqual(meta.files.compactMap { $0.isPadding ? nil : $0.pieceRoot }.count, 3)
        XCTAssertTrue(meta.hasPadding)
        XCTAssertEqual(meta.pieceCount, meta.pieceHashes.count)
        XCTAssertEqual(meta.totalLength, Int64(v1.stream.count))
        XCTAssertEqual(meta.visibleFiles.count, 3)
        // The same bytes as a magnet's metadata parse the same way (layers come later).
        XCTAssertEqual(try TorrentMetainfo.parse(infoSection: t.info).version, .hybrid)
    }

    func testHybridPiecesNeedBothHashesAndEitherFailureRefusesThePiece() throws {
        let v1 = V2Fx.v1Info(files, hybrid: true)
        let meta = try TorrentMetainfo.parse(build(v1))
        let storage = TorrentStorage(meta: meta, workingFolder: V2Fx.tempFolder(), selected: [])
        for p in 0..<meta.pieceCount {
            let d = v1.stream.subdata(in: Int(Int64(p) * meta.pieceLength)..<Int(Int64(p) * meta.pieceLength + meta.length(ofPiece: p)))
            XCTAssertTrue(storage.matches(d, piece: p), "piece \(p)")
            var bad = d; bad[bad.startIndex + 5] ^= 0x40
            XCTAssertFalse(storage.matches(bad, piece: p), "a changed byte in piece \(p)")
        }
        XCTAssertFalse(storage.matches(Data(), piece: 0))
        XCTAssertFalse(storage.matches(Data(count: 10), piece: 99))
        XCTAssertFalse(storage.matches(Data(count: 32768), piece: -1))

        // Version 1 hashes that are right but a version 2 root that is wrong (for a one-piece file the root is the whole check): the piece is refused.
        var wrong = files
        wrong[2].data = V2Fx.content(100, seed: 99)          // z.bin: the tree describes different bytes than the stream
        var info = v1.info
        info["file tree"] = .dict(V2Fx.v2Parts(wrong, pl: 32768).tree)
        let meta2 = try TorrentMetainfo.parse(V2Fx.torrent(info: info, layers: V2Fx.v2Parts(files, pl: 32768).layers).torrent)
        let s2 = TorrentStorage(meta: meta2, workingFolder: V2Fx.tempFolder(), selected: [])
        let last = meta2.pieceCount - 1
        let d = v1.stream.subdata(in: Int(Int64(last) * meta2.pieceLength)..<v1.stream.count)
        XCTAssertEqual(Data(Insecure.SHA1.hash(data: d)), meta2.pieceHashes[last], "the version 1 hash agrees")
        XCTAssertFalse(s2.matches(d, piece: last), "the version 2 root does not")
        XCTAssertTrue(s2.matches(v1.stream.subdata(in: 0..<32768), piece: 0), "other pieces are unaffected")
    }

    func testHybridInconsistenciesAreRefusedWithAReason() throws {
        func expectRefused(_ label: String, _ data: @autoclosure () throws -> Data, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try TorrentMetainfo.parse(try data()), label, file: file, line: line) { error in
                guard let f = error as? TorrentMetainfo.Failure else { return XCTFail("\(label): \(error)", file: file, line: line) }
                switch f {
                case .inconsistentHybrid, .invalid, .missingPieceLayer: break
                default: XCTFail("\(label): unexpected \(f)", file: file, line: line)
                }
            }
        }
        // different sizes, names, counts, order
        var sizes = files; sizes[1].data = V2Fx.content(70_001, seed: 11)
        expectRefused("size differs", Self.hybridWithTree(files, tree: V2Fx.v2Parts(sizes, pl: 32768).tree))
        var renamed = files; renamed[0].path = ["a2.bin"]
        expectRefused("name differs", Self.hybridWithTree(files, tree: V2Fx.v2Parts(renamed, pl: 32768).tree))
        expectRefused("fewer files in the tree", Self.hybridWithTree(files, tree: V2Fx.v2Parts(Array(files.dropLast()), pl: 32768).tree))
        let reordered = [files[2], files[0], files[1]]          // the version 1 list is not in the tree's order
        expectRefused("different order", V2Fx.torrent(info: V2Fx.v1Info(reordered, hybrid: true).info, layers: V2Fx.v2Parts(reordered, pl: 32768).layers).torrent)
        // no padding at all: files do not start on boundaries
        expectRefused("unaligned", build(V2Fx.v1Info(files, pads: false, hybrid: true)))
        // padding of the wrong size / name / place
        expectRefused("padding name", build(V2Fx.v1Info(files, hybrid: true, padName: { ["pad", String($0)] })))
        expectRefused("padding length in the name", build(V2Fx.v1Info(files, hybrid: true, padName: { [".pad", String($0 + 1)] })))
        expectRefused("trailing padding", build(V2Fx.v1Info(files, hybrid: true, trailingPad: true)))
        // a real file that takes a padding name
        let collide = [Spec(path: [".pad", "100"], data: V2Fx.content(100)), files[0], files[1]]
        expectRefused("padding-named file", build(V2Fx.v1Info(collide, hybrid: true), files: collide))
        // piece length that is not a power of two (a valid version 1 value)
        var odd = V2Fx.v1Info(files, pl: 49152, hybrid: true)
        odd.info["piece length"] = .int(49152)
        expectRefused("piece length", V2Fx.torrent(info: odd.info, layers: [:]).torrent)
        // meta version with no file tree; a layer that does not match
        var noTree = V2Fx.v1Info(files, hybrid: true).info; noTree["file tree"] = nil
        expectRefused("meta version without tree", V2Fx.torrent(info: noTree, layers: [:]).torrent)
        var layers = V2Fx.v2Parts(files, pl: 32768).layers
        let k = layers.keys.first!; var l = layers[k]!; l[3] ^= 1; layers[k] = l
        expectRefused("bad layer", V2Fx.torrent(info: V2Fx.v1Info(files, hybrid: true).info, layers: layers).torrent)
        expectRefused("missing layer", V2Fx.torrent(info: V2Fx.v1Info(files, hybrid: true).info, layers: [:]).torrent)
        // the unmerged control: the good one parses
        XCTAssertNoThrow(try TorrentMetainfo.parse(build(V2Fx.v1Info(files, hybrid: true))))
    }

    /// The same hybrid, with its `file tree` replaced.
    static func hybridWithTree(_ files: [V2Fx.Spec], tree: [String: Bencode]) -> Data {
        var v1 = V2Fx.v1Info(files, hybrid: true)
        v1.info["file tree"] = .dict(tree)
        return V2Fx.torrent(info: v1.info, layers: V2Fx.v2Parts(files, pl: 32768).layers).torrent
    }
}

// MARK: Padding in version 1, storage, verification

final class DX06StorageV2Tests: XCTestCase {
    typealias Spec = V2Fx.Spec

    func testVersion1PaddingIsRecognisedHiddenZeroFilledAndNeverWritten() throws {
        let files = [Spec(path: ["a.bin"], data: V2Fx.content(40_000)), Spec(path: ["b.bin"], data: V2Fx.content(50_000, seed: 3))]
        let v1 = V2Fx.v1Info(files, hybrid: false)
        let meta = try TorrentMetainfo.parse(V2Fx.torrent(info: v1.info, layers: [:]).torrent)
        XCTAssertEqual(meta.version, .v1)
        XCTAssertEqual(meta.files.map(\.isPadding), [false, true, false])
        XCTAssertTrue(meta.hasPadding)
        XCTAssertEqual(meta.contentLength, 90_000)
        let folder = V2Fx.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let work = TorrentStorage.workingFolder(for: UUID(), in: folder)
        // An old saved choice that included the padding entry (index 1) loads and the entry is ignored.
        let storage = TorrentStorage(meta: meta, workingFolder: work, selected: [0, 1, 2])
        XCTAssertEqual(storage.selected, [0, 2])
        XCTAssertEqual(storage.selectedBytes, 90_000, "padding is not part of the download size")
        XCTAssertEqual(storage.neededPieces, Array(0..<meta.pieceCount))
        XCTAssertEqual(TorrentStorage(meta: meta, workingFolder: work, selected: []).selected, [0, 2])
        try storage.prepare(freeSpace: { _ in Int64.max })
        for p in 0..<meta.pieceCount {
            let d = V2Fx.piece(v1.stream, meta, p)
            XCTAssertTrue(storage.matches(d, piece: p))
            try storage.write(piece: p, data: d)
        }
        // Nothing for the padding was created; reading a piece gives zeros where it was.
        let names = try FileManager.default.subpathsOfDirectory(atPath: storage.dataFolder.path)
        XCTAssertFalse(names.contains { $0.contains(".pad") }, "\(names)")
        XCTAssertEqual(try Data(contentsOf: storage.dataFolder.appendingPathComponent("a.bin")), files[0].data)
        XCTAssertEqual(try Data(contentsOf: storage.dataFolder.appendingPathComponent("b.bin")), files[1].data)
        for p in 0..<meta.pieceCount { XCTAssertEqual(storage.read(piece: p), V2Fx.piece(v1.stream, meta, p), "piece \(p)") }
        XCTAssertEqual(storage.read(piece: 1, begin: 7_300, length: 100), Data(count: 100), "inside the padding")
        XCTAssertEqual(storage.read(file: 1, offset: 100, length: 50), Data(count: 50), "a padding entry read as a file is zeros")
        XCTAssertEqual(storage.read(file: 2, offset: 10, length: 20), files[1].data.subdata(in: 10..<30))
        // A piece whose padding carries anything but zeros is refused even if its bytes were hashed that way.
        var dirty = V2Fx.piece(v1.stream, meta, 1)
        dirty[dirty.startIndex + 7_500] = 1
        XCTAssertFalse(storage.matches(dirty, piece: 1))
        // Finishing publishes only the real files.
        let done = try storage.finish(into: folder.appendingPathComponent("out"))
        let published = try FileManager.default.subpathsOfDirectory(atPath: done.path).sorted()
        XCTAssertEqual(published, ["a.bin", "b.bin"])
    }

    func testVersion1PaddingByNameAloneIsRecognisedAndRealFilesWithOtherNamesAreNot() throws {
        let t = try TorrentFixture.build(files: [(["a"], 40_000), ([".pad", "25536"], 25_536), (["b"], 100), ([".pad", "5"], 7)])
        XCTAssertEqual(t.meta.files.map(\.isPadding), [false, true, false, false], "'.pad/5' of length 7 is spelled like padding only when its number is its length")
    }

    func testVersion2OnlyStorageChecksPiecesAgainstTheMerkleLayersAndNeverWritesTheGaps() throws {
        let files = [Spec(path: ["a.bin"], data: V2Fx.content(100_000)), Spec(path: ["d", "b.bin"], data: V2Fx.content(20_000, seed: 8)), Spec(path: ["e.bin"], data: V2Fx.content(32_768, seed: 21))]
        let (info, layers) = V2Fx.v2Info(files)
        let meta = try TorrentMetainfo.parse(V2Fx.torrent(info: info, layers: layers).torrent)
        let stream = V2Fx.stream(meta, files)
        let folder = V2Fx.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let storage = TorrentStorage(meta: meta, workingFolder: TorrentStorage.workingFolder(for: UUID(), in: folder), selected: [])
        XCTAssertEqual(storage.selected, Set(meta.visibleFiles.map(\.index)))
        XCTAssertEqual(storage.selectedBytes, 152_768)
        XCTAssertEqual(meta.pieceCount, 4 + 1 + 1)
        try storage.prepare(freeSpace: { _ in Int64.max })
        for p in 0..<meta.pieceCount {
            let d = V2Fx.piece(stream, meta, p)
            XCTAssertTrue(storage.matches(d, piece: p), "piece \(p)")
            var bad = d; bad[bad.startIndex + d.count / 2] ^= 1
            XCTAssertFalse(storage.matches(bad, piece: p), "tampered piece \(p)")
            XCTAssertFalse(storage.matches(d.dropLast(), piece: p), "short piece \(p)")
            XCTAssertFalse(storage.matches(d + Data([0]), piece: p), "long piece \(p)")
            XCTAssertFalse(storage.matches(V2Fx.piece(stream, meta, (p + 1) % meta.pieceCount), piece: p), "another piece's bytes in piece \(p)")
            try storage.write(piece: p, data: d)
        }
        XCTAssertEqual(try Data(contentsOf: storage.dataFolder.appendingPathComponent("a.bin")), files[0].data)
        XCTAssertEqual(try Data(contentsOf: storage.dataFolder.appendingPathComponent("d/b.bin")), files[1].data)
        XCTAssertFalse(try FileManager.default.subpathsOfDirectory(atPath: storage.dataFolder.path).contains { $0.contains(".pad") })
        XCTAssertEqual(storage.read(file: 2, offset: 0, length: 20_000), files[1].data)
        for p in 0..<meta.pieceCount { XCTAssertEqual(storage.read(piece: p), V2Fx.piece(stream, meta, p)) }
        // The whole-file check, streaming.
        let root = meta.files[0].pieceRoot!
        XCTAssertTrue(try TorrentStorage.verifyFile(url: storage.dataFolder.appendingPathComponent("a.bin"), expectedRoot: root, pieceLength: 32768))
        XCTAssertTrue(try TorrentStorage.verifyFile(url: storage.dataFolder.appendingPathComponent("d/b.bin"), expectedRoot: meta.files[2].pieceRoot!, pieceLength: 32768))
        XCTAssertFalse(try TorrentStorage.verifyFile(url: storage.dataFolder.appendingPathComponent("a.bin"), expectedRoot: meta.files[2].pieceRoot!, pieceLength: 32768))
        XCTAssertThrowsError(try TorrentStorage.verifyFile(url: storage.dataFolder.appendingPathComponent("a.bin"), expectedRoot: root, pieceLength: 32768, isCancelled: { true })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertThrowsError(try TorrentStorage.verifyFile(url: storage.dataFolder.appendingPathComponent("missing"), expectedRoot: root, pieceLength: 32768))
        XCTAssertFalse(try TorrentStorage.verifyFile(url: storage.dataFolder.appendingPathComponent("a.bin"), expectedRoot: Data(count: 32), pieceLength: 32768))
        XCTAssertFalse(try TorrentStorage.verifyFile(url: storage.dataFolder.appendingPathComponent("a.bin"), expectedRoot: root, pieceLength: 1000), "an invalid piece length")
    }

    func testVerifyFileMatchesTheIndependentVectorsAtEveryBoundarySize() throws {
        let folder = V2Fx.tempFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let vectors: [(Int, String)] = [(1, "6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d"), (16384, "5252abae92836caa122f8d6c078aa2487dc32b17e1b204a7cc022809faebc192"),
                                        (16385, "831c51b911745d225c3ef7ddaaeb0971d93962202f8bd82789db755f86fb5a49"), (32768, "52be10908528d4e56eca06f83e2ec15e48ea3f97f7ce4ee463615c00143dd0fa"),
                                        (32769, "d4284bbf94fc69446f2b4cc76aea8a8256929e425b0a39bde22cb546167a5737"), (100_000, "a61f2da045dde32ea6426a18b0d05e483d7686473b1dacbd9cc24e56caa4770d"),
                                        (131_072, "03773bf22d46d4491005bf5d2a2b4fe0b4ab1ce4d617c30dc1b07c5bc5aece83"), (200_000, "3966669c522f4002cd6b8e010ff5fe8b333b20d18532a542ec8551ae8fd1eba2")]
        for (n, rootHex) in vectors {
            let url = folder.appendingPathComponent("f\(n)")
            try V2Fx.content(n).write(to: url)
            let root = Data(stride(from: 0, to: rootHex.count, by: 2).map { UInt8(rootHex[rootHex.index(rootHex.startIndex, offsetBy: $0)...rootHex.index(rootHex.startIndex, offsetBy: $0 + 1)], radix: 16)! })
            XCTAssertTrue(try TorrentStorage.verifyFile(url: url, expectedRoot: root, pieceLength: 32768), "\(n) bytes")
        }
        let empty = folder.appendingPathComponent("empty"); try Data().write(to: empty)
        XCTAssertFalse(try TorrentStorage.verifyFile(url: empty, expectedRoot: Data(count: 32), pieceLength: 32768), "an empty file has no root")
    }

    func testAV2TorrentFromAMagnetNeedsItsLayersBeforeLongFilesCanBeChecked() throws {
        let files = [Spec(path: ["big.bin"], data: V2Fx.content(100_000)), Spec(path: ["small.bin"], data: V2Fx.content(500, seed: 2))]
        let (info, layers) = V2Fx.v2Info(files)
        let t = V2Fx.torrent(info: info, layers: layers)
        let meta = try TorrentMetainfo.parse(infoSection: t.info)
        XCTAssertEqual(meta.missingLayerRoots.count, 1)
        let stream = V2Fx.stream(meta, files)
        let storage = TorrentStorage(meta: meta, workingFolder: V2Fx.tempFolder(), selected: [])
        XCTAssertEqual(storage.missingLayerRoots, meta.missingLayerRoots)
        XCTAssertFalse(storage.matches(V2Fx.piece(stream, meta, 0), piece: 0), "without the layer a version 2 piece cannot be accepted")
        XCTAssertTrue(storage.matches(V2Fx.piece(stream, meta, 4), piece: 4), "a file of one piece needs no layer")
        let root = meta.missingLayerRoots[0]
        XCTAssertFalse(storage.install(pieceLayer: layers[root]!.dropLast(32), forRoot: root))
        var bad = layers[root]!; bad[2] ^= 1
        XCTAssertFalse(storage.install(pieceLayer: bad, forRoot: root))
        XCTAssertFalse(storage.install(pieceLayer: layers[root]!, forRoot: Data(count: 32)))
        XCTAssertFalse(storage.matches(V2Fx.piece(stream, meta, 0), piece: 0))
        XCTAssertTrue(storage.install(pieceLayer: layers[root]!, forRoot: root))
        XCTAssertTrue(storage.missingLayerRoots.isEmpty)
        for p in 0..<meta.pieceCount { XCTAssertTrue(storage.matches(V2Fx.piece(stream, meta, p), piece: p), "piece \(p)") }
        var tampered = V2Fx.piece(stream, meta, 1); tampered[tampered.startIndex] ^= 1
        XCTAssertFalse(storage.matches(tampered, piece: 1))
    }
}

// MARK: Magnet links

final class DX06MagnetV2Tests: XCTestCase {
    let h2 = String(repeating: "ab", count: 32)
    let h1 = "0123456789abcdef0123456789abcdef01234567"

    func testABtmhOnlyLinkNamesTheTorrentByItsTruncatedHash() throws {
        let m = try MagnetLink.parse("magnet:?xt=urn:btmh:1220\(h2)&dn=Name&tr=http%3A%2F%2Ft.example%2Fa")
        XCTAssertEqual(m.infoHashV2, Data(repeating: 0xab, count: 32))
        XCTAssertEqual(m.infoHash, Data(repeating: 0xab, count: 20))
        XCTAssertTrue(m.isV2Only)
        XCTAssertEqual(m.infoHashV2Hex, h2)
        XCTAssertEqual(m.displayName, "Name"); XCTAssertEqual(m.trackers.count, 1)
        XCTAssertEqual(try MagnetLink.parse("magnet:?xt=urn:btmh:1220\(h2.uppercased())").infoHashV2, m.infoHashV2, "case does not matter")
    }

    func testACombinedLinkKeepsBothHashes() throws {
        let m = try MagnetLink.parse("magnet:?xt=urn:btih:\(h1)&xt=urn:btmh:1220\(h2)")
        XCTAssertEqual(m.infoHashHex, h1); XCTAssertEqual(m.infoHashV2Hex, h2); XCTAssertFalse(m.isV2Only)
        XCTAssertNil(try MagnetLink.parse("magnet:?xt=urn:btih:\(h1)").infoHashV2)
        XCTAssertFalse(try MagnetLink.parse("magnet:?xt=urn:btih:\(h1)").isV2Only)
    }

    func testOtherHashTypesAndBrokenIdentifiersAreRefusedClearly() {
        XCTAssertThrowsError(try MagnetLink.parse("magnet:?xt=urn:btmh:1114\(String(repeating: "a", count: 40))")) { XCTAssertEqual($0 as? MagnetLink.Failure, .unsupportedHashType) }
        XCTAssertNotNil(MagnetLink.problem("magnet:?xt=urn:btmh:1114\(String(repeating: "a", count: 40))"))
        for bad in ["1220", "1220" + String(repeating: "a", count: 63), "1220" + String(repeating: "a", count: 66), "1220" + String(repeating: "g", count: 64), "", "zz"] {
            XCTAssertThrowsError(try MagnetLink.parse("magnet:?xt=urn:btmh:\(bad)&dn=x"), bad) { XCTAssertEqual($0 as? MagnetLink.Failure, .badHash, bad) }
        }
        XCTAssertThrowsError(try MagnetLink.parse("magnet:?xt=urn:btmh:1220\(h2)&xt=urn:btmh:1220\(String(repeating: "cd", count: 32))")) { XCTAssertEqual($0 as? MagnetLink.Failure, .badHash) }
        XCTAssertThrowsError(try MagnetLink.parse("magnet:?dn=x")) { XCTAssertEqual($0 as? MagnetLink.Failure, .missingHash) }
    }

    func testFetchedMetadataIsCheckedAgainstWhicheverHashTheLinkHad() throws {
        let (info, layers) = V2Fx.v2Info([V2Fx.Spec(path: ["f"], data: V2Fx.content(100))])
        let t = V2Fx.torrent(info: info, layers: layers)
        let full = Data(SHA256.hash(data: t.info))
        XCTAssertTrue(TorrentMetainfo.infoMatches(t.info, session: full.prefix(20), v2: full))
        XCTAssertTrue(TorrentMetainfo.infoMatches(t.info, session: full.prefix(20), v2: nil))
        XCTAssertFalse(TorrentMetainfo.infoMatches(t.info, session: full.prefix(20), v2: Data(count: 32)))
        XCTAssertFalse(TorrentMetainfo.infoMatches(t.info, session: Data(count: 20), v2: nil))
        XCTAssertTrue(TorrentMetainfo.infoMatches(t.info, session: Data(Insecure.SHA1.hash(data: t.info)), v2: nil), "a hybrid link's v1 hash")
        var other = t.info; other[other.startIndex + 10] ^= 1
        XCTAssertFalse(TorrentMetainfo.infoMatches(other, session: full.prefix(20), v2: full))
    }
}

// MARK: Wire codec and proofs

final class DX06HashMessageTests: XCTestCase {
    let root = Data((0..<32).map { UInt8($0) })

    private func parts(_ data: Data) throws -> [PeerWire.Parser.Item] {
        var p = PeerWire.Parser(pieceCount: 100)
        return try p.feedAll(data)
    }

    func testRoundTripOfAllThreeMessagesWithBigEndianFields() throws {
        let req = PeerWire.HashMessage(kind: .request, piecesRoot: root, baseLayer: 3, index: 8, length: 4, proofLayers: 5)
        let enc = PeerWire.encodeHash(req)
        XCTAssertEqual(Array(enc.prefix(5)), [0, 0, 0, 49, 21])
        XCTAssertEqual(Array(enc.dropFirst(5 + 32)), [0, 0, 0, 3, 0, 0, 0, 8, 0, 0, 0, 4, 0, 0, 0, 5])
        XCTAssertEqual(enc, PeerWire.hashRequest(piecesRoot: root, baseLayer: 3, index: 8, length: 4, proofLayers: 5))
        let hashes = (0..<6).map { Data(repeating: UInt8($0), count: 32) }
        let rep = PeerWire.HashMessage(kind: .hashes, piecesRoot: root, baseLayer: 3, index: 8, length: 4, proofLayers: 5, hashes: hashes)
        let rej = PeerWire.HashMessage(kind: .reject, piecesRoot: root, baseLayer: 3, index: 8, length: 4, proofLayers: 5)
        let items = try parts(PeerWire.encodeHash(req) + PeerWire.encodeHash(rep) + PeerWire.encode(.have(7)) + PeerWire.encodeHash(rej))
        XCTAssertEqual(items, [.hash(req), .hash(rep), .message(.have(7)), .hash(rej)])
        // The old entry point still parses the stream and reports the new ids as unknown.
        var legacy = PeerWire.Parser(pieceCount: 100)
        XCTAssertEqual(try legacy.feed(PeerWire.encodeHash(req) + PeerWire.encode(.haveAll)), [.unknown(21), .haveAll])
        // A message split in pieces is held until whole.
        var split = PeerWire.Parser(pieceCount: 100)
        let bytes = PeerWire.encodeHash(rep)
        XCTAssertTrue(try split.feedAll(bytes.prefix(30)).isEmpty)
        XCTAssertEqual(try split.feedAll(bytes.dropFirst(30)), [.hash(rep)])
    }

    func testBadHashMessagesAreRefusedBeforeAnythingIsKept() throws {
        func frame(_ id: UInt8, base: Int = 0, index: Int = 0, length: Int = 2, proofs: Int = 0, hashes: Int = 0, rootSize: Int = 32, extra: Int = 0) -> Data {
            func u32(_ v: Int) -> [UInt8] { withUnsafeBytes(of: UInt32(truncatingIfNeeded: v).bigEndian, Array.init) }
            let body: [UInt8] = [id] + [UInt8](repeating: 1, count: rootSize) + u32(base) + u32(index) + u32(length) + u32(proofs) + [UInt8](repeating: 2, count: hashes * 32 + extra)
            return Data(u32(body.count) + body)
        }
        XCTAssertNoThrow(try parts(frame(21)))
        XCTAssertNoThrow(try parts(frame(22, hashes: 2)))
        XCTAssertNoThrow(try parts(frame(22, index: 512, length: 512, hashes: 512)))
        XCTAssertNoThrow(try parts(frame(22, length: 2, hashes: 2 + 64)))
        XCTAssertThrowsError(try parts(frame(21, length: 1)), "length below two")
        XCTAssertThrowsError(try parts(frame(21, length: 0)))
        XCTAssertThrowsError(try parts(frame(21, length: 3)), "not a power of two")
        XCTAssertThrowsError(try parts(frame(21, length: 1024)), "above 512")
        XCTAssertThrowsError(try parts(frame(21, index: 6, length: 4)), "index not a multiple of length")
        XCTAssertThrowsError(try parts(frame(21, proofs: 65)))
        XCTAssertThrowsError(try parts(frame(21, base: 64)))
        XCTAssertThrowsError(try parts(frame(21, rootSize: 31)), "short root")
        XCTAssertThrowsError(try parts(frame(21, extra: 1)), "a request has no tail")
        XCTAssertThrowsError(try parts(frame(23, extra: 32)), "a reject has no tail")
        XCTAssertThrowsError(try parts(frame(22, hashes: 1)), "fewer than `length` hashes")
        XCTAssertThrowsError(try parts(frame(22, hashes: 2, extra: 5)), "a partial hash")
        XCTAssertThrowsError(try parts(frame(22, length: 2, hashes: 2 + 65)), "too many hashes")
        XCTAssertThrowsError(try parts(Data([0, 0, 0, 5, 21, 0, 0, 0, 0])), "short")
        // a huge announced size is refused before the payload is read
        var p = PeerWire.Parser(pieceCount: 100)
        XCTAssertThrowsError(try p.feedAll(Data([0, 2, 0, 0, 22])))
    }
}

final class DX06HashProofTests: XCTestCase {
    typealias Spec = V2Fx.Spec
    let pl: Int64 = 32768
    let length = 200_000          // 7 pieces of 2 blocks each: piece layer is layer 1, the tree is 4 layers high

    /// The nodes of the piece layer, padded to a power of two the way a file root is made.
    private func layerNodes(_ data: Data) -> [Data] {
        let roots = Merkle.pieceRoots(leaves: Merkle.leafHashes(of: data), pieceLength: pl)!
        let pad = Merkle.padPieceHash(blocksPerPiece: 2)!
        return roots + [Data](repeating: pad, count: Merkle.nextPowerOfTwo(roots.count) - roots.count)
    }

    func testHeightsAndRequestsForAFile() throws {
        XCTAssertEqual(HashProof.treeHeight(fileLength: Int64(length), pieceLength: pl), 4)
        XCTAssertEqual(HashProof.treeHeight(fileLength: 1, pieceLength: pl), 0)
        XCTAssertEqual(HashProof.treeHeight(fileLength: 16385, pieceLength: pl), 1)
        XCTAssertEqual(HashProof.treeHeight(fileLength: 32768, pieceLength: pl), 1)
        XCTAssertEqual(HashProof.pieceLayerNumber(pieceLength: pl), 1)
        let data = V2Fx.content(length)
        let root = V2Fx.root(of: data, pl: pl)!
        let reqs = HashProof.requestsForPieceLayer(piecesRoot: root, fileLength: Int64(length), pieceLength: pl)
        XCTAssertEqual(reqs.count, 1)
        XCTAssertEqual([reqs[0].baseLayer, reqs[0].index, reqs[0].length, reqs[0].proofLayers], [1, 0, 8, 2])
        XCTAssertTrue(HashProof.requestsForPieceLayer(piecesRoot: root, fileLength: 100, pieceLength: pl).isEmpty, "a file of one piece has no layer to fetch")
        // A big file asks in runs of 512.
        let big = HashProof.requestsForPieceLayer(piecesRoot: root, fileLength: 2000 * pl, pieceLength: pl)
        XCTAssertEqual(big.map(\.index), [0, 512, 1024, 1536])
        XCTAssertTrue(big.allSatisfy { $0.length == 512 && Merkle.isPowerOfTwo($0.length) })
    }

    func testAWholeLayerReplyIsVerifiedAgainstTheRootAndBecomesTheLayer() throws {
        let data = V2Fx.content(length)
        let root = V2Fx.root(of: data, pl: pl)!
        let nodes = layerNodes(data)
        let req = HashProof.requestsForPieceLayer(piecesRoot: root, fileLength: Int64(length), pieceLength: pl)[0]
        var reply = PeerWire.HashMessage(kind: .hashes, piecesRoot: root, baseLayer: req.baseLayer, index: req.index, length: req.length, proofLayers: req.proofLayers, hashes: nodes)
        let verified = HashProof.verify(reply, piecesRoot: root, fileLength: Int64(length), pieceLength: pl)
        XCTAssertEqual(verified, nodes)
        let layer = HashProof.assemblePieceLayer(runs: [0: verified!], piecesRoot: root, fileLength: Int64(length), pieceLength: pl)
        let expected = Merkle.pieceRoots(leaves: Merkle.leafHashes(of: data), pieceLength: pl)!.reduce(Data(), +)
        XCTAssertEqual(layer, expected, "only the real piece roots, never the padding")
        // Any change is caught.
        var tampered = reply; tampered.hashes[3][0] ^= 1
        XCTAssertNil(HashProof.verify(tampered, piecesRoot: root, fileLength: Int64(length), pieceLength: pl))
        XCTAssertNil(HashProof.verify(reply, piecesRoot: Data(count: 32), fileLength: Int64(length), pieceLength: pl), "someone else's root")
        reply.piecesRoot = Data(count: 32)
        XCTAssertNil(HashProof.verify(reply, piecesRoot: root, fileLength: Int64(length), pieceLength: pl), "the reply names another root")
        XCTAssertNil(HashProof.assemblePieceLayer(runs: [0: Array(nodes.prefix(5))], piecesRoot: root, fileLength: Int64(length), pieceLength: pl), "an incomplete layer")
    }

    func testAPartialReplyNeedsTheUncleHashesAndTheyAreOrderedFromTheBaseUp() throws {
        let data = V2Fx.content(length)
        let root = V2Fx.root(of: data, pl: pl)!
        let nodes = layerNodes(data)
        // The right half of the piece layer (4 nodes at index 4): one uncle, the root of the left half.
        let uncle = Merkle.root(of: Array(nodes[0..<4]))!
        let good = PeerWire.HashMessage(kind: .hashes, piecesRoot: root, baseLayer: 1, index: 4, length: 4, proofLayers: 2, hashes: Array(nodes[4..<8]) + [uncle])
        XCTAssertEqual(HashProof.verify(good, piecesRoot: root, fileLength: Int64(length), pieceLength: pl), Array(nodes[4..<8]))
        // The left half has the right half's root as its uncle.
        let rightRoot = Merkle.root(of: Array(nodes[4..<8]))!
        let left = PeerWire.HashMessage(kind: .hashes, piecesRoot: root, baseLayer: 1, index: 0, length: 4, proofLayers: 2, hashes: Array(nodes[0..<4]) + [rightRoot])
        XCTAssertEqual(HashProof.verify(left, piecesRoot: root, fileLength: Int64(length), pieceLength: pl), Array(nodes[0..<4]))
        // A quarter (2 nodes at index 2) needs two uncles: its sibling pair's root, then the other half's root.
        let sib = Merkle.root(of: Array(nodes[0..<2]))!
        let quarter = PeerWire.HashMessage(kind: .hashes, piecesRoot: root, baseLayer: 1, index: 2, length: 2, proofLayers: 2, hashes: Array(nodes[2..<4]) + [sib, rightRoot])
        XCTAssertEqual(HashProof.verify(quarter, piecesRoot: root, fileLength: Int64(length), pieceLength: pl), Array(nodes[2..<4]))
        var swapped = quarter; swapped.hashes.swapAt(2, 3)
        XCTAssertNil(HashProof.verify(swapped, piecesRoot: root, fileLength: Int64(length), pieceLength: pl), "uncles out of order")
        // Missing, extra, wrong or misplaced proofs
        var noUncle = good; noUncle.hashes.removeLast()
        XCTAssertNil(HashProof.verify(noUncle, piecesRoot: root, fileLength: Int64(length), pieceLength: pl))
        var extra = good; extra.hashes.append(uncle)
        XCTAssertNil(HashProof.verify(extra, piecesRoot: root, fileLength: Int64(length), pieceLength: pl))
        var wrongUncle = good; wrongUncle.hashes[4][1] ^= 1
        XCTAssertNil(HashProof.verify(wrongUncle, piecesRoot: root, fileLength: Int64(length), pieceLength: pl))
        var moved = good; moved.index = 0
        XCTAssertNil(HashProof.verify(moved, piecesRoot: root, fileLength: Int64(length), pieceLength: pl), "the hashes claim a different place")
        var outside = good; outside.index = 8
        XCTAssertNil(HashProof.verify(outside, piecesRoot: root, fileLength: Int64(length), pieceLength: pl), "beyond the layer")
        var request = good; request.kind = .request
        XCTAssertNil(HashProof.verify(request, piecesRoot: root, fileLength: Int64(length), pieceLength: pl))
        var tooHigh = good; tooHigh.baseLayer = 4
        XCTAssertNil(HashProof.verify(tooHigh, piecesRoot: root, fileLength: Int64(length), pieceLength: pl))
        // Assembling two runs out of order or with a gap fails; in order it succeeds.
        let all = layerNodes(data)
        let expected = Merkle.pieceRoots(leaves: Merkle.leafHashes(of: data), pieceLength: pl)!.reduce(Data(), +)
        XCTAssertEqual(HashProof.assemblePieceLayer(runs: [0: Array(all[0..<4]), 4: Array(all[4..<8])], piecesRoot: root, fileLength: Int64(length), pieceLength: pl), expected)
        XCTAssertNil(HashProof.assemblePieceLayer(runs: [4: Array(all[4..<8])], piecesRoot: root, fileLength: Int64(length), pieceLength: pl))
    }

    func testProofsFromTheLeafLayerOfASmallFile() throws {
        // A 3-block file (one piece at 64 KiB): the tree is 2 layers high; four leaves (the fourth is the zero hash).
        let plBig: Int64 = 65536
        let data = V2Fx.content(3 * 16384 - 5)
        let leaves = Merkle.leafHashes(of: data)
        let padded = leaves + [Merkle.zeroHash]
        let root = V2Fx.root(of: data, pl: plBig)!
        let whole = PeerWire.HashMessage(kind: .hashes, piecesRoot: root, baseLayer: 0, index: 0, length: 4, proofLayers: 1, hashes: padded)
        XCTAssertEqual(HashProof.verify(whole, piecesRoot: root, fileLength: Int64(data.count), pieceLength: plBig), padded)
        let half = PeerWire.HashMessage(kind: .hashes, piecesRoot: root, baseLayer: 0, index: 2, length: 2, proofLayers: 1, hashes: Array(padded[2..<4]) + [Merkle.sha256(padded[0], padded[1])])
        XCTAssertEqual(HashProof.verify(half, piecesRoot: root, fileLength: Int64(data.count), pieceLength: plBig), Array(padded[2..<4]))
    }
}
