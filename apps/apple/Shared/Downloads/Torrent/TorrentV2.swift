import CryptoKit
import Foundation

// MARK: BitTorrent v2 and hybrid metadata (BEP 52, BEP 47)
//
// A version 2 torrent describes its files as a tree with a Merkle root per file. To keep the rest of the engine (segments, picker, storage) working on one byte stream, the files are laid out in
// that stream aligned to piece boundaries, with `File.isPadding` entries standing for the gaps. Padding is never a real file. In a version 2 only torrent a piece ends where its file ends (the
// gap is not part of the piece); in a hybrid torrent the version 1 view already contains real padding entries and its pieces are whole.
//
// A hybrid torrent is accepted only when both views agree exactly. Nothing is merged: a disagreement is a refusal with a reason.

extension TorrentMetainfo {
    /// One file of a version 2 file tree, in the tree's order.
    struct V2File: Equatable {
        var path: [String]
        var raw: [String]
        var length: Int64
        var root: Data?
        var relativePath: String { path.joined(separator: "/") }
    }

    // MARK: File tree

    /// Walks `file tree` in byte order of the names (the order a bencoded dictionary is written in). A file is the dictionary under the empty-string key; nothing else may sit beside it.
    static func parseFileTree(_ tree: [String: Bencode]) throws -> [V2File] {
        var out: [V2File] = []
        func byBytes(_ a: String, _ b: String) -> Bool { Array(a.utf8).lexicographicallyPrecedes(Array(b.utf8)) }
        func walk(_ dict: [String: Bencode], path: [String], raw: [String]) throws {
            if let leaf = dict[""] {
                guard !path.isEmpty else { throw Failure.invalid("the file tree is itself a file") }
                guard dict.count == 1 else { throw Failure.invalid("“\(path.joined(separator: "/").prefix(60))” is both a file and a folder") }
                guard let attrs = leaf.dict else { throw Failure.invalid("a file entry is not a dictionary") }
                guard let length = attrs["length"]?.int, length >= 0, length <= Limit.maxTotal else { throw Failure.invalid("a file in the tree has no usable length") }
                if (attrs["attr"]?.string ?? "").contains("p") { throw Failure.invalid("a version 2 file tree lists a padding file") }
                var root: Data?
                if length > 0 {
                    guard let r = attrs["pieces root"]?.data, r.count == Merkle.hashSize else { throw Failure.invalid("“\(path.joined(separator: "/").prefix(60))” has no valid pieces root") }
                    root = r
                } else if attrs["pieces root"] != nil { throw Failure.invalid("an empty file has a pieces root") }
                guard out.count < Limit.maxFiles else { throw Failure.tooMany("files") }
                out.append(V2File(path: path, raw: raw, length: length, root: root))
                return
            }
            guard path.count < Limit.maxPathDepth else { throw Failure.unsafePath(path.joined(separator: "/")) }
            guard !dict.isEmpty || path.isEmpty else { throw Failure.invalid("the file tree has an empty folder") }
            for key in dict.keys.sorted(by: byBytes) {
                guard let child = dict[key]?.dict else { throw Failure.invalid("a file tree entry is not a dictionary") }
                guard let safe = safeComponent(key) else { throw Failure.unsafePath(key) }
                try walk(child, path: path + [safe], raw: raw + [key])
            }
        }
        try walk(tree, path: [], raw: [])
        guard !out.isEmpty else { throw Failure.invalid("it lists no files") }
        // The same name rules as version 1: nothing that collides on a case-insensitive disk, no file that is also a folder.
        var seen = Set<String>()
        var total: Int64 = 0
        for f in out {
            let joined = f.relativePath
            guard joined.utf8.count <= Limit.maxPathBytes else { throw Failure.unsafePath(joined) }
            guard seen.insert(joined.lowercased().precomposedStringWithCanonicalMapping).inserted else { throw Failure.unsafePath(joined) }
            let (sum, overflow) = total.addingReportingOverflow(f.length)
            guard !overflow, sum <= Limit.maxTotal else { throw Failure.tooMany("bytes") }
            total = sum
        }
        let prefixes = Set(out.flatMap { f in (1..<max(1, f.path.count)).map { f.path.prefix($0).joined(separator: "/").lowercased() } })
        for f in out where prefixes.contains(f.relativePath.lowercased()) { throw Failure.unsafePath(f.relativePath) }
        return out
    }

