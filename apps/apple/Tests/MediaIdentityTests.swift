import WebKit
import XCTest
@testable import Browser_Setu

/// A player is named by a number that stays with it, not by its place in a list, and a refused action says why.
@MainActor
final class MediaIdentityTests: XCTestCase {
    fileprivate func page(_ body: String) async throws -> WKWebView {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        web.loadHTMLString("<html><body>\(body)</body></html>", baseURL: URL(string: "http://127.0.0.1:18766/"))
        try await Task.sleep(for: .seconds(1.5))
        return web
    }

    fileprivate func list(_ web: WKWebView) async throws -> [[String: Any]] {
        try await web.callAsyncJavaScript(MediaScripts.list(), contentWorld: .defaultClient) as? [[String: Any]] ?? []
    }

    fileprivate func control(_ web: WKWebView, _ id: Int, _ action: String, _ value: Double = 0) async throws -> String? {
        try await web.callAsyncJavaScript(MediaScripts.control, arguments: ["id": id, "action": action, "value": value], contentWorld: .defaultClient) as? String
    }

    private func rates(_ web: WKWebView) async throws -> [Double] {
        try await web.callAsyncJavaScript("return Array.from(document.querySelectorAll('video')).map(v => v.playbackRate);", contentWorld: .page) as? [Double] ?? []
    }

    func testAPlayerKeepsItsNumberWhenAnotherIsAddedBeforeIt() async throws {
        let web = try await page("<video id=a></video><video id=b></video>")
        let before = try await list(web)
        XCTAssertEqual(before.count, 2)
        let second = try XCTUnwrap((before[1]["id"] as? NSNumber)?.intValue)
        _ = try await web.callAsyncJavaScript("var v = document.createElement('video'); document.body.insertBefore(v, document.body.firstChild);", contentWorld: .page)
        let after = try await list(web)
        XCTAssertEqual(after.count, 3)
        XCTAssertEqual((after[2]["id"] as? NSNumber)?.intValue, second, "the same player, now third in the page")
        let problem = try await control(web, second, "speed", 2)
        XCTAssertNil(problem)
        let now = try await rates(web)
        XCTAssertEqual(now, [1, 1, 2], "only the player that was named changed")
    }

    func testARemovedPlayerIsReportedNotReplacedByAnother() async throws {
        let web = try await page("<video id=a></video><video id=b></video>")
        let f7 = try await list(web)
        let first = try XCTUnwrap(f7[0]["id"] as? NSNumber).intValue
        _ = try await web.callAsyncJavaScript("document.getElementById('a').remove();", contentWorld: .page)
        let problem = try await control(web, first, "speed", 2)
        XCTAssertEqual(problem, "That player is no longer on the page.")
        let now = try await rates(web)
        XCTAssertEqual(now, [1], "the one left was not touched")
    }

    func testAnActionThePlayerCannotDoSaysSo() async throws {
        let web = try await page("<video id=a></video>")
        let f8 = try await list(web)
        let id = try XCTUnwrap(f8[0]["id"] as? NSNumber).intValue
        let unknown = try await control(web, id, "teleport")
        XCTAssertEqual(unknown, "Unknown action.")
    }

    func testPlayersInsideAnOpenShadowTreeAndASameSiteFrameAreFound() async throws {
        let web = try await page("""
        <div id=host></div><iframe id=f srcdoc="<video id=inner></video>"></iframe>
        <script>var r = document.getElementById('host').attachShadow({mode:'open'}); r.innerHTML = '<video id=deep></video>';</script>
        """)
        try await Task.sleep(for: .seconds(1))
        let found = try await list(web)
        XCTAssertEqual(found.count, 2, "one in the shadow tree, one in the frame")
    }

    func testTheNumbersCannotBeReadOrChangedByThePage() async throws {
        let web = try await page("<video id=a></video>")
        _ = try await list(web)
        let seen = try await web.callAsyncJavaScript("return typeof window.__bsMedia;", contentWorld: .page) as? String
        XCTAssertEqual(seen, "undefined", "the table lives in the browser's own script world")
    }

    func testNoMoreThanTheLimitIsReported() async throws {
        let many = String(repeating: "<video></video>", count: 30)
        let web = try await page(many)
        let found = try await list(web)
        XCTAssertEqual(found.count, 16)
    }

    func testSeekingByAStepNeedsARangeAndLoopAndRepeatSayWhatIsWrong() async throws {
        let web = try await page("<video id=a></video>")
        let f9 = try await list(web)
        let id = try XCTUnwrap(f9[0]["id"] as? NSNumber).intValue
        let seek = try await control(web, id, "seekBy", 10)
        XCTAssertEqual(seek, "This video cannot be moved to another point.", "nothing loaded, so no range to move in")
        let loop = try await control(web, id, "loop", 1)
        XCTAssertNil(loop)
        let looping = try await web.callAsyncJavaScript("return document.getElementById('a').loop;", contentWorld: .page) as? Bool
        XCTAssertEqual(looping, true)
        let b = try await control(web, id, "markB")
        XCTAssertEqual(b, "This video cannot be repeated between two points.", "no seekable range yet")
    }

