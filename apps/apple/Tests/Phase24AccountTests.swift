import XCTest
@testable import Browser_Setu

// Phase 24: website accounts. The rules (who may be sent a credential, when, and what happens when it is refused) are tested with in-memory secrets; the transfer tests use the local
// fixture server (port 18766), which answers 401 unless the Authorization header is exactly the value the test asked for and lists every Authorization value it saw per path.

private func https(_ host: String, _ path: String = "/f.bin") -> URL { URL(string: "https://\(host)\(path)")! }

// MARK: - The list and its secrets

@MainActor
final class AccountStoreTests: XCTestCase {
    var secrets: MemoryAccountSecretStore!
    var clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() { secrets = MemoryAccountSecretStore() }

    private func store(profile: String = "default", file: URL? = nil) -> AccountStore { AccountStore(profile: profile, file: file, secrets: secrets, now: { self.clock }) }
    private func id(_ o: AccountStore.Outcome) -> String { if case .ok(let id) = o { return id }; XCTFail("\(o)"); return "" }

    func testAddingAndDeletingAnAccount() {
        let s = store()
        let a = id(s.add(name: "Files", host: "Files.Example.com", method: .apiToken, secret: "tok_123"))
        XCTAssertEqual(s.accounts.first?.host, "files.example.com"); XCTAssertEqual(s.accounts.first?.state, .valid)
        XCTAssertEqual(secrets.count, 1)
        if case .refused = s.add(name: "Again", host: "files.example.com", method: .apiToken, secret: "other") {} else { XCTFail("one account per website") }
        s.delete(a)
        XCTAssertTrue(s.accounts.isEmpty); XCTAssertEqual(secrets.count, 0, "the credential goes with the account")
    }

    func testBadInputIsRefusedBeforeAnythingIsStored() {
        let s = store()
        for host in ["", "https://x.com", "x.com/path", "*.x.com", "x .com", ".x.com", "x..com", "x.com:99", "ex@mple.com"] {
            if case .refused = s.add(name: "N", host: host, method: .apiToken, secret: "t") {} else { XCTFail("host \(host)") }
        }
        for token in ["", "has space", "line\r\nInjected: 1", String(repeating: "a", count: 5000)] {
            if case .refused = s.add(name: "N", host: "x.com", method: .apiToken, secret: token) {} else { XCTFail("token") }
        }
        if case .refused = s.add(name: "N", host: "x.com", method: .httpBasic, username: "a:b", secret: "p") {} else { XCTFail("colon in user name") }
        if case .refused = s.add(name: "N", host: "x.com", method: .httpBasic, username: "u", secret: "bad\r\npass") {} else { XCTFail("newline in password") }
        if case .refused = s.add(name: "", host: "x.com", method: .webSession) {} else { XCTFail("name") }
        XCTAssertTrue(s.accounts.isEmpty); XCTAssertEqual(secrets.count, 0)
    }

