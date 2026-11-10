import XCTest

/// Download category indicators in the real Debug app against a controlled local page (scripts/download_fixture_server.py on 18766, started by the scheme): the page links to files of several kinds,
/// a video watch page, and adds one more link after it has loaded. Real clicks; the app must be frontmost.
final class ResourceDetectionUITests: XCTestCase {
    var app: XCUIApplication!
    let site = "http://127.0.0.1:18766"
    func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    override func tearDown() { app?.terminate() }

    func send(_ method: String, _ path: String, _ body: Data? = nil) -> Data {
        var r = URLRequest(url: URL(string: site + path)!); r.httpMethod = method; r.httpBody = body; r.timeoutInterval = 5
        let sem = DispatchSemaphore(value: 0); var out = Data()
        URLSession(configuration: .ephemeral).dataTask(with: r) { d, _, _ in out = d ?? Data(); sem.signal() }.resume()
        _ = sem.wait(timeout: .now() + 8)
        return out
    }
    func hits(_ key: String) -> Int {
        ((try? JSONSerialization.jsonObject(with: send("GET", "/_media_hits")) as? [String: Any])?["hits"] as? [String: Int])?[key] ?? 0
    }

    func testCategoriesAppearAndDownload() throws {
        let n = "rd\(Int(Date().timeIntervalSince1970))"
        let html = """
        <html><body><h1>Resources</h1>
        <a href="/media/\(n)/photo.png">photo</a> <a href="/media/\(n)/manual.pdf">manual</a> <a href="/media/\(n)/bundle.zip">bundle</a>
        <a href="/media/\(n)/main.swift">source</a> <a href="https://www.w3schools.com/html/mov_bbb.mp4">clip</a> <a href="/media/\(n)/index.php">just a page</a>
        <a href="https://www.youtube.com/watch?v=dQw4w9WgXcQ">a video card</a>
        <script>setTimeout(function(){ var a=document.createElement('a'); a.href='/media/\(n)/late.csv'; a.textContent='late'; document.body.appendChild(a); }, 1200);</script>
        </body></html>
        """
        _ = send("PUT", "/_media/\(n)/page.html", Data(html.utf8))
        for f in ["photo.png", "manual.pdf", "bundle.zip", "main.swift", "late.csv"] { _ = send("PUT", "/_media/\(n)/\(f)", Data(repeating: 0x41, count: 4096)) }
        app = XCUIApplication()
        app.launchArguments += ["-UITestRoot", "bs-ui-rd-\(UUID().uuidString)", "-UIState", "url", "-UIURL", "\(site)/media/\(n)/page.html", "-UIDownloadsScratch", "rd-\(n)", "-NSRequiresAquaSystemAppearance", "YES", "-UITestFastScan", "YES"]
        app.launch(); app.activate()
        try XCTSkipUnless(app.wait(for: .runningForeground, timeout: 15), "Browser Setu is not frontmost; refusing to send input")

        XCTAssertTrue(any("category-image").waitForExistence(timeout: 12), "image indicator")
        XCTAssertTrue(any("category-document").exists); XCTAssertTrue(any("category-archive").exists); XCTAssertTrue(any("category-code").exists)
        XCTAssertTrue(any("media-button").exists, "video card counted as a video")
        XCTAssertFalse(any("category-config").exists); XCTAssertFalse(any("category-other").exists, "a .php link is a page, not a file")
        // The link added after load shows up without any interaction.
        XCTAssertTrue(any("category-data").waitForExistence(timeout: 14), "late link detected")
        Thread.sleep(forTimeInterval: 2)          // the last automatic re-read of the page has run; chips are stable
        print("RESOURCE chips: image/document/archive/code/video/data present")

        // A local address found on a page is refused by the download engine (a page cannot point the browser at the local network), so the local file is not fetched; the notice says so.
        any("category-archive").click()
        XCTAssertTrue(any("category-download-selected").waitForExistence(timeout: 4))
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.safeScreenshot()); shot.name = "archive-popover"; shot.lifetime = .keepAlways; add(shot)
        let before = hits("\(n)/bundle.zip")
        any("category-download-selected").click()
        Thread.sleep(forTimeInterval: 4)
        XCTAssertEqual(hits("\(n)/bundle.zip"), before, "a page-origin download of a local address must not be fetched")

