import XCTest
import Compression
import CryptoKit
@testable import Browser_Setu

// Phase 7: what a download is called, where it goes, how it is protected, and what can be done with the file afterwards.

private func tempFolder(_ tag: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("p7-\(tag)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: Filenames (the existing parser, held to the Phase 7 list)

final class FilenameResolutionTests: XCTestCase {
    func testExtendedNameBeatsPlainAndDecodesUTF8() {
        let d = DownloadFilename.derive(contentDisposition: "attachment; filename=\"fallback.txt\"; filename*=UTF-8''r%C3%A9sum%C3%A9%20%E2%82%AC.pdf", url: URL(string: "https://x.test/a/b.bin"))
        XCTAssertEqual(d.name, "résumé €.pdf"); XCTAssertEqual(d.source, .contentDisposition)
    }

    func testInvalidEncodingIsIgnoredAndThePlainNameIsUsed() {
        let d = DownloadFilename.derive(contentDisposition: "attachment; filename=\"plain.txt\"; filename*=UTF-8''bad%ZZname.txt", url: nil)
        XCTAssertEqual(d.name, "plain.txt")
        let unknownCharset = DownloadFilename.derive(contentDisposition: "attachment; filename*=KOI8-R''abc.txt; filename=\"ok.txt\"", url: nil)
        XCTAssertEqual(unknownCharset.name, "ok.txt")
    }

    func testUnicodeIsNormalisedSoTheSameNameIsTheSameName() {
        let decomposed = "re\u{0301}sume\u{0301}.pdf"
        XCTAssertEqual(DownloadFilename.sanitize(decomposed), "résumé.pdf")
    }

    func testUrlIsTheFallbackThenAGeneratedName() {
        XCTAssertEqual(DownloadFilename.derive(contentDisposition: nil, url: URL(string: "https://x.test/files/My%20Report.pdf?token=1")).name, "My Report.pdf")
        XCTAssertEqual(DownloadFilename.derive(contentDisposition: "attachment; filename=\"\"", url: URL(string: "https://x.test/")).name, "download")
        XCTAssertEqual(DownloadFilename.derive(contentDisposition: "garbage", url: nil).source, .fallback)
    }

    func testAHeaderCannotChooseAFolder() {
        for evil in ["../../etc/passwd", "..\\..\\evil.exe", "/Library/x.sh", "a/b/c.txt", "~/x", "con.txt", ".hidden", "a\u{0}b.txt", "x\u{202E}txt.exe"] {
            let name = DownloadFilename.sanitize(evil)
            XCTAssertNotNil(name, evil)
            XCTAssertFalse(name!.contains("/") || name!.contains("\\") || name!.hasPrefix(".") || name!.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x202E }, "\(evil) became \(name!)")
        }
        XCTAssertEqual(DownloadFilename.sanitize("../../etc/passwd"), "passwd")
        XCTAssertEqual(DownloadFilename.sanitize("a:b.txt"), "a-b.txt", "a colon would show as a slash in Finder")
    }

    func testDoubleExtensionsAndLongNames() {
        XCTAssertTrue(DownloadFilename.isSuspicious("invoice.pdf.app"))
        XCTAssertFalse(DownloadFilename.isSuspicious("archive.tar.gz"))
        let long = String(repeating: "é", count: 300) + ".pdf"
        let cut = DownloadFilename.sanitize(long)!
        XCTAssertLessThanOrEqual(cut.utf8.count, DownloadFilename.maxBytes)
        XCTAssertTrue(cut.hasSuffix(".pdf"), "the ending survives truncation")
    }
}

// MARK: Naming templates

@MainActor
final class NamingTemplateTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_793_000_000)           // a fixed moment

    func testValidTemplatesAndTheReasonsForRefusing() {
        XCTAssertNil(NamingTemplate.problem("{name}"))
        XCTAssertNil(NamingTemplate.problem("{site}/{date}/{name}"))
        XCTAssertNil(NamingTemplate.problem("{type}/{filename}"))
        for (bad, why) in [("", "empty"), ("{date}", "no name token"), ("../{name}", "traversal"), ("/abs/{name}", "absolute"), ("~/{name}", "home"), ("a\\{name}", "backslash"),
                           ("a:{name}", "colon"), ("{bogus}{name}", "unknown token"), ("a/b/c/d/{name}", "too deep"), ("a//{name}", "empty folder"), (".hidden/{name}", "hidden folder"),
                           ("{name}/", "empty file part"), (String(repeating: "x", count: 200) + "{name}", "too long"), ("a\u{1}{name}", "control character")] {
            XCTAssertNotNil(NamingTemplate.problem(bad), why)
        }
    }

    func testExpansionMakesFoldersAndKeepsTheEnding() {
        let x = NamingTemplate.expand("{site}/{type}/{date}-{name}", filename: "Quarterly report.pdf", host: "www.example.com", now: day)
        XCTAssertEqual(x.folders, ["example.com", "Documents"])
        XCTAssertTrue(x.name.hasSuffix("-Quarterly report.pdf"), x.name)
        XCTAssertEqual(NamingTemplate.expand("{filename}", filename: "a.zip", host: nil).name, "a.zip", "the ending is not added twice")
        XCTAssertEqual(NamingTemplate.expand("{name}.{ext}", filename: "a.zip", host: nil).name, "a.zip")
    }

    func testValuesCannotAddPathsOfTheirOwn() {
        let hostile = NamingTemplate.expand("{site}/{name}", filename: "x.txt", host: "evil/../..", now: day)
        XCTAssertTrue(hostile.folders.allSatisfy { !$0.contains("/") && $0 != ".." && !$0.hasPrefix(".") }, "\(hostile.folders)")
        let weirdName = NamingTemplate.expand("{name}-copy", filename: "a/b\\c.txt", host: nil)
        XCTAssertFalse(weirdName.name.contains("/") || weirdName.name.contains("\\"))
    }

    func testAnUnusableTemplateLeavesTheNameAsTheSiteGaveIt() {
        let x = NamingTemplate.expand("../../{name}", filename: "keep.pdf", host: "h.test")
        XCTAssertEqual(x, NamingTemplate.Expansion(folders: [], name: "keep.pdf"))
        XCTAssertEqual(DownloadCoordinator.applyTemplate("{date} {name}", to: "a.pdf", host: nil, now: day).hasSuffix(" a.pdf"), true, "the older single-name template still works")
    }

    func testPreviewShowsTheResultOrTheProblem() {
        XCTAssertTrue(NamingTemplate.preview("{site}/{name}").hasPrefix("example.com/Quarterly report"))
        XCTAssertEqual(NamingTemplate.preview("{date}"), "The last part must contain {name} or {filename}, the name the site gave the file.")
    }

    func testCategoriesUseTheEndingThenWhatTheSystemKnowsAboutIt() {
        XCTAssertEqual(DownloadCategory.of(filename: "a.PDF"), .documents)
        XCTAssertEqual(DownloadCategory.of(filename: "a.heif"), .images)
        XCTAssertEqual(DownloadCategory.of(filename: "a.xyzunknown"), .other)
        XCTAssertEqual(DownloadCategory.folderName(forFilename: "a.dmg"), "Installers", "existing sorted folders keep their name")
        XCTAssertEqual(DownloadCoordinator.category(forFilename: "a.mp3"), "Audio")
    }
}

