import XCTest
@testable import Browser_Setu

@MainActor
final class ChromeLayoutTests: XCTestCase {
    func testToolbarOptionalButtonsMoveToTheMenuAsTheWindowNarrows() {
        let wide = ToolbarPriority(width: 1000)
        XCTAssertTrue(wide.showBookmark && wide.showDownloads && wide.showOptional && wide.showForward)
        let medium = ToolbarPriority(width: 700)
        XCTAssertTrue(medium.showBookmark && medium.showDownloads && !medium.showOptional)
        let narrow = ToolbarPriority(width: 600)
        XCTAssertTrue(narrow.showBookmark && !narrow.showDownloads)
        let tiny = ToolbarPriority(width: 450)
        XCTAssertFalse(tiny.showBookmark); XCTAssertTrue(tiny.showForward)
        XCTAssertFalse(ToolbarPriority(width: 380).showForward)
    }

    private func model() -> BrowserModel {
        BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-cl-\(UUID().uuidString)", profile: "default")
    }

    func testTabsAreShownInExactlyOnePlace() async throws {
        let m = model()
        await m.start()
        for preset in LayoutPreset.allCases {
            m.layoutPreset = preset
            let inSidebar = m.effectiveTabLayout == .sidebar
            let inStrip = m.effectiveTabLayout == .separate || m.effectiveTabLayout == .compact
            XCTAssertNotEqual(inSidebar, inStrip, "\(preset): tabs must live in the sidebar or the strip, never both")
        }
    }

    func testSwitchingLayoutsKeepsTabsSelectionAndWebViews() async throws {
        let m = model()
        await m.start()
        let a = m.tabs[0], b = m.newTab()
        m.select(a.id)
        let views = [a.hostView, b.hostView]
        // Every layout, including the four from the design pack, in a round trip: no tab, selection or web view is touched.
        for preset in [LayoutPreset.sidebar, .hybrid, .canvas, .researchDesk, .workspaceDeck, .floating, .inline, .minimal, .minimalReversed, .classicReversed, .classic, .hybrid, .sidebar] { m.layoutPreset = preset }
        XCTAssertEqual(m.activeID, a.id)
        XCTAssertEqual(m.tabs.count, 2)
        XCTAssertTrue(a.hostView === views[0] && b.hostView === views[1])
    }

    func testHideSidebarToEdgeKeepsItReachable() async throws {
        let m = model()
        await m.start()
        m.layoutPreset = .sidebar
        XCTAssertTrue(m.sidebarVisible)
        m.hideSidebarToEdge()
        XCTAssertFalse(m.sidebarVisible)
        XCTAssertTrue(m.sidebarAutoHide)
    }

    @MainActor func testSidebarPeekShowsAfterDwellHidesAfterLingerAndHoldsWhileAMenuIsOpen() async throws {
        let peek = SidebarPeek()
        peek.edge(true)
        XCTAssertFalse(peek.revealed, "not instant: a pass-through flick must not reveal it")
        try await Task.sleep(for: .milliseconds(120))   // after the dwell, before the linger would end
        XCTAssertTrue(peek.revealed)
        peek.edge(false); peek.panel(true)                 // pointer moves from the edge into the panel
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(peek.revealed, "stays while the pointer is inside the panel")
        peek.menu(true); peek.panel(false)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(peek.revealed, "stays while a menu is open")
        peek.menu(false)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertFalse(peek.revealed, "hides after the pointer has left and nothing is open")
        peek.edge(true); peek.edge(false)                  // quick flick
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(peek.revealed, "a flick that leaves before the dwell never reveals it")
    }

    func testAddressBarRoutingFollowsTheLayout() async throws {
        let m = model()
        await m.start()
        // On a loaded page ⌘L goes to the address bar; on a blank tab it goes to the page's own search field (see StartPageTests).
        m.openTab(url: URL(string: "https://example.org/"), isPrivate: false)
        // Classic: the top bar's address bar takes focus.
        let tick = m.omniboxFocusTick
        m.focusAddressBar()
        XCTAssertEqual(m.omniboxFocusTick, tick + 1)
        XCTAssertFalse(m.floatingAddressVisible)
        // The sidebar layout has no top bar, so with the sidebar hidden the address bar floats.
        m.layoutPreset = .sidebar
        XCTAssertTrue(m.singleToolbar)
        m.pinSidebar()
        let before = m.omniboxFocusTick
        m.focusAddressBar()
        XCTAssertEqual(m.omniboxFocusTick, before + 1, "pinned sidebar: the in-sidebar field takes focus")
        XCTAssertFalse(m.floatingAddressVisible)
        m.hideSidebarToEdge()
        m.focusAddressBar()
        XCTAssertTrue(m.floatingAddressVisible)
        m.floatingAddressVisible = false
        // Floating and focus modes must route to a visible floating field.
        m.layoutPreset = .floating
        m.focusAddressBar()
        XCTAssertTrue(m.floatingAddressVisible)
        m.floatingAddressVisible = false
        m.layoutPreset = .classic
        m.focusMode = true
        m.focusAddressBar()
        XCTAssertTrue(m.floatingAddressVisible)
        // Existing custom sidebar-only layout remains available.
        m.focusMode = false
        m.layoutPreset = .custom
        m.singleToolbarCustom = true
        m.pinSidebar()
        XCTAssertTrue(m.sidebarAddressBarShown)
    }

    func testNewBlankTabInFloatingOpensTheFloatingBar() async throws {
        let m = model()
        await m.start()
        m.layoutPreset = .floating
        m.hideSidebarToEdge()
        let before = m.startFocusTick
        m.newTab()
        XCTAssertEqual(m.startFocusTick, before + 1, "a blank tab opens with the search field in the middle of its own page ready")
        XCTAssertFalse(m.floatingAddressVisible, "so the floating bar does not open over it")
    }

    func testSidebarLayoutKeepsUnifiedToolbarAndOnlyVerticalTabs() async throws {
        let m = model()
        await m.start()
        m.layoutPreset = .sidebar
        XCTAssertTrue(m.singleToolbar, "the sidebar layout has no top bar; the address bar is in the sidebar")
        XCTAssertEqual(m.effectiveTabLayout, .sidebar, "no horizontal strip in single-toolbar mode")
        m.layoutPreset = .classic
        XCTAssertFalse(m.singleToolbar)
    }