    func testTheSecretIsNeverInTheSavedListOrInADescription() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("p24-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let s = store(file: folder.appendingPathComponent("accounts.json"))
        _ = s.add(name: "Basic", host: "a.example.com", method: .httpBasic, username: "alice", secret: "hunter2-secret")
        _ = s.add(name: "Token", host: "b.example.com", method: .apiToken, secret: "tok_SECRETVALUE")
        let text = try String(contentsOf: folder.appendingPathComponent("accounts.json"), encoding: .utf8)
        for forbidden in ["hunter2", "SECRETVALUE", "Basic ", "Bearer"] { XCTAssertFalse(text.contains(forbidden), forbidden) }
        XCTAssertTrue(text.contains("alice"), "the user name is not a secret and is shown")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("accounts.json").path)[.posixPermissions] as? Int), 0o600)
        let dump = String(describing: s.accounts) + String(describing: s.hint(for: https("a.example.com")))
        XCTAssertFalse(dump.contains("hunter2")); XCTAssertFalse(dump.contains("SECRETVALUE"))
    }

    func testEachProfileHasItsOwnAccountsAndNoneReachesAnother() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("p24b-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("accounts.json")
        let a = store(profile: "alpha", file: file)
        _ = a.add(name: "A", host: "x.example.com", method: .apiToken, secret: "tok")
        let b = store(profile: "beta", file: file)          // even handed alpha's file
        XCTAssertTrue(b.accounts.isEmpty, "alpha's entries are not beta's")
        XCTAssertEqual(b.router.decide(https("x.example.com"), origin: .user), .none)
        if case .use = a.router.decide(https("x.example.com"), origin: .user) {} else { XCTFail("alpha uses its own") }
    }

    func testAKeychainThatWillNotSaveAddsNothing() {
        let s = store()
        secrets.failWrites = true
        if case .refused = s.add(name: "N", host: "x.com", method: .apiToken, secret: "t") {} else { XCTFail() }
        XCTAssertTrue(s.accounts.isEmpty)
        secrets.failWrites = false
        let ok = id(s.add(name: "N", host: "x.com", method: .apiToken, secret: "t"))
        secrets.failWrites = true
        if case .refused = s.reconnect(ok, secret: "new") {} else { XCTFail("an unsaved credential changes nothing") }
        secrets.failWrites = false
        if case .use(_, let header) = s.router.decide(https("x.com"), origin: .user) { XCTAssertEqual(header, "Bearer t", "the old credential is untouched") } else { XCTFail() }
    }

    func testALockedKeychainIsUnavailableNotSignedOutAndComesBack() {
        let s = store()
        _ = s.add(name: "N", host: "x.com", method: .apiToken, secret: "t")
        secrets.unavailable = true
        XCTAssertEqual(s.router.decide(https("x.com"), origin: .user), .refused(.keychainUnavailable, account: s.accounts[0].id))
        s.checkKeychain()
        XCTAssertEqual(s.accounts[0].state, .unavailable)
        secrets.unavailable = false
        s.checkKeychain()
        XCTAssertEqual(s.accounts[0].state, .valid, "it is usable again as soon as the Keychain is")
    }

    func testExpiryRevocationDisconnectAndRotation() {
        let s = store()
        let a = id(s.add(name: "N", host: "x.com", method: .apiToken, secret: "old", expiresAt: clock.addingTimeInterval(100)))
        if case .use = s.router.decide(https("x.com"), origin: .user) {} else { XCTFail() }
        clock = clock.addingTimeInterval(101)
        XCTAssertEqual(s.router.decide(https("x.com"), origin: .user), .refused(.expired, account: a), "an end date that passed stops use even before the list is refreshed")
        s.refreshExpiry(); XCTAssertEqual(s.accounts[0].state, .expired)
        _ = s.reconnect(a, secret: "new", expiresAt: nil)
        XCTAssertEqual(s.router.decide(https("x.com"), origin: .user), .use(account: a, header: "Bearer new"), "rotation: the new credential, never the old")
        s.disconnect(a)
        XCTAssertEqual(s.router.decide(https("x.com"), origin: .user), .none); XCTAssertEqual(secrets.count, 0, "disconnecting forgets the credential")
        XCTAssertEqual(s.accounts[0].state, .disconnected)
        _ = s.reconnect(a, secret: "again")
        if case .use = s.router.decide(https("x.com"), origin: .user) {} else { XCTFail() }
    }

    func testARefusedCredentialNeedsReconnectingAndIsNotRetried() {
        let s = store()
        let a = id(s.add(name: "N", host: "x.com", method: .apiToken, secret: "zq9-secret"))
        s.authorizationRefused(account: a)
        XCTAssertEqual(s.accounts[0].state, .reauthRequired)
        XCTAssertEqual(s.router.decide(https("x.com"), origin: .user), .refused(.reauthRequired, account: a))
        XCTAssertNotNil(s.accounts[0].lastError); XCTAssertFalse(s.accounts[0].lastError!.contains("zq9"), "no secret in the message")
    }

    func testOnlyThePersonsOwnHttpsRequestToTheExactWebsiteGetsTheCredential() {
        let s = store()
        let a = id(s.add(name: "N", host: "files.example.com", method: .httpBasic, username: "al", secret: "pw"))
        let expected = "Basic " + Data("al:pw".utf8).base64EncodedString()
        XCTAssertEqual(s.router.decide(https("files.example.com"), origin: .user), .use(account: a, header: expected))
        for origin in [DownloadRequestOrigin.page, .automation, .browserExtension] { XCTAssertEqual(s.router.decide(https("files.example.com"), origin: origin), .none, "\(origin)") }
        XCTAssertEqual(s.router.decide(https("files.example.com"), origin: .user, isPrivate: true), .none, "never for a private download")
        XCTAssertEqual(s.router.decide(https("other.example.com"), origin: .user), .none)
        XCTAssertEqual(s.router.decide(https("sub.files.example.com"), origin: .user), .none, "a subdomain is another website")
        XCTAssertEqual(s.router.decide(https("example.com"), origin: .user), .none)
        XCTAssertEqual(s.router.decide(https("evil.com", "/files.example.com"), origin: .user), .none)
        XCTAssertEqual(s.router.decide(URL(string: "https://files.example.com:8443/x")!, origin: .user), .none, "another port is another website")
        XCTAssertEqual(s.router.decide(URL(string: "http://files.example.com/x")!, origin: .user), .refused(.insecure, account: a), "never over plain http")
        XCTAssertEqual(s.router.decide(URL(string: "https://user:pass@files.example.com/x")!, origin: .user), .use(account: a, header: expected))
    }

    func testSuggestionsSayWhatTheAccountsAllow() {
        let s = store()
        let t = id(s.add(name: "Token", host: "t.example.com", method: .apiToken, secret: "t"))
        _ = s.add(name: "Browser", host: "w.example.com", method: .webSession)
        XCTAssertEqual(s.hint(for: https("t.example.com")), .connected("Token"))
        XCTAssertEqual(s.hint(for: https("w.example.com")), .sessionOnly("Browser"))
        XCTAssertEqual(s.hint(for: https("none.example.com")), .none)
        XCTAssertEqual(s.hint(for: URL(string: "http://t.example.com/x")!), .unsupported("Token"))
        s.authorizationRefused(account: t); XCTAssertEqual(s.hint(for: https("t.example.com")), .signInAgain("Token"))
        XCTAssertEqual(s.router.decide(https("w.example.com"), origin: .user), .none, "a browser-session entry has no credential to send")
    }

    func testAnUnreadableListUsesNoAccount() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("p24c-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("garbage".utf8).write(to: folder.appendingPathComponent("accounts.json"))
        let s = store(file: folder.appendingPathComponent("accounts.json"))
        XCTAssertTrue(s.accounts.isEmpty); XCTAssertNotNil(s.storageProblem)
    }
}

