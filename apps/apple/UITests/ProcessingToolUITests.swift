import XCTest

/// The optional media processing tool in the real Debug app, driven by real clicks: its Settings row (install, fail, retry, cancel, remove) and the Download sheet's "Enable Media Processing…" button for a WebM
/// file (progress, then the new choices appear in the same sheet), and that the installed state survives a relaunch. The app installs a small stand-in package built by the scheme
/// (scripts/make-ffmpegtools-ui-fixture.sh) into an isolated folder with an isolated defaults suite, never the real tool or the person's Application Support. Real FFmpeg processing is covered by the unit
/// tests and by ResourceDetectionUITests (-FFmpegDevTool). Nothing is clicked unless the app is frontmost.
final class ProcessingToolUITests: XCTestCase {
    var app: XCUIApplication!
    var work: URL!
    var package: URL!
    var installRoot: URL!
    var suite = ""
    var profile = ""
    let site = "http://127.0.0.1:18766"

    /// Looks in the front window only: asking the whole app makes the accessibility service describe every window, including the web page, on each query, which is the slow part of these tests.
    func any(_ id: String) -> XCUIElement { app.windows.firstMatch.descendants(matching: .any).matching(identifier: id).firstMatch }

    override func setUpWithError() throws {
        continueAfterFailure = false
        package = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BS_FFMPEGTOOLS_FIXTURE"] ?? "/private/tmp/bs-ffmpegtools-ui-fixture")
        work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bs-ui-pt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        installRoot = work.appendingPathComponent("install", isDirectory: true)
        suite = "bs-ui-pt-\(UUID().uuidString)"; profile = "bs-ui-pt-\(UUID().uuidString)"
    }
    override func tearDown() {
        app?.terminate()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        if let work { try? FileManager.default.removeItem(at: work) }
    }

    func send(_ method: String, _ path: String, _ body: Data? = nil) {
        var r = URLRequest(url: URL(string: site + path)!); r.httpMethod = method; r.httpBody = body; r.timeoutInterval = 5
        let sem = DispatchSemaphore(value: 0)
        URLSession(configuration: .ephemeral).dataTask(with: r) { _, _, _ in sem.signal() }.resume()
        _ = sem.wait(timeout: .now() + 8)
    }

    func launch(extra: [String] = [], page: String? = nil) throws {
        app = XCUIApplication()
        app.launchArguments += ["-UITestRoot", profile, "-NSRequiresAquaSystemAppearance", "YES", "-UITestFastScan", "YES",
                                "-FFmpegToolsFixture", package.path, "-FFmpegToolsFixtureRoot", installRoot.path, "-FFmpegToolsFixtureSuite", suite, "-FFmpegToolsFixtureSkipLaunch", "YES"] + extra
        if let page { app.launchArguments += ["-UITestAllowLocalPageOrigin", "YES", "-UIState", "url", "-UIURL", page, "-UIDownloadsScratch", "pt-\(UUID().uuidString.prefix(8))"] }
        else { app.launchEnvironment["BS_SKIP_SETUP"] = "1" }
        // Where the time goes is printed (`TIMING …`), so a slow run can be told apart: launching the app, becoming frontmost, or the first screen being readable.
        let t0 = Date()
        app.launch()
        let t1 = Date()
        app.activate()
        try XCTSkipUnless(app.wait(for: .runningForeground, timeout: 15), "Browser Setu is not frontmost; refusing to send input")
        let t2 = Date()
        _ = app.windows.firstMatch.waitForExistence(timeout: 30)
        let t3 = Date()
        print(String(format: "TIMING %@ launch=%.1fs foreground=%.1fs firstWindow=%.1fs load1=%.2f", name, t1.timeIntervalSince(t0), t2.timeIntervalSince(t1), t3.timeIntervalSince(t2), ProcessInfo.processInfo.systemUptime > 0 ? Self.load1() : 0))
    }
    /// The machine's one-minute load average, to show whether a slow run coincided with a busy Mac.
    static func load1() -> Double { var l = [Double](repeating: 0, count: 3); getloadavg(&l, 3); return l[0] }

