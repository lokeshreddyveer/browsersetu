import Darwin
import Foundation

// MARK: Seeding (DX-06 S)

/// How a finished torrent may be shared. Off until the person turns it on (and then each torrent needs its own consent as well, see `TorrentRunner.authorizeSeeding`).
enum SeedingMode: String, Codable, CaseIterable, Sendable {
    case off, completed, whileDownloadingAndCompleted
    var title: String {
        switch self {
        case .off: "Off"
        case .completed: "After a download finishes"
        case .whileDownloadingAndCompleted: "While downloading and after it finishes"
        }
    }
}

/// Why a seeding session ended by itself.
enum SeedStopReason: Equatable, Sendable {
    case ratioReached, timeLimitReached, filesChanged, nothingToShare
    var text: String {
        switch self {
        case .ratioReached: "Stopped: the share ratio you chose was reached."
        case .timeLimitReached: "Stopped: the seeding time you chose was reached."
        case .filesChanged: "Stopped: the files were moved, changed or removed, so they are no longer shared."
        case .nothingToShare: "Stopped: none of the pieces can be shared."
        }
    }
}

/// The pure rules for when seeding must stop or may not run (kept free of any I/O so they are tested directly).
enum SeedPolicy {
    /// uploaded / size of the data shared. A zero size has no ratio.
    static func ratio(uploaded: Int64, size: Int64) -> Double { size > 0 ? Double(uploaded) / Double(size) : 0 }

    static func stopReason(uploaded: Int64, size: Int64, seconds: TimeInterval, ratioTarget: Double?, timeLimit: TimeInterval?, servable: Int) -> SeedStopReason? {
        if servable == 0 { return .nothingToShare }
        if let r = ratioTarget, r > 0, ratio(uploaded: uploaded, size: size) >= r { return .ratioReached }
        if let t = timeLimit, t > 0, seconds >= t { return .timeLimitReached }
        return nil
    }

    /// nil when seeding may run; otherwise the plain reason it may not. App-wide off always wins; a task needs its own authorization; the network rules the person chose apply.
    static func blockReason(enabled: Bool, mode: SeedingMode, authorized: Bool, proxyUnusable: Bool, pathRefusal: String?) -> String? {
        if !enabled { return "Peer-to-peer is off." }
        if mode == .off { return "Seeding is off in Settings." }
        if !authorized { return "Seeding was not started for this torrent." }
        if proxyUnusable { return "The proxy settings cannot be used, so nothing is shared." }
        if let pathRefusal { return pathRefusal }
        return nil
    }
}

/// A compact set of small integers (piece numbers a peer has reported).
struct PieceBits: Sendable {
    private var words: [UInt64]
    private(set) var count = 0
    let capacity: Int
    init(capacity: Int) { self.capacity = capacity; words = Array(repeating: 0, count: (capacity + 63) / 64) }
    func contains(_ i: Int) -> Bool { i >= 0 && i < capacity && words[i / 64] & (1 << UInt64(i % 64)) != 0 }
    @discardableResult mutating func insert(_ i: Int) -> Bool {
        guard i >= 0, i < capacity, !contains(i) else { return false }
        words[i / 64] |= 1 << UInt64(i % 64); count += 1; return true
    }
    var isFull: Bool { capacity > 0 && count == capacity }
}

/// What the dashboard and the inspector show about a torrent's seeding.
struct SeedingInfo: Equatable, Sendable {
    enum State: Equatable, Sendable { case verifying, seeding, paused(String), ended(String), stopped, idle }
    var state: State
    var authorized: Bool
    var uploaded: Int64
    var downloaded: Int64
    var ratio: Double
    var seconds: TimeInterval
    var uploadPeers: Int
    var peers: Int
    var upRate: Double
    var superSeeding: Bool
    var ratioTarget: Double?
    var timeLimit: TimeInterval?
    var verifyProgress: Double?
    var servablePieces: Int
    var totalPieces: Int
    var isActive: Bool { state == .seeding || state == .verifying }
}

/// What a running seeding session says about itself (in `TorrentSession.Snapshot`).
struct SeedingSnapshot: Sendable, Equatable {
    var uploadedTotal: Int64 = 0
    var seconds: TimeInterval = 0
    var ratio = 0.0
    var uploadPeers = 0
    var superSeeding = false
    var superSeedFellBack: String?
    var servablePieces = 0
    var unavailablePieces = 0
    var completePeersSeen = 0
}

/// Reads the bytes of a finished torrent from where the person's files now are, and only the bytes that may be given to a peer.
///
/// Trust rule: a piece may be served only if (a) it was verified (the caller passes the set it holds, copied from the picker, or the result of `rehash`) and (b) every file it touches still
/// has the identity (size, modification time, inode, device) it had when it was verified. A file that changed or vanished is revoked: every piece touching it is unavailable from then on.
/// Files are only ever opened for reading, without following a link, and are never altered or removed. Padding is zeros and has no file. Files the person did not choose are not available, so
/// a piece that touches one is not served (its other bytes were never kept).
///
/// This identity check is this module's own and private; it does not depend on the fast-resume module.
final class SeedingSource: @unchecked Sendable {
    struct Identity: Equatable, Sendable {
        var size: Int64, mtimeSec: Int64, mtimeNsec: Int64, inode: UInt64, device: Int64
    }
    enum ReadFailure: Error, Equatable { case invalidRequest, unavailable, filesChanged, io }

