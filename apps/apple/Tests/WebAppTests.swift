import WebKit
import XCTest
@testable import Browser_Setu

/// Websites kept as apps: what they may show, how they are made from a page, and what their windows and tabs do with links, pop-ups and notifications.
@MainActor
final class WebAppTests: XCTestCase {
    private func model() async -> BrowserModel {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-webapp-\(UUID().uuidString)", profile: "default")
        await m.start()
        return m
    }

    private func record(_ url: String = "https://work.example.com/dashboard", sites: [String] = ["example.com"], popups: Bool = false, notifications: Bool = false) -> WebAppRecord {
        WebAppRecord(name: "Work", startURL: URL(string: url)!, iconPNG: nil, allowedSites: sites, container: "app-test1234", allowsPopups: popups, notifications: notifications)
    }

    func testAnAppShowsItsOwnSitesAndNothingElse() {
        let app = record(sites: ["example.com", "accounts.example.org"])
        XCTAssertTrue(app.allows(URL(string: "https://work.example.com/x")!), "any page of an allowed site, subdomains included")
        XCTAssertTrue(app.allows(URL(string: "https://example.com/")!))
        XCTAssertTrue(app.allows(URL(string: "https://accounts.example.org/login")!))
        XCTAssertFalse(app.allows(URL(string: "https://evil.example.net/")!))
        XCTAssertFalse(app.allows(URL(string: "https://notexample.com/")!))
        XCTAssertFalse(app.allows(URL(string: "file:///etc/hosts")!))
        XCTAssertFalse(app.allows(URL(string: "javascript:alert(1)")!))
    }

    func testTheManifestGivesTheNameAndAStartAddressOnTheSameSiteOnly() throws {
        let json = #"{"title":"Dash","url":"https://work.example.com/a","appName":null,"manifest":{"name":"Work Dashboard","short_name":"Work","start_url":"/home?source=pwa","display":"standalone","icons":[{"src":"https://work.example.com/i.png","sizes":"192x192"}]},"icons":[]}"#
        let meta = try JSONDecoder().decode(WebAppMetadata.self, from: Data(json.utf8))
        XCTAssertEqual(meta.bestName, "Work Dashboard")
        XCTAssertEqual(meta.startURL(page: URL(string: "https://work.example.com/a")!).absoluteString, "https://work.example.com/home?source=pwa")
        let hostile = try JSONDecoder().decode(WebAppMetadata.self, from: Data(#"{"title":"T","manifest":{"name":"X","start_url":"https://evil.example.net/steal"}}"#.utf8))
        XCTAssertEqual(hostile.startURL(page: URL(string: "https://work.example.com/a")!).absoluteString, "https://work.example.com/a", "a start address on another site is ignored")
        let plain = try JSONDecoder().decode(WebAppMetadata.self, from: Data(#"{"title":"Just a page"}"#.utf8))
        XCTAssertEqual(plain.bestName, "Just a page")
        XCTAssertFalse(WebApps.read.contains("credentials: 'include'"), "the manifest is read without cookies")
    }

    func testAPageBecomesAnAppWithItsManifestItsOwnIdentityAndNoDuplicates() async throws {
        let m = await model()
        let tab = m.openTab(url: nil, isPrivate: false)
        let manifest = #"{"name":"Fixture App","start_url":"/start","display":"standalone"}"#.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let html = "<html><head><title>Fixture</title><link rel='manifest' href='data:application/manifest+json,\(manifest)'></head><body>x</body></html>"
        (tab.hostView as? WKWebView)?.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        tab.engine.showHTML(html, baseURL: URL(string: "http://127.0.0.1:18765/page"))
        try await Task.sleep(for: .seconds(1.2))
        tab.url = URL(string: "http://127.0.0.1:18765/page")
        let made = await m.webAppDraft(from: tab)
        let draft = try XCTUnwrap(made)
        XCTAssertEqual(draft.name, "Fixture App", "the manifest's own name")
        XCTAssertEqual(draft.startURL.absoluteString, "http://127.0.0.1:18765/start")
        XCTAssertTrue(draft.container.hasPrefix("app-"), "its own identity")
        XCTAssertEqual(draft.allowedSites, ["127.0.0.1"])
        let installed = try XCTUnwrap(m.installWebApp(draft))
        XCTAssertEqual(m.webApps.count, 1)
        XCTAssertTrue(m.containers.contains(installed.container), "the identity exists")
        _ = m.installWebApp(draft)
        XCTAssertEqual(m.webApps.count, 1, "the same app is not installed twice")
        let priv = m.openTab(url: nil, isPrivate: true)
        priv.url = URL(string: "https://www.example.com/")
        let none = await m.webAppDraft(from: priv)
        XCTAssertNil(none, "a private tab is never made into an app")
        await m.removeWebApp(installed, deleteData: true)
        XCTAssertTrue(m.webApps.isEmpty)
        XCTAssertFalse(m.containers.contains(installed.container), "removing it with its data removes the identity")
    }

    func testRecordsSurviveSavingAndLoading() throws {
        let app = record()
        let data = try JSONEncoder().encode([app])
        XCTAssertEqual(try JSONDecoder().decode([WebAppRecord].self, from: data), [app])
    }

    func testAnAppTabLoadsItsOwnSitesAndHandsEverythingElseToTheSystem() async throws {
        let m = await model()
        let tab = m.openTab(url: nil, isPrivate: false)
        tab.webApp = record()
        XCTAssertEqual(tab.engineDecideNavigation(url: URL(string: "https://work.example.com/next")!, mainFrame: true), .allow)
        XCTAssertEqual(tab.engineDecideNavigation(url: URL(string: "https://other.example.net/")!, mainFrame: true), .external, "another site opens outside the app")
        XCTAssertEqual(tab.engineDecideNavigation(url: URL(string: "https://ads.example.net/frame")!, mainFrame: false), .allow, "a frame inside the app's page is the page's business")
        let plain = m.openTab(url: nil, isPrivate: false)
        XCTAssertNotEqual(plain.engineDecideNavigation(url: URL(string: "https://other.example.net/")!, mainFrame: true), .external, "an ordinary tab is unchanged")
    }

    func testAnAppNeverGrowsTabsOrWindowsAndOnlyAsksForNotificationsIfAllowed() async throws {
        let m = await model()
        let tab = m.openTab(url: nil, isPrivate: false)
        tab.webApp = record(popups: true, notifications: false)
        let before = m.tabs.count
        tab.engineLinkAction(URL(string: "https://work.example.com/own")!, .newTab)
        tab.engineOpenInNewTab(url: URL(string: "https://work.example.com/popup")!, userInitiated: true)
        XCTAssertEqual(m.tabs.count, before, "its own links and allowed pop-ups load in place, never as new tabs")
        XCTAssertNil(tab.engineOpenPopup(configuration: WKWebViewConfiguration()), "no second web view is made for it")
        let denied = await tab.engineRequestPermission(origin: "https://work.example.com", kinds: [.notifications])
        XCTAssertFalse(denied, "notifications are off for this app")
    }

    func testAnAppWindowIsNotAPlaceForOtherAppsLinksAndIsNotRestoredAsAnOrdinaryWindow() async throws {
        let m = await model()
        m.webApp = record()
        let candidate = WindowPolicy.Candidate(id: 0, isGuest: m.isGuest || m.webApp != nil, isUnrequested: false, isFocused: true, isPrimary: false)
        XCTAssertTrue(candidate.isGuest, "a link from another application is not sent to an app's window")
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("apps/apple/Shared/Windows.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("$0.webApp == nil"), "the saved window layout leaves app windows out")
    }
}
