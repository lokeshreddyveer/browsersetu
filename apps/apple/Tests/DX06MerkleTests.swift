import XCTest
@testable import Browser_Setu

// DX-06: SHA-256 Merkle trees (BEP 52). The expected values were produced by an independent Python transcription of the reference creator's rules (see docs), not by this code.

final class DX06MerkleTests: XCTestCase {
    private func content(_ n: Int) -> Data { Data((0..<n).map { UInt8(truncatingIfNeeded: ($0 * 7 + ($0 >> 8)) % 256) }) }
    private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
    static let pieceLength: Int64 = 32768

    /// (file length, pieces root, piece layer or nil) for piece length 32768.
    private let vectors: [(Int, String, String?)] = [
        (1, "6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d", nil),
        (16384, "5252abae92836caa122f8d6c078aa2487dc32b17e1b204a7cc022809faebc192", nil),
        (16385, "831c51b911745d225c3ef7ddaaeb0971d93962202f8bd82789db755f86fb5a49", nil),
        (32768, "52be10908528d4e56eca06f83e2ec15e48ea3f97f7ce4ee463615c00143dd0fa", nil),
        (32769, "d4284bbf94fc69446f2b4cc76aea8a8256929e425b0a39bde22cb546167a5737", "52be10908528d4e56eca06f83e2ec15e48ea3f97f7ce4ee463615c00143dd0fa2c5821e4f8a9f025131c6430f54cb49d348bacdcb4f1ff30683388e625bc2b54"),
        (100000, "a61f2da045dde32ea6426a18b0d05e483d7686473b1dacbd9cc24e56caa4770d", "52be10908528d4e56eca06f83e2ec15e48ea3f97f7ce4ee463615c00143dd0fa8afee8402bf361cf7eaec07bae9a0e4dfc819ed04bd9d248fc8654074c910e3f52be10908528d4e56eca06f83e2ec15e48ea3f97f7ce4ee463615c00143dd0fa401370c32732f067362670be600ce24fef332e156703db40bc7a97022bbee4be"),
        (131072, "03773bf22d46d4491005bf5d2a2b4fe0b4ab1ce4d617c30dc1b07c5bc5aece83", "52be10908528d4e56eca06f83e2ec15e48ea3f97f7ce4ee463615c00143dd0fa8afee8402bf361cf7eaec07bae9a0e4dfc819ed04bd9d248fc8654074c910e3f52be10908528d4e56eca06f83e2ec15e48ea3f97f7ce4ee463615c00143dd0fa8afee8402bf361cf7eaec07bae9a0e4dfc819ed04bd9d248fc8654074c910e3f"),
        (200000, "3966669c522f4002cd6b8e010ff5fe8b333b20d18532a542ec8551ae8fd1eba2", "52be10908528d4e56eca06f83e2ec15e48ea3f97f7ce4ee463615c00143dd0fa8afee8402bf361cf7eaec07bae9a0e4dfc819ed04bd9d248fc8654074c910e3f52be10908528d4e56eca06f83e2ec15e48ea3f97f7ce4ee463615c00143dd0fa8afee8402bf361cf7eaec07bae9a0e4dfc819ed04bd9d248fc8654074c910e3f52be10908528d4e56eca06f83e2ec15e48ea3f97f7ce4ee463615c00143dd0fa8afee8402bf361cf7eaec07bae9a0e4dfc819ed04bd9d248fc8654074c910e3f202acc58b9bd22cfccda4a9f70c5e30955fc47831bf12ae779dbf9aba15b95d4"),
    ]

    func testFileRootsAndPieceLayersMatchTheIndependentValues() {
        for (length, root, layer) in vectors {
            let leaves = Merkle.leafHashes(of: content(length))
            XCTAssertEqual(Merkle.fileRoot(leaves: leaves, pieceLength: Self.pieceLength).map(hex), root, "root of \(length) bytes")
            let roots = Merkle.pieceRoots(leaves: leaves, pieceLength: Self.pieceLength)
            if let layer { XCTAssertEqual(roots.map { hex($0.reduce(Data(), +)) }, layer, "piece layer of \(length) bytes") }
        }
    }

