import CryptoKit
import Foundation

// MARK: BitTorrent v2 Merkle trees (BEP 52)
//
// A file is cut into 16 KiB blocks; each block is hashed with SHA-256 (the last block may be shorter and is not padded). The hashes are the leaves of a binary tree. The rules below follow the
// reference creator that BEP 52 links (bep_0052_torrent_creator.py), which the BEP's own words ("the remaining leaf hashes ... are set to zero") leave open:
//
//  * A file no longer than one piece: its leaves are padded with 32 zero bytes (as leaves) up to the next power of two of ITS block count, and the root of that is the file's `pieces root`.
//    A file of one block has that block's hash as its root.
//  * A longer file: each piece's leaves are padded with zero leaves up to blocks-per-piece (only the last piece needs it) and reduced to a piece root; the piece roots form the "piece layer".
//    The layer is padded up to the next power of two of the piece count with `padPieceHash = root(blocksPerPiece zero leaves)`, and the root of that is the file's `pieces root`.
//  * `piece layers` in a .torrent lists, for each file longer than a piece, the real piece roots only (never the padding), keyed by the file's pieces root.
//
// Nothing here touches the disk or the network. Sizes are checked; hashes are 32 bytes each.

enum Merkle {
    static let blockSize = 16 * 1024
    static let hashSize = 32
    static let zeroHash = Data(count: 32)

    static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    static func sha256(_ a: Data, _ b: Data) -> Data {
        var h = SHA256(); h.update(data: a); h.update(data: b); return Data(h.finalize())
    }

    static func isPowerOfTwo(_ n: Int) -> Bool { n > 0 && n & (n - 1) == 0 }
    static func nextPowerOfTwo(_ n: Int) -> Int { n <= 1 ? 1 : 1 << (Int.bitWidth - (n - 1).leadingZeroBitCount) }

    /// A valid v2 piece length: a power of two, at least 16 KiB.
    static func validPieceLength(_ n: Int64) -> Bool { n >= Int64(blockSize) && n <= Int64(Int32.max) && isPowerOfTwo(Int(n)) }
    static func blocksPerPiece(_ pieceLength: Int64) -> Int { Int(pieceLength) / blockSize }

