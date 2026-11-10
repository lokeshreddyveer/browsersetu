import XCTest
@testable import Browser_Setu

final class TabFeaturePureTests: XCTestCase {
    private func record(_ id: String, _ url: String, profile: String = "default", container: String? = nil, position: Int = 0) -> EssentialTab {
        EssentialTab(id: id, profile: profile, url: url, title: id, container: container, position: position, createdAt: Date(timeIntervalSince1970: Double(position)))
    }

    func testNormalizingKeepsOnlyThisProfilesValidRecordsOnceInOrder() {
        let stored = [
            record("c", "https://c.example", position: 2),
            record("a", "https://a.example", position: 0),
            record("a", "https://a2.example", position: 1),                        // same id twice
            record("x", "https://x.example", profile: "other", position: 3),       // another profile's cookies must not meet this one's
            record("f", "file:///etc/passwd", position: 4),                        // not a web page
            record("b", "https://b.example", position: 1),
        ]
        let clean = Essentials.normalized(stored, profile: "default")
        XCTAssertEqual(clean.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(clean.map(\.position), [0, 1, 2])
    }

    func testNormalizingCapsAtTwelve() {
        let many = (0..<20).map { record("e\($0)", "https://e\($0).example", position: $0) }
        XCTAssertEqual(Essentials.normalized(many, profile: "default").count, Essentials.maxCount)
    }

    func testMovingAndDuplicates() {
        let list = [record("a", "https://a.example", position: 0), record("b", "https://b.example", position: 1), record("c", "https://c.example", position: 2)]
        XCTAssertEqual(Essentials.moved(list, id: "c", to: 0).map(\.id), ["c", "a", "b"])
        XCTAssertEqual(Essentials.moved(list, id: "a", to: 99).map(\.id), ["b", "c", "a"])
        XCTAssertEqual(Essentials.moved(list, id: "zzz", to: 0), list)
        // The same page in another container is a different Essential; a fragment or trailing slash is not a difference.
        let url = URL(string: "https://a.example/#top")!
        XCTAssertNotNil(Essentials.isDuplicate(list, url: url, container: nil))
        XCTAssertNil(Essentials.isDuplicate(list, url: url, container: "Work"))
    }

    func testPinnedAddressValidation() {
        XCTAssertEqual(PinnedAddresses.parse("example.com/mail").url?.absoluteString, "https://example.com/mail")
        XCTAssertEqual(PinnedAddresses.parse("http://example.com").url?.scheme, "http")
        for bad in ["", "javascript:alert(1)", "file:///etc/hosts", "data:text/html,hi", "about:blank", "https://user:pw@example.com", "https://exa mple.com",
                    "ftp://example.com", "https://nodot", "browsersetu://panel/history", String(repeating: "a", count: 2100)] {
            XCTAssertNil(PinnedAddresses.parse(bad).url, bad)
            XCTAssertNotNil(PinnedAddresses.parse(bad).problem, bad)
        }
    }

    func testSanitizingDropsDamagedPinnedEntries() {
        let map = ["a": PinnedTabMetadata(originalURL: "https://a.example", customHomeURL: "javascript:1", resetOnWorkspaceSwitch: true),
                   "b": PinnedTabMetadata(originalURL: "not a url")]
        let clean = PinnedAddresses.sanitized(map)
        XCTAssertEqual(clean.keys.sorted(), ["a"])
        XCTAssertNil(clean["a"]?.customHomeURL)
        XCTAssertEqual(clean["a"]?.resetOnWorkspaceSwitch, true)
    }

    func testTabLocationFromFrames() {
        let height: CGFloat = 400
        func loc(_ minY: CGFloat, _ h: CGFloat = 30) -> TabLocation { TabVisibilityCoordinator.location(of: CGRect(x: 0, y: minY, width: 100, height: h), viewportHeight: height) }
        XCTAssertEqual(loc(100), .visible)
        XCTAssertEqual(loc(-100), .above)
        XCTAssertEqual(loc(500), .below)
        XCTAssertEqual(loc(-10), .visible, "two thirds in view counts as seen")
        XCTAssertEqual(loc(-20), .above, "only a third in view is not seen")
        XCTAssertEqual(loc(385), .visible, "exactly half in view counts as seen")
        XCTAssertEqual(loc(390), .below)
        XCTAssertEqual(TabVisibilityCoordinator.location(of: nil, viewportHeight: height), .visible)
        XCTAssertEqual(TabVisibilityCoordinator.location(of: CGRect(x: 0, y: -900, width: 1, height: 30), viewportHeight: 0), .visible, "an unmeasured list shows nothing")
    }
}

@MainActor
final class TabFeatureModelTests: XCTestCase {
    private var model: BrowserModel!
    private var root = ""