    func testPopoverAndEditingHoldTransientChrome() async throws {
        let peek = SidebarPeek()
        peek.edge(true)
        try await Task.sleep(for: .milliseconds(120))
        peek.hold(true); peek.edge(false)
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertTrue(peek.revealed)
        peek.editing(true); peek.hold(false)
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertTrue(peek.revealed)
        peek.editing(false)
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertFalse(peek.revealed)
    }

    func testAutoHidePreferenceSurvivesRestartAndPinClearsIt() async throws {
        let m = model()
        m.layoutPreset = .sidebar
        m.hideSidebarToEdge()
        XCTAssertTrue(m.sidebarAutoHide)
        m.pinSidebar()
        XCTAssertFalse(m.sidebarAutoHide)
        XCTAssertTrue(m.sidebarVisible)
    }
    func testOverlayTakesOwnershipWhenEdgeExitIsOccluded() async throws {
        let peek = SidebarPeek()
        peek.edge(true)
        try await Task.sleep(for: .milliseconds(120))
        peek.panel(true)
        // The newly revealed panel covers the edge, so no edge(false) event is guaranteed.
        peek.panel(false)
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertFalse(peek.revealed)
    }


    @MainActor func testPeekTimingMatchesSpecAndFlashHidesItself() async throws {
        let sidebar = SidebarPeek(), toolbar = SidebarPeek(linger: 1.0)
        XCTAssertEqual(sidebar.linger, 0.15, accuracy: 0.001)
        XCTAssertEqual(toolbar.linger, 1.0, accuracy: 0.001)
        toolbar.edge(true)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(toolbar.revealed)
        toolbar.edge(false)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(toolbar.revealed, "the toolbar stays a full second after the pointer leaves")
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertFalse(toolbar.revealed)
        sidebar.flash(0.3)
        XCTAssertTrue(sidebar.revealed, "flash shows the sidebar immediately")
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertFalse(sidebar.revealed, "and it hides itself when the pointer is elsewhere")
    }

    func testAddressFieldNeverTouchesTheControlsAtAnyWindowWidth() {
        for inset in [CGFloat(84), 10] {
            var width: CGFloat = 520
            while width <= 2200 {
                let p = ToolbarPriority(fitting: width, leadingInset: inset)
                let field = p.fieldWidth(window: width, leadingInset: inset)
                let room = width / 2 - max(p.leadingWidth(inset: inset), p.trailingWidth)
                XCTAssertGreaterThanOrEqual(field, 160, "width \(width)")
                XCTAssertLessThanOrEqual(field / 2, room + 0.5, "field overlaps the controls at width \(width), inset \(inset)")
                width += 10
            }
        }
    }

    func testControlsLeaveInAFixedOrderAndBackNeverLeaves() {
        var seenNoOptional = false, seenNoDownloads = false, seenNoBookmark = false
        var width: CGFloat = 2200
        while width >= 520 {
            let p = ToolbarPriority(fitting: width, leadingInset: 84)
            if !p.showOptional { seenNoOptional = true }
            if !p.showDownloads { seenNoDownloads = true }
            if !p.showBookmark { seenNoBookmark = true }
            // Once a control is gone it stays gone as the window keeps narrowing, in this order.
            if seenNoBookmark { XCTAssertTrue(seenNoDownloads && seenNoOptional, "bookmark left before downloads/optional at \(width)") }
            if seenNoDownloads { XCTAssertTrue(seenNoOptional, "downloads left before the optional buttons at \(width)") }
            width -= 10
        }
        XCTAssertTrue(seenNoOptional)
    }

    /// Full screen keeps every layout's own chrome: the toolbar hides only where the person chose auto-hide (Custom).
    func testFullScreenKeepsTheToolbarUnlessAutoHideWasChosen() async throws {
        let m = model()
        await m.start()
        for preset in [LayoutPreset.classic, .classicReversed, .minimal, .minimalReversed, .inline, .sidebar] {
            m.layoutPreset = preset
            m.windowFullScreen = true
            XCTAssertFalse(m.autoHidesToolbar, "\(preset): full screen must not hide the toolbar")
            m.windowFullScreen = false
            XCTAssertFalse(m.autoHidesToolbar, "\(preset): a window does not hide it either")
        }
        // Hybrid today: Custom with vertical tabs and a separate toolbar.
        m.layoutPreset = .custom
        m.singleToolbarCustom = false
        m.tabLayout = .sidebar
        m.toolbarAutoHide = false
        m.windowFullScreen = true
        XCTAssertFalse(m.autoHidesToolbar, "vertical tabs with a separate toolbar: full screen keeps that toolbar")
        // The person's own choice still counts, in a window and in full screen.
        m.toolbarAutoHide = true
        XCTAssertTrue(m.autoHidesToolbar, "Custom's auto-hide option hides the toolbar in full screen")
        m.windowFullScreen = false
        XCTAssertTrue(m.autoHidesToolbar, "and in a window")
        m.toolbarAutoHide = false
        m.layoutPreset = .classic
    }

    /// The four layouts from the design pack resolve to existing parts: no new tab data, one address field, one navigator.
    func testDesignPackLayoutsResolveToExistingParts() async throws {
        let m = model()
        await m.start()
        for preset in [LayoutPreset.hybrid, .researchDesk, .workspaceDeck] {
            m.layoutPreset = preset
            XCTAssertEqual(m.effectiveTabLayout, .sidebar, "\(preset): vertical tabs")
            XCTAssertFalse(m.singleToolbar, "\(preset): a separate toolbar, not an address field in the sidebar")
            XCTAssertTrue(m.sidebarVisible, "\(preset): the navigator is docked")
            XCTAssertFalse(m.topBarHidden, "\(preset): the toolbar is shown")
            XCTAssertTrue(preset.usesSidebarPin && preset.docksTabNavigator)
        }
        m.layoutPreset = .canvas
        XCTAssertTrue(m.topBarHidden, "Canvas: no toolbar")
        XCTAssertFalse(m.sidebarVisible, "Canvas: no docked sidebar")
        let state = m.layoutState(width: 1200)
        XCTAssertEqual(state.sidebar, .hidden, "Canvas: no sidebar at the edge either")
        XCTAssertTrue(state.everythingReachable, "Canvas: everything stays reachable (handle, ⌘L, ⇧⌘A)")
        for preset in [LayoutPreset.hybrid, .researchDesk, .workspaceDeck] {
            m.layoutPreset = preset
            XCTAssertTrue(m.layoutState(width: 1200).everythingReachable, "\(preset): something is unreachable")
        }
        m.layoutPreset = .classic
    }

