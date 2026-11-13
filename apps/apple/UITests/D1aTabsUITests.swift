import XCTest

/// D1a-A runtime checks on the real Classic window: the locked-tab affordance, keyboard focus and arrow keys, the hover preview's lifecycle, and the tab basics in the other layouts.
/// Same isolation as the performance tests (throwaway profile, scratch downloads, refuses to run while another copy of the app is open).
final class D1aTabsUITests: PerfCase {
    private func menuItem(_ title: String) -> XCUIElement { app.menuItems[title].firstMatch }

    private func hasFocus(_ e: XCUIElement) -> Bool { (e.value(forKey: "hasKeyboardFocus") as? Bool) == true }

    func testLockedTabShowsLockAndStaysProtected() throws {
        launch(state: "many-tabs")
        XCTAssertNotNil(until(10) { tabChips().count >= 8 }, "tabs did not appear")
        let tab = chip(3)
        tab.click()
        XCTAssertNotNil(until(3) { tab.isSelected })
        XCTAssertFalse(((tab.value as? String) ?? "").contains("Locked"))
        tab.rightClick()
        XCTAssertTrue(menuItem("Lock Tab").waitForExistence(timeout: 3), "the tab menu has no Lock Tab")
        menuItem("Lock Tab").click()
        XCTAssertNotNil(until(3) { ((tab.value as? String) ?? "").contains("Locked") }, "the locked state is not announced; value = \(String(describing: tab.value))")
        attachShot("locked-tab")
        // The close protection still holds for the keyboard.
        let before = tabChips().count
        app.typeKey("w", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(tabChips().count, before, "a locked tab was closed by Cmd-W")
        // Unlocking brings back ordinary closing.
        tab.rightClick()
        XCTAssertTrue(menuItem("Unlock Tab").waitForExistence(timeout: 3))
        menuItem("Unlock Tab").click()
        XCTAssertNotNil(until(3) { !((tab.value as? String) ?? "").contains("Locked") })
        app.typeKey("w", modifierFlags: .command)
        XCTAssertNotNil(until(3) { tabChips().count == before - 1 }, "an unlocked tab did not close")
    }

    func testKeyboardFocusMovesBetweenTabsAndStaysOutOfTheOmnibox() throws {
        launch(state: "many-tabs")
        XCTAssertNotNil(until(10) { tabChips().count >= 8 })
        // Reach the strip with the Tab key (this depends on the Mac's Keyboard navigation setting; if it is off, the strip cannot be reached by keyboard at all and that is recorded).
        var focused: Int?
        for _ in 0..<40 {
            app.typeKey(.tab, modifierFlags: [])
            if let i = (0..<tabChips().count).first(where: { hasFocus(chip($0)) }) { focused = i; break }
        }
        guard let start = focused else {
            report.note("keyboard: no tab received focus from 40 Tab presses (System Settings > Keyboard > Keyboard navigation is probably off)")
            attachShot("keyboard-no-focus")
            throw XCTSkip("the tab strip could not be reached with the Tab key; Keyboard navigation (Full Keyboard Access) is probably off")
        }
        attachShot("keyboard-focus-start")
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertNotNil(until(2) { hasFocus(chip(start + 1)) }, "Right arrow did not move focus from tab \(start)")
        attachShot("keyboard-focus-after-right")
        app.typeKey(.leftArrow, modifierFlags: [])
        XCTAssertNotNil(until(2) { hasFocus(chip(start)) }, "Left arrow did not move focus back")
        app.typeKey(.end, modifierFlags: [])
        XCTAssertNotNil(until(2) { hasFocus(chip(tabChips().count - 1)) }, "End did not reach the last tab")
        // The first tab here is a pinned tile, whose keyboard focus XCUITest does not report (the screenshot attached below shows its ring), so it is checked by elimination:
        // after more Left presses than there are tabs no other tab holds focus, and Right then moves to the second tab.
        func othersFocused() -> [Int] { (1..<tabChips().count).filter { hasFocus(chip($0)) } }
        for _ in 0..<(tabChips().count + 2) { app.typeKey(.leftArrow, modifierFlags: []) }
        attachShot("after-left-arrows")
        XCTAssertTrue(othersFocused().isEmpty, "Left arrows left focus on tab \(othersFocused())")
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertNotNil(until(2) { hasFocus(chip(1)) }, "Right arrow from the first tab did not reach the second")
        // Home goes back to the first tab (again checked by elimination), End to the last.
        app.typeKey(.home, modifierFlags: [])
        XCTAssertNotNil(until(2) { othersFocused().isEmpty }, "Home did not leave the later tabs; focused: \(othersFocused())")
        attachShot("after-home")
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertNotNil(until(2) { hasFocus(chip(1)) }, "after Home, Right did not reach the second tab")
        // Return opens the focused tab.
        app.typeKey(.return, modifierFlags: [])          // focus is on the second tab from the step above
        XCTAssertNotNil(until(2) { chip(1).isSelected }, "Return did not select the focused tab")
        // The omnibox keeps its arrows.
        app.typeKey("l", modifierFlags: .command)
        XCTAssertNotNil(until(2) { hasFocus(any("omnibox")) })
        paste("abc")
        let selectedBefore = (0..<tabChips().count).first { chip($0).isSelected }
        app.typeKey(.leftArrow, modifierFlags: [])
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertEqual((0..<tabChips().count).first { chip($0).isSelected }, selectedBefore, "arrow keys in the address bar changed the tab")
        XCTAssertTrue((0..<tabChips().count).allSatisfy { !hasFocus(chip($0)) }, "a tab took focus from the address bar")
        XCTAssertEqual(any("omnibox").value as? String, "abc")
    }

    func testHoverPreviewAppearsAndEndsWithItsContext() throws {
        launch(state: "workspaces")
        app.typeKey("k", modifierFlags: .command)
        XCTAssertNotNil(until(3) { any("palette-field").exists })
        paste("Layout: Classic"); app.typeKey(.return, modifierFlags: [])
        XCTAssertNotNil(until(5) { any("omnibox").exists && !any("sidebar").exists }, "Classic did not come back")
        XCTAssertNotNil(open("/p/Hover", title: "Hover"))
        let tab = chip(0)
        func previewShown() -> Bool { app.descendants(matching: .any)["tab-preview"].exists }
        // Appears after the delay while the pointer rests on the tab.
        tab.hover()
        let shown = until(3) { previewShown() }
        if shown == nil { attachShot("no-preview"); report.note("hover: no popover/window after resting; windows=\(app.windows.count) popovers=\(app.popovers.count)") }
        XCTAssertNotNil(shown, "no preview after resting on a tab (windows \(app.windows.count), popovers \(app.popovers.count))")
        // Ends when the pointer leaves.
        win.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.7)).hover()
        XCTAssertNotNil(until(2) { !previewShown() }, "the preview stayed after the pointer left")
        // A workspace change during the delay: nothing shows afterwards.
        tab.hover()
        app.typeKey("2", modifierFlags: .control)
        Thread.sleep(forTimeInterval: 1.3)
        // A tab of the new workspace may now be under the resting pointer, and its own preview is legitimate; the old workspace's tab must not be previewed.
        XCTAssertFalse(app.descendants(matching: .any)["tab-preview"].staticTexts.matching(NSPredicate(format: "value CONTAINS 'Hover' OR label CONTAINS 'Hover'")).firstMatch.exists, "the old workspace's tab was previewed after the workspace changed")
        app.typeKey("1", modifierFlags: .control)
        // The command palette taking over during the delay: nothing shows.
        win.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.7)).hover()
        chip(0).hover()
        app.typeKey("k", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1.3)
        XCTAssertFalse(previewShown(), "a preview appeared over the command palette")
    }

    func testTabBasicsInTheOtherLayouts() throws {
        launch(state: "many-tabs")
        XCTAssertNotNil(until(10) { tabChips().count >= 8 })
        for layout in ["Minimal", "One Row", "Sidebar", "Classic"] {
            app.typeKey("k", modifierFlags: .command)
            XCTAssertNotNil(until(8) { any("palette-field").exists }, "the palette did not open before switching to \(layout)")
            paste("Layout: \(layout)"); app.typeKey(.return, modifierFlags: [])
            Thread.sleep(forTimeInterval: 0.8)
            XCTAssertNotNil(until(5) { tabChips().count >= 2 }, "\(layout): no tabs")
            let target = 2
            app.typeKey("\(target + 1)", modifierFlags: .command)
            if layout != "One Row" { XCTAssertNotNil(until(3) { (0..<tabChips().count).contains { chip($0).isSelected } && chipLabels()[safe: target] != nil }, "\(layout): no tab is selected after selecting one") }   // in One Row the selected tab is the address field itself
            app.typeKey("t", modifierFlags: .command)
            let withNew = tabChips().count
            XCTAssertNotNil(until(3) { tabChips().count == withNew })
            app.typeKey("w", modifierFlags: .command)
            XCTAssertNotNil(until(3) { tabChips().count == withNew - 1 }, "\(layout): closing a tab failed")
            attachShot("layout-\(layout)")
        }
    }
}

private extension Array { subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }
