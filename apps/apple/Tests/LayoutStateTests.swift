import XCTest
@testable import Browser_Setu

/// Every combination of the layout settings has to leave the essential controls reachable. The settings are many and independent; this runs all of them.
final class LayoutStateTests: XCTestCase {
    private func everyMacInput() -> [LayoutInputs] {
        var all: [LayoutInputs] = []
        for preset in LayoutPreset.allCases {
            for tabs in TabLayout.allCases {
                for single in [false, true] {
                    for visible in [false, true] {
                        for autoHide in [false, true] {
                            for rail in [false, true] {
                                for focus in [false, true] {
                                    for toolbarAutoHide in [false, true] {
                                        for full in [false, true] {
                                            for width in [300.0, 520, 760, 1100, 2400] {
                                                var inputs = LayoutInputs()
                                                inputs.preset = preset; inputs.customTabLayout = tabs; inputs.singleToolbarCustom = single
                                                inputs.sidebarVisible = visible; inputs.sidebarAutoHide = autoHide; inputs.sidebarRail = rail
                                                inputs.focusMode = focus; inputs.toolbarAutoHide = toolbarAutoHide; inputs.windowFullScreen = full; inputs.windowWidth = width
                                                all.append(inputs)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return all
    }

    func testEveryCombinationKeepsEveryEssentialControlReachable() {
        for inputs in everyMacInput() {
            let state = LayoutState.resolve(inputs)
            XCTAssertTrue(state.everythingReachable, "unreachable controls in \(inputs)")
            XCTAssertNotNil(state.reach[.restoreLayout], "no way back to the standard layout in \(inputs)")
        }
    }

    func testAnythingFoundOnlyAtAnEdgeBringsUpTheHandle() {
        for inputs in everyMacInput() {
            let state = LayoutState.resolve(inputs)
            let edgeOnly = LayoutControl.allCases.filter { state.reach[$0] == .onHover }
            XCTAssertEqual(state.needsHandle, !edgeOnly.isEmpty)
            // Every state with controls that are not on screen has some visible way to them: the toolbar's More menu, the pill, the focus band, or the handle.
            if !state.hiddenControls.isEmpty {
                let hasVisibleMenu = [.toolbar, .singleRow, .floatingPill, .focusBand].contains(state.topChrome) || state.needsHandle || state.sidebar == .pinned
                XCTAssertTrue(hasVisibleMenu, "hidden controls with nothing on screen leading to them: \(inputs)")
            }
        }
    }

    func testFocusModeKeepsABandAndPutsSearchBehindItsMenu() {
        var inputs = LayoutInputs(); inputs.focusMode = true
        let state = LayoutState.resolve(inputs)
        XCTAssertEqual(state.topChrome, .focusBand)
        XCTAssertEqual(state.address, .floatingSearch)
        XCTAssertEqual(state.reach[.search], .handle)
        XCTAssertEqual(state.tabs, .none)
    }

    func testTheSidebarLayoutWithAHiddenSidebarShowsTheHandle() {
        var inputs = LayoutInputs(); inputs.preset = .sidebar; inputs.sidebarVisible = false
        let state = LayoutState.resolve(inputs)
        XCTAssertEqual(state.topChrome, .none)
        XCTAssertTrue(state.needsHandle, "nothing else is on screen")
        inputs.sidebarVisible = true
        XCTAssertFalse(LayoutState.resolve(inputs).needsHandle)
        XCTAssertEqual(LayoutState.resolve(inputs).address, .sidebar)
    }

    func testTheClassicLayoutFoldsButtonsIntoMoreWhenNarrowAndNeverHidesSearch() {
        var inputs = LayoutInputs(); inputs.preset = .classic
        inputs.windowWidth = 2400
        XCTAssertTrue(LayoutState.resolve(inputs).folded.isEmpty)
        inputs.windowWidth = 520
        let narrow = LayoutState.resolve(inputs)
        XCTAssertEqual(narrow.folded, [.newTab, .tabOverview])
        XCTAssertEqual(narrow.reach[.search], .visible)
        XCTAssertEqual(narrow.reach[.newTab], .handle)
    }

    func testThePhoneDockAlwaysShowsTheEssentials() {
        var inputs = LayoutInputs(); inputs.isPhone = true; inputs.isMac = false
        let state = LayoutState.resolve(inputs)
        XCTAssertEqual(state.address, .bottomDock)
        for control in [LayoutControl.search, .newTab, .tabOverview, .settings] { XCTAssertEqual(state.reach[control], .visible) }
    }

    func testWindowPresetsAreWholeAndKnown() {
        for preset in WindowPreset.allCases {
            let snapshot = preset.snapshot
            XCTAssertNotNil(LayoutPreset(rawValue: snapshot.preset))
            XCTAssertNotNil(SidebarPosition(rawValue: snapshot.sidebarPosition))
            XCTAssertNotNil(SplitOrientation(rawValue: snapshot.splitOrientation))
        }
    }
}

@MainActor
final class LayoutModelTests: XCTestCase {
    private func makeModel() -> BrowserModel {
        BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-layout-\(UUID().uuidString)", profile: "default")
    }

    func testRestoreStandardLayoutUndoesEveryWayToGetLost() async throws {
        let model = makeModel()
        await model.start()
        model.layoutPreset = .floating
        model.sidebarRail = true
        model.focusMode = true
        model.floatingAddressVisible = true
        model.restoreStandardLayout()
        XCTAssertEqual(model.layoutPreset, .classic)
        XCTAssertFalse(model.focusMode)
        XCTAssertFalse(model.sidebarRail)
        XCTAssertFalse(model.floatingAddressVisible)
        XCTAssertEqual(model.toolbarItems, ToolbarItemID.defaults)
        XCTAssertFalse(model.layoutState().needsHandle)
    }

    func testAWindowPresetAppliesAndSnapshotsRoundTrip() async throws {
        let model = makeModel()
        await model.start()
        model.applyWindowPreset(.research)
        XCTAssertEqual(model.layoutPreset, .sidebar)
        XCTAssertTrue(model.sidebarVisible)
        let saved = model.layoutSnapshot()
        model.applyWindowPreset(.media)
        XCTAssertEqual(model.layoutPreset, .floating)
        model.apply(saved)
        XCTAssertEqual(model.layoutPreset, .sidebar)
        model.apply(LayoutSnapshot(preset: "nonsense", sidebarPosition: "nowhere", sidebarVisible: true, sidebarRail: false, sidebarAutoHide: false, focusMode: false, splitOrientation: "diagonal", toolbarAutoHide: false, collapseOnScroll: true))
        XCTAssertNotNil(LayoutPreset(rawValue: model.layoutPreset.rawValue), "an unknown value leaves a real layout")
    }

    func testEachWorkspaceRemembersItsOwnLayout() async throws {
        let model = makeModel()
        await model.start()
        model.createWorkspace("Work", icon: "briefcase")
        model.layoutPreset = .sidebar
        model.switchWorkspace("Work")
        model.layoutPreset = .floating
        model.switchWorkspace("")
        XCTAssertEqual(model.layoutPreset, .sidebar, "the personal workspace comes back as it was")
        model.switchWorkspace("Work")
        XCTAssertEqual(model.layoutPreset, .floating, "and so does Work")
    }

    func testSavedSessionsCarryTheLayoutAndTheSplit() async throws {
        let model = makeModel()
        await model.start()
        let a = model.openTab(url: nil, isPrivate: false), b = model.openTab(url: nil, isPrivate: false, select: false)
        a.url = URL(string: "https://a.test/")!; b.url = URL(string: "https://b.test/")!
        model.select(a.id)
        model.openSplit(with: b)
        model.applyWindowPreset(.research)
        model.saveSession(named: "Study")
        let session = try XCTUnwrap(model.savedSessions.first)
        XCTAssertEqual(session.layout?.preset, "sidebar")
        XCTAssertEqual(session.split, ["https://a.test/", "https://b.test/"])
    }
}
