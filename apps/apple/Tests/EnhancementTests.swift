import WebKit
import XCTest
@testable import Browser_Setu

/// Website enhancement packages: data that stays on its website, installs as an ordinary off-by-default script, and is switched off by itself if it keeps failing.
@MainActor
final class EnhancementTests: XCTestCase {
    private func model() async -> BrowserModel {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-enh-\(UUID().uuidString)", profile: "default")
        await m.start()
        return m
    }

    func testTheBundledPackageIsValidAndEveryScriptInItIsOnGitHub() {
        let package = GitHubEnhancements.package
        XCTAssertEqual(Enhancements.validate(package), [], "no problems")
        XCTAssertEqual(Enhancements.bundled.map(\.id), ["github"])
        for item in package.items {
            XCTAssertNil(UserScriptSyntax.firstError(in: item.source), "\(item.id) has no syntax error")
            for pattern in item.matches + item.excludes { XCTAssertTrue(Enhancements.pattern(pattern, staysOn: "github.com"), pattern) }
        }
        let network = package.items.filter { !$0.grants.isEmpty }
        XCTAssertEqual(network.map(\.id), ["repo-summary"], "only one asks for anything")
        XCTAssertEqual(network.first?.connects, ["api.github.com"])
    }

    func testAPackageCannotReachBeyondItsWebsiteOrAskForTooMuch() {
        func make(_ edit: (inout EnhancementItem) -> Void) -> [String] {
            var item = EnhancementItem(id: "x", name: "X", summary: "", matches: ["https://github.com/*"], source: "1;")
            edit(&item)
            return Enhancements.validate(EnhancementPackage(id: "github", name: "G", domain: "github.com", version: 1, summary: "", items: [item]))
        }
        XCTAssertEqual(make { _ in }, [])
        XCTAssertFalse(make { $0.matches = ["https://evil.example/*"] }.isEmpty, "another website")
        XCTAssertFalse(make { $0.matches = ["https://notgithub.com/*"] }.isEmpty, "a website that only ends the same way")
        XCTAssertFalse(make { $0.matches = ["*://*/*"] }.isEmpty, "every website")
        XCTAssertFalse(make { $0.matches = ["<all_urls>"] }.isEmpty)
        XCTAssertFalse(make { $0.matches = ["/^https:\\/\\/.*\\.example\\.org\\//"] }.isEmpty, "a pattern that names another website")
        XCTAssertFalse(make { $0.excludes = ["https://evil.example/*"] }.isEmpty)
        XCTAssertFalse(make { $0.grants = ["GM_setClipboard"] }.isEmpty, "an ability packages cannot have")
        XCTAssertFalse(make { $0.connects = ["*"] }.isEmpty)
        XCTAssertFalse(make { $0.connects = ["192.168.1.2"] }.isEmpty, "never the home network")
        XCTAssertFalse(make { $0.source = "var a = ;" }.isEmpty, "code with a mistake")
        XCTAssertFalse(make { $0.source = String(repeating: "x", count: 40_000) }.isEmpty, "too long")
        XCTAssertFalse(make { $0.id = "Bad Name" }.isEmpty)
        XCTAssertTrue(Enhancements.pattern("https://gist.github.com/*", staysOn: "github.com"), "a subdomain is still the website")
        XCTAssertNil(Enhancements.parse(Data("not json".utf8)))
    }

    func testInstallingAddsAnOrdinaryScriptThatIsOffAndHasBeenGivenNothing() async throws {
        let m = await model()
        let package = GitHubEnhancements.package
        let item = try XCTUnwrap(package.items.first { $0.id == "repo-summary" })
        await m.installEnhancement(package: package, item: item)
        let script = try XCTUnwrap(m.enhancementScript(package: package, item: item))
        XCTAssertFalse(script.enabled)
        XCTAssertTrue(script.granted.isEmpty, "no permission until it is confirmed")
        XCTAssertEqual(script.requestedCapabilities, [.network])
        XCTAssertEqual(script.connects, ["api.github.com"])
        XCTAssertEqual(script.package, "github")
        XCTAssertTrue(m.effectiveUserScripts.filter { $0.package == "github" }.isEmpty, "nothing is handed to a page while it is off")
        await m.installEnhancement(package: package, item: item)
        XCTAssertEqual(m.userScripts.filter { $0.package == "github" }.count, 1, "not twice")
        var asked = 0
        Dialogs.testHandler = { _, _, _ in asked += 1; return 0 }
        defer { Dialogs.testHandler = nil }
        await m.setUserScript(script, enabled: true)
        XCTAssertEqual(asked, 1, "turning it on is confirmed like any script")
        XCTAssertTrue(m.userScripts[0].enabled)
        XCTAssertTrue(m.userScripts[0].granted.isEmpty, "and the network permission is still a separate yes")
        await m.removeEnhancement(package: package, item: item)
        XCTAssertTrue(m.userScripts.isEmpty)
    }

