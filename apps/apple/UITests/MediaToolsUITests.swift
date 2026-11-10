import XCTest

/// Advanced media downloads in the real Debug app, driven by real clicks: the Setup Assistant step, Settings, install progress, cancel, failure and retry, and what is remembered across a relaunch.
/// The app is started with a throwaway profile (-UITestRoot), an isolated install folder and an isolated defaults suite (-MediaToolsFixture*, Debug only), and installs a small fixture package built
/// here (a tiny signed program, pinned by digest), never the real tool and never the person's Application Support. The real notarized package is covered by MediaToolsSignedPackageTests.
/// As with the other UI tests, nothing is typed or clicked unless the app is frontmost.
final class MediaToolsUITests: XCTestCase {
    var app: XCUIApplication!
    var work: URL!
    var package: URL!
    var installRoot: URL!
    var suite = ""
    var profile = ""

    /// The front window. Queries look here, not in the whole app: asking the whole app makes the accessibility service describe every window, including the web page, on each query (the slow part).
    var win: XCUIElement { app.windows.firstMatch }
    func any(_ id: String) -> XCUIElement { win.descendants(matching: .any).matching(identifier: id).firstMatch }

    // MARK: Fixture package (built by the scheme's pre-action with scripts/make-mediatools-ui-fixture.sh; this runner is sandboxed and cannot compile)

    override func setUpWithError() throws {
        continueAfterFailure = false
        // The scheme builds this folder before every run (see "Build the media-tools UI fixture" in project.yml). If it is missing the app stops at launch with a clear message: these tests never skip.
        package = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BS_MEDIATOOLS_FIXTURE"] ?? "/private/tmp/bs-mediatools-ui-fixture")
        work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bs-ui-mt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        installRoot = work.appendingPathComponent("install", isDirectory: true)
        suite = "bs-ui-mt-\(UUID().uuidString)"; profile = "bs-ui-mt-\(UUID().uuidString)"
    }

    override func tearDown() {
        app?.terminate()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        if let work { try? FileManager.default.removeItem(at: work) }
    }

    // MARK: Driving the app

    /// Launch arguments that start the app with Settings already open on the Downloads pane.
    let settingsLaunch = ["-UIOpenSettings", "downloads"]
    func launch(extra: [String] = [], skipSetup: Bool = false) throws {
        app = XCUIApplication()
        app.launchArguments += ["-UITestRoot", profile, "-NSRequiresAquaSystemAppearance", "YES", "-MediaToolsFixture", package.path, "-MediaToolsFixtureRoot", installRoot.path,
                                "-MediaToolsFixtureSuite", suite, "-MediaToolsFixtureSkipLaunch", "YES", "-SetupJumpToMedia", "YES"] + extra
        if skipSetup { app.launchEnvironment["BS_SKIP_SETUP"] = "1" }
        app.launch(); app.activate()
        try XCTSkipUnless(app.wait(for: .runningForeground, timeout: 15), "Browser Setu is not frontmost; refusing to send input")
    }
    func button(_ label: String) -> XCUIElement { win.buttons[label] }

