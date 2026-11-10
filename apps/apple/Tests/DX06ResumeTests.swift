import CryptoKit
import XCTest
@testable import Browser_Setu

// DX-06 workstream R: the fast-resume trust model. Temp folders only.

private final class DX06ResumeBox<T>: @unchecked Sendable {
    private let lock = NSLock(); private var v: T
    init(_ v: T) { self.v = v }
    func with<R>(_ f: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return f(&v) }
}

private struct DX06ResumeRig {
    let folder: URL
    let t: TorrentFixture.Built
    var meta: TorrentMetainfo { t.meta }
    let names: [String]

    /// Files a (40_000), b (40_000), c (40_000); piece length 32_768 => pieces: 0 [a], 1 [a,b], 2 [b,c], 3 [c].
    init(sizes: [Int] = [40_000, 40_000, 40_000]) throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("dx06-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        names = sizes.indices.map { "f\($0)" }
        t = try TorrentFixture.build(files: zip(names, sizes).map { ([$0.0], $0.1) })
        var off = 0
        for (i, n) in sizes.enumerated() { try t.stream.subdata(in: off..<(off + n)).write(to: folder.appendingPathComponent(names[i])); off += n }
    }
    func url(_ i: Int) -> URL { folder.appendingPathComponent(names[i]) }
    var recordURL: URL { folder.appendingPathComponent(".resume.json") }
    func identities() -> [Int: TorrentFileIdentity?] { ResumeTrust.captureIdentities(meta: meta, url: url) }
    func concrete() -> [Int: TorrentFileIdentity] { identities().compactMapValues { $0 } }
    /// A record in which every piece was verified now, after the files were written.
    func fullRecord(verifiedAt: Date = Date()) -> ResumeRecord {
        ResumeRecord(infoHash: meta.infoHashHex, pieceCount: meta.pieceCount, pieceLength: meta.pieceLength, verified: Set(0..<meta.pieceCount), verifiedAt: verifiedAt, files: concrete())
    }
    func evaluate(_ r: ResumeRecord?, level: ResumeTrustLevel = .identityOnly, scratch: TorrentFileIdentity? = nil, unselected: Set<Int> = []) -> ResumeTrust.Decision {
        ResumeTrust.evaluate(record: r, meta: meta, currentIdentities: identities(), currentScratch: scratch, unselectedFiles: unselected, trustLevel: level)
    }
    func cleanup() { try? FileManager.default.removeItem(at: folder) }
    func setMtime(_ i: Int, _ date: Date) { utimes(url(i).path, [timeval(tv_sec: Int(date.timeIntervalSince1970), tv_usec: 0), timeval(tv_sec: Int(date.timeIntervalSince1970), tv_usec: 0)]) }
}

final class DX06ResumeTests: XCTestCase {
    private func rig(_ sizes: [Int] = [40_000, 40_000, 40_000]) throws -> DX06ResumeRig { let r = try DX06ResumeRig(sizes: sizes); addTeardownBlock { r.cleanup() }; return r }

    // MARK: record persistence