// MARK: Destination rules

final class DestinationRuleTests: XCTestCase {
    func testMostSpecificRuleWinsAndEqualOnesKeepTheirOrder() {
        let general = DownloadRule(host: "", kind: .documents, folder: "Docs")
        let site = DownloadRule(host: "work.test", kind: .any, folder: "Work")
        var type = DownloadRule(host: "", kind: .any, folder: "Pictures"); type.uti = "public.image"
        let first = DownloadRule(host: "", kind: .any, folder: "FirstOfEquals"), second = DownloadRule(host: "", kind: .any, folder: "SecondOfEquals")
        XCTAssertEqual(DownloadRouting.folder(for: "a.pdf", from: "files.work.test", rules: [general, site]), "Work")
        XCTAssertEqual(DownloadRouting.folder(for: "a.png", from: "x.test", rules: [first, type]), "Pictures", "a type beats a rule with neither site nor type")
        XCTAssertEqual(DownloadRouting.folder(for: "a.png", from: "x.test", rules: [first, second]), "FirstOfEquals")
        XCTAssertNil(DownloadRouting.folder(for: "a.pdf", from: "x.test", rules: [type]), "a pdf is not an image")
    }

    func testARuleForOneProfileNeverAppliesToAnother() {
        var rule = DownloadRule(host: "", kind: .any, folder: "WorkOnly"); rule.profile = "work"
        XCTAssertEqual(DownloadRouting.folder(for: "a.pdf", from: nil, profile: "work", rules: [rule]), "WorkOnly")
        XCTAssertNil(DownloadRouting.folder(for: "a.pdf", from: nil, profile: "home", rules: [rule]))
        XCTAssertNil(DownloadRouting.folder(for: "a.pdf", from: nil, profile: nil, rules: [rule]))
    }

    func testRulesSavedBeforeTheNewFieldsStillDecodeAndKeepTheirIdentity() throws {
        let old = #"[{"host":"x.test","kind":"images","folder":"Pics"}]"#.data(using: .utf8)!
        let rules = try JSONDecoder().decode([DownloadRule].self, from: old)
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].id, "x.test|images"); XCTAssertNil(rules[0].uti); XCTAssertNil(rules[0].bookmark)
        let round = try JSONDecoder().decode([DownloadRule].self, from: try JSONEncoder().encode(rules))
        XCTAssertEqual(round, rules)
    }

    func testAChosenFolderOpensAndAMissingOrBrokenOneFallsBack() throws {
        let folder = try tempFolder("dest")
        defer { DownloadDestinationAccess.closeAll(); try? FileManager.default.removeItem(at: folder) }
        let bookmark: Data
        do { bookmark = try DownloadDestinationAccess.makeBookmark(for: folder) } catch { throw XCTSkip("this environment cannot make security-scoped bookmarks: \(error)") }
        guard case .granted(let url) = DownloadDestinationAccess.open(bookmark) else { return XCTFail("a folder that exists should open") }
        XCTAssertEqual(url.resolvingSymlinksInPath().path, folder.resolvingSymlinksInPath().path)
        XCTAssertTrue(DownloadDestinationAccess.grantedRoots.contains { $0.resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path })
        guard case .unavailable = DownloadDestinationAccess.open(Data("not a bookmark".utf8)) else { return XCTFail("garbage is not a folder") }
        try FileManager.default.removeItem(at: folder)
        guard case .unavailable(let why) = DownloadDestinationAccess.open(bookmark) else { return XCTFail("a deleted folder cannot be used") }
        XCTAssertFalse(why.isEmpty)
    }

    @MainActor
    func testADownloadGoesToTheOrdinaryFolderWhenTheChosenOneIsGone() throws {
        let base = try tempFolder("fallback")
        let saved = DownloadCoordinator.directoryOverride
        DownloadCoordinator.directoryOverride = base
        defer { DownloadCoordinator.directoryOverride = saved; try? FileManager.default.removeItem(at: base) }
        let c = DownloadCoordinator()
        var rule = DownloadRule(host: "", kind: .any, folder: ""); rule.bookmark = Data("revoked".utf8); rule.bookmarkName = "Elsewhere"
        c.rules = [rule]
        let started = c.begin(suggestedName: "a.pdf", sourceHost: "x.test", cancel: {})
        XCTAssertEqual(started.destination.deletingLastPathComponent().resolvingSymlinksInPath().path, base.resolvingSymlinksInPath().path, "it did not fail and did not go anywhere unexpected")
        XCTAssertTrue(c.events.contains { $0.contains("rule") }, "the person is told why")
    }

    @MainActor
    func testTemplateFoldersAndRuleFoldersNestInOrder() throws {
        let base = try tempFolder("nest")
        let saved = DownloadCoordinator.directoryOverride
        DownloadCoordinator.directoryOverride = base
        defer { DownloadCoordinator.directoryOverride = saved; try? FileManager.default.removeItem(at: base) }
        let c = DownloadCoordinator()
        c.rules = [DownloadRule(host: "", kind: .documents, folder: "Docs")]
        c.nameTemplate = "{site}/{name}"
        let dest = c.begin(suggestedName: "r.pdf", sourceHost: "www.example.com", cancel: {}).destination
        let relative = dest.path.replacingOccurrences(of: base.resolvingSymlinksInPath().path, with: "").replacingOccurrences(of: base.path, with: "")
        XCTAssertEqual(relative, "/Docs/example.com/r.pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.deletingLastPathComponent().path), "its folders were made")
    }
}

// MARK: Duplicates and safe finalisation

@MainActor
final class DuplicateAndFinaliseTests: XCTestCase {
    private var base: URL!
    private var saved: URL?
    override func setUp() async throws { try await super.setUp(); base = try tempFolder("dup"); saved = DownloadCoordinator.directoryOverride; DownloadCoordinator.directoryOverride = base }
    override func tearDown() async throws { DownloadCoordinator.directoryOverride = saved; try? FileManager.default.removeItem(at: base); try await super.tearDown() }

    func testTwoDownloadsWithOneNameGetTwoDestinationsEvenBeforeEitherFileExists() {
        let c = DownloadCoordinator()
        let a = c.begin(suggestedName: "report.pdf", cancel: {}).destination
        let b = c.begin(suggestedName: "report.pdf", cancel: {}).destination
        let d = c.begin(suggestedName: "report.pdf", cancel: {}).destination
        XCTAssertEqual(Set([a, b, d]).count, 3)
        XCTAssertEqual([a, b, d].map(\.lastPathComponent), ["report.pdf", "report (1).pdf", "report (2).pdf"])
    }

