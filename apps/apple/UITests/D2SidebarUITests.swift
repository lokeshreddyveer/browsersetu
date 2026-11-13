import XCTest

/// The fixed pauses in the Sidebar classes run at half length (never below 0.1 s); every wait that watches for a condition (`until`, `waitForExistence`) is unchanged, and no test is removed. `PauseBudget` adds up what the
/// tests asked for and what they actually waited, and each test prints the totals, so the saving is measured, not assumed.
fileprivate enum PauseBudget { nonisolated(unsafe) static var asked = 0.0, slept = 0.0 }
fileprivate extension PerfCase {
    /// What the window shows, as one string: every accessibility item with its place. Two equal readings mean nothing moved between them.
    func signature() -> String { snapItems().map { "\($0.id)|\($0.label)|\(Int($0.frame.minX)),\(Int($0.frame.minY)),\(Int($0.frame.width)),\(Int($0.frame.height))|\($0.selected)" }.joined(separator: ";") }
    /// Returns as soon as `read()` has stayed the same for `quiet` seconds (or after `timeout`). It stands in for a fixed pause: a screen that settles at once costs `quiet`, not the longest settle time that was ever seen.
    func settle(quiet: Double = 0.2, timeout: Double = 3, _ read: () -> String) {
        var last = read(), since = Date()
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            Thread.sleep(forTimeInterval: 0.04)
            let now = read()
            if now != last { last = now; since = Date() } else if Date().timeIntervalSince(since) >= quiet { return }
        }
    }
    func pause(_ seconds: Double) {
        let shortened = max(0.1, seconds * 0.5)
        PauseBudget.asked += seconds; PauseBudget.slept += shortened
        Thread.sleep(forTimeInterval: shortened)
    }
}

/// D2 Sidebar: measurements and window-only pictures of the vertical layout in the states D2 asks about. Every launch is a throwaway profile (see PerfCase); nothing here is a whole-screen capture.
final class D2SidebarUITests: PerfCase {
    override func tearDown() { print(String(format: "PAUSE-BUDGET %@ asked %.1f s, waited %.1f s", name, PauseBudget.asked, PauseBudget.slept)); super.tearDown() }
    /// Launches the Sidebar layout with `tabs` tabs and the extra Debug options given.
    private func launchSidebar(width: Int = 1200, tabs: Int = 12, options: [String] = [], light: Bool = false, sidebarVisibleAtRest: Bool = true) {
        var env = ["BS_WINDOW_SIZE": "\(width)x800"]
        if light { env["BS_SETUP_LIGHT"] = "1" }
        launch(state: "bulk-tabs", extra: ["-UITabCount", "\(tabs)", "-UILayout", "sidebar", "-UIPinned", "2", "-UILocked", "1", "-UIGroups", "1", "-UIWorkspaces", "1"] + options, env: env)
        XCTAssertNotNil(until(30) { win.exists && abs(win.frame.width - CGFloat(width)) < 6 && (!sidebarVisibleAtRest || any("omnibox").exists || any("sidebar-rail").exists) }, "the Sidebar layout did not come up at \(width)")
        settle(quiet: 0.3) { signature() }
        app.typeKey(.escape, modifierFlags: [])
        win.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.7)).hover()
        settle(quiet: 0.15, timeout: 1.5) { signature() }
    }
    private func rel(_ r: CGRect) -> String { let w = win.frame; return String(format: "x %.0f–%.0f y %.0f–%.0f (w %.0f h %.0f)", r.minX - w.minX, r.maxX - w.minX, r.minY - w.minY, r.maxY - w.minY, r.width, r.height) }
    private func attachCrop(_ name: String, x: CGFloat = 0, y: CGFloat = 0, width: CGFloat = 340, height: CGFloat = 520) {
        guard let cg = win.safeScreenshot()?.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let scale = CGFloat(cg.width) / win.frame.width
        guard let crop = cg.cropping(to: CGRect(x: x * scale, y: y * scale, width: min(width, win.frame.width - x) * scale, height: min(height, win.frame.height - y) * scale)) else { return }
        let a = XCTAttachment(image: NSImage(cgImage: crop, size: NSSize(width: crop.width, height: crop.height))); a.name = name; a.lifetime = .keepAlways; add(a)
    }
    private func pageFrame() -> CGRect? { let web = win.descendants(matching: .webView).firstMatch; return web.exists ? web.frame : nil }

    /// Baseline: geometry and pictures of the expanded Sidebar.
    func testBaselineExpandedGeometry() throws {
        for (width, light) in [(1200, false), (1200, true), (800, false), (520, false)] {
            launchSidebar(width: width, light: light)
            let sidebar = any("sidebar").exists ? any("sidebar").frame : nil
            let rows = tabChips().allElementsBoundByIndex.map { $0.frame }
            report.note("D2 BASE @\(width)\(light ? " light" : ""): sidebar \(sidebar.map(rel) ?? "none"); page \(pageFrame().map(rel) ?? "none"); tab rows \(rows.count), first row \(rows.first.map(rel) ?? "-")")
            attachShot("d2-expanded-\(width)\(light ? "-light" : "-dark")")
            app.terminate()
        }
    }

    func testBaselineStates() throws {
        launchSidebar()
        // Hover a row: the Close it shows.
        chip(3).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover(); settle(quiet: 0.2, timeout: 1.7999999999999998) { signature() }
        attachCrop("d2-row-hover"); report.note("D2 BASE close buttons visible on hover: \(win.buttons.matching(NSPredicate(format: "label == 'Close tab'")).count)")
        // Address editing and suggestions.
        app.typeKey("l", modifierFlags: .command); paste("swift browser"); settle(quiet: 0.2, timeout: 2.4000000000000004) { signature() }
        attachShot("d2-omnibox-editing"); app.typeKey(.escape, modifierFlags: [])
        // Tab search.
        if any("search-tabs-button").exists { any("search-tabs-button").click(); settle(quiet: 0.2, timeout: 1.7999999999999998) { signature() }; attachShot("d2-tab-search"); app.typeKey(.escape, modifierFlags: []) }
        app.terminate()
        launchSidebar(options: ["-UISidebarPosition", "right"]); attachShot("d2-right"); app.terminate()
        launchSidebar(options: ["-UISidebarRail", "1"]); attachShot("d2-rail")
        report.note("D2 BASE rail: sidebar \(any("sidebar-rail").exists ? rel(any("sidebar-rail").frame) : "none"); page \(pageFrame().map(rel) ?? "none")")
        app.terminate()
    }

    func testBaselineManyTabs() throws {
        for count in [25, 100] {
            launchSidebar(tabs: count)
            let selected = chipSnapshots().first { $0.selected }
            report.note("D2 BASE \(count) tabs: rows \(chipSnapshots().count), selected row \(selected.map { rel($0.frame) } ?? "none")")
            attachShot("d2-\(count)-tabs")
            app.terminate()
        }
    }

    private func closeButtons() -> [XCUIElement] { win.buttons.matching(NSPredicate(format: "label == 'Close tab'")).allElementsBoundByIndex.filter { $0.frame.minX - win.frame.minX < 340 } }

    /// D2S-08: one workspace row with a menu; choosing another switches; the long list of every workspace is gone.
    func testWorkspaceHeaderSwitchesWorkspace() throws {
        launchSidebar()
        let menu = any("workspace-menu")
        XCTAssertTrue(menu.exists, "no workspace header")
        XCTAssertFalse(win.staticTexts["WORKSPACES"].exists, "the list of workspaces is still there")
        menu.click()
        func devItem() -> XCUIElement? { app.menuItems.matching(NSPredicate(format: "title == 'Dev'")).allElementsBoundByIndex.first { $0.isHittable } }
        XCTAssertNotNil(until(3) { devItem() != nil }, "the workspace menu has no Dev")
        devItem()?.click()
        settle(quiet: 0.2, timeout: 3.0) { signature() }
        attachCrop("d2-workspace-header-dev", height: 300)
        // Personal's twelve tabs belong to Personal: in Dev none of them is listed (workspaces filter, they do not close anything).
        let labels = chipSnapshots().map { $0.label }
        report.note("D2 workspace after choosing Dev: rows \(labels)")
        XCTAssertTrue(labels.allSatisfy { !$0.hasPrefix("Page Bulk") }, "Personal's tabs are still listed after switching to Dev: \(labels)")
    }

    /// Clicks where the selected row draws its Close (its trailing end).
    private func clickSelectedRowClose() {
        guard let row = chipSnapshots().first(where: { $0.selected }) else { return XCTFail("no selected row") }
        let origin = win.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: row.frame.maxX - win.frame.minX - 22, dy: row.frame.midY - win.frame.minY)).click()
    }

    /// D2S-12 / D2S-32: the selected row has a Close at its trailing end (drawn: see d2-selected-close) that closes that tab only; a locked selected row has none and stays.
    func testSelectedRowCloseAndLockedSafety() throws {
        launchSidebar(tabs: 8)
        attachCrop("d2-selected-close", height: 640)
        let before = chipSnapshots(), selectedLabel = before.first { $0.selected }?.label
        clickSelectedRowClose()
        XCTAssertNotNil(until(4) { chipSnapshots().count == before.count - 1 }, "closing the selected row should leave \(before.count - 1) tabs, found \(chipSnapshots().count)")
        XCTAssertFalse(chipSnapshots().contains { $0.label == selectedLabel }, "the selected tab \(String(describing: selectedLabel)) is still there")
        // A locked tab: select it, and the same place does nothing.
        func visibleItem(_ title: String) -> XCUIElement? { app.menuItems.matching(NSPredicate(format: "title == %@", title)).allElementsBoundByIndex.first { $0.isHittable } }
        let lockedRow = chipSnapshots().first { _ in true }   // pinned tiles come first; the locked tab is an open row
        _ = lockedRow
        let rows = chipSnapshots()
        guard let target = rows.indices.last(where: { !rows[$0].selected && rows[$0].frame.width > 100 }) else { return XCTFail("no open row to lock") }
        chip(target).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        XCTAssertNotNil(until(3) { visibleItem("Lock Tab") != nil }, "no Lock Tab"); visibleItem("Lock Tab")?.click(); settle(quiet: 0.2, timeout: 1.5) { signature() }
        chip(target).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click(); settle(quiet: 0.2, timeout: 1.7999999999999998) { signature() }
        attachCrop("d2-locked-selected", height: 640)
        let n = chipSnapshots().count
        clickSelectedRowClose(); settle(quiet: 0.2, timeout: 2.4000000000000004) { signature() }
        XCTAssertEqual(chipSnapshots().count, n, "a locked tab was closed from its row")
    }

    /// D2S-31: the selected tab is in view when the list opens, with 25 and 100 tabs.
    func testSelectedTabIsInViewOnOpen() throws {
        for count in [25, 100] {
            launchSidebar(tabs: count)
            let w = win.frame
            XCTAssertNotNil(until(4) { guard let s = chipSnapshots().first(where: { $0.selected }) else { return false }; return s.frame.minY >= w.minY && s.frame.maxY <= w.maxY }, "\(count) tabs: the selected row is not on screen (\(chipSnapshots().first(where: { $0.selected }).map { rel($0.frame) } ?? "none"))")
            report.note("D2 AFTER \(count) tabs: selected row \(chipSnapshots().first(where: { $0.selected }).map { rel($0.frame) } ?? "none"), first open row \(chipSnapshots().map { rel($0.frame) }.dropFirst(2).first ?? "-")")
            attachShot("d2-after-\(count)-tabs")
            app.terminate()
        }
    }

    /// D2S-18: Down and Up move the keyboard through the rows, Return selects the focused one.
    func testArrowKeysWalkTheRows() throws {
        launchSidebar(tabs: 8)
        func focused() -> Int? { chipSnapshots().firstIndex { _ in false } }
        let rows = tabChips()
        // Focus the first open row by clicking it (this selects it), then walk down.
        let startLabel = chipLabels()
        guard startLabel.count >= 6 else { return XCTFail("rows: \(startLabel)") }
        chip(3).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click(); settle(quiet: 0.2, timeout: 1.5) { signature() }
        let first = chipSnapshots().firstIndex { $0.selected }
        app.typeKey(.downArrow, modifierFlags: []); settle(quiet: 0.2, timeout: 1.5) { signature() }
        app.typeKey(.return, modifierFlags: []); settle(quiet: 0.2, timeout: 1.7999999999999998) { signature() }
        let second = chipSnapshots().firstIndex { $0.selected }
        report.note("D2 keyboard: selected row \(String(describing: first)) -> after Down+Return \(String(describing: second)) of \(rows.count)")
        XCTAssertNotNil(first); XCTAssertNotNil(second)
        XCTAssertNotEqual(first, second, "Down then Return did not move to another row")
        attachCrop("d2-keyboard-focus", height: 640)
    }

    /// D2S-27: with the sidebar hidden at the window edge, the pointer at the left edge brings it out; it goes again when the pointer leaves.
    func testEdgeRevealAndDismiss() throws {
        launchSidebar(options: ["-UISidebarAutoHide", "1"], sidebarVisibleAtRest: false)
        let w = win.frame
        XCTAssertNotNil(until(4) { (self.pageFrame()?.minX ?? 999) - w.minX < 20 }, "with auto-hide the page should start at the window edge: \(pageFrame().map(rel) ?? "none")")
        attachShot("d2-autohide-rest")
        win.coordinate(withNormalizedOffset: CGVector(dx: 0.002, dy: 0.5)).hover()
        XCTAssertNotNil(until(5) { self.any("sidebar").exists || self.any("workspace-menu").exists }, "the edge did not reveal the sidebar")
        settle(quiet: 0.2, timeout: 1.7999999999999998) { signature() }; attachShot("d2-edge-reveal")
        win.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).hover()
        XCTAssertNotNil(until(6) { !self.any("workspace-menu").exists }, "the revealed sidebar did not hide when the pointer left")
    }

    /// D2S-30 / short windows: a short window keeps the footer reachable.
    func testShortWindowKeepsFooterReachable() throws {
        launch(state: "bulk-tabs", extra: ["-UITabCount", "12", "-UILayout", "sidebar", "-UIPinned", "2", "-UIGroups", "1"], env: ["BS_WINDOW_SIZE": "900x420"])
        XCTAssertNotNil(until(30) { win.exists && abs(win.frame.height - 420) < 8 && any("omnibox").exists })
        settle(quiet: 0.2, timeout: 3.0) { signature() }
        let w = win.frame
        let footer = any("profile-button")
        XCTAssertTrue(footer.exists, "the footer's profile button is missing in a short window")
        if footer.exists { XCTAssertTrue(footer.frame.maxY <= w.maxY + 1 && footer.frame.minY >= w.minY, "the footer is outside the short window: \(rel(footer.frame))") }
        report.note("D2 short window 420: footer \(footer.exists ? rel(footer.frame) : "none"); page \(pageFrame().map(rel) ?? "none")")
        attachShot("d2-short-height")
    }

    /// D2S-19: a group's header folds and unfolds its tabs inline; folding closes nothing.
    func testGroupCollapseAndExpand() throws {
        launchSidebar()
        let open = chipSnapshots().count
        let header = win.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Reading, 2 tabs'")).firstMatch
        XCTAssertTrue(header.exists, "no Reading group header")
        attachCrop("d2-group-expanded", height: 800)
        header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertNotNil(until(3) { self.chipSnapshots().count == open - 2 }, "folding the group should hide its two tabs (\(open) -> \(self.chipSnapshots().count))")
        attachCrop("d2-group-collapsed", height: 800)
        header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertNotNil(until(3) { self.chipSnapshots().count == open }, "unfolding the group should bring its tabs back")
    }

    /// D2S-21: Search Tabs finds an open tab, and choosing it selects it.
    func testTabSearchSelectsTheFoundTab() throws {
        launchSidebar()
        any("search-tabs-button").click()
        XCTAssertNotNil(until(3) { self.any("tab-search-field").exists }, "the tab search field did not open")
        paste("Bulk7"); settle(quiet: 0.2, timeout: 2) { signature() }
        attachShot("d2-tab-search-results")
        app.typeKey(.return, modifierFlags: []); settle(quiet: 0.2, timeout: 2.4000000000000004) { signature() }
        XCTAssertNotNil(until(4) { self.chipSnapshots().first(where: { $0.selected })?.label == "Page Bulk7" }, "choosing the found tab did not select it: \(chipSnapshots().first(where: { $0.selected })?.label ?? "none")")
    }

    /// D2S-33: opening Bookmarks from the footer shows the Library and leaves the tab list as it was.
    func testLibraryFromTheFooterLeavesTheTabsAlone() throws {
        launchSidebar()
        let before = chipSnapshots().map { $0.label }
        let bookmarks = win.buttons["Bookmarks"]
        XCTAssertTrue(bookmarks.exists, "no Bookmarks button in the footer")
        bookmarks.click(); settle(quiet: 0.2, timeout: 3.0) { signature() }
        attachShot("d2-library-open")
        app.typeKey(.escape, modifierFlags: []); settle(quiet: 0.2, timeout: 1.7999999999999998) { signature() }
        XCTAssertEqual(chipSnapshots().map { $0.label }, before, "opening and closing the Library changed the tab list")
    }

    /// D2S-20: tree and stack modes still draw their presentation, and no tab goes missing.
    func testTreeAndStackModesKeepEveryTab() throws {
        for (name, flag) in [("tree", "-UITree"), ("stacks", "-UIStacks")] {
            launchSidebar(options: [flag, "1"])
            let rows = chipSnapshots().count
            report.note("D2 \(name): rows \(rows)")
            XCTAssertGreaterThanOrEqual(rows, 10, "\(name): tabs went missing from the sidebar (\(rows))")
            attachShot("d2-\(name)")
            app.terminate()
        }
    }
}

// MARK: - Phase 1: gap verification (tests only; they observe and record, they do not change what the app does)

