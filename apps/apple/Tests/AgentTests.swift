import XCTest
import WebKit
@testable import Browser_Setu

// MARK: Rules for what an AI tool may do

final class AgentPolicyTests: XCTestCase {
    private func button(_ text: String, submit: Bool = false, form: Bool = false, secret: Bool = false) -> AgentPolicy.Element {
        AgentPolicy.Element(tag: "button", text: text, insideForm: form, formHasSecret: secret, isSubmit: submit)
    }

    func testLinksAskUnlessThePersonChoseOtherwise() {
        // A neutral-looking link can still log you out or unsubscribe you, so by default it asks like any other click.
        let link = AgentPolicy.Element(tag: "a", text: "Continue", href: "https://example.com/account/leave")
        if case .confirm = AgentPolicy.click(link, pageHost: "example.com") {} else { XCTFail("a link should ask by default") }
        XCTAssertEqual(AgentPolicy.click(link, pageHost: "example.com", trustLinks: true), .allow)
        // Even with that setting, a link whose words say it sends or deletes still asks.
        let risky = AgentPolicy.Element(tag: "a", text: "Delete my account", href: "https://example.com/delete")
        if case .confirm = AgentPolicy.click(risky, pageHost: "example.com", trustLinks: true) {} else { XCTFail("a delete link should always ask") }
    }

    func testHarmlessButtonsGoAheadButEverythingElseAsks() {
        XCTAssertEqual(AgentPolicy.click(button("Next"), pageHost: "example.com"), .allow)
        XCTAssertEqual(AgentPolicy.click(button("Show more"), pageHost: "example.com"), .allow)
        XCTAssertEqual(AgentPolicy.click(AgentPolicy.Element(tag: "summary", text: "Details"), pageHost: "example.com"), .allow)
        // The cases an earlier word list missed: nothing here says "buy" or "send", but each changes something.
        for label in ["Continue", "Log in", "Enable", "Yes", "OK", "Turn on", "Allow", "Go", "Save", ""] {
            if case .confirm = AgentPolicy.click(button(label), pageHost: "example.com") {} else { XCTFail("“\(label)” should ask first") }
        }
    }

    func testSubmitPayAndDeleteAlwaysAsk() {
        for label in ["Pay now", "Place order", "Send", "Delete account", "Post", "Transfer funds"] {
            if case .confirm = AgentPolicy.click(button(label), pageHost: "shop.example") {} else { XCTFail("“\(label)” should ask first") }
        }
        if case .confirm = AgentPolicy.click(button("Search", submit: true, form: true), pageHost: "example.com") {} else { XCTFail("a submit button should ask") }
        if case .confirm = AgentPolicy.click(button("Go", form: true, secret: true), pageHost: "bank.example") {} else { XCTFail("a form with a password should ask") }
    }

    func testLinksThatLeaveTheWebAreRefused() {
        let mail = AgentPolicy.Element(tag: "a", text: "Email us", href: "mailto:a@b.com")
        let script = AgentPolicy.Element(tag: "a", text: "Run", href: "javascript:alert(1)")
        if case .refuse = AgentPolicy.click(mail, pageHost: "example.com") {} else { XCTFail("mailto should be refused") }
        if case .refuse = AgentPolicy.click(script, pageHost: "example.com") {} else { XCTFail("javascript: should be refused") }
    }