    func testAskCanKeepBothSkipOrReplaceAndNeverActsWithoutAnAnswer() async throws {
        let c = DownloadCoordinator()
        c.duplicatePolicy = .ask
        try Data("old".utf8).write(to: base.appendingPathComponent("x.txt"))
        var asked: [String] = []
        c.duplicateAsker = { name in asked.append(name); return .keepBoth }
        let skipKeep = await c.askAboutDuplicate(suggestedName: "x.txt", sourceHost: nil, source: nil, isPrivate: false)
        XCTAssertFalse(skipKeep); XCTAssertEqual(asked, ["x.txt"])
        XCTAssertEqual(c.begin(suggestedName: "x.txt", cancel: {}).destination.lastPathComponent, "x (1).txt")

        let record = c.ledger.create(protocolID: .http, source: URL(string: "https://h.test/x.txt"), filename: "x.txt", isPrivate: false)
        _ = c.ledger.apply(.queued, to: record.id)
        c.duplicateAsker = { _ in .skip }
        let skipped = await c.askAboutDuplicate(suggestedName: "x.txt", sourceHost: nil, source: nil, isPrivate: false, taskID: record.id)
        XCTAssertTrue(skipped)
        XCTAssertEqual(c.ledger.record(record.id)?.state, .cancelled)
        XCTAssertEqual(try String(contentsOf: base.appendingPathComponent("x.txt")), "old", "skipping leaves the old file alone")

        // No file there: nothing is asked.
        asked = []
        c.duplicateAsker = { name in asked.append(name); return .skip }
        let fresh = await c.askAboutDuplicate(suggestedName: "new.txt", sourceHost: nil, source: nil, isPrivate: false)
        XCTAssertFalse(fresh); XCTAssertTrue(asked.isEmpty)
    }

    func testReplaceOnlyHappensForTheDownloadTheAnswerWasGivenFor() async throws {
        let c = DownloadCoordinator()
        c.duplicatePolicy = .ask
        let old = base.appendingPathComponent("y.txt")
        try Data("old".utf8).write(to: old)
        c.duplicateAsker = { _ in .replace }
        let first = UUID()
        _ = await c.askAboutDuplicate(suggestedName: "y.txt", sourceHost: nil, source: nil, isPrivate: false, taskID: first)
        // Another download of the same name that was not asked about keeps both.
        let other = c.begin(suggestedName: "y.txt", taskID: UUID(), cancel: {}).destination
        XCTAssertEqual(other.lastPathComponent, "y (1).txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path), "the old file is untouched by an unrelated download")
        // The one that was answered takes the name; the old file goes to the Trash (or, if the Trash is unavailable here, both are kept: it is never deleted).
        let replaced = c.begin(suggestedName: "y.txt", taskID: first, cancel: {}).destination
        XCTAssertTrue(replaced.lastPathComponent == "y.txt" || replaced.lastPathComponent.hasPrefix("y ("))
        if replaced.lastPathComponent != "y.txt" { XCTAssertTrue(FileManager.default.fileExists(atPath: old.path)) }
    }

    func testFinalisingNeverOverwritesAndTwoTasksCannotTakeOneName() throws {
        let staged1 = base.appendingPathComponent("s1"), staged2 = base.appendingPathComponent("s2")
        try Data("one".utf8).write(to: staged1); try Data("two".utf8).write(to: staged2)
        let target = base.appendingPathComponent("out.txt")
        let a = try HTTPTransferEngine.finalise(from: staged1, to: target, taskID: UUID(), sourceOrigin: "https://h.test")
        let b = try HTTPTransferEngine.finalise(from: staged2, to: target, taskID: UUID(), sourceOrigin: "https://h.test")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(try String(contentsOf: a), "one"); XCTAssertEqual(try String(contentsOf: b), "two")
        XCTAssertEqual(b.lastPathComponent, "out (2).txt")
        XCTAssertTrue(DownloadQuarantine.isQuarantined(a), "the file carries the mark macOS uses for things from the internet")
    }

    func testAFolderOrALinkAtTheDestinationIsNeverReplaced() throws {
        let dir = base.appendingPathComponent("taken", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let secret = base.appendingPathComponent("secret.txt"); try Data("keep".utf8).write(to: secret)
        let link = base.appendingPathComponent("link.txt"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        for name in ["taken", "link.txt"] {
            let staged = base.appendingPathComponent("s-\(name)"); try Data("new".utf8).write(to: staged)
            let result = try HTTPTransferEngine.finalise(from: staged, to: base.appendingPathComponent(name), taskID: UUID(), sourceOrigin: "https://h.test")
            XCTAssertNotEqual(result.lastPathComponent, name, "it took a name of its own")
        }
        XCTAssertEqual(try String(contentsOf: secret), "keep", "the file a link pointed at was not written through")
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue)
    }

    func testAFailedFinaliseLeavesTheStagedFileAndNothingElse() throws {
        let readOnly = base.appendingPathComponent("ro", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        let staged = base.appendingPathComponent("staged"); try Data("data".utf8).write(to: staged)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnly.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnly.path) }
        XCTAssertThrowsError(try HTTPTransferEngine.finalise(from: staged, to: readOnly.appendingPathComponent("f.txt"), taskID: UUID(), sourceOrigin: "https://h.test"))
        XCTAssertEqual(try String(contentsOf: staged), "data", "a permission failure does not cost the downloaded bytes")
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: readOnly.path)).isEmpty)
    }
}

// MARK: Integrity

final class IntegrityCheckTests: XCTestCase {
    private let abcDigest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    func testDigestsAreReadFromWhatPeoplePaste() {
        XCTAssertEqual(DownloadIntegrityCheck.normalizedDigest(abcDigest.uppercased()), abcDigest)
        XCTAssertEqual(DownloadIntegrityCheck.normalizedDigest("SHA256: " + abcDigest), abcDigest)
        XCTAssertNil(DownloadIntegrityCheck.normalizedDigest("abc")); XCTAssertNil(DownloadIntegrityCheck.normalizedDigest(String(repeating: "z", count: 64)))
    }

    func testMatchMismatchAndNoExpectedDigest() throws {
        let dir = try tempFolder("int"); defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("abc.txt"); try Data("abc".utf8).write(to: f)
        let ok = try DownloadIntegrityCheck.verify(file: f, expectedSHA256: abcDigest, expectedSize: 3, digestIsTrusted: true)
        XCTAssertEqual(ok.outcome, .matchesGivenChecksum(trusted: true)); XCTAssertEqual(ok.sha256, abcDigest); XCTAssertEqual(ok.bytes, 3)
        XCTAssertEqual(try DownloadIntegrityCheck.verify(file: f, expectedSHA256: abcDigest, expectedSize: nil, digestIsTrusted: false).outcome, .matchesGivenChecksum(trusted: false))
        let bad = try DownloadIntegrityCheck.verify(file: f, expectedSHA256: String(repeating: "0", count: 64), expectedSize: nil, digestIsTrusted: true)
        XCTAssertEqual(bad.outcome, .doesNotMatchChecksum(expected: String(repeating: "0", count: 64)))
        let none = try DownloadIntegrityCheck.verify(file: f, expectedSHA256: nil, expectedSize: nil, digestIsTrusted: false)
        XCTAssertEqual(none.outcome, .computedOnly)
        XCTAssertFalse(DownloadIntegrityCheck.summary(none.outcome, sha256: none.sha256).lowercased().contains("verified"), "a bare digest is not called verification")
        XCTAssertTrue(DownloadIntegrityCheck.summary(none.outcome, sha256: none.sha256).contains("not proof"))
        XCTAssertEqual(try DownloadIntegrityCheck.verify(file: f, expectedSHA256: nil, expectedSize: 99, digestIsTrusted: false).outcome, .sizeDiffers(expected: 99))
    }

