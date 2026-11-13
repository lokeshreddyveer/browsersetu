import XCTest
@testable import Browser_Setu

/// Section 14: how Classic's tab organization behaves in the model: groups, nested groups, the empty group, workspaces, tree order, stacks, Essentials rules, protections, and the stored settings.
/// Every test uses a throwaway profile folder (and the test process's relocated home). Nothing here touches a real profile.
@MainActor
final class D1aClassicOrganizationTests: XCTestCase {
    private func model() -> BrowserModel {
        BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-org-\(UUID().uuidString)", profile: "default")
    }
    @discardableResult private func tab(_ m: BrowserModel, _ n: Int, select: Bool = false, opener: TabController? = nil) -> TabController {
        m.openTab(url: URL(string: "about:blank#\(n)")!, isPrivate: false, select: select, opener: opener)
    }

    // MARK: Defaults (ORG-03)

    func testTheDefaultsOfTheTabOrganizationSettings() {
        let m = model()
        XCTAssertFalse(m.doubleClickClosesTab, "double-click Close is off by default")
        XCTAssertFalse(m.hideTabCloseButtons)
        XCTAssertFalse(m.hideSingleTabStrip)
        XCTAssertTrue(m.hoverPreviews)
        XCTAssertEqual(m.hoverDelay, 0.6, accuracy: 0.001)
        XCTAssertFalse(m.closeWindowWithLastTab)
        XCTAssertFalse(m.tabTree)
        XCTAssertFalse(m.tabStacks)
        XCTAssertTrue(m.protectPinned)
        XCTAssertTrue(m.keepPinnedTabs)
    }

    // MARK: Groups (ORG-04…09)

    func testMovingATabIntoAGroupFiltersTheStrip() {
        let m = model()
        let a = tab(m, 1), b = tab(m, 2)
        m.createGroup("Work", moving: a)
        XCTAssertEqual(a.group, "Work")
        m.selectGroup("")
        XCTAssertFalse(m.visibleTabs.contains { $0.id == a.id }, "a grouped tab is not in the ungrouped strip")
        XCTAssertTrue(m.visibleTabs.contains { $0.id == b.id })
        m.selectGroup("Work")
        XCTAssertEqual(m.visibleTabs.map(\.id), [a.id], "the Work group shows only its own tab")
    }

    func testAParentGroupShowsItsDescendantsAndASubgroupOnlyItsOwn() {
        let m = model()
        let a = tab(m, 1), b = tab(m, 2)
        m.createGroup("Work")
        m.createSubgroup(under: "Work", named: "Project A")
        XCTAssertTrue(m.groupNames.contains("Work/Project A"), "groups are path strings: \(m.groupNames)")
        m.moveTab(a, to: "Work")
        m.moveTab(b, to: "Work/Project A")
        m.selectGroup("Work")
        XCTAssertEqual(Set(m.visibleTabs.map(\.id)), [a.id, b.id], "the parent shows its descendants")
        m.selectGroup("Work/Project A")
        XCTAssertEqual(m.visibleTabs.map(\.id), [b.id], "the subgroup shows only its own")
    }

    func testGroupsAreNestedFiveLevelsAtMost() {
        let m = model()
        var path = "L1"
        m.createGroup(path)
        for level in 2...5 { m.createSubgroup(under: path, named: "L\(level)"); path += "/L\(level)" }
        XCTAssertTrue(m.groupNames.contains(path), "five levels are allowed: \(m.groupNames)")
        m.createSubgroup(under: path, named: "L6")
        XCTAssertFalse(m.groupNames.contains(path + "/L6"), "a sixth level is refused")
    }

    /// ORG-06: choosing an empty group opens one blank tab in it, once.
    func testChoosingAnEmptyGroupOpensOneBlankTabInItOnce() {
        let m = model()
        tab(m, 1)
        m.createGroup("Empty")
        let before = m.tabs.count
        m.selectGroup("Empty")
        XCTAssertEqual(m.tabs.count, before + 1, "one tab is opened")
        XCTAssertEqual(m.visibleTabs.count, 1)
        XCTAssertEqual(m.visibleTabs.first?.group, "Empty", "it belongs to the group")
        XCTAssertEqual(m.visibleTabs.first?.workspace, m.activeWorkspace, "and to the workspace in front")
        m.selectGroup("Empty")
        XCTAssertEqual(m.tabs.count, before + 1, "choosing it again opens nothing more")
        m.selectGroup("")
        m.selectGroup("Empty")
        XCTAssertEqual(m.tabs.count, before + 1, "leaving and coming back opens nothing more")
        XCTAssertFalse(m.visibleTabs.first?.isPrivate ?? true, "an ordinary window opens an ordinary tab")
    }

