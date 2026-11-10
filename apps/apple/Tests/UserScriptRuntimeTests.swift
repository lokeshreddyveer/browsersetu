import WebKit
import XCTest
@testable import Browser_Setu

/// The userscript runtime: which pages a script matches, what its header says, what it is allowed to do (nothing, until given), and what really happens in a real web
/// view: when it runs, in which world, in which frame, in a private tab, and after a permission is taken away or the script is replaced.
@MainActor
final class UserScriptRuntimeTests: XCTestCase {
    // MARK: Matching

    func testMatchPatternsAndGlobsAreJudgedByTheWholeAddress() {
        let m = UserScriptMatcher.matches
        XCTAssertTrue(m("https://www.example.com/a/b?x=1", ["https://*.example.com/*"]))
        XCTAssertTrue(m("https://example.com/", ["https://*.example.com/*"]), "*. also covers the bare name")
        XCTAssertFalse(m("https://evilexample.com/", ["https://*.example.com/*"]))
        XCTAssertFalse(m("http://example.com/", ["https://example.com/*"]), "the scheme counts")
        XCTAssertTrue(m("http://example.com/", ["*://example.com/*"]))
        XCTAssertTrue(m("https://example.com:8443/x", ["https://example.com/*"]), "a port is allowed unless the pattern names one")
        XCTAssertFalse(m("https://example.com:8443/x", ["https://example.com:443/*"]))
        XCTAssertTrue(m("https://example.com/docs/page", ["https://example.com/docs/*"]))
        XCTAssertFalse(m("https://example.com/other", ["https://example.com/docs/*"]), "the path counts")
        XCTAssertTrue(m("https://news.test/anything", ["<all_urls>"]))
        XCTAssertFalse(m("file:///etc/passwd", ["<all_urls>"]), "only web pages")
        XCTAssertFalse(m("ftp://example.com/", ["*://example.com/*"]))
        XCTAssertTrue(m("https://example.com/search?q=cats", ["/^https:\\/\\/example\\.com\\/search\\?q=/"]), "a /regex/ is used as written")
        XCTAssertTrue(m("https://sub.example.com/x", ["example.com"]), "the older bare name: that site and its subdomains")
        XCTAssertFalse(m("https://notexample.com/x", ["example.com"]))
        XCTAssertTrue(m("https://example.com/path/file.html", ["https://example.com/path/*.html"]))
        XCTAssertNil(UserScriptMatcher.regexSource(for: "file:///*"), "other schemes are not honoured")
        XCTAssertNil(UserScriptMatcher.regexSource(for: "/(/"), "a regex that does not compile is refused")
        XCTAssertNil(UserScriptMatcher.regexSource(for: "https://bad host.com/*"))
    }

    func testAnExcludeBeatsAMatch() {
        var script = UserScript(name: "S", sites: [], source: "1")
        script.matches = ["https://*.example.com/*"]
        script.excludes = ["https://admin.example.com/*"]
        XCTAssertTrue(UserScriptMatcher.runs(script, on: "https://www.example.com/"))
        XCTAssertFalse(UserScriptMatcher.runs(script, on: "https://admin.example.com/x"))
    }

    // MARK: Header and saved form

    func testTheHeaderGivesEverythingTheSpecNames() throws {
        let text = """
        // ==UserScript==
        // @name         Tidy
        // @version      1.10.2
        // @description  Cleans things
        // @match        https://*.example.com/*
        // @exclude      https://admin.example.com/*
        // @run-at       document-start
        // @grant        GM_setValue
        // @grant        GM_xmlhttpRequest
        // @grant        GM_addStyle
        // @grant        GM_setClipboard
        // @connect      api.example.com
        // @updateURL    https://example.com/tidy.meta.js
        // @downloadURL  https://example.com/tidy.user.js
        // @noframes
        // ==/UserScript==
        run();
        """
        let script = try XCTUnwrap(UserScriptFile.parse(text, fallbackName: "x"))
        XCTAssertEqual(script.version, "1.10.2")
        XCTAssertEqual(script.matches, ["https://*.example.com/*"])
        XCTAssertEqual(script.excludes, ["https://admin.example.com/*"])
        XCTAssertTrue(script.runAtStart)
        XCTAssertEqual(script.grants, ["GM_setValue", "GM_xmlhttpRequest", "GM_addStyle", "GM_setClipboard"])
        XCTAssertEqual(script.requestedCapabilities, [.storage, .network])
        XCTAssertEqual(script.unsupportedGrants, ["GM_setClipboard"])
        XCTAssertEqual(script.connects, ["api.example.com"])
        XCTAssertEqual(script.updateURL, "https://example.com/tidy.meta.js")
        XCTAssertEqual(script.downloadURL, "https://example.com/tidy.user.js")
        XCTAssertFalse(script.allFrames, "@noframes keeps it to the main page")
        XCTAssertTrue(script.granted.isEmpty, "nothing is allowed until the person says so")
        XCTAssertFalse(script.enabled)
    }

