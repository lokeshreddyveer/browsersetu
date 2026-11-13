import XCTest
@testable import Browser_Setu

/// Adversarial cases for the two post-release corrections: (1) removing a download before / while / without its older-history line being loaded, in any window and after a relaunch;
/// (2) which Vimeo and Facebook addresses count as video pages. Existing coverage is untouched; these only add.
@MainActor
final class DownloadHistoryRaceTests: XCTestCase {
    private let when = Int64(1_794_412_146)
    private func suite() -> UserDefaults { UserDefaults(suiteName: "bs.hardening.\(UUID().uuidString)")! }

    private func completedTask(_ c: DownloadCoordinator, name: String, url: String, finishedAt: Int64) -> UUID {
        let r = c.ledger.create(protocolID: .http, source: URL(string: url), filename: name, isPrivate: false)
        for e in [DownloadEvent.queued, .started, .running, .verifying, .completed(.verified)] { _ = c.ledger.apply(e, to: r.id) }
        c.ledger.update(r.id) { $0.completedAt = Date(timeIntervalSince1970: TimeInterval(finishedAt)) }
        return r.id
    }
    private func model(_ c: DownloadCoordinator, _ defaults: UserDefaults, _ entries: [(url: String, filename: String, created: Int64)]) -> DownloadsViewModel {
        DownloadsViewModel(coordinator: c, legacy: { limit in Array(entries.prefix(Int(limit))) }, defaults: defaults)
    }
    private func settle(_ vm: DownloadsViewModel) async throws { try await Task.sleep(nanoseconds: 350_000_000); vm.refreshNow() }
    private func names(_ vm: DownloadsViewModel) -> [String] { vm.rows.filter(\.isLegacy).map(\.filename).sorted() }

    func testRemovingBeforeTheOlderHistoryHasLoadedStillHidesItsLine() async throws {
        let d = suite(), c = DownloadCoordinator()
        let id = completedTask(c, name: "watch.html", url: "https://youtu.be/zrnciBMFlzI", finishedAt: when)
        let entries = [(url: "https://youtu.be/zrnciBMFlzI", filename: "watch.html", created: when), (url: "https://example.org/other.zip", filename: "other.zip", created: when - 9_000)]
        let vm = model(c, d, entries)
        vm.refreshNow()                                                   // the older history has NOT loaded yet
        XCTAssertEqual(vm.perform(.removeRecord, on: [id]), 1)           // removed first ...
        vm.loadLegacy(); try await settle(vm)                             // ... loaded afterwards
        XCTAssertEqual(names(vm), ["other.zip"], "the removed download's older line must not appear once the history loads")
    }

    func testALineOnAPageThatLoadsLaterIsStillHidden() async throws {
        let d = suite(), c = DownloadCoordinator()
        let id = completedTask(c, name: "old-one.zip", url: "https://example.org/old-one.zip", finishedAt: when - 100_000)
        // 450 newer lines come first; the removed download's line is number 451, beyond the first page.
        var entries: [(url: String, filename: String, created: Int64)] = (0..<450).map { (url: "https://example.org/n\($0).zip", filename: "n\($0).zip", created: when - Int64($0)) }
        entries.append((url: "https://example.org/old-one.zip", filename: "old-one.zip", created: when - 100_000))
        let vm = model(c, d, entries)
        vm.loadLegacy(); try await settle(vm)
        XCTAssertFalse(names(vm).contains("old-one.zip"), "not loaded yet")
        XCTAssertEqual(vm.perform(.removeRecord, on: [id]), 1)
        vm.loadMoreHistory(); vm.loadMoreHistory(); try await settle(vm)
        XCTAssertFalse(names(vm).contains("old-one.zip"), "its line arrived on a later page and must stay hidden")
        XCTAssertTrue(names(vm).contains("n0.zip"), "unrelated lines are untouched")
    }

