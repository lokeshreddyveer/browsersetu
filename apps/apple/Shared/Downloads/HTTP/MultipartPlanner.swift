import Foundation

/// One durable piece of a multipart download: a fixed byte range with a stable index. Boundaries are decided once, from the file's size, and never change for the life of the task,
/// so what a restart finds on disk and in the database always refers to the same ranges.
struct PieceRecord: Equatable, Sendable {
    enum State: String, Sendable { case pending, done }

    var index: Int
    var start: Int64
    var end: Int64                       // inclusive
    var state: State = .pending
    /// SHA-256 (hex) of the piece as it was written, kept so a piece completed in an earlier run can be checked again before the file is finalised.
    var checksum: String?
    /// The attempt in which it was completed (0 while pending).
    var session = 0

    var length: Int64 { end - start + 1 }
}

enum MultipartPlanner {
    /// Below this a file is not worth several connections: the setup costs more than it saves.
    static let minimumTotal: Int64 = 16 << 20
    static let minimumPieceSize: Int64 = 4 << 20
    static let defaultPieceSize: Int64 = 8 << 20
    /// Bounds the rows and the bookkeeping, however big the file is.
    static let maxPieces = 512
    /// The most connections one download may use, and the default (conservative: more is not automatically faster).
    static let maxConnections = 8
    static let defaultConnections = 4

    static let maxPieceSize: Int64 = 64 << 20
    /// About this many pieces for a file, so a pool of workers always has several to share out (a slow connection then holds up one small piece, not a quarter of the file).
    static let targetPieceCount: Int64 = 32

    /// A size in bytes, rounded up to a whole MiB, from the file's size alone (it must never depend on how many connections happen to be in use, because it is saved and has to mean the
    /// same thing after a restart): about `targetPieceCount` pieces, never smaller than 4 MiB or larger than 64 MiB, and never so small that the count passes `maxPieces`.
    static func pieceSize(total: Int64) -> Int64 {
        func mib(_ bytes: Int64) -> Int64 { ((bytes + (1 << 20) - 1) >> 20) << 20 }
        let wanted = min(maxPieceSize, max(minimumPieceSize, mib((total + targetPieceCount - 1) / targetPieceCount)))
        let forCount = mib((total + Int64(maxPieces) - 1) / Int64(maxPieces))
        return max(wanted, forCount)
    }

    /// Contiguous, non-overlapping pieces that cover every byte from 0 to total - 1 exactly once. Empty for a size that is not positive.
    static func plan(total: Int64) -> [PieceRecord] {
        guard total > 0 else { return [] }
        let size = pieceSize(total: total)
        var pieces: [PieceRecord] = []
        var start: Int64 = 0
        var index = 0
        while start < total {
            let end = min(total - 1, start + size - 1)     // no overflow: start + size - 1 is far below Int64.max for any real file
            pieces.append(PieceRecord(index: index, start: start, end: end))
            start = end + 1
            index += 1
        }
        return pieces
    }

    /// How many connections to use: what was configured, never more than there are pieces, and never more than the cap. At least one.
    /// A website that takes this long to answer one request makes every extra connection cost a full round of set-up before it moves a byte. Measured (24 MiB, 300 ms before the first
    /// byte, no per-connection limit): one connection 1.8 s, four connections 2.4 s. For a file this size or smaller the extra connections cannot pay for themselves.
    static let slowAnswerSeconds = 0.25
    static let slowAnswerMaxTotal: Int64 = 64 << 20

    /// True when pieces would probably be slower than one transfer: a slow first answer on a file small enough that set-up dominates. A large file keeps its pieces, because the
    /// gain from several connections grows with the size while their set-up cost does not.
    static func isCounterproductive(probeSeconds: Double, total: Int64) -> Bool {
        probeSeconds >= slowAnswerSeconds && total <= slowAnswerMaxTotal
    }

    static func connections(total: Int64, configured: Int) -> Int {
        let pieces = plan(total: total).count
        return max(1, min(configured, maxConnections, pieces))
    }

    enum CoverageProblem: Equatable, Sendable {
        case empty, gap(after: Int64), overlap(at: Int64), wrongEnd(Int64), badIndex(Int), wrongLength(Int), notDone(Int)
    }

    /// Whether the pieces cover the whole file exactly: in order, no gap, no overlap, ending at the last byte, and (when `requireDone`) every one finished.
    static func coverageProblem(_ pieces: [PieceRecord], total: Int64, requireDone: Bool) -> CoverageProblem? {
        guard !pieces.isEmpty, total > 0 else { return .empty }
        var next: Int64 = 0
        for (position, piece) in pieces.enumerated() {
            if piece.index != position { return .badIndex(piece.index) }
            if piece.start > next { return .gap(after: next - 1) }
            if piece.start < next { return .overlap(at: piece.start) }
            if piece.end < piece.start { return .wrongLength(piece.index) }
            if requireDone, piece.state != .done { return .notDone(piece.index) }
            next = piece.end + 1
        }
        return next == total ? nil : .wrongEnd(next - 1)
    }
}

/// Whether a source is demonstrably suitable for multipart: everything that was verified, never just a header that claims it.
struct MultipartEligibility: Equatable, Sendable {
    var total: Int64
    var etag: String?
    var lastModified: String?

    enum Refusal: String, Equatable, Sendable, Error {
        case origin = "the request is not the person's own"
        case size = "the file is too small to gain from several connections"
        case unknownSize = "the file's size is not known"
        case noRangeSupport = "the server did not answer a range request with a correct partial response"
        case wrongRange = "the server's answer to the range request was not for the range asked"
        case encoded = "the server compresses the file, so byte positions do not match the file"
        case noValidator = "the server gives no way to tell whether the file changes between requests"
        case weakValidator = "the server's version tag is weak, which cannot guard byte ranges"
    }

    /// `status` and the headers are those of a `Range: bytes=0-0` request.
    static func evaluate(origin: DownloadRequestOrigin, status: Int, headers: (String) -> String?, minimumTotal: Int64 = MultipartPlanner.minimumTotal) -> Result<MultipartEligibility, Refusal> {
        guard origin == .user else { return .failure(.origin) }
        guard status == 206 else { return .failure(.noRangeSupport) }
        guard let range = HTTPResponseRules.parseContentRange(headers("Content-Range")) else { return .failure(.wrongRange) }
        guard range.start == 0, range.end == 0 else { return .failure(.wrongRange) }
        guard let total = range.total, total > 0 else { return .failure(.unknownSize) }
        let encoding = (headers("Content-Encoding") ?? "identity").lowercased().trimmingCharacters(in: .whitespaces)
        guard encoding.isEmpty || encoding == "identity" else { return .failure(.encoded) }
        guard total >= minimumTotal else { return .failure(.size) }
        let etag = headers("ETag"), modified = headers("Last-Modified")
        if let etag, etag.hasPrefix("W/") { return modified == nil ? .failure(.weakValidator) : .success(MultipartEligibility(total: total, etag: nil, lastModified: modified)) }
        guard etag != nil || modified != nil else { return .failure(.noValidator) }
        return .success(MultipartEligibility(total: total, etag: etag, lastModified: modified))
    }
}