    func testAScriptSavedByAnEarlierVersionStillLoadsAndKeepsItsMeaning() throws {
        let old = #"[{"id":"2B1B8F5A-0B5E-4C4B-9C0E-6B3A0E5F1D11","name":"Old","sites":["example.com"],"source":"1","enabled":true,"runAtStart":false,"inPageWorld":false}]"#
        let list = try JSONDecoder().decode([UserScript].self, from: Data(old.utf8))
        XCTAssertEqual(list.count, 1)
        XCTAssertTrue(list[0].enabled)
        XCTAssertEqual(list[0].patterns, ["example.com"], "the older website name stands in for patterns")
        XCTAssertTrue(UserScriptMatcher.runs(list[0], on: "https://www.example.com/x"))
        XCTAssertTrue(list[0].granted.isEmpty)
        let again = try JSONDecoder().decode([UserScript].self, from: JSONEncoder().encode(list))
        XCTAssertEqual(again, list)
    }

    func testASyntaxErrorIsFoundWithoutRunningAnything() {
        XCTAssertNil(UserScriptSyntax.firstError(in: "var a = 1;\nconsole.log(a);"))
        let problem = UserScriptSyntax.firstError(in: "var a = 1;\nvar b = ;\n")
        XCTAssertEqual(problem?.line, 2)
    }

    // MARK: Network rules

    func testScriptsCanNeverReachTheLocalNetwork() {
        for host in ["localhost", "192.168.1.5", "10.0.0.2", "172.20.1.1", "127.0.0.1", "169.254.1.1", "printer", "nas.local", "[::1]", "fd00::1", "100.64.0.1"] {
            XCTAssertTrue(UserScriptNet.isLocalHost(host), host)
            XCTAssertFalse(UserScriptNet.connectAllows(host, connects: ["*", host]), "\(host) is refused even when listed")
        }
        XCTAssertFalse(UserScriptNet.isLocalHost("example.com"))
        XCTAssertFalse(UserScriptNet.isLocalHost("8.8.8.8"))
        XCTAssertTrue(UserScriptNet.connectAllows("api.example.com", connects: ["example.com"]))
        XCTAssertFalse(UserScriptNet.connectAllows("evil.com", connects: ["example.com"]))
        XCTAssertFalse(UserScriptNet.connectAllows("example.com.evil.com", connects: ["example.com"]))
    }

    func testDownloadsAreOnlyHttpsToPublicSites() async {
        for bad in ["http://example.com/a.user.js", "https://localhost/a.user.js", "https://192.168.0.2/a.js", "file:///tmp/a.js", "not a url"] {
            do { _ = try await UserScriptNet.fetchScript(bad); XCTFail("\(bad) should be refused") } catch {}
        }
    }