        // A real public file (the same small test clip the HTML tutorial site hosts) goes through the same route and is fetched for real.
        any("media-button").click()
        let rows = app.descendants(matching: .any).matching(identifier: "resource-row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 4))
        let clip = any("resource-download-mov_bbb.mp4")
        XCTAssertTrue(clip.waitForExistence(timeout: 3), "the public clip is listed as a video")
        clip.click()
        // The Download button opens the sheet; the original file is the default choice.
        XCTAssertTrue(any("video-sheet-download").waitForExistence(timeout: 6))
        any("video-sheet-download").click()
        XCTAssertTrue(any("video-sheet-done").waitForExistence(timeout: 60), "the clip was saved")
        app.buttons["Done"].firstMatch.click()
        let table = any("downloads-table")
        XCTAssertTrue(table.waitForExistence(timeout: 8))
        let cells = table.staticTexts.allElementsBoundByIndex.map { ($0.value as? String) ?? $0.label }
        print("RESOURCE downloads table: \(cells.prefix(12))")
        XCTAssertTrue(cells.contains("Completed") && cells.contains("788 KB"), "the clip completed (788 KB); the local-address attempt shows Failed")
        app.windows.allElementsBoundByIndex.first { $0.title.contains("Downloads") }?.buttons[XCUIIdentifierCloseWindow].click()

        // The video card is listed as not resolved, with an Open button and no Download.
        any("media-button").click()
        XCTAssertTrue(any("resource-row").waitForExistence(timeout: 4))
        XCTAssertGreaterThanOrEqual(app.descendants(matching: .any).matching(identifier: "resource-row").count, 2)
        XCTAssertTrue(any("resource-analyze-YouTube video").exists, "the video card has a Download button that opens the analysis sheet")
        print("RESOURCE video rows: \(app.descendants(matching: .any).matching(identifier: "resource-row").count)")
    }

    /// The Download button on a video entry, driven with real clicks: the sheet, consent, an audio-only (M4A) save of a public test clip, and the honest sheet for a YouTube link.
    func testVideoDownloadSheetSavesAudioAfterConsentAndExplainsAProviderVideo() throws {
        let n = "vs\(Int(Date().timeIntervalSince1970))"
        let html = """
        <html><body><h1>Videos</h1>
        <a href="https://www.w3schools.com/html/mov_bbb.mp4">clip</a>
        <a href="https://www.youtube.com/watch?v=dQw4w9WgXcQ">a YouTube video</a>
        </body></html>
        """
        _ = send("PUT", "/_media/\(n)/page.html", Data(html.utf8))
        app = XCUIApplication()
        app.launchArguments += ["-UITestRoot", "bs-ui-vs-\(UUID().uuidString)", "-UIState", "url", "-UIURL", "\(site)/media/\(n)/page.html", "-UIDownloadsScratch", "vs-\(n)", "-NSRequiresAquaSystemAppearance", "YES", "-UITestFastScan", "YES"]
        app.launch(); app.activate()
        try XCTSkipUnless(app.wait(for: .runningForeground, timeout: 15), "Browser Setu is not frontmost; refusing to send input")
        XCTAssertTrue(any("media-button").waitForExistence(timeout: 14))
        Thread.sleep(forTimeInterval: 2.5)                                  // the page's automatic re-reads are done

        // The YouTube entry: a sheet that says what is and is not possible, and starts nothing.
        any("media-button").click()
        let analyze = any("resource-analyze-YouTube video")
        XCTAssertTrue(analyze.waitForExistence(timeout: 4)); analyze.click()
        XCTAssertTrue(any("video-download-sheet").waitForExistence(timeout: 6))
        let status = any("video-sheet-status")
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        print("VIDEOSHEET youtube status: \(status.label) \(status.value as? String ?? "")")
        XCTAssertFalse(any("video-sheet-download").exists, "no download is offered for a YouTube video")
        XCTAssertTrue(any("video-sheet-open").exists)
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 1)