    func testTheListSaysWhatThePlayerCanDo() async throws {
        let web = try await page("<video id=a width=300 height=200></video><video id=b muted loop style='display:none'></video>")
        let found = try await list(web)
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual((found[0]["visible"] as? NSNumber)?.boolValue, true)
        XCTAssertEqual((found[1]["visible"] as? NSNumber)?.boolValue, false, "hidden")
        XCTAssertEqual((found[1]["decorative"] as? NSNumber)?.boolValue, true, "muted, looping, no controls")
        XCTAssertTrue(found[0]["seekStart"] is NSNull || found[0]["seekStart"] == nil, "no range until something is loaded")
    }
}

extension MediaIdentityTests {
    func testTheaterModeIsReversibleAndTheOtherVideoIsUntouched() async throws {
        let web = try await page("<video id=a style='width:200px;height:100px'></video><video id=b></video>")
        let found = try await list(web)
        let first = try XCTUnwrap((found[0]["id"] as? NSNumber)?.intValue)
        let before = try await web.callAsyncJavaScript("return document.getElementById('a').getAttribute('style');", contentWorld: .page) as? String
        let r1 = try await control(web, first, "theater", 1)
        XCTAssertNil(r1)
        let during = try await web.callAsyncJavaScript("return [document.getElementById('a').style.position, document.getElementById('b').style.position, document.documentElement.style.overflow];", contentWorld: .page) as? [String]
        XCTAssertEqual(during, ["fixed", "", "hidden"])
        let r2 = try await control(web, first, "theater", 0)
        XCTAssertNil(r2)
        let after = try await web.callAsyncJavaScript("return [document.getElementById('a').getAttribute('style'), document.documentElement.style.overflow];", contentWorld: .page) as? [String]
        XCTAssertEqual(after?[0], before, "its own style is back exactly")
        XCTAssertEqual(after?[1], "", "and the page scrolls again")
    }

    func testAudioTrackAndBlockedFramesSaySoWhenThereIsNothingToChooseOrReach() async throws {
        let web = try await page("<video id=a></video><iframe sandbox srcdoc='<p>x</p>' title='video player'></iframe>")
        let f10 = try await list(web)
        let id = try XCTUnwrap(f10[0]["id"] as? NSNumber).intValue
        let problem = try await control(web, id, "audioTrack", 1)
        XCTAssertEqual(problem, "This player has no other audio to choose.")
        let blocked = try await web.callAsyncJavaScript(MediaScripts.blockedFrames, contentWorld: .defaultClient) as? Int
        XCTAssertEqual(blocked, 1, "a frame cut off from the page (as another site's is) is counted, not reached")
    }
}

extension MediaIdentityTests {
    func testTheNewActionsSayWhyWhenThePlayerCannotDoThem() async throws {
        let web = try await page("<video id=a></video>")
        let f11 = try await list(web)
        let id = try XCTUnwrap(f11[0]["id"] as? NSNumber).intValue
        let frame = try await control(web, id, "frame", 1)
        XCTAssertEqual(frame, "This video cannot be moved to another point.")
        let shift = try await control(web, id, "subtitleShift", 0.5)
        XCTAssertEqual(shift, "No subtitles are showing.")
        let ab = try await control(web, id, "setAB:10:20")
        XCTAssertEqual(ab, "This video cannot be repeated between two points.")
        let r3 = try await control(web, id, "speedBy", 0.25)
        XCTAssertNil(r3)
        let rate = try await web.callAsyncJavaScript("return document.getElementById('a').playbackRate;", contentWorld: .page) as? Double
        XCTAssertEqual(rate, 1.25)
        let r4 = try await control(web, id, "fit", 1)
        XCTAssertNil(r4)
        let fit = try await web.callAsyncJavaScript("return document.getElementById('a').style.objectFit;", contentWorld: .page) as? String
        XCTAssertEqual(fit, "cover")
    }