    func testAnUpdateShowsWhatItAddsAndAMoreDemandingOneNeedsApprovalAgain() {
        var old = UserScriptFile.parse("// ==UserScript==\n// @name A\n// @version 1.9\n// @match https://a.test/*\n// ==/UserScript==\n1", fallbackName: "A")!
        old.granted = []
        let calm = UserScriptUpdate.make(from: "// ==UserScript==\n// @name A\n// @version 1.10\n// @match https://a.test/*\n// ==/UserScript==\n2", for: old)
        XCTAssertTrue(calm.isNewer, "1.10 is newer than 1.9")
        XCTAssertFalse(calm.needsReapproval)
        let greedy = UserScriptUpdate.make(from: "// ==UserScript==\n// @name A\n// @version 2.0\n// @match https://a.test/*\n// @match https://b.test/*\n// @grant GM_xmlhttpRequest\n// @connect b.test\n// ==/UserScript==\n3", for: old)
        XCTAssertEqual(greedy.addedPatterns, ["https://b.test/*"])
        XCTAssertEqual(greedy.addedCapabilities, [.network])
        XCTAssertEqual(greedy.addedConnects, ["b.test"])
        XCTAssertTrue(greedy.needsReapproval)
        XCTAssertFalse(UserScriptUpdate.make(from: "// ==UserScript==\n// @version 1.9\n// @match https://a.test/*\n// ==/UserScript==\n1", for: old).isNewer)
    }

    // MARK: A real web view

    private func model() async -> BrowserModel {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-us2-\(UUID().uuidString)", profile: "default")
        await m.start()
        return m
    }

    private func script(_ name: String, host: String, source: String, start: Bool = false, page: Bool = false, frames: Bool = false, grants: [String] = [], granted: [UserScriptCapability] = []) -> UserScript {
        var s = UserScript(name: name, sites: [], source: source, enabled: true, runAtStart: start, inPageWorld: page)
        s.matches = ["*://\(host)/*"]
        s.allFrames = frames
        s.grants = grants
        s.granted = granted
        return s
    }

    private func load(_ html: String, host: String, in tab: TabController, wait: Double = 1.1) async throws {
        (tab.hostView as? WKWebView)?.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        tab.engine.showHTML(html, baseURL: URL(string: "http://\(host)/"))
        try await Task.sleep(for: .seconds(wait))
    }

    private func read(_ tab: TabController, _ code: String) async -> Any? {
        guard let web = tab.hostView as? WKWebView else { return nil }
        return try? await web.callAsyncJavaScript(code, contentWorld: .page)
    }

    func testItRunsAtDocumentStartOrEndAsAsked() async throws {
        let m = await model()
        m.setUserScripts([
            script("early", host: "timing-a.test", source: "document.documentElement.setAttribute('data-early', document.readyState);", start: true),
            script("late", host: "timing-a.test", source: "document.documentElement.setAttribute('data-late', document.readyState);"),
        ])
        let tab = m.openTab(url: nil, isPrivate: false)
        try await load("<html><body>hi</body></html>", host: "timing-a.test", in: tab)
        let early = await read(tab, "return document.documentElement.getAttribute('data-early');") as? String
        let late = await read(tab, "return document.documentElement.getAttribute('data-late');") as? String
        XCTAssertEqual(early, "loading")
        XCTAssertNotEqual(late, "loading")
        XCTAssertNotNil(late)
    }

    func testItOnlyRunsWhereItMatchesAndNeverWhereExcluded() async throws {
        let m = await model()
        var s = script("s", host: "match-b.test", source: "document.documentElement.setAttribute('data-ran', '1');")
        s.excludes = ["*://match-b.test/private/*"]
        m.setUserScripts([s])
        let tab = m.openTab(url: nil, isPrivate: false)
        try await load("<html><body>x</body></html>", host: "match-b.test", in: tab)
        let here = await read(tab, "return document.documentElement.getAttribute('data-ran');") as? String
        XCTAssertEqual(here, "1")
        let other = m.openTab(url: nil, isPrivate: false)
        try await load("<html><body>x</body></html>", host: "elsewhere-b.test", in: other)
        let there = await read(other, "return document.documentElement.getAttribute('data-ran');") as? String
        XCTAssertNil(there, "another site is not touched")
    }