/// D2 gap verification for the Sidebar layout: drag and drop (G1), the saved width (G3), the window controls (G4), tab states and search (G5/G6). Each test attaches what it saw (`<name>` text attachments), so a failure says
/// whether the behavior is missing or the test aimed at the wrong thing. Debug fixture: 12 tabs Bulk0…Bulk11, Bulk0 and Bulk1 pinned, group "Reading" = Bulk3 + Bulk4, Bulk6 locked.
final class D2SidebarGapUITests: PerfCase {
    override func tearDown() { print(String(format: "PAUSE-BUDGET %@ asked %.1f s, waited %.1f s", name, PauseBudget.asked, PauseBudget.slept)); super.tearDown() }
    private func launchSidebar(width: Int = 1200, tabs: Int = 12, options: [String] = [], root: String? = nil) {
        launch(state: "bulk-tabs", root: root, extra: ["-UITabCount", "\(tabs)", "-UILayout", "sidebar", "-UIPinned", "2", "-UILocked", "1", "-UIGroups", "1"] + options, env: ["BS_WINDOW_SIZE": "\(width)x800"])
        let hiddenAtRest = options.contains("-UISidebarAutoHide")
        XCTAssertNotNil(until(30) { win.exists && abs(win.frame.width - CGFloat(width)) < 6 && (hiddenAtRest ? win.descendants(matching: .webView).firstMatch.exists : (any("omnibox").exists || any("sidebar-rail").exists)) }, "the Sidebar layout did not come up")
        settle(quiet: 0.3) { signature() }
        app.typeKey(.escape, modifierFlags: [])
        win.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.7)).hover()
        settle(quiet: 0.15, timeout: 1.5) { signature() }
    }
    private func record(_ name: String, _ text: String) {
        report.note("\(name): \(text)")
        let a = XCTAttachment(string: text); a.name = name; a.lifetime = .keepAlways; add(a)
    }
    private func at(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate { win.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x - win.frame.minX, dy: y - win.frame.minY)) }
    /// The sidebar's tab rows and pinned tiles, top to bottom, from one snapshot: rows are wide, tiles are narrow.
    private struct Entry { let label: String; let frame: CGRect; let selected: Bool; var isTile: Bool { frame.width < 100 } }
    private func entries() -> [Entry] {
        snapItems().filter { $0.id == "tab-chip" && $0.frame.minX - win.frame.minX < 400 }.sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
            .map { Entry(label: $0.label, frame: $0.frame, selected: $0.selected) }
    }
    private func rows() -> [Entry] { entries().filter { !$0.isTile } }
    private func tiles() -> [Entry] { entries().filter(\.isTile) }
    private func labels(_ e: [Entry]) -> [String] { e.map(\.label) }
    private func entry(_ title: String) -> Entry? { entries().first { $0.label.hasPrefix(title) } }
    private func groupHeaderLabel() -> String? { snapItems().first { $0.label.hasPrefix("Reading,") }?.label }
    private func groupHeaderFrame() -> CGRect? { snapItems().first { $0.label.hasPrefix("Reading,") }?.frame }
    /// Press, hold, drag: hover first, as a person's pointer does.
    private func drag(_ from: CGRect, toY: CGFloat, toX: CGFloat? = nil) {
        at(from.midX, from.midY).hover(); settle(quiet: 0.15, timeout: 1) { signature() }
        at(from.midX, from.midY).click(forDuration: 0.5, thenDragTo: at(toX ?? from.midX, toY))
        settle(quiet: 0.35) { signature() }
    }
    private func menuTitles(for e: Entry) -> [String] {
        at(e.frame.midX, e.frame.midY).rightClick(); settle(quiet: 0.2, timeout: 2) { "\(app.menuItems.count)" }
        let titles = (try? app.snapshot())?.children.flatMap { _ in [String]() } ?? []
        _ = titles
        var out: [String] = []
        func walk(_ s: XCUIElementSnapshot) { if s.elementType == .menuItem, !s.title.isEmpty { out.append(s.title) }; s.children.forEach(walk) }
        if let snap = try? app.snapshot() { walk(snap) }
        app.typeKey(.escape, modifierFlags: []); settle(quiet: 0.1, timeout: 1) { "\(app.menuItems.count)" }
        return out
    }

    // MARK: D2a audit fixes

    private func collapseToRail() {
        let menu = any("sidebar-options")
        XCTAssertTrue(menu.waitForExistence(timeout: 3), "the Sidebar header has no options menu")
        menu.click()
        let item = app.menuItems["Collapse to Icons"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 3), "the options menu has no Collapse to Icons")
        item.click()
        XCTAssertNotNil(until(4) { self.any("sidebar-rail").exists }, "choosing Collapse to Icons did not produce the rail")
        settle(quiet: 0.2, timeout: 1.5) { signature() }
    }

    /// The Sidebar header has the options menu, and it collapses the sidebar to the rail and back.
    func testD2aOptionsMenuCollapsesToTheRailAndBack() throws {
        launchSidebar()
        collapseToRail()
        attachShot("d2a-rail")
        win.buttons["Expand Sidebar"].click()
        XCTAssertNotNil(until(4) { self.any("sidebar").exists && !self.any("sidebar-rail").exists }, "Expand Sidebar did not bring the sidebar back")
    }

    /// A group folded shut stays folded across the rail and back (the fold belongs to the model now, not to the view).
    func testD2aGroupFoldSurvivesTheRail() throws {
        launchSidebar()
        let open = rows().count
        guard let header = groupHeaderFrame() else { return XCTFail("no group header") }
        at(header.midX, header.midY).click(); settle(quiet: 0.25, timeout: 2) { signature() }
        let folded = rows().count
        XCTAssertLessThan(folded, open, "folding the group did not hide its tabs (\(open) → \(folded))")
        collapseToRail()
        win.buttons["Expand Sidebar"].click()
        XCTAssertNotNil(until(4) { self.any("sidebar").exists }, "no sidebar after expanding")
        settle(quiet: 0.3, timeout: 2) { signature() }
        XCTAssertEqual(rows().count, folded, "the folded group opened itself again after the rail (\(folded) → \(rows().count))")
    }

    /// Dragging a tab out of a group onto the open tabs takes it out of the group (it used to reorder it and leave it in).
    func testD2aDragOutOfAGroupLeavesTheGroup() throws {
        launchSidebar()
        guard let member = entry("Page Bulk3"), let target = entry("Page Bulk6") else { return XCTFail("rows missing: \(labels(rows()))") }
        XCTAssertTrue(groupHeaderLabel()?.hasPrefix("Reading, 2 tabs") == true, "the fixture's group is not 2 tabs: \(groupHeaderLabel() ?? "-")")
        drag(member.frame, toY: target.frame.minY + 4)
        let after = groupHeaderLabel() ?? "-"
        record("D2a-drag-out", "group header after: \(after); rows \(labels(rows()))")
        attachShot("d2a-drag-out")
        XCTAssertTrue(after.hasPrefix("Reading, 1 tab"), "dragging a tab out of the group did not take it out (\(after))")
    }

    /// The edge-reveal sidebar is never wider than 42 % of the window (in a narrow window it used to take the full saved width).
    func testD2aPeekIsCappedAtTheDocksShareOfTheWindow() throws {
        launchSidebar(width: 640, options: ["-UISidebarAutoHide", "1", "-UISidebarWidth", "340"])
        let w = win.frame
        win.coordinate(withNormalizedOffset: CGVector(dx: 0.002, dy: 0.5)).hover()
        XCTAssertNotNil(until(5) { self.any("sidebar").exists || self.any("workspace-menu").exists }, "the edge did not reveal the sidebar")
        settle(quiet: 0.3, timeout: 2) { signature() }
        let side = snapItems().filter { $0.id == "sidebar" && $0.frame.width > 100 }.map(\.frame.width).min() ?? 0
        record("D2a-peek-cap", "window \(Int(w.width)), peeked sidebar width \(Int(side))")
        XCTAssertGreaterThan(side, 100, "no peeked sidebar found")
        XCTAssertLessThanOrEqual(side, w.width * 0.42 + 4, "the peeked sidebar is \(Int(side)) pt in a \(Int(w.width)) pt window (cap \(Int(w.width * 0.42)))")
    }

    /// The rail carries the shared tab behaviour: a right-click opens the tab menu, and pinned tabs are marked.
    func testD2aRailTabsHaveTheTabMenu() throws {
        launchSidebar()
        collapseToRail()
        let tab = snapItems().first { $0.id == "tab-chip" && $0.frame.width < 60 }
        guard let f = tab?.frame else { return XCTFail("no tab in the rail") }
        at(f.midX, f.midY).rightClick()
        XCTAssertTrue(app.menuItems["Close Tab"].firstMatch.waitForExistence(timeout: 3), "a right-click on a rail tab did not open the tab menu")
        app.typeKey(.escape, modifierFlags: [])
    }

    /// The footer's Downloads button is there, named, and says nothing about progress while nothing downloads.
    func testD2aFooterDownloadsButtonIsNamedAndQuiet() throws {
        launchSidebar()
        let b = any("downloads-button")
        guard b.waitForExistence(timeout: 3) else { return XCTFail("no Downloads button in the footer") }
        XCTAssertFalse(b.label.isEmpty, "the Downloads button has no spoken name")
        XCTAssertFalse(b.label.contains("percent"), "the Downloads button shows progress with nothing downloading (\(b.label))")
    }

    /// Workspace deletion in the plain Sidebar layout asks first.
    func testD2aDeletingAWorkspaceAsks() throws {
        launchSidebar(options: ["-UIWorkspaces", "1"])
        any("workspace-menu").click()
        let dev = app.menuItems["Dev"].firstMatch
        guard dev.waitForExistence(timeout: 3) else { return XCTFail("no Dev workspace in the menu") }
        dev.click(); settle(quiet: 0.3, timeout: 2) { signature() }
        any("workspace-menu").click()
        let del = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'Delete'")).firstMatch
        guard del.waitForExistence(timeout: 3) else { return XCTFail("no Delete in the workspace menu") }
        del.click()
        // The question is an app-modal alert: its window is not reachable from the test, but the browser window is disabled while it is up.
        XCTAssertNotNil(until(4) { !self.win.isEnabled }, "Delete did not ask for confirmation (the window stayed usable)")
        // The alert's own window is out of the test's reach (it cannot be clicked or dismissed from here), so the check ends at the proof that it is up: the browser
        // window is disabled until it is answered. Nothing was deleted: the answer was never given, and the app ends with the test.
        XCTAssertTrue(((any("workspace-menu").title.isEmpty ? any("workspace-menu").label : any("workspace-menu").title)).contains("Dev"), "the workspace changed before the question was answered")
        app.terminate()
    }

    // MARK: G1

    /// Reorder two regular tabs: Bulk8 is dragged to the upper half of Bulk5's row.
    func testG1ReorderRegularTabs() throws {
        launchSidebar()
        let before = labels(rows())
        guard let src = entry("Page Bulk8"), let dst = entry("Page Bulk5") else { record("G1-reorder", "rows missing: \(before) tiles \(labels(tiles()))"); XCTFail("no Bulk8/Bulk5 rows"); return }
        let origin = win.frame.origin
        drag(src.frame, toY: dst.frame.minY + 4)
        let after = labels(rows())
        record("G1-reorder", "before \(before)\nafter  \(after)\nwindow moved \(Int(abs(win.frame.origin.x - origin.x) + abs(win.frame.origin.y - origin.y))) pt")
        attachShot("g1-reorder-after")
        let i8 = after.firstIndex { $0.hasPrefix("Page Bulk8") }, i5 = after.firstIndex { $0.hasPrefix("Page Bulk5") }
        XCTAssertNotNil(i8); XCTAssertNotNil(i5)
        if let i8, let i5 { XCTAssertLessThan(i8, i5, "dragging Bulk8 above Bulk5 did not reorder the sidebar list") }
    }

    /// A regular tab dragged onto the group's header joins the group.
    func testG1DragIntoGroup() throws {
        launchSidebar()
        guard let header = groupHeaderFrame(), let src = entry("Page Bulk8") else { record("G1-into-group", "header or Bulk8 missing"); XCTFail("group header or tab missing"); return }
        let before = groupHeaderLabel() ?? "-"
        drag(src.frame, toY: header.midY)
        let after = groupHeaderLabel() ?? "-"
        record("G1-into-group", "header before '\(before)' after '\(after)'; rows \(labels(rows()))")
        attachShot("g1-into-group-after")
        XCTAssertTrue(after.hasPrefix("Reading, 3 tabs"), "dragging a tab onto the group header did not add it (\(before) → \(after))")
    }

    /// Reorder inside the group: Bulk4 above Bulk3.
    func testG1ReorderWithinGroup() throws {
        launchSidebar()
        guard let a = entry("Page Bulk3"), let b = entry("Page Bulk4") else { record("G1-in-group", "group rows missing: \(labels(rows()))"); XCTFail("group rows missing"); return }
        let before = labels(rows())
        drag(b.frame, toY: a.frame.minY + 4)
        let after = labels(rows())
        record("G1-in-group", "before \(before)\nafter  \(after)")
        let i3 = after.firstIndex { $0.hasPrefix("Page Bulk3") }, i4 = after.firstIndex { $0.hasPrefix("Page Bulk4") }
        if let i3, let i4 { XCTAssertLessThan(i4, i3, "dragging Bulk4 above Bulk3 inside the group did not reorder it") } else { XCTFail("group rows disappeared") }
    }

    /// Pin and unpin: the context menu is the control (it must work), then the drag targets are observed: a regular tab onto the pinned tiles, and a pinned tile out to the list.
    func testG1PinAndUnpin() throws {
        launchSidebar()
        let startTiles = tiles().count
        guard let victim = entry("Page Bulk8") else { XCTFail("Bulk8 missing"); return }
        let menu = menuTitles(for: victim)
        record("G1-pin-menu", "Bulk8 menu: \(menu)")
        // Drag a regular tab onto the pinned tiles.
        if let tile = tiles().first, let src = entry("Page Bulk9") {
            drag(src.frame, toY: tile.frame.midY, toX: tile.frame.midX)
            record("G1-pin-by-drag", "tiles \(startTiles) → \(tiles().count); Bulk9 still a row: \(rows().contains { $0.label.hasPrefix("Page Bulk9") })")
            XCTAssertEqual(tiles().count, startTiles + 1, "dragging a tab onto the pinned tiles did not pin it")
        } else { XCTFail("no pinned tile or Bulk9 row") }
        // A pinned tile dragged down into the list.
        if let tile = tiles().first, let row = entry("Page Bulk5") {
            let before = tiles().count
            drag(tile.frame, toY: row.frame.midY, toX: row.frame.midX)
            record("G1-unpin-by-drag", "tiles \(before) → \(tiles().count)")
            XCTAssertEqual(tiles().count, before - 1, "dragging a pinned tile into the list did not unpin it")
        }
        attachShot("g1-pin-after")
    }

    private func pageName() -> String { win.descendants(matching: .webView).firstMatch.label }
    private func essentialTiles() -> [SnapItem] { snapItems().filter { $0.label.hasSuffix(", Essential") }.sorted { $0.frame.minX < $1.frame.minX } }

    /// Essentials: the two tiles have the same title (one site), so each is identified by the page it opens. The second is dropped on the first, which puts it first (a drop puts the dragged one in front of the target);
    /// then a regular tab is dropped on an Essential.
    func testG1EssentialsDrag() throws {
        launchSidebar(options: ["-UIEssentials", "2"])
        var tiles = essentialTiles()
        record("G1-essentials", "essentials \(tiles.map { "\($0.label)@\(Int($0.frame.minX - win.frame.minX)),\(Int($0.frame.minY - win.frame.minY))" })")
        guard tiles.count == 2 else { XCTFail("two Essentials expected, found \(tiles.count)"); return }
        func opens(_ i: Int) -> String { let t = essentialTiles()[i].frame; at(t.midX, t.midY).click(); settle(quiet: 0.25, timeout: 2) { pageName() }; return pageName() }
        let firstBefore = opens(0), secondBefore = opens(1)
        XCTAssertNotEqual(firstBefore, secondBefore, "the two Essentials open the same page, so their order cannot be told apart")
        tiles = essentialTiles()
        drag(tiles[1].frame, toY: tiles[0].frame.midY, toX: tiles[0].frame.minX + 6)
        let firstAfter = opens(0), secondAfter = opens(1)
        record("G1-essentials-reorder", "before first '\(firstBefore)' second '\(secondBefore)'; after first '\(firstAfter)' second '\(secondAfter)'")
        XCTAssertEqual(firstAfter, secondBefore, "dropping the second Essential on the first did not put it first")
        XCTAssertEqual(secondAfter, firstBefore)
        if let src = entry("Page Bulk9"), let target = essentialTiles().first {
            let n = essentialTiles().count
            drag(src.frame, toY: target.frame.midY, toX: target.frame.midX)
            record("G1-essentials-add", "Essentials \(n) → \(essentialTiles().count)")
            XCTAssertEqual(essentialTiles().count, n + 1, "dropping a tab on an Essential did not make it an Essential")
        }
    }

    // MARK: G3

    private func sidebarWidth() -> CGFloat? { any("sidebar").exists ? any("sidebar").frame.width : nil }

    func testG3WidthDefaultClampPersistenceAndReset() throws {
        let root = "bs-perf-width-\(UUID().uuidString.prefix(8))"
        launchSidebar(root: root)
        let initial = sidebarWidth() ?? 0
        record("G3-initial", "sidebar frame width \(initial)")
        // Resize: the grip is on the sidebar's inner edge.
        func resize(by dx: CGFloat) {
            let g = any("sidebar-resize-handle")
            guard g.exists else { XCTFail("no resize handle"); return }
            let f = g.frame
            at(f.midX, f.midY).hover(); settle(quiet: 0.1, timeout: 1) { signature() }
            at(f.midX, f.midY).click(forDuration: 0.2, thenDragTo: at(f.midX + dx, f.midY)); settle(quiet: 0.3) { "\(self.sidebarWidth() ?? 0)" }
        }
        resize(by: 400); let wide = sidebarWidth() ?? 0
        resize(by: -600); let narrow = sidebarWidth() ?? 0
        record("G3-clamp", "dragged far right → \(wide); far left → \(narrow) (range 190…340 plus the sidebar's own padding)")
        resize(by: 40 - (narrow - 250)); let chosen = sidebarWidth() ?? 0       // lands near a mid width
        record("G3-chosen", "width after a mid drag \(chosen)")
        app.terminate()
        launchSidebar(root: root)
        let kept = sidebarWidth() ?? 0
        record("G3-persist", "chosen \(chosen) → after relaunch with the same profile \(kept)")
        XCTAssertEqual(kept, chosen, accuracy: 3, "the chosen width was not kept")
        // Settings → Appearance → Reset Appearance and Layout. The chosen width was 290; the reset must bring back the standard 260 (it used to say 250), and the isolation proof checks that Settings wrote nothing outside the profile.
        XCTAssertGreaterThan(kept, 280, "the width to be reset was not 290 (\(kept))")
        app.typeKey(",", modifierFlags: .command)
        let settings = settingsWin
        XCTAssertTrue(settings.waitForExistence(timeout: 6), "Settings did not open")
        let appearance = settings.buttons["Appearance"].exists ? settings.buttons["Appearance"] : settings.toolbars.buttons["Appearance"]
        if appearance.exists { appearance.click(); settle(quiet: 0.3, timeout: 2) { "\(settings.buttons.count)" } }
        let reset = settings.descendants(matching: .button).matching(NSPredicate(format: "label == 'Reset Appearance and Layout' OR title == 'Reset Appearance and Layout'")).firstMatch
        guard reset.waitForExistence(timeout: 4) else { XCTFail("the Reset button was not reachable in Settings"); return }
        reset.click(); settle(quiet: 0.4, timeout: 3) { signature() }
        app.typeKey("w", modifierFlags: .command)
        // Reset also returns to the standard layout; the width it set is seen by going back to the Sidebar layout.
        app.typeKey("k", modifierFlags: .command)
        XCTAssertNotNil(until(8) { self.any("palette-field").exists }, "the palette did not open")
        paste("Layout: Sidebar"); app.typeKey(.return, modifierFlags: [])
        XCTAssertNotNil(until(8) { self.sidebarWidth() != nil }, "the Sidebar layout did not come back after the reset")
        settle(quiet: 0.4, timeout: 3) { signature() }
        let afterReset = sidebarWidth() ?? 0
        record("G3-reset", "width before the reset \(kept), after \(afterReset)")
        XCTAssertEqual(afterReset, 260, accuracy: 2, "Reset Appearance and Layout did not set the standard width")
    }

    // MARK: G4

    /// The window controls in each Sidebar mode: whether the close button is in the accessibility tree at rest, appears with the pointer in the top-left corner, and goes again. Observation only.
    private func lightsState() -> String {
        let close = win.buttons[XCUIIdentifierCloseWindow]
        return "close button exists \(close.exists) hittable \(close.exists && close.isHittable)"
    }
    private func observeLights(_ mode: String) {
        var out = ["rest: \(lightsState())"]
        at(win.frame.minX + 12, win.frame.minY + 12).hover(); settle(quiet: 0.3, timeout: 2) { lightsState() }
        out.append("pointer in the corner: \(lightsState())")
        win.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.7)).hover(); settle(quiet: 0.3, timeout: 2) { lightsState() }
        out.append("pointer away: \(lightsState())")
        record("G4-\(mode)", out.joined(separator: "; "))
        attachShot("g4-\(mode)")
    }
    func testG4WindowControlsInEveryMode() throws {
        launchSidebar(); observeLights("expanded"); app.terminate()
        launchSidebar(options: ["-UISidebarRail", "1"]); observeLights("rail"); app.terminate()
        launchSidebar(options: ["-UISidebarAutoHide", "1"]); observeLights("auto-hide-at-rest")
        win.coordinate(withNormalizedOffset: CGVector(dx: 0.002, dy: 0.5)).hover(); settle(quiet: 0.3, timeout: 2) { signature() }
        record("G4-edge-peek", "sidebar revealed \(any("sidebar").exists || any("workspace-menu").exists); \(lightsState())")
        attachShot("g4-edge-peek"); app.terminate()
        launchSidebar()
        func viaMenu(_ item: String) {
            win.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).hover()
            _ = app.menuBars.menuBarItems["View"].waitForExistence(timeout: 3)
            app.menuBars.menuBarItems["View"].click()
            let entry = app.menuBars.menuItems[item]
            if entry.waitForExistence(timeout: 3) { entry.click() } else { app.typeKey(.escape, modifierFlags: []) }
        }
        viaMenu("Enter Full Screen")
        let sw = NSScreen.main?.frame.width ?? 0
        if until(12, { self.win.exists && self.win.frame.width >= sw - 2 }) != nil {
            settle(quiet: 0.4, timeout: 4) { signature() }
            observeLights("fullscreen")
        } else { record("G4-fullscreen", "UNVERIFIED: the window did not enter full screen from the keyboard") }
        // Keyboard access to the same actions does not depend on the lights.
        let items = ["Close Window", "Minimize", "Zoom"].map { title in "\(title): \(app.menuBars.menuItems[title].exists)" }
        record("G4-menu-equivalents", items.joined(separator: ", "))
    }

    // MARK: Layout handle

    /// The window-controls pill is invisible at rest (the sidebar hidden, nothing else on screen), shows when the pointer is near the top, and goes again. While it is invisible it is out of the accessibility tree (a transparent view is); it is
    /// always shown when VoiceOver is running, so it stays findable for the people who need that.
    func testLayoutHandleFadesUntilThePointerIsNear() throws {
        launchSidebar(options: ["-UISidebarAutoHide", "1"])
        let handle = any("layout-handle")
        func away() { win.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.8)).hover(); settle(quiet: 0.4, timeout: 3) { signature() } }
        // Bring the pointer near the top centre, where the pill is, to learn its place.
        win.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 10)).hover()
        XCTAssertTrue(handle.waitForExistence(timeout: 5), "the layout handle did not appear with the pointer near the top")
        settle(quiet: 0.4, timeout: 3) { signature() }
        let frame = handle.frame
        func crop() -> Data? {
            guard let cg = win.safeScreenshot()?.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            let scale = CGFloat(cg.width) / win.frame.width
            let r = CGRect(x: (frame.minX - win.frame.minX) * scale, y: (frame.minY - win.frame.minY) * scale, width: frame.width * scale, height: frame.height * scale).insetBy(dx: -2, dy: -2)
            return cg.cropping(to: r)?.dataProvider?.data as Data?
        }
        let near = crop()
        attachShot("layout-handle-near")
        away()
        let atRest = crop()
        let hiddenFromAccessibility = !handle.exists
        at(frame.midX, frame.midY).hover(); settle(quiet: 0.4, timeout: 3) { signature() }
        let nearAgain = crop()
        away()
        let restAgain = crop()
        record("layout-handle", "frame \(Int(frame.minX - win.frame.minX)),\(Int(frame.minY - win.frame.minY)) \(Int(frame.width))x\(Int(frame.height)); rest==restAgain \(atRest == restAgain); rest==near \(atRest == near); near==nearAgain \(near == nearAgain); hidden from accessibility at rest \(hiddenFromAccessibility)")
        XCTAssertNotNil(atRest); XCTAssertNotNil(near)
        XCTAssertNotEqual(atRest, near, "the handle looks the same at rest and with the pointer near: it is not fading in")
        XCTAssertEqual(atRest, restAgain, "the handle did not fade out again after the pointer left")
        XCTAssertNotEqual(restAgain, nearAgain, "the handle did not show again when the pointer came back")
    }

    // MARK: Traffic lights and the first row of controls

    /// Measures (does not judge) whether the window's three buttons and the first row of controls share a horizontal line, in each layout: the centre of each button and of the controls beside it, in points from the window's top.
    func testTrafficLightsAlignWithTheControlRow() throws {
        let layouts: [(name: String, args: [String], state: String)] = [
            ("sidebar", ["-UILayout", "sidebar"], "bulk-tabs"), ("classic", ["-UILayout", "classic"], "bulk-tabs"), ("minimal", ["-UILayout", "minimal"], "bulk-tabs"),
            ("classicReversed", ["-UILayout", "classicReversed"], "bulk-tabs"), ("oneRow", ["-UILayout", "inline"], "bulk-tabs"),
        ]
        var lines: [String] = []
        for (name, args, state) in layouts {
            launch(state: state, extra: ["-UITabCount", "6"] + args, env: ["BS_WINDOW_SIZE": "1000x800"])
            guard until(30, { self.win.exists && abs(self.win.frame.width - 1000) < 6 && (self.any("omnibox").exists || self.any("sidebar-rail").exists) }) != nil else {
                lines.append("\(name): window not found (app windows: \(app.windows.count))"); app.terminate(); continue
            }
            settle(quiet: 0.3) { signature() }
            at(win.frame.minX + 12, win.frame.minY + 12).hover()      // shows the buttons in the layouts that hide them
            settle(quiet: 0.3, timeout: 2) { signature() }
            guard win.exists else { lines.append("\(name): window vanished after the pointer reached the corner"); app.terminate(); continue }
            let top = win.frame.minY
            func mid(_ e: XCUIElement) -> String { e.exists ? String(format: "%.1f", e.frame.midY - top) : "-" }
            let close = win.buttons[XCUIIdentifierCloseWindow], zoom = win.buttons[XCUIIdentifierFullScreenWindow]
            let controls = ["sidebar-button", "hide-sidebar", "back-button", "forward-button", "reload-button", "omnibox", "tab-chip"].map { "\($0) \(mid(self.any($0)))" }.joined(separator: ", ")
            let strip = any("tab-bar").exists ? "tab-bar \(mid(any("tab-bar")))" : ""
            lines.append("\(name): close mid \(mid(close)) (h \(close.exists ? Int(close.frame.height) : 0)), zoom mid \(mid(zoom)); \(controls) \(strip)")
            app.terminate()
        }
        record("traffic-light-alignment", lines.joined(separator: "\n"))
        lines.forEach { print("ALIGN " + $0) }
    }

    /// A tab put to sleep from its menu is announced as asleep (and drawn quieter); opening it wakes it. Crashed tabs end up in the same state (the page process ended), which cannot be provoked here: UNVERIFIED.
    func testG5SleepingTabIsAnnounced() throws {
        launchSidebar()
        guard let victim = entry("Page Bulk8") else { XCTFail("Bulk8 missing"); return }
        at(victim.frame.midX, victim.frame.midY).rightClick()
        settle(quiet: 0.2, timeout: 2) { "\(app.menuItems.count)" }
        let sleep = app.menuItems.matching(NSPredicate(format: "title == 'Put Tab to Sleep'")).allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(sleep, "no Put Tab to Sleep in the tab menu")
        sleep?.click()
        func value() -> String { (tabChips().allElementsBoundByIndex.first { $0.label.hasPrefix("Page Bulk8") }?.value as? String) ?? "" }
        XCTAssertNotNil(until(5) { value().contains("Asleep") }, "a tab put to sleep is not announced as asleep (value '\(value())')")
        record("G5-asleep", "Bulk8 value after Put Tab to Sleep: '\(value())'")
        attachShot("g5-asleep")
        guard let now = entry("Page Bulk8") else { XCTFail("Bulk8 missing after sleeping"); return }
        at(now.frame.midX, now.frame.midY).click()
        XCTAssertNotNil(until(6) { !value().contains("Asleep") }, "opening a sleeping tab did not wake it (value '\(value())')")
    }

    // MARK: G5 / G6

    /// What a row says about the tab it shows: label, value, selected trait, for the locked and the group tabs, and the states the fixture can produce.
    func testG5RowStatesAndLabels() throws {
        launchSidebar()
        let items = snapItems().filter { $0.id == "tab-chip" && $0.frame.minX - win.frame.minX < 400 }
        record("G5-rows", items.map { "\($0.label) | selected \($0.selected) | w \(Int($0.frame.width))" }.joined(separator: "\n"))
        guard let locked = entry("Page Bulk6") else { XCTFail("the locked tab's row is missing"); return }
        let el = tabChips().allElementsBoundByIndex.first { $0.label.hasPrefix("Page Bulk6") }
        let value = (el?.value as? String) ?? ""
        record("G5-locked", "label '\(locked.label)' value '\(value)' — the lock must be announced, not only drawn")
        XCTAssertTrue(locked.label.localizedCaseInsensitiveContains("lock") || value.localizedCaseInsensitiveContains("lock"), "a locked tab's row does not say it is locked (label '\(locked.label)', value '\(value)')")
        let selected = items.filter(\.selected)
        XCTAssertEqual(selected.count, 1, "exactly one row should be selected: \(selected.map(\.label))")
        // Loading, audio, muted, suspended and crashed rows need a page or a state the fixture does not produce.
        record("G5-unproduced", "UNVERIFIED at runtime: loading spinner, audio/mute badge, suspended, crashed (no fixture produces them here)")
    }

    /// Search: the panel's field has the keyboard, says what it searches, finds across the scope, shows where a result lives, keeps the selected tab reachable, and Escape returns to the list unchanged.
    func testG6SearchScopeSelectionAndKeyboard() throws {
        launchSidebar(options: ["-UIWorkspaces", "1"])
        let before = labels(rows()), selectedBefore = rows().first(where: \.selected)?.label ?? "-"
        any("search-tabs-button").click()
        XCTAssertNotNil(until(3) { self.any("tab-search-field").exists }, "the tab search field did not open")
        let field = any("tab-search-field")
        record("G6-field", "label '\(field.label)' placeholder '\(field.placeholderValue ?? "-")' keyboard focus \((field.value(forKey: "hasKeyboardFocus") as? Bool) ?? false)")
        paste("Bulk7"); pause(0.6)
        let results = snapItems().filter { $0.id == "tab-search-result" }
        record("G6-results", results.map { "\($0.id)|\($0.label)|\($0.type)" }.joined(separator: "\n"))
        XCTAssertEqual(results.count, 1, "searching Bulk7 should list one tab: \(results.map(\.label))")
        XCTAssertTrue(results.first?.label.hasPrefix("Page Bulk7") == true, "the result does not name the tab: \(results.first?.label ?? "none")")
        attachShot("g6-search-bulk7")
        // The selected tab (not Bulk7) is not in the results: record what the panel says about it.
        let texts = snapItems().filter { $0.frame.minX - win.frame.minX < 400 }.map(\.label).filter { !$0.isEmpty }
        record("G6-panel-text", texts.joined(separator: " / "))
        paste(""); app.typeKey("a", modifierFlags: .command); app.typeKey(.delete, modifierFlags: []); paste("zzzz-no-such"); settle(quiet: 0.2, timeout: 2) { signature() }
        let empty = snapItems().first { $0.id == "tab-search-empty" }
        XCTAssertNotNil(empty, "no empty-result message for a query that matches nothing")
        app.typeKey(.escape, modifierFlags: []); _ = until(2) { !self.any("tab-search-field").exists }
        XCTAssertFalse(any("tab-search-field").exists, "Escape did not close the search")
        XCTAssertEqual(labels(rows()), before, "the list changed after searching and escaping")
        XCTAssertEqual(rows().first(where: \.selected)?.label ?? "-", selectedBefore, "the selected tab changed after searching and escaping")
    }
}

