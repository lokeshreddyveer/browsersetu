import XCTest
import Compression
import CryptoKit
@testable import Browser_Setu

// Phase 25: archives and link files. Every archive here is original, made by the test (a ZIP writer from Phase 20, a TAR and a gzip writer below), including the hostile ones.

enum TarFixture {
    struct Entry { var name: String; var data: Data = Data(); var type: UInt8 = UInt8(ascii: "0"); var link = ""; var badChecksum = false }

    private static func field(_ s: String, _ n: Int) -> [UInt8] { var b = Array(s.utf8.prefix(n)); b += [UInt8](repeating: 0, count: n - b.count); return b }
    private static func octal(_ v: Int, _ n: Int) -> [UInt8] { Array((String(v, radix: 8).leftPad(n - 1) + "\0").utf8) }

    static func header(name: String, size: Int, type: UInt8, link: String = "", badChecksum: Bool = false) -> Data {
        var h = [UInt8](repeating: 0, count: 512)
        func put(_ bytes: [UInt8], at i: Int) { h.replaceSubrange(i..<i + bytes.count, with: bytes) }
        put(field(name, 100), at: 0); put(octal(0o644, 8), at: 100); put(octal(0, 8), at: 108); put(octal(0, 8), at: 116)
        put(octal(size, 12), at: 124); put(octal(1_700_000_000, 12), at: 136)
        put([UInt8](repeating: 0x20, count: 8), at: 148)
        h[156] = type; put(field(link, 100), at: 157); put(field("ustar", 6), at: 257); put(Array("00".utf8), at: 263)
        let sum = h.reduce(0) { $0 + Int($1) } + (badChecksum ? 7 : 0)
        put(Array((String(sum, radix: 8).leftPad(6) + "\0 ").utf8), at: 148)
        return Data(h)
    }

    static func build(_ entries: [Entry], pax: Bool = false) -> Data {
        var out = Data()
        for e in entries {
            var name = e.name
            if name.utf8.count > 100 {
                if pax {
                    let record = "path=\(name)\n"; var len = record.utf8.count + 3; while "\(len) \(record)".utf8.count != len { len += 1 }
                    let body = Data("\(len) \(record)".utf8)
                    out.append(header(name: "PaxHeader", size: body.count, type: UInt8(ascii: "x"))); out.append(body); out.append(Data(count: (512 - body.count % 512) % 512))
                } else {
                    let body = Data(name.utf8) + Data([0])
                    out.append(header(name: "././@LongLink", size: body.count, type: UInt8(ascii: "L"))); out.append(body); out.append(Data(count: (512 - body.count % 512) % 512))
                }
                name = String(name.prefix(90))
            }
            out.append(header(name: name, size: e.data.count, type: e.type, link: e.link, badChecksum: e.badChecksum))
            out.append(e.data); out.append(Data(count: (512 - e.data.count % 512) % 512))
        }
        out.append(Data(count: 1024))
        return out
    }

    static func gzip(_ data: Data) -> Data {
        var out = Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 3])
        var buffer = [UInt8](repeating: 0, count: max(1024, data.count + data.count / 10 + 64))
        let n = data.withUnsafeBytes { s in buffer.withUnsafeMutableBufferPointer { d in compression_encode_buffer(d.baseAddress!, d.count, s.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(bitPattern: 1)!, data.count, nil, COMPRESSION_ZLIB) } }
        out.append(contentsOf: buffer.prefix(n))
        var crc = ZipFormat.crc32(data).littleEndian, size = UInt32(truncatingIfNeeded: data.count).littleEndian
        out.append(Data(bytes: &crc, count: 4)); out.append(Data(bytes: &size, count: 4))
        return out
    }
}

private extension String { func leftPad(_ n: Int) -> String { String(repeating: "0", count: max(0, n - count)) + self } }

class ArchiveCase: XCTestCase {
    var root: URL!, downloads: URL!
    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("p25-\(UUID().uuidString)")
        downloads = root.appendingPathComponent("Downloads")
        try? FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }
    func write(_ data: Data, _ name: String) -> URL { let u = downloads.appendingPathComponent(name); try! data.write(to: u); return u }
    func hash(_ u: URL) -> String { SHA256.hash(data: (try? Data(contentsOf: u)) ?? Data()).map { String(format: "%02x", $0) }.joined() }
    func visible() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: downloads.path)) ?? []).sorted() }
    func bytes(_ n: Int, _ seed: UInt64 = 1) -> Data { ZipFixture.noise(n, seed: seed) }
    func extract(_ f: URL, _ sel: Set<Int>? = nil, limits: ArchiveLimits = ArchiveLimits()) throws -> ArchiveManager.Result { try ArchiveManager.extract(f, selection: sel, destination: downloads, roots: [downloads], limits: limits) }
}

// MARK: - What it is and what is inside