    func testItRunsInsideFramesOnlyWhenAskedAndJudgesEachFrameByItsOwnAddress() async throws {
        let m = await model()
        let host = "127.0.0.1:18765"
        let html = "<html><body><iframe id=f src='http://\(host)/video-matrix'></iframe></body></html>"
        let code = "document.documentElement.setAttribute('data-frame', location.pathname);"
        m.setUserScripts([script("frames", host: host, source: code, frames: true)])
        let tab = m.openTab(url: nil, isPrivate: false)
        try await load(html, host: host, in: tab, wait: 2.0)
        let inFrame = await read(tab, "return document.getElementById('f').contentDocument.documentElement.getAttribute('data-frame');") as? String
        XCTAssertEqual(inFrame, "/video-matrix")
        m.setUserScripts([script("mainOnly", host: host, source: code, frames: false)])
        let second = m.openTab(url: nil, isPrivate: false)
        try await load(html, host: host, in: second, wait: 2.0)
        let off = await read(second, "return document.getElementById('f').contentDocument.documentElement.getAttribute('data-frame');") as? String
        XCTAssertNil(off, "without 'also in frames' the frame is left alone")
    }

    func testAPrivateTabNeverRunsAScript() async throws {
        let m = await model()
        m.setUserScripts([script("s", host: "private-d.test", source: "document.documentElement.setAttribute('data-ran', '1');")])
        let tab = m.openTab(url: nil, isPrivate: true)
        try await load("<html><body>x</body></html>", host: "private-d.test", in: tab)
        let ran = await read(tab, "return document.documentElement.getAttribute('data-ran');") as? String
        XCTAssertNil(ran)
    }

    func testAPrivateWorldCannotSeeThePagesVariablesAndAPageWorldScriptCan() async throws {
        let m = await model()
        let probe = "document.documentElement.setAttribute('data-probe', typeof window.pageSecret);"
        m.setUserScripts([script("isolated", host: "world-e.test", source: probe)])
        let a = m.openTab(url: nil, isPrivate: false)
        try await load("<html><body><script>window.pageSecret = 42;</script></body></html>", host: "world-e.test", in: a)
        let isolated = await read(a, "return document.documentElement.getAttribute('data-probe');") as? String
        XCTAssertEqual(isolated, "undefined", "the page's own variables are out of reach")
        m.setUserScripts([script("page", host: "world-f.test", source: probe, page: true)])
        let b = m.openTab(url: nil, isPrivate: false)
        try await load("<html><body><script>window.pageSecret = 42;</script></body></html>", host: "world-f.test", in: b)
        let page = await read(b, "return document.documentElement.getAttribute('data-probe');") as? String
        XCTAssertEqual(page, "number", "in the page's world it sees them")
    }

    func testThePageCannotSeeAnIsolatedScriptsAbilitiesOrBridge() async throws {
        let m = await model()
        m.setUserScripts([script("s", host: "hide-g.test", source: "window.myHelper = 1; window.GM_setValue = function(){};", grants: ["GM_setValue"], granted: [.storage])])
        let tab = m.openTab(url: nil, isPrivate: false)
        try await load("<html><body>x</body></html>", host: "hide-g.test", in: tab)
        let seen = await read(tab, "return [typeof window.myHelper, typeof window.GM_setValue, typeof (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bsus)].join(',');") as? String
        XCTAssertEqual(seen, "undefined,undefined,undefined")
    }

    func testStorageIsDeniedUntilGivenAndStopsWhenTakenAway() async throws {
        let m = await model()
        let code = "GM_setValue('k', 5); document.documentElement.setAttribute('data-got', String(GM_getValue('k', 'none')));"
        // Declared but not given: nothing is kept, and the script is told no.
        var s = script("kv", host: "store-h.test", source: code, grants: ["GM_setValue", "GM_getValue"])
        m.setUserScripts([s])
        let denied = m.openTab(url: nil, isPrivate: false)
        try await load("<html><body>x</body></html>", host: "store-h.test", in: denied)
        let got1 = await read(denied, "return document.documentElement.getAttribute('data-got');") as? String
        XCTAssertEqual(got1, "none")
        XCTAssertNil(m.userScriptValues[s.id.uuidString], "nothing was written")
        let report = UserScriptDiagnostics.shared.entries[s.id]
        XCTAssertTrue(report?.denied.contains("GM_setValue") ?? false, "the refusal shows in its diagnostics")
        // Given: kept, and read back.
        s.granted = [.storage]
        m.setUserScripts([s])
        let allowed = m.openTab(url: nil, isPrivate: false)
        try await load("<html><body>x</body></html>", host: "store-h.test", in: allowed)
        let got2 = await read(allowed, "return document.documentElement.getAttribute('data-got');") as? String
        XCTAssertEqual(got2, "5")
        XCTAssertEqual(m.userScriptValues[s.id.uuidString]?["k"], "5")
        // Taken away: a page loaded afterwards cannot write.
        m.revokeCapability(.storage, from: s)
        m.userScriptValues[s.id.uuidString] = nil
        let revoked = m.openTab(url: nil, isPrivate: false)
        try await load("<html><body>x</body></html>", host: "store-h.test", in: revoked)
        XCTAssertNil(m.userScriptValues[s.id.uuidString], "after revoking, nothing is written")
        XCTAssertFalse(m.userScripts[0].granted.contains(.storage))
    }

