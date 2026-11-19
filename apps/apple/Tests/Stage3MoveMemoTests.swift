import XCTest
@testable import Browser_Setu

/// Stage 3: `canMoveTab` remembers its move lists for one round of drawing. After every kind of change that decides those lists, the remembered answer must equal
/// one worked out afresh, checked in the same run-loop turn as the change (so the invalidation itself is tested, not the end-of-turn clearing).
@MainActor
final class Stage3MoveMemoTests: XCTestCase {
    private func makeModel(tabs count: Int) async -> BrowserModel {
        let model = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-stage3-memo-\(UUID().uuidString)", profile: "default")
        await model.start()
        for _ in 0..<count { _ = model.openTab(url: nil, isPrivate: false) }
        return model
    }

    private func assertSame(_ model: BrowserModel, _ step: String, file: StaticString = #filePath, line: UInt = #line) {
        for tab in model.tabs {
            for delta in [-1, 1] {
                let remembered = model.canMoveTab(tab, by: delta)
                XCTAssertEqual(remembered, model.canMoveTabUncached(tab, by: delta), "\(step): tab \(tab.id) by \(delta)", file: file, line: line)
                // Asked again: the remembered list is used and gives the same answer.
                XCTAssertEqual(model.canMoveTab(tab, by: delta), remembered, file: file, line: line)
            }
        }
    }

    func testRememberedAnswersMatchFreshOnesAfterEveryKindOfChange() async {
        let model = await makeModel(tabs: 30)
        var seed: UInt64 = 0x51A6E3
        func next(_ bound: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(bound)) }
        let groups = ["", "", "Work", "Read"]
        let presets: [LayoutPreset] = [.classic, .sidebar, .classic, .minimal]
        assertSame(model, "start")
        for step in 0..<400 {
            let tab = model.tabs[next(model.tabs.count)]
            let label: String
            switch next(12) {
            case 0: tab.pinned.toggle(); label = "pin"
            case 1: tab.group = groups[next(groups.count)]; label = "group"
            case 2: tab.workspace = next(3) == 0 ? "Other" : ""; label = "workspace of a tab"
            case 3: let i = next(model.tabs.count), j = next(model.tabs.count); model.tabs.swapAt(i, j); label = "reorder"
            case 4: model.activeWorkspace = next(3) == 0 ? "Other" : ""; label = "active workspace"
            case 5: model.activeGroup = groups[next(groups.count)]; label = "active group"
            case 6: model.layoutPreset = presets[next(presets.count)]; label = "layout"
            case 7: model.select(tab.id); label = "select"
            // Inputs the first version did not change directly: the hidden panel tab, the group order, focus mode, and a tab becoming an Essential.
            case 8: model.panelTabID = next(3) == 0 ? nil : tab.id; label = "panel tab"
            case 9: var lists = model.groupLists; lists[model.activeWorkspace] = next(2) == 0 ? ["Work", "Read"] : ["Read", "Work"]; model.groupLists = lists; label = "group order"
            case 10: model.focusMode.toggle(); label = "focus mode"
            default:
                var meta = model.tabMeta[tab.id] ?? TabMeta()
                meta.essential = meta.essential == nil ? "stage3-memo" : nil
                model.tabMeta[tab.id] = meta; label = "essential"
            }
            assertSame(model, "step \(step) \(label)")
        }
    }

    /// Asks every tab once so the lists are remembered, as one redraw of the tab strip would.
    private func prime(_ model: BrowserModel) { for tab in model.tabs { _ = model.canMoveTab(tab, by: -1); _ = model.canMoveTab(tab, by: 1) } }

    /// The panel tab is kept out of every list through `panelTabID`, which is not published. Opening a panel, closing it, and moving its page into the tab list must each give
    /// fresh answers in the same turn, with the lists remembered from before the change.
    func testWebPanelOpenCloseAndMoveToTabGiveFreshAnswers() async {
        let model = await makeModel(tabs: 6)
        model.webPanels = [WebPanel(name: "Stage 3 panel", url: "https://panel.stage3.invalid/")]
        let panel = model.webPanels[0].id
        prime(model)
        model.toggleWebPanel(panel)
        XCTAssertNotNil(model.panelTabID)
        assertSame(model, "panel opened")
        prime(model)
        model.moveWebPanelToTab()
        XCTAssertNil(model.panelTabID)
        assertSame(model, "panel moved into the tab list")
        model.toggleWebPanel(panel)
        prime(model)
        model.toggleWebPanel(panel)
        XCTAssertNil(model.panelTabID)
        assertSame(model, "panel closed")
        // The unpublished input on its own, with nothing published beside it.
        let tab = model.tabs[2]
        prime(model)
        model.panelTabID = tab.id
        assertSame(model, "panel tab set alone")
        prime(model)
        model.panelTabID = nil
        assertSame(model, "panel tab cleared alone")
    }

    /// Split panes: opening, adding a third and fourth panel, taking them away and closing the split, each with remembered lists from before the change.
    func testSplitPaneTransitionsGiveFreshAnswers() async {
        let model = await makeModel(tabs: 8)
        model.select(model.tabs[0].id)
        let steps: [(String, () -> Void)] = [
            ("open split", { model.openSplit(with: model.tabs[1]) }),
            ("third panel", { model.addThirdPanel(with: model.tabs[2]) }),
            ("fourth panel", { model.addThirdPanel(with: model.tabs[3]) }),
            ("pin a split tab", { model.tabs[1].pinned.toggle() }),
            ("move a split tab", { model.tabs.swapAt(1, 5) }),
            ("remove a panel", { model.removeThirdPanel() }),
            ("new tab in split", { model.closeSplit(); model.openSplitNewTab() }),
            ("close split", { model.closeSplit() }),
        ]
        for (label, change) in steps { prime(model); change(); assertSame(model, label) }
    }

    /// The remembered lists never outlive the turn that made them, even when nothing changes (an asynchronous callback in a later turn starts afresh).
    func testRememberedListsAreDroppedAtTheEndOfTheTurn() async {
        let model = await makeModel(tabs: 5)
        prime(model)
        XCTAssertFalse(model.moveNeighbourMemo.isEmpty)
        await Task.yield()
        let end = Date().addingTimeInterval(2)
        while !model.moveNeighbourMemo.isEmpty, Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(model.moveNeighbourMemo.isEmpty)
    }

    func testOneRedrawWorksTheListOutOnceInsteadOfTwicePerTab() async {
        let model = await makeModel(tabs: 100)
        model.forgetMoveNeighbours()
        let t0 = DispatchTime.now().uptimeNanoseconds
        for tab in model.tabs { _ = model.canMoveTabUncached(tab, by: -1); _ = model.canMoveTabUncached(tab, by: 1) }
        let fresh = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        model.forgetMoveNeighbours()
        let t1 = DispatchTime.now().uptimeNanoseconds
        for tab in model.tabs { _ = model.canMoveTab(tab, by: -1); _ = model.canMoveTab(tab, by: 1) }
        let remembered = Double(DispatchTime.now().uptimeNanoseconds - t1) / 1e6
        print(String(format: "STAGE3 MEMO 100 tabs, 200 answers (one redraw): afresh %.2f ms, remembered %.2f ms", fresh, remembered))
        XCTAssertLessThan(remembered, fresh)
    }
}
