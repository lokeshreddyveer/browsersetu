import WebKit
import XCTest
@testable import Browser_Setu

/// Genuine failures, produced by a real web view, and what the classifier makes of the error WebKit actually reports. The classifier's mapping was not guessed: where these
/// tests print what was observed, the mapping was set from it.
@MainActor
final class ErrorEvidenceTests: XCTestCase {
    private final class Probe: NSObject, WKNavigationDelegate {
        var errors: [NSError] = []
        var finished = false
        var onEvent: (() -> Void)?
        /// Schemes WebKit asked about that are not ordinary web content. A test must never hand one to the system (an unknown scheme would open a Finder dialog on the
        /// person's screen), so these are refused here, and the fact that WebKit asked first is itself the evidence.
        var refusedSchemes: [String] = []
        private var refusedPending = false
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
            if ["http", "https", "file", "about", "blob", "data", "javascript"].contains(scheme) { decisionHandler(.allow); return }
            refusedSchemes.append(scheme)
            refusedPending = true
            decisionHandler(.cancel)
            // Nothing else will arrive for a navigation that was refused before it began.
            Task { @MainActor in self.onEvent?() }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if refusedPending, (error as NSError).code == NSURLErrorCancelled { refusedPending = false; return }      // our own refusal, not a failure
            errors.append(error as NSError); onEvent?()
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { errors.append(error as NSError); onEvent?() }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true; onEvent?() }
    }

    /// Loads in a real web view and waits (up to `seconds`) for the first failure or finish.
    private var lastRefusedSchemes: [String] = []

    private func fail(_ configure: (WKWebViewConfiguration) -> Void = { _ in }, seconds: Double = 8, load: (WKWebView) -> Void) async -> NSError? {
        let config = WKWebViewConfiguration()
        configure(config)
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        let probe = Probe()
        web.navigationDelegate = probe
        load(web)
        let deadline = Date().addingTimeInterval(seconds)
        while probe.errors.isEmpty, !probe.finished, probe.refusedSchemes.isEmpty, Date() < deadline { try? await Task.sleep(for: .milliseconds(80)) }
        // A refused navigation may still report its cancellation a moment later; give that time to arrive (and be ignored) before reading the result.
        if !probe.refusedSchemes.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
        lastRefusedSchemes = probe.refusedSchemes
        withExtendedLifetime(probe) {}
        return probe.errors.first
    }

    func testAMainFrameLoadBlockedByAContentRuleIsReportedAndClassifiedAsProtection() async throws {
        let rules = #"[{"trigger":{"url-filter":"blocked\\.test"},"action":{"type":"block"}}]"#
        let list = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "error-evidence-\(UUID().uuidString)", encodedContentRuleList: rules)
        let error = await fail({ $0.userContentController.add(try! XCTUnwrap(list)) }) { $0.load(URLRequest(url: URL(string: "http://blocked.test/")!)) }
        let seen = try XCTUnwrap(error, "WebKit reported nothing for a blocked main-frame load")
        print("OBSERVED content-rule block: domain=\(seen.domain) code=\(seen.code) description=\(seen.localizedDescription)")
        XCTAssertEqual(BrowserErrorClassifier.classify(domain: seen.domain, code: seen.code, deviceOnline: true), .protectionBlocked,
                       "the error WebKit really gives for a content-blocked page (\(seen.domain) \(seen.code)) must be recognised as the protection block")
    }

    func testAMissingLocalFileIsAFileFailureNotANetworkProblem() async throws {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/page.html")
        let error = await fail { $0.loadFileURL(missing, allowingReadAccessTo: missing.deletingLastPathComponent()) }
        let seen = try XCTUnwrap(error)
        print("OBSERVED missing file: domain=\(seen.domain) code=\(seen.code)")
        let kind = BrowserErrorClassifier.classify(domain: seen.domain, code: seen.code, deviceOnline: true)
        XCTAssertEqual(kind, .fileFailure, "\(seen.domain) \(seen.code)")
    }

    func testAnAddressWithASchemeNoOneHandlesRaisesNoWebKitErrorSoThePolicyDecidesInstead() async throws {
        // Observed, not assumed: WebKit reports no failure at all for a scheme it cannot load, so there is nothing to classify here. The browser's own navigation policy
        // (NavigationPolicy) decides these before WebKit is asked, and a typed or clicked address of that kind is refused or handed to another app there.
        let error = await fail(seconds: 3) { $0.load(URLRequest(url: URL(string: "notarealscheme://example/thing")!)) }
        print("OBSERVED unknown scheme: \(String(describing: error.map { "\($0.domain) \($0.code)" })), asked the delegate about \(lastRefusedSchemes)")
        XCTAssertEqual(lastRefusedSchemes, ["notarealscheme"], "WebKit asks the embedder first, so the browser's own policy decides: it never reaches the system on its own")
        XCTAssertNil(error, "if WebKit ever starts reporting this, the classifier already maps 100 and 101 to unsupported content")
        XCTAssertEqual(BrowserErrorClassifier.classify(domain: "WebKitErrorDomain", code: 101, deviceOnline: true), .unsupportedContent)
    }

    func testAnUnresolvableNameIsReportedAsANameOrNetworkProblemNeverAsSecurityOrACrash() async throws {
        let error = await fail(seconds: 12) { $0.load(URLRequest(url: URL(string: "http://no-such-host-\(UUID().uuidString.prefix(8).lowercased()).invalid/")!)) }
        let seen = try XCTUnwrap(error)
        print("OBSERVED unresolvable host: domain=\(seen.domain) code=\(seen.code)")
        let kind = BrowserErrorClassifier.classify(domain: seen.domain, code: seen.code, deviceOnline: true)
        XCTAssertTrue([.dnsFailure, .noInternet, .serverUnavailable].contains(kind), "got \(String(describing: kind)) for \(seen.domain) \(seen.code)")
        XCTAssertNotEqual(kind, .certificate); XCTAssertNotEqual(kind, .processCrashed)
    }

    func testANavigationTheCodeCancelsIsNotAFailureToShow() async throws {
        // A page the browser itself stops (a new load replaces the old one) reports "cancelled" and must show nothing.
        let config = WKWebViewConfiguration()
        let web = WKWebView(frame: .zero, configuration: config)
        let probe = Probe()
        web.navigationDelegate = probe
        web.load(URLRequest(url: URL(string: "http://slow.invalid/")!))
        web.stopLoading()
        try await Task.sleep(for: .milliseconds(800))
        for error in probe.errors {
            print("OBSERVED after stop: domain=\(error.domain) code=\(error.code)")
            XCTAssertNil(BrowserErrorClassifier.classify(domain: error.domain, code: error.code, deviceOnline: true), "a cancelled load must show nothing (\(error.domain) \(error.code))")
        }
    }
}