// MARK: - Maximized window and full screen

/// The Sidebar layout in a maximized window (the Window menu's Zoom) and in full screen: the sidebar keeps its width, the page takes the rest, the footer is reachable, and nothing leaves the window. Four arrangements each:
/// docked left, docked right, rail, and hidden with edge reveal.
final class D2SidebarScreenSizesUITests: PerfCase {
    override func tearDown() { print(String(format: "PAUSE-BUDGET %@ asked %.1f s, waited %.1f s", name, PauseBudget.asked, PauseBudget.slept)); super.tearDown() }
    private let arrangements: [(name: String, options: [String])] = [
        ("left", []), ("right", ["-UISidebarPosition", "right"]), ("rail", ["-UISidebarRail", "1"]), ("hidden", ["-UISidebarAutoHide", "1"]),
    ]
    private func launchSidebar(_ options: [String]) {
        launch(state: "bulk-tabs", extra: ["-UITabCount", "12", "-UILayout", "sidebar", "-UIPinned", "2", "-UILocked", "1", "-UIGroups", "1"] + options, env: ["BS_WINDOW_SIZE": "1000x800"])
        let hiddenAtRest = options.contains("-UISidebarAutoHide")
        XCTAssertNotNil(until(30) { win.exists && abs(win.frame.width - 1000) < 6 && (hiddenAtRest ? win.descendants(matching: .webView).firstMatch.exists : (any("omnibox").exists || any("sidebar-rail").exists || tabChips().count > 0)) }, "the Sidebar layout did not come up")
        settle(quiet: 0.3) { signature() }
        app.typeKey(.escape, modifierFlags: [])
        win.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.7)).hover()
        settle(quiet: 0.15, timeout: 1.5) { signature() }
    }
    private func choose(_ menu: String, _ item: String) -> Bool {
        // The menu bar belongs to the front app, and right after another window left full screen (the app ended there) macOS is still closing that Space: ask again, bringing the app forward, until the menu bar is there.
        let bar = app.menuBars.menuBarItems[menu]
        var found = false
        for _ in 0..<12 {
            app.activate()
            win.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).hover()   // in full screen the menu bar shows when the pointer reaches the top edge
            if bar.waitForExistence(timeout: 1) { found = true; break }
        }
        guard found else { return false }
        bar.click()
        let entry = app.menuBars.menuItems[item]
        guard entry.waitForExistence(timeout: 3) else { app.typeKey(.escape, modifierFlags: []); return false }
        entry.click(); return true
    }
    private func page() -> CGRect? { let web = win.descendants(matching: .webView).firstMatch; return web.exists ? web.frame : nil }
    private func record(_ name: String, _ text: String) {
        report.note("\(name): \(text)")
        let a = XCTAttachment(string: text); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    /// What must hold in any window size.
    private func assertHealthy(_ label: String, arrangement: String) {
        let w = win.frame
        let items = snapItems()
        attachShot("d2-\(label)")
        guard let web = page() else { XCTFail("\(label): no page"); return }
        XCTAssertGreaterThanOrEqual(web.minX, w.minX - 1, "\(label): the page leaves the window on the left"); XCTAssertLessThanOrEqual(web.maxX, w.maxX + 1, "\(label): the page leaves the window on the right")
        XCTAssertGreaterThan(web.width, w.width * 0.55, "\(label): the page is squeezed to \(Int(web.width)) of \(Int(w.width))")
        if let side = items.first(where: { $0.id == "sidebar" })?.frame {
            XCTAssertLessThanOrEqual(side.width, 345, "\(label): the sidebar grew to \(Int(side.width)) with the window")
            XCTAssertGreaterThanOrEqual(side.minX, w.minX - 1); XCTAssertLessThanOrEqual(side.maxX, w.maxX + 1)
            if arrangement == "left" || arrangement == "right" { XCTAssertFalse(side.intersects(web.insetBy(dx: 3, dy: 3)), "\(label): the sidebar overlaps the page") }
            if arrangement == "left" { XCTAssertEqual(side.minX, w.minX, accuracy: 8) }
            if arrangement == "right" { XCTAssertEqual(side.maxX, w.maxX, accuracy: 8) }
        } else if arrangement == "left" || arrangement == "right" { XCTFail("\(label): no sidebar") }
        if arrangement == "rail", let rail = items.first(where: { $0.id == "sidebar-rail" })?.frame { XCTAssertLessThan(rail.width, 80, "\(label): the rail grew to \(Int(rail.width))") }
        if arrangement == "left" || arrangement == "right" {
            let footer = items.first { $0.id == "profile-button" }?.frame
            XCTAssertNotNil(footer, "\(label): the footer's profile button is missing")
            if let footer { XCTAssertTrue(footer.maxY <= w.maxY + 1 && footer.minY >= w.minY, "\(label): the footer is outside the window") }
        }
        let rows = items.filter { $0.id == "tab-chip" }
        if arrangement != "hidden" { XCTAssertFalse(rows.isEmpty, "\(label): no tab rows") }
        if let selected = rows.first(where: \.selected) { XCTAssertTrue(selected.frame.minY >= w.minY - 1 && selected.frame.maxY <= w.maxY + 1, "\(label): the selected tab is out of view") }
        record("d2-\(label)", "window \(Int(w.width))x\(Int(w.height)); sidebar \(items.first { $0.id == "sidebar" }.map { "\(Int($0.frame.width))" } ?? "-"); page \(Int(web.width))x\(Int(web.height)); rows \(rows.count)")
    }

    func testMaximizedWindow() throws {
        let visible = NSScreen.main?.visibleFrame ?? .zero
        for (name, options) in arrangements {
            launchSidebar(options)
            XCTAssertTrue(choose("Window", "Zoom"), "no Zoom item in the Window menu")
            XCTAssertNotNil(until(10) { self.win.exists && self.win.frame.width >= visible.width - 12 }, "\(name): the window did not fill the screen (\(Int(self.win.frame.width)) of \(Int(visible.width)))")
            settle(quiet: 0.35, timeout: 4) { signature() }
            if name == "hidden" {
                win.coordinate(withNormalizedOffset: CGVector(dx: 0.002, dy: 0.5)).hover()
                XCTAssertNotNil(until(5) { self.any("sidebar").exists || self.any("workspace-menu").exists }, "maximized: the edge did not reveal the sidebar")
                settle(quiet: 0.25, timeout: 2) { signature() }
            }
            assertHealthy("maximized-\(name)", arrangement: name == "hidden" ? "edge" : name)
            app.terminate()
        }
    }

    func testFullScreen() throws {
        let screenWidth = NSScreen.main?.frame.width ?? 0
        for (name, options) in arrangements {
            launchSidebar(options)
            // The window's own full-screen button (shown when the pointer is in the top-left corner): no menu bar involved, which cannot be asked reliably right after an app ended in full screen.
            win.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 12, dy: 12)).hover()
            let green = win.buttons[XCUIIdentifierFullScreenWindow]
            XCTAssertTrue(green.waitForExistence(timeout: 4), "\(name): no full-screen button at the window's corner")
            green.click()
            XCTAssertNotNil(until(12) { self.win.exists && self.win.frame.width >= screenWidth - 2 }, "\(name): the window did not enter full screen")
            settle(quiet: 0.4, timeout: 4) { signature() }
            if name == "hidden" {
                win.coordinate(withNormalizedOffset: CGVector(dx: 0.002, dy: 0.5)).hover()
                XCTAssertNotNil(until(5) { self.any("sidebar").exists || self.any("workspace-menu").exists }, "full screen: the edge did not reveal the sidebar")
                settle(quiet: 0.25, timeout: 2) { signature() }
            }
            assertHealthy("fullscreen-\(name)", arrangement: name == "hidden" ? "edge" : name)
            // In full screen the window's own buttons are not in the window, so nothing keeps room for them: the first control starts at the edge.
            if name == "left", let toggle = snapItems().first(where: { $0.id == "sidebar-toggle" || $0.id == "sidebar-pin" })?.frame {
                XCTAssertLessThan(toggle.minX - win.frame.minX, 40, "full screen: the sidebar button still keeps room for the window buttons (\(Int(toggle.minX - win.frame.minX)) pt)")
            }
            app.terminate()
        }
    }
}