    // MARK: Piece layers

    /// The key `piece layers` has for a root, spelled the way the decoder spells binary keys (UTF-8 text when it is valid, otherwise Latin-1).
    static func layerKey(_ root: Data) -> String { String(data: root, encoding: .utf8) ?? String(data: root, encoding: .isoLatin1) ?? "" }

    /// Every file longer than a piece needs its layer, and the layer must hash to the file's root. A missing layer is an error for a .torrent file (`require`), and left for peers to supply otherwise.
    static func collectLayers(root: [String: Bencode], files: [V2File], pieceLength: Int64, require: Bool) throws -> [Data: Data] {
        var table: [String: Bencode] = [:]
        if let raw = root["piece layers"] {
            guard let d = raw.dict else { throw Failure.invalid("the piece layers are not a dictionary") }
            table = d
        }
        var out: [Data: Data] = [:]
        for f in files where f.length > pieceLength {
            guard let r = f.root else { continue }
            if out[r] != nil { continue }
            guard let layer = table[layerKey(r)]?.data else {
                if require { throw Failure.missingPieceLayer(f.relativePath) }
                continue
            }
            guard Merkle.layerMatches(layer, fileLength: f.length, pieceLength: pieceLength, piecesRoot: r) else { throw Failure.invalid("the checksums for “\(f.relativePath.prefix(60))” do not match its root") }
            out[r] = layer
        }
        return out
    }

    // MARK: Version 2 only

    static func parseV2Only(info: [String: Bencode], rawInfo: Data, root: [String: Bencode], requireLayers: Bool) throws -> TorrentMetainfo {
        guard let pieceLength = info["piece length"]?.int, Merkle.validPieceLength(pieceLength), pieceLength <= Limit.maxPieceLength else { throw Failure.invalid("the piece length is not usable") }
        guard let rawName = info["name"]?.string ?? info["name.utf-8"]?.string, let name = safeComponent(rawName) else { throw Failure.unsafePath(info["name"]?.string ?? "") }
        guard let tree = info["file tree"]?.dict else { throw Failure.invalid("a version 2 torrent has no file tree") }
        let v2 = try parseFileTree(tree)

        var files: [File] = []
        var offset: Int64 = 0
        var pieces = 0
        for v in v2 {
            if v.length > 0 {
                let rem = offset % pieceLength
                if rem != 0 {
                    let gap = pieceLength - rem
                    files.append(File(index: files.count, path: [".pad", String(gap)], length: gap, offset: offset, isPadding: true))
                    offset += gap
                }
                pieces += Int((v.length + pieceLength - 1) / pieceLength)
                guard pieces <= Limit.maxPieces else { throw Failure.tooMany("pieces") }
            }
            files.append(File(index: files.count, path: v.path, length: v.length, offset: offset, rawPath: v.raw == v.path ? nil : v.raw, pieceRoot: v.root))
            offset += v.length
        }
        guard offset > 0, pieces > 0 else { throw Failure.invalid("it is empty") }
        let single = v2.count == 1 && v2[0].path == [name]
        let layers = try collectLayers(root: root, files: v2, pieceLength: pieceLength, require: requireLayers)
        let v2Hash = Data(SHA256.hash(data: rawInfo))
        var meta = TorrentMetainfo(infoHash: Merkle.truncated(v2Hash), rawInfo: rawInfo, name: name, pieceLength: pieceLength, pieceHashes: [], files: files, isMultiFile: !single,
                                   totalLength: offset, isPrivate: info["private"]?.int == 1, trackers: trackerURLs(root: root), webSeeds: webSeedURLs(root["url-list"]),
                                   comment: root["comment"]?.string.map { String($0.prefix(500)) }, trackerTiers: trackerTierURLs(root: root), rawName: rawName == name ? nil : rawName,
                                   httpSeeds: httpSeedURLs(root["httpseeds"]))
        meta.version = .v2
        meta.infoHashV2 = v2Hash
        meta.pieceLayers = layers
        meta.v2PieceCount = pieces
        meta.hasPadding = files.contains { $0.isPadding }
        return meta
    }