// MARK: - Through the downloader (local fixture server)

@MainActor
final class AccountTransferTests: MediaCase {
    var secrets: MemoryAccountSecretStore!
    var store: AccountStore!
    static let payload = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })

    override func setUp() async throws {
        try await super.setUp()
        AccountRouter.allowPlainHTTPForTests = true
        secrets = MemoryAccountSecretStore()
        store = AccountStore(profile: "default", file: nil, secrets: secrets)
        c.accountStore = store
    }
    override func tearDown() async throws { AccountRouter.allowPlainHTTPForTests = false; try await super.tearDown() }

    private func addAccount(host: String = "127.0.0.1", port: Int = 18766, secret: String = "tok-ok") -> String {
        guard case .ok(let id) = store.add(name: "Fixture", host: host, port: port, method: .apiToken, secret: secret) else { fatalError() }
        return id
    }
    private func auth() async -> [String: [String]] {
        guard let d = try? await get("/_media_hits"), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return j["auth"] as? [String: [String]] ?? [:]
    }
    private func run(_ path: String, query: String, origin: DownloadRequestOrigin = .user) async throws -> DownloadTaskRecord? {
        let id = try XCTUnwrap(c.scheduleDownload(url: url("/media/\(path)?\(query)"), at: Date(), origin: origin))
        return await wait(id, for: [.completed, .failed], seconds: 30)
    }
    private func need(_ value: String) -> String { "need_auth=" + value.addingPercentEncoding(withAllowedCharacters: .alphanumerics)! }

    func testAnAccountDownloadSendsTheCredentialAndNothingAboutItIsSaved() async throws {
        try await put("acc/a.bin", Self.payload)
        _ = addAccount()
        let record = try await run("acc/a.bin", query: need("Bearer tok-ok"))
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? "")
        let seen = await auth()["acc/a.bin"] ?? []
        XCTAssertTrue(seen.contains("Bearer tok-ok")); XCTAssertTrue(seen.allSatisfy { $0 == "Bearer tok-ok" }, "every request of the download carried it: \(seen)")
        // Nothing durable holds it.
        // (The address the test used for the server carries the value it expects in its own query; what must not hold it is everything the app writes about the download.)
        let dump = c.events.joined() + String(describing: c.ledger.records.values.map { $0.engineMetadata }) + (record?.failure?.reason ?? "") + String(describing: record?.file)
        XCTAssertFalse(dump.contains("tok-ok")); XCTAssertFalse(dump.contains("Bearer"))
        XCTAssertNotNil(store.accounts.first?.lastValidatedAt, "a working credential is recorded as validated")
    }

    func testWithoutAnAccountTheSameAddressFailsAndIsNotQuietlyAnonymous() async throws {
        try await put("acc/b.bin", Self.payload)
        let record = try await run("acc/b.bin", query: need("Bearer tok-ok"))
        XCTAssertEqual(record?.state, .failed)
        let seenB = await auth()["acc/b.bin"] ?? []
        XCTAssertTrue(seenB.allSatisfy { $0.isEmpty })
    }

    func testPageDerivedAndAutomationRequestsNeverCarryTheCredential() async throws {
        try await put("acc/c.bin", Self.payload)
        _ = addAccount()
        for origin in [DownloadRequestOrigin.page, .automation] {
            _ = try? await run("acc/c.bin", query: need("Bearer tok-ok"), origin: origin)
        }
        let seen = await auth()["acc/c.bin"] ?? []
        XCTAssertFalse(seen.contains("Bearer tok-ok"), "\(seen)")          // (such requests are not even allowed to reach this local address; either way no credential left)
    }

    func testAWrongCredentialMarksTheAccountAndTheNextTryIsStoppedWithoutAskingTheWebsite() async throws {
        try await put("acc/d.bin", Self.payload)
        let id = addAccount(secret: "tok-wrong")
        let first = try await run("acc/d.bin", query: need("Bearer tok-ok"))
        XCTAssertEqual(first?.state, .failed)
        XCTAssertEqual(store.account(id)?.state, .reauthRequired, "the website refused it")
        let before = (await auth()["acc/d.bin"] ?? []).count
        let second = try await run("acc/d.bin", query: need("Bearer tok-ok"))
        XCTAssertEqual(second?.state, .failed); XCTAssertTrue(second?.failure?.reason.contains("Reconnect") == true, second?.failure?.reason ?? "")
        let after = (await auth()["acc/d.bin"] ?? []).count
        XCTAssertEqual(before, after, "no request at all went to the website with the refused credential, and none without it")
        // Reconnecting with the right credential works again.
        _ = store.reconnect(id, secret: "tok-ok")
        let third = try await run("acc/d.bin", query: need("Bearer tok-ok"))
        XCTAssertEqual(third?.state, .completed, third?.failure?.reason ?? "")
    }

    func testAnExpiredAccountStopsTheDownloadAndNoOtherAccountIsTried() async throws {
        try await put("acc/e.bin", Self.payload)
        let id = addAccount()
        _ = store.add(name: "Other", host: "localhost", port: 18766, method: .apiToken, secret: "tok-other")
        store.reconnect(id, secret: "tok-ok", expiresAt: Date().addingTimeInterval(-5))
        store.refreshExpiry()
        let before = (await auth()["acc/e.bin"] ?? []).count
        let record = try await run("acc/e.bin", query: need("Bearer tok-ok"))
        XCTAssertEqual(record?.state, .failed); XCTAssertTrue(record?.failure?.reason.contains("expired") == true, record?.failure?.reason ?? "")
        let afterE = (await auth()["acc/e.bin"] ?? []).count
        XCTAssertEqual(afterE, before, "the website was not asked")
    }

    func testTheCredentialIsDroppedWhenARedirectLeavesTheWebsite() async throws {
        try await put("acc/target.bin", Self.payload)
        _ = addAccount()
        // 127.0.0.1 redirects to localhost: another website, even though it is the same machine.
        let record = try await run("acc/start.bin", query: "redirect=" + "http://localhost:18766/media/acc/target.bin".addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)
        _ = record
        let start = await auth()["acc/start.bin"] ?? [], target = await auth()["acc/target.bin"] ?? []
        XCTAssertTrue(start.contains("Bearer tok-ok"), "the first request went to the account's website with it: \(start)")
        XCTAssertFalse(target.isEmpty, "the redirect was followed: \(target)")
        XCTAssertTrue(target.allSatisfy { $0.isEmpty }, "…and the other website saw no credential: \(target)")
    }

    func testAPartsDownloadCarriesTheCredentialOnEveryPiece() async throws {
        let big = Data((0..<(20 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        try await put("acc/big.bin", big)
        _ = addAccount()
        c.segmentedEnabled = true
        let record = try await run("acc/big.bin", query: need("Bearer tok-ok"))
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? "")
        let seen = await auth()["acc/big.bin"] ?? []
        XCTAssertGreaterThan(seen.count, 2, "probed and fetched in pieces")
        XCTAssertTrue(seen.allSatisfy { $0 == "Bearer tok-ok" }, "\(seen)")
        XCTAssertEqual(ConnectionBudget.shared.holding(owner: c.ownerID), 0)
    }
}


// MARK: - Review fixes

@MainActor
final class AccountReviewFixTests: MediaCase {
    var secrets: MemoryAccountSecretStore!
    var store: AccountStore!
    override func setUp() async throws {
        try await super.setUp()
        AccountRouter.allowPlainHTTPForTests = true
        secrets = MemoryAccountSecretStore()
        store = AccountStore(profile: "default", file: nil, secrets: secrets)
        c.accountStore = store
    }
    override func tearDown() async throws { AccountRouter.allowPlainHTTPForTests = false; try await super.tearDown() }

    private func account(secret: String = "tok-ok") -> String {
        guard case .ok(let id) = store.add(name: "F", host: "127.0.0.1", port: 18766, method: .apiToken, secret: secret) else { fatalError() }
        return id
    }

    func testOnlyThePersonsOwnRequestThatCarriedTheCredentialCanMarkItRefused() {
        let id = account()
        let u = URL(string: "http://127.0.0.1:18766/media/x")!
        for origin in [DownloadRequestOrigin.page, .automation, .browserExtension] { c.accountCredentialRefused(for: u, code: "http:401", origin: origin) }
        XCTAssertEqual(store.account(id)?.state, .valid, "another kind of request can neither use nor spoil the account")
        c.accountCredentialRefused(for: u, code: "http:403", origin: .user)
        XCTAssertEqual(store.account(id)?.state, .valid, "only 401 means the credential was refused")
        c.accountCredentialRefused(for: u, code: "http:401", origin: .user, startedAt: Date(timeIntervalSinceNow: -3600))
        XCTAssertEqual(store.account(id)?.state, .valid, "a request that began before the credential was replaced says nothing about the new one")
        c.accountCredentialRefused(for: u, code: "http:401", origin: .user, startedAt: Date())
        XCTAssertEqual(store.account(id)?.state, .reauthRequired)
    }

    func testWithdrawingAnAccountStopsTheDownloadsRunningWithIt() {
        let id = account()
        let s = c.begin(suggestedName: "r.bin", sourceURL: URL(string: "http://127.0.0.1:18766/media/r"), protocolID: .http, cancel: {})
        c.ledger.update(s.id) { $0.engineMetadata["account"] = "1" }
        let other = c.begin(suggestedName: "o.bin", sourceURL: URL(string: "http://127.0.0.1:18766/media/o"), protocolID: .http, cancel: {})
        store.disconnect(id)
        XCTAssertEqual(c.ledger.record(s.id)?.state, .cancelled, "stopped: the credential was taken away")
        XCTAssertFalse(c.ledger.record(other.id)?.state.isFinal ?? true, "a download that never used the account is left alone")
    }

    func testADownloadThatUsedAnAccountIsNotCarriedOnAnonymouslyAfterItIsDisconnected() async throws {
        try await put("acc/w.bin", Data(repeating: 7, count: 100_000))
        let id = account()
        store.disconnect(id)
        let s = c.begin(suggestedName: "w.bin", sourceURL: url("/media/acc/w.bin?need_auth=Bearer%20tok-ok"), protocolID: .http, cancel: {})
        c.ledger.update(s.id) { $0.engineMetadata["account"] = "1"; $0.engineMetadata["origin"] = "user" }
        c.http.restart(s.id)
        let record = await wait(s.id, for: [.completed, .failed, .cancelled], seconds: 20)
        XCTAssertEqual(record?.state, .failed); XCTAssertTrue(record?.failure?.reason.contains("account") == true, record?.failure?.reason ?? "")
        let seen = (try? JSONSerialization.jsonObject(with: await get("/_media_hits")) as? [String: Any])?["auth"] as? [String: [String]]
        XCTAssertNil(seen?["acc/w.bin"], "nothing was requested, with or without the credential")
    }

    func testAnUnreadableListIsKeptAsideAndBlocksAddingUntilReset() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("p24r-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("accounts.json")
        try Data("garbage".utf8).write(to: file)
        let s = AccountStore(profile: "default", file: file, secrets: MemoryAccountSecretStore())
        XCTAssertTrue(s.unreadable)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix("accounts.unreadable-") }, "the damaged file is kept, not overwritten")
        if case .refused = s.add(name: "N", host: "x.com", method: .apiToken, secret: "t") {} else { XCTFail("blocked until reset") }
        s.resetUnreadable()
        if case .ok = s.add(name: "N", host: "x.com", method: .apiToken, secret: "t") {} else { XCTFail() }
    }

    func testRemovingAProfileRemovesItsCredentialsAndList() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("p24w-\(UUID().uuidString)")
        let mem = MemoryAccountSecretStore()
        let s = AccountStore(profile: "gone", file: folder.appendingPathComponent("accounts.json"), secrets: mem)
        _ = s.add(name: "N", host: "x.com", method: .apiToken, secret: "t")
        XCTAssertEqual(mem.count, 1)
        AccountStore.wipe(profile: "gone", folder: folder, secrets: mem)
        XCTAssertEqual(mem.count, 0); XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(AccountStore(profile: "gone", file: folder.appendingPathComponent("accounts.json"), secrets: mem).accounts.isEmpty, "a new profile of the same name inherits nothing")
    }

    func testNoResumeDataIsKeptForATransferThatCarriesACredential() throws {
        let engine = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Shared/Downloads/HTTP/HTTPTransferEngine.swift"), encoding: .utf8)
        XCTAssertTrue(engine.contains("context.usedCredential ? nil : data"), "paused: no blob"); XCTAssertTrue(engine.contains("context.usedCredential) ? nil : resumeData"), "failed: no blob")
        XCTAssertTrue(engine.contains("let resumeData: Data? = context.usedCredential ? nil : resumeData"), "an old blob is never used for such a transfer")
    }
}

