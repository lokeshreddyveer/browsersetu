import XCTest
@testable import Browser_Setu

@MainActor
final class WorkspaceAndPerformanceTests: XCTestCase {
    private func makeModel(root: String? = nil, profile: String = "default") -> BrowserModel {
        BrowserModel(engine: WebKitEngine(), root: root ?? NSTemporaryDirectory() + "bs-wp-\(UUID().uuidString)", profile: profile)
    }

    // MARK: Workspaces

    func testWorkspacesOrganiseTabsWithoutTouchingProfileData() async throws {
        let model = makeModel()
        await model.start()
        try model.core.addBookmark(url: "https://keep.example", title: "keep", folder: "")
        model.createWorkspace("Work", icon: "briefcase")
        model.createWorkspace("Work")                       // duplicate ignored
        model.createWorkspace("   ")                        // empty ignored
        XCTAssertEqual(model.workspaces.map(\.name), ["Work"])
        let personal = model.active!
        model.switchWorkspace("Work")
        XCTAssertEqual(model.activeWorkspace, "Work")
        XCTAssertFalse(model.visibleTabs.contains { $0.id == personal.id }, "other workspace's tabs hidden")
        let work = model.active!
        XCTAssertEqual(work.workspace, "Work")
        model.switchWorkspace("")
        XCTAssertTrue(model.visibleTabs.contains { $0.id == personal.id })
        XCTAssertFalse(model.visibleTabs.contains { $0.id == work.id })
        XCTAssertEqual(try model.core.listBookmarks(query: "").count, 1, "bookmarks are per profile, not per workspace")
        model.renameWorkspace("Work", to: "Job")
        XCTAssertEqual(work.workspace, "Job")
        model.deleteWorkspace("Job")
        XCTAssertEqual(work.workspace, "", "deleting a workspace keeps its tabs")
        XCTAssertTrue(model.tabs.contains { $0.id == work.id })
    }

    func testWorkspacesAndTheirLayoutPersist() async throws {
        let root = NSTemporaryDirectory() + "bs-wp-\(UUID().uuidString)"
        let a = makeModel(root: root)
        await a.start()
        a.createWorkspace("Dev", icon: "hammer")
        a.setWorkspacePreset("Dev", preset: .sidebar)
        a.switchWorkspace("Dev")
        XCTAssertEqual(a.layoutPreset, .sidebar, "workspace layout applied on switch")
        a.saveNow()
        let b = makeModel(root: root)
        XCTAssertEqual(b.workspaces.first?.icon, "hammer")
        XCTAssertEqual(b.workspaces.first?.preset, "sidebar")
        XCTAssertEqual(b.activeWorkspace, "Dev", "startup workspace restored")
    }

    func testMovingTabsBetweenWorkspaces() async throws {
        let model = makeModel()
        await model.start()
        model.createWorkspace("A")
        let tab = model.active!
        model.moveTab(tab, toWorkspace: "A")
        XCTAssertEqual(tab.workspace, "A")
        XCTAssertFalse(model.visibleTabs.contains { $0.id == tab.id })
        XCTAssertNotNil(model.active, "a tab remains selected after the move")
    }

    // MARK: Reordering

    func testReorderingTabsUpdatesCoreOrder() async throws {
        let model = makeModel()
        await model.start()
        let a = model.tabs[0]
        let b = model.newTab(), c = model.newTab()
        model.reorder(c.id, before: a.id)
        XCTAssertEqual(model.tabs.map(\.id), [c.id, a.id, b.id])
        XCTAssertEqual(try model.core.listTabs().map(\.id), [c.id, a.id, b.id], "core order follows the UI")
        model.reorder(c.id, before: nil)
        XCTAssertEqual(model.tabs.last?.id, c.id)
    }

    // MARK: Split view

    func testSplitViewOwnsOneLiveViewPerPanelAndRespectsPrivacy() async throws {
        let model = makeModel()
        await model.start()
        let a = model.active!
        let b = model.newTab()
        model.select(a.id)
        let viewA = a.hostView, viewB = b.hostView
        model.openSplit(with: b)
        XCTAssertEqual(model.splitTabID, b.id)
        XCTAssertTrue(a.hostView === viewA && b.hostView === viewB, "split view reuses the existing live views")
        XCTAssertFalse(viewA === viewB)
        model.swapSplit()
        XCTAssertEqual(model.activeID, b.id)
        XCTAssertEqual(model.splitTabID, a.id)
        let priv = model.openTab(url: nil, isPrivate: true, select: false)
        model.openSplit(with: priv)
        XCTAssertEqual(model.splitTabID, a.id, "private tabs cannot join a normal split")
        model.closeTab(id: a.id)
        XCTAssertNil(model.splitTabID, "closing a panel's tab closes the split")
    }

