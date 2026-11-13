import XCTest

/// Classic and its Library sidebar: structure, selected-tab visibility, the Library being a Library (saved resources, no tab navigator), placement and width. Throwaway profile, window-only pictures.
class D1aClassicUITests: PerfCase {
    /// The layout under test; Classic Reversed's parity class runs every test below with it set to `classicReversed`.
    var layoutName: String { "classic" }
    /// `resize: false` leaves the window at the app's own size (1200): no programmatic resize is made while the Library is being laid out.
    func launchClassic(width: Int = 1000, tabs: Int = 5, options: [String] = [], light: Bool = false, resize: Bool = true) {
        var env: [String: String] = resize ? ["BS_WINDOW_SIZE": "\(width)x800"] : [:]
        if light { env["BS_SETUP_LIGHT"] = "1" }
        launch(state: "bulk-tabs", extra: ["-UITabCount", "\(tabs)", "-UILayout", layoutName] + options, env: env)
        XCTAssertNotNil(until(30) { win.exists && (!resize || abs(win.frame.width - CGFloat(width)) < 6) && any("omnibox").exists }, "Classic did not come up at \(width)")
        Thread.sleep(forTimeInterval: 0.5)
        app.typeKey(.escape, modifierFlags: [])
        win.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.7)).hover()
        Thread.sleep(forTimeInterval: 0.2)
    }
    private func rel(_ r: CGRect) -> String { let w = win.frame; return String(format: "x %.0f–%.0f y %.0f–%.0f (w %.0f h %.0f)", r.minX - w.minX, r.maxX - w.minX, r.minY - w.minY, r.maxY - w.minY, r.width, r.height) }
    private func attachCrop(_ name: String, width: CGFloat = 700, height: CGFloat = 80) {
        guard let cg = win.safeScreenshot()?.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let scale = CGFloat(cg.width) / win.frame.width
        guard let crop = cg.cropping(to: CGRect(x: 0, y: 0, width: min(width, win.frame.width) * scale, height: height * scale)) else { return }
        let a = XCTAttachment(image: NSImage(cgImage: crop, size: NSSize(width: crop.width, height: crop.height))); a.name = name; a.lifetime = .keepAlways; add(a)
    }
    private func pageFrame() -> CGRect? { let web = win.descendants(matching: .webView).firstMatch; return web.exists ? web.frame : nil }
    private func count(_ id: String) -> Int { win.descendants(matching: .any).matching(identifier: id).count }
    /// How many separate tab strips there are: the strip's accessibility identifier is on more than one element (the strip and what it holds), so strips are counted by where they sit.
    private func stripRows() -> Int { Set(chipSnapshots().filter { $0.frame.width > 100 }.map { Int($0.frame.minY.rounded()) }).count }

    /// CL-01…04: one toolbar with one omnibox, one tab strip, no sidebar until it is asked for.
    func testClassicHasOneToolbarOneStripOneField() throws {
        for (light, name) in [(false, "dark"), (true, "light")] {
            launchClassic(light: light)
            XCTAssertEqual(count("omnibox"), 1, "Classic has exactly one address field")
            XCTAssertEqual(stripRows(), 1, "Classic has exactly one tab strip row")
            XCTAssertFalse(any("sidebar").exists, "the Library is hidden until it is opened")
            let strip = any("tab-bar").frame, field = any("omnibox").frame
            XCTAssertLessThan(field.maxY, strip.minY + 1, "the address field is above the tab strip, not beside it")
            report.note("CLASSIC \(name): field \(rel(field)); strip \(rel(strip)); page \(pageFrame().map(rel) ?? "none")")
            attachShot("classic-5tabs-\(name)")
            app.terminate()
        }
    }

    /// CL-16/17: with 25 and 100 tabs the selected tab is in view and the strip scrolls, not shrinks.
    func testSelectedTabStaysInViewWithManyTabs() throws {
        for count in [25, 100] {
            launchClassic(width: 800, tabs: count)
            let w = win.frame
            XCTAssertNotNil(until(5) { guard let s = chipSnapshots().first(where: { $0.selected }) else { return false }; return s.frame.minX >= w.minX - 1 && s.frame.maxX <= w.maxX + 1 }, "\(count) tabs: the selected tab is not in view")
            let widths = chipSnapshots().prefix(5).map { Int($0.frame.width) }
            report.note("CLASSIC \(count) tabs: first tab widths \(widths)")
            XCTAssertTrue(widths.allSatisfy { $0 >= 100 }, "\(count) tabs: tabs shrank to \(widths) instead of the strip scrolling")
            attachShot("classic-\(count)-tabs")
            app.terminate()
        }
    }

    /// CL-36…48: the Library shows saved resources, not open tabs, and does not starve the page.
    func testLibrarySidebarIsALibrary() throws {
        launchClassic(width: 1200, options: ["-UISidebarOpen", "1", "-UIBookmarks", "1"], resize: false)
        XCTAssertTrue(any("sidebar").exists, "the Library did not open")
        let sidebar = any("sidebar").frame
        report.note("CLASSIC library: sidebar \(rel(sidebar)); page \(pageFrame().map(rel) ?? "none")")
        // No open-tab rows inside the Library (the tabs are in the strip).
        let rows = chipSnapshots().filter { $0.frame.minX < sidebar.maxX - 20 && $0.frame.minY > any("tab-bar").frame.maxY }
        XCTAssertTrue(rows.isEmpty, "the Library lists open tabs: \(rows.map { $0.label })")
        XCTAssertFalse(any("search-tabs-button").exists, "the Library carries a Search Tabs row (a tab-navigator control)")
        XCTAssertGreaterThanOrEqual((pageFrame()?.width ?? 0), 400, "the Library squeezes the page")
        // The Library's own bar: add, add to a folder, sort, more.
        XCTAssertTrue(any("library-add").exists && any("library-folder").exists && any("library-sort").exists && any("library-more").exists, "the Library bar is incomplete")
        attachShot("classic-library-bookmarks")
        // The History section: the picker stays, Clear History is in the Library (not a "Clear All" in the window toolbar), rows have no raw-address clutter.
        let history = win.radioButtons["History"].exists ? win.radioButtons["History"] : win.buttons["History"]
        XCTAssertTrue(history.exists, "no History in the Library's picker")
        history.click(); Thread.sleep(forTimeInterval: 0.4)
        XCTAssertTrue(win.radioButtons["Bookmarks"].exists || win.buttons["Bookmarks"].exists, "the picker is gone in History, so there is no way back")
        XCTAssertFalse(win.buttons["Clear All"].exists, "History's Clear All leaked into the window toolbar")
        XCTAssertTrue(any("clear-history").exists, "no Clear History in the Library")
        attachShot("classic-library-history")
        XCTAssertEqual(count("omnibox"), 1, "opening the Library must not add an address field")
        XCTAssertEqual(stripRows(), 1, "opening the Library must not add a tab strip row")
    }

    /// CL-44: the Library on the right.
    func testLibraryOnTheRight() throws {
        launchClassic(width: 1200, options: ["-UISidebarOpen", "1", "-UISidebarPosition", "right", "-UIBookmarks", "1"], resize: false)
        let sidebar = any("sidebar").frame, page = pageFrame()
        report.note("CLASSIC library right: sidebar \(rel(sidebar)); page \(page.map(rel) ?? "none")")
        XCTAssertGreaterThan(sidebar.minX, win.frame.minX + win.frame.width / 2, "the Library should be on the right")
        attachShot("classic-library-right")
    }

    /// CL-45: the way a person gets there: a narrow window first, then the Library opened from the toolbar. Each step is noted, so a crash shows where it happened.
    func testOpeningTheLibraryAtNarrowWidth() throws {
        report.note("CLASSIC narrow: launching at 520")
        launchClassic(width: 520, options: ["-UIBookmarks", "1"])
        report.note("CLASSIC narrow: up at \(Int(win.frame.width)); opening the Library")
        XCTAssertFalse(any("sidebar").exists)
        XCTAssertTrue(any("sidebar-button").exists, "no sidebar button in the toolbar at 520 pt")
        any("sidebar-button").click()
        XCTAssertNotNil(until(5) { self.any("sidebar").exists }, "the Library did not open at 520 pt")
        report.note("CLASSIC narrow: Library open; measuring")
        Thread.sleep(forTimeInterval: 0.5)
        let narrow = pageFrame()
        report.note("CLASSIC library 520: sidebar \(any("sidebar").exists ? rel(any("sidebar").frame) : "none"); page \(narrow.map(rel) ?? "none")")
        XCTAssertGreaterThanOrEqual(narrow?.width ?? 0, 200, "at 520 pt the Library leaves the page \(narrow?.width ?? 0) pt")
        attachShot("classic-library-520")
    }

    // MARK: Omnibox

    private func fieldText() -> String { (any("omnibox").value as? String) ?? "" }
    private func hasKeyboardFocus() -> Bool { (any("omnibox").value(forKey: "hasKeyboardFocus") as? Bool) == true }

    /// Display shows the host, editing shows the whole address (selected); Escape returns to the display.
    func testOmniboxDisplayVersusEditable() throws {
        launchClassic()
        let display = fieldText()
        XCTAssertEqual(display, "127.0.0.1", "the field at rest shows the host: \(display)")
        app.typeKey("l", modifierFlags: .command)
        XCTAssertNotNil(until(3) { self.hasKeyboardFocus() }, "Cmd-L did not focus the field")
        XCTAssertNotNil(until(3) { self.fieldText().hasPrefix("http://127.0.0.1") }, "editing should show the whole address, not the host: \(fieldText())")
        attachCrop("classic-omnibox-editing", width: 1000, height: 120)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertNotNil(until(3) { self.fieldText() == "127.0.0.1" }, "Escape should return the field to its display text: \(fieldText())")
    }

    /// Suggestions: they appear under the field, inside the window; the arrows move through them; Escape closes them first.
    func testOmniboxSuggestionsAnchorAndKeys() throws {
        launchClassic()
        app.typeKey("l", modifierFlags: .command); paste("swift browser"); Thread.sleep(forTimeInterval: 0.4)
        let row = win.buttons["Search for “swift browser”"]
        XCTAssertNotNil(until(4) { row.exists }, "no suggestion row")
        let w = win.frame, f = any("omnibox").frame, r = row.frame
        report.note("CLASSIC suggestions: field \(rel(f)); row \(rel(r))")
        XCTAssertGreaterThanOrEqual(r.minX, w.minX - 1); XCTAssertLessThanOrEqual(r.maxX, w.maxX + 1, "suggestions leave the window")
        XCTAssertGreaterThanOrEqual(r.minY, f.maxY - 4, "suggestions should be under the field")
        XCTAssertTrue(r.minX <= f.midX && f.midX <= r.maxX, "suggestions are not anchored to the field")
        attachShot("classic-omnibox-suggestions")
        app.typeKey(.downArrow, modifierFlags: []); Thread.sleep(forTimeInterval: 0.15)
        XCTAssertEqual(fieldText().isEmpty, false, "the arrows must not clear the field")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertNotNil(until(3) { !row.exists }, "Escape did not close the suggestions")
    }

    /// Stale suggestions: choosing another tab ends the edit and takes its suggestions with it.
    func testOmniboxSuggestionsDoNotSurviveATabChange() throws {
        launchClassic()
        app.typeKey("l", modifierFlags: .command); paste("swift browser"); Thread.sleep(forTimeInterval: 0.4)
        let row = win.buttons["Search for “swift browser”"]
        XCTAssertNotNil(until(4) { row.exists }, "no suggestion row")
        app.typeKey("2", modifierFlags: .command)
        XCTAssertNotNil(until(3) { !row.exists }, "the suggestions stayed after changing tab")
        XCTAssertNotEqual(fieldText(), "swift browser", "the draft was carried onto another tab: \(fieldText())")
    }

    /// The Library's bar: add the page you are on; sort offers its choices; Clear History asks first.
    func testLibraryBarAddSortAndClearHistory() throws {
        launchClassic(width: 1200, options: ["-UISidebarOpen", "1", "-UIBookmarks", "1"], resize: false)
        XCTAssertTrue(any("library-add").exists)
        any("library-add").click(); Thread.sleep(forTimeInterval: 0.4)
        XCTAssertNotNil(until(3) { self.win.buttons["Page Bulk4"].exists || self.win.descendants(matching: .any).matching(NSPredicate(format: "label == 'Page Bulk4'")).count > 0 }, "the page was not added to the bookmarks")
        any("library-sort").click()
        let title = app.menuItems["Title"]
        XCTAssertNotNil(until(3) { title.exists }, "the sort menu has no Title")
        title.click(); Thread.sleep(forTimeInterval: 0.2)
        // History, then the confirmation.
        let history = win.radioButtons["History"].exists ? win.radioButtons["History"] : win.buttons["History"]
        history.click(); Thread.sleep(forTimeInterval: 0.4)
        any("clear-history").click()
        let confirm = app.buttons["Clear History"]
        XCTAssertNotNil(until(3) { confirm.exists }, "Clear History did not ask for confirmation")
        attachShot("classic-library-clear-confirmation")
        app.buttons["Cancel"].click()
    }

    // MARK: Tab interaction contract

    private func visibleItem(_ title: String) -> XCUIElement? { app.menuItems.matching(NSPredicate(format: "title == %@", title)).allElementsBoundByIndex.first { $0.isHittable } }
    private func labels() -> [String] { chipSnapshots().filter { $0.frame.width > 100 }.map { $0.label } }

    /// Right-click opens the clicked tab's menu and acts on it, without changing which tab is selected; Move Left reorders without dragging.
    func testRightClickTargetsTheClickedTabAndMoveLeftReorders() throws {
        launchClassic()
        let before = labels(), selected = chipSnapshots().first { $0.selected }?.label
        guard before.count >= 4 else { return XCTFail("tabs: \(before)") }
        let target = before[2]
        chip(chipSnapshots().firstIndex { $0.label == target }!).rightClick()
        XCTAssertNotNil(until(3) { visibleItem("Move Left") != nil }, "no Move Left in the tab menu")
        visibleItem("Move Left")?.click(); Thread.sleep(forTimeInterval: 0.3)
        let after = labels()
        XCTAssertEqual(after.firstIndex(of: target), (before.firstIndex(of: target) ?? 0) - 1, "Move Left did not move \(target) one place left: \(before) -> \(after)")
        XCTAssertEqual(chipSnapshots().first { $0.selected }?.label, selected, "the right-click or the menu changed which tab is selected")
    }

    /// ⌥⇧⌘→ and ⌥⇧⌘← move the tab in front one place, without a drag (the keyboard way to reorder), and leave it selected.
    func testKeyboardMovesTheTabInFront() throws {
        launchClassic()
        let before = labels()
        guard before.count >= 4 else { return XCTFail("tabs: \(before)") }
        let target = before[1]
        chip(chipSnapshots().firstIndex { $0.label == target }!).click(); Thread.sleep(forTimeInterval: 0.2)
        app.typeKey(.rightArrow, modifierFlags: [.command, .option, .shift]); Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(labels().firstIndex(of: target), 2, "⌥⇧⌘→ did not move the tab one place right: \(labels())")
        app.typeKey(.leftArrow, modifierFlags: [.command, .option, .shift]); Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(labels().firstIndex(of: target), 1, "⌥⇧⌘← did not move it back")
        XCTAssertEqual(chipSnapshots().first { $0.selected }?.label, target, "moving the tab changed which tab is selected")
    }

    /// A full strip has an All Tabs menu; choosing a tab there selects it and brings it into view.
    func testOverflowMenuReachesEveryTab() throws {
        launchClassic(tabs: 30)
        XCTAssertFalse(chipSnapshots().isEmpty)
        let menu = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'tab-overflow-menu' OR label BEGINSWITH 'All tabs'")).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 3), "no All Tabs menu on a full strip")
        menu.click()
        let item = app.menuItems["Page Bulk27"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 3), "the All Tabs menu does not list every tab")
        item.click(); Thread.sleep(forTimeInterval: 0.4)
        let selected = chipSnapshots().first { $0.selected }
        XCTAssertTrue(selected?.label.hasPrefix("Page Bulk27") == true, "choosing a tab in All Tabs did not select it (\(selected?.label ?? "-"))")
        if let f = selected?.frame { XCTAssertTrue(win.frame.contains(CGPoint(x: f.midX, y: f.midY)), "the chosen tab is not in view") }
    }

    /// With few tabs there is no All Tabs menu (it is only there when the strip is full).
    func testNoOverflowMenuWhenTheTabsFit() throws {
        launchClassic(tabs: 3)
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'tab-overflow-menu' OR label BEGINSWITH 'All tabs'")).firstMatch.exists, "an All Tabs menu with only three tabs")
    }

    /// Escape closes a hover preview (the top layer first).
    func testEscapeClosesTheHoverPreview() throws {
        launchClassic(options: ["-UIHoverPreviews", "1", "-UIHoverDelay", "0.3"])
        let snaps = chipSnapshots().filter { !$0.selected && $0.frame.width > 100 }
        guard let f = snaps.first?.frame else { return XCTFail("no inactive tab") }
        win.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: f.midX - win.frame.minX, dy: f.midY - win.frame.minY)).hover()
        let preview = app.descendants(matching: .any)["tab-preview"]
        guard preview.waitForExistence(timeout: 4) else { throw XCTSkip("no preview appeared for this page (it needs a snapshot); Escape could not be checked") }
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertNotNil(until(2) { !preview.exists }, "Escape did not close the hover preview")
    }

    /// Dragging a tab to the strip's far end scrolls a full strip that way (and does not reorder: the end is not a drop place).
    func testDraggingToTheStripEndScrollsIt() throws {
        launchClassic(tabs: 30)
        let w = win.frame
        let onScreen = { self.chipSnapshots().filter { $0.frame.width > 100 && $0.frame.minX >= w.minX && $0.frame.maxX <= w.maxX } }
        let visible = onScreen()
        guard visible.count >= 3, let all = Optional(chipSnapshots().filter { $0.frame.width > 100 }) else { return XCTFail("no visible tabs") }
        // Toward the end that has room to scroll: the strip opens on the tab in front, wherever it is.
        let hiddenLeft = all.contains { $0.frame.maxX < w.minX }
        let source = visible[visible.count / 2]
        // The zones are 12 pt strips just outside the scrolling tabs: at the strip's start, and before the All Tabs / New Tab buttons at its end.
        let stripFrame = snapItems().filter { $0.id == "tab-bar" && $0.frame.width > 300 }.map(\.frame).max { $0.width < $1.width } ?? w
        let endButtons = [any("tab-overflow-menu"), any("new-tab-inline")].filter { $0.exists }.map(\.frame.minX).min() ?? stripFrame.maxX
        let edgeX = hiddenLeft ? stripFrame.minX + 6 : endButtons - 8
        let probe = hiddenLeft ? all.first! : all.last!
        let probeBefore = probe.frame.minX
        let at = { (x: CGFloat, y: CGFloat) in self.win.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x - w.minX, dy: y - w.minY)) }
        at(source.frame.midX, source.frame.midY).hover(); Thread.sleep(forTimeInterval: 0.2)
        at(source.frame.midX, source.frame.midY).click(forDuration: 0.4, thenDragTo: at(edgeX, source.frame.midY), withVelocity: .default, thenHoldForDuration: 2.0)
        Thread.sleep(forTimeInterval: 0.4)
        let probeAfter = chipSnapshots().first { $0.label == probe.label }?.frame.minX ?? probeBefore
        XCTAssertGreaterThan(abs(probeAfter - probeBefore), 100, "holding a dragged tab at the strip's \(hiddenLeft ? "start" : "end") did not scroll it (\(probe.label) x \(Int(probeBefore)) → \(Int(probeAfter)))")
        XCTAssertEqual(chipSnapshots().filter { $0.frame.width > 100 }.count, all.count, "the drag changed the number of tabs")
    }

    /// Groups inline: the label is in the strip with its tabs after it; a click collapses it (its tabs leave the strip, the label shows the count) and opens it again.
    func testGroupsAreInlineAndCollapse() throws {
        launchClassic(tabs: 8, options: ["-UIGroups", "1"])
        let label = app.descendants(matching: .any).matching(identifier: "strip-group-label").firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 3), "no inline group label in the strip")
        let before = chipSnapshots().count
        XCTAssertGreaterThanOrEqual(before, 8, "every tab, grouped or not, is in the strip (\(before))")
        label.click(); Thread.sleep(forTimeInterval: 0.4)
        let collapsed = chipSnapshots().count
        XCTAssertLessThan(collapsed, before, "collapsing the group did not take its tabs out of the strip (\(before) → \(collapsed))")
        XCTAssertEqual(label.value as? String, "Collapsed")
        attachCrop("inline-group-collapsed", width: 900, height: 90)
        label.click(); Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(chipSnapshots().count, before, "expanding did not bring the tabs back")
        attachCrop("inline-group-expanded", width: 900, height: 90)
    }

    /// The group chip says how many tabs the strip is showing.
    func testGroupChipSaysHowManyTabs() throws {
        launchClassic(tabs: 8, options: ["-UIGroups", "1"])
        let chipEl = any("classic-group-chip")
        XCTAssertTrue(chipEl.waitForExistence(timeout: 3), "no group chip")
        let name = chipEl.title.isEmpty ? chipEl.label : chipEl.title
        XCTAssertTrue(name.contains(" tab"), "the group chip does not state a tab count: '\(name)'")
    }

    /// Close on another tab's menu closes that tab and leaves the selected one alone.
    func testContextMenuCloseClosesTheClickedTabOnly() throws {
        launchClassic()
        let selected = chipSnapshots().first { $0.selected }?.label
        let target = labels()[1]
        chip(chipSnapshots().firstIndex { $0.label == target }!).rightClick()
        XCTAssertNotNil(until(3) { visibleItem("Close Tab") != nil }); visibleItem("Close Tab")?.click(); Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(labels().contains(target), "the clicked tab is still there")
        XCTAssertEqual(chipSnapshots().first { $0.selected }?.label, selected, "closing another tab changed the selection")
    }

    /// A double-click on the selected tab's Close closes one tab, not two; a double-click on a tab body closes nothing (that setting is off by default).
    func testDoubleClickOnCloseClosesOneTabAndOnTheBodyNone() throws {
        launchClassic(tabs: 6)
        let w = win.frame
        let body = chipSnapshots().first { !$0.selected && $0.frame.width > 100 }!
        win.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: body.frame.midX - w.minX, dy: body.frame.midY - w.minY)).doubleClick()
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(labels().count, 6, "a double-click on a tab body closed a tab with the setting off")
        let selected = chipSnapshots().first { $0.selected }!
        let before = labels().count
        win.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: selected.frame.minX - w.minX + 13, dy: selected.frame.midY - w.minY)).doubleClick()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(labels().count, before - 1, "a double-click on Close should close one tab (\(before) -> \(labels().count))")
    }

    /// Single click selects at once and keeps the same tab object (no reload).
    func testSingleClickSelectsTheClickedTab() throws {
        launchClassic()
        let target = labels()[1]
        chip(chipSnapshots().firstIndex { $0.label == target }!).click()
        XCTAssertNotNil(until(3) { self.chipSnapshots().first { $0.selected }?.label == target }, "a click did not select \(target)")
        XCTAssertEqual(labels().count, 5, "a click changed how many tabs there are")
    }

    /// Essentials and pinned tabs are different things: pinned is a tile of a tab in the strip, an Essential is its own tile, and no tab is in both.
    func testEssentialsAndPinnedTabsStayDistinct() throws {
        launchClassic(tabs: 6, options: ["-UIPinned", "1", "-UIEssentials", "2"])
        let essentials = win.descendants(matching: .any).matching(NSPredicate(format: "label ENDSWITH ', Essential'")).allElementsBoundByIndex
        XCTAssertEqual(essentials.count, 2, "two Essentials expected: \(essentials.map { $0.label })")
        let tabs = chipSnapshots()
        let pinned = tabs.filter { $0.frame.width < 60 }
        XCTAssertEqual(pinned.count, 1, "one pinned tile expected")
        XCTAssertEqual(tabs.count, 4, "6 tabs, 2 of them Essentials: the strip lists 4 (1 pinned, 3 regular), not 6: \(tabs.map { $0.label })")
        attachShot("classic-essentials-and-pinned")
        // Opening an Essential selects it (its tile carries the selection).
        essentials[0].click(); Thread.sleep(forTimeInterval: 0.4)
        XCTAssertTrue(win.descendants(matching: .any).matching(NSPredicate(format: "label ENDSWITH ', Essential'")).allElementsBoundByIndex.contains { $0.isSelected }, "opening an Essential did not select its tile")
    }

    /// The group chip says which group the strip shows and switches it; its menu holds the group management.
    /// The chip's accessible name: a menu button is named by its title, not its label.
    private func chipName() -> String { let e = any("classic-group-chip"); return e.title.isEmpty ? e.label : e.title }

    func testGroupChipShowsAndSwitchesTheActiveGroup() throws {
        launchClassic(tabs: 8, options: ["-UIGroups", "1"])
        let chipView = any("classic-group-chip")
        XCTAssertTrue(chipView.exists, "no group chip although a group exists; present: \(presentIDs()); strip elements: \(snapItems().filter { $0.frame.minY - win.frame.minY > 40 && $0.frame.minY - win.frame.minY < 110 && $0.frame.minX - win.frame.minX < 260 }.map { "\($0.type)|\($0.id)|\($0.label)|\(Int($0.frame.minX - win.frame.minX)),\(Int($0.frame.width))" })")
        // One actionable menu control: exactly one element carries the identifier, it is a menu button / pop-up button, and the icon and text inside it are not separate accessibility elements.
        let chipItems = snapItems().filter { $0.id == "classic-group-chip" }
        XCTAssertEqual(chipItems.count, 1, "the group chip is not exactly one accessibility element: \(chipItems.map { "\($0.type)|\($0.label)" })")
        XCTAssertTrue([UInt(XCUIElement.ElementType.menuButton.rawValue), UInt(XCUIElement.ElementType.popUpButton.rawValue), UInt(XCUIElement.ElementType.button.rawValue)].contains(chipItems.first?.type ?? 0), "the group chip is not exposed as a button/menu: type \(chipItems.first?.type ?? 0)")
        let insideChip = snapItems().filter { item in item.id != "classic-group-chip" && item.id != "tab-chip" && item.id != "strip-group-label" && !item.label.isEmpty && chipItems.contains { $0.frame.contains(CGPoint(x: item.frame.midX, y: item.frame.midY)) && $0.frame != item.frame } }
        XCTAssertTrue(insideChip.isEmpty, "the chip's icon or text is a separate accessibility element: \(insideChip.map(\.label))")
        XCTAssertFalse(chipName().isEmpty, "the group chip has no accessibility label (VoiceOver would say nothing); \(chipView.debugDescription)")
        XCTAssertTrue(chipName().contains("All Tabs"), "with no group chosen the strip shows every tab, groups inline: \(chipName())")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "strip-group-label").firstMatch.exists, "the Reading group has no inline label in the strip")
        let ungrouped = chipSnapshots().count
        attachCrop("classic-group-chip-ungrouped", width: 700, height: 90)
        chipView.click()
        let item = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'Reading'")).allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(item, "the menu does not list the Reading group")
        item?.click()
        XCTAssertNotNil(until(4) { self.chipName().contains("Reading") }, "the chip did not change to Reading: \(chipName())")
        XCTAssertTrue(chipName().contains("Tab group") && chipName().contains("Reading"), "the accessible name does not say the group: \(chipName())")
        XCTAssertEqual(chipSnapshots().count, 2, "the Reading group has two tabs; the strip shows \(chipSnapshots().count) (ungrouped it showed \(ungrouped))")
        attachCrop("classic-group-chip-reading", width: 700, height: 90)
        any("classic-group-chip").click()
        XCTAssertNotNil(until(3) { self.app.menuItems["Rename Group…"].exists }, "the group menu has no Rename Group…")
        XCTAssertTrue(app.menuItems["New Subgroup…"].exists && app.menuItems["Delete Group"].exists, "the group menu is missing New Subgroup… or Delete Group")
        app.typeKey(.escape, modifierFlags: [])
    }
}
