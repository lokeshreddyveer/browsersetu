import Foundation

/// Decides which blocks to ask which peer for, and assembles blocks into pieces. Pure bookkeeping, used from one queue.
///
/// Rules: only pieces that hold bytes of a chosen file are wanted; among the pieces a peer has, one already begun is finished first, otherwise the rarest is taken; a block is
/// accepted only from the peer it was asked of, at the size and place it was asked for; a piece is handed back only when every block has arrived, and is not "had" until the caller has
/// checked it. The memory held for unfinished pieces is capped, whatever the piece size.
final class TorrentPicker {
    typealias PeerID = Int

    struct Request: Equatable { var piece: Int; var begin: Int; var length: Int }

    enum Received: Equatable {
        case accepted
        case pieceComplete(index: Int, data: Data, contributors: Set<PeerID>)
        case unexpected
    }

    /// The order new pieces are begun in among pieces of the same priority.
    enum Order: Equatable, Sendable {
        case rarest
        case sequential
        /// Pieces from `anchor` for `window` pieces first (lowest number first), then rarest first.
        case streaming(anchor: Int, window: Int)
    }

    /// A request that was outstanding when the wanted pieces changed or a duplicate became redundant: the peer is told to forget it.
    struct Outstanding: Equatable { var peer: PeerID; var request: Request }

    /// How many other peers may be asked for a block that is already asked of one, in the last stretch of a download.
    static let maxDuplicates = 2
    /// The last stretch begins when no piece is left unbegun and no more than this many blocks are missing.
    static let endgameBlocks = 48

    let meta: TorrentMetainfo
    private(set) var needed: Set<Int>
    private(set) var have: [Bool]
    private var peerPieces: [PeerID: [Bool]] = [:]
    private var availability: [Int]
    private struct Progress {
        var data: Data
        var blockCount: Int
        var requested: [Int: (peer: PeerID, at: TimeInterval)] = [:]
        /// Endgame: other peers asked for the same block, with when.
        var extra: [Int: [PeerID: TimeInterval]] = [:]
        var got = Set<Int>()
        var contributors = Set<PeerID>()
    }
    private var inProgress: [Int: Progress] = [:]
    /// Pieces whose blocks have all arrived and that are being checked and written: not asked for again, and their memory still counts.
    private var verifying: [Int: Int] = [:]
    /// Bytes of unfinished pieces held in memory, at most.
    let memoryCap: Int
    private var selectedBytesInPiece: [Int64]
    /// Urgency of each piece (the highest priority of the selected files that touch it); nil means every needed piece is equally urgent.
    private var weights: [Int]?
    private(set) var order: Order = .rarest
    /// Bytes of each file that lie in verified pieces (a boundary piece counts for each file it touches, by the bytes it holds of it).
    private var fileVerifiedBytes: [Int64]
    private var cancels: [Outstanding] = []
    /// The last stretch (duplicate requests). On by default; off lets a test check the one-asker-per-block rule on its own.
    var allowsEndgame = true
    /// How many duplicate requests the last stretch has sent in all (a count for the inspector and the tests).
    private(set) var duplicateRequestsSent = 0

    init(meta: TorrentMetainfo, needed: [Int], alreadyHave: Set<Int>, selected: Set<Int>, memoryCap: Int = 128 * 1024 * 1024, weights: [Int]? = nil, order: Order = .rarest) {
        self.meta = meta; self.needed = Set(needed); self.memoryCap = memoryCap; self.weights = weights; self.order = order
        have = (0..<meta.pieceCount).map { alreadyHave.contains($0) }
        availability = Array(repeating: 0, count: meta.pieceCount)
        selectedBytesInPiece = Self.selectedBytes(meta: meta, selected: selected)
        fileVerifiedBytes = Array(repeating: 0, count: meta.files.count)
        for p in 0..<meta.pieceCount where have[p] { addFileBytes(of: p, sign: 1) }
    }