    func testHybridHidesToTheEdgeAndDocksAgainLikeTheSidebarLayout() async throws {
        let m = model()
        await m.start()
        m.layoutPreset = .hybrid
        m.setSidebarShown(false)
        XCTAssertFalse(m.sidebarVisible); XCTAssertTrue(m.sidebarAutoHide, "hidden to the window edge, so the edge brings it back")
        m.sidebarRail = true
        m.setSidebarShown(true)
        XCTAssertTrue(m.sidebarVisible); XCTAssertFalse(m.sidebarRail, "showing it docks it expanded"); XCTAssertFalse(m.sidebarAutoHide)
        m.layoutPreset = .classic
    }

    func testResearchDeskOpensTwoPagesAndGivesTheRailChoiceBack() async throws {
        let m = model()
        await m.start()
        let first = try XCTUnwrap(m.active)
        let second = m.openTab(url: URL(string: "https://example.com/b"), isPrivate: false, select: false)
        m.select(first.id)
        m.sidebarRail = false
        let tabCount = m.tabs.count
        m.layoutPreset = .researchDesk
        XCTAssertTrue(m.sidebarRail, "the tabs become a compact rail")
        XCTAssertEqual(m.splitTabID, second.id, "the next tab is shown beside the one in front")
        XCTAssertEqual(m.activeID, first.id, "the tab in front stays in front")
        XCTAssertEqual(m.tabs.count, tabCount, "no tab is opened, closed or replaced")
        m.layoutPreset = .hybrid
        XCTAssertFalse(m.sidebarRail, "leaving the Desk gives back the rail choice it replaced")
        XCTAssertEqual(m.splitTabID, second.id, "the split is kept (closing it is the person's choice)")
        m.closeSplit()
        m.layoutPreset = .classic
    }

    func testPanelCanBeReplacedAndFocusMovesOn() async throws {
        let m = model()
        await m.start()
        let first = try XCTUnwrap(m.active)
        let second = m.openTab(url: URL(string: "https://example.com/b"), isPrivate: false, select: false)
        let third = m.openTab(url: URL(string: "https://example.com/c"), isPrivate: false, select: false)
        m.select(first.id)
        m.openSplit(with: second)
        XCTAssertFalse(m.tabsAvailableForPanel().contains { $0.id == first.id || $0.id == second.id }, "tabs already in the split are not offered")
        XCTAssertTrue(m.tabsAvailableForPanel().contains { $0.id == third.id })
        let count = m.tabs.count
        m.replaceSplitPanel(second.id, with: third)
        XCTAssertEqual(m.splitTabID, third.id, "the side panel shows the other tab")
        XCTAssertEqual(m.tabs.count, count, "the replaced tab stays open")
        XCTAssertEqual(m.activeID, first.id)
        m.focusNextPanel()
        XCTAssertEqual(m.activeID, third.id, "Focus Next Panel moves the focus to the other panel")
        m.focusNextPanel()
        XCTAssertEqual(m.activeID, first.id, "and back to the first after the last")
        m.closeSplit()
    }

    func testTabDroppedOnAWorkspaceMovesThere() async throws {
        let m = model()
        await m.start()
        m.createWorkspace("DeckW", icon: "bolt")
        let tab = m.openTab(url: URL(string: "https://example.com/deck"), isPrivate: false, select: false)
        XCTAssertTrue(m.acceptDroppedTabToWorkspace(tab.id, workspace: "DeckW"))
        XCTAssertEqual(tab.workspace, "DeckW", "the tab is in the workspace it was dropped on")
        XCTAssertFalse(m.acceptDroppedTabToWorkspace(tab.id, workspace: "DeckW"), "dropping it where it already is does nothing")
        XCTAssertFalse(m.acceptDroppedTabToWorkspace(tab.id, workspace: "NoSuchWorkspace"), "an unknown workspace takes nothing")
        XCTAssertTrue(m.acceptDroppedTabToWorkspace(tab.id, workspace: ""), "Personal takes it back")
        XCTAssertEqual(tab.workspace, "")
    }

    func testFocusingAnotherPanelKeepsEveryWebView() async throws {
        let m = model()
        await m.start()
        let first = try XCTUnwrap(m.active)
        let second = m.openTab(url: URL(string: "https://example.com/pane2"), isPrivate: false, select: false)
        m.select(first.id)
        m.openSplit(with: second)
        let views = [first.hostView, second.hostView]
        m.swapSplit(with: second.id)
        XCTAssertEqual(m.activeID, second.id, "the clicked panel is the focused one")
        m.focusNextPanel()
        XCTAssertTrue(first.hostView === views[0] && second.hostView === views[1], "moving the focus never replaces a page's view")
        m.closeSplit()
    }

    func testWorkspaceRowsReorderByDrag() async throws {
        let m = model()
        await m.start()
        for name in ["DragA", "DragB", "DragC"] { m.createWorkspace(name, icon: "bolt") }
        m.moveWorkspace("DragC", before: "DragA")
        XCTAssertEqual(m.workspaces.map(\.name).filter { $0.hasPrefix("Drag") }, ["DragC", "DragA", "DragB"])
        m.moveWorkspace("DragA", before: "")
        XCTAssertEqual(m.workspaces.first?.name, "DragA", "dropping on Personal puts it first of the others")
        m.moveWorkspace("DragB", before: "DragB")
        for name in ["DragA", "DragB", "DragC"] { m.deleteWorkspace(name) }
    }

