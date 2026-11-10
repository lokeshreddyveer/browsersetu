import Foundation

/// How the eD2k network names a file and checks its parts. MD4 throughout, which is a compatibility requirement and not a security one: it says "this is the file the link names", and that
/// a part arrived undamaged; a deliberately made file can match it. The app says that wherever it shows the result.
enum ED2KHash {
    static let partSize: Int64 = 9_728_000
    static let blockSize = 184_320
    static let emptyHash = MD4.hash(Data())

    /// Data parts: how many pieces of 9,728,000 bytes (the last shorter) the file is cut into.
    static func partCount(size: Int64) -> Int { size <= 0 ? 0 : Int((size + partSize - 1) / partSize) }

    static func partLength(_ index: Int, size: Int64) -> Int64 {
        guard index >= 0, index < partCount(size: size) else { return 0 }
        return min(partSize, size - Int64(index) * partSize)
    }

    /// The file hash from the hashes of its data parts. One part: that part's hash. Several: the hash of the hashes put end to end.
    static func fileHash(partHashes: [Data]) -> Data { partHashes.count == 1 ? partHashes[0] : MD4.hash(partHashes.reduce(Data(), +)) }

    /// Every file hash that is right for these part hashes. A file whose size is an exact multiple of the part size has two: the sources disagree on whether a final empty part is counted
    /// (eMule counts it, the plain rule does not), so a hash made either way is accepted.
    static func acceptableFileHashes(partHashes: [Data], size: Int64) -> [Data] {
        var out = [fileHash(partHashes: partHashes)]
        if size % partSize == 0 { out.append(MD4.hash((partHashes + [emptyHash]).reduce(Data(), +))) }
        return out
    }

    /// The part hashes that can be trusted, or nil. `hashes` may have one entry per data part, or one more (the empty final part). They must add up to the hash the link promised.
    static func validatedPartHashes(_ hashes: [Data], fileHash: Data, size: Int64) -> [Data]? {
        let parts = partCount(size: size)
        guard parts > 0, hashes.allSatisfy({ $0.count == 16 }) else { return nil }
        var data = hashes
        if hashes.count == parts + 1 { guard hashes.last == emptyHash else { return nil }; data.removeLast() }
        guard data.count == parts else { return nil }
        return acceptableFileHashes(partHashes: data, size: size).contains(fileHash) ? data : nil
    }

    /// A file of one part has no separate list of part hashes: the file hash is the part's hash.
    /// Not for a file of exactly one part size: its hash may be the eMule form (the part hash and an empty part hash hashed together), so it is checked through a hash list instead.
    static func singlePartHashes(fileHash: Data, size: Int64) -> [Data]? { partCount(size: size) == 1 && size % partSize != 0 ? [fileHash] : nil }

    /// Hashes a whole file stream by stream (used by tests and by the final check).
    static func hashes(of data: Data) -> (parts: [Data], file: Data) {
        var parts: [Data] = []
        var offset = 0
        while offset < data.count || (offset == 0 && data.isEmpty) {
            let n = min(Int(partSize), data.count - offset)
            parts.append(MD4.hash(data.subdata(in: offset..<(offset + n)))); offset += n
            if data.isEmpty { break }
        }
        return (parts, fileHash(partHashes: parts))
    }
}
