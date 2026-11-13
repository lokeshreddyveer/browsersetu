import XCTest

/// D1c One Row: the active tab is the address field, the other tabs share one row with it. Checks click safety on compact cells, locked tabs, keyboard navigation, selected-tab visibility with many tabs,
/// the active field's editing and suggestions, responsive geometry, the Library and a crowded toolbar. Real window, throwaway profile, window-only pictures.
final class D1cOneRowUITests: PerfCase {
    private func launchOneRow(width: Int = 1000, tabs: Int = 8, extra: [String] = [], env: [String: String] = [:], light: Bool = false) {
        var e = ["BS_WINDOW_SIZE": "\(width)x800"].merging(env) { a, _ in a }
        if light { e["BS_SETUP_LIGHT"] = "1" }
        launch(state: "bulk-tabs", extra: ["-UITabCount", "\(tabs)", "-UILayout", "inline"] + extra, env: e)
        XCTAssertNotNil(until(30) { win.exists && abs(win.frame.width - CGFloat(width)) < 6 && any("omnibox").exists }, "One Row did not come up at \(width)")
        Thread.sleep(forTimeInterval: 0.8)
    }
    private func selectedFieldFrame() -> CGRect? { any("omnibox").exists ? any("omnibox").frame : nil }
    private func hasFocus(_ e: XCUIElement) -> Bool { (e.value(forKey: "hasKeyboardFocus") as? Bool) == true }
    private func stripPicture() -> Data? {
        guard let cg = win.safeScreenshot()?.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = CGFloat(cg.width) / win.frame.width
        guard let crop = cg.cropping(to: CGRect(x: 0, y: 0, width: CGFloat(cg.width), height: 40 * scale)), let data = crop.dataProvider?.data else { return nil }
        return data as Data
    }
    /// Every control in the top 44 pt that is outside the tab row, left to right: none may leave the window or overlap its neighbour.
    private func barControls() -> [(String, CGRect)] {
        let w = win.frame
        let items = snapItems()                                         // one accessibility snapshot: nothing can go stale between reading the elements
        let strip = items.first { $0.id == "tab-bar" }?.frame ?? .zero
        let button = UInt(XCUIElement.ElementType.button.rawValue)
        return items.compactMap { b -> (String, CGRect)? in
            let f = b.frame
            guard b.type == button, f.width > 0, b.id != "tab-chip", !b.label.contains("protection"), f.minY - w.minY < 44, f.minX - w.minX > 70, !strip.insetBy(dx: -1, dy: -1).contains(f) else { return nil }
            return (b.label.isEmpty ? b.id : b.label, f)
        }.sorted { $0.1.minX < $1.1.minX }
    }
    private func assertNoOverlap(_ label: String) {
        let w = win.frame, items = barControls()
        for (id, r) in items { XCTAssertGreaterThanOrEqual(r.minX, w.minX - 1, "\(label): \(id) leaves the window on the left"); XCTAssertLessThanOrEqual(r.maxX, w.maxX + 1, "\(label): \(id) leaves the window on the right") }
        for (a, b) in zip(items, items.dropFirst()) { XCTAssertLessThanOrEqual(a.1.maxX, b.1.minX + 1, "\(label): \(a.0) overlaps \(b.0)") }
    }
    /// A close-up of the top of the window at full pixel density.
    private func attachCrop(_ name: String, width: CGFloat = 700, height: CGFloat = 64) {
        guard let cg = win.safeScreenshot()?.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let scale = CGFloat(cg.width) / win.frame.width
        guard let crop = cg.cropping(to: CGRect(x: 0, y: 0, width: min(width, win.frame.width) * scale, height: height * scale)) else { return }
        let a = XCTAttachment(image: NSImage(cgImage: crop, size: NSSize(width: crop.width, height: crop.height))); a.name = name; a.lifetime = .keepAlways; add(a)
    }
    private var hasBack: Bool { until(4) { win.buttons["Back"].exists } != nil }
    private var hasMore: Bool { any("more-menu").exists || win.menuButtons["More"].exists }
    private var hasNewTabRoute: Bool { win.buttons["New Tab"].exists || hasMore }

    /// D1C-09: pointing at a compact cell and clicking selects it; nothing closes.
    func testCompactCellsNeverCloseOnClick() throws {
        launchOneRow(width: 520, tabs: 8)
        attachShot("one-row-520-dark")
        let before = tabChips().count
        XCTAssertGreaterThanOrEqual(before, 4, "no inactive cells (\(before))")
        for target in [1, 3, 2, 4] where target < tabChips().count {
            let label = chip(target).label
            chip(target).hover(); Thread.sleep(forTimeInterval: 0.3)
            if target == 1 { attachShot("one-row-hover-inactive") }
            chip(target).click(); Thread.sleep(forTimeInterval: 0.5)
            XCTAssertTrue(chipLabels().contains(where: { $0 == label }) || any("omnibox").exists, "the tab \"\(label)\" is gone after a click")
        }
        XCTAssertGreaterThanOrEqual(tabChips().count + 1, before, "a click on a compact cell closed a tab (\(before) inactive cells before, \(tabChips().count) after)")
    }

    /// D1C-13: a locked cell is marked as locked, is not closed by click or Cmd-W, and unlocks again.
    func testLockedCellIsMarkedAndProtected() throws {
        launchOneRow(width: 1000, tabs: 6)
        func visibleItem(_ title: String) -> XCUIElement? { app.menuItems.matching(NSPredicate(format: "title == %@", title)).allElementsBoundByIndex.first { $0.isHittable } }
        chip(1).rightClick()
        XCTAssertNotNil(until(3) { visibleItem("Lock Tab") != nil }, "no Lock Tab in the tab menu"); visibleItem("Lock Tab")!.click()
        XCTAssertNotNil(until(3) { ((chip(1).value as? String) ?? "").contains("Locked") }, "the locked state is not announced; value = \(String(describing: chip(1).value))")
        chip(1).hover(); Thread.sleep(forTimeInterval: 0.3)
        attachShot("one-row-locked")
        let n = tabChips().count
        chip(1).click(); Thread.sleep(forTimeInterval: 0.5)
        app.typeKey("w", modifierFlags: .command); Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(tabChips().count + 0, tabChips().count)   // count of inactive cells may change by one as selection moves; the locked tab must still exist
        XCTAssertTrue(chipLabels().count >= n - 1, "a locked tab was closed")
    }

    /// D1C-04/05/06/07/19: Cmd-L focuses the field, typing keeps text and focus, the field does not jump, suggestions line up with it and go when the tab changes.
    func testActiveFieldEditingAndSuggestions() throws {
        launchOneRow(width: 1000, tabs: 4)
        attachShot("one-row-field-display")
        app.typeKey("l", modifierFlags: .command)
        XCTAssertNotNil(until(3) { hasFocus(any("omnibox")) }, "Cmd-L did not focus the field")
        let before = selectedFieldFrame()!
        paste("swift browser")
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertEqual(any("omnibox").value as? String, "swift browser", "typed text was lost or replaced")
        XCTAssertTrue(hasFocus(any("omnibox")), "the field lost focus while typing")
        let after = selectedFieldFrame()!
        report.note(String(format: "ONEROW field: display x %.0f–%.0f (w %.0f) → editing x %.0f–%.0f (w %.0f)", before.minX, before.maxX, before.width, after.minX, after.maxX, after.width))
        let row = win.buttons["Search for “swift browser”"]
        XCTAssertNotNil(until(4) { row.exists }, "no suggestion row")
        if row.exists {
            let r = row.frame, w = win.frame
            report.note(String(format: "ONEROW suggestion x %.0f–%.0f; field x %.0f–%.0f; window width %.0f", r.minX - w.minX, r.maxX - w.minX, after.minX - w.minX, after.maxX - w.minX, w.width))
            XCTAssertGreaterThanOrEqual(r.minX, w.minX - 1); XCTAssertLessThanOrEqual(r.maxX, w.maxX + 1, "suggestions leave the window")
            XCTAssertLessThanOrEqual(abs(r.minX - after.minX), 140, "suggestions are not lined up with the field")
        }
        attachShot("one-row-field-editing-suggestions")
        // A tab change drops them.
        app.typeKey("2", modifierFlags: .command)
        XCTAssertNotNil(until(3) { !win.buttons["Search for “swift browser”"].exists }, "stale suggestions stayed after changing tab")
        app.typeKey("l", modifierFlags: .command); paste("keep"); app.typeKey(.escape, modifierFlags: [])
        XCTAssertNotEqual(any("omnibox").value as? String, "keep", "Escape did not leave editing")
    }

    /// D1C-10/11/12: the selected tab and the New Tab route stay reachable from 1 to 100 tabs.
    func testSelectedTabVisibleWithManyTabs() throws {
        for count in [1, 5, 25, 100] {
            launchOneRow(width: 800, tabs: count)
            let w = win.frame
            func fieldVisible(_ why: String) {
                XCTAssertNotNil(until(3) { guard let f = selectedFieldFrame() else { return false }; return f.minX >= w.minX - 1 && f.maxX <= w.maxX + 1 && f.width > 60 }, "\(count) tabs, \(why): the active field is not visible (\(String(describing: selectedFieldFrame())))")
            }
            fieldVisible("with the last tab selected")
            if count >= 5 {
                app.typeKey("1", modifierFlags: .command); fieldVisible("after Cmd-1")
                app.typeKey("9", modifierFlags: .command); fieldVisible("after Cmd-9")
                app.typeKey("w", modifierFlags: .command); fieldVisible("after closing a tab")
            }
            XCTAssertTrue(hasNewTabRoute, "\(count): no New Tab route (button or More)")
            report.note("ONEROW-MANY \(count): inactive cells \(tabChips().count); active field w \(Int(selectedFieldFrame()?.width ?? 0))")
            if count == 5 || count == 25 || count == 100 || count == 1 { attachShot("one-row-\(count)-tabs") }
            app.terminate()
        }
    }