    /// Selecting a tab that is in another group brings that group's view with it.
    func testSelectingATabInAnotherGroupSwitchesTheStripToIt() {
        let m = model()
        let a = tab(m, 1)
        m.createGroup("Work", moving: a)
        m.selectGroup("")
        XCTAssertEqual(m.activeGroup, "")
        m.select(a.id)
        XCTAssertEqual(m.activeGroup, "Work", "the strip follows the selected tab")
    }

    /// ORG-09: groups belong to the workspace in front, so the same name can exist in two workspaces.
    func testTheSameGroupNameInTwoWorkspaces() {
        let m = model()
        m.createGroup("Same")
        XCTAssertEqual(m.groupNames, ["Same"])
        m.createWorkspace("W1", icon: "bolt")
        m.switchWorkspace("W1")
        XCTAssertEqual(m.groupNames, [], "the other workspace has no groups yet")
        m.createGroup("Same")
        XCTAssertEqual(m.groupNames, ["Same"])
        m.switchWorkspace("")
        XCTAssertEqual(m.groupNames, ["Same"], "and Personal still has its own")
    }

    func testChoosingAGroupDoesNotChangeTheProfile() {
        let m = model()
        let profile = m.profileName
        m.createGroup("Work")
        m.selectGroup("Work")
        XCTAssertEqual(m.profileName, profile, "a group is not a profile")
    }

    // MARK: Persistence (ORG-07, ORG-23)

    func testGroupsAndTheTabSettingsSurviveARestart() async throws {
        let root = NSTemporaryDirectory() + "bs-org-\(UUID().uuidString)"
        let a = BrowserModel(engine: WebKitEngine(), root: root, profile: "default")
        await a.start()
        a.createGroup("Kept")
        a.tabStacks = true; a.doubleClickClosesTab = true; a.hideTabCloseButtons = true; a.hideSingleTabStrip = true; a.hoverDelay = 1.2
        let b = BrowserModel(engine: WebKitEngine(), root: root, profile: "default")
        await b.start()
        XCTAssertEqual(b.groupNames, ["Kept"])
        XCTAssertTrue(b.tabStacks); XCTAssertTrue(b.doubleClickClosesTab); XCTAssertTrue(b.hideTabCloseButtons); XCTAssertTrue(b.hideSingleTabStrip)
        XCTAssertEqual(b.hoverDelay, 1.2, accuracy: 0.001)
        XCTAssertEqual(b.activeGroup, "", "the group on show is not stored: a restart starts on the ungrouped tabs")
    }

    // MARK: Tree tabs (ORG-10…12)

    func testTreeOrderPutsEachChildRightAfterItsParent() {
        let order = TabOrganizing.treeOrder([(1, nil), (2, nil), (3, nil), (4, 1), (5, 4)])
        XCTAssertEqual(order, [1, 4, 5, 2, 3])
    }

    func testTurningTheTreeOnReordersTheRealTabsAndTheOpenerIsKept() {
        let m = model()
        let a = tab(m, 1), b = tab(m, 2), c = tab(m, 3)
        let d = tab(m, 4, opener: a)
        XCTAssertEqual(m.tabMeta[d.id]?.parent, a.id, "the opener is recorded")
        let ids = [a.id, b.id, c.id, d.id]
        func order() -> [UInt64] { m.tabs.map(\.id).filter { ids.contains($0) } }
        // A tab opened from another tab already sits beside its opener (placeNextToOpener) with the tree off; turning the tree on keeps the opener and keeps that order.
        XCTAssertEqual(order(), [a.id, d.id, b.id, c.id], "without the tree a tab opened from a link sits beside its opener")
        m.tabTree = true
        XCTAssertEqual(order(), [a.id, d.id, b.id, c.id], "with the tree on the child stays beside its parent")
        XCTAssertEqual(m.treeDepth(of: d), 1)
    }

    func testClosingAParentGivesItsChildrenToTheNextLevelUp() {
        let m = model()
        let a = tab(m, 1), d = tab(m, 4, opener: a)
        tab(m, 2, select: true)
        m.closeTab(id: a.id)
        XCTAssertNotEqual(m.tabMeta[d.id]?.parent, a.id, "the child no longer points at the closed parent")
    }