// MARK: - H0: Hybrid baseline probes (the current Custom vertical-tabs + separate-toolbar arrangement)

/// H0 baseline for the Hybrid layout, measured on the arrangement that exists today: the Custom preset with vertical tabs and a separate toolbar. Nothing here changes what the app does, and no `.hybrid` preset is assumed.
///
/// Built to be quick: one throwaway profile is seeded once (the `custom-vertical-bar` state saves the layout choice), every probe launch reuses it with the tab fixtures, each launch does all of its measurements (geometry,
/// suggestions, rail, hide and show, workspace controls) with no fixed pauses, and the slower interaction probes (groups, drag and drop, full screen) run in one launch each. Results are printed as `H0 ...` lines (and attached),
/// so a run is read from its log. They are recorded with an assertion where the design contract states a rule, so a FAIL names the rule.
final class H0HybridBaselineUITests: PerfCase {
    override func tearDown() { print(String(format: "PAUSE-BUDGET %@ asked %.1f s, waited %.1f s", name, PauseBudget.asked, PauseBudget.slept)); super.tearDown() }

    /// One profile for the whole run, seeded with the vertical-tabs + separate-toolbar layout (its name matches what the launcher removes when it ends).
    nonisolated(unsafe) private static var root = "bs-perf-" + UUID().uuidString.prefix(8)
    nonisolated(unsafe) private static var seeded = false

