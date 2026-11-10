import XCTest
@testable import Browser_Setu

// DX-05: selective files and priorities, BEP 53, the file tree, the piece picker's order and last stretch, web seeds (BEP 19) and HTTP seeds (BEP 17).

private func fixture(_ files: [([String], Int)], pieceLength: Int = 32768, extra: [String: Bencode] = [:]) throws -> TorrentFixture.Built {
    try TorrentFixture.build(files: files, pieceLength: pieceLength, extra: extra)
}

// MARK: Selection, plan, BEP 53

final class DX05SelectionTests: XCTestCase {
    func testAPieceSharedWithASkippedFileIsStillNeededButAddsNoUrgency() throws {
        // a: 0..39_999 (pieces 0 and 1), b: 40_000..79_999 (pieces 1 and 2), c: 80_000..119_999 (pieces 2 and 3). Piece length 32_768.
        let t = try fixture([(["a"], 40_000), (["b"], 40_000), (["c"], 40_000)])
        var sel = TorrentSelection.only([0], in: t.meta)
        sel.priorities[0] = .high
        let plan = TorrentPlan(sel, meta: t.meta)
        XCTAssertEqual(plan.needed, [0, 1], "piece 1 holds the end of a and the start of b: it is needed to check a")
        XCTAssertEqual(plan.weights, [3, 3, 0, 0], "urgency comes only from the chosen file")
        XCTAssertEqual(plan.selectedBytes, 40_000)
    }

    func testAPieceTouchedByTwoChosenFilesTakesTheHigherPriority() throws {
        let t = try fixture([(["a"], 40_000), (["b"], 40_000)])
        var sel = TorrentSelection.all(t.meta)
        sel.priorities[0] = .low; sel.priorities[1] = .maximum
        let plan = TorrentPlan(sel, meta: t.meta)
        XCTAssertEqual(plan.weights[0], 1); XCTAssertEqual(plan.weights[1], 4, "piece 1 is shared"); XCTAssertEqual(plan.weights[2], 4)
    }

    func testNothingChosenNeedsNothingAndStaleEntriesAreDropped() throws {
        let t = try fixture([(["a"], 40_000), (["b"], 1000)])
        XCTAssertTrue(TorrentPlan(TorrentSelection.only([], in: t.meta), meta: t.meta).needed.isEmpty)
        var sel = TorrentSelection(priorities: [0: .normal, 99: .high]); sel.streamFile = 77
        let clean = sel.normalized(for: t.meta)
        XCTAssertEqual(clean.priorities.keys.sorted(), [0]); XCTAssertNil(clean.streamFile)
    }

    func testZeroLengthFilesAddNoPieces() throws {
        let t = try fixture([(["a"], 40_000), (["empty"], 0), (["b"], 10)])
        let plan = TorrentPlan(TorrentSelection.only([1], in: t.meta), meta: t.meta)
        XCTAssertTrue(plan.needed.isEmpty, "an empty file has no bytes to fetch")
    }

    func testStreamingAnchorFollowsThePlaybackPosition() throws {
        let t = try fixture([(["a"], 10 * 32768), (["b"], 10 * 32768)])
        var sel = TorrentSelection.only([1], in: t.meta); sel.mode = .streaming; sel.streamFile = 1; sel.streamPosition = 5 * 32768 + 7
        XCTAssertEqual(TorrentPlan(sel, meta: t.meta).anchorPiece, 15)
    }

    func testMagnetSelectionSyntaxFromTheBEP() {
        XCTAssertEqual(MagnetSelection.parse("0,2,4,6-8"), .indices([0, 2, 4, 6, 7, 8]))
        XCTAssertEqual(MagnetSelection.parse(" 1 , 3-3 ,1"), .indices([1, 3]), "spaces are allowed, repeats collapse")
        for bad in ["", "a", "1,,2", "5-3", "4-", "-4", "1-2-3", "99999999", "1.5", "０"] {
            guard case .malformed = MagnetSelection.parse(bad) else { return XCTFail("“\(bad)” must be refused, not guessed at") }
        }
        guard case .malformed = MagnetSelection.parse("0-" + String(TorrentMetainfo.Limit.maxFiles + 5)) else { return XCTFail("a huge range") }
    }

    func testMagnetLinkCarriesTheChoiceAndALinkWithoutOneIsUnchanged() throws {
        let hash = String(repeating: "ab", count: 20)
        XCTAssertEqual(try MagnetLink.parse("magnet:?xt=urn:btih:\(hash)&so=0,2,4,6-8").selectOnly, .indices([0, 2, 4, 6, 7, 8]))
        XCTAssertNil(try MagnetLink.parse("magnet:?xt=urn:btih:\(hash)").selectOnly)
        guard case .malformed? = try MagnetLink.parse("magnet:?xt=urn:btih:\(hash)&so=zz").selectOnly else { return XCTFail("malformed choices are reported") }
    }

    func testMagnetChoiceIsCheckedAgainstTheRealFileListAndNeverMeansEverything() throws {
        let t = try fixture([(["a"], 100), (["b"], 100), (["c"], 100)])
        let ok = MagnetSelection.apply([0, 2], to: t.meta)
        XCTAssertEqual(ok.selection.selected(in: t.meta), [0, 2]); XCTAssertNil(ok.problem)
        let partly = MagnetSelection.apply([1, 9], to: t.meta)
        XCTAssertEqual(partly.selection.selected(in: t.meta), [1]); XCTAssertNotNil(partly.problem)
        let none = MagnetSelection.apply([7, 8], to: t.meta)
        XCTAssertTrue(none.selection.selected(in: t.meta).isEmpty, "nothing real was named: nothing is chosen, and the person is told")
        XCTAssertNotNil(none.problem)
    }

    func testMergingAMagnetIntoAKnownTorrentAddsOnlyWhatWasNotDownloading() throws {
        let t = try fixture([(["a"], 100), (["b"], 100), (["c"], 100)])
        var current = TorrentSelection.only([0], in: t.meta); current.priorities[0] = .high
        let merged = MagnetSelection.merge([0, 2], into: current, meta: t.meta)
        XCTAssertEqual(merged.priority(of: 0), .high, "already downloading: unchanged"); XCTAssertEqual(merged.priority(of: 2), .normal); XCTAssertEqual(merged.priority(of: 1), .skip)
    }
}

// MARK: The file tree

final class DX05TreeTests: XCTestCase {
    func testFoldersAggregateAndChooseTheirFiles() throws {
        let t = try fixture([(["season1", "e1.mkv"], 100), (["season1", "e2.mkv"], 200), (["season2", "deep", "e3.mkv"], 400), (["readme.txt"], 5)])
        let tree = TorrentFileTree(t.meta)
        var sel = TorrentSelection.all(t.meta)
        var rows = tree.rows(expanded: [], selection: sel, filter: "", meta: t.meta)
        XCTAssertEqual(rows.map(\.name), ["season1", "season2", "readme.txt"])
        XCTAssertEqual(rows[0].size, 300); XCTAssertEqual(rows[1].fileCount, 1); XCTAssertEqual(rows[0].state, .all)
        tree.set(folder: ["season1"], chosen: false, in: &sel)
        rows = tree.rows(expanded: ["season1"], selection: sel, filter: "", meta: t.meta)
        XCTAssertEqual(rows.map(\.name), ["season1", "e1.mkv", "e2.mkv", "season2", "readme.txt"])
        XCTAssertEqual(rows[0].state, .none); XCTAssertEqual(rows[1].depth, 1)
        sel.priorities[0] = .normal
        XCTAssertEqual(tree.rows(expanded: [], selection: sel, filter: "", meta: t.meta)[0].state, .some, "mixed when only some files under a folder are chosen")
        tree.set(folder: ["season2"], priority: .maximum, in: &sel)
        XCTAssertEqual(sel.priority(of: 2), .maximum)
    }

