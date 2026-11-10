import CryptoKit
import Foundation

// DX-06 fast resume: the trust model. Pure and self-contained (no runner or session code).
//
// THE RULE: fast resume is an optimisation, never permission to trust arbitrary data. A piece is trusted without a re-hash only if there is recorded evidence that it was verified AND
// every file it touches still has the identity it had at that moment. Anything else is re-hashed. Nothing in this file deletes anything: an unreadable file is reported, never removed.
// (This mirrors the earlier HTTP crash-recovery defect, where a file was believed verified because its SIZE matched.)

// MARK: - File identity

/// What `lstat` says about a file. Size, modification time (nanoseconds), inode and device must ALL be equal for the identity to match.
///
/// Residual risk (documented, not hidden): an in-place edit that keeps the size, restores the modification time (`utimes`) and keeps the inode evades this check, as does a restore
/// from backup that reproduces all four. APFS clones (`clonefile`) get a NEW inode, so a clone of a file does not match the original; a copy-on-write edit of a cloned file keeps the
/// inode but updates mtime. APFS mtime resolution is 1 ns, but other volumes (HFS+, FAT, network shares) round to 1 s or 2 s, so edits within that window can hide there; that is why
/// `ResumeTrust` also demands that the mtime is not newer than the moment of verification. The `.rehashAll` trust level ("verify on resume") removes the risk entirely at the cost of reading every byte.
struct TorrentFileIdentity: Codable, Equatable, Sendable {
    var size: Int64
    /// Modification time in nanoseconds since 1970 (st_mtimespec).
    var mtimeNanos: Int64
    var inode: UInt64
    var device: Int64

    /// Captures the identity of a regular file WITHOUT following symlinks. Missing files, symlinks, directories and other special files give nil: none of them is trusted evidence.
    static func capture(_ url: URL) -> TorrentFileIdentity? {
        var st = stat()
        let ok = url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return lstat(path, &st) == 0
        }
        guard ok, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        let nanos = Int64(st.st_mtimespec.tv_sec) &* 1_000_000_000 &+ Int64(st.st_mtimespec.tv_nsec)
        return TorrentFileIdentity(size: Int64(st.st_size), mtimeNanos: nanos, inode: UInt64(st.st_ino), device: Int64(st.st_dev))
    }

    /// All four fields equal.
    func matches(_ other: TorrentFileIdentity) -> Bool { self == other }

    var modified: Date { Date(timeIntervalSince1970: Double(mtimeNanos) / 1_000_000_000) }
}

/// How much a resume believes.
enum ResumeTrustLevel: String, Codable, Sendable {
    /// Default: verified pieces whose files are unchanged are trusted; anything suspicious is re-hashed.
    case identityOnly
    /// "Verify on resume": nothing is trusted, every piece is re-hashed.
    case rehashAll
}

// MARK: - The record

