import XCTest
import WebKit
@testable import Browser_Setu

@MainActor
final class VideoControlsTests: XCTestCase {
    private func page(speeds: [String: Double], host: String = "127.0.0.1") async throws -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(WKUserScript(source: VideoControls.rememberedSpeedScript(speeds), injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 400), configuration: config)
        web.loadHTMLString("<html><body><video id=a></video><video id=b></video></body></html>", baseURL: URL(string: "http://\(host):18765/"))
        try await Task.sleep(for: .seconds(2))
        return web
    }

    func testARememberedSpeedIsGivenToEveryVideoOnThatSite() async throws {
        let web = try await page(speeds: ["127.0.0.1": 1.5])
        let rates = try await web.callAsyncJavaScript("return Array.from(document.querySelectorAll('video')).map(v => v.playbackRate);", contentWorld: .page) as? [Double]
        XCTAssertEqual(rates, [1.5, 1.5])
    }

    func testAnotherSiteIsNotChanged() async throws {
        let web = try await page(speeds: ["example.com": 2])
        let rates = try await web.callAsyncJavaScript("return Array.from(document.querySelectorAll('video')).map(v => v.playbackRate);", contentWorld: .page) as? [Double]
        XCTAssertEqual(rates, [1, 1])
    }

    func testAVideoAddedLaterGetsTheSpeedToo() async throws {
        let web = try await page(speeds: ["127.0.0.1": 1.25])
        let rate = try await web.callAsyncJavaScript("""
            var v = document.createElement('video'); document.body.appendChild(v);
            v.dispatchEvent(new Event('loadedmetadata', { bubbles: true }));
            return v.playbackRate;
            """, contentWorld: .page) as? Double
        XCTAssertEqual(rate, 1.25)
    }

    func testChoosingASpeedChangesTheVideosNow() async throws {
        let web = try await page(speeds: [:])
        let count = try await web.callAsyncJavaScript(VideoControls.setNow(2), contentWorld: .defaultClient) as? Int
        XCTAssertEqual(count, 2)
        let rates = try await web.callAsyncJavaScript("return Array.from(document.querySelectorAll('video')).map(v => v.playbackRate);", contentWorld: .page) as? [Double]
        XCTAssertEqual(rates, [2, 2])
    }

    func testTheLabelsReadWell() {
        XCTAssertEqual(VideoControls.label(1), "1×")
        XCTAssertEqual(VideoControls.label(1.5), "1.5×")
        XCTAssertEqual(VideoControls.label(0.75), "0.75×")
    }
}
