import CryptoKit
import XCTest
@testable import Browser_Setu

/// Builds torrents from content held in memory (no files, no network).
enum TorrentFixture {
    /// Deterministic content: byte i of a stream is (i * 7 + 3) % 253.
    static func content(_ n: Int, from start: Int = 0) -> Data { Data((start..<(start + n)).map { UInt8(($0 * 7 + 3) % 253) }) }

    struct Built { var torrent: Data; var info: Data; var stream: Data; var meta: TorrentMetainfo }

    static func b(_ s: String) -> Bencode { .bytes(Data(s.utf8)) }

    /// `files`: (path components, length). One entry with a single component and `multi: false` makes a single-file torrent.
    static func build(name: String = "sample", files: [([String], Int)], pieceLength: Int = 32768, multi: Bool = true, isPrivate: Bool = false,
                      announce: [String] = [], extra: [String: Bencode] = [:], infoExtra: [String: Bencode] = [:]) throws -> Built {
        let total = files.reduce(0) { $0 + $1.1 }
        let stream = content(max(0, total))          // a negative length is written into the entry as given, to test that it is refused
        var hashes = Data()
        var offset = 0
        while offset < total { let n = min(pieceLength, total - offset); hashes.append(Data(Insecure.SHA1.hash(data: stream.subdata(in: offset..<(offset + n))))); offset += n }
        var info: [String: Bencode] = ["name": b(name), "piece length": .int(Int64(pieceLength)), "pieces": .bytes(hashes)]
        if multi { info["files"] = .list(files.map { .dict(["length": .int(Int64($0.1)), "path": .list($0.0.map(b))]) }) } else { info["length"] = .int(Int64(total)) }
        if isPrivate { info["private"] = .int(1) }
        for (k, v) in infoExtra { info[k] = v }
        var root: [String: Bencode] = ["info": .dict(info)]
        if let first = announce.first { root["announce"] = b(first); root["announce-list"] = .list(announce.map { .list([b($0)]) }) }
        for (k, v) in extra { root[k] = v }
        let torrent = BencodeDecoder.encode(.dict(root))
        let infoBytes = BencodeDecoder.encode(.dict(info))
        return Built(torrent: torrent, info: infoBytes, stream: stream, meta: try TorrentMetainfo.parse(torrent))
    }
}

final class BencodeTests: XCTestCase {
    func d(_ s: String) -> Data { Data(s.utf8) }

    func testDecodesAllKinds() throws {
        let v = try BencodeDecoder.decode(d("d3:bar4:spam3:fooi42e1:ai-7e1:lli1e3:abcee")).value.dict
        XCTAssertEqual(v?["foo"]?.int, 42); XCTAssertEqual(v?["bar"]?.string, "spam"); XCTAssertEqual(v?["a"]?.int, -7)
        XCTAssertEqual(v?["l"]?.list?.count, 2)
    }

    func testRefusesWhatIsNotStrict() {
        for bad in ["i03e", "i-0e", "ie", "i1", "5:abc", "03:abc", "l", "d3:fooi1e3:fooi2ee", "x", "", "i1ei2e", "d3:fooi1ee3:bar", "d1:a", "99999999999:x", "i99999999999999999999e"] {
            XCTAssertThrowsError(try BencodeDecoder.decode(d(bad)), bad)
        }
    }

    func testNestingAndSizeAreBounded() {
        XCTAssertThrowsError(try BencodeDecoder.decode(d(String(repeating: "l", count: 100) + String(repeating: "e", count: 100)))) { XCTAssertEqual($0 as? BencodeDecoder.Failure, .tooDeep) }
        XCTAssertThrowsError(try BencodeDecoder.decode(d("l" + String(repeating: "i1e", count: 5000) + "e"), limits: .message)) { XCTAssertEqual($0 as? BencodeDecoder.Failure, .tooManyValues) }
        XCTAssertThrowsError(try BencodeDecoder.decode(Data(count: 3 * 1024 * 1024), limits: .message)) { XCTAssertEqual($0 as? BencodeDecoder.Failure, .tooLarge) }
    }

    func testAStringCannotClaimMoreThanTheData() {
        XCTAssertThrowsError(try BencodeDecoder.decode(d("1000000:abc")))
    }

    func testRawBytesOfAKeyAreKeptAsWritten() throws {
        let text = "d4:infod1:bi2e1:ai1ee3:zzzi0ee"            // keys deliberately out of order inside info
        let r = try BencodeDecoder.decode(d(text), rawKeys: ["info"])
        XCTAssertEqual(String(data: d(text).subdata(in: r.rawRanges["info"]!), encoding: .utf8), "d1:bi2e1:ai1ee")
    }

    func testEncodeRoundTrips() throws {
        let v: Bencode = .dict(["b": .list([.int(1), .bytes(d("x"))]), "a": .int(-3)])
        XCTAssertEqual(try BencodeDecoder.decode(BencodeDecoder.encode(v)).value, v)
        XCTAssertEqual(String(data: BencodeDecoder.encode(v), encoding: .utf8), "d1:ai-3e1:bli1e1:xee")
    }
}

final class TorrentMetainfoTests: XCTestCase {
    func testSingleFile() throws {
        let t = try TorrentFixture.build(name: "one.bin", files: [(["one.bin"], 100_000)], multi: false)
        XCTAssertEqual(t.meta.name, "one.bin"); XCTAssertFalse(t.meta.isMultiFile); XCTAssertEqual(t.meta.totalLength, 100_000)
        XCTAssertEqual(t.meta.pieceCount, 4); XCTAssertEqual(t.meta.length(ofPiece: 3), 100_000 - 3 * 32768)
        XCTAssertEqual(t.meta.infoHash.count, 20)
    }

