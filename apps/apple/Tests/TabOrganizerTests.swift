import XCTest
@testable import Browser_Setu

final class TabOrganizingRulesTests: XCTestCase {
    func testDepthsFollowTheTabEachWasOpenedFromAndNeverLoop() {
        let tabs: [(id: UInt64, parent: UInt64?)] = [(1, nil), (2, 1), (3, 2), (4, 99), (5, 6), (6, 5)]
        let depths = TabOrganizing.depths(tabs)
        XCTAssertEqual(depths[1], 0)
        XCTAssertEqual(depths[2], 1)
        XCTAssertEqual(depths[3], 2)
        XCTAssertEqual(depths[4], 0, "a parent that is gone leaves the tab at the top")
        XCTAssertLessThanOrEqual(depths[5] ?? 0, 1, "a loop ends")
    }

    func testTreeOrderPutsChildrenUnderParentsAndKeepsTheRest() {
        let tabs: [(id: UInt64, parent: UInt64?)] = [(1, nil), (2, nil), (3, 1), (4, 2), (5, 1)]
        XCTAssertEqual(TabOrganizing.treeOrder(tabs), [1, 3, 5, 2, 4])
        XCTAssertEqual(Set(TabOrganizing.treeOrder([(1, 2), (2, 1)])), [1, 2], "even a loop keeps every tab")
    }

    func testSiteNamesAndGroupNames() {
        XCTAssertEqual(TabOrganizing.siteName(forHost: "www.example.com"), "example.com")
        XCTAssertEqual(TabOrganizing.siteName(forHost: "docs.example.co.uk"), "example.co.uk")
        XCTAssertEqual(TabOrganizing.siteName(forHost: "localhost"), "localhost")
        XCTAssertEqual(TabOrganizing.groupName(forSite: "example.co.uk"), "Example")
    }

    func testContainerNamesAreCheckedAndColoursAreStable() {
        XCTAssertEqual(TabOrganizing.cleanContainerName("  Work 2 "), "Work 2")
        XCTAssertNil(TabOrganizing.cleanContainerName(""))
        XCTAssertNil(TabOrganizing.cleanContainerName("scratch"))
        XCTAssertNil(TabOrganizing.cleanContainerName("a/b"))
        XCTAssertNil(TabOrganizing.cleanContainerName(String(repeating: "x", count: 25)))
        XCTAssertEqual(TabOrganizing.containerColor("Work"), TabOrganizing.containerColor("Work"))
    }
}

@MainActor
final class TabOrganizerModelTests: XCTestCase {
    private func makeModel(root: String? = nil) -> BrowserModel {
        BrowserModel(engine: WebKitEngine(), root: root ?? NSTemporaryDirectory() + "bs-org-\(UUID().uuidString)", profile: "default")
    }

    func testNamesColoursStatusesAndNotesPersist() async throws {
        let root = NSTemporaryDirectory() + "bs-org-\(UUID().uuidString)"
        let model = makeModel(root: root)
        await model.start()
        let tab = model.openTab(url: nil, isPrivate: false)
        model.setTabName(tab, "  Budget  ")
        model.setTabColor(tab, .green)
        model.setTabStatus(tab, .doing)
        model.setTabNote(tab, "ask Sam")
        XCTAssertEqual(tab.displayTitle, "Budget")
        XCTAssertEqual(model.tabMeta[tab.id], TabMeta(name: "Budget", color: "green", status: .doing, note: "ask Sam"))
        model.setTabName(tab, "")
        model.setTabColor(tab, nil); model.setTabStatus(tab, nil); model.setTabNote(tab, "")
        XCTAssertNil(model.tabMeta[tab.id], "nothing left to remember, nothing kept")
    }

    func testAScratchTabLeavesNoTraceWhenClosed() async throws {
        let model = makeModel()
        await model.start()
        let before = model.closedTabs.count
        let scratch = model.openScratchTab()
        XCTAssertTrue(model.isScratch(scratch))
        XCTAssertEqual(model.container(of: scratch), TabOrganizing.scratchContainer)
        model.closeTab(id: scratch.id, force: true)
        XCTAssertEqual(model.closedTabs.count, before, "a scratch tab is not in Recently Closed")
        XCTAssertNil(model.tabMeta[scratch.id])
    }

    func testAContainerTabKeepsItsContainerAndANewTabFromItStaysInIt() async throws {
        let model = makeModel()
        await model.start()
        let tab = try XCTUnwrap(model.openTab(inContainer: "Work"))
        XCTAssertEqual(model.container(of: tab), "Work")
        XCTAssertEqual(model.containers, ["Work"])
        let child = model.openTab(url: nil, isPrivate: false, opener: tab, container: model.container(of: tab))
        XCTAssertEqual(model.container(of: child), "Work")
        XCTAssertEqual(model.tabMeta[child.id]?.parent, tab.id)
        XCTAssertNil(model.openTab(inContainer: "bad/name"))
    }

    func testPrivateTabsNeverGetAContainerOrAParent() async throws {
        let model = makeModel()
        await model.start()
        let parent = model.openTab(url: nil, isPrivate: false)
        let tab = model.openTab(url: nil, isPrivate: true, opener: parent, container: "Work", scratch: true)
        XCTAssertNil(model.tabMeta[tab.id])
    }

    func testTabTreePlacesAChildRightAfterItsParent() async throws {
        let model = makeModel()
        await model.start()
        model.tabTree = true
        let a = model.openTab(url: nil, isPrivate: false)
        let b = model.openTab(url: nil, isPrivate: false)
        let child = model.openTab(url: nil, isPrivate: false, opener: a)
        let order = model.tabs.map(\.id)
        let position = try XCTUnwrap(order.firstIndex(of: a.id))
        XCTAssertEqual(order[position + 1], child.id)
        XCTAssertEqual(model.treeDepth(of: child), 1)
        XCTAssertEqual(model.treeDepth(of: b), 0)
    }

    func testGroupingByWebsiteGroupsOnlySitesWithTwoOrMoreTabs() async throws {
        let model = makeModel()
        await model.start()
        let a = model.openTab(url: nil, isPrivate: false), b = model.openTab(url: nil, isPrivate: false), c = model.openTab(url: nil, isPrivate: false)
        for (tab, address) in [(a, "https://docs.example.com/1"), (b, "https://www.example.com/2"), (c, "https://other.test/3")] {
            tab.url = URL(string: address)!
        }
        XCTAssertEqual(model.groupTabsByWebsite(), 2)
        XCTAssertEqual(a.group, "Example")
        XCTAssertEqual(b.group, "Example")
        XCTAssertTrue(c.group.isEmpty)
    }

    func testSplitLayoutsAreSavedAndOpenedAgain() async throws {
        let model = makeModel()
        await model.start()
        let left = model.openTab(url: nil, isPrivate: false), right = model.openTab(url: nil, isPrivate: false, select: false)
        left.url = URL(string: "https://a.test/")!
        right.url = URL(string: "https://b.test/")!
        model.select(left.id)
        model.openSplit(with: right)
        model.saveSplitTemplate(named: "Docs")
        XCTAssertEqual(model.splitTemplates.first?.left, "https://a.test/")
        XCTAssertEqual(model.splitTemplates.first?.right, "https://b.test/")
        model.deleteSplitTemplate(try XCTUnwrap(model.splitTemplates.first))
        XCTAssertTrue(model.splitTemplates.isEmpty)
    }
}