struct ResumeRecord: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let maxFileBytes = 4 * 1024 * 1024

    var version: Int
    /// Lowercase hex of the info-hash (v1: 40 characters; v2 truncated: 40 characters of the SHA-256).
    var infoHash: String
    /// "v1", "v2" or "hybrid". The record is version-aware but never hashes anything itself.
    var torrentVersion: String
    /// Lowercase hex of the v2 info-hash when the torrent has one (v2 / hybrid).
    var infoHashV2: String?
    var pieceCount: Int
    var pieceLength: Int64
    /// One bit per piece, least significant bit first within a byte; bits past `pieceCount` are zero.
    var verifiedBitmap: Data
    var verifiedAt: Date
    /// Identity of each data file (by file index) at the time `verifiedAt`.
    var files: [Int: TorrentFileIdentity]
    /// Identity of the '.unselected' scratch file at that time, nil when it did not exist.
    var scratch: TorrentFileIdentity?
    var uploadedBytes: UInt64?
    var downloadedBytes: UInt64?
    var seedingSeconds: Double?
    var lastVerifiedFullyAt: Date?
    var checksum: String

    enum Failure: Error, Equatable { case tooLarge, notARegularFile, unreadable, badJSON, badChecksum, wrongTorrent, wrongShape, unsupportedVersion }

    // MARK: bitmap

    static func bitmap(for pieces: Set<Int>, count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: (max(0, count) + 7) / 8)
        for p in pieces where p >= 0 && p < count { bytes[p / 8] |= UInt8(1 << (p % 8)) }
        return Data(bytes)
    }

    func isVerified(_ piece: Int) -> Bool {
        guard piece >= 0, piece < pieceCount, verifiedBitmap.count == (pieceCount + 7) / 8 else { return false }
        return verifiedBitmap[verifiedBitmap.startIndex + piece / 8] & UInt8(1 << (piece % 8)) != 0
    }

    var verifiedPieces: Set<Int> { Set((0..<max(0, pieceCount)).filter { isVerified($0) }) }

    // MARK: construction

    /// Builds a record and seals it with its checksum.
    init(infoHash: String, torrentVersion: String = "v1", infoHashV2: String? = nil, pieceCount: Int, pieceLength: Int64, verified: Set<Int>, verifiedAt: Date, files: [Int: TorrentFileIdentity], scratch: TorrentFileIdentity? = nil,
         uploadedBytes: UInt64? = nil, downloadedBytes: UInt64? = nil, seedingSeconds: Double? = nil, lastVerifiedFullyAt: Date? = nil) {
        self.version = Self.currentVersion
        self.infoHash = infoHash.lowercased()
        self.torrentVersion = torrentVersion
        self.infoHashV2 = infoHashV2?.lowercased()
        self.pieceCount = pieceCount
        self.pieceLength = pieceLength
        self.verifiedBitmap = Self.bitmap(for: verified, count: pieceCount)
        self.verifiedAt = Self.roundedToMillis(verifiedAt)
        self.files = files
        self.scratch = scratch
        self.uploadedBytes = uploadedBytes; self.downloadedBytes = downloadedBytes; self.seedingSeconds = seedingSeconds
        self.lastVerifiedFullyAt = lastVerifiedFullyAt.map(Self.roundedToMillis)
        self.checksum = ""
        self.checksum = computeChecksum()
    }

    /// Nothing verified yet: what a torrent starts with. (An old DX-05 sidecar has no record at all, which the runner treats the same way: `ResumeTrust.Decision.allRehash`.)
    static func empty(for meta: TorrentMetainfo, torrentVersion: String = "v1", infoHashV2: String? = nil, now: Date = Date()) -> ResumeRecord {
        ResumeRecord(infoHash: meta.infoHashHex, torrentVersion: torrentVersion, infoHashV2: infoHashV2, pieceCount: meta.pieceCount, pieceLength: meta.pieceLength, verified: [], verifiedAt: now, files: [:])
    }

    /// A new record after `pieces` were verified (hashed) just now. `identities` are the CURRENT identities of the data files (and `scratch` of the scratch file) captured right after
    /// the verification. Verified set = old ∪ `pieces`, except that an older piece touching a file whose identity differs from the recorded one is dropped (it was verified against
    /// bytes that may be gone): refreshing identities must never launder an earlier verification onto changed data. Counters carry over unless replaced.
    func bumped(afterVerifying pieces: Set<Int>, identities: [Int: TorrentFileIdentity], scratch newScratch: TorrentFileIdentity? = nil, meta: TorrentMetainfo, isPaddingFile: (Int) -> Bool = { _ in false }, now: Date,
                uploadedBytes: UInt64? = nil, downloadedBytes: UInt64? = nil, seedingSeconds: Double? = nil, fullyVerified: Bool = false) -> ResumeRecord {
        var kept = Set<Int>()
        if meta.infoHashHex == infoHash, meta.pieceCount == pieceCount, meta.pieceLength == pieceLength {
            for p in verifiedPieces {
                let touched = meta.segments(offset: Int64(p) * meta.pieceLength, length: meta.length(ofPiece: p)).map(\.file).filter { !isPaddingFile($0) }
                if touched.allSatisfy({ files[$0] != nil && files[$0] == identities[$0] }) { kept.insert(p) }
            }
        }
        let valid = pieces.filter { $0 >= 0 && $0 < pieceCount }
        return ResumeRecord(infoHash: infoHash, torrentVersion: torrentVersion, infoHashV2: infoHashV2, pieceCount: pieceCount, pieceLength: pieceLength, verified: kept.union(valid), verifiedAt: now, files: identities, scratch: newScratch,
                            uploadedBytes: uploadedBytes ?? self.uploadedBytes, downloadedBytes: downloadedBytes ?? self.downloadedBytes,
                            seedingSeconds: seedingSeconds ?? self.seedingSeconds, lastVerifiedFullyAt: fullyVerified ? now : lastVerifiedFullyAt)
    }

    // MARK: checksum

    private static func roundedToMillis(_ date: Date) -> Date { Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000) }
    private static func millis(_ date: Date) -> Int64 { let v = (date.timeIntervalSince1970 * 1000).rounded(); return v.isFinite ? Int64(max(-4e15, min(4e15, v))) : 0 }

    /// SHA-256 over a canonical, length-prefixed encoding of every field except `checksum` itself (dictionary order and JSON formatting do not matter).
    func computeChecksum() -> String {
        var d = Data()
        func int(_ v: Int64) { var x = v.bigEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func bytes(_ s: Data) { int(Int64(s.count)); d.append(s) }
        func text(_ s: String) { bytes(Data(s.utf8)) }
        func identity(_ i: TorrentFileIdentity?) { if let i { int(1); int(i.size); int(i.mtimeNanos); int(Int64(bitPattern: i.inode)); int(i.device) } else { int(0) } }
        func count(_ n: UInt64?) { if let n { int(1); int(Int64(bitPattern: n)) } else { int(0) } }
        func date(_ v: Date?) { if let v { int(1); int(Self.millis(v)) } else { int(0) } }
        text("BrowserSetu.ResumeRecord"); int(Int64(version)); text(infoHash); text(torrentVersion); text(infoHashV2 ?? "-"); int(infoHashV2 == nil ? 0 : 1); int(Int64(pieceCount)); int(pieceLength); bytes(verifiedBitmap); date(verifiedAt)
        int(Int64(files.count))
        for key in files.keys.sorted() { int(Int64(key)); identity(files[key]) }
        identity(scratch); count(uploadedBytes); count(downloadedBytes)
        if let s = seedingSeconds { int(1); int(Int64(bitPattern: s.bitPattern)) } else { int(0) }
        date(lastVerifiedFullyAt)
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    var checksumIsValid: Bool { checksum == computeChecksum() }

    // MARK: persistence

    private static func encoder() -> JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .millisecondsSince1970; e.outputFormatting = [.sortedKeys]; return e }
    private static func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .millisecondsSince1970; return d }

    /// Atomic: a temporary file in the same folder is written and fsynced, then renamed over the old one (replaceItemAt when it exists, else moveItem; like `TorrentRunner.saveSidecar`).
    /// A crash leaves the old whole file or the new whole file, never half of one.
    /// The record as bytes (for the sidecar blob). `decode` applies the same rules as `load`.
    func encoded() -> Data { (try? Self.encoder().encode(self)) ?? Data() }

    static func decode(_ data: Data, expecting meta: TorrentMetainfo? = nil, torrentVersion: String? = nil, infoHashV2: String? = nil) -> ResumeRecord? {
        try? validated(data, expecting: meta, torrentVersion: torrentVersion, infoHashV2: infoHashV2)
    }

    func write(to url: URL) throws {
        let data = try Self.encoder().encode(self)
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
        try? FileManager.default.removeItem(at: temp)
        guard FileManager.default.createFile(atPath: temp.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let handle = try FileHandle(forWritingTo: temp)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() } catch { try? handle.close(); try? FileManager.default.removeItem(at: temp); throw error }
        if FileManager.default.fileExists(atPath: url.path) { _ = try FileManager.default.replaceItemAt(url, withItemAt: temp) } else { try FileManager.default.moveItem(at: temp, to: url) }
    }

    /// Reads a record. Refuses anything over 4 MiB, a symlink or non-regular file, bad JSON, a wrong checksum, another torrent, or a bitmap/count that do not fit. Never traps on garbage.
    static func load(from url: URL, expecting meta: TorrentMetainfo? = nil, expectingInfoHash: String? = nil, torrentVersion: String? = nil, infoHashV2: String? = nil) throws -> ResumeRecord {
        var st = stat()
        let ok = url.withUnsafeFileSystemRepresentation { p -> Bool in
            guard let p else { return false }
            return lstat(p, &st) == 0
        }
        guard ok else { throw Failure.unreadable }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw Failure.notARegularFile }
        guard st.st_size <= Int64(maxFileBytes) else { throw Failure.tooLarge }
        guard let data = try? Data(contentsOf: url) else { throw Failure.unreadable }
        return try validated(data, expecting: meta, expectingInfoHash: expectingInfoHash, torrentVersion: torrentVersion, infoHashV2: infoHashV2)
    }

    private static func validated(_ data: Data, expecting meta: TorrentMetainfo?, expectingInfoHash: String? = nil, torrentVersion: String?, infoHashV2: String?) throws -> ResumeRecord {
        guard data.count <= maxFileBytes else { throw Failure.tooLarge }
        guard let record = try? decoder().decode(ResumeRecord.self, from: data) else { throw Failure.badJSON }
        guard record.version == currentVersion else { throw Failure.unsupportedVersion }
        guard record.checksumIsValid else { throw Failure.badChecksum }
        guard record.pieceCount >= 0, record.pieceCount <= TorrentMetainfo.Limit.maxPieces, record.pieceLength > 0, record.verifiedBitmap.count == (record.pieceCount + 7) / 8 else { throw Failure.wrongShape }
        if record.pieceCount % 8 != 0, let last = record.verifiedBitmap.last, last >> UInt8(record.pieceCount % 8) != 0 { throw Failure.wrongShape }
        if let expected = expectingInfoHash?.lowercased() ?? meta?.infoHashHex, expected != record.infoHash { throw Failure.wrongTorrent }
        if let meta, meta.pieceCount != record.pieceCount || meta.pieceLength != record.pieceLength { throw Failure.wrongShape }
        if let torrentVersion, torrentVersion != record.torrentVersion || infoHashV2?.lowercased() != record.infoHashV2 { throw Failure.wrongTorrent }
        return record
    }
}