    override func setUp() async throws {
        root = NSTemporaryDirectory() + "bs-tf-\(UUID().uuidString)"
        model = BrowserModel(engine: WebKitEngine(), root: root, profile: "tf")
        Dialogs.testHandler = { _, _, buttons in 0 }
    }

    override func tearDown() async throws {
        Dialogs.testHandler = nil
        model = nil
        try? FileManager.default.removeItem(atPath: root)
    }

    /// A tab that looks like it has the page, without any network.
    @discardableResult
    private func tab(_ url: String, container: String? = nil) -> TabController {
        let t = model.openTab(url: nil, isPrivate: false, container: container)
        t.url = URL(string: url)
        return t
    }

    func testAddingAnEssentialHidesItsTabFromEveryWorkspaceListAndKeepsTheTab() {
        let t = tab("https://mail.example/inbox")
        XCTAssertTrue(model.visibleTabs.contains { $0.id == t.id })
        XCTAssertTrue(model.addToEssentials(t))
        XCTAssertEqual(model.essentials.count, 1)
        XCTAssertFalse(model.visibleTabs.contains { $0.id == t.id }, "an Essential is in no workspace's list")
        XCTAssertTrue(model.tabs.contains { $0.id == t.id }, "its page is kept, not reloaded")
        XCTAssertEqual(model.essentials[0].profile, "tf")
    }

    func testEssentialsSurviveWorkspaceSwitchesWithoutDuplicates() {
        model.createWorkspace("Work")
        let t = tab("https://mail.example/")
        XCTAssertTrue(model.addToEssentials(t))
        let record = model.essentials[0]
        model.switchWorkspace("Work")
        model.switchWorkspace("")
        model.switchWorkspace("Work")
        XCTAssertEqual(model.essentials, [record], "no copy is made and none is lost")
        XCTAssertEqual(model.tabs.filter { model.isEssentialTab($0) }.count, 1)
        // Opening it from the other workspace shows it and stays in that workspace.
        model.openEssential(record.id)
        XCTAssertEqual(model.activeID, t.id)
        XCTAssertEqual(model.activeWorkspace, "Work")
    }

    func testClosingAnEssentialsTabKeepsTheEssential() {
        let t = tab("https://mail.example/")
        model.addToEssentials(t)
        let other = tab("https://other.example/")
        model.select(t.id)
        model.closeTab(id: t.id)
        XCTAssertTrue(model.tabs.contains { $0.id == t.id }, "closing lets go of the page but keeps the tab record")
        XCTAssertEqual(model.essentials.count, 1)
        XCTAssertEqual(model.activeID, other.id)
    }

    func testRemovingAnEssentialReturnsItsTabToTheWorkspace() {
        let t = tab("https://mail.example/")
        model.addToEssentials(t)
        model.removeFromEssentials(model.essentials[0].id)
        XCTAssertTrue(model.essentials.isEmpty)
        XCTAssertTrue(model.visibleTabs.contains { $0.id == t.id })
        XCTAssertFalse(model.isEssentialTab(t))
    }

    func testPrivateAndInternalTabsCannotBecomeEssentials() {
        let p = model.openTab(url: nil, isPrivate: true)
        p.url = URL(string: "https://secret.example/")
        XCTAssertFalse(model.addToEssentials(p))
        let blank = model.openTab(url: nil, isPrivate: false)
        XCTAssertFalse(model.addToEssentials(blank))
        XCTAssertTrue(model.essentials.isEmpty)
    }

    func testTheLimitAndDuplicates() {
        for i in 0..<Essentials.maxCount { XCTAssertTrue(model.addToEssentials(tab("https://site\(i).example/"))) }
        XCTAssertFalse(model.addToEssentials(tab("https://one-too-many.example/")))
        XCTAssertEqual(model.essentials.count, Essentials.maxCount)
        model.removeFromEssentials(model.essentials[0].id)
        let again = tab(model.essentials[0].url)
        XCTAssertFalse(model.addToEssentials(again), "the same page is not added twice")
    }