    private static func selectedBytes(meta: TorrentMetainfo, selected: Set<Int>) -> [Int64] {
        (0..<meta.pieceCount).map { p in
            meta.segments(offset: Int64(p) * meta.pieceLength, length: meta.length(ofPiece: p)).filter { selected.isEmpty || selected.contains($0.file) }.reduce(0) { $0 + $1.count }
        }
    }

    private func addFileBytes(of piece: Int, sign: Int64) {
        for seg in meta.segments(offset: Int64(piece) * meta.pieceLength, length: meta.length(ofPiece: piece)) { fileVerifiedBytes[seg.file] += sign * seg.count }
    }

    /// Bytes of each file (by position in `meta.files`) that are in verified pieces.
    var verifiedBytesByFile: [Int64] { fileVerifiedBytes.map { max(0, $0) } }

    /// The wanted pieces, their urgency and the order changed (the person changed the selection, or playback moved). Verified pieces stay verified. Requests for pieces no longer wanted
    /// are returned so the peers can be told to forget them; pieces being checked are left alone.
    @discardableResult
    func configure(needed newNeeded: [Int], selected: Set<Int>, weights newWeights: [Int]?, order newOrder: Order) -> [Outstanding] {
        needed = Set(newNeeded.filter { $0 >= 0 && $0 < meta.pieceCount })
        weights = newWeights.flatMap { $0.count == meta.pieceCount ? $0 : nil }
        order = newOrder
        selectedBytesInPiece = Self.selectedBytes(meta: meta, selected: selected)
        var dropped: [Outstanding] = []
        for index in Array(inProgress.keys) where !needed.contains(index) {
            guard let progress = inProgress[index] else { continue }
            for (block, r) in progress.requested { dropped.append(Outstanding(peer: r.peer, request: blockRequest(index, block))) }
            for (block, owners) in progress.extra { for (peer, _) in owners { dropped.append(Outstanding(peer: peer, request: blockRequest(index, block))) } }
            inProgress[index] = nil
        }
        return dropped
    }

    private func blockRequest(_ index: Int, _ block: Int) -> Request {
        Request(piece: index, begin: block * PeerWire.blockSize, length: min(PeerWire.blockSize, Int(meta.length(ofPiece: index)) - block * PeerWire.blockSize))
    }

    /// Requests that became redundant (a duplicate whose block arrived from someone else): to be cancelled. Taking them empties the list.
    func takeCancels() -> [Outstanding] { defer { cancels = [] }; return cancels }

    private struct Rank: Comparable {
        var weight: Int, prefer: Int, group: Int, key: Int, index: Int
        static func < (a: Rank, b: Rank) -> Bool { (a.weight, a.prefer, a.group, a.key, a.index) < (b.weight, b.prefer, b.group, b.key, b.index) }
    }

    /// Smaller is taken first: higher priority, then a peer's suggestion, then the order, then availability.
    private func rank(_ p: Int, prefer: Set<Int>) -> Rank {
        let weight = -(weights?[p] ?? 1)
        let suggested = prefer.contains(p) ? 0 : 1
        switch order {
        case .rarest: return Rank(weight: weight, prefer: suggested, group: 0, key: availability[p], index: p)
        case .sequential: return Rank(weight: weight, prefer: suggested, group: 0, key: p, index: p)
        case .streaming(let anchor, let window):
            let inside = p >= anchor && p < anchor + window
            return Rank(weight: weight, prefer: suggested, group: inside ? 0 : 1, key: inside ? p : availability[p], index: p)
        }
    }

    // MARK: Peers

    func peerBitfield(_ peer: PeerID, _ bitfield: Data) {
        remove(peer: peer, keepRequests: true)
        let flags = (0..<meta.pieceCount).map { PeerWire.has(bitfield, $0) }
        peerPieces[peer] = flags
        for (i, f) in flags.enumerated() where f { availability[i] += 1 }
    }

