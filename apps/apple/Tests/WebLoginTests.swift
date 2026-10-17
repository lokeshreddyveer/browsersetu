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

final class PasswordKeepingTests: XCTestCase {
    func testASecretIsFoundWhicheverWayItWasKept() {
        let service = "com.browsersetu.test.keep." + UUID().uuidString
        defer { SecretStore.deleteAll(service: service) }
        let data = Data("secret".utf8)
        // Asking for iCloud Keychain on a copy that cannot use it must keep the secret on this device, not lose it.
        let outcome = SecretStore.put(data, service: service, account: "a", synchronizable: true)
        XCTAssertNotEqual(outcome, .failed)
        XCTAssertEqual(SecretStore.get(service: service, account: "a"), data)
        XCTAssertEqual(SecretStore.accounts(service: service), ["a"])
        // Writing it the other way replaces it; it never shows twice.
        XCTAssertNotEqual(SecretStore.put(Data("again".utf8), service: service, account: "a"), .failed)
        XCTAssertEqual(SecretStore.get(service: service, account: "a"), Data("again".utf8))
        XCTAssertEqual(SecretStore.accounts(service: service), ["a"])
        SecretStore.delete(service: service, account: "a")
        XCTAssertNil(SecretStore.get(service: service, account: "a"))
    }

    func testMovingPasswordsLeavesThemAllThere() {
        let profile = "move-" + UUID().uuidString
        defer { WebLoginVault.removeAll(profile: profile) }
        guard WebLoginVault.save(WebLogin(origin: "https://a.test", user: "me", password: "pw"), profile: profile) else { return XCTFail("the Keychain is not available to this test run") }
        WebLoginVault.save(WebLogin(origin: "https://b.test", user: "you", password: "pw2"), profile: profile)
        let result = WebLoginVault.migrate(profile: profile, toCloud: true)
        XCTAssertEqual(result.total, 2)
        XCTAssertEqual(WebLoginVault.list(profile: profile).count, 2, "none are lost, whether or not iCloud Keychain was available")
        _ = WebLoginVault.migrate(profile: profile, toCloud: false)
        XCTAssertEqual(WebLoginVault.list(profile: profile).map(\.password).sorted(), ["pw", "pw2"])
    }

    func testABackupCarriesPasswordsOnlyWhenAsked() throws {
        let payloadWith = BackupPayload(created: Date(), bookmarks: [], settings: [:], passwords: [WebLogin(origin: "https://a.test", user: "me", password: "pw")])
        let sealed = try BackupFile.seal(payloadWith, passphrase: "correct horse", iterations: 1_000)
        XCTAssertEqual(try BackupFile.open(sealed, passphrase: "correct horse").passwords?.first?.password, "pw")
        let without = try BackupFile.seal(BackupPayload(created: Date(), bookmarks: [], settings: [:]), passphrase: "x", iterations: 1_000)
        XCTAssertNil(try BackupFile.open(without, passphrase: "x").passwords)
    }

    @MainActor
    func testRestoringPasswordsRefusesOddOnes() async {
        let model = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-restore-\(UUID().uuidString)", profile: "restore-" + UUID().uuidString)
        defer { WebLoginVault.removeAll(profile: model.profileName) }
        let added = model.restorePasswords([
            WebLogin(origin: "https://good.test", user: "me", password: "pw"),
            WebLogin(origin: "http://plain.test", user: "me", password: "pw"),                 // plain http is never kept
            WebLogin(origin: "https://empty.test", user: "", password: "pw"),
            WebLogin(origin: "https://long.test", user: "me", password: String(repeating: "x", count: 600)),
        ])
        XCTAssertEqual(added, 1)
        XCTAssertEqual(model.restorePasswords([WebLogin(origin: "https://good.test", user: "me", password: "pw")]), 0, "the same one again is not added twice")
    }
}