    func testTwoWindowsRemovingDifferentDownloadsBothHold() async throws {
        let d = suite(), c = DownloadCoordinator()
        let a = completedTask(c, name: "a.zip", url: "https://example.org/a.zip", finishedAt: when)
        let b = completedTask(c, name: "b.zip", url: "https://example.org/b.zip", finishedAt: when + 1_000)
        let entries = [(url: "https://example.org/a.zip", filename: "a.zip", created: when), (url: "https://example.org/b.zip", filename: "b.zip", created: when + 1_000), (url: "https://example.org/c.zip", filename: "c.zip", created: when + 2_000)]
        let windowA = model(c, d, entries), windowB = model(c, d, entries)
        windowA.refreshNow(); windowB.refreshNow()
        XCTAssertEqual(windowA.perform(.removeRecord, on: [a]), 1)
        XCTAssertEqual(windowB.perform(.removeRecord, on: [b]), 1)       // B started before A removed anything
        for w in [windowA, windowB] { w.loadLegacy() }
        try await Task.sleep(nanoseconds: 400_000_000); windowA.refreshNow(); windowB.refreshNow()
        XCTAssertEqual(names(windowA), ["c.zip"], "window A sees B's removal too, after it refreshes"); XCTAssertEqual(names(windowB), ["c.zip"])
        let relaunched = model(c, d, entries); relaunched.loadLegacy(); try await settle(relaunched)
        XCTAssertEqual(names(relaunched), ["c.zip"], "and a relaunch keeps both")
    }

    func testConcurrentRemovalAndLoadingInEveryOrder() async throws {
        for order in 0..<3 {
            let d = suite(), c = DownloadCoordinator()
            let id = completedTask(c, name: "x.zip", url: "https://example.org/x.zip", finishedAt: when)
            let entries = [(url: "https://example.org/x.zip", filename: "x.zip", created: when), (url: "https://example.org/keep.zip", filename: "keep.zip", created: when - 5_000)]
            let vm = model(c, d, entries)
            switch order {
            case 0: vm.loadLegacy(); vm.perform(.removeRecord, on: [id])          // load and removal started together
            case 1: vm.perform(.removeRecord, on: [id]); vm.loadLegacy()          // removal first
            default: vm.loadLegacy(); try await Task.sleep(nanoseconds: 300_000_000); vm.refreshNow(); vm.perform(.removeRecord, on: [id])   // load finished first
            }
            try await settle(vm)
            XCTAssertEqual(names(vm), ["keep.zip"], "order \(order)")
        }
    }

    func testNearMissesAreNotHidden() async throws {
        let d = suite(), c = DownloadCoordinator()
        let id = completedTask(c, name: "f.zip", url: "https://example.org/f.zip?token=SECRET", finishedAt: when)
        let entries = [
            (url: "https://example.org/f.zip", filename: "f.zip", created: when + 60),            // within a minute: the twin
            (url: "https://example.org/f.zip", filename: "f.zip", created: when + 61),            // one second too late: a different download
            (url: "https://example.org/f.zip", filename: "f.zip", created: when + 86_400),        // downloaded again another day
            (url: "https://example.org/g.zip", filename: "f.zip", created: when),                 // same name, other address
            (url: "https://example.org/f.zip", filename: "F.zip", created: when),                 // same address, other name (case differs)
            (url: "https://other.example.org/f.zip", filename: "f.zip", created: when)]           // same path, other host
        let vm = model(c, d, entries); vm.refreshNow()
        XCTAssertEqual(vm.perform(.removeRecord, on: [id]), 1)
        vm.loadLegacy(); try await settle(vm)
        let shown = vm.rows.filter(\.isLegacy)
        XCTAssertEqual(shown.count, 5, "only the one twin is hidden; every near miss stays listed")
        XCTAssertFalse(shown.contains { Int($0.date.timeIntervalSince1970) == Int(when + 60) }, "the twin (60 s after it finished) is hidden")
        XCTAssertTrue(shown.contains { Int($0.date.timeIntervalSince1970) == Int(when + 61) }, "61 s is a different download")
    }

    func testFailedOrCancelledTasksHideNothing() async throws {
        let d = suite(), c = DownloadCoordinator()
        let r = c.ledger.create(protocolID: .http, source: URL(string: "https://example.org/z.zip"), filename: "z.zip", isPrivate: false)
        for e in [DownloadEvent.queued, .started, .failed(DownloadFailureInfo(code: "http-404", reason: "x", retryable: true))] { _ = c.ledger.apply(e, to: r.id) }
        let vm = model(c, d, [(url: "https://example.org/z.zip", filename: "z.zip", created: when)])
        vm.refreshNow(); XCTAssertEqual(vm.perform(.removeRecord, on: [r.id]), 1)
        vm.loadLegacy(); try await settle(vm)
        XCTAssertEqual(names(vm), ["z.zip"], "a failed task is not a finished download: its older line, if any, is a different thing and stays")
    }

