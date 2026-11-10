import XCTest
import WebKit
@testable import Browser_Setu

/// A banner built like a common consent tool: pressing its reject button must happen, and a banner with no known button must be hidden.
@MainActor
final class CookieBannerTests: XCTestCase {
    private func run(_ html: String, check: String) async throws -> Any? {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(WKUserScript(source: CookieBanners.script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        web.loadHTMLString(html, baseURL: URL(string: "http://127.0.0.1:18765/"))
        try await Task.sleep(for: .seconds(2))
        return try await web.callAsyncJavaScript(check, contentWorld: .page)
    }

    func testTheRejectButtonOfAKnownBannerIsPressed() async throws {
        let html = """
        <html><body style="height:3000px"><div id="onetrust-banner-sdk" style="position:fixed;bottom:0;width:100%;height:80px;background:#eee">
        <button id="onetrust-accept-btn-handler" onclick="window.accepted=true">Accept all</button>
        <button id="onetrust-reject-all-handler" onclick="window.rejected=true">Reject all</button></div></body></html>
        """
        let result = try await run(html, check: "return [window.rejected === true, window.accepted === true];") as? [Bool]
        XCTAssertEqual(result, [true, false], "reject was pressed and accept never was")
    }

    func testABannerWithNoKnownButtonIsHiddenAndScrollingIsGivenBack() async throws {
        let html = """
        <html style="overflow:hidden"><body style="overflow:hidden;height:3000px"><div id="cookie-banner" style="position:fixed;top:0;left:0;width:100%;height:100%;background:#000">We use cookies</div></body></html>
        """
        let result = try await run(html, check: "var b = document.getElementById('cookie-banner'); return [getComputedStyle(b).display, getComputedStyle(document.body).overflow];") as? [String]
        XCTAssertEqual(result?.first, "none")
        XCTAssertEqual(result?.last, "auto")
    }

    func testAnUnknownBannerWithAClearRejectWordIsRefused() async throws {
        let html = """
        <html><body><div class="my-cookie-box" style="width:300px;height:100px"><button onclick="window.said='no'">Reject all</button><button onclick="window.said='yes'">Accept</button></div></body></html>
        """
        let result = try await run(html, check: "return window.said || null;") as? String
        XCTAssertEqual(result, "no")
    }

    func testAnOrdinaryPageIsLeftAlone() async throws {
        let html = "<html><body><div id='content' style='width:200px;height:50px'>Hello</div><button id='b' onclick='window.clicked=true'>Reject all</button></body></html>"
        let result = try await run(html, check: "return [getComputedStyle(document.getElementById('content')).display, window.clicked === true];") as? [Any]
        XCTAssertEqual(result?.first as? String, "block")
        XCTAssertEqual(result?.last as? Bool, false, "a button outside a cookie box is not pressed")
    }

    // MARK: Refusal is only claimed when it happened

    private func load(_ html: String, script: String = CookieBanners.script, wait: Double = 2.2) async throws -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        web.loadHTMLString(html, baseURL: URL(string: "http://127.0.0.1:18765/"))
        try await Task.sleep(for: .seconds(wait))
        return web
    }

    private func found(_ web: WKWebView) async -> [String: Any] {
        guard let text = (try? await web.callAsyncJavaScript(CookieBanners.read, contentWorld: .defaultClient)) as? String,
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return [:] }
        return object
    }

    private func page(_ js: String, _ web: WKWebView) async -> Any? { try? await web.callAsyncJavaScript(js, contentWorld: .page) }

    func testARefusalIsReportedOnlyAfterTheBannerReallyCloses() async throws {
        let web = try await load("""
        <html><body><div id="onetrust-banner-sdk" style="position:fixed;bottom:0;width:100%;height:80px;background:#eee">
        <button id="onetrust-accept-btn-handler" onclick="window.accepted=true">Accept all</button>
        <button id="onetrust-reject-all-handler" onclick="window.rejected=true; document.getElementById('onetrust-banner-sdk').remove()">Reject all</button></div></body></html>
        """)
        let result = await found(web)
        XCTAssertEqual(result["state"] as? String, "refused")
        XCTAssertEqual(result["platform"] as? String, "onetrust")
        let flags = await page("return [window.rejected === true, window.accepted === true];", web) as? [Bool]
        XCTAssertEqual(flags, [true, false], "reject was pressed and accept never was")
    }

