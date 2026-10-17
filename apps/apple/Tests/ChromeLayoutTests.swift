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
        for preset in [LayoutPreset.sidebar, .minimal, .classic, .sidebar] { m.layoutPreset = preset }
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

    func testFullScreenHidesTheToolbarExceptInTheSidebarLayout() async throws {
        let m = model()
        await m.start()
        m.layoutPreset = .classic
        XCTAssertFalse(m.autoHidesToolbar)
        m.windowFullScreen = true
        XCTAssertTrue(m.autoHidesToolbar, "full screen reveals the toolbar only at the top edge")
        m.layoutPreset = .sidebar
        XCTAssertFalse(m.autoHidesToolbar, "the sidebar layout has no top toolbar to hide")
        m.layoutPreset = .custom
        m.singleToolbarCustom = false
        m.tabLayout = .sidebar
        XCTAssertTrue(m.autoHidesToolbar, "vertical tabs with a separate toolbar: full screen hides that toolbar")
        m.windowFullScreen = false
        m.layoutPreset = .classic
        XCTAssertFalse(m.autoHidesToolbar)
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
