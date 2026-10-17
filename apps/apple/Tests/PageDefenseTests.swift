import XCTest
import WebKit
@testable import Browser_Setu

final class PageDefenseTests: XCTestCase {
    func testAMPCacheLinksGoToTheSitesOwnPage() {
        func canon(_ s: String) -> String? { AMPLinks.canonical(URL(string: s)!)?.absoluteString }
        XCTAssertEqual(canon("https://www.google.com/amp/s/example.com/news/story?id=3&amp_js_v=0.1"), "https://example.com/news/story?id=3")
        XCTAssertEqual(canon("https://example-com.cdn.ampproject.org/c/s/example.com/a/b.html"), "https://example.com/a/b.html")
        XCTAssertEqual(canon("https://example-com.cdn.ampproject.org/v/example.com/a"), "http://example.com/a")
        XCTAssertEqual(canon("https://www.google.co.uk/amp/s/news.test/x"), "https://news.test/x")
        XCTAssertNil(canon("https://www.google.com/search?q=amp"))
        XCTAssertNil(canon("https://www.google.com/amp/s/notahost/page"), "the next part must look like a host")
        XCTAssertNil(canon("https://example.com/amp/s/other.com/x"), "only Google's and the AMP cache's own addresses")
        XCTAssertNil(canon("https://example.cdn.ampproject.org/zzz/s/example.com/x"))
        XCTAssertNil(canon("ftp://www.google.com/amp/s/example.com/x"))
    }

    func testTheNeverSleepListKeepsATabAwake() {
        let now = Date()
        let old = now.addingTimeInterval(-3600)
        func tab(_ id: UInt64, exempt: Bool) -> TabCandidate {
            TabCandidate(id: id, lastActive: old, pinned: false, isPrivate: false, isActive: false, loaded: true, discarded: false, exempt: exempt)
        }
        let candidates = [TabCandidate(id: 1, lastActive: now, pinned: false, isPrivate: false, isActive: true, loaded: true, discarded: false), tab(2, exempt: false), tab(3, exempt: true), tab(4, exempt: false)]
        let victims = TabLifecyclePolicy.victims(candidates, mode: .saver, event: .critical, now: now, keepPinned: true)
        XCTAssertTrue(victims.contains(2) && victims.contains(4))
        XCTAssertFalse(victims.contains(3), "a tab on a never-sleep site is not chosen")
    }

    @MainActor func testPerSiteChoicesAreSavedByTheSitesNameAndSurviveARestart() async throws {
        let root = NSTemporaryDirectory() + "bs-def-\(UUID().uuidString)"
        let m = BrowserModel(engine: WebKitEngine(), root: root, profile: "default")
        await m.start()
        m.setScripts(host: "www.Shop.test", allowed: false)
        m.setNeverSleeps(host: "mail.test", true)
        m.setFingerprintException(host: "www.maps.test", allowed: true)
        XCTAssertFalse(m.scriptsAllowed(forHost: "shop.test"), "www. and capitals do not matter")
        XCTAssertTrue(m.scriptsAllowed(forHost: "other.test"))
        XCTAssertTrue(m.neverSleeps(host: "MAIL.test"))
        let again = BrowserModel(engine: WebKitEngine(), root: root, profile: "default")
        await again.start()
        XCTAssertFalse(again.scriptsAllowed(forHost: "shop.test"))
        XCTAssertTrue(again.neverSleeps(host: "mail.test"))
        XCTAssertTrue(again.fingerprintExceptions.contains("maps.test"))
        XCTAssertTrue(again.deAMP, "AMP replacing is on unless the person turns it off")
        XCTAssertFalse(again.blockVideoAds); XCTAssertFalse(again.randomizeFingerprint)
        let report = await again.siteReport(host: "shop.test")
        XCTAssertTrue(report.settings.contains("JavaScript off"), "the site report lists it")
    }