    func testAButtonThatIsPressedButChangesNothingIsNeverReportedAsARefusal() async throws {
        let web = try await load("""
        <html><body><div id="CybotCookiebotDialog" style="position:fixed;bottom:0;width:100%;height:80px;background:#eee">
        <button id="CybotCookiebotDialogBodyButtonDecline" onclick="window.pressed=true">Decline</button></div></body></html>
        """, wait: 4.5)
        let result = await found(web)
        XCTAssertEqual(result["state"] as? String, "hidden", "it could not be refused, so it was only hidden")
        XCTAssertEqual(result["why"] as? String, "still-showing")
        XCTAssertNotEqual(result["state"] as? String, "refused")
        let hidden = await page("return getComputedStyle(document.getElementById('CybotCookiebotDialog')).display;", web) as? String
        XCTAssertEqual(hidden, "none")
    }

    func testWithHidingSwitchedOffAnUnrefusableBannerIsLeftExactlyAsItWas() async throws {
        let web = try await load("""
        <html><body><div id="CybotCookiebotDialog" style="position:fixed;bottom:0;width:100%;height:80px;background:#eee">
        <button id="CybotCookiebotDialogBodyButtonDecline">Decline</button></div></body></html>
        """, script: CookieBanners.script(hideUnrefusable: false), wait: 4.5)
        let result = await found(web)
        XCTAssertEqual(result["state"] as? String, "recognised")
        let display = await page("return getComputedStyle(document.getElementById('CybotCookiebotDialog')).display;", web) as? String
        XCTAssertEqual(display, "block", "not hidden")
    }

    func testABannerWhoseToolOffersNoWayToRefuseIsHiddenAndSaidToBeHidden() async throws {
        let web = try await load("""
        <html><body style="overflow:hidden"><div id="sp_message_container_123" style="position:fixed;top:0;left:0;width:100%;height:100%;background:#000">We value your privacy</div></body></html>
        """)
        let result = await found(web)
        XCTAssertEqual(result["state"] as? String, "hidden")
        XCTAssertEqual(result["why"] as? String, "refusal-not-possible")
        let overflow = await page("return getComputedStyle(document.body).overflow;", web) as? String
        XCTAssertEqual(overflow, "auto", "scrolling is given back")
    }

    func testABannerWithASecondScreenIsRefusedThroughBothSteps() async throws {
        let web = try await load("""
        <html><body><div id="onetrust-banner-sdk" style="position:fixed;bottom:0;width:100%;height:80px;background:#eee">
        <button id="onetrust-pc-btn-handler" onclick="var b=document.createElement('button'); b.className='ot-pc-refuse-all-handler'; b.textContent='Reject all'; b.onclick=function(){window.refused=true; document.getElementById('onetrust-banner-sdk').remove();}; document.body.appendChild(b);">Settings</button>
        </div></body></html>
        """, wait: 3.5)
        let result = await found(web)
        XCTAssertEqual(result["state"] as? String, "refused")
        let done = await page("return window.refused === true;", web) as? Bool
        XCTAssertEqual(done, true)
    }

    func testABannerThatArrivesLateIsStillHandled() async throws {
        let web = try await load("""
        <html><body><script>setTimeout(function () {
          var d = document.createElement('div'); d.id = 'didomi-host'; d.style.cssText = 'position:fixed;bottom:0;width:100%;height:60px;background:#eee';
          var b = document.createElement('button'); b.id = 'didomi-notice-disagree-button'; b.textContent = 'Disagree'; b.onclick = function () { d.remove(); window.said = 'no'; };
          d.appendChild(b); document.body.appendChild(d); }, 1800);</script></body></html>
        """, wait: 4.5)
        let result = await found(web)
        XCTAssertEqual(result["state"] as? String, "refused")
        let said = await page("return window.said || null;", web) as? String
        XCTAssertEqual(said, "no")
    }

    func testABannerKeptInAShadowRootIsRefused() async throws {
        let web = try await load("""
        <html><body><div id="usercentrics-root" style="position:fixed;bottom:0;width:100%;height:80px"></div><script>
          var root = document.getElementById('usercentrics-root').attachShadow({ mode: 'open' });
          root.innerHTML = "<div id='uc-center-container' style='height:60px;background:#eee'><button data-testid='uc-deny-all-button'>Deny</button></div>";
          root.querySelector('button').onclick = function () { window.denied = true; document.getElementById('usercentrics-root').remove(); };
        </script></body></html>
        """, wait: 3.0)
        let result = await found(web)
        XCTAssertEqual(result["state"] as? String, "refused")
        XCTAssertEqual(result["platform"] as? String, "usercentrics")
    }

