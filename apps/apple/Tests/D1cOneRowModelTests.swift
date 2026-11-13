import XCTest
@testable import Browser_Setu

/// One Row at the model level: switching layouts never rebuilds a tab or its web view, and choosing another tab ends a half-typed address in every layout.
@MainActor
final class D1cOneRowModelTests: XCTestCase {
    private func model() -> BrowserModel {
        BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-d1c-\(UUID().uuidString)", profile: "default")
    }

    func testSwitchingLayoutsKeepsEveryTabAndItsWebView() {
        let m = model()
        for i in 0..<3 { m.openTab(url: URL(string: "about:blank#\(i)")!, isPrivate: false) }
        let tabs = m.tabs.map { ObjectIdentifier($0) }
        let engines = m.tabs.map { ObjectIdentifier($0.engine as AnyObject) }
        XCTAssertGreaterThanOrEqual(tabs.count, 3)
        for preset in [LayoutPreset.inline, .classic, .classicReversed, .sidebar, .minimal, .minimalReversed, .classicReversed, .inline, .minimalReversed, .classic, .classicReversed, .minimal, .sidebar, .classic] {
            m.layoutPreset = preset
            XCTAssertEqual(m.tabs.map { ObjectIdentifier($0) }, tabs, "a tab object was replaced when the layout became \(preset)")
            XCTAssertEqual(m.tabs.map { ObjectIdentifier($0.engine as AnyObject) }, engines, "a web view was replaced when the layout became \(preset)")
        }
    }

    func testOnlyOneRowIsASingleRow() {
        let m = model()
        for preset in LayoutPreset.allCases { m.layoutPreset = preset; XCTAssertEqual(m.singleRow, preset == .inline, "\(preset)") }
    }

    /// Choosing another tab abandons a half-typed address, in every layout: the draft and its suggestions belong to the tab that was in front. (This used to be One Row only, with Classic keeping one live field across
    /// tabs; Classic's approved omnibox behavior is now the same, and `D1aClassicUITests.testOmniboxSuggestionsDoNotSurviveATabChange` checks it on the running app.)
    func testChoosingAnotherTabEndsTheDraftInEveryLayout() {
        for preset in [LayoutPreset.classic, .minimal, .inline, .sidebar] {
            let m = model()
            for i in 0..<2 { m.openTab(url: URL(string: "about:blank#\(i)")!, isPrivate: false) }
            guard m.tabs.count >= 2, let other = m.tabs.first(where: { $0.id != m.activeID }) else { return XCTFail("need two tabs") }
            m.layoutPreset = preset
            m.addressBar.isEditing = true; m.addressBar.text = "half typed"; m.addressBar.refresh(model: m)
            m.select(other.id)
            XCTAssertFalse(m.addressBar.isEditing, "\(preset): the draft must go with the tab that showed it")
            XCTAssertTrue(m.addressBar.suggestions.isEmpty, "\(preset): the suggestions outlived the tab change: \(m.addressBar.suggestions.map(\.title))")
        }
    }

    // MARK: Motion setting (Off / Standard)

    /// The app's Motion setting is applied and kept: Off removes the animation, Standard keeps it, switching every layout works under both, and the choice is read back by a model opened on the same profile.
    /// (The system's Reduce Motion is read from the system and is not changed by tests.)
    func testMotionOffAndStandardApplyPersistAndKeepLayoutSwitchingWorking() {
        defer { MotionStyle.current = .standard }
        let root = NSTemporaryDirectory() + "bs-d1c-\(UUID().uuidString)"
        let m = BrowserModel(engine: WebKitEngine(), root: root, profile: "default")
        for style in [MotionStyle.off, .standard] {
            m.motionStyle = style
            XCTAssertEqual(MotionStyle.current, style)
            let applied = MotionStyle.current.apply(.spring(response: 0.4, dampingFraction: 0.88))
            if style == .off { XCTAssertNil(applied, "Motion Off still animates") } else { XCTAssertNotNil(applied, "Motion Standard lost its animation") }
            for preset in LayoutPreset.allCases { m.layoutPreset = preset; XCTAssertEqual(m.layoutPreset, preset, "\(preset) under \(style)") }
        }
        m.motionStyle = .off
        let again = BrowserModel(engine: WebKitEngine(), root: root, profile: "default")
        XCTAssertEqual(again.motionStyle, .off, "Motion Off was not kept for the next launch")
    }

    // MARK: Classic Reversed

