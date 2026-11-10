import WebKit
import XCTest
@testable import Browser_Setu

/// What the new privacy switches do to a real page in a real web view, not just what the settings say. Needs the fixture server (scripts/testserver.py, port 18765),
/// which the test scheme starts by itself.
@MainActor
final class RealPageBehaviourTests: XCTestCase {
    private func model() async -> BrowserModel {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-real-\(UUID().uuidString)", profile: "default")
        await m.start()
        return m
    }

    private func eval(_ tab: TabController, _ code: String) async -> Any? {
        guard let web = tab.hostView as? WKWebView else { return nil }
        return try? await web.callAsyncJavaScript(code, contentWorld: .page)
    }

    private func show(_ html: String, host: String, in tab: TabController) async throws {
        (tab.hostView as? WKWebView)?.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        tab.engine.showHTML(html, baseURL: URL(string: "http://\(host)/"))
        try await Task.sleep(for: .milliseconds(900))
    }

    func testGlobalPrivacyControlIsSeenByThePageAndCanBeSwitchedOff() async throws {
        let on = await model()
        let tab = on.openTab(url: nil, isPrivate: false)
        try await show("<html><body>x</body></html>", host: "gpc-on.test", in: tab)
        let seen = await eval(tab, "return navigator.globalPrivacyControl === true;") as? Bool
        XCTAssertEqual(seen, true)
        let off = await model()
        off.globalPrivacyControl = false
        let other = off.openTab(url: nil, isPrivate: false)
        try await show("<html><body>x</body></html>", host: "gpc-off.test", in: other)
        let notSeen = await eval(other, "return navigator.globalPrivacyControl === true;") as? Bool
        XCTAssertEqual(notSeen, false)
    }