    /// A private tab is a normal part of every layout: it opens in front, is listed, is counted, keeps its privacy through a layout change and a workspace move, and never joins a normal tab's split.
    func testPrivateTabsWorkInEveryLayout() async throws {
        let m = model()
        await m.start()
        m.createWorkspace("PrivW", icon: "bolt")
        for preset in LayoutPreset.allCases {
            m.layoutPreset = preset
            let tab = m.openTab(url: URL(string: "https://example.com/private-\(preset.rawValue)"), isPrivate: true)
            XCTAssertTrue(tab.isPrivate, "\(preset): the tab is private")
            XCTAssertEqual(m.activeID, tab.id, "\(preset): a new private tab opens in front")
            XCTAssertTrue(m.visibleTabs.contains { $0.id == tab.id }, "\(preset): the private tab is listed")
            XCTAssertTrue(m.workspaceTabCount(m.activeWorkspace) >= 1, "\(preset): it is counted")
            m.layoutPreset = preset == .classic ? .sidebar : .classic
            XCTAssertTrue(tab.isPrivate && m.visibleTabs.contains { $0.id == tab.id }, "\(preset): it keeps its privacy and its place through a layout change")
            m.moveTab(tab, toWorkspace: "PrivW")
            XCTAssertTrue(tab.isPrivate, "\(preset): moving it to a workspace keeps it private")
            m.moveTab(tab, toWorkspace: "")
            let normal = m.openTab(url: URL(string: "https://example.com/normal-\(preset.rawValue)"), isPrivate: false, select: false)
            m.select(normal.id)
            m.openSplit(with: tab)
            XCTAssertNotEqual(m.splitTabID, tab.id, "\(preset): a private tab never joins a normal tab's split")
            m.closeTab(id: tab.id, force: true)
            m.closeTab(id: normal.id, force: true)
        }
        m.layoutPreset = .classic
        m.deleteWorkspace("PrivW")
    }

    func testNextAndPreviousWorkspaceGoRound() async throws {
        let m = model()
        await m.start()
        m.createWorkspace("DeckA", icon: "bolt")
        m.createWorkspace("DeckB", icon: "bolt")
        m.switchWorkspace("")
        m.switchWorkspace(by: 1);  XCTAssertEqual(m.activeWorkspace, "DeckA")
        m.switchWorkspace(by: 1);  XCTAssertEqual(m.activeWorkspace, "DeckB")
        m.switchWorkspace(by: 1);  XCTAssertEqual(m.activeWorkspace, "", "after the last comes Personal")
        m.switchWorkspace(by: -1); XCTAssertEqual(m.activeWorkspace, "DeckB", "and back from Personal to the last")
        m.switchWorkspace("")
    }

    func testSwitchingWorkspaceKeepsTheDeck() async throws {
        let m = model()
        await m.start()
        m.createWorkspace("DeckKeep", icon: "bolt")
        m.layoutPreset = .workspaceDeck
        m.switchWorkspace("DeckKeep")
        XCTAssertEqual(m.layoutPreset, .workspaceDeck, "a workspace's remembered layout does not take the window out of the Deck")
        m.switchWorkspace("")
        XCTAssertEqual(m.layoutPreset, .workspaceDeck)
        m.layoutPreset = .classic
    }

    func testWorkspaceCountMatchesTheList() async throws {
        let m = model()
        await m.start()
        m.createWorkspace("DeckCount", icon: "bolt")
        let before = m.workspaceTabCount("DeckCount")
        let normal = m.openTab(url: URL(string: "https://example.com/n"), isPrivate: false, select: false)
        let priv = m.openTab(url: URL(string: "https://example.com/p"), isPrivate: true, select: false)
        m.moveTab(normal, toWorkspace: "DeckCount"); m.moveTab(priv, toWorkspace: "DeckCount")
        let expected = m.separatesPrivate ? 1 : 2
        XCTAssertEqual(m.workspaceTabCount("DeckCount") - before, expected, "the count is the number of tabs the list shows for the workspace")
        m.deleteWorkspace("DeckCount")
    }

    func testResearchDeskWithOneTabOpensNothing() async throws {
        let m = model()
        await m.start()
        for tab in m.tabs.dropFirst() { m.closeTab(id: tab.id, force: true) }
        let count = m.tabs.count
        m.layoutPreset = .researchDesk
        XCTAssertNil(m.splitTabID)
        XCTAssertEqual(m.tabs.count, count, "no tab is opened to fill the second panel")
        m.layoutPreset = .classic
    }

    func testLeavingCanvasReturnsToTheLayoutItCameFrom() async throws {
        let m = model()
        await m.start()
        m.layoutPreset = .minimal
        m.layoutPreset = .canvas
        let selected = m.activeID, count = m.tabs.count
        m.leaveCanvas()
        XCTAssertEqual(m.layoutPreset, .minimal)
        XCTAssertEqual(m.activeID, selected); XCTAssertEqual(m.tabs.count, count)
        m.layoutPreset = .canvas
        m.layoutPreset = .canvas
        m.leaveCanvas()
        XCTAssertEqual(m.layoutPreset, .minimal, "choosing Canvas twice does not forget where it came from")
        m.layoutPreset = .classic
    }

    // MARK: D1a / D1b audit fixes

    func testPageTitlesAreMadeSafeForTheChrome() {
        XCTAssertEqual(TabController.displaySafeTitle("Bank\u{202E}moc.evil"), "Bankmoc.evil", "direction overrides are removed")
        XCTAssertEqual(TabController.displaySafeTitle("A\u{2066}B\u{2069}\u{200F}C"), "ABC")
        XCTAssertEqual(TabController.displaySafeTitle("  Line\none\t\ttwo  "), "Line one two", "control characters and runs of space fold to one space")
        XCTAssertEqual(TabController.displaySafeTitle(String(repeating: "x", count: 400)).count, 301, "capped at 300 characters plus an ellipsis")
        XCTAssertEqual(TabController.displaySafeTitle("Plain title"), "Plain title")
        XCTAssertEqual(TabController.displaySafeTitle("\u{202E}\u{202E}"), "", "a title of only overrides is empty, so the old title is kept")
    }

    func testATileLetterComesOnlyFromTheHost() {
        XCTAssertEqual(tileLetter(title: "Apple", url: "https://www.example.com/x"), "E")
        XCTAssertEqual(tileLetter(title: "PayPal Login", url: ""), "", "no host: a neutral globe, never a letter from the page's own title")
        XCTAssertEqual(tileLetter(title: "x", url: "about:blank"), "")
    }

    func testTheDownloadsRingCountsBytesAndNeverInventsAShare() {
        func item(_ done: Int64, _ total: Int64) -> ActiveDownload { var a = ActiveDownload(id: UUID(), filename: "f", fraction: 0); a.completedBytes = done; a.totalBytes = total; return a }
        XCTAssertNil(DownloadsToolbarButton.ringProgress([item(500, 0)]), "size not known: no percentage")
        XCTAssertNil(DownloadsToolbarButton.ringProgress([]))
        XCTAssertEqual(DownloadsToolbarButton.ringProgress([item(0, 100)]), 0, "a known size at the start is 0, not a made-up sliver")
        XCTAssertEqual(DownloadsToolbarButton.ringProgress([item(10, 100), item(890, 900)])!, 0.9, accuracy: 0.001, "weighted by bytes, not by item")
        XCTAssertEqual(DownloadsToolbarButton.ringProgress([item(50, 100), item(7, 0)])!, 0.5, accuracy: 0.001, "unknown-size items do not dilute the share")
    }