    /// Classic Reversed is Classic with the two top rows swapped: the same resolved layout, the same single-row answer, and the tabs-above flag only on itself.
    func testClassicReversedIsClassicWithTheRowsSwapped() {
        XCTAssertEqual(resolveLayout(preset: .classicReversed, customTabLayout: .separate, customSidebarVisible: false),
                       resolveLayout(preset: .classic, customTabLayout: .separate, customSidebarVisible: false))
        for preset in LayoutPreset.allCases { XCTAssertEqual(preset.tabsOnTop, preset == .classicReversed || preset == .minimalReversed, "\(preset)") }
        XCTAssertEqual(LayoutPreset.classicReversed.title, "Classic Reversed")
        XCTAssertFalse(LayoutPreset.classicReversed.summary.isEmpty)
        XCTAssertFalse(BrowserModel.layoutCycle.contains(.classicReversed), "the layout shortcut's cycle must not change")
        XCTAssertEqual(LayoutPreset(rawValue: "classicReversed"), .classicReversed)
        let m = model(); m.layoutPreset = .classicReversed
        XCTAssertFalse(m.singleRow); XCTAssertEqual(m.effectiveTabLayout, .separate)
    }

    /// Where the traffic lights' room is kept, for every combination. Classic is unchanged; Classic Reversed moves the room to the strip row, none in full screen, and back to the toolbar when the strip is hidden.
    func testWhereTheTrafficLightRoomIsKept() {
        typealias M = LayoutMetrics
        for full in [false, true] {
            for shown in [false, true] {
                XCTAssertEqual(M.chromeInsets(tabsOnTop: false, fullScreen: full, stripShown: shown), M.ChromeInsets(stripClearance: 0, toolbar: M.toolbarLeadingInset(fullScreen: full)), "Classic must not change")
            }
            XCTAssertEqual(M.chromeInsets(tabsOnTop: true, fullScreen: full, stripShown: false), M.ChromeInsets(stripClearance: 0, toolbar: M.toolbarLeadingInset(fullScreen: full)), "a hidden strip gives the room back to the toolbar")
        }
        XCTAssertEqual(M.chromeInsets(tabsOnTop: true, fullScreen: false, stripShown: true), M.ChromeInsets(stripClearance: 84, toolbar: 10))
        XCTAssertEqual(M.chromeInsets(tabsOnTop: true, fullScreen: true, stripShown: true), M.ChromeInsets(stripClearance: 0, toolbar: 10), "no lights in the window in full screen")
    }

    /// Classic's single-tab setting applies to Classic Reversed (and the strip is hidden only when asked for).
    func testClassicReversedKeepsClassicsSingleTabRule() {
        let m = model()
        m.layoutPreset = .classicReversed
        m.hideSingleTabStrip = false
        XCTAssertFalse(m.stripHiddenForSingleTab)
        m.hideSingleTabStrip = true
        XCTAssertEqual(m.stripHiddenForSingleTab, m.visibleTabs.count <= 1)
        m.layoutPreset = .classic
        XCTAssertEqual(m.stripHiddenForSingleTab, m.visibleTabs.count <= 1, "Classic's own rule changed")
    }

    /// The choice is kept for the next launch, comes back through a saved layout, and the standard layout resets to Classic.
    func testClassicReversedPersistsSnapshotsAndResets() {
        let root = NSTemporaryDirectory() + "bs-d1c-\(UUID().uuidString)"
        let m = BrowserModel(engine: WebKitEngine(), root: root, profile: "default")
        m.layoutPreset = .classicReversed
        XCTAssertEqual(BrowserModel(engine: WebKitEngine(), root: root, profile: "default").layoutPreset, .classicReversed, "the next launch lost the layout")
        var snapshot = WindowPreset.minimal.snapshot; snapshot.preset = "classicReversed"
        m.layoutPreset = .sidebar
        m.apply(snapshot)
        XCTAssertEqual(m.layoutPreset, .classicReversed, "a saved layout did not bring it back")
        m.restoreStandardLayout()
        XCTAssertEqual(m.layoutPreset, .classic, "the standard layout is Classic")
    }