        // The public clip: choose audio only, answer the consent prompt, save.
        any("media-button").click()
        let clip = any("resource-download-mov_bbb.mp4")
        XCTAssertTrue(clip.waitForExistence(timeout: 4)); clip.click()
        XCTAssertTrue(any("video-sheet-download").waitForExistence(timeout: 6))
        app.radioButtons.matching(NSPredicate(format: "label CONTAINS 'Audio only (M4A)'")).firstMatch.click()
        XCTAssertTrue(any("consent-prompt").waitForExistence(timeout: 3), "converting asks first")
        XCTAssertFalse(any("video-sheet-download").isEnabled, "Download waits for the answer")
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.safeScreenshot()); shot.name = "video-sheet-consent"; shot.lifetime = .keepAlways; add(shot)
        any("consent-once").click()
        XCTAssertTrue(waitEnabled(any("video-sheet-download")))
        any("video-sheet-download").click()
        XCTAssertTrue(any("video-sheet-done").waitForExistence(timeout: 60), "the audio was saved")
        let saved = app.staticTexts.matching(NSPredicate(format: "value CONTAINS '.m4a' OR label CONTAINS '.m4a'")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 3), "the sheet names the .m4a file")
        print("VIDEOSHEET saved: \((saved.value as? String) ?? saved.label)")
    }

    // MARK: HLS and DASH playlists: found on the page, read, qualities listed

    /// A page whose player points at a stream playlist. The picker lists it, reading it lists the real qualities (no media is downloaded: the playlists name segments the fixture does not serve).
    private func streamPage(_ fileName: String, _ body: String, element: String, prepare: ((String) throws -> Void)? = nil) throws {
        let n = "st\(Int(Date().timeIntervalSince1970))\(Int.random(in: 100...999))"
        try prepare?(n)
        _ = send("PUT", "/_media/\(n)/\(fileName)", Data(body.utf8))
        _ = send("PUT", "/_media/\(n)/page.html", Data("<html><body><h1>Stream</h1><\(element) src=\"/media/\(n)/\(fileName)\" controls width=320></\(element)></body></html>".utf8))
        app = XCUIApplication()
        app.launchArguments += ["-UITestRoot", "bs-ui-st-\(UUID().uuidString)", "-UITestAllowLocalPageOrigin", "YES", "-UIState", "url", "-UIURL", "\(site)/media/\(n)/page.html", "-UIDownloadsScratch", "st-\(n)", "-NSRequiresAquaSystemAppearance", "YES", "-UITestFastScan", "YES"]
        app.launch(); app.activate()
        try XCTSkipUnless(app.wait(for: .runningForeground, timeout: 15), "Browser Setu is not frontmost; refusing to send input")
        XCTAssertTrue(any("media-button").waitForExistence(timeout: 30), "the player is detected")
        Thread.sleep(forTimeInterval: 1)
        app.menuBars.menuBarItems["Library"].click()
        let find = app.menuBars.menuItems["Find Downloadable Media"]
        XCTAssertTrue(find.waitForExistence(timeout: 5)); find.click()
        // The player also fetches the variant playlists, so several rows may be listed: the one for the page's own playlist is chosen by name.
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'media-row' AND (value BEGINSWITH %@ OR label BEGINSWITH %@)", fileName, fileName)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the playlist \(fileName) is listed"); row.click()
    }
    private var qualityTexts: XCUIElementQuery { app.descendants(matching: .any).matching(NSPredicate(format: "identifier != 'media-row' AND identifier != 'media-button' AND (label CONTAINS '720' OR value CONTAINS '720')")) }

    func testAnHLSPlaylistOnAPageIsListedAndItsQualitiesAreRead() throws {
        let master = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360\nv360.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1280x720\nv720.m3u8\n"
        try streamPage("master.m3u8", master, element: "video")
        let look = app.buttons["Look at Qualities"]
        XCTAssertTrue(look.waitForExistence(timeout: 6), "a stream offers reading its qualities before any download"); look.click()
        XCTAssertTrue(qualityTexts.firstMatch.waitForExistence(timeout: 20), "the 720p quality is listed after reading the playlist (not just a row named v720.m3u8)")
        let status = app.staticTexts.matching(NSPredicate(format: "identifier == 'media-outputs' AND value CONTAINS 'Unavailable'")).firstMatch
        XCTAssertFalse(status.exists, "the playlist was read, not refused")
        let download = any("media-download")
        if !download.waitForExistence(timeout: 3) {
            let lines = app.debugDescription.split(separator: "\n").filter { $0.contains("media-") || $0.contains("Status") || $0.contains("720") || $0.contains("Download") || $0.contains("Qualit") }.prefix(30)
            print("HLS diag:\n" + lines.joined(separator: "\n"))
        }
        XCTAssertTrue(download.exists, "a download can now be started")
    }

    func testADASHManifestOnAPageIsListedAndItsQualitiesAreRead() throws {
        let mpd = """
        <?xml version="1.0"?><MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT8S" profiles="urn:mpeg:dash:profile:isoff-on-demand:2011"><Period>
        <AdaptationSet mimeType="video/mp4" contentType="video"><Representation id="v1" bandwidth="800000" width="640" height="360" codecs="avc1.42c01e"><BaseURL>v360.mp4</BaseURL><SegmentBase indexRange="0-100"/></Representation>
        <Representation id="v2" bandwidth="2400000" width="1280" height="720" codecs="avc1.4d401f"><BaseURL>v720.mp4</BaseURL><SegmentBase indexRange="0-100"/></Representation></AdaptationSet></Period></MPD>
        """
        try streamPage("manifest.mpd", mpd, element: "video")
        let look = app.buttons["Look at Qualities"]
        XCTAssertTrue(look.waitForExistence(timeout: 6), "a DASH manifest offers reading its qualities")
        look.click()
        XCTAssertTrue(qualityTexts.firstMatch.waitForExistence(timeout: 20), "the 720p representation of the manifest is listed")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier != 'media-row' AND (label CONTAINS '360' OR value CONTAINS '360')")).firstMatch.exists, "and the 360p one")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "identifier == 'media-outputs' AND value CONTAINS 'Unavailable'")).firstMatch.exists, "it was read, not refused")
    }

    // MARK: A real segmented stream, downloaded through the picker

    /// Real fragmented-MP4 segments (Tests/Fixtures/stream: H.264 picture, AAC sound, 4 s) and, for HLS, the media playlists that name them.
    private func putStreamTracks(_ n: String, playlists: Bool) throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tests/Fixtures/stream", isDirectory: true)
        let info = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("durations.json"))) as? [String: [Double]], "Tests/Fixtures/stream is missing")
        for dir in ["v", "a"] {
            let d = folder.appendingPathComponent(dir)
            _ = send("PUT", "/_media/\(n)/\(dir)/init.mp4", try Data(contentsOf: d.appendingPathComponent("init.mp4")))
            var list = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-MAP:URI=\"init.mp4\"\n"
            for (i, dur) in (info[dir] ?? []).enumerated() {
                _ = send("PUT", "/_media/\(n)/\(dir)/seg\(i).m4s", try Data(contentsOf: d.appendingPathComponent("seg\(i).m4s")))
                list += "#EXTINF:\(String(format: "%.5f", dur)),\nseg\(i).m4s\n"
            }
            if playlists { _ = send("PUT", "/_media/\(n)/\(dir)/index.m3u8", Data((list + "#EXT-X-ENDLIST\n").utf8)) }
        }
    }
    private func dumpPicker(_ label: String) {
        let lines = app.debugDescription.split(separator: "\n").filter { $0.contains("Button") || $0.contains("sheet") || $0.contains("Sheet") || $0.contains("media-") || $0.contains("Download") }.prefix(40)
        print("\(label):\n" + lines.joined(separator: "\n"))
    }
    /// Reads the stream in the picker, starts the download from it, and checks the Downloads window: exactly one completed download with the stream's mp4 name and no leftover rows.
    private func downloadStreamThroughThePicker(fileName: String, body: String) throws {
        try streamPage(fileName, body, element: "video", prepare: { try self.putStreamTracks($0, playlists: fileName.hasSuffix("m3u8")) })
        let look = app.buttons["Look at Qualities"]
        XCTAssertTrue(look.waitForExistence(timeout: 6), "the stream offers reading its qualities"); look.click()
        let download = any("media-download")
        XCTAssertTrue(download.waitForExistence(timeout: 20)); XCTAssertTrue(waitEnabled(download, 20), "after reading, Choose & Download is available")
        download.click()
        XCTAssertTrue(download.waitForNonExistence(timeout: 10), "the picker steps aside after Choose & Download, so the add-download form is in front")
        // Downloads opens with the add-download form for this stream (the picker used to close the panel instead: see BrowserModel.openLinkPreview).
        XCTAssertTrue(any("downloads-table").waitForExistence(timeout: 15), "Choosing a stream brings Downloads up")
        // The add-download form is filled with the stream's address; for a playlist its button is "Next…" (the quality step), and only that step has "Download".
        let next = app.buttons["Next…"].firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 15), "the add-download form offers the quality step for a stream"); next.click()
        let go = app.buttons["Download"].firstMatch
        XCTAssertTrue(go.waitForExistence(timeout: 15), "the quality step offers Download"); XCTAssertTrue(waitEnabled(go, 20), "and it is ready once the playlist was read")
        go.click()
        let table = any("downloads-table")
        if !table.waitForExistence(timeout: 10) { any("downloads-button").click() }
        XCTAssertTrue(table.waitForExistence(timeout: 10), "the Downloads window opens")
        let completed = app.staticTexts.matching(NSPredicate(format: "value == 'Completed' OR label == 'Completed'"))
        let end = Date().addingTimeInterval(60)
        while Date() < end, completed.count < 1 { Thread.sleep(forTimeInterval: 1) }
        let cells = table.staticTexts.allElementsBoundByIndex.map { ($0.value as? String) ?? $0.label }
        print("STREAM downloads table: \(cells.prefix(20))")
        XCTAssertEqual(completed.count, 1, "exactly one completed download: \(cells)")
        let row = table.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '.mp4' OR value CONTAINS '.mp4'")).firstMatch
        XCTAssertTrue(row.exists, "its name ends in .mp4")
        XCTAssertFalse(table.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '.m4s' OR label CONTAINS '.m3u8' OR label CONTAINS 'seg' OR value CONTAINS '.m4s'")).firstMatch.exists, "no segment or playlist is listed as a download")
    }

    func testARealHLSStreamDownloadsThroughThePickerToOneCompletedMP4() throws {
        let master = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"English\",LANGUAGE=\"en\",DEFAULT=YES,URI=\"a/index.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=160x120,CODECS=\"avc1.42c01e,mp4a.40.2\",AUDIO=\"aud\"\nv/index.m3u8\n"
        try downloadStreamThroughThePicker(fileName: "master.m3u8", body: master)
    }

    func testARealDASHStreamDownloadsThroughThePickerToOneCompletedMP4() throws {
        // Durations are those of the fixture tracks: the timeline names the real segments.
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tests/Fixtures/stream", isDirectory: true)
        let info = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("durations.json"))) as? [String: [Double]])
        func timeline(_ d: [Double]) -> String { d.map { "<S d=\"\(Int(($0 * 1000).rounded()))\"/>" }.joined() }
        let mpd = """
        <?xml version="1.0" encoding="UTF-8"?>
        <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT4S" minBufferTime="PT1S" profiles="urn:mpeg:dash:profile:isoff-on-demand:2011"><Period>
        <AdaptationSet mimeType="video/mp4" codecs="avc1.42c01e" width="160" height="120"><SegmentTemplate timescale="1000" startNumber="0" initialization="v/init.mp4" media="v/seg$Number$.m4s"><SegmentTimeline>\(timeline(info["v"] ?? []))</SegmentTimeline></SegmentTemplate><Representation id="v1" bandwidth="800000"/></AdaptationSet>
        <AdaptationSet mimeType="audio/mp4" lang="en" codecs="mp4a.40.2"><SegmentTemplate timescale="1000" startNumber="0" initialization="a/init.mp4" media="a/seg$Number$.m4s"><SegmentTimeline>\(timeline(info["a"] ?? []))</SegmentTimeline></SegmentTemplate><Representation id="a1" bandwidth="64000"/></AdaptationSet>
        </Period></MPD>
        """
        try downloadStreamThroughThePicker(fileName: "manifest.mpd", body: mpd)
    }

    // MARK: A direct WebM file: sound from it needs the media processing tool

    /// A page linking to a real WebM/Opus sound file served by the local fixture; the system's media engine cannot open it.
    private func launchWithWebMLink(tool: Bool) throws -> String {
        let n = "wm\(Int(Date().timeIntervalSince1970))"
        let webm = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tests/Fixtures/media/bbb-6s-audio.webm")
        _ = send("PUT", "/_media/\(n)/song.webm", try Data(contentsOf: webm))
        _ = send("PUT", "/_media/\(n)/page.html", Data("<html><body><h1>Sound</h1><a href=\"/media/\(n)/song.webm\">song</a></body></html>".utf8))
        app = XCUIApplication()
        app.launchArguments += ["-UITestRoot", "bs-ui-wm-\(UUID().uuidString)", "-UITestAllowLocalPageOrigin", "YES", "-UIState", "url", "-UIURL", "\(site)/media/\(n)/page.html", "-UIDownloadsScratch", "wm-\(n)", "-NSRequiresAquaSystemAppearance", "YES", "-UITestFastScan", "YES"]
        if tool { app.launchArguments += ["-FFmpegDevTool", URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("ThirdParty/ffmpeg/bin").path] }
        app.launch(); app.activate()
        try XCTSkipUnless(app.wait(for: .runningForeground, timeout: 15), "Browser Setu is not frontmost; refusing to send input")
        XCTAssertTrue(any("media-button").waitForExistence(timeout: 14), "the link is listed")
        any("media-button").click()
        let clip = any("resource-download-song.webm")
        XCTAssertTrue(clip.waitForExistence(timeout: 5), "the file is listed"); clip.click()
        XCTAssertTrue(any("video-download-sheet").waitForExistence(timeout: 6))
        return n
    }

    func testSoundFromAWebMFileIsMadeByTheProcessingToolFromTheDirectFileSheet() throws {
        _ = try launchWithWebMLink(tool: true)
        let m4a = app.radioButtons.matching(NSPredicate(format: "label CONTAINS 'Audio only (M4A)'")).firstMatch
        XCTAssertTrue(m4a.waitForExistence(timeout: 4), "the M4A choice is offered because the tool is installed")
        XCTAssertFalse(any("processing-tools-offer-enable").exists, "no offer to enable what is already there")
        m4a.click()
        XCTAssertTrue(any("consent-prompt").waitForExistence(timeout: 3), "converting asks first")
        any("consent-once").click()
        XCTAssertTrue(waitEnabled(any("video-sheet-download")))
        any("video-sheet-download").click()
        XCTAssertTrue(any("video-sheet-done").waitForExistence(timeout: 40), "the sound was made")
        let saved = app.staticTexts.matching(NSPredicate(format: "value CONTAINS '.m4a' OR label CONTAINS '.m4a'")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 3), "the sheet names the .m4a file")
        XCTAssertTrue(any("video-sheet-reveal").exists, "the finished file can be shown in Finder")

        // The Downloads window agrees with the sheet and the disk: the .m4a is listed as a completed download, and the downloaded WebM source (removed after the conversion) is not listed as one.
        let finalName = (saved.value as? String ?? saved.label).replacingOccurrences(of: "Saved: ", with: "")
        app.buttons["Done"].firstMatch.click()
        let table = any("downloads-table")
        XCTAssertTrue(table.waitForExistence(timeout: 10), "the Downloads window opens")
        let cells = table.staticTexts.allElementsBoundByIndex.map { ($0.value as? String) ?? $0.label }
        print("PROCESSED downloads table: \(cells.prefix(16))")
        // The name is not a plain text cell: look for it among everything in the table.
        // (A row speaks as one element whose summary starts with its name.)
        let named = table.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@ OR title CONTAINS %@", finalName, finalName, finalName)).firstMatch
        XCTAssertTrue(named.waitForExistence(timeout: 5), "the finished file '\(finalName)' is listed")
        XCTAssertTrue(finalName.hasSuffix(".m4a") && !finalName.contains(".source"), "it has its own name and the right extension: \(finalName)")
        let leftoverRow = table.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '.source.' OR value CONTAINS '.source.' OR title CONTAINS '.source.'")).firstMatch
        XCTAssertFalse(leftoverRow.exists, "the removed source is not listed as a download")
        XCTAssertEqual(cells.filter { $0 == "Completed" }.count, 1, "exactly one completed download: \(cells)")
        // (The file on disk is asserted by the unit tests: this runner is sandboxed and cannot see the app's scratch Downloads folder.)
    }

    func testWithoutTheToolTheDirectFileSheetSaysWhatIsNeededAndOffersIt() throws {
        _ = try launchWithWebMLink(tool: false)
        XCTAssertTrue(any("video-sheet-download").waitForExistence(timeout: 4), "the original file can still be saved")
        XCTAssertFalse(app.radioButtons.matching(NSPredicate(format: "label CONTAINS 'Audio only'")).firstMatch.exists, "sound cannot be made without the tool")
        let reason = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'media processing tool' OR value CONTAINS 'media processing tool'")).firstMatch
        XCTAssertTrue(reason.waitForExistence(timeout: 4), "the sheet says the tool is what is missing, not that the file is unsupported")
    }

    func waitEnabled(_ e: XCUIElement, _ seconds: Double = 5) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if e.exists && e.isEnabled { return true }; Thread.sleep(forTimeInterval: 0.2) }
        return e.exists && e.isEnabled
    }

    /// A page on a provider's own site (the fixture is treated as Vimeo in Debug with -ProviderFixture) whose player uses a plain MP4: the media picker lists it as downloadable and the file really
    /// arrives, because provider identity no longer blocks a plain stream. The Debug-only seam lets the page-origin request reach the loopback fixture; the production rule is tested separately.
    func testPlainVideoOnAProviderPageDownloadsThroughThePicker() throws {
        let n = "pp\(Int(Date().timeIntervalSince1970))"
        var req = URLRequest(url: URL(string: "https://www.w3schools.com/html/mov_bbb.mp4")!); req.timeoutInterval = 30
        let sem = DispatchSemaphore(value: 0); var clip = Data()
        URLSession.shared.dataTask(with: req) { d, _, _ in clip = d ?? Data(); sem.signal() }.resume(); _ = sem.wait(timeout: .now() + 40)
        try XCTSkipIf(clip.count < 100_000, "the public test clip could not be fetched")
        _ = send("PUT", "/_media/\(n)/clip.mp4", clip)
        _ = send("PUT", "/_media/\(n)/page.html", Data("<html><body><h1>Provider page</h1><video src=\"/media/\(n)/clip.mp4\" controls width=320></video></body></html>".utf8))
        app = XCUIApplication()
        app.launchArguments += ["-UITestRoot", "bs-ui-pp-\(UUID().uuidString)", "-ProviderFixture", site, "-UITestAllowLocalPageOrigin", "YES", "-UIState", "url", "-UIURL", "\(site)/media/\(n)/page.html", "-UIDownloadsScratch", "pp-\(n)", "-NSRequiresAquaSystemAppearance", "YES", "-UITestFastScan", "YES"]
        app.launch(); app.activate()
        try XCTSkipUnless(app.wait(for: .runningForeground, timeout: 15), "Browser Setu is not frontmost; refusing to send input")
        XCTAssertTrue(any("media-button").waitForExistence(timeout: 14), "the player is detected")
        Thread.sleep(forTimeInterval: 1.5)
        app.menuBars.menuBarItems["Library"].click()
        let find = app.menuBars.menuItems["Find Downloadable Media"]
        XCTAssertTrue(find.waitForExistence(timeout: 5)); find.click()
        let row = app.descendants(matching: .any).matching(identifier: "media-row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.click()
        let download = any("media-download")
        XCTAssertTrue(download.waitForExistence(timeout: 5), "the picker offers Download for a plain stream on a provider's page")
        XCTAssertTrue(download.isEnabled)
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.safeScreenshot()); shot.name = "provider-page-picker"; shot.lifetime = .keepAlways; add(shot)
        download.click()
        Thread.sleep(forTimeInterval: 3)
        app.typeKey(.escape, modifierFlags: [])          // closes the picker; the Downloads list it sits in stays
        let table = any("downloads-table")
        XCTAssertTrue(table.waitForExistence(timeout: 8))
        let cells = table.staticTexts.allElementsBoundByIndex.map { ($0.value as? String) ?? $0.label }
        print("RESOURCE provider-page downloads: \(cells.prefix(10))")
        XCTAssertTrue(cells.contains("Completed"), "the file was downloaded")
    }

    /// Page → detected video → Download → consent → the person's extractor (a stand-in script) → formats shown → choose → real download → completed file. Also: deny does nothing.
    func testExtractorLookupFromAYouTubeLinkAfterConsentDownloadsTheChosenFormat() throws {
        let n = "ex\(Int(Date().timeIntervalSince1970))"
        var req = URLRequest(url: URL(string: "https://www.w3schools.com/html/mov_bbb.mp4")!); req.timeoutInterval = 30
        let sem = DispatchSemaphore(value: 0); var clip = Data()
        URLSession.shared.dataTask(with: req) { d, _, _ in clip = d ?? Data(); sem.signal() }.resume(); _ = sem.wait(timeout: .now() + 40)
        try XCTSkipIf(clip.count < 100_000, "the public test clip could not be fetched")
        _ = send("PUT", "/_media/\(n)/clip.mp4", clip)
        _ = send("PUT", "/_media/\(n)/page.html", Data("<html><body><h1>Videos</h1><a href=\"https://www.youtube.com/watch?v=dQw4w9WgXcQ&fx=\(n)\">a YouTube video</a></body></html>".utf8))
        // The stand-in extractor is the repository's own fixture (the app no longer runs in the App Sandbox, so it can use it where it is). A missing fixture is a failure, not a skip.
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tests/Fixtures/test-extractor.sh").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: script), "the stand-in extractor fixture is missing: \(script)")
        app = XCUIApplication()
        app.launchArguments += ["-UITestRoot", "bs-ui-ex-\(UUID().uuidString)", "-UITestAllowLocalPageOrigin", "YES", "-bs.extractor.enabled", "YES", "-bs.extractor.path", script,
                                "-UIState", "url", "-UIURL", "\(site)/media/\(n)/page.html", "-UIDownloadsScratch", "ex-\(n)", "-NSRequiresAquaSystemAppearance", "YES", "-UITestFastScan", "YES"]
        app.launch(); app.activate()
        try XCTSkipUnless(app.wait(for: .runningForeground, timeout: 15), "Browser Setu is not frontmost; refusing to send input")
        XCTAssertTrue(any("media-button").waitForExistence(timeout: 14))
        Thread.sleep(forTimeInterval: 2.5)
        func openSheet() {
            any("media-button").click()
            let analyze = any("resource-analyze-YouTube video")
            XCTAssertTrue(analyze.waitForExistence(timeout: 5)); analyze.click()
            XCTAssertTrue(any("video-download-sheet").waitForExistence(timeout: 6))
        }
        // Deny: nothing is run and the sheet goes away.
        openSheet()
        XCTAssertTrue(any("extractor-consent").waitForExistence(timeout: 4), "asks before running the extractor")
        any("extractor-consent-deny").click()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(any("extractor-quality").exists); XCTAssertFalse(any("extractor-running").exists)
        // Allow once: formats appear; choose; download.
        openSheet()
        XCTAssertTrue(any("extractor-consent").waitForExistence(timeout: 4))
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.safeScreenshot()); shot.name = "extractor-consent"; shot.lifetime = .keepAlways; add(shot)
        any("extractor-consent-once").click()
        let quality = any("extractor-quality")
        XCTAssertTrue(quality.waitForExistence(timeout: 20) || any("extractor-download").waitForExistence(timeout: 2), "the extractor's formats are shown")
        let shot2 = XCTAttachment(screenshot: app.windows.firstMatch.safeScreenshot()); shot2.name = "extractor-formats"; shot2.lifetime = .keepAlways; add(shot2)
        XCTAssertTrue(any("extractor-download").waitForExistence(timeout: 5), "Download button")
        XCTAssertTrue(any("extractor-download").isEnabled)
        any("extractor-download").click()
        XCTAssertTrue(any("video-sheet-done").waitForExistence(timeout: 90), "the chosen format was downloaded")
        print("EXTRACTOR saved: \(any("video-sheet-done").label)")
    }

    /// A page whose player builds its video in memory (a blob: address): nothing to fetch by itself. The media picker offers a lookup of the page with the person's extractor; consent, formats, download and the saved file follow.
    func testInMemoryPlayerPageCanBeLookedUpWithTheExtractorFromThePicker() throws {
        let n = "bl\(Int(Date().timeIntervalSince1970))"
        var req = URLRequest(url: URL(string: "https://www.w3schools.com/html/mov_bbb.mp4")!); req.timeoutInterval = 30
        let sem = DispatchSemaphore(value: 0); var clip = Data()
        URLSession.shared.dataTask(with: req) { d, _, _ in clip = d ?? Data(); sem.signal() }.resume(); _ = sem.wait(timeout: .now() + 40)
        try XCTSkipIf(clip.count < 100_000, "the public test clip could not be fetched")
        _ = send("PUT", "/_media/\(n)/clip.mp4", clip)
        _ = send("PUT", "/_media/\(n)/page.html", Data("<html><body><h1>In-memory player</h1><video id=v controls width=320></video><script>document.getElementById('v').src = URL.createObjectURL(new Blob([new Uint8Array(64)], {type: 'video/mp4'}));</script></body></html>".utf8))
        // The stand-in extractor is the repository's own fixture (the app no longer runs in the App Sandbox, so it can use it where it is). A missing fixture is a failure, not a skip.
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tests/Fixtures/test-extractor.sh").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: script), "the stand-in extractor fixture is missing: \(script)")
        app = XCUIApplication()
        app.launchArguments += ["-UITestRoot", "bs-ui-bl-\(UUID().uuidString)", "-UITestAllowLocalPageOrigin", "YES", "-bs.extractor.enabled", "YES", "-bs.extractor.path", script, "-UITestFastScan", "YES",
                                "-UIState", "url", "-UIURL", "\(site)/media/\(n)/page.html", "-UIDownloadsScratch", "bl-\(n)", "-NSRequiresAquaSystemAppearance", "YES"]
        app.launch(); app.activate()
        try XCTSkipUnless(app.wait(for: .runningForeground, timeout: 15), "Browser Setu is not frontmost; refusing to send input")
        Thread.sleep(forTimeInterval: 4)
        app.menuBars.menuBarItems["Library"].click()
        let find = app.menuBars.menuItems["Find Downloadable Media"]
        XCTAssertTrue(find.waitForExistence(timeout: 5)); find.click()
        let row = app.descendants(matching: .any).matching(identifier: "media-row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the in-memory player is listed"); row.click()
        let lookup = any("media-extractor-lookup")
        XCTAssertTrue(lookup.waitForExistence(timeout: 5), "the picker offers a lookup of the page for an in-memory player")
        lookup.click()
        XCTAssertTrue(any("extractor-consent").waitForExistence(timeout: 8), "the picker closed and the consent prompt is shown")
        any("extractor-consent-once").click()
        XCTAssertTrue(any("extractor-download").waitForExistence(timeout: 20), "the extractor's formats are shown")
        any("extractor-download").click()
        XCTAssertTrue(any("video-sheet-done").waitForExistence(timeout: 90), "the chosen format was downloaded")
    }

    /// Observation only: opens one live page in the real app and reports what the browser detects. It never clicks any Download button. Runs only when TEST_RUNNER_BS_LIVE_URL is set.
    func testObserveALivePageWithoutDownloading() throws {
        guard let live = ProcessInfo.processInfo.environment["BS_LIVE_URL"] else { throw XCTSkip("set TEST_RUNNER_BS_LIVE_URL to run this live observation") }
        app = XCUIApplication()
        app.launchArguments += ["-UITestRoot", "bs-ui-live-\(UUID().uuidString)", "-UIState", "url", "-UIURL", live, "-UIDownloadsScratch", "live-scratch", "-NSRequiresAquaSystemAppearance", "YES", "-UITestFastScan", "YES"]
        app.launch(); app.activate()
        try XCTSkipUnless(app.wait(for: .runningForeground, timeout: 15), "Browser Setu is not frontmost; refusing to send input")
        Thread.sleep(forTimeInterval: 25)                                   // the page loads and its players report
        let chips = ["media-button", "category-audio", "category-image", "category-document", "category-archive", "category-code", "category-config", "category-data", "category-torrent", "category-installer", "category-feed", "category-cloud", "category-other", "category-all"]
        let present = chips.filter { any($0).exists }
        print("LIVE chips shown: \(present.map { $0 + "=" + any($0).label })")
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.safeScreenshot()); shot.name = "live-page"; shot.lifetime = .keepAlways; add(shot)
        if any("media-button").exists {
            any("media-button").click()
            Thread.sleep(forTimeInterval: 1)
            let rows = app.descendants(matching: .any).matching(identifier: "resource-row").allElementsBoundByIndex.prefix(10)
            print("LIVE list rows: \(rows.map { $0.label })")
            print("LIVE media-picker button offered: \(any("category-open-picker").exists)")
        }
        // Step 1: open the Download sheet for the first video entry. Opening it only shows what can be done; nothing is fetched and no button that starts a download is pressed.
        let openers = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'resource-analyze-'")).allElementsBoundByIndex
        print("LIVE video entries with a Download button: \(openers.count)")
        let pop = app.debugDescription.split(separator: "\n").filter { $0.contains("Popover") || $0.contains("resource-") || $0.contains("category-") }.prefix(14).map { String($0.trimmingCharacters(in: .whitespaces).prefix(170)) }
        print("LIVE popover tree: \(pop)")
        if let first = openers.first {
            first.click()
            _ = any("video-download-sheet").waitForExistence(timeout: 6)
            Thread.sleep(forTimeInterval: 1.5)
            let sheet = app.descendants(matching: .any).matching(identifier: "video-download-sheet").firstMatch
            let texts = sheet.descendants(matching: .staticText).allElementsBoundByIndex.prefix(12).map { ($0.value as? String) ?? $0.label }
            print("LIVE sheet text: \(texts)")
            print("LIVE sheet buttons: \(sheet.descendants(matching: .button).allElementsBoundByIndex.map { $0.identifier + "/" + $0.label })")
            let shot2 = XCTAttachment(screenshot: app.windows.firstMatch.safeScreenshot()); shot2.name = "live-sheet"; shot2.lifetime = .keepAlways; add(shot2)
        }
        let lines = app.debugDescription.split(separator: "\n").filter { $0.contains("Video") || $0.contains("media-") }.prefix(6).map { String($0.trimmingCharacters(in: .whitespaces).prefix(160)) }
        print("LIVE window mentions: \(lines)")
    }
}
