import Foundation

/// Part-by-part bookkeeping for one file: which 180 KiB blocks of which parts are wanted, asked for, and received. Pure; used from one queue.
///
/// A part is the unit that is checked (MD4), so its blocks are held in memory until all have arrived, and at most `maxPartsInMemory` parts are open at once. A block is accepted only from the
/// peer it was asked of, for exactly the range that was asked.
final class ED2KPartPicker {
    typealias PeerID = Int
    struct Request: Equatable { var part: Int; var start: Int64; var end: Int64 }          // absolute offsets in the file, end exclusive

    enum Received: Equatable {
        case accepted
        case partComplete(index: Int, data: Data, contributors: Set<PeerID>)
        case unexpected
    }

    let size: Int64
    let partCount: Int
    private(set) var have: [Bool]
    let maxPartsInMemory: Int
    private struct Open {
        var data: Data
        var blockCount: Int
        var asked: [Int: (peer: PeerID, at: TimeInterval)] = [:]
        var got = Set<Int>()
        var contributors = Set<PeerID>()
        var owner: PeerID?            // a suspect part is fetched from one peer only, so a repeat failure can be pinned on it
    }
    private var open: [Int: Open] = [:]
    private var suspect = Set<Int>()
    private var verifying = Set<Int>()
    private var peerParts: [PeerID: [Bool]] = [:]
    private var availability: [Int]

    init(size: Int64, alreadyHave: Set<Int>, maxPartsInMemory: Int = 4) {
        self.size = size; partCount = ED2KHash.partCount(size: size); self.maxPartsInMemory = maxPartsInMemory
        have = (0..<ED2KHash.partCount(size: size)).map { alreadyHave.contains($0) }
        availability = Array(repeating: 0, count: ED2KHash.partCount(size: size))
    }

    func blockCount(ofPart p: Int) -> Int { Int((ED2KHash.partLength(p, size: size) + Int64(ED2KHash.blockSize) - 1) / Int64(ED2KHash.blockSize)) }

    func peerHas(_ peer: PeerID, _ flags: [Bool]) {
        peerGone(peer, keepAsked: true)
        guard flags.count == partCount else { return }
        peerParts[peer] = flags
        for (i, f) in flags.enumerated() where f { availability[i] += 1 }
    }

    func peerGone(_ peer: PeerID, keepAsked: Bool = false) {
        if let flags = peerParts.removeValue(forKey: peer) { for (i, f) in flags.enumerated() where f { availability[i] = max(0, availability[i] - 1) } }
        guard !keepAsked else { return }
        for index in Array(open.keys) {
            guard var o = open[index] else { continue }
            if o.owner == peer { open[index] = nil; continue }              // its exclusive part starts over
            o.asked = o.asked.filter { $0.value.peer != peer }
            open[index] = o.got.isEmpty && o.asked.isEmpty ? nil : o
        }
    }

    func inFlight(for peer: PeerID) -> Int { open.values.reduce(0) { $0 + $1.asked.values.filter { $0.peer == peer }.count } }
    func peerHasWanted(_ peer: PeerID) -> Bool { guard let f = peerParts[peer] else { return false }; return (0..<partCount).contains { !have[$0] && f[$0] } }

    /// Up to `limit` blocks to ask `peer` for: parts already open first, then the rarest part the peer has.
    func nextRequests(for peer: PeerID, limit: Int, now: TimeInterval) -> [Request] {
        guard limit > 0, let flags = peerParts[peer] else { return [] }
        var out: [Request] = []
        func take(_ part: Int) {
            guard var o = open[part] else { return }
            for b in 0..<o.blockCount where out.count < limit && !o.got.contains(b) && o.asked[b] == nil {
                o.asked[b] = (peer, now)
                let start = Int64(part) * ED2KHash.partSize + Int64(b) * Int64(ED2KHash.blockSize)
                let end = min(start + Int64(ED2KHash.blockSize), Int64(part) * ED2KHash.partSize + ED2KHash.partLength(part, size: size))
                out.append(Request(part: part, start: start, end: end))
            }
            open[part] = o
        }
        for p in open.keys.sorted() where flags[p] && out.count < limit && (open[p]?.owner == nil || open[p]?.owner == peer) { take(p) }
        // Open parts that nobody connected has, and nobody is being asked for, would hold the memory for ever: one is let go to make room.
        if open.count + verifying.count >= maxPartsInMemory, let orphan = open.keys.sorted().first(where: { availability[$0] == 0 && open[$0]?.asked.isEmpty == true && !(flags[$0]) }) { open[orphan] = nil }
        while out.count < limit, open.count + verifying.count < maxPartsInMemory,
              let pick = (0..<partCount).filter({ !have[$0] && flags[$0] && open[$0] == nil && !verifying.contains($0) }).min(by: { (availability[$0], $0) < (availability[$1], $1) }) {
            open[pick] = Open(data: Data(count: Int(ED2KHash.partLength(pick, size: size))), blockCount: blockCount(ofPart: pick), owner: suspect.contains(pick) ? peer : nil)
            take(pick)
        }
        return out
    }