    func testSearchListsMatchingFilesFlatAndSelectionActsOnThem() throws {
        let t = try fixture([(["a", "Cover.JPG"], 10), (["a", "track.flac"], 10), (["b", "cover.png"], 10)])
        let tree = TorrentFileTree(t.meta)
        var sel = TorrentSelection.all(t.meta)
        let rows = tree.rows(expanded: [], selection: sel, filter: "cover", meta: t.meta)
        XCTAssertEqual(rows.map(\.name), ["a/Cover.JPG", "b/cover.png"])
        TorrentFileTree.set(files: rows.compactMap(\.fileIndex), chosen: false, in: &sel)
        XCTAssertEqual(sel.selected(in: t.meta), [1])
    }

    func testDuplicateNamesInDifferentFoldersAreDifferentRowsAndALongListIsBounded() throws {
        let t = try fixture([(["x", "same.bin"], 1), (["y", "same.bin"], 1)])
        let tree = TorrentFileTree(t.meta)
        let rows = tree.rows(expanded: ["x", "y"], selection: TorrentSelection.all(t.meta), filter: "", meta: t.meta)
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
        let many = try fixture((0..<6000).map { (["f\($0)"], 1) })
        XCTAssertEqual(TorrentFileTree(many.meta).rows(expanded: [], selection: TorrentSelection.all(many.meta), filter: "", meta: many.meta).count, TorrentFileTree.maxRows)
    }
}

// MARK: The picker

final class DX05PickerTests: XCTestCase {
    private func make(_ files: [([String], Int)], weights: [Int]? = nil, order: TorrentPicker.Order = .rarest, needed: [Int]? = nil) throws -> (TorrentPicker, TorrentFixture.Built) {
        let t = try fixture(files)
        return (TorrentPicker(meta: t.meta, needed: needed ?? Array(0..<t.meta.pieceCount), alreadyHave: [], selected: [], weights: weights, order: order), t)
    }
    private func all(_ n: Int) -> Data { PeerWire.makeBitfield(Array(repeating: true, count: n)) }

    func testAHigherPriorityPieceComesBeforeARarerOne() throws {
        let (p, t) = try make([(["a"], 32768 * 4)], weights: [1, 1, 4, 1])
        let n = t.meta.pieceCount
        p.peerBitfield(1, all(n)); p.peerBitfield(2, PeerWire.makeBitfield((0..<n).map { $0 != 0 }))          // piece 0 is the rarest
        XCTAssertEqual(p.nextRequests(for: 1, limit: 1, now: 0).first?.piece, 2, "priority first, rarity second")
    }

    func testSequentialTakesLowestFirstAndStreamingTakesTheWindowFirst() throws {
        let (seq, t) = try make([(["a"], 32768 * 8)], order: .sequential)
        seq.peerBitfield(1, all(t.meta.pieceCount)); seq.peerBitfield(2, PeerWire.makeBitfield((0..<8).map { $0 != 0 }))
        XCTAssertEqual(seq.nextRequests(for: 1, limit: 1, now: 0).first?.piece, 0, "in order, though piece 0 is the rarest too")
        let (str, _) = try make([(["a"], 32768 * 8)], order: .streaming(anchor: 5, window: 2))
        str.peerBitfield(1, all(8)); str.peerBitfield(2, PeerWire.makeBitfield((0..<8).map { $0 != 7 }))
        XCTAssertEqual(str.nextRequests(for: 1, limit: 1, now: 0).first?.piece, 5)
        XCTAssertEqual(str.nextRequests(for: 1, limit: 4, now: 0).map(\.piece).first, 5, "the begun piece is finished first")
        let (outside, _) = try make([(["a"], 32768 * 8)], order: .streaming(anchor: 2, window: 1))
        outside.peerBitfield(1, PeerWire.makeBitfield([false, false, false, true, true, true, true, true]))
        outside.peerBitfield(2, PeerWire.makeBitfield([false, false, false, true, true, true, true, false]))
        XCTAssertEqual(outside.nextRequests(for: 1, limit: 1, now: 0).first?.piece, 7, "no peer has the window: the rarest outside it is taken")
    }

    func testChangingTheChoiceDropsRequestsForPiecesNoLongerWantedAndKeepsVerifiedOnes() throws {
        let (p, t) = try make([(["a"], 32768 * 4)])
        p.peerBitfield(1, all(t.meta.pieceCount))
        let asked = p.nextRequests(for: 1, limit: 8, now: 0)
        XCTAssertFalse(asked.isEmpty)
        p.pieceVerified(0)
        let dropped = p.configure(needed: [0, 3], selected: [], weights: nil, order: .rarest)
        XCTAssertTrue(dropped.allSatisfy { $0.peer == 1 && [1, 2].contains($0.request.piece) }, "requests for pieces that are no longer wanted are returned to be cancelled")
        XCTAssertFalse(dropped.isEmpty)
        XCTAssertTrue(p.have[0], "verified stays verified")
        XCTAssertEqual(p.wantedPiecesRemaining, 1)
    }

    func testPerFileVerifiedBytesCountASharedPieceForEachFileByItsOwnBytes() throws {
        let (p, _) = try make([(["a"], 40_000), (["b"], 40_000)])
        p.pieceVerified(1)          // bytes 32768..65535: the end of a (7232) and the start of b (25536)
        XCTAssertEqual(p.verifiedBytesByFile, [7232, 25536])
        p.pieceVerified(0)
        XCTAssertEqual(p.verifiedBytesByFile[0], 40_000)
        p.invalidate([1])
        XCTAssertEqual(p.verifiedBytesByFile, [32768, 0])
    }

    func testTheLastStretchAsksOtherPeersAndTheFirstAnswerWinsAndCancelsTheRest() throws {
        let (p, t) = try make([(["a"], 32768)])
        p.peerBitfield(1, all(1)); p.peerBitfield(2, all(1)); p.peerBitfield(3, all(1))
        let first = p.nextRequests(for: 1, limit: 8, now: 0)
        XCTAssertEqual(first.count, 2)
        XCTAssertTrue(p.isEndgame)
        let second = p.nextRequests(for: 2, limit: 8, now: 0), third = p.nextRequests(for: 3, limit: 8, now: 0)
        XCTAssertEqual(second.count, 2, "asked too, in the last stretch"); XCTAssertEqual(third.count, 2)
        XCTAssertTrue(p.nextRequests(for: 2, limit: 8, now: 0).isEmpty, "never twice of the same peer")
        // A fourth peer is refused: a block is asked of at most 1 + maxDuplicates peers.
        p.peerBitfield(4, all(1))
        XCTAssertTrue(p.nextRequests(for: 4, limit: 8, now: 0).isEmpty)
        let block0 = t.stream.subdata(in: 0..<16384), block1 = t.stream.subdata(in: 16384..<32768)
        XCTAssertEqual(p.received(from: 2, piece: 0, begin: 0, data: block0), .accepted)
        let cancelled = Set(p.takeCancels().map { "\($0.peer):\($0.request.begin)" })
        XCTAssertEqual(cancelled, ["1:0", "3:0"], "the other askers of that block are told to forget it")
        XCTAssertEqual(p.received(from: 1, piece: 0, begin: 0, data: block0), .unexpected, "the late answer is ignored, not written twice")
        guard case .pieceComplete(_, _, let who) = p.received(from: 3, piece: 0, begin: 16384, data: block1) else { return XCTFail("complete") }
        XCTAssertEqual(who, [2, 3])
        XCTAssertTrue(p.takeCancels().contains { $0.request.begin == 16384 })
    }