    /// Counts how often the hidden-line lists are written to the settings store.
    private final class CountingDefaults: UserDefaults {
        var writes: [String: Int] = [:]
        override func set(_ value: Any?, forKey defaultName: String) { writes[defaultName, default: 0] += 1; super.set(value, forKey: defaultName) }
    }

    func testClearingManyDownloadsWritesTheHiddenRulesOnceAndKeepsEveryRule() async throws {
        let d = CountingDefaults(suiteName: "bs.hardening.\(UUID().uuidString)")!, c = DownloadCoordinator()
        let n = 550          // the list shows at most DownloadRowProjector.maxRows completed rows; this is a full window's worth
        var entries: [(url: String, filename: String, created: Int64)] = []
        for i in 0..<n {
            _ = completedTask(c, name: "bulk\(i).zip", url: "https://example.org/bulk\(i).zip", finishedAt: when + Int64(i) * 120)
            entries.append((url: "https://example.org/bulk\(i).zip", filename: "bulk\(i).zip", created: when + Int64(i) * 120))
        }
        let vm = DownloadsViewModel(coordinator: c, legacy: { limit in Array(entries.prefix(Int(limit))) }, defaults: d); vm.refreshNow()
        let ids = Set(vm.rows.filter { !$0.isLegacy }.map(\.id))
        XCTAssertEqual(ids.count, n, "every task is in the list, so all of them can be removed in one action")
        d.writes = [:]
        let began = Date()
        XCTAssertEqual(vm.perform(.removeRecord, on: ids), n)
        let took = Date().timeIntervalSince(began)
        XCTAssertEqual(d.writes["downloads.legacyHiddenTwins"], 1, "one bulk removal writes the stored rules once, not once per entry")
        XCTAssertLessThan(took, 10, "took \(took) s")
        vm.loadLegacy(); vm.loadMoreHistory(); vm.loadMoreHistory(); try await settle(vm)
        XCTAssertTrue(names(vm).isEmpty, "every older line is hidden")
        let relaunched = DownloadsViewModel(coordinator: DownloadCoordinator(), legacy: { limit in Array(entries.prefix(Int(limit))) }, defaults: d)
        relaunched.loadLegacy(); relaunched.loadMoreHistory(); relaunched.loadMoreHistory(); try await settle(relaunched)
        XCTAssertTrue(names(relaunched).isEmpty, "and all \(n) rules survive a relaunch")
    }

    func testAFileNameContainingTheStorageSeparatorRoundTrips() async throws {
        let d = suite(), c = DownloadCoordinator()
        let name = "odd\u{1F}name|https://x.test/a\u{1F}.zip"
        let id = completedTask(c, name: name, url: "https://example.org/odd.zip", finishedAt: when)
        let entries = [(url: "https://example.org/odd.zip", filename: name, created: when), (url: "https://example.org/odd.zip", filename: "odd.zip", created: when)]
        let vm = model(c, d, entries); vm.refreshNow()
        XCTAssertEqual(vm.perform(.removeRecord, on: [id]), 1)
        let relaunched = model(DownloadCoordinator(), d, entries); relaunched.loadLegacy(); try await settle(relaunched)
        XCTAssertEqual(names(relaunched), ["odd.zip"], "the odd name's line is hidden after a relaunch and the plain one is not")
    }

