import XCTest
@testable import Browser_Setu

/// Stage 0 behavioral-contract tests: they describe how tab switching, web-view ownership and memory release behave TODAY, so that later architecture work can be checked against them.
/// Nothing here changes production code. Each test uses its own throwaway storage root. A test never passes by skipping its own precondition: it is skipped instead.
@MainActor
final class Stage0BaselineTests: XCTestCase {
    private func model() -> BrowserModel {
        BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-stage0-\(UUID().uuidString)", profile: "default")
    }

    private func openTabs(_ m: BrowserModel, _ count: Int) -> [TabController] {
        (0..<count).map { m.openTab(url: URL(string: "about:blank#s0-\($0)")!, isPrivate: false) }
    }

    /// Waits (bounded) for a condition on the main actor.
    private func until(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if condition() { return true }; try? await Task.sleep(nanoseconds: 50_000_000) }
        return condition()
    }

    // MARK: Rapid A -> B -> C tab switching

    func testRapidSwitchEndsOnTheLastTabAndReplacesNoWebView() {
        let m = model()
        let tabs = openTabs(m, 3)
        let engines = tabs.map { ObjectIdentifier($0.engine as AnyObject) }
        for _ in 0..<20 {
            m.select(tabs[0].id); m.select(tabs[1].id); m.select(tabs[2].id)
        }
        m.select(tabs[1].id); m.select(tabs[0].id); m.select(tabs[2].id)
        XCTAssertEqual(m.activeID, tabs[2].id, "the last request wins")
        XCTAssertEqual(tabs.map { ObjectIdentifier($0.engine as AnyObject) }, engines, "switching tabs must never replace a web view")
        XCTAssertTrue(tabs.allSatisfy { !$0.isDiscarded }, "switching tabs must not put a tab to sleep")
    }

    func testRapidSwitchLeavesSnapshotAndScrollWorkHarmlessAfterItSettles() async {
        let m = model()
        let tabs = openTabs(m, 3)
        for _ in 0..<10 { m.select(tabs[0].id); m.select(tabs[1].id); m.select(tabs[2].id) }
        // `selectTab` starts snapshot and scroll-save tasks for the tab it leaves; let them all finish.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(m.activeID, tabs[2].id, "late snapshot or scroll completions must not change which tab is in front")
        XCTAssertTrue(m.tabs.contains { $0.id == tabs[0].id } && m.tabs.contains { $0.id == tabs[1].id })
    }

    func testSelectingTheActiveTabAgainIsANoOpForIdentity() {
        let m = model()
        let tabs = openTabs(m, 2)
        m.select(tabs[1].id)
        let engine = ObjectIdentifier(tabs[1].engine as AnyObject)
        for _ in 0..<5 { m.select(tabs[1].id) }
        XCTAssertEqual(m.activeID, tabs[1].id)
        XCTAssertEqual(ObjectIdentifier(tabs[1].engine as AnyObject), engine)
    }

    // MARK: WebView resource replacement (what is true today)

    /// Today a tab's web view is replaced when the tab is put to sleep. The tab keeps its id; the engine object is new; nothing numbers the generations.
    func testSleepingATabKeepsItsIdentityAndReplacesItsEngineObject() {
        let m = model()
        let tab = openTabs(m, 2)[0]
        let id = tab.id
        let before = ObjectIdentifier(tab.engine as AnyObject)
        tab.discard(afterProcessEnd: true)
        XCTAssertTrue(tab.isDiscarded)
        XCTAssertEqual(tab.id, id, "tab identity survives the replacement")
        XCTAssertNotEqual(ObjectIdentifier(tab.engine as AnyObject), before, "the web view is replaced when a tab sleeps")
        let after = ObjectIdentifier(tab.engine as AnyObject)
        tab.ensureLoaded()
        XCTAssertEqual(ObjectIdentifier(tab.engine as AnyObject), after, "waking a tab reuses the replacement and does not create another")
    }

    func testPrivateTabsAreNeverPutToSleep() {
        let m = model()
        let tab = m.openTab(url: URL(string: "about:blank#private")!, isPrivate: true)
        let before = ObjectIdentifier(tab.engine as AnyObject)
        tab.discard(afterProcessEnd: true)
        XCTAssertFalse(tab.isDiscarded, "a private tab's state could not be restored, so it is kept")
        XCTAssertEqual(ObjectIdentifier(tab.engine as AnyObject), before)
    }

    // MARK: Multi-pane visibility and the asynchronous memory check

    private func idleLiveTabs(_ m: BrowserModel, count: Int) async -> [TabController]? {
        let tabs = openTabs(m, count)
        let loaded = await until(20) { tabs.allSatisfy { $0.hasLoadedPage } }
        guard loaded else { return nil }
        // A page that is still loading reports itself busy and the release pass rightly skips it, so wait until every tab is really idle.
        var idle = false
        let end = Date().addingTimeInterval(20)
        while !idle, Date() < end {
            var anyBusy = false
            for t in tabs where await t.engine.isBusy() { anyBusy = true }
            idle = !anyBusy
            if !idle { try? await Task.sleep(nanoseconds: 100_000_000) }
        }
        guard idle else { return nil }
        // Old enough for the critical-pressure rule (10 s idle) and never the most recent one.
        for (offset, tab) in tabs.enumerated() { tab.lastActive = Date().addingTimeInterval(-600 + Double(offset)) }
        return tabs
    }

    /// Control 1: with nothing protecting them, idle tabs ARE released by this setup. Without this, the tests below could pass only because nothing was ever a victim.
    func testIdleBackgroundTabsAreReleasedWhenNothingProtectsThem() async throws {
        let m = model()
        m.memoryMode = .battery
        guard let tabs = await idleLiveTabs(m, count: 4) else { throw XCTSkip("the blank pages did not finish loading in time") }
        m.select(tabs[3].id)
        let now = Date()
        let candidates = m.tabs.map { t in
            TabCandidate(id: t.id, lastActive: t.lastActive, pinned: t.pinned, isPrivate: t.isPrivate, isActive: t.id == m.activeID, loaded: t.hasLoadedPage, discarded: t.isDiscarded, exempt: m.neverSleeps(host: t.url?.host) || t.playingAudio)
        }
        print("S0DIAG candidates \(candidates.map { "id=\($0.id) loaded=\($0.loaded) active=\($0.isActive) idle=\(Int(now.timeIntervalSince($0.lastActive)))s pinned=\($0.pinned) exempt=\($0.exempt)" })")
        print("S0DIAG policy victims = \(TabLifecyclePolicy.victims(candidates, mode: m.effectiveMemoryMode, event: .critical, now: now, keepPinned: m.keepPinnedTabs, custom: m.customMemory)) mode=\(m.effectiveMemoryMode) rule=\(String(describing: TabLifecyclePolicy.rule(mode: m.effectiveMemoryMode, event: .critical)))")
        var busy: [Bool] = []
        for t in m.tabs { busy.append(await t.engine.isBusy()) }
        print("S0DIAG busy = \(busy)")
        let released = await TabLifecycle(model: m).run(.critical)
        print("S0DIAG control-1 effective=\(m.effectiveMemoryMode) released=\(released) ids=\(tabs.map(\.id))")
        XCTAssertTrue(released.contains(tabs[0].id), "the setup must produce at least one release, or the protection tests prove nothing")
    }

    /// Control 2: a tab that is in a split pane BEFORE the release pass starts is protected (and the same setup does release the others).
    func testATabAlreadyInASplitPaneIsNotReleased() async throws {
        let m = model()
        m.memoryMode = .battery
        guard let tabs = await idleLiveTabs(m, count: 4) else { throw XCTSkip("the blank pages did not finish loading in time") }
        m.select(tabs[3].id)
        m.splitTabID = tabs[0].id
        let released = await TabLifecycle(model: m).run(.critical)
        XCTAssertFalse(released.contains(tabs[0].id), "a visible split pane must never be released")
        XCTAssertFalse(tabs[0].isDiscarded)
        XCTAssertFalse(released.isEmpty, "the same setup releases other idle tabs, so the protection was exercised")
    }

    /// S0-1 (fixed in Stage 0.5): the release pass picks its victims, then waits for each one's busy check. A tab moved into ANY split pane during that wait must not be released. Each test only
    /// counts if the pass really was suspended when the pane changed; otherwise it is skipped, never passed.
    private func raceTest(_ name: String, othersStillReleased: Bool = true, putInPane: (BrowserModel, UInt64) -> Void) async throws {
        let m = model()
        m.memoryMode = .battery
        guard let tabs = await idleLiveTabs(m, count: 4) else { throw XCTSkip("the blank pages did not finish loading in time") }
        m.select(tabs[3].id)
        let victim = tabs[0]                       // the oldest, so the policy picks it first
        let lifecycle = TabLifecycle(model: m)
        let finished = Box()
        let pass = Task { @MainActor () -> [UInt64] in let r = await lifecycle.run(.critical); finished.value = true; return r }
        await Task.yield()                         // lets the pass start and reach its first await
        let suspended = !finished.value
        putInPane(m, victim.id)                    // the person puts that tab in a split pane while the check is pending
        let released = await pass.value
        print("S0DIAG race[\(name)] suspendedWhenPaneChanged=\(suspended) released=\(released) victimDiscarded=\(victim.isDiscarded)")
        try XCTSkipUnless(suspended, "the release pass finished before the pane changed, so the window was not exercised")
        XCTAssertFalse(released.contains(victim.id), "S0-1 [\(name)]: a tab that became a visible pane during the busy check was released")
        XCTAssertFalse(victim.isDiscarded, "S0-1 [\(name)]: the pane tab was discarded")
        if othersStillReleased { XCTAssertTrue(released.contains(tabs[1].id) || released.contains(tabs[2].id), "genuinely idle background tabs must still be released") }
    }

    func testATabMovedIntoASplitPaneDuringTheBusyCheckIsNotReleased() async throws {
        try await raceTest("second pane") { m, id in m.splitTabID = id }
    }

    func testATabMovedIntoTheThirdPaneDuringTheBusyCheckIsNotReleased() async throws {
        try await raceTest("third pane") { m, id in
            m.splitTabID = m.tabs.last!.id == m.activeID ? m.tabs[1].id : m.tabs.last!.id   // a second pane must exist for a third
            m.thirdSplitTabID = id
        }
    }

    func testATabMovedIntoTheFourthPaneDuringTheBusyCheckIsNotReleased() async throws {
        try await raceTest("fourth pane", othersStillReleased: false) { m, id in
            m.splitTabID = m.tabs.last!.id == m.activeID ? m.tabs[1].id : m.tabs.last!.id
            m.thirdSplitTabID = m.tabs[1].id == m.splitTabID ? m.tabs[2].id : m.tabs[1].id
            m.fourthSplitTabID = id
        }
    }

    private final class Box { var value = false }

    func testThePolicyNeverChoosesTheSelectedOrAnyMarkedActiveTab() {
        let now = Date()
        func candidate(_ id: UInt64, active: Bool) -> TabCandidate {
            TabCandidate(id: id, lastActive: now.addingTimeInterval(-900), pinned: false, isPrivate: false, isActive: active, loaded: true, discarded: false)
        }
        let victims = TabLifecyclePolicy.victims([candidate(1, active: true), candidate(2, active: true), candidate(3, active: false), candidate(4, active: false)],
                                                 mode: .battery, event: .critical, now: now, keepPinned: true)
        XCTAssertFalse(victims.contains(1)); XCTAssertFalse(victims.contains(2))
    }

    // MARK: Layout switching keeps identity (all presets)

    func testEveryLayoutKeepsEveryTabAndWebViewAcrossAFullCycle() {
        let m = model()
        let tabs = openTabs(m, 4)
        let objects = tabs.map { ObjectIdentifier($0) }
        let engines = tabs.map { ObjectIdentifier($0.engine as AnyObject) }
        let active = m.activeID
        for preset in LayoutPreset.allCases + LayoutPreset.allCases.reversed() {
            m.layoutPreset = preset
            XCTAssertEqual(m.activeID, active, "\(preset): the selected tab changed with the layout")
            XCTAssertEqual(tabs.map { ObjectIdentifier($0) }, objects, "\(preset): a tab object changed")
            XCTAssertEqual(tabs.map { ObjectIdentifier($0.engine as AnyObject) }, engines, "\(preset): a web view was replaced")
        }
    }

    // MARK: Restoration

    func testRestoredTabsStayAsleepUntilSelectedAndPrivateTabsAreNotRestored() async throws {
        let root = NSTemporaryDirectory() + "bs-stage0-restore-\(UUID().uuidString)"
        let first = BrowserModel(engine: WebKitEngine(), root: root, profile: "default")
        await first.start()
        let a = first.active!
        a.engineURLChanged(URL(string: "https://one.example/")!)
        try first.core.commitNavigation(tabId: a.id, url: "https://one.example/", title: "One")
        let b = first.openTab(url: nil, isPrivate: false)
        b.engineURLChanged(URL(string: "https://two.example/")!)
        try first.core.commitNavigation(tabId: b.id, url: "https://two.example/", title: "Two")
        let p = first.openTab(url: nil, isPrivate: true)
        p.engineURLChanged(URL(string: "https://secret.example/")!)
        first.saveNow()
        let second = BrowserModel(engine: WebKitEngine(), root: root, profile: "default")
        await second.start()
        XCTAssertFalse(second.tabs.contains { $0.isPrivate }, "private tabs are never restored")
        let addresses = second.tabs.compactMap { $0.url?.absoluteString }
        XCTAssertTrue(addresses.contains("https://one.example/") && addresses.contains("https://two.example/"))
        XCTAssertFalse(addresses.contains("https://secret.example/"))
        let loadedNow = second.tabs.filter { $0.hasLoadedPage && $0.id != second.activeID }
        XCTAssertTrue(loadedNow.isEmpty, "restored background tabs must not load until selected")
    }
}