    func testPictureAdjustmentsAreScopedToOneVideoAndResetCleanly() async throws {
        let web = try await page("<video id=a></video><video id=b></video>")
        let found = try await list(web)
        let first = try XCTUnwrap((found[0]["id"] as? NSNumber)?.intValue)
        let r5 = try await control(web, first, "adjust:brightness", 0.2)
        XCTAssertNil(r5)
        let filters = try await web.callAsyncJavaScript("return [document.getElementById('a').style.filter, document.getElementById('b').style.filter];", contentWorld: .page) as? [String]
        XCTAssertTrue(filters?[0].contains("brightness(1.2)") == true)
        XCTAssertEqual(filters?[1], "", "the other video is untouched")
        let r6 = try await control(web, first, "adjust:reset")
        XCTAssertNil(r6)
        let after = try await web.callAsyncJavaScript("return document.getElementById('a').style.filter;", contentWorld: .page) as? String
        XCTAssertEqual(after, "")
    }

    func testTheTranscriptAndCaptureRefuseWhenThereIsNothingToGive() async throws {
        let web = try await page("<video id=a></video>")
        let f12 = try await list(web)
        let id = try XCTUnwrap(f12[0]["id"] as? NSNumber).intValue
        let t = try await web.callAsyncJavaScript(MediaScripts.transcript, arguments: ["id": id], contentWorld: .defaultClient) as? [String: Any]
        XCTAssertEqual(t?["error"] as? String, "This player has no subtitles or captions to read.")
        let c = try await web.callAsyncJavaScript(MediaScripts.capture, arguments: ["id": id], contentWorld: .defaultClient) as? [String: Any]
        XCTAssertEqual(c?["error"] as? String, "The video has not shown a picture yet.")
    }
}

extension MediaIdentityTests {
    /// The guard against videos starting by themselves still refuses a page, and lets a deliberate command from the browser's own controls through, only after the secret event.
    func testTheAutoplayGuardRefusesAPageButHonoursAGrantFromTheBrowser() async throws {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(WKUserScript(source: PageScripts.noAutoplay(exceptions: [], grant: "bs-test-grant"), injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        web.loadHTMLString("<html><body><video id=a></video></body></html>", baseURL: URL(string: "http://127.0.0.1:18767/"))
        try await Task.sleep(for: .seconds(1.5))
        // A video with no source never settles its play(): after 1.5 s it counts as "not refused".
        let attempt = "const v = document.getElementById('a'); return Promise.race([v.play().then(() => 'played', e => e.name), new Promise(r => setTimeout(() => r('pending'), 1500))]);"
        let refused = try await web.callAsyncJavaScript(attempt, contentWorld: .page) as? String
        XCTAssertEqual(refused, "NotAllowedError", "a page cannot start playback on its own")
        // The wrong name does nothing.
        _ = try await web.callAsyncJavaScript("window.dispatchEvent(new Event('bs-not-the-name'));", contentWorld: .page)
        let stillRefused = try await web.callAsyncJavaScript(attempt, contentWorld: .page) as? String
        XCTAssertEqual(stillRefused, "NotAllowedError")
        _ = try await web.callAsyncJavaScript("window.dispatchEvent(new Event('bs-test-grant'));", contentWorld: .page)
        let allowed = try await web.callAsyncJavaScript(attempt, contentWorld: .page) as? String
        XCTAssertNotEqual(allowed, "NotAllowedError", "after the browser's grant the guard steps aside (a video with no source then fails for its own reason: \(allowed ?? "nil"))")
    }
}

final class MediaSelectionTests: XCTestCase {
    private func video(_ id: Int, paused: Bool = true, muted: Bool = false, visible: Bool = true, inView: Bool = true, area: Int = 1000, decorative: Bool = false) -> DetectedVideo {
        var v = DetectedVideo(raw: ["id": id, "tag": "video"])
        v.paused = paused; v.muted = muted; v.visible = visible; v.inView = inView; v.area = area; v.decorative = decorative
        return v
    }

    func testThePlayerThatIsReallyBeingWatchedComesFirst() {
        let background = video(1, paused: false, muted: true, area: 900_000, decorative: true)
        let watched = video(2, paused: false, area: 100_000)
        let idle = video(3, area: 500_000)
        XCTAssertEqual(MediaSelection.primary(of: [background, idle, watched])?.id, 2, "playing and audible beats a bigger, silent decoration")
    }

    func testWithNothingPlayingTheBiggestOneInViewWins() {
        let small = video(1, area: 10_000), big = video(2, area: 300_000), off = video(3, inView: false, area: 900_000)
        XCTAssertEqual(MediaSelection.primary(of: [small, off, big])?.id, 2)
    }

    func testAHiddenOrDecorativeOneIsUsedOnlyWhenItIsAllThereIs() {
        XCTAssertEqual(MediaSelection.primary(of: [video(1, visible: false)])?.id, 1)
        XCTAssertEqual(MediaSelection.primary(of: [video(1, visible: false, area: 5_000_000), video(2, area: 100)])?.id, 2)
        XCTAssertNil(MediaSelection.primary(of: []))
    }
}