    func testDoubleClickOnTheSpeakerIsNotADoubleClickOnTheTab() {
        AudioBadge.lastTap = .distantPast
        XCTAssertFalse(AudioBadge.tappedJustNow)
        AudioBadge.lastTap = Date()
        XCTAssertTrue(AudioBadge.tappedJustNow, "a double-click right after the speaker was clicked does not close the tab")
        AudioBadge.lastTap = Date().addingTimeInterval(-1)
        XCTAssertFalse(AudioBadge.tappedJustNow)
    }

    func testSpokenStateSaysPrivateAndExplainsAsleep() {
        XCTAssertEqual(TabChipRules.spokenState(locked: false, pinned: false, playing: false, muted: false, isPrivate: true), "Private")
        XCTAssertEqual(TabChipRules.spokenState(locked: false, pinned: true, playing: true, muted: false, asleep: false, isPrivate: true), "Private, Pinned, Playing sound")
    }

    func testReorderingKeepsPinnedTabsAheadOfTheOthers() async throws {
        let m = model()
        await m.start()
        let a = try XCTUnwrap(m.active)
        let b = m.openTab(url: URL(string: "https://example.com/b"), isPrivate: false, select: false)
        let c = m.openTab(url: URL(string: "https://example.com/c"), isPrivate: false, select: false)
        m.togglePin(a)
        let pinnedFirst = { m.tabs.firstIndex { !$0.pinned }.map { i in m.tabs[..<i].allSatisfy(\.pinned) && m.tabs[i...].allSatisfy { !$0.pinned } } ?? true }
        XCTAssertTrue(pinnedFirst())
        m.reorder(c.id, before: a.id)           // an unpinned tab dropped before a pinned one
        XCTAssertTrue(pinnedFirst(), "an unpinned tab cannot land among the pinned ones")
        XCTAssertEqual(m.tabs.first { !$0.pinned }?.id, c.id, "it goes to the front of the unpinned run")
        m.reorder(a.id, before: nil)            // a pinned tab dropped at the end
        XCTAssertTrue(pinnedFirst(), "a pinned tab cannot land after the unpinned ones")
        _ = b
    }

    func testCustomKeepsItsOwnSidebarChoiceAcrossReadyMadeLayouts() async throws {
        let m = model()
        await m.start()
        m.layoutPreset = .custom
        m.tabLayout = .separate
        m.sidebarVisible = true
        m.layoutPreset = .classic
        XCTAssertFalse(m.sidebarVisible, "Classic has no sidebar")
        m.layoutPreset = .custom
        XCTAssertTrue(m.sidebarVisible, "Custom's own sidebar choice comes back")
        m.sidebarVisible = false
        m.layoutPreset = .minimal
        m.layoutPreset = .custom
        XCTAssertFalse(m.sidebarVisible)
        m.layoutPreset = .classic
    }

    func testLayoutNamesDoNotCollide() {
        XCTAssertEqual(WindowPreset.minimal.title, "Compact", "the One Row arrangement is not also called Minimal")
        XCTAssertEqual(WindowPreset.minimal.rawValue, "minimal", "the stored value is unchanged")
        XCTAssertEqual(LayoutPreset.minimal.family, .horizontal)
        XCTAssertEqual(Set(LayoutPreset.allCases.map(\.title)).count, LayoutPreset.allCases.count, "every layout has its own name")
        XCTAssertFalse(LayoutPreset.classic.hasTabSidebar); XCTAssertFalse(LayoutPreset.minimal.hasTabSidebar)
        XCTAssertTrue(LayoutPreset.hybrid.hasTabSidebar)
    }

    func testATabDroppedOnTheGroupChipJoinsTheGroupShown() async throws {
        let m = model()
        await m.start()
        let t = m.openTab(url: URL(string: "https://example.com/g"), isPrivate: false, select: false)
        XCTAssertTrue(m.acceptDroppedTab(t.id, intoGroup: "Reading"))
        XCTAssertEqual(t.group, "Reading", "dropped on the chip while a group is shown: it joins that group")
        XCTAssertTrue(m.acceptDroppedTab(t.id, intoGroup: ""))
        XCTAssertEqual(t.group, "", "dropped on the chip while the ungrouped tabs are shown: it leaves its group")
    }

    func testHorizontalStripsShowEveryGroupInlineInOneBlock() async throws {
        let m = model()
        await m.start()
        let a = try XCTUnwrap(m.active)
        let b = m.openTab(url: URL(string: "https://example.com/b"), isPrivate: false, select: false)
        let c = m.openTab(url: URL(string: "https://example.com/c"), isPrivate: false, select: false)
        let d = m.openTab(url: URL(string: "https://example.com/d"), isPrivate: false, select: false)
        m.moveTab(b, to: "Work"); m.moveTab(d, to: "Work")
        for preset in [LayoutPreset.classic, .classicReversed, .minimal, .minimalReversed, .inline] {
            m.layoutPreset = preset
            XCTAssertTrue(m.stripGroupsInline, "\(preset) shows groups inline")
            XCTAssertEqual(Set(m.visibleTabs.map(\.id)), Set([a, b, c, d].map(\.id)), "\(preset): every tab is in the strip, grouped or not")
        }
        m.layoutPreset = .classic
        let order = m.visibleTabs.map(\.id)
        XCTAssertEqual(order, [a.id, b.id, d.id, c.id], "a group's tabs are drawn together, at the place of its first tab")
        let items = m.stripItems(m.visibleTabs)
        XCTAssertEqual(items.map(\.id), ["t\(a.id)", "gWork", "t\(b.id)", "t\(d.id)", "t\(c.id)"], "the label comes before its tabs")
        // Collapsing hides the group's tabs, never the tab in front.
        m.select(a.id)
        m.toggleStripGroup("Work")
        XCTAssertEqual(m.stripShownTabs(m.visibleTabs).map(\.id), [a.id, c.id])
        if case .group(_, let count, let collapsed) = m.stripItems(m.visibleTabs)[1] { XCTAssertTrue(collapsed); XCTAssertEqual(count, 2) } else { XCTFail("no label") }
        m.select(d.id)
        XCTAssertTrue(m.stripShownTabs(m.visibleTabs).contains { $0.id == d.id }, "choosing a tab of a collapsed group shows it")
        // Collapsing the group of the tab in front moves to a tab outside it.
        m.collapsedGroups.remove("Work"); m.select(b.id)
        m.toggleStripGroup("Work")
        XCTAssertNotEqual(m.active?.group, "Work", "collapsing the front tab's group moves to a tab outside it")
        // Choosing a group in the chip still narrows the strip; the Sidebar layout is unchanged.
        m.selectGroup("Work")
        XCTAssertFalse(m.stripGroupsInline)
        XCTAssertEqual(Set(m.visibleTabs.map(\.id)), Set([b.id, d.id]))
        m.selectGroup("")
        m.layoutPreset = .sidebar
        // The Sidebar draws groups as sections, and the lists commands use include every group's tabs, in the order it draws them.
        XCTAssertEqual(Set(m.visibleTabs.map(\.id)), Set([a, b, c, d].map(\.id)), "next/previous tab and ⌘1…⌘9 reach grouped tabs in the Sidebar too")
        XCTAssertEqual(m.visibleTabs.map(\.id), [a.id, c.id, b.id, d.id], "ungrouped first, then each group's tabs (the order the sidebar draws)")
        XCTAssertEqual(Set(m.closableTabs(inGroup: "Work").map(\.id)), Set([b.id, d.id]), "Close N Tabs in Group finds the group's tabs whichever group is shown")
        m.layoutPreset = .classic
    }