    @discardableResult
    func expire(olderThan seconds: TimeInterval, now: TimeInterval) -> [PeerID] {
        var slow = Set<PeerID>()
        for index in Array(open.keys) {
            guard var o = open[index] else { continue }
            for (b, a) in o.asked where now - a.at > seconds { o.asked[b] = nil; slow.insert(a.peer) }
            open[index] = o
        }
        return Array(slow)
    }

    func received(from peer: PeerID, start: Int64, end: Int64, data: Data) -> Received {
        guard start >= 0, end > start, end <= size, Int64(data.count) == end - start else { return .unexpected }
        let part = Int(start / ED2KHash.partSize)
        guard open[part] != nil else { return .unexpected }
        let inPart = start - Int64(part) * ED2KHash.partSize
        guard inPart % Int64(ED2KHash.blockSize) == 0 else { return .unexpected }
        let block = Int(inPart / Int64(ED2KHash.blockSize))
        let expectedEnd = min(Int64(part) * ED2KHash.partSize + (Int64(block) + 1) * Int64(ED2KHash.blockSize), Int64(part) * ED2KHash.partSize + ED2KHash.partLength(part, size: size))
        guard let current = open[part], block < current.blockCount, current.asked[block]?.peer == peer, end == expectedEnd, !current.got.contains(block) else { return .unexpected }
        var o = open.removeValue(forKey: part)!               // taken out first: changing it in place then copies nothing (a copy of a 9.7 MB part per block would be 500 MB of copying)
        o.data.replaceSubrange(Int(inPart)..<Int(inPart) + data.count, with: data)
        o.got.insert(block); o.asked[block] = nil; o.contributors.insert(peer)
        if o.got.count == o.blockCount { open[part] = nil; verifying.insert(part); return .partComplete(index: part, data: o.data, contributors: o.contributors) }
        open[part] = o
        return .accepted
    }

    /// Blocks that were handed out but not sent to anyone: free to be asked for again.
    func release(_ requests: [Request]) {
        for r in requests {
            guard var o = open[r.part] else { continue }
            let block = Int((r.start - Int64(r.part) * ED2KHash.partSize) / Int64(ED2KHash.blockSize))
            o.asked[block] = nil
            open[r.part] = o.got.isEmpty && o.asked.isEmpty ? nil : o
        }
    }

    func partVerified(_ p: Int) { have[p] = true; verifying.remove(p); open[p] = nil; suspect.remove(p) }
    /// A part failed its check. If several peers took part nobody can be blamed yet, so the part is fetched again from one peer alone.
    func partFailed(_ p: Int, contributors: Set<PeerID>) { verifying.remove(p); open[p] = nil; if contributors.count > 1 { suspect.insert(p) } }
    func invalidate(_ parts: [Int]) { for p in parts where p >= 0 && p < have.count { have[p] = false; verifying.remove(p); open[p] = nil } }

    var isComplete: Bool { have.allSatisfy { $0 } }
    var verifiedParts: Int { have.filter { $0 }.count }
    var completedBytes: Int64 { (0..<partCount).filter { have[$0] }.reduce(0) { $0 + ED2KHash.partLength($1, size: size) } }
    var heldBytes: Int { open.keys.reduce(0) { $0 + Int(ED2KHash.partLength($1, size: size)) } + verifying.reduce(0) { $0 + Int(ED2KHash.partLength($1, size: size)) } }
    var sourcesWithParts: Int { peerParts.count }
}