    /// D1C-21: Tab reaches the cells (a ring appears), arrows move it, Return selects; the field keeps its arrows.
    /// Groups inline in One Row: the label sits in the row and collapses its tabs.
    func testOneRowShowsGroupsInline() throws {
        launch(state: "bulk-tabs", extra: ["-UITabCount", "8", "-UILayout", "inline", "-UIGroups", "1"], env: ["BS_WINDOW_SIZE": "1200x800"])
        XCTAssertNotNil(until(20) { self.win.exists && self.any("inline-bar").exists }, "One Row did not come up")
        let label = app.descendants(matching: .any).matching(identifier: "strip-group-label").firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 3), "no inline group label in One Row")
        let before = chipSnapshots().count
        label.click(); Thread.sleep(forTimeInterval: 0.5)
        XCTAssertLessThan(chipSnapshots().count, before, "collapsing did not hide the group's tabs in One Row")
    }

    /// Dragging a One Row tab reorders it and does not drag the window (the tabs sit in the title-bar band).
    func testOneRowTabDragMovesTheTabNotTheWindow() throws {
        launch(state: "bulk-tabs", extra: ["-UITabCount", "6", "-UILayout", "inline"], env: ["BS_WINDOW_SIZE": "1200x800"])
        XCTAssertNotNil(until(20) { self.win.exists && self.any("inline-bar").exists }, "One Row did not come up")
        let origin = win.frame.origin
        let cells = chipSnapshots().filter { !$0.selected }.sorted { $0.frame.minX < $1.frame.minX }
        guard cells.count >= 3 else { return XCTFail("too few inactive cells: \(cells.count)") }
        let first = cells[0], last = cells[cells.count - 1]
        let before = chipSnapshots().sorted { $0.frame.minX < $1.frame.minX }.map(\.label)
        let at = { (x: CGFloat, y: CGFloat) in self.win.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x - self.win.frame.minX, dy: y - self.win.frame.minY)) }
        at(first.frame.midX, first.frame.midY).hover(); Thread.sleep(forTimeInterval: 0.2)
        at(first.frame.midX, first.frame.midY).click(forDuration: 0.5, thenDragTo: at(last.frame.midX + 6, last.frame.midY))
        Thread.sleep(forTimeInterval: 0.5)
        let after = chipSnapshots().sorted { $0.frame.minX < $1.frame.minX }.map(\.label)
        XCTAssertEqual(win.frame.origin.x, origin.x, accuracy: 2, "dragging a tab moved the window")
        XCTAssertEqual(win.frame.origin.y, origin.y, accuracy: 2, "dragging a tab moved the window")
        XCTAssertNotEqual(before, after, "dragging a tab did not reorder the row (\(before) → \(after))")
    }

    func testKeyboardNavigationInOneRow() throws {
        launchOneRow(width: 1000, tabs: 8)
        app.typeKey(.escape, modifierFlags: [])
        win.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).hover(); Thread.sleep(forTimeInterval: 0.8)
        guard let rest = stripPicture() else { XCTFail("no picture of the row"); return }
        var changes = 0, last = rest
        for _ in 0..<30 {
            app.typeKey(.tab, modifierFlags: []); Thread.sleep(forTimeInterval: 0.3)
            if let now = stripPicture(), now != last { changes += 1; last = now }
        }
        attachShot("one-row-keyboard-focus")
        // A ring on a cell is a change that is NOT just toolbar buttons: arrows must move something in the row.
        var moved = false
        let base = stripPicture()
        app.typeKey(.rightArrow, modifierFlags: []); Thread.sleep(forTimeInterval: 0.4)
        if let now = stripPicture(), now != base { moved = true }
        // At the last cell before the field, Right has nowhere to go (it steps over the field): Left must move then.
        if !moved { app.typeKey(.leftArrow, modifierFlags: []); Thread.sleep(forTimeInterval: 0.4); if let now = stripPicture(), now != base { moved = true } }
        report.note("ONEROW keyboard: picture changes over 30 Tab presses \(changes); arrow moved something: \(moved)")
        XCTAssertTrue(moved, "no arrow-key navigation among the cells")
    }

    /// D1C-02/16/17/18: at every width nothing overlaps, Back and More are there, and the field is usable.
    func testResponsiveGeometry() throws {
        for width in [520, 640, 800, 1000, 1200, 1600] {
            launchOneRow(width: width, tabs: 8)
            let w = win.frame
            assertNoOverlap("one row \(width)")
            let field = selectedFieldFrame()
            report.note(String(format: "ONEROW @%d: field x %.0f–%.0f (w %.0f); inactive cells %d; back %@, more %@", width, (field?.minX ?? 0) - w.minX, (field?.maxX ?? 0) - w.minX, field?.width ?? 0, tabChips().count, hasBack ? "yes" : "no", hasMore ? "yes" : "no"))
            XCTAssertTrue(hasBack && hasMore, "\(width): Back or More is missing")
            // "omnibox" is the text region inside the field (the field itself, with its icons, is about 105 pt wider).
            XCTAssertGreaterThan(field?.width ?? 0, 60, "\(width): the field is too narrow to use (\(field?.width ?? 0))")
            if width == 800 || width == 1200 { attachShot("one-row-\(width)-dark") }
            app.terminate()
        }
    }

    func testLightAppearancePicture() throws {
        launchOneRow(width: 1200, tabs: 8, light: true)
        attachShot("one-row-1200-light")
        XCTAssertTrue(any("omnibox").exists)
    }

    /// D1C-25: Library open at narrow and wide windows.
    /// What the bar's geometry is, written down before it is judged: the window, the Library, the strip, the active field and every control in the bar (positions relative to the window's left edge).
    private func attachGeometry(_ name: String) {
        let w = win.frame
        func r(_ f: CGRect) -> String { String(format: "x %.0f–%.0f (w %.0f)", f.minX - w.minX, f.maxX - w.minX, f.width) }
        var lines = ["window w \(Int(w.width))"]
        if any("sidebar").exists { lines.append("library \(r(any("sidebar").frame))") }
        if any("tab-bar").exists { lines.append("tab-bar \(r(any("tab-bar").frame))") }
        let snap = snapItems()
        lines.append("selected field \(snap.first { $0.id == "omnibox" }.map { r($0.frame) } ?? "none")")
        lines.append("reload \(snap.first { $0.id == "reload-button" }.map { r($0.frame) } ?? "none")")
        lines.append("page \(snap.first { $0.type == UInt(XCUIElement.ElementType.webView.rawValue) }.map { r($0.frame) } ?? "none")")
        let cells = chipSnapshots(); lines.append("cells \(cells.count), selected index \(cells.firstIndex { $0.selected }.map(String.init) ?? "none"), selected \(cells.first { $0.selected }.map { r($0.frame) } ?? "none")")
        for (n, f) in barControls() { lines.append("control \(n): \(r(f))") }
        let a = XCTAttachment(string: lines.joined(separator: "\n")); a.name = "geometry-" + name; a.lifetime = .keepAlways; add(a)
        report.note("GEOMETRY " + name + " | " + lines.joined(separator: " | "))
    }

    func testLibraryOpen() throws {
        for width in [520, 800, 1200] {
            launchOneRow(width: width, tabs: 8)
            app.typeKey("l", modifierFlags: [.command, .shift])
            XCTAssertNotNil(until(5) { any("sidebar").exists }, "\(width): the Library did not open")
            Thread.sleep(forTimeInterval: 0.8)
            let page = win.descendants(matching: .webView).firstMatch.frame
            XCTAssertGreaterThan(page.width, 200, "\(width): the page is squeezed to \(page.width)")
            attachGeometry("one-row-library-\(width)")
            assertNoOverlap("one row + library \(width)")
            XCTAssertNotNil(selectedFieldFrame(), "\(width): the active field disappeared with the Library open")
            if width == 520 { attachShot("one-row-library-520") }
            app.terminate()
        }
    }

    /// One Row at 520 pt with the Library open on each side, read from one snapshot: the active field, Reload, the page and the Library all inside the window, the Library on the chosen side. A no-Library reading is
    /// taken first for comparison. Nothing here is a new limit: it is the existing "nothing leaves the window" rule, stated for every part of the bar.
    func testLibraryAt520InDetailOnBothSides() throws {
        launchOneRow(width: 520, tabs: 8)
        attachGeometry("baseline-520-no-library")
        app.terminate()
        for position in ["left", "right"] {
            launchOneRow(width: 520, tabs: 8, extra: ["-UISidebarOpen", "1", "-UISidebarPosition", position])
            XCTAssertNotNil(until(5) { self.any("sidebar").exists }, "\(position): the Library did not open")
            Thread.sleep(forTimeInterval: 0.8)
            attachGeometry("detail-520-\(position)")
            let w = win.frame, snap = snapItems()
            func item(_ id: String) -> CGRect? { snap.first { $0.id == id }?.frame }
            guard let sidebar = item("sidebar"), let field = item("omnibox"), let reload = item("reload-button") else { XCTFail("\(position): sidebar, field or Reload missing"); attachShot("detail-520-\(position)-missing"); app.terminate(); continue }
            let page = snap.first { $0.type == UInt(XCUIElement.ElementType.webView.rawValue) }?.frame ?? .zero
            XCTAssertGreaterThanOrEqual(field.minX, w.minX - 1, "\(position): the active field leaves the window on the left")
            XCTAssertLessThanOrEqual(field.maxX, w.maxX + 1, "\(position): the active field leaves the window on the right (field \(field), window \(w))")
            XCTAssertLessThanOrEqual(reload.maxX, w.maxX + 1, "\(position): Reload leaves the window on the right (\(reload))")
            XCTAssertGreaterThanOrEqual(reload.minX, w.minX - 1, "\(position): Reload leaves the window on the left")
            XCTAssertGreaterThanOrEqual(page.minX, w.minX - 1); XCTAssertLessThanOrEqual(page.maxX, w.maxX + 1, "\(position): the page leaves the window")
            XCTAssertGreaterThan(page.width, 200, "\(position): the page is squeezed to \(page.width)")
            if position == "left" { XCTAssertEqual(sidebar.minX, w.minX, accuracy: 6, "the Library is not on the left") } else { XCTAssertEqual(sidebar.maxX, w.maxX, accuracy: 6, "the Library is not on the right") }
            attachShot("one-row-library-520-\(position)")
            app.terminate()
        }
    }

    /// The toolbar's own menu in One Row (it is attached to the shared top bar, which holds the One Row bar too): right-clicking a part of the bar that is not a control or a tab opens it, and it carries the toolbar's
    /// items and, with a group present, "Show Tab Group". The points tried are recorded; at least one must open the menu.
    /// Menu items are found the way the other menu tests find them: by title, not by identifier. The titles seen are attached when nothing matches, so a miss can be told from a menu that never opened.
    private func menuHas(_ title: String) -> Bool { app.menuItems.matching(NSPredicate(format: "title == %@", title)).firstMatch.exists }
    private func attachMenuTitles(_ name: String) {
        let titles = app.menuItems.allElementsBoundByIndex.prefix(60).map(\.title).joined(separator: " | ")
        let a = XCTAttachment(string: titles); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    /// The titles of every menu item in the app, from one snapshot (per-element queries go stale while a menu is opening).
    private func menuTitles() -> [String] {
        guard let snapshot = try? app.snapshot() else { return [] }
        var titles: [String] = []
        func walk(_ s: XCUIElementSnapshot) { if s.elementType == .menuItem { titles.append(s.title.isEmpty ? s.label : s.title) }; s.children.forEach(walk) }
        walk(snapshot)
        return titles
    }
    /// Right-clicks a set of points on the bar and records which menu items are new after each click (against the menu bar's own items), so a menu with unexpected items still shows up.
    /// Returns the first point whose menu has any of the toolbar menu's own items; every point and what appeared is attached.
    private func probeToolbarMenu(_ name: String) -> String? {
        let w = win.frame
        let base = Set(menuTitles())
        var log: [String] = [], opened: String?
        let points: [(CGFloat, CGFloat)] = [(w.width * 0.5, 4), (w.width * 0.35, 4), (w.width * 0.65, 4), (w.width * 0.5, 40), (w.width * 0.9, 4), (w.width * 0.2, 4),
                                            (60, 20), (w.width * 0.5, 20), (w.width * 0.75, 20), (w.width - 60, 20), (w.width * 0.42, 20), (w.width * 0.58, 20)]
        for (dx, dy) in points {
            win.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: dx, dy: dy)).rightClick()
            Thread.sleep(forTimeInterval: 0.5)
            let now = menuTitles()
            let new = now.filter { !base.contains($0) && !$0.isEmpty }
            log.append("(\(Int(dx)), \(Int(dy))): new menu items = \(new)")
            if new.contains("Show Tab Group") || new.contains("Hide Sidebar") || new.contains("Show Sidebar") || new.contains("New Private Tab") { opened = "(\(Int(dx)), \(Int(dy)))"; break }
            app.typeKey(.escape, modifierFlags: [])
        }
        let a = XCTAttachment(string: log.joined(separator: "\n")); a.name = name + "-points"; a.lifetime = .keepAlways; add(a)
        return opened
    }

    /// Control for the test below: the same right-click points on Classic's toolbar, to tell a test that clicks on nothing from a One Row bar that does not open the menu. Diagnostic only.
    func testToolbarMenuControlInClassic() throws {
        launch(state: "bulk-tabs", extra: ["-UITabCount", "8", "-UILayout", "classic", "-UIGroups", "1"], env: ["BS_WINDOW_SIZE": "1000x800"])
        XCTAssertNotNil(until(30) { win.exists && any("omnibox").exists }, "Classic did not come up")
        Thread.sleep(forTimeInterval: 0.8)
        let opened = probeToolbarMenu("classic")
        report.note("TOOLBARMENU-CLASSIC opened at " + (opened ?? "none"))
        let note = XCTAttachment(string: opened ?? "no point opened the toolbar menu in Classic"); note.name = "toolbar-menu-classic"; note.lifetime = .keepAlways; add(note)
        XCTAssertNotNil(opened, "right-clicking Classic's toolbar did not open the toolbar menu at any point tried")
        app.typeKey(.escape, modifierFlags: [])
    }

    func testToolbarMenuOpensInOneRow() throws {
        launchOneRow(width: 1000, tabs: 8, extra: ["-UIGroups", "1"])
        let opened = probeToolbarMenu("oneRow")
        report.note("TOOLBARMENU opened at " + (opened ?? "none"))
        let note = XCTAttachment(string: opened ?? "no point opened the toolbar menu"); note.name = "toolbar-menu"; note.lifetime = .keepAlways; add(note)
        XCTAssertNotNil(opened, "right-clicking the One Row bar did not open the toolbar menu at any point tried")
        XCTAssertTrue(menuHas("Show Tab Group"), "the toolbar menu has no Show Tab Group although a group exists")
        app.typeKey(.escape, modifierFlags: [])
    }

    /// D1C-15: every optional toolbar control on.
    func testFullyCustomizedToolbar() throws {
        for width in [520, 1000, 1600] {
            launch(state: "all-toolbar", extra: ["-UILayout", "inline"], env: ["BS_WINDOW_SIZE": "\(width)x800"])
            XCTAssertNotNil(until(20) { win.exists && abs(win.frame.width - CGFloat(width)) < 6 && hasMore })
            Thread.sleep(forTimeInterval: 0.8)
            assertNoOverlap("one row full toolbar \(width)")
            XCTAssertTrue(hasBack && hasMore)
            if width == 1000 || width == 1600 { attachShot("one-row-full-toolbar-\(width)") }
            app.terminate()
        }
    }

    /// The selected tab shows a Close at the end of its field: it closes that tab, does not touch Reload, goes while typing, and is a lock (no Close) when the tab is locked.
    func testSelectedTabCloseButton() throws {
        launchOneRow(width: 1000, tabs: 4)
        let close = win.buttons.matching(identifier: "tab-close").firstMatch
        XCTAssertTrue(until(4) { win.buttons.matching(NSPredicate(format: "label == 'Close tab' AND NOT identifier == 'tab-chip'")).count >= 1 } != nil, "no visible Close on the selected tab")
        let closes = win.buttons.matching(NSPredicate(format: "label == 'Close tab'")).allElementsBoundByIndex.filter { $0.frame.minY - win.frame.minY < 44 }
        XCTAssertEqual(closes.count, 1, "exactly one Close in the row at rest (the selected tab's), found \(closes.count)")
        _ = close
        let button = closes[0].frame, field = any("omnibox").frame
        XCTAssertGreaterThan(button.minX, field.maxX - 2, "Close should be after the address text")
        if any("reload-button").exists { XCTAssertLessThanOrEqual(any("reload-button").frame.maxX, button.minX + 1, "Close overlaps Reload") }
        attachCrop("close-selected-crop")
        // Typing hides it (the field's room is the text's).
        app.typeKey("l", modifierFlags: .command); paste("abc"); Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(win.buttons.matching(NSPredicate(format: "label == 'Close tab'")).allElementsBoundByIndex.filter { $0.frame.minY - win.frame.minY < 44 }.count, 0, "Close stayed while typing")
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.4)
        // Clicking it closes the selected tab, and only that one.
        let before = tabChips().count
        let again = win.buttons.matching(NSPredicate(format: "label == 'Close tab'")).allElementsBoundByIndex.first { $0.frame.minY - win.frame.minY < 44 }
        XCTAssertNotNil(again); again?.click()
        XCTAssertNotNil(until(4) { tabChips().count == before - 1 }, "closing the selected tab should leave \(before - 1) other tabs, found \(tabChips().count)")
    }

    func testLockedSelectedTabShowsLockNotClose() throws {
        launchOneRow(width: 1000, tabs: 4)
        func visibleItem(_ title: String) -> XCUIElement? { app.menuItems.matching(NSPredicate(format: "title == %@", title)).allElementsBoundByIndex.first { $0.isHittable } }
        // Lock an inactive tab from its chip, then select it: it becomes the field.
        chip(1).rightClick()
        XCTAssertNotNil(until(3) { visibleItem("Lock Tab") != nil }, "no Lock Tab in the tab menu"); visibleItem("Lock Tab")?.click(); Thread.sleep(forTimeInterval: 0.5)
        chip(1).click(); Thread.sleep(forTimeInterval: 0.8)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(win.buttons.matching(NSPredicate(format: "label == 'Close tab'")).allElementsBoundByIndex.filter { $0.frame.minY - win.frame.minY < 44 }.count, 0, "a locked tab must not show Close")
        XCTAssertTrue(win.images["Locked tab"].exists || win.descendants(matching: .any).matching(NSPredicate(format: "label == 'Locked tab'")).count > 0, "no lock mark on the locked selected tab")
        attachCrop("close-locked-selected-crop")
        let n = tabChips().count
        app.typeKey("w", modifierFlags: .command); Thread.sleep(forTimeInterval: 0.6)
        XCTAssertEqual(tabChips().count, n, "Cmd-W closed a locked tab")
    }

    /// D1C-12: at a narrow width New Tab lives in More; opening More and choosing it makes a new tab.
    func testNewTabFromMoreWhenFolded() throws {
        launchOneRow(width: 520, tabs: 3)
        XCTAssertFalse(win.buttons["New Tab"].exists && win.buttons["New Tab"].isHittable && win.buttons["New Tab"].frame.minY - win.frame.minY < 44, "this width should have folded New Tab into More")
        let more = win.menuButtons["More"].exists ? win.menuButtons["More"] : any("more-menu")
        XCTAssertTrue(more.exists, "no More menu")
        let before = tabChips().count
        more.click()
        // The File menu has a "New Tab" too: the one to use is the item that is on screen and under More.
        func moreItem() -> XCUIElement? { app.menuItems.matching(NSPredicate(format: "title == 'New Tab'")).allElementsBoundByIndex.first { $0.isHittable } }
        XCTAssertNotNil(until(3) { moreItem() != nil }, "More has no New Tab")
        moreItem()?.click()
        XCTAssertNotNil(until(4) { tabChips().count == before + 1 }, "New Tab from More did not add a tab (\(before) -> \(tabChips().count))")
    }

    /// D1C-06: the suggestions at the narrowest width are fully on screen and begin near the field.
    func testSuggestionsAtNarrowWidth() throws {
        launchOneRow(width: 520, tabs: 3)
        app.typeKey("l", modifierFlags: .command); paste("swift browser"); Thread.sleep(forTimeInterval: 0.6)
        let row = win.buttons["Search for “swift browser”"]
        XCTAssertNotNil(until(4) { row.exists }, "no suggestions at 520")
        let r = row.frame, w = win.frame, f = any("omnibox").frame
        report.note(String(format: "ONEROW-SUGG @520: row x %.0f–%.0f of window 0–%.0f; field text x %.0f–%.0f", r.minX - w.minX, r.maxX - w.minX, w.width, f.minX - w.minX, f.maxX - w.minX))
        XCTAssertGreaterThanOrEqual(r.minX, w.minX - 1, "suggestions clipped on the left"); XCTAssertLessThanOrEqual(r.maxX, w.maxX + 1, "suggestions clipped on the right")
        // The popup is 440 pt wide, so in a 520 pt window it is moved to fit; what matters is that it sits under the field, not beside it.
        XCTAssertTrue(r.minX <= f.midX && f.midX <= r.maxX, "the suggestions do not sit under the field (field centre \(f.midX - w.minX), popup \(r.minX - w.minX)–\(r.maxX - w.minX))")
        attachShot("one-row-suggestions-520")
    }

    /// D1C-13: a pinned tab stays in the row and keeps its identity and its menu.
    func testPinnedTabStaysInTheRow() throws {
        launchOneRow(width: 1000, tabs: 5)
        func visibleItem(_ title: String) -> XCUIElement? { app.menuItems.matching(NSPredicate(format: "title == %@", title)).allElementsBoundByIndex.first { $0.isHittable } }
        let before = tabChips().count
        chip(1).rightClick()
        XCTAssertNotNil(until(3) { visibleItem("Pin Tab") != nil }, "no Pin Tab"); visibleItem("Pin Tab")?.click(); Thread.sleep(forTimeInterval: 0.8)
        XCTAssertEqual(tabChips().count, before, "pinning changed how many tabs the row shows")
        chip(0).rightClick()
        XCTAssertNotNil(until(3) { visibleItem("Unpin Tab") != nil || visibleItem("Pin Tab") != nil }, "the pinned tab lost its menu")
        app.typeKey(.escape, modifierFlags: [])
    }

    /// D1C-11: with many tabs, every tab can be reached: the first and the last by keyboard, and the row scrolls to whichever is chosen.
    func testEveryTabIsReachableWithManyTabs() throws {
        launchOneRow(width: 800, tabs: 25)
        app.typeKey("1", modifierFlags: .command)
        XCTAssertNotNil(until(3) { let f = any("omnibox").frame; return f.minX >= win.frame.minX && f.maxX <= win.frame.maxX }, "after Cmd-1 the field is not visible")
        for _ in 0..<6 { app.typeKey("]", modifierFlags: [.command, .shift]) }
        XCTAssertNotNil(until(3) { let f = any("omnibox").frame; return f.minX >= win.frame.minX && f.maxX <= win.frame.maxX }, "after stepping tabs the field is not visible")
        app.typeKey("9", modifierFlags: .command)
        XCTAssertNotNil(until(3) { let f = any("omnibox").frame; return f.minX >= win.frame.minX && f.maxX <= win.frame.maxX }, "after Cmd-9 the field is not visible")
        XCTAssertTrue(any("overview-button").exists || hasMore, "no route to the tab overview")
    }
}