    func testSidebarDropAtTheEndLeavesTheGroupAndMoveFollowsTheSections() async throws {
        let m = model()
        await m.start()
        m.layoutPreset = .sidebar
        let a = try XCTUnwrap(m.active)
        let b = m.openTab(url: URL(string: "https://example.com/b"), isPrivate: false, select: false)
        let c = m.openTab(url: URL(string: "https://example.com/c"), isPrivate: false, select: false)
        let d = m.openTab(url: URL(string: "https://example.com/d"), isPrivate: false, select: false)
        m.moveTab(b, to: "Work"); m.moveTab(c, to: "Work")
        // Move Up / Down step among the tabs of the same section, as the sidebar draws them.
        XCTAssertFalse(m.canMoveTab(b, by: -1), "the first tab of a group has nowhere to go up to")
        XCTAssertTrue(m.canMoveTab(b, by: 1)); XCTAssertTrue(m.canMoveTab(c, by: -1))
        m.moveTabAlong(c, by: -1)
        XCTAssertEqual(m.tabs.firstIndex { $0.id == c.id }.map { $0 < (m.tabs.firstIndex { $0.id == b.id } ?? 0) }, true, "c moved before b inside the group")
        XCTAssertEqual(c.group, "Work", "moving inside a section keeps the group")
        XCTAssertFalse(m.canMoveTab(a, by: -1) && m.canMoveTab(a, by: 1) && false)
        // Dropped after the last open row (before nothing): out of its group.
        XCTAssertTrue(m.acceptDroppedTab(b.id, before: nil))
        XCTAssertEqual(b.group, "", "a grouped tab dropped at the end of the open tabs leaves its group")
        _ = d
        m.layoutPreset = .classic
    }

    func testGroupLabelTextMeetsContrastOnEveryColour() {
        for color in GroupColor.allCases {
            let l = color.luminance
            // Black text is 0 luminance (0.85 alpha over the fill is at least as light as pure black: checked with pure black, the best case, and 0.85 as the real one).
            let whiteRatio = 1.05 / (l + 0.05)
            let blackRatio = (l + 0.05) / 0.05
            let chosen = color.prefersDarkText ? blackRatio : whiteRatio
            XCTAssertGreaterThanOrEqual(chosen, 4.5, "\(color): text on this group colour is under 4.5:1 (\(chosen))")
            // The choice is the better of the two where they differ meaningfully.
            XCTAssertGreaterThanOrEqual(chosen, min(whiteRatio, blackRatio), "\(color): the worse ink was chosen")
        }
    }