// MARK: - Trust decision

enum ResumeTrust {
    /// Slack between a file's mtime and `verifiedAt` (coarse-resolution volumes, clock rounding).
    static let mtimeTolerance: TimeInterval = 2

    enum Reason: Equatable, Sendable {
        case noRecord, otherTorrent, rehashAll
        case notVerified              // the record does not mark the piece verified
        case missingFile(Int)         // absent, a symlink, or not a regular file
        case noRecordedIdentity(Int)  // the record has no identity for that file
        case sizeChanged(Int), mtimeChanged(Int), inodeChanged(Int), deviceChanged(Int)
        case newerThanVerification(Int)
        case lengthMismatch(Int)      // size differs from the metainfo length
        case scratchChanged           // the '.unselected' scratch file is missing or differs from the record
    }

    struct Decision: Equatable, Sendable {
        var trusted: Set<Int>
        var mustRehash: Set<Int>
        /// Why each piece in `mustRehash` is there.
        var reasons: [Int: Reason]

        /// Nothing trusted: no record (an old sidecar), another torrent, or `.rehashAll`.
        static func allRehash(pieceCount: Int, reason: Reason = .noRecord) -> Decision {
            let all = Set(0..<max(0, pieceCount))
            return Decision(trusted: [], mustRehash: all, reasons: Dictionary(uniqueKeysWithValues: all.map { ($0, reason) }))
        }
    }

