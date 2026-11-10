import SetuPrivacyCore
import WebKit
import XCTest
@testable import Browser_Setu

/// A website the person switched blocking off for (or paused) is left alone by every part of the filtering, not only the network rules.
@MainActor
final class FilterExceptionTests: XCTestCase {
    private let list = """
    shop.test##.card:has-text(Sponsored)
    shop.test##+js(set-constant, adBlockDetected, false)
    """
    private let html = "<html><body><script>window.adBlockDetected = true;</script><div class='card' id='a'>Sponsored: buy now</div></body></html>"

    private func page(host: String, exceptions: [String]) async throws -> (hidden: String?, detected: Bool?) {
        var classified = FilterClassifier.parse(Data(list.utf8), name: "T")
        classified.scripts.exceptions = exceptions
        let scripts = FilterScripts.make(from: classified.scripts)
        let config = WKWebViewConfiguration()
        UserScriptInstaller.addFilterScripts(scripts, to: config.userContentController)
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 600), configuration: config)
        web.loadHTMLString(html, baseURL: URL(string: "http://\(host)/"))
        try await Task.sleep(for: .seconds(1.2))
        let hidden = try await web.callAsyncJavaScript("return getComputedStyle(document.getElementById('a')).display;", contentWorld: .page) as? String
        let detected = try await web.callAsyncJavaScript("return window.adBlockDetected;", contentWorld: .page) as? Bool
        return (hidden, detected)
    }

    func testWithoutAnExceptionTheSiteIsFilteredBothWays() async throws {
        let r = try await page(host: "shop.test", exceptions: [])
        XCTAssertEqual(r.hidden, "none")
        XCTAssertEqual(r.detected, false, "the scriptlet ran")
    }

    func testAnExceptedSiteGetsNeitherTheHidingNorTheScriptlet() async throws {
        let r = try await page(host: "shop.test", exceptions: ["shop.test"])
        XCTAssertEqual(r.hidden, "block", "the element is left alone")
        XCTAssertEqual(r.detected, true, "and the page's own value is untouched")
    }

    func testAnExceptionCoversSubdomainsButNotOtherSites() async throws {
        let sub = try await page(host: "www.shop.test", exceptions: ["shop.test"])
        XCTAssertEqual(sub.hidden, "block")
        // (a rule written for shop.test only reaches www.shop.test through the domain match; an unrelated exception changes nothing)
        let other = try await page(host: "shop.test", exceptions: ["unrelated.test"])
        XCTAssertEqual(other.hidden, "none")
        XCTAssertEqual(other.detected, false)
    }

    func testChangingTheExceptionsChangesTheScriptsSoTheyAreInstalledAgain() {
        var rules = FilterClassifier.parse(Data(list.utf8), name: "T").scripts
        let none = FilterScripts.make(from: rules)
        rules.exceptions = ["shop.test"]
        let some = FilterScripts.make(from: rules)
        XCTAssertNotEqual(none, some, "the engine only reinstalls scripts that changed")
        XCTAssertNotEqual(rules.digest, FilterClassifier.parse(Data(list.utf8), name: "T").scripts.digest)
    }

    func testPausingASiteReachesThePageScriptsThroughTheSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bs-exc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let core = try BrowserCore.open(root: root.path, profile: "exc-test")
        let privacy = PrivacyController(engine: WebKitEngine(), cacheDirectory: root.appendingPathComponent("lists"))
        privacy.load(from: core)
        // Pausing or resuming starts its own rebuild; wait for it rather than racing it.
        func settle(_ expected: Bool) async -> Bool {
            for _ in 0..<80 {
                if (privacy.snapshot?.scriptRules.exceptions.contains("news.example.com") == true) == expected, !privacy.isApplying { return true }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return false
        }
        privacy.pause(host: "news.example.com", length: .hour)
        let paused = await settle(true)
        XCTAssertTrue(paused, "\(String(describing: privacy.snapshot?.scriptRules.exceptions))")
        privacy.resume(host: "news.example.com")
        let resumed = await settle(false)
        XCTAssertTrue(resumed)
    }
}