    func peerHave(_ peer: PeerID, _ index: Int) {
        guard index >= 0, index < meta.pieceCount else { return }
        var flags = peerPieces[peer] ?? Array(repeating: false, count: meta.pieceCount)
        if !flags[index] { flags[index] = true; availability[index] += 1 }
        peerPieces[peer] = flags
    }

    func peerHasAnything(_ peer: PeerID) -> Bool { peerPieces[peer]?.contains(true) ?? false }
    func peerHasWanted(_ peer: PeerID) -> Bool {
        guard let flags = peerPieces[peer] else { return false }
        return needed.contains { !have[$0] && flags[$0] }
    }

    /// A peer left: what it was asked for becomes free to ask others, and its pieces no longer count as available.
    func peerGone(_ peer: PeerID) { remove(peer: peer, keepRequests: false) }

    private func remove(peer: PeerID, keepRequests: Bool) {
        if let flags = peerPieces.removeValue(forKey: peer) { for (i, f) in flags.enumerated() where f { availability[i] = max(0, availability[i] - 1) } }
        guard !keepRequests else { return }
        for index in Array(inProgress.keys) {
            guard var progress = inProgress[index] else { continue }
            // A block this peer was asked for passes to a peer that was asked for it too (endgame), if there is one.
            for block in Array(progress.extra.keys) { progress.extra[block]?[peer] = nil }          // first: the departing peer is no candidate to take over a block
            for (block, r) in progress.requested where r.peer == peer {
                if let next = progress.extra[block]?.min(by: { $0.value < $1.value }) {
                    progress.requested[block] = (next.key, next.value); progress.extra[block]?[next.key] = nil
                } else { progress.requested[block] = nil }
            }
            for block in Array(progress.extra.keys) { progress.extra[block]?[peer] = nil; if progress.extra[block]?.isEmpty == true { progress.extra[block] = nil } }
            inProgress[index] = progress.got.isEmpty && progress.requested.isEmpty ? nil : progress
        }
    }

    // MARK: Asking

    func inFlight(for peer: PeerID) -> Int { inProgress.values.reduce(0) { $0 + $1.requested.values.filter { $0.peer == peer }.count } }

    /// `only`: ask only for these pieces (a choked peer's allowed-fast set, BEP 6). `prefer`: pieces the peer suggested, taken first among new ones. `avoid`: pieces the peer rejected.
    func nextRequests(for peer: PeerID, limit: Int, now: TimeInterval, only: Set<Int>? = nil, prefer: Set<Int> = [], avoid: Set<Int> = []) -> [Request] {
        guard limit > 0, let flags = peerPieces[peer] else { return [] }
        func allowed(_ i: Int) -> Bool { (only?.contains(i) ?? true) && !avoid.contains(i) }
        var out: [Request] = []
        func take(from index: Int) {
            guard var progress = inProgress[index] else { return }
            for block in 0..<progress.blockCount where out.count < limit && !progress.got.contains(block) && progress.requested[block] == nil {
                progress.requested[block] = (peer, now)
                out.append(Request(piece: index, begin: block * PeerWire.blockSize, length: min(PeerWire.blockSize, Int(meta.length(ofPiece: index)) - block * PeerWire.blockSize)))
            }
            inProgress[index] = progress
        }
        // Pieces already begun come first.
        for index in inProgress.keys.sorted() where flags[index] && allowed(index) && out.count < limit { take(from: index) }
        // Then new pieces, rarest first, while the memory for unfinished pieces allows.
        while out.count < limit {
            let held = heldBytes
            let candidates = needed.filter { allowed($0) && !have[$0] && flags[$0] && inProgress[$0] == nil && verifying[$0] == nil && held + Int(meta.length(ofPiece: $0)) <= memoryCap }
            guard let pick = candidates.min(by: { rank($0, prefer: prefer) < rank($1, prefer: prefer) }) else { break }
            let length = Int(meta.length(ofPiece: pick))
            inProgress[pick] = Progress(data: Data(count: length), blockCount: (length + PeerWire.blockSize - 1) / PeerWire.blockSize)
            take(from: pick)
        }
        // The last stretch: nothing new is left to begin, so the blocks still missing are also asked of other peers (a few at most), and the first to arrive wins.
        if out.count < limit, isEndgame {
            for index in inProgress.keys.sorted() where flags[index] && allowed(index) && out.count < limit {
                guard var progress = inProgress[index] else { continue }
                for block in 0..<progress.blockCount where out.count < limit && !progress.got.contains(block) {
                    guard let owner = progress.requested[block], owner.peer >= 0, owner.peer != peer, progress.extra[block]?[peer] == nil, (progress.extra[block]?.count ?? 0) < Self.maxDuplicates else { continue }
                    progress.extra[block, default: [:]][peer] = now
                    duplicateRequestsSent += 1
                    out.append(blockRequest(index, block))
                }
                inProgress[index] = progress
            }
        }
        return out
    }

