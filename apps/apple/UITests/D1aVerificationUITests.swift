import XCTest

/// D1a verification pass (no new geometry): the top bar shared with the vertical-tabs layouts, a fully loaded custom toolbar, a Classic window with the Library open, light and dark appearance,
/// and what the accessibility tree says about the toolbar and tabs. Findings are written to the report as notes; assertions are overlap/containment rules, not coordinates.
final class D1aVerificationUITests: PerfCase {
    private func rect(_ id: String) -> CGRect? { let e = any(id); return e.exists ? e.frame : nil }
    private let toolbarIDs = ["sidebar-button", "back-button", "forward-button", "shield-button", "reload-button", "workspace-button", "profile-button", "split-button", "history-button", "library-button", "find-button", "palette-button",
                              "new-tab-button", "overview-button", "bookmark-button", "downloads-button", "more-menu"]

    /// No toolbar control overlaps another, and all lie inside the window.
    private func assertToolbarClean(_ label: String, in w: CGRect) {
        var items: [(String, CGRect)] = []
        for id in toolbarIDs { if let r = rect(id), r.minY - w.minY < 44 { items.append((id, r)) } }
        for (id, r) in items { XCTAssertGreaterThanOrEqual(r.minX, w.minX - 1, "\(label): \(id) leaves the window on the left"); XCTAssertLessThanOrEqual(r.maxX, w.maxX + 1, "\(label): \(id) leaves the window on the right") }
        let sorted = items.sorted { $0.1.minX < $1.1.minX }
        for (a, b) in zip(sorted, sorted.dropFirst()) { XCTAssertLessThanOrEqual(a.1.maxX, b.1.minX + 1, "\(label): \(a.0) overlaps \(b.0)") }
        if let o = rect("omnibox"), let reload = rect("reload-button") {
            XCTAssertGreaterThanOrEqual(o.minX, (sorted.filter { $0.0 == "back-button" || $0.0 == "sidebar-button" || $0.0 == "forward-button" }.map { $0.1.maxX }.max() ?? 0) + 2, "\(label): the field runs into the controls on its left")
            XCTAssertTrue(sorted.filter { $0.1.minX > reload.maxX }.allSatisfy { $0.1.minX >= reload.maxX + 2 }, "\(label): the field runs into the controls on its right")
        }
    }

    func testSharedTopBarInTheVerticalTabsLayoutAtNarrowWidths() throws {
        for width in [520, 640, 800, 1200] {
            launch(state: "custom-vertical-bar", env: ["BS_WINDOW_SIZE": "\(width)x800"])
            XCTAssertNotNil(until(15) { win.exists && abs(win.frame.width - CGFloat(width)) < 6 && rect("sidebar") != nil }, "window did not reach \(width) with the sidebar: \(win.frame)")
            XCTAssertNotNil(open("/p/Bar", title: "Bar"), "the page did not load")        // a blank tab hides the field, so a page is loaded first
            Thread.sleep(forTimeInterval: 0.8)
            let w = win.frame
            let sidebar = rect("sidebar")
            report.note("VERTICAL-BAR @\(width): sidebar \(sidebar.map { "x \(Int($0.minX - w.minX))–\(Int($0.maxX - w.minX))" } ?? "absent"); omnibox \(rect("omnibox").map { "x \(Int($0.minX - w.minX))–\(Int($0.maxX - w.minX)) w \(Int($0.width))" } ?? "absent"); more \(rect("more-menu").map { "x \(Int($0.minX - w.minX))" } ?? "absent")")
            assertToolbarClean("vertical-bar \(width)", in: w)
            attachShot("vertical-bar-\(width)")
            app.terminate()
        }
    }