    // MARK: Hybrid

    /// `meta` was read from the version 1 side. The version 2 side must describe exactly the same files in the same order, and the padding must put every file on a piece boundary.
    static func applyHybrid(to meta: inout TorrentMetainfo, info: [String: Bencode], root: [String: Bencode], requireLayers: Bool, nonCanonicalPadding: Bool) throws {
        func refuse(_ why: String) -> Failure { Failure.inconsistentHybrid(why) }
        guard let tree = info["file tree"]?.dict else { throw Failure.invalid("a version 2 torrent has no file tree") }
        let pl = meta.pieceLength
        guard Merkle.validPieceLength(pl) else { throw refuse("the piece length is not a power of two") }
        let v2 = try parseFileTree(tree)
        let real = meta.files.filter { !$0.isPadding }
        guard real.count == v2.count else { throw refuse("\(real.count) files in version 1, \(v2.count) in version 2") }
        for (a, b) in zip(real, v2) {
            guard a.path == b.path else { throw refuse("file \(a.index) is “\(a.relativePath.prefix(40))” in one and “\(b.relativePath.prefix(40))” in the other") }
            guard a.length == b.length else { throw refuse("“\(a.relativePath.prefix(40))” has two different sizes") }
        }
        if nonCanonicalPadding { throw refuse("a padding entry is not named .pad/<length>") }

        // Padding: after a file, up to the next boundary, never first, never twice in a row, never last, and no real file may take a padding name.
        var previousWasReal = false
        for (position, f) in meta.files.enumerated() {
            if f.isPadding {
                guard previousWasReal, position < meta.files.count - 1 else { throw refuse("padding is in the wrong place") }
                guard f.length >= 1, f.length < pl, (f.offset + f.length) % pl == 0 else { throw refuse("a padding entry does not end on a piece boundary") }
                previousWasReal = false
            } else {
                if f.length > 0, f.offset % pl != 0 { throw refuse("“\(f.relativePath.prefix(40))” does not start on a piece boundary") }
                if f.path.count == 2, f.path[0] == ".pad", !f.path[1].isEmpty, f.path[1].allSatisfy({ $0.isASCII && $0.isNumber }) { throw refuse("a file takes the name of padding") }
                previousWasReal = true
            }
        }
        // The two views must also agree on how many pieces there are.
        var v2Pieces = 0
        for f in v2 where f.length > 0 { v2Pieces += Int((f.length + pl - 1) / pl) }
        guard v2Pieces == meta.pieceHashes.count else { throw refuse("the number of pieces differs") }

        // Only now are the version 2 facts attached.
        var roots = v2.map(\.root).makeIterator()
        for i in meta.files.indices where !meta.files[i].isPadding { meta.files[i].pieceRoot = roots.next() ?? nil }
        meta.pieceLayers = try collectLayers(root: root, files: v2, pieceLength: pl, require: requireLayers)
        meta.infoHashV2 = Data(SHA256.hash(data: meta.rawInfo))
        meta.version = .hybrid
    }

    // MARK: Identity

