import XCTest
@testable import Browser_Setu

/// Reported after 0.4.2: entries of the older downloads history could not be removed, and a YouTube link in "Add a download" saved the page's HTML.
@MainActor
final class PostReleaseFixesTests: XCTestCase {
    func testVideoPagesAreRecognisedAndFilesAreNot() {
        for s in ["https://youtu.be/zrnciBMFlzI", "https://www.youtube.com/watch?v=zrnciBMFlzI", "https://www.youtube.com/shorts/abcdefghijk"] {
            XCTAssertTrue(ProviderRecognizer.isVideoPage(URL(string: s)!), s)
        }
        for s in ["https://example.org/file.zip", "https://example.org/clip.mp4", "https://www.youtube.com/", "https://example.org/page.html"] {
            XCTAssertFalse(ProviderRecognizer.isVideoPage(URL(string: s)!), s)
        }
    }

    func testAnOlderHistoryRowCanBeRemovedFromTheList() {
        let entry = DownloadLegacyHistory.Entry(url: "https://youtu.be/zrnciBMFlzI", filename: "watch.html", created: Date(timeIntervalSince1970: 1_794_412_146))
        let row = DownloadLegacyHistory.row(for: entry) { _ in false }
        XCTAssertTrue(row.actions.contains(.removeRecord), "an entry whose file is gone must still be removable")
        XCTAssertTrue(row.isLegacy)
        let found = DownloadLegacyHistory.row(for: entry) { _ in true }
        XCTAssertTrue(found.actions.contains(.removeRecord) && found.actions.contains(.open))
    }

    func testRemovingAnOlderHistoryRowIsRememberedAndNeverTouchesTheFile() async throws {
        let suite = UserDefaults(suiteName: "bs.postrelease.\(UUID().uuidString)")!
        let entries = [DownloadLegacyHistory.Entry(url: "https://youtu.be/zrnciBMFlzI", filename: "watch.html", created: Date(timeIntervalSince1970: 1_794_412_146)),
                       DownloadLegacyHistory.Entry(url: "https://www.youtube.com/watch?v=zrnciBMFlzI", filename: "watch (1).html", created: Date(timeIntervalSince1970: 1_794_412_181))]
        let coordinator = DownloadCoordinator()
        func makeModel() -> DownloadsViewModel {
            DownloadsViewModel(coordinator: coordinator, legacy: { _ in entries.map { (url: $0.url, filename: $0.filename, created: Int64($0.created.timeIntervalSince1970)) } }, defaults: suite)
        }
        let vm = makeModel(); vm.loadLegacy()
        try await Task.sleep(nanoseconds: 400_000_000)
        vm.refreshNow()
        XCTAssertEqual(vm.rows.filter(\.isLegacy).count, 2)
        let first = try XCTUnwrap(vm.rows.first { $0.isLegacy && $0.filename == "watch.html" })
        XCTAssertEqual(vm.perform(.removeRecord, on: [first.id]), 1)
        vm.refreshNow()
        XCTAssertEqual(vm.rows.filter(\.isLegacy).map(\.filename), ["watch (1).html"])
        // A new window (a new model on the same settings) still does not show it.
        let again = makeModel(); again.loadLegacy()
        try await Task.sleep(nanoseconds: 400_000_000)
        again.refreshNow()
        XCTAssertEqual(again.rows.filter(\.isLegacy).map(\.filename), ["watch (1).html"])
    }

    // MARK: What an address is: site support, redirects, content type; never the ending alone

