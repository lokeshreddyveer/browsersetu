import WebKit
import XCTest
@testable import Browser_Setu

/// A tracker frame embedded in many sites must not be able to tell the sites apart from the others, or see the same noise on all of them: the noise it gets is the top
/// page's, so it is the same inside one site and different between sites. The frame here is from another origin (sandboxed, so it cannot read the page around it).
@MainActor
final class FingerprintFrameTests: XCTestCase {
    private let draw = """
    function fp() {
      var c = document.createElement('canvas'); c.width = 200; c.height = 40;
      var x = c.getContext('2d'); x.fillStyle = '#336699'; x.fillRect(0, 0, 200, 40); x.fillStyle = '#ffcc00'; x.font = '18px sans-serif'; x.fillText('Fingerprint test 123', 6, 26);
      var s = c.toDataURL(), h = 5381; for (var i = 0; i < s.length; i++) { h = ((h << 5) + h + s.charCodeAt(i)) | 0; } return String(h);
    }
    """

    private func hashes(topSite: String, exceptions: Set<String> = []) async throws -> (top: String, frame: String, frameCouldReadTop: Bool) {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(WKUserScript(source: PageScripts.fingerprint(seed: 424242, exceptions: exceptions), injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 500, height: 400), configuration: config)
        let frameCode = "<script>\(draw) var readable = true; try { void window.top.location.href; } catch (e) { readable = false; } parent.postMessage({ h: fp(), readable: readable }, '*');</script>"
        let html = """
        <html><body><script>
        \(draw)
        window.__top = fp(); window.__frame = null; window.__readable = null;
        window.addEventListener('message', function (e) { window.__frame = e.data.h; window.__readable = e.data.readable; });
        var f = document.createElement('iframe'); f.sandbox = 'allow-scripts'; f.srcdoc = \(jsString(frameCode)); document.body.appendChild(f);
        </script></body></html>
        """
        web.loadHTMLString(html, baseURL: URL(string: "http://\(topSite)/"))
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(150))
            if let ready = try await web.callAsyncJavaScript("return window.__frame !== null;", contentWorld: .page) as? Bool, ready { break }
        }
        let top = try await web.callAsyncJavaScript("return window.__top;", contentWorld: .page) as? String ?? ""
        let frame = try await web.callAsyncJavaScript("return String(window.__frame);", contentWorld: .page) as? String ?? ""
        let readable = try await web.callAsyncJavaScript("return window.__readable;", contentWorld: .page) as? Bool ?? true
        return (top, frame, readable)
    }

    private func jsString(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[\"\"]".utf8)
        let array = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }

    func testAFrameFromAnotherSiteGetsTheTopPagesNoiseNotItsOwn() async throws {
        let a = try await hashes(topSite: "site-a.test")
        let b = try await hashes(topSite: "site-b.test")
        XCTAssertFalse(a.frameCouldReadTop, "the frame really is cut off from the page around it")
        XCTAssertFalse(a.top.isEmpty); XCTAssertFalse(a.frame.isEmpty); XCTAssertNotEqual(a.frame, "null")
        XCTAssertNotEqual(a.top, b.top, "different sites get different noise")
        XCTAssertEqual(a.frame, a.top, "inside one site, the frame and the page agree")
        XCTAssertEqual(b.frame, b.top)
        XCTAssertNotEqual(a.frame, b.frame, "the same tracker frame sees something different on each site")
    }

    func testAnExceptionForTheTopSiteAlsoCoversItsFrames() async throws {
        let plain = try await hashes(topSite: "site-a.test")
        let excepted = try await hashes(topSite: "site-a.test", exceptions: ["site-a.test"])
        XCTAssertNotEqual(plain.top, excepted.top, "the page itself is left alone when excepted")
        XCTAssertEqual(excepted.top, excepted.frame, "and so is the frame inside it (both give the untouched picture)")
    }
}
