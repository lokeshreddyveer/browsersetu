import CryptoKit
import WebKit
import XCTest
@testable import Browser_Setu

/// The password manager's guarantees: exact origins, associations only the person adds, duplicate and reuse findings that never carry a password, private tabs kept out, and no
/// plaintext password anywhere but the Keychain. Every test uses a throwaway profile name and removes what it made; none touches a real saved sign-in.
@MainActor
final class PasswordSafetyTests: XCTestCase {
    private var profiles: [String] = []

    private func profile() -> String { let name = "test-\(UUID().uuidString.prefix(8))"; profiles.append(name); return name }

    override func tearDown() {
        for name in profiles { WebLoginVault.removeAll(profile: name); SyncLedgerGuard.deleteKey(profile: name) }
        profiles = []
        super.tearDown()
    }

    func testOnlyAnExactSecureOriginIsEverMatched() {
        XCTAssertEqual(WebLoginOrigin.normalized("https://Example.com/login?x=1"), "https://example.com")
        XCTAssertEqual(WebLoginOrigin.normalized("https://example.com:8443/"), "https://example.com:8443")
        XCTAssertNotEqual(WebLoginOrigin.normalized("https://www.example.com"), WebLoginOrigin.normalized("https://example.com"), "a sibling address is a different origin")
        XCTAssertNil(WebLoginOrigin.normalized("http://example.com"), "plain http is never matched")
        XCTAssertNotNil(WebLoginOrigin.normalized("http://localhost:3000"), "except this computer")
        XCTAssertNil(WebLoginOrigin.normalized("https://example.com.evil.net/").flatMap { $0 == "https://example.com" ? $0 : nil })
    }

    func testAnOlderSavedItemStillOpensAndAnAssociationIsOnlyWhatThePersonAdded() throws {
        let old = #"{"origin":"https://example.com","user":"ada","password":"pw","saved":0}"#
        let login = try JSONDecoder().decode(WebLogin.self, from: Data(old.utf8))
        XCTAssertEqual(login.related, [])
        XCTAssertTrue(login.applies(to: "https://example.com"))
        XCTAssertFalse(login.applies(to: "https://www.example.com"), "never guessed")
        let name = profile()
        XCTAssertTrue(WebLoginVault.save(WebLogin(origin: "https://example.com", user: "ada", password: "pw-\(UUID().uuidString)"), profile: name))
        var saved = try XCTUnwrap(WebLoginVault.list(profile: name).first)
        XCTAssertTrue(WebLoginVault.associate(saved, with: "https://accounts.example.net/login", profile: name))
        saved = try XCTUnwrap(WebLoginVault.list(profile: name).first)
        XCTAssertEqual(saved.related, ["https://accounts.example.net"])
        XCTAssertEqual(WebLoginVault.list(origin: "https://accounts.example.net", profile: name).count, 1, "now offered there")
        XCTAssertTrue(WebLoginVault.list(origin: "https://www.example.com", profile: name).isEmpty, "and nowhere else")
        XCTAssertFalse(WebLoginVault.associate(saved, with: "http://insecure.example", profile: name), "plain http refused")
        XCTAssertFalse(WebLoginVault.associate(saved, with: "https://example.com", profile: name), "its own address refused")
        for i in 0..<WebLogin.maxRelated { _ = WebLoginVault.associate(try XCTUnwrap(WebLoginVault.list(profile: name).first), with: "https://s\(i).example.org", profile: name) }
        XCTAssertLessThanOrEqual(try XCTUnwrap(WebLoginVault.list(profile: name).first).related.count, WebLogin.maxRelated)
        WebLoginVault.dissociate(try XCTUnwrap(WebLoginVault.list(profile: name).first), from: "https://accounts.example.net", profile: name)
        XCTAssertTrue(WebLoginVault.list(origin: "https://accounts.example.net", profile: name).isEmpty)
    }