    let meta: TorrentMetainfo
    let location: URL
    let chosen: Set<Int>
    private let lock = NSLock()
    private var identities: [Int: Identity] = [:]
    private var revoked = Set<Int>()                 // files
    private var candidates = Set<Int>()              // pieces that were verified and whose files are all available
    private var filesOfPiece: [Int: [Int]] = [:]
    /// Called (on any thread) when a file is taken out of service.
    var onRevoked: (() -> Void)?
    private var readsMade = 0
    /// How many block reads got past every check and touched the disk (a count for the tests).
    var blockReads: Int { lock.lock(); defer { lock.unlock() }; return readsMade }

    /// A file whose path starts with ".pad" is padding (BEP 47): its bytes are zeros and it is never on disk. (Replaced by the metainfo's own flag once it exists.)
    static func isPadding(_ f: TorrentMetainfo.File) -> Bool { f.isPadding }

    init(meta: TorrentMetainfo, location: URL, chosen: Set<Int>, verifiedPieces: Set<Int>, expected: [Int: Identity]? = nil) {
        self.meta = meta; self.location = location; self.chosen = chosen
        var ok = Set<Int>()
        var needsFile = Set<Int>()
        for p in verifiedPieces where p >= 0 && p < meta.pieceCount {
            var files: [Int] = []
            var usable = true
            for seg in meta.segments(offset: Int64(p) * meta.pieceLength, length: meta.length(ofPiece: p)) {
                let f = meta.files[seg.file]
                if Self.isPadding(f) { continue }
                if !chosen.contains(f.index) { usable = false; break }
                files.append(f.index)
            }
            if usable { ok.insert(p); filesOfPiece[p] = files; needsFile.formUnion(files) }
        }
        candidates = ok
        for fi in needsFile {
            let now = Self.identity(of: path(of: meta.files[fi]))
            if let now, expected == nil || expected?[fi] == now { identities[fi] = now } else { revoked.insert(fi) }
        }
    }

    func path(of f: TorrentMetainfo.File) -> URL {
        guard meta.isMultiFile else { return location }
        var url = location
        for part in f.path { url.appendPathComponent(part) }
        return url
    }

    static func identity(of url: URL) -> Identity? {
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        return Identity(size: Int64(st.st_size), mtimeSec: Int64(st.st_mtimespec.tv_sec), mtimeNsec: Int64(st.st_mtimespec.tv_nsec), inode: UInt64(st.st_ino), device: Int64(st.st_dev))
    }

    static func identity(from st: stat) -> Identity {
        Identity(size: Int64(st.st_size), mtimeSec: Int64(st.st_mtimespec.tv_sec), mtimeNsec: Int64(st.st_mtimespec.tv_nsec), inode: UInt64(st.st_ino), device: Int64(st.st_dev))
    }

    /// Pieces that may be given out right now.
    var servablePieces: Set<Int> {
        lock.lock(); defer { lock.unlock() }
        return candidates.filter { p in !(filesOfPiece[p] ?? []).contains(where: revoked.contains) }.reduce(into: Set<Int>()) { $0.insert($1) }
    }
    var servableCount: Int { servablePieces.count }

    func isServable(_ piece: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return candidates.contains(piece) && !(filesOfPiece[piece] ?? []).contains(where: revoked.contains)
    }

    var revokedFiles: Set<Int> { lock.lock(); defer { lock.unlock() }; return revoked }

    /// Bytes of the chosen files that are not padding: what the ratio is measured against.
    var sharedSize: Int64 { meta.files.filter { chosen.contains($0.index) && !Self.isPadding($0) }.reduce(0) { $0 + $1.length } }

    /// Takes the files away from service (never touches them).
    func revoke(files: [Int]) {
        lock.lock(); let before = revoked.count; revoked.formUnion(files); let changed = revoked.count != before; lock.unlock()
        if changed { onRevoked?() }
    }

    /// Looks at every file the servable pieces use and revokes those that no longer have the recorded identity. Cheap (one stat each); run now and then, and the read path checks too.
    @discardableResult func audit() -> Bool {
        lock.lock(); let items = identities; lock.unlock()
        var gone: [Int] = []
        for (fi, id) in items where Self.identity(of: path(of: meta.files[fi])) != id { gone.append(fi) }
        if !gone.isEmpty { revoke(files: gone) }
        return gone.isEmpty
    }

