import XCTest

/// D1a-B: measures the real Classic window's geometry at set widths (accessibility frames, window coordinates), so decisions about the toolbar, omnibox and tabs rest on numbers.
final class D1bGeometryUITests: PerfCase {
    private func f(_ e: XCUIElement) -> CGRect? { e.exists ? e.frame : nil }
    private func fmt(_ r: CGRect?) -> String { r.map { String(format: "x %.0f–%.0f  y %.0f–%.0f  w %.0f h %.0f", $0.minX, $0.maxX, $0.minY, $0.maxY, $0.width, $0.height) } ?? "absent" }

    func testMeasureClassicGeometryAtWidths() throws {
        for width in [520, 640, 800, 1000, 1200, 1600] {
            launch(state: "many-tabs", env: ["BS_WINDOW_SIZE": "\(width)x800"])
            XCTAssertNotNil(until(15) { tabChips().count >= 8 && abs(win.frame.width - CGFloat(width)) < 6 }, "window did not reach \(width): \(win.frame)")
            Thread.sleep(forTimeInterval: 0.6)                      // let the toolbar's own 0.2 s animation settle
            let w = win.frame
            let close = win.buttons[XCUIIdentifierCloseWindow], zoom = win.buttons[XCUIIdentifierFullScreenWindow]
            var lines = ["window \(fmt(w))"]
            func rel(_ r: CGRect?) -> String { r.map { fmt($0.offsetBy(dx: -w.minX, dy: -w.minY)) } ?? "absent" }
            lines.append("close light  \(rel(f(close)))"); lines.append("zoom light   \(rel(f(zoom)))")
            for id in ["sidebar-button", "back-button", "forward-button", "omnibox", "shield-button", "reload-button", "workspace-button", "split-button", "bookmark-button", "downloads-button", "more-menu", "new-tab-button", "overview-button", "new-tab-inline"] {
                lines.append("\(id.padding(toLength: 16, withPad: " ", startingAt: 0)) \(rel(f(any(id))))")
            }
            if let o = f(any("omnibox")) { lines.append(String(format: "omnibox centre offset from window centre: %.1f pt; width %.0f (%.0f%% of window)", o.midX - w.midX, o.width, o.width / w.width * 100)) }
            if let z = f(zoom), let first = [f(any("sidebar-button"))].compactMap({ $0 }).first { lines.append(String(format: "gap, zoom light to first toolbar control: %.1f pt", first.minX - z.maxX)) }
            if let c = f(close), let b = f(any("back-button")) { lines.append(String(format: "vertical centre: lights %.1f, toolbar buttons %.1f (difference %.1f pt)", c.midY - w.minY, b.midY - w.minY, b.midY - c.midY)) }
            let chips = (0..<tabChips().count).map { chip($0).frame }
            lines.append("tabs: \(chips.count); widths: \(chips.map { Int($0.width) })")
            if let last = chips.last, let plus = f(any("new-tab-inline")) { lines.append(String(format: "last tab right edge %.0f, plus button %.0f–%.0f, window right %.0f", last.maxX - w.minX, plus.minX - w.minX, plus.maxX - w.minX, w.width)) }
            if width <= 800 { XCTAssertTrue(chips.dropFirst().allSatisfy { $0.width >= 132 - 1 }, "a regular tab is narrower than the 132 pt minimum at \(width): \(chips.map { Int($0.width) })") }
            report.note("GEOMETRY @\(width)\n" + lines.joined(separator: "\n"))
            attachShot("geometry-\(width)")

            app.terminate()
        }
    }