    func testFullyLoadedCustomToolbarAtWidths() throws {
        for width in [520, 640, 800, 1000, 1200, 1600] {
            launch(state: "all-toolbar", env: ["BS_WINDOW_SIZE": "\(width)x800"])
            XCTAssertNotNil(until(15) { win.exists && abs(win.frame.width - CGFloat(width)) < 6 && any("more-menu").exists }, "window did not reach \(width)")
            XCTAssertNotNil(open("/p/Full", title: "Full"), "the page did not load")
            Thread.sleep(forTimeInterval: 0.8)
            let w = win.frame
            let shown = toolbarIDs.filter { rect($0) != nil }
            report.note("FULL-TOOLBAR @\(width): shown \(shown.count): \(shown.joined(separator: ", ")); omnibox w \(rect("omnibox").map { Int($0.width) } ?? 0)")
            assertToolbarClean("full toolbar \(width)", in: w)
            XCTAssertNotNil(rect("more-menu"), "\(width): More is not reachable"); XCTAssertNotNil(rect("back-button"), "\(width): Back is not reachable")
            if width == 520 || width == 1200 { attachShot("full-toolbar-\(width)") }
            app.terminate()
        }
    }

    func testLibraryOpenInClassic() throws {
        for width in [520, 800, 1200] {
            launch(state: "many-tabs", env: ["BS_WINDOW_SIZE": "\(width)x800"])
            XCTAssertNotNil(until(15) { win.exists && abs(win.frame.width - CGFloat(width)) < 6 && tabChips().count >= 8 })
            app.typeKey("l", modifierFlags: [.command, .shift])
            XCTAssertNotNil(until(5) { rect("sidebar") != nil }, "\(width): the sidebar did not open")
            Thread.sleep(forTimeInterval: 0.8)
            let w = win.frame, side = rect("sidebar")!
            let page = win.descendants(matching: .webView).firstMatch
            let pageFrame = page.exists ? page.frame : .zero
            report.note("LIBRARY @\(width): sidebar x \(Int(side.minX - w.minX))–\(Int(side.maxX - w.minX)) (w \(Int(side.width)), \(Int(side.width / w.width * 100))%); page x \(Int(pageFrame.minX - w.minX))–\(Int(pageFrame.maxX - w.minX)) (w \(Int(pageFrame.width)))")
            XCTAssertGreaterThan(pageFrame.width, 200, "\(width): the page is squeezed to \(pageFrame.width) pt by the Library")
            XCTAssertLessThanOrEqual(side.width, w.width * 0.43, "\(width): the sidebar is wider than 42% of the window")
            XCTAssertLessThanOrEqual(pageFrame.minX, w.maxX); XCTAssertGreaterThanOrEqual(pageFrame.minX, side.maxX - 12, "\(width): the page overlaps the sidebar")
            assertToolbarClean("library \(width)", in: w)
            attachShot("library-\(width)")
            app.terminate()
        }
    }

    func testLightAndDarkAppearance() throws {
        var widths: [String: CGFloat] = [:]
        for mode in ["Light", "Dark"] {
            for width in [520, 800] {
                launch(state: "many-tabs", env: ["BS_WINDOW_SIZE": "\(width)x800"].merging(mode == "Light" ? ["BS_SETUP_LIGHT": "1"] : [:]) { a, _ in a })      // the app's own light switch; the system style argument is ignored by this app
                XCTAssertNotNil(until(15) { win.exists && abs(win.frame.width - CGFloat(width)) < 6 && tabChips().count >= 8 })
                Thread.sleep(forTimeInterval: 0.8)
                widths["\(mode)\(width)"] = rect("omnibox")?.width ?? 0
                assertToolbarClean("\(mode) \(width)", in: win.frame)
                attachShot("appearance-\(mode)-\(width)")
                app.terminate()
            }
        }
        report.note("APPEARANCE omnibox widths: \(widths)")
        XCTAssertEqual(widths["Light520"], widths["Dark520"]); XCTAssertEqual(widths["Light800"], widths["Dark800"])
    }