// MARK: - Boundaries by construction

final class AccountIsolationTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let base = root.appendingPathComponent(relative)
        var text = ""
        if let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) {
            for case let f as URL in walker where f.pathExtension == "swift" { text += (try? String(contentsOf: f, encoding: .utf8)) ?? "" }
        }
        return text
    }

    func testWebKitDownloadsExtensionsAutomationAndRemoteNeverSeeAccounts() throws {
        for folder in ["Engines/WebKit", "Shared/Downloads/Extensions", "Shared/Downloads/Automation", "Shared/Downloads/Remote", "Shared/Downloads/Explorer"] {
            let text = try source(folder)
            XCTAssertFalse(text.isEmpty, folder)
            for name in ["AccountStore", "AccountRouter", "WebsiteAccount", "AccountSecretStore"] { XCTAssertFalse(text.contains(name), "\(folder) must not reach \(name)") }
        }
    }

    func testTheEngineOffersACredentialOnlyThroughTheRouter() throws {
        let engine = try source("Shared/Downloads/HTTP")
        XCTAssertTrue(engine.contains("accounts?.decide"))
        XCTAssertFalse(engine.contains("SecretStore"), "the transfer engines never touch the Keychain themselves")
        XCTAssertFalse(try source("Shared/Downloads/Accounts").contains("HTTPCookieStorage"), "no cookies are read or exported")
        XCTAssertFalse(try source("Shared/Downloads/Accounts").contains("WKHTTPCookieStore"))
    }
}