    func testAnEssentialNeverOpensOutsideItsContainer() {
        model.setContainers(["Work"])
        let t = tab("https://crm.example/", container: "Work")
        model.addToEssentials(t)
        XCTAssertEqual(model.essentials[0].container, "Work")
        // Its page goes; the container is deleted. The Essential is removed rather than reopened in another identity.
        let before = model.tabs.count
        model.dropEssentials(inContainer: "Work")
        XCTAssertTrue(model.essentials.isEmpty)
        model.setContainers([])
        XCTAssertEqual(model.tabs.count, before)
    }

    func testAMissingContainerBlocksOpeningAndCreatesNoTab() {
        model.setContainers(["Work"])
        let t = tab("https://crm.example/", container: "Work")
        model.addToEssentials(t)
        model.closeTab(id: t.id, force: true)                 // really closed
        model.setContainers([])                               // the container is gone
        let before = model.tabs.count
        model.openEssential(model.essentials[0].id)
        XCTAssertEqual(model.tabs.count, before, "no tab is made in a different identity")
        XCTAssertNotNil(model.notice)
    }

    func testEssentialsPersistPerProfileAndForeignRecordsAreIgnored() {
        let t = tab("https://mail.example/")
        model.addToEssentials(t)
        let saved = model.essentials
        model.reloadEssentials()
        XCTAssertEqual(model.essentials, saved)
        // A record that belongs to another profile (copied in) is dropped when read.
        var foreign = saved[0]; foreign.profile = "someone-else"; foreign.id = "foreign"
        model.saveSetting("essentials", model.encodedMap(["list": saved + [foreign]]))
        model.reloadEssentials()
        XCTAssertEqual(model.essentials.map(\.id), saved.map(\.id))
    }

    // MARK: Pinned addresses

    func testPinningRegistersAnAddressAndResetGoesBackInTheSameTab() throws {
        let t = tab("https://docs.example/start")
        model.togglePin(t)
        XCTAssertEqual(model.pinnedHome(for: t)?.absoluteString, "https://docs.example/start")
        t.url = URL(string: "https://docs.example/elsewhere")
        model.resetPinnedTab(t)
        XCTAssertEqual(t.url?.absoluteString, "https://docs.example/start")
        XCTAssertTrue(model.tabs.contains { $0.id == t.id }, "the tab itself is kept")
    }

    func testSettingTheCurrentPageAsThePinnedAddressAndUnpinning() {
        let t = tab("https://docs.example/start")
        model.togglePin(t)
        t.url = URL(string: "https://docs.example/work")
        model.setCurrentPageAsPinnedAddress(t)
        XCTAssertEqual(model.pinnedHome(for: t)?.absoluteString, "https://docs.example/work")
        XCTAssertEqual(model.pinnedMetadata(for: t)?.originalURL, "https://docs.example/start")
        model.togglePin(t)
        XCTAssertNil(model.pinnedMetadata(for: t))
        XCTAssertTrue(model.pinnedAddresses.isEmpty, "an address nobody uses is not kept")
    }

    func testResetOnWorkspaceSwitchMarksOnlyTheTabsOfTheWorkspaceLeft() {
        model.createWorkspace("Work")
        let t = tab("https://docs.example/start")
        model.togglePin(t)
        model.setResetOnWorkspaceSwitch(t, true)
        let plain = tab("https://plain.example/")
        model.togglePin(plain)
        model.switchWorkspace("Work")
        XCTAssertTrue(model.pendingPinnedResets.contains(t.id))
        XCTAssertFalse(model.pendingPinnedResets.contains(plain.id))
        t.url = URL(string: "https://docs.example/drifted")
        model.switchWorkspace("")
        model.select(t.id)
        XCTAssertEqual(t.url?.absoluteString, "https://docs.example/start")
        XCTAssertFalse(model.pendingPinnedResets.contains(t.id))
    }

    // MARK: Clear tabs

    func testClearKeepsPinnedEssentialsAndLockedAndUndoBringsBack() {
        let pinned = tab("https://pinned.example/"); model.togglePin(pinned)
        let essential = tab("https://essential.example/"); model.addToEssentials(essential)
        let locked = tab("https://locked.example/"); model.setLockedTabs([locked.id])
        let a = tab("https://a.example/"), b = tab("https://b.example/")
        XCTAssertEqual(Set(model.clearableTabs().map(\.id)).intersection([a.id, b.id]).count, 2)
        model.clearTabs()
        XCTAssertFalse(model.tabs.contains { $0.id == a.id || $0.id == b.id })
        for kept in [pinned, essential, locked] { XCTAssertTrue(model.tabs.contains { $0.id == kept.id }) }
        XCTAssertNotNil(model.noticeUndo, "Undo is offered")
        let count = model.tabs.count
        model.noticeUndo?.run()
        let restored = model.tabs.filter { $0.url?.host == "a.example" || $0.url?.host == "b.example" }
        XCTAssertEqual(restored.count, 2)
        XCTAssertGreaterThan(model.tabs.count, count)
    }