    func testSecretFieldsAreNeverTypedInto() {
        let password = AgentPolicy.Element(tag: "input", type: "password", editable: true)
        let card = AgentPolicy.Element(tag: "input", type: "text", name: "cardnumber", autocomplete: "cc-number", editable: true)
        let code = AgentPolicy.Element(tag: "input", type: "text", autocomplete: "one-time-code", editable: true)
        let cvv = AgentPolicy.Element(tag: "input", type: "text", label: "CVV", editable: true)
        for field in [password, card, code, cvv] {
            if case .refuse = AgentPolicy.type(field, text: "x", pageHost: "example.com") {} else { XCTFail("secret field accepted: \(field)") }
        }
        let search = AgentPolicy.Element(tag: "input", type: "search", label: "Search", editable: true)
        XCTAssertEqual(AgentPolicy.type(search, text: "pasta", pageHost: "example.com"), .allow)
        // Any other field fires the page's own scripts (autosave, live checks), so it asks first.
        for field in [AgentPolicy.Element(tag: "input", type: "text", label: "Email", editable: true),
                      AgentPolicy.Element(tag: "textarea", label: "Message", editable: true),
                      AgentPolicy.Element(tag: "input", type: "text", label: "Search", insideForm: true, formHasSecret: true, editable: true)] {
            if case .confirm = AgentPolicy.type(field, text: "hello", pageHost: "example.com") {} else { XCTFail("typing into \(field.label) should ask") }
        }
        if case .refuse = AgentPolicy.type(AgentPolicy.Element(tag: "button", text: "Go"), text: "x", pageHost: "example.com") {} else { XCTFail("a button is not a field") }
    }

    func testWordsMatchWholeWordsOnly() {
        XCTAssertNil(AgentPolicy.containsWord("Postal code", from: ["post"]))
        XCTAssertNil(AgentPolicy.containsWord("Spinning", from: ["pin"]))
        XCTAssertEqual(AgentPolicy.containsWord("Please pay now", from: ["pay"]), "pay")
    }

    func testReturnAsksEverywhereExceptInASearchBox() {
        let inForm = AgentPolicy.Element(tag: "input", type: "text", label: "Name", insideForm: true, editable: true)
        let loose = AgentPolicy.Element(tag: "input", type: "text", label: "Title", editable: true)
        for field in [inForm, loose] {
            if case .confirm = AgentPolicy.pressEnter(field, pageHost: "example.com") {} else { XCTFail("Return in \(field.label) should ask: pages attach their own key handlers") }
        }
        let search = AgentPolicy.Element(tag: "input", type: "search", label: "Search", editable: true)
        XCTAssertEqual(AgentPolicy.pressEnter(search, pageHost: "example.com"), .allow)
    }

    func testPermissionBelongsToTheExactOrigin() {
        let secure = AgentPolicy.origin(of: URL(string: "https://Example.com/a?b=c"))
        XCTAssertEqual(secure, "https://example.com:443")
        XCTAssertNotEqual(secure, AgentPolicy.origin(of: URL(string: "http://example.com/")))
        XCTAssertNotEqual(secure, AgentPolicy.origin(of: URL(string: "https://example.com:8443/")))
        XCTAssertNotEqual(secure, AgentPolicy.origin(of: URL(string: "https://evil.example.com/")))
        XCTAssertNil(AgentPolicy.origin(of: URL(string: "file:///etc/passwd")))
        XCTAssertNil(AgentPolicy.origin(of: nil))
    }

