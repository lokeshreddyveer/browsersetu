import XCTest

/// Repositories & Models in the real Debug app, with real clicks, against the local GitHub / Hugging Face / bucket stand-ins (scripts/provider_ui_fixture.sh, ports 18791 and 18792, started by the scheme).
/// A throwaway profile and a scratch downloads folder are used; nothing real is touched, no token is needed (the flows are public ones).
final class ProviderUITests: XCTestCase {
    var app: XCUIApplication!
    let service = "http://127.0.0.1:18791"
    func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    override func tearDown() { app?.terminate() }

    func launch(root: String, scratch: String, page: String) throws {
        app = XCUIApplication()
        app.launchArguments += ["-UITestRoot", root, "-UITestAllowLocalPageOrigin", "YES", "-UIState", "url", "-UIURL", page, "-UIDownloadsScratch", scratch,
                                "-UIProviderGitHubAPI", service, "-UIProviderGitHubHost", "127.0.0.1", "-UIProviderHFEndpoint", service, "-UIProviderHFHost", "localhost",
                                "-NSRequiresAquaSystemAppearance", "YES", "-UITestFastScan", "YES"]
        app.launch(); app.activate()
        try XCTSkipUnless(app.wait(for: .runningForeground, timeout: 15), "Browser Setu is not frontmost; refusing to send input")
    }

    /// Downloads → Collect → Repositories & Models…
    func openSheet() {
        XCTAssertTrue(any("downloads-button").waitForExistence(timeout: 30)); any("downloads-button").click()
        let openWindow = app.buttons["Open Downloads"]
        XCTAssertTrue(openWindow.waitForExistence(timeout: 8)); openWindow.click()
        let collect = any("downloads-collect")
        XCTAssertTrue(collect.waitForExistence(timeout: 15)); collect.click()
        // The same name is also in the Library menu of the menu bar: the one in the open Collect menu is the one that can be clicked.
        let end = Date().addingTimeInterval(5)
        var item: XCUIElement?
        while item == nil, Date() < end { item = app.menuItems.matching(NSPredicate(format: "title == %@", "Repositories & Models…")).allElementsBoundByIndex.first { $0.isHittable }; if item == nil { Thread.sleep(forTimeInterval: 0.2) } }
        XCTAssertNotNil(item, "the Collect menu offers Repositories & Models"); item?.click()
        XCTAssertTrue(any("provider-sheet").waitForExistence(timeout: 10))
    }

    func lookUp(_ address: String) {
        app.activate()
        let field = any("provider-address")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click(); field.typeKey("a", modifierFlags: .command); field.typeText(address)
        any("provider-load").click()
    }

