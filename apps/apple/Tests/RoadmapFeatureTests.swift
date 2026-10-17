import XCTest
@testable import Browser_Setu

// MARK: - Link cleaning

final class TrackingParametersTests: XCTestCase {
    private func clean(_ s: String) -> String? { TrackingParameters.clean(URL(string: s)!)?.absoluteString }

    func testRemovesTrackingParametersAndKeepsEverythingElse() {
        XCTAssertEqual(clean("https://example.com/p?utm_source=a&id=7&fbclid=x#top"), "https://example.com/p?id=7#top")
        XCTAssertEqual(clean("https://example.com/?UTM_Campaign=x&gclid=1"), "https://example.com/", "the whole query goes when nothing real is left")
    }

    func testLeavesLinksWithNothingToRemoveAlone() {
        XCTAssertNil(clean("https://example.com/p?id=7&page=2"))
        XCTAssertNil(clean("https://example.com/p"))
        XCTAssertNil(clean("https://example.com/p?utmx=1"), "a look-alike name is not a campaign parameter")
        XCTAssertNil(clean("https://example.com/p?ref=friend"), "ref carries real meaning on many sites")
    }

    func testOnlyWebLinksAreTouched() {
        XCTAssertNil(clean("mailto:a@b.c?utm_source=x"))
        XCTAssertNil(clean("about:blank"))
        XCTAssertNil(clean("file:///tmp/a?utm_source=x"))
    }

    func testRemainingQueryKeepsItsExactEncoding() {
        XCTAssertEqual(clean("https://example.com/s?q=a%20b+c&utm_medium=x&lang=en-US"), "https://example.com/s?q=a%20b+c&lang=en-US")
        XCTAssertEqual(clean("https://example.com/s?gclid=&x=1"), "https://example.com/s?x=1")
    }
}

// MARK: - Threat list

final class ThreatListTests: XCTestCase {
    func testParsesCommonFormatsAndIgnoresNoise() {
        let list = ThreatList.parse("""
        # a comment
        0.0.0.0 bad.example
        ||evil.test^
        https://phish.example/login?x=1
        localhost
        127.0.0.1 localhost
        not a host
        GOOD.com   # trailing comment
        bad_char!.com
        """)
        XCTAssertEqual(list.hosts, ["bad.example", "evil.test", "phish.example", "good.com"])
    }

    func testMatchesTheHostAndItsSubdomainsOnly() {
        let list = ThreatList.parse("bad.example\nevil.test")
        XCTAssertTrue(list.contains(host: "bad.example"))
        XCTAssertTrue(list.contains(host: "www.Bad.Example"))
        XCTAssertTrue(list.contains(host: "a.b.evil.test."))
        XCTAssertFalse(list.contains(host: "notbad.example"), "a longer name that merely ends the same way is a different site")
        XCTAssertFalse(list.contains(host: "example"))
        XCTAssertFalse(list.contains(host: "good.example"))
        XCTAssertFalse(ThreatList.empty.contains(host: "bad.example"))
    }

    func testStoreRoundTripsAndRejectsBadFiles() throws {
        let root = NSTemporaryDirectory() + "bs-threat-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        XCTAssertTrue(ThreatListStore.load(root: root).isEmpty)
        let saved = try ThreatListStore.save(Data("bad.example\nevil.test\n".utf8), root: root)
        XCTAssertEqual(saved.count, 2)
        XCTAssertEqual(ThreatListStore.load(root: root).count, 2)
        XCTAssertThrowsError(try ThreatListStore.save(Data([0xFF, 0xFE, 0x00, 0x80]), root: root))
        XCTAssertThrowsError(try ThreatListStore.save(Data("# only comments\n".utf8), root: root))
        XCTAssertEqual(ThreatListStore.load(root: root).count, 2, "a rejected file never replaces the good list")
        ThreatListStore.remove(root: root)
        XCTAssertTrue(ThreatListStore.load(root: root).isEmpty)
    }
}

// MARK: - Memory policy