    func testContactingWebsitesIsRefusedWithoutThePermission() async throws {
        let m = await model()
        let code = "GM_xmlhttpRequest({ url: 'https://example.com/', onload: function () { document.documentElement.setAttribute('data-net', 'loaded'); }, onerror: function (e) { document.documentElement.setAttribute('data-net', 'refused'); } });"
        let s = script("net", host: "net-i.test", source: code, grants: ["GM_xmlhttpRequest"])
        m.setUserScripts([s])
        let tab = m.openTab(url: nil, isPrivate: false)
        try await load("<html><body>x</body></html>", host: "net-i.test", in: tab)
        let result = await read(tab, "return document.documentElement.getAttribute('data-net');") as? String
        XCTAssertEqual(result, "refused")
    }

    func testAPageWorldScriptGetsNoAbilitiesAtAll() async throws {
        let m = await model()
        let s = script("page", host: "pageworld-j.test", source: "document.documentElement.setAttribute('data-api', typeof GM_setValue + ',' + typeof GM_xmlhttpRequest);", page: true,
                       grants: ["GM_setValue", "GM_xmlhttpRequest"], granted: [.storage, .network])
        m.setUserScripts([s])
        let tab = m.openTab(url: nil, isPrivate: false)
        try await load("<html><body>x</body></html>", host: "pageworld-j.test", in: tab)
        let api = await read(tab, "return document.documentElement.getAttribute('data-api');") as? String
        XCTAssertEqual(api, "undefined,undefined", "whatever it was granted, the page can see everything it holds, so it holds nothing")
    }

    func testDiagnosticsCountRunsAndErrors() async throws {
        let m = await model()
        let s = script("diag", host: "diag-k.test", source: "GM_log('hello'); throw new Error('boom');")
        m.setUserScripts([s])
        let tab = m.openTab(url: nil, isPrivate: false)
        try await load("<html><body>x</body></html>", host: "diag-k.test", in: tab)
        let e = UserScriptDiagnostics.shared.entries[s.id]
        XCTAssertEqual(e?.runs, 1)
        XCTAssertEqual(e?.errors, 1)
        XCTAssertEqual(e?.lastError, "boom")
        XCTAssertEqual(e?.log, ["hello"])
    }

    func testAReplacedScriptIsUsedByThePagesOpenedAfterwardsAndAnOpenPageKeepsWhatItHad() async throws {
        let m = await model()
        let id = UUID()
        func version(_ n: String) -> UserScript {
            var s = script("v", host: "update-l.test", source: "document.documentElement.setAttribute('data-v', '\(n)');"); s.id = id; return s
        }
        m.setUserScripts([version("one")])
        let open = m.openTab(url: nil, isPrivate: false)
        try await load("<html><body>x</body></html>", host: "update-l.test", in: open)
        m.setUserScripts([version("two")])
        let kept = await read(open, "return document.documentElement.getAttribute('data-v');") as? String
        XCTAssertEqual(kept, "one", "an open page is not changed under the reader")
        try await load("<html><body>y</body></html>", host: "update-l.test", in: open)
        let after = await read(open, "return document.documentElement.getAttribute('data-v');") as? String
        XCTAssertEqual(after, "two", "the next load uses the new version")
    }