    func testAnEnhancementThatKeepsFailingIsSwitchedOffByItselfButAnOrdinaryScriptIsNot() async throws {
        let m = await model()
        Dialogs.testHandler = { _, _, _ in 0 }
        defer { Dialogs.testHandler = nil }
        let package = GitHubEnhancements.package
        let item = try XCTUnwrap(package.items.first { $0.id == "file-jump" })
        await m.installEnhancement(package: package, item: item)
        await m.setUserScript(try XCTUnwrap(m.enhancementScript(package: package, item: item)), enabled: true)
        var mine = UserScript(name: "Mine", sites: ["example.com"], source: "1;")
        await m.saveUserScript(mine)
        mine = m.userScripts.first { $0.name == "Mine" }!
        await m.setUserScript(mine, enabled: true)
        UserScriptDiagnostics.shared.onRepeatedFailure = { [weak m] id in m?.autoDisableFailingEnhancement(id) }
        let enhancement = try XCTUnwrap(m.enhancementScript(package: package, item: item))
        for _ in 0..<2 { UserScriptDiagnostics.shared.failed(enhancement.id, "the list of changed files was not found") }
        XCTAssertTrue(m.enhancementScript(package: package, item: item)?.enabled == true, "two failures are not enough")
        UserScriptDiagnostics.shared.failed(enhancement.id, "the list of changed files was not found")
        let after = try XCTUnwrap(m.enhancementScript(package: package, item: item))
        XCTAssertFalse(after.enabled, "three failures switch it off")
        XCTAssertTrue(after.autoDisabledReason.contains("failed 3 times"), after.autoDisabledReason)
        for _ in 0..<5 { UserScriptDiagnostics.shared.failed(mine.id, "boom") }
        XCTAssertTrue(m.userScripts.first { $0.name == "Mine" }?.enabled == true, "a script the person wrote is left to them")
        // Turning it on again is a fresh start.
        await m.setUserScript(after, enabled: true)
        XCTAssertTrue(m.enhancementScript(package: package, item: item)?.enabled == true)
        XCTAssertEqual(m.enhancementScript(package: package, item: item)?.autoDisabledReason, "")
    }

    // MARK: On a real page

    private func page(_ item: String, html: String, address: String, granted: [UserScriptCapability] = []) async throws -> (BrowserModel, WKWebView) {
        let m = await model()
        let package = GitHubEnhancements.package
        let found = try XCTUnwrap(package.items.first { $0.id == item })
        var script = UserScript(name: found.name, sites: ["github.com"], source: found.source, enabled: true, runAtStart: found.runAtStart)
        script.matches = found.matches; script.excludes = found.excludes; script.grants = found.grants; script.connects = found.connects; script.granted = granted; script.package = "github"; script.packageItem = item
        m.setUserScripts([script])
        let tab = m.openTab(url: nil, isPrivate: false)
        (tab.hostView as? WKWebView)?.frame = CGRect(x: 0, y: 0, width: 700, height: 500)
        tab.engine.showHTML(html, baseURL: URL(string: address))
        try await Task.sleep(for: .seconds(1.4))
        return (m, try XCTUnwrap(tab.hostView as? WKWebView))
    }

    func testTheWideReviewStyleAppliesOnlyOnTheFilesPage() async throws {
        let html = "<html><head><style>.container-xl { max-width: 600px; }</style></head><body><div class='container-xl' id='c'>x</div></body></html>"
        let (_, files) = try await page("wide-review", html: html, address: "https://github.com/octo/repo/pull/7/files")
        let wide = try? await files.callAsyncJavaScript("return getComputedStyle(document.getElementById('c')).maxWidth;", contentWorld: .page) as? String
        XCTAssertEqual(wide, "none")
        let (_, other) = try await page("wide-review", html: html, address: "https://github.com/octo/repo/issues")
        let normal = try? await other.callAsyncJavaScript("return getComputedStyle(document.getElementById('c')).maxWidth;", contentWorld: .page) as? String
        XCTAssertEqual(normal, "600px", "it does nothing on pages it was not made for")
    }

    func testFileJumpMovesBetweenFilesAndAMissingListIsAFailureThatIsCounted() async throws {
        var rows = ""
        for i in 0..<4 { rows += "<div class='file' data-tagsearch-path='f\(i)' style='height:600px'>file \(i)</div>" }
        let (_, web) = try await page("file-jump", html: "<html><body>\(rows)</body></html>", address: "https://github.com/octo/repo/pull/7/files")
        _ = try? await web.callAsyncJavaScript("document.dispatchEvent(new KeyboardEvent('keydown', { key: ']' })); await new Promise(function (r) { setTimeout(r, 300); }); return true;", contentWorld: .page)
        let y = (try? await web.callAsyncJavaScript("return window.scrollY;", contentWorld: .page)) as? Double ?? 0
        XCTAssertGreaterThan(y, 100, "] went to a later file")
        // Typing in a field is left alone.
        let (m2, empty) = try await page("file-jump", html: "<html><body><p>no files here</p></body></html>", address: "https://github.com/octo/repo/pull/8/files")
        let before = UserScriptDiagnostics.shared.entries[m2.userScripts[0].id]?.errors ?? 0
        _ = try? await empty.callAsyncJavaScript("document.dispatchEvent(new KeyboardEvent('keydown', { key: ']' })); await new Promise(function (r) { setTimeout(r, 300); }); return true;", contentWorld: .page)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertGreaterThan(UserScriptDiagnostics.shared.entries[m2.userScripts[0].id]?.errors ?? 0, before, "a layout the script does not recognise counts as a failure")
    }

    func testTheRepositorySummaryDoesNothingWithoutThePermissionAndNothingFailsForIt() async throws {
        let (m, web) = try await page("repo-summary", html: "<html><body>repo</body></html>", address: "https://github.com/octo/repo")
        let note = (try? await web.callAsyncJavaScript("return document.querySelectorAll('div[style*=\"fixed\"]').length;", contentWorld: .page)) as? Int
        XCTAssertEqual(note, 0, "no permission, nothing asked of api.github.com, nothing drawn")
        let entry = UserScriptDiagnostics.shared.entries[m.userScripts[0].id]
        XCTAssertTrue(entry?.denied.contains("GM_xmlhttpRequest") ?? false, "the refusal is in its diagnostics")
        XCTAssertEqual(entry?.errors ?? 0, 0, "a refusal is not a failure")
    }
}