    func testALargeFileIsHashedInChunksAndGivesTheRightAnswer() throws {
        let dir = try tempFolder("big"); defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("big.bin")
        FileManager.default.createFile(atPath: f.path, contents: nil)
        let handle = try FileHandle(forWritingTo: f)
        var reference = SHA256()
        let block = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        for _ in 0..<33 { try handle.write(contentsOf: block); reference.update(data: block) }     // 33 MiB: crosses many chunk boundaries
        let tail = Data([1, 2, 3, 4, 5]); try handle.write(contentsOf: tail); reference.update(data: tail)
        try handle.close()
        let report = try DownloadIntegrityCheck.verify(file: f, expectedSHA256: nil, expectedSize: nil, digestIsTrusted: false)
        XCTAssertEqual(report.sha256, reference.finalize().map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(report.bytes, 33 * (1 << 20) + 5)
    }

    func testReadingCanBeCancelledAndMissingFilesAreReported() throws {
        let dir = try tempFolder("cancel"); defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("a"); try Data("abc".utf8).write(to: f)
        XCTAssertThrowsError(try DownloadIntegrityCheck.verify(file: f, expectedSHA256: nil, expectedSize: nil, digestIsTrusted: false, isCancelled: { true })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertThrowsError(try DownloadIntegrityCheck.verify(file: dir.appendingPathComponent("missing"), expectedSHA256: nil, expectedSize: nil, digestIsTrusted: false))
        XCTAssertThrowsError(try DownloadIntegrityCheck.verify(file: dir, expectedSHA256: nil, expectedSize: nil, digestIsTrusted: false))
    }

    @MainActor
    func testReverifyRecordsTheOutcomeWithoutCallingABareDigestVerified() async throws {
        let dir = try tempFolder("rev"); defer { try? FileManager.default.removeItem(at: dir) }
        let saved = DownloadCoordinator.directoryOverride; DownloadCoordinator.directoryOverride = dir
        defer { DownloadCoordinator.directoryOverride = saved }
        let c = DownloadCoordinator()
        func completed(_ name: String, expected: String?) throws -> UUID {
            let f = dir.appendingPathComponent(name); try Data("abc".utf8).write(to: f)
            let r = c.ledger.create(protocolID: .http, source: URL(string: "https://h.test/\(name)"), filename: name, isPrivate: false)
            for e in [DownloadEvent.queued, .started, .running, .verifying, .completed(.unknown)] { _ = c.ledger.apply(e, to: r.id) }
            c.ledger.update(r.id) { $0.file.destinationPath = f.path; if let expected { $0.engineMetadata["sha256"] = expected; $0.engineMetadata["sha256From"] = "user" } }
            return r.id
        }
        let none = try completed("none.txt", expected: nil), good = try completed("good.txt", expected: abcDigest), bad = try completed("bad.txt", expected: String(repeating: "1", count: 64))
        for id in [none, good, bad] { await c.reverify(id) }
        XCTAssertEqual(c.ledger.record(none)?.file.integrity, .unknown, "nothing was given to compare with, so it is not 'verified'")
        XCTAssertEqual(c.ledger.record(none)?.engineMetadata["sha256Computed"], abcDigest)
        XCTAssertEqual(c.ledger.record(good)?.file.integrity, .verified)
        XCTAssertEqual(c.ledger.record(bad)?.file.integrity, .mismatch)
        let rows = DownloadRowProjector.rows(from: DownloadsSnapshot(records: [c.ledger.record(none)!, c.ledger.record(good)!, c.ledger.record(bad)!]))
        let text = Dictionary(uniqueKeysWithValues: rows.map { ($0.filename, $0) })
        XCTAssertTrue(text["none.txt"]!.integrityText.contains("not proof")); XCTAssertNil(text["none.txt"]!.integrityMatched)
        XCTAssertEqual(text["good.txt"]!.integrityText, "Matches the checksum you gave."); XCTAssertEqual(text["good.txt"]!.integrityMatched, true)
        XCTAssertEqual(text["bad.txt"]!.integrityMatched, false)
    }
}

// MARK: Finder-style operations

@MainActor
final class FileOperationsTests: XCTestCase {
    private var base: URL!
    private var saved: URL?
    private var c: DownloadCoordinator!
    override func setUp() async throws {
        try await super.setUp()
        base = try tempFolder("ops"); saved = DownloadCoordinator.directoryOverride; DownloadCoordinator.directoryOverride = base
        c = DownloadCoordinator()
    }
    override func tearDown() async throws { DownloadCoordinator.directoryOverride = saved; try? FileManager.default.removeItem(at: base); try await super.tearDown() }

    private func completed(_ name: String, text: String = "data") throws -> UUID {
        let f = base.appendingPathComponent(name); try Data(text.utf8).write(to: f)
        let r = c.ledger.create(protocolID: .http, source: URL(string: "https://h.test/\(name)"), filename: name, isPrivate: false)
        for e in [DownloadEvent.queued, .started, .running, .verifying, .completed(.unknown)] { _ = c.ledger.apply(e, to: r.id) }
        c.ledger.update(r.id) { $0.file.destinationPath = f.path }
        return r.id
    }

    func testRenameKeepsTheEndingNeverOverwritesAndFollowsTheRecord() throws {
        let id = try completed("old.pdf"); _ = try completed("taken.pdf", text: "other")
        guard case .success(let url) = c.renameFile(of: id, to: "new name") else { return XCTFail("rename failed") }
        XCTAssertEqual(url.lastPathComponent, "new name.pdf")
        XCTAssertEqual(c.ledger.record(id)?.file.destinationPath, url.path); XCTAssertEqual(c.ledger.record(id)?.file.filename, "new name.pdf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("old.pdf").path))
        XCTAssertEqual(c.renameFile(of: id, to: "taken.pdf"), .failure(.exists("taken.pdf")))
        XCTAssertEqual(try String(contentsOf: base.appendingPathComponent("taken.pdf")), "other", "nothing was overwritten")
        XCTAssertEqual(c.renameFile(of: id, to: "../escape.pdf"), .failure(.invalidName))
        XCTAssertEqual(c.renameFile(of: id, to: "   "), .failure(.invalidName))
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.deletingLastPathComponent().appendingPathComponent("escape.pdf").path))
    }

    func testACaseOnlyRenameWorksOnACaseInsensitiveDisk() throws {
        let id = try completed("report.pdf")
        guard case .success(let url) = c.renameFile(of: id, to: "Report.pdf") else { return XCTFail("a case-only rename should work") }
        XCTAssertEqual(url.lastPathComponent, "Report.pdf")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: base.path), ["Report.pdf"], "one file, renamed, not two")
        XCTAssertEqual(try String(contentsOf: url), "data")
    }

    func testAnArchiveOpeningThatWasInterruptedIsCleanedUpLaterButNothingElseIs() throws {
        let stale = base.appendingPathComponent(".ab12cd34.bsetu-extract", isDirectory: true)
        let fresh = base.appendingPathComponent(".ff00ff00.bsetu-extract", isDirectory: true)
        let mine = base.appendingPathComponent("My Folder", isDirectory: true)
        let hiddenOther = base.appendingPathComponent(".cache", isDirectory: true)
        for d in [stale, fresh, mine, hiddenOther] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true); try Data("x".utf8).write(to: d.appendingPathComponent("f")) }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 86_400)], ofItemAtPath: stale.path)
        XCTAssertEqual(c.removeStalePieceFolders(in: base), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        for kept in [fresh, mine, hiddenOther] { XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path), kept.lastPathComponent) }
    }

    func testMoveGoesToTheChosenFolderWithTheNextFreeNameAndUpdatesTheRecord() throws {
        let id = try completed("m.txt")
        let dest = try tempFolder("movedest"); defer { try? FileManager.default.removeItem(at: dest) }
        try Data("existing".utf8).write(to: dest.appendingPathComponent("m.txt"))
        guard case .success(let url) = c.moveFile(of: id, toFolder: dest) else { return XCTFail("move failed") }
        XCTAssertEqual(url.lastPathComponent, "m (2).txt")
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("m.txt")), "existing")
        XCTAssertEqual(c.ledger.record(id)?.file.destinationPath, url.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("m.txt").path))
        // It is now outside the folders the app manages: further operations are refused rather than guessed.
        XCTAssertNil(c.managedFile(of: id))
        XCTAssertEqual(c.renameFile(of: id, to: "x.txt"), .failure(.notAFile))
    }

    func testMoveRefusesALinkAndANonFolder() throws {
        let id = try completed("n.txt")
        let notFolder = base.appendingPathComponent("plain.txt"); try Data("x".utf8).write(to: notFolder)
        XCTAssertEqual(c.moveFile(of: id, toFolder: notFolder), .failure(.notAFolder))
        let realDir = try tempFolder("real"); defer { try? FileManager.default.removeItem(at: realDir) }
        let link = base.appendingPathComponent("dirlink"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realDir)
        XCTAssertEqual(c.moveFile(of: id, toFolder: link), .failure(.notAFolder))
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathComponent("n.txt").path))
    }

    func testAFileThatIsALinkOrOutsideTheManagedFoldersIsNeverTouched() throws {
        let outside = try tempFolder("outside"); defer { try? FileManager.default.removeItem(at: outside) }
        let stranger = outside.appendingPathComponent("s.txt"); try Data("mine".utf8).write(to: stranger)
        let r = c.ledger.create(protocolID: .http, source: URL(string: "https://h.test/s.txt"), filename: "s.txt", isPrivate: false)
        for e in [DownloadEvent.queued, .started, .running, .verifying, .completed(.unknown)] { _ = c.ledger.apply(e, to: r.id) }
        c.ledger.update(r.id) { $0.file.destinationPath = stranger.path }          // a record that points outside (a damaged or hostile database)
        XCTAssertNil(c.managedFile(of: r.id))
        XCTAssertFalse(c.trashFile(of: r.id)); XCTAssertEqual(c.renameFile(of: r.id, to: "z"), .failure(.notAFile))
        XCTAssertEqual(try String(contentsOf: stranger), "mine")
        let target = base.appendingPathComponent("t.txt"); try Data("t".utf8).write(to: target)
        let link = base.appendingPathComponent("l.txt"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try DownloadFileOperations.trash(link, roots: [base]))
        XCTAssertNil(DownloadFileOperations.managedFile(link.path, roots: [base]))
    }

    func testTrashTakesTheFileAwayButRemovingTheEntryNeverDoes() throws {
        let keep = try completed("keep.txt"), gone = try completed("gone.txt")
        c.removeRecord(keep)
        XCTAssertNil(c.ledger.record(keep)); XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathComponent("keep.txt").path), "removing the entry keeps the file")
        if c.trashFile(of: gone) { XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("gone.txt").path)) }
        else { XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathComponent("gone.txt").path), "if the Trash is unavailable the file is simply kept") }
    }

    func testCrossVolumeCopyIsOnlyUsedWhenRenameCannotWorkAndNeverReplaces() throws {
        // A true second volume is not available here; this checks the rename path and the collision refusal that the copy path shares.
        let a = base.appendingPathComponent("a"), b = base.appendingPathComponent("b")
        try Data("a".utf8).write(to: a); try Data("b".utf8).write(to: b)
        XCTAssertThrowsError(try DownloadFileOperations.moveWithoutReplacing(a, to: b)) { XCTAssertEqual($0 as? DownloadFileOperations.Failure, .exists("b")) }
        XCTAssertEqual(try String(contentsOf: a), "a"); XCTAssertEqual(try String(contentsOf: b), "b")
    }
}