    func testMultiFileOffsetsAndSegments() throws {
        let t = try TorrentFixture.build(files: [(["a.txt"], 10_000), (["d", "empty"], 0), (["d", "b.bin"], 50_000), (["c.bin"], 3)])
        XCTAssertEqual(t.meta.files.map(\.offset), [0, 10_000, 10_000, 60_000])
        // piece 0 covers bytes 0..<32768: all of a.txt and the first 22768 bytes of b.bin
        let seg = t.meta.segments(offset: 0, length: 32768)
        XCTAssertEqual(seg.map { $0.file }, [0, 2]); XCTAssertEqual(seg.map { $0.count }, [10_000, 22_768])
        // the last piece spans b.bin's end and c.bin
        let last = t.meta.segments(offset: Int64(t.meta.pieceCount - 1) * 32768, length: t.meta.length(ofPiece: t.meta.pieceCount - 1))
        XCTAssertEqual(last.last?.file, 3)
        XCTAssertEqual(last.reduce(0) { $0 + $1.count }, t.meta.length(ofPiece: t.meta.pieceCount - 1))
        XCTAssertTrue(t.meta.segments(offset: 0, length: t.meta.totalLength + 1).isEmpty, "a range past the end is nothing")
    }

    func testTheInfoHashIsOfTheOriginalBytesWhateverTheKeyOrder() throws {
        // info written with keys out of order (as some real torrents are): the hash must be of those bytes, not of a re-encoding
        let pieces = Data(Insecure.SHA1.hash(data: TorrentFixture.content(1000)))
        var info = Data("d4:name1:n6:lengthi1000e12:piece lengthi16384e6:pieces20:".utf8); info.append(pieces); info.append(Data("e".utf8))
        let ordered = BencodeDecoder.encode(try BencodeDecoder.decode(info).value)
        XCTAssertNotEqual(info, ordered, "the fixture really is out of order")
        var torrent = Data("d4:info".utf8); torrent.append(info); torrent.append(Data("e".utf8))
        let meta = try TorrentMetainfo.parse(torrent)
        XCTAssertEqual(meta.infoHash, Data(Insecure.SHA1.hash(data: info)))
        XCTAssertEqual(try TorrentMetainfo.parse(infoSection: info).infoHash, meta.infoHash, "magnet metadata is hashed the same way")
    }

    func testUnsafePathsAreRefused() {
        let bad: [[String]] = [[".."], ["a", ".."], ["."], ["a/b"], ["a\\b"], [""], ["/etc/passwd"], ["a:b"], ["ok", "x\u{0}y"], ["x\u{202E}fdp.exe"], [String(repeating: "a", count: 300)], []]
        for path in bad {
            XCTAssertThrowsError(try TorrentFixture.build(files: [(path, 10), (["fine"], 10)])) { error in
                if case TorrentMetainfo.Failure.unsafePath = error { return }
                if case TorrentMetainfo.Failure.invalid = error, path.isEmpty { return }
                XCTFail("\(path) -> \(error)")
            }
        }
        XCTAssertThrowsError(try TorrentFixture.build(name: "../escape", files: [(["a"], 10)], multi: true))
        XCTAssertThrowsError(try TorrentFixture.build(name: "a/b", files: [(["a"], 10)], multi: false))
    }

    func testNamesThatCollideAreRefused() {
        XCTAssertThrowsError(try TorrentFixture.build(files: [(["A.txt"], 5), (["a.TXT"], 5)]), "same file on a case-insensitive disk")
        XCTAssertThrowsError(try TorrentFixture.build(files: [(["x"], 5), (["x", "y"], 5)]), "a file that is also a folder")
        XCTAssertThrowsError(try TorrentFixture.build(files: [(["é"], 5), (["e\u{301}"], 5)]), "the same name written two ways")
    }

    func testInconsistentSizesAreRefused() throws {
        let t = try TorrentFixture.build(files: [(["a"], 40_000)])
        var broken = t.torrent
        // truncate the piece list by one hash by rebuilding with the wrong length
        XCTAssertThrowsError(try TorrentFixture.build(files: [(["a"], 40_000)], infoExtra: ["pieces": .bytes(Data(count: 20))]))
        XCTAssertThrowsError(try TorrentFixture.build(files: [(["a"], 40_000)], infoExtra: ["pieces": .bytes(Data(count: 30))]))
        XCTAssertThrowsError(try TorrentFixture.build(files: [(["a"], 40_000)], infoExtra: ["piece length": .int(1000)]))
        XCTAssertThrowsError(try TorrentFixture.build(files: [(["a"], 40_000)], infoExtra: ["piece length": .int(20_000)]), "not a multiple of 16 KiB")
        XCTAssertThrowsError(try TorrentFixture.build(files: [(["a"], 0)]), "empty")
        broken.removeLast()
        XCTAssertThrowsError(try TorrentMetainfo.parse(broken))
        XCTAssertThrowsError(try TorrentMetainfo.parse(Data("hello".utf8)))
        XCTAssertThrowsError(try TorrentMetainfo.parse(Data()))
    }