    func testTheStoredRulesAreCappedAndTheOldestAreForgottenFirst() async throws {
        DownloadsViewModel.hiddenLimitOverride = 3; defer { DownloadsViewModel.hiddenLimitOverride = nil }
        let d = suite(), c = DownloadCoordinator()
        var entries: [(url: String, filename: String, created: Int64)] = []; var ids: [UUID] = []
        for i in 0..<5 {
            ids.append(completedTask(c, name: "t\(i).zip", url: "https://example.org/t\(i).zip", finishedAt: when + Int64(i) * 1_000))
            entries.append((url: "https://example.org/t\(i).zip", filename: "t\(i).zip", created: when + Int64(i) * 1_000))
        }
        let vm = model(c, d, entries); vm.refreshNow()
        for id in ids { XCTAssertEqual(vm.perform(.removeRecord, on: [id]), 1) }      // t0 first, t4 last
        let relaunched = model(DownloadCoordinator(), d, entries); relaunched.loadLegacy(); try await settle(relaunched)
        XCTAssertEqual(names(relaunched), ["t0.zip", "t1.zip"], "only the newest three rules are kept")
    }

    func testAStaleWindowSeesARuleAnotherWindowStoredWithoutReloading() async throws {
        let d = suite(), c = DownloadCoordinator()
        let id = completedTask(c, name: "s.zip", url: "https://example.org/s.zip", finishedAt: when)
        let entries = [(url: "https://example.org/s.zip", filename: "s.zip", created: when)]
        let stale = model(DownloadCoordinator(), d, entries); stale.loadLegacy(); try await settle(stale)
        XCTAssertEqual(names(stale), ["s.zip"], "nothing removed yet, so the line is listed")   // the older line is shown because no task describes it here
        let other = model(c, d, entries); other.refreshNow()
        XCTAssertEqual(other.perform(.removeRecord, on: [id]), 1)
        stale.refreshNow()
        XCTAssertTrue(names(stale).isEmpty, "the stale window picks up the other window's removal on its next refresh")
    }

    func testAMissingDefaultsStoreStillWorksInMemory() async throws {
        let c = DownloadCoordinator()
        let id = completedTask(c, name: "m.zip", url: "https://example.org/m.zip", finishedAt: when)
        let vm = DownloadsViewModel(coordinator: c, legacy: { _ in [(url: "https://example.org/m.zip", filename: "m.zip", created: self.when)] }, defaults: nil)
        vm.refreshNow(); XCTAssertEqual(vm.perform(.removeRecord, on: [id]), 1)
        vm.loadLegacy(); try await settle(vm)
        XCTAssertTrue(names(vm).isEmpty)
    }
}

final class ProviderStructureTests: XCTestCase {
    private func page(_ s: String) -> Bool { ProviderRecognizer.isVideoPage(URL(string: s)!) }

    func testRealVimeoVideoShapesAreVideoPages() {
        for s in ["https://vimeo.com/76979871", "https://www.vimeo.com/76979871", "https://vimeo.com/channels/staffpicks/76979871", "https://vimeo.com/groups/abc/videos/123456",
                  "https://vimeo.com/album/55/video/123456", "https://vimeo.com/showcase/55/video/123456", "https://vimeo.com/ondemand/somefilm/123456", "https://vimeo.com/76979871/abcdef1234"] {
            XCTAssertTrue(page(s), s)
        }
    }

    func testVimeoAddressesThatOnlyContainANumberAreNotVideoPages() {
        for s in ["https://vimeo.com/blog/2024", "https://vimeo.com/help/article/360000", "https://vimeo.com/user12345", "https://vimeo.com/settings/123", "https://vimeo.com/channels/staffpicks",
                  "https://vimeo.com/channels/staffpicks/videos", "https://vimeo.com/123/settings/extra", "https://vimeo.com/stock/clip/12345", "https://developer.vimeo.com/api/videos/123",
                  "https://api.vimeo.com/videos/123", "https://vimeo.com/\u{0661}\u{0662}\u{0663}", "https://vimeo.com.evil.net/76979871", "https://vimeo.com@evil.example/76979871", "https://vimeo.com/76979871.mp4"] {
            XCTAssertFalse(page(s), s)
        }
    }

    func testRealFacebookVideoShapesAreVideoPages() {
        for s in ["https://www.facebook.com/watch/?v=1234567890", "https://facebook.com/somepage/videos/1234567890", "https://www.facebook.com/somepage/videos/a-title-slug/1234567890/",
                  "https://m.facebook.com/somepage/videos/1234567890", "https://www.facebook.com/groups/mygroup/videos/1234567890", "https://www.facebook.com/reel/1234567890", "https://fb.watch/abcDEF12/"] {
            XCTAssertTrue(page(s), s)
        }
    }