// MARK: Older history

@MainActor
final class LegacyHistoryTests: XCTestCase {
    private func fetcher(_ total: Int) -> DownloadsViewModel.LegacySource {
        { limit in (0..<min(total, Int(limit))).map { (url: "https://old.test/f\($0).zip?sig=SECRET\($0)", filename: "old\($0).zip", created: Int64(2_000_000_000 - $0 * 100)) } }
    }

    func testPagesAreBoundedAndTellWhetherThereIsMore() {
        let one = DownloadLegacyHistory.page(1, fetch: fetcher(450))
        XCTAssertEqual(one.entries.count, 200); XCTAssertTrue(one.hasMore)
        XCTAssertEqual(one.entries.first?.filename, "old0.zip", "newest first")
        let three = DownloadLegacyHistory.page(3, fetch: fetcher(450))
        XCTAssertEqual(three.entries.count, 450); XCTAssertFalse(three.hasMore)
        let huge = DownloadLegacyHistory.page(10_000, fetch: fetcher(100_000))
        XCTAssertEqual(huge.entries.count, DownloadLegacyHistory.maxPages * DownloadLegacyHistory.pageSize); XCTAssertFalse(huge.hasMore, "never reads past the cap")
        XCTAssertTrue(DownloadLegacyHistory.page(1, fetch: { _ in throw NSError(domain: "x", code: 1) }).entries.isEmpty, "a failing core shows nothing rather than crashing")
    }