    func testAPermissionIsOnlyGivenAfterItIsConfirmedAndDecliningGivesNothing() async {
        let m = await model()
        var s = UserScriptFile.parse("// ==UserScript==\n// @name G\n// @match https://g.test/*\n// @grant GM_setValue\n// ==/UserScript==\n1", fallbackName: "G")!
        s.granted = [.storage]
        var asked: [String] = []
        Dialogs.testHandler = { title, _, _ in asked.append(title); return 1 }
        await m.saveUserScript(s)
        XCTAssertEqual(asked.count, 1, "it was shown first")
        XCTAssertTrue(m.userScripts[0].granted.isEmpty, "declined, so nothing was given")
        Dialogs.testHandler = { _, _, _ in 0 }
        await m.saveUserScript({ var c = m.userScripts[0]; c.granted = [.storage]; return c }())
        Dialogs.testHandler = nil
        XCTAssertEqual(m.userScripts[0].granted, [.storage])
        XCTAssertFalse(m.userScripts[0].enabled, "a script is never switched on by being saved")
    }

    func testWidenedPermissionsSwitchAnEnabledScriptOffUntilConfirmed() async {
        let m = await model()
        Dialogs.testHandler = { _, _, _ in 0 }
        defer { Dialogs.testHandler = nil }
        let s = UserScriptFile.parse("// ==UserScript==\n// @name W\n// @match https://w.test/*\n// ==/UserScript==\n1", fallbackName: "W")!
        await m.saveUserScript(s)
        await m.setUserScript(m.userScripts[0], enabled: true)
        XCTAssertTrue(m.userScripts[0].enabled)
        var wider = m.userScripts[0]
        wider.matches.append("https://other.test/*")
        await m.saveUserScript(wider)
        XCTAssertFalse(m.userScripts[0].enabled, "running on another site needs a new yes")
    }

    // MARK: Security: who can reach the bridge, and what the network service refuses

    private func inWorld(_ tab: TabController, _ script: UserScript, _ code: String) async -> Any? {
        guard let web = tab.hostView as? WKWebView else { return nil }
        return try? await web.callAsyncJavaScript(code, contentWorld: .world(name: "BrowserSetuUserScript-" + script.id.uuidString))
    }

    func testNeitherThePageNorItsFramesNorAnotherScriptCanReachAScriptsBridge() async throws {
        let m = await model()
        var a = script("A", host: "bridge-m.test", source: "GM_setValue('mine', 'a');", grants: ["GM_setValue"], granted: [.storage])
        let b = script("B", host: "bridge-m.test", source: "1;")
        a.enabled = true
        m.setUserScripts([a, b])
        let tab = m.openTab(url: nil, isPrivate: false)
        try await load("<html><body><iframe id='f' srcdoc='<p>frame</p>'></iframe></body></html>", host: "bridge-m.test", in: tab, wait: 1.6)
        XCTAssertEqual(m.userScriptValues[a.id.uuidString]?["mine"], "\"a\"", "the script itself can keep a value")
        // The page, and a frame of the page, have no handler at all.
        let page = await read(tab, "return String(typeof (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bsus));") as? String
        let frame = await read(tab, "var w = document.getElementById('f').contentWindow; return String(typeof (w.webkit && w.webkit.messageHandlers && w.webkit.messageHandlers.bsus));") as? String
        XCTAssertEqual(page, "undefined")
        XCTAssertEqual(frame, "undefined")
        // Script B holds a bridge of its own, which is bound to B: whatever it posts, it cannot write A's values or take permissions it was not given.
        let steal = await inWorld(tab, b, """
            var h = window.webkit.messageHandlers.bsus;
            await h.postMessage({ op: 'set', key: 'stolen', value: '"x"', id: '\(a.id.uuidString)', scriptId: '\(a.id.uuidString)' });
            await h.postMessage({ op: 'del', key: 'mine', id: '\(a.id.uuidString)' });
            var net = await h.postMessage({ op: 'xhr', url: 'https://example.com/', method: 'GET', id: '\(a.id.uuidString)' });
            var unknown = await h.postMessage({ op: 'readKeychain' });
            var files = await h.postMessage({ op: 'readFile', path: '/etc/hosts' });
            return JSON.stringify({ net: net, unknown: unknown, files: files });
            """) as? String
        XCTAssertTrue(steal?.contains("not given permission") ?? false, "B has no network permission: \(steal ?? "nil")")
        XCTAssertNil(m.userScriptValues[a.id.uuidString]?["stolen"], "B cannot write A's store")
        XCTAssertEqual(m.userScriptValues[a.id.uuidString]?["mine"], "\"a\"", "B cannot delete A's value")
        XCTAssertNil(m.userScriptValues[b.id.uuidString], "and B has no store of its own: it was not given one")
        XCTAssertTrue(steal?.contains("\"unknown\":null") ?? false || (steal?.contains("unknown") == false), "an unknown kind of message gets nothing")
        XCTAssertFalse(steal?.contains("root:") ?? false, "there is no way to ask for a file")
    }