    /// True in the last stretch: every wanted piece has been begun and only a few blocks are missing.
    var isEndgame: Bool {
        guard allowsEndgame else { return false }
        var missing = 0
        for p in needed where !have[p] {
            if verifying[p] != nil { continue }
            guard let progress = inProgress[p] else { return false }          // a piece not begun yet: not the last stretch
            missing += progress.blockCount - progress.got.count
            if missing > Self.endgameBlocks { return false }
        }
        return missing > 0
    }

    /// A whole piece for a source that answers piece requests (a web seed), standing in as `peer`: the best piece not yet begun (by the same rules), with every block marked as asked of
    /// `peer`. nil when there is nothing to give it. `avoid`: pieces this source failed.
    func claimWholePiece(for peer: PeerID, now: TimeInterval, avoid: Set<Int> = []) -> Int? {
        let held = heldBytes
        let candidates = needed.filter { !have[$0] && !avoid.contains($0) && inProgress[$0] == nil && verifying[$0] == nil && held + Int(meta.length(ofPiece: $0)) <= memoryCap }
        guard let pick = candidates.min(by: { rank($0, prefer: []) < rank($1, prefer: []) }) else { return nil }
        let length = Int(meta.length(ofPiece: pick))
        var progress = Progress(data: Data(count: length), blockCount: (length + PeerWire.blockSize - 1) / PeerWire.blockSize)
        for block in 0..<progress.blockCount { progress.requested[block] = (peer, now) }
        inProgress[pick] = progress
        return pick
    }

    /// The whole of a claimed piece arrived from its source. Accepted only if every block is still asked of that source (someone else may have finished it first).
    func receivedWholePiece(from peer: PeerID, piece index: Int, data: Data) -> Received {
        guard let progress = inProgress[index], data.count == Int(meta.length(ofPiece: index)),
              (0..<progress.blockCount).allSatisfy({ progress.requested[$0]?.peer == peer && !progress.got.contains($0) }) else { return .unexpected }
        inProgress[index] = nil
        verifying[index] = data.count
        return .pieceComplete(index: index, data: data, contributors: [peer])
    }

    /// Everything a piece's other askers were told to forget when it was claimed whole by a source (they may hold duplicate requests only in the last stretch).
    func owners(ofPiece index: Int) -> [PeerID] {
        guard let progress = inProgress[index] else { return [] }
        return Array(Set(progress.requested.values.map(\.peer) + progress.extra.values.flatMap { $0.keys }))
    }

    /// A peer refused one block (BEP 6 REJECT_REQUEST): it is free to be asked of someone else. Only a request that was made of that peer is released.
    func rejected(from peer: PeerID, piece index: Int, begin: Int) {
        guard var progress = inProgress[index], begin % PeerWire.blockSize == 0 else { return }
        let block = begin / PeerWire.blockSize
        let wasExtra = progress.extra[block]?[peer] != nil
        progress.extra[block]?[peer] = nil          // first: the refusing peer is no candidate to take the block over
        if progress.requested[block]?.peer == peer {
            if let next = progress.extra[block]?.min(by: { $0.value < $1.value }) { progress.requested[block] = (next.key, next.value); progress.extra[block]?[next.key] = nil } else { progress.requested[block] = nil }
        } else if !wasExtra { return }
        inProgress[index] = progress
    }