    func testIdentifiersAreStableDistinctAndNotTaskIdentities() {
        let a = DownloadLegacyHistory.Entry(url: "https://x.test/a", filename: "a", created: Date(timeIntervalSince1970: 100))
        var b = a; b.filename = "b"
        XCTAssertEqual(DownloadLegacyHistory.identifier(for: a), DownloadLegacyHistory.identifier(for: a))
        XCTAssertNotEqual(DownloadLegacyHistory.identifier(for: a), DownloadLegacyHistory.identifier(for: b))
    }

    func testAnEntryTheTaskDatabaseAlreadyDescribesIsNotListedTwice() {
        var r = DownloadTaskRecord(protocolID: .http, profile: "default", source: DownloadSourceRef(url: URL(string: "https://x.test/f.zip?token=1")), filename: "f.zip", now: Date(timeIntervalSince1970: 1_000))
        r.state = .completed; r.completedAt = Date(timeIntervalSince1970: 1_030)
        let same = DownloadLegacyHistory.Entry(url: "https://x.test/f.zip", filename: "f.zip", created: Date(timeIntervalSince1970: 1_000))
        let later = DownloadLegacyHistory.Entry(url: "https://x.test/f.zip", filename: "f.zip", created: Date(timeIntervalSince1970: 9_000))     // downloaded again another day
        let other = DownloadLegacyHistory.Entry(url: "https://x.test/g.zip", filename: "g.zip", created: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(DownloadLegacyHistory.unseen([same, later, other], records: [r]), [later, other])
    }

    func testTheListShowsOldHistoryWithoutInventingStateOrAddresses() async throws {
        let c = DownloadCoordinator()
        let vm = DownloadsViewModel(coordinator: c, legacy: fetcher(5), defaults: nil, changeDelay: 0, progressDelay: 0.05)
        vm.acquire(); defer { vm.release() }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(vm.rows.count, 5)
        let row = vm.rows[0]
        XCTAssertTrue(row.isLegacy); XCTAssertEqual(row.status, .completed); XCTAssertEqual(row.protocolID, "legacy")
        XCTAssertFalse(row.sourceDisplay.contains("SECRET") || row.detail.contains("SECRET"), "an old address's signature is not shown")
        XCTAssertTrue(row.actions.isDisjoint(with: [.cancel, .retry, .resume, .rename, .move, .trashFile]), "there is no task to change")
        XCTAssertTrue(row.actions.contains(.removeRecord), "but an old entry can always be taken off the list (its file is never touched)")
        XCTAssertTrue(row.detail.contains("file not found"), "a file that is gone is said to be gone")
        XCTAssertNil(c.ledger.record(row.id), "no record was created for it")
        var q = DownloadQuery(); q.search = "old3"
        XCTAssertEqual(q.apply(to: vm.rows).map(\.filename), ["old3.zip"], "searchable with the rest")
        q = DownloadQuery(); q.sort = .name; q.ascending = true
        XCTAssertEqual(q.apply(to: vm.rows).first?.filename, "old0.zip")
    }

    func testMoreHistoryLoadsOnRequestAndActiveDownloadsStayAtTheTop() async throws {
        let c = DownloadCoordinator()
        let live = c.ledger.create(protocolID: .http, source: URL(string: "https://h.test/live.bin"), filename: "live.bin", isPrivate: false)
        for e in [DownloadEvent.queued, .started, .running] { _ = c.ledger.apply(e, to: live.id) }
        let vm = DownloadsViewModel(coordinator: c, legacy: fetcher(450), defaults: nil, changeDelay: 0, progressDelay: 0.05)
        vm.acquire(); defer { vm.release() }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(vm.rows.count, 201); XCTAssertTrue(vm.hasMoreHistory)
        XCTAssertEqual(vm.rows.first?.id, live.id, "the live download is first, before any history")
        vm.loadMoreHistory(); try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(vm.rows.count, 401); vm.loadMoreHistory(); try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(vm.rows.count, 451); XCTAssertFalse(vm.hasMoreHistory)
    }
}

// MARK: Archives

private enum ZipBuilder {
    struct Item { var name: String; var content: Data; var deflate = false; var mode: UInt32 = 0o100644; var wrongCRC = false }

    static func deflated(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data() }
        let capacity = data.count + 1024
        var out = Data(count: capacity)
        let n = out.withUnsafeMutableBytes { dst in data.withUnsafeBytes { src in
            compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity, src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB) } }
        return out.prefix(n)
    }

    static func build(_ items: [Item]) -> Data {
        var out = Data(), central = Data()
        func le16(_ v: Int) -> Data { Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
        func le32(_ v: UInt32) -> Data { Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]) }
        for item in items {
            let name = Data(item.name.utf8)
            let packed = item.deflate ? deflated(item.content) : item.content
            let crc = ExtensionPackage.crc32(item.content) ^ (item.wrongCRC ? 0xFFFF : 0)
            let offset = out.count
            let method = item.deflate ? 8 : 0
            var local = Data([0x50, 0x4B, 3, 4])
            local += le16(20); local += le16(0); local += le16(method); local += le16(0); local += le16(0x21)
            local += le32(crc); local += le32(UInt32(packed.count)); local += le32(UInt32(item.content.count))
            local += le16(name.count); local += le16(0); local += name; local += packed
            out += local
            var entry = Data([0x50, 0x4B, 1, 2])
            entry += le16(0x031E); entry += le16(20); entry += le16(0); entry += le16(method); entry += le16(0); entry += le16(0x21)
            entry += le32(crc); entry += le32(UInt32(packed.count)); entry += le32(UInt32(item.content.count))
            entry += le16(name.count); entry += le16(0); entry += le16(0); entry += le16(0); entry += le16(0)
            entry += le32(item.mode << 16); entry += le32(UInt32(offset)); entry += name
            central += entry
        }
        let start = out.count
        out += central
        var end = Data([0x50, 0x4B, 5, 6])
        end += le16(0); end += le16(0); end += le16(items.count); end += le16(items.count)
        end += le32(UInt32(central.count)); end += le32(UInt32(start)); end += le16(0)
        out += end
        return out
    }
}