    func testNoLastStretchWhileAPieceIsUnbegunAndAPeerLeavingPassesItsBlockOn() throws {
        let (p, _) = try make([(["a"], 32768 * 3)])
        p.peerBitfield(1, all(3))
        _ = p.nextRequests(for: 1, limit: 2, now: 0)          // only part of the first piece is begun
        XCTAssertFalse(p.isEndgame, "pieces remain that nobody has begun")
        let (q, _) = try make([(["a"], 32768)])
        q.peerBitfield(1, all(1)); q.peerBitfield(2, all(1))
        _ = q.nextRequests(for: 1, limit: 8, now: 0); _ = q.nextRequests(for: 2, limit: 8, now: 0)
        q.peerGone(1)
        XCTAssertTrue(q.nextRequests(for: 2, limit: 8, now: 0).isEmpty, "peer 2 already holds both blocks (they passed to it)")
        XCTAssertEqual(q.inFlight(for: 2), 2)
    }

    func testAWholePieceIsClaimedForASourceAndReceivedOnlyIfStillItsAlone() throws {
        let (p, t) = try make([(["a"], 32768 * 3)], weights: [1, 5, 1])
        let piece = p.claimWholePiece(for: -1, now: 0)
        XCTAssertEqual(piece, 1, "the most urgent piece")
        XCTAssertEqual(p.owners(ofPiece: 1), [-1])
        XCTAssertNotEqual(p.claimWholePiece(for: -2, now: 0), 1, "a claimed piece is not given to another source")
        guard case .pieceComplete(let i, _, let who) = p.receivedWholePiece(from: -1, piece: 1, data: t.stream.subdata(in: 32768..<65536)) else { return XCTFail("complete") }
        XCTAssertEqual(i, 1); XCTAssertEqual(who, [-1])
        p.peerGone(-2)
        XCTAssertEqual(p.receivedWholePiece(from: -2, piece: 1, data: Data(count: 32768)), .unexpected)
    }
}

// MARK: Storage when the choice changes

final class DX05StorageTests: XCTestCase {
    var root: URL!
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent("dx05s-\(UUID().uuidString)"); try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func storage(_ t: TorrentFixture.Built, selected: Set<Int>) throws -> TorrentStorage {
        let s = TorrentStorage(meta: t.meta, workingFolder: root.appendingPathComponent(".\(UUID().uuidString.prefix(8)).bsetu-torrent"), selected: selected)
        try s.prepare(); return s
    }
    private func piece(_ t: TorrentFixture.Built, _ i: Int) -> Data { t.stream.subdata(in: (i * 32768)..<(i * 32768 + Int(t.meta.length(ofPiece: i)))) }

    func testAFileChosenLaterIsFilledFromWhatWasAlreadyHeldAndNothingIsFetchedTwice() throws {
        let t = try fixture([(["a"], 40_000), (["b"], 40_000)])
        let s = try storage(t, selected: [0])
        for i in 0..<2 { try s.write(piece: i, data: piece(t, i)) }          // piece 1 holds the start of b, which is not chosen: it goes to the scratch file
        try s.reselect(to: [0, 1], verified: [0, 1])
        let b = try Data(contentsOf: try s.fileURL(t.meta.files[1]))
        XCTAssertEqual(b.prefix(25_536), t.stream.subdata(in: 40_000..<65_536), "the verified part of b is already in b")
        try s.write(piece: 2, data: piece(t, 2))
        XCTAssertEqual(try Data(contentsOf: try s.fileURL(t.meta.files[1])), t.stream.subdata(in: 40_000..<80_000))
        XCTAssertEqual(s.read(piece: 1), piece(t, 1), "pieces read back the same through the new layout")
    }

    func testAFileSkippedLaterIsNotPublishedAndComesBackIfChosenAgain() throws {
        let t = try fixture([(["a"], 40_000), (["d", "b"], 40_000)])
        let s = try storage(t, selected: [0, 1])
        for i in 0..<3 { try s.write(piece: i, data: piece(t, i)) }
        try s.reselect(to: [0], verified: [0, 1, 2])
        XCTAssertFalse(FileManager.default.fileExists(atPath: (try s.fileURL(t.meta.files[1])).path), "its file is gone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.dataFolder.appendingPathComponent("d").path), "and the empty folder with it")
        XCTAssertEqual(s.read(piece: 1), piece(t, 1), "the bytes the pieces need are kept in the scratch file")
        try s.reselect(to: [0, 1], verified: [0, 1, 2])
        XCTAssertEqual(try Data(contentsOf: try s.fileURL(t.meta.files[1])), t.stream.subdata(in: 40_000..<80_000), "back, complete")
        let placed = try s.finish(into: root.appendingPathComponent("out"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: placed.appendingPathComponent("d/b").path))
    }

    func testNothingChosenIsRefusedAndChangesNothing() throws {
        let t = try fixture([(["a"], 1000), (["b"], 1000)])
        let s = try storage(t, selected: [0])
        XCTAssertThrowsError(try s.reselect(to: [], verified: []))
        XCTAssertThrowsError(try s.reselect(to: [9], verified: []))
        XCTAssertEqual(s.selected, [0])
    }

    func testOnlyChosenFilesArePublished() throws {
        let t = try fixture([(["a"], 40_000), (["b"], 40_000)])
        let s = try storage(t, selected: [0])
        for i in 0..<2 { try s.write(piece: i, data: piece(t, i)) }
        let placed = try s.finish(into: root.appendingPathComponent("out"))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: placed.path)) ?? []
        XCTAssertEqual(names, ["a"], "b was only held for the piece check and is never published")
    }
}

// MARK: Web seed addresses, ranges and the HTTP path

private final class FakeResolver: HostAddressResolving, @unchecked Sendable {
    var table: [String: [String]]
    init(_ table: [String: [String]]) { self.table = table }
    func addresses(for host: String) async -> [String]? { table[host] }
}

private final class FakeHTTP: PinnedHTTPConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [(url: URL, address: String, range: String?)] = []
    var respond: (URL, String?) throws -> PinnedHTTPResult
    init(_ respond: @escaping (URL, String?) throws -> PinnedHTTPResult) { self.respond = respond }
    func get(_ url: URL, address: String, maxBody: Int, refuseExpensive: Bool, refuseConstrained: Bool) async throws -> PinnedHTTPResult { try await get(url, address: address, maxBody: maxBody, range: nil, refuseExpensive: refuseExpensive, refuseConstrained: refuseConstrained) }
    func get(_ url: URL, address: String, maxBody: Int, range: String?, refuseExpensive: Bool, refuseConstrained: Bool) async throws -> PinnedHTTPResult {
        lock.lock(); requests.append((url, address, range)); lock.unlock()
        let r = try respond(url, range)
        if r.body.count > maxBody { throw NWPinnedHTTP.Failure.tooLarge }
        return r
    }
}

