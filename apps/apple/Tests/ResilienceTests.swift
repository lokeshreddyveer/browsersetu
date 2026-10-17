import XCTest
@testable import Browser_Setu

final class NetworkProblemTests: XCTestCase {
    func testFailuresAreNamedInPlainWords() {
        XCTAssertEqual(NetworkProblem(description: "The Internet connection appears to be offline."), .offline)
        XCTAssertEqual(NetworkProblem(description: "The request timed out."), .timedOut)
        XCTAssertEqual(NetworkProblem(description: "A server with the specified hostname could not be found."), .siteNotFound)
        XCTAssertEqual(NetworkProblem(description: "Could not connect to the server."), .cannotConnect)
        XCTAssertEqual(NetworkProblem(description: "The network connection was lost."), .connectionLost)
        XCTAssertEqual(NetworkProblem(description: "The certificate for this server is invalid."), .certificate)
        XCTAssertEqual(NetworkProblem(description: "Something unexpected"), .other)
    }

    func testOnlyConnectionProblemsRetryByThemselves() {
        XCTAssertTrue(NetworkProblem.offline.retriesAutomatically)
        XCTAssertTrue(NetworkProblem.connectionLost.retriesAutomatically)
        XCTAssertFalse(NetworkProblem.certificate.retriesAutomatically, "an untrusted site must never be tried again on its own")
        XCTAssertFalse(NetworkProblem.siteNotFound.retriesAutomatically)
    }

    func testEveryProblemHasAdviceAndATitle() {
        for p in [NetworkProblem.offline, .timedOut, .siteNotFound, .cannotConnect, .connectionLost, .certificate, .blocked, .other] {
            XCTAssertFalse(p.title.isEmpty); XCTAssertFalse(p.advice.isEmpty)
        }
    }
}

@MainActor
final class PermissionExpiryTests: XCTestCase {
    private func model() -> BrowserModel {
        BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-perm-\(UUID().uuidString)", profile: "default")
    }

    /// "Ask" is stored as no entry at all, so a missing one reads as .prompt.
    private func decision(_ m: BrowserModel, _ origin: String, _ kind: PermissionType) -> Decision {
        (try? m.core.listPermissions())?.first { $0.origin == origin && $0.kind == kind }?.decision ?? .prompt
    }

    func testOldAccessLapsesAndRecentAccessStays() async throws {
        let m = model()
        await m.start()
        m.permissionExpiry = .week
        try m.core.rememberPermission(origin: "https://old.test", kind: .camera, decision: .allow)
        try m.core.rememberPermission(origin: "https://new.test", kind: .microphone, decision: .allow)
        m.notePermissionGranted(origin: "https://old.test", kinds: [.camera], now: Date().addingTimeInterval(-9 * 86_400))
        m.notePermissionGranted(origin: "https://new.test", kinds: [.microphone], now: Date().addingTimeInterval(-86_400))
        XCTAssertEqual(m.expirePermissions(), 1)
        XCTAssertEqual(decision(m, "https://old.test", .camera), .prompt, "after a week the site has to ask again")
        XCTAssertEqual(decision(m, "https://new.test", .microphone), .allow)
    }

    func testNeverMeansNever() async throws {
        let m = model()
        await m.start()
        m.permissionExpiry = .off
        try m.core.rememberPermission(origin: "https://a.test", kind: .camera, decision: .allow)
        m.notePermissionGranted(origin: "https://a.test", kinds: [.camera], now: Date().addingTimeInterval(-400 * 86_400))
        XCTAssertEqual(m.expirePermissions(), 0)
        XCTAssertEqual(decision(m, "https://a.test", .camera), .allow)
    }

    func testAccessGivenBeforeThisExistedStartsCountingFromNow() async throws {
        let m = model()
        await m.start()
        m.permissionExpiry = .day
        try m.core.rememberPermission(origin: "https://legacy.test", kind: .location, decision: .allow)
        XCTAssertEqual(m.expirePermissions(), 0, "no date is known, so it is not cut off at once")
        XCTAssertEqual(m.expirePermissions(now: Date().addingTimeInterval(2 * 86_400)), 1)
    }

    func testDenialsAreNeverTouched() async throws {
        let m = model()
        await m.start()
        m.permissionExpiry = .day
        try m.core.rememberPermission(origin: "https://no.test", kind: .camera, decision: .deny)
        XCTAssertEqual(m.expirePermissions(now: Date().addingTimeInterval(90 * 86_400)), 0)
        XCTAssertEqual(decision(m, "https://no.test", .camera), .deny)
    }
}

@MainActor
final class NavigationPolicyTests: XCTestCase {
    private func decide(_ text: String, main: Bool = true) -> NavDecision { NavigationPolicy.decide(url: URL(string: text)!, mainFrame: main) }

    func testAuthenticatorAndOtherAppLinksAreOfferedToTheSystem() {
        for link in ["msauth://auth?code=1", "otpauth://totp/Acme:me?secret=ABC", "microsoft-authenticator://x", "googleauthenticator://x",
                     "duo://x", "okta-verify://x", "twilio-authy://x", "itms-apps://apps.apple.com/app/id1", "com.company.easyauth://login?t=1"] {
            XCTAssertEqual(decide(link), .external, link)
        }
    }

    func testWebAndMailLinksKeepTheirOwnRules() {
        XCTAssertEqual(decide("https://example.com"), .allow)
        XCTAssertEqual(decide("mailto:a@b.test"), .external)
    }

    func testKindsThatCanRunCodeOrReadFilesStayBlocked() {
        for link in ["javascript:alert(1)", "data:text/html,<b>x</b>", "file:///etc/passwd", "vbscript:x", "view-source:https://a.test", "ftp://a.test/x"] {
            XCTAssertEqual(decide(link), .deny, link)
        }
    }

    func testAnAppLinkInsideAFrameIsNeverOpened() {
        XCTAssertEqual(decide("msauth://auth", main: false), .deny, "only the page in front can hand off to another app")
    }
}

final class ProxyConfigTests: XCTestCase {
    func testGoodProxyIsAccepted() throws {
        let config = try ProxyConfig.validated(kind: .socks5, host: " proxy.example.com ", port: "1080", username: "me").get()
        XCTAssertEqual(config.host, "proxy.example.com")
        XCTAssertEqual(config.port, 1080)
        XCTAssertEqual(config.summary, "proxy.example.com:1080")
        XCTAssertNoThrow(try ProxyConfig.validated(kind: .http, host: "192.168.1.5", port: "8080", username: "").get())
    }

    func testBadInputIsRefusedInPlainWords() {
        XCTAssertEqual(ProxyConfig.validated(kind: .http, host: "", port: "80", username: "").failureValue, .noHost)
        XCTAssertEqual(ProxyConfig.validated(kind: .http, host: "http://proxy.example.com", port: "80", username: "").failureValue, .badHost)
        XCTAssertEqual(ProxyConfig.validated(kind: .http, host: "proxy.example.com/path", port: "80", username: "").failureValue, .badHost)
        XCTAssertEqual(ProxyConfig.validated(kind: .http, host: "proxy.example.com", port: "0", username: "").failureValue, .badPort)
        XCTAssertEqual(ProxyConfig.validated(kind: .http, host: "proxy.example.com", port: "70000", username: "").failureValue, .badPort)
        XCTAssertEqual(ProxyConfig.validated(kind: .http, host: "proxy.example.com", port: "abc", username: "").failureValue, .badPort)
    }
}

private extension Result {
    var failureValue: Failure? { if case .failure(let error) = self { return error }; return nil }
}