    /// Whether metadata fetched for a magnet link is the torrent the link named: its SHA-1 equals a version 1 hash, or the first 20 bytes of its SHA-256 equal the link's 20 bytes, and a full
    /// version 2 hash, when the link has one, equals the SHA-256.
    static func infoMatches(_ raw: Data, session: Data, v2: Data?) -> Bool {
        let sha256 = Data(SHA256.hash(data: raw))
        if let v2, sha256 != v2 { return false }
        return Data(Insecure.SHA1.hash(data: raw)) == session || Merkle.truncated(sha256) == session
    }
}

// MARK: Hash proofs (BEP 52 peer messages 21 and 22)

enum HashProof {
    /// Layers above the leaf layer up to the file's root, for a file of this size (the leaf layer is layer 0).
    static func treeHeight(fileLength: Int64, pieceLength: Int64) -> Int? {
        guard Merkle.validPieceLength(pieceLength), fileLength > 0 else { return nil }
        func log2(_ n: Int) -> Int { n.trailingZeroBitCount }
        let blocks = Int((fileLength + Int64(Merkle.blockSize) - 1) / Int64(Merkle.blockSize))
        if fileLength <= pieceLength { return log2(Merkle.nextPowerOfTwo(blocks)) }
        let pieces = Int((fileLength + pieceLength - 1) / pieceLength)
        return log2(Merkle.nextPowerOfTwo(pieces)) + log2(Merkle.blocksPerPiece(pieceLength))
    }

    /// The layer a file's pieces hash to: `log2(blocks per piece)`.
    static func pieceLayerNumber(pieceLength: Int64) -> Int { Merkle.blocksPerPiece(pieceLength).trailingZeroBitCount }

    /// Checks a `hashes` reply against the file's known pieces root. Returns the base-layer hashes it carries (`length` of them) only if hashing them together and then up through the
    /// uncle hashes ends exactly at `piecesRoot`. Strict: the uncle count must be exactly what reaches the root; anything else is nil.
    static func verify(_ m: PeerWire.HashMessage, piecesRoot: Data, fileLength: Int64, pieceLength: Int64) -> [Data]? {
        guard m.kind == .hashes, m.piecesRoot == piecesRoot, piecesRoot.count == Merkle.hashSize, let height = treeHeight(fileLength: fileLength, pieceLength: pieceLength) else { return nil }
        let n = m.length
        guard Merkle.isPowerOfTwo(n), n >= 2, n <= PeerWire.maxHashesPerRequest, m.index >= 0, m.index % n == 0 else { return nil }
        let lg = n.trailingZeroBitCount
        let layer = m.baseLayer
        guard layer >= 0, layer + lg <= height, m.index + n <= (1 << (height - layer)) else { return nil }
        let uncleCount = height - layer - lg
        guard m.hashes.count == n + uncleCount, m.hashes.allSatisfy({ $0.count == Merkle.hashSize }) else { return nil }
        let base = Array(m.hashes[0..<n])
        guard var node = Merkle.root(of: base) else { return nil }
        var position = m.index / n
        for uncle in m.hashes[n...] {
            node = position % 2 == 0 ? Merkle.sha256(node, uncle) : Merkle.sha256(uncle, node)
            position /= 2
        }
        return node == piecesRoot ? base : nil
    }

    /// The requests that fetch a whole piece layer: pieces roots are asked for in runs of up to 512, each with a full proof. Replies are checked with `verify`.
    static func requestsForPieceLayer(piecesRoot: Data, fileLength: Int64, pieceLength: Int64) -> [PeerWire.HashMessage] {
        guard fileLength > pieceLength, let height = treeHeight(fileLength: fileLength, pieceLength: pieceLength) else { return [] }
        let layer = pieceLayerNumber(pieceLength: pieceLength)
        let nodes = 1 << (height - layer)
        let run = min(PeerWire.maxHashesPerRequest, nodes)
        return stride(from: 0, to: nodes, by: run).map {
            PeerWire.HashMessage(kind: .request, piecesRoot: piecesRoot, baseLayer: layer, index: $0, length: run, proofLayers: height - layer - 1)
        }
    }