final class DX05WebSeedTests: XCTestCase {
    private func client(_ http: FakeHTTP, hosts: [String: [String]] = ["seed.test": ["93.184.216.34"]]) -> HTTPWebSeedFetcher {
        var setup = DownloadNetworkSetup(); setup.proxy.mode = .direct
        return HTTPWebSeedFetcher(client: HTTPTrackerClient(network: { setup }, resolver: FakeResolver(hosts), connector: http, authorized: { _ in false }, systemProxyActive: { false }))
    }
    private func partial(_ stream: Data, _ range: String?, status: Int = 206) -> PinnedHTTPResult {
        guard let range, range.hasPrefix("bytes=") else { return PinnedHTTPResult(status: 200, location: nil, body: stream) }
        let parts = range.dropFirst(6).split(separator: "-").compactMap { Int($0) }
        let body = stream.subdata(in: parts[0]..<(parts[1] + 1))
        return PinnedHTTPResult(status: status, location: nil, body: body, contentRange: "bytes \(parts[0])-\(parts[1])/\(stream.count)")
    }

    func testBEP19AddressesForSingleAndMultiFileTorrents() throws {
        let single = try TorrentFixture.build(name: "my file.bin", files: [(["my file.bin"], 40_000)], multi: false)
        XCTAssertEqual(WebSeedMapping.fileURL(base: URL(string: "http://m.test/pub/")!, meta: single.meta, file: single.meta.files[0])?.absoluteString, "http://m.test/pub/my%20file.bin", "a trailing slash adds the name")
        XCTAssertEqual(WebSeedMapping.fileURL(base: URL(string: "http://m.test/exact.bin")!, meta: single.meta, file: single.meta.files[0])?.absoluteString, "http://m.test/exact.bin")
        let multi = try TorrentFixture.build(name: "pack", files: [(["a", "x y.txt"], 40_000), (["b.bin"], 5)])
        XCTAssertEqual(WebSeedMapping.fileURL(base: URL(string: "http://m.test/pub/")!, meta: multi.meta, file: multi.meta.files[0])?.absoluteString, "http://m.test/pub/pack/a/x%20y.txt")
        XCTAssertEqual(WebSeedMapping.fileURL(base: URL(string: "http://m.test/pub")!, meta: multi.meta, file: multi.meta.files[1])?.absoluteString, "http://m.test/pub/pack/b.bin", "a missing slash is added for a folder")
    }

    func testAPieceAcrossTwoFilesIsTwoRanges() throws {
        let t = try TorrentFixture.build(name: "pack", files: [(["a"], 40_000), (["b"], 40_000)])
        let r = try XCTUnwrap(WebSeedMapping.requests(base: URL(string: "http://m.test/")!, meta: t.meta, piece: 1))
        XCTAssertEqual(r.map(\.range), [32768...39_999, 0...25_535])
        XCTAssertEqual(r.map { $0.url.lastPathComponent }, ["a", "b"])
    }

    func testBEP17RequestAddress() {
        let hash = Data(repeating: 0x9C, count: 20)
        let url = WebSeedMapping.hoffmanURL(base: URL(string: "http://s.test/seed.php")!, infoHash: hash, piece: 8, ranges: [49152...131071, 180224...262143])
        XCTAssertEqual(url?.absoluteString, "http://s.test/seed.php?info_hash=" + String(repeating: "%9C", count: 20) + "&piece=8&ranges=49152-131071,180224-262143")
        XCTAssertTrue(WebSeedMapping.hoffmanURL(base: URL(string: "http://s.test/seed.php?k=1")!, infoHash: hash, piece: 0)!.absoluteString.contains("?k=1&info_hash="))
        XCTAssertEqual(HTTPWebSeedFetcher.seconds(in: Data("45".utf8)), 45); XCTAssertEqual(HTTPWebSeedFetcher.seconds(in: Data("x".utf8)), 30); XCTAssertEqual(HTTPWebSeedFetcher.seconds(in: Data("99999".utf8)), 3600)
    }

    func testRangesAreAskedForAndTheRightBytesComeBack() async throws {
        let t = try TorrentFixture.build(name: "pack", files: [(["a"], 40_000), (["b"], 40_000)])
        let files = [t.stream.subdata(in: 0..<40_000), t.stream.subdata(in: 40_000..<80_000)]
        let http = FakeHTTP { url, range in self.partial(files[url.lastPathComponent == "a" ? 0 : 1], range) }
        let data = try await client(http).piece(1, from: WebSeedSource(kind: .getRight, url: URL(string: "http://seed.test/")!), meta: t.meta)
        XCTAssertEqual(data, t.stream.subdata(in: 32768..<65536))
        XCTAssertEqual(http.requests.map(\.range), ["bytes=32768-39999", "bytes=0-25535"])
        XCTAssertEqual(http.requests.first?.address, "93.184.216.34", "the connection goes to the address that was checked")
    }

    func testAServerThatIgnoresRangesIsUsedOnlyWhenTheFileIsSmallAndIsDroppedOtherwise() async throws {
        let small = try TorrentFixture.build(name: "s.bin", files: [(["s.bin"], 40_000)], multi: false)
        let ignoring = FakeHTTP { _, _ in PinnedHTTPResult(status: 200, location: nil, body: small.stream) }
        let source = WebSeedSource(kind: .getRight, url: URL(string: "http://seed.test/s.bin")!)
        let data = try await client(ignoring).piece(1, from: source, meta: small.meta)
        XCTAssertEqual(data, small.stream.subdata(in: 32768..<40_000), "a small file is read whole and cut")
        let big = try TorrentFixture.build(name: "big.bin", files: [(["big.bin"], 9 * 1024 * 1024)], multi: false)
        let hugeIgnoring = FakeHTTP { _, _ in PinnedHTTPResult(status: 200, location: nil, body: big.stream) }
        do { _ = try await client(hugeIgnoring).piece(0, from: WebSeedSource(kind: .getRight, url: URL(string: "http://seed.test/big.bin")!), meta: big.meta); XCTFail("must not read nine megabytes for one piece") }
        catch let f as WebSeedFailure { guard case .unusable = f else { return XCTFail("\(f)") } }
    }

    func testErrorsBecomeTheRightKindOfFailure() async throws {
        let t = try TorrentFixture.build(name: "s.bin", files: [(["s.bin"], 40_000)], multi: false)
        let source = WebSeedSource(kind: .getRight, url: URL(string: "http://seed.test/s.bin")!)
        func failure(_ http: FakeHTTP) async -> WebSeedFailure? { do { _ = try await client(http).piece(0, from: source, meta: t.meta); return nil } catch { return error as? WebSeedFailure } }
        let notFound = await failure(FakeHTTP { _, _ in PinnedHTTPResult(status: 404, location: nil, body: Data()) })
        XCTAssertEqual(notFound, .unusable("HTTP 404"))
        let busy = await failure(FakeHTTP { _, _ in PinnedHTTPResult(status: 503, location: nil, body: Data()) })
        XCTAssertEqual(busy, .busy(seconds: 30))
        let short = await failure(FakeHTTP { _, r in var x = self.partial(t.stream, r); x.body = x.body.dropLast(); return x })
        XCTAssertEqual(short, .wrongData, "a truncated answer")
        let wrongRange = await failure(FakeHTTP { _, r in var x = self.partial(t.stream, r); x.contentRange = "bytes 5-9/40000"; return x })
        XCTAssertEqual(wrongRange, .wrongData, "an answer for another range")
        let server = await failure(FakeHTTP { _, _ in PinnedHTTPResult(status: 500, location: nil, body: Data()) })
        XCTAssertEqual(server, .transient("HTTP 500"))
    }