    /// Scrolls the pane that holds `id` until it is on screen, then returns it.
    @discardableResult func reveal(_ id: String) -> XCUIElement {
        let e = any(id)
        XCTAssertTrue(e.waitForExistence(timeout: 10), "\(id) exists")
        let window = app.windows.firstMatch
        if !e.isHittable {
            // A few large steps, one scroll and one check each (many small steps, each followed by queries, were the slowest part).
            let holder = app.scrollViews.containing(.any, identifier: id).firstMatch
            let pane = holder.exists ? holder : app.scrollViews.firstMatch
            for _ in 0..<4 where !e.isHittable { pane.scroll(byDeltaX: 0, deltaY: (e.frame.minY > window.frame.maxY || e.frame.minY > window.frame.midY) ? -2500 : 2500) }
        }
        XCTAssertTrue(e.isHittable, "\(id) is on screen: \(e.frame)")
        return e
    }
    /// The app is started with `-UIOpenSettings downloads`: Settings is already on the Downloads pane, so there is no ⌘, key press and no sidebar click.
    static let settingsLaunch = ["-UIOpenSettings", "downloads"]
    func openDownloadsSettings() {
        reveal("processing-tools-status")
    }
    func status() -> String { let e = any("processing-tools-status"); return ((e.value as? String) ?? "") + " " + e.label }
    func waitStatus(contains text: String, seconds: Double = 30) -> Bool {
        let e = app.windows.firstMatch.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
        return e.waitForExistence(timeout: seconds)
    }
    func confirmInstall() {
        let go = app.windows.firstMatch.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Download and Install'")).firstMatch
        XCTAssertTrue(go.waitForExistence(timeout: 15), "the confirmation names what is installed"); go.click()
    }

    // MARK: Settings row

