import XCTest

/// DX-09 final UI gate: the real provider panel in the real Debug app, driven by real clicks, against a controlled local "Vimeo-shaped" site (scripts/download_fixture_server.py on port 18766, started
/// by the scheme). The app is started with -ProviderFixture, which exists only in debug builds: it treats that local server as Vimeo and keeps credentials in a separate Keychain service, so a
/// real saved Vimeo token is never read or written. Nothing here contacts Vimeo, and the real authorization flow is therefore not exercised. As with the other UI tests, nothing is typed unless the
/// app is frontmost.
final class ProviderPanelUITests: XCTestCase {
    var app: XCUIApplication!
    let port = 18766
    var site: String { "http://127.0.0.1:\(port)" }
    var shots: String { ProcessInfo.processInfo.environment["PROVIDER_SHOTS_DIR"] ?? NSTemporaryDirectory() }

    // MARK: Helpers

    func send(_ method: String, _ path: String, _ body: Data? = nil) -> (Int, Data) {
        var r = URLRequest(url: URL(string: site + path)!); r.httpMethod = method; r.httpBody = body; r.timeoutInterval = 5
        let sem = DispatchSemaphore(value: 0); var out: (Int, Data) = (0, Data())
        URLSession(configuration: .ephemeral).dataTask(with: r) { d, resp, _ in out = ((resp as? HTTPURLResponse)?.statusCode ?? 0, d ?? Data()); sem.signal() }.resume()
        _ = sem.wait(timeout: .now() + 8)
        return out
    }
    func put(_ key: String, _ text: String) { _ = send("PUT", "/_media/\(key)", Data(text.utf8)) }
    func hits() -> [String: Int] {
        let d = send("GET", "/_media_hits").1
        return ((try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["hits"] as? [String: Int]) ?? [:]
    }
    func waitFor(_ seconds: Double, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if cond() { return true }; Thread.sleep(forTimeInterval: 0.2) }
        return cond()
    }
    func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    func shot(_ name: String) {
        guard let image = app.windows["browser-AppWindow-1"].safeScreenshot() else { return }
        try? image.pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/provider-\(name).png"))
        let a = XCTAttachment(screenshot: image); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    let payload = String(repeating: "provider fixture payload. ", count: 800)
    func api(link: String, size: Int? = nil) -> String {
        """
        {"name":"Owner clip","duration":10,"privacy":{"download":true},"download":[{"quality":"hd","type":"source","width":1280,"height":720,"link":"\(link)","size":\(size ?? payload.utf8.count),"md5":"m1","public_name":"Original","expires":"2099-01-01T00:00:00Z"}]}
        """
    }
    func publish(link: String) {
        put("vimeo/file.bin", payload)
        // The fixture sends no cache headers (and a 2015 Last-Modified), so WebKit may serve its pages from cache and the server never sees them: each run asks for its own address.
        let nonce = UUID().uuidString
        put("vimeo/clip.mp4", "not really a video")
        put("vimeo/page.html", "<html><body><h1>Provider fixture</h1><iframe src=\"http://localhost:\(port)/media/vimeo/embed.html?v=123456&n=\(nonce)\" width=\"320\" height=\"200\"></iframe></body></html>")
        put("vimeo/embed.html", "<html><body><video controls src=\"http://localhost:\(port)/media/vimeo/clip.mp4?n=\(nonce)\" width=\"300\"></video></body></html>")
        put("vimeo/videos/123456", api(link: link))
    }

    func launch(delay: Double = 0) throws {
        continueAfterFailure = false
        try XCTSkipUnless(send("GET", "/").0 == 200, "the download fixture server is not running on \(port)")
        app = XCUIApplication()
        app.launchArguments += ["-UITestRoot", "bs-ui-provider-\(UUID().uuidString)", "-UIState", "provider-page", "-NSRequiresAquaSystemAppearance", "YES",
                                "-ProviderFixture", site, "-ProviderFixtureDelay", String(delay)]
        app.launch()
        app.activate()
        try XCTSkipUnless(app.wait(for: .runningForeground, timeout: 15), "Browser Setu is not frontmost; refusing to send input")
    }
    override func tearDown() { app?.terminate() }

    func navigate(_ address: String) {
        guard app.state == .runningForeground else { XCTFail("lost foreground; not typing"); return }
        // A new window shows the start page, whose own search field takes the keyboard (clicking the address bar does not move focus away from it); type where the focus really is.
        let start = app.textFields["start-search"]
        if start.waitForExistence(timeout: 6) { start.click(); start.typeText(address) }
        else {
            let box = app.textFields["omnibox"]
            XCTAssertTrue(box.waitForExistence(timeout: 10), "address bar not found")
            box.click(); box.typeText(address)
        }
        guard app.state == .runningForeground else { XCTFail("lost foreground; not pressing Return"); return }
        app.typeKey(.return, modifierFlags: [])
    }
    func openMediaSheet() {
        guard app.state == .runningForeground else { XCTFail("lost foreground; not clicking"); return }
        app.menuBars.menuBarItems["Library"].click()
        let item = app.menuBars.menuItems["Find Downloadable Media"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the menu has no Find Downloadable Media")
        item.click()
    }
    func open(delay: Double = 0, link: String, openSheet: Bool = true) throws {
        publish(link: link)
        let clipBefore = hits()["vimeo/clip.mp4"] ?? 0
        try launch(delay: delay)
        // Loaded means the embedded frame's player asked for its media (the page itself may come from cache).
        let loaded = waitFor(25) { (self.hits()["vimeo/clip.mp4"] ?? 0) > clipBefore }
        if !loaded {
            let box = app.textFields["omnibox"]
            let chips = app.descendants(matching: .any).matching(identifier: "tab-chip").allElementsBoundByIndex.map(\.label)
            XCTFail("the page was not loaded. omnibox=\(box.exists ? String(describing: box.value) : "none") tabs=\(chips) start-search=\(app.textFields["start-search"].exists) server hits=\(hits())")
            return
        }
        Thread.sleep(forTimeInterval: 2)           // the page and its frame report their player
        guard openSheet else { return }
        openMediaSheet()
        XCTAssertTrue(any("provider-name").waitForExistence(timeout: 10), "the provider panel did not appear for a recognised provider page")
    }
    func text(_ id: String) -> String { (any(id).value as? String) ?? any(id).label }

    // MARK: The gate

    /// On macOS a click does not scroll the element into view, and the tool calls an element that is scrolled out of sight "not hittable". Steps the window's scroll view toward the element in small turns
    /// (which way "positive" is, is learned from what the first step does) until the element can be clicked.
    func reveal(_ element: XCUIElement, inWindow identifier: String) {
        let window = app.windows[identifier]
        // The window has more than one scroll view (the list of panes, and the pane itself): the one to turn is the one the element is in, by where it is across the window.
        let scrollers = window.scrollViews.allElementsBoundByIndex
        guard let scroller = scrollers.first(where: { $0.frame.minX <= element.frame.midX && element.frame.midX <= $0.frame.maxX }) ?? scrollers.last else { return }
        var sign: CGFloat = 1
        for _ in 0..<120 where !element.isHittable {
            let target = scroller.frame.midY
            let before = abs(element.frame.midY - target)
            scroller.scroll(byDeltaX: 0, deltaY: sign * (element.frame.midY < target ? 120 : -120))
            Thread.sleep(forTimeInterval: 0.15)
            if abs(element.frame.midY - target) >= before { sign = -sign }       // that step went the wrong way: turn round
        }
    }

    /// Authorization is entered in Settings ▸ Downloads ▸ Providers (the media window only links there). Opens it through the panel's "Manage account…", types a fixture token, saves, and comes back.
    func authorizeThroughSettings() {
        dump("before manage-account")
        any("provider-manage-account").click()
        let authorize = any("settings-provider-vimeo-authorize")
        XCTAssertTrue(authorize.waitForExistence(timeout: 15), "Manage account… did not reach Settings ▸ Downloads ▸ Providers")
        reveal(authorize, inWindow: "com_apple_SwiftUI_Settings_window")
        authorize.click()
        let field = any("provider-token-field")
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the token sheet did not open in Settings")
        field.click(); field.typeText("fixture-token-12345")
        any("provider-token-save").click()
        XCTAssertTrue(waitFor(10) { self.any("settings-provider-vimeo-remove").exists }, "Settings does not show Vimeo as authorized")
        shot("settings-authorized")
    }
    /// Diagnostic: what the window holds right now (identifiers of buttons/text/sheets/windows), printed with PANEL lines.
    func dump(_ label: String) {
        // One snapshot of the whole tree (enumerating elements one by one races with the UI changing).
        let lines = app.debugDescription.split(separator: "\n").filter { l in ["provider-", "settings-", "media-", "category-", "Sheet", "Window", "Settings"].contains { l.contains($0) } }
        print("PANEL \(label): " + lines.prefix(40).map { String($0.trimmingCharacters(in: .whitespaces).prefix(140)) }.joined(separator: " // "))
    }
    func closeSettings() {
        dump("before closing settings")
        guard app.state == .runningForeground else { return }
        app.typeKey("w", modifierFlags: .command)          // closes the Settings window (or leaves the inline Settings), returning to the browser
        Thread.sleep(forTimeInterval: 1)
        dump("after closing settings")
    }

    /// Toolbar indicator, provenance, enablement, Settings authorization, resolve, download, expiry and renewal, with Downloads on screen.
    func testAuthorizeResolveDownloadAndRenewTheExpiredLink() throws {
        // The first link the "provider" gives is already stale (the server refuses it as a signed link would be refused).
        publish(link: "\(site)/media/vimeo/file.bin?status=403")
        try open(link: "\(site)/media/vimeo/file.bin?status=403", openSheet: false)
        // 1. The toolbar indicator: shown because the page has media; it says media was found, and the count is dimmed because nothing in it can be downloaded (a local player is not downloadable).
        let badge = any("media-button")
        XCTAssertTrue(badge.waitForExistence(timeout: 15), "no media indicator in the toolbar for a page with a player")
        XCTAssertTrue(badge.label.contains("found"), badge.label)
        shot("00-toolbar-indicator")
        badge.click()                                          // opens the category list; its button opens the existing media picker
        let openPicker = any("category-open-picker")
        XCTAssertTrue(openPicker.waitForExistence(timeout: 5), "the list offers the media picker for the page's players")
        openPicker.click()
        XCTAssertTrue(any("provider-name").waitForExistence(timeout: 10), "the indicator did not open the media picker with the provider panel")
        XCTAssertEqual(text("provider-name"), "Vimeo")
        shot("01-panel")

        // 2. Real tab and frame provenance: the list holds the player found in the embedded frame; choosing it tells the panel where it plays.
        // The row is one combined element: the item's name, then "Embedded player" and the frame's host. The name may be the page's title, so the row is found by what marks it as embedded.
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Embedded player' OR value CONTAINS 'Embedded player'")).firstMatch
        let listed = row.waitForExistence(timeout: 10)
        if !listed {
            let lines = app.debugDescription.split(separator: "\n").filter { $0.contains("StaticText") || $0.contains("Button") || $0.contains("Table") || $0.contains("Sheet") }.prefix(45).map { String($0.trimmingCharacters(in: .whitespaces).prefix(110)) }
            XCTFail("the player in the embedded frame was not listed. The window shows:\n" + lines.joined(separator: "\n"))
            return
        }
        row.click()
        XCTAssertTrue(any("provider-frame").waitForExistence(timeout: 5), "the panel does not show the embedded frame")
        XCTAssertTrue(text("provider-frame").contains("localhost"), text("provider-frame"))
        shot("02-frame")

        // 3. Enablement: nothing to download before there is an authorization and a resolution.
        XCTAssertFalse(any("provider-download-0").exists)
        any("provider-resolve").click()
        XCTAssertTrue(waitFor(10) { self.text("provider-state").lowercased().contains("authorize") || self.text("provider-state").lowercased().contains("sign in") }, "no request for authorization: \(any("provider-state").exists ? text("provider-state") : "no state shown")")
        XCTAssertFalse(any("provider-download-0").exists, "a Download button without an authorization")
        shot("03-needs-authorization")

        // 4. Authorize in Settings, come back, resolve.
        authorizeThroughSettings()
        closeSettings()
        // Coming back from Settings with an authorization, the panel looks up by itself: no Resolve click (so Resolve is not looked for).
        if !(any("provider-name").waitForExistence(timeout: 5)) { openMediaSheet() }
        XCTAssertTrue(any("provider-name").waitForExistence(timeout: 10), "could not get back to the media picker after Settings")
        XCTAssertTrue(any("provider-download-0").waitForExistence(timeout: 20), "no Download button after authorization, with no Resolve click: \(any("provider-state").exists ? text("provider-state") : "none")")
        XCTAssertTrue(hitsAuthorization(), "the API call did not carry the token")
        shot("04-resolved")

        // 5. Download with a link that has already ended, then the provider hands out the same file with a fresh link: the flow renews it and the download finishes.
        any("provider-download-0").click()
        XCTAssertTrue(waitFor(15) { self.hits()["vimeo/file.bin"] ?? 0 >= 1 }, "no download request was made")
        Thread.sleep(forTimeInterval: 1.0)
        shot("05-downloads-failing")
        put("vimeo/videos/123456", api(link: "\(site)/media/vimeo/file.bin"))
        XCTAssertTrue(any("provider-renewed").waitForExistence(timeout: 30), "the expired link was not renewed")
        XCTAssertTrue(waitFor(30) { self.hits()["vimeo/file.bin"] ?? 0 >= 2 }, "the renewed link was not fetched")
        Thread.sleep(forTimeInterval: 1.5)
        shot("06-downloads-done")
        XCTAssertTrue(any("downloads-table").exists || app.tables.firstMatch.exists || app.outlines.firstMatch.exists, "the download is not shown in Downloads")
    }

    /// Downloads ▸ Collect: the menu has the entries, and the TikTok export opens its window with its eligibility text and no way to request without an authorization.
    func testCollectMenuAndTheTikTokExportWindow() throws {
        try open(link: "\(site)/media/vimeo/file.bin", openSheet: false)
        // The media window is not open here; open Downloads and use its Collect menu.
        app.menuBars.menuBarItems["Library"].click()
        let show = app.menuBars.menuItems["Show Downloads"]
        XCTAssertTrue(show.waitForExistence(timeout: 5)); show.click()
        let collect = any("downloads-collect")
        XCTAssertTrue(collect.waitForExistence(timeout: 10), "no Collect menu in the Downloads window")
        collect.click()
        for title in ["Find Media on This Page…", "Explore This Website…", "LinkGrabber", "Download Packages…", "Open Archive from Address…", "Export My TikTok Data…"] {
            XCTAssertTrue(app.menuItems[title].waitForExistence(timeout: 3), "the Collect menu has no “\(title)”")
        }
        shot("08-collect-menu")
        app.menuItems["Export My TikTok Data…"].click()
        XCTAssertTrue(app.staticTexts["Export my TikTok data"].waitForExistence(timeout: 5), "the export window did not open")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'EEA' OR value CONTAINS 'EEA'")).firstMatch.waitForExistence(timeout: 3), "the eligibility text is missing")
        XCTAssertFalse(app.buttons["Request"].isEnabled, "a request can be made with no authorization")
        shot("09-tiktok-export")
    }

    /// Cancel while a lookup is in flight (the fixture slows the answer): nothing is shown and nothing is started.
    func testCancellingALookupStartsNothing() throws {
        put("vimeo/file.bin", payload)
        try open(delay: 15, link: "\(site)/media/vimeo/file.bin")
        // The panel looks up by itself once it is shown (and authorized), so either Resolve is offered or a lookup is already under way.
        _ = any("provider-resolve").waitForExistence(timeout: 8) || any("provider-cancel").waitForExistence(timeout: 1)
        if any("provider-resolve").exists { any("provider-resolve").click() }
        // With an authorization a lookup is under way (slowed to four seconds) and Cancel shows at once. Without one it ends at once: authorize through Settings first, then look again.
        if !any("provider-cancel").waitForExistence(timeout: 1.5) {
            authorizeThroughSettings(); closeSettings()
            if !any("provider-resolve").waitForExistence(timeout: 5), !any("provider-cancel").exists { openMediaSheet() }
            _ = any("provider-resolve").waitForExistence(timeout: 5)
            if any("provider-resolve").exists { any("provider-resolve").click() }
        }
        XCTAssertTrue(any("provider-cancel").waitForExistence(timeout: 3), "no Cancel while a lookup runs")
        let before = hits()["vimeo/file.bin"] ?? 0
        any("provider-cancel").click()
        Thread.sleep(forTimeInterval: 16)           // longer than the slowed answer
        XCTAssertFalse(any("provider-download-0").exists, "the cancelled lookup came back")
        XCTAssertEqual(hits()["vimeo/file.bin"] ?? 0, before, "something was fetched after the cancel")
        shot("07-cancelled")
    }

    private func hitsAuthorization() -> Bool {
        let d = send("GET", "/_media_hits").1
        let auth = ((try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["auth"] as? [String: [String]])?["vimeo/videos/123456"] ?? []
        return auth.contains("Bearer fixture-token-12345")
    }
}