final class ArchiveExtractorTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws { dir = try tempFolder("zip") }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func write(_ name: String, _ items: [ZipBuilder.Item]) throws -> URL {
        let url = dir.appendingPathComponent(name); try ZipBuilder.build(items).write(to: url); return url
    }
    private func listing() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }

    func testAValidZipOpensIntoANewFolderBesideItAndNeverIntoAnExistingOne() throws {
        let zip = try write("Photos.zip", [.init(name: "a.txt", content: Data("alpha".utf8)), .init(name: "sub/b.txt", content: Data(repeating: 0x42, count: 5000), deflate: true)])
        XCTAssertTrue(ArchiveExtractor.canExtract(zip))
        let out = try ArchiveExtractor.extract(file: zip)
        XCTAssertEqual(out.lastPathComponent, "Photos"); XCTAssertEqual(out.deletingLastPathComponent().path, dir.path)
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("a.txt")), "alpha")
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("sub/b.txt")).count, 5000)
        let again = try ArchiveExtractor.extract(file: zip)
        XCTAssertEqual(again.lastPathComponent, "Photos 2", "a second opening never merges into or replaces the first")
        XCTAssertFalse(listing().contains { $0.hasSuffix(".bsetu-extract") }, "no staging folder is left behind")
    }

    func testPathsOutsideTheFolderAreRefusedAndNothingIsLeftBehind() throws {
        for name in ["../evil.txt", "a/../../evil.txt", "/abs/evil.txt", "a\\..\\evil.txt"] {
            let zip = try write("bad.zip", [.init(name: "ok.txt", content: Data("fine".utf8)), .init(name: name, content: Data("x".utf8))])
            XCTAssertThrowsError(try ArchiveExtractor.extract(file: zip), name) { XCTAssertTrue(($0 as? ArchiveExtractor.Failure).map { if case .invalid = $0 { true } else { false } } ?? false) }
            XCTAssertEqual(listing(), ["bad.zip"], "\(name): the earlier good entry was not left behind either")
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().appendingPathComponent("evil.txt").path))
        }
    }

    func testLinksInsideAnArchiveAreRefused() throws {
        let zip = try write("link.zip", [.init(name: "link", content: Data("/etc/passwd".utf8), mode: 0o120777)])
        XCTAssertThrowsError(try ArchiveExtractor.extract(file: zip))
        XCTAssertEqual(listing(), ["link.zip"])
    }

    func testAnArchiveThatExpandsFarMoreThanItShouldIsRefusedBeforeAnythingIsWritten() throws {
        let zip = try write("bomb.zip", [.init(name: "zeros.bin", content: Data(count: 30 * 1024 * 1024), deflate: true)])
        let size = (try FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int) ?? 0
        XCTAssertLessThan(size, 200_000, "the fixture really is tiny")
        XCTAssertThrowsError(try ArchiveExtractor.extract(file: zip)) { XCTAssertNotNil($0 as? ArchiveExtractor.Failure) }
        XCTAssertEqual(listing(), ["bomb.zip"])
        // The same file is fine when the person's limits allow it (the limit is the protection, not a flaw in the file).
        let permissive = ExtensionPackage.Limits(maxUnpacked: 64 * 1024 * 1024, maxEntries: 10, maxDepth: 4, maxRatio: Int.max, rejectLinks: true)
        XCTAssertNoThrow(try ArchiveExtractor.extract(file: zip, limits: permissive))
    }

    func testTooManyFilesTooDeepAndTooLargeAreRefused() throws {
        let many = try write("many.zip", (0..<20).map { ZipBuilder.Item(name: "f\($0).txt", content: Data("x".utf8)) })
        XCTAssertThrowsError(try ArchiveExtractor.extract(file: many, limits: .init(maxUnpacked: 1 << 20, maxEntries: 10, maxDepth: 8, maxRatio: 1000, rejectLinks: true)))
        let deep = try write("deep.zip", [.init(name: "a/b/c/d/e/f.txt", content: Data("x".utf8))])
        XCTAssertThrowsError(try ArchiveExtractor.extract(file: deep, limits: .init(maxUnpacked: 1 << 20, maxEntries: 10, maxDepth: 3, maxRatio: 1000, rejectLinks: true)))
        let large = try write("large.zip", [.init(name: "a.bin", content: Data(count: 4096))])
        XCTAssertThrowsError(try ArchiveExtractor.extract(file: large, limits: .init(maxUnpacked: 1000, maxEntries: 10, maxDepth: 8, maxRatio: 1000, rejectLinks: true)))
        XCTAssertEqual(listing(), ["deep.zip", "large.zip", "many.zip"])
    }

    func testCorruptAndMislabelledArchivesAreRefused() throws {
        let good = ZipBuilder.build([.init(name: "a.txt", content: Data("hello world".utf8))])
        try good.prefix(good.count - 10).write(to: dir.appendingPathComponent("truncated.zip"))
        XCTAssertThrowsError(try ArchiveExtractor.extract(file: dir.appendingPathComponent("truncated.zip")))
        let badCRC = try write("crc.zip", [.init(name: "a.txt", content: Data("hello".utf8), wrongCRC: true)])
        XCTAssertThrowsError(try ArchiveExtractor.extract(file: badCRC))
        try Data("not a zip at all".utf8).write(to: dir.appendingPathComponent("fake.zip"))
        XCTAssertFalse(ArchiveExtractor.canExtract(dir.appendingPathComponent("fake.zip")))
        XCTAssertThrowsError(try ArchiveExtractor.extract(file: dir.appendingPathComponent("fake.zip")))
        XCTAssertEqual(listing(), ["crc.zip", "fake.zip", "truncated.zip"], "failures leave no folders")
    }

    func testOtherFormatsAreDeclinedPlainly() throws {
        let rar = dir.appendingPathComponent("a.rar"); try Data("Rar!".utf8).write(to: rar)
        XCTAssertFalse(ArchiveExtractor.canExtract(rar))
        XCTAssertThrowsError(try ArchiveExtractor.extract(file: rar)) { XCTAssertEqual($0 as? ArchiveExtractor.Failure, .notSupported(".rar files")) }
        XCTAssertThrowsError(try ArchiveExtractor.extract(file: dir.appendingPathComponent("missing.zip")))
    }

    func testNotEnoughDiskSpaceStopsBeforeWritingAnything() throws {
        let zip = try write("space.zip", [.init(name: "a.bin", content: Data(count: 4 << 20), deflate: true)])
        XCTAssertThrowsError(try ArchiveExtractor.extract(file: zip, limits: .init(maxUnpacked: 100 << 20, maxEntries: 10, maxDepth: 8, maxRatio: 100_000, rejectLinks: true), freeSpace: { _ in 1000 })) {
            guard case .notEnoughSpace? = $0 as? ArchiveExtractor.Failure else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(listing(), ["space.zip"])
    }

    func testTheInternetMarkOnTheArchiveIsCarriedToWhatComesOutOfIt() throws {
        let zip = try write("marked.zip", [.init(name: "a.txt", content: Data("x".utf8))])
        let value = "0083;5f5e1000;Browser Setu;"
        let marked = setxattr(zip.path, "com.apple.quarantine", value, value.utf8.count, 0, 0)
        let why = errno
        XCTAssertEqual(marked, 0, "the test could not mark its own archive: errno \(why) \(String(cString: strerror(why)))")
        let out = try ArchiveExtractor.extract(file: zip)
        XCTAssertTrue(DownloadQuarantine.isQuarantined(out.appendingPathComponent("a.txt")))
    }

    @MainActor
    func testItIsOnlyDoneOnRequestAndOnlyForAManagedCompletedFile() async throws {
        let saved = DownloadCoordinator.directoryOverride; DownloadCoordinator.directoryOverride = dir
        defer { DownloadCoordinator.directoryOverride = saved }
        let zip = try write("auto.zip", [.init(name: "a.txt", content: Data("x".utf8))])
        let c = DownloadCoordinator()
        let r = c.ledger.create(protocolID: .http, source: URL(string: "https://h.test/auto.zip"), filename: "auto.zip", isPrivate: false)
        for e in [DownloadEvent.queued, .started, .running, .verifying, .completed(.unknown)] { _ = c.ledger.apply(e, to: r.id) }
        c.ledger.update(r.id) { $0.file.destinationPath = zip.path }
        XCTAssertEqual(listing(), ["auto.zip"], "finishing a download opens nothing by itself")
        XCTAssertTrue(c.canExtract(r.id))
        guard case .success(let out) = await c.extractArchive(r.id) else { return XCTFail("extract failed") }
        XCTAssertEqual(out.lastPathComponent, "auto")
        let row = DownloadRowProjector.rows(from: { var s = DownloadsSnapshot(records: [c.ledger.record(r.id)!]); s.fileExists = { _ in true }; s.isExtractable = { _ in true }; return s }())[0]
        XCTAssertTrue(row.actions.contains(.extract) && row.actions.contains(.rename) && row.actions.contains(.verify))
    }
}