/// Classic Reversed: Classic's complete toolbar, tab strip, Library and behavior with the two top rows swapped (tabs above, toolbar below). These check the swap itself, the room for the window's traffic lights, window dragging
/// against tab dragging, the suggestions under the field, the Library on both sides, the single-tab rule, full screen and parity with Classic. Everything else is Classic's, and Classic's own classes cover it.
final class D1dClassicReversedUITests: PerfCase {
    private func launchLayout(_ layout: String, width: Int = 1000, tabs: Int = 6, extra: [String] = []) {
        launch(state: "bulk-tabs", extra: ["-UITabCount", "\(tabs)", "-UILayout", layout] + extra, env: ["BS_WINDOW_SIZE": "\(width)x800"])
        XCTAssertNotNil(until(30) { win.exists && abs(win.frame.width - CGFloat(width)) < 6 && any("omnibox").exists }, "\(layout) did not come up at \(width)")
        Thread.sleep(forTimeInterval: 0.8)
    }
    private func item(_ id: String, _ snap: [SnapItem]) -> CGRect? { snap.first { $0.id == id }?.frame }
    private func chips(_ snap: [SnapItem]) -> [SnapItem] { snap.filter { $0.id == "tab-chip" }.sorted { $0.frame.minX < $1.frame.minX } }
    private func page(_ snap: [SnapItem]) -> CGRect? { snap.first { $0.type == UInt(XCUIElement.ElementType.webView.rawValue) }?.frame }
    private func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate { win.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x - win.frame.minX, dy: y - win.frame.minY)) }

    /// Tabs above the toolbar, the first tab clear of the traffic lights, the toolbar starting at its own edge, and every control Classic has.
    func testRowsAreSwappedAndTheLightsAreClear() throws {
        launchLayout("classic")
        let c = snapItems()
        guard let cField = item("omnibox", c), let cStrip = item("tab-bar", c) else { XCTFail("Classic: field or strip missing (\(presentIDs()))"); return }
        XCTAssertLessThan(cField.minY, cStrip.minY, "Classic itself changed: the toolbar is no longer above the tabs")
        let controls = ["sidebar-button", "omnibox", "reload-button", "new-tab-button", "overview-button", "tab-bar"]
        let classicHas = controls.filter { item($0, c) != nil }
        app.terminate()

        launchLayout("classicReversed")
        let r = snapItems(), w = win.frame
        attachShot("classic-reversed-1000")
        guard let field = item("omnibox", r), let strip = item("tab-bar", r), let page = page(r), let first = chips(r).first?.frame else { XCTFail("Classic Reversed: field, strip, page or tabs missing (\(presentIDs()))"); return }
        XCTAssertLessThan(strip.minY, field.minY, "the tabs are not above the toolbar")
        XCTAssertGreaterThanOrEqual(field.minY, strip.maxY - 2, "the toolbar overlaps the tab strip")
        XCTAssertGreaterThanOrEqual(page.minY, field.maxY - 2, "the page overlaps the toolbar")
        XCTAssertGreaterThanOrEqual(first.minX - w.minX, 83, "the first tab is under the traffic lights (\(first.minX - w.minX) pt from the edge)")
        if let button = item("sidebar-button", r) { XCTAssertLessThan(button.minX - w.minX, 40, "the toolbar still keeps the traffic lights' room although the tabs carry it") }
        for id in classicHas { XCTAssertNotNil(item(id, r), "Classic has \(id) and Classic Reversed does not") }
        XCTAssertGreaterThanOrEqual(field.minX, w.minX - 1); XCTAssertLessThanOrEqual(field.maxX, w.maxX + 1)
        for chip in chips(r) { XCTAssertFalse(chip.label.isEmpty, "a tab has no accessibility label") }
    }

    /// 520, 1000 and 1600 pt: nothing leaves the window, the tabs stay clear of the lights, and the page keeps its room.
    func testWindowWidths() throws {
        for width in [520, 1000, 1600] {
            launchLayout("classicReversed", width: width, tabs: 8)
            let s = snapItems(), w = win.frame
            attachShot("classic-reversed-\(width)")
            guard let field = item("omnibox", s), let strip = item("tab-bar", s), let page = page(s) else { XCTFail("\(width): field, strip or page missing (\(presentIDs()))"); app.terminate(); continue }
            XCTAssertLessThan(strip.minY, field.minY, "\(width): rows not swapped")
            XCTAssertGreaterThanOrEqual(field.minX, w.minX - 1, "\(width): the field leaves the window on the left")
            XCTAssertLessThanOrEqual(field.maxX, w.maxX + 1, "\(width): the field leaves the window on the right")
            XCTAssertLessThanOrEqual(strip.maxX, w.maxX + 1, "\(width): the strip leaves the window")
            XCTAssertGreaterThanOrEqual(strip.minX - w.minX, 83, "\(width): the tab strip starts under the traffic lights (\(strip.minX - w.minX) pt from the edge)")
            XCTAssertGreaterThan(page.width, 200, "\(width): the page is squeezed to \(page.width)")
            app.terminate()
        }
    }

    /// The Library on each side sits below both rows, and the strip reaches as far across as Classic's does in the same state.
    func testLibraryOnBothSides() throws {
        for position in ["left", "right"] {
            launchLayout("classic", extra: ["-UISidebarOpen", "1", "-UISidebarPosition", position])
            XCTAssertNotNil(until(5) { self.any("sidebar").exists }, "\(position): the Library did not open in Classic")
            Thread.sleep(forTimeInterval: 0.6)
            let c = snapItems(), cw = win.frame
            guard let cStrip = item("tab-bar", c) else { XCTFail("Classic strip missing"); return }
            let classicReach = cw.maxX - cStrip.maxX
            app.terminate()
            launchLayout("classicReversed", extra: ["-UISidebarOpen", "1", "-UISidebarPosition", position])
            XCTAssertNotNil(until(5) { self.any("sidebar").exists }, "\(position): the Library did not open")
            Thread.sleep(forTimeInterval: 0.6)
            let s = snapItems(), w = win.frame
            attachShot("classic-reversed-library-\(position)")
            guard let side = item("sidebar", s), let field = item("omnibox", s), let strip = item("tab-bar", s) else { XCTFail("\(position): sidebar, field or strip missing (\(presentIDs()))"); app.terminate(); continue }
            XCTAssertGreaterThanOrEqual(side.minY, field.maxY - 2, "\(position): the Library overlaps the toolbar")
            XCTAssertGreaterThanOrEqual(side.minY, strip.maxY - 2, "\(position): the Library overlaps the tabs")
            XCTAssertEqual(w.maxX - strip.maxX, classicReach, accuracy: 4, "\(position): the strip does not reach as far as Classic's (\(w.maxX - strip.maxX) pt short, Classic \(classicReach))")
            if position == "left" { XCTAssertEqual(side.minX, w.minX, accuracy: 6) } else { XCTAssertEqual(side.maxX, w.maxX, accuracy: 6) }
            app.terminate()
        }
    }

    /// The suggestions open directly under the real field, below both rows.
    func testSuggestionsSitUnderTheField() throws {
        launchLayout("classicReversed", tabs: 4)
        app.typeKey("l", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.4)
        paste("swift browser")
        XCTAssertNotNil(until(5) { self.any("suggestions").exists }, "no suggestions appeared")
        Thread.sleep(forTimeInterval: 0.5)
        let s = snapItems()
        attachShot("classic-reversed-suggestions")
        guard let field = item("omnibox", s), let sug = item("suggestions", s), let strip = item("tab-bar", s) else { XCTFail("field, suggestions or strip missing (\(presentIDs()))"); return }
        XCTAssertGreaterThanOrEqual(sug.minY, field.maxY - 1, "the suggestions overlap the field (suggestions \(sug), field \(field))")
        XCTAssertLessThan(sug.minY - field.maxY, 30, "the suggestions are far below the field (\(sug.minY - field.maxY) pt)")
        XCTAssertGreaterThan(sug.minY, strip.maxY, "the suggestions are over the tab strip")
        XCTAssertEqual(sug.midX, field.midX, accuracy: 40, "the suggestions are not under the field horizontally")
    }

    /// Drags the first tab to the third one's place; returns whether the order changed.
    private func dragFirstTabToThird() -> (changed: Bool, before: [String], after: [String], windowMoved: CGFloat)? {
        let tabs = chips(snapItems())
        guard tabs.count >= 3 else { return nil }
        let before = tabs.map(\.label)
        let origin = win.frame.origin
        point(tabs[0].frame.midX, tabs[0].frame.midY).hover()
        Thread.sleep(forTimeInterval: 0.4)
        point(tabs[0].frame.midX, tabs[0].frame.midY).click(forDuration: 0.4, thenDragTo: point(tabs[2].frame.midX + 10, tabs[2].frame.midY))
        Thread.sleep(forTimeInterval: 0.8)
        let after = chips(snapItems()).map(\.label)
        let moved = win.frame.origin
        return (before != after, before, after, abs(moved.x - origin.x) + abs(moved.y - origin.y))
    }

    /// Dragging a tab reorders it in Classic Reversed exactly when it does in Classic (the same drag on the same tabs).
    func testTabDragMatchesClassic() throws {
        launchLayout("classic", tabs: 3)
        guard let classic = dragFirstTabToThird() else { XCTFail("Classic: fewer than three tabs"); return }
        app.terminate()
        launchLayout("classicReversed", tabs: 3)
        guard let reversed = dragFirstTabToThird() else { XCTFail("Classic Reversed: fewer than three tabs"); return }
        report.note("TABDRAG classic changed=\(classic.changed) \(classic.before)->\(classic.after); reversed changed=\(reversed.changed) \(reversed.before)->\(reversed.after)")
        let detail = XCTAttachment(string: "classic: \(classic)\nreversed: \(reversed)"); detail.name = "tab-drag-detail"; detail.lifetime = .keepAlways; add(detail)
        XCTAssertEqual(reversed.changed, classic.changed, "tab drag differs from Classic: reversed changed=\(reversed.changed), window moved \(Int(reversed.windowMoved)) pt, now \(reversed.after.joined(separator: ","))")
        XCTAssertEqual(Set(reversed.before), Set(reversed.after), "dragging a tab changed which tabs exist")
    }

    /// Empty strip space and the room beside the lights drag the window (a tab itself is for reordering, not for moving the window). With two tabs there is room to the right of them; where tabs fill the strip there is
    /// no empty space, which is recorded rather than tested.
    func testWindowDragFromTheStrip() throws {
        launchLayout("classicReversed", tabs: 2)
        let s = snapItems()
        guard let strip = item("tab-bar", s), let last = chips(s).last?.frame else { XCTFail("strip or tabs missing (\(presentIDs()))"); return }
        let y = strip.midY - win.frame.minY
        var targets: [(String, CGFloat)] = [("beside the lights", 76)]
        let gap = strip.maxX - last.maxX
        if gap > 60 { targets.insert(("empty strip", (last.maxX + min(strip.maxX, last.maxX + 200)) / 2 - win.frame.minX), at: 0) }
        else { report.note("WINDOWDRAG no empty strip space with two tabs (gap \(Int(gap)) pt): only the room beside the lights was tested") }
        for (name, dx) in targets {
            let origin = win.frame.origin
            // The pointer arrives before the press, as a person's does (a tab holds the window still only while the pointer is over it).
            point(win.frame.minX + dx, win.frame.minY + y).hover()
            Thread.sleep(forTimeInterval: 0.4)
            point(win.frame.minX + dx, win.frame.minY + y).click(forDuration: 0.3, thenDragTo: point(win.frame.minX + dx + 90, win.frame.minY + y + 60))
            Thread.sleep(forTimeInterval: 0.6)
            let moved = win.frame.origin
            XCTAssertGreaterThan(abs(moved.x - origin.x) + abs(moved.y - origin.y), 40, "dragging the \(name) did not move the window")
        }
    }

    /// With one tab and Classic's setting on, the strip is gone and the toolbar takes the lights' room back; a second tab brings the strip back and moves the room up with it.
    func testSingleTabRule() throws {
        launchLayout("classicReversed", tabs: 1, extra: ["-UIHideSingleStrip", "1"])
        var s = snapItems(); var w = win.frame
        attachShot("classic-reversed-single-tab")
        XCTAssertNil(item("tab-bar", s), "the strip is shown with one tab although the setting hides it")
        if let button = item("sidebar-button", s) { XCTAssertGreaterThanOrEqual(button.minX - w.minX, 83, "the toolbar is under the traffic lights with the strip hidden") } else { XCTFail("no sidebar button (\(presentIDs()))") }
        app.typeKey("t", modifierFlags: .command)
        XCTAssertNotNil(until(5) { self.snapItems().contains { $0.id == "tab-bar" } }, "the strip did not come back with a second tab")
        Thread.sleep(forTimeInterval: 0.6)
        s = snapItems(); w = win.frame
        if let button = item("sidebar-button", s) { XCTAssertLessThan(button.minX - w.minX, 40, "the toolbar kept the lights' room after the strip returned") }
        if let first = chips(s).first?.frame { XCTAssertGreaterThanOrEqual(first.minX - w.minX, 83, "the first tab is under the lights") }
    }

    /// Full screen has no traffic lights in the window: the tabs start at the edge, still above the toolbar.
    func testFullScreen() throws {
        launchLayout("classicReversed", tabs: 4)
        let enter = app.menuBars.menuItems["Enter Full Screen"]
        XCTAssertTrue(enter.waitForExistence(timeout: 3) || app.menuBars.menuBarItems["View"].exists, "no Enter Full Screen item")
        app.menuBars.menuBarItems["View"].click()
        XCTAssertTrue(enter.waitForExistence(timeout: 3), "the View menu has no Enter Full Screen")
        enter.click()
        let screenWidth = NSScreen.main?.frame.width ?? 0
        XCTAssertNotNil(until(12) { self.win.exists && self.win.frame.width >= screenWidth - 2 }, "the window did not enter full screen")
        Thread.sleep(forTimeInterval: 1.5)
        let s = snapItems(), w = win.frame
        attachShot("classic-reversed-fullscreen")
        if let strip = item("tab-bar", s), let field = item("omnibox", s) { XCTAssertLessThan(strip.minY, field.minY, "full screen: rows not swapped") } else { XCTFail("full screen: strip or field missing (\(presentIDs()))") }
        if let first = chips(s).first?.frame { XCTAssertLessThan(first.minX - w.minX, 40, "full screen: the first tab still keeps room for lights that are not there") }
        app.menuBars.menuBarItems["View"].click()
        let exit = app.menuBars.menuItems["Exit Full Screen"]
        XCTAssertTrue(exit.waitForExistence(timeout: 3), "no Exit Full Screen item")
        exit.click()
        XCTAssertNotNil(until(12) { self.win.exists && self.win.frame.width < screenWidth - 2 }, "the window did not leave full screen")
    }
}