    func testNegativeAndOverflowingLengthsAreRefused() {
        XCTAssertThrowsError(try TorrentFixture.build(files: [(["a"], -5)]))
        let huge = Int64.max / 2
        let info: [String: Bencode] = ["name": TorrentFixture.b("n"), "piece length": .int(16384), "pieces": .bytes(Data(count: 20)),
                                       "files": .list([.dict(["length": .int(huge), "path": .list([TorrentFixture.b("a")])]), .dict(["length": .int(huge), "path": .list([TorrentFixture.b("b")])])])]
        XCTAssertThrowsError(try TorrentMetainfo.parse(BencodeDecoder.encode(.dict(["info": .dict(info)]))))
    }

    func testTooManyFilesIsRefused() {
        let files = (0...TorrentMetainfo.Limit.maxFiles).map { (["f\($0)"], 1) }
        XCTAssertThrowsError(try TorrentFixture.build(files: files, pieceLength: 16384)) { XCTAssertEqual($0 as? TorrentMetainfo.Failure, .tooMany("files")) }
    }

    func testVersion2OnlyIsSaidPlainly() {
        let info: [String: Bencode] = ["name": TorrentFixture.b("n"), "piece length": .int(16384), "meta version": .int(2), "file tree": .dict([:])]
        XCTAssertThrowsError(try TorrentMetainfo.parse(BencodeDecoder.encode(.dict(["info": .dict(info)])))) { XCTAssertEqual($0 as? TorrentMetainfo.Failure, .invalid("it lists no files")) }          // DX-06: version 2 is read now; this one has an empty tree
    }

    func testTrackersAreFilteredAndBounded() throws {
        var list = ["http://t.example/announce", "udp://t.example:80", "https://t.example/a", "ftp://t.example/x", "javascript:alert(1)", "file:///etc/passwd", "http:///nohost", "http://t.example/announce"]
        list += (0..<60).map { "http://many\($0).example/a" }
        let t = try TorrentFixture.build(files: [(["a"], 10)], announce: list)
        XCTAssertTrue(t.meta.trackers.allSatisfy { ["http", "https", "udp"].contains($0.scheme ?? "") })
        XCTAssertEqual(t.meta.trackers.filter { $0.absoluteString == "http://t.example/announce" }.count, 1)
        XCTAssertLessThanOrEqual(t.meta.trackers.count, TorrentMetainfo.Limit.maxTrackers)
    }

    func testPrivateFlagIsRead() throws {
        XCTAssertTrue(try TorrentFixture.build(files: [(["a"], 10)], isPrivate: true).meta.isPrivate)
        XCTAssertFalse(try TorrentFixture.build(files: [(["a"], 10)]).meta.isPrivate)
    }
}

final class MagnetLinkTests: XCTestCase {
    let hex = "0123456789abcdef0123456789abcdef01234567"

    func testHexAndBase32() throws {
        let a = try MagnetLink.parse("magnet:?xt=urn:btih:\(hex)&dn=Name&tr=http%3A%2F%2Ft.example%2Fannounce&tr=udp%3A%2F%2Ft.example%3A80")
        XCTAssertEqual(a.infoHashHex, hex); XCTAssertEqual(a.displayName, "Name"); XCTAssertEqual(a.trackers.count, 2)
        XCTAssertEqual(try MagnetLink.parse("magnet:?xt=urn:btih:\(hex.uppercased())").infoHashHex, hex)
        let b32 = Data((0..<20).map { UInt8($0 * 13) })
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0, value = 0, text = ""
        for byte in b32 { value = (value << 8) | Int(byte); bits += 8; while bits >= 5 { text.append(alphabet[(value >> (bits - 5)) & 31]); bits -= 5 } }
        XCTAssertEqual(try MagnetLink.parse("magnet:?xt=urn:btih:\(text)").infoHash, b32)
    }

    func testBadLinksAreRefused() {
        XCTAssertThrowsError(try MagnetLink.parse("http://example.com")) { XCTAssertEqual($0 as? MagnetLink.Failure, .notMagnet) }
        XCTAssertThrowsError(try MagnetLink.parse("magnet:?dn=x")) { XCTAssertEqual($0 as? MagnetLink.Failure, .missingHash) }
        XCTAssertThrowsError(try MagnetLink.parse("magnet:?xt=urn:btih:zzzz")) { XCTAssertEqual($0 as? MagnetLink.Failure, .badHash) }
        XCTAssertThrowsError(try MagnetLink.parse("magnet:?xt=urn:btih:\(hex)&xt=urn:btih:\(String(repeating: "a", count: 40))")) { XCTAssertEqual($0 as? MagnetLink.Failure, .badHash) }
        XCTAssertThrowsError(try MagnetLink.parse("magnet:?xt=urn:btmh:1220abcd")) { XCTAssertEqual($0 as? MagnetLink.Failure, .badHash) }          // DX-06: a SHA-256 multihash is accepted; a truncated one is a bad identifier
        XCTAssertThrowsError(try MagnetLink.parse("magnet:?xt=urn:btih:\(hex)&dn=" + String(repeating: "a", count: 9000))) { XCTAssertEqual($0 as? MagnetLink.Failure, .tooLong) }
    }

    func testHybridLinkUsesItsVersion1Hash() throws {
        XCTAssertEqual(try MagnetLink.parse("magnet:?xt=urn:btih:\(hex)&xt=urn:btmh:1220abcd").infoHashHex, hex)
    }

