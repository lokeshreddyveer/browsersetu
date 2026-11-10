import XCTest
@testable import Browser_Setu

/// Download names, duplicates, failures, resuming and leftovers. Every test works in a folder of its own, never the real Downloads.
@MainActor
final class DownloadPolicyTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("bs-dl-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        DownloadCoordinator.directoryOverride = folder
    }

    override func tearDown() {
        DownloadCoordinator.directoryOverride = nil
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private func coordinator() -> DownloadCoordinator { DownloadCoordinator() }

    // MARK: Naming

    func testATemplateKeepsTheEndingAndFillsInTheDetails() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        XCTAssertEqual(DownloadCoordinator.applyTemplate("{date} {name}", to: "report.pdf", host: "www.example.com", now: now), "2025-10-09 report.pdf")
        XCTAssertEqual(DownloadCoordinator.applyTemplate("{host} - {name}", to: "a.tar.gz", host: "www.example.com", now: now), "example.com - a.tar.gz")
        XCTAssertEqual(DownloadCoordinator.applyTemplate("{name} ({time})", to: "noending", host: nil, now: now).hasPrefix("noending ("), true)
        XCTAssertEqual(DownloadCoordinator.applyTemplate("{name}", to: "same.pdf", host: "x.test"), "same.pdf")
    }

    func testABadTemplateLeavesTheNameAloneAndSaysWhy() {
        for bad in ["", "no name token", "{name}{bogus}", "{name}/x", "a:{name}", String(repeating: "x", count: 130) + "{name}", "{name"] {
            XCTAssertNotNil(DownloadCoordinator.templateProblem(bad), bad)
            XCTAssertEqual(DownloadCoordinator.applyTemplate(bad, to: "keep.pdf", host: "x.test"), "keep.pdf", bad)
        }
        XCTAssertNil(DownloadCoordinator.templateProblem("{date} {name}"))
    }

    func testATemplateCannotMakeAPathOrAHiddenFile() {
        let name = DownloadCoordinator.applyTemplate("{name}", to: "../../evil.sh", host: nil)
        XCTAssertFalse(name.contains("/")); XCTAssertFalse(name.hasPrefix("."))
        XCTAssertFalse(DownloadCoordinator.applyTemplate("{host}{name}", to: "x.pdf", host: "../..").contains("/"))
    }

    func testBeginUsesTheTemplate() {
        let c = coordinator()
        c.nameTemplate = "dl {name}"
        let started = c.begin(suggestedName: "a.txt", sourceHost: "x.test", cancel: {})
        XCTAssertEqual(started.destination.lastPathComponent, "dl a.txt")
        XCTAssertEqual(started.destination.deletingLastPathComponent().standardizedFileURL, folder.standardizedFileURL)
    }

    // MARK: Duplicates

    func testOneImplementationGivesTheTwoNumberingStyles() {
        let taken: Set<String> = ["a.pdf", "a (1).pdf", "a 2.pdf"]
        XCTAssertEqual(FileNaming.unique("a.pdf", style: .parenthesized) { taken.contains($0) }, "a (2).pdf")
        XCTAssertEqual(FileNaming.unique("a.pdf", style: .spaced) { taken.contains($0) }, "a 3.pdf")
        XCTAssertEqual(FileNaming.unique("b.pdf", style: .spaced) { taken.contains($0) }, "b.pdf")
        XCTAssertEqual(DownloadRouting.uniqueName("a.pdf") { taken.contains($0) }, "a 3.pdf")
        XCTAssertEqual(DownloadCoordinator.uniqueURL(in: folder, name: "n.txt").lastPathComponent, "n.txt")
    }

    func testKeepBothNumbersTheNewFileAndNeverTouchesTheOldOne() throws {
        let existing = folder.appendingPathComponent("a.txt")
        try Data("old".utf8).write(to: existing)
        let c = coordinator()
        c.duplicatePolicy = .keepBoth
        let started = c.begin(suggestedName: "a.txt", cancel: {})
        XCTAssertEqual(started.destination.lastPathComponent, "a (1).txt")
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "old")
        let second = c.begin(suggestedName: "a.txt", cancel: {})
        XCTAssertEqual(second.destination.lastPathComponent, "a (2).txt", "two at once do not take the same name")
    }

    func testSkipDoesNotStartAndTellsThePerson() throws {
        try Data("old".utf8).write(to: folder.appendingPathComponent("a.txt"))
        let c = coordinator()
        c.duplicatePolicy = .skip
        XCTAssertTrue(c.skipDuplicate(suggestedName: "a.txt", sourceHost: nil, source: URL(string: "https://x.test/a.txt"), isPrivate: false))
        XCTAssertEqual(c.failures.first?.filename, "a.txt")
        XCTAssertTrue(c.failures.first?.reason.contains("not downloaded again") == true)
        XCTAssertEqual(c.failures.first?.canRetry, false)
        XCTAssertFalse(c.skipDuplicate(suggestedName: "new.txt", sourceHost: nil, source: nil, isPrivate: false), "a file that is not there is downloaded")
        let p = coordinator(); p.duplicatePolicy = .skip
        XCTAssertTrue(p.skipDuplicate(suggestedName: "a.txt", sourceHost: nil, source: nil, isPrivate: true))
        XCTAssertTrue(p.failures.isEmpty, "a private download leaves no record")
        let k = coordinator(); k.duplicatePolicy = .keepBoth
        XCTAssertFalse(k.skipDuplicate(suggestedName: "a.txt", sourceHost: nil, source: nil, isPrivate: false))
    }

    func testReplaceNeverLosesTheOldFileOutright() throws {
        let existing = folder.appendingPathComponent("a.txt")
        try Data("old".utf8).write(to: existing)
        let c = coordinator()
        c.duplicatePolicy = .replace
        let started = c.begin(suggestedName: "a.txt", cancel: {})
        // Replace no longer touches the old file when the download starts: the new one is written to a place of its own and takes the name (the old one going to the Trash) only once
        // it is finished and checked, so a failed or cancelled download costs nothing.
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "old", "the old file is untouched until the new one is complete")
        XCTAssertNotEqual(started.destination.deletingLastPathComponent().standardizedFileURL, folder.standardizedFileURL, "the new download is written to its own place, not over the old file")
    }

    // MARK: Failures

    func testAFailureIsListedWithAReasonAndCanBeRetriedOrDismissed() {
        let c = coordinator()
        var started: [URL] = []
        c.starter = { started.append($0) }
        let source = URL(string: "https://x.test/big.zip")!
        c.fail(nil, filename: "big.zip", source: source, error: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut), willRetry: false)
        let f = try! XCTUnwrap(c.failures.first)
        XCTAssertEqual(f.filename, "big.zip"); XCTAssertEqual(f.reason, "The server took too long to answer."); XCTAssertTrue(f.canRetry)
        c.retryFailure(f.id)
        XCTAssertEqual(started, [source]); XCTAssertTrue(c.failures.isEmpty, "it left the list when it was tried again")
        c.fail(nil, filename: "x", source: nil, error: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError), willRetry: false)
        XCTAssertEqual(c.failures.first?.reason, "There is not enough space on the disk.")
        XCTAssertEqual(c.failures.first?.canRetry, false, "nothing to start it from")
        c.dismissFailure(try! XCTUnwrap(c.failures.first).id)
        XCTAssertTrue(c.failures.isEmpty)
    }

    func testAPlannedRetryAndAPrivateDownloadAreNotReportedAsFailures() {
        let c = coordinator()
        let err = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
        c.fail(nil, filename: "a", source: nil, error: err, willRetry: true)
        c.fail(nil, filename: "secret", source: URL(string: "https://x.test/s"), error: err, willRetry: false, isPrivate: true)
        XCTAssertTrue(c.failures.isEmpty)
        XCTAssertFalse(c.diagnostics.contains("secret"), "a private download is not named even in the log")
    }

    func testTheListOfFailuresIsBounded() {
        let c = coordinator()
        for i in 0..<(DownloadFailure.limit + 20) { c.fail(nil, filename: "f\(i)", source: nil, error: NSError(domain: "x", code: 1), willRetry: false) }
        XCTAssertEqual(c.failures.count, DownloadFailure.limit)
        XCTAssertEqual(c.failures.first?.filename, "f\(DownloadFailure.limit + 19)", "newest first")
    }

    func testPieceTroubleFallsBackToAPlainDownloadOnce() {
        let c = coordinator()
        var started: [URL] = []
        c.starter = { started.append($0) }
        let source = URL(string: "https://x.test/big.iso")!
        c.fallBackToPlainDownload(source)
        XCTAssertEqual(started, [source])
        XCTAssertTrue(c.noPieces.contains(source.absoluteString), "and the pieces are not tried for it again")
    }

    // MARK: Resuming safely

    func testAResumeWithNoPageToUseKeepsTheDownloadOnTheList() throws {
        let c = coordinator()
        c.store = folder.appendingPathComponent("store")
        let started = c.begin(suggestedName: "a.zip", cancel: {})
        let id = started.id
        c.interrupt(id, resumeData: Data("resume".utf8), source: URL(string: "https://x.test/a.zip"))
        var resumed = false
        c.resumer = { _ in resumed = true }
        c.hasHost = { false }
        c.resume(id)
        XCTAssertFalse(resumed)
        XCTAssertNotNil(c.interrupted[id], "still there, with its Resume button")
        c.hasHost = { true }
        c.resume(id)
        XCTAssertTrue(resumed); XCTAssertNil(c.interrupted[id])
    }

    func testScheduledDownloadsWaitWhenThereIsNoPageToStartThemFrom() async {
        let c = coordinator()
        var started: [URL] = []
        c.starter = { started.append($0) }
        c.holdQueue(until: Date().addingTimeInterval(3600))
        let source = URL(string: "https://x.test/s.zip")!
        let go = await c.admit(filename: "s.zip", source: source)
        XCTAssertFalse(go, "put off until later")
        XCTAssertEqual(c.scheduled.count, 1)
        c.hasHost = { false }
        c.startScheduledNow()
        XCTAssertTrue(started.isEmpty)
        XCTAssertEqual(c.scheduled.count, 1, "kept, not used up")
        c.hasHost = { true }
        c.startScheduledNow()
        XCTAssertEqual(started, [source])
        XCTAssertTrue(c.scheduled.isEmpty)
    }

    // MARK: Leftovers

    func testOnlyOldHiddenPieceFoldersAreRemoved() throws {
        let fm = FileManager.default
        let old = folder.appendingPathComponent(".big.zip.parts", isDirectory: true)
        let fresh = folder.appendingPathComponent(".new.zip.parts", isDirectory: true)
        let real = folder.appendingPathComponent("Documents", isDirectory: true)
        let hidden = folder.appendingPathComponent(".config", isDirectory: true)
        for d in [old, fresh, real, hidden] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        try Data("piece".utf8).write(to: old.appendingPathComponent("0"))
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 86_400)], ofItemAtPath: old.path)
        let removed = coordinator().removeStalePieceFolders(in: folder)
        XCTAssertEqual(removed, 1)
        XCTAssertFalse(fm.fileExists(atPath: old.path))
        XCTAssertTrue(fm.fileExists(atPath: fresh.path), "a recent one may belong to a download that is still running")
        XCTAssertTrue(fm.fileExists(atPath: real.path) && fm.fileExists(atPath: hidden.path), "nothing else is touched")
    }

    // MARK: Nothing is opened for you

    func testNoDownloadPathOpensAFileByItself() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let download = try String(contentsOf: root.appendingPathComponent("Shared/DownloadCoordinator.swift"), encoding: .utf8)
        let model = try String(contentsOf: root.appendingPathComponent("Shared/BrowserModel.swift"), encoding: .utf8)
        let engine = try String(contentsOf: root.appendingPathComponent("Engines/WebKit/WebKitEngine.swift"), encoding: .utf8)
        let delegateStart = engine.range(of: "final class WebKitDownloads")?.lowerBound ?? engine.startIndex
        let forbidden = ["NSWorkspace.shared.open(", "NSWorkspace.shared.openFile", "DownloadedFiles.open(", "UIApplication.shared.open(", "QLPreviewController", "UIDocumentInteractionController"]
        for (name, text) in [("DownloadCoordinator", download), ("WebKitDownloads", String(engine[delegateStart...]))] {
            for word in forbidden { XCTAssertFalse(text.contains(word), "\(name) must not call \(word)") }
        }
        // The one thing finishing does besides noting it: a PDF the person asked to edit opens in the editor. Everything else waits for a button.
        let finish = try XCTUnwrap(model.range(of: "engine.downloads.onFinished = "))
        let handler = String(model[finish.lowerBound...].prefix(1800))
        XCTAssertTrue(handler.contains("openFinishedPDFIfWanted"))
        XCTAssertFalse(handler.contains("DownloadedFiles.open"), "a pass, contact or event is added by a button, not on arrival")
        XCTAssertFalse(handler.contains("NSWorkspace"))
    }

    func testTheAnswerToWhyADownloadFailedIsNeverTheRawError() {
        for error: Error in [NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet), NSError(domain: "weird", code: 42), PieceDownloadError.wrongSize, PieceDownloadError.failed("x")] {
            let reason = DownloadCoordinator.reason(for: error)
            XCTAssertFalse(reason.contains("Error Domain") || reason.contains("NSURL"), reason)
            XCTAssertTrue(reason.hasSuffix("."))
        }
    }
}