    func testClearCanLeaveSleepingTabsAlone() {
        let a = tab("https://a.example/")
        XCTAssertTrue(model.clearableTabs(includeSleeping: false).contains { $0.id == a.id })
        XCTAssertTrue(model.clearableTabs(includeSleeping: true).contains { $0.id == a.id })
    }

    func testALargeClearAsksAndDontAskAgainIsRemembered() async {
        for i in 0..<ClearTabs.confirmFrom { tab("https://t\(i).example/") }
        var asked = 0
        Dialogs.testHandler = { _, _, buttons in asked += 1; return 1 }           // "Close and Don't Ask Again"
        model.clearTabs()
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(asked, 1)
        XCTAssertFalse(model.clearTabsAsks)
        XCTAssertTrue(model.clearableTabs().filter { $0.url != nil }.isEmpty)
    }
}

@MainActor
final class GlanceAndGroupTests: XCTestCase {
    private var model: BrowserModel!
    private var root = ""

    override func setUp() async throws {
        root = NSTemporaryDirectory() + "bs-gl-\(UUID().uuidString)"
        model = BrowserModel(engine: WebKitEngine(), root: root, profile: "gl")
    }

    override func tearDown() async throws {
        model = nil
        try? FileManager.default.removeItem(atPath: root)
    }

    private func page(_ url: String = "https://source.example/", container: String? = nil) -> TabController {
        let t = model.openTab(url: nil, isPrivate: false, container: container)
        t.url = URL(string: url)
        return t
    }

    func testOnlyOrdinaryWebAddressesCanBeGlanced() {
        for ok in ["https://a.example/x", "http://a.example"] { XCTAssertTrue(GlanceRules.isEligible(URL(string: ok)), ok) }
        for bad in ["javascript:alert(1)", "data:text/html,hi", "file:///etc/hosts", "browsersetu://panel/history", "https://user:pw@a.example/", "mailto:a@b.example", "https:///nohost"] {
            XCTAssertFalse(GlanceRules.isEligible(URL(string: bad)), bad)
        }
    }

    func testThePreviewIsInNoListAndKeepsTheSourcesContainer() {
        model.setContainers(["Work"])
        let source = page(container: "Work")
        model.glance.present(URL(string: "https://preview.example/")!, from: source)
        let preview = try! XCTUnwrap(model.glance.tab)
        XCTAssertEqual(model.tabMeta[preview.id]?.container, "Work", "it browses in the page's own identity, never another")
        XCTAssertFalse(model.visibleTabs.contains { $0.id == preview.id })
        XCTAssertFalse(model.clearableTabs().contains { $0.id == preview.id })
        XCTAssertTrue(model.isHiddenTab(preview))
        XCTAssertEqual(model.activeID, source.id, "the page in front does not change")
    }

    func testAPrivatePageGetsAPrivatePreviewAndATemporarySessionGetsItsOwnStorage() {
        let privatePage = model.openTab(url: nil, isPrivate: true)
        privatePage.url = URL(string: "https://secret.example/")
        model.glance.present(URL(string: "https://x.example/")!, from: privatePage)
        XCTAssertEqual(model.glance.tab?.isPrivate, true)
        model.glance.dismiss(animated: false)
        model.glanceTemporarySession = true
        let normal = page()
        model.glance.present(URL(string: "https://x.example/")!, from: normal)
        let preview = try! XCTUnwrap(model.glance.tab)
        XCTAssertEqual(model.tabMeta[preview.id]?.container, TabOrganizing.scratchContainer)
        XCTAssertEqual(model.tabMeta[preview.id]?.scratch, true)
    }

    func testOnePreviewAtATimeAndItGoesWhenAnotherTabIsChosen() {
        let a = page(), b = page("https://other.example/")
        model.select(a.id)
        model.glance.present(URL(string: "https://one.example/")!, from: a)
        let first = model.glance.tab?.id
        model.glance.present(URL(string: "https://two.example/")!, from: a)
        XCTAssertNotEqual(model.glance.tab?.id, first)
        XCTAssertFalse(model.tabs.contains { $0.id == first }, "the first preview is closed")
        model.select(b.id)
        XCTAssertNil(model.glance.session, "choosing another tab ends it")
        XCTAssertEqual(model.tabs.filter { $0.workspace == GlanceCoordinator.hiddenWorkspace }.count, 0)
    }