    /// The reply to a request for hashes of the PIECE layer, from a layer we hold (nil means: answer with a reject). Only the piece layer is served (BEP 52 requires only the leaf and piece layers;
    /// serving leaves would need the file's data). The reply carries `length` hashes from `index`, then the uncle hashes the request's `proofLayers` asks for, nearest the base first, padded with the
    /// padding-piece hash beyond the last real piece.
    static func answer(_ r: PeerWire.HashMessage, layer: Data, fileLength: Int64, pieceLength: Int64) -> PeerWire.HashMessage? {
        guard r.kind == .request, fileLength > pieceLength, layer.count % Merkle.hashSize == 0, let height = treeHeight(fileLength: fileLength, pieceLength: pieceLength),
              let pad = Merkle.padPieceHash(blocksPerPiece: Merkle.blocksPerPiece(pieceLength)) else { return nil }
        let base = pieceLayerNumber(pieceLength: pieceLength)
        let n = r.length
        guard r.baseLayer == base, Merkle.isPowerOfTwo(n), n >= 2, n <= PeerWire.maxHashesPerRequest, r.index >= 0, r.index % n == 0, r.proofLayers >= 0, r.proofLayers <= PeerWire.maxProofLayers else { return nil }
        let total = 1 << (height - base)
        let lg = n.trailingZeroBitCount
        guard r.index + n <= total, base + lg <= height else { return nil }
        let real = layer.count / Merkle.hashSize
        guard real == Int((fileLength + pieceLength - 1) / pieceLength), total <= 1 << 17 else { return nil }          // a layer that large is not answered from (the cost of one answer grows with it)
        var level: [Data] = (0..<real).map { layer.subdata(in: ($0 * Merkle.hashSize)..<(($0 + 1) * Merkle.hashSize)) } + [Data](repeating: pad, count: total - real)
        let run = Array(level[r.index..<(r.index + n)])
        func up(_ l: [Data]) -> [Data] { stride(from: 0, to: l.count, by: 2).map { Merkle.sha256(l[$0], l[$0 + 1]) } }
        for _ in 0..<lg { level = up(level) }
        var position = r.index / n
        let wanted = min(max(0, r.proofLayers - lg + 1), height - base - lg)
        var uncles: [Data] = []
        for _ in 0..<wanted { uncles.append(level[position ^ 1]); level = up(level); position /= 2 }
        return PeerWire.HashMessage(kind: .hashes, piecesRoot: r.piecesRoot, baseLayer: r.baseLayer, index: r.index, length: n, proofLayers: r.proofLayers, hashes: run + uncles)
    }

    /// Joins verified runs (`verify`'s result, with the index each was asked at) into the file's piece layer: only the real piece roots, and only if they hash to the file's root.
    static func assemblePieceLayer(runs: [Int: [Data]], piecesRoot: Data, fileLength: Int64, pieceLength: Int64) -> Data? {
        let count = Int((fileLength + pieceLength - 1) / pieceLength)
        var out = Data()
        var next = 0
        for start in runs.keys.sorted() {
            guard start == next, let run = runs[start] else { return nil }
            out.append(contentsOf: run.joined())
            next += run.count
            if next >= count { break }
        }
        guard next >= count else { return nil }
        let layer = out.prefix(count * Merkle.hashSize)
        return Merkle.layerMatches(Data(layer), fileLength: fileLength, pieceLength: pieceLength, piecesRoot: piecesRoot) ? Data(layer) : nil
    }
}

// MARK: Piece layers kept beside the details of a torrent

/// A version 2 torrent whose details came from a magnet link has no piece layers until peers supply them; the ones fetched are kept in `.layers` beside the other saved details so a restart does
/// not fetch them again. Format: u32 count, then for each: 32-byte pieces root, u32 length, the hashes. Nothing read back is believed: every layer is checked against its file's root.
enum LayerStore {
    static let maxBytes = 64 * 1024 * 1024