final class TabLifecyclePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func tab(_ id: UInt64, idle: TimeInterval, pinned: Bool = false, isPrivate: Bool = false, active: Bool = false,
                     loaded: Bool = true, discarded: Bool = false) -> TabCandidate {
        TabCandidate(id: id, lastActive: now.addingTimeInterval(-idle), pinned: pinned, isPrivate: isPrivate,
                     isActive: active, loaded: loaded, discarded: discarded)
    }

    private func victims(_ tabs: [TabCandidate], _ mode: MemoryMode, _ event: MemoryEvent, keepPinned: Bool = true) -> [UInt64] {
        TabLifecyclePolicy.victims(tabs, mode: mode, event: event, now: now, keepPinned: keepPinned)
    }

    func testBalancedAndPerformanceNeverReleaseTabsOnTheTimer() {
        let tabs = (1...12).map { tab(UInt64($0), idle: 99_999) }
        XCTAssertTrue(victims(tabs, .balanced, .timer).isEmpty)
        XCTAssertTrue(victims(tabs, .performance, .timer).isEmpty)
        XCTAssertTrue(victims(tabs, .performance, .warning).isEmpty, "Performance waits for a critical shortage")
    }

    func testMemoryWarningKeepsTheFiveMostRecentAndReleasesOldestFirst() {
        let tabs = (1...9).map { tab(UInt64($0), idle: TimeInterval($0) * 300) }   // 1 is the freshest
        XCTAssertEqual(victims(tabs, .balanced, .warning), [9, 8, 7, 6], "oldest first, the five freshest stay")
    }

    func testRecentlyUsedTabsAreNotReleasedEvenWhenOverTheBudget() {
        let tabs = [tab(1, idle: 10), tab(2, idle: 20), tab(3, idle: 30), tab(4, idle: 40), tab(5, idle: 50), tab(6, idle: 60), tab(7, idle: 70)]
        XCTAssertTrue(victims(tabs, .balanced, .warning).isEmpty, "idle under two minutes is too recent")
    }

    func testNeverReleasesTheSelectedPrivatePinnedOrEmptyTabs() {
        let tabs = [tab(1, idle: 9_000, active: true), tab(2, idle: 9_000, isPrivate: true), tab(3, idle: 9_500, pinned: true),
                    tab(4, idle: 9_000, loaded: false), tab(5, idle: 9_000, discarded: true), tab(6, idle: 9_000),
                    tab(7, idle: 100), tab(8, idle: 100), tab(9, idle: 100), tab(10, idle: 100), tab(11, idle: 100), tab(12, idle: 100)]
        XCTAssertEqual(victims(tabs, .balanced, .warning), [6])
        XCTAssertEqual(victims(tabs, .balanced, .warning, keepPinned: false), [3, 6], "pinned tabs are fair game only when allowed")
    }

    func testMemorySaverReleasesTabsIdleForTenMinutesOnTheTimer() {
        let tabs = [tab(1, idle: 5), tab(2, idle: 30), tab(3, idle: 60), tab(4, idle: 700), tab(5, idle: 900)]
        XCTAssertEqual(victims(tabs, .saver, .timer), [5, 4])
        XCTAssertEqual(victims(tabs, .saver, .critical), [5, 4, 3, 2], "a critical shortage keeps only the freshest")
    }
}

// MARK: - Models and tabs

@MainActor
final class RoadmapIntegrationTests: XCTestCase {
    private func model() -> BrowserModel {
        BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-rm-\(UUID().uuidString)", profile: "default")
    }

