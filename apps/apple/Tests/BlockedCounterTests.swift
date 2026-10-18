import XCTest
import WebKit
@testable import Browser_Setu

/// Whether a failed load with no resource timing really means "the content rules blocked it", checked against a real WebKit rule list.
@MainActor
final class BlockedCounterTests: XCTestCase {
    private func run(html: String, rules: String) async throws -> [String] {
        let id = "bs-counter-" + UUID().uuidString
        let list = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: id, encodedContentRuleList: rules)
        defer { Task { try? await WKContentRuleListStore.default().removeContentRuleList(forIdentifier: id) } }
        let config = WKWebViewConfiguration()
        config.userContentController.add(list!)
        config.userContentController.addUserScript(WKUserScript(source: BlockedCounter.script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 400), configuration: config)
        web.loadHTMLString(html, baseURL: URL(string: "http://127.0.0.1:18765/"))
        try await Task.sleep(for: .seconds(3))
        let result = try await web.callAsyncJavaScript(BlockedCounter.read, contentWorld: .defaultClient)
        return (result as? [String]) ?? []
    }

    func testABlockedPictureAndScriptAreCountedAndAnOrdinary404IsNot() async throws {
        let rules = #"[{"trigger":{"url-filter":"blocked-ad\\.js"},"action":{"type":"block"}},{"trigger":{"url-filter":"blocked-pic\\.png"},"action":{"type":"block"}}]"#
        let html = "<html><body><img src='/blocked-pic.png'><script src='/blocked-ad.js'></script><img src='/does-not-exist.png'></body></html>"
        let blocked = try await run(html: html, rules: rules)
        XCTAssertEqual(blocked.count, 2, "\(blocked)")
        XCTAssertTrue(blocked.contains { $0.hasSuffix("/blocked-pic.png") })
        XCTAssertTrue(blocked.contains { $0.hasSuffix("/blocked-ad.js") })
        XCTAssertFalse(blocked.contains { $0.hasSuffix("/does-not-exist.png") }, "a real 404 is not a block")
    }

    func testTheSameAddressAskedForThreeTimesIsCountedThreeTimes() async throws {
        let rules = #"[{"trigger":{"url-filter":"blocked-pic\\.png"},"action":{"type":"block"}}]"#
        let html = "<html><body><img src='/blocked-pic.png'><img src='/blocked-pic.png'><img src='/blocked-pic.png'></body></html>"
        let blocked = try await run(html: html, rules: rules)
        XCTAssertEqual(blocked.count, 3, "\(blocked)")
    }

    func testAPageWithNothingBlockedCountsZero() async throws {
        let rules = #"[{"trigger":{"url-filter":"never-matches-anything"},"action":{"type":"block"}}]"#
        let blocked = try await run(html: "<html><body><p>hello</p></body></html>", rules: rules)
        XCTAssertEqual(blocked.count, 0)
    }
}