    private func out(_ line: String) { print("H0 " + line); report.note("H0 " + line) }
    private func attach(_ name: String, _ text: String) { let a = XCTAttachment(string: text); a.name = name; a.lifetime = .keepAlways; add(a) }
    private func at(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate { win.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x - win.frame.minX, dy: y - win.frame.minY)) }
    private func rel(_ r: CGRect?) -> String { guard let r else { return "absent" }; let w = win.frame; return "x \(Int(r.minX - w.minX))–\(Int(r.maxX - w.minX)) y \(Int(r.minY - w.minY))–\(Int(r.maxY - w.minY)) (\(Int(r.width))×\(Int(r.height)))" }
    private func frame(_ id: String, _ items: [SnapItem]) -> CGRect? {
        let matches = items.filter { $0.id == id }
        // The sidebar's identifier can also sit on an outer wrapper that spans the window: the sidebar itself is the narrowest one.
        return (id == "sidebar" ? matches.filter { $0.frame.width > 40 }.min { $0.frame.width < $1.frame.width } : matches.first)?.frame
    }
    /// The three window buttons: where they are and whether the pointer can reach each (a hit target is not the same as a drawn frame).
    private func lightsReport() -> String {
        [("close", XCUIIdentifierCloseWindow), ("minimize", XCUIIdentifierMinimizeWindow), ("zoom", XCUIIdentifierFullScreenWindow)].map { name, id in
            let b = win.buttons[id]
            return b.exists ? "\(name) \(rel(b.frame)) hittable \(b.isHittable)" : "\(name) absent"
        }.joined(separator: "; ")
    }
    nonisolated(unsafe) private var offscreen = false
    /// A 1600 pt window starts at x 255 and does not fit a 1710 pt screen, so its far edge is out of reach. It is moved left by dragging empty chrome (the sidebar header beside its button); if it still does not fit, the click-based steps
    /// are reported as UNVERIFIED rather than skipped quietly.
    private func bringOnScreen() -> Bool {
        let screen = NSScreen.main?.frame ?? .zero
        guard win.frame.maxX > screen.maxX - 1 else { return true }
        let over = win.frame.maxX - screen.maxX + 8
        guard let side = frame("sidebar", snapItems()) else { return false }
        let x = side.midX + 40, y = win.frame.minY + 20
        at(x, y).hover(); settleQuick()
        at(x, y).click(forDuration: 0.3, thenDragTo: at(x - over, y))
        settle(quiet: 0.3, timeout: 2) { "\(self.win.frame)" }
        return win.frame.maxX <= screen.maxX
    }
    private func settleQuick() { settle(quiet: 0.12, timeout: 2) { signature() } }

    /// Launches the arrangement under test: Custom preset, vertical tabs, separate toolbar; 12 tabs, two pinned, one group ("Reading"), two workspaces, two Essentials.
    private func launchHybridLike(width: Int, sidebarRight: Bool = false, height: Int = 800, tabs: Int = 12, pinned: Int = 2, essentials: Int = 2) {
        // A fresh profile for every probe: the layout choice, sidebar side, rail state and restored tabs are all saved in it, so a shared one let one probe change the next one's starting state (the right-side probe left
        // later "left" probes on the right, and every launch restored the previous launch's tabs). It is seeded with the vertical-tabs layout, then launched again with the tab fixtures.
        let root = "bs-perf-" + UUID().uuidString.prefix(8)
        launch(state: "custom-vertical-bar", root: root, env: ["BS_WINDOW_SIZE": "1000x800"])
        _ = until(20) { self.win.exists && self.any("sidebar").exists }
        app.terminate()
        var args = ["-UITabCount", "\(tabs)", "-UILayout", "custom", "-UIPinned", "\(pinned)", "-UIGroups", "1", "-UIWorkspaces", "1", "-UIEssentials", "\(essentials)"]
        if sidebarRight { args += ["-UISidebarPosition", "right"] }
        launch(state: "bulk-tabs", root: root, extra: args, env: ["BS_WINDOW_SIZE": "\(width)x\(height)"])
        // The profile is shared by every probe and the sidebar's mode is saved in it, so each probe first puts the sidebar in a known state: docked and expanded (not as icons, not hidden).
        XCTAssertNotNil(until(12) { self.win.exists && abs(self.win.frame.width - CGFloat(width)) < 6 && self.any("omnibox").exists }, "the window did not come up at \(width)")
        if win.buttons["Expand Sidebar"].exists { win.buttons["Expand Sidebar"].click(); settle(quiet: 0.15, timeout: 2) { signature() } }
        if !any("sidebar").exists, !any("sidebar-rail").exists, any("sidebar-button").exists { any("sidebar-button").click(); settle(quiet: 0.15, timeout: 2) { signature() } }
        XCTAssertNotNil(until(8) { self.any("sidebar").exists }, "the vertical-tabs layout did not come up at \(width) (sidebar \(any("sidebar").exists), rail \(any("sidebar-rail").exists), omnibox \(any("omnibox").exists))")
        settle(quiet: 0.2) { signature() }
        offscreen = !bringOnScreen()
        if offscreen { out("OFFSCREEN: the \(width) pt window does not fit the screen (\(Int(NSScreen.main?.frame.width ?? 0)) pt): clicks on its far edge are UNVERIFIED") }
        app.typeKey(.escape, modifierFlags: [])
        win.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.7)).hover()
        settleQuick()
    }

    // MARK: Geometry (one launch per width and side)

    private func probe(width: Int, right: Bool) {
        let tag = "\(width)-\(right ? "right" : "left")"
        launchHybridLike(width: width, sidebarRight: right)
        addTeardownBlock { [self] in if win.exists, win.buttons["Expand Sidebar"].exists { win.buttons["Expand Sidebar"].click() } }
        var items = snapItems()
        let w = win.frame
        guard let side = frame("sidebar", items), let field = frame("omnibox", items) else { XCTFail("\(tag): sidebar or omnibox missing (\(presentIDs()))"); app.terminate(); return }
        let web = items.first { $0.type == UInt(XCUIElement.ElementType.webView.rawValue) }?.frame
        let lights = [XCUIIdentifierCloseWindow, XCUIIdentifierMinimizeWindow, XCUIIdentifierFullScreenWindow].compactMap { win.buttons[$0].exists ? win.buttons[$0].frame : nil }
        let lightsBox = lights.reduce(CGRect.null) { $0.union($1) }
        let toolbarControls = ["sidebar-button", "back-button", "forward-button", "reload-button", "new-tab-button", "more-menu"].compactMap { id in frame(id, items).map { (id, $0) } }
        out("GEOMETRY \(tag): window \(Int(w.width))×\(Int(w.height)); sidebar \(rel(side)); omnibox \(rel(field)); page \(rel(web)); lights \(rel(lights.isEmpty ? nil : lightsBox)); toolbar \(toolbarControls.map { "\($0.0) \(rel($0.1))" }.joined(separator: "; "))")
        out("LIGHTS \(tag) docked: \(lightsReport())")
        attachShot("h0-\(tag)")
        XCTAssertFalse(any("sidebar-button").exists, "\(tag): the toolbar still has its own sidebar button although the sidebar carries one (two sidebar icons)")
        // Contract: the sidebar is full height beside the page, the toolbar belongs to the page column, the page keeps room, the lights are clear of every control.
        XCTAssertGreaterThanOrEqual(side.height, w.height - 10, "\(tag): the sidebar is not full height (\(Int(side.height)) of \(Int(w.height)))")
        let columnMin = right ? w.minX : side.maxX, columnMax = right ? side.minX : w.maxX
        XCTAssertGreaterThanOrEqual(field.minX, columnMin - 1, "\(tag): the omnibox leaves its column on the sidebar side"); XCTAssertLessThanOrEqual(field.maxX, columnMax + 1, "\(tag): the omnibox leaves its column")
        if let web { XCTAssertGreaterThan(web.width, 200, "\(tag): the page is squeezed to \(Int(web.width))") }
        if !lights.isEmpty {
            for (id, r) in toolbarControls { XCTAssertFalse(r.intersects(lightsBox), "\(tag): the traffic lights overlap \(id)") }
            for it in items where it.frame.intersects(lightsBox) && ["hide-sidebar", "pin-sidebar", "back-button", "reload-button"].contains(it.id) { XCTFail("\(tag): the traffic lights overlap \(it.id)") }
        }
        // Omnibox suggestions sit under the real field.
        app.typeKey("l", modifierFlags: .command); paste("swift browser")
        if until(4, { self.any("suggestions").exists }) != nil {
            settleQuick()
            items = snapItems()
            if let sug = frame("suggestions", items), let f = frame("omnibox", items) {
                out("SUGGESTIONS \(tag): field \(rel(f)); list \(rel(sug))")
                attachShot("h0-suggestions-\(tag)")
                XCTAssertGreaterThanOrEqual(sug.minY, f.maxY - 1, "\(tag): the suggestions overlap the field"); XCTAssertLessThan(sug.minY - f.maxY, 30, "\(tag): the suggestions are far from the field")
                XCTAssertGreaterThanOrEqual(sug.minX, columnMin - 1, "\(tag): the suggestions leave the page column"); XCTAssertLessThanOrEqual(sug.maxX, columnMax + 1, "\(tag): the suggestions leave the page column")
            }
        } else { out("SUGGESTIONS \(tag): none appeared") ; XCTFail("\(tag): no suggestions appeared") }
        app.typeKey(.escape, modifierFlags: []); settleQuick()
        // Rail: the sidebar as icons, and whether it clears the window buttons.
        // "Collapse to Icons" now lives in the sidebar's "…" menu (identifier sidebar-options); open it and choose the item.
        let options = any("sidebar-options")
        let collapse = app.menuItems["Collapse to Icons"]
        if offscreen && !options.isHittable { out("RAIL \(tag): UNVERIFIED (the sidebar options menu is off screen)") }
        else if options.exists {
            options.click()
            guard collapse.waitForExistence(timeout: 3) else { XCTFail("\(tag): the sidebar options menu has no Collapse to Icons item"); return }
            collapse.click(); settle(quiet: 0.15, timeout: 2) { signature() }
            XCTAssertNotNil(until(3) { self.any("sidebar-rail").exists }, "\(tag): choosing Collapse to Icons did not produce the rail")
            items = snapItems()
            let rail = frame("sidebar-rail", items)
            let first = ["sidebar-button", "back-button"].compactMap { frame($0, items) }.min { $0.minX < $1.minX }
            out("RAIL \(tag): rail \(rel(rail)); first toolbar control \(rel(first)); lights \(rel(lights.isEmpty ? nil : lightsBox))")
            XCTAssertFalse(any("sidebar-button").exists, "\(tag): in rail mode the toolbar still has its own sidebar button (the rail has one)")
            _ = rail
            if let first, !lights.isEmpty { XCTAssertFalse(first.intersects(lightsBox), "\(tag): in rail mode the toolbar's first control overlaps the window buttons") }
            out("LIGHTS \(tag) rail: \(lightsReport())")
            attachShot("h0-rail-\(tag)")
            let expand = win.buttons["Expand Sidebar"]
            if expand.waitForExistence(timeout: 3) { expand.click(); settle(quiet: 0.15, timeout: 2) { signature() } }
            XCTAssertNotNil(until(3) { self.any("sidebar").exists && !self.any("sidebar-rail").exists }, "\(tag): the rail did not expand again (Expand Sidebar \(expand.exists))")
        } else { out("RAIL \(tag): no sidebar options menu") ; XCTFail("\(tag): no sidebar options menu in the sidebar") }
        // Hide and show: hidden from the View menu; with it hidden the toolbar must offer the way back, and use it.
        app.menuBars.menuBarItems["View"].click()
        let menuToggle = app.menuBars.menuItems["Toggle Sidebar"]
        if menuToggle.waitForExistence(timeout: 2) {
            menuToggle.click()
            // The menu item sits at the window's left edge, which is where an explicitly hidden sidebar is revealed from: the pointer is moved into the page, and the reveal is allowed to end, before anything is measured.
            win.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.7)).hover()
            settle(quiet: 0.4, timeout: 3) { signature() }
            let hidden = snapItems()
            let page = hidden.first { $0.type == UInt(XCUIElement.ElementType.webView.rawValue) }?.frame
            out("HIDE \(tag): sidebar \(rel(frame("sidebar", hidden))); omnibox \(rel(frame("omnibox", hidden))); page \(rel(page)); toolbar sidebar button \(rel(frame("sidebar-button", hidden))); first toolbar control \(rel(["sidebar-button", "back-button"].compactMap { frame($0, hidden) }.min { $0.minX < $1.minX })); lights \(rel(lights.isEmpty ? nil : lightsBox))")
            attachShot("h0-hidden-\(tag)")
            XCTAssertNotNil(frame("sidebar-button", hidden), "\(tag): with the sidebar hidden the toolbar has no button to bring it back")
            if let first = ["sidebar-button", "back-button"].compactMap({ frame($0, hidden) }).min(by: { $0.minX < $1.minX }), !lights.isEmpty { XCTAssertFalse(first.intersects(lightsBox), "\(tag): with the sidebar hidden the toolbar's first control overlaps the window buttons") }
            // Showing it again from the toolbar's button, sampled over time: is the toolbar slow to settle, or does it stay over the sidebar?
            if let button = Optional(any("sidebar-button")), button.exists, button.isHittable {
                button.click()
                let t0 = Date(); var samples: [String] = []; var last: [SnapItem] = []
                for delay in [0.1, 0.5, 1.5, 3.0] {
                    while Date().timeIntervalSince(t0) < delay { Thread.sleep(forTimeInterval: 0.02) }
                    last = snapItems()
                    samples.append("t+\(delay): sidebar \(rel(frame("sidebar", last))); back \(rel(frame("back-button", last))); omnibox \(rel(frame("omnibox", last)))")
                }
                out("SHOW-TIMELINE \(tag): \(samples.joined(separator: " | "))")
                attachShot("h0-shown-again-\(tag)")
                if let sidebar = frame("sidebar", last), let back = frame("back-button", last) {
                    // The toolbar belongs to the page column: its first control must clear the sidebar once the layout has settled.
                    if right { XCTAssertLessThanOrEqual(back.maxX, sidebar.minX + 1, "\(tag): after showing the sidebar again the toolbar is still over it (\(rel(back)) vs sidebar \(rel(sidebar)))") }
                    else { XCTAssertGreaterThanOrEqual(back.minX, sidebar.maxX - 1, "\(tag): after showing the sidebar again the toolbar is still over it (back \(rel(back)), sidebar \(rel(sidebar)))") }
                } else { XCTFail("\(tag): the sidebar did not come back after the toolbar's button (\(presentIDs()))") }
            } else { out("HIDE \(tag): the toolbar's sidebar button is not reachable (UNVERIFIED)") }
        } else { out("HIDE \(tag): no Toggle Sidebar in the View menu"); app.typeKey(.escape, modifierFlags: []) }
        // Workspace controls: where each is, to see whether the toolbar and the sidebar both offer one (H3).
        items = snapItems()
        let workspace = items.filter { $0.id == "workspace-menu" || $0.label.hasPrefix("Workspace") }
        out("WORKSPACE \(tag): \(workspace.map { "\($0.id.isEmpty ? "-" : $0.id)|\($0.label)|\(rel($0.frame))|in \($0.frame.intersects(side) ? "sidebar" : "toolbar")" })")
        XCTAssertTrue(workspace.filter { !$0.frame.intersects(side) }.isEmpty, "\(tag): the toolbar repeats the workspace switcher the sidebar already has")
        app.terminate()
    }

    func testBaseline520Left() throws { probe(width: 520, right: false) }
    func testBaseline520Right() throws { probe(width: 520, right: true) }
    func testBaseline1000Left() throws { probe(width: 1000, right: false) }
    func testBaseline1000Right() throws { probe(width: 1000, right: true) }
    func testBaseline1600Left() throws { probe(width: 1600, right: false) }
    func testBaseline1600Right() throws { probe(width: 1600, right: true) }

    /// Isolates the hide/show result: no rail step first. Hide from the View menu, park the pointer in the page, press the toolbar's restore button, and report whether the sidebar comes back expanded or as the rail.
    func testHideThenShowWithoutAnyRailStep() throws {
        launchHybridLike(width: 1000)
        func state(_ label: String) -> String {
            let it = snapItems()
            return "\(label): sidebar \(rel(frame("sidebar", it))); rail \(rel(frame("sidebar-rail", it))); expandButton \(it.contains { $0.id == "Expand Sidebar" }); back \(rel(frame("back-button", it))); page \(rel(it.first { $0.type == UInt(XCUIElement.ElementType.webView.rawValue) }?.frame))"
        }
        out("HS " + state("start"))
        app.menuBars.menuBarItems["View"].click()
        let item = app.menuBars.menuItems["Toggle Sidebar"]
        XCTAssertTrue(item.waitForExistence(timeout: 3), "no Toggle Sidebar item"); item.click()
        win.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.7)).hover()
        settle(quiet: 0.4, timeout: 3) { signature() }
        out("HS " + state("hidden"))
        let button = any("sidebar-button")
        XCTAssertTrue(button.waitForExistence(timeout: 3), "no toolbar button to bring the sidebar back")
        button.click()
        settle(quiet: 0.5, timeout: 3) { signature() }
        out("HS " + state("after the toolbar button"))
        attachShot("h0-hide-show-no-rail")
        XCTAssertFalse(snapItems().contains { $0.id == "Expand Sidebar" }, "the sidebar came back as the icon rail without the rail ever being chosen")
        XCTAssertNotNil(frame("sidebar", snapItems()), "the expanded sidebar did not come back")
    }

    // MARK: Interactions (one launch)

    private func selectedLabel() -> String { chipSnapshots().first(where: { $0.selected })?.label ?? "none" }
    private func rowLabels() -> [String] { snapItems().filter { $0.id == "tab-chip" && $0.frame.width > 100 }.sorted { $0.frame.minY < $1.frame.minY }.map(\.label) }
    private func rowFrame(_ title: String) -> CGRect? { snapItems().first { $0.id == "tab-chip" && $0.label.hasPrefix(title) }?.frame }
    private func drag(_ from: CGRect, toY: CGFloat, toX: CGFloat? = nil) {
        at(from.midX, from.midY).hover(); settle(quiet: 0.12, timeout: 1) { signature() }
        at(from.midX, from.midY).click(forDuration: 0.5, thenDragTo: at(toX ?? from.midX, toY))
        settle(quiet: 0.3) { signature() }
    }

    // MARK: Real web pages

    /// The sidebar's whole list scrolls (Essentials and pinned tiles included), and it follows the selected tab down; a person scrolls back up to reach them.
    private func sidebarToTop() {
        any("sidebar").scroll(byDeltaX: 0, deltaY: 6000); settle(quiet: 0.2, timeout: 1.5) { signature() }
    }
    private func essentialLabels() -> [String] { snapItems().filter { $0.label.hasSuffix(", Essential") }.map(\.label) }
    private func activeRowTitle() -> String { snapItems().first { $0.id == "tab-chip" && $0.selected }?.label ?? "-" }
    /// Opens `address` in a new tab, through the real address field (⌘T, ⌘L, type, Return), and waits for the page to give the tab a title.
    private func openReal(_ address: String, titleContains: String) -> Bool {
        app.typeKey("t", modifierFlags: .command); settleQuick()
        app.typeKey("l", modifierFlags: .command)
        app.typeText(address); app.typeKey(.return, modifierFlags: [])
        return until(25) { self.snapItems().contains { $0.id == "tab-chip" && $0.label.localizedCaseInsensitiveContains(titleContains) } } != nil
    }
    private func chooseFromMenu(of frame: CGRect, _ title: String) -> Bool {
        at(frame.midX, frame.midY).rightClick()
        let item = app.menuItems[title]
        guard item.waitForExistence(timeout: 3) else { app.typeKey(.escape, modifierFlags: []); return false }
        item.click(); settle(quiet: 0.3, timeout: 2) { signature() }
        return true
    }

    /// Real pages in the Hybrid arrangement: open three, pin one, make one an Essential, then try the behaviours the contract lists. Observations are printed as H0 REAL lines.
    func testRealPagesPinEssentialsAndBehaviours() throws {
        continueAfterFailure = true
        launchHybridLike(width: 1000)
        let essentialsBefore = essentialLabels()
        out("REAL start: essentials \(essentialsBefore); rows \(rowLabels().count)")
        let pages = [("https://example.com", "Example Domain"), ("https://en.wikipedia.org/wiki/Web_browser", "Web browser"), ("https://www.mozilla.org", "Mozilla")]
        var opened: [String] = []
        for (url, title) in pages {
            let ok = openReal(url, titleContains: title)
            out("REAL open \(url): \(ok ? "title appeared" : "NO TITLE within 25 s (network or page)")")
            if ok { opened.append(title) }
        }
        attachShot("h0-real-opened")
        guard opened.count >= 2 else { XCTFail("fewer than two real pages loaded (\(opened)); the network may be unavailable"); app.terminate(); return }

        // Pin the first real page from its row's menu: it leaves the open-tab list and becomes a tile.
        if let row = rowFrame(opened[0]) {
            let rowsBefore = rowLabels().count
            XCTAssertTrue(chooseFromMenu(of: row, "Pin Tab"), "no Pin Tab item in the row's menu")
            out("REAL pin \(opened[0]): open rows \(rowsBefore) → \(rowLabels().count); still a row: \(rowFrame(opened[0]) != nil)")
            XCTAssertEqual(rowLabels().count, rowsBefore - 1, "pinning did not move the page out of the open list")
            XCTAssertNil(rowFrame(opened[0]), "the pinned page still has an open-tab row")
            attachShot("h0-real-pinned")
        } else { XCTFail("no row for \(opened[0])") }

        // Make the second real page an Essential.
        if let row = rowFrame(opened[1]) {
            XCTAssertTrue(chooseFromMenu(of: row, "Add to Essentials"), "no Add to Essentials item in the row's menu")
            let now = essentialLabels()
            out("REAL essential \(opened[1]): essentials \(essentialsBefore.count) → \(now.count): \(now)")
            XCTAssertEqual(now.count, essentialsBefore.count + 1, "adding to Essentials did not add exactly one tile")
            XCTAssertTrue(now.contains { $0.localizedCaseInsensitiveContains(opened[1]) || $0.localizedCaseInsensitiveContains("wikipedia") }, "the new Essential is not the page that was added")
            attachShot("h0-real-essential")
        } else { XCTFail("no row for \(opened[1])") }

        // Behaviours. Click an Essential: it is selected. Click a pinned tile: selected. Both without a reload visible as a new tab.
        let tabsBefore = rowLabels().count
        if let tile = snapItems().first(where: { $0.label.hasSuffix(", Essential") && $0.label.localizedCaseInsensitiveContains(opened[1]) })?.frame {
            at(tile.midX, tile.midY).click(); settle(quiet: 0.3, timeout: 3) { signature() }
            out("REAL click essential: selected tile \(snapItems().contains { $0.label.hasSuffix(", Essential") && $0.selected }); rows \(tabsBefore) → \(rowLabels().count)")
            XCTAssertEqual(rowLabels().count, tabsBefore, "clicking an Essential opened a duplicate tab")
        } else { out("REAL click essential: tile not found"); XCTFail("the new Essential's tile is missing") }
        if let pinnedTile = snapItems().first(where: { $0.label.hasPrefix(opened[0]) && $0.id != "tab-chip" })?.frame {
            at(pinnedTile.midX, pinnedTile.midY).click(); settle(quiet: 0.3, timeout: 3) { signature() }
            out("REAL click pinned: active row/tile now \(activeRowTitle())")
        }
        // The Essentials stay when the workspace changes (they belong to the profile).
        let essentialsHere = essentialLabels().count
        if let menu = snapItems().first(where: { $0.id == "workspace-menu" })?.frame {
            at(menu.midX, menu.midY).click()
            let other = app.menuItems.matching(NSPredicate(format: "title != 'Personal' AND title != 'New Workspace…' AND title != 'Rename…' AND title != 'Delete'")).firstMatch
            if other.waitForExistence(timeout: 2), other.isHittable { let name = other.title; other.click(); settle(quiet: 0.4, timeout: 3) { signature() }
                out("REAL workspace → \(name): essentials \(essentialsHere) → \(essentialLabels().count); rows \(rowLabels().count)")
                XCTAssertEqual(essentialLabels().count, essentialsHere, "Essentials changed when the workspace changed") }
            else { app.typeKey(.escape, modifierFlags: []); out("REAL workspace: no other workspace item") }
        }
        attachShot("h0-real-end")
        app.terminate()
    }

    /// Zooms the window to the largest size the screen allows (the Window menu's Zoom, not full screen) and prints what it got.
    private func maximizeWindow() {
        let screen = NSScreen.main?.visibleFrame ?? .zero
        app.activate()
        app.menuBars.menuBarItems["Window"].click()
        let zoom = app.menuBars.menuItems["Zoom"]
        guard zoom.waitForExistence(timeout: 3) else { XCTFail("no Zoom item in the Window menu"); return }
        zoom.click()
        let reached = until(8) { self.win.exists && self.win.frame.width >= screen.width - 30 && self.win.frame.height >= screen.height - 30 }
        settle(quiet: 0.4, timeout: 3) { signature() }
        let f = win.frame
        out("MAX window \(Int(f.width))×\(Int(f.height)) of visible screen \(Int(screen.width))×\(Int(screen.height)); full screen \(f.width >= (NSScreen.main?.frame.width ?? 0) - 2 && f.height >= (NSScreen.main?.frame.height ?? 0) - 2)")
        XCTAssertNotNil(reached, "Zoom did not enlarge the window to the screen's visible area")
    }

    /// Closing with the × and reordering by drag, on plain fixture tabs and a maximized window, with the × and the rows measured and printed so a miss can be told from a failure.
    func testCloseAndReorderMaximized() throws {
        continueAfterFailure = true
        launchHybridLike(width: 1000)
        maximizeWindow()
        sidebarToTop()
        let start = rowLabels()
        out("CR rows \(start)")
        // Close: select a plain tab (its × shows at rest), measure the row and click the × where it is drawn.
        guard let target = rowFrame("Page Bulk9") else { XCTFail("no Page Bulk9 row: \(start)"); app.terminate(); return }
        at(target.midX, target.midY).click(); settle(quiet: 0.2, timeout: 1.5) { signature() }
        let row = rowFrame("Page Bulk9") ?? target
        let xButton = snapItems().first { $0.label == "Close tab" || $0.label == "Close Tab" }
        out("CR close: row \(rel(row)); × element \(rel(xButton?.frame)); selected \(activeRowTitle())")
        attachShot("cr-before-close")
        let n = rowLabels().count
        let clickAt = xButton?.frame ?? CGRect(x: row.maxX - 30, y: row.minY, width: 24, height: row.height)
        at(clickAt.midX, clickAt.midY).click(); settle(quiet: 0.35, timeout: 2) { signature() }
        out("CR close result: rows \(n) → \(rowLabels().count); Bulk9 still listed \(rowFrame("Page Bulk9") != nil)")
        attachShot("cr-after-close")
        XCTAssertEqual(rowLabels().count, n - 1, "the × did not close the tab")
        XCTAssertNil(rowFrame("Page Bulk9"), "Page Bulk9 is still listed after its × was clicked")
        // Reorder: drag Bulk11 above Bulk6 (both plain open rows).
        if let a = rowFrame("Page Bulk11"), let b = rowFrame("Page Bulk6") {
            let before = rowLabels().filter { $0.hasPrefix("Page Bulk") }
            drag(a, toY: b.minY + 4)
            let after = rowLabels().filter { $0.hasPrefix("Page Bulk") }
            out("CR reorder: \(before) → \(after)")
            attachShot("cr-after-reorder")
            let i11 = after.firstIndex { $0.hasPrefix("Page Bulk11") }, i6 = after.firstIndex { $0.hasPrefix("Page Bulk6") }
            XCTAssertTrue((i11 ?? 99) < (i6 ?? 0), "dragging Bulk11 above Bulk6 did not reorder the list")
        } else { XCTFail("Bulk11 or Bulk6 row missing: \(rowLabels())") }
        app.terminate()
    }

    // MARK: Scrolling structure (shared with the Sidebar layout)

    /// Scrolls the main tab list (pinned, open tabs, groups) by scrolling over one of its rows.
    private func scrollMain(_ dy: CGFloat) {
        // A row that is really on screen (the list is long: the first row in the tree can be far above the visible part).
        let w = win.frame
        guard let item = snapItems().first(where: { $0.id == "tab-chip" && $0.frame.width > 100 && $0.frame.minY > w.minY + 150 && $0.frame.maxY < w.maxY - 60 }) else { out("SCROLL: no on-screen row to scroll over"); return }
        let hittable = app.descendants(matching: .any).matching(identifier: "tab-chip").allElementsBoundByIndex.first { $0.frame.equalTo(item.frame) }
        hittable?.scroll(byDeltaX: 0, deltaY: dy); settle(quiet: 0.25, timeout: 2) { signature() }
    }
    private func fixedParts() -> [String: CGRect] {
        let items = snapItems()
        var r: [String: CGRect] = [:]
        if let f = frame("workspace-menu", items) { r["workspace"] = f }
        if let f = frame("search-tabs-button", items) { r["search"] = f }
        if let f = frame("essentials-block", items) { r["essentials"] = f }
        return r
    }

    /// The approved shared scrolling structure, in a maximized window with 12 Essentials, 8 pinned tabs and 120 tabs: the workspace selector, search and Essentials stay put while the list scrolls; pinned tiles scroll away with the tabs.
    func testSharedScrollingStructureMaximized() throws {
        continueAfterFailure = true
        launchHybridLike(width: 1000, tabs: 120, pinned: 8, essentials: 12)
        maximizeWindow()
        sidebarToTop()
        let top = fixedParts()
        out("SCROLL top: \(top.mapValues { rel($0) })")
        attachShot("scroll-top")
        for key in ["workspace", "search", "essentials"] { XCTAssertNotNil(top[key], "\(key) is missing at the top") }
        if let e = top["essentials"] { XCTAssertLessThanOrEqual(e.height, 150, "the Essentials block is taller than two rows plus its label (\(Int(e.height)) pt)") }
        let pinnedBefore = snapItems().contains { $0.label == "Page Bulk0" }
        let selectedBefore = activeRowTitle()
        scrollMain(-1500)
        let scrolled = fixedParts()
        out("SCROLL after wheel: \(scrolled.mapValues { rel($0) }); pinned tile 'Page Bulk0' visible before \(pinnedBefore), after \(snapItems().contains { $0.label == "Page Bulk0" && $0.frame.minY > (top["search"]?.maxY ?? 0) && $0.frame.maxY < win.frame.maxY })")
        attachShot("scroll-after-wheel")
        for key in ["workspace", "search", "essentials"] {
            if let a = top[key], let b = scrolled[key] { XCTAssertEqual(a.minY, b.minY, accuracy: 1, "\(key) moved while the tab list scrolled") }
            else { XCTFail("\(key) disappeared while the tab list scrolled") }
        }
        XCTAssertEqual(activeRowTitle(), selectedBefore, "scrolling changed the selected tab")
        // Pinned tiles scroll with the tabs: after scrolling far down they are not in the visible list area.
        let listTop = (scrolled["essentials"] ?? scrolled["search"] ?? .zero).maxY
        let pinnedStillShown = snapItems().contains { $0.label == "Page Bulk0" && $0.frame.minY >= listTop && $0.frame.maxY <= win.frame.maxY }
        XCTAssertFalse(pinnedStillShown, "a pinned tile stayed in view while the tabs scrolled (it should scroll with them)")
        // All twelve Essentials can be reached: the block scrolls inside itself and nothing else moves.
        let tilesTop = snapItems().filter { $0.label.hasSuffix(", Essential") }.count
        any("essentials-block").scroll(byDeltaX: 0, deltaY: -600); settle(quiet: 0.25, timeout: 1.5) { signature() }
        let block = fixedParts()["essentials"] ?? .zero
        let tiles = snapItems().filter { $0.label.hasSuffix(", Essential") }
        let lastTile = tiles.max { $0.frame.maxY < $1.frame.maxY }?.frame
        let inside = tiles.filter { $0.frame.minY >= block.minY - 1 && $0.frame.maxY <= block.maxY + 1 }.count
        out("SCROLL essentials: tiles in tree at top \(tilesTop), at bottom \(tiles.count); inside the block after scrolling to its end \(inside); last tile \(rel(lastTile)); block \(rel(block))")
        XCTAssertEqual(tiles.count, 12, "the Essentials block does not hold all 12 tiles")
        if let lastTile { XCTAssertLessThanOrEqual(lastTile.maxY, block.maxY + 1, "the last Essential is not reachable (it is below the block even after scrolling to its end)") }
        XCTAssertGreaterThanOrEqual(inside, 5, "scrolling the Essentials to their end did not bring a full row into the block")
        let afterEss = fixedParts()
        if let a = scrolled["workspace"], let b = afterEss["workspace"] { XCTAssertEqual(a.minY, b.minY, accuracy: 1) }
        attachShot("scroll-essentials-bottom")
        // Back to the top and disclose the group: the selection must not change.
        scrollMain(3000)
        let before = activeRowTitle()
        if let group = snapItems().first(where: { $0.label.hasPrefix("Reading") })?.frame {
            at(group.midX, group.midY).click(); settle(quiet: 0.25, timeout: 2) { signature() }
            XCTAssertEqual(activeRowTitle(), before, "disclosing a group changed the selected tab")
            out("SCROLL group disclosure: selection '\(before)' → '\(activeRowTitle())'")
        } else { out("SCROLL group header not in view (UNVERIFIED)") }
        app.terminate()
    }

    /// The same structure in a short window: the Essentials take one row and the tab list keeps room.
    func testSharedScrollingShortWindow() throws {
        continueAfterFailure = true
        launchHybridLike(width: 1000, height: 500, tabs: 120, pinned: 8, essentials: 12)
        sidebarToTop()
        let parts = fixedParts()
        let list = snapItems().filter { $0.id == "tab-chip" && $0.frame.width > 100 && $0.frame.minY >= win.frame.minY && $0.frame.maxY <= win.frame.maxY }
        let footerTop = snapItems().filter { $0.frame.maxY > win.frame.maxY - 80 && $0.frame.width > 20 && $0.frame.minY > win.frame.midY }.map(\.frame.minY).min() ?? win.frame.maxY
        out("SHORT window \(Int(win.frame.width))×\(Int(win.frame.height)): \(parts.mapValues { rel($0) }); tab rows visible \(list.count)")
        attachShot("scroll-short")
        for key in ["workspace", "search", "essentials"] { XCTAssertNotNil(parts[key], "\(key) is missing in the short window") }
        if let e = parts["essentials"] { XCTAssertLessThanOrEqual(e.height, 50, "the Essentials block takes more than one row in a short window (\(Int(e.height)) pt)") }
        XCTAssertGreaterThanOrEqual(list.count, 4, "fewer than four tab rows are on screen in the short window (footer top \(Int(footerTop)))")
        let selectedBefore = activeRowTitle()
        scrollMain(-800)
        let after = fixedParts()
        for key in ["workspace", "search", "essentials"] { if let a = parts[key], let b = after[key] { XCTAssertEqual(a.minY, b.minY, accuracy: 1, "\(key) moved in the short window") } }
        XCTAssertEqual(activeRowTitle(), selectedBefore)
        app.terminate()
    }

    // MARK: Full screen keeps each layout's chrome (shared policy)

    /// Enters native full screen (View > Enter Full Screen) with the pointer resting on the page, and checks what is on screen at rest: the address field and the tabs, inside the
    /// screen, not overlapping each other or the sidebar. Then ⌘L and typing reach the field, and leaving full screen gives back the window with the same tabs and selection.
    private func fullScreenCheck(_ tag: String, expectTabs: Bool = true, expectField: Bool = true) {
        let windowBefore = win.frame
        let rowsBefore = snapItems().filter { $0.id == "tab-chip" }.count
        let selectedBefore = activeRowTitle()
        app.activate()
        app.menuBars.menuBarItems["View"].click()
        let enter = app.menuBars.menuItems["Enter Full Screen"]
        guard enter.waitForExistence(timeout: 3) else { XCTFail("\(tag): no Enter Full Screen item"); return }
        enter.click()
        let screen = NSScreen.main?.frame ?? .zero
        // On a screen with a camera housing, full screen stops below it, so only the width is a reliable sign.
        XCTAssertNotNil(until(12) { self.win.exists && self.win.frame.width >= screen.width - 2 }, "\(tag): the window did not enter full screen")
        // The pointer rests on the middle of the page, away from the top edge (where macOS would show its menu bar).
        at(win.frame.midX + 100, win.frame.midY).hover()
        settle(quiet: 0.6, timeout: 4) { signature() }
        Thread.sleep(forTimeInterval: 1.2)   // longer than any reveal's linger: what is shown now is what stays
        let items = snapItems(), w = win.frame
        let field = frame("omnibox", items)
        let chips = items.filter { $0.id == "tab-chip" && $0.frame.minY >= w.minY && $0.frame.maxY <= w.maxY && $0.frame.minX >= w.minX && $0.frame.maxX <= w.maxX }
        let side = frame("sidebar", items)
        out("FS \(tag): window \(Int(w.width))×\(Int(w.height)); field \(rel(field)); tabs on screen \(chips.count); sidebar \(rel(side)); selected '\(activeRowTitle())'")
        attachShot("fs-\(tag)")
        if expectField {
            XCTAssertNotNil(field, "\(tag): the address field is not on screen at rest in full screen")
            if let field { XCTAssertTrue(w.contains(field), "\(tag): the address field is outside the screen") }
        }
        if expectTabs { XCTAssertGreaterThan(chips.count, 0, "\(tag): no tab is on screen at rest in full screen") }
        // (The Sidebar layout's field is inside its sidebar by design.)
        if tag != "sidebar", let field, let side, side.width < w.width / 2 { XCTAssertFalse(field.intersects(side), "\(tag): the address field overlaps the sidebar") }
        // ⌘L reaches the field.
        if expectField {
            app.typeKey("l", modifierFlags: .command)
            app.typeText("fullscreen check")
            settle(quiet: 0.3, timeout: 2) { signature() }
            let typed = (any("omnibox").value as? String) ?? ""
            let list = frame("suggestions", snapItems())
            let fieldNow = frame("omnibox", snapItems())
            out("FS \(tag): after ⌘L and typing, field '\(typed.prefix(40))'; suggestions \(rel(list)) under field \(rel(fieldNow))")
            if let list, let fieldNow {
                XCTAssertGreaterThanOrEqual(list.minY, fieldNow.maxY - 1, "\(tag): the suggestions overlap the field")
                XCTAssertLessThan(abs(list.midX - fieldNow.midX), 40, "\(tag): the suggestions are not under the field (centres \(Int(list.midX)) vs \(Int(fieldNow.midX)))")
            }
            XCTAssertTrue(typed.contains("fullscreen check"), "\(tag): ⌘L did not put the typing in the address field ('\(typed)')")
            app.typeKey(.escape, modifierFlags: []); app.typeKey(.escape, modifierFlags: [])
            settle(quiet: 0.2, timeout: 1.5) { signature() }
        }
        // Leave full screen: the window, the tabs and the selection come back as they were.
        // Escape leaves full screen, as in Safari (nothing else is open by now). ⌃⌘F is the second way, tried only if Escape did nothing.
        func gone(_ seconds: TimeInterval) -> Bool { until(seconds, { self.win.exists && self.win.frame.width < screen.width - 2 }) != nil }
        let leaveStart = Date()
        app.typeKey(.escape, modifierFlags: [])
        if !gone(6) {
            out("FS \(tag): Escape did not leave full screen after 6 s; trying ⌃⌘F")
            XCTFail("\(tag): Escape did not leave full screen")
            app.typeKey("f", modifierFlags: [.control, .command])
            out("FS \(tag): ⌃⌘F then \(gone(8) ? "left" : "did not leave") full screen (\(String(format: "%.1f", Date().timeIntervalSince(leaveStart))) s since Escape)")
        }
        if win.exists && win.frame.width >= screen.width - 2 {
            out("FS \(tag): ⌃⌘F did not leave full screen; using View > Exit Full Screen from the menu bar")
            XCTFail("\(tag): ⌃⌘F did not leave full screen")
            at(win.frame.midX, win.frame.minY + 1).hover(); Thread.sleep(forTimeInterval: 1.2)
            app.menuBars.menuBarItems["View"].click()
            let exit = app.menuBars.menuItems["Exit Full Screen"]
            if exit.waitForExistence(timeout: 3) { exit.click() }
        }
        XCTAssertNotNil(until(12) { self.win.exists && self.win.frame.width < screen.width - 2 }, "\(tag): the window did not leave full screen")
        settle(quiet: 0.5, timeout: 4) { signature() }
        let after = win.frame
        out("FS \(tag) exit: window \(Int(windowBefore.width))×\(Int(windowBefore.height)) → \(Int(after.width))×\(Int(after.height)); tabs \(rowsBefore) → \(snapItems().filter { $0.id == "tab-chip" }.count); selected '\(selectedBefore)' → '\(activeRowTitle())'")
        XCTAssertEqual(after.width, windowBefore.width, accuracy: 4, "\(tag): the window size did not come back")
        XCTAssertEqual(after.height, windowBefore.height, accuracy: 4, "\(tag): the window size did not come back")
        if selectedBefore != "-" { XCTAssertEqual(activeRowTitle(), selectedBefore, "\(tag): the selected tab changed across full screen") }
    }
    private func launchPreset(_ layout: String, tabs: Int = 6, extra: [String] = []) {
        launch(state: "bulk-tabs", extra: ["-UITabCount", "\(tabs)", "-UILayout", layout] + extra, env: ["BS_WINDOW_SIZE": "1000x800"])
        let marks = ["omnibox", "sidebar", "floating-search-button", "pill-handle", "canvas-handle", "workspace-deck"]
        XCTAssertNotNil(until(30) { self.win.exists && abs(self.win.frame.width - 1000) < 6 && (marks.contains { self.any($0).exists } || self.win.webViews.count > 0) }, "\(layout) did not come up at 1000 pt")
        settle(quiet: 0.4, timeout: 3) { signature() }
    }

    func testFullScreenClassic() throws { continueAfterFailure = true; launchPreset("classic"); fullScreenCheck("classic"); app.terminate() }
    func testFullScreenMinimal() throws { continueAfterFailure = true; launchPreset("minimal"); fullScreenCheck("minimal"); app.terminate() }
    func testFullScreenOneRow() throws { continueAfterFailure = true; launchPreset("inline"); fullScreenCheck("one-row"); app.terminate() }
    func testFullScreenClassicReversed() throws { continueAfterFailure = true; launchPreset("classicReversed"); fullScreenCheck("classic-reversed"); app.terminate() }
    func testFullScreenMinimalReversed() throws { continueAfterFailure = true; launchPreset("minimalReversed"); fullScreenCheck("minimal-reversed"); app.terminate() }
    func testFullScreenSidebarLayout() throws { continueAfterFailure = true; launchPreset("sidebar"); fullScreenCheck("sidebar"); app.terminate() }
    /// Floating keeps its immersive pill: only recorded, not held to the toolbar rule.
    func testFullScreenFloating() throws { continueAfterFailure = true; launchPreset("floating"); fullScreenCheck("floating", expectTabs: false, expectField: false); app.terminate() }
    func testFullScreenHybridLeft() throws { continueAfterFailure = true; launchHybridLike(width: 1000); fullScreenCheck("hybrid-left"); app.terminate() }
    func testFullScreenHybridRight() throws { continueAfterFailure = true; launchHybridLike(width: 1000, sidebarRight: true); fullScreenCheck("hybrid-right"); app.terminate() }
    func testFullScreenHybridRail() throws {
        continueAfterFailure = true
        launchHybridLike(width: 1000)
        any("sidebar-options").click()
        let collapse = app.menuItems["Collapse to Icons"].firstMatch
        if collapse.waitForExistence(timeout: 3) { collapse.click() }
        XCTAssertNotNil(until(3) { self.any("sidebar-rail").exists }, "the rail did not appear")
        fullScreenCheck("hybrid-rail")
        app.terminate()
    }
    func testFullScreenHybridHidden() throws {
        continueAfterFailure = true
        launchHybridLike(width: 1000)
        any("hide-sidebar").click()
        XCTAssertNotNil(until(3) { !self.any("sidebar").exists || (self.frame("sidebar", self.snapItems())?.width ?? 0) < 40 }, "the sidebar did not hide")
        fullScreenCheck("hybrid-hidden", expectTabs: false)
        app.terminate()
    }

    // MARK: The four layouts added from the design pack (Hybrid, Canvas, Research Desk, Workspace Deck), in a maximized window

    /// Hybrid as its own preset: the docked tab navigator, the full toolbar above the page column, one address field (not in the sidebar), one sidebar button;
    /// hiding the sidebar brings the toolbar's sidebar button back, and showing it again docks it.
    func testLayoutHybridPreset() throws {
        continueAfterFailure = true
        launchPreset("hybrid")
        maximizeWindow()
        let items = snapItems()
        let side = frame("sidebar", items), field = frame("omnibox", items)
        out("NEW hybrid: sidebar \(rel(side)); field \(rel(field)); fields \(items.filter { $0.id == "omnibox" }.count); toolbar sidebar button \(any("sidebar-button").exists); sidebar toggle \(any("hide-sidebar").exists)")
        attachShot("new-hybrid")
        XCTAssertNotNil(side, "Hybrid: no sidebar"); XCTAssertNotNil(field, "Hybrid: no address field")
        if let side, let field { XCTAssertFalse(side.intersects(field), "Hybrid: the address field is in or over the sidebar") }
        XCTAssertEqual(items.filter { $0.id == "omnibox" }.count, 1, "Hybrid: more than one address field")
        XCTAssertFalse(any("sidebar-button").exists, "Hybrid: two sidebar buttons (toolbar and sidebar)")
        XCTAssertGreaterThan(items.filter { $0.id == "tab-chip" }.count, 0, "Hybrid: no tab rows")
        any("hide-sidebar").click()
        XCTAssertNotNil(until(3) { (self.frame("sidebar", self.snapItems())?.width ?? 0) < 40 || !self.any("sidebar").exists }, "Hybrid: the sidebar did not hide")
        XCTAssertTrue(any("sidebar-button").waitForExistence(timeout: 2), "Hybrid: with the sidebar hidden the toolbar has no way to bring it back")
        any("sidebar-button").click()
        XCTAssertNotNil(until(3) { (self.frame("sidebar", self.snapItems())?.width ?? 0) > 150 }, "Hybrid: the sidebar did not come back")
        app.terminate()
    }

    /// Canvas: nothing but the page and a faint handle at rest (no toolbar, no tab strip, no sidebar, no pill); ⌘L brings an address field that takes typing; ⇧⌘A
    /// shows the open tabs; the handle's menu leaves Canvas for the layout it came from, with the same tabs.
    /// Floating: the tabs can be brought out without a pointer (View menu), stay while the pointer is elsewhere, and the pill has a visible More menu.
    func testFloatingTabsRevealWithoutPointer() throws {
        continueAfterFailure = true
        launchPreset("floating")
        maximizeWindow()
        at(win.frame.midX, win.frame.midY).hover(); settleQuick()
        func tabRowsOnScreen() -> Int { snapItems().filter { $0.id == "tab-chip" && win.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }.count }
        XCTAssertTrue(any("pill-more").exists, "Floating: the pill has no visible More menu")
        XCTAssertEqual(tabRowsOnScreen(), 0, "Floating: tabs are on screen at rest")
        app.menuBars.menuBarItems["View"].click()
        let reveal = app.menuItems["Show Tabs at the Edge"]
        XCTAssertTrue(reveal.waitForExistence(timeout: 3), "Floating: View menu has no Show Tabs at the Edge")
        reveal.click(); Thread.sleep(forTimeInterval: 0.8)
        XCTAssertGreaterThan(tabRowsOnScreen(), 0, "Floating: Show Tabs at the Edge showed no tabs")
        // No pointer near the edge, and they are still there a moment later.
        at(win.frame.midX, win.frame.midY).hover(); Thread.sleep(forTimeInterval: 0.8)
        XCTAssertGreaterThan(tabRowsOnScreen(), 0, "Floating: the keyboard-opened tabs went away on their own")
        attachShot("new-floating-keyboard-tabs")
        app.terminate()
    }

    /// Canvas: what a sidebar would show is on demand from the handle's menu: commands, pinned tabs, groups, workspaces, and the way back.
    func testCanvasHandleMenuHasWhatTheSidebarWould() throws {
        continueAfterFailure = true
        launch(state: "bulk-tabs", extra: ["-UITabCount", "6", "-UILayout", "canvas", "-UIPinned", "2", "-UIGroups", "1", "-UIWorkspaces", "1"], env: ["BS_WINDOW_SIZE": "1000x800"])
        XCTAssertNotNil(until(30) { self.win.exists && self.any("canvas-handle").exists }, "Canvas did not come up")
        settle(quiet: 0.4, timeout: 3) { signature() }
        any("canvas-handle").click()
        for title in ["Open Address…", "Show Open Tabs", "Search Commands…", "Pinned", "Groups", "Workspaces", "Leave Canvas", "Restore Standard Layout"] {
            XCTAssertTrue(app.menuItems[title].waitForExistence(timeout: 2), "Canvas handle menu has no “\(title)”")
        }
        app.typeKey(.escape, modifierFlags: [])
        app.terminate()
    }

    func testLayoutCanvas() throws {
        continueAfterFailure = true
        launchPreset("canvas")
        maximizeWindow()
        at(win.frame.midX, win.frame.midY).hover(); settleQuick()
        let rest = snapItems()
        let visibleChips = rest.filter { $0.id == "tab-chip" && win.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
        out("NEW canvas rest: handle \(rel(frame("canvas-handle", rest))); field \(rel(frame("omnibox", rest))); sidebar \(rel(frame("sidebar", rest))); pill \(rel(frame("floating-search-button", rest))); tab rows on screen \(visibleChips.count)")
        attachShot("new-canvas-rest")
        XCTAssertNotNil(frame("canvas-handle", rest), "Canvas: no handle (nothing to recover with a mouse)")
        XCTAssertNil(frame("omnibox", rest), "Canvas: an address field is on screen at rest")
        XCTAssertTrue(visibleChips.isEmpty, "Canvas: tabs are on screen at rest")
        XCTAssertNil(frame("floating-search-button", rest), "Canvas: Floating's pill is on screen")
        // The edge does not slide a sidebar in.
        at(win.frame.minX + 2, win.frame.midY).hover(); Thread.sleep(forTimeInterval: 0.6)
        XCTAssertFalse(snapItems().contains { $0.id == "tab-chip" && win.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }, "Canvas: the window edge revealed a sidebar")
        at(win.frame.midX, win.frame.midY).hover()
        // ⌘L
        app.typeKey("l", modifierFlags: .command); app.typeText("canvas check"); settleQuick()
        let field = any("floating-address-bar")
        let typed = ((any("omnibox").value as? String) ?? "") + ((field.value as? String) ?? "")
        out("NEW canvas ⌘L: address bar \(field.exists); typed '\(typed.prefix(30))'")
        XCTAssertTrue(field.exists || typed.contains("canvas check"), "Canvas: ⌘L did not bring an address field")
        app.typeKey(.escape, modifierFlags: []); app.typeKey(.escape, modifierFlags: []); settleQuick()
        // ⇧⌘A: the open tabs
        app.typeKey("a", modifierFlags: [.command, .shift]); settle(quiet: 0.3, timeout: 2) { signature() }
        let overview = any("overview-options").exists
        out("NEW canvas ⇧⌘A: overview shown \(overview)")
        attachShot("new-canvas-tabs")
        XCTAssertTrue(overview, "Canvas: ⇧⌘A did not show the open tabs")
        app.typeKey(.escape, modifierFlags: []); settleQuick()
        // Leave Canvas from the handle
        any("canvas-handle").click()
        let leave = app.menuItems["Leave Canvas"]
        XCTAssertTrue(leave.waitForExistence(timeout: 3), "Canvas: the handle has no Leave Canvas")
        leave.click(); settle(quiet: 0.4, timeout: 3) { signature() }
        let after = snapItems()
        out("NEW canvas leave: field \(rel(frame("omnibox", after))); tab rows \(after.filter { $0.id == "tab-chip" }.count); handle gone \(!any("canvas-handle").exists)")
        XCTAssertNotNil(frame("omnibox", after), "leaving Canvas did not bring a toolbar back")
        XCTAssertGreaterThan(after.filter { $0.id == "tab-chip" }.count, 0, "leaving Canvas did not bring the tabs back")
        app.terminate()
    }

    /// Research Desk: the tabs as a compact rail, the full toolbar, two pages side by side; clicking the other page makes it the focused one and the toolbar follows it.
    func testLayoutResearchDesk() throws {
        continueAfterFailure = true
        launchPreset("researchDesk")
        maximizeWindow()
        let items = snapItems()
        let webs = items.filter { $0.type == UInt(XCUIElement.ElementType.webView.rawValue) && $0.frame.width > 200 }.sorted { $0.frame.minX < $1.frame.minX }
        out("NEW desk: rail \(rel(frame("sidebar-rail", items))); field \(rel(frame("omnibox", items))); pages \(webs.map { rel($0.frame) })")
        attachShot("new-research-desk")
        XCTAssertNotNil(frame("sidebar-rail", items), "Research Desk: the tabs are not a compact rail")
        XCTAssertNotNil(frame("omnibox", items), "Research Desk: no toolbar address field")
        XCTAssertGreaterThanOrEqual(webs.count, 2, "Research Desk: not two pages side by side")
        guard webs.count >= 2 else { app.terminate(); return }
        // The two pages share a host, so the focused one is told by the selected tab in the rail rather than by the host the field shows.
        let before = activeRowTitle()
        at(webs[1].frame.midX, webs[1].frame.midY).click(); settle(quiet: 0.4, timeout: 3) { signature() }
        let after = activeRowTitle()
        out("NEW desk focus: address '\(before.prefix(50))' → '\(after.prefix(50))'")
        XCTAssertNotEqual(before, after, "Research Desk: clicking the other page did not move the toolbar to it")
        // The rail expands and collapses with the existing control.
        let expand = win.buttons["Expand Sidebar"]
        if expand.exists { expand.click(); XCTAssertNotNil(until(3) { self.any("sidebar").exists && !self.any("sidebar-rail").exists }, "Research Desk: the rail did not expand") }
        app.terminate()
    }

    /// Research Desk: the keyboard moves the focus between panels, a panel can be closed without its tab, and a narrow window stacks the panels instead of squeezing them.
    func testResearchDeskPanelControls() throws {
        continueAfterFailure = true
        launchPreset("researchDesk")
        maximizeWindow()
        let headers = { self.snapItems().filter { $0.id == "research-panel-header" } }
        XCTAssertGreaterThanOrEqual(headers().count, 2, "Research Desk: panels have no headers")
        let before = activeRowTitle()
        app.typeKey("]", modifierFlags: [.control, .command]); settle(quiet: 0.4, timeout: 3) { signature() }
        let after = activeRowTitle()
        out("NEW desk ⌃⌘]: '\(before.prefix(40))' → '\(after.prefix(40))'")
        XCTAssertNotEqual(before, after, "Research Desk: Focus Next Panel (⌃⌘]) did not move the focus")
        let tabsBefore = snapItems().filter { $0.id == "tab-chip" || $0.id == "rail-tab" }.count
        any("panel-close").firstMatch.click(); settle(quiet: 0.4, timeout: 3) { signature() }
        XCTAssertLessThan(headers().count, 2, "Research Desk: closing a panel did not take it out of the split")
        let tabsAfter = snapItems().filter { $0.id == "tab-chip" || $0.id == "rail-tab" }.count
        XCTAssertEqual(tabsBefore, tabsAfter, "Research Desk: closing a panel closed its tab")
        app.terminate()
        // A narrow window: one page at a time, with a switcher for the other (neither page is squeezed).
        launch(state: "bulk-tabs", extra: ["-UITabCount", "4", "-UILayout", "researchDesk"], env: ["BS_WINDOW_SIZE": "560x760"])
        XCTAssertNotNil(until(30) { self.win.exists && self.win.frame.width < 700 && self.win.webViews.count > 0 }, "narrow Research Desk did not come up")
        settle(quiet: 0.5, timeout: 4) { signature() }
        let pages = snapItems().filter { $0.type == UInt(XCUIElement.ElementType.webView.rawValue) && $0.frame.width > 150 }
        out("NEW desk narrow: pages \(pages.map { rel($0.frame) }); switcher \(any("pane-switcher").exists)")
        XCTAssertEqual(pages.count, 1, "narrow Research Desk: expected one page on its own")
        XCTAssertTrue(any("pane-switcher").exists, "narrow Research Desk: no switcher for the other page")
        if let page = pages.first { XCTAssertGreaterThan(page.frame.width, 300, "narrow Research Desk: the page is squeezed") }
        let beforeTitle = activeRowTitle()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Page 2 of'")).firstMatch.click(); settle(quiet: 0.4, timeout: 3) { signature() }
        XCTAssertNotEqual(beforeTitle, activeRowTitle(), "narrow Research Desk: the switcher did not change the page")
        app.terminate()
    }

    /// Workspace Deck: the overview names the workspace, the profile has its own labelled row, and with many workspaces a search field narrows the list.
    func testWorkspaceDeckOverviewProfileAndFilter() throws {
        continueAfterFailure = true
        launchPreset("workspaceDeck", tabs: 6, extra: ["-UIWorkspaces", "12"])
        maximizeWindow()
        XCTAssertTrue(any("deck-profile").exists, "Workspace Deck: no labelled Profile row")
        XCTAssertTrue(any("workspace-filter").exists, "Workspace Deck: no search field with many workspaces")
        any("workspace-filter").click(); app.typeText("zzzz-none"); settleQuick()
        let rowsAfter = snapItems().filter { $0.id == "workspace-deck" }
        out("NEW deck filter: list \(rowsAfter.count)")
        app.typeKey("a", modifierFlags: .command); app.typeKey(.delete, modifierFlags: []); settleQuick()
        any("workspace-overview").click(); settle(quiet: 0.3, timeout: 3) { signature() }
        let title = any("overview-title")
        XCTAssertTrue(title.waitForExistence(timeout: 3), "Workspace Deck: the overview has no workspace title")
        out("NEW deck overview title: '\((title.value as? String) ?? title.label)'")
        XCTAssertTrue(title.label.hasPrefix("Overview of"), "Workspace Deck: overview title reads '\(title.label)'")
        app.typeKey(.escape, modifierFlags: []); settleQuick()
        app.terminate()
    }

    /// Workspace Deck in the narrowest window (520 pt) with 32 workspaces: the list stays capped and scrolls, tab search and the tabs keep their room, and a private tab is
    /// marked (spoken as Private) in the list.
    func testWorkspaceDeckNarrowWithManyWorkspacesAndAPrivateTab() throws {
        continueAfterFailure = true
        launch(state: "bulk-tabs", extra: ["-UITabCount", "6", "-UILayout", "workspaceDeck", "-UIWorkspaces", "32"], env: ["BS_WINDOW_SIZE": "520x720"])
        XCTAssertNotNil(until(30) { self.win.exists && self.win.frame.width < 600 && self.any("workspace-deck").exists }, "the Deck did not come up at 520 pt")
        settle(quiet: 0.5, timeout: 4) { signature() }
        let items = snapItems()
        let deck = frame("workspace-deck", items)
        let sidebar = frame("sidebar", items)
        out("NEW deck 520: window \(Int(win.frame.width))×\(Int(win.frame.height)); deck list \(rel(deck)); sidebar \(rel(sidebar)); filter \(any("workspace-filter").exists)")
        if let deck { XCTAssertLessThan(deck.height, 330, "32 workspaces: the list is not capped (\(Int(deck.height)) pt)") }
        if let sidebar { XCTAssertLessThanOrEqual(sidebar.width, win.frame.width * 0.45, "the sidebar takes too much of a 520 pt window") }
        XCTAssertTrue(any("workspace-filter").exists, "32 workspaces: no search field")
        let rows = items.filter { $0.id == "tab-chip" && win.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
        XCTAssertGreaterThan(rows.count, 0, "32 workspaces: no tab is left on screen")
        // A private tab, from the File menu: its row says Private.
        app.menuBars.menuBarItems["File"].click()
        let item = app.menuItems["New Private Tab"]
        XCTAssertTrue(item.waitForExistence(timeout: 3), "no New Private Tab in the File menu")
        item.click(); settle(quiet: 0.5, timeout: 4) { signature() }
        let privateRows = app.descendants(matching: .any).matching(NSPredicate(format: "value CONTAINS 'Private'")).count
        out("NEW deck 520 private: elements spoken as Private \(privateRows)")
        XCTAssertGreaterThan(privateRows, 0, "a private tab is not marked in the Deck's list")
        app.terminate()
    }

    /// Workspace Deck: every workspace listed at the top of the sidebar, the toolbar's address field above the page; choosing another workspace switches to it
    /// (its row becomes the selected one) and the tab list follows; Personal is listed by name.
    func testLayoutWorkspaceDeck() throws {
        continueAfterFailure = true
        launchPreset("workspaceDeck", tabs: 8, extra: ["-UIWorkspaces", "1"])
        maximizeWindow()
        let items = snapItems()
        let deck = frame("workspace-deck", items)
        let rows = items.filter { item in item.frame.width > 150 && (deck?.contains(CGPoint(x: item.frame.midX, y: item.frame.midY)) ?? false) && item.type == UInt(XCUIElement.ElementType.button.rawValue) }
        out("NEW deck: list \(rel(deck)); rows \(rows.map(\.label)); field \(rel(frame("omnibox", items))); compact selector \(any("workspace-menu").exists)")
        attachShot("new-workspace-deck")
        XCTAssertNotNil(deck, "Workspace Deck: no workspace list")
        XCTAssertTrue(rows.contains { $0.label.hasPrefix("Personal") }, "Workspace Deck: Personal is not listed by name")
        XCTAssertGreaterThanOrEqual(rows.count, 2, "Workspace Deck: fewer than two workspaces listed")
        XCTAssertFalse(any("workspace-menu").exists, "Workspace Deck: the compact selector is shown as well")
        XCTAssertNotNil(frame("omnibox", items), "Workspace Deck: no toolbar address field")
        let tabsBefore = rowLabels()
        if let other = rows.first(where: { !$0.selected && !$0.label.hasPrefix("Overview") }) {
            at(other.frame.midX, other.frame.midY).click(); settle(quiet: 0.4, timeout: 3) { signature() }
            let name = other.label.components(separatedBy: ",").first ?? other.label
            let now = snapItems().first { $0.label.hasPrefix(name + ",") && $0.type == UInt(XCUIElement.ElementType.button.rawValue) }
            out("NEW deck switch to '\(other.label)': selected \(now?.selected ?? false); tabs \(tabsBefore.count) → \(rowLabels().count)")
            XCTAssertEqual(now?.selected, true, "Workspace Deck: the chosen workspace is not shown as selected")
            XCTAssertNotEqual(rowLabels(), tabsBefore, "Workspace Deck: the tab list did not follow the workspace")
        } else { XCTFail("Workspace Deck: no other workspace row to choose") }
        app.terminate()
    }

    /// MAC-HYBRID-WORKSPACE-SWITCH (doc 13): in the Hybrid preset the workspace selector (sidebar, top) switches to another workspace; that workspace's tabs are listed (the other's are not), the toolbar and its address field stay put, and nothing is closed.
    func testMacHybridWorkspaceSwitch() throws {
        continueAfterFailure = true
        launchPreset("hybrid", tabs: 8, extra: ["-UIWorkspaces", "1"])
        maximizeWindow()
        let fieldBefore = frame("omnibox", snapItems())
        let tabsBefore = rowLabels()
        any("workspace-menu").click()
        let dev = app.menuItems["Dev"].firstMatch
        XCTAssertTrue(dev.waitForExistence(timeout: 3), "the workspace menu has no Dev")
        dev.click(); settle(quiet: 0.4, timeout: 3) { signature() }
        attachShot("MAC-HYBRID-WORKSPACE-SWITCH")
        let tabsAfter = rowLabels()
        out("HYB workspace switch: tabs \(tabsBefore.count) → \(tabsAfter.count); field \(rel(fieldBefore)) → \(rel(frame("omnibox", snapItems())))")
        XCTAssertTrue(tabsAfter.allSatisfy { !$0.hasPrefix("Page Bulk") }, "Personal's tabs are still listed in Dev: \(tabsAfter)")
        if let a = fieldBefore, let b = frame("omnibox", snapItems()) { XCTAssertEqual(a.minX, b.minX, accuracy: 2, "the toolbar's address field moved when the workspace changed") }
        any("workspace-menu").click()
        let personal = app.menuItems["Personal"].firstMatch
        XCTAssertTrue(personal.waitForExistence(timeout: 3)); personal.click(); settle(quiet: 0.4, timeout: 3) { signature() }
        XCTAssertEqual(rowLabels().count, tabsBefore.count, "going back to Personal did not bring its tabs back")
    }

    func testFullScreenCanvas() throws { continueAfterFailure = true; launchPreset("canvas"); fullScreenCheck("canvas", expectTabs: false, expectField: false); app.terminate() }
    func testFullScreenResearchDesk() throws { continueAfterFailure = true; launchPreset("researchDesk"); fullScreenCheck("research-desk"); app.terminate() }
    func testFullScreenWorkspaceDeck() throws { continueAfterFailure = true; launchPreset("workspaceDeck", extra: ["-UIWorkspaces", "1"]); fullScreenCheck("workspace-deck"); app.terminate() }
    /// ⌃⌘F, the system shortcut, leaves full screen in the Hybrid layout (Escape is the other way, tested above).
    func testHybridLeavesFullScreenWithControlCommandF() throws {
        continueAfterFailure = true
        launchPreset("hybrid")
        let screen = NSScreen.main?.frame ?? .zero
        app.activate()
        app.menuBars.menuBarItems["View"].click()
        let enter = app.menuBars.menuItems["Enter Full Screen"]
        guard enter.waitForExistence(timeout: 3) else { XCTFail("no Enter Full Screen item"); return }
        enter.click()
        XCTAssertNotNil(until(12) { self.win.exists && self.win.frame.width >= screen.width - 2 }, "the window did not enter full screen")
        at(win.frame.midX + 100, win.frame.midY).hover()
        settle(quiet: 0.6, timeout: 4) { signature() }
        Thread.sleep(forTimeInterval: 1.0)
        app.typeKey("f", modifierFlags: [.control, .command])
        let left = until(8) { self.win.exists && self.win.frame.width < screen.width - 2 }
        XCTAssertNotNil(left, "Hybrid: ⌃⌘F did not leave full screen")
        if left == nil { app.typeKey(.escape, modifierFlags: []) }
        app.terminate()
    }

    func testFullScreenHybridPreset() throws { continueAfterFailure = true; launchPreset("hybrid"); fullScreenCheck("hybrid-preset"); app.terminate() }

    /// A browsing session like a person's, fast: twelve real sites opened through the address field, clicked through, two pinned, two made Essentials, searched, one closed.
    func testRealBrowsingSessionTwelveSites() throws { try realSession(maximized: false) }
    /// The same session with the window zoomed to the largest size the screen allows (the green button's Zoom, not full screen).
    func testRealBrowsingSessionTwelveSitesMaximized() throws { try realSession(maximized: true) }

    private func realSession(maximized: Bool) throws {
        continueAfterFailure = true
        launchHybridLike(width: 1000)
        if maximized { maximizeWindow() }
        let sites: [(String, String)] = [
            ("example.com", "Example Domain"), ("en.wikipedia.org/wiki/Web_browser", "Web browser"), ("mozilla.org", "Mozilla"),
            ("news.ycombinator.com", "Hacker News"), ("github.com", "GitHub"), ("developer.mozilla.org", "MDN"),
            ("python.org", "Python"), ("apple.com", "Apple"), ("archive.org", "Internet Archive"),
            ("w3.org", "W3C"), ("rust-lang.org", "Rust"), ("bbc.com/news", "BBC")]
        let started = Date()
        let rowsAtStart = rowLabels().count
        // Open them one after another without waiting for each to finish, as a person opens a handful of tabs.
        for (url, _) in sites {
            app.typeKey("t", modifierFlags: .command)
            app.typeKey("l", modifierFlags: .command)
            app.typeText(url); app.typeKey(.return, modifierFlags: [])
            Thread.sleep(forTimeInterval: 0.7)
        }
        // Give the pages a moment, then see which got a title.
        _ = until(20) { sites.filter { s in self.snapItems().contains { $0.id == "tab-chip" && $0.label.localizedCaseInsensitiveContains(s.1) } }.count >= 9 }
        let titled = sites.filter { s in snapItems().contains { $0.id == "tab-chip" && $0.label.localizedCaseInsensitiveContains(s.1) } }
        out("REAL12 opened \(sites.count) in \(String(format: "%.0f", Date().timeIntervalSince(started))) s; rows \(rowsAtStart) → \(rowLabels().count); titled \(titled.count): \(titled.map(\.1)); missing \(sites.filter { s in !titled.contains { $0.1 == s.1 } }.map(\.0))")
        XCTAssertEqual(rowLabels().count, rowsAtStart + sites.count, "not every site got its own tab")
        XCTAssertGreaterThanOrEqual(titled.count, 8, "fewer than 8 of 12 real pages loaded (network?)")
        attachShot("h0-real12-opened")

        // Click through the tabs: each click selects that tab, none opens or closes one.
        var clickOK = 0
        for (_, title) in titled.prefix(6) {
            guard let row = rowFrame(title) else { continue }
            let n = rowLabels().count
            at(row.midX, row.midY).click(); settle(quiet: 0.12, timeout: 1.5) { signature() }
            let sel = activeRowTitle()
            if sel.localizedCaseInsensitiveContains(title) && rowLabels().count == n { clickOK += 1 } else { out("REAL12 click '\(title)': selected '\(sel)', rows \(n) → \(rowLabels().count)") }
        }
        out("REAL12 clicks that selected the right tab without changing the list: \(clickOK)/\(min(6, titled.count))")
        XCTAssertEqual(clickOK, min(6, titled.count), "clicking a tab row did not select that tab (or changed the list)")

        // Pin two pages, make two others Essentials.
        var pinned = 0, essentials = 0
        sidebarToTop()
        let essentialsBefore = essentialLabels().count
        for (_, title) in titled.prefix(2) {
            guard let row = rowFrame(title) else { continue }
            let n = rowLabels().count
            if chooseFromMenu(of: row, "Pin Tab"), rowLabels().count == n - 1 { pinned += 1 }
        }
        for (_, title) in titled.dropFirst(2).prefix(2) {
            guard let row = rowFrame(title) else { continue }
            if chooseFromMenu(of: row, "Add to Essentials") { essentials += 1 }
        }
        sidebarToTop()
        out("REAL12 pinned \(pinned)/2; essentials added \(essentials)/2 (tiles \(essentialsBefore) → \(essentialLabels().count): \(essentialLabels()))")
        XCTAssertEqual(pinned, 2, "two pages were not pinned"); XCTAssertEqual(essentialLabels().count, essentialsBefore + 2, "two Essentials were not added")
        attachShot("h0-real12-pinned-essentials")

        // Click an Essential and a pinned tile: selected, no duplicate tab.
        let rowsNow = rowLabels().count
        if let tile = snapItems().first(where: { $0.label.hasSuffix(", Essential") && $0.label.localizedCaseInsensitiveContains(titled[2].1) })?.frame {
            at(tile.midX, tile.midY).click(); settle(quiet: 0.2, timeout: 2) { signature() }
            out("REAL12 essential click: selected \(snapItems().contains { $0.label.hasSuffix(", Essential") && $0.selected }); rows \(rowsNow) → \(rowLabels().count)")
            XCTAssertEqual(rowLabels().count, rowsNow)
        }
        if let tile = snapItems().first(where: { $0.label.localizedCaseInsensitiveContains(titled[0].1) && $0.id != "tab-chip" })?.frame {
            at(tile.midX, tile.midY).click(); settle(quiet: 0.2, timeout: 2) { signature() }
            out("REAL12 pinned click: rows \(rowsNow) → \(rowLabels().count)")
            XCTAssertEqual(rowLabels().count, rowsNow)
        }

        // Search tabs (the sidebar row), type a word, Return: that tab comes forward.
        sidebarToTop()
        if let search = snapItems().first(where: { $0.id == "search-tabs-button" })?.frame {
            at(search.midX, search.midY).click(); settleQuick()
            app.typeText("python"); settleQuick()
            let results = snapItems().filter { $0.id == "tab-search-result" }.count
            app.typeKey(.return, modifierFlags: []); settle(quiet: 0.25, timeout: 2) { signature() }
            out("REAL12 search 'python': \(results) result(s); selected now '\(activeRowTitle())'")
            XCTAssertGreaterThan(results, 0, "searching 'python' found no open tab")
        }

        // Close a real page with its × (the × is not an accessibility element, so it is clicked where it is drawn, at the row's trailing end), then reorder two plain open rows by drag.
        sidebarToTop()
        if let title = titled.dropFirst(5).first?.1, let row = rowFrame(title) {
            let n = rowLabels().count
            at(row.midX, row.midY).click(); settle(quiet: 0.15, timeout: 1) { signature() }   // the × is on the selected row at rest
            at(row.maxX - 30 + 12, row.midY).click(); settle(quiet: 0.35, timeout: 2) { signature() }
            out("REAL12 close '\(title)': rows \(n) → \(rowLabels().count); still listed \(rowFrame(title) != nil)")
            XCTAssertEqual(rowLabels().count, n - 1, "closing a real page with its × did not remove exactly that row")
            XCTAssertNil(rowFrame(title), "the closed page is still listed")
            attachShot("h0-real12-closed")
        }
        if let a = rowFrame("Page Bulk11"), let b = rowFrame("Page Bulk6") {
            let before = rowLabels().filter { $0.hasPrefix("Page Bulk") }
            drag(a, toY: b.minY + 4)
            let after = rowLabels().filter { $0.hasPrefix("Page Bulk") }
            out("REAL12 reorder: \(before) → \(after)")
            let i11 = after.firstIndex { $0.hasPrefix("Page Bulk11") }, i6 = after.firstIndex { $0.hasPrefix("Page Bulk6") }
            XCTAssertTrue((i11 ?? 99) < (i6 ?? 0), "dragging Bulk11 above Bulk6 did not reorder the list (with real pages open)")
        } else { XCTFail("Bulk11 or Bulk6 missing with real pages open: \(rowLabels())") }
        out("REAL12 session took \(String(format: "%.0f", Date().timeIntervalSince(started))) s")
        attachShot("h0-real12-end")
        app.terminate()
    }

    /// H5 and the vertical list's group semantics: what clicking a group does to the selection and to the list, in the list the Custom arrangement uses today.
    func testGroupSelectionSideEffects() throws {
        launchHybridLike(width: 1000)
        let before = (selected: selectedLabel(), rows: rowLabels())
        let groupRow = snapItems().first { $0.label == "Reading" || $0.label.hasPrefix("Reading,") || $0.label == "Reading 2" }
        let all = snapItems().first { $0.label == "All Tabs" || $0.label.hasPrefix("All Tabs") }
        out("GROUP-ROWS: group \(groupRow.map { "\($0.id)|\($0.label)" } ?? "none"); all-tabs \(all.map { "\($0.id)|\($0.label)" } ?? "none"); rows before \(before.rows.count), selected \(before.selected)")
        guard let g = groupRow else { XCTFail("no Reading group row in the vertical list (labels: \(snapItems().map(\.label).filter { !$0.isEmpty }.prefix(40)))"); app.terminate(); return }
        at(g.frame.midX, g.frame.midY).click(); settle(quiet: 0.2, timeout: 2) { signature() }
        let after = (selected: selectedLabel(), rows: rowLabels())
        attachShot("h0-group-click")
        out("GROUP-CLICK: selected \(before.selected) → \(after.selected); rows \(before.rows.count) → \(after.rows.count); rows now \(after.rows)")
        // Contract (PD-11): choosing a group to filter by must not silently change which tab is open, and disclosure is not selection.
        XCTAssertEqual(after.selected, before.selected, "clicking a group changed the selected tab (\(before.selected) → \(after.selected))")
        app.terminate()
    }

    /// Vertical drag and drop in the Custom arrangement's list: reorder, into a group, pin by drop.
    func testVerticalDragAndDrop() throws {
        launchHybridLike(width: 1000)
        let start = rowLabels()
        out("DND start rows \(start)")
        if let a = rowFrame("Page Bulk8"), let b = rowFrame("Page Bulk5") {
            drag(a, toY: b.minY + 4)
            let now = rowLabels()
            out("DND reorder: \(now)")
            let i8 = now.firstIndex { $0.hasPrefix("Page Bulk8") }, i5 = now.firstIndex { $0.hasPrefix("Page Bulk5") }
            XCTAssertTrue((i8 ?? 99) < (i5 ?? 0), "dragging Bulk8 above Bulk5 did not reorder the list")
        } else { XCTFail("Bulk8 or Bulk5 row missing: \(start)") }
        let group = snapItems().first { $0.label.hasPrefix("Reading") }
        if let g = group?.frame, let r = rowFrame("Page Bulk9") {
            let before = snapItems().first { $0.label.hasPrefix("Reading") }?.label ?? "-"
            drag(r, toY: g.midY)
            let after = snapItems().first { $0.label.hasPrefix("Reading") }?.label ?? "-"
            out("DND into group: header '\(before)' → '\(after)'")
            XCTAssertNotEqual(before, after, "dropping a tab on the group row did not change the group (\(before))")
        } else { XCTFail("group row or Bulk9 missing") }
        // Pinned tabs are rows above the open tabs: a tab dropped on the first pinned row must move above Bulk5 (an open tab).
        if let pinnedRow = rowFrame("Page Bulk0"), let dragged = rowFrame("Page Bulk10"), let open = rowFrame("Page Bulk5") {
            let before = dragged.minY > open.minY
            drag(dragged, toY: pinnedRow.midY)
            let afterRow = rowFrame("Page Bulk10"), afterOpen = rowFrame("Page Bulk5")
            out("DND pin: Bulk10 below Bulk5 before \(before); after \(afterRow.map { $0.minY < (afterOpen?.minY ?? 0) } ?? false) (Bulk10 \(rel(afterRow)), Bulk5 \(rel(afterOpen)))")
            XCTAssertTrue(before, "the fixture changed: Bulk10 should start below Bulk5")
            XCTAssertTrue((afterRow?.minY ?? .infinity) < (afterOpen?.minY ?? 0), "dropping a tab on the pinned section did not pin it (it did not move above the open tabs)")
        } else { XCTFail("pin probe: the pinned row or the dragged row is missing (\(rowLabels()))") }
        attachShot("h0-dnd-end")
        app.terminate()
    }

    /// H2: in full screen the toolbar slides in at the top edge. Where does it sit relative to the sidebar and the page column?
    func testFullScreenToolbarPeekAlignment() throws { try fullScreenPeek(right: false) }
    func testFullScreenToolbarPeekAlignmentRight() throws { try fullScreenPeek(right: true) }

    private func fullScreenPeek(right: Bool) throws {
        launchHybridLike(width: 1000, sidebarRight: right)
        let docked = snapItems()
        let dockedField = frame("omnibox", docked), dockedSide = frame("sidebar", docked)
        app.activate()
        app.menuBars.menuBarItems["View"].click()
        let enter = app.menuBars.menuItems["Enter Full Screen"]
        guard enter.waitForExistence(timeout: 3) else { XCTFail("no Enter Full Screen item"); app.terminate(); return }
        enter.click()
        let screenWidth = NSScreen.main?.frame.width ?? 0
        XCTAssertNotNil(until(12) { self.win.exists && self.win.frame.width >= screenWidth - 2 }, "the window did not enter full screen")
        settle(quiet: 0.4, timeout: 4) { signature() }
        let rest = snapItems()
        out("FULLSCREEN rest: omnibox \(rel(frame("omnibox", rest))); sidebar \(rel(frame("sidebar", rest)))")
        attachShot("h0-fullscreen-rest")
        at(win.frame.midX, win.frame.minY + 1).hover()
        _ = until(5) { self.frame("omnibox", self.snapItems()) != nil && (self.frame("omnibox", self.snapItems())?.minY ?? 999) - self.win.frame.minY < 120 }
        settle(quiet: 0.3, timeout: 3) { signature() }
        let peek = snapItems()
        let field = frame("omnibox", peek), side = frame("sidebar", peek), back = frame("back-button", peek)
        out("FULLSCREEN peek: omnibox \(rel(field)); back \(rel(back)); sidebar \(rel(side)); docked omnibox was \(rel(dockedField)), docked sidebar \(rel(dockedSide))")
        attachShot("h0-fullscreen-peek")
        // Contract: the peeked toolbar stays over the page column; it must not run across the sidebar.
        if let field, let side {
            XCTAssertFalse(field.intersects(side), "in full screen the peeked omnibox overlaps the sidebar")
            if let back { XCTAssertFalse(back.intersects(side), "in full screen the peeked toolbar's controls overlap the sidebar") }
        } else { out("FULLSCREEN peek: toolbar or sidebar not found") }
        app.terminate()
    }
}