    // MARK: WebView preservation (performance requirement)

    func testLayoutChangesNeverRecreateWebViews() async throws {
        let model = makeModel()
        await model.start()
        let tab = model.active!
        let engineTab = tab.engine as AnyObject
        let view = tab.hostView
        for preset in LayoutPreset.allCases + [.classic] { model.layoutPreset = preset }
        model.sidebarRail.toggle(); model.sidebarPosition = .right; model.density = .compact
        model.toggleFocusMode(); model.toggleFocusMode()
        model.showOverview(); model.hideOverview()
        XCTAssertTrue(tab.engine as AnyObject === engineTab)
        XCTAssertTrue(tab.hostView === view, "web view must survive every layout change")
    }

    // MARK: Find

    func testFindStateResetsOnClose() async throws {
        let model = makeModel()
        await model.start()
        model.showFind()
        XCTAssertTrue(model.findVisible)
        model.findText = "x"
        model.hideFind()
        XCTAssertFalse(model.findVisible)
        XCTAssertEqual(model.findText, "")
    }

    // MARK: Omnibox keyboard selection

    func testSuggestionSelectionWrapsWithinBounds() async throws {
        let model = makeModel()
        await model.start()
        let bar = model.addressBar
        bar.isEditing = true
        bar.text = "swift"
        bar.refresh(model: model)
        XCTAssertFalse(bar.suggestions.isEmpty)
        XCTAssertNil(bar.selection)
        bar.moveSelection(1); XCTAssertEqual(bar.selection, 0)
        for _ in 0..<20 { bar.moveSelection(1) }
        XCTAssertEqual(bar.selection, bar.suggestions.count - 1)
        for _ in 0..<20 { bar.moveSelection(-1) }
        XCTAssertEqual(bar.selection, 0)
        XCTAssertFalse(bar.suggestions.contains { $0.target.lowercased().hasPrefix("javascript:") }, "dangerous schemes are never suggested")
    }

    func testDangerousInputBecomesASearchNotANavigation() async throws {
        let model = makeModel()
        await model.start()
        let bar = model.addressBar
        bar.isEditing = true
        bar.text = "javascript:alert(1)"
        bar.refresh(model: model)
        XCTAssertEqual(bar.suggestions.first?.kind, .search)
    }

    func testSiteOriginKeysMatchPermissionKeys() {
        XCTAssertEqual(originString(for: URL(string: "https://a.example/x?y=1")), "https://a.example")
        XCTAssertEqual(originString(for: URL(string: "http://localhost:3000/p")), "http://localhost:3000")
        XCTAssertNil(originString(for: URL(string: "file:///etc/hosts")))
        XCTAssertNil(originString(for: nil))
    }

    // MARK: Performance measurements

    func testTabSwitchingLatency() async throws {
        let model = makeModel()
        await model.start()
        for _ in 0..<40 { model.newTab() }
        let ids = model.tabs.map(\.id)
        measure(metrics: [XCTClockMetric()]) {
            for id in ids { model.select(id) }
        }
    }

    func testLayoutSwitchingLatency() async throws {
        let model = makeModel()
        await model.start()
        for _ in 0..<40 { model.newTab() }
        measure(metrics: [XCTClockMetric()]) {
            for _ in 0..<10 { for preset in LayoutPreset.allCases { model.layoutPreset = preset } }
        }
    }

    func testClosingManyTabsDoesNotLeakMemory() async throws {
        let model = makeModel()
        await model.start()
        let baseline = currentMemoryFootprint()
        for _ in 0..<30 { model.newTab() }
        for tab in model.tabs.dropFirst() { model.closeTab(id: tab.id) }
        try await Task.sleep(for: .seconds(1))
        let after = currentMemoryFootprint()
        // Generous bound: blank tabs should not leave tens of MB behind once closed.
        XCTAssertLessThan(Int64(after) - Int64(baseline), 80 * 1024 * 1024, "memory grew \(Int64(after) - Int64(baseline)) bytes after closing tabs")
    }
}