    func testDisplayNameCannotBeAPathAndTrackersAreFiltered() throws {
        let m = try MagnetLink.parse("magnet:?xt=urn:btih:\(hex)&dn=..%2F..%2Fetc&tr=ftp%3A%2F%2Fx&tr=javascript%3Aalert(1)&tr=http%3A%2F%2Fok.example%2Fa&ws=file%3A%2F%2F%2Fetc")
        XCTAssertNil(m.displayName)
        XCTAssertEqual(m.trackers.map(\.absoluteString), ["http://ok.example/a"])
        XCTAssertTrue(m.webSeeds.isEmpty)
    }

    func testUnknownParametersCauseNothing() throws {
        let m = try MagnetLink.parse("magnet:?xt=urn:btih:\(hex)&x.pe=1.2.3.4:5555&xs=http%3A%2F%2Fevil.example%2Ft.torrent&as=http%3A%2F%2Fevil.example%2F")
        XCTAssertTrue(m.trackers.isEmpty)
    }
}

final class TorrentStorageTests: XCTestCase {
    var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("p9-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func storage(_ t: TorrentFixture.Built, selected: Set<Int> = []) -> TorrentStorage {
        TorrentStorage(meta: t.meta, workingFolder: TorrentStorage.workingFolder(for: UUID(), in: root), selected: selected)
    }

    private func writeAll(_ s: TorrentStorage, _ t: TorrentFixture.Built, pieces: [Int]? = nil) throws {
        for p in pieces ?? s.neededPieces {
            let start = p * Int(t.meta.pieceLength)
            try s.write(piece: p, data: t.stream.subdata(in: start..<(start + Int(t.meta.length(ofPiece: p)))))
        }
    }

    func testPiecesSpanningFilesLandInTheRightPlaces() throws {
        let t = try TorrentFixture.build(files: [(["a.bin"], 20_000), (["sub", "b.bin"], 50_000), (["c.bin"], 1_234)])
        let s = storage(t)
        try s.prepare(); try writeAll(s, t)
        for f in t.meta.files {
            let got = try Data(contentsOf: try s.fileURL(f))
            XCTAssertEqual(got, t.stream.subdata(in: Int(f.offset)..<Int(f.offset + f.length)), f.relativePath)
        }
        for p in 0..<t.meta.pieceCount { XCTAssertTrue(s.matches(try XCTUnwrap(s.read(piece: p)), piece: p), "piece \(p) reads back and verifies") }
    }

    func testAWrongPieceIsRecognisedAndAWrongSizeRefused() throws {
        let t = try TorrentFixture.build(files: [(["a"], 70_000)])
        let s = storage(t)
        var data = t.stream.subdata(in: 0..<32768); XCTAssertTrue(s.matches(data, piece: 0))
        data[5] ^= 1; XCTAssertFalse(s.matches(data, piece: 0))
        XCTAssertFalse(s.matches(Data(), piece: 99))
        try s.prepare()
        XCTAssertThrowsError(try s.write(piece: 0, data: Data(count: 10)))
    }

    func testChoosingFilesNeverCreatesTheOthers() throws {
        let t = try TorrentFixture.build(files: [(["a.bin"], 40_000), (["b.bin"], 40_000), (["c.bin"], 40_000)])
        let s = storage(t, selected: [1])
        XCTAssertEqual(s.selectedBytes, 40_000)
        XCTAssertEqual(s.neededPieces, [1, 2], "the pieces that touch b.bin (bytes 40000-79999), and only those")
        try s.prepare(); try writeAll(s, t)
        let names = try FileManager.default.contentsOfDirectory(atPath: s.workingFolder.path)
        XCTAssertFalse(names.contains("a.bin")); XCTAssertFalse(names.contains("c.bin"))
        XCTAssertEqual(try Data(contentsOf: try s.fileURL(t.meta.files[1])), t.stream.subdata(in: 40_000..<80_000))
        // the edges the neighbours share are checked like any other piece
        for p in s.neededPieces { XCTAssertTrue(s.matches(try XCTUnwrap(s.read(piece: p)), piece: p)) }
    }

