import XCTest
import WebKit
@testable import Browser_Setu

/// The page-side half of saving a password: a real web view, a real form, the real watcher script, and a check that the browser is told.
@MainActor
final class LoginWatcherTests: XCTestCase {
    private final class Catcher: NSObject, WKScriptMessageHandler {
        var messages: [[String: Any]] = []
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? [String: Any] { messages.append(body) }
        }
    }

    private func makePage(_ html: String) async throws -> (WKWebView, Catcher) {
        let catcher = Catcher()
        let config = WKWebViewConfiguration()
        config.userContentController.add(catcher, contentWorld: .defaultClient, name: "bsLogin")
        config.userContentController.addUserScript(WKUserScript(source: LoginScripts.watcher, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        web.loadHTMLString(html, baseURL: URL(string: "https://example.test"))
        for _ in 0..<100 { if !web.isLoading { break }; try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(200))
        return (web, catcher)
    }

    private func wait(_ catcher: Catcher, for kind: String) async throws -> [String: Any]? {
        for _ in 0..<60 {
            if let hit = catcher.messages.first(where: { $0["kind"] as? String == kind }) { return hit }
            try await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    func testAFormSubmitReportsTheSignIn() async throws {
        let (web, catcher) = try await makePage("""
        <html><body><form onsubmit="return false"><input id=u type=text><input id=p type=password><button id=go type=submit>Sign in</button></form></body></html>
        """)
        _ = try await web.callAsyncJavaScript("document.getElementById('u').value='me@example.com'; document.getElementById('p').value='hunter2'; document.getElementById('go').click(); return true;", contentWorld: .defaultClient)
        let hit = try await wait(catcher, for: "submit")
        XCTAssertEqual(hit?["user"] as? String, "me@example.com")
        XCTAssertEqual(hit?["password"] as? String, "hunter2")
        XCTAssertEqual(hit?["origin"] as? String, "https://example.test")
    }

    func testASignInSentWithScriptAndNoNavigationIsStillReported() async throws {
        let (web, catcher) = try await makePage("""
        <html><body><div><input id=u type=email><input id=p type=password><button id=go type=button onclick="fetch('/x').catch(()=>{})">Log in</button></div></body></html>
        """)
        _ = try await web.callAsyncJavaScript("document.getElementById('u').value='a@b.co'; document.getElementById('p').value='pw-12345'; document.getElementById('go').click(); return true;", contentWorld: .defaultClient)
        let hit = try await wait(catcher, for: "submit")
        XCTAssertEqual(hit?["user"] as? String, "a@b.co")
    }

    func testEnterInThePasswordFieldReportsIt() async throws {
        let (web, catcher) = try await makePage("<html><body><input id=u type=text><input id=p type=password></body></html>")
        _ = try await web.callAsyncJavaScript("document.getElementById('u').value='name'; const p = document.getElementById('p'); p.value='secret99'; p.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', bubbles: true})); return true;", contentWorld: .defaultClient)
        let hit = try await wait(catcher, for: "submit")
        XCTAssertEqual(hit?["password"] as? String, "secret99")
    }

    func testFocusingThePasswordFieldIsReported() async throws {
        let (web, catcher) = try await makePage("<html><body><input id=p type=password></body></html>")
        _ = try await web.callAsyncJavaScript("document.getElementById('p').focus(); return true;", contentWorld: .defaultClient)
        let hit = try await wait(catcher, for: "focus")
        XCTAssertNotNil(hit)
    }
}

/// The whole path inside the browser: a real tab, the real engine and handlers, and the question the person is asked.
@MainActor
final class LoginPromptFlowTests: XCTestCase {
    private func run(_ html: String, script: String, profile: String = "login-flow-" + UUID().uuidString) async throws -> (asked: [String], model: BrowserModel) {
        let model = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-login-\(UUID().uuidString)", profile: profile)
        await model.start()
        var asked: [String] = []
        Dialogs.testHandler = { title, _, _ in asked.append(title); return 1 }     // "Not Now"
        defer { Dialogs.testHandler = nil }
        let tab = model.openTab(url: nil, isPrivate: false)
        tab.engine.showHTML(html, baseURL: URL(string: "https://login-flow.test/"))
        try await Task.sleep(for: .seconds(2))
        tab.engine.runPageScript(script, arguments: [:])
        for _ in 0..<80 where asked.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        return (asked, model)
    }

    func testAFormSignInMakesTheBrowserAsk() async throws {
        let result = try await run("<html><body><form onsubmit=\"return false\"><input id=u type=text><input id=p type=password><button id=go type=submit>Sign in</button></form></body></html>",
                                   script: "document.getElementById('u').value='me@example.com'; document.getElementById('p').value='hunter2'; document.getElementById('go').click(); return true;")
        XCTAssertEqual(result.asked.count, 1, "the browser should ask once whether to save the password")
        XCTAssertTrue(result.asked.first?.contains("me@example.com") ?? false)
    }

    /// App Store Connect's and Google's sign-in boxes are a page from another origin inside the page: the form is in the frame.
    /// Needs scripts/testserver.py; the page inside the frame fills and submits itself.
    func testASignInInsideACrossOriginFrameMakesTheBrowserAsk() async throws {
        let model = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-frame-\(UUID().uuidString)", profile: "frame-" + UUID().uuidString)
        await model.start()
        var asked: [String] = []
        Dialogs.testHandler = { title, _, _ in asked.append(title); return 2 }
        defer { Dialogs.testHandler = nil }
        let tab = model.openTab(url: URL(string: "http://127.0.0.1:18765/login-frame"), isPrivate: false)
        _ = tab
        for _ in 0..<100 where asked.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(asked.count, 1, "a sign-in inside a frame from another site is saved too")
        XCTAssertTrue(asked.first?.contains("dev@example.com") ?? false)
    }

    /// Even when no sign-in is noticed, a typed password is offered for keeping from the page.
    func testATypedPasswordIsOfferedForKeeping() async throws {
        let model = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-typed-\(UUID().uuidString)", profile: "typed-" + UUID().uuidString)
        await model.start()
        let tab = model.openTab(url: nil, isPrivate: false)
        tab.engine.showHTML("<html><body><input id=u type=text><input id=p type=password></body></html>", baseURL: URL(string: "https://typed.test/"))
        try await Task.sleep(for: .seconds(2))
        tab.engine.runPageScript("const u = document.getElementById('u'), p = document.getElementById('p'); u.value='me@typed.test'; p.value='typed-secret'; p.dispatchEvent(new Event('input', {bubbles: true})); return true;", arguments: [:])
        for _ in 0..<60 where tab.typedLogin == nil { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(tab.typedLogin?.user, "me@typed.test")
        model.saveTypedLogin(in: tab)
        XCTAssertNil(tab.typedLogin)
        XCTAssertEqual(WebLoginVault.list(origin: "https://typed.test", profile: model.profileName).first?.password, "typed-secret", "one click keeps it")
        WebLoginVault.removeAll(profile: model.profileName)
    }

    func testAScriptSentSignInMakesTheBrowserAsk() async throws {
        let result = try await run("<html><body><div><input id=u type=email><input id=p type=password><button id=go type=button onclick=\"fetch('/x').catch(()=>{})\">Log in</button></div></body></html>",
                                   script: "document.getElementById('u').value='a@b.co'; document.getElementById('p').value='pw-12345'; document.getElementById('go').click(); return true;")
        XCTAssertEqual(result.asked.count, 1)
    }
}

/// The YouTube ad rules, run in a real web view in the page's own world, as they are installed: the ad schedule must be gone from the data the player reads.
@MainActor
final class YouTubeStripTests: XCTestCase {
    func testTheAdScheduleIsRemovedFromTheDataThePageReads() async throws {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(WKUserScript(source: YouTubeAdRules.builtIn.script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        web.loadHTMLString("<html><head><script>var ytInitialPlayerResponse = {adPlacements:[1], playerAds:[2], videoDetails:{title:'t'}};</script></head><body></body></html>", baseURL: URL(string: "https://www.youtube.com/"))
        for _ in 0..<100 { if !web.isLoading { break }; try await Task.sleep(for: .milliseconds(50)) }
        let initial = try await web.evaluateJavaScript("JSON.stringify(Object.keys(ytInitialPlayerResponse))") as? String
        XCTAssertEqual(initial, "[\"videoDetails\"]", "the inline player data loses its ad schedule")
        let parsed = try await web.evaluateJavaScript("JSON.stringify(Object.keys(JSON.parse('{\"playerResponse\":{\"adPlacements\":[1],\"keep\":1},\"adSlots\":[3],\"x\":1}').playerResponse))") as? String
        XCTAssertEqual(parsed, "[\"keep\"]", "data the page parses loses it too")
        let rest = try await web.evaluateJavaScript("JSON.stringify(Object.keys(JSON.parse('{\"adSlots\":[3],\"x\":1}')))") as? String
        XCTAssertEqual(rest, "[\"x\"]")
    }
}

/// The autoplay guard as a real tab gets it: no hand-injected script, just what the browser installs.
@MainActor
final class AutoplayInRealTabTests: XCTestCase {
    func testAPageCannotStartSoundWithoutATap() async throws {
        let model = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-ap-\(UUID().uuidString)", profile: "ap-" + UUID().uuidString)
        await model.start()
        XCTAssertTrue(model.blockAutoplay, "on by default")
        let tab = model.openTab(url: nil, isPrivate: false)
        tab.engine.showHTML("<html><body><audio id=a></audio></body></html>", baseURL: URL(string: "https://autoplay.test/"))
        try await Task.sleep(for: .seconds(2))
        guard let web = (tab.engine as? WebKitTab)?.webView else { return XCTFail("not a WebKitTab") }
        let wav = "data:audio/wav;base64,UklGRiQAAABXQVZFZm10IBAAAAABAAEAQB8AAEAfAAABAAgAZGF0YQAAAAA="
        let result = try await web.callAsyncJavaScript("""
            const a = new Audio(wav);
            const outcome = await Promise.race([a.play().then(() => 'played', e => 'refused ' + e.name), new Promise(r => setTimeout(() => r('timeout'), 800))]);
            return outcome;
            """, arguments: ["wav": wav], contentWorld: .page) as? String
        XCTAssertTrue(result?.hasPrefix("refused") ?? false, "a script's play() with no tap must be refused, got \(result ?? "nil")")
    }
}

/// The first step of a two-step sign-in asks for the name alone: the saved name is filled in, with no question when only one is saved.
@MainActor
final class UsernameStepTests: XCTestCase {
    private func page(saved: [WebLogin], html: String, focus script: String) async throws -> (value: String, asked: [String]) {
        let model = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-step-\(UUID().uuidString)", profile: "step-" + UUID().uuidString)
        defer { WebLoginVault.removeAll(profile: model.profileName) }
        await model.start()
        for login in saved { guard WebLoginVault.save(login, profile: model.profileName) else { throw XCTSkip("the Keychain is not available to this test run") } }
        var asked: [String] = []
        Dialogs.testHandler = { title, _, _ in asked.append(title); return 0 }
        defer { Dialogs.testHandler = nil }
        let tab = model.openTab(url: nil, isPrivate: false)
        tab.engine.showHTML(html, baseURL: URL(string: "https://step.test/"))
        try await Task.sleep(for: .seconds(2))
        guard let web = (tab.engine as? WebKitTab)?.webView else { XCTFail("not a WebKitTab"); return ("", asked) }
        tab.engine.runPageScript(script, arguments: [:])
        try await Task.sleep(for: .seconds(2))
        let value = try await web.callAsyncJavaScript("return document.getElementById('u').value", contentWorld: .defaultClient) as? String ?? ""
        return (value, asked)
    }

    func testTheNameIsFilledOnTheFirstStepWithNoQuestionWhenOneIsSaved() async throws {
        let result = try await page(saved: [WebLogin(origin: "https://step.test", user: "me@example.com", password: "pw")],
                                    html: "<html><body><input id=u type=text name=username autocomplete=username></body></html>",
                                    focus: "document.getElementById('u').focus(); return true;")
        XCTAssertEqual(result.value, "me@example.com")
        XCTAssertTrue(result.asked.isEmpty, "a lone saved name is filled without a question: \(result.asked)")
    }

    func testAFieldThatAlreadyHasANameIsNotFilledOver() async throws {
        let result = try await page(saved: [WebLogin(origin: "https://step.test", user: "me@example.com", password: "pw")],
                                    html: "<html><body><input id=u type=text name=username value='someone@else.test'></body></html>",
                                    focus: "document.getElementById('u').focus(); return true;")
        XCTAssertEqual(result.value, "someone@else.test")
    }

    func testASearchBoxIsNeverFilled() async throws {
        let result = try await page(saved: [WebLogin(origin: "https://step.test", user: "me@example.com", password: "pw")],
                                    html: "<html><body><input id=u type=search name=q placeholder='Search'></body></html>",
                                    focus: "document.getElementById('u').focus(); return true;")
        XCTAssertEqual(result.value, "")
    }
}