    func testALayerIsAcceptedOnlyForItsFile() {
        for (length, root, layer) in vectors {
            guard let layer else { continue }
            let l = Data(stride(from: 0, to: layer.count, by: 2).map { UInt8(layer[layer.index(layer.startIndex, offsetBy: $0)...layer.index(layer.startIndex, offsetBy: $0 + 1)], radix: 16)! })
            let r = Data(stride(from: 0, to: root.count, by: 2).map { UInt8(root[root.index(root.startIndex, offsetBy: $0)...root.index(root.startIndex, offsetBy: $0 + 1)], radix: 16)! })
            XCTAssertTrue(Merkle.layerMatches(l, fileLength: Int64(length), pieceLength: Self.pieceLength, piecesRoot: r), "\(length)")
            var broken = l; broken[broken.startIndex] ^= 1
            XCTAssertFalse(Merkle.layerMatches(broken, fileLength: Int64(length), pieceLength: Self.pieceLength, piecesRoot: r), "one changed hash")
            XCTAssertFalse(Merkle.layerMatches(l.dropLast(32), fileLength: Int64(length), pieceLength: Self.pieceLength, piecesRoot: r), "a missing hash")
            XCTAssertFalse(Merkle.layerMatches(l, fileLength: Int64(length) + Self.pieceLength, pieceLength: Self.pieceLength, piecesRoot: r), "the wrong length")
        }
    }

    func testPiecesAreCheckedAgainstTheLayerAndACorruptedBlockIsCaught() {
        let length = 100_000
        let data = content(length)
        let leaves = Merkle.leafHashes(of: data)
        let root = Merkle.fileRoot(leaves: leaves, pieceLength: Self.pieceLength)!
        let layer = Merkle.pieceRoots(leaves: leaves, pieceLength: Self.pieceLength)!.reduce(Data(), +)
        let pl = Int(Self.pieceLength)
        for i in 0..<4 {
            let piece = data.subdata(in: (i * pl)..<min(length, (i + 1) * pl))
            XCTAssertTrue(Merkle.pieceMatches(piece, fileLength: Int64(length), pieceLength: Self.pieceLength, piecesRoot: root, pieceLayer: layer, indexInFile: i), "piece \(i)")
            var bad = piece; bad[bad.startIndex + 17000 % bad.count] ^= 0x80
            XCTAssertFalse(Merkle.pieceMatches(bad, fileLength: Int64(length), pieceLength: Self.pieceLength, piecesRoot: root, pieceLayer: layer, indexInFile: i), "piece \(i) with one changed byte")
            XCTAssertFalse(Merkle.pieceMatches(piece, fileLength: Int64(length), pieceLength: Self.pieceLength, piecesRoot: root, pieceLayer: layer, indexInFile: (i + 1) % 4), "piece \(i) offered as another piece")
        }
        XCTAssertFalse(Merkle.pieceMatches(data.prefix(pl - 1), fileLength: Int64(length), pieceLength: Self.pieceLength, piecesRoot: root, pieceLayer: layer, indexInFile: 0), "a truncated piece")
        XCTAssertFalse(Merkle.pieceMatches(data.prefix(pl), fileLength: Int64(length), pieceLength: Self.pieceLength, piecesRoot: root, pieceLayer: nil, indexInFile: 0), "no layer for a long file")
    }

    func testAFileOfOnePieceOrLessIsCheckedAgainstItsRootAlone() {
        let data = content(20_000)
        let root = Merkle.fileRoot(leaves: Merkle.leafHashes(of: data), pieceLength: Self.pieceLength)!
        XCTAssertTrue(Merkle.pieceMatches(data, fileLength: 20_000, pieceLength: Self.pieceLength, piecesRoot: root, pieceLayer: nil, indexInFile: 0))
        XCTAssertFalse(Merkle.pieceMatches(data, fileLength: 20_000, pieceLength: Self.pieceLength, piecesRoot: root, pieceLayer: nil, indexInFile: 1))
    }

    func testPieceLengthRulesAndTheTruncatedIdentity() {
        XCTAssertTrue(Merkle.validPieceLength(16384)); XCTAssertTrue(Merkle.validPieceLength(1 << 20))
        XCTAssertFalse(Merkle.validPieceLength(8192), "below 16 KiB"); XCTAssertFalse(Merkle.validPieceLength(49152), "not a power of two"); XCTAssertFalse(Merkle.validPieceLength(0))
        XCTAssertNil(Merkle.fileRoot(leaves: [], pieceLength: 32768), "an empty file has no root")
        XCTAssertNil(Merkle.fileRoot(leaves: [Merkle.zeroHash], pieceLength: 20000), "an invalid piece length")
        XCTAssertEqual(Merkle.truncated(Data(repeating: 7, count: 32)).count, 20)
        XCTAssertEqual(Merkle.nextPowerOfTwo(5), 8); XCTAssertEqual(Merkle.nextPowerOfTwo(8), 8); XCTAssertEqual(Merkle.nextPowerOfTwo(1), 1)
    }
}
