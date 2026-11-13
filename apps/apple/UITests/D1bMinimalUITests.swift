import XCTest

/// D1b Minimal: the compact strip's click safety, selected-tab visibility with many tabs, keyboard focus, scroll-bar styles and narrow widths. Real window, throwaway profile.
class D1bMinimalUITests: PerfCase {
    /// The layout under test: Minimal here; Minimal Reversed's parity class changes only these three (its palette title, its launch name, and where the strip is).
    var layoutName: String { "minimal" }
    var layoutTitle: String { "Minimal" }
    var stripTop: CGFloat { 40 }
    private func goMinimal() {
        app.typeKey("k", modifierFlags: .command)
        XCTAssertNotNil(until(8) { any("palette-field").exists }, "the palette did not open")
        paste("Layout: \(layoutTitle)"); app.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.9)
    }
    func launchMinimal(width: Int = 1000, extra: [String] = [], state: String = "many-tabs", env: [String: String] = [:]) {
        launch(state: state, extra: extra, env: ["BS_WINDOW_SIZE": "\(width)x800"].merging(env) { a, _ in a })
        XCTAssertNotNil(until(15) { win.exists && abs(win.frame.width - CGFloat(width)) < 6 && (state != "many-tabs" || tabChips().count >= 8) }, "window did not reach \(width)")
        goMinimal()
    }
    /// Groups inline in the compact strip too.
    func testCompactStripShowsGroupsInline() throws {
        launch(state: "bulk-tabs", extra: ["-UITabCount", "8", "-UILayout", layoutName, "-UIGroups", "1"], env: ["BS_WINDOW_SIZE": "1000x800"])
        XCTAssertNotNil(until(20) { win.exists && any("tab-bar").exists }, "\(layoutTitle) did not come up")
        let label = app.descendants(matching: .any).matching(identifier: "strip-group-label").firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 3), "no inline group label in the compact strip")
        let before = chipSnapshots().count
        label.click(); Thread.sleep(forTimeInterval: 0.4)
        XCTAssertLessThan(chipSnapshots().count, before, "collapsing did not hide the group's tabs")
    }

    /// The compact strip has Classic's group chip (the visible way to see and leave the group shown) and, when full, the All Tabs menu.
    func testCompactStripHasTheGroupChipAndAllTabs() throws {
        launch(state: "bulk-tabs", extra: ["-UITabCount", "40", "-UILayout", layoutName, "-UIGroups", "1"], env: ["BS_WINDOW_SIZE": "1000x800"])
        XCTAssertNotNil(until(20) { win.exists && any("tab-bar").exists }, "\(layoutTitle) did not come up")
        XCTAssertTrue(any("classic-group-chip").waitForExistence(timeout: 3), "no group chip in the compact strip")
        let allTabs = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'tab-overflow-menu' OR label BEGINSWITH 'All tabs'")).firstMatch
        XCTAssertTrue(allTabs.waitForExistence(timeout: 3), "no All Tabs menu on a full compact strip")
        allTabs.click()
        let item = app.menuItems["Page Bulk38"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 3), "All Tabs does not list the tabs")
        item.click(); Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(chipSnapshots().first { $0.selected }?.label.hasPrefix("Page Bulk38") == true, "choosing a tab in All Tabs did not select it")
    }

    private func selectedIndex() -> Int? { chipSnapshots().firstIndex { $0.selected } }
    private func hasFocus(_ e: XCUIElement) -> Bool { (e.value(forKey: "hasKeyboardFocus") as? Bool) == true }
    /// A picture of the tab strip (window points y 40–78), as bytes: the focus ring, which XCUITest cannot report for icon-only tiles, shows up as a change in it.
    private func stripPicture() -> Data? {
        guard let cg = win.safeScreenshot()?.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = CGFloat(cg.width) / win.frame.width
        guard let crop = cg.cropping(to: CGRect(x: 0, y: stripTop * scale, width: CGFloat(cg.width), height: 38 * scale)), let data = crop.dataProvider?.data else { return nil }
        return data as Data
    }

    private func openTabs(upTo n: Int) { while tabChips().count < n { let c = tabChips().count; app.typeKey("t", modifierFlags: .command); _ = until(3) { tabChips().count > c } } }
    private func saveShot(_ name: String) { attachShot(name) }

    /// D1B-01/02: pointing at an inactive favicon and clicking selects that tab; nothing closes.
    func testInactiveTabClickSelectsAndNeverCloses() throws {
        launchMinimal()
        saveShot("minimal-baseline")
        for target in [3, 5, 2, 6, 4] {
            let before = tabChips().count
            let label = chip(target).label
            chip(target).hover()
            Thread.sleep(forTimeInterval: 0.25)
            if target == 3 { saveShot("minimal-hover-inactive") }
            chip(target).click()
            Thread.sleep(forTimeInterval: 0.4)
            XCTAssertEqual(tabChips().count, before, "clicking the inactive tab \"\(label)\" closed a tab (\(before) → \(tabChips().count))")
            XCTAssertTrue(chipLabels().contains(label), "tab \"\(label)\" is gone after being clicked")
            if let i = selectedIndex() { XCTAssertEqual(chip(i).label, label, "the click selected \"\(chip(i).label)\" instead of \"\(label)\"") } else { XCTFail("no tab is selected") }
        }
        // Rapid hover-and-click sequences.
        let before = tabChips().count
        for _ in 0..<6 { for t in [2, 4] { chip(t).hover(); chip(t).click() } }
        XCTAssertEqual(tabChips().count, before, "rapid hover/click closed a tab")
    }

    /// D1B-04/05: the tab menu closes the tab it was opened on; a locked tab is not closed.
    func testContextMenuCloseAndLockedProtection() throws {
        launchMinimal()
        let victim = chip(4).label, keep = chip(3).label
        chip(4).rightClick()
        func visibleItem(_ title: String) -> XCUIElement? { app.menuItems.matching(NSPredicate(format: "title == %@", title)).allElementsBoundByIndex.first { $0.isHittable } }
        XCTAssertNotNil(until(3) { visibleItem("Close Tab") != nil }, "no Close Tab in the tab menu")
        let close = visibleItem("Close Tab")!
        let before = tabChips().count
        close.click()
        XCTAssertNotNil(until(3) { tabChips().count == before - 1 }, "the menu's Close Tab did not close")
        XCTAssertFalse(chipLabels().contains(victim), "the wrong tab was closed: \"\(victim)\" is still there")
        XCTAssertTrue(chipLabels().contains(keep), "\"\(keep)\" was closed instead")
        // Lock one, then try to close it by the menu and the keyboard.
        let locked = chip(3).label
        chip(3).rightClick()
        XCTAssertNotNil(until(3) { visibleItem("Lock Tab") != nil }); visibleItem("Lock Tab")!.click()
        XCTAssertNotNil(until(3) { ((chip(3).value as? String) ?? "").contains("Locked") }, "the locked state is not announced")
        saveShot("minimal-locked-inactive")
        let n = tabChips().count
        chip(3).hover(); chip(3).click(); Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(tabChips().count, n, "clicking a locked inactive tab closed it")
        app.typeKey("w", modifierFlags: .command); Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(tabChips().count, n, "Cmd-W closed a locked tab")
        XCTAssertTrue(chipLabels().contains(locked))
    }

    /// D1B-12/13/14: the selected tab is fully visible and + stays reachable, from 1 to 100 tabs, after selecting, opening, closing and resizing. The tabs are created at once by the app's debug state.
    func testSelectedTabStaysVisibleWithManyTabs() throws {
        for count in [1, 5, 25, 100] {
            launch(state: "bulk-tabs", extra: ["-UITabCount", "\(count)", "-UILayout", layoutName], env: ["BS_WINDOW_SIZE": "800x800"])
            XCTAssertNotNil(until(30) { win.exists && abs(win.frame.width - 800) < 6 && tabChips().count >= max(1, count - 1) }, "\(count): the tabs did not appear (\(tabChips().count))")
            Thread.sleep(forTimeInterval: 1.0)
            let w = win.frame
            func plus() -> CGRect { win.buttons.matching(NSPredicate(format: "label == 'New Tab' AND identifier == 'tab-bar'")).firstMatch.frame }
            func selectedVisible(_ why: String) {
                XCTAssertNotNil(until(3) { guard let selected = chipSnapshots().first(where: { $0.selected }) else { return false }; let f = selected.frame; return f.minX >= w.minX - 1 && f.maxX <= plus().minX + 2 }, "\(count) tabs, \(why): the selected tab is not fully visible (frame \(String(describing: selectedIndex().map { chip($0).frame })), + at \(plus().minX))")
            }
            selectedVisible("with the last tab selected")
            if count >= 5 {
                app.typeKey("1", modifierFlags: .command); selectedVisible("after Cmd-1")
                app.typeKey("9", modifierFlags: .command); selectedVisible("after Cmd-9 (the ninth tab)")
                app.typeKey("w", modifierFlags: .command); selectedVisible("after closing a tab")
            }
            XCTAssertGreaterThanOrEqual(plus().minX, w.minX); XCTAssertLessThanOrEqual(plus().maxX, w.maxX + 1, "\(count): the New Tab button is not on screen")
            report.note("MINIMAL-MANY \(count): chips \(tabChips().count), selected \(String(describing: selectedIndex())), + at x \(Int(plus().minX - w.minX))")
            if count == 25 { saveShot("minimal-25-tabs") }
            if count == 100 { saveShot("minimal-100-tabs") }
            app.terminate()
        }
    }

    /// D1B-08: Tab reaches the compact strip (the focus ring appears there), arrow keys move it, Return selects the focused tab, and the address bar keeps its arrows.
    func testKeyboardNavigationInMinimal() throws {
        launchMinimal()
        app.typeKey(.escape, modifierFlags: [])
        win.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).hover()          // the pointer off the strip, so hover does not change the picture
        Thread.sleep(forTimeInterval: 0.8)
        guard let rest = stripPicture() else { XCTFail("no picture of the strip"); return }
        var reached = false
        for _ in 0..<30 {
            app.typeKey(.tab, modifierFlags: [])
            Thread.sleep(forTimeInterval: 0.35)
            if let now = stripPicture(), now != rest { reached = true; break }
        }
        XCTAssertTrue(reached, "no focus ring ever appeared in the tab strip from 30 Tab presses")
        saveShot("minimal-keyboard-focus")
        guard reached else { return }
        // The ring is on the first tab (the pinned one, which is also the selected one). Right moves it; the picture changes.
        let onFirst = stripPicture()
        app.typeKey(.rightArrow, modifierFlags: []); Thread.sleep(forTimeInterval: 0.4)
        XCTAssertNotEqual(stripPicture(), onFirst, "Right arrow did not move the focus ring")
        saveShot("minimal-keyboard-focus-right")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertNotNil(until(3) { selectedIndex() == 1 }, "Return on the second tab did not select it (selected \(String(describing: selectedIndex())))")
        // End and Home keep the ring in the strip; Return then selects the last / first tab.
        app.typeKey(.end, modifierFlags: []); Thread.sleep(forTimeInterval: 0.3); app.typeKey(.return, modifierFlags: [])
        XCTAssertNotNil(until(3) { selectedIndex() == tabChips().count - 1 }, "End then Return did not select the last tab (selected \(String(describing: selectedIndex())))")
        app.typeKey(.home, modifierFlags: []); Thread.sleep(forTimeInterval: 0.3); app.typeKey(.return, modifierFlags: [])
        XCTAssertNotNil(until(3) { selectedIndex() == 0 }, "Home then Return did not select the first tab (selected \(String(describing: selectedIndex())))")
        // The address bar keeps its arrows.
        app.typeKey("l", modifierFlags: .command)
        XCTAssertNotNil(until(2) { hasFocus(any("omnibox")) })
        paste("abc"); let sel = selectedIndex()
        app.typeKey(.leftArrow, modifierFlags: []); app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertEqual(selectedIndex(), sel, "arrow keys in the address bar changed the tab")
    }

    /// D1B-15: the compact strip stays level with the + button under each scroll-bar style.
    func testStripAlignmentUnderScrollBarStyles() throws {
        for style in ["WhenScrolling", "Always"] {
            launchMinimal(width: 900, extra: ["-AppleShowScrollBars", style])
            Thread.sleep(forTimeInterval: 0.5)
            let w = win.frame
            let plus = win.buttons.matching(NSPredicate(format: "label == 'New Tab' AND identifier == 'tab-bar'")).firstMatch.frame
            let c = chip(3).frame
            report.note(String(format: "MINIMAL-ALIGN scrollbars=%@: chip mid %.1f, + mid %.1f (offset %.1f)", style, Double(c.midY - w.minY), Double(plus.midY - w.minY), Double(plus.midY - c.midY)))
            XCTAssertEqual(c.midY, plus.midY, accuracy: 1.5, "\(style): the compact strip is not level with the + button")
            saveShot("minimal-scrollbars-\(style)")
            app.terminate()
        }
    }

    /// D1B-16/17/18/19: narrow widths and the Library open: nothing overlaps, the field is usable, the selected tab is visible.
    func testNarrowWidthsAndLibraryOpen() throws {
        for width in [520, 640, 800] {
            launchMinimal(width: width)
            Thread.sleep(forTimeInterval: 0.5)
            let w = win.frame
            XCTAssertNotNil(any("omnibox").exists ? true : nil, "\(width): no address field")
            if let o = any("omnibox").exists ? any("omnibox").frame : nil, let more = any("more-menu").exists ? any("more-menu").frame : nil, let back = any("back-button").exists ? any("back-button").frame : nil {
                XCTAssertGreaterThanOrEqual(o.minX, back.maxX + 2, "\(width): the field runs into Back"); XCTAssertLessThanOrEqual(o.maxX, more.minX - 2, "\(width): the field runs into More")
            }
            app.typeKey("9", modifierFlags: .command)
            XCTAssertNotNil(until(3) { guard let i = selectedIndex() else { return false }; let f = chip(i).frame; return f.minX >= w.minX - 1 && f.maxX <= w.maxX + 1 }, "\(width): selected tab not visible")
            app.typeKey("l", modifierFlags: [.command, .shift])
            XCTAssertNotNil(until(5) { any("sidebar").exists }, "\(width): the Library did not open")
            Thread.sleep(forTimeInterval: 0.8)
            let page = win.descendants(matching: .webView).firstMatch.frame
            report.note("MINIMAL-LIBRARY @\(width): sidebar w \(Int(any("sidebar").frame.width)), page w \(Int(page.width))")
            XCTAssertGreaterThan(page.width, 200, "\(width): the page is squeezed to \(page.width)")
            saveShot("minimal-library-\(width)")
            app.terminate()
        }
    }

    /// Persistent pictures: light and dark, wide.
    func testAppearancePictures() throws {
        for mode in ["Light", "Dark"] {
            launch(state: "many-tabs", env: ["BS_WINDOW_SIZE": "1200x800"].merging(mode == "Light" ? ["BS_SETUP_LIGHT": "1"] : [:]) { a, _ in a })
            XCTAssertNotNil(until(15) { win.exists && abs(win.frame.width - 1200) < 6 && tabChips().count >= 8 })
            goMinimal()
            chip(3).hover(); Thread.sleep(forTimeInterval: 0.4)
            saveShot("minimal-\(mode)-1200-hover")
            app.terminate()
        }
    }

    /// What the pointer, the preview and the selection look like around a click (a diagnostic note only; the assertions are the test's own).
    private func hoverDiagnostic(_ when: String, target: Int) {
        let e = chip(target)
        let preview = app.descendants(matching: .any).matching(identifier: "tab-preview").count
        let windows = app.windows.allElementsBoundByIndex.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" }
        let line = "HOVERDIAG \(when): chip \(target) exists \(e.exists) frame \(e.exists ? e.frame : .zero) hittable \(e.exists && e.isHittable); preview elements \(preview); selected index \(String(describing: selectedIndex())); windows \(windows)"
        report.note(line)
        let a = XCTAttachment(string: line); a.name = "hoverdiag-" + when; a.lifetime = .keepAlways; add(a)
    }

    /// D1B-01/02, rapid and slow: hovering first (with or without the preview showing) never changes what a click does.
    func testHoverThenClickAlwaysSelects() throws {
        let traceFile = NSTemporaryDirectory() + "bs-click-trace.log"
        try? FileManager.default.removeItem(atPath: traceFile)
        launchMinimal(env: ["BS_CHROME_TRACE": traceFile, "BS_CLICK_TRACE": "1"])
        // The record of the mouse, the preview and the selection around the clicks, kept with the result whenever any trial fails (bounded: 300 lines).
        addTeardownBlock {
            guard self.testRun?.failureCount ?? 0 > 0, let text = try? String(contentsOfFile: traceFile, encoding: .utf8) else { return }
            let a = XCTAttachment(string: text); a.name = "click-trace-on-failure"; a.lifetime = .keepAlways; self.add(a)
        }
        func trial(_ name: String, _ target: Int, _ body: () -> Void) {
            chip(0).click(); Thread.sleep(forTimeInterval: 0.6)            // back to the first tab
            let before = tabChips().count
            body()
            Thread.sleep(forTimeInterval: 0.6)
            XCTAssertEqual(tabChips().count, before, "\(name): a tab was closed")
            XCTAssertEqual(selectedIndex(), min(target, tabChips().count - 1), "\(name): the click did not select tab \(target)")
            report.note("HOVERCLICK \(name): target \(target) \"\(chip(min(target, tabChips().count - 1)).label)\" → selected index \(String(describing: selectedIndex())), count \(before) → \(tabChips().count), popovers \(app.popovers.count)")
        }
        trial("click only", 3) { chip(3).click() }
        trial("hover, click at once", 4) { chip(4).hover(); chip(4).click() }
        trial("hover, wait 0.25 s, click", 5) { chip(5).hover(); Thread.sleep(forTimeInterval: 0.25); chip(5).click() }
        trial("hover, wait 0.9 s (preview up), click", 6) {
            chip(6).hover(); Thread.sleep(forTimeInterval: 0.9)
            hoverDiagnostic("before click", target: 6)
            chip(6).click()
            hoverDiagnostic("right after click", target: 6)
            Thread.sleep(forTimeInterval: 0.3)
            hoverDiagnostic("300 ms after click", target: 6)
        }
        trial("click, then click the same tab again", 7) { chip(7).click(); Thread.sleep(forTimeInterval: 0.5); chip(selectedIndex() ?? 7).click() }
    }
}
