import XCTest
@testable import Browser_Setu

/// The shared filename resolver: which candidate wins for an ordinary file and for extracted media, how the ending is chosen, and that nothing unsafe, generic, doubled or colliding comes out.
@MainActor
final class FilenameResolverTests: XCTestCase {
    func resolve(_ i: FilenameResolver.Inputs, _ c: FilenameResolver.Context = .ordinaryFile, ext: String? = nil) -> FilenameResolver.Resolved { FilenameResolver.resolve(i, context: c, outputExtension: ext) }
    func url(_ s: String) -> URL { URL(string: s)! }

    // MARK: Precedence

    func testAnOrdinaryFileKeepsItsPublishedNameTitlesOnlyStandInForNothing() {
        let all = FilenameResolver.Inputs(user: nil, mediaTitle: "A Talk", contentDisposition: "attachment; filename=\"report-final.pdf\"", downloadAttribute: "from-attr.pdf",
                                          embeddedTitle: "Embedded", pageTitle: "Page Title", url: url("https://cdn.example/files/original.pdf?token=1"))
        XCTAssertEqual(resolve(all).name, "report-final.pdf"); XCTAssertEqual(resolve(all).source, .contentDisposition)
        var noCD = all; noCD.contentDisposition = nil
        XCTAssertEqual(resolve(noCD).name, "from-attr.pdf"); XCTAssertEqual(resolve(noCD).source, .downloadAttribute)
        noCD.downloadAttribute = nil
        XCTAssertEqual(resolve(noCD).name, "original.pdf", "the address's last part (query ignored) before any title"); XCTAssertEqual(resolve(noCD).source, .url)
        var typed = all; typed.user = "My copy.pdf"
        XCTAssertEqual(resolve(typed).name, "My copy.pdf"); XCTAssertEqual(resolve(typed).source, .user)
    }

    func testExtractedMediaIsCalledByItsTitleNotByAGenericAddress() {
        let i = FilenameResolver.Inputs(mediaTitle: "Intro to Swift Concurrency", pageTitle: "Watch – Site", url: url("https://cdn.example/hls/master.m3u8"))
        let r = resolve(i, .extractedMedia, ext: "mp4")
        XCTAssertEqual(r.name, "Intro to Swift Concurrency.mp4"); XCTAssertEqual(r.source, .mediaTitle)
        // No extractor title: the page title beats the generic playlist name.
        let page = resolve(FilenameResolver.Inputs(pageTitle: "Intro Lecture", url: url("https://cdn.example/hls/master.m3u8")), .extractedMedia, ext: "mp4")
        XCTAssertEqual(page.name, "Intro Lecture.mp4"); XCTAssertEqual(page.source, .pageTitle)
        // Nothing but a generic address and no title: the generic name is used rather than nothing, with the real ending.
        let bare = resolve(FilenameResolver.Inputs(url: url("https://cdn.example/hls/master.m3u8")), .extractedMedia, ext: "mp4")
        XCTAssertEqual(bare.name, "master.mp4")
        // A name the person typed always wins, even over a title.
        XCTAssertEqual(resolve(FilenameResolver.Inputs(user: "Mine", mediaTitle: "Their Title"), .extractedMedia, ext: "mp4").name, "Mine.mp4")
    }