final class ArchiveListingTests: ArchiveCase {
    func testKindsComeFromTheContentsAndUnsupportedOnesSayWhy() throws {
        let zip = write(ZipFixture.build([ZipFixtureEntry(name: "a.txt", data: Data("a".utf8))]).data, "really-a-zip.bin")
        XCTAssertEqual(ArchiveManager.sniff(zip), .zip)
        XCTAssertEqual(ArchiveManager.sniff(write(TarFixture.build([.init(name: "a.txt", data: Data("a".utf8))]), "x.dat")), .tar)
        XCTAssertEqual(ArchiveManager.sniff(write(TarFixture.gzip(TarFixture.build([.init(name: "a.txt", data: Data("a".utf8))])), "x.tgz")), .tarGz)
        for (magic, word) in [([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C], "7z"), (Array("Rar!".utf8), "RAR"), ([0x42, 0x5A, 0x68], "bzip2"), ([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00], "xz")] {
            let f = write(Data(magic) + Data(count: 600), "u-\(word)")
            if case .unsupported(let why) = ArchiveManager.sniff(f) { XCTAssertTrue(why.contains(word), why) } else { XCTFail(word) }
            XCTAssertThrowsError(try ArchiveManager.list(f))
        }
        let single = write(TarFixture.gzip(Data("just one compressed file, not a tar".utf8)), "single.gz")
        if case .unsupported = ArchiveManager.sniff(single) {} else { XCTFail("a lone .gz is not an archive") }
        let text = write(Data("hello".utf8), "t.zip")
        if case .unsupported = ArchiveManager.sniff(text) {} else { XCTFail("the name does not make an archive") }
        let link = downloads.appendingPathComponent("link.zip"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: zip)
        if case .unsupported = ArchiveManager.sniff(link) {} else { XCTFail("a link is not opened") }
    }