    func testHTTPSeedAnswers() async throws {
        let t = try TorrentFixture.build(name: "s.bin", files: [(["s.bin"], 40_000)], multi: false)
        let source = WebSeedSource(kind: .hoffman, url: URL(string: "http://seed.test/seed.php")!)
        let good = FakeHTTP { _, _ in PinnedHTTPResult(status: 200, location: nil, body: self.partialBody(t.stream, 1)) }
        let piece = try await client(good).piece(1, from: source, meta: t.meta)
        XCTAssertEqual(piece, t.stream.subdata(in: 32768..<40_000))
        XCTAssertTrue(good.requests[0].url.absoluteString.contains("piece=1") && good.requests[0].url.absoluteString.contains("info_hash=%"))
        let busy = FakeHTTP { _, _ in PinnedHTTPResult(status: 503, location: nil, body: Data("45".utf8)) }
        do { _ = try await client(busy).piece(0, from: source, meta: t.meta); XCTFail("busy") } catch { XCTAssertEqual(error as? WebSeedFailure, .busy(seconds: 45)) }
        let short = FakeHTTP { _, _ in PinnedHTTPResult(status: 200, location: nil, body: Data(count: 10)) }
        do { _ = try await client(short).piece(0, from: source, meta: t.meta); XCTFail("short") } catch { XCTAssertEqual(error as? WebSeedFailure, .wrongData) }
    }
    private func partialBody(_ stream: Data, _ piece: Int) -> Data { stream.subdata(in: (piece * 32768)..<min(stream.count, (piece + 1) * 32768)) }

    func testAddressesFromTorrentMetadataAreNotContactedWhenLocalUnlessApproved() async throws {
        let t = try TorrentFixture.build(name: "s.bin", files: [(["s.bin"], 40_000)], multi: false)
        let http = FakeHTTP { _, r in self.partial(t.stream, r) }
        for url in ["http://192.168.1.20/s.bin", "http://127.0.0.1:8080/s.bin", "http://nas.test/s.bin"] {
            do {
                _ = try await client(http, hosts: ["nas.test": ["10.0.0.5"]]).piece(0, from: WebSeedSource(kind: .getRight, url: URL(string: url)!), meta: t.meta)
                XCTFail("\(url) is on the local network and was not approved")
            } catch { guard case .blocked? = error as? WebSeedFailure else { return XCTFail("\(url): \(error)") } }
        }
        XCTAssertTrue(http.requests.isEmpty, "nothing was sent")
    }

    func testARedirectToTheLocalNetworkIsRefused() async throws {
        let t = try TorrentFixture.build(name: "s.bin", files: [(["s.bin"], 40_000)], multi: false)
        let http = FakeHTTP { url, _ in url.host == "seed.test" ? PinnedHTTPResult(status: 302, location: "http://192.168.1.1/admin", body: Data()) : PinnedHTTPResult(status: 200, location: nil, body: Data()) }
        do { _ = try await client(http).piece(0, from: WebSeedSource(kind: .getRight, url: URL(string: "http://seed.test/s.bin")!), meta: t.meta); XCTFail("must refuse") }
        catch { guard case .blocked? = error as? WebSeedFailure else { return XCTFail("\(error)") } }
        XCTAssertEqual(http.requests.count, 1, "the second hop was never made")
    }

    func testSeedsAreListedOnceFromTheTorrentAndTheMagnet() throws {
        let t = try TorrentFixture.build(name: "s.bin", files: [(["s.bin"], 100)], multi: false, extra: ["url-list": .list([TorrentFixture.b("http://a.test/s.bin"), TorrentFixture.b("ftp://x.test/s.bin")]), "httpseeds": .list([TorrentFixture.b("http://h.test/seed.php")])])
        let sources = WebSeedMapping.sources(meta: t.meta, magnetSeeds: [URL(string: "http://a.test/s.bin")!, URL(string: "http://b.test/s.bin")!])
        XCTAssertEqual(sources.map(\.url.host), ["a.test", "b.test", "h.test"], "ftp is not used; repeats collapse")
        XCTAssertEqual(sources.map(\.kind), [.getRight, .getRight, .hoffman])
    }
}

// MARK: The session with seeds, selection and priorities

