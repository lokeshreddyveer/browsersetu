import WebKit
import XCTest
@testable import Browser_Setu

/// A site that changes its address without loading a new document (the History API): a script for the new address runs there only if it asked to run again.
@MainActor
final class ScriptNavigationTests: XCTestCase {
    private func run(rerun: Bool, steps: [String]) async throws -> (runs: Int, address: String) {
        var script = try XCTUnwrap(UserScriptFile.parse("// ==UserScript==\n// @name Counter\n// @match http://spa.test/pull/*\n// @noframes\n// ==/UserScript==\nwindow.__runs = (window.__runs || 0) + 1;\n(window.__paths = window.__paths || []).push(location.pathname);\ndocument.documentElement.setAttribute('data-runs', String(window.__runs));", fallbackName: "Counter"))
        script.enabled = true; script.inPageWorld = true; script.rerunOnNavigation = rerun
        let config = WKWebViewConfiguration()
        UserScriptInstaller.install([script], policy: WebPolicy(), storage: nil, filter: FilterScripts(), into: config.userContentController)
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        web.loadHTMLString("<html><body>app</body></html>", baseURL: URL(string: "http://spa.test/repo"))
        try await Task.sleep(for: .seconds(1.0))
        for step in steps {
            _ = try? await web.callAsyncJavaScript(step + "; await new Promise(function (r) { setTimeout(r, 1700); }); return true;", contentWorld: .page)
        }
        let runs = (try await web.callAsyncJavaScript("return window.__runs || 0;", contentWorld: .page) as? Int) ?? -1
        let address = (try await web.callAsyncJavaScript("return location.pathname;", contentWorld: .page) as? String) ?? ""
        let paths = (try await web.callAsyncJavaScript("return (window.__paths || []).join(',');", contentWorld: .page) as? String) ?? ""
        print("NAVIGATION RUNS at: \(paths) — ended at \(address)")
        return (runs, address)
    }

    func testAScriptThatAskedToRunAgainRunsWhenTheSiteMovesToAMatchingAddress() async throws {
        let r = try await run(rerun: true, steps: ["history.pushState({}, '', '/pull/7')"])
        XCTAssertEqual(r.address, "/pull/7")
        XCTAssertEqual(r.runs, 1, "it ran once the address matched, not before")
    }

    func testItRunsForEachNewMatchingAddressButNotTwiceForTheSameOne() async throws {
        let r = try await run(rerun: true, steps: ["history.pushState({}, '', '/pull/7')", "history.replaceState({}, '', '/pull/7')", "document.body.appendChild(document.createElement('p'))", "history.pushState({}, '', '/pull/8')", "history.pushState({}, '', '/issues/3')", "history.replaceState({}, '', '/pull/8'); window.dispatchEvent(new PopStateEvent('popstate'))"])
        XCTAssertEqual(r.runs, 3, "pull/7, pull/8, and pull/8 again after returning to it from issues/3 (a real go-back does not traverse in an unattached test view, so its popstate is sent by hand) — and none for issues/3 or for page changes at the same address")
    }

    func testAScriptThatDidNotAskRunsOnlyWhenADocumentLoadsAtAMatchingAddress() async throws {
        let r = try await run(rerun: false, steps: ["history.pushState({}, '', '/pull/7')"])
        XCTAssertEqual(r.address, "/pull/7")
        XCTAssertEqual(r.runs, 0, "unchanged behaviour: the document loaded at /repo, which does not match")
    }

    func testAnOlderSavedScriptStillLoadsAndDoesNotRunAgain() throws {
        let old = Data("""
        {"name":"Old","source":"void 0","enabled":true,"matches":["https://a.test/*"]}
        """.utf8)
        let script = try JSONDecoder().decode(UserScript.self, from: old)
        XCTAssertFalse(script.rerunOnNavigation)
        let packaged = try JSONDecoder().decode(UserScript.self, from: try JSONEncoder().encode({ var s = script; s.rerunOnNavigation = true; return s }()))
        XCTAssertTrue(packaged.rerunOnNavigation, "and the choice is saved")
    }

    func testGitHubEnhancementsAreInstalledToRunAgain() async throws {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-nav-\(UUID().uuidString)", profile: "default")
        m.wifiKeys = MemoryWiFiKeys()
        await m.start()
        let package = GitHubEnhancements.package
        let item = try XCTUnwrap(package.items.first)
        await m.installEnhancement(package: package, item: item)
        XCTAssertEqual(m.enhancementScript(package: package, item: item)?.rerunOnNavigation, true)
    }
}
