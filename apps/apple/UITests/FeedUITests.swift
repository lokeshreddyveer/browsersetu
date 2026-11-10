import XCTest

/// Feeds & Podcasts in the real Debug app, with real clicks: Downloads → Collect → Feeds & Podcasts…, a feed served by the fixture server (on 18766, started by the scheme), choose all its episodes,
/// Download, and the Downloads window lists them as completed under their episode titles. The app is started with a throwaway profile and a scratch downloads folder; nothing real is touched.
final class FeedUITests: XCTestCase {
    var app: XCUIApplication!
    let site = "http://127.0.0.1:18766"
    func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    override func tearDown() { app?.terminate() }

    func put(_ path: String, _ body: Data) {
        var r = URLRequest(url: URL(string: site + "/_media/" + path)!); r.httpMethod = "PUT"; r.httpBody = body; r.timeoutInterval = 5
        let sem = DispatchSemaphore(value: 0)
        URLSession(configuration: .ephemeral).dataTask(with: r) { _, _, _ in sem.signal() }.resume(); _ = sem.wait(timeout: .now() + 8)
    }

    func testChooseAllEpisodesOfAFeedAndTheyDownloadUnderTheirTitles() throws {
        let n = "fu\(Int(Date().timeIntervalSince1970))"
        for i in 1...3 { put("\(n)/ep\(i)", Data(repeating: UInt8(0x60 + i), count: 3000 + i)) }
        let items = (1...3).map { "<item><title>Episode \($0) – Live</title><guid>\(n)-\($0)</guid><pubDate>Sat, 0\($0) Nov 2026 10:00:00 +0000</pubDate><enclosure url=\"\(site)/media/\(n)/ep\($0)\" type=\"audio/mpeg\" length=\"\(3000 + $0)\"/></item>" }.joined()
        put("\(n)/feed.xml", Data("<rss version=\"2.0\"><channel><title>UI Show</title>\(items)</channel></rss>".utf8))
        put("\(n)/page.html", Data("<html><body><h1>Podcast</h1></body></html>".utf8))

        app = XCUIApplication()
        app.launchArguments += ["-UITestRoot", "bs-ui-fu-\(UUID().uuidString)", "-UITestAllowLocalPageOrigin", "YES", "-UIState", "url", "-UIURL", "\(site)/media/\(n)/page.html", "-UIDownloadsScratch", "fu-\(n)",
                                "-NSRequiresAquaSystemAppearance", "YES", "-UITestFastScan", "YES"]
        app.launch(); app.activate()
        try XCTSkipUnless(app.wait(for: .runningForeground, timeout: 15), "Browser Setu is not frontmost; refusing to send input")

        // Downloads → Collect → Feeds & Podcasts…
        XCTAssertTrue(any("downloads-button").waitForExistence(timeout: 30)); any("downloads-button").click()
        let openWindow = app.buttons["Open Downloads"]
        XCTAssertTrue(openWindow.waitForExistence(timeout: 8), "the toolbar button's popover offers the Downloads window"); openWindow.click()
        let collect = any("downloads-collect")
        XCTAssertTrue(collect.waitForExistence(timeout: 15)); collect.click()
        // The same name is also in the Library menu of the menu bar: the one in the open Collect menu is the one that can be clicked.
        let until = Date().addingTimeInterval(5)
        var item: XCUIElement?
        while item == nil, Date() < until { item = app.menuItems.matching(NSPredicate(format: "title == %@", "Feeds & Podcasts…")).allElementsBoundByIndex.first { $0.isHittable }; if item == nil { Thread.sleep(forTimeInterval: 0.2) } }
        XCTAssertNotNil(item, "the Collect menu offers Feeds & Podcasts"); item?.click()
        XCTAssertTrue(any("feed-sheet").waitForExistence(timeout: 10))

        // Load the feed by its address.
        let address = any("feed-address")
        XCTAssertTrue(address.waitForExistence(timeout: 5)); address.click(); address.typeText("\(site)/media/\(n)/feed.xml")
        any("feed-load").click()
        let rows = app.descendants(matching: .any).matching(identifier: "feed-row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 20), "the episodes are listed")
        XCTAssertEqual(rows.count, 3)
        let title = rows.element(boundBy: 0).descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Episode' OR value CONTAINS 'Episode'")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5), "titles are shown in the rows")

        // Choose all of them and download.
        any("feed-select-all").click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS '3 selected' OR label CONTAINS '3 selected'")).firstMatch.waitForExistence(timeout: 5), "the count shows three chosen")
        let go = any("feed-download")
        XCTAssertTrue(go.isEnabled); go.click()
        let message = app.staticTexts.matching(NSPredicate(format: "value CONTAINS 'Started 3' OR label CONTAINS 'Started 3'")).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 20), "the result is said in a sentence")