    /// SHA-256 of every 16 KiB block of `data` (the last block may be shorter).
    static func leafHashes(of data: Data) -> [Data] {
        var out: [Data] = []
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = min(offset + blockSize, data.endIndex)
            out.append(sha256(data.subdata(in: offset..<end)))
            offset = end
        }
        return out
    }

    /// The root of `hashes` after padding them with zero hashes up to `count` (a power of two, at least `hashes.count`).
    static func root(of hashes: [Data], paddedTo count: Int? = nil) -> Data? {
        let target = count ?? nextPowerOfTwo(hashes.count)
        guard !hashes.isEmpty, isPowerOfTwo(target), target >= hashes.count, hashes.allSatisfy({ $0.count == hashSize }) else { return nil }
        var layer = hashes + [Data](repeating: zeroHash, count: target - hashes.count)
        while layer.count > 1 {
            var next: [Data] = []
            next.reserveCapacity(layer.count / 2)
            for i in stride(from: 0, to: layer.count, by: 2) { next.append(sha256(layer[i], layer[i + 1])) }
            layer = next
        }
        return layer[0]
    }

    /// The hash that stands for a whole piece of zero leaves, used to pad a piece layer.
    private static let padCache = NSLock()
    nonisolated(unsafe) private static var padHashes: [Int: Data] = [:]
    static func padPieceHash(blocksPerPiece: Int) -> Data? {
        padCache.lock(); defer { padCache.unlock() }
        if let known = padHashes[blocksPerPiece] { return known }
        guard let made = root(of: [Data](repeating: zeroHash, count: blocksPerPiece)) else { return nil }
        padHashes[blocksPerPiece] = made
        return made
    }

    /// The roots of the pieces of a file, from the file's leaf hashes: the real piece roots (the last one padded with zero leaves to a whole piece). nil if the piece length is invalid.
    static func pieceRoots(leaves: [Data], pieceLength: Int64) -> [Data]? {
        guard validPieceLength(pieceLength) else { return nil }
        let per = blocksPerPiece(pieceLength)
        var out: [Data] = []
        var i = 0
        while i < leaves.count {
            let slice = Array(leaves[i..<min(i + per, leaves.count)])
            guard let r = root(of: slice, paddedTo: per) else { return nil }
            out.append(r); i += per
        }
        return out
    }

    /// The file's `pieces root` from its leaf hashes. nil for an empty file (it has none) or an invalid piece length.
    static func fileRoot(leaves: [Data], pieceLength: Int64) -> Data? {
        guard validPieceLength(pieceLength), !leaves.isEmpty else { return nil }
        let per = blocksPerPiece(pieceLength)
        if leaves.count <= per { return root(of: leaves) }          // one piece or less: the tree of its own blocks
        guard let roots = pieceRoots(leaves: leaves, pieceLength: pieceLength) else { return nil }
        return rootOfPieceLayer(roots, pieceLength: pieceLength)
    }

    /// The root made from a piece layer: padded to a power of two with `padPieceHash`.
    static func rootOfPieceLayer(_ roots: [Data], pieceLength: Int64) -> Data? {
        guard validPieceLength(pieceLength), !roots.isEmpty, let pad = padPieceHash(blocksPerPiece: blocksPerPiece(pieceLength)) else { return nil }
        let target = nextPowerOfTwo(roots.count)
        return root(of: roots + [Data](repeating: pad, count: target - roots.count))
    }

    /// Whether a piece layer (concatenated 32-byte hashes, as stored in `piece layers`) belongs to a file with this `pieces root`, length and piece length.
    static func layerMatches(_ layer: Data, fileLength: Int64, pieceLength: Int64, piecesRoot: Data) -> Bool {
        guard validPieceLength(pieceLength), fileLength > pieceLength, piecesRoot.count == hashSize, layer.count % hashSize == 0 else { return false }
        let expectedCount = Int((fileLength + pieceLength - 1) / pieceLength)
        guard layer.count / hashSize == expectedCount else { return false }
        let roots = stride(from: 0, to: layer.count, by: hashSize).map { layer.subdata(in: $0..<($0 + hashSize)) }
        return rootOfPieceLayer(roots, pieceLength: pieceLength) == piecesRoot
    }

    /// The expected hash of one piece of a file, and how to check a piece's bytes against it: the piece root of its blocks (padded to a whole piece) must equal the layer's hash; for a file that
    /// is one piece or less, the root of its own blocks must equal the file's `pieces root`.
    static func pieceMatches(_ bytes: Data, fileLength: Int64, pieceLength: Int64, piecesRoot: Data, pieceLayer: Data?, indexInFile: Int) -> Bool {
        guard validPieceLength(pieceLength), fileLength > 0, indexInFile >= 0, piecesRoot.count == hashSize else { return false }
        let leaves = leafHashes(of: bytes)
        if fileLength <= pieceLength {
            guard indexInFile == 0, Int64(bytes.count) == fileLength else { return false }
            return root(of: leaves) == piecesRoot
        }
        guard let layer = pieceLayer, (indexInFile + 1) * hashSize <= layer.count else { return false }
        let start = Int64(indexInFile) * pieceLength
        guard start < fileLength, Int64(bytes.count) == min(pieceLength, fileLength - start),
              let r = root(of: leaves, paddedTo: blocksPerPiece(pieceLength)) else { return false }
        return r == layer.subdata(in: (indexInFile * hashSize)..<((indexInFile + 1) * hashSize))
    }

    /// The hash of the first 20 bytes: how a v2 info hash is written where only 20 bytes fit (trackers, the DHT, the handshake).
    static func truncated(_ infoHashV2: Data) -> Data { infoHashV2.prefix(20) }
}
