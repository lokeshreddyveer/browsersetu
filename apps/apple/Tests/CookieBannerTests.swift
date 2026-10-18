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
}
