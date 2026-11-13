import XCTest

/// Opens real websites in the real Debug app (a throwaway profile; downloads go to a scratch folder) and records what the browser itself does: whether the toolbar indicator and the media picker
/// find the videos, whether the picker says they can be downloaded, and — only for sites that publish openly licensed or deliberate test media — whether choosing Download really starts a download.
/// It enters no token and makes no request to any provider's API. Results are printed as REALSITE lines: observations about live websites, which change, not assertions about them.
final class RealSitesUITests: XCTestCase {
    var app: XCUIApplication!
    func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    func text(_ id: String) -> String { ((any(id).value as? String).flatMap { $0.isEmpty ? nil : $0 }) ?? any(id).label }
    override func tearDown() { app?.terminate() }

    private func lines(_ contains: [String], max: Int = 14, width: Int = 170) -> [String] {
        app.debugDescription.split(separator: "\n").filter { l in contains.contains { l.contains($0) } }.prefix(max).map { String($0.trimmingCharacters(in: .whitespaces).prefix(width)) }
    }

    func look(_ name: String, _ url: String, download: Bool = false, settle: Double = 14) throws {
        continueAfterFailure = true
        let scratch = "real-\(name)-\(Int(Date().timeIntervalSince1970))"
        print("REALSITE \(name): scratch folder=\(scratch)")
        app = XCUIApplication()
        app.launchArguments += ["-UITestRoot", "bs-ui-real-\(UUID().uuidString)", "-UIState", "url", "-UIURL", url, "-UIDownloadsScratch", scratch, "-NSRequiresAquaSystemAppearance", "YES"]
        app.launch(); app.activate()
        try XCTSkipUnless(app.wait(for: .runningForeground, timeout: 15), "Browser Setu is not frontmost; refusing to send input")
        Thread.sleep(forTimeInterval: settle)                       // the page loads and its players report
        let badge = any("media-button")
        let hasBadge = badge.waitForExistence(timeout: 5)
        print("REALSITE \(name): toolbar indicator=\(hasBadge ? badge.label : "none")")
        guard app.state == .runningForeground else { return }
        app.menuBars.menuBarItems["Library"].click()
        let find = app.menuBars.menuItems["Find Downloadable Media"]
        guard find.waitForExistence(timeout: 5) else { print("REALSITE \(name): no Find Downloadable Media menu item"); return }
        find.click()
        Thread.sleep(forTimeInterval: 5)
        print("REALSITE \(name): provider panel=\(any("provider-name").exists ? text("provider-name") : "none (generic site)")")
        // The picker's own rows: each is one element whose label holds the name, kind, quality, host and status.
        let rowQuery = app.descendants(matching: .any).matching(identifier: "media-row")
        _ = rowQuery.firstMatch.waitForExistence(timeout: 6)
        let rowLabels = rowQuery.allElementsBoundByIndex.prefix(8).map { String($0.label.prefix(150)) }
        print("REALSITE \(name): picker rows (\(rowQuery.count))=\(rowLabels.isEmpty ? "(none)" : rowLabels.joined(separator: " || "))")
        let canRows = (0..<min(rowQuery.count, 40)).map { rowQuery.element(boundBy: $0) }.filter { $0.label.contains("Can download") }
        print("REALSITE \(name): rows marked Can download=\(canRows.count)")
        let shot = app.windows.firstMatch.safeAttachment(); shot.name = name; shot.lifetime = .keepAlways; add(shot)
        guard download, app.state == .runningForeground else { return }

        // Choose the first item the picker says can be downloaded (else the first that can be opened), then Download: the real route a person takes.
        guard let target = canRows.first ?? (rowQuery.count > 0 ? rowQuery.firstMatch : nil) else { print("REALSITE \(name): nothing to choose"); return }
        target.click()
        Thread.sleep(forTimeInterval: 1)
        let download = any("media-download"), look = any("media-look")
        if look.exists { look.click(); Thread.sleep(forTimeInterval: 6); print("REALSITE \(name): looked at qualities") }
        if download.waitForExistence(timeout: 3) { print("REALSITE \(name): Download button enabled=\(download.isEnabled) title=\(download.label)"); if download.isEnabled { download.click(); print("REALSITE \(name): clicked Download") } }
        else { print("REALSITE \(name): no Download button; media-look present=\(look.exists)") }
        Thread.sleep(forTimeInterval: 2)
        // Show the Downloads window and read it.
        app.typeKey(.escape, modifierFlags: [])
        app.menuBars.menuBarItems["Library"].click()
        let show = app.menuBars.menuItems["Show Downloads"]
        if show.waitForExistence(timeout: 4) { show.click() }
        Thread.sleep(forTimeInterval: 15)
        let table = any("downloads-table")
        _ = table.waitForExistence(timeout: 8)
        let cells = table.staticTexts.allElementsBoundByIndex.prefix(18).map { (($0.value as? String).flatMap { $0.isEmpty ? nil : $0 }) ?? $0.label }
        print("REALSITE \(name): downloads table=\(cells.isEmpty ? "(empty or not shown)" : cells.joined(separator: " | "))")
        print("REALSITE \(name): scratch folder (check on disk)=\(scratch)")
    }

    // Openly licensed or deliberate test media: these are downloaded for real (small files, scratch folder).
    func testW3SchoolsHTML5Video() throws { try look("w3schools-html5-video", "https://www.w3schools.com/html/html5_video.asp", download: true) }
    func testMDNVideoElement() throws { try look("mdn-video-element", "https://developer.mozilla.org/en-US/docs/Web/HTML/Element/video", download: true) }
    func testSamplelibLinks() throws { try look("samplelib-mp4-links", "https://samplelib.com/sample-mp4.html", download: true) }
    func testInternetArchiveBigBuckBunny() throws { try look("internet-archive-bbb", "https://archive.org/details/BigBuckBunny_124", download: true) }
    // Looked at only: streaming test pages (their streams are long), commercial providers, and pages whose media is not offered for download.
    func testHlsJsDemo() throws { try look("hlsjs-demo", "https://hls-js.netlify.app/demo/") }
    func testShakaDemo() throws { try look("shaka-demo", "https://shaka-player-demo.appspot.com/demo/") }
    func testDashJsReferencePlayer() throws { try look("dashjs-reference", "https://reference.dashif.org/dash.js/latest/samples/dash-if-reference-player/index.html") }
    func testAppleStreamingExamples() throws { try look("apple-hls-examples", "https://developer.apple.com/streaming/examples/") }
    func testWikimediaCommonsVideo() throws { try look("wikimedia-commons", "https://commons.wikimedia.org/wiki/File:Big_Buck_Bunny_4K.webm") }
    func testPexelsVideos() throws { try look("pexels-videos", "https://www.pexels.com/search/videos/ocean/") }
    func testPixabayVideos() throws { try look("pixabay-videos", "https://pixabay.com/videos/search/ocean/") }
    func testDailymotion() throws { try look("dailymotion", "https://www.dailymotion.com/") }
    func testVimeoPublicPage() throws { try look("vimeo", "https://vimeo.com/76979871") }
    func testYouTubePage() throws { try look("youtube", "https://www.youtube.com/watch?v=dQw4w9WgXcQ") }
}