    func testZipListingHasFactsAndFlagsWhatCannotBeTaken() throws {
        let data = ZipFixture.build([
            ZipFixtureEntry(name: "docs/", data: Data(), method: 0), ZipFixtureEntry(name: "docs/a.txt", data: ZipFixture.text(5000)), ZipFixtureEntry(name: "b.bin", data: bytes(3000), method: 0),
            ZipFixtureEntry(name: "secret.txt", data: Data("x".utf8), flags: 1), ZipFixtureEntry(name: "../evil.txt", data: Data("x".utf8)), ZipFixtureEntry(name: "/abs.txt", data: Data("x".utf8)),
            ZipFixtureEntry(name: "é.txt", data: Data("1".utf8)), ZipFixtureEntry(name: "e\u{301}.txt", data: Data("2".utf8)),
        ], comment: String(repeating: "c", count: 65_535), zip64End: true).data
        let listing = try ArchiveManager.list(write(data, "a.zip"))
        XCTAssertEqual(listing.kind, .zip)
        let byName = Dictionary(listing.items.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })          // (Swift treats the two spellings of é as one name, as the file system does)
        XCTAssertEqual(byName["docs/a.txt"]?.size, 5000); XCTAssertEqual(byName["docs/a.txt"]?.method, "deflate"); XCTAssertLessThan(byName["docs/a.txt"]?.compressedSize ?? 99999, 5000)
        XCTAssertEqual(byName["b.bin"]?.method, "stored"); XCTAssertTrue(byName["docs/"]?.isDirectory == true)
        XCTAssertTrue(byName["secret.txt"]?.encrypted == true); XCTAssertFalse(byName["secret.txt"]?.isSupported ?? true, "password-protected entries are shown and not taken")
        XCTAssertTrue(byName["../evil.txt"]?.unsafePath == true); XCTAssertTrue(byName["/abs.txt"]?.unsafePath == true); XCTAssertTrue(listing.hasUnsafeEntries)
        let twins = listing.items.filter { $0.name == "é.txt" }
        XCTAssertEqual(twins.count, 2); XCTAssertEqual(twins.filter(\.isSupported).count, 1, "the Unicode-equivalent twin is refused")
        XCTAssertTrue(listing.notes.contains("ZIP64 archive."))
    }

    func testTarListingKnowsLongNamesLinksAndDevices() throws {
        let long = "deep/" + String(repeating: "n", count: 140) + ".txt"
        for pax in [false, true] {
            let t = TarFixture.build([.init(name: "dir/", type: UInt8(ascii: "5")), .init(name: "dir/a.txt", data: ZipFixture.text(1200)), .init(name: long, data: Data("L".utf8)),
                                      .init(name: "ln", type: UInt8(ascii: "2"), link: "/etc/passwd"), .init(name: "hl", type: UInt8(ascii: "1"), link: "dir/a.txt"), .init(name: "dev", type: UInt8(ascii: "3")),
                                      .init(name: "../up.txt", data: Data("x".utf8))], pax: pax)
            let l = try ArchiveManager.list(write(t, "t\(pax).tar"))
            XCTAssertEqual(l.kind, .tar); XCTAssertEqual(l.items.map(\.name), ["dir/", "dir/a.txt", long, "ln", "hl", "dev", "../up.txt"], "pax=\(pax)")
            XCTAssertTrue(l.items[0].isDirectory); XCTAssertEqual(l.items[1].size, 1200)
            for i in [3, 4, 5] { XCTAssertFalse(l.items[i].isSupported, "\(l.items[i].name)") }
            XCTAssertTrue(l.items[6].unsafePath); XCTAssertTrue(l.items[2].isSupported)
        }
    }

    func testAGzippedTarIsReadThroughWithoutWritingAnything() throws {
        let t = TarFixture.gzip(TarFixture.build([.init(name: "a.txt", data: ZipFixture.text(100_000))]))
        let f = write(t, "a.tar.gz")
        let before = visible()
        let l = try ArchiveManager.list(f)
        XCTAssertEqual(l.kind, .tarGz); XCTAssertEqual(l.items.first?.size, 100_000); XCTAssertEqual(visible(), before)
    }

    func testDamagedArchivesFailPlainlyAndNeverCrash() throws {
        let zip = ZipFixture.build([ZipFixtureEntry(name: "a.txt", data: ZipFixture.text(4000))]).data
        for cut in [zip.count - 5, zip.count / 2, 30] { XCTAssertThrowsError(try ArchiveManager.list(write(Data(zip.prefix(cut)), "cut\(cut).zip"))) }
        let tar = TarFixture.build([.init(name: "a.txt", data: Data("x".utf8), badChecksum: true)])
        XCTAssertThrowsError(try ArchiveManager.list(write(tar, "bad.tar"))) { XCTAssertTrue(($0 as? ArchiveError)?.errorDescription?.contains("checksum") == true) }
        var gz = TarFixture.gzip(TarFixture.build([.init(name: "a.txt", data: ZipFixture.text(50_000))]))
        gz[gz.count - 12] ^= 0xFF
        XCTAssertThrowsError(try ArchiveManager.list(write(gz, "flip.tgz")))
        XCTAssertThrowsError(try ArchiveManager.list(write(Data(gz.prefix(gz.count / 2)), "half.tgz")))
        var weird = TarFixture.build([.init(name: "a.txt", data: Data("x".utf8))]); weird.replaceSubrange(124..<136, with: Data(repeating: 0xFF, count: 12))
        XCTAssertThrowsError(try ArchiveManager.list(write(weird, "weird.tar")), "a size field of nonsense")
    }

    func testBombsAndHugeListsAreStoppedByTheLimits() throws {
        var tight = ArchiveLimits(); tight.maxTotal = 10_000_000; tight.ratioFloor = 1_000_000; tight.maxRatio = 100
        let bomb = TarFixture.gzip(TarFixture.build([.init(name: "zeros.bin", data: Data(count: 30_000_000))]))
        XCTAssertLessThan(bomb.count, 200_000)
        XCTAssertThrowsError(try ArchiveManager.list(write(bomb, "bomb.tgz"), limits: tight)) { XCTAssertTrue(($0 as? ArchiveError)?.errorDescription?.contains("safety limit") == true || ($0 as? ArchiveError)?.errorDescription?.contains("expands") == true) }
        var few = ArchiveLimits(); few.maxEntries = 10
        let many = TarFixture.build((0..<50).map { .init(name: "f\($0)", data: Data("x".utf8)) })
        XCTAssertThrowsError(try ArchiveManager.list(write(many, "many.tar"), limits: few))
        let zipMany = ZipFixture.build((0..<50).map { ZipFixtureEntry(name: "f\($0)", data: Data("x".utf8)) }).data
        XCTAssertThrowsError(try ArchiveManager.list(write(zipMany, "many.zip"), limits: few))
        var small = ArchiveLimits(); small.maxTotal = 1000
        XCTAssertThrowsError(try ArchiveManager.list(write(ZipFixture.build([ZipFixtureEntry(name: "a", data: bytes(5000), method: 0)]).data, "big.zip"), limits: small))
    }
}

// MARK: - Taking files out