    // MARK: Stacks (ORG-13/14)

    /// The horizontal strip's list of tabs does not consult the stack setting.
    func testTheStackSettingDoesNotChangeWhatTheHorizontalStripListsNorTheOrder() {
        let m = model()
        tab(m, 1); tab(m, 2); tab(m, 3)
        let before = m.visibleTabs.map(\.id)
        m.tabStacks = true
        XCTAssertEqual(m.visibleTabs.map(\.id), before, "visibleTabs (the strip's list) is the same with stacks on")
        m.tabStacks = false
        XCTAssertEqual(m.visibleTabs.map(\.id), before)
    }

    // MARK: Combinations (ORG-16)

    func testTreeAndStacksDoNotChangeWhichTabsAGroupShows() {
        let m = model()
        let a = tab(m, 1), b = tab(m, 2)
        m.createGroup("Work", moving: a)
        m.selectGroup("Work")
        let shown = Set(m.visibleTabs.map(\.id))
        XCTAssertEqual(shown, [a.id])
        m.tabTree = true; m.tabStacks = true
        XCTAssertEqual(Set(m.visibleTabs.map(\.id)), shown, "the group still decides what is shown")
        XCTAssertFalse(m.visibleTabs.contains { $0.id == b.id })
        XCTAssertNotNil(m.active, "a tab stays selected")
    }

    // MARK: Protections and bulk closing (ORG-17)

    func testLockedAndPinnedTabsStayWhenOthersAreClosed() {
        let m = model()
        let keep = tab(m, 1, select: true), locked = tab(m, 2), pinned = tab(m, 3), plain = tab(m, 4)
        m.toggleLock(locked)
        m.togglePin(pinned)
        XCTAssertTrue(m.needsPinnedConfirmation(pinned.id), "a pinned tab asks before it closes")
        XCTAssertFalse(m.needsPinnedConfirmation(plain.id))
        m.closeTab(id: locked.id)
        XCTAssertTrue(m.tabs.contains { $0.id == locked.id }, "a locked tab is not closed")
        m.closeOtherTabs(except: keep.id)
        XCTAssertTrue(m.tabs.contains { $0.id == locked.id }, "Close Others leaves a locked tab")
        XCTAssertTrue(m.tabs.contains { $0.id == pinned.id }, "Close Others leaves a pinned tab")
        XCTAssertFalse(m.tabs.contains { $0.id == plain.id }, "and closes an ordinary one")
    }

    func testMovingATabLeftAndRightFollowsTheStrip() {
        let m = model()
        let a = tab(m, 1), b = tab(m, 2), c = tab(m, 3)
        let ids = [a.id, b.id, c.id]
        func order() -> [UInt64] { m.visibleTabs.map(\.id).filter { ids.contains($0) } }
        XCTAssertFalse(m.canMoveTab(a, by: -1), "the first cannot move left")
        m.moveTabAlong(b, by: -1)
        XCTAssertEqual(order(), [b.id, a.id, c.id])
        m.moveTabAlong(b, by: 1)
        XCTAssertEqual(order(), [a.id, b.id, c.id])
        XCTAssertFalse(m.canMoveTab(c, by: 1), "the last cannot move right")
    }

    // MARK: Essentials rules (ORG-17)

    func testEssentialsRules() {
        XCTAssertEqual(Essentials.maxCount, 12)
        XCTAssertTrue(Essentials.isEligible(URL(string: "https://example.com/a")))
        XCTAssertFalse(Essentials.isEligible(URL(string: "about:blank")), "a blank page cannot be an Essential")
        XCTAssertFalse(Essentials.isEligible(URL(string: "file:///tmp/x.html")))
        XCTAssertFalse(Essentials.isEligible(URL(string: "https://example.com/" + String(repeating: "a", count: 2100))))
        let record = EssentialTab(id: "1", profile: "default", url: "https://example.com/a", title: "A", container: nil, position: 0, createdAt: Date())
        XCTAssertNotNil(Essentials.isDuplicate([record], url: URL(string: "https://example.com/a/#top")!, container: nil), "a fragment and a trailing slash do not make a different page")
        XCTAssertNil(Essentials.isDuplicate([record], url: URL(string: "https://example.com/a")!, container: "work"), "another container is another Essential")
    }
}