    func testOnlyPlainWebAddressesOpen() {
        XCTAssertNotNil(AgentPolicy.openable("https://example.com/x"))
        XCTAssertNotNil(AgentPolicy.openable(" http://example.com "))
        for bad in ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,hi", "ftp://x.com", "https://user:pw@example.com", "example.com", ""] {
            XCTAssertNil(AgentPolicy.openable(bad), bad)
        }
    }

    func testCardAndSocialSecurityNumbersAreHiddenFromPageText() {
        let text = "Card 4111 1111 1111 1111 and 4111-1111-1111-1111, ssn 123-45-6789, order 1234567890123 and phone 555-1234."
        // More formats of the same things.
        let more = AgentPolicy.redact("SSN 123 45 6789; Social Security number: 987654321; IBAN GB82 WEST 1234 5698 7654 32; plain 123456789 stays.")
        XCTAssertFalse(more.contains("123 45 6789"))
        XCTAssertFalse(more.contains("987654321"))
        XCTAssertFalse(more.contains("WEST 1234"))
        XCTAssertTrue(more.contains("plain 123456789 stays"), "a bare nine-digit number with no SSN words around it is not guessed at")
        // What is not recognised is not hidden, and the documentation says so.
        let kept = AgentPolicy.redact("Write to jane.doe@example.com, born 4 May 1980, passport X1234567, customer 5551234.")
        XCTAssertTrue(kept.contains("jane.doe@example.com"))
        XCTAssertTrue(kept.contains("4 May 1980"))
        XCTAssertTrue(AgentPolicy.iban("GB82 WEST 1234 5698 7654 32"))
        XCTAssertFalse(AgentPolicy.iban("GB82 WEST 1234 5698 7654 33"))
        let safe = AgentPolicy.redact(text)
        XCTAssertFalse(safe.contains("4111"))
        XCTAssertFalse(safe.contains("123-45-6789"))
        XCTAssertTrue(safe.contains("[hidden card number]"))
        // A long number that is not a card number (fails the check) and a short phone number are left alone.
        XCTAssertTrue(safe.contains("1234567890123"))
        XCTAssertTrue(safe.contains("555-1234"))
        XCTAssertTrue(AgentPolicy.luhn("4111111111111111"))
        XCTAssertFalse(AgentPolicy.luhn("4111111111111112"))
    }

    func testInvisibleCharactersAreRemovedAndTextIsCut() {
        let tricky = "Hello\u{200B}\u{202E} world\u{0007}"
        XCTAssertEqual(AgentPolicy.prepare(pageText: tricky), "Hello world")
        let long = String(repeating: "a", count: 100)
        XCTAssertTrue(AgentPolicy.prepare(pageText: long, limit: 10).hasSuffix("[Page text cut off here.]"))
    }
}

// MARK: The local connection

final class AgentHTTPTests: XCTestCase {
    private func raw(_ lines: [String], body: String = "") -> Data { Data((lines.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8) }
    private let token = "secret-token-secret-token-secret-token"

    private func request(host: String = "127.0.0.1:47615", extra: [String] = [], method: String = "POST", path: String = "/mcp", auth: String? = nil) -> AgentHTTP.Request {
        var lines = ["\(method) \(path) HTTP/1.1", "Host: \(host)", "Content-Length: 2"] + extra
        if let auth { lines.append("Authorization: \(auth)") }
        guard case .request(let r) = AgentHTTP.parse(raw(lines, body: "{}")) else { fatalError("did not parse") }
        return r
    }

    func testParsesAWholeRequestAndWaitsForTheRest() {
        let head = ["POST /mcp HTTP/1.1", "Host: 127.0.0.1:1", "Content-Length: 5"]
        XCTAssertEqual(AgentHTTP.parse(Data("POST /mcp HTTP/1.1\r\nHost: x".utf8)), .needMore)
        XCTAssertEqual(AgentHTTP.parse(raw(head, body: "ab")), .needMore)
        guard case .request(let r) = AgentHTTP.parse(raw(head, body: "abcde")) else { return XCTFail("not parsed") }
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.path, "/mcp")
        XCTAssertEqual(String(data: r.body, encoding: .utf8), "abcde")
        XCTAssertEqual(r.headers["host"], "127.0.0.1:1")
    }

    func testRefusesOversizedChunkedAndMalformedRequests() {
        if case .bad = AgentHTTP.parse(raw(["POST / HTTP/1.1", "Content-Length: 99999999"])) {} else { XCTFail("huge body accepted") }
        if case .bad = AgentHTTP.parse(raw(["POST / HTTP/1.1", "Transfer-Encoding: chunked"])) {} else { XCTFail("chunked accepted") }
        if case .bad = AgentHTTP.parse(raw(["NONSENSE"])) {} else { XCTFail("bad request line accepted") }
        if case .bad = AgentHTTP.parse(Data(repeating: 65, count: AgentHTTP.maxHeader + 10)) {} else { XCTFail("endless header accepted") }
    }