    @MainActor func testAnAMPCacheLinkIsReplacedOnlyWhileTheSwitchIsOn() async throws {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-amp-\(UUID().uuidString)", profile: "default")
        await m.start()
        let link = URL(string: "https://www.google.com/amp/s/example.com/story")!
        XCTAssertEqual(m.deAMPedLink(link)?.absoluteString, "https://example.com/story")
        m.deAMP = false
        XCTAssertNil(m.deAMPedLink(link))
    }
}

@MainActor
final class PageDefensePageTests: XCTestCase {
    private func model() async -> BrowserModel {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-defp-\(UUID().uuidString)", profile: "default")
        await m.start()
        return m
    }

    private func waitFor(_ seconds: Double = 10, _ condition: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if await condition() { return true }; try? await Task.sleep(for: .milliseconds(100)) }
        return await condition()
    }

    private func eval(_ tab: TabController, _ code: String, world: WKContentWorld = .page) async -> Any? {
        guard let web = tab.hostView as? WKWebView else { return nil }
        return try? await web.callAsyncJavaScript(code, contentWorld: world)
    }

    func testScriptsCanBeSwitchedOffForOneSiteAndOnForTheNextLoad() async throws {
        let m = await model()
        m.setScripts(host: "127.0.0.1", allowed: false)
        let tab = m.openTab(url: nil, isPrivate: false)
        tab.load(URL(string: "http://127.0.0.1:18765/script-page")!)
        _ = await waitFor { tab.hasLoadedPage }
        try await Task.sleep(for: .milliseconds(600))
        let off = await eval(tab, "return document.title;") as? String
        XCTAssertEqual(off, "before", "the page's own script did not run")
        m.setScripts(host: "127.0.0.1", allowed: true)      // reloads the tab
        let ran = await waitFor { (await self.eval(tab, "return document.title;") as? String) == "ran" }
        XCTAssertTrue(ran, "and runs once the site is allowed again")
    }

    func testTheTabsOwnSwitchStillWorks() async throws {
        let m = await model()
        let tab = m.openTab(url: nil, isPrivate: false)
        tab.toggleJavaScript()
        tab.load(URL(string: "http://127.0.0.1:18765/script-page")!)
        _ = await waitFor { tab.hasLoadedPage }
        try await Task.sleep(for: .milliseconds(600))
        let title = await eval(tab, "return document.title;") as? String
        XCTAssertEqual(title, "before")
    }

    func testAnAMPPageSendsYouToItsOwnVersion() async throws {
        let m = await model()
        m.deAMP = true
        let tab = m.openTab(url: nil, isPrivate: false)
        tab.load(URL(string: "http://127.0.0.1:18765/amp-page")!)
        let moved = await waitFor { tab.url?.path == "/full-page" }
        XCTAssertTrue(moved, "the AMP copy named its own page and the browser went there")
    }

    func testFingerprintChangesAreStableInASiteDifferentBetweenSitesAndOffByDefault() async throws {
        let paint = """
        const c = document.createElement('canvas'); c.width = 220; c.height = 60; const x = c.getContext('2d');
        x.fillStyle = '#336699'; x.fillRect(0, 0, 220, 60); x.fillStyle = '#ffcc00'; x.font = '22px Arial'; x.fillText('Cwm fjordbank glyphs vext quiz', 4, 36);
        const d = x.getImageData(0, 0, 220, 60).data; let sum = 0; for (let i = 0; i < d.length; i++) sum += d[i];
        return [c.toDataURL(), sum, navigator.hardwareConcurrency];
        """
        func read(_ m: BrowserModel, host: String) async throws -> (String, Int, Int) {
            let tab = m.openTab(url: nil, isPrivate: false)
            (tab.hostView as? WKWebView)?.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
            tab.engine.showHTML("<html><body>x</body></html>", baseURL: URL(string: "https://\(host)/"))
            try await Task.sleep(for: .seconds(1.0))
            let value = await eval(tab, paint)
            let r = try XCTUnwrap(value as? [Any])
            return (r[0] as? String ?? "", (r[1] as? NSNumber)?.intValue ?? -1, (r[2] as? NSNumber)?.intValue ?? -1)
        }
        let plain = await model()
        let base = try await read(plain, host: "a.fp.test")
        let other = try await read(plain, host: "b.fp.test")
        XCTAssertEqual(base.0, other.0, "without the switch every site sees the same picture")

        let m = await model()
        m.randomizeFingerprint = true
        let a1 = try await read(m, host: "a.fp.test"), a2 = try await read(m, host: "a.fp.test"), b1 = try await read(m, host: "b.fp.test")
        XCTAssertNotEqual(a1.0, base.0, "the picture's code is changed")
        XCTAssertEqual(a1.0, a2.0, "but the same on the same site")
        XCTAssertNotEqual(a1.0, b1.0, "and different on another site")
        XCTAssertLessThan(abs(a1.1 - base.1), base.1 / 50, "the change is tiny")
        XCTAssertLessThanOrEqual(a1.2, 8)
        m.setFingerprintException(host: "a.fp.test", allowed: true)
        let excepted = try await read(m, host: "a.fp.test")
        XCTAssertEqual(excepted.0, base.0, "a site on the exception list sees the real picture")
    }

    func testYouTubeAdsAreHiddenSkippedAndTheSoundComesBack() async throws {
        let m = await model()
        m.blockVideoAds = true
        let tab = m.openTab(url: nil, isPrivate: false)
        (tab.hostView as? WKWebView)?.frame = CGRect(x: 0, y: 0, width: 640, height: 400)
        // One second of silence as a sound file, built in the page itself.
        let html = """
        <html><body><div id="movie_player" class="html5-video-player ad-showing"><video class="html5-main-video" preload="auto"></video>
        <button class="ytp-skip-ad-button" onclick="window.skipped = 1">Skip</button></div><div id="masthead-ad">ad</div>
        <script>
        const samples = 8000, bytes = new Uint8Array(44 + samples * 2), view = new DataView(bytes.buffer);
        const text = (at, s) => { for (let i = 0; i < s.length; i++) view.setUint8(at + i, s.charCodeAt(i)); };
        text(0, 'RIFF'); view.setUint32(4, 36 + samples * 2, true); text(8, 'WAVEfmt '); view.setUint32(16, 16, true); view.setUint16(20, 1, true); view.setUint16(22, 1, true);
        view.setUint32(24, 8000, true); view.setUint32(28, 16000, true); view.setUint16(32, 2, true); view.setUint16(34, 16, true); text(36, 'data'); view.setUint32(40, samples * 2, true);
        document.querySelector('video').src = URL.createObjectURL(new Blob([bytes], { type: 'audio/wav' }));
        </script></body></html>
        """
        tab.engine.showHTML(html, baseURL: URL(string: "https://www.youtube.com/watch?v=x"))
        // The sound clip has to be known to the video before the script can act on it.
        let ready = await waitFor(8) { ((await self.eval(tab, "const v = document.querySelector('video'); return v ? v.readyState : -1;") as? NSNumber)?.intValue ?? -1) >= 1 }
        try await Task.sleep(for: .seconds(2))
        let display = await eval(tab, "return getComputedStyle(document.getElementById('masthead-ad')).display;") as? String
        XCTAssertEqual(display, "none", "the ad slot is hidden")
        let skipped = (await eval(tab, "return window.skipped || 0;") as? NSNumber)?.intValue
        XCTAssertEqual(skipped, 1, "Skip was pressed")
        // Muting and jumping to the end need a sound clip that really loads. In the test host WebKit's media does not (the video reports "no source"), so this part is
        // only exercised when it does; it has not been exercised on a real page either.
        guard ready else { throw XCTSkip("the test host cannot load media, so the mute-and-jump path was not exercised") }
        let muted = await eval(tab, "const v = document.querySelector('video'); return [v.muted, v.currentTime, v.duration];", world: .defaultClient) as? [Any]
        XCTAssertEqual(muted?.first as? Bool, true, "the ad is muted")
        _ = await eval(tab, "document.getElementById('movie_player').classList.remove('ad-showing');")
        try await Task.sleep(for: .seconds(1))
        let after = await eval(tab, "const v = document.querySelector('video'); return [v.muted, v.playbackRate];", world: .defaultClient) as? [Any]
        XCTAssertEqual(after?.first as? Bool, false, "the sound is back when the ad is over")
        XCTAssertEqual((after?.last as? NSNumber)?.doubleValue, 1)
    }

    func testOtherSitesAreLeftAloneByTheYouTubeScript() async throws {
        let m = await model()
        m.blockVideoAds = true
        let tab = m.openTab(url: nil, isPrivate: false)
        (tab.hostView as? WKWebView)?.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        tab.engine.showHTML("<html><body><div id='masthead-ad'>not an ad here</div></body></html>", baseURL: URL(string: "https://news.example.test/"))
        try await Task.sleep(for: .seconds(1))
        let display = await eval(tab, "return getComputedStyle(document.getElementById('masthead-ad')).display;") as? String
        XCTAssertEqual(display, "block")
    }
}