    func testClassifierUsesSiteSupportRedirectsAndContentTypeNotTheEnding() {
        func u(_ s: String) -> URL { URL(string: s)! }
        XCTAssertEqual(AddressClassifier.classify(u("https://youtu.be/zrnciBMFlzI")), .videoPage, "a known video site needs no network question")
        XCTAssertEqual(AddressClassifier.classify(u("https://short.example/abc"), contentType: "text/html", finalURL: u("https://www.youtube.com/watch?v=zrnciBMFlzI")), .videoPage, "a link that ends on a video page")
        XCTAssertEqual(AddressClassifier.classify(u("https://example.org/article"), contentType: "text/html; charset=utf-8"), .webPage, "a web page of an unfamiliar site is the person's choice")
        XCTAssertEqual(AddressClassifier.classify(u("https://example.org/watch.html"), contentType: "video/mp4"), .file, "the server says it is a video: the .html ending is only a name")
        XCTAssertEqual(AddressClassifier.classify(u("https://example.org/get?id=7"), contentType: "application/zip"), .file)
        XCTAssertEqual(AddressClassifier.classify(u("https://example.org/get?id=7")), .file, "not asked or no answer: saved as it always was")
        XCTAssertEqual(AddressClassifier.classify(u("https://example.org/page"), contentType: "application/xhtml+xml"), .webPage)
        XCTAssertEqual(AddressClassifier.mediaType("Text/HTML ; charset=UTF-8"), "text/html")
        XCTAssertNil(AddressClassifier.mediaType("garbage")); XCTAssertNil(AddressClassifier.mediaType(nil))
    }

    func testOnlyAddressesThatMayBePagesAreWorthAskingAbout() {
        func u(_ s: String) -> URL { URL(string: s)! }
        for s in ["https://example.org/", "https://example.org/article", "https://example.org/page.html", "https://example.org/index.php?x=1"] { XCTAssertTrue(AddressClassifier.worthProbing(u(s)), s) }
        for s in ["https://example.org/file.zip", "https://example.org/clip.mp4", "https://youtu.be/zrnciBMFlzI", "ftp://example.org/x", "magnet:?xt=urn:btih:abc"] { XCTAssertFalse(AddressClassifier.worthProbing(u(s)), s) }
    }

    // MARK: Video pages and the optional tool

    func testAVideoPageWithNoToolOffersTheInstallInsteadOfSavingAFile() {
        let page = URL(string: "https://www.youtube.com/watch?v=zrnciBMFlzI")!
        let none = RouterContext(isPrivate: false, extractorConfigured: false), have = RouterContext(isPrivate: false, extractorConfigured: true), priv = RouterContext(isPrivate: true, extractorConfigured: true)
        XCTAssertEqual(DownloadRouter.route(.videoPage(page, provider: .youtube), none), .unresolved(.extractorOff), "the sheet shows the consent-first install offer for exactly this answer")
        XCTAssertEqual(DownloadRouter.route(.videoPage(page, provider: .youtube), have), .extractor(page: page))
        XCTAssertEqual(DownloadRouter.route(.videoPage(page, provider: .youtube), priv), .unresolved(.privateTab), "never in a private tab")
        let unfamiliar = URL(string: "https://videos.example.org/watch/42")!
        XCTAssertEqual(DownloadRouter.route(.videoPage(unfamiliar, provider: .generic), have), .extractor(page: unfamiliar), "an unsupported site is asked about by the extractor, which says plainly if it cannot read it")
    }

    // MARK: Older history: removal, twins, persistence, isolation

    private func completedTask(_ c: DownloadCoordinator, name: String, url: String, finishedAt: Date) -> UUID {
        let r = c.ledger.create(protocolID: .http, source: URL(string: url), filename: name, isPrivate: false)
        for e in [DownloadEvent.queued, .started, .running, .verifying, .completed(.verified)] { _ = c.ledger.apply(e, to: r.id) }
        c.ledger.update(r.id) { $0.completedAt = finishedAt }
        return r.id
    }