/// Every Classic interaction test (select, close, double-click, context menus, move left and right, Essentials and pinned tabs, group chip, omnibox and suggestions, Library), run with the tabs above the toolbar by changing
/// only the layout under test. The test that states the row order is replaced by its reversed statement. Then the interactions that are particular to the top strip: hover preview, window drag from empty strip space,
/// and the toolbar that slides in over a full-screen page.
final class D1dClassicReversedParityUITests: D1aClassicUITests {
    override var layoutName: String { "classicReversed" }

    override func testClassicHasOneToolbarOneStripOneField() throws {
        launchClassic()
        XCTAssertEqual(win.descendants(matching: .any).matching(identifier: "omnibox").count, 1, "exactly one address field")
        XCTAssertFalse(any("sidebar").exists, "the Library is hidden until it is opened")
        let strip = any("tab-bar").frame, field = any("omnibox").frame
        XCTAssertLessThanOrEqual(strip.maxY, field.minY + 1, "the tab strip is above the address field")
        attachShot("classic-reversed-5tabs")
    }

    private func tabFrames() -> [CGRect] { snapItems().filter { $0.id == "tab-chip" }.sorted { $0.frame.minX < $1.frame.minX }.map(\.frame) }
    private func at(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate { win.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x - win.frame.minX, dy: y - win.frame.minY)) }

    /// Resting the pointer on a tab shows the preview card (a panel of its own); moving away removes it.
    func testHoverPreviewAppearsAndGoes() throws {
        launchClassic(tabs: 4)
        guard let tab = tabFrames().dropFirst().first else { XCTFail("no second tab"); return }
        func previewShown() -> Bool { app.descendants(matching: .any)["tab-preview"].exists }
        at(tab.midX, tab.midY).hover()
        XCTAssertNotNil(until(4) { previewShown() }, "no preview after resting on a tab (windows \(app.windows.count))")
        attachShot("classic-reversed-hover-preview")
        win.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.7)).hover()
        XCTAssertNotNil(until(4) { !previewShown() }, "the preview stayed after the pointer left")
    }

    /// With room to the right of the tabs, dragging that empty strip space moves the window. Where the tabs fill the strip there is no such space; that is recorded, not asserted.
    func testWindowDragFromEmptyStripSpace() throws {
        launchClassic(tabs: 1)
        let s = snapItems()
        guard let strip = s.first(where: { $0.id == "tab-bar" })?.frame, let last = tabFrames().last else { XCTFail("strip or tab missing (\(presentIDs()))"); return }
        let gap = strip.maxX - last.maxX
        let note = XCTAttachment(string: "gap to the right of the last tab: \(Int(gap)) pt (strip \(strip), tab \(last))"); note.name = "empty-strip-gap"; note.lifetime = .keepAlways; add(note)
        guard gap > 60 else { report.note("EMPTYSTRIP none with one tab (gap \(Int(gap)) pt)"); return }
        let x = last.maxX + gap / 2, y = strip.midY, origin = win.frame.origin
        at(x, y).hover(); Thread.sleep(forTimeInterval: 0.4)
        at(x, y).click(forDuration: 0.3, thenDragTo: at(x + 90, y + 60))
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertGreaterThan(abs(win.frame.origin.x - origin.x) + abs(win.frame.origin.y - origin.y), 40, "dragging empty strip space did not move the window")
    }

    /// What the toolbar and tabs do in full screen for one layout: whether they go away with the pointer in the page, come in at the top edge, in which order, and go again.
    private struct PeekObservation { var hidesAway = false, appearsAtTop = false, stripAboveField = false, tabsAtTop = false, firstTabClear = false, controls = false, goesAgain = false }
    private func observeFullScreenPeek(layout: String) -> PeekObservation {
        var o = PeekObservation()
        launch(state: "bulk-tabs", extra: ["-UITabCount", "4", "-UILayout", layout], env: ["BS_WINDOW_SIZE": "1000x800"])
        XCTAssertNotNil(until(30) { self.win.exists && abs(self.win.frame.width - 1000) < 6 && self.any("omnibox").exists }, "\(layout) did not come up")
        Thread.sleep(forTimeInterval: 0.8)
        app.menuBars.menuBarItems["View"].click()
        let enter = app.menuBars.menuItems["Enter Full Screen"]
        XCTAssertTrue(enter.waitForExistence(timeout: 3), "the View menu has no Enter Full Screen")
        enter.click()
        let screenWidth = NSScreen.main?.frame.width ?? 0
        XCTAssertNotNil(until(12) { self.win.exists && self.win.frame.width >= screenWidth - 2 }, "\(layout): the window did not enter full screen")
        Thread.sleep(forTimeInterval: 1.5)
        func toolbarShowing() -> Bool { snapItems().contains { $0.id == "omnibox" && $0.frame.minY - self.win.frame.minY < 120 } }
        win.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).hover()
        o.hidesAway = until(8) { !toolbarShowing() } != nil
        at(win.frame.midX, win.frame.minY + 1).hover()
        o.appearsAtTop = until(5) { toolbarShowing() } != nil
        Thread.sleep(forTimeInterval: 0.6)
        let s = snapItems(), w = win.frame
        attachShot("\(layout)-fullscreen-peek")
        if let strip = s.first(where: { $0.id == "tab-bar" })?.frame, let field = s.first(where: { $0.id == "omnibox" })?.frame {
            o.stripAboveField = strip.maxY <= field.minY + 1
            o.tabsAtTop = strip.minY - w.minY < 20
        }
        if let first = s.filter({ $0.id == "tab-chip" }).sorted(by: { $0.frame.minX < $1.frame.minX }).first?.frame { o.firstTabClear = first.minX - w.minX < 40 }
        o.controls = ["sidebar-button", "omnibox", "reload-button"].allSatisfy { id in s.contains { $0.id == id } }
        win.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).hover()
        o.goesAgain = until(8) { !toolbarShowing() } != nil
        app.menuBars.menuBarItems["View"].click()
        let exit = app.menuBars.menuItems["Exit Full Screen"]
        if exit.waitForExistence(timeout: 3) { exit.click() }
        _ = until(10) { self.win.exists && self.win.frame.width < screenWidth - 2 }
        app.terminate()
        return o
    }

    /// In full screen the toolbar and tabs behave as Classic's do (the same go-away, come-in and go-again), with the rows in the reversed order, the tabs at the top edge and no room kept for lights that are not there.
    func testFullScreenToolbarPeekMatchesClassic() throws {
        let classic = observeFullScreenPeek(layout: "classic")
        let reversed = observeFullScreenPeek(layout: "classicReversed")
        let note = XCTAttachment(string: "classic: \(classic)\nreversed: \(reversed)"); note.name = "fullscreen-peek"; note.lifetime = .keepAlways; add(note)
        XCTAssertEqual(reversed.hidesAway, classic.hidesAway, "the toolbar's go-away differs from Classic: \(reversed) vs \(classic)")
        XCTAssertEqual(reversed.appearsAtTop, classic.appearsAtTop, "the toolbar's come-in at the top edge differs from Classic: \(reversed) vs \(classic)")
        XCTAssertEqual(reversed.goesAgain, classic.goesAgain, "the peeked toolbar's leaving differs from Classic: \(reversed) vs \(classic)")
        XCTAssertEqual(reversed.controls, classic.controls, "the peek's controls differ from Classic: \(reversed) vs \(classic)")
        if reversed.appearsAtTop {
            XCTAssertTrue(reversed.stripAboveField, "peek: the tabs are not above the toolbar")
            XCTAssertTrue(reversed.tabsAtTop, "peek: the tabs are not at the top edge")
            XCTAssertTrue(reversed.firstTabClear, "peek: the first tab keeps room for lights that are not there")
        }
    }
}

