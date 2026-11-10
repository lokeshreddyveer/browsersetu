import XCTest
@testable import Browser_Setu

/// Whole-trip checks: what is saved comes back, nothing breaks with many tabs or many pages, and the work stays inside a time budget so a
/// change that makes the browser slower shows up here.
@MainActor
final class RoundTripAndBudgetTests: XCTestCase {
    private func model(_ root: String? = nil) -> BrowserModel {
        BrowserModel(engine: WebKitEngine(), root: root ?? NSTemporaryDirectory() + "bs-rt-\(UUID().uuidString)", profile: "default")
    }

    func testBackupCarriesTheNewSettingsToAnotherInstall() async throws {
        let a = model()
        await a.start()
        a.appLinkMode = .app
        a.setAppLinkSite("youtube.com", to: "app")
        a.setAppLinkSite("maps.apple.com", to: "browser")
        a.blurPrivateSwitcher = false
        let data = try a.makeBackup(passphrase: "pw", iterations: 1_000)

        let root = NSTemporaryDirectory() + "bs-rt-b-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let b = model(root)
        await b.start()
        XCTAssertEqual(b.appLinkMode, .ask)
        XCTAssertTrue(b.blurPrivateSwitcher)
        _ = try b.restoreBackup(data, passphrase: "pw")
        XCTAssertEqual(b.appLinkMode, .app)
        XCTAssertEqual(ExternalApps.mode, .app, "the engine reads the same answer")
        XCTAssertFalse(b.blurPrivateSwitcher)
        // The per-site answers are read back when the next install starts.
        let again = model(root)
        await again.start()
        XCTAssertEqual(again.appLinkSites["youtube.com"], "app")
        XCTAssertEqual(again.appLinkSites["maps.apple.com"], "browser")
    }

    func testTheSearchableCopyIsNeverPartOfABackup() async throws {
        let a = model()
        await a.start()
        a.pageIndex?.upsert(url: "https://secret.test/1", title: "Private notes", host: "secret.test", body: "very private text")
        let data = try a.makeBackup(passphrase: "pw", iterations: 1_000)
        XCTAssertNil(data.range(of: Data("very private text".utf8)), "page text must not be written into the backup file")
        let payload = try BackupFile.open(data, passphrase: "pw")
        XCTAssertFalse(payload.settings.keys.contains("page_index"))
    }

    func testTheIndexStaysUnderItsCapAndStillAnswersQuickly() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bs-cap-" + UUID().uuidString)
        let index = try XCTUnwrap(PageIndex(folder: folder))
        for i in 0..<3_000 {
            index.upsert(url: "https://site\(i % 40).test/p\(i)", title: "Page \(i)", host: "site\(i % 40).test",
                         body: "article \(i) about topic\(i % 17) and some more words to make the page text longer", visited: Date(timeIntervalSinceNow: -Double(i)))
        }
        XCTAssertEqual(index.count, 3_000)
        index.prune(olderThan: 365, maxPages: 1_000)
        XCTAssertEqual(index.count, 1_000, "the cap holds")
        XCTAssertTrue(index.searchAfterWrites("Page 0").contains { $0.url.hasSuffix("/p0") }, "the newest pages are the ones kept")
        measure { _ = index.searchAfterWrites("topic3", limit: 20) }
    }

    func testHundredsOfTabsSurviveARestartAndStayBlankUntilUsed() async throws {
        let root = NSTemporaryDirectory() + "bs-many-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let a = model(root)
        await a.start()
        for i in 0..<300 { a.openTab(url: URL(string: "https://tab\(i).example/page"), isPrivate: false) }
        XCTAssertGreaterThanOrEqual(a.tabs.count, 300)
        let started = Date()
        a.saveNow()
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "saving 300 tabs stays fast")

        let b = model(root)
        let launch = Date()
        await b.start()
        XCTAssertLessThan(Date().timeIntervalSince(launch), 8, "starting with 300 saved tabs stays inside its budget")
        XCTAssertGreaterThanOrEqual(b.tabs.count, 300, "every tab came back")
        let loaded = b.tabs.filter { $0.url?.host?.hasSuffix(".example") == true && $0.hasLoadedPage }.count
        XCTAssertLessThanOrEqual(loaded, 3, "only the tab in front is loaded; the other pages wait until they are used")
    }

    /// CPU time (user + system) used by this process so far.
    static func processCPUSeconds() -> Double {
        var ts = timespec(); clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
    }

    func testStartingAnEmptyProfileIsQuick() async throws {
        // The budget is the app's own CPU time, not the wall clock: a busy machine (other builds, a simulator) stretches the wall clock without the app doing any more work.
        let m = model()
        let cpuBefore = Self.processCPUSeconds()
        let began = Date()
        await m.start()
        let cpu = Self.processCPUSeconds() - cpuBefore
        print("EMPTY-PROFILE START: cpu \(cpu) s, wall \(Date().timeIntervalSince(began)) s")
        XCTAssertLessThan(cpu, 3, "an empty profile starts with a few CPU-seconds of work at most")
    }

    /// A crash seen in the One Row tab strip: several tabs and none active left the width list with one entry, and the view read past it.
    func testEveryTabGetsAWidthEvenWhenNoneIsActive() {
        for count in 0...12 {
            for active in [nil] + (0..<max(count, 1)).map({ Optional($0) }) {
                let widths = InlineTabs.widths(total: 900, count: count, activeIndex: active, iconCell: 36, maxCell: 240)
                XCTAssertEqual(widths.count, count, "count \(count), active \(String(describing: active))")
                XCTAssertTrue(widths.allSatisfy { $0 > 0 && $0.isFinite })
            }
        }
    }
}