final class ArchiveExtractionTests: ArchiveCase {
    private func sample() -> (files: [String: Data], entries: [ZipFixtureEntry]) {
        let files = ["a.txt": ZipFixture.text(30_000), "docs/readme.md": ZipFixture.text(900), "docs/deep/b.bin": bytes(70_000, 3), "empty.txt": Data()]
        return (files, [ZipFixtureEntry(name: "docs/", data: Data(), method: 0)] + files.sorted { $0.key < $1.key }.map { ZipFixtureEntry(name: $0.key, data: $0.value, method: $0.key.hasSuffix(".bin") ? 0 : 8) })
    }
    private func compare(_ folder: URL, _ files: [String: Data], only: Set<String>? = nil) throws {
        for (name, data) in files where only == nil || only!.contains(name) { XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(name)), data, name) }
        if let only { for name in files.keys where !only.contains(name) { XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path), "not chosen: \(name)") } }
    }

    func testZipExtractsEverythingIntactIntoANewFolderAndLeavesTheArchiveAlone() throws {
        let (files, entries) = sample()
        let f = write(ZipFixture.build(entries).data, "pack.zip"), before = hash(f)
        let r = try extract(f)
        XCTAssertEqual(r.folder.lastPathComponent, "pack"); try compare(r.folder, files)
        XCTAssertEqual(hash(f), before); XCTAssertEqual(visible(), ["pack", "pack.zip"], "no staging folder is left")
        let again = try extract(f)
        XCTAssertEqual(again.folder.lastPathComponent, "pack 2", "never merged into the first")
        XCTAssertEqual(visible(), ["pack", "pack 2", "pack.zip"])
    }

    func testChosenEntriesOnlyAndZip64() throws {
        let (files, entries) = sample()
        let f = write(ZipFixture.build(entries, comment: "c", zip64End: true).data, "z64.zip")
        let listing = try ArchiveManager.list(f)
        let pick = Set(listing.items.filter { $0.name == "a.txt" || $0.name == "docs/deep/b.bin" }.map(\.id))
        let r = try extract(f, pick)
        try compare(r.folder, files, only: ["a.txt", "docs/deep/b.bin"]); XCTAssertEqual(r.extracted, 2)
    }

    func testTarAndTarGzExtractIntactAndLinksAreReportedNotCreated() throws {
        let files = ["x/one.txt": ZipFixture.text(20_000), "x/two.bin": bytes(100_000, 5)]
        let t = TarFixture.build([.init(name: "x/", type: UInt8(ascii: "5")), .init(name: "x/one.txt", data: files["x/one.txt"]!), .init(name: "x/two.bin", data: files["x/two.bin"]!),
                                  .init(name: "x/ln", type: UInt8(ascii: "2"), link: "/etc/passwd"), .init(name: String(repeating: "q", count: 130) + ".txt", data: Data("long".utf8))])
        for (name, data) in [("p.tar", t), ("p.tar.gz", TarFixture.gzip(t))] {
            let f = write(data, name)
            let r = try extract(f)
            try compare(r.folder, files)
            XCTAssertEqual(r.skipped.map(\.name), ["x/ln"]); XCTAssertEqual(r.skipped.first?.reason.contains("link"), true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: r.folder.appendingPathComponent("x/ln").path))
            XCTAssertEqual(try Data(contentsOf: r.folder.appendingPathComponent(String(repeating: "q", count: 130) + ".txt")), Data("long".utf8), "a long name from a GNU record")
            XCTAssertEqual(r.folder.lastPathComponent, name == "p.tar" ? "p" : "p 2", "the .tar.gz folder is named p, and p was taken by the first")
        }
    }

    func testAnArchiveWithUnsafeNamesIsNotOpenedWholeButItsSafeEntriesCanBeChosen() throws {
        let f = write(ZipFixture.build([ZipFixtureEntry(name: "good.txt", data: Data("ok".utf8)), ZipFixtureEntry(name: "../escape.txt", data: Data("no".utf8)), ZipFixtureEntry(name: "/abs.txt", data: Data("no".utf8))]).data, "evil.zip")
        XCTAssertThrowsError(try extract(f)) { XCTAssertTrue(($0 as? ArchiveError)?.errorDescription?.contains("outside") == true) }
        XCTAssertEqual(visible(), ["evil.zip"], "nothing written anywhere")
        let listing = try ArchiveManager.list(f)
        XCTAssertThrowsError(try extract(f, Set(listing.items.map(\.id))), "choosing an unsafe entry is refused too")
        let r = try extract(f, Set(listing.items.filter { $0.name == "good.txt" }.map(\.id)))
        XCTAssertEqual(try Data(contentsOf: r.folder.appendingPathComponent("good.txt")), Data("ok".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloads.deletingLastPathComponent().appendingPathComponent("escape.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloads.appendingPathComponent("escape.txt").path))
    }

    func testAnEntryWithAWrongChecksumOrSizeLeavesNothingBehind() throws {
        let f = write(ZipFixture.build([ZipFixtureEntry(name: "ok.txt", data: ZipFixture.text(500)), ZipFixtureEntry(name: "bad.txt", data: ZipFixture.text(4000), crcOverride: 123)]).data, "badcrc.zip")
        XCTAssertThrowsError(try extract(f))
        XCTAssertEqual(visible(), ["badcrc.zip"], "the folder appears only when everything was written and checked")
        let big = write(ZipFixture.build([ZipFixtureEntry(name: "lie.bin", data: ZipFixture.text(100_000), declaredUncompressed: 50)]).data, "lie.zip")
        XCTAssertThrowsError(try extract(big)); XCTAssertEqual(visible(), ["badcrc.zip", "lie.zip"])
        var gz = TarFixture.gzip(TarFixture.build([.init(name: "a.txt", data: ZipFixture.text(80_000))])); gz[gz.count - 6] ^= 1
        let g = write(gz, "crc.tgz")
        XCTAssertThrowsError(try extract(g)); XCTAssertEqual(visible(), ["badcrc.zip", "crc.tgz", "lie.zip"])
    }

    func testCancellationStopsAndRemovesWhatItMade() throws {
        let f = write(ZipFixture.build((0..<30).map { ZipFixtureEntry(name: "f\($0).bin", data: bytes(20_000, UInt64($0 + 1)), method: 0) }).data, "many.zip")
        var calls = 0
        XCTAssertThrowsError(try ArchiveManager.extract(f, destination: downloads, roots: [downloads], isCancelled: { calls += 1; return calls > 6 })) { XCTAssertEqual($0 as? ArchiveError, .cancelled) }
        XCTAssertEqual(visible(), ["many.zip"])
        let t = write(TarFixture.gzip(TarFixture.build((0..<30).map { .init(name: "f\($0)", data: self.bytes(20_000, UInt64($0 + 1))) })), "many.tgz")
        calls = 0
        XCTAssertThrowsError(try ArchiveManager.extract(t, destination: downloads, roots: [downloads], isCancelled: { calls += 1; return calls > 3 })) { XCTAssertEqual($0 as? ArchiveError, .cancelled) }
        XCTAssertEqual(visible(), ["many.tgz", "many.zip"])
        let ok = try extract(f); XCTAssertEqual(ok.extracted, 30, "and it can simply be tried again")
    }

    func testNoSpaceFailsBeforeWritingAndFoldersOutsideTheAllowedPlacesAreRefused() throws {
        let f = write(ZipFixture.build([ZipFixtureEntry(name: "a.bin", data: bytes(20_000), method: 0)]).data, "s.zip")
        XCTAssertThrowsError(try ArchiveManager.extract(f, destination: downloads, roots: [downloads], freeSpace: { _ in 10 })) { guard case ArchiveError.notEnoughSpace? = $0 as? ArchiveError else { return XCTFail("\($0)") } }
        XCTAssertEqual(visible(), ["s.zip"])
        let elsewhere = root.appendingPathComponent("Elsewhere"); try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        XCTAssertThrowsError(try ArchiveManager.extract(f, destination: elsewhere, roots: [downloads])) { XCTAssertEqual($0 as? ArchiveError, .notAuthorized) }
        let escape = downloads.appendingPathComponent("escape"); try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: elsewhere)
        XCTAssertThrowsError(try ArchiveManager.extract(f, destination: escape, roots: [downloads]), "a link that leads out is not followed")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }

    func testAFolderOrFileAlreadyThereIsNeverReplacedOrMergedInto() throws {
        let f = write(ZipFixture.build([ZipFixtureEntry(name: "a.txt", data: Data("new".utf8))]).data, "keep.zip")
        let existing = downloads.appendingPathComponent("keep"); try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: existing.appendingPathComponent("a.txt"))
        let r = try extract(f)
        XCTAssertEqual(r.folder.lastPathComponent, "keep 2")
        XCTAssertEqual(try String(contentsOf: existing.appendingPathComponent("a.txt"), encoding: .utf8), "mine")
        let file = downloads.appendingPathComponent("keep 3"); try Data("a file".utf8).write(to: file)
        XCTAssertEqual(try extract(f).folder.lastPathComponent, "keep 4")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "a file")
    }

    func testTheQuarantineMarkIsCarriedToWhatIsTakenOut() throws {
        let f = write(ZipFixture.build([ZipFixtureEntry(name: "a.txt", data: Data("x".utf8))]).data, "q.zip")
        DownloadQuarantine.apply(to: f, sourceOrigin: "https://example.com")
        let r = try extract(f)
        XCTAssertTrue(DownloadQuarantine.isQuarantined(r.folder.appendingPathComponent("a.txt")))
    }

    func testSeveralArchivesAtOnceEachReportOnTheirOwn() throws {
        let good = write(ZipFixture.build([ZipFixtureEntry(name: "a.txt", data: Data("x".utf8))]).data, "one.zip")
        let tar = write(TarFixture.build([.init(name: "b.txt", data: Data("y".utf8))]), "two.tar")
        let bad = write(Data("not an archive at all".utf8), "three.zip")
        let results = ArchiveBatch.extract([good, bad, tar], destination: downloads, roots: [downloads])
        XCTAssertEqual(results.count, 3)
        if case .success = results[0].outcome {} else { XCTFail() }
        if case .failure = results[1].outcome {} else { XCTFail("the bad one fails alone") }
        if case .success = results[2].outcome {} else { XCTFail() }
        XCTAssertEqual(visible(), ["one", "one.zip", "three.zip", "two", "two.tar"])
        let cancelled = ArchiveBatch.extract([good], destination: downloads, roots: [downloads], isCancelled: { true })
        if case .failure(.cancelled) = cancelled[0].outcome {} else { XCTFail() }
    }
}