    /// Clicks through the Setup Assistant to the media step (Set Up, then Continue until the media switch is there).
    func goToMediaStep() {
        XCTAssertTrue(button("Set Up").waitForExistence(timeout: 20), "the Setup Assistant is shown on a fresh profile")
        button("Set Up").click()          // (the app is started with -SetupJumpToMedia, so this goes straight to the media step)
        for _ in 0..<10 {
            if any("setup-media-toggle").exists { return }
            XCTAssertTrue(button("Continue").waitForExistence(timeout: 5)); button("Continue").click()
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(any("setup-media-toggle").waitForExistence(timeout: 5), "reached the media step")
    }

    /// Prints the time since the previous lap (`LAP …`), to find which step of a slow test is slow.
    var lapAt = Date()
    func lap(_ s: String) { let now = Date(); print(String(format: "LAP %.1fs %@", now.timeIntervalSince(lapAt), s)); lapAt = now }

    /// `opened`: the app was launched with `-UIOpenSettings downloads` (see `settingsLaunch`), so Settings is already on the Downloads pane: no ⌘, key press, no sidebar click.
    func openDownloadsSettings(opened: Bool = false) {
        lap("before settings")
        if !opened {
            XCTAssertEqual(app.state, .runningForeground, "lost foreground; not typing")
            app.typeKey(",", modifierFlags: .command)
            lap("typeKey")
            let sidebar = win.descendants(matching: .any).matching(NSPredicate(format: "label == 'Downloads' OR title == 'Downloads' OR value == 'Downloads'")).firstMatch
            XCTAssertTrue(sidebar.waitForExistence(timeout: 10), "Settings is open"); lap("sidebar found"); sidebar.click(); lap("sidebar clicked")
        }
        let status = any("media-tools-status")
        bringIntoView(status, id: "media-tools-status")
        lap("scrolled to status")
        XCTAssertTrue(status.waitForExistence(timeout: 5), "the media tools row is in Settings › Downloads")
        lap("status exists")
    }
    /// Clicks the install/retry button once it is actually on screen: the settings pane may still be laying out or have the button just below the visible area.
    func tapInstall() {
        let b = any("media-tools-install")
        XCTAssertTrue(b.waitForExistence(timeout: 10), "the install button exists")
        bringIntoView(b, id: "media-tools-install")
        XCTAssertTrue(b.isHittable, "the install button is on screen: \(b.frame)")
        b.click()
    }
    /// Scrolls the pane that holds `e` until it can be clicked, in a few large steps (each step is one scroll and one check: many small steps, each followed by queries, were the slowest part of these tests).
    func bringIntoView(_ e: XCUIElement, id: String) {
        guard e.waitForExistence(timeout: 10), !e.isHittable else { return }
        let holder = app.scrollViews.containing(.any, identifier: id).firstMatch
        let pane = holder.exists ? holder : app.scrollViews.firstMatch
        for _ in 0..<4 {
            let below = e.frame.minY > win.frame.maxY || e.frame.minY > win.frame.midY      // under the visible part, or low in it
            pane.scroll(byDeltaX: 0, deltaY: below ? -2500 : 2500)
            if e.isHittable { return }
        }
    }
    /// The status line only (not messages elsewhere on screen). One predicate query each time, not an enumeration of every text on screen (that is slow over the accessibility connection).
    func text(startingWith prefix: String) -> XCUIElement {
        win.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", prefix, prefix)).firstMatch
    }
    func statusText() -> String {
        for p in ["Installed", "Not installed", "Checking"] { let e = text(startingWith: p); if e.exists { return (e.value as? String) ?? e.label } }
        return ""
    }
    func waitStatus(prefix: String, seconds: Double = 30) -> Bool { text(startingWith: prefix).waitForExistence(timeout: seconds) }
    func waitFailure(containing text: String, seconds: Double = 30) -> Bool {
        let e = win.staticTexts.matching(NSPredicate(format: "(label CONTAINS[c] %@ OR value CONTAINS[c] %@) AND NOT (label BEGINSWITH 'Installed')", text, text)).firstMatch
        return e.waitForExistence(timeout: seconds)
    }
    func confirmInstallDialog() {
        let go = win.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Download and Install'")).firstMatch
        XCTAssertTrue(go.waitForExistence(timeout: 8), "the confirmation names what is installed"); go.click()
    }

    // MARK: 1. Setup, selected by default

    func testSetupMediaStepIsOnByDefaultAndContinueInstallsInTheBackground() throws {
        try launch()
        goToMediaStep()
        let toggle = any("setup-media-toggle")
        XCTAssertEqual("\(toggle.value ?? "")", "1", "selected by default")
        button("Continue").click()
        XCTAssertTrue(button("Start Browsing").waitForExistence(timeout: 8), "Continue leaves setup without waiting for the download")
        let ready = win.staticTexts["Media tools are ready"]
        let progress = win.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Media tools:'")).firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 5) || ready.waitForExistence(timeout: 20), "progress or completion is shown")
        XCTAssertTrue(ready.waitForExistence(timeout: 40), "the package is verified, activated and reported ready")
        button("Start Browsing").click()
        openDownloadsSettings()
        XCTAssertTrue(waitStatus(prefix: "Installed ·"), "Settings reports it installed: \(statusText())")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installRoot.appendingPathComponent("versions/1/mini/mini").path), "the program is in the isolated install folder")
    }

    // MARK: 2. Setup, deselected; Settings later

    func testDeselectedSetupInstallsNothingAndSettingsOffersItWithoutNagging() throws {
        try launch()
        goToMediaStep()
        any("setup-media-toggle").click()
        XCTAssertEqual("\(any("setup-media-toggle").value ?? "")", "0", "easy to deselect")
        button("Continue").click()
        XCTAssertTrue(button("Start Browsing").waitForExistence(timeout: 8))
        XCTAssertFalse(win.staticTexts["Media tools are ready"].exists)
        button("Start Browsing").click()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installRoot.appendingPathComponent("versions").path), "nothing was downloaded")
        openDownloadsSettings()
        XCTAssertTrue(waitStatus(prefix: "Not installed"), statusText())
        // Later, on purpose: Install… asks first, then installs and reports.
        any("media-tools-install").click()
        confirmInstallDialog()
        XCTAssertTrue(waitStatus(prefix: "Installed ·", seconds: 40), "installed from Settings: \(statusText())")
        XCTAssertTrue(any("media-tools-remove").waitForExistence(timeout: 5), "Remove and Repair are offered once installed")
        // Repair asks its own question, not the install one, and "Not Now" changes nothing.
        any("media-tools-repair").click()
        XCTAssertTrue(win.staticTexts["Repair advanced media downloads?"].waitForExistence(timeout: 5), "the confirmation says Repair")
        win.buttons["Not Now"].click()
        XCTAssertTrue(waitStatus(prefix: "Installed ·", seconds: 5), "still installed")
    }

    func testSkippingSetupEntirelyStartsBrowsingAndInstallsNothing() throws {
        try launch()
        XCTAssertTrue(button("Skip Setup").waitForExistence(timeout: 20)); button("Skip Setup").click()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(button("Skip Setup").exists, "the browser is usable")
        XCTAssertFalse(FileManager.default.fileExists(atPath: installRoot.appendingPathComponent("versions").path))
    }

    // MARK: 3 and 5. Progress, cancel, failure, retry

    func testCancelDuringInstallLeavesNothingAndInstallCanBeStartedAgain() throws {
        try launch(extra: ["-MediaToolsFixtureSlow", "YES"] + settingsLaunch, skipSetup: true)
        openDownloadsSettings(opened: true)
        tapInstall(); confirmInstallDialog()
        XCTAssertTrue(any("media-tools-cancel").waitForExistence(timeout: 8), "Cancel is shown while it installs")
        XCTAssertTrue(any("media-tools-progress").exists, "a progress bar is shown")
        any("media-tools-cancel").click()
        XCTAssertTrue(waitStatus(prefix: "Not installed", seconds: 15), "cancelled: \(statusText())")
        XCTAssertFalse(FileManager.default.fileExists(atPath: installRoot.appendingPathComponent("versions/1").path), "nothing was activated")
        tapInstall(); confirmInstallDialog()
        XCTAssertTrue(waitStatus(prefix: "Installed ·", seconds: 40), "a new install works after a cancel: \(statusText())")
    }

    func testAFailedDownloadShowsAReasonAndRetryWorks() throws {
        try launch(extra: ["-MediaToolsFixtureFailFirst", "1"] + settingsLaunch, skipSetup: true)
        openDownloadsSettings(opened: true)
        tapInstall(); confirmInstallDialog()
        let retry = any("media-tools-install")      // the button reads Retry after a failure
        XCTAssertTrue(waitFailure(containing: "download failed", seconds: 30), "the reason is shown: \(statusText())")
        XCTAssertTrue(retry.waitForExistence(timeout: 5)); XCTAssertEqual(retry.label, "Retry")
        retry.click(); confirmInstallDialog()
        XCTAssertTrue(waitStatus(prefix: "Installed ·", seconds: 40), "retry succeeds: \(statusText())")
    }

    // MARK: 6. Relaunch

    func testInstalledStateAndTheDeclinedChoiceSurviveARelaunchWithoutPrompting() throws {
        // Decline in setup, relaunch: setup does not return, nothing installs by itself.
        lap("start")
        try launch(); lap("launched")
        goToMediaStep(); lap("at media step"); any("setup-media-toggle").click(); button("Continue").click(); lap("toggled+continue")
        XCTAssertTrue(button("Start Browsing").waitForExistence(timeout: 8)); button("Start Browsing").click(); lap("start browsing")
        app.terminate(); lap("terminated")
        try launch(extra: settingsLaunch); lap("relaunched")
        XCTAssertFalse(button("Set Up").exists, "setup is not shown again"); lap("no setup check")
        XCTAssertFalse(FileManager.default.fileExists(atPath: installRoot.appendingPathComponent("versions").path), "no silent install after declining")
        openDownloadsSettings(opened: true)
        XCTAssertTrue(waitStatus(prefix: "Not installed"), statusText()); lap("not installed status")
        tapInstall(); lap("tapInstall"); confirmInstallDialog(); lap("confirmed")
        XCTAssertTrue(waitStatus(prefix: "Installed ·", seconds: 40)); lap("installed")
        // Relaunch again: still installed (verified in the background, not reinstalled).
        app.terminate()
        try launch(extra: settingsLaunch)
        openDownloadsSettings(opened: true)
        XCTAssertTrue(waitStatus(prefix: "Installed ·", seconds: 30), "installed state persists: \(statusText())")
    }

    // MARK: 4. Download sheet fallback

    func put(_ path: String, _ body: String) -> Bool {
        var r = URLRequest(url: URL(string: "http://127.0.0.1:18766" + path)!); r.httpMethod = "PUT"; r.httpBody = Data(body.utf8); r.timeoutInterval = 5
        let sem = DispatchSemaphore(value: 0); var ok = false
        URLSession(configuration: .ephemeral).dataTask(with: r) { _, resp, _ in ok = ((resp as? HTTPURLResponse)?.statusCode ?? 0) < 300; sem.signal() }.resume()
        _ = sem.wait(timeout: .now() + 8); return ok
    }

    func testTheDownloadSheetOffersTheToolsOnlyWhenAPageNeedsThemAndThenInstallsThemInPlace() throws {
        let n = "mt\(Int(Date().timeIntervalSince1970))"
        XCTAssertTrue(put("/_media/\(n)/page.html", "<html><body><h1>Videos</h1><a href=\"https://www.youtube.com/watch?v=dQw4w9WgXcQ\">a YouTube video</a></body></html>"), "the download fixture server (started by the scheme on 18766) is not answering")
        try launch(extra: ["-UIState", "url", "-UIURL", "http://127.0.0.1:18766/media/\(n)/page.html", "-UIDownloadsScratch", "mt-\(n)", "-UITestFastScan", "YES"], skipSetup: true)
        XCTAssertTrue(any("media-button").waitForExistence(timeout: 14)); Thread.sleep(forTimeInterval: 2.5)
        any("media-button").click()
        let analyze = any("resource-analyze-YouTube video")
        XCTAssertTrue(analyze.waitForExistence(timeout: 5)); analyze.click()
        XCTAssertTrue(any("video-download-sheet").waitForExistence(timeout: 8))
        // The page needs the extractor and none is installed: one quiet button, no automatic install, and the sheet starts no download.
        let enable = any("media-tools-offer-enable")
        if !enable.waitForExistence(timeout: 8) {
            let sheet = any("video-download-sheet")
            print("SHEET-DUMP " + sheet.descendants(matching: .any).allElementsBoundByIndex.prefix(60).map { "\($0.elementType.rawValue):\($0.identifier):\($0.label)\(($0.value as? String).map { "=" + $0 } ?? "")" }.joined(separator: " | "))
        }
        XCTAssertTrue(enable.exists, "Enable Advanced Media Downloads is offered here")
        XCTAssertFalse(any("video-sheet-download").exists, "nothing pretends a download started")
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installRoot.appendingPathComponent("versions").path), "nothing installed on its own")
        enable.click(); confirmInstallDialog()
        XCTAssertTrue(any("media-tools-offer-progress").waitForExistence(timeout: 10) || any("extractor-consent").waitForExistence(timeout: 20), "progress is shown in the sheet")
        // When it finishes the same sheet moves on by itself: the offer is gone and the extractor flow (its consent prompt) takes over.
        XCTAssertTrue(any("extractor-consent").waitForExistence(timeout: 40) || any("video-sheet-use-extractor").waitForExistence(timeout: 5), "the sheet uses the extractor now")
        XCTAssertFalse(enable.exists, "the offer is gone")
        app.typeKey(.escape, modifierFlags: [])
    }
}