@MainActor
final class AutoplayGuardTests: XCTestCase {
    private func model() async -> BrowserModel {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-ap-\(UUID().uuidString)", profile: "default")
        await m.start()
        return m
    }

    private func probe(_ m: BrowserModel, host: String) async throws -> [String: Any] {
        let tab = m.openTab(url: nil, isPrivate: false)
        (tab.hostView as? WKWebView)?.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        tab.engine.showHTML("<html><body><video id='v' autoplay muted></video><audio id='a'></audio></body></html>", baseURL: URL(string: "https://\(host)/"))
        try await Task.sleep(for: .seconds(1.2))
        let web = try XCTUnwrap(tab.hostView as? WKWebView)
        let script = """
        const v = document.getElementById('v'), a = document.getElementById('a');
        let message = 'resolved';
        try { message = await Promise.race([a.play().then(() => 'resolved'), new Promise(r => setTimeout(() => r('still waiting'), 800))]); } catch (e) { message = e.name + ': ' + e.message; }
        return { message: message, autoplayAttribute: v.hasAttribute('autoplay'), patched: HTMLMediaElement.prototype.play.toString().indexOf('native code') < 0 };
        """
        let value = try await web.callAsyncJavaScript(script, contentWorld: .page)
        return try XCTUnwrap(value as? [String: Any])
    }

