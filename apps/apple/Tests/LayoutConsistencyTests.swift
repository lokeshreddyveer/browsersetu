import XCTest
@testable import Browser_Setu

/// The layout rules that the model and `LayoutState` must answer the same way. They used to be written twice and had drifted: a stored Custom auto-hide
/// choice brought back a second toolbar, and One Row in full screen showed nothing and no way back.
final class LayoutConsistencyTests: XCTestCase {
    private func everyInput() -> [LayoutInputs] {
        var all: [LayoutInputs] = []
        for preset in LayoutPreset.allCases {
            for tabs in TabLayout.allCases {
                for single in [false, true] {
                    for focus in [false, true] {
                        for toolbarAutoHide in [false, true] {
                            for full in [false, true] {
                                var i = LayoutInputs()
                                i.preset = preset; i.customTabLayout = tabs; i.singleToolbarCustom = single
                                i.focusMode = focus; i.toolbarAutoHide = toolbarAutoHide; i.windowFullScreen = full
                                all.append(i)
                            }
                        }
                    }
                }
            }
        }
        return all
    }

    func testTheToolbarHidesOnTheEdgeExactlyWhenTheSharedRuleSaysSo() {
        for i in everyInput() where !i.focusMode && i.preset != .floating {
            let resolved = resolveLayout(preset: i.preset, customTabLayout: i.customTabLayout, customSidebarVisible: i.sidebarVisible, customSingleToolbar: i.singleToolbarCustom)
            let hides = LayoutRules.autoHidesToolbar(preset: i.preset, singleToolbar: resolved.singleToolbar, toolbarAutoHide: i.toolbarAutoHide, fullScreen: i.windowFullScreen)
            let state = LayoutState.resolve(i)
            XCTAssertEqual(state.topChrome == .toolbarOnEdge, hides && !resolved.singleToolbar, "toolbar edge state disagrees with the rule for \(i)")
        }
    }

    func testOneRowInFullScreenHidesLikeTheOthersAndKeepsItsWayBack() {
        var i = LayoutInputs()
        i.preset = .inline; i.windowFullScreen = true
        let state = LayoutState.resolve(i)
        XCTAssertEqual(state.topChrome, .toolbarOnEdge)
        XCTAssertTrue(state.needsHandle, "nothing but the page is on screen, so the handle must be drawn")
        XCTAssertTrue(state.everythingReachable)
    }

    func testASingleToolbarNeverBringsBackASecondOneFromAStoredAutoHide() {
        var i = LayoutInputs()
        i.preset = .custom; i.customTabLayout = .sidebar; i.singleToolbarCustom = true; i.toolbarAutoHide = true
        XCTAssertNotEqual(LayoutState.resolve(i).topChrome, .toolbarOnEdge)
        XCTAssertFalse(LayoutRules.autoHidesToolbar(preset: .custom, singleToolbar: true, toolbarAutoHide: true, fullScreen: false))
        XCTAssertFalse(LayoutRules.autoHidesToolbar(preset: .sidebar, singleToolbar: true, toolbarAutoHide: false, fullScreen: true), "the Sidebar layout has no bar to hide in full screen")
    }

    func testTheSharedSizesAreTheOnesTheScreensUsed() {
        XCTAssertEqual(LayoutMetrics.toolbarLeadingInset(fullScreen: false), 84)
        XCTAssertEqual(LayoutMetrics.toolbarLeadingInset(fullScreen: true), 10)
        XCTAssertEqual(LayoutMetrics.sidebarLights, 74)
    }

    func testASavedLayoutFromBeforeCustomKeptItsChoicesStillLoads() throws {
        let old = #"{"preset":"classic","sidebarPosition":"left","sidebarVisible":false,"sidebarRail":false,"sidebarAutoHide":false,"focusMode":false,"splitOrientation":"sideBySide","toolbarAutoHide":false,"collapseOnScroll":true}"#
        let snapshot = try JSONDecoder().decode(LayoutSnapshot.self, from: Data(old.utf8))
        XCTAssertNil(snapshot.tabLayout)
        XCTAssertNil(snapshot.singleToolbar)
        let custom = LayoutSnapshot(preset: "custom", sidebarPosition: "left", sidebarVisible: true, sidebarRail: false, sidebarAutoHide: false, focusMode: false,
                                    splitOrientation: "sideBySide", toolbarAutoHide: false, collapseOnScroll: true, tabLayout: "sidebar", singleToolbar: true)
        let again = try JSONDecoder().decode(LayoutSnapshot.self, from: JSONEncoder().encode(custom))
        XCTAssertEqual(again, custom, "Custom's own choices survive being saved and read back")
    }

    func testEveryPresetDescribesWhatItDoes() {
        for preset in LayoutPreset.allCases { XCTAssertFalse(preset.summary.isEmpty) }
        XCTAssertFalse(LayoutPreset.floating.summary.lowercased().contains("search button"), "the Mac has no separate search button in Floating")
    }
}