    func testClosingTheSourceEndsThePreview() {
        let a = page(), b = page("https://other.example/")
        model.select(a.id)
        model.glance.present(URL(string: "https://one.example/")!, from: a)
        model.closeTab(id: a.id)
        XCTAssertNil(model.glance.session)
        _ = b
    }

    func testPromotingMakesItAnOrdinaryTabInTheSourcesWorkspaceWithoutAReload() {
        model.createWorkspace("Work")
        model.switchWorkspace("Work")
        let source = page()
        model.glance.present(URL(string: "https://one.example/")!, from: source)
        let preview = try! XCTUnwrap(model.glance.tab)
        let webView = preview.hostView
        model.glance.promote()
        XCTAssertNil(model.glance.session)
        XCTAssertEqual(model.activeID, preview.id)
        XCTAssertEqual(preview.workspace, "Work")
        XCTAssertTrue(model.visibleTabs.contains { $0.id == preview.id })
        XCTAssertTrue(webView === model.tabs.first { $0.id == preview.id }?.hostView, "the same web view: nothing reloads")
        XCTAssertEqual(model.tabMeta[preview.id]?.parent, source.id)
    }

    func testAPopupFromThePreviewStaysInThePreviewOrIsDropped() {
        let source = page()
        model.glance.present(URL(string: "https://one.example/")!, from: source)
        let preview = try! XCTUnwrap(model.glance.tab)
        let before = model.tabs.count
        preview.engineOpenInNewTab(url: URL(string: "https://popup.example/")!, userInitiated: false)
        XCTAssertEqual(model.tabs.count, before, "no new tab")
        preview.engineOpenInNewTab(url: URL(string: "https://popup.example/")!, userInitiated: true)
        XCTAssertEqual(model.tabs.count, before, "a click-made one goes to the preview itself")
        XCTAssertEqual(preview.url?.host, "popup.example")
    }

    func testNestedGroupsHaveALimitAndCannotBeMovedIntoThemselves() {
        model.createGroup("A")
        model.createSubgroup(under: "A", named: "B")
        model.createSubgroup(under: "A/B", named: "C")
        model.createSubgroup(under: "A/B/C", named: "D")
        model.createSubgroup(under: "A/B/C/D", named: "E")
        XCTAssertTrue(model.groupNames.contains("A/B/C/D/E"), "five levels are allowed")
        model.createSubgroup(under: "A/B/C/D/E", named: "F")
        XCTAssertFalse(model.groupNames.contains("A/B/C/D/E/F"), "a sixth is refused")
        XCTAssertNotNil(model.notice)
        let before = model.groupNames
        model.renameGroup("A", to: "A/inner")
        XCTAssertEqual(model.groupNames, before, "a group cannot move inside itself")
        model.renameGroup("A/B/C/D/E", to: "A/B/C/D/E/x/y")
        XCTAssertEqual(model.groupNames, before, "a rename may not push anything past the limit")
        XCTAssertFalse(GroupPath.isValid("A//B"))
        XCTAssertFalse(GroupPath.isValid("/A"))
        XCTAssertTrue(GroupPath.isValid("A/B/C"))
    }
}

@MainActor
final class ClearUndoTests: XCTestCase {
    func testUndoOfALargeClearBringsMostTabsBackAsleep() {
        let root = NSTemporaryDirectory() + "bs-undo-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let model = BrowserModel(engine: WebKitEngine(), root: root, profile: "undo")
        model.clearTabsAsks = false
        let count = ClearTabs.loadedOnUndo + 4
        for i in 0..<count { let t = model.openTab(url: nil, isPrivate: false); t.url = URL(string: "https://t\(i).example/") }
        model.clearTabs()
        XCTAssertFalse(model.tabs.contains { $0.url?.host?.hasSuffix(".example") == true })
        model.noticeUndo?.run()
        let back = model.tabs.filter { $0.url?.host?.hasSuffix(".example") == true }
        XCTAssertEqual(back.count, count)
        XCTAssertEqual(back.filter(\.isDiscarded).count, count - ClearTabs.loadedOnUndo, "only the first few are loading; the rest wait to be shown")
        XCTAssertEqual(Set(back.compactMap { $0.url?.host }).count, count, "every address came back")
        // A waiting tab loads when it is shown.
        if let waiting = back.first(where: \.isDiscarded) { model.select(waiting.id); XCTAssertFalse(waiting.isDiscarded) }
    }
}