private final class FakeSeed: WebSeedFetching, @unchecked Sendable {
    enum Mode { case good, corrupt, gated, busy, gone }
    private let lock = NSLock()
    private var _calls: [Int] = []
    private var _open = true
    var mode: Mode
    let stream: Data
    init(stream: Data, mode: Mode = .good) { self.stream = stream; self.mode = mode }
    var calls: [Int] { lock.lock(); defer { lock.unlock() }; return _calls }
    func open() { lock.lock(); _open = true; lock.unlock() }
    func close() { lock.lock(); _open = false; lock.unlock() }
    func piece(_ index: Int, from source: WebSeedSource, meta: TorrentMetainfo) async throws -> Data {
        lock.lock(); _calls.append(index); lock.unlock()
        switch mode {
        case .busy: throw WebSeedFailure.busy(seconds: 3600)
        case .gone: throw WebSeedFailure.unusable("HTTP 404")
        default: break
        }
        while true { lock.lock(); let ok = _open; lock.unlock(); if ok { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        var d = stream.subdata(in: (index * Int(meta.pieceLength))..<(index * Int(meta.pieceLength) + Int(meta.length(ofPiece: index))))
        if mode == .corrupt { d[0] ^= 0xFF }
        return d
    }
}

final class DX05SessionTests: TorrentSessionTestCase {
    private func torrent(_ files: [([String], Int)]) throws -> TorrentFixture.Built {
        try TorrentFixture.build(files: files, extra: ["url-list": TorrentFixture.b("http://seed.test/")])
    }

    func testAWebSeedAloneCompletesTheTorrent() async throws {
        let t = try torrent([(["a.bin"], 70_000), (["d", "b.bin"], 90_001)])
        let r = try makeRun(t, peers: [])
        r.session.webSeedFetcher = FakeSeed(stream: t.stream)
        r.session.start()
        let done = await until { r.events.finished }
        XCTAssertTrue(done, "failure: \(r.events.failure ?? "-")")
        try assertFilesMatch(r, t)
        let seed = r.session.snapshot.webSeeds.first
        XCTAssertEqual(seed?.pieces, t.meta.pieceCount); XCTAssertEqual(seed?.kind, "web seed")
        r.session.stop()
    }

    func testASeedThatSendsWrongDataIsDroppedAndPeersFinishTheJob() async throws {
        let t = try torrent([(["a.bin"], 200_000)])
        let r = try makeRun(t, peers: [1, 2])
        r.session.webSeedFetcher = FakeSeed(stream: t.stream, mode: .corrupt)
        r.session.start()
        let done = await until { r.events.finished }
        XCTAssertTrue(done, "failure: \(r.events.failure ?? "-")")
        try assertFilesMatch(r, t)
        XCTAssertEqual(r.session.snapshot.webSeeds.first?.state, "Not used")
        r.session.stop()
    }

    func testAMissingSeedIsDroppedAndABusySeedWaits() async throws {
        let t = try torrent([(["a.bin"], 100_000)])
        for mode in [FakeSeed.Mode.gone, .busy] {
            let r = try makeRun(t, peers: [1])
            r.session.webSeedFetcher = FakeSeed(stream: t.stream, mode: mode)
            r.session.start()
            let done = await until { r.events.finished }
            XCTAssertTrue(done, "peers carry on (\(mode)): \(r.events.failure ?? "-")")
            let state = r.session.snapshot.webSeeds.first?.state
            XCTAssertEqual(state, mode == .gone ? "Not used" : "Waiting")
            r.session.stop()
            PeerBudget.shared.releaseAll(task: taskID)
        }
    }

    func testOnlyTheChosenFileIsDownloadedAndTheSharedPieceIsChecked() async throws {
        let t = try torrent([(["a"], 40_000), (["b"], 40_000), (["c"], 40_000)])
        let r = try makeRun(t, peers: [], selected: [0])
        let seed = FakeSeed(stream: t.stream)
        r.session.webSeedFetcher = seed
        r.session.start()
        let done = await until { r.events.finished }
        XCTAssertTrue(done, "failure: \(r.events.failure ?? "-")")
        XCTAssertEqual(Set(seed.calls), [0, 1], "pieces 0 and 1 only: 1 holds the end of a and the start of b")
        let placed = try r.storage.finish(into: root.appendingPathComponent("out"))
        XCTAssertEqual((try FileManager.default.contentsOfDirectory(atPath: placed.path)).sorted(), ["a"], "b and c are not published")
        XCTAssertEqual(try Data(contentsOf: placed.appendingPathComponent("a")), t.stream.subdata(in: 0..<40_000))
        r.session.stop()
    }

    func testPrioritiesDecideWhichPiecesAreFetchedFirst() async throws {
        let t = try torrent([(["a"], 4 * 32768), (["b"], 4 * 32768)])
        let r = try makeRun(t, peers: [])
        let seed = FakeSeed(stream: t.stream)
        var sel = TorrentSelection.all(t.meta); sel.priorities[1] = .maximum
        r.session.initialSelection = sel
        r.session.webSeedFetcher = seed
        r.session.start()
        let done = await until { r.events.finished }
        XCTAssertTrue(done)
        XCTAssertEqual(Array(seed.calls.prefix(4)), [4, 5, 6, 7], "the Maximum file first, then the rest")
        r.session.stop()
    }

    func testChangingTheChoiceWhileRunningFillsTheNewFileFromWhatIsHeldAndCompletes() async throws {
        let t = try torrent([(["a"], 40_000), (["b"], 40_000)])
        let r = try makeRun(t, peers: [], selected: [0])
        let seed = FakeSeed(stream: t.stream)
        seed.close()
        r.session.webSeedFetcher = seed
        r.session.start()
        _ = await until(2) { false }
        let changed = expectation(description: "changed")
        r.session.updateSelection(TorrentSelection.all(t.meta)) { result in if case .failure(let e) = result { XCTFail("\\(e)") }; changed.fulfill() }
        await fulfillment(of: [changed], timeout: 5)
        XCTAssertEqual(r.storage.selected, [0, 1])
        seed.open()
        let done = await until { r.events.finished }
        XCTAssertTrue(done, "failure: \(r.events.failure ?? "-")")
        try assertFilesMatch(r, t)
        XCTAssertTrue(r.events.all.contains { if case .selectionChanged = $0 { true } else { false } }, "the change is reported so it can be saved")
        r.session.stop()
    }

    func testAChoiceOfNothingIsRefusedWhileRunning() async throws {
        let t = try torrent([(["a"], 40_000), (["b"], 40_000)])
        let r = try makeRun(t, peers: [])
        let seed = FakeSeed(stream: t.stream); seed.close()
        r.session.webSeedFetcher = seed
        r.session.start()
        let refused = expectation(description: "refused")
        r.session.updateSelection(TorrentSelection.only([], in: t.meta)) { result in if case .failure = result { refused.fulfill() } }
        await fulfillment(of: [refused], timeout: 5)
        XCTAssertEqual(r.storage.selected, [0, 1], "nothing changed")
        r.session.stop()
    }

    func testFileProgressCountsVerifiedBytesPerFile() async throws {
        let t = try torrent([(["a"], 40_000), (["b"], 40_000)])
        let r = try makeRun(t, peers: [], have: [0])
        let seed = FakeSeed(stream: t.stream); seed.close()
        r.session.webSeedFetcher = seed
        r.session.start()
        let got = expectation(description: "progress")
        var rows: [TorrentFileProgress] = []
        r.session.fileProgress { rows = $0; got.fulfill() }
        await fulfillment(of: [got], timeout: 5)
        XCTAssertEqual(rows.map(\.verified), [32768, 0])
        XCTAssertEqual(rows.map(\.priority), [.normal, .normal])
        r.session.stop()
    }
}

// MARK: Saved state

final class DX05SidecarTests: XCTestCase {
    func testPrioritiesOrderAndSeedsSurviveARelaunchAndOldSidecarsStillLoad() throws {
        let t = try TorrentFixture.build(files: [(["a"], 100), (["b"], 100), (["c"], 100)], extra: ["url-list": TorrentFixture.b("http://s.test/"), "httpseeds": .list([TorrentFixture.b("http://h.test/seed.php")])])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dx05side-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var sel = TorrentSelection.only([0, 2], in: t.meta); sel.priorities[2] = .maximum; sel.mode = .streaming; sel.streamFile = 2; sel.streamPosition = 55
        try TorrentRunner.saveSidecar(folder, meta: t.meta, selected: sel.selected(in: t.meta), trackers: [], selection: sel, magnetSeeds: [URL(string: "http://m.test/x")!])
        let loaded = try XCTUnwrap(TorrentRunner.loadSidecar(folder, expectedHash: t.meta.infoHashHex))
        XCTAssertEqual(loaded.selection.priority(of: 2), .maximum); XCTAssertEqual(loaded.selection.priority(of: 1), .skip)
        XCTAssertEqual(loaded.selection.mode, .streaming); XCTAssertEqual(loaded.selection.streamFile, 2); XCTAssertEqual(loaded.selection.streamPosition, 55)
        XCTAssertEqual(loaded.meta.webSeeds.map(\.host), ["s.test"]); XCTAssertEqual(loaded.meta.httpSeeds.map(\.host), ["h.test"]); XCTAssertEqual(loaded.magnetSeeds.map(\.host), ["m.test"])
        // A sidecar written before DX-05 has only the chosen files: they load at Normal, in the usual order.
        let old = #"{"selected":[1],"trackers":[]}"#
        try Data(old.utf8).write(to: folder.appendingPathComponent(".state.json"))
        let legacy = try XCTUnwrap(TorrentRunner.loadSidecar(folder, expectedHash: nil))
        XCTAssertEqual(legacy.selected, [1]); XCTAssertEqual(legacy.selection.priority(of: 1), .normal); XCTAssertEqual(legacy.selection.mode, .automatic)
        // Damaged choices never mean "everything": priorities that name no real file leave nothing chosen, so the sidecar is refused.
        let junk = #"{"selected":[0],"trackers":[],"priorities":{"77":2,"x":9},"mode":"nonsense"}"#
        try Data(junk.utf8).write(to: folder.appendingPathComponent(".state.json"))
        XCTAssertNil(TorrentRunner.loadSidecar(folder, expectedHash: nil))
    }
}

// MARK: Fixes found by the independent review

final class DX05ReviewFixTests: XCTestCase {
    private func all(_ n: Int) -> Data { PeerWire.makeBitfield(Array(repeating: true, count: n)) }

    func testTheLastStretchNeverDuplicatesABlockThatAWebSeedOwns() throws {
        let t = try fixture([(["a"], 32768)])
        let p = TorrentPicker(meta: t.meta, needed: [0], alreadyHave: [], selected: [])
        p.peerBitfield(1, all(1))
        XCTAssertEqual(p.claimWholePiece(for: -1, now: 0), 0)
        XCTAssertTrue(p.isEndgame)
        XCTAssertTrue(p.nextRequests(for: 1, limit: 8, now: 0).isEmpty, "a seed's whole-piece claim is not split with a peer: its answer would be wasted")
    }

    func testAnExpiredSeedClaimIsGivenLongerThanAPeersRequest() throws {
        let t = try fixture([(["a"], 32768 * 2)])
        let p = TorrentPicker(meta: t.meta, needed: [0, 1], alreadyHave: [], selected: [])
        p.peerBitfield(1, all(2))
        _ = p.claimWholePiece(for: -1, now: 0)
        _ = p.nextRequests(for: 1, limit: 8, now: 0)
        let slow = p.expire(olderThan: 30, now: 45)
        XCTAssertEqual(slow, [1], "the peer's requests expired; the seed is still within its longer allowance")
        XCTAssertEqual(p.expire(olderThan: 30, now: 130), [-1])
    }

    func testAPeerThatLeavesIsNotPromotedBackToOwnerOfItsOwnBlock() throws {
        let t = try fixture([(["a"], 32768)])
        let p = TorrentPicker(meta: t.meta, needed: [0], alreadyHave: [], selected: [])
        p.peerBitfield(1, all(1)); p.peerBitfield(2, all(1))
        _ = p.nextRequests(for: 1, limit: 8, now: 0)
        _ = p.nextRequests(for: 2, limit: 8, now: 0)          // peer 2 asked too (last stretch)
        p.peerGone(2)
        XCTAssertEqual(p.inFlight(for: 2), 0, "nothing stays asked of a peer that left")
        XCTAssertEqual(p.inFlight(for: 1), 2)
        p.rejected(from: 1, piece: 0, begin: 0)
        XCTAssertEqual(p.inFlight(for: 1), 1)
    }

    func testAnUnchosenFileLeftInTheDataFolderIsNeverPublished() throws {
        let t = try fixture([(["a"], 40_000), (["d", "b"], 40_000)])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dx05f-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let s = TorrentStorage(meta: t.meta, workingFolder: root.appendingPathComponent(".aaaaaaaa.bsetu-torrent"), selected: [0])
        try s.prepare()
        try s.write(piece: 0, data: t.stream.subdata(in: 0..<32768))
        // What a failed change of the choice could leave behind: a full-length file for a file that was never chosen.
        let stray = s.dataFolder.appendingPathComponent("d/b")
        try FileManager.default.createDirectory(at: stray.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 40_000).write(to: stray)
        let placed = try s.finish(into: root.appendingPathComponent("out"))
        XCTAssertEqual((try FileManager.default.contentsOfDirectory(atPath: placed.path)).sorted(), ["a"])
    }

    func testEmptyFilesFollowTheChoiceToo() throws {
        let t = try fixture([(["a"], 40_000), (["empty"], 0)])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dx05e-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let s = TorrentStorage(meta: t.meta, workingFolder: root.appendingPathComponent(".bbbbbbbb.bsetu-torrent"), selected: [0])
        try s.prepare()
        let emptyURL = try s.fileURL(t.meta.files[1])
        XCTAssertFalse(FileManager.default.fileExists(atPath: emptyURL.path))
        try s.reselect(to: [0, 1], verified: [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: emptyURL.path), "chosen: it exists, empty")
        try s.reselect(to: [0], verified: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: emptyURL.path), "no longer chosen: it is not published")
    }

    func testAShortBodyIsAFailedTransferNotADifferentFile() {
        let raw = Data("HTTP/1.0 200 OK\r\nContent-Length: 10\r\n\r\nabc".utf8)
        XCTAssertThrowsError(try NWPinnedHTTP.parse(raw, maxBody: 100))
        XCTAssertNoThrow(try NWPinnedHTTP.parse(Data("HTTP/1.0 200 OK\r\nContent-Length: 3\r\n\r\nabc".utf8), maxBody: 100))
        XCTAssertNoThrow(try NWPinnedHTTP.parse(Data("HTTP/1.0 200 OK\r\n\r\nabc".utf8), maxBody: 100), "no length given: what arrived is the body (HTTP/1.0 reads to the end)")
    }
}

final class DX05SessionRaceTests: TorrentSessionTestCase {
    func testAChoiceThatGrowsWhileTheLastPieceIsBeingCheckedDoesNotFinishWithHoles() async throws {
        let t = try TorrentFixture.build(files: [(["a"], 40_000), (["b"], 40_000)], extra: ["url-list": TorrentFixture.b("http://seed.test/")])
        // Everything of a is held; the session is about to run the final check for a alone. At the same moment the choice grows to include b.
        let r = try makeRun(t, peers: [], selected: [0], have: [0, 1])
        let seed = FakeSeedForRace(stream: t.stream)
        r.session.webSeedFetcher = seed
        r.session.start()
        let changed = expectation(description: "changed")
        r.session.updateSelection(TorrentSelection.all(t.meta)) { _ in changed.fulfill() }
        await fulfillment(of: [changed], timeout: 5)
        let done = await until { r.events.finished }
        XCTAssertTrue(done, "it finishes, after b has been fetched: \(r.events.failure ?? "-")")
        try assertFilesMatch(r, t)          // b is exact: it was not published with zero-filled holes
        r.session.stop()
    }
}

private final class FakeSeedForRace: WebSeedFetching, @unchecked Sendable {
    let stream: Data
    init(stream: Data) { self.stream = stream }
    func piece(_ index: Int, from source: WebSeedSource, meta: TorrentMetainfo) async throws -> Data {
        stream.subdata(in: (index * Int(meta.pieceLength))..<(index * Int(meta.pieceLength) + Int(meta.length(ofPiece: index))))
    }
}

// MARK: DX-05 closure

final class DX05ClosureTests: TorrentSessionTestCase {
    private func torrent(_ files: [([String], Int)], extra: [String: Bencode] = ["url-list": TorrentFixture.b("http://seed.test/")]) throws -> TorrentFixture.Built {
        try TorrentFixture.build(files: files, extra: extra)
    }