    /// `trusted` and `mustRehash` partition every piece of the torrent. Notes on what is compared:
    /// - `currentIdentities[i]` is `TorrentFileIdentity.capture` of data file i (nil or absent = missing/symlink). Zero-length files are never consulted.
    /// - `unselectedFiles`: files whose bytes live in the '.unselected' scratch file (DX-05). A piece touching one is trusted only when `currentScratch` equals the recorded scratch
    ///   identity (and is not newer than the verification); the unselected file itself need not exist.
    /// - In this engine a data file has its FULL metainfo length from the start (it is preallocated / sparse), so both the recorded and the current size must equal the metainfo length,
    ///   even while the download is partial. A file at any other size is never trusted, and size alone is never enough.
    static func evaluate(record: ResumeRecord?, meta: TorrentMetainfo, currentIdentities: [Int: TorrentFileIdentity?], currentScratch: TorrentFileIdentity? = nil, unselectedFiles: Set<Int> = [], isPaddingFile: (Int) -> Bool = { _ in false }, torrentVersion: String = "v1", infoHashV2: String? = nil,
                         tolerance: TimeInterval = mtimeTolerance, trustLevel: ResumeTrustLevel = .identityOnly) -> Decision {
        let count = meta.pieceCount
        guard let record else { return .allRehash(pieceCount: count, reason: .noRecord) }
        guard record.infoHash == meta.infoHashHex, record.torrentVersion == torrentVersion, record.infoHashV2 == infoHashV2?.lowercased(), record.pieceCount == count, record.pieceLength == meta.pieceLength, record.verifiedBitmap.count == (count + 7) / 8, record.checksumIsValid else {
            return .allRehash(pieceCount: count, reason: .otherTorrent)
        }
        if trustLevel == .rehashAll { return .allRehash(pieceCount: count, reason: .rehashAll) }

        var judged: [Int: Reason?] = [:]
        func problem(of index: Int) -> Reason? {
            if let cached = judged[index] { return cached }
            let found = judge(index)
            judged[index] = .some(found)
            return found
        }
        func judge(_ index: Int) -> Reason? {
            guard let slot = currentIdentities[index], let current = slot else { return .missingFile(index) }
            guard let old = record.files[index] else { return .noRecordedIdentity(index) }
            let length = meta.files[index].length
            if old.size != length || current.size != length { return old.size != current.size ? .sizeChanged(index) : .lengthMismatch(index) }
            if current.mtimeNanos != old.mtimeNanos { return .mtimeChanged(index) }
            if current.inode != old.inode { return .inodeChanged(index) }
            if current.device != old.device { return .deviceChanged(index) }
            if current.modified.timeIntervalSince(record.verifiedAt) > tolerance { return .newerThanVerification(index) }
            return nil
        }
        let scratchOK: Bool = {
            guard let now = currentScratch, let old = record.scratch else { return false }
            return now == old && now.modified.timeIntervalSince(record.verifiedAt) <= tolerance
        }()

        var decision = Decision(trusted: [], mustRehash: [], reasons: [:])
        for piece in 0..<count {
            guard record.isVerified(piece) else { decision.mustRehash.insert(piece); decision.reasons[piece] = .notVerified; continue }
            let segs = meta.segments(offset: Int64(piece) * meta.pieceLength, length: meta.length(ofPiece: piece))
            var reason: Reason? = segs.isEmpty ? .notVerified : nil
            for seg in segs where reason == nil {
                if isPaddingFile(seg.file) { continue }   // BEP 47 padding: zeros, not on disk, no identity
                if unselectedFiles.contains(seg.file) { if !scratchOK { reason = .scratchChanged }; continue }
                reason = problem(of: seg.file)
            }
            if let reason { decision.mustRehash.insert(piece); decision.reasons[piece] = reason } else { decision.trusted.insert(piece) }
        }
        return decision
    }