/// The partly downloaded file: one sparse file beside its destination, written a checked part at a time, moved into place only when every part has been checked again from disk.
final class ED2KStorage: @unchecked Sendable {
    enum Failure: Error, Equatable, LocalizedError {
        case noSpace(needed: Int64, available: Int64), io(String)
        var errorDescription: String? {
            switch self {
            case .noSpace(let n, let a): "Not enough space: it needs about \(DownloadStats.bytes(n)) and \(DownloadStats.bytes(a)) is free."
            case .io(let why): why
            }
        }
    }

    let size: Int64
    let partFile: URL
    private var fd: Int32 = -1
    private let lock = NSLock()

    static func partFile(for id: UUID, in directory: URL) -> URL { directory.appendingPathComponent(".\(id.uuidString.prefix(8)).bsetu-ed2k") }

    init(size: Int64, partFile: URL) { self.size = size; self.partFile = partFile }
    deinit { closeFile() }

    func prepare(freeSpace: ((URL) -> Int64?)? = nil) throws {
        let parent = partFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let existing = (try? FileManager.default.attributesOfItem(atPath: partFile.path)[.size] as? NSNumber)?.int64Value ?? 0
        let need = max(0, size - existing)
        if let free = (freeSpace ?? { DiskSpace.available(at: $0) })(parent), free < need + max(50_000_000, need / 20) { throw Failure.noSpace(needed: need, available: free) }
        lock.lock(); defer { lock.unlock() }
        guard fd < 0 else { return }
        let d = open(partFile.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard d >= 0 else { throw Failure.io("The download file could not be opened (\(String(cString: strerror(errno)))).") }
        var st = stat()
        if fstat(d, &st) == 0, Int64(st.st_size) != size, ftruncate(d, off_t(size)) != 0 { let e = errno; Darwin.close(d); throw Failure.io("The download file could not be prepared (\(String(cString: strerror(e)))).") }
        fd = d
    }

    /// Whether the part file is there at its full size (a missing or shortened file means the saved parts cannot be trusted).
    var existsAtFullSize: Bool { ((try? FileManager.default.attributesOfItem(atPath: partFile.path)[.size] as? NSNumber)?.int64Value ?? -1) == size }

    func write(part index: Int, data: Data) throws {
        guard Int64(data.count) == ED2KHash.partLength(index, size: size) else { throw Failure.io("A part has the wrong size.") }
        lock.lock(); let d = fd; lock.unlock()
        guard d >= 0 else { throw Failure.io("The download file is not open.") }
        let base = Int64(index) * ED2KHash.partSize
        try data.withUnsafeBytes { raw in
            var done = 0
            while done < raw.count {
                let n = pwrite(d, raw.baseAddress! + done, raw.count - done, off_t(base) + off_t(done))
                if n < 0 { if errno == EINTR { continue }; throw Failure.io("Writing failed (\(String(cString: strerror(errno)))).") }
                done += n
            }
        }
    }

    func read(part index: Int) -> Data? {
        let length = Int(ED2KHash.partLength(index, size: size))
        guard length > 0 else { return nil }
        lock.lock(); let d = fd; lock.unlock()
        guard d >= 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        var got = 0
        let base = Int64(index) * ED2KHash.partSize
        while got < length {
            let done = got
            let n = buffer.withUnsafeMutableBytes { pread(d, $0.baseAddress! + done, length - done, off_t(base) + off_t(done)) }
            if n <= 0 { return nil }
            got += n
        }
        return Data(buffer)
    }

    func sync() { lock.lock(); let d = fd; lock.unlock(); if d >= 0 { _ = fcntl(d, F_FULLFSYNC) } }

    func closeFile() { lock.lock(); if fd >= 0 { Darwin.close(fd); fd = -1 }; lock.unlock() }

    /// Moves the finished file to `directory/name` (or "name 2"…), never over anything. Returns where it is.
    func finish(into directory: URL, name: String) throws -> URL {
        sync(); closeFile()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try TorrentStorage.place(partFile, in: directory, name: name, isDirectory: false)
    }

    func discard() { closeFile(); try? FileManager.default.removeItem(at: partFile) }
}