    func testTitleConflictsEmbeddedMetadataAndGenericNames() {
        let i = FilenameResolver.Inputs(embeddedTitle: "Track 7 – Live", pageTitle: "Home", url: url("https://x.example/download"))
        XCTAssertEqual(resolve(i, .extractedMedia, ext: "m4a").name, "Track 7 – Live.m4a", "embedded metadata before the page title; both before a generic address")
        for generic in ["download", "index.html", "videoplayback", "player.php", "playlist.m3u8", "file", "master_2.m3u8", "video (3).mp4"] {
            XCTAssertTrue(FilenameResolver.isGeneric(generic), generic)
        }
        XCTAssertFalse(FilenameResolver.isGeneric("Quarterly Report.pdf")); XCTAssertFalse(FilenameResolver.isGeneric("invoice-2026-11.pdf"))
        for specific in ["1984", "300.mp4", "000123.pdf", "Video 2024", "Index of Sales", "Clip 2024-05.mp4"] { XCTAssertFalse(FilenameResolver.isGeneric(specific), "\(specific) names something") }
        // A server's number-only name beats a script address, and a movie called "1984" keeps its title over the page's.
        XCTAssertEqual(resolve(FilenameResolver.Inputs(contentDisposition: "attachment; filename=\"000123.pdf\"", url: url("https://x.example/getfile.php?id=9"))).name, "000123.pdf")
        XCTAssertEqual(resolve(FilenameResolver.Inputs(mediaTitle: "1984", pageTitle: "Watch Online"), .extractedMedia, ext: "mp4").name, "1984.mp4")
        // A cut name has no stray dots or spaces before its ending.
        let cut = resolve(FilenameResolver.Inputs(user: String(repeating: "a", count: 195) + " . b"), .extractedMedia, ext: "mp4").name      // the cut falls right after "aaa… "
        XCTAssertFalse(cut.contains(" ."), cut); XCTAssertFalse(cut.contains(" mp4"), cut); XCTAssertFalse(cut.contains(".."), cut); XCTAssertTrue(cut.hasSuffix(".mp4")); XCTAssertLessThanOrEqual(cut.utf8.count, DownloadFilename.maxBytes)
    }

    func testMissingMetadataGivesAMeaningfulFallback() {
        XCTAssertEqual(resolve(FilenameResolver.Inputs()).name, "download"); XCTAssertEqual(resolve(FilenameResolver.Inputs()).source, .fallback)
        XCTAssertEqual(resolve(FilenameResolver.Inputs(mimeType: "application/pdf")).name, "download.pdf", "an ending from the type when the name has none")
        XCTAssertEqual(resolve(FilenameResolver.Inputs(url: url("https://x.example/"), mimeType: "video/mp4"), .extractedMedia, ext: "mp4").name, "download.mp4")
    }

    // MARK: Content-Disposition, redirects, query strings

    func testContentDispositionExtendedNameWinsAndASmuggledPathIsRefused() {
        let utf8 = FilenameResolver.Inputs(contentDisposition: "attachment; filename=\"fallback.txt\"; filename*=UTF-8''%E2%82%AC%20rates%20%C3%BCber.txt")
        XCTAssertEqual(resolve(utf8).name, "€ rates über.txt")
        let latin = FilenameResolver.Inputs(contentDisposition: "attachment; filename*=ISO-8859-1''na%EFve.txt")
        XCTAssertEqual(resolve(latin).name, "naïve.txt")
        let evil = FilenameResolver.Inputs(contentDisposition: "attachment; filename=\"../../../etc/passwd\"")
        XCTAssertEqual(resolve(evil).name, "passwd", "only the last component survives")
        let hidden = FilenameResolver.Inputs(contentDisposition: "attachment; filename=\".bashrc\"")
        XCTAssertEqual(resolve(hidden).name, "bashrc", "no hidden file")
    }

    func testRedirectedAndQueryStringAddressesUseTheFinalPathNotTheQuery() {
        // The caller passes the address the file was finally served from (after redirects); the query and fragment never reach the name.
        XCTAssertEqual(resolve(FilenameResolver.Inputs(url: url("https://cdn2.example/dl/Setup%20Guide.pdf?sig=abc&exp=9#top"))).name, "Setup Guide.pdf")
        XCTAssertEqual(resolve(FilenameResolver.Inputs(url: url("https://cdn.example/get?id=12345&name=ignored.zip")), .ordinaryFile).name, "get", "the query's name= is never used; a bare script address gives its (generic) last segment")
        XCTAssertEqual(resolve(FilenameResolver.Inputs(url: url("https://x.example/a/b/"))).name, "b", "a folder-style address uses its last segment")
    }

    // MARK: The ending