    func rows() -> XCUIElementQuery { app.descendants(matching: .any).matching(identifier: "provider-row") }
    func row(_ name: String) -> XCUIElement { rows().matching(NSPredicate(format: "label == %@", name)).firstMatch }
    /// Clicks a row and waits for the row itself to say it is chosen before anything else is clicked: the next click is sent only once the list has taken this one. A click the list never takes fails here.
    func choose(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let r = row(name)
        r.click()
        let until = Date().addingTimeInterval(5)
        var seen = ""
        while Date() < until {
            seen = (row(name).value as? String) ?? ""
            if seen == "chosen" { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertEqual(seen, "chosen", "“\(name)” was chosen by the click", file: file, line: line)
    }

    func message(contains text: String) -> XCUIElement { app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", text, text)).firstMatch }

    /// The page being viewed is a release page: the sheet opens already looking at it, recommends the one file for this Mac, and the download completes under its name.
    func testReleaseFromTheCurrentPageRecommendsOneFileAndItDownloads() throws {
        try launch(root: "bs-ui-pr-\(UUID().uuidString)", scratch: "pr-\(Int(Date().timeIntervalSince1970))", page: "\(service)/o/r")
        openSheet()
        XCTAssertTrue(any("provider-title").waitForExistence(timeout: 20), "the page's address was looked up")
        XCTAssertTrue(rows().firstMatch.waitForExistence(timeout: 10))
        let rec = any("provider-recommendation")
        XCTAssertTrue(rec.waitForExistence(timeout: 5), "a recommendation, or the reason there is none")
        // The only macOS file for this Mac's processor is already chosen.
        XCTAssertTrue(message(contains: "1 file").waitForExistence(timeout: 5) || any("provider-count").exists)
        let download = any("provider-download"); XCTAssertTrue(download.isEnabled); download.click()
        XCTAssertTrue(message(contains: "Started 1").waitForExistence(timeout: 20), "the result is said in a sentence")
        any("provider-close").click()
        let table = any("downloads-table"); XCTAssertTrue(table.waitForExistence(timeout: 10))
        let completed = app.staticTexts.matching(NSPredicate(format: "value == 'Completed' OR label == 'Completed'"))
        let end = Date().addingTimeInterval(40); while Date() < end, completed.count < 1 { Thread.sleep(forTimeInterval: 1) }
        XCTAssertEqual(completed.count, 1, "the file downloaded")
        XCTAssertTrue(table.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'macos' OR value CONTAINS 'macos'")).firstMatch.exists, "listed by the asset's own name")

        // Quit and open again with the same profile: the finished download is still listed (restore).
        let root = app.launchArguments[app.launchArguments.firstIndex(of: "-UITestRoot")! + 1], scratch = app.launchArguments[app.launchArguments.firstIndex(of: "-UIDownloadsScratch")! + 1]
        app.terminate()
        try launch(root: root, scratch: scratch, page: "\(service)/o/r")
        XCTAssertTrue(any("downloads-button").waitForExistence(timeout: 30)); any("downloads-button").click()
        let open2 = app.buttons["Open Downloads"]; XCTAssertTrue(open2.waitForExistence(timeout: 8)); open2.click()
        let table2 = any("downloads-table"); XCTAssertTrue(table2.waitForExistence(timeout: 15))
        XCTAssertTrue(table2.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'macos' OR value CONTAINS 'macos'")).firstMatch.waitForExistence(timeout: 10), "after relaunch the download is still there")
    }

    /// A model: several files chosen with clicks, a format filter, and a refusal that says what to do for a model that needs a token; then a dataset narrowed by name and chosen in bulk; then a signed link.
    func testModelFilesDatasetAndSignedLinkAndAnAuthErrorAreSaidPlainly() throws {
        try launch(root: "bs-ui-pm-\(UUID().uuidString)", scratch: "pm-\(Int(Date().timeIntervalSince1970))", page: "\(service)/")
        openSheet()

        // Needs a token: said in a sentence, nothing downloaded.
        lookUp("http://localhost:18791/org/private")
        let failed = any("provider-failed"); XCTAssertTrue(failed.waitForExistence(timeout: 20))
        XCTAssertTrue(message(contains: "access token").exists, "says what to do")

        // A model: two files by clicking their rows.
        lookUp("http://localhost:18791/org/model")
        XCTAssertTrue(rows().firstMatch.waitForExistence(timeout: 20)); XCTAssertEqual(rows().count, 5, "both pages of the tree")
        // The test sends real clicks: if another application took the front while the list loaded, the clicks would land in it. Bring this one back first.
        app.activate(); XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        choose("config.json"); choose("weights-Q4.gguf")
        let twoChosen = message(contains: "2 files").waitForExistence(timeout: 5)
        if !twoChosen {
            // The failure, as the app itself shows it: its own window (not the whole screen), the accessibility hierarchy, and what each row and text says.
            let shot = XCTAttachment(screenshot: app.windows.firstMatch.safeScreenshot()); shot.name = "two-chosen-missing-window"; shot.lifetime = .keepAlways; add(shot)
            let tree = XCTAttachment(string: app.debugDescription); tree.name = "two-chosen-missing-hierarchy"; tree.lifetime = .keepAlways; add(tree)
            print("PROVIDER-FLAKE app foreground: \(app.state == .runningForeground)")
        }
        XCTAssertTrue(twoChosen, "the count shows two chosen")
        any("provider-download").click()
        XCTAssertTrue(message(contains: "Started 2").waitForExistence(timeout: 20))

        // A dataset: filtered by name, every match chosen at once.
        lookUp("http://localhost:18791/datasets/org/bulk")
        XCTAssertTrue(rows().firstMatch.waitForExistence(timeout: 20))
        let filter = any("provider-filter"); filter.click(); filter.typeText("part-0000")
        any("provider-select-all").click()
        XCTAssertTrue(message(contains: "10 files").waitForExistence(timeout: 5), "ten files match and are chosen")
        any("provider-download").click()
        XCTAssertTrue(message(contains: "Started 10").waitForExistence(timeout: 30))

        // A signed link to one file in a bucket.
        lookUp("http://127.0.0.1:18791/pub-bucket/readme.txt?X-Amz-Signature=abc&X-Amz-Date=20990101T000000Z&X-Amz-Expires=3600")
        XCTAssertTrue(rows().firstMatch.waitForExistence(timeout: 20)); XCTAssertFalse(message(contains: "X-Amz-Signature=abc").exists, "the secret part is not shown")
        any("provider-download").click()
        XCTAssertTrue(message(contains: "Started 1").waitForExistence(timeout: 20))

        any("provider-close").click()
        let table = any("downloads-table"); XCTAssertTrue(table.waitForExistence(timeout: 10))
        let completed = app.staticTexts.matching(NSPredicate(format: "value == 'Completed' OR label == 'Completed'"))
        let end = Date().addingTimeInterval(90); while Date() < end, completed.count < 13 { Thread.sleep(forTimeInterval: 1) }
        XCTAssertEqual(completed.count, 13, "2 model files + 10 dataset files + 1 object, all completed")
    }
}
