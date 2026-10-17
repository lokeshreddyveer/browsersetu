import XCTest
@testable import Browser_Setu

final class WebLoginTests: XCTestCase {
    func testOriginsAreExactAndPlainHTTPIsLocalOnly() {
        XCTAssertEqual(WebLoginOrigin.normalized("https://Example.com/login?x=1"), "https://example.com")
        XCTAssertEqual(WebLoginOrigin.normalized("https://example.com:443/"), "https://example.com")
        XCTAssertEqual(WebLoginOrigin.normalized("https://example.com:8443/"), "https://example.com:8443")
        XCTAssertEqual(WebLoginOrigin.normalized("http://localhost:3000/"), "http://localhost:3000")
        XCTAssertNil(WebLoginOrigin.normalized("http://example.com/"))
        XCTAssertNil(WebLoginOrigin.normalized("file:///etc/passwd"))
        XCTAssertNil(WebLoginOrigin.normalized("javascript:alert(1)"))
        XCTAssertNotEqual(WebLoginOrigin.normalized("https://example.com"), WebLoginOrigin.normalized("https://example.com.evil.test"))
    }

    func testOffersSaveUpdateOrNothing() {
        let kept = [WebLogin(origin: "https://a.test", user: "me", password: "old")]
        XCTAssertEqual(LoginRules.offer(origin: "https://a.test", user: "you", password: "p", kept: kept, neverFor: []), .save)
        XCTAssertEqual(LoginRules.offer(origin: "https://a.test", user: "me", password: "new", kept: kept, neverFor: []), .update)
        XCTAssertEqual(LoginRules.offer(origin: "https://a.test", user: "me", password: "old", kept: kept, neverFor: []), .nothing)
        XCTAssertEqual(LoginRules.offer(origin: "https://a.test", user: "you", password: "p", kept: kept, neverFor: ["https://a.test"]), .nothing)
        XCTAssertEqual(LoginRules.offer(origin: "https://b.test", user: "me", password: "old", kept: kept, neverFor: []), .save, "another site is another sign-in")
        XCTAssertEqual(LoginRules.offer(origin: "https://a.test", user: "", password: "p", kept: [], neverFor: []), .nothing)
        XCTAssertEqual(LoginRules.offer(origin: "https://a.test", user: "me", password: String(repeating: "x", count: 600), kept: [], neverFor: []), .nothing)
    }

    func testCaptureRefusesAnythingOddFromThePage() {
        XCTAssertNotNil(LoginRules.capture(["origin": "https://a.test", "user": " me ", "password": "pw"]))
        XCTAssertEqual(LoginRules.capture(["origin": "https://a.test", "user": " me ", "password": "pw"])?.user, "me")
        XCTAssertNil(LoginRules.capture(["origin": "http://a.test", "user": "me", "password": "pw"]), "plain http is never saved")
        XCTAssertNil(LoginRules.capture(["origin": "https://a.test", "user": "", "password": "pw"]))
        XCTAssertNil(LoginRules.capture(nil))
    }

    func testTheVaultKeepsListsAndForgetsPerProfile() {
        let profile = "test-" + UUID().uuidString
        defer { WebLoginVault.removeAll(profile: profile) }
        let a = WebLogin(origin: "https://a.test", user: "me", password: "pw")
        let b = WebLogin(origin: "https://b.test", user: "me", password: "pw2")
        guard WebLoginVault.save(a, profile: profile) else { return XCTFail("the Keychain is not available to this test run") }
        WebLoginVault.save(b, profile: profile)
        XCTAssertEqual(WebLoginVault.list(profile: profile).count, 2)
        XCTAssertEqual(WebLoginVault.list(origin: "https://a.test", profile: profile).first?.password, "pw")
        XCTAssertTrue(WebLoginVault.list(profile: "other-" + profile).isEmpty)
        WebLoginVault.forget(a, profile: profile)
        XCTAssertEqual(WebLoginVault.list(profile: profile).map(\.origin), ["https://b.test"])
    }
}