    /// What an older build would do with a layout it does not know, simulated with a value this build does not know: the three ways a layout is read, and whether a later write can replace it.
    /// Reading never writes. A later change of the layout does replace it (that is the limitation: an older build that saves its fallback would overwrite a reversed choice).
    func testAnUnknownLayoutValueIsReadSafelyAndOnlyReplacedByALaterLayoutWrite() {
        let root = NSTemporaryDirectory() + "bs-d1c-\(UUID().uuidString)"
        let m = BrowserModel(engine: WebKitEngine(), root: root, profile: "default")
        m.saveSetting("layout_preset", "someFutureLayout")
        // 1. The profile's own setting.
        let again = BrowserModel(engine: WebKitEngine(), root: root, profile: "default")
        XCTAssertEqual(again.layoutPreset, .classic, "an unknown layout must fall back to Classic")
        XCTAssertEqual(again.settingValue("layout_preset"), "someFutureLayout", "reading wrote the fallback back")
        // 2. A saved layout (workspace or personal) with an unknown preset changes nothing.
        again.layoutPreset = .minimal
        again.saveSetting("layout_preset", "someFutureLayout")
        var snapshot = WindowPreset.minimal.snapshot; snapshot.preset = "someFutureLayout"
        again.apply(snapshot)
        XCTAssertEqual(again.layoutPreset, .minimal, "an unknown saved layout changed the layout")
        // 3. Unrelated changes after the read do not touch it; a layout change does.
        again.motionStyle = .off
        XCTAssertEqual(again.settingValue("layout_preset"), "someFutureLayout", "an unrelated change rewrote the layout")
        again.layoutPreset = .sidebar
        XCTAssertEqual(again.settingValue("layout_preset"), "sidebar", "a layout change must be saved")
    }

    // MARK: Minimal Reversed

    /// Minimal Reversed is Minimal with the two top rows swapped: the same compact layout, no Classic single-tab rule, not in the shortcut's cycle, read and saved like any layout.
    func testMinimalReversedIsMinimalWithTheRowsSwapped() {
        XCTAssertEqual(resolveLayout(preset: .minimalReversed, customTabLayout: .separate, customSidebarVisible: false),
                       resolveLayout(preset: .minimal, customTabLayout: .separate, customSidebarVisible: false))
        XCTAssertTrue(LayoutPreset.minimalReversed.tabsOnTop)
        XCTAssertFalse(LayoutPreset.minimal.tabsOnTop)
        XCTAssertEqual(LayoutPreset.minimalReversed.title, "Minimal Reversed")
        XCTAssertFalse(LayoutPreset.minimalReversed.summary.isEmpty)
        XCTAssertEqual(LayoutPreset.allCases.count, 12, "the preset list: the existing seven, Minimal Reversed, and the design pack's Hybrid, Canvas, Research Desk and Workspace Deck")
        XCTAssertTrue(LayoutPreset.allCases.contains(.minimalReversed))
        XCTAssertEqual(BrowserModel.layoutCycle, [.classic, .sidebar, .minimal, .floating, .inline], "the layout shortcut's cycle must not change")
        XCTAssertEqual(LayoutPreset(rawValue: "minimalReversed"), .minimalReversed)
        let m = model(); m.layoutPreset = .minimalReversed
        XCTAssertFalse(m.singleRow); XCTAssertEqual(m.effectiveTabLayout, .compact)
        // Minimal never hides its strip for a single tab, whatever Classic's setting says.
        m.hideSingleTabStrip = true
        XCTAssertFalse(m.stripHiddenForSingleTab, "Classic's hide-the-strip rule must not reach the compact strip")
        // Edge-hover sidebars stay off in both Reversed layouts, as in Classic and Minimal.
        for preset in [LayoutPreset.classic, .classicReversed, .minimal, .minimalReversed, .inline] { XCTAssertFalse(LayoutRules.sidebarAutoHides(preset: preset, sidebarAutoHide: true), "\(preset)") }
        XCTAssertTrue(LayoutRules.sidebarAutoHides(preset: .sidebar, sidebarAutoHide: true))
    }

    func testMinimalReversedPersistsSnapshotsAndResets() {
        let root = NSTemporaryDirectory() + "bs-d1c-\(UUID().uuidString)"
        let m = BrowserModel(engine: WebKitEngine(), root: root, profile: "default")
        m.layoutPreset = .minimalReversed
        XCTAssertEqual(BrowserModel(engine: WebKitEngine(), root: root, profile: "default").layoutPreset, .minimalReversed, "the next launch lost the layout")
        var snapshot = WindowPreset.minimal.snapshot; snapshot.preset = "minimalReversed"
        m.layoutPreset = .sidebar
        m.apply(snapshot)
        XCTAssertEqual(m.layoutPreset, .minimalReversed, "a saved layout did not bring it back")
        // A workspace's layout and a motion change do not disturb it.
        m.motionStyle = .off; XCTAssertEqual(m.layoutPreset, .minimalReversed)
        m.motionStyle = .standard; XCTAssertEqual(m.layoutPreset, .minimalReversed)
        m.restoreStandardLayout()
        XCTAssertEqual(m.layoutPreset, .classic, "the standard layout is Classic")
    }