    func testCleanRoundTripAndTrustsEverything() throws {
        let r = try rig(); let rec = r.fullRecord()
        try rec.write(to: r.recordURL)
        let back = try ResumeRecord.load(from: r.recordURL, expecting: r.meta)
        XCTAssertEqual(back, rec); XCTAssertTrue(back.checksumIsValid)
        let d = r.evaluate(back)
        XCTAssertEqual(d.trusted, Set(0..<4)); XCTAssertTrue(d.mustRehash.isEmpty)
        // Overwriting an existing file also works, and no temp file is left.
        try rec.bumped(afterVerifying: [], identities: r.concrete(), meta: r.meta, now: Date()).write(to: r.recordURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.folder.appendingPathComponent(".resume.json.tmp").path))
        XCTAssertNotNil(ResumeRecord.decode(rec.encoded()))
    }

    func testCorruptChecksumIsRefused() throws {
        let r = try rig(); var rec = r.fullRecord(); rec.downloadedBytes = 5   // edited after sealing
        try JSONEncoder().encode(rec).write(to: r.recordURL)   // plain encoder, default date format: unreadable too
        XCTAssertThrowsError(try ResumeRecord.load(from: r.recordURL))
        var tampered = r.fullRecord().encoded()
        let s = String(decoding: tampered, as: UTF8.self).replacingOccurrences(of: "\"pieceLength\":32768", with: "\"pieceLength\":65536")
        tampered = Data(s.utf8)
        try tampered.write(to: r.recordURL)
        XCTAssertThrowsError(try ResumeRecord.load(from: r.recordURL)) { XCTAssertEqual($0 as? ResumeRecord.Failure, .badChecksum) }
        XCTAssertNil(ResumeRecord.decode(tampered))
    }

    func testTruncatedAndGarbageNeverCrash() throws {
        let r = try rig(); let good = r.fullRecord().encoded()
        for cut in [0, 1, good.count / 2, good.count - 1] {
            try good.prefix(cut).write(to: r.recordURL)
            XCTAssertThrowsError(try ResumeRecord.load(from: r.recordURL)); XCTAssertNil(ResumeRecord.decode(Data(good.prefix(cut))))
        }
        for junk in [Data([0xff, 0xfe, 0, 1]), Data("{}".utf8), Data("[1,2,3]".utf8), Data("null".utf8), Data(repeating: 0x7b, count: 5000)] {
            XCTAssertNil(ResumeRecord.decode(junk))
        }
        XCTAssertThrowsError(try ResumeRecord.load(from: r.folder.appendingPathComponent("absent")))
    }

    func testRecordOfAnotherTorrentIsRefusedAndRehashesAll() throws {
        let r = try rig(); let other = try rig([50_000])
        try r.fullRecord().write(to: r.recordURL)
        XCTAssertThrowsError(try ResumeRecord.load(from: r.recordURL, expecting: other.meta))
        XCTAssertThrowsError(try ResumeRecord.load(from: r.recordURL, expectingInfoHash: other.meta.infoHashHex)) { XCTAssertEqual($0 as? ResumeRecord.Failure, .wrongTorrent) }
        let d = ResumeTrust.evaluate(record: r.fullRecord(), meta: other.meta, currentIdentities: other.identities())
        XCTAssertTrue(d.trusted.isEmpty); XCTAssertEqual(d.mustRehash.count, other.meta.pieceCount); XCTAssertEqual(d.reasons[0], .otherTorrent)
        // Version-aware: a v1 record is not accepted for a hybrid torrent.
        XCTAssertThrowsError(try ResumeRecord.load(from: r.recordURL, torrentVersion: "hybrid", infoHashV2: "ab"))
        XCTAssertNil(ResumeRecord.decode(r.fullRecord().encoded(), torrentVersion: "v2", infoHashV2: nil))
        let h = ResumeRecord(infoHash: r.meta.infoHashHex, torrentVersion: "hybrid", infoHashV2: "ABCD", pieceCount: 4, pieceLength: 32768, verified: [0], verifiedAt: Date(), files: [:])
        XCTAssertNotNil(ResumeRecord.decode(h.encoded(), torrentVersion: "hybrid", infoHashV2: "abcd"))
        XCTAssertNil(ResumeRecord.decode(h.encoded(), torrentVersion: "hybrid", infoHashV2: "ffff"))
        XCTAssertEqual(ResumeTrust.evaluate(record: h, meta: r.meta, currentIdentities: r.identities()).trusted, [], "v1 torrent vs hybrid record")
    }

    func testOversizedFileIsRefused() throws {
        let r = try rig()
        try Data(repeating: 0x20, count: ResumeRecord.maxFileBytes + 1).write(to: r.recordURL)
        XCTAssertThrowsError(try ResumeRecord.load(from: r.recordURL)) { XCTAssertEqual($0 as? ResumeRecord.Failure, .tooLarge) }
        XCTAssertNil(ResumeRecord.decode(Data(repeating: 0x20, count: ResumeRecord.maxFileBytes + 1)))
    }

    func testSymlinkedRecordIsRefused() throws {
        let r = try rig(); let real = r.folder.appendingPathComponent("real.json")
        try r.fullRecord().write(to: real)
        try FileManager.default.createSymbolicLink(at: r.recordURL, withDestinationURL: real)
        XCTAssertThrowsError(try ResumeRecord.load(from: r.recordURL)) { XCTAssertEqual($0 as? ResumeRecord.Failure, .notARegularFile) }
    }

    func testBitmapLengthMismatchIsRefused() throws {
        let r = try rig(); var rec = r.fullRecord(); rec.verifiedBitmap = Data([0xff, 0xff]); rec.checksum = rec.computeChecksum()   // resealed, still wrong shape
        try rec.write(to: r.recordURL)
        XCTAssertThrowsError(try ResumeRecord.load(from: r.recordURL)) { XCTAssertEqual($0 as? ResumeRecord.Failure, .wrongShape) }
        var stray = r.fullRecord(); stray.verifiedBitmap = Data([0xff]); stray.checksum = stray.computeChecksum()   // bits past pieceCount (4) set
        try stray.write(to: r.recordURL)
        XCTAssertThrowsError(try ResumeRecord.load(from: r.recordURL))
        XCTAssertFalse(ResumeRecord.empty(for: r.meta).isVerified(99))
    }

    // MARK: trust decisions

    func testNoRecordMeansAllRehash() throws {
        let r = try rig(); let d = r.evaluate(nil)
        XCTAssertEqual(d, .allRehash(pieceCount: 4)); XCTAssertEqual(d.reasons[2], .noRecord)
    }

    func testSizeChangedRehashesPiecesTouchingThatFileOnly() throws {
        let r = try rig(); let rec = r.fullRecord()
        let h = try FileHandle(forWritingTo: r.url(2)); try h.seekToEnd(); try h.write(contentsOf: Data([1])); try h.close()
        let d = r.evaluate(rec)
        XCTAssertEqual(d.mustRehash, [2, 3]); XCTAssertEqual(d.trusted, [0, 1])
        XCTAssertEqual(d.reasons[3], .sizeChanged(2))
    }

    func testMtimeChangedRehashesTouchingPiecesOnlyAcrossASpan() throws {
        let r = try rig(); let rec = r.fullRecord()
        r.setMtime(1, Date(timeIntervalSinceNow: -3600))   // b: touched by pieces 1 and 2 only; a and c untouched
        let d = r.evaluate(rec)
        XCTAssertEqual(d.mustRehash, [1, 2]); XCTAssertEqual(d.trusted, [0, 3])
        XCTAssertEqual(d.reasons[1], .mtimeChanged(1))
    }

    func testInodeChangedByReplacementWithACopy() throws {
        let r = try rig(); let rec = r.fullRecord()
        let old = TorrentFileIdentity.capture(r.url(0))!
        let copy = r.folder.appendingPathComponent("copy"); try FileManager.default.copyItem(at: r.url(0), to: copy)
        try FileManager.default.removeItem(at: r.url(0)); try FileManager.default.moveItem(at: copy, to: r.url(0))
        // Make size and mtime identical so ONLY the inode differs.
        let ts = [timeval(tv_sec: Int(old.mtimeNanos / 1_000_000_000), tv_usec: 0)]
        _ = ts
        var times = [timespec(tv_sec: Int(old.mtimeNanos / 1_000_000_000), tv_nsec: Int(old.mtimeNanos % 1_000_000_000)), timespec(tv_sec: Int(old.mtimeNanos / 1_000_000_000), tv_nsec: Int(old.mtimeNanos % 1_000_000_000))]
        XCTAssertEqual(utimensat(AT_FDCWD, r.url(0).path, &times, 0), 0)
        let now = TorrentFileIdentity.capture(r.url(0))!
        XCTAssertEqual(now.size, old.size); XCTAssertEqual(now.mtimeNanos, old.mtimeNanos); XCTAssertNotEqual(now.inode, old.inode)
        let d = r.evaluate(rec)
        XCTAssertEqual(d.mustRehash, [0, 1]); XCTAssertEqual(d.reasons[0], .inodeChanged(0))
    }

    func testMissingFileRehashesItsPieces() throws {
        let r = try rig(); let rec = r.fullRecord()
        try FileManager.default.removeItem(at: r.url(2))
        let d = r.evaluate(rec)
        XCTAssertEqual(d.mustRehash, [2, 3]); XCTAssertEqual(d.reasons[2], .missingFile(2))
    }

    func testFileNewerThanVerifiedAtIsNotTrusted() throws {
        let r = try rig()
        let rec = r.fullRecord(verifiedAt: Date(timeIntervalSinceNow: -3600))   // identities captured now, but the record claims verification an hour ago
        let d = r.evaluate(rec)
        XCTAssertTrue(d.trusted.isEmpty); XCTAssertEqual(d.reasons[0], .newerThanVerification(0))
    }

    func testSymlinkReplacingADataFileIsNotTrusted() throws {
        let r = try rig(); let rec = r.fullRecord()
        let target = r.folder.appendingPathComponent("elsewhere"); try r.t.stream.subdata(in: 0..<40_000).write(to: target)
        try FileManager.default.removeItem(at: r.url(0)); try FileManager.default.createSymbolicLink(at: r.url(0), withDestinationURL: target)
        XCTAssertNil(TorrentFileIdentity.capture(r.url(0)))
        let d = r.evaluate(rec)
        XCTAssertEqual(d.mustRehash, [0, 1]); XCTAssertEqual(d.reasons[0], .missingFile(0))
    }

    func testRehashAllTrustsNothing() throws {
        let r = try rig(); let d = r.evaluate(r.fullRecord(), level: .rehashAll)
        XCTAssertTrue(d.trusted.isEmpty); XCTAssertEqual(d.mustRehash.count, 4); XCTAssertEqual(d.reasons[1], .rehashAll)
    }

    func testUnverifiedPiecesAreRehashedEvenWhenFilesMatch() throws {
        let r = try rig()
        let rec = ResumeRecord(infoHash: r.meta.infoHashHex, pieceCount: 4, pieceLength: r.meta.pieceLength, verified: [0, 3], verifiedAt: Date(), files: r.concrete())
        let d = r.evaluate(rec)
        XCTAssertEqual(d.trusted, [0, 3]); XCTAssertEqual(d.reasons[1], .notVerified)
    }

    func testScratchIdentityChangeRehashesPiecesWithUnselectedBytes() throws {
        let r = try rig()
        let scratch = r.folder.appendingPathComponent(".unselected"); try Data(repeating: 9, count: 40_000).write(to: scratch)
        let sid = TorrentFileIdentity.capture(scratch)
        // b (index 1) is unselected: its bytes live in the scratch file; there is no data file for it.
        try FileManager.default.removeItem(at: r.url(1))
        var ids = r.concrete(); ids[1] = nil
        let rec = ResumeRecord(infoHash: r.meta.infoHashHex, pieceCount: 4, pieceLength: r.meta.pieceLength, verified: Set(0..<4), verifiedAt: Date(), files: ids, scratch: sid)
        let cur = ResumeTrust.captureIdentities(meta: r.meta, skipping: [1], url: r.url)
        let ok = ResumeTrust.evaluate(record: rec, meta: r.meta, currentIdentities: cur, currentScratch: TorrentFileIdentity.capture(scratch), unselectedFiles: [1])
        XCTAssertEqual(ok.trusted, Set(0..<4))
        // Scratch rewritten (same size, new mtime): pieces 1 and 2 touch b and are rehashed; 0 and 3 do not.
        var times = [timeval(tv_sec: Int(Date().timeIntervalSince1970) - 7200, tv_usec: 0), timeval(tv_sec: Int(Date().timeIntervalSince1970) - 7200, tv_usec: 0)]
        utimes(scratch.path, &times)
        let bad = ResumeTrust.evaluate(record: rec, meta: r.meta, currentIdentities: cur, currentScratch: TorrentFileIdentity.capture(scratch), unselectedFiles: [1])
        XCTAssertEqual(bad.mustRehash, [1, 2]); XCTAssertEqual(bad.reasons[1], .scratchChanged)
        let gone = ResumeTrust.evaluate(record: rec, meta: r.meta, currentIdentities: cur, currentScratch: nil, unselectedFiles: [1])
        XCTAssertEqual(gone.mustRehash, [1, 2])
    }

    func testPaddingFilesNeedNoIdentity() throws {
        let r = try rig()
        let rec = r.fullRecord()
        try FileManager.default.removeItem(at: r.url(1))   // file 1 acts as a padding file: absent on disk
        var ids = r.identities(); ids[1] = nil
        let d = ResumeTrust.evaluate(record: rec, meta: r.meta, currentIdentities: ids, isPaddingFile: { $0 == 1 })
        XCTAssertEqual(d.trusted, Set(0..<4))
        let d2 = ResumeTrust.evaluate(record: rec, meta: r.meta, currentIdentities: ids)
        XCTAssertEqual(d2.mustRehash, [1, 2])
    }

    func testBumpedUnionsAndDoesNotLaunderChangedFiles() throws {
        let r = try rig()
        let rec = ResumeRecord(infoHash: r.meta.infoHashHex, pieceCount: 4, pieceLength: r.meta.pieceLength, verified: [0, 3], verifiedAt: Date(timeIntervalSinceNow: -10), files: r.concrete(), uploadedBytes: 7)
        r.setMtime(2, Date(timeIntervalSinceNow: -100))   // c changed after the record (piece 3 lives in c)
        let b = rec.bumped(afterVerifying: [1], identities: r.concrete(), meta: r.meta, now: Date())
        XCTAssertEqual(b.verifiedPieces, [0, 1], "piece 3 touched the changed file and was not re-verified"); XCTAssertTrue(b.checksumIsValid); XCTAssertEqual(b.uploadedBytes, 7)
    }

    // MARK: historical defect

    func testSameSizeDifferentContentIsNotTrustedAndFailsRehash() async throws {
        let r = try rig([40_000]); let rec = r.fullRecord()
        // Same size, different bytes, written later: the old "size matches" shortcut would have believed it.
        var bad = Data(repeating: 0xAB, count: 40_000); bad[0] = 1
        try FileManager.default.removeItem(at: r.url(0)); try bad.write(to: r.url(0))
        XCTAssertEqual(TorrentFileIdentity.capture(r.url(0))?.size, rec.files[0]?.size)
        let d = r.evaluate(rec)
        XCTAssertTrue(d.trusted.isEmpty)
        let result = await Rehasher.run(pieces: d.mustRehash.sorted(), read: diskReader(r), matches: hashMatcher(r))
        XCTAssertEqual(result.failed, [0, 1]); XCTAssertTrue(result.verified.isEmpty)
    }

    // MARK: Rehasher

    private func diskReader(_ r: DX06ResumeRig) -> @Sendable (Int) -> Data? {
        let urls = r.names.indices.map { r.url($0) }, meta = r.meta
        return { p in
            let segs = meta.segments(offset: Int64(p) * meta.pieceLength, length: meta.length(ofPiece: p))
            var out = Data()
            for s in segs {
                guard let h = try? FileHandle(forReadingFrom: urls[s.file]) else { return nil }
                defer { try? h.close() }
                guard (try? h.seek(toOffset: UInt64(s.fileOffset))) != nil, let part = try? h.read(upToCount: Int(s.count)), part.count == Int(s.count) else { return nil }
                out.append(part)
            }
            return out
        }
    }
    private func hashMatcher(_ r: DX06ResumeRig) -> @Sendable (Data, Int) -> Bool {
        let hashes = r.meta.pieceHashes
        return { data, p in Data(Insecure.SHA1.hash(data: data)) == hashes[p] }
    }

    func testRehasherAllGood() async throws {
        let r = try rig(); let ticks = DX06ResumeBox(0)
        let res = await Rehasher.run(pieces: [0, 1, 2, 3], concurrency: 2, read: diskReader(r), matches: hashMatcher(r), progress: { _, _ in ticks.with { $0 += 1 } })
        XCTAssertEqual(res.verified, Set(0..<4)); XCTAssertTrue(res.failed.isEmpty); XCTAssertTrue(res.unreadable.isEmpty); XCTAssertTrue(res.completed); XCTAssertEqual(ticks.with { $0 }, 4)
    }

    func testRehasherOneBadHashAndOneUnreadableAreSeparate() async throws {
        let r = try rig()
        var bytes = try Data(contentsOf: r.url(0)); bytes[5] ^= 0xff; try bytes.write(to: r.url(0))     // piece 0 fails
        try FileManager.default.removeItem(at: r.url(2))                                                  // pieces 2 and 3 cannot be read
        let res = await Rehasher.run(pieces: [0, 1, 2, 3], read: diskReader(r), matches: hashMatcher(r))
        XCTAssertEqual(res.failed, [0]); XCTAssertEqual(res.verified, [1]); XCTAssertEqual(res.unreadable, [2, 3], "unreadable is not a hash failure")
        XCTAssertTrue(FileManager.default.fileExists(atPath: r.url(0).path), "nothing is deleted")
    }

    func testRehasherCancellationReturnsPartialResults() async throws {
        let r = try rig(); let reader = diskReader(r), match = hashMatcher(r)
        let holder = DX06ResumeBox<Task<Rehasher.Result, Never>?>(nil)
        let task = Task { await Rehasher.run(pieces: Array(0..<4), read: { p in if p == 1 { holder.with { $0?.cancel() } }; return reader(p) }, matches: match) }
        holder.with { $0 = task }
        let res = await task.value
        XCTAssertFalse(res.completed); XCTAssertLessThan(res.verified.count + res.failed.count + res.unreadable.count, 4)
        XCTAssertTrue(res.verified.isSubset(of: Set(0..<4)))
    }

    func testCheckpointsAndCrashResume() async throws {
        let r = try rig(); let reader = diskReader(r), match = hashMatcher(r)
        let saved = DX06ResumeBox<[Set<Int>]>([])
        _ = await Rehasher.run(pieces: Array(0..<4), checkpointEvery: 2, read: reader, matches: match, checkpoint: { v in saved.with { $0.append(v) } })
        XCTAssertEqual(saved.with { $0 }, [[0, 1], [0, 1, 2, 3]])
        // Crash after the first checkpoint: only its record survived on disk; resume continues with the rest.
        let rec = ResumeRecord.empty(for: r.meta).bumped(afterVerifying: [0, 1], identities: r.concrete(), meta: r.meta, now: Date())
        try rec.write(to: r.recordURL)
        let loaded = try ResumeRecord.load(from: r.recordURL, expecting: r.meta)
        let d = r.evaluate(loaded)
        XCTAssertEqual(d.trusted, [0, 1]); XCTAssertEqual(d.mustRehash, [2, 3])
        let rest = await Rehasher.run(pieces: d.mustRehash.sorted(), read: reader, matches: match)
        XCTAssertEqual(rest.verified, [2, 3])
    }
}