    func testFacebookAddressesThatMerelyContainVideosAreNotVideoPages() {
        for s in ["https://www.facebook.com/videos/1234567890", "https://www.facebook.com/help/videos/1234567890", "https://www.facebook.com/marketplace/videos/12345678", "https://www.facebook.com/policies/videos/12345678",
                  "https://developers.facebook.com/docs/videos/1234567890", "https://about.facebook.com/videos/1234567890", "https://www.facebook.com/somepage/videos/", "https://www.facebook.com/somepage/videos/notanumber",
                  "https://www.facebook.com/somepage/videos/12/", "https://www.facebook.com/somepage/photos/1234567890", "https://www.facebook.com/a/b/videos/1234567890", "https://l.facebook.com/l.php?u=https%3A%2F%2Fexample.com",
                  "https://www.facebook.com/groups/mygroup/videos/notanumber", "https://facebook.com.evil.net/somepage/videos/1234567890"] {
            XCTAssertFalse(page(s), s)
        }
    }

    func testVimeoPrivateLinkReviewAndManagementFormsAreVideoPagesButNeighbouringPagesAreNot() {
        for s in ["https://vimeo.com/76979871/abcdef0123", "https://vimeo.com/someowner/review/76979871/abcdef0123", "https://vimeo.com/manage/videos/76979871"] { XCTAssertTrue(page(s), s) }
        for s in ["https://vimeo.com/76979871/settings", "https://vimeo.com/76979871/comments", "https://vimeo.com/76979871/download", "https://vimeo.com/76979871/privacy",
                  "https://vimeo.com/76979871/ABCDEF0123", "https://vimeo.com/someowner/review/76979871", "https://vimeo.com/manage/videos", "https://vimeo.com/manage/settings/76979871"] { XCTAssertFalse(page(s), s) }
    }

    func testFacebookLanguageHostsAndTheLegacyPagesFormAreVideoPages() {
        for s in ["https://en-gb.facebook.com/somepage/videos/1234567890", "https://de.facebook.com/somepage/videos/1234567890", "https://pt-br.facebook.com/somepage/videos/1234567890",
                  "https://www.facebook.com/pages/Some-Name/123456789/videos/987654321", "https://free.facebook.com/somepage/videos/1234567890"] { XCTAssertTrue(page(s), s) }
        for s in ["https://xx-yy-zz.facebook.com/somepage/videos/1234567890", "https://developers.facebook.com/somepage/videos/1234567890", "https://EN-GB.facebook.com.evil.net/somepage/videos/1234567890",
                  "https://www.facebook.com/pages/Some-Name/notdigits/videos/987654321", "https://www.facebook.com/pages/Some-Name/123456789/videos/", "https://www.facebook.com/pages/videos/987654321"] { XCTAssertFalse(page(s), s) }
    }

    func testDirectFilesAndEmbedsStayOutOfTheVideoFlow() {
        XCTAssertFalse(page("https://player.vimeo.com/video/76979871"), "an embed is not a page to open")
        XCTAssertFalse(page("https://v.redd.it/abcde1/DASH_720.mp4"))
        XCTAssertFalse(page("https://www.youtube.com/embed/zrnciBMFlzI"))
        XCTAssertTrue(page("https://www.youtube.com/watch?v=zrnciBMFlzI"))
    }

    func testAddressesTheRecognizerNoLongerClaimsAreLeftToTheServerAndThePerson() {
        // Not a video page by structure: the Add form asks the server what it is (a web page gets an explicit choice), so intent decides, not the host name.
        let blog = URL(string: "https://vimeo.com/blog/2024")!
        XCTAssertTrue(AddressClassifier.worthProbing(blog))
        XCTAssertEqual(AddressClassifier.classify(blog, contentType: "text/html"), .webPage)
        XCTAssertEqual(AddressClassifier.classify(blog, contentType: "application/zip"), .file)
        XCTAssertEqual(AddressClassifier.classify(blog), .file, "no answer: saved as it always was")
        XCTAssertEqual(AddressClassifier.classify(blog, contentType: "text/html", finalURL: URL(string: "https://vimeo.com/76979871")!), .videoPage, "a redirect that ends on a real video page")
    }
}
