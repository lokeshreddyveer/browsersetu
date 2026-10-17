import XCTest
import WebKit
@testable import Browser_Setu

/// Checks of everyday behaviour that a daily-use browser must get right. Each one drives real WebKit.
@MainActor
final class DailyDriverAuditTests: XCTestCase {
    private let server = "http://127.0.0.1:18765"

    private func model() -> BrowserModel {
        BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-dd-\(UUID().uuidString)", profile: "default")
    }

    private func webView(_ tab: TabController) throws -> WKWebView {
        try XCTUnwrap((tab.engine as? WebKitTab)?.webView)
    }

    private func load(_ html: String, into tab: TabController) async throws {
        let view = try webView(tab)
        view.loadHTMLString(html, baseURL: URL(string: server))
        for _ in 0..<80 where view.isLoading || view.url == nil { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(150))
    }

    func testVideoFullscreenIsEnabledOnEveryTab() async throws {
        let engine = WebKitEngine()
        XCTAssertTrue(engine.makeConfiguration(isPrivate: false, profile: "default").preferences.isElementFullscreenEnabled)
        XCTAssertTrue(engine.makeConfiguration(isPrivate: true, profile: "default").preferences.isElementFullscreenEnabled)
    }

    func testOnlyNameAndPasswordChallengesAreAnsweredByTheUser() {
        XCTAssertEqual(ChallengeAction.action(forAuthenticationMethod: NSURLAuthenticationMethodHTTPBasic), .askUser)
        XCTAssertEqual(ChallengeAction.action(forAuthenticationMethod: NSURLAuthenticationMethodHTTPDigest), .askUser)
        XCTAssertEqual(ChallengeAction.action(forAuthenticationMethod: NSURLAuthenticationMethodNTLM), .askUser)
        XCTAssertEqual(ChallengeAction.action(forAuthenticationMethod: NSURLAuthenticationMethodServerTrust), .systemDefault,
                       "a bad certificate is never overridden by the browser")
        XCTAssertEqual(ChallengeAction.action(forAuthenticationMethod: NSURLAuthenticationMethodClientCertificate), .systemDefault)
    }

    func testTextTypedIntoAFormSurvivesSwitchingTabsAndBack() async throws {
        let m = model()
        await m.start()
        let first = try XCTUnwrap(m.active)
        try await load("<html><body><input id='name' value=''></body></html>", into: first)
        let view = try webView(first)
        _ = try await view.evaluateJavaScript("document.getElementById('name').value = 'Ada Lovelace'; 1")

        let other = m.newTab()
        XCTAssertNotEqual(m.activeID, first.id)
        try await Task.sleep(for: .milliseconds(300))
        m.select(first.id)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertTrue(try webView(first) === view, "the same web view comes back, not a new one")
        let value = try await view.evaluateJavaScript("document.getElementById('name').value") as? String
        XCTAssertEqual(value, "Ada Lovelace", "what was typed is still there")
        _ = other
    }

    func testChangingLayoutAndFoldingTheToolbarNeverRebuildsTheWebView() async throws {
        let m = model()
        await m.start()
        let tab = try XCTUnwrap(m.active)
        try await load("<html><body><input id='x' value='keep me'></body></html>", into: tab)
        let view = try webView(tab)
        for preset in [LayoutPreset.sidebar, .minimal, .classic, .floating, .classic] { m.layoutPreset = preset }
        for _ in 0..<5 { m.pageScrolled(deltaY: -20) }
        m.expandChrome()
        XCTAssertTrue(try webView(tab) === view)
        let value = try await view.evaluateJavaScript("document.getElementById('x').value") as? String
        XCTAssertEqual(value, "keep me")
    }

    func testALoginCookieSurvivesQuittingAndReopeningTheBrowser() async throws {
        let root = NSTemporaryDirectory() + "bs-dd-login-\(UUID().uuidString)"
        let profile = "audit-\(UUID().uuidString.prefix(8))"
        let first = BrowserModel(engine: WebKitEngine(), root: root, profile: profile)
        await first.start()
        first.active?.load(URL(string: server + "/cookie/loginaudit")!)
        for _ in 0..<80 { if first.active?.hasLoadedPage == true, first.active?.isLoading == false { break }; try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(500))
        var seen = await first.engine.cookies(profile: profile, isPrivate: false)
        guard seen.contains(where: { $0.name == "marker" }) else {
            throw XCTSkip("the local test server is not running on 18765, so no cookie was issued")
        }
        first.tabs.forEach { $0.shutdown() }

        // A different engine and model, as after a relaunch: the cookie must come from disk.
        let second = BrowserModel(engine: WebKitEngine(), root: root, profile: profile)
        await second.start()
        seen = await second.engine.cookies(profile: profile, isPrivate: false)
        XCTAssertTrue(seen.contains { $0.name == "marker" }, "still signed in after a restart")
        await second.engine.removeProfileData(profile: profile)
    }

    func testAPrivateTabLeavesNothingInTheProfile() async throws {
        let profile = "audit-priv-\(UUID().uuidString.prefix(8))"
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-dd-priv-\(UUID().uuidString)", profile: profile)
        await m.start()
        let priv = m.openTab(url: URL(string: server + "/cookie/privateaudit"), isPrivate: true)
        for _ in 0..<80 { if priv.hasLoadedPage, !priv.isLoading { break }; try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(500))
        let inPrivate = await m.engine.cookies(profile: profile, isPrivate: true)
        guard inPrivate.contains(where: { $0.name == "marker" }) else { throw XCTSkip("the local test server is not running on 18765") }
        let inProfile = await m.engine.cookies(profile: profile, isPrivate: false)
        XCTAssertFalse(inProfile.contains { $0.name == "marker" }, "the private cookie never reaches the profile's store")
        await m.engine.removeProfileData(profile: profile)
    }
}