// MARK: Real downloads: names from the server, checksums given by the person (fixture server on port 18766)

@MainActor
final class FileManagementIntegrationTests: XCTestCase {
    private static let port = 18766
    private var root: URL!, downloads: URL!
    private var saved: URL?
    private var c: DownloadCoordinator!

    override func setUp() async throws {
        try await super.setUp()
        let up = (try? await URLSession(configuration: .ephemeral).data(from: URL(string: "http://127.0.0.1:\(Self.port)/")!)) != nil
        XCTAssertTrue(up, "run through the BrowserSetuMac scheme, which starts the fixture server")
        guard up else { throw XCTSkip("fixture server not running") }
        root = try tempFolder("int"); downloads = root.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        saved = DownloadCoordinator.directoryOverride; DownloadCoordinator.directoryOverride = downloads
        c = DownloadCoordinator(); c.profileName = "default"; c.store = root.appendingPathComponent("store"); c.hasHost = { false }
    }
    override func tearDown() async throws {
        if let c { for (id, r) in c.ledger.records where !r.state.isFinal && r.state != .failed { c.cancel(id) }; if let s = c.store { DownloadTaskStore.close(folder: s) } }
        try? await Task.sleep(for: .milliseconds(150))
        // Whatever this test started must have given its connections back (a lease left here used to break unrelated classes that ran later).
        var leftover = ConnectionBudget.shared.holders()
        let deadline = Date().addingTimeInterval(5)
        while !leftover.isEmpty, Date() < deadline { try? await Task.sleep(for: .milliseconds(20)); leftover = ConnectionBudget.shared.holders() }
        XCTAssertTrue(leftover.isEmpty, "\(name) left \(leftover.count) connection lease(s) behind: \(leftover.map { "\($0.connections)" })")
        for stale in leftover { ConnectionBudget.shared.release(task: stale.task) }          // so one leak is reported once, by the test that made it
        DownloadCoordinator.directoryOverride = saved
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    private func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(Self.port)\(path)")! }
    private func finished(_ id: UUID, seconds: Double = 30) async -> DownloadTaskRecord? {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if let r = c.ledger.record(id), r.state == .completed || r.state == .failed { return r }; try? await Task.sleep(for: .milliseconds(30)) }
        return c.ledger.record(id)
    }
    private func cd(_ value: String) -> String { "/file/4096?cd=" + (value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "") }

    func testATypedInAddressTakesItsNameAndSizeFromTheServer() async throws {
        let id = try XCTUnwrap(c.scheduleDownload(url: url(cd("attachment; filename*=UTF-8''r%C3%A9sum%C3%A9.bin")), at: Date()))
        let done = await finished(id)
        XCTAssertEqual(done?.state, .completed)
        XCTAssertEqual(done?.file.filename, "résumé.bin")
        XCTAssertEqual(done?.transfer.totalBytes, 4096); XCTAssertEqual(done?.transfer.completedBytes, 4096)
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloads.appendingPathComponent("résumé.bin").path))
    }

    func testAMaliciousHeaderNameStaysInsideTheDownloadsFolder() async throws {
        let id = try XCTUnwrap(c.scheduleDownload(url: url(cd("attachment; filename=\"../../evil.txt\"")), at: Date()))
        let done = await finished(id)
        XCTAssertEqual(done?.state, .completed)
        XCTAssertEqual(done?.file.filename, "evil.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloads.appendingPathComponent("evil.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("evil.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloads.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("evil.txt").path))
    }

    func testTheNameThePersonTypedIsNeverReplacedByTheServers() async throws {
        let id = try XCTUnwrap(c.scheduleDownload(url: url(cd("attachment; filename=\"server-name.bin\"")), at: Date(), filename: "my name.bin"))
        let done = await finished(id)
        XCTAssertEqual(done?.file.filename, "my name.bin")
        XCTAssertEqual(done?.engineMetadata["nameSource"], "user")
    }

    func testAChecksumTheyGaveIsComparedAndAWrongOneIsReported() async throws {
        let (bytes, _) = try await URLSession(configuration: .ephemeral).data(from: url("/file/4096"))
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let good = try XCTUnwrap(c.scheduleDownload(url: url("/file/4096"), at: Date(), expectedSHA256: "SHA256:" + digest.uppercased()))
        let ok = await finished(good)
        XCTAssertEqual(ok?.state, .completed); XCTAssertEqual(ok?.file.integrity, .verified); XCTAssertEqual(ok?.engineMetadata["sha256From"], "user")
        let bad = try XCTUnwrap(c.scheduleDownload(url: url("/file/4096"), at: Date(), filename: "wrong.bin", expectedSHA256: String(repeating: "0", count: 64)))
        let failed = await finished(bad)
        XCTAssertEqual(failed?.state, .failed, "a file that is not the one promised is not kept as if it were")
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloads.appendingPathComponent("wrong.bin").path))
        XCTAssertNil(c.scheduleDownload(url: url("/file/4096"), at: Date(), expectedSHA256: "nonsense").flatMap { c.ledger.record($0)?.engineMetadata["sha256"] }, "an invalid checksum is not stored")
    }

    func testTheSkipPolicyNowAppliesToTheAppsOwnDownloadsToo() async throws {
        try Data("mine".utf8).write(to: downloads.appendingPathComponent("4096"))
        c.duplicatePolicy = .skip
        let id = try XCTUnwrap(c.scheduleDownload(url: url("/file/4096"), at: Date(), filename: "4096"))
        try? await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(c.ledger.record(id)?.state, .cancelled)
        XCTAssertEqual(try String(contentsOf: downloads.appendingPathComponent("4096")), "mine")
        XCTAssertTrue(ConnectionBudget.shared.holders().filter { $0.task == id }.isEmpty, "a skipped download gives its connection back")
    }
}