    func testAnOversizedWriteIsRefusedAndAReportCannotFloodTheDiagnostics() async throws {
        let m = await model()
        let a = script("A", host: "limits-n.test", source: "1;", grants: ["GM_setValue"], granted: [.storage])
        m.setUserScripts([a])
        let tab = m.openTab(url: nil, isPrivate: false)
        try await load("<html><body>x</body></html>", host: "limits-n.test", in: tab)
        _ = await inWorld(tab, a, """
            var h = window.webkit.messageHandlers.bsus;
            await h.postMessage({ op: 'set', key: 'big', value: 'x'.repeat(200000) });
            for (var i = 0; i < 400; i++) { h.postMessage({ op: 'log', text: 'line ' + i }); }
            return true;
            """)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNil(m.userScriptValues[a.id.uuidString]?["big"], "a value over the limit is refused")
        let log = UserScriptDiagnostics.shared.entries[a.id]?.log ?? []
        XCTAssertLessThanOrEqual(log.count, 50, "the log is bounded")
    }

    func testAPrivateTabHasNoBridgeAndNoScript() async throws {
        let m = await model()
        let s = script("P", host: "private-o.test", source: "document.documentElement.setAttribute('data-ran', '1');", grants: ["GM_xmlhttpRequest"], granted: [.network])
        m.setUserScripts([s])
        let priv = m.openTab(url: nil, isPrivate: true)
        try await load("<html><body>x</body></html>", host: "private-o.test", in: priv)
        let handler = await inWorld(priv, s, "return String(typeof (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bsus));") as? String
        XCTAssertEqual(handler, "undefined", "a private tab has no handler for the script's world, so nothing can be asked of the network from it")
        let ran = await read(priv, "return document.documentElement.getAttribute('data-ran');") as? String
        XCTAssertNil(ran)
        let normal = m.openTab(url: nil, isPrivate: false)
        try await load("<html><body>x</body></html>", host: "private-o.test", in: normal)
        let there = await inWorld(normal, s, "return String(typeof window.webkit.messageHandlers.bsus);") as? String
        XCTAssertEqual(there, "object", "the same script in a normal tab does have its own bridge")
    }

    func testTheNetworkServiceRefusesLocalAddressesUnlistedSitesAndWeakSchemesEvenWhenAskedToConnectToEverything() async {
        let everything = ["*"]
        for address in ["https://127.0.0.1/", "https://localhost/x", "https://192.168.1.1/", "https://[::1]/", "https://printer/", "https://router.local/", "http://example.com/", "file:///etc/hosts", "ftp://example.com/"] {
            let result = await UserScriptNet.request(method: "GET", address: address, headers: [:], body: nil, timeout: 2, connects: everything)
            XCTAssertNotNil(result["error"], "\(address) must be refused: \(result)")
        }
        let unlisted = await UserScriptNet.request(method: "GET", address: "https://example.com/", headers: [:], body: nil, timeout: 2, connects: ["other.example"])
        XCTAssertNotNil(unlisted["error"], "a site the script did not list is refused")
        let verb = await UserScriptNet.request(method: "CONNECT", address: "https://example.com/", headers: [:], body: nil, timeout: 2, connects: everything)
        XCTAssertNotNil(verb["error"])
        let big = await UserScriptNet.request(method: "POST", address: "https://example.com/", headers: [:], body: String(repeating: "x", count: 200_000), timeout: 2, connects: everything)
        XCTAssertNotNil(big["error"], "a large body is refused before anything is sent")
    }
}
