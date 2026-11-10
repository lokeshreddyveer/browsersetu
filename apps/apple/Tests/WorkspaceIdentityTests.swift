import XCTest
@testable import Browser_Setu

@MainActor
final class WorkspaceIdentityTests: XCTestCase {
    private var root = ""
    private var model: BrowserModel!

    override func setUp() async throws {
        root = NSTemporaryDirectory() + "bs-wi-\(UUID().uuidString)"
        model = BrowserModel(engine: WebKitEngine(), root: root, profile: "wi")
    }

    override func tearDown() async throws {
        model = nil
        try? FileManager.default.removeItem(atPath: root)
    }

    private func page(_ url: String = "https://a.example/") -> TabController {
        let t = model.openTab(url: nil, isPrivate: false)
        t.url = URL(string: url)
        return t
    }

    // MARK: One answer to "which tabs are listed"

    func testListedTabsLeaveOutEssentialsPreviewsAndPanels() {
        let normal = page("https://n.example/")
        let essential = page("https://e.example/"); model.addToEssentials(essential)
        model.glance.present(URL(string: "https://g.example/")!, from: normal)
        let preview = try! XCTUnwrap(model.glance.tab)
        let listed = model.listedTabs(inWorkspace: model.activeWorkspace).map(\.id)
        XCTAssertTrue(listed.contains(normal.id))
        XCTAssertFalse(listed.contains(essential.id))
        XCTAssertFalse(listed.contains(preview.id))
        XCTAssertEqual(model.visibleTabs.map(\.id).filter { [essential.id, preview.id].contains($0) }, [])
        XCTAssertEqual(model.workspaceTabCount(""), listed.count)
        XCTAssertTrue(model.belongsInLists(normal))
        XCTAssertFalse(model.belongsInLists(essential))
        XCTAssertTrue(model.isHiddenTab(preview))
        XCTAssertFalse(model.isHiddenTab(essential), "an Essential is searchable and shown, just not listed in a workspace")
    }

    // MARK: Hidden identity

    func testWorkspacesGetAnIdentityThatARenameKeeps() {
        model.createWorkspace("Work")
        let id = try! XCTUnwrap(model.workspaces.first?.uid)
        model.renameWorkspace("Work", to: "Office")
        XCTAssertEqual(model.workspaces.first?.name, "Office")
        XCTAssertEqual(model.workspaces.first?.uid, id)
        XCTAssertEqual(try SpaceLookup.resolve(id, in: model.workspaces).get(), "Office", "the old request, written with the id, still finds it")
    }

    func testOlderWorkspacesWithoutAnIdentityAreGivenOne() throws {
        let old = #"[{"name":"Work","icon":"briefcase"}]"#
        model.saveSetting("workspaces", old)
        let reopened = BrowserModel(engine: WebKitEngine(), root: root, profile: "wi")
        XCTAssertNil(reopened.workspaces.first?.uid)
        reopened.ensureWorkspaceIDs()
        let first = try XCTUnwrap(reopened.workspaces.first?.uid)
        let again = BrowserModel(engine: WebKitEngine(), root: root, profile: "wi")
        XCTAssertEqual(again.workspaces.first?.uid, first, "and it was saved")
    }

    // MARK: A rename follows everything that remembers the name