// MARK: - Archives made by other tools

final class ArchiveInteropTests: ArchiveCase {
    private let expected: [String: Data] = ["a.txt": Data("hello world\n".utf8), "sub/b.txt": Data("inside the folder\n".utf8), "sub/rep.txt": Data(String(repeating: "x", count: 3000).utf8)]

    func testArchivesMadeByInfoZipAndBsdtarListAndExtractExactly() throws {
        for (name, data, kind) in [("info.zip", InteropFixtures.infoZip, ArchiveKind.zip), ("bsd.zip", InteropFixtures.bsdZip, .zip), ("bsd.tar.gz", InteropFixtures.bsdTarGz, .tarGz), ("pax.tar.gz", InteropFixtures.paxTarGz, .tarGz)] {
            let f = write(data, name)
            let listing = try ArchiveManager.list(f)
            XCTAssertEqual(listing.kind, kind, name)
            // (bsdtar on macOS also stores each file's extended attributes as "._name" companion entries; they are ordinary files here.)
            let files = listing.items.filter { !$0.isDirectory && !($0.name as NSString).lastPathComponent.hasPrefix("._") }
            XCTAssertEqual(Set(files.map(\.name)), Set(expected.keys), "\(name): \(listing.items.map(\.name))")
            XCTAssertTrue(listing.items.allSatisfy(\.isSupported), "\(name): \(listing.items.filter { !$0.isSupported }.map(\.name))")
            XCTAssertEqual(files.first { $0.name == "sub/rep.txt" }?.size, 3000)
            let r = try extract(f)
            for (path, content) in expected { XCTAssertEqual(try Data(contentsOf: r.folder.appendingPathComponent(path)), content, "\(name) \(path)") }
            XCTAssertTrue(r.skipped.isEmpty, "\(name)")
        }
    }
}