    func testAPathThatEscapesTheFolderIsRefusedEvenIfMetadataSlippedThrough() throws {
        let t = try TorrentFixture.build(files: [(["a"], 10)])
        var meta = t.meta
        meta.files[0].path = ["..", "..", "escape"]
        let s = TorrentStorage(meta: meta, workingFolder: TorrentStorage.workingFolder(for: UUID(), in: root), selected: [])
        XCTAssertThrowsError(try s.fileURL(meta.files[0])) { XCTAssertTrue(($0 as? TorrentStorage.Failure).map { if case .escapesFolder = $0 { true } else { false } } ?? false) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("escape").path))
    }

    func testALinkPlantedInTheWorkingFolderIsNotFollowed() throws {
        let t = try TorrentFixture.build(files: [(["dir", "f.bin"], 20_000)])
        let s = storage(t)
        let outside = root.appendingPathComponent("outside"); try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: s.dataFolder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: s.dataFolder.appendingPathComponent("dir"), withDestinationURL: outside)
        XCTAssertThrowsError(try s.prepare())
        XCTAssertTrue((try? FileManager.default.contentsOfDirectory(atPath: outside.path))?.isEmpty ?? true)
    }

    func testNotEnoughSpaceIsReportedBeforeAnythingIsWritten() throws {
        let t = try TorrentFixture.build(files: [(["a"], 200_000)])
        let s = storage(t)
        XCTAssertThrowsError(try s.prepare(freeSpace: { _ in 1000 })) { if case TorrentStorage.Failure.noSpace = $0 {} else { XCTFail("\($0)") } }
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.workingFolder.path))
    }

    func testFinishPlacesFilesWithoutOverwritingAnything() throws {
        let t = try TorrentFixture.build(name: "pack", files: [(["a.bin"], 20_000), (["sub", "b.bin"], 20_000)])
        let dest = root.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: dest.appendingPathComponent("pack"), withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: dest.appendingPathComponent("pack/keep.txt"))
        let s = storage(t); try s.prepare(); try writeAll(s, t)
        let placed = try s.finish(into: dest)
        XCTAssertEqual(placed.lastPathComponent, "pack 2", "the name was taken, so the new folder got another")
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("pack/keep.txt")), Data("mine".utf8))
        XCTAssertEqual(try Data(contentsOf: placed.appendingPathComponent("sub/b.bin")), t.stream.subdata(in: 20_000..<40_000))
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.workingFolder.path), "the working folder is gone")
    }

    func testSingleFileFinishAndDiscard() throws {
        let t = try TorrentFixture.build(name: "solo.bin", files: [(["solo.bin"], 40_000)], multi: false)
        let dest = root.appendingPathComponent("Downloads")
        let s = storage(t); try s.prepare(); try writeAll(s, t)
        let placed = try s.finish(into: dest)
        XCTAssertEqual(placed.lastPathComponent, "solo.bin"); XCTAssertEqual(try Data(contentsOf: placed), t.stream)
        let again = storage(t); try again.prepare(); try writeAll(again, t)
        XCTAssertEqual(try again.finish(into: dest).lastPathComponent, "solo 2.bin")
        let gone = storage(t); try gone.prepare(); gone.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone.workingFolder.path))
    }
}

// MARK: Pieces

final class TorrentPickerTests: XCTestCase {
    private func make(files: [([String], Int)] = [(["a"], 32768 * 6)], needed: [Int]? = nil, have: Set<Int> = [], cap: Int = 128 << 20) throws -> (TorrentPicker, TorrentFixture.Built) {
        let t = try TorrentFixture.build(files: files, pieceLength: 32768)
        return (TorrentPicker(meta: t.meta, needed: needed ?? Array(0..<t.meta.pieceCount), alreadyHave: have, selected: [], memoryCap: cap), t)
    }
    private func all(_ n: Int) -> Data { PeerWire.makeBitfield(Array(repeating: true, count: n)) }

    func testTakesTheRarestPieceFirstAndFinishesWhatItBegan() throws {
        let (p, t) = try make()
        let n = t.meta.pieceCount
        p.peerBitfield(1, all(n))
        p.peerBitfield(2, PeerWire.makeBitfield((0..<n).map { $0 != 4 }))          // piece 4 only peer 1 has
        let first = p.nextRequests(for: 1, limit: 1, now: 0)
        XCTAssertEqual(first.first?.piece, 4, "the rarest piece first")
        let more = p.nextRequests(for: 1, limit: 1, now: 0)
        XCTAssertEqual(more.first?.piece, 4, "a piece begun is finished before another is started")
        XCTAssertNotEqual(more.first?.begin, first.first?.begin)
    }

    func testBlocksAreOnlyAcceptedAsAskedAndPiecesCompleteWhole() throws {
        let (p, t) = try make(files: [(["a"], 32768)])
        p.peerBitfield(1, all(1)); p.peerBitfield(2, all(1))
        let reqs = p.nextRequests(for: 1, limit: 10, now: 0)
        XCTAssertEqual(reqs.count, 2); XCTAssertEqual(reqs.map(\.length), [16384, 16384])
        XCTAssertEqual(p.received(from: 2, piece: 0, begin: 0, data: Data(count: 16384)), .unexpected, "a block from a peer it was not asked of")
        XCTAssertEqual(p.received(from: 1, piece: 0, begin: 0, data: Data(count: 100)), .unexpected, "the wrong size")
        XCTAssertEqual(p.received(from: 1, piece: 0, begin: 7, data: Data(count: 16384)), .unexpected, "not on a block boundary")
        XCTAssertEqual(p.received(from: 1, piece: 9, begin: 0, data: Data(count: 16384)), .unexpected, "a piece nobody asked for")
        XCTAssertEqual(p.received(from: 1, piece: 0, begin: 0, data: t.stream.subdata(in: 0..<16384)), .accepted)
        XCTAssertEqual(p.received(from: 1, piece: 0, begin: 0, data: t.stream.subdata(in: 0..<16384)), .unexpected, "a duplicate")
        guard case .pieceComplete(let i, let data, let who) = p.received(from: 1, piece: 0, begin: 16384, data: t.stream.subdata(in: 16384..<32768)) else { return XCTFail() }
        XCTAssertEqual(i, 0); XCTAssertEqual(data, t.stream); XCTAssertEqual(who, [1])
        XCTAssertFalse(p.have[0], "not had until the caller has checked it")
        p.pieceVerified(0); XCTAssertTrue(p.isComplete)
    }

    func testAFailedPieceCanBeAskedForAgainAndALeavingPeerFreesItsBlocks() throws {
        let (p, _) = try make(files: [(["a"], 32768)])
        p.allowsEndgame = false          // this test is about one asker per block; the last stretch (duplicates) has its own tests
        p.peerBitfield(1, all(1)); p.peerBitfield(2, all(1))
        _ = p.nextRequests(for: 1, limit: 10, now: 0)
        XCTAssertTrue(p.nextRequests(for: 2, limit: 10, now: 0).isEmpty, "everything is already asked of peer 1")
        p.peerGone(1)
        XCTAssertEqual(p.nextRequests(for: 2, limit: 10, now: 0).count, 2, "peer 1 left, so peer 2 is asked instead")
        p.pieceFailed(0)
        XCTAssertEqual(p.nextRequests(for: 2, limit: 10, now: 0).count, 2)
    }