    func testAPageCannotStartMediaWithoutATapAndTheAutoplayAttributeIsRemoved() async throws {
        let m = await model()
        XCTAssertTrue(m.blockAutoplay, "on unless the person turns it off")
        let r = try await probe(m, host: "feed.example.test")
        XCTAssertEqual(r["patched"] as? Bool, true)
        XCTAssertTrue((r["message"] as? String ?? "").hasPrefix("NotAllowedError"), "play() with no tap is refused: \(String(describing: r["message"]))")
        XCTAssertEqual(r["autoplayAttribute"] as? Bool, false, "an autoplay attribute does not start anything")
    }

    func testASiteOnTheExceptionListAndTheSwitchBeingOffLeavePlaybackAlone() async throws {
        let m = await model()
        m.setAutoplayException(host: "www.call.example.test", allowed: true)
        let allowed = try await probe(m, host: "call.example.test")
        XCTAssertFalse((allowed["message"] as? String ?? "").hasPrefix("NotAllowedError: Playback needs a tap"), "this site is let alone")
        let other = await model()
        other.blockAutoplay = false
        let off = try await probe(other, host: "feed.example.test")
        XCTAssertEqual(off["patched"] as? Bool, false, "nothing is installed with the switch off")
    }

    func testTheChoiceIsRememberedPerProfile() async throws {
        let root = NSTemporaryDirectory() + "bs-apr-\(UUID().uuidString)"
        let a = BrowserModel(engine: WebKitEngine(), root: root, profile: "default")
        await a.start()
        a.blockAutoplay = false
        a.setAutoplayException(host: "x.test", allowed: true)
        let b = BrowserModel(engine: WebKitEngine(), root: root, profile: "default")
        await b.start()
        XCTAssertFalse(b.blockAutoplay)
        XCTAssertTrue(b.autoplayExceptions.contains("x.test"))
    }
}