    func testRenamingAWorkspaceCarriesItsTabsRulesSessionsAndGroupsAlong() async {
        model.createWorkspace("Work")
        model.switchWorkspace("Work")
        let tab = page("https://w.example/")
        model.createGroup("Project")
        model.moveTab(tab, to: "Project")
        model.workbench.setSiteRules([SiteOpenRule(host: "w.example", action: .workspace("Work"))])
        model.focusRules = [FocusRule(name: "Mornings", workspace: "Work")]
        model.saveSession(named: "Saved", group: nil)
        model.saveSetting("startup_workspace", "Work")
        model.closedTabs = [ClosedTab(url: URL(string: "https://c.example/")!, title: "c", group: "", workspace: "Work")]
        model.takeCheckpoint(reason: "t", force: true)
        let before = model.activeWorkspace

        model.renameWorkspace("Work", to: "Office")

        XCTAssertEqual(before, "Work")
        XCTAssertEqual(model.activeWorkspace, "Office")
        XCTAssertEqual(tab.workspace, "Office")
        XCTAssertEqual(model.groupLists["Office"], ["Project"])
        XCTAssertNil(model.groupLists["Work"])
        XCTAssertEqual(model.groupNames, ["Project"])
        XCTAssertEqual(model.workbench.siteRules.first?.action, .workspace("Office"))
        XCTAssertEqual(model.focusRules.first?.workspace, "Office")
        XCTAssertEqual(model.savedSessions.first?.workspace, "Office")
        XCTAssertEqual(model.closedTabs.first?.workspace, "Office")
        XCTAssertTrue(model.checkpoints.flatMap(\.tabs).allSatisfy { $0.workspace != "Work" })
        XCTAssertEqual(try? model.core.getSetting(key: "startup_workspace"), "Office")
        XCTAssertTrue(model.pendingPinnedResets.isEmpty, "a rename is not leaving the workspace")
    }

    func testARenameToATakenOrEmptyNameChangesNothing() {
        model.createWorkspace("A"); model.createWorkspace("B")
        model.renameWorkspace("A", to: "B")
        model.renameWorkspace("A", to: "  ")
        XCTAssertEqual(model.workspaces.map(\.name), ["A", "B"])
    }

    // MARK: Groups belong to a workspace

    func testTheSameGroupNameInTwoWorkspacesIsTwoGroups() {
        model.createWorkspace("Work")
        model.createGroup("Reading")
        let personalTab = page("https://p.example/"); model.moveTab(personalTab, to: "Reading")
        model.switchWorkspace("Work")
        XCTAssertEqual(model.groupNames, [], "Personal's group is not Work's")
        model.createGroup("Reading")
        XCTAssertEqual(model.groupNames, ["Reading"])
        let workTab = page("https://w.example/"); model.moveTab(workTab, to: "Reading")
        XCTAssertEqual(model.tabCount(inGroup: "Reading"), 1)
        model.deleteGroup("Reading")
        XCTAssertEqual(workTab.group, "")
        XCTAssertEqual(personalTab.group, "Reading", "deleting Work's group leaves Personal's tabs alone")
        model.switchWorkspace("")
        XCTAssertEqual(model.groupNames, ["Reading"])
    }

    func testDeletingAWorkspaceMovesItsGroupedTabsAndListsTheirGroupsInPersonal() {
        model.createWorkspace("Work")
        model.switchWorkspace("Work")
        model.createGroup("Plans")
        let tab = page("https://w.example/"); model.moveTab(tab, to: "Plans")
        model.deleteWorkspace("Work")
        XCTAssertEqual(tab.workspace, "")
        XCTAssertEqual(model.activeWorkspace, "")
        XCTAssertTrue(model.groupNames.contains("Plans"), "the tab's group is listed where the tab now is")
        XCTAssertNil(model.groupLists["Work"])
    }

    func testGroupsSavedBeforeWorkspacesOwnedThemAreSortedIntoPlace() async throws {
        model.createWorkspace("Work")
        let tab = model.openTab(url: nil, isPrivate: false)
        try model.core.setTabWorkspace(tabId: tab.id, workspace: "Work")
        try model.core.setTabGroup(tabId: tab.id, group: "Old")
        model.saveNow()
        try model.core.setSetting(key: "tab_groups", value: #"["Old","Unused"]"#)
        XCTAssertNil(try model.core.getSetting(key: "tab_groups_v2"), "nothing in the new form yet")
        let reopened = BrowserModel(engine: WebKitEngine(), root: root, profile: "wi")
        await reopened.start()
        XCTAssertEqual(reopened.groupLists["Work"], ["Old"], "a group goes where its tabs are")
        XCTAssertEqual(reopened.groupLists[""], ["Unused"], "one no tab uses goes to Personal")
        XCTAssertNotNil(try reopened.core.getSetting(key: "tab_groups_v2"), "and the new form is saved")
    }
}
