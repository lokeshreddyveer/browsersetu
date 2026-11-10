import XCTest

/// The page's right-click menu offers "Download from This Page" (find media, collect images, LinkGrabber, explore) on an ordinary web page, and choosing one reaches the Downloads window.
/// Real clicks in the real Debug app; the page is served by the fixture server (18766, started by the scheme); throwaway profile and scratch downloads folder.
final class PageDownloadMenuUITests: XCTestCase {
    var app: XCUIApplication!
    let site = "http://127.0.0.1:18766"
    func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    override func tearDown() { app?.terminate() }

    func put(_ path: String, _ body: Data) {
        var r = URLRequest(url: URL(string: site + "/_media/" + path)!); r.httpMethod = "PUT"; r.httpBody = body; r.timeoutInterval = 5
        let sem = DispatchSemaphore(value: 0)
        URLSession(configuration: .ephemeral).dataTask(with: r) { _, _, _ in sem.signal() }.resume(); _ = sem.wait(timeout: .now() + 8)
    }

    func testTheDownloadChoicesAreInOneSubmenuOnAPageAndLeadToDownloads() throws {
        let n = "pm\(Int(Date().timeIntervalSince1970))"
        put("\(n)/page.html", Data("<html><body style='margin:0;background:#eee'><h1>Course</h1><p>Plain page</p></body></html>".utf8))
        app = XCUIApplication()
        app.launchArguments += ["-UITestRoot", "bs-ui-pm-\(UUID().uuidString)", "-UITestAllowLocalPageOrigin", "YES", "-UIState", "url", "-UIURL", "\(site)/media/\(n)/page.html",
                                "-UIDownloadsScratch", "pm-\(n)", "-NSRequiresAquaSystemAppearance", "YES", "-UITestFastScan", "YES"]
        app.launch(); app.activate()
        try XCTSkipUnless(app.wait(for: .runningForeground, timeout: 15), "Browser Setu is not frontmost; refusing to send input")

        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 2)                          // let the page finish loading before the click
        web.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.7)).rightClick()
        let submenu = app.menuItems["Download from This Page"]
        XCTAssertTrue(submenu.waitForExistence(timeout: 8), "the page's right-click menu offers the download choices")
        submenu.click()
        for title in ["Find Media…", "Collect Images", "LinkGrabber…", "Explore This Website…"] {
            XCTAssertTrue(app.menuItems[title].waitForExistence(timeout: 5), "\(title) is in the submenu")
        }
        app.menuItems["LinkGrabber…"].click()
        XCTAssertTrue(any("downloads-collect").waitForExistence(timeout: 15), "the Downloads window is opened")
    }
}