    func testAuthorization() {
        let good = request(auth: "Bearer \(token)")
        XCTAssertEqual(AgentHTTP.authorize(good, token: token, port: 47615), .ok)
        XCTAssertEqual(AgentHTTP.authorize(request(host: "localhost:47615", auth: "Bearer \(token)"), token: token, port: 47615), .ok)
        // Wrong or missing token.
        XCTAssertEqual(AgentHTTP.authorize(request(auth: "Bearer nope"), token: token, port: 47615), .reject(status: 401, reason: "Missing or wrong token"))
        XCTAssertEqual(AgentHTTP.authorize(request(), token: token, port: 47615), .reject(status: 401, reason: "Missing or wrong token"))
        // A web page reaching the port by another name, or sending an Origin, is turned away even with the right token.
        XCTAssertEqual(AgentHTTP.authorize(request(host: "evil.example:47615", auth: "Bearer \(token)"), token: token, port: 47615), .reject(status: 403, reason: "Wrong host"))
        XCTAssertEqual(AgentHTTP.authorize(request(host: "127.0.0.1:9999", auth: "Bearer \(token)"), token: token, port: 47615), .reject(status: 403, reason: "Wrong host"))
        XCTAssertEqual(AgentHTTP.authorize(request(extra: ["Origin: https://evil.example"], auth: "Bearer \(token)"), token: token, port: 47615),
                       .reject(status: 403, reason: "Requests from web pages are not accepted"))
        // Only POST to /mcp.
        XCTAssertEqual(AgentHTTP.authorize(request(method: "GET", auth: "Bearer \(token)"), token: token, port: 47615), .reject(status: 405, reason: "Use POST"))
        XCTAssertEqual(AgentHTTP.authorize(request(path: "/other", auth: "Bearer \(token)"), token: token, port: 47615), .reject(status: 404, reason: "Not found"))
    }

    func testTokensAreLongAndDifferent() {
        let a = AgentHTTP.makeToken(), b = AgentHTTP.makeToken()
        XCTAssertEqual(a.count, 64)
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(AgentHTTP.constantTimeEqual(a, a))
        XCTAssertFalse(AgentHTTP.constantTimeEqual(a, b))
        XCTAssertFalse(AgentHTTP.constantTimeEqual("abc", "abcd"))
    }
}

// MARK: The protocol

@MainActor
final class AgentMCPTests: XCTestCase {
    final class FakeHost: AgentHost {
        var calls: [(String, [String: Any])] = []
        func runTool(_ name: String, arguments: [String: Any]) async -> AgentToolResult {
            calls.append((name, arguments))
            return AgentToolResult(text: "ran \(name)", isError: name == "fail")
        }
    }

    private func send(_ json: String, _ host: AgentHost) async -> [String: Any]? {
        guard let data = await AgentMCP.handle(Data(json.utf8), host: host) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func testInitializeAgreesOnAVersion() async throws {
        let host = FakeHost()
        let sent178 = await send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#, host)
        let reply = try XCTUnwrap(sent178)
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-03-26")
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])
        let sent183 = await send(#"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2099-01-01"}}"#, host)
        let newer = try XCTUnwrap(sent183)
        XCTAssertEqual((newer["result"] as? [String: Any])?["protocolVersion"] as? String, AgentMCP.supportedVersions[0])
    }