    /// The narrow-window omnibox: editable room, nothing moving while typing, suggestions lined up with the field, the selected tab always visible.
    func testNarrowWindowOmniboxAndTabVisibility() throws {
        for width in [520, 560, 640, 800] {
            launch(state: "many-tabs", env: ["BS_WINDOW_SIZE": "\(width)x800"])
            XCTAssertNotNil(until(15) { tabChips().count >= 8 && abs(win.frame.width - CGFloat(width)) < 6 }, "window did not reach \(width)")
            Thread.sleep(forTimeInterval: 0.6)
            let w = win.frame
            let box = any("omnibox")
            let idle = box.frame
            let reload = any("reload-button").frame, shield = any("shield-button").frame
            let more = any("more-menu").frame, back = any("back-button").frame
            // The pill spans from the site-info icon (left of the text) to just past the reload button; the text element is inside it.
            report.note(String(format: "NARROW @%d idle: text area %.0f pt (x %.0f–%.0f), reload/shield right edge %.0f, back right edge %.0f, More left edge %.0f", width, idle.width, idle.minX - w.minX, idle.maxX - w.minX, reload.maxX - w.minX, back.maxX - w.minX, more.minX - w.minX))
            XCTAssertLessThanOrEqual(reload.maxX, more.minX - 4, "\(width): the field runs into the buttons on its right")
            XCTAssertGreaterThanOrEqual(idle.minX, back.maxX + 4, "\(width): the field runs into the controls on its left")
            // Focus and type: the field must not move, and it must have room.
            app.typeKey("l", modifierFlags: .command)
            XCTAssertNotNil(until(3) { (box.value(forKey: "hasKeyboardFocus") as? Bool) == true })
            let before = box.frame
            paste("swift browser")
            Thread.sleep(forTimeInterval: 0.5)
            let after = box.frame
            report.note(String(format: "NARROW @%d editing: text area x %.0f–%.0f (was %.0f–%.0f), width %.0f", width, after.minX - w.minX, after.maxX - w.minX, before.minX - w.minX, before.maxX - w.minX, after.width))
            XCTAssertEqual(after.minX, before.minX, accuracy: 3, "\(width): the field moved while typing")      // the field swells 2% when it takes focus (existing behaviour), about 1.5 pt at each edge
            // Suggestions lie within the window and under the field.
            let row = win.buttons["Search for “swift browser”"]
            if until(4, { row.exists }) != nil {
                let r = row.frame
                report.note(String(format: "NARROW @%d suggestion row x %.0f–%.0f (field text x %.0f–%.0f)", width, r.minX - w.minX, r.maxX - w.minX, after.minX - w.minX, after.maxX - w.minX))
                XCTAssertGreaterThanOrEqual(r.minX, w.minX - 1); XCTAssertLessThanOrEqual(r.maxX, w.maxX + 1, "\(width): the suggestions leave the window")
                XCTAssertLessThanOrEqual(abs((r.midX) - (after.midX)), 120, "\(width): suggestions are not lined up with the field")
            } else { report.failure("narrow \(width)", "no suggestion row"); attachShot("no-suggestions-\(width)") }
            attachShot("narrow-editing-\(width)")
            app.typeKey(.escape, modifierFlags: [])
            // The selected tab stays visible when selected from the keyboard (the strip scrolls to it).
            for key in ["9", "2", "9", "3"] {
                app.typeKey(key, modifierFlags: .command)
                let selected = { () -> XCUIElement? in (0..<self.tabChips().count).map { self.chip($0) }.first { $0.isSelected } }
                XCTAssertNotNil(until(3) { guard let c = selected() else { return false }; let f = c.frame; return f.minX >= w.minX - 1 && f.maxX <= w.maxX + 1 }, "\(width): after Cmd-\(key) the selected tab is not fully visible: \(String(describing: selected()?.frame))")
            }
            attachShot("narrow-tabs-\(width)")
            app.terminate()
        }
    }

    /// After-change pictures at the two widths the review asked for. The window may be on a second display, so only the window itself is captured (a whole-screen capture would include whatever else is on the person's displays).
    func testAfterChangeScreenshots() throws {
        for width in [520, 800] {
            launch(state: "many-tabs", env: ["BS_WINDOW_SIZE": "\(width)x800"])
            XCTAssertNotNil(until(15) { tabChips().count >= 8 && abs(win.frame.width - CGFloat(width)) < 6 })
            Thread.sleep(forTimeInterval: 0.8)
            attachShot("after-window-\(width)")
            report.note("AFTER @\(width): window frame \(win.frame)")
            app.terminate()
        }
    }
}