    func testSettingsRowShowsTheStateAndInstallFailsRetriesAndRemovesCleanly() throws {
        try launch(extra: ["-FFmpegToolsFixtureFailFirst", "1"] + Self.settingsLaunch)
        openDownloadsSettings()
        XCTAssertTrue(waitStatus(contains: "Not installed", seconds: 10), "not installed at first: \(status())")
        reveal("processing-tools-install").click(); confirmInstall()
        XCTAssertTrue(waitStatus(contains: "not reachable", seconds: 30), "the failure reason is shown")
        XCTAssertFalse(FileManager.default.fileExists(atPath: installRoot.appendingPathComponent("versions").path), "a failed download leaves nothing active")
        let retry = reveal("processing-tools-install"); XCTAssertEqual(retry.label, "Retry")
        retry.click(); confirmInstall()
        XCTAssertTrue(waitStatus(contains: "Installed · FFmpeg 9.0.2", seconds: 40), "retry installs it: \(status())")
        XCTAssertTrue(FileManager.default.fileExists(atPath: installRoot.appendingPathComponent("versions/9.0.2/ffmpeg/ffprobe").path), "both programs are in place")
        reveal("processing-tools-remove").click()
        let remove = app.buttons["Remove"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5)); remove.click()
        XCTAssertTrue(waitStatus(contains: "Not installed", seconds: 20), "removed: \(status())")
        XCTAssertFalse(FileManager.default.fileExists(atPath: installRoot.appendingPathComponent("versions/9.0.2").path), "the files are gone")
    }

    func testCancellingTheInstallLeavesNothingAndItCanBeStartedAgain() throws {
        try launch(extra: ["-FFmpegToolsFixtureSlow", "YES"] + Self.settingsLaunch)
        openDownloadsSettings()
        reveal("processing-tools-install").click(); confirmInstall()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 8), "Cancel is shown while it installs")
        cancel.click()
        XCTAssertTrue(waitStatus(contains: "Not installed", seconds: 15), "cancelled: \(status())")
        XCTAssertFalse(FileManager.default.fileExists(atPath: installRoot.appendingPathComponent("versions/9.0.2").path), "nothing was activated")
        reveal("processing-tools-install").click(); confirmInstall()
        XCTAssertTrue(waitStatus(contains: "Installed · FFmpeg 9.0.2", seconds: 40), "a new install works after a cancel: \(status())")
    }

    // MARK: Download sheet

    private func webMPage() throws -> String {
        let n = "pt\(Int(Date().timeIntervalSince1970))"
        let webm = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tests/Fixtures/media/bbb-6s-audio.webm")
        send("PUT", "/_media/\(n)/song.webm", try Data(contentsOf: webm))
        send("PUT", "/_media/\(n)/page.html", Data("<html><body><h1>Sound</h1><a href=\"/media/\(n)/song.webm\">song</a></body></html>".utf8))
        return "\(site)/media/\(n)/page.html"
    }
    var lapAt = Date()
    func lap(_ s: String) { let now = Date(); print(String(format: "LAP %.1fs %@", now.timeIntervalSince(lapAt), s)); lapAt = now }
    private func openSheet() {
        lap("page launched")
        let found = any("media-button").waitForExistence(timeout: 30); lap("media-button found")
        if !found { print("DIAG no media-button:\n" + String(app.debugDescription.prefix(6000))) }
        XCTAssertTrue(found, "the link is listed")
        any("media-button").click(); lap("media-button clicked")
        let clip = any("resource-download-song.webm")
        XCTAssertTrue(clip.waitForExistence(timeout: 5)); lap("row found"); clip.click(); lap("row clicked")
        XCTAssertTrue(any("video-download-sheet").waitForExistence(timeout: 6)); lap("sheet found")
    }
    private var m4aChoice: XCUIElement { app.windows.firstMatch.radioButtons.matching(NSPredicate(format: "label CONTAINS 'Audio only (M4A)'")).firstMatch }

    func testTheSheetEnablesTheToolInPlaceShowsTheNewChoicesAndTheStateSurvivesARelaunch() throws {
        let page = try webMPage()
        try launch(extra: ["-FFmpegToolsFixtureSlow", "YES"], page: page)
        openSheet()
        XCTAssertFalse(m4aChoice.exists, "no sound choice before the tool is there")
        let enable = any("processing-tools-offer-enable")
        XCTAssertTrue(enable.waitForExistence(timeout: 5), "the sheet offers to enable media processing"); enable.click()
        confirmInstall()
        XCTAssertTrue(any("processing-tools-offer-progress").waitForExistence(timeout: 8), "progress is shown inside the sheet")
        XCTAssertTrue(m4aChoice.waitForExistence(timeout: 40), "the new choice appears in the same sheet when the install finishes")
        XCTAssertFalse(any("processing-tools-offer-enable").exists, "the offer is gone")
        XCTAssertTrue(any("video-sheet-download").isEnabled)
        app.terminate()

        // Relaunch with the same install folder and settings: the tool is still there, nothing asks again.
        try launch(page: page)
        openSheet()
        XCTAssertTrue(m4aChoice.waitForExistence(timeout: 10), "after a relaunch the choice is still offered")
        XCTAssertFalse(any("processing-tools-offer-enable").exists)
    }

    func testAFailedInstallInTheSheetShowsTheReasonAndRetryWorks() throws {
        let page = try webMPage()
        try launch(extra: ["-FFmpegToolsFixtureFailFirst", "1"], page: page)
        openSheet()
        any("processing-tools-offer-enable").click(); lap("enable clicked"); confirmInstall(); lap("confirmed")
        let retry = any("processing-tools-offer-retry")
        XCTAssertTrue(retry.waitForExistence(timeout: 30), "Retry is shown with the reason"); lap("retry shown")
        XCTAssertTrue(waitStatus(contains: "not reachable", seconds: 5), "the reason is shown"); lap("reason shown")
        XCTAssertFalse(m4aChoice.exists); lap("m4a checked")
        retry.click(); lap("retry clicked"); confirmInstall(); lap("reconfirmed")
        XCTAssertTrue(m4aChoice.waitForExistence(timeout: 40), "after the retry the choice appears"); lap("m4a appeared")
    }
}
