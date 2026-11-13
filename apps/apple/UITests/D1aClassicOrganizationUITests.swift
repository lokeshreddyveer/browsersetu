import XCTest

/// Section 14, the visible side: what Classic's strip does with the tab settings. Throwaway profile, window-only pictures, one accessibility snapshot per question (never one per tab).
final class D1aClassicOrganizationUITests: PerfCase {
    private func launchClassic(width: Int = 1000, tabs: Int = 6, options: [String] = []) {
        launch(state: "bulk-tabs", extra: ["-UITabCount", "\(tabs)", "-UILayout", "classic"] + options, env: ["BS_WINDOW_SIZE": "\(width)x800"])
        XCTAssertNotNil(until(30) { win.exists && abs(win.frame.width - CGFloat(width)) < 6 && any("omnibox").exists }, "Classic did not come up")
        Thread.sleep(forTimeInterval: 0.5)
        app.typeKey(.escape, modifierFlags: [])
        win.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.7)).hover()
        Thread.sleep(forTimeInterval: 0.2)
    }
    private func labels() -> [String] { chipSnapshots().filter { $0.frame.width > 100 }.map { $0.label } }
    private func closeButtons() -> Int { win.buttons.matching(NSPredicate(format: "label == 'Close tab'")).allElementsBoundByIndex.filter { $0.frame.minY - win.frame.minY < 80 }.count }
    private func visibleItem(_ title: String) -> XCUIElement? { app.menuItems.matching(NSPredicate(format: "title == %@", title)).allElementsBoundByIndex.first { $0.isHittable } }

    /// ORG-14: with stacks on, the six tabs of one site are all still in the strip: Classic has no stack presentation.
    func testStacksOnLeavesClassicsStripUnchanged() throws {
        launchClassic(options: ["-UIStacks", "1"])
        XCTAssertEqual(chipSnapshots().count, 6, "Classic's strip folded or hid tabs when stacks were on: \(labels())")
        attachShot("classic-stacks-on")
    }

    /// ORG-19: hiding the close cross hides it everywhere in the strip, and Cmd-W still closes.
    func testHidingTheCloseCrossLeavesNoCloseButtonButCmdWWorks() throws {
        launchClassic(options: ["-UIHideClose", "1"])
        let selected = chipSnapshots().first { $0.selected }!
        XCTAssertEqual(closeButtons(), 0, "a Close cross is still shown")
        win.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: selected.frame.midX - win.frame.minX, dy: selected.frame.midY - win.frame.minY)).hover()
        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertEqual(closeButtons(), 0, "the cross appears on hover")
        let before = chipSnapshots().count
        app.typeKey("w", modifierFlags: .command)
        XCTAssertNotNil(until(3) { self.chipSnapshots().count == before - 1 }, "Cmd-W did not close the tab")
    }

    /// ORG-18: with the setting on, a double-click on a tab body closes that tab once, and a locked tab stays.
    func testDoubleClickCloseWhenOnClosesOneTabAndNeverALockedOne() throws {
        launchClassic(options: ["-UIDoubleClickClose", "1"])
        let w = win.frame
        func doubleClick(_ row: (selected: Bool, frame: CGRect, label: String)) {
            win.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: row.frame.midX - w.minX, dy: row.frame.midY - w.minY)).doubleClick()
            Thread.sleep(forTimeInterval: 0.4)
        }
        let before = labels()
        let target = chipSnapshots().filter { !$0.selected && $0.frame.width > 100 }[1]
        doubleClick(target)
        XCTAssertEqual(labels().count, before.count - 1, "one double-click should close exactly one tab: \(before) -> \(labels())")
        XCTAssertFalse(labels().contains(target.label), "the double-clicked tab is still there")
        // A locked tab.
        let victim = chipSnapshots().filter { !$0.selected && $0.frame.width > 100 }[0]
        chip(chipSnapshots().firstIndex { $0.label == victim.label }!).rightClick()
        XCTAssertNotNil(until(3) { visibleItem("Lock Tab") != nil }); visibleItem("Lock Tab")?.click(); Thread.sleep(forTimeInterval: 0.25)
        let count = labels().count
        if let again = chipSnapshots().first(where: { $0.label == victim.label }) { doubleClick(again) }
        XCTAssertEqual(labels().count, count, "a double-click closed a locked tab")
    }

    /// ORG-21: with the setting on, a single tab shows no strip; a second brings it back.
    func testHideSingleTabStrip() throws {
        launchClassic(tabs: 1, options: ["-UIHideSingleStrip", "1"])
        XCTAssertEqual(chipSnapshots().count, 0, "the strip should be hidden while one tab is open: \(chipSnapshots().map { $0.label })")
        XCTAssertFalse(snapItems().contains { $0.id == "tab-bar" }, "the tab bar is still present while the strip should be hidden")
        attachShot("classic-single-tab-strip-hidden")
        app.typeKey("t", modifierFlags: .command)
        XCTAssertNotNil(until(4) { self.chipSnapshots().count >= 2 }, "the strip did not come back with a second tab")
        XCTAssertTrue(snapItems().contains { $0.id == "tab-bar" }, "the tab bar did not come back with the second tab")
    }

    /// ORG-20: previews appear after the delay when on, and never when off.
    func testHoverPreviewFollowsTheSetting() throws {
        launchClassic(options: ["-UIHoverDelay", "0.3"])
        let w = win.frame
        let target = chipSnapshots().filter { !$0.selected && $0.frame.width > 100 }[0]
        let spot = win.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: target.frame.midX - w.minX, dy: target.frame.midY - w.minY))
        spot.hover()
        XCTAssertNotNil(until(4) { self.any("tab-preview").exists || self.app.descendants(matching: .any).matching(identifier: "tab-preview").count > 0 }, "no preview appeared with previews on")
        app.terminate()
        launchClassic(options: ["-UIHoverPreviews", "0"])
        let target2 = chipSnapshots().filter { !$0.selected && $0.frame.width > 100 }[0]
        win.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: target2.frame.midX - w.minX, dy: target2.frame.midY - w.minY)).hover()
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "tab-preview").count, 0, "a preview appeared with previews off")
    }

    /// 1, 5, 25 and 100 tabs: the selected tab is in view (one snapshot per check).
    func testSelectedTabIsInViewAtEveryTabCount() throws {
        for count in [1, 5, 25, 100] {
            launchClassic(width: 800, tabs: count)
            let w = win.frame
            XCTAssertNotNil(until(5) { guard let s = chipSnapshots().first(where: { $0.selected }) else { return false }; return s.frame.minX >= w.minX - 1 && s.frame.maxX <= w.maxX + 1 }, "\(count) tabs: the selected tab is not in view")
            app.terminate()
        }
    }
}