    func testLinkPingsAreRemovedNowAndAsThePageAddsThem() async throws {
        let m = await model()
        let tab = m.openTab(url: nil, isPrivate: false)
        try await show(#"<html><body><a id="a" href="https://x.test/" ping="https://tracker.test/p">x</a><script>setTimeout(function(){var b=document.createElement('a');b.id='b';b.href='https://y.test/';b.setAttribute('ping','https://t.test/');document.body.appendChild(b);},100);</script></body></html>"#, host: "ping.test", in: tab)
        let first = await eval(tab, "return document.getElementById('a').hasAttribute('ping');") as? Bool
        let second = await eval(tab, "return document.getElementById('b') ? document.getElementById('b').hasAttribute('ping') : false;") as? Bool
        XCTAssertEqual(first, false, "the link that was there is cleaned")
        XCTAssertEqual(second, false, "and so is the one the page added later")
        let off = await model()
        off.blockLinkPings = false
        let plain = off.openTab(url: nil, isPrivate: false)
        try await show(#"<html><body><a id="a" href="https://x.test/" ping="https://tracker.test/p">x</a></body></html>"#, host: "pingoff.test", in: plain)
        let kept = await eval(plain, "return document.getElementById('a').hasAttribute('ping');") as? Bool
        XCTAssertEqual(kept, true, "left alone when the switch is off")
    }

    func testMeasurementNoiseKeepsPagesWorking() async throws {
        let m = await model()
        m.randomizeFingerprint = true
        let tab = m.openTab(url: nil, isPrivate: false)
        try await show(#"<html><body style="margin:0"><div id="d" style="width:120px;height:40px">hello</div></body></html>"#, host: "noise.test", in: tab)
        let value = await eval(tab, """
        const r = document.getElementById('d').getBoundingClientRect();
        const w = document.createElement('canvas').getContext('2d').measureText('hello');
        return [r.width, r.height, typeof r.toJSON, w.width, document.createRange().getBoundingClientRect() instanceof DOMRect];
        """) as? [Any]
        let r = try XCTUnwrap(value)
        XCTAssertEqual((r[0] as? NSNumber)?.doubleValue ?? 0, 120, accuracy: 0.01, "far below anything a layout shows")
        XCTAssertEqual((r[1] as? NSNumber)?.doubleValue ?? 0, 40, accuracy: 0.01)
        XCTAssertEqual(r[2] as? String, "function")
        XCTAssertGreaterThan((r[3] as? NSNumber)?.doubleValue ?? 0, 0)
        XCTAssertEqual(r[4] as? Bool, true)
    }

    /// The fixture server stands in for a device on the home network: a page on the internet may not load from it, unless the person said so.
    func testAWebsiteCannotLoadFromTheHomeNetworkUnlessAllowed() async throws {
        let probe = #"<html><body><script>window.result='waiting';</script><script src="http://127.0.0.1:18765/tracker.js" onload="window.result='loaded'" onerror="window.result='blocked'"></script></body></html>"#

        let free = await model()
        let a = free.openTab(url: nil, isPrivate: false)
        try await show(probe, host: "public-a.test", in: a)
        let open = await eval(a, "return window.result;") as? String
        XCTAssertEqual(open, "loaded", "without the switch the page reaches the local address")

        let guarded = await model()
        guarded.blockLocalNetwork = true
        await guarded.engine.policyRulesReady()
        let b = guarded.openTab(url: nil, isPrivate: false)
        try await show(probe, host: "public-b.test", in: b)
        let refused = await eval(b, "return window.result;") as? String
        XCTAssertEqual(refused, "blocked", "with the switch it is refused")

        let allowed = await model()
        allowed.blockLocalNetwork = true
        allowed.localNetworkAllowed = ["public-c.test"]
        await allowed.engine.policyRulesReady()
        let c = allowed.openTab(url: nil, isPrivate: false)
        try await show(probe, host: "public-c.test", in: c)
        let permitted = await eval(c, "return window.result;") as? String
        XCTAssertEqual(permitted, "loaded", "a site the person allowed may")
    }

    func testAPageOnTheLocalNetworkItselfIsNotCutOff() async throws {
        let m = await model()
        m.blockLocalNetwork = true
        await m.engine.policyRulesReady()
        let tab = m.openTab(url: nil, isPrivate: false)
        tab.load(URL(string: "http://127.0.0.1:18765/page")!)
        let end = Date().addingTimeInterval(10)
        while tab.title != "Page", Date() < end { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(tab.hasLoadedPage, "going to a local address yourself still works")
        XCTAssertEqual(tab.title, "Page", "the page itself loaded, not an error")
    }

    // MARK: Video: what may start by itself

    private func scriptedPlayErrors(blockAutoplay: Bool) async throws -> [String: String] {
        let m = await model()
        m.blockAutoplay = blockAutoplay
        let tab = m.openTab(url: nil, isPrivate: false)
        (tab.hostView as? WKWebView)?.frame = CGRect(x: 0, y: 0, width: 400, height: 900)
        tab.load(URL(string: "http://127.0.0.1:18765/video-matrix")!)
        try await Task.sleep(for: .seconds(5))
        return (await eval(tab, "return window.__err || {};") as? [String: String]) ?? ["_": "no answer"]
    }

    /// A page that calls play() with nobody having touched it is refused while the switch is on, and allowed when it is off (it used to be refused either way).
    func testTheAutoplaySwitchDecidesWhetherAPageMayStartVideoItself() async throws {
        let on = try await scriptedPlayErrors(blockAutoplay: true)
        XCTAssertEqual(on["f"], "NotAllowedError", "switch on: refused")
        XCTAssertEqual(on["g"], "NotAllowedError", "…also when the page waits a few seconds first")
        let off = try await scriptedPlayErrors(blockAutoplay: false)
        XCTAssertNil(off["f"], "switch off: allowed")
        XCTAssertNil(off["g"])
    }

    func testProbeColourFilterSupport() async throws {
        let m = await model()
        let tab = m.openTab(url: nil, isPrivate: false)
        try await show("<html><body>x</body></html>", host: "probe.test", in: tab)
        let v = await eval(tab, """
        return JSON.stringify({
          appleInvert: CSS.supports('-apple-color-filter', 'apple-invert-lightness()'),
          appleNone: CSS.supports('-apple-color-filter', 'none'),
          backdrop: CSS.supports('backdrop-filter', 'invert(1)'),
          webkitBackdrop: CSS.supports('-webkit-backdrop-filter', 'invert(1)'),
          colorScheme: CSS.supports('color-scheme', 'dark'),
          userActivation: !!navigator.userActivation,
          matchDark: matchMedia('(prefers-color-scheme: dark)').matches
        });
        """) as? String
        print("PROBE \(v ?? "nil")")
    }
}