    func testDuplicatesReuseAndWeakPasswordsAreFoundWithoutAnyPasswordInTheReport() {
        let shared = "Correct-Horse-9!-\(UUID().uuidString)"
        let logins = [
            WebLogin(origin: "https://example.com", user: "ada", password: "Unique-One-\(UUID().uuidString)"),
            WebLogin(origin: "https://www.example.com", user: "Ada", password: "Unique-Two-\(UUID().uuidString)"),
            WebLogin(origin: "https://shop.example.org", user: "ada", password: shared),
            WebLogin(origin: "https://bank.example.net", user: "ada", password: shared),
            WebLogin(origin: "https://weak.example.io", user: "ada", password: "1234"),
        ]
        let report = PasswordAudit.analyze(logins)
        XCTAssertEqual(report.duplicates, [["https://example.com\nada", "https://www.example.com\nAda"].sorted()], "the same name on two addresses of one website")
        XCTAssertEqual(report.reused.count, 1)
        XCTAssertEqual(Set(report.reused[0]), ["https://shop.example.org\nada", "https://bank.example.net\nada"])
        XCTAssertEqual(report.weak, ["https://weak.example.io\nada"])
        XCTAssertFalse("\(report)".contains(shared), "a report holds sign-in ids, never a password")
        for login in logins { XCTAssertFalse("\(report)".contains(login.password)) }
        XCTAssertTrue(PasswordAudit.analyze([]).isEmpty)
    }

    func testMergingKeepsTheNewerPasswordAndRemembersTheOtherAddress() throws {
        let name = profile()
        let older = WebLogin(origin: "https://example.com", user: "ada", password: "old-\(UUID().uuidString)", saved: Date(timeIntervalSinceNow: -1000))
        let newer = WebLogin(origin: "https://www.example.com", user: "ada", password: "new-\(UUID().uuidString)", saved: Date())
        XCTAssertTrue(WebLoginVault.save(older, profile: name)); XCTAssertTrue(WebLoginVault.save(newer, profile: name))
        XCTAssertTrue(WebLoginVault.merge(older, newer, profile: name))
        let left = WebLoginVault.list(profile: name)
        XCTAssertEqual(left.count, 1)
        XCTAssertEqual(left[0].password, newer.password)
        XCTAssertEqual(left[0].origin, "https://www.example.com")
        XCTAssertEqual(left[0].related, ["https://example.com"])
    }

    // MARK: Nothing in plaintext but the Keychain

    func testTheSyncLedgersStoredCopyHoldsNoPasswordAndStillRecognisesAnUnchangedOne() throws {
        let name = profile()
        let secret = "Hunter2-\(UUID().uuidString)"
        let login = WebLogin(origin: "https://example.com", user: "ada", password: secret)
        XCTAssertTrue(WebLoginVault.save(login, profile: name))
        var state = SyncState()
        state.logins[login.id] = SyncCell(stamp: SyncStamp(time: 5, device: "d"), value: SyncLogin(origin: login.origin, user: login.user, password: secret))
        let stored = SyncLedgerGuard.redacted(state, profile: name)
        let text = String(decoding: try JSONEncoder().encode(["state": stored]), as: UTF8.self)
        XCTAssertFalse(text.contains(secret), "the stored ledger never holds the password")
        XCTAssertTrue(text.contains(SyncLedgerGuard.marker))
        XCTAssertFalse(text.contains("Hunter2"))
        // Loaded again, an unchanged sign-in is whole again, so it is not mistaken for a change.
        let loaded = SyncLedgerGuard.rehydrated(stored, current: [login.id: login], profile: name)
        XCTAssertEqual(loaded.logins[login.id]?.value?.password, secret)
        XCTAssertEqual(loaded, state)
        // A changed password does not match its fingerprint, so it stays different and the change is seen.
        let changed = WebLogin(origin: login.origin, user: login.user, password: secret + "-new")
        XCTAssertNotEqual(SyncLedgerGuard.rehydrated(stored, current: [login.id: changed], profile: name).logins[login.id]?.value?.password, changed.password)
        XCTAssertNotEqual(SyncLedgerGuard.rehydrated(stored, current: [login.id: changed], profile: name).logins[login.id]?.value?.password, secret)
        // Tombstones and other kinds of cell are untouched.
        var withTombstone = state
        withTombstone.logins["gone"] = SyncCell(stamp: SyncStamp(time: 6, device: "d"), value: nil)
        XCTAssertNil(SyncLedgerGuard.redacted(withTombstone, profile: name).logins["gone"]?.value)
        // The key is this profile's own.
        let other = profile()
        XCTAssertNotEqual(SyncLedgerGuard.redacted(state, profile: name).logins[login.id]?.value?.password, SyncLedgerGuard.redacted(state, profile: other).logins[login.id]?.value?.password)
    }