    func testSlowRequestsAreGivenBack() throws {
        let (p, _) = try make(files: [(["a"], 32768)])
        p.peerBitfield(1, all(1)); p.peerBitfield(2, all(1))
        _ = p.nextRequests(for: 1, limit: 10, now: 0)
        XCTAssertEqual(p.expire(olderThan: 30, now: 10), []); XCTAssertEqual(p.expire(olderThan: 30, now: 31), [1])
        XCTAssertEqual(p.nextRequests(for: 2, limit: 10, now: 31).count, 2)
    }

    func testOnlyWantedPiecesAreAskedForAndMemoryIsCapped() throws {
        let (p, _) = try make(files: [(["a"], 32768 * 10)], needed: [3, 4, 5], have: [4], cap: 32768 * 2)
        p.peerBitfield(1, all(10))
        let reqs = p.nextRequests(for: 1, limit: 100, now: 0)
        XCTAssertEqual(Set(reqs.map(\.piece)), [3, 5], "not pieces outside the chosen files, not pieces already had")
        XCTAssertLessThanOrEqual(p.heldBytes, 32768 * 2, "unfinished pieces never use more memory than the cap")
        let (q, _) = try make(files: [(["a"], 32768 * 10)], needed: Array(0..<10), have: [], cap: 32768 * 3)
        q.peerBitfield(1, all(10)); _ = q.nextRequests(for: 1, limit: 1000, now: 0)
        XCTAssertLessThanOrEqual(q.heldBytes, 32768 * 3)
    }

    func testProgressCountsOnlyChosenBytes() throws {
        let t = try TorrentFixture.build(files: [(["a"], 40_000), (["b"], 40_000)], pieceLength: 32768)
        let p = TorrentPicker(meta: t.meta, needed: [1, 2], alreadyHave: [1, 2], selected: [1])
        XCTAssertEqual(p.completedBytes, 40_000, "the neighbour's share of an edge piece is not counted")
    }
}

final class PeerWireTests: XCTestCase {
    func testMessagesRoundTripAndSplitAcrossReads() throws {
        let messages: [PeerWire.Message] = [.keepAlive, .choke, .unchoke, .interested, .notInterested, .have(7), .bitfield(Data([0xF0])), .request(index: 1, begin: 16384, length: 16384),
                                            .piece(index: 2, begin: 0, data: Data(repeating: 9, count: 100)), .cancel(index: 1, begin: 0, length: 5), .extended(id: 1, payload: Data("x".utf8))]
        let wire = messages.map(PeerWire.encode).reduce(Data(), +)
        var parser = PeerWire.Parser(pieceCount: 4)
        var got: [PeerWire.Message] = []
        for byte in wire { got += try parser.feed(Data([byte])) }                // one byte at a time
        XCTAssertEqual(got, messages)
    }

    func testAnnouncedHugeFrameIsRefusedBeforeItIsBuffered() {
        var parser = PeerWire.Parser(pieceCount: 100)
        XCTAssertThrowsError(try parser.feed(Data([0xFF, 0xFF, 0xFF, 0xFF, 7]))) { XCTAssertEqual($0 as? PeerWire.Failure, .messageTooLong(UInt32.max)) }
        XCTAssertLessThan(parser.buffered, 10)
    }

    func testMalformedMessagesAreRefused() {
        for body in [[UInt8]([0, 1]), [4, 0, 0], [6, 0, 0, 0, 1], [7, 0, 0, 0, 1], [20]] {
            var parser = PeerWire.Parser(pieceCount: 8)
            let frame = Data(withUnsafeBytes(of: UInt32(body.count).bigEndian, Array.init) + body)
            XCTAssertThrowsError(try parser.feed(frame), "\(body)")
        }
        var parser = PeerWire.Parser(pieceCount: 8)
        let big = Data(withUnsafeBytes(of: UInt32(9 + 16385).bigEndian, Array.init) + [7] + [UInt8](repeating: 0, count: 8 + 16385 - 0))
        XCTAssertThrowsError(try parser.feed(big), "a block larger than 16 KiB")
    }

    func testUnknownMessageIdsAreSkipped() throws {
        var parser = PeerWire.Parser(pieceCount: 8)
        XCTAssertEqual(try parser.feed(PeerWire.encode(.unknown(77)) + PeerWire.encode(.unchoke)), [.unknown(77), .unchoke])
    }

    func testHandshake() throws {
        let hash = Data(repeating: 1, count: 20), id = Data(repeating: 2, count: 20)
        let hs = try PeerWire.parseHandshake(PeerWire.handshake(infoHash: hash, peerID: id, extensions: true))
        XCTAssertEqual(hs.infoHash, hash); XCTAssertEqual(hs.peerID, id); XCTAssertTrue(hs.supportsExtensions)
        XCTAssertFalse(try PeerWire.parseHandshake(PeerWire.handshake(infoHash: hash, peerID: id, extensions: false)).supportsExtensions)
        XCTAssertThrowsError(try PeerWire.parseHandshake(Data(repeating: 0, count: 68)))
        XCTAssertThrowsError(try PeerWire.parseHandshake(Data([19]) + Data("BitTorrent protocoX".utf8) + Data(repeating: 0, count: 48)))
        XCTAssertThrowsError(try PeerWire.parseHandshake(Data(repeating: 19, count: 10)))
    }

