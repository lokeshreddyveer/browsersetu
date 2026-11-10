import CryptoKit
import WebKit
import XCTest
@testable import Browser_Setu

/// SponsorBlock: what it sends and when, how segments are read, and what really happens to a video in a real web view.
@MainActor
final class SponsorBlockTests: XCTestCase {
    private let id = "dQw4w9WgXcQ"

    // MARK: Identifier, hash prefix, request

    func testOnlyAYouTubeVideoAddressGivesAnIdentifier() {
        XCTAssertEqual(SponsorVideoID.parse(URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=10")), id)
        XCTAssertEqual(SponsorVideoID.parse(URL(string: "https://m.youtube.com/watch?v=dQw4w9WgXcQ")), id)
        XCTAssertEqual(SponsorVideoID.parse(URL(string: "https://youtube.com/shorts/dQw4w9WgXcQ")), id)
        XCTAssertEqual(SponsorVideoID.parse(URL(string: "https://www.youtube.com/embed/dQw4w9WgXcQ")), id)
        XCTAssertNil(SponsorVideoID.parse(URL(string: "https://www.youtube.com/")))
        XCTAssertNil(SponsorVideoID.parse(URL(string: "https://music.youtube.com/watch?v=dQw4w9WgXcQ")), "other YouTube sites are left alone")
        XCTAssertNil(SponsorVideoID.parse(URL(string: "https://evil.example/watch?v=dQw4w9WgXcQ")))
        XCTAssertNil(SponsorVideoID.parse(URL(string: "https://www.youtube.com/watch?v=short")))
        XCTAssertNil(SponsorVideoID.parse(URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXc!")))
        XCTAssertNil(SponsorVideoID.parse(nil))
    }

    func testTheRequestCarriesOnlyAFourCharacterHashPrefixAndNeverTheIdentifier() throws {
        let expected = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined().prefix(4)
        XCTAssertEqual(SponsorVideoID.hashPrefix(id), String(expected))
        XCTAssertEqual(SponsorVideoID.hashPrefix(id).count, 4)
        let url = try XCTUnwrap(SponsorBlockService.requestURL(videoID: id, categories: ["sponsor", "selfpromo"], server: SponsorBlockService.defaultServer))
        XCTAssertTrue(url.absoluteString.hasPrefix("https://sponsor.ajay.app/api/skipSegments/\(expected)?"))
        XCTAssertFalse(url.absoluteString.contains(id), "the identifier itself is never sent")
        XCTAssertFalse(url.absoluteString.lowercased().contains(id.lowercased()))
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name).sorted(), ["actionTypes", "categories"], "nothing else rides along")
    }

    func testOnlyAPublicHttpsServerIsEverUsed() {
        for bad in ["http://sponsor.ajay.app", "https://localhost", "https://192.168.1.4/", "https://user:pw@example.com", "https://printer", "ftp://example.com", "https://example.com/?q=1", "not a url"] {
            XCTAssertFalse(SponsorBlockService.validServer(bad), bad)
            XCTAssertNil(SponsorBlockService.requestURL(videoID: id, categories: ["sponsor"], server: bad))
        }
        XCTAssertTrue(SponsorBlockService.validServer("https://segments.example.org"))
        XCTAssertTrue(SponsorBlockService.validServer("https://segments.example.org/sb/"))
        XCTAssertNil(SponsorBlockService.requestURL(videoID: "../../etc/passwd", categories: ["sponsor"], server: SponsorBlockService.defaultServer))
    }

    // MARK: Reading the answer

    func testTheAnswerForAPrefixIsReducedToThisVideosCheckedSkipSegments() throws {
        let json = """
        [{"videoID":"otherVideo01","segments":[{"segment":[1,5],"category":"sponsor","UUID":"x","actionType":"skip"}]},
         {"videoID":"dQw4w9WgXcQ","segments":[
           {"segment":[40.5,90.25],"category":"sponsor","UUID":"b","actionType":"skip"},
           {"segment":[10,20],"category":"selfpromo","UUID":"a","actionType":"skip"},
           {"segment":[15,25],"category":"selfpromo","UUID":"overlap","actionType":"skip"},
           {"segment":[100,101],"category":"sponsor","UUID":"mute","actionType":"mute"},
           {"segment":[200,100],"category":"sponsor","UUID":"backwards","actionType":"skip"},
           {"segment":[300,300.1],"category":"sponsor","UUID":"tiny","actionType":"skip"},
           {"segment":[5,9],"category":"intro","UUID":"unasked","actionType":"skip"},
           {"segment":[1e9,1e9],"category":"sponsor","UUID":"huge","actionType":"skip"},
           {"segment":[50],"category":"sponsor","UUID":"bad","actionType":"skip"}]}]
        """
        let segments = try XCTUnwrap(SponsorBlockService.parse(Data(json.utf8), videoID: id, categories: ["sponsor", "selfpromo"]))
        XCTAssertEqual(segments.map(\.uuid), ["a", "b"], "this video's, in order, overlapping ones merged, and only skip segments of asked-for kinds with sane numbers")
        XCTAssertEqual(segments[0].start, 10); XCTAssertEqual(segments[0].end, 25)
        XCTAssertEqual(try XCTUnwrap(SponsorBlockService.parse(Data("[]".utf8), videoID: id, categories: ["sponsor"])), [])
        XCTAssertNil(SponsorBlockService.parse(Data("not json".utf8), videoID: id, categories: ["sponsor"]))
    }

    func testTheCacheKeepsAnAnswerForAWhileAndForgetsIt() {
        let cache = SponsorCache()
        let now = Date()
        cache.set(id, categories: ["sponsor"], segments: [SponsorSpan(start: 1, end: 2, category: "sponsor", uuid: "u")], now: now)
        cache.set("aaaaaaaaaaa", categories: ["sponsor"], segments: [], now: now)
        XCTAssertNotNil(cache.get(id, categories: ["sponsor"], now: now.addingTimeInterval(5 * 3600)))
        XCTAssertNil(cache.get(id, categories: ["sponsor"], now: now.addingTimeInterval(7 * 3600)), "six hours")
        XCTAssertNil(cache.get("aaaaaaaaaaa", categories: ["sponsor"], now: now.addingTimeInterval(2 * 3600)), "an hour for a video without segments")
        XCTAssertNil(cache.get(id, categories: ["sponsor", "intro"], now: now), "a different choice of kinds is a different question")
        cache.clear()
        XCTAssertEqual(cache.count, 0)
    }

    // MARK: When anything is sent

    private func model() async -> BrowserModel {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-sb-\(UUID().uuidString)", profile: "default")
        await m.start()
        return m
    }

    private func watch(_ m: BrowserModel, private isPrivate: Bool = false) async -> (tab: TabController, requests: () -> [URL]) {
        var seen: [URL] = []
        SponsorBlockService.shared.transport = { url in seen.append(url); return (Data("[]".utf8), 200) }
        let tab = m.openTab(url: nil, isPrivate: isPrivate)
        tab.url = URL(string: "https://www.youtube.com/watch?v=\(id)")
        return (tab, { seen })
    }

    func testNothingIsSentWhileItIsOffOrNotAgreedToOrInAPrivateTabOrOnASiteSwitchedOff() async throws {
        defer { SponsorBlockService.shared.transport = { _ in throw URLError(.notConnectedToInternet) } }
        let m = await model()
        XCTAssertFalse(m.sponsorBlockEnabled, "off by default")
        XCTAssertNil(m.sponsorPolicy, "and no page script at all")
        var (tab, requests) = await watch(m)
        m.sponsorCheck(tab); await tab.sponsorTask?.value
        XCTAssertEqual(requests().count, 0, "off: nothing is sent")
        m.sponsorBlockEnabled = true
        m.sponsorCheck(tab); await tab.sponsorTask?.value
        XCTAssertEqual(requests().count, 0, "turned on without agreeing: nothing is sent")
        XCTAssertNil(m.sponsorPolicy)
        m.sponsorConsentDate = Date()
        XCTAssertNotNil(m.sponsorPolicy)
        (tab, requests) = await watch(m, private: true)
        m.sponsorCheck(tab); await tab.sponsorTask?.value
        XCTAssertEqual(requests().count, 0, "a private tab sends nothing")
        (tab, requests) = await watch(m)
        m.setSponsor(host: "www.youtube.com", on: false)
        m.sponsorCheck(tab); await tab.sponsorTask?.value
        XCTAssertEqual(requests().count, 0, "a site switched off sends nothing")
        m.setSponsor(host: "www.youtube.com", on: true)
        m.sponsorCheck(tab); await tab.sponsorTask?.value
        XCTAssertEqual(requests().count, 1, "agreed, normal tab, site on: one request")
        m.sponsorCheck(tab); await tab.sponsorTask?.value
        XCTAssertEqual(requests().count, 1, "the second look is answered from memory")
        XCTAssertFalse(requests()[0].absoluteString.contains(id))
        let notVideo = m.openTab(url: nil, isPrivate: false)
        notVideo.url = URL(string: "https://www.youtube.com/feed/subscriptions")
        m.sponsorCheck(notVideo)
        XCTAssertNil(notVideo.sponsorTask, "a page that is not a video asks nothing")
    }

    func testTurningItOnAsksFirstAndDecliningLeavesItOff() async throws {
        let m = await model()
        var asked: [String] = []
        Dialogs.testHandler = { title, message, _ in asked.append(title + "\n" + message); return 1 }
        await m.setSponsorBlock(enabled: true)
        XCTAssertFalse(m.sponsorBlockEnabled)
        XCTAssertNil(m.sponsorConsentDate)
        XCTAssertEqual(asked.count, 1)
        XCTAssertTrue(asked[0].contains("first 4 characters"), "it says what is sent")
        XCTAssertTrue(asked[0].contains("internet address"), "and what the server can see")
        Dialogs.testHandler = { _, _, _ in 0 }
        await m.setSponsorBlock(enabled: true)
        Dialogs.testHandler = nil
        XCTAssertTrue(m.sponsorBlockEnabled)
        XCTAssertNotNil(m.sponsorConsentDate)
        await m.setSponsorBlock(enabled: false)
        XCTAssertFalse(m.sponsorBlockEnabled)
        XCTAssertEqual(m.sponsorCache.count, 0)
    }

    // MARK: A real video
    // The video is steered by seeking, which is what a person scrubbing does: it needs the picture to have loaded, not to be playing (a web view that is not on screen may not play).

    private func player(_ actions: [String: String], offSites: Set<String> = [], host: String = "www.youtube.com", markup: String = "") async throws -> WKWebView {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.addUserScript(WKUserScript(source: SponsorBlockScript.source(SponsorPolicy(actions: actions, offSites: offSites)), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 400), configuration: config)
        let html = "<html><body><div id='movie_player' class='html5-video-player \(markup)'><video id='v' class='html5-main-video' src='http://127.0.0.1:18765/clip.mp4' muted playsinline preload='auto' width='320'></video></div></body></html>"
        web.loadHTMLString(html, baseURL: URL(string: "http://\(host)/watch?v=\(id)"))
        // Give the real video a few seconds to load. A web view that is not on screen does not always load media, so if it does not, the same page script is exercised on a video element
        // whose length and position are supplied by the test (which is what the script reads); the output says which one was used.
        var ready = false
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(200))
            if let state = try? await web.callAsyncJavaScript("var v = document.getElementById('v'); return v && v.readyState >= 1 && isFinite(v.duration) && v.duration > 3;", contentWorld: .defaultClient) as? Bool, state { ready = true; break }
        }
        if !ready {
            print("SPONSORBLOCK TEST: real video did not load here; using a stand-in element for its length and position")
            _ = try? await web.callAsyncJavaScript("""
                var v = document.getElementById('v'), t = 0;
                Object.defineProperty(v, 'duration', { get: function () { return 6; } });
                Object.defineProperty(v, 'paused', { get: function () { return true; } });
                Object.defineProperty(v, 'currentTime', { get: function () { return t; }, set: function (x) { t = x; setTimeout(function () { v.dispatchEvent(new Event('seeked')); }, 0); } });
                return true;
                """, contentWorld: .defaultClient)
        }
        return web
    }