// MARK: - Link files

@MainActor
final class LinkContainerTests: ArchiveCase {
    func testPlainListsAndM3UListsGiveTheirLinks() throws {
        let text = "# my list\nhttps://example.com/a.zip\nsome words https://example.com/b.iso more\nhttps://example.com/a.zip\nmagnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567\n"
        let r = try LinkContainers.parse(write(Data(text.utf8), "list.txt"))
        if case .text = r.kind {} else { XCTFail() }; XCTAssertTrue(r.links.contains("https://example.com/b.iso")); XCTAssertTrue(r.links.contains { $0.hasPrefix("magnet:") })
        let m3u = "#EXTM3U\n#EXTINF:1,x\nhttps://example.com/one.mp3\nhttps://example.com/two.mp3\n"
        let m = try LinkContainers.parse(write(Data(m3u.utf8), "songs.m3u"))
        if case .m3uList = m.kind {} else { XCTFail() }; XCTAssertEqual(m.links.count, 2)
        let hls = try LinkContainers.parse(write(Data("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nlow.m3u8\n".utf8), "stream.m3u8"))
        if case .unsupported(let why) = hls.kind { XCTAssertTrue(why.contains("stream")) } else { XCTFail("a stream playlist is not a list of links") }
    }

    func testMetalinkGivesItsFilesAndNotesTheMirrors() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?><metalink xmlns="urn:ietf:params:xml:ns:metalink"><file name="a.iso"><size>10</size><hash type="sha-256">\(String(repeating: "a", count: 64))</hash>
        <url priority="1">https://one.example.com/a.iso</url><url priority="2">https://two.example.com/a.iso</url></file></metalink>
        """
        let r = try LinkContainers.parse(write(Data(xml.utf8), "x.meta4"))
        if case .metalink = r.kind {} else { XCTFail() }; XCTAssertEqual(r.links, ["https://one.example.com/a.iso"]); XCTAssertEqual(r.notes.count, 1)
        let bad = try LinkContainers.parse(Data("<?xml version=\"1.0\"?><metalink xmlns=\"urn:ietf:params:xml:ns:metalink\"><!DOCTYPE x></metalink>".utf8))
        if case .unsupported = bad.kind {} else { XCTFail("a document with a DOCTYPE is refused") }
    }

    func testDLCRSDFAndCCFAreSaidToBeUnsupportedWhateverIsInside() throws {
        for ext in ["dlc", "rsdf", "ccf"] {
            let r = try LinkContainers.parse(write(Data("https://example.com/readable-looking.zip".utf8), "pack.\(ext)"))
            if case .unsupported(let why) = r.kind { XCTAssertFalse(why.isEmpty) } else { XCTFail(ext) }
            XCTAssertTrue(r.links.isEmpty, "a name that says DLC is not read as a list, and nothing is guessed")
        }
    }

    func testBinaryOversizeAndHugeListsAreBounded() throws {
        XCTAssertThrowsError(try LinkContainers.parse(write(Data([0, 1, 2, 3, 0xFF]), "b.txt"))) { XCTAssertEqual($0 as? LinkContainerError, .notText) }
        XCTAssertThrowsError(try LinkContainers.parse(write(Data(repeating: 65, count: LinkContainers.maxBytes + 10), "big.txt"))) { XCTAssertEqual($0 as? LinkContainerError, .tooLarge) }
        let many = (0..<6000).map { "https://example.com/f\($0).zip" }.joined(separator: "\n")
        let r = try LinkContainers.parse(Data(many.utf8))
        XCTAssertLessThanOrEqual(r.links.count, LinkContainers.maxLinks); XCTAssertTrue(r.truncated)
        let link = downloads.appendingPathComponent("l.txt"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: write(Data("https://a.example.com/x".utf8), "real.txt"))
        XCTAssertThrowsError(try LinkContainers.parse(link))
    }

    func testImportedLinksAreOnlyCollectedForReviewAndStartNothing() throws {
        let store = LinkGrabberStore(profile: "default", isPrivate: false)
        let c = DownloadCoordinator()
        let text = "https://example.com/a.zip\nhttps://example.com/a.zip\nhttp://127.0.0.1/secret\nmagnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567\njavascript:alert(1)\n"
        let (result, report) = try LinkContainers.importFile(write(Data(text.utf8), "in.txt"), into: store)
        if case .text = result.kind {} else { XCTFail("\(result.kind)") }
        XCTAssertGreaterThan(report.added, 0); XCTAssertTrue(store.items.allSatisfy { $0.provenance == .page }, "links from a file are never the person's own typed ones")
        XCTAssertEqual(store.items.filter { $0.display.contains("a.zip") }.count, 1, "duplicates are suppressed")
        XCTAssertFalse(store.items.contains { $0.original.hasPrefix("javascript:") && $0.kind.isSupported })
        XCTAssertTrue(c.ledger.records.isEmpty, "nothing was started")
        XCTAssertTrue(store.items.allSatisfy { $0.group?.hasPrefix("Imported: in.txt") == true })
    }
}

// MARK: - Boundaries by construction

final class ArchiveBoundaryTests: XCTestCase {
    func testTheArchiveCodeNeverShellsOutOrCreatesLinks() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Shared/Downloads/Archives")
        var text = ""
        for case let f as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)! where f.pathExtension == "swift" { text += try String(contentsOf: f, encoding: .utf8) }
        for forbidden in ["Process(", "NSTask", "createSymbolicLink", "createLink", "system(", "popen("] { XCTAssertFalse(text.contains(forbidden), forbidden) }
        XCTAssertFalse(text.contains("Password") || text.contains("password:"), "no password is asked for or tried: there is no decoder for protected archives")
    }
}

// Regression tests for the independent review of Phase 25.
final class ArchiveReviewFixTests: ArchiveCase {
    private func pax(_ body: String) -> Data {
        let b = Data(body.utf8)
        return TarFixture.header(name: "PaxHeader", size: b.count, type: UInt8(ascii: "x")) + b + Data(count: (512 - b.count % 512) % 512)
    }

    func testMalformedPaxRecordsNeverCrash() throws {
        for bad in ["1 \n", "2 \n", "0 x\n", "99999999999999999999 path=a\n", "5 path\n", "7 path=\n"] {
            let t = pax(bad) + TarFixture.header(name: "a.txt", size: 0, type: UInt8(ascii: "0")) + Data(count: 1024)
            let f = write(t, "pax.tar")
            _ = try? ArchiveManager.list(f)
        }
    }

    func testDotSlashNamesAreSafeAndFilesAndFoldersCannotCollide() throws {
        XCTAssertEqual(ArchiveManager.normalizedTarName("./a/b.txt"), "a/b.txt")
        let l = try ArchiveManager.list(write(TarFixture.build([.init(name: "./a.txt", data: Data("x".utf8))]), "dot.tar"))
        XCTAssertFalse(l.items[0].unsafePath)
        let both = write(TarFixture.build([.init(name: "x/", type: UInt8(ascii: "5")), .init(name: "x", data: Data("f".utf8))]), "clash.tar")
        let items = try ArchiveManager.list(both).items
        XCTAssertTrue(items[0].isSupported); XCTAssertFalse(items[1].isSupported, "the file that shares a folder's name is not taken")
        let out = try extract(both)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.folder.appendingPathComponent("x").path, isDirectory: &isDir)); XCTAssertTrue(isDir.boolValue)
    }

    func testATruncatedTarIsDamagedAndLeavesNothing() throws {
        let full = TarFixture.build([.init(name: "a.txt", data: ZipFixture.text(5000)), .init(name: "b.txt", data: ZipFixture.text(5000))])
        for cut in [full.count - 1024 - 700, 700, 512 + 100] {
            let f = write(full.prefix(cut), "cut\(cut).tar")
            XCTAssertThrowsError(try extract(f), "cut at \(cut)")
        }
        XCTAssertEqual(visible().filter { !$0.hasSuffix(".tar") }, [])
    }

    func testAPartFileNamedLikeTheOutputFolderDoesNotClash() throws {
        let f = write(TarFixture.build([.init(name: "a.txt", data: Data("x".utf8))]), "pkg.tar")
        _ = write(Data("keep".utf8), "pkg.part")
        _ = try extract(f)
        XCTAssertEqual(try Data(contentsOf: downloads.appendingPathComponent("pkg.part")), Data("keep".utf8))
    }

    func testCancelledMidEntryLeavesNothing() throws {
        let f = write(TarFixture.build([.init(name: "big.bin", data: bytes(3_000_000))]), "big.tar")
        var calls = 0
        XCTAssertThrowsError(try ArchiveManager.extract(f, destination: downloads, roots: [downloads], isCancelled: { calls += 1; return calls > 2 }))
        XCTAssertEqual(visible(), ["big.tar"])
    }

    func testUTF16LinkListsAreReadAndBinaryIsStillRefused() throws {
        var u = Data([0xFF, 0xFE]); u.append("https://example.com/a.zip\n".data(using: .utf16LittleEndian)!)
        let r = try LinkContainers.parse(write(u, "u16.txt"))
        XCTAssertTrue(r.links.contains("https://example.com/a.zip"))
        XCTAssertThrowsError(try LinkContainers.parse(write(Data([0, 1, 2, 0, 0, 5]), "b.txt")))
    }
}

final class TarFormatTests: ArchiveCase {
    func testGnuTarTimesInTheUstarPrefixPositionAreNotReadAsAFolderName() throws {
        var h = [UInt8](TarFixture.header(name: "plain.txt", size: 0, type: UInt8(ascii: "0")))
        h.replaceSubrange(257..<265, with: Array("ustar  ".utf8) + [0])          // GNU magic and version
        h.replaceSubrange(345..<357, with: Array("13700000000\0".utf8))          // an access time where POSIX keeps the prefix
        var sum = 0; for (i, b) in h.enumerated() { sum += (148..<156).contains(i) ? 0x20 : Int(b) }
        h.replaceSubrange(148..<156, with: Array((String(repeating: "0", count: max(0, 6 - String(sum, radix: 8).count)) + String(sum, radix: 8) + "\0 ").utf8))
        let l = try ArchiveManager.list(write(Data(h) + Data(count: 1024), "gnu.tar"))
        XCTAssertEqual(l.items.map(\.name), ["plain.txt"])
    }
}

final class ArchiveIdentityTests: ArchiveCase {
    func testAnArchiveReplacedWhileItIsExtractedIsRefusedAndLeavesNothing() throws {
        let big = write(TarFixture.build([.init(name: "a.bin", data: bytes(4_000_000))]), "swap.tar")
        var calls = 0
        XCTAssertThrowsError(try ArchiveManager.extract(big, destination: downloads, roots: [downloads], progress: { _, _ in
            calls += 1
            if calls == 2 { try? Data("x".utf8).write(to: big) }          // another process replaces the archive part-way
        })) { XCTAssertTrue("\($0)".lowercased().contains("changed") || "\($0)".lowercased().contains("short") || "\($0)".lowercased().contains("damaged"), "\($0)") }
        XCTAssertEqual(visible(), ["swap.tar"], "nothing of the extraction is left")
    }

    func testAZipWhoseTableOfContentsNowSaysSomethingElseIsNotTrusted() throws {
        let f = write(ZipFixture.build([ZipFixtureEntry(name: "a.txt", data: ZipFixture.text(3000))]).data, "t.zip")
        let before = FileIdentity(f)
        XCTAssertNotNil(before)
        try Data("different".utf8).write(to: f)
        XCTAssertNotEqual(FileIdentity(f), before)
        XCTAssertThrowsError(try extract(f))
        XCTAssertEqual(visible(), ["t.zip"])
    }

    func testADestinationThatIsALinkIsResolvedOnceAndNothingIsWrittenThroughAnUnauthorizedOne() throws {
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)
        let f = write(TarFixture.build([.init(name: "a.txt", data: Data("x".utf8))]), "l.tar")
        XCTAssertThrowsError(try ArchiveManager.extract(f, destination: link, roots: [downloads]), "a link out of the allowed folders is not followed")
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: elsewhere.path)) ?? ["x"], [], "nothing was written through the link")
    }
}