    func testBitfieldsMustBeExactlyRight() {
        XCTAssertTrue(PeerWire.validBitfield(Data([0xFF, 0x80]), pieceCount: 9))
        XCTAssertFalse(PeerWire.validBitfield(Data([0xFF]), pieceCount: 9), "too short")
        XCTAssertFalse(PeerWire.validBitfield(Data([0xFF, 0xC0]), pieceCount: 9), "a spare bit is set")
        XCTAssertFalse(PeerWire.validBitfield(Data([0xFF, 0x80, 0]), pieceCount: 9), "too long")
        XCTAssertTrue(PeerWire.has(Data([0x80]), 0)); XCTAssertFalse(PeerWire.has(Data([0x80]), 1)); XCTAssertFalse(PeerWire.has(Data([0x80]), 99)); XCTAssertFalse(PeerWire.has(Data(), -1))
    }

    func testTrackerRepliesAreReadSafely() throws {
        let compact = Data([10, 0, 0, 1, 0x1A, 0xE1, 10, 0, 0, 2, 0, 0])             // second has port 0: dropped
        let ok = BencodeDecoder.encode(.dict(["interval": .int(900), "peers": .bytes(compact)]))
        let r = try HTTPTrackerClient.parse(ok)
        XCTAssertEqual(r.peers, [PeerAddress(host: "10.0.0.1", port: 6881)]); XCTAssertEqual(r.interval, 900)
        let list = BencodeDecoder.encode(.dict(["peers": .list([.dict(["ip": TorrentFixture.b("10.1.1.1"), "port": .int(51413)]), .dict(["ip": TorrentFixture.b("x"), "port": .int(0)]), .int(5)])]))
        XCTAssertEqual(try HTTPTrackerClient.parse(list).peers, [PeerAddress(host: "10.1.1.1", port: 51413)])
        XCTAssertThrowsError(try HTTPTrackerClient.parse(BencodeDecoder.encode(.dict(["failure reason": TorrentFixture.b("nope")])))) { XCTAssertEqual($0 as? HTTPTrackerClient.Failure, .refused("nope")) }
        XCTAssertThrowsError(try HTTPTrackerClient.parse(Data("junk".utf8)))
        let flood = BencodeDecoder.encode(.dict(["peers": .bytes(Data(repeating: 1, count: 6 * 5000))]))
        XCTAssertLessThanOrEqual(try HTTPTrackerClient.parse(flood).peers.count, HTTPTrackerClient.maxPeers)
        XCTAssertEqual(try HTTPTrackerClient.parse(BencodeDecoder.encode(.dict(["interval": .int(1)]))).interval, 60, "an absurdly short interval is raised")
    }

    func testUDPTrackersAreNotSupportedAndSaySo() async {
        let client = HTTPTrackerClient()
        do { _ = try await client.announce(URL(string: "udp://t.example:80")!, infoHash: Data(count: 20), peerID: Data(count: 20), uploaded: 0, downloaded: 0, left: 1, event: nil); XCTFail() }
        catch { XCTAssertEqual(error as? HTTPTrackerClient.Failure, .unsupportedScheme("udp")) }
    }
}

// MARK: Findings from the independent review

final class TorrentReviewFixTests: TorrentSessionTestCase {
    func testAServedBlockIsReadWithoutReadingTheWholePiece() throws {
        let t = try TorrentFixture.build(files: [(["a.bin"], 20_000), (["b.bin"], 50_000)], pieceLength: 32768)
        let s = TorrentStorage(meta: t.meta, workingFolder: TorrentStorage.workingFolder(for: UUID(), in: root), selected: [])
        try s.prepare()
        for p in 0..<t.meta.pieceCount { try s.write(piece: p, data: t.stream.subdata(in: (p * 32768)..<(p * 32768 + Int(t.meta.length(ofPiece: p))))) }
        XCTAssertEqual(s.read(piece: 0, begin: 16384, length: 3616), t.stream.subdata(in: 16384..<20000), "across the end of a.bin")
        XCTAssertEqual(s.read(piece: 1, begin: 0, length: 16384), t.stream.subdata(in: 32768..<(32768 + 16384)))
        XCTAssertNil(s.read(piece: 1, begin: 0, length: 40_000), "past the end of the piece"); XCTAssertNil(s.read(piece: 9, begin: 0, length: 1)); XCTAssertNil(s.read(piece: 0, begin: -1, length: 1))
    }