    private func give(_ web: WKWebView, _ segments: String, id: String? = nil) async {
        _ = try? await web.callAsyncJavaScript("window.__bsSponsor && window.__bsSponsor.set(id, JSON.parse(list));", arguments: ["id": id ?? self.id, "list": segments], contentWorld: .defaultClient)
    }

    private func time(_ web: WKWebView) async -> Double {
        ((try? await web.callAsyncJavaScript("return document.getElementById('v').currentTime;", contentWorld: .defaultClient)) as? Double) ?? -1
    }

    /// Moves the video to `seconds` and gives the page's scripts a moment to react.
    private func seek(_ web: WKWebView, to seconds: Double) async {
        _ = try? await web.callAsyncJavaScript("var v = document.getElementById('v'); v.currentTime = t; await new Promise(function (r) { setTimeout(r, 600); }); return true;", arguments: ["t": seconds], contentWorld: .defaultClient)
    }

    func testAnAutomaticSegmentIsSkippedAndUndoPutsItBack() async throws {
        let web = try await player(["sponsor": "auto"])
        await give(web, #"[{"start":1.0,"end":2.5,"category":"sponsor","uuid":"s1"}]"#)
        await seek(web, to: 1.3)
        let after = await time(web)
        XCTAssertGreaterThanOrEqual(after, 2.5, "the video jumped over the segment (now at \(after))")
        let stats = (try? await web.callAsyncJavaScript(SponsorBlockScript.stats, contentWorld: .defaultClient)) as? String
        XCTAssertTrue(stats?.contains("\"skipped\":1") ?? false, stats ?? "nil")
        // The notice offers Undo, which goes back and does not skip that segment again.
        _ = try? await web.callAsyncJavaScript("var b = document.querySelector('[data-bs-sponsor] button'); if (b) b.click(); return !!b;", contentWorld: .defaultClient)
        try await Task.sleep(for: .seconds(0.8))
        let back = await time(web)
        XCTAssertLessThan(back, 2.5, "undo returned to the start of the segment (at \(back))")
        XCTAssertGreaterThanOrEqual(back, 0.9)
    }

    func testAButtonSegmentShowsASkipButtonThatSkipsAndAKindSetToLeaveAloneIsLeftAlone() async throws {
        let web = try await player(["sponsor": "button"])
        await give(web, #"[{"start":1.0,"end":4.0,"category":"sponsor","uuid":"s1"}]"#)
        await seek(web, to: 1.5)
        let shown = (try? await web.callAsyncJavaScript("var b = document.querySelector('[data-bs-sponsor] button'); return b ? b.textContent : null;", contentWorld: .defaultClient)) as? String
        XCTAssertEqual(shown, "Skip sponsor")
        let before = await time(web)
        XCTAssertLessThan(before, 4.0, "nothing was skipped by itself")
        _ = try? await web.callAsyncJavaScript("document.querySelector('[data-bs-sponsor] button').click(); return true;", contentWorld: .defaultClient)
        try await Task.sleep(for: .seconds(0.6))
        let after = await time(web)
        XCTAssertGreaterThanOrEqual(after, 4.0)
        let off = try await player(["sponsor": "off"])
        await give(off, #"[{"start":1.0,"end":4.0,"category":"sponsor","uuid":"s1"}]"#)
        await seek(off, to: 1.5)
        let still = await time(off)
        XCTAssertEqual(still, 1.5, accuracy: 0.3, "a kind set to leave alone is left alone")
    }

    func testItDoesNothingOnAProtectedVideoWhileAnAdPlaysForADifferentVideoOrOnAnotherSiteAndTheSameSetupDoesSkipWhenItShould() async throws {
        let segments = #"[{"start":0.5,"end":3.0,"category":"sponsor","uuid":"s1"}]"#
        // The control: the same setup, nothing special, skips. Without it the cases below could pass because nothing works at all.
        let control = try await player(["sponsor": "auto"])
        await give(control, segments); await seek(control, to: 1.0)
        let c = await time(control)
        XCTAssertGreaterThanOrEqual(c, 3.0, "the control skipped (at \(c))")
        // Protected playback (the video has encryption keys): untouched.
        let drm = try await player(["sponsor": "auto"])
        _ = try? await drm.callAsyncJavaScript("Object.defineProperty(document.getElementById('v'), 'mediaKeys', { value: {} }); return true;", contentWorld: .defaultClient)
        await give(drm, segments); await seek(drm, to: 1.0)
        let t1 = await time(drm)
        XCTAssertEqual(t1, 1.0, accuracy: 0.3, "a protected video is not touched (at \(t1))")
        // An ad is showing.
        let ad = try await player(["sponsor": "auto"], markup: "ad-showing")
        await give(ad, segments); await seek(ad, to: 1.0)
        let t2 = await time(ad)
        XCTAssertEqual(t2, 1.0, accuracy: 0.3, "while an ad plays nothing is skipped (at \(t2))")
        // Segments for another video are refused by the page.
        let other = try await player(["sponsor": "auto"])
        await give(other, segments, id: "aaaaaaaaaaa"); await seek(other, to: 1.0)
        let t3 = await time(other)
        XCTAssertEqual(t3, 1.0, accuracy: 0.3, "segments made for another video are never used (at \(t3))")
        // Another site, and a site switched off.
        let elsewhere = try await player(["sponsor": "auto"], host: "video.example")
        await give(elsewhere, segments); await seek(elsewhere, to: 1.0)
        let t4 = await time(elsewhere)
        XCTAssertEqual(t4, 1.0, accuracy: 0.3, "the script does nothing outside YouTube (at \(t4))")
        let off = try await player(["sponsor": "auto"], offSites: ["youtube.com"])
        await give(off, segments); await seek(off, to: 1.0)
        let t5 = await time(off)
        XCTAssertEqual(t5, 1.0, accuracy: 0.3, "a site switched off is not touched (at \(t5))")
    }
}