    func testASiteSwitchedOffIsNotTouchedAtAll() async throws {
        let web = try await load("""
        <html><body><div id="onetrust-banner-sdk" style="position:fixed;bottom:0;width:100%;height:80px;background:#eee">
        <button id="onetrust-reject-all-handler" onclick="window.rejected=true">Reject all</button></div></body></html>
        """, script: CookieBanners.script(excluded: ["127.0.0.1"]))
        let result = await found(web)
        XCTAssertEqual(result["why"] as? String, "site-off")
        let flags = await page("return [window.rejected === true, getComputedStyle(document.getElementById('onetrust-banner-sdk')).display];", web) as? [Any]
        XCTAssertEqual(flags?.first as? Bool, false)
        XCTAssertEqual(flags?.last as? String, "block")
    }

    func testAPageThatKeepsChangingIsNotScannedWithoutEndAndStaysUsable() async throws {
        let web = try await load("""
        <html><body style="height:4000px"><input id="name" value=""><a id="link" href="#section">go</a><div id="section" style="margin-top:2000px">s</div>
        <script>setInterval(function () { var d = document.createElement('div'); d.textContent = 'tick'; document.body.appendChild(d); }, 25);</script></body></html>
        """, wait: 5.0)
        let result = await found(web)
        XCTAssertEqual(result["state"] as? String, "none", "nothing here is a banner")
        XCTAssertLessThanOrEqual(result["sweeps"] as? Int ?? 99, 25, "the page is swept a bounded number of times however much it changes")
        // Scrolling, typing and following a link all still work.
        let usable = await page("""
        document.getElementById('name').value = 'typed'; window.scrollTo(0, 800);
        document.getElementById('link').click();
        await new Promise(function (r) { setTimeout(r, 200); });
        return [document.getElementById('name').value, window.scrollY > 0, location.hash];
        """, web) as? [Any]
        XCTAssertEqual(usable?[0] as? String, "typed")
        XCTAssertEqual(usable?[1] as? Bool, true)
        XCTAssertEqual(usable?[2] as? String, "#section")
    }

    func testAnOrdinaryContentBoxNamedLikeACookieIsNotHidden() async throws {
        let web = try await load("""
        <html><body><div id="cookie-recipes" style="width:300px;height:100px">Chocolate chip cookie recipes <button>Reject</button></div></body></html>
        """, wait: 3.5)
        let display = await page("return getComputedStyle(document.getElementById('cookie-recipes')).display;", web) as? String
        XCTAssertEqual(display, "block", "only fixed or stuck elements and known banner names are treated as banners")
    }

    // MARK: The record

    func testTheRecordNeverCallsAHiddenBannerRefusedAndPrivateTabsKeepNothing() async throws {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-consent-\(UUID().uuidString)", profile: "default")
        await m.start()
        m.recordConsent(host: "shop.example", platform: "cookiebot", outcome: .hidden, why: "still-showing", catalog: 4)
        m.recordConsent(host: "news.example", platform: "onetrust", outcome: .refused, why: "banner-closed", catalog: 4)
        m.recordConsent(host: "news.example", platform: "onetrust", outcome: .refused, why: "banner-closed", catalog: 4)
        XCTAssertEqual(m.consentLog.count, 2, "the same result for the same site within the hour is one record")
        let hidden = try XCTUnwrap(m.consentLog.first { $0.outcome == .hidden })
        XCTAssertTrue(hidden.summary.contains("NOT refused"))
        XCTAssertEqual(hidden.outcome.title, "Hidden, not refused")
        let refused = try XCTUnwrap(m.consentLog.first { $0.outcome == .refused })
        XCTAssertFalse(refused.summary.contains("NOT"))
        XCTAssertTrue(m.consentLog.allSatisfy { $0.outcome != .none && $0.outcome != .pending })
        let priv = m.openTab(url: nil, isPrivate: true)
        priv.watchConsent()
        XCTAssertNil(priv.consentTask, "a private tab records nothing")
        m.setConsentHandling(host: "shop.example", on: false)
        XCTAssertFalse(m.consentHandling(forHost: "www.shop.example"))
        m.clearConsentLog()
        XCTAssertTrue(m.consentLog.isEmpty)
    }
}