// Regression tests for the F5 security review: every way a transfer continues is held to its account, and a mirror is judged by its own accounts.
final class AccountGateTests: MediaCase {
    var secrets: MemoryAccountSecretStore!
    var store: AccountStore!
    override func setUp() async throws {
        try await super.setUp()
        AccountRouter.allowPlainHTTPForTests = true
        secrets = MemoryAccountSecretStore()
        store = AccountStore(profile: "default", file: nil, secrets: secrets)
        c.accountStore = store
    }
    override func tearDown() async throws { AccountRouter.allowPlainHTTPForTests = false; try await super.tearDown() }

    func testAResumedDownloadWhoseAccountWasDisconnectedIsStoppedNotSentAnonymously() async throws {
        try await put("acc/r.bin", Data(repeating: 9, count: 100_000))
        guard case .ok(let id) = store.add(name: "F", host: "127.0.0.1", port: 18766, method: .apiToken, secret: "tok-ok") else { return XCTFail() }
        let s = c.begin(suggestedName: "r.bin", sourceURL: url("/media/acc/r.bin?need_auth=Bearer%20tok-ok"), protocolID: .http, cancel: {})
        // The account goes away while the task is not one that "withdrawn" stops (it was waiting); the task, which used the account, then continues.
        store.disconnect(id)
        c.ledger.update(s.id) { $0.engineMetadata["account"] = "1"; $0.engineMetadata["origin"] = "user" }
        c.http.resume(s.id, data: Data())
        let record = await wait(s.id, for: [.completed, .failed, .cancelled], seconds: 20)
        XCTAssertEqual(record?.state, .failed, "state \(String(describing: record?.state))")
        XCTAssertTrue(record?.failure?.reason.contains("account") == true, record?.failure?.reason ?? "")
        let seen = (try? JSONSerialization.jsonObject(with: await get("/_media_hits")) as? [String: Any])?["auth"] as? [String: [String]]
        XCTAssertNil(seen?["acc/r.bin"], "no request, with or without the credential")
    }
}

final class ProfileRemovalTests: XCTestCase {
    func testRemovingAProfileRemovesItsAutomationFolderSoANewProfileOfTheSameNameStartsEmpty() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bs-wipe-\(UUID().uuidString)")
        let profile = "wipe-test-\(UUID().uuidString.prefix(8))"
        let folder = root.appendingPathComponent("automation/\(profile)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["clients.json", "remote-devices.json", "denied.json", "webhooks.json"] { try Data("[]".utf8).write(to: folder.appendingPathComponent(name)) }
        let other = root.appendingPathComponent("automation/other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: other.appendingPathComponent("clients.json"))
        AutomationController.wipe(profile: profile, root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.appendingPathComponent("clients.json").path), "another profile's data is not touched")
    }
}