    // HTTP-only: no peer network

    func testAWebSeedOnlyTorrentContactsNoTrackerAndNoPeer() async throws {
        let t = try torrent([(["a.bin"], 100_000)])
        let r = try makeRun(t, peers: [1, 2])          // a tracker that would name two peers, if it were asked
        r.session.peerNetworkEnabled = false
        r.session.webSeedFetcher = FakeSeedForRace(stream: t.stream)
        r.session.start()
        let done = await until { r.events.finished }
        XCTAssertTrue(done, "failure: \(r.events.failure ?? "-")")
        try assertFilesMatch(r, t)
        XCTAssertTrue(r.factory.all.isEmpty, "no peer connection was ever made")
        XCTAssertEqual(r.session.snapshot.peers + r.session.snapshot.connecting, 0)
        XCTAssertTrue(r.session.snapshot.trackerRows.allSatisfy { $0.secondsSinceAnnounce == nil }, "no tracker was asked")
        XCTAssertFalse(r.session.adoptInbound(ScriptedPeer(PeerAddress(host: "198.51.100.5", port: 1), queue: DispatchQueue(label: "x")), address: PeerAddress(host: "198.51.100.5", port: 1), initial: Data()), "and no incoming peer is taken")
        r.session.stop()
    }

    // Names exactly as the torrent wrote them