    func testNoNameInATorrentCanCollideWithTheAppsOwnFiles() async throws {
        let t = try TorrentFixture.build(name: "odd", files: [([".state.json"], 40_000), ([".info"], 40_000), ([".unselected"], 5_000)])
        let r = try makeRun(t, peers: [1])
        r.session.start()
        let ok = await until { r.events.finished }
        XCTAssertTrue(ok, "failure: \(r.events.failure ?? "-")")
        try assertFilesMatch(r, t)
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.storage.workingFolder.appendingPathComponent(".state.json").path), "the torrent's files live in their own folder")
        r.session.stop()
    }

    func testPeersOnTheLocalNetworkNamedByATrackerAreIgnoredByDefault() async throws {
        let t = try TorrentFixture.build(files: [(["a.bin"], 40_000)])
        let storage = TorrentStorage(meta: t.meta, workingFolder: TorrentStorage.workingFolder(for: taskID, in: root), selected: [])
        try storage.prepare()
        let factory = FakePeers { _, q in FakePeer(queue: q, stream: t.stream, meta: t.meta, infoHash: t.meta.infoHash) }
        let tracker = FakeTracker(peers: [PeerAddress(host: "127.0.0.1", port: 22), PeerAddress(host: "192.168.1.5", port: 80), PeerAddress(host: "169.254.1.1", port: 80), PeerAddress(host: "10.0.0.9", port: 80)])
        let session = TorrentSession(infoHash: t.meta.infoHash, meta: t.meta, trackers: [URL(string: "http://tracker.test/a")!], storage: { storage }, alreadyHave: [], transports: factory, tracker: tracker,
                                     download: nil, upload: nil, taskID: taskID)
        session.start()
        try? await Task.sleep(for: .milliseconds(1200))
        XCTAssertGreaterThan(tracker.calls, 0)
        XCTAssertEqual(factory.all.count, 0, "a tracker cannot point the browser at the local network")
        session.stop()
    }

    func testAPieceBeingCheckedIsNotAskedForAgain() throws {
        let t = try TorrentFixture.build(files: [(["a.bin"], 32768 * 3)], pieceLength: 32768)
        let p = TorrentPicker(meta: t.meta, needed: [0, 1, 2], alreadyHave: [], selected: [])
        p.peerBitfield(1, PeerWire.makeBitfield([true, true, true]))
        let first = p.nextRequests(for: 1, limit: 2, now: 0)
        XCTAssertEqual(first.map(\.piece), [0, 0])
        _ = p.received(from: 1, piece: 0, begin: 0, data: t.stream.subdata(in: 0..<16384))
        guard case .pieceComplete = p.received(from: 1, piece: 0, begin: 16384, data: t.stream.subdata(in: 16384..<32768)) else { return XCTFail() }
        let next = p.nextRequests(for: 1, limit: 10, now: 0)
        XCTAssertFalse(next.contains { $0.piece == 0 }, "piece 0 is being checked and is not fetched a second time")
        XCTAssertGreaterThanOrEqual(p.heldBytes, 32768, "its memory still counts toward the cap")
        p.pieceFailed(0)
        XCTAssertTrue(p.nextRequests(for: 1, limit: 10, now: 0).contains { $0.piece == 0 }, "after a failed check it can be asked for again")
    }

    func testOnlyTheAppsOwnWorkingFolderNameIsEverUsedAsAPath() {
        XCTAssertTrue(TorrentRunner.isWorkingFolderName(".ABCD1234.bsetu-torrent"))
        for bad in ["..", "../x", ".abcd1234.bsetu-torrent/..", "x", ".ABCD123.bsetu-torrent", ".ABCD1234.bsetu-torrent ", "/etc", ""] { XCTAssertFalse(TorrentRunner.isWorkingFolderName(bad), bad) }
    }

    func testSavedDetailsAreOnlyBelievedWhenTheyCheckOut() throws {
        let t = try TorrentFixture.build(name: "n", files: [(["a"], 40_000), (["b"], 40_000)])
        let folder = root.appendingPathComponent("w"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try TorrentRunner.saveSidecar(folder, meta: t.meta, selected: [1], trackers: [URL(string: "http://t.example/a")!])
        XCTAssertEqual(TorrentRunner.loadSidecar(folder, expectedHash: t.meta.infoHashHex)?.selected, [1])
        XCTAssertNil(TorrentRunner.loadSidecar(folder, expectedHash: String(repeating: "0", count: 40)), "details of another torrent")
        try TorrentRunner.saveSidecar(folder, meta: t.meta, selected: [7, 9], trackers: [])
        XCTAssertNil(TorrentRunner.loadSidecar(folder, expectedHash: nil), "a selection that names no real file would otherwise mean “finished” at once")
        try Data("not json".utf8).write(to: folder.appendingPathComponent(".state.json"))
        XCTAssertNil(TorrentRunner.loadSidecar(folder, expectedHash: nil))
    }

    func testAMagnetWhoseMetadataIsPoisonedSetsAsideEveryoneWhoTookPart() async throws {
        let t = try TorrentFixture.build(files: [(["a.bin"], 60_000)], infoExtra: ["x": .bytes(Data(repeating: 1, count: 40_000))])
        var b = FakePeer.Behaviour(); b.serveMetadata = t.info; b.badMetadata = true
        let factory = FakePeers { _, q in FakePeer(queue: q, stream: t.stream, meta: nil, infoHash: t.meta.infoHash, behaviour: b) }
        let events = Events()
        let session = TorrentSession(infoHash: t.meta.infoHash, meta: nil, trackers: [URL(string: "http://tracker.test/a")!], storage: { nil }, alreadyHave: [], transports: factory,
                                     tracker: FakeTracker(peers: [addr(1), addr(2)]), download: nil, upload: nil, taskID: taskID, settings: .testing)
        session.onEvent = { events.add($0) }
        session.start()
        try? await Task.sleep(for: .seconds(1.5))
        XCTAssertNil(events.metadata)
        let senders = factory.all.filter { $0.sentToUs > 1000 }          // handshakes are far smaller; only a peer that sent metadata parts is above this
        XCTAssertFalse(senders.isEmpty)
        XCTAssertTrue(senders.allSatisfy(\.closed), "everyone who sent a part of the rejected metadata was dropped")
        session.stop()
    }
}