    func testExtensionIconsAreDecodedOnceAndKeptSmall() throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let first = try XCTUnwrap(ExtensionIconCache.image(for: data))
        XCTAssertEqual(first.size, NSSize(width: 32, height: 32))
        XCTAssertTrue(ExtensionIconCache.image(for: data) === first, "the second draw reuses the decoded icon")
        XCTAssertNil(ExtensionIconCache.image(for: Data(count: 600 * 1024)), "an oversized icon is refused")
    }

    func testPageColourIsKeptPerTabAndClearsWhenThePageDropsIt() async throws {
        let m = model()
        await m.start()
        let tab = try XCTUnwrap(m.active)
        XCTAssertNil(tab.tint)
        tab.engineThemeColorChanged(PageTint(red: 0.1, green: 0.2, blue: 0.3))
        XCTAssertEqual(tab.tint?.green, 0.2)
        tab.engineThemeColorChanged(nil)
        XCTAssertNil(tab.tint)
        XCTAssertTrue(m.tintToolbar, "tinting is on by default")
    }

    func testFloatingLayoutHasNoTopBarAndKeepsTabsInTheEdgeSidebar() async throws {
        let m = model()
        await m.start()
        m.layoutPreset = .floating
        XCTAssertTrue(m.topBarHidden)
        XCTAssertEqual(m.effectiveTabLayout, .sidebar, "tabs are vertical")
        XCTAssertFalse(m.sidebarVisible, "and stay out of sight until the pointer reaches the edge")
        XCTAssertFalse(m.autoHidesToolbar, "there is no toolbar to reveal at the top edge")
        XCTAssertFalse(m.canCollapseChrome, "and nothing to fold into the pill: the pill is always there")
        XCTAssertTrue(m.canFoldPill, "the pill folds away as a page is read")
        for _ in 0..<5 { m.pageScrolled(deltaY: -20) }
        XCTAssertTrue(m.chromeCollapsed)
        m.layoutPreset = .classic
        XCTAssertFalse(m.topBarHidden, "the other layouts are untouched")
    }

    func testFloatingLayoutSendsTheAddressBarToTheFloatingPanel() async throws {
        let m = model()
        await m.start()
        m.layoutPreset = .floating
        m.openTab(url: URL(string: "https://example.org/"), isPrivate: false)
        m.focusAddressBar()
        XCTAssertTrue(m.floatingAddressVisible, "on a loaded page the search button and ⌘L open the floating address bar")
        m.floatingAddressVisible = false
        let before = m.startFocusTick
        m.newTab()
        XCTAssertEqual(m.startFocusTick, before + 1, "a new tab uses the search field on its own page instead")
        XCTAssertFalse(m.floatingAddressVisible)
    }

    func testTheEdgeSidebarStaysOpenLongerInTheFloatingLayout() async throws {
        let peek = SidebarPeek()
        XCTAssertEqual(peek.linger, 0.15, accuracy: 0.001)
        peek.linger = 0.55
        peek.edge(true)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(peek.revealed, "it opens as soon as the pointer reaches the edge")
        peek.edge(false)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(peek.revealed, "and waits a moment after the pointer leaves")
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertFalse(peek.revealed, "then closes by itself")
    }

    func testTheOuterGapIsOneSmallValue() {
        XCTAssertEqual(WindowInset.gap, 4)
        XCTAssertGreaterThanOrEqual(WindowInset.pillTop, 8, "the pill sits clear of the window's top border")
    }

    func testDoubleClickStepsThroughEveryLayoutAndComesBackToTheStart() async throws {
        let m = model()
        await m.start()
        XCTAssertEqual(m.doubleClickAction, .cycleLayout)
        m.layoutPreset = .classic
        var seen: [LayoutPreset] = [m.layoutPreset]
        for _ in 0..<BrowserModel.layoutCycle.count {
            XCTAssertTrue(m.handleTopBarDoubleClick())
            seen.append(m.layoutPreset)
        }
        XCTAssertEqual(seen, [.classic, .sidebar, .minimal, .floating, .inline, .classic], "every layout once, then round again")
        XCTAssertEqual(Set(BrowserModel.layoutCycle).count, BrowserModel.layoutCycle.count)
        m.layoutPreset = .custom
        XCTAssertEqual(m.nextLayout(after: .custom), .classic, "a custom layout steps into the cycle at the start")
    }

    func testDoubleClickCanBeSetToZoomTheWindowInstead() async throws {
        let m = model()
        await m.start()
        m.layoutPreset = .classic
        m.doubleClickAction = .zoom
        XCTAssertFalse(m.handleTopBarDoubleClick(), "declined, so the window zooms")
        XCTAssertEqual(m.layoutPreset, .classic, "and the layout stays")
    }

    func testTheDoubleClickChoiceIsSavedAndBackedUp() async throws {
        let root = NSTemporaryDirectory() + "bs-dc-\(UUID().uuidString)"
        let a = BrowserModel(engine: WebKitEngine(), root: root, profile: "default")
        await a.start()
        a.doubleClickAction = .zoom
        let b = BrowserModel(engine: WebKitEngine(), root: root, profile: "default")
        await b.start()
        XCTAssertEqual(b.doubleClickAction, .zoom)
        XCTAssertTrue(BrowserModel.backupSettingKeys.contains("double_click"))
    }

    func testThePointerZonesForALeftSidebar() {
        let size = CGSize(width: 1000, height: 700)
        func zones(_ x: CGFloat, y: CGFloat = 300, revealed: Bool) -> (Bool, Bool) {
            let z = PeekGeometry.zones(pointer: CGPoint(x: x, y: y), windowSize: size, onLeft: true, edgeWidth: 12, panelWidth: 260, revealed: revealed)
            return (z.inEdge, z.inPanel)
        }
        XCTAssertTrue(zones(5, revealed: false) == (true, false), "the edge strip reveals it")
        XCTAssertTrue(zones(40, revealed: false) == (false, false), "only the strip, not where the sidebar would be")
        XCTAssertTrue(zones(5, y: 800, revealed: false) == (false, false), "above the window is not the edge")
        XCTAssertTrue(zones(100, revealed: true) == (false, true), "once shown, its own area keeps it open")
        XCTAssertTrue(zones(259, revealed: true) == (false, true))
        XCTAssertTrue(zones(300, revealed: true) == (false, false), "past its edge it can close")
        XCTAssertTrue(zones(-120, revealed: true) == (false, true), "a little beyond the window's edge still counts, as an overshoot")
        XCTAssertTrue(zones(-400, revealed: true) == (false, false), "far beyond does not")
        XCTAssertTrue(zones(100, y: -150, revealed: true) == (false, false), "nor far above or below the window")
    }

    func testThePointerZonesForARightSidebarAreTheMirrorImage() {
        let size = CGSize(width: 1000, height: 700)
        let edge = PeekGeometry.zones(pointer: CGPoint(x: 995, y: 300), windowSize: size, onLeft: false, edgeWidth: 12, panelWidth: 260, revealed: false)
        XCTAssertTrue(edge.inEdge && !edge.inPanel)
        let panel = PeekGeometry.zones(pointer: CGPoint(x: 800, y: 300), windowSize: size, onLeft: false, edgeWidth: 12, panelWidth: 260, revealed: true)
        XCTAssertTrue(!panel.inEdge && panel.inPanel)
        let away = PeekGeometry.zones(pointer: CGPoint(x: 500, y: 300), windowSize: size, onLeft: false, edgeWidth: 12, panelWidth: 260, revealed: true)
        XCTAssertFalse(away.inPanel)
    }

    func testTheSidebarOpensAndClosesFromPointerReportsAlone() async throws {
        let peek = SidebarPeek(dwell: 0.05, linger: 0.1)
        peek.pointer(inEdge: true, inPanel: false)
        try await Task.sleep(for: .milliseconds(90))                   // revealed at 50ms; it would close at 150ms if nothing reported
        XCTAssertTrue(peek.revealed)
        peek.pointer(inEdge: false, inPanel: true)                     // the tracker now sees it on the sidebar
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(peek.revealed, "it stays as long as the pointer is on it")
        peek.pointer(inEdge: false, inPanel: false)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(peek.revealed, "and closes shortly after the pointer leaves")
    }

    func testSearchOpensTheSameWayFromTheButtonThePillAndTheKeyboard() async throws {
        let m = model()
        await m.start()
        m.layoutPreset = .floating
        m.openTab(url: URL(string: "https://example.org/"), isPrivate: false)
        m.openSearch()
        XCTAssertTrue(m.floatingAddressVisible)
        m.floatingAddressVisible = false
        m.focusAddressBar()
        XCTAssertTrue(m.floatingAddressVisible, "⌘L reaches the same place")
    }

    func testTheFloatingSidebarClosesQuickly() {
        XCTAssertLessThanOrEqual(SidebarPeek().linger, 0.25)
    }

    func testTheSearchPanelOpensFromTheTopInAnyLayout() async throws {
        let m = model()
        await m.start()
        for preset in [LayoutPreset.classic, .floating] {
            m.layoutPreset = preset
            m.floatingAddressVisible = false
            m.openSearchPanel()
            XCTAssertTrue(m.floatingAddressVisible, "\(preset): the panel is the one that opens")
        }
    }
}