    func testWebSeedAddressesUseTheNamesAsWrittenWhileTheDiskUsesTheNormalisedOnes() throws {
        // "é" written as e + combining accent (not normalised), and a trailing space the disk name drops.
        let decomposed = "caf\u{65}\u{301}.txt "
        let t = try torrent([(["dir", decomposed], 100)])
        let file = t.meta.files[0]
        XCTAssertEqual(file.path[1], "caf\u{E9}.txt", "the disk name is composed and trimmed")
        XCTAssertEqual(file.rawPath?[1], decomposed)
        let url = try XCTUnwrap(WebSeedMapping.fileURL(base: URL(string: "http://m.test/pub/")!, meta: t.meta, file: file))
        XCTAssertTrue(url.absoluteString.hasSuffix("/dir/cafe%CC%81.txt%20"), url.absoluteString)
        let plain = try torrent([(["a", "b.txt"], 10)])
        XCTAssertNil(plain.meta.files[0].rawPath, "nothing extra is kept when the names are already plain")
    }

    // Preserving verified bytes

    func testVerifiedBytesInTheOtherPlaceAreFoundAndPutBackByHash() throws {
        let t = try torrent([(["a"], 40_000), (["b"], 40_000)])
        let s = TorrentStorage(meta: t.meta, workingFolder: TorrentStorage.workingFolder(for: taskID, in: root), selected: [0])
        try s.prepare()
        for i in 0..<3 { try s.write(piece: i, data: t.stream.subdata(in: (i * 32768)..<(i * 32768 + Int(t.meta.length(ofPiece: i))))) }          // b's bytes of pieces 1 and 2 go to the scratch file
        // The choice was saved as {a, b} but the files were never rearranged (the app stopped in between): b's file is sparse zeros while its verified bytes sit in the scratch file.
        let resumed = TorrentStorage(meta: t.meta, workingFolder: s.workingFolder, selected: [0, 1])
        s.closeAll()
        try resumed.prepare()
        let result = resumed.reconcile(verified: [0, 1, 2])
        XCTAssertEqual(result.healed, 2, "pieces 1 and 2 were in the scratch file")
        XCTAssertTrue(result.missing.isEmpty)
        XCTAssertEqual(try Data(contentsOf: try resumed.fileURL(t.meta.files[1])).prefix(40_000 - 0).prefix(25_536), t.stream.subdata(in: 40_000..<65_536))
    }

    func testAPieceFoundInNeitherPlaceIsNotKept() throws {
        let t = try torrent([(["a"], 40_000), (["b"], 40_000)])
        let s = TorrentStorage(meta: t.meta, workingFolder: TorrentStorage.workingFolder(for: taskID, in: root), selected: [0, 1])
        try s.prepare()
        try s.write(piece: 0, data: t.stream.subdata(in: 0..<32768))
        let result = s.reconcile(verified: [0, 3])
        XCTAssertEqual(result.missing, [3], "claimed verified, but the bytes are nowhere: to be fetched again")
        XCTAssertEqual(result.healed, 0)
    }

    // Verified reads (for a player) and playback position

    func testOnlyVerifiedBytesAreHandedToAReaderAndTheWaitEndsWhenTheyArrive() async throws {
        let t = try torrent([(["movie.mp4"], 4 * 32768)])
        let r = try makeRun(t, peers: [], have: [0])
        var sel = TorrentSelection.all(t.meta); sel.mode = .streaming
        let seed = FakeSeed(stream: t.stream); seed.close()
        r.session.initialSelection = sel
        r.session.webSeedFetcher = seed
        r.session.start()
        let known: Data? = await withCheckedContinuation { c in r.session.readVerified(file: 0, offset: 100, length: 5000) { c.resume(returning: $0) } }
        XCTAssertEqual(known, t.stream.subdata(in: 100..<5100), "inside a verified piece")
        let early: Data? = await withCheckedContinuation { c in r.session.readVerified(file: 0, offset: 3 * 32768, length: 10) { c.resume(returning: $0) } }
        XCTAssertNil(early, "not verified yet: nothing is handed over")
        let across: Data? = await withCheckedContinuation { c in r.session.readVerified(file: 0, offset: 32768 - 10, length: 20) { c.resume(returning: $0) } }
        XCTAssertNil(across, "a read that reaches into an unverified piece is refused whole")
        seed.open()
        let waited = await r.session.waitForVerified(file: 0, offset: 3 * 32768, length: 10, timeout: 10)
        XCTAssertEqual(waited, t.stream.subdata(in: (3 * 32768)..<(3 * 32768 + 10)))
        r.session.stop()
    }

    func testAskingAheadMovesThePlaybackPositionSoThosePiecesComeNext() async throws {
        let t = try torrent([(["movie.mp4"], 8 * 32768)])
        let r = try makeRun(t, peers: [])
        var sel = TorrentSelection.all(t.meta); sel.mode = .streaming
        let seed = FakeSeed(stream: t.stream)
        r.session.initialSelection = sel
        r.session.webSeedFetcher = seed
        seed.close()          // nothing arrives yet; what is asked for first is what matters
        r.session.start()
        _ = await until(1) { false }
        let _: Data? = await withCheckedContinuation { c in r.session.readVerified(file: 0, offset: 6 * 32768 + 5, length: 100) { c.resume(returning: $0) } }
        _ = await until(1) { false }
        let firstAfter = seed.calls.last
        seed.open()
        let done = await until { r.events.finished }
        XCTAssertTrue(done)
        XCTAssertNotNil(firstAfter)
        XCTAssertEqual(seed.calls.suffix(8).first.map { $0 >= 0 }, true)
        XCTAssertTrue(seed.calls.contains(6), "the pieces at the playback position were fetched")
        r.session.stop()
    }

    // The sidecar remembers the web-seed-only choice

    func testWebSeedOnlyAndLocalApprovalSurviveARelaunch() throws {
        let t = try torrent([(["a"], 100), (["b"], 100)])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dx05cl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try TorrentRunner.saveSidecar(folder, meta: t.meta, selected: [0, 1], trackers: [], selection: TorrentSelection.all(t.meta), magnetSeeds: [], httpOnly: true, allowLocalWebSeeds: true)
        let loaded = try XCTUnwrap(TorrentRunner.loadSidecar(folder, expectedHash: nil))
        XCTAssertTrue(loaded.httpOnly); XCTAssertTrue(loaded.allowLocalWebSeeds)
        try TorrentRunner.saveSidecar(folder, meta: t.meta, selected: [0, 1], trackers: [])
        let plain = try XCTUnwrap(TorrentRunner.loadSidecar(folder, expectedHash: nil))
        XCTAssertFalse(plain.httpOnly); XCTAssertFalse(plain.allowLocalWebSeeds)
    }
}
