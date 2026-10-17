import XCTest
@testable import Browser_Setu

@MainActor
final class WindowTests: XCTestCase {
    private func pair() async -> (BrowserModel, BrowserModel) {
        let a = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-win-\(UUID().uuidString)", profile: "default")
        await a.start()
        let b = BrowserModel(sharing: a)
        b.hasStarted = true
        _ = b.openTab(url: nil, isPrivate: false)
        return (a, b)
    }

    func testWindowsShareTheDatabaseButNotTheirTabs() async throws {
        let (a, b) = await pair()
        XCTAssertEqual(a.windows.count, 2)
        XCTAssertTrue(a.windows === b.windows)
        XCTAssertTrue(b.isSecondary)
        try a.core.addBookmark(url: "https://shared.test", title: "Shared", folder: "")
        XCTAssertTrue(try b.core.isBookmarked(url: "https://shared.test"), "one database for every window")
        let tab = a.openTab(url: nil, isPrivate: false)
        XCTAssertTrue(a.tabs.contains { $0.id == tab.id })
        XCTAssertFalse(b.tabs.contains { $0.id == tab.id }, "each window shows only its own tabs")
        XCTAssertEqual(a.windows.model(forTab: tab.id) === a, true)
    }

    func testATabMovesToAnotherWindowWithItsPageAndNothingIsLost() async throws {
        let (a, b) = await pair()
        let tab = a.openTab(url: nil, isPrivate: false)
        tab.engine.showHTML("<html><body>moving</body></html>", baseURL: URL(string: "https://move.example.test/"))
        let before = a.tabs.count
        XCTAssertTrue(a.moveTab(tab.id, to: b))
        XCTAssertEqual(a.tabs.count, before - 1)
        XCTAssertTrue(b.tabs.contains { $0.id == tab.id })
        XCTAssertEqual(b.activeID, tab.id, "it is the one in front where it landed")
        XCTAssertNotNil(a.active, "the window it left still has a tab in front")
        XCTAssertFalse(a.moveTab(tab.id, to: b), "it is no longer there to move")
        XCTAssertFalse(a.moveTab(tab.id, to: a))
        // The tab belongs to the new window: closing it there empties nothing here.
        b.closeTab(id: tab.id)
        XCTAssertFalse(a.tabs.contains { $0.id == tab.id })
    }

    func testTheFirstWindowAlwaysKeepsATabAndAnEmptiedExtraWindowClosesItself() async throws {
        let (a, b) = await pair()
        var closed = 0
        b.onWindowShouldClose = { closed += 1 }
        // Move everything out of the first window: it gets a fresh tab instead of an empty window.
        for tab in a.tabs { a.moveTab(tab.id, to: b) }
        XCTAssertEqual(a.tabs.count, 1)
        XCTAssertEqual(closed, 0)
        // Close every tab of the extra window: the window asks to close.
        for tab in b.tabs { b.closeTab(id: tab.id, force: true) }
        XCTAssertEqual(closed, 1, "closing the last tab closes the extra window")
        XCTAssertNil(b.activeID)
    }

    func testMovingTheLastTabOutOfAnExtraWindowClosesIt() async throws {
        let (a, b) = await pair()
        var closed = 0
        b.onWindowShouldClose = { closed += 1 }
        for tab in b.tabs { b.moveTab(tab.id, to: a) }
        XCTAssertEqual(closed, 1)
        XCTAssertTrue(b.tabs.isEmpty)
    }

    func testSharedSettingsReachEveryWindowButEachKeepsItsOwnWorkspaceAndLayout() async throws {
        let (a, b) = await pair()
        a.createWorkspace("Work")
        b.createWorkspace("Home2")
        XCTAssertTrue(b.workspaces.contains { $0.name == "Work" }, "a workspace made in one window shows in the others")
        a.switchWorkspace("Work")
        b.switchWorkspace("")
        a.accent = .blue
        XCTAssertEqual(b.accent, .blue, "an appearance choice follows everywhere")
        XCTAssertEqual(a.activeWorkspace, "Work", "each window keeps its own workspace")
        XCTAssertEqual(b.activeWorkspace, "")
        #if os(macOS)
        b.layoutPreset = .sidebar
        a.accent = .green
        XCTAssertEqual(b.layoutPreset, .sidebar, "another window's change does not move this window's layout")
        #endif
    }

    func testNamesAndColoursOfTabsInAllWindowsAreSavedTogether() async throws {
        let (a, b) = await pair()
        let ta = a.openTab(url: nil, isPrivate: false), tb = b.openTab(url: nil, isPrivate: false)
        a.setTabName(ta, "Alpha")
        b.setTabName(tb, "Beta")
        let saved = BrowserModel.decodeMap(try a.core.getSetting(key: "tab_meta"), as: TabMeta.self)
        XCTAssertEqual(saved[String(ta.id)]?.name, "Alpha")
        XCTAssertEqual(saved[String(tb.id)]?.name, "Beta", "one window does not erase the other's names")
    }

    func testWhichTabsBelongedToWhichExtraWindowIsRemembered() async throws {
        let (a, b) = await pair()
        let t = b.openTab(url: nil, isPrivate: false)
        a.windows.saveWindowLayout(in: a)
        let reader = BrowserModel(sharing: a)
        reader.windows.loadPendingRestores(from: a)
        XCTAssertEqual(reader.windows.pendingRestores.count, 1)
        XCTAssertTrue(reader.windows.pendingRestores[0].contains(t.id))
        _ = b
    }

    func testAGuestWindowOnlyOpensPrivateTabsAndIsNotRemembered() async throws {
        let (a, b) = await pair()
        let guest = BrowserModel(sharing: a)
        a.windows.openingGuest = true
        guest.startSecondaryWindow()
        XCTAssertTrue(guest.isGuest)
        XCTAssertFalse(a.windows.openingGuest, "the request is used up by the one window it was for")
        XCTAssertTrue(guest.tabs.allSatisfy(\.isPrivate) && !guest.tabs.isEmpty, "its first tab is private")
        let normal = guest.openTab(url: nil, isPrivate: false)
        XCTAssertTrue(normal.isPrivate, "even a tab asked to be normal is private in a guest window")
        let outsider = b.openTab(url: nil, isPrivate: false)
        XCTAssertFalse(b.moveTab(outsider.id, to: guest), "a normal tab cannot be moved into a guest window")
        a.windows.saveWindowLayout(in: a)
        let reader = BrowserModel(sharing: a)
        reader.windows.loadPendingRestores(from: a)
        XCTAssertFalse(reader.windows.pendingRestores.joined().contains(normal.id), "a guest window is not brought back at the next start")
        XCTAssertFalse(a.isGuest)
    }
}