    // MARK: The window hold

    private func hostWindow() -> (NSWindow, NSView) {
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 600, height: 300), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        let tab = NSView(frame: NSRect(x: 100, y: 300 - 34, width: 80, height: 30))
        window.isReleasedWhenClosed = false   // ARC owns it; the default would release it a second time on close
        window.contentView?.addSubview(tab)
        window.makeKeyAndOrderFront(nil)
        return (window, tab)
    }

    /// Holding makes the window immovable, remembers what it had, counts owners, and gives it back exactly when the last one lets go.
    func testTheHoldIsCountedAndRestoresWhatTheWindowHad() throws {
        let (window, tab) = hostWindow()
        defer { TitleBarTabHold.shared.releaseAll(); window.close() }
        let hold = TitleBarTabHold.shared
        XCTAssertTrue(window.isMovable)
        XCTAssertTrue(hold.hold(owner: 1, view: tab)); XCTAssertFalse(window.isMovable)
        XCTAssertTrue(hold.hold(owner: 2, view: tab)); XCTAssertFalse(window.isMovable)
        hold.release(owner: 1); XCTAssertFalse(window.isMovable, "one tab is still under the pointer")
        hold.release(owner: 2); XCTAssertTrue(window.isMovable, "the last release did not give the window back")
        XCTAssertEqual(hold.heldCount, 0)
        hold.release(owner: 2); XCTAssertTrue(window.isMovable, "a second release changed something")
        // A window that was not movable to begin with stays so.
        window.isMovable = false
        XCTAssertTrue(hold.hold(owner: 3, view: tab)); hold.release(owner: 3)
        XCTAssertFalse(window.isMovable, "the hold invented a movable window")
    }

    /// Every other way the pointer stops being over a tab gives the window back: the window or the app losing the front, the window closing, a view that left the window. A view outside the title bar band never holds.
    func testTheHoldIsLiftedWhenTheWindowOrAppLeavesTheFront() throws {
        let (window, tab) = hostWindow()
        defer { TitleBarTabHold.shared.releaseAll(); window.close() }
        let hold = TitleBarTabHold.shared
        for name in [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification, NSWindow.willCloseNotification] {
            XCTAssertTrue(hold.hold(owner: 7, view: tab)); XCTAssertFalse(window.isMovable)
            NotificationCenter.default.post(name: name, object: window)
            XCTAssertTrue(window.isMovable, "\(name.rawValue) left the window held")
            XCTAssertEqual(hold.heldCount, 0)
        }
        // A tab that is not in the title bar band (the page area) does not hold the window.
        let low = NSView(frame: NSRect(x: 10, y: 10, width: 80, height: 30)); window.contentView?.addSubview(low)
        XCTAssertFalse(hold.hold(owner: 8, view: low)); XCTAssertTrue(window.isMovable)
        // A view with no window cannot hold anything.
        XCTAssertFalse(hold.hold(owner: 9, view: NSView())); XCTAssertEqual(hold.heldCount, 0)
    }

    /// Two windows are held independently: giving one back does not touch the other; the front-window notifications give back all.
    func testTwoWindowsAreHeldIndependently() {
        let (a, tabA) = hostWindow(); let (b, tabB) = hostWindow()
        defer { TitleBarTabHold.shared.releaseAll(); a.close(); b.close() }
        let hold = TitleBarTabHold.shared
        XCTAssertTrue(hold.hold(owner: 21, view: tabB)); XCTAssertFalse(b.isMovable); XCTAssertTrue(a.isMovable, "the other window was held")
        XCTAssertTrue(hold.hold(owner: 22, view: tabA)); XCTAssertFalse(a.isMovable)
        hold.release(owner: 22); XCTAssertTrue(a.isMovable); XCTAssertFalse(b.isMovable, "releasing one window's tab freed the other")
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: b)
        XCTAssertTrue(b.isMovable, "the window that lost the front stayed held")
        XCTAssertEqual(hold.heldCount, 0)
    }
}