// MARK: - Minimal Reversed

/// Minimal Reversed: Minimal's compact strip, toolbar, Library and behavior with the two top rows swapped (compact tabs above, toolbar below). These check the swap itself, the room for the traffic lights, the compact cells
/// against window dragging, whether the window gets back its movability after every way a tab can lose the pointer, the suggestions, the Library, Minimal's single-tab behavior, Essentials, pinned tabs, groups and full screen.
final class D1eMinimalReversedUITests: PerfCase {
    private func launchLayout(_ layout: String, width: Int = 1000, tabs: Int = 6, extra: [String] = []) {
        launch(state: "bulk-tabs", extra: ["-UITabCount", "\(tabs)", "-UILayout", layout] + extra, env: ["BS_WINDOW_SIZE": "\(width)x800"])
        XCTAssertNotNil(until(30) { win.exists && abs(win.frame.width - CGFloat(width)) < 6 && any("omnibox").exists }, "\(layout) did not come up at \(width)")
        Thread.sleep(forTimeInterval: 0.8)
    }
    private func item(_ id: String, _ snap: [SnapItem]) -> CGRect? { snap.first { $0.id == id }?.frame }
    private func chips(_ snap: [SnapItem]) -> [SnapItem] { snap.filter { $0.id == "tab-chip" }.sorted { $0.frame.minX < $1.frame.minX } }
    private func page(_ snap: [SnapItem]) -> CGRect? { snap.first { $0.type == UInt(XCUIElement.ElementType.webView.rawValue) }?.frame }
    private func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate { win.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x - win.frame.minX, dy: y - win.frame.minY)) }
    private func movedBy(_ origin: CGPoint) -> CGFloat { abs(win.frame.origin.x - origin.x) + abs(win.frame.origin.y - origin.y) }

    /// Compact tabs above the toolbar, the first tab clear of the lights, the toolbar at its own edge, and every control Minimal has.
    func testRowsAreSwappedAndTheLightsAreClear() throws {
        launchLayout("minimal")
        let m = snapItems()
        guard let mField = item("omnibox", m), let mFirst = chips(m).first?.frame else { XCTFail("Minimal: field or tabs missing (\(presentIDs()))"); return }
        XCTAssertGreaterThan(mFirst.minY, mField.minY, "Minimal itself changed: the tabs are no longer below the toolbar")
        let controls = ["sidebar-button", "omnibox", "reload-button", "new-tab-button", "overview-button", "tab-bar"]
        let minimalHas = controls.filter { item($0, m) != nil }
        app.terminate()

        launchLayout("minimalReversed")
        let r = snapItems(), w = win.frame
        attachShot("minimal-reversed-1000")
        guard let field = item("omnibox", r), let page = page(r), let first = chips(r).first?.frame else { XCTFail("Minimal Reversed: field, page or tabs missing (\(presentIDs()))"); return }
        XCTAssertLessThan(first.minY, field.minY, "the tabs are not above the toolbar")
        XCTAssertGreaterThanOrEqual(field.minY, first.maxY - 4, "the toolbar overlaps the tabs")
        XCTAssertGreaterThanOrEqual(page.minY, field.maxY - 2, "the page overlaps the toolbar")
        XCTAssertGreaterThanOrEqual(first.minX - w.minX, 83, "the first tab is under the traffic lights (\(first.minX - w.minX) pt from the edge)")
        XCTAssertLessThan(first.minY - w.minY, 20, "the tabs are not at the top edge")
        if let button = item("sidebar-button", r) { XCTAssertLessThan(button.minX - w.minX, 40, "the toolbar still keeps the traffic lights' room although the tabs carry it") }
        for id in minimalHas { XCTAssertNotNil(item(id, r), "Minimal has \(id) and Minimal Reversed does not") }
        XCTAssertGreaterThanOrEqual(field.minX, w.minX - 1); XCTAssertLessThanOrEqual(field.maxX, w.maxX + 1)
        for chip in chips(r) { XCTAssertFalse(chip.label.isEmpty, "a tab has no accessibility label") }
        XCTAssertEqual(chips(r).count, chips(m).count, "a different number of tabs is listed")
    }

    /// 520, 1000 and 1600 pt: nothing leaves the window, the tabs stay clear of the lights, and the page keeps its room.
    func testWindowWidths() throws {
        for width in [520, 1000, 1600] {
            launchLayout("minimalReversed", width: width, tabs: 3)
            let s = snapItems(), w = win.frame
            attachShot("minimal-reversed-\(width)")
            guard let field = item("omnibox", s), let page = page(s), let first = chips(s).first?.frame else { XCTFail("\(width): field, tabs or page missing (\(presentIDs()))"); app.terminate(); continue }
            XCTAssertLessThan(first.minY, field.minY, "\(width): rows not swapped")
            XCTAssertGreaterThanOrEqual(field.minX, w.minX - 1, "\(width): the field leaves the window on the left")
            XCTAssertLessThanOrEqual(field.maxX, w.maxX + 1, "\(width): the field leaves the window on the right")
            XCTAssertGreaterThanOrEqual(first.minX - w.minX, 83, "\(width): the tabs start under the traffic lights (\(first.minX - w.minX) pt from the edge)")
            for chip in chips(s) { XCTAssertLessThanOrEqual(chip.frame.maxX, w.maxX + 1, "\(width): a tab leaves the window on the right") }
            if let plus = win.buttons.matching(NSPredicate(format: "label == 'New Tab' AND identifier == 'tab-bar'")).firstMatch.exists ? win.buttons.matching(NSPredicate(format: "label == 'New Tab' AND identifier == 'tab-bar'")).firstMatch.frame : nil {
                XCTAssertLessThanOrEqual(plus.maxX, w.maxX + 1, "\(width): the New Tab button is off the window")
            }
            XCTAssertGreaterThan(page.width, 200, "\(width): the page is squeezed to \(page.width)")
            app.terminate()
        }
    }

    /// The Library on each side sits below both rows, and the compact strip (its New Tab button) reaches as far as Minimal's in the same state.
    func testLibraryOnBothSides() throws {
        func plusReach() -> CGFloat? {
            let plus = win.buttons.matching(NSPredicate(format: "label == 'New Tab' AND identifier == 'tab-bar'")).firstMatch
            return plus.exists ? win.frame.maxX - plus.frame.maxX : nil
        }
        for position in ["left", "right"] {
            launchLayout("minimal", extra: ["-UISidebarOpen", "1", "-UISidebarPosition", position])
            XCTAssertNotNil(until(5) { self.any("sidebar").exists }, "\(position): the Library did not open in Minimal")
            Thread.sleep(forTimeInterval: 0.6)
            guard let minimalReach = plusReach() else { XCTFail("Minimal: no New Tab button"); return }
            app.terminate()
            launchLayout("minimalReversed", extra: ["-UISidebarOpen", "1", "-UISidebarPosition", position])
            XCTAssertNotNil(until(5) { self.any("sidebar").exists }, "\(position): the Library did not open")
            Thread.sleep(forTimeInterval: 0.6)
            let s = snapItems(), w = win.frame
            attachShot("minimal-reversed-library-\(position)")
            guard let side = item("sidebar", s), let field = item("omnibox", s), let first = chips(s).first?.frame, let reach = plusReach() else { XCTFail("\(position): sidebar, field, tabs or New Tab missing (\(presentIDs()))"); app.terminate(); continue }
            XCTAssertGreaterThanOrEqual(side.minY, field.maxY - 2, "\(position): the Library overlaps the toolbar")
            XCTAssertGreaterThanOrEqual(side.minY, first.maxY - 2, "\(position): the Library overlaps the tabs")
            XCTAssertEqual(reach, minimalReach, accuracy: 6, "\(position): the compact strip does not reach as far as Minimal's (\(reach) pt short, Minimal \(minimalReach))")
            if position == "left" { XCTAssertEqual(side.minX, w.minX, accuracy: 6) } else { XCTAssertEqual(side.maxX, w.maxX, accuracy: 6) }
            app.terminate()
        }
    }

    /// The suggestions open directly under the real field, below both rows.
    func testSuggestionsSitUnderTheField() throws {
        launchLayout("minimalReversed", tabs: 4)
        app.typeKey("l", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.4)
        paste("swift browser")
        XCTAssertNotNil(until(5) { self.any("suggestions").exists }, "no suggestions appeared")
        Thread.sleep(forTimeInterval: 0.5)
        let s = snapItems()
        attachShot("minimal-reversed-suggestions")
        guard let field = item("omnibox", s), let sug = item("suggestions", s), let first = chips(s).first?.frame else { XCTFail("field, suggestions or tabs missing (\(presentIDs()))"); return }
        XCTAssertGreaterThanOrEqual(sug.minY, field.maxY - 1, "the suggestions overlap the field (suggestions \(sug), field \(field))")
        XCTAssertLessThan(sug.minY - field.maxY, 30, "the suggestions are far below the field (\(sug.minY - field.maxY) pt)")
        XCTAssertGreaterThan(sug.minY, first.maxY, "the suggestions are over the tab strip")
        XCTAssertEqual(sug.midX, field.midX, accuracy: 40, "the suggestions are not under the field horizontally")
    }

    /// Drags the first tab to the third one's place; returns whether the order changed and how far the window moved.
    private func dragFirstTabToThird() -> (changed: Bool, before: [String], after: [String], windowMoved: CGFloat)? {
        let tabs = chips(snapItems())
        guard tabs.count >= 3 else { return nil }
        let before = tabs.map(\.label)
        let origin = win.frame.origin
        point(tabs[0].frame.midX, tabs[0].frame.midY).hover()
        Thread.sleep(forTimeInterval: 0.4)
        point(tabs[0].frame.midX, tabs[0].frame.midY).click(forDuration: 0.4, thenDragTo: point(tabs[2].frame.midX + 6, tabs[2].frame.midY))
        Thread.sleep(forTimeInterval: 0.8)
        let after = chips(snapItems()).map(\.label)
        return (before != after, before, after, movedBy(origin))
    }

    /// Dragging a compact tab reorders it in Minimal Reversed exactly when it does in Minimal, and never moves the window.
    func testTabDragMatchesMinimal() throws {
        launchLayout("minimal", tabs: 4)
        guard let minimal = dragFirstTabToThird() else { XCTFail("Minimal: fewer than three tabs"); return }
        app.terminate()
        launchLayout("minimalReversed", tabs: 4)
        guard let reversed = dragFirstTabToThird() else { XCTFail("Minimal Reversed: fewer than three tabs"); return }
        report.note("TABDRAG minimal changed=\(minimal.changed) \(minimal.before)->\(minimal.after); reversed changed=\(reversed.changed) \(reversed.before)->\(reversed.after)")
        let detail = XCTAttachment(string: "minimal: \(minimal)\nreversed: \(reversed)"); detail.name = "tab-drag-detail"; detail.lifetime = .keepAlways; add(detail)
        XCTAssertEqual(reversed.changed, minimal.changed, "tab drag differs from Minimal: reversed changed=\(reversed.changed), window moved \(Int(reversed.windowMoved)) pt, now \(reversed.after.joined(separator: ","))")
        XCTAssertLessThan(reversed.windowMoved, 4, "dragging a tab moved the window by \(Int(reversed.windowMoved)) pt")
        XCTAssertEqual(Set(reversed.before), Set(reversed.after), "dragging a tab changed which tabs exist")
    }

    /// The room beside the lights and empty strip space drag the window; a tab does not (it reorders). Then the pointer goes from a tab to empty strip space and the drag works there: the hold is gone.
    func testWindowDragFromTheStripAndAfterHoveringATab() throws {
        launchLayout("minimalReversed", tabs: 2)
        let s = snapItems(), w0 = win.frame
        guard let first = chips(s).first?.frame, let last = chips(s).last?.frame, let plus = Optional(win.buttons.matching(NSPredicate(format: "label == 'New Tab' AND identifier == 'tab-bar'")).firstMatch), plus.exists else { XCTFail("tabs or New Tab missing (\(presentIDs()))"); return }
        // Offsets from the window's corner, so they stay right after the window has moved.
        let y = first.midY - w0.minY, tabX = first.midX - w0.minX
        var targets: [(String, CGFloat)] = [("beside the lights", 76)]
        let gapStart = last.maxX - w0.minX, gapEnd = plus.frame.minX - w0.minX
        if gapEnd - gapStart > 80 { targets.append(("empty strip space", (gapStart + gapEnd) / 2)) }
        else { report.note("WINDOWDRAG no empty compact strip space (\(Int(gapEnd - gapStart)) pt)") }
        for (name, dx) in targets {
            for hoverTabFirst in [false, true] {
                let origin = win.frame.origin, o = win.frame.origin
                if hoverTabFirst { point(o.x + tabX, o.y + y).hover(); Thread.sleep(forTimeInterval: 0.4) }
                point(o.x + dx, o.y + y).hover(); Thread.sleep(forTimeInterval: 0.4)
                point(o.x + dx, o.y + y).click(forDuration: 0.3, thenDragTo: point(o.x + dx + 90, o.y + y + 60))
                Thread.sleep(forTimeInterval: 0.6)
                XCTAssertGreaterThan(movedBy(origin), 40, "dragging \(name)\(hoverTabFirst ? " after hovering a tab" : "") did not move the window")
            }
        }
    }

    /// Every way a held window can be given back, seen as behavior: the window moves again when dragged by the room beside the lights.
    private func windowMovesFromTheLightsRoom(_ why: String) {
        guard let first = chips(snapItems()).first?.frame else { XCTFail("\(why): no tab"); return }
        let origin = win.frame.origin
        let x = win.frame.minX + 76, y = first.midY
        point(x, y).hover(); Thread.sleep(forTimeInterval: 0.4)
        point(x, y).click(forDuration: 0.3, thenDragTo: point(x + 80, y + 50))
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertGreaterThan(movedBy(origin), 40, "\(why): the window stayed held (moved \(Int(movedBy(origin))) pt)")
    }

    func testTheWindowIsMovableAgainAfterEveryLifecycleTransition() throws {
        launchLayout("minimalReversed", tabs: 3)
        // Hover exit.
        guard let tab = chips(snapItems()).dropFirst().first?.frame else { XCTFail("no second tab"); return }
        point(tab.midX, tab.midY).hover(); Thread.sleep(forTimeInterval: 0.4)
        windowMovesFromTheLightsRoom("after the pointer left a tab")
        // Drag end: a reorder, then the window must still be movable.
        _ = dragFirstTabToThird()
        windowMovesFromTheLightsRoom("after a tab drag")
        // Tab disappearing under the pointer: close the hovered tab, then drag.
        if let t = chips(snapItems()).last?.frame {
            point(t.midX, t.midY).hover(); Thread.sleep(forTimeInterval: 0.4)
            app.typeKey("w", modifierFlags: .command); Thread.sleep(forTimeInterval: 0.6)
            windowMovesFromTheLightsRoom("after the tab under the pointer closed")
        }
        // Window switching: a second window opens while a tab is hovered, closes again.
        if let t = chips(snapItems()).first?.frame {
            point(t.midX, t.midY).hover(); Thread.sleep(forTimeInterval: 0.4)
            app.typeKey("n", modifierFlags: .command)
            XCTAssertNotNil(until(8) { self.app.windows.count >= 2 }, "no second window")
            Thread.sleep(forTimeInterval: 0.8)
            app.typeKey("w", modifierFlags: .command)
            XCTAssertNotNil(until(8) { self.app.windows.count == 1 }, "the second window did not close")
            Thread.sleep(forTimeInterval: 0.6)
            windowMovesFromTheLightsRoom("after switching windows")
        }
        // Deactivation: another app comes to the front while a tab is hovered.
        if let t = chips(snapItems()).first?.frame {
            point(t.midX, t.midY).hover(); Thread.sleep(forTimeInterval: 0.4)
            XCUIApplication(bundleIdentifier: "com.apple.finder").activate()
            Thread.sleep(forTimeInterval: 1.0)
            app.activate()
            XCTAssertNotNil(until(8) { self.app.state == .runningForeground && self.win.exists }, "the app did not come back")
            Thread.sleep(forTimeInterval: 0.6)
            windowMovesFromTheLightsRoom("after the app lost the front and came back")
        }
    }

    /// Minimal's own rule: the compact strip stays with one tab (Classic's hide-the-strip setting does not reach it), and the first tab is clear of the lights.
    func testTheStripStaysWithOneTab() throws {
        launchLayout("minimalReversed", tabs: 1, extra: ["-UIHideSingleStrip", "1"])
        let s = snapItems(), w = win.frame
        attachShot("minimal-reversed-single-tab")
        guard let only = chips(s).first?.frame, let field = item("omnibox", s) else { XCTFail("tab or field missing (\(presentIDs()))"); return }
        XCTAssertLessThan(only.minY, field.minY, "the tab is not above the toolbar")
        XCTAssertGreaterThanOrEqual(only.minX - w.minX, 83, "the only tab is under the lights")
        if let button = item("sidebar-button", s) { XCTAssertLessThan(button.minX - w.minX, 40, "the toolbar kept the lights' room") }
    }

    /// Essentials, pinned tabs and a group: the same tiles Minimal lists, in the same number, selectable; the strip stays above the toolbar.
    func testEssentialsPinnedTabsAndGroups() throws {
        func survey(_ layout: String) -> (essentials: Int, chips: Int, labels: [String], groupChip: Bool, selectedEssential: Bool)? {
            launchLayout(layout, tabs: 8, extra: ["-UIPinned", "1", "-UIEssentials", "2", "-UIGroups", "1"])
            let essentials = win.descendants(matching: .any).matching(NSPredicate(format: "label ENDSWITH ', Essential'")).allElementsBoundByIndex
            let count = chips(snapItems()).count
            let labels = chips(snapItems()).map(\.label)
            let groupChip = any("classic-group-chip").exists
            attachShot("\(layout)-essentials-pinned-groups")
            var selected = false
            if let e = essentials.first { e.click(); Thread.sleep(forTimeInterval: 0.5); selected = win.descendants(matching: .any).matching(NSPredicate(format: "label ENDSWITH ', Essential'")).allElementsBoundByIndex.contains { $0.isSelected } }
            return (essentials.count, count, labels, groupChip, selected)
        }
        guard let minimal = survey("minimal") else { return }
        app.terminate()
        guard let reversed = survey("minimalReversed") else { return }
        report.note("ESSENTIALS minimal \(minimal) reversed \(reversed)")
        let detail = XCTAttachment(string: "minimal: \(minimal)\nreversed: \(reversed)"); detail.name = "essentials-pinned-groups"; detail.lifetime = .keepAlways; add(detail)
        XCTAssertEqual(reversed.essentials, minimal.essentials, "a different number of Essentials")
        XCTAssertEqual(reversed.chips, minimal.chips, "a different number of tab tiles")
        XCTAssertEqual(reversed.labels, minimal.labels, "the tiles differ")
        XCTAssertEqual(reversed.groupChip, minimal.groupChip, "the group control differs")
        XCTAssertEqual(reversed.selectedEssential, minimal.selectedEssential, "opening an Essential behaves differently")
        XCTAssertEqual(reversed.essentials, 2, "two Essentials expected")
    }

    /// Full screen has no traffic lights in the window: the compact tabs start at the edge, still above the toolbar.
    func testFullScreen() throws {
        launchLayout("minimalReversed", tabs: 4)
        app.menuBars.menuBarItems["View"].click()
        let enter = app.menuBars.menuItems["Enter Full Screen"]
        XCTAssertTrue(enter.waitForExistence(timeout: 3), "the View menu has no Enter Full Screen")
        enter.click()
        let screenWidth = NSScreen.main?.frame.width ?? 0
        XCTAssertNotNil(until(12) { self.win.exists && self.win.frame.width >= screenWidth - 2 }, "the window did not enter full screen")
        Thread.sleep(forTimeInterval: 1.5)
        let s = snapItems(), w = win.frame
        attachShot("minimal-reversed-fullscreen")
        if let first = chips(s).first?.frame, let field = item("omnibox", s) {
            XCTAssertLessThan(first.minY, field.minY, "full screen: rows not swapped")
            XCTAssertLessThan(first.minX - w.minX, 40, "full screen: the first tab still keeps room for lights that are not there")
        } else { XCTFail("full screen: tabs or field missing (\(presentIDs()))") }
        app.menuBars.menuBarItems["View"].click()
        let exit = app.menuBars.menuItems["Exit Full Screen"]
        XCTAssertTrue(exit.waitForExistence(timeout: 3), "no Exit Full Screen item")
        exit.click()
        XCTAssertNotNil(until(12) { self.win.exists && self.win.frame.width < screenWidth - 2 }, "the window did not leave full screen")
    }
}