    func testNotificationsGetNoReply() async {
        let reply = await send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, FakeHost())
        XCTAssertNil(reply)
    }

    func testToolListNamesEveryToolWithASchema() async throws {
        let sent194 = await send(#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#, FakeHost())
        let reply = try XCTUnwrap(sent194)
        let tools = try XCTUnwrap((reply["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }),
                       ["list_tabs", "open_url", "read_page", "click", "type_text", "scroll", "go_back", "close_tab"])
        XCTAssertTrue(tools.allSatisfy { $0["inputSchema"] != nil && ($0["description"] as? String)?.isEmpty == false })
    }

    func testToolCallsReachTheHostAndUnknownOnesDoNot() async throws {
        let host = FakeHost()
        let sent204 = await send(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"list_tabs","arguments":{}}}"#, host)
        let ok = try XCTUnwrap(sent204)
        let content = try XCTUnwrap((ok["result"] as? [String: Any])?["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "ran list_tabs")
        XCTAssertEqual(host.calls.count, 1)
        let sent209 = await send(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"delete_everything"}}"#, host)
        let unknown = try XCTUnwrap(sent209)
        XCTAssertNotNil(unknown["error"])
        XCTAssertEqual(host.calls.count, 1, "an unknown tool must never reach the browser")
    }

    func testArgumentsAreCheckedAgainstTheSchemaBeforeTheBrowserSeesThem() async throws {
        let host = FakeHost()
        let bad = [
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"scroll","arguments":{"tab_id":1,"direction":"sideways"}}}"#,   // not in the enum
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"click","arguments":{"tab_id":1}}}"#,                           // missing element
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"click","arguments":{"tab_id":1,"elemnt":2}}}"#,                // misspelt, unknown
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"click","arguments":{"tab_id":true,"element":2}}}"#,            // a boolean is not a number
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"click","arguments":{"tab_id":"1","element":2}}}"#,             // a string is not a number
            #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"click","arguments":{"tab_id":1.5,"element":2}}}"#,             // not whole
            #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"type_text","arguments":{"tab_id":1,"element":2,"text":"x","press_enter":"yes"}}}"#,
            #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"open_url","arguments":{"url":7}}}"#,
        ]
        for message in bad {
            let raw = await send(message, host)
            let reply = try XCTUnwrap(raw)
            XCTAssertNotNil(reply["error"], message)
        }
        XCTAssertEqual(host.calls.count, 0, "nothing invalid may reach the browser")
        let good = await send(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"type_text","arguments":{"tab_id":1,"element":2,"text":"x","press_enter":false}}}"#, host)
        XCTAssertNil(try XCTUnwrap(good)["error"])
        XCTAssertEqual(host.calls.count, 1)
    }

    func testBadMessages() async throws {
        let host = FakeHost()
        let raw1 = await send("not json", host)
        let reply217 = try XCTUnwrap(raw1)
        XCTAssertNotNil(reply217["error"])
        let raw2 = await send(#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#, host)
        let reply219 = try XCTUnwrap(raw2)
        XCTAssertNotNil(reply219["error"])
        let raw3 = await send(#"{"jsonrpc":"1.0","id":1,"method":"ping"}"#, host)
        let reply221 = try XCTUnwrap(raw3)
        XCTAssertNotNil(reply221["error"])
        let raw4 = await send(#"{"jsonrpc":"2.0","id":1,"method":"made/up"}"#, host)
        let reply223 = try XCTUnwrap(raw4)
        XCTAssertNotNil(reply223["error"])
        let raw5 = await send(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, host)
        let reply225 = try XCTUnwrap(raw5)
        XCTAssertNil(reply225["error"])
    }
}

// MARK: Regressions found in review

final class AgentReviewRegressionTests: XCTestCase {
    func testAddressesLoseTheirQueryFragmentAndTokenLikePieces() {
        XCTAssertEqual(AgentPolicy.safeURL("https://Example.com/path/to?code=abc123&token=xyz#frag"), "https://example.com/path/to")
        XCTAssertEqual(AgentPolicy.safeURL("https://x.com/reset/ab12cd34ef56gh78ij90kl12"), "https://x.com/reset/…")
        XCTAssertEqual(AgentPolicy.safeURL("https://x.com/orders/20261020123456"), "https://x.com/orders/…")
        XCTAssertEqual(AgentPolicy.safeURL("https://user:pw@x.com/a"), "https://x.com/a")
        XCTAssertEqual(AgentPolicy.safeURL("https://x.com:8443/a"), "https://x.com:8443/a")
        XCTAssertEqual(AgentPolicy.safeURL("https://x.com"), "https://x.com")
        XCTAssertEqual(AgentPolicy.safeURL("mailto:a@b.com"), "")
        XCTAssertEqual(AgentPolicy.safeURL("not a url"), "")
        for leaked in ["code=", "token", "frag", "pw"] { XCTAssertFalse(AgentPolicy.safeURL("https://user:pw@x.com/a?code=1&token=2#frag").contains(leaked)) }
    }

    func testAnEmptyTokenNeverMatches() {
        guard case .request(let r) = AgentHTTP.parse(Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:47615\r\nAuthorization: Bearer \r\nContent-Length: 0\r\n\r\n".utf8)) else { return XCTFail("not parsed") }
        XCTAssertEqual(AgentHTTP.authorize(r, token: "", port: 47615), .reject(status: 401, reason: "Missing or wrong token"))
    }

    /// Runs the real page-reading script of the AI tools against a page that has things typed into it.
    @MainActor
    func testReadingAPageNeverReturnsWhatIsTypedIntoFields() async throws {
        let html = """
        <html><body>
        <form action="/go">
          <input type="password" value="hunter2-secret" placeholder="Password">
          <input type="text" name="user" value="alice@example.com" placeholder="Email address">
          <input type="text" autocomplete="one-time-code" value="918273" placeholder="Code">
          <input type="text" autocomplete="cc-number" value="4111 1111 1111 1111" placeholder="Card">
          <textarea placeholder="Notes">my private draft</textarea>
          <select><option>chosen-secret-option</option></select>
          <input type="submit" value="Save changes">
          <button type="button">Next</button>
        </form>
        <a href="https://example.com/page">A link</a>
        <p>Visible text</p>
        </body></html>
        """
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 900))
        let loader = PageLoader()
        web.navigationDelegate = loader
        try await loader.load(html, in: web)
        let result = try await web.callAsyncJavaScript(WebKitTab.agentSnapshotScript, contentWorld: .defaultClient) as? [String: Any]
        let snapshot = try XCTUnwrap(result)
        let elements = try XCTUnwrap(snapshot["elements"] as? [[String: Any]])
        let everything = String(data: try JSONSerialization.data(withJSONObject: elements), encoding: .utf8) ?? ""
        for secret in ["hunter2-secret", "alice@example.com", "918273", "4111", "my private draft", "chosen-secret-option"] {
            XCTAssertFalse(everything.contains(secret), "the snapshot leaked “\(secret)”")
        }
        // The labels and buttons are still described.
        XCTAssertTrue(everything.contains("Email address"))
        XCTAssertTrue(everything.contains("Save changes"))
        XCTAssertTrue(everything.contains("Next"))
        let pageText = (snapshot["text"] as? String) ?? ""
        XCTAssertTrue(pageText.contains("Visible text"))
        XCTAssertFalse(pageText.contains("hunter2"))
        XCTAssertFalse(pageText.contains("alice@example.com"))
        // And the fields are recognised as fields the policy refuses.
        let fields = elements.filter { ($0["editable"] as? Bool) == true }
        XCTAssertGreaterThanOrEqual(fields.count, 4)
        XCTAssertTrue(fields.contains { ($0["type"] as? String) == "password" })
    }
}

@MainActor
private final class PageLoader: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    func load(_ html: String, in web: WKWebView) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            continuation = c
            web.loadHTMLString(html, baseURL: URL(string: "https://example.com/"))
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { continuation?.resume(); continuation = nil }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { continuation?.resume(throwing: error); continuation = nil }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { continuation?.resume(throwing: error); continuation = nil }
}