    func testTheModelSavesTheLedgerRedactedAndNoPasswordFileOrLogCallExists() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sync = try String(contentsOf: root.appendingPathComponent("Shared/SyncModel.swift"), encoding: .utf8)
        XCTAssertTrue(sync.contains("SyncLedgerGuard.redacted(syncLedger, profile: profileName)"), "the ledger is stored redacted")
        let model = try String(contentsOf: root.appendingPathComponent("Shared/BrowserModel.swift"), encoding: .utf8)
        XCTAssertTrue(model.contains("SyncLedgerGuard.rehydrated("), "and made whole from the Keychain when loaded")
        // Files that handle passwords never log, print or write them.
        for file in ["Shared/WebLogins.swift", "Shared/PasswordManager.swift", "Shared/PasswordSafety.swift", "Shared/SyncMerge.swift", "Shared/SyncModel.swift", "Shared/BreachCheck.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            for call in ["print(", "NSLog(", "os_log", "Logger(", "debugPrint(", "dump(", "FileHandle.standardError"] { XCTAssertFalse(text.contains(call), "\(file) contains \(call)") }
        }
        // Passwords are only ever put in the Keychain: the vault's data goes through SecretStore, never the settings table.
        let logins = try String(contentsOf: root.appendingPathComponent("Shared/WebLogins.swift"), encoding: .utf8)
        XCTAssertFalse(logins.contains("saveSetting") || logins.contains("setSetting"))
    }

    func testAPrivateTabNeverOffersToSaveOrFillAndNothingIsAsked() async throws {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-pw-\(UUID().uuidString)", profile: profile())
        await m.start()
        var asked = 0
        Dialogs.testHandler = { _, _, _ in asked += 1; return 0 }
        defer { Dialogs.testHandler = nil }
        let priv = m.openTab(url: nil, isPrivate: true)
        priv.url = URL(string: "https://example.com/login")
        m.loginSubmitted(origin: "https://example.com", user: "ada", password: "pw-\(UUID().uuidString)", in: priv)
        m.offerToFillLogin(in: priv, force: true)
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(asked, 0, "a private tab is never asked about a password")
        XCTAssertTrue(WebLoginVault.list(profile: m.profileName).isEmpty, "and nothing was saved")
        XCTAssertNil(priv.typedLogin)
    }

    func testTheFillScriptRefusesAFrameWhoseOriginIsNotTheOneTheLoginBelongsTo() async throws {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        web.loadHTMLString("<html><body><form><input id='u' type='text'><input id='p' type='password'></form></body></html>", baseURL: URL(string: "https://attacker.example/"))
        try await Task.sleep(for: .seconds(1.0))
        let wrong = try await web.callAsyncJavaScript(LoginScripts.fill, arguments: ["origin": "https://bank.example", "user": "ada", "password": "secret-\(UUID().uuidString)"], contentWorld: .defaultClient) as? Bool
        XCTAssertEqual(wrong, false, "a page at another origin is never filled")
        let value = try await web.callAsyncJavaScript("return document.getElementById('p').value + document.getElementById('u').value;", contentWorld: .page) as? String
        XCTAssertEqual(value, "", "nothing was typed into it")
        let right = try await web.callAsyncJavaScript(LoginScripts.fill, arguments: ["origin": "https://attacker.example", "user": "ada", "password": "pw"], contentWorld: .defaultClient) as? Bool
        XCTAssertEqual(right, true, "its own origin is")
    }
}