        // The Downloads window lists three completed downloads named by their episodes.
        any("feed-close").click()
        let table = any("downloads-table")
        XCTAssertTrue(table.waitForExistence(timeout: 10))
        let completed = app.staticTexts.matching(NSPredicate(format: "value == 'Completed' OR label == 'Completed'"))
        let end = Date().addingTimeInterval(60)
        while Date() < end, completed.count < 3 { Thread.sleep(forTimeInterval: 1) }
        XCTAssertEqual(completed.count, 3, "all three episodes completed")
        for i in 1...3 {
            let name = table.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Episode \(i)' OR value CONTAINS 'Episode \(i)'")).firstMatch
            XCTAssertTrue(name.exists, "Episode \(i) is listed by its title")
        }
        XCTAssertFalse(table.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'ep1' OR value CONTAINS 'ep1'")).firstMatch.exists, "not under the address's last part")
    }

    /// A page that is not a feed → "Look Up as a Playlist…" → the person's extractor (a stand-in script) asks for permission → entries listed → a quality chosen → Download → the entries save into one
    /// collection, the one that cannot be had fails alone and is offered again.
    func testAPlaylistPageIsListedAskedForPermissionAndSavedWithOneFailureOffered() throws {
        let n = "fp\(Int(Date().timeIntervalSince1970))"
        let clip = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tests/Fixtures/video/clip.mp4"))
        put("\(n)/clip.mp4", clip)
        put("\(n)/a", Data("<html><body><h1>Course</h1></body></html>".utf8))
        put("\(n)/page.html", Data("<html><body><h1>Start</h1></body></html>".utf8))
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tests/Fixtures/test-extractor.sh").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: script), "the stand-in extractor fixture is missing: \(script)")

        app = XCUIApplication()
        app.launchArguments += ["-UITestRoot", "bs-ui-fp-\(UUID().uuidString)", "-UITestAllowLocalPageOrigin", "YES", "-bs.extractor.enabled", "YES", "-bs.extractor.path", script,
                                "-UIState", "url", "-UIURL", "\(site)/media/\(n)/page.html", "-UIDownloadsScratch", "fp-\(n)", "-NSRequiresAquaSystemAppearance", "YES", "-UITestFastScan", "YES"]
        app.launch(); app.activate()
        try XCTSkipUnless(app.wait(for: .runningForeground, timeout: 15), "Browser Setu is not frontmost; refusing to send input")

        XCTAssertTrue(any("downloads-button").waitForExistence(timeout: 30)); any("downloads-button").click()
        let openWindow = app.buttons["Open Downloads"]
        XCTAssertTrue(openWindow.waitForExistence(timeout: 8)); openWindow.click()
        let collect = any("downloads-collect")
        XCTAssertTrue(collect.waitForExistence(timeout: 15)); collect.click()
        let until2 = Date().addingTimeInterval(5)
        var item: XCUIElement?
        while item == nil, Date() < until2 { item = app.menuItems.matching(NSPredicate(format: "title == %@", "Feeds & Podcasts…")).allElementsBoundByIndex.first { $0.isHittable }; if item == nil { Thread.sleep(forTimeInterval: 0.2) } }
        XCTAssertNotNil(item, "the Collect menu offers Feeds & Podcasts"); item?.click()
        XCTAssertTrue(any("feed-sheet").waitForExistence(timeout: 10))
        let address = any("feed-address")
        XCTAssertTrue(address.waitForExistence(timeout: 5)); address.click(); address.typeText("\(site)/media/\(n)/a?flatlist")
        any("feed-load").click()

        // Not a feed: the sheet offers to look it up as a playlist, and asks permission before the program sees the address.
        let lookup = any("feed-playlist")
        XCTAssertTrue(lookup.waitForExistence(timeout: 20), "a page that is not a feed offers a playlist lookup"); lookup.click()
        XCTAssertTrue(any("feed-playlist-consent").waitForExistence(timeout: 30), "asks before the program is given the address")
        any("feed-allow-site").click()
        let rows = app.descendants(matching: .any).matching(identifier: "feed-row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 30), "the entries are listed")
        XCTAssertEqual(rows.count, 6, "seven entries, one of them removed")

        // A batch quality is chosen from the menu, then everything is downloaded.
        let quality = app.popUpButtons.matching(identifier: "feed-quality").firstMatch
        XCTAssertTrue(quality.waitForExistence(timeout: 5), "the playlist offers a quality choice"); quality.click()
        let seven = app.menuItems["Up to 720p"]
        XCTAssertTrue(seven.waitForExistence(timeout: 5)); seven.click()
        any("feed-select-all").click()
        let go = any("feed-download"); XCTAssertTrue(go.isEnabled); go.click()
        XCTAssertTrue(any("feed-retry").waitForExistence(timeout: 120), "the entry that cannot be had fails alone and is offered again")
        XCTAssertTrue(app.buttons.matching(identifier: "feed-retry").firstMatch.label.contains("1"), "exactly one failed")
        any("feed-close").click()
        let table = any("downloads-table")
        XCTAssertTrue(table.waitForExistence(timeout: 10))
        let completed = app.staticTexts.matching(NSPredicate(format: "value == 'Completed' OR label == 'Completed'"))
        let end = Date().addingTimeInterval(30)
        while Date() < end, completed.count < 5 { Thread.sleep(forTimeInterval: 1) }
        XCTAssertEqual(completed.count, 5, "the five entries that could be had are completed files")
    }
}