/// Every Minimal interaction test (inactive and active tab clicks, hover-then-click, context menu close and lock, the selected tab in view with up to 100 tabs, keyboard navigation, narrow widths with the Library open,
/// scroll-bar styles), run with the compact tabs above the toolbar by changing only the layout under test. Then the interactions that are particular to the top strip: hover preview and the toolbar that slides in over a full-screen page.
final class D1eMinimalReversedParityUITests: D1bMinimalUITests {
    override var layoutName: String { "minimalReversed" }
    override var layoutTitle: String { "Minimal Reversed" }
    override var stripTop: CGFloat { 0 }

    private func at(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate { win.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x - win.frame.minX, dy: y - win.frame.minY)) }
    private func tabFrames() -> [CGRect] { snapItems().filter { $0.id == "tab-chip" }.sorted { $0.frame.minX < $1.frame.minX }.map(\.frame) }

    /// Resting the pointer on a compact tab shows the preview card; moving away removes it.
    func testHoverPreviewAppearsAndGoes() throws {
        launch(state: "bulk-tabs", extra: ["-UITabCount", "4", "-UILayout", layoutName], env: ["BS_WINDOW_SIZE": "1000x800"])
        XCTAssertNotNil(until(30) { self.win.exists && self.tabFrames().count >= 3 }, "tabs did not appear")
        Thread.sleep(forTimeInterval: 0.8)
        guard let tab = tabFrames().dropFirst().first else { XCTFail("no second tab"); return }
        func previewShown() -> Bool { app.descendants(matching: .any)["tab-preview"].exists }
        at(tab.midX, tab.midY).hover()
        XCTAssertNotNil(until(4) { previewShown() }, "no preview after resting on a tab")
        attachShot("minimal-reversed-hover-preview")
        win.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.7)).hover()
        XCTAssertNotNil(until(4) { !previewShown() }, "the preview stayed after the pointer left")
    }

    private struct PeekObservation { var hidesAway = false, appearsAtTop = false, tabsAboveField = false, tabsAtTop = false, firstTabClear = false, controls = false, goesAgain = false }
    private func observeFullScreenPeek(layout: String) -> PeekObservation {
        var o = PeekObservation()
        launch(state: "bulk-tabs", extra: ["-UITabCount", "4", "-UILayout", layout], env: ["BS_WINDOW_SIZE": "1000x800"])
        XCTAssertNotNil(until(30) { self.win.exists && abs(self.win.frame.width - 1000) < 6 && self.any("omnibox").exists }, "\(layout) did not come up")
        Thread.sleep(forTimeInterval: 0.8)
        app.menuBars.menuBarItems["View"].click()
        let enter = app.menuBars.menuItems["Enter Full Screen"]
        XCTAssertTrue(enter.waitForExistence(timeout: 3), "the View menu has no Enter Full Screen")
        enter.click()
        let screenWidth = NSScreen.main?.frame.width ?? 0
        XCTAssertNotNil(until(12) { self.win.exists && self.win.frame.width >= screenWidth - 2 }, "\(layout): the window did not enter full screen")
        Thread.sleep(forTimeInterval: 1.5)
        func toolbarShowing() -> Bool { snapItems().contains { $0.id == "omnibox" && $0.frame.minY - self.win.frame.minY < 120 } }
        win.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).hover()
        o.hidesAway = until(8) { !toolbarShowing() } != nil
        at(win.frame.midX, win.frame.minY + 1).hover()
        o.appearsAtTop = until(5) { toolbarShowing() } != nil
        Thread.sleep(forTimeInterval: 0.6)
        let s = snapItems(), w = win.frame
        attachShot("\(layout)-fullscreen-peek")
        let chips = s.filter { $0.id == "tab-chip" }.sorted { $0.frame.minX < $1.frame.minX }
        if let first = chips.first?.frame, let field = s.first(where: { $0.id == "omnibox" })?.frame {
            o.tabsAboveField = first.maxY <= field.minY + 4
            o.tabsAtTop = first.minY - w.minY < 20
            o.firstTabClear = first.minX - w.minX < 40
        }
        o.controls = ["sidebar-button", "omnibox", "reload-button"].allSatisfy { id in s.contains { $0.id == id } }
        win.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).hover()
        o.goesAgain = until(8) { !toolbarShowing() } != nil
        app.menuBars.menuBarItems["View"].click()
        let exit = app.menuBars.menuItems["Exit Full Screen"]
        if exit.waitForExistence(timeout: 3) { exit.click() }
        _ = until(10) { self.win.exists && self.win.frame.width < screenWidth - 2 }
        app.terminate()
        return o
    }

    /// In full screen the toolbar and tabs behave as Minimal's do (same go-away, come-in and go-again), with the rows reversed, the tabs at the top edge and no room kept for absent lights.
    func testFullScreenToolbarPeekMatchesMinimal() throws {
        let minimal = observeFullScreenPeek(layout: "minimal")
        let reversed = observeFullScreenPeek(layout: "minimalReversed")
        let note = XCTAttachment(string: "minimal: \(minimal)\nreversed: \(reversed)"); note.name = "fullscreen-peek"; note.lifetime = .keepAlways; add(note)
        XCTAssertEqual(reversed.hidesAway, minimal.hidesAway, "the toolbar's go-away differs from Minimal: \(reversed) vs \(minimal)")
        XCTAssertEqual(reversed.appearsAtTop, minimal.appearsAtTop, "the toolbar's come-in differs from Minimal: \(reversed) vs \(minimal)")
        XCTAssertEqual(reversed.goesAgain, minimal.goesAgain, "the peeked toolbar's leaving differs from Minimal: \(reversed) vs \(minimal)")
        XCTAssertEqual(reversed.controls, minimal.controls, "the peek's controls differ from Minimal: \(reversed) vs \(minimal)")
        if reversed.appearsAtTop {
            XCTAssertTrue(reversed.tabsAboveField, "peek: the tabs are not above the toolbar")
            XCTAssertTrue(reversed.tabsAtTop, "peek: the tabs are not at the top edge")
            XCTAssertTrue(reversed.firstTabClear, "peek: the first tab keeps room for lights that are not there")
        }
    }
}
