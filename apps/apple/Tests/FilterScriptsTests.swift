import SetuPrivacyCore
import WebKit
import XCTest
@testable import Browser_Setu

/// The page scripts that carry out scriptlets and procedural hiding, in a real web view.
@MainActor
final class FilterScriptsTests: XCTestCase {
    private func page(_ list: String, html: String, host: String, wait: Double = 1.2) async throws -> WKWebView {
        let classified = FilterClassifier.parse(Data(list.utf8), name: "T")
        let scripts = FilterScripts.make(from: classified.scripts)
        let config = WKWebViewConfiguration()
        UserScriptInstaller.addFilterScripts(scripts, to: config.userContentController)
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 600), configuration: config)
        web.loadHTMLString(html, baseURL: URL(string: "http://\(host)/"))
        try await Task.sleep(for: .seconds(wait))
        return web
    }

    private func js(_ web: WKWebView, _ code: String) async -> Any? { try? await web.callAsyncJavaScript(code, contentWorld: .page) }

    func testProceduralRulesHideOnlyWhatTheyDescribeAndOnlyOnTheirSites() async throws {
        let html = """
        <html><body>
        <div class='card' id='a'>Sponsored: buy now</div>
        <div class='card' id='b'>A real article</div>
        <div id='wrap'><span class='ad-label'>Ad</span> wrapped ad</div><div id='plain'>plain</div>
        <ul><li class='row' id='r1'>Ad row</li><li class='row' id='r2'>Good row</li></ul>
        </body></html>
        """
        let list = """
        filter-a.test##.card:has-text(Sponsored)
        filter-a.test##div:has(> .ad-label)
        filter-a.test##.row:has-text(Ad):remove()
        other-site.test##.card:has-text(real)
        """
        let web = try await page(list, html: html, host: "filter-a.test")
        let shown = await js(web, "return ['a','b','wrap','plain','r1','r2'].map(function (id) { var e = document.getElementById(id); return e ? getComputedStyle(e).display : 'removed'; }).join(',');") as? String
        XCTAssertEqual(shown, "none,block,none,block,removed,list-item", "only what the rules describe is touched, and the other site's rule is not applied")
    }

    func testProceduralHidingFollowsAPageThatAddsContentLaterWithoutScanningForever() async throws {
        let list = "later.test##.card:has-text(Sponsored)"
        let web = try await page(list, html: "<html><body><div id='box'></div></body></html>", host: "later.test", wait: 0.8)
        _ = await js(web, "document.getElementById('box').innerHTML = \"<div class='card' id='late'>Sponsored late</div>\"; await new Promise(function (r) { setTimeout(r, 900); }); return true;")
        let late = await js(web, "return getComputedStyle(document.getElementById('late')).display;") as? String
        XCTAssertEqual(late, "none", "late content is caught")
    }

    func testScriptletsRunInThePageAndOnlyOnTheirSites() async throws {
        let list = """
        scriptlet.test##+js(set-constant, adBlockDetected, false)
        scriptlet.test##+js(aopr, trackerConfig)
        scriptlet.test##+js(nostif, popupAd)
        elsewhere.test##+js(set-constant, adBlockDetected, true)
        """
        let html = """
        <html><body><script>
        window.adBlockDetected = true;
        var read = 'fine'; try { var x = window.trackerConfig; } catch (e) { read = 'aborted'; }
        window.__read = read;
        window.__timerRan = 'no'; setTimeout(function popupAd() { window.__timerRan = 'yes'; }, 10);
        window.__ok = 'yes'; setTimeout(function fine() { window.__ok2 = 'yes'; }, 10);
        </script></body></html>
        """
        let web = try await page(list, html: html, host: "scriptlet.test")
        let r = await js(web, "return [String(window.adBlockDetected), window.__read, window.__timerRan, window.__ok2 || 'none'].join(',');") as? String
        XCTAssertEqual(r, "false,aborted,no,yes", "set-constant wins over the page's own assignment, the read is aborted, the matching timer is dropped, an unrelated timer runs")
    }

    func testAListCannotSmuggleCodeThroughAScriptletOrARule() async throws {
        let list = """
        evil.test##+js(set-constant, x, false); window.__pwned = 1; //)
        evil.test##+js(set-constant, \\"); window.__pwned = 2; (\\", false)
        evil.test##.a:has-text(");window.__pwned=3;(")
        """
        let web = try await page(list, html: "<html><body><div class='a'>x</div></body></html>", host: "evil.test")
        let pwned = await js(web, "return typeof window.__pwned;") as? String
        XCTAssertEqual(pwned, "undefined", "rules are data, never code")
    }

    func testPagesWithoutRulesAreLeftAlone() async throws {
        let web = try await page("only-here.test##.x:has-text(a)\nonly-here.test##+js(set-constant, q, 1)", html: "<html><body><div class='x'>a</div><script>window.q = 5;</script></body></html>", host: "untouched.test")
        let result = await js(web, "return [getComputedStyle(document.querySelector('.x')).display, String(window.q)].join(',');") as? String
        XCTAssertEqual(result, "block,5")
    }
}