    /// One block for a peer. Everything is validated first; nothing is read for a request that is not valid.
    func read(piece: Int, begin: Int, length: Int) -> Result<Data, ReadFailure> {
        guard piece >= 0, piece < meta.pieceCount, begin >= 0, length > 0, length <= PeerWire.blockSize, begin + length <= Int(meta.length(ofPiece: piece)) else { return .failure(.invalidRequest) }
        guard isServable(piece) else { return .failure(.unavailable) }
        lock.lock(); readsMade += 1; lock.unlock()
        return readRange(piece: piece, begin: begin, length: length)
    }

    private func readRange(piece: Int, begin: Int, length: Int) -> Result<Data, ReadFailure> {
        var out = Data(capacity: length)
        for seg in meta.segments(offset: Int64(piece) * meta.pieceLength + Int64(begin), length: Int64(length)) {
            let f = meta.files[seg.file]
            if Self.isPadding(f) { out.append(Data(count: Int(seg.count))); continue }
            let fd = open(path(of: f).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)          // never follows a link; never blocks on a pipe put in the file's place
            guard fd >= 0 else { revoke(files: [f.index]); return .failure(.filesChanged) }
            defer { Darwin.close(fd) }
            var st = stat()
            lock.lock(); let expected = identities[f.index]; lock.unlock()
            guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, let expected,
                  Identity(size: Int64(st.st_size), mtimeSec: Int64(st.st_mtimespec.tv_sec), mtimeNsec: Int64(st.st_mtimespec.tv_nsec), inode: UInt64(st.st_ino), device: Int64(st.st_dev)) == expected else {
                revoke(files: [f.index]); return .failure(.filesChanged)
            }
            var buffer = [UInt8](repeating: 0, count: Int(seg.count))
            var got = 0
            let wanted = buffer.count
            while got < wanted {
                let done = got
                let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + done, wanted - done, off_t(seg.fileOffset) + off_t(done)) }
                if n < 0, errno == EINTR { continue }
                if n <= 0 { revoke(files: [f.index]); return .failure(.io) }
                got += n
            }
            // The file must be the same, unchanged, after the read: bytes read while it was being written are never given out.
            var after = stat(), onDisk = stat()
            guard fstat(fd, &after) == 0, lstat(path(of: f).path, &onDisk) == 0, Self.identity(from: after) == expected, Self.identity(from: onDisk) == expected else {
                revoke(files: [f.index]); return .failure(.filesChanged)
            }
            out.append(contentsOf: buffer)
        }
        return out.count == length ? .success(out) : .failure(.io)
    }

    /// Establishes trust when there is no evidence: every piece that lies only in chosen (or padding) files is read back, one at a time (memory is one piece), and kept only if `matches`
    /// (the one hash gate, `TorrentStorage.matches`) accepts it. A file that changes while it is read is not trusted. `progress` is called with the fraction done; return true from
    /// `cancelled` to stop (the result is then nil).
    static func rehash(meta: TorrentMetainfo, location: URL, chosen: Set<Int>, trusted: Set<Int> = [], matches: (Data, Int) -> Bool, cancelled: () -> Bool, progress: (Double) -> Void, baseline: [Int: Identity]? = nil) -> SeedingSource? {
        // One identity snapshot serves the trust decision, the read-back and the source that results: a file that differs from `baseline` at any later moment is not served.
        let probe = SeedingSource(meta: meta, location: location, chosen: chosen, verifiedPieces: Set(0..<meta.pieceCount), expected: baseline)
        let started = baseline ?? probe.identitiesSnapshot
        var good = trusted.intersection(probe.servablePieces)          // pieces the fast-resume evidence vouches for are not read again
        let candidates = probe.servablePieces.subtracting(trusted).sorted()
        for (n, p) in candidates.enumerated() {
            if cancelled() { return nil }
            if case .success(let data) = probe.readRange(piece: p, begin: 0, length: Int(meta.length(ofPiece: p))), matches(data, p) { good.insert(p) }
            if n % 8 == 0 { progress(Double(n) / Double(max(1, candidates.count))) }
        }
        progress(1)
        return SeedingSource(meta: meta, location: location, chosen: chosen, verifiedPieces: good, expected: started)
    }

    /// The identity of every real chosen file as it is now: what a resume record keeps as evidence.
    /// Taken from the identities this source holds from the moment its pieces were verified (never captured afresh), and only for files still in service: a record can never pair edited bytes with an old verification.
    func resumeIdentities() -> [Int: TorrentFileIdentity] {
        audit()
        lock.lock(); let held = identities, gone = revoked; lock.unlock()
        var out: [Int: TorrentFileIdentity] = [:]
        for (fi, id) in held where !gone.contains(fi) {
            out[fi] = TorrentFileIdentity(size: id.size, mtimeNanos: id.mtimeSec &* 1_000_000_000 &+ id.mtimeNsec, inode: id.inode, device: id.device)
        }
        return out
    }

    var identitiesSnapshot: [Int: Identity] { lock.lock(); defer { lock.unlock() }; return identities }
}