    /// Convenience: captures the identity of every non-empty file that is not unselected. `url(index)` is where the engine keeps data file `index`.
    static func captureIdentities(meta: TorrentMetainfo, skipping unselected: Set<Int> = [], url: (Int) -> URL) -> [Int: TorrentFileIdentity?] {
        var out: [Int: TorrentFileIdentity?] = [:]
        for f in meta.files where f.length > 0 && !unselected.contains(f.index) { out[f.index] = TorrentFileIdentity.capture(url(f.index)) }
        return out
    }
}

// MARK: - Re-verification

/// Streaming re-verification with bounded memory: at most `concurrency` (1...2) pieces are in memory at a time. It reads and compares; it NEVER deletes or writes anything.
enum Rehasher {
    struct Result: Equatable, Sendable {
        var verified: Set<Int> = []
        /// Read fine, hash differs.
        var failed: Set<Int> = []
        /// Could not be read at all (file missing, permission): reported apart from a hash failure.
        var unreadable: Set<Int> = []
        /// False when cancellation stopped the run early; pieces not reached are in none of the sets.
        var completed = true
    }

    /// `checkpoint` receives the cumulative verified set every `checkpointEvery` pieces (so a crash loses at most that much work). `progress` gets (done, total).
    static func run(pieces: [Int], concurrency: Int = 1, checkpointEvery: Int = 64,
                    read: @escaping @Sendable (Int) -> Data?, matches: @escaping @Sendable (Data, Int) -> Bool,
                    progress: (@Sendable (Int, Int) -> Void)? = nil, checkpoint: (@Sendable (Set<Int>) -> Void)? = nil) async -> Result {
        var result = Result()
        let lanes = min(2, max(1, concurrency))
        let every = max(1, checkpointEvery)
        var done = 0, sinceCheckpoint = 0, index = 0
        while index < pieces.count {
            if Task.isCancelled { result.completed = false; return result }
            let batch = Array(pieces[index..<min(pieces.count, index + lanes)])
            index += batch.count
            // 0 verified, 1 failed, 2 unreadable, 3 skipped because of cancellation
            let outcomes: [(Int, Int)] = await withTaskGroup(of: (Int, Int).self) { group in
                for piece in batch {
                    group.addTask {
                        if Task.isCancelled { return (piece, 3) }
                        guard let data = read(piece) else { return (piece, 2) }
                        return (piece, matches(data, piece) ? 0 : 1)
                    }
                }
                var all: [(Int, Int)] = []
                for await o in group { all.append(o) }
                return all.sorted { $0.0 < $1.0 }
            }
            for (piece, code) in outcomes {
                switch code {
                case 0: result.verified.insert(piece)
                case 1: result.failed.insert(piece)
                case 2: result.unreadable.insert(piece)
                default: result.completed = false; continue
                }
                done += 1; sinceCheckpoint += 1
                progress?(done, pieces.count)
                if sinceCheckpoint >= every { sinceCheckpoint = 0; checkpoint?(result.verified) }
            }
            if !result.completed { return result }
        }
        return result
    }
}