    func testRemovingATaskDoesNotBringItsOlderHistoryLineBack() async throws {
        let when = Date(timeIntervalSince1970: 1_794_412_146)
        let suite = UserDefaults(suiteName: "bs.postrelease.\(UUID().uuidString)")!
        let c = DownloadCoordinator()
        let mine = completedTask(c, name: "watch.html", url: "https://youtu.be/zrnciBMFlzI", finishedAt: when)
        let other = completedTask(c, name: "report.pdf", url: "https://example.org/report.pdf", finishedAt: when)
        let entries = [(url: "https://youtu.be/zrnciBMFlzI", filename: "watch.html", created: Int64(when.timeIntervalSince1970)),
                       (url: "https://example.org/report.pdf", filename: "report.pdf", created: Int64(when.timeIntervalSince1970)),
                       (url: "https://example.org/old.zip", filename: "old.zip", created: Int64(when.timeIntervalSince1970) - 9_999)]
        func make() -> DownloadsViewModel { DownloadsViewModel(coordinator: c, legacy: { _ in entries }, defaults: suite) }
        let vm = make(); vm.loadLegacy(); try await Task.sleep(nanoseconds: 400_000_000); vm.refreshNow()
        XCTAssertEqual(vm.rows.filter(\.isLegacy).map(\.filename), ["old.zip"], "lines the tasks already describe are hidden")
        XCTAssertEqual(vm.perform(.removeRecord, on: [mine]), 1)
        vm.refreshNow()
        XCTAssertNil(c.ledger.record(mine), "the task is gone")
        XCTAssertNotNil(c.ledger.record(other), "an unrelated record is untouched")
        XCTAssertEqual(Set(vm.rows.filter(\.isLegacy).map(\.filename)), ["old.zip"], "its older line must not appear in its place")
        let fresh = make(); fresh.loadLegacy(); try await Task.sleep(nanoseconds: 400_000_000); fresh.refreshNow()
        XCTAssertEqual(Set(fresh.rows.filter(\.isLegacy).map(\.filename)), ["old.zip"], "and it stays gone after a relaunch")
        XCTAssertTrue(fresh.rows.contains { $0.filename == "report.pdf" }, "the other download is still listed")
    }

    func testRemovingOneOfTwoLinesForTheSameFileKeepsTheOtherAndNeverTouchesTheFiles() async throws {
        let when = Date(timeIntervalSince1970: 1_794_412_146)
        let suite = UserDefaults(suiteName: "bs.postrelease.\(UUID().uuidString)")!
        // Two lines for one file name (the same page saved twice, minutes apart): distinct entries, removed one at a time.
        let entries = [(url: "https://example.org/a", filename: "watch.html", created: Int64(when.timeIntervalSince1970)),
                       (url: "https://example.org/a", filename: "watch.html", created: Int64(when.timeIntervalSince1970) + 300)]
        let c = DownloadCoordinator()
        let active = c.ledger.create(protocolID: .http, source: URL(string: "https://example.org/big.bin"), filename: "big.bin", isPrivate: false)
        for e in [DownloadEvent.queued, .started, .running] { _ = c.ledger.apply(e, to: active.id) }
        let vm = DownloadsViewModel(coordinator: c, legacy: { _ in entries }, defaults: suite)
        vm.loadLegacy(); try await Task.sleep(nanoseconds: 400_000_000); vm.refreshNow()
        let lines = vm.rows.filter(\.isLegacy)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(vm.perform(.removeRecord, on: [lines[0].id]), 1)
        vm.refreshNow()
        XCTAssertEqual(vm.rows.filter(\.isLegacy).count, 1, "only the chosen line went")
        XCTAssertEqual(c.ledger.record(active.id)?.state, .running, "an active transfer is not affected")
        XCTAssertEqual(vm.perform(.removeRecord, on: [active.id]), 0, "a running download cannot be 'removed from the list'; it is cancelled instead")
        vm.refreshNow()
        XCTAssertEqual(c.ledger.record(active.id)?.state, .running)
    }

    func testAHistoryLineWhoseFileIsMissingCanStillBeRemoved() async throws {
        let entry = (url: "https://example.org/gone.zip", filename: "definitely-not-on-disk-\(UUID().uuidString).zip", created: Int64(1_794_412_146))
        let suite = UserDefaults(suiteName: "bs.postrelease.\(UUID().uuidString)")!
        let vm = DownloadsViewModel(coordinator: DownloadCoordinator(), legacy: { _ in [entry] }, defaults: suite)
        vm.loadLegacy(); try await Task.sleep(nanoseconds: 400_000_000); vm.refreshNow()
        let row = try XCTUnwrap(vm.rows.first { $0.isLegacy })
        XCTAssertFalse(row.actions.contains(.open), "the file is not there")
        XCTAssertEqual(vm.perform(.removeRecord, on: [row.id]), 1)
        vm.refreshNow()
        XCTAssertTrue(vm.rows.filter(\.isLegacy).isEmpty)
    }