    static func encode(_ layers: [Data: Data]) -> Data {
        func u32(_ v: Int) -> [UInt8] { withUnsafeBytes(of: UInt32(truncatingIfNeeded: v).bigEndian, Array.init) }
        var out = Data(u32(layers.count))
        for (root, layer) in layers.sorted(by: { $0.key.lexicographicallyPrecedes($1.key) }) { out.append(root); out.append(contentsOf: u32(layer.count)); out.append(layer) }
        return out
    }

    /// The layers in `data` that really belong to `meta` (right root, right count, hashing up to the root).
    static func decode(_ data: Data, for meta: TorrentMetainfo) -> [Data: Data] {
        guard data.count >= 4, data.count <= maxBytes else { return [:] }
        let b = [UInt8](data)
        func u32(_ i: Int) -> Int { Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) }
        let count = u32(0)
        guard count <= TorrentMetainfo.Limit.maxFiles else { return [:] }
        var out: [Data: Data] = [:], at = 4
        for _ in 0..<count {
            guard at + 36 <= b.count else { break }
            let root = Data(b[at..<(at + 32)]); let n = u32(at + 32); at += 36
            guard n >= 0, n % 32 == 0, at + n <= b.count else { break }
            let layer = Data(b[at..<(at + n)]); at += n
            if let f = meta.files.first(where: { !$0.isPadding && $0.pieceRoot == root && $0.length > meta.pieceLength }),
               Merkle.layerMatches(layer, fileLength: f.length, pieceLength: meta.pieceLength, piecesRoot: root) { out[root] = layer }
        }
        return out
    }
}

// MARK: Whole-file check

extension TorrentStorage {
    /// Whether the file at `url` has this version 2 `pieces root`, read in 16 KiB blocks so memory stays at one piece's worth of block hashes however large the file is. `isCancelled` is asked
    /// every few blocks; a cancelled check throws `CancellationError`. An empty file has no root and is never a match.
    static func verifyFile(url: URL, expectedRoot: Data, pieceLength: Int64, isCancelled: () -> Bool = { false }) throws -> Bool {
        guard Merkle.validPieceLength(pieceLength), expectedRoot.count == Merkle.hashSize else { return false }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw Failure.io("The file could not be opened (\(String(cString: strerror(errno)))).") }
        defer { Darwin.close(fd) }
        let perPiece = Merkle.blocksPerPiece(pieceLength)
        var leaves: [Data] = []
        leaves.reserveCapacity(perPiece)
        var pieceRoots: [Data] = []
        var buffer = [UInt8](repeating: 0, count: Merkle.blockSize)
        var offset: Int64 = 0
        var blocks = 0
        while true {
            var got = 0
            let size = buffer.count
            while got < size {
                let done = got
                let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + done, size - done, off_t(offset) + off_t(done)) }
                if n < 0 { if errno == EINTR { continue }; throw Failure.io("The file could not be read (\(String(cString: strerror(errno)))).") }
                if n == 0 { break }
                got += n
            }
            if got == 0 { break }
            leaves.append(Merkle.sha256(Data(buffer[0..<got])))
            offset += Int64(got)
            blocks += 1
            if leaves.count == perPiece {
                guard let r = Merkle.root(of: leaves) else { return false }
                pieceRoots.append(r); leaves.removeAll(keepingCapacity: true)
            }
            if blocks % 64 == 0, isCancelled() || Task.isCancelled { throw CancellationError() }
            if got < buffer.count { break }
        }
        if isCancelled() || Task.isCancelled { throw CancellationError() }
        guard offset > 0 else { return false }
        if offset <= pieceLength {
            if let only = pieceRoots.first { return only == expectedRoot }
            return Merkle.root(of: leaves) == expectedRoot
        }
        if !leaves.isEmpty {
            guard let r = Merkle.root(of: leaves, paddedTo: perPiece) else { return false }
            pieceRoots.append(r)
        }
        return Merkle.rootOfPieceLayer(pieceRoots, pieceLength: pieceLength) == expectedRoot
    }
}