    func testTheEndingComesFromTheRealOutputNeverFromTheAddressAndNeverDoubles() {
        XCTAssertEqual(FilenameResolver.applying(extension: "mp4", to: "clip.m3u8"), "clip.mp4")
        XCTAssertEqual(FilenameResolver.applying(extension: "mp4", to: "clip.mp4"), "clip.mp4")
        XCTAssertEqual(FilenameResolver.applying(extension: "mp4", to: "clip.mp4.mp4"), "clip.mp4")
        XCTAssertEqual(FilenameResolver.applying(extension: "mp3", to: "talk.webm"), "talk.mp3")
        XCTAssertEqual(FilenameResolver.applying(extension: "mp4", to: "Learn.PHP"), "Learn.PHP.mp4", "a title's last word is not an ending")
        XCTAssertEqual(resolve(FilenameResolver.Inputs(url: url("https://x.example/watch.php?id=1")), .extractedMedia, ext: "mp4").name, "watch.mp4", "a page ending in an ADDRESS is dropped")
        XCTAssertEqual(FilenameResolver.applying(extension: "mp4", to: "Lecture 1.5"), "Lecture 1.5.mp4", "a dot inside a title is not an ending")
        XCTAssertEqual(FilenameResolver.applying(extension: "mp4", to: "Episode 1. Pilot"), "Episode 1. Pilot.mp4")
        XCTAssertEqual(FilenameResolver.applying(extension: "MP4", to: "Clip"), "Clip.mp4", "lower case")
        XCTAssertEqual(FilenameResolver.applying(extension: "m4a", to: ".mp4"), ".mp4.m4a", "a name that is only an ending is kept, not emptied")
        XCTAssertEqual(FilenameResolver.applying(extension: "../x", to: "Clip"), "Clip", "an ending that is not a plain word is refused")
        XCTAssertEqual(FilenameResolver.stem(of: "show.m3u8"), "show"); XCTAssertEqual(FilenameResolver.stem(of: "Lecture 1.5"), "Lecture 1.5")
        // Through the resolver: a processed output named after a source with another ending.
        XCTAssertEqual(resolve(FilenameResolver.Inputs(user: "Concert.webm"), .extractedMedia, ext: "mp3").name, "Concert.mp3")
    }

    // MARK: Unicode, length, hostile names

    func testUnicodeIsKeptAndLongHostileAndReservedNamesAreMadeSafe() {
        XCTAssertEqual(resolve(FilenameResolver.Inputs(user: "日本語のタイトル – 第1話 «α»?.mp4")).name, "日本語のタイトル – 第1話 «α»?.mp4")
        let decomposed = "Cafe\u{301}.txt"
        XCTAssertEqual(resolve(FilenameResolver.Inputs(user: decomposed)).name, "Café.txt".precomposedStringWithCanonicalMapping, "one canonical form")
        XCTAssertEqual(resolve(FilenameResolver.Inputs(user: "a/b\\c:d.txt")).name, "c-d.txt")
        XCTAssertEqual(resolve(FilenameResolver.Inputs(user: "CON.txt")).name, "_CON.txt")
        XCTAssertEqual(resolve(FilenameResolver.Inputs(user: "report\u{202E}fdp.exe")).name, "reportfdp.exe", "a direction override cannot disguise the ending")
        let long = String(repeating: "界", count: 300) + ".mp4"
        let r = resolve(FilenameResolver.Inputs(user: long), .extractedMedia, ext: "mp4").name
        XCTAssertLessThanOrEqual(r.utf8.count, DownloadFilename.maxBytes); XCTAssertTrue(r.hasSuffix(".mp4"), "the ending survives the cut")
        XCTAssertNil(DownloadFilename.sanitize("///")); XCTAssertEqual(resolve(FilenameResolver.Inputs(user: "///")).source, .fallback)
        XCTAssertTrue(resolve(FilenameResolver.Inputs(contentDisposition: "attachment; filename=\"invoice.pdf.app\"")).suspicious, "a document name that really runs is flagged")
    }