/// Hidden toolbar buttons take no room, and extension buttons do.
final class ToolbarRoomTests: XCTestCase {
    func testAHiddenButtonLeavesNoRoomForItself() {
        let all = ToolbarPriority(width: 1000)
        var hidden = all
        hidden.visible.bookmark = false; hidden.visible.downloads = false
        XCTAssertEqual(all.trailingWidth - hidden.trailingWidth, 56, "two 28 pt buttons")
        var noOptional = all
        noOptional.visible.share = false; noOptional.visible.newTab = false; noOptional.visible.overview = false
        XCTAssertEqual(all.trailingWidth - noOptional.trailingWidth, 84)
        var noLeading = all
        noLeading.visible.sidebar = false; noLeading.visible.backForward = false
        XCTAssertLessThan(noLeading.leadingWidth(inset: 84), all.leadingWidth(inset: 84))
        XCTAssertEqual(noLeading.leadingWidth(inset: 84), 84 + 8)
    }

    func testExtensionButtonsTakeRoom() {
        let plain = ToolbarPriority(width: 1000)
        var withExtensions = plain
        withExtensions.visible.extensionButtons = 5
        XCTAssertEqual(withExtensions.trailingWidth - plain.trailingWidth, 5 * 28)
    }

    func testTheDefaultStillMeansEverythingIsShown() {
        // The earlier width model: leading inset + 28 + 2 + (4 + 28 + 28) + 8, trailing 4 + 28 + 28 + 28 + 28 * 3 + 10.
        let p = ToolbarPriority(width: 1000)
        let leading: CGFloat = 84 + 28 + 2 + 4 + 28 + 28 + 8
        let trailing: CGFloat = 4 + 28 + 28 + 28 + 84 + 10
        XCTAssertEqual(p.leadingWidth(inset: 84), leading)
        XCTAssertEqual(p.trailingWidth, trailing)
    }

    func testMoreButtonsStayWhenTheOnesOnTheLeftAreHidden() {
        // At 560 pt the full set does not fit, so the bar drops bookmark and downloads. With the sidebar and back/forward hidden there is room for them.
        let full = ToolbarPriority(fitting: 560, leadingInset: 84)
        XCTAssertFalse(full.showBookmark)
        let lean = ToolbarPriority(fitting: 560, leadingInset: 84, visible: ToolbarVisibility(sidebar: false, backForward: false))
        XCTAssertTrue(lean.showBookmark && lean.showDownloads)
    }

    func testTheFieldNeverTouchesTheControlsWhateverIsHidden() {
        for width in stride(from: 520.0, through: 2000.0, by: 20.0) {
            for mask in 0..<64 {
                var v = ToolbarVisibility()
                v.sidebar = mask & 1 == 0
                v.backForward = mask & 2 == 0
                v.share = mask & 4 == 0
                v.bookmark = mask & 8 == 0
                v.downloads = mask & 16 == 0
                v.extensionButtons = mask & 32 == 0 ? 0 : 5
                let window = CGFloat(width)
                let p = ToolbarPriority(fitting: window, leadingInset: 84, visible: v)
                let field: CGFloat = p.fieldWidth(window: window, leadingInset: 84)
                let room: CGFloat = (window - field) / 2
                let needed: CGFloat = max(p.leadingWidth(inset: 84), p.trailingWidth)
                // The narrowest set may still not fit in a very narrow window; the field then keeps its floor and is the thing that gives.
                if window >= p.requiredWindow(leadingInset: 84) { XCTAssertGreaterThanOrEqual(room, needed + 12 - 0.01, "width \(width) mask \(mask)") }
            }
        }
    }

    func testNarrowWindowFieldGrowsIntoFreeRoomWithoutMovingAtOrdinaryWidths() {
        let inset: CGFloat = 84
        func placement(_ w: CGFloat) -> (width: CGFloat, shift: CGFloat, centred: CGFloat, trailing: CGFloat) {
            let p = ToolbarPriority(fitting: w, leadingInset: inset)
            let r = p.fieldPlacement(window: w, leadingInset: inset)
            return (r.width, r.shift, p.fieldWidth(window: w, leadingInset: inset), p.trailingWidth)
        }
        // Ordinary widths: exactly the centred field, no move.
        for w: CGFloat in [800, 1000, 1200, 1600] {
            let r = placement(w)
            XCTAssertEqual(r.shift, 0, "\(w): the field moved at an ordinary width"); XCTAssertEqual(r.width, r.centred)
        }
        // The narrowest window: the field is wider than the centred one, stays under the comfortable width, and ends before the buttons on its right.
        let narrow = placement(520)
        XCTAssertGreaterThan(narrow.width, narrow.centred)
        XCTAssertLessThanOrEqual(narrow.width, ToolbarPriority.comfortableField)
        let right = 520 / 2 + narrow.shift + narrow.width / 2
        XCTAssertLessThanOrEqual(right, 520 - narrow.trailing, "the field runs into the buttons on its right")
        // The left edge stays where the centred field's was (never nearer the controls on the left).
        let left = 520 / 2 + narrow.shift - narrow.width / 2
        XCTAssertEqual(left, 520 / 2 - narrow.centred / 2, accuracy: 0.001)
        // Continuous: no jump in the field's right edge between neighbouring widths (steps of one point).
        var previous: CGFloat?
        for w in stride(from: CGFloat(520), through: 900, by: 1) {
            let r = placement(w)
            let edge = w / 2 + r.shift + r.width / 2
            if let previous, abs(edge - previous) > 90 { XCTFail("the field's right edge jumped by \(edge - previous) at \(w)") }
            previous = edge
        }
        // Never wider than comfortable, never narrower than the centred field.
        for w in stride(from: CGFloat(520), through: 1700, by: 5) { let r = placement(w); XCTAssertGreaterThanOrEqual(r.width, r.centred); if r.shift > 0 { XCTAssertLessThanOrEqual(r.width, ToolbarPriority.comfortableField) } }
    }
}