    /// Requests that have waited too long are given back so another peer can be asked.
    @discardableResult
    func expire(olderThan seconds: TimeInterval, now: TimeInterval) -> [PeerID] {
        var slow = Set<PeerID>()
        for index in Array(inProgress.keys) {
            guard var progress = inProgress[index] else { continue }
            for (block, r) in progress.requested where now - r.at > (r.peer < 0 ? seconds * 4 : seconds) { progress.requested[block] = nil; slow.insert(r.peer) }          // a web seed is given longer: it sends a whole piece
            for (block, owners) in progress.extra { for (peer, at) in owners where now - at > seconds { progress.extra[block]?[peer] = nil; slow.insert(peer) } }
            inProgress[index] = progress
        }
        return Array(slow)
    }

    // MARK: Receiving

    func received(from peer: PeerID, piece index: Int, begin: Int, data: Data) -> Received {
        guard var progress = inProgress[index], begin % PeerWire.blockSize == 0 else { return .unexpected }
        let block = begin / PeerWire.blockSize
        let expected = min(PeerWire.blockSize, Int(meta.length(ofPiece: index)) - begin)
        // Only a block that was asked for, of that peer, at that size.
        guard block < progress.blockCount, progress.requested[block]?.peer == peer || progress.extra[block]?[peer] != nil, data.count == expected, !progress.got.contains(block) else { return .unexpected }
        progress.data.replaceSubrange(begin..<(begin + expected), with: data)
        // The first valid answer wins: every other peer that was asked for this block is told to forget it.
        var others: [PeerID] = progress.extra[block].map { Array($0.keys) } ?? []
        if let owner = progress.requested[block]?.peer { others.append(owner) }
        for other in others where other != peer { cancels.append(Outstanding(peer: other, request: blockRequest(index, block))) }
        progress.got.insert(block); progress.requested[block] = nil; progress.extra[block] = nil; progress.contributors.insert(peer)
        if progress.got.count == progress.blockCount {
            inProgress[index] = nil
            verifying[index] = progress.data.count
            return .pieceComplete(index: index, data: progress.data, contributors: progress.contributors)
        }
        inProgress[index] = progress
        return .accepted
    }

    func pieceVerified(_ index: Int) {
        if !have[index] { addFileBytes(of: index, sign: 1) }
        have[index] = true; inProgress[index] = nil; verifying[index] = nil
    }

    /// Pieces that were thought to be held but are not (the final check of the files on disk found them wrong): wanted again, with everything known about the peers kept.
    func invalidate(_ pieces: [Int]) {
        for p in pieces where p >= 0 && p < have.count { if have[p] { addFileBytes(of: p, sign: -1) }; have[p] = false; inProgress[p] = nil; verifying[p] = nil }
    }

    /// A piece failed its check: nothing of it is kept, and it can be asked for again.
    func pieceFailed(_ index: Int) { inProgress[index] = nil; verifying[index] = nil }

    // MARK: Progress

    var wantedPiecesRemaining: Int { needed.filter { !have[$0] }.count }
    var isComplete: Bool { wantedPiecesRemaining == 0 }
    var verifiedPieces: Int { have.filter { $0 }.count }
    var heldBytes: Int { inProgress.keys.reduce(0) { $0 + Int(meta.length(ofPiece: $1)) } + verifying.values.reduce(0, +) }

    /// Bytes of the chosen files that are in verified pieces.
    var completedBytes: Int64 { needed.filter { have[$0] }.reduce(0) { $0 + selectedBytesInPiece[$1] } }

    /// How many of the connected peers have each piece (the rarest piece's count, and the average), when known.
    var availabilitySummary: (rarest: Int, peers: Int) { (needed.filter { !have[$0] }.map { availability[$0] }.min() ?? 0, peerPieces.count) }
}