    // MARK: Concurrent saves of one name

    func testConcurrentSavesOfOneNameEachGetTheirOwnFileAndNothingIsOverwritten() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bs-pub-\(UUID().uuidString)", isDirectory: true)
        let work = dir.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
        // A file the person already has under that name must survive untouched.
        let preferred = dir.appendingPathComponent("Episode.mp3")
        try Data("the person's own file".utf8).write(to: preferred)
        let count = 60
        for i in 0..<count { try Data("save \(i)".utf8).write(to: work.appendingPathComponent("p\(i)")) }
        let lock = NSLock(); var results: [URL?] = Array(repeating: nil, count: count); var errors = 0
        DispatchQueue.concurrentPerform(iterations: count) { i in
            do { let r = try FileNaming.publish(work.appendingPathComponent("p\(i)"), as: preferred); lock.lock(); results[i] = r; lock.unlock() }
            catch { lock.lock(); errors += 1; lock.unlock() }
        }
        XCTAssertEqual(errors, 0)
        let names = results.compactMap { $0?.lastPathComponent }
        XCTAssertEqual(Set(names).count, count, "every save got a different name")
        XCTAssertFalse(names.contains("Episode.mp3"), "the existing file's name was never taken")
        XCTAssertEqual(try String(contentsOf: preferred, encoding: .utf8), "the person's own file", "and it was not touched")
        // Each result holds exactly its own bytes: nothing was overwritten by another save.
        for (i, r) in results.enumerated() { XCTAssertEqual(try String(contentsOf: try XCTUnwrap(r), encoding: .utf8), "save \(i)") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [], "the working files were all moved, none left")
        XCTAssertTrue(names.contains("Episode (2).mp3")); XCTAssertTrue(names.contains("Episode (61).mp3"), "numbered in order from (2)")
        // A name with no ending, and a folder that does not exist yet.
        try Data("x".utf8).write(to: work.appendingPathComponent("q"))
        XCTAssertEqual(try FileNaming.publish(work.appendingPathComponent("q"), as: dir.appendingPathComponent("new/Notes")).lastPathComponent, "Notes")
    }

    // MARK: Collisions

    func testDuplicateDownloadsGetFreeNamesAndNothingIsOverwritten() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bs-names-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
        var made: [String] = []
        for _ in 0..<4 {
            let n = FilenameResolver.freeName("Title.mp4", in: dir, taken: [])
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(n).path)); made.append(n)
            try Data("x".utf8).write(to: dir.appendingPathComponent(n))
        }
        XCTAssertEqual(made, ["Title.mp4", "Title (1).mp4", "Title (2).mp4", "Title (3).mp4"])
        XCTAssertEqual(FilenameResolver.freeName("Title.mp4", in: dir, taken: ["Title (4).mp4"]), "Title (5).mp4", "a name another download has claimed but not yet written is avoided too")
        XCTAssertEqual(FilenameResolver.freeName("Other", in: dir), "Other", "no ending: still works")
        // The names the media paths use are the same kind.
        XCTAssertEqual(VideoSaveOperation.unique(dir.appendingPathComponent("Title.mp4")).lastPathComponent, "Title (4).mp4")
    }

    func testPublishOnAVolumeWithoutExclusiveRenameStillNeverReplacesAFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bs-pub-\(UUID().uuidString.prefix(8))"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let none: (String, String) -> Int32 = { _, _ in ENOTSUP }          // what FAT/exFAT and some network shares answer
        var results: [String] = []
        for n in 1...3 {
            let part = dir.appendingPathComponent("part\(n)"); try Data("v\(n)".utf8).write(to: part)
            results.append(try FileNaming.publish(part, as: dir.appendingPathComponent("a.mp3"), claim: none).lastPathComponent)
        }
        XCTAssertEqual(results, ["a.mp3", "a (2).mp3", "a (3).mp3"], "the first claim wins, the others are numbered")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("a.mp3")), "v1", "the first file was not replaced")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("a (3).mp3")), "v3")
    }
}