    func testRemovingAHistoryLineLeavesTheRealFileOnDisk() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("postrelease-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let saved = DownloadCoordinator.directoryOverride; DownloadCoordinator.directoryOverride = dir
        defer { DownloadCoordinator.directoryOverride = saved; try? FileManager.default.removeItem(at: dir) }
        let name = "keep-me-\(UUID().uuidString).html"
        let file = dir.appendingPathComponent(name); try Data("<p>hi</p>".utf8).write(to: file)
        let suite = UserDefaults(suiteName: "bs.postrelease.\(UUID().uuidString)")!
        let entry = (url: "https://youtu.be/zrnciBMFlzI", filename: name, created: Int64(1_794_412_146))
        let vm = DownloadsViewModel(coordinator: DownloadCoordinator(), legacy: { _ in [entry] }, defaults: suite)
        vm.loadLegacy(); try await Task.sleep(nanoseconds: 400_000_000); vm.refreshNow()
        let row = try XCTUnwrap(vm.rows.first { $0.isLegacy })
        XCTAssertTrue(row.actions.contains(.open) && row.actions.contains(.removeRecord), "the file is found, and the entry can still be removed")
        XCTAssertEqual(vm.perform(.removeRecord, on: [row.id]), 1)
        vm.refreshNow()
        XCTAssertTrue(vm.rows.filter(\.isLegacy).isEmpty, "the line is gone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "the downloaded file is untouched")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "<p>hi</p>")
    }

    // MARK: Review follow-ups

    func testADirectFileOnAVideoSiteIsAFileNotAVideoPage() {
        XCTAssertFalse(ProviderRecognizer.isVideoPage(URL(string: "https://v.redd.it/abcde1/DASH_720.mp4")!), "a direct media file is a file")
        XCTAssertFalse(ProviderRecognizer.isVideoPage(URL(string: "https://example.org/watch.zip")!))
        XCTAssertTrue(ProviderRecognizer.isVideoPage(URL(string: "https://www.youtube.com/watch?v=zrnciBMFlzI")!), "a real watch page still is one")
        XCTAssertTrue(ProviderRecognizer.isVideoPage(URL(string: "https://youtu.be/zrnciBMFlzI")!))
    }

    func testTwoDownloadsWindowsDoNotUndoEachOthersRemovals() async throws {
        let suite = UserDefaults(suiteName: "bs.postrelease.\(UUID().uuidString)")!
        let when = Int64(1_794_412_146)
        let entries = [(url: "https://example.org/a", filename: "a.html", created: when), (url: "https://example.org/b", filename: "b.html", created: when + 5)]
        func make() -> DownloadsViewModel { DownloadsViewModel(coordinator: DownloadCoordinator(), legacy: { _ in entries }, defaults: suite) }
        let windowA = make(), windowB = make()
        for vm in [windowA, windowB] { vm.loadLegacy() }
        try await Task.sleep(nanoseconds: 400_000_000)
        windowA.refreshNow(); windowB.refreshNow()
        let a = try XCTUnwrap(windowA.rows.first { $0.filename == "a.html" }), b = try XCTUnwrap(windowB.rows.first { $0.filename == "b.html" })
        XCTAssertEqual(windowA.perform(.removeRecord, on: [a.id]), 1)      // window A removes a.html
        XCTAssertEqual(windowB.perform(.removeRecord, on: [b.id]), 1)      // window B (started before) removes b.html
        let later = make(); later.loadLegacy(); try await Task.sleep(nanoseconds: 400_000_000); later.refreshNow()
        XCTAssertTrue(later.rows.filter(\.isLegacy).isEmpty, "both removals persist; the later write did not overwrite the earlier one")
    }
}