    /// What the accessibility tree offers: every control in the toolbar row has a name, the tabs have names and exactly one is selected.
    func testToolbarAndTabAccessibilityTree() throws {
        launch(state: "many-tabs")
        XCTAssertNotNil(until(15) { tabChips().count >= 8 })
        let w = win.frame
        let tree = win.debugDescription
        var controls = 0; var unnamed: [String] = []
        for line in tree.split(separator: "\n") where line.contains("Button,") || line.contains("MenuButton,") || line.contains("PopUpButton,") || line.contains("TextField,") {
            guard let r = line.range(of: #"\{\{(-?[0-9.]+), (-?[0-9.]+)\}, \{([0-9.]+), ([0-9.]+)\}\}"#, options: .regularExpression) else { continue }
            let nums = line[r].components(separatedBy: CharacterSet(charactersIn: "{}, ")).compactMap { Double($0) }
            guard nums.count == 4, nums[1] >= Double(w.minY), nums[1] - Double(w.minY) < 40, !line.contains("_XCUI:") else { continue }
            controls += 1
            if !line.contains("identifier:") && !line.contains("label:") && !line.contains("title:") { unnamed.append(String(line.prefix(90))) }
        }
        report.note("A11Y toolbar: \(controls) controls in the top row; without any name: \(unnamed)")
        XCTAssertGreaterThan(controls, 5, "the top row was not read")
        XCTAssertTrue(unnamed.isEmpty, "unnamed toolbar controls: \(unnamed)")
        let labels = chipLabels()
        XCTAssertTrue(labels.allSatisfy { !$0.isEmpty }, "a tab has no accessible name: \(labels)")
        XCTAssertEqual((0..<tabChips().count).filter { chip($0).isSelected }.count, 1, "exactly one tab should be selected")
        report.note("A11Y tabs: labels \(labels); values \((0..<tabChips().count).map { (chip($0).value as? String) ?? "" })")
    }

    /// The tab row sat about 8 pt above its neighbours when macOS showed always-visible scroll bars (a mouse being connected does that). Measured in each horizontal layout with the scroll-bar style
    /// forced each way: how far the tab row's centre is from the centre of the control beside it (the strip's + button, or Back in One Row).
    func testTabRowAlignmentInEachLayoutUnderEachScrollBarStyle() throws {
        for layout in ["Classic", "Minimal", "One Row"] {
            for style in ["WhenScrolling", "Always"] {
                launch(state: "many-tabs", extra: ["-AppleShowScrollBars", style], env: ["BS_WINDOW_SIZE": "900x800"])
                XCTAssertNotNil(until(15) { win.exists && abs(win.frame.width - 900) < 6 && tabChips().count >= 8 })
                if layout != "Classic" {
                    app.typeKey("k", modifierFlags: .command)
                    XCTAssertNotNil(until(8) { any("palette-field").exists })
                    paste("Layout: \(layout)"); app.typeKey(.return, modifierFlags: [])
                    Thread.sleep(forTimeInterval: 0.8)
                }
                Thread.sleep(forTimeInterval: 0.6)
                let w = win.frame
                var reference: CGRect = .zero
                if layout == "One Row" {
                    // In One Row there is no + beside the tabs; any control of the same bar will do as the reference (the bar's own centre).
                    guard let id = ["more-menu", "omnibox", "sidebar-button", "shield-button"].first(where: { any($0).exists }) else { attachShot("onerow-no-reference"); report.note("TABROW-ALIGN One Row scrollbars=\(style): no reference control found"); app.terminate(); continue }
                    reference = any(id).frame
                } else {
                    reference = win.buttons.matching(NSPredicate(format: "label == 'New Tab' AND identifier == 'tab-bar'")).firstMatch.frame
                }
                guard tabChips().count > 1 else { report.note("TABROW-ALIGN \(layout) scrollbars=\(style): fewer than two tabs visible"); app.terminate(); continue }
                let target = chip(min(layout == "One Row" ? 3 : 2, tabChips().count - 1)).frame
                let offset = Double(reference.midY - target.midY)
                report.note(String(format: "TABROW-ALIGN %@ scrollbars=%@: tab mid %.1f, reference mid %.1f (offset %.1f pt)", layout, style, Double(target.midY - w.minY), Double(reference.midY - w.minY), offset))
                attachShot("tabrow-\(layout)-\(style)")
                app.terminate()
            }
        }
    }
}