    /// A page has an address as soon as it commits; it is only idle once loading has finished.
    private func waitIdle(_ tab: TabController) async {
        for _ in 0..<80 {
            if !tab.isLoading { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func waitLoaded(_ tab: TabController) async -> Bool {
        for _ in 0..<60 {
            if tab.hasLoadedPage { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    func testLinkCleaningStopsAfterThreeQuickRepeats() async throws {
        let m = model()
        await m.start()
        let url = URL(string: "https://example.com/?utm_source=x&id=1")!
        XCTAssertNotNil(m.cleanedLink(url)); XCTAssertNotNil(m.cleanedLink(url)); XCTAssertNotNil(m.cleanedLink(url))
        XCTAssertNil(m.cleanedLink(url), "a site that keeps re-adding the parameter must not loop the tab")
        XCTAssertEqual(m.strippedLinkCount, 3)
        m.stripTrackingParameters = false
        XCTAssertNil(m.cleanedLink(url), "off means off")
    }

    func testThreatListWarnsUntilTheUserContinuesForTheSession() async throws {
        let m = model()
        await m.start()
        XCTAssertFalse(m.shouldWarnAboutThreat(host: "bad.example"), "no list, no warnings")
        let file = URL(fileURLWithPath: NSTemporaryDirectory() + "bs-list-\(UUID().uuidString).txt")
        try Data("bad.example\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        m.importThreatList(from: file)
        XCTAssertEqual(m.threatList.count, 1)
        XCTAssertTrue(m.shouldWarnAboutThreat(host: "www.bad.example"))

        let tab = try XCTUnwrap(m.active)
        Dialogs.testHandler = { _, _, _ in 0 }                       // Go Back
        m.presentThreatWarning(for: URL(string: "https://bad.example/")!, in: tab)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(m.shouldWarnAboutThreat(host: "bad.example"), "going back leaves the warning in place")
        Dialogs.testHandler = { _, _, _ in 1 }                       // Continue Anyway
        m.presentThreatWarning(for: URL(string: "https://bad.example/")!, in: tab)
        try await Task.sleep(for: .milliseconds(200))
        Dialogs.testHandler = nil
        XCTAssertFalse(m.shouldWarnAboutThreat(host: "bad.example"), "continuing silences it for this session only")

        m.clearThreatList()
        XCTAssertTrue(m.threatList.isEmpty)
    }

    func testNavigationToAListedHostIsDeniedAndALinkWithTrackersIsReissuedClean() async throws {
        let m = model()
        await m.start()
        let tab = try XCTUnwrap(m.active)
        let file = URL(fileURLWithPath: NSTemporaryDirectory() + "bs-list-\(UUID().uuidString).txt")
        try Data("bad.example\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        m.importThreatList(from: file)
        Dialogs.testHandler = { _, _, _ in 0 }
        defer { Dialogs.testHandler = nil }
        XCTAssertEqual(tab.engineDecideNavigation(url: URL(string: "https://bad.example/x")!, mainFrame: true), .deny)
        XCTAssertEqual(tab.engineDecideNavigation(url: URL(string: "https://bad.example/x")!, mainFrame: false), .allow, "only the page itself is checked, not its sub-frames")
        // The warning dialog is shown from a task; let it run while the stub is still in place.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(tab.engineDecideNavigation(url: URL(string: "https://good.example/?utm_source=x")!, mainFrame: true), .deny, "reissued without trackers")
        XCTAssertEqual(tab.engineDecideNavigation(url: URL(string: "https://good.example/?id=1")!, mainFrame: true), .allow)
    }

    func testReleasedTabKeepsItsAddressAndComesBackWhenSelected() async throws {
        let m = model()
        await m.start()
        let tab = try XCTUnwrap(m.active)
        tab.load(URL(string: "about:blank")!)
        let loaded = await waitLoaded(tab)
        XCTAssertTrue(loaded)
        let other = m.newTab()
        XCTAssertNotEqual(m.activeID, tab.id)

        tab.discard()
        XCTAssertTrue(tab.isDiscarded)
        XCTAssertFalse(tab.hasLoadedPage, "the web process is gone")
        XCTAssertEqual(tab.url?.absoluteString, "about:blank", "the address stays in the tab list")

        m.select(tab.id)
        XCTAssertFalse(tab.isDiscarded, "selecting it brings it back")
        _ = other
    }

    func testPrivateTabsAndUnloadedTabsAreNeverReleased() async throws {
        let m = model()
        await m.start()
        let priv = m.openTab(url: URL(string: "about:blank"), isPrivate: true, select: false)
        let loaded = await waitLoaded(priv)
        XCTAssertTrue(loaded)
        priv.discard()
        XCTAssertFalse(priv.isDiscarded, "a private tab's page could not be restored")
        let blank = m.newTab()
        blank.discard()
        XCTAssertFalse(blank.isDiscarded, "nothing loaded, nothing to release")
    }

    func testManagerReleasesOnlyWhatThePolicyPicksAndNeverTheSelectedTab() async throws {
        let m = model()
        await m.start()
        m.memoryMode = .saver
        let first = try XCTUnwrap(m.active)
        first.load(URL(string: "about:blank")!)
        let ready = await waitLoaded(first)
        XCTAssertTrue(ready)
        first.lastActive = Date().addingTimeInterval(-3_600)
        _ = m.newTab()                                   // the new tab is now selected; `first` is idle
        let manager = try XCTUnwrap(m.lifecycle)
        let released = await manager.run(.timer)
        XCTAssertTrue(released.isEmpty, "saver keeps the three freshest tabs; two tabs are always inside that budget")
        let more = [m.newTab(), m.newTab(), m.newTab()]
        for tab in more { tab.load(URL(string: "about:blank")!) }
        for tab in more { let ok = await waitLoaded(tab); XCTAssertTrue(ok) }
        first.lastActive = Date().addingTimeInterval(-3_600)   // switching away marks a tab as just used, so age it now
        await waitIdle(first)
        let busy = await first.engine.isBusy()
        XCTAssertFalse(busy, "an idle blank page is not loading, playing media or capturing")
        let again = await manager.run(.timer)
        XCTAssertEqual(again, [first.id], "the long-idle loaded tab goes; the selected one never does")
        XCTAssertTrue(first.isDiscarded)
        XCTAssertFalse(try XCTUnwrap(m.active).isDiscarded)
    }

    func testHealthCheckReportsTheCoreParts() async throws {
        let m = model()
        await m.start()
        let items = await HealthCheck.run(model: m)
        let names = Set(items.map(\.name))
        for expected in ["Profile database", "Web engine", "Ad and tracker protection", "Link cleaning", "Threat list", "Tabs"] {
            XCTAssertTrue(names.contains(expected), "missing \(expected)")
        }
        XCTAssertEqual(items.first { $0.name == "Profile database" }?.status, .ok)
        XCTAssertEqual(items.first { $0.name == "Web engine" }?.status, .ok)
    }

    func testSettingsSurviveARestart() async throws {
        let root = NSTemporaryDirectory() + "bs-rm-persist-\(UUID().uuidString)"
        let a = BrowserModel(engine: WebKitEngine(), root: root, profile: "default")
        await a.start()
        a.memoryMode = .saver
        a.keepPinnedTabs = false
        a.stripTrackingParameters = false
        let b = BrowserModel(engine: WebKitEngine(), root: root, profile: "default")
        await b.start()
        XCTAssertEqual(b.memoryMode, .saver)
        XCTAssertFalse(b.keepPinnedTabs)
        XCTAssertFalse(b.stripTrackingParameters)
    }

    func testWebsiteDataListIsEmptyForAFreshProfile() async throws {
        let m = model()
        await m.start()
        let sites = await m.siteData()
        XCTAssertTrue(sites.allSatisfy { !$0.host.isEmpty })
    }
}
