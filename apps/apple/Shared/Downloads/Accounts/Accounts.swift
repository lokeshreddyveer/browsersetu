import Foundation
import Security

// Website accounts for downloads.
//
// What this is: a list, per browser profile, of sites the person has chosen to give a credential to for downloads the app makes ITSELF (an address typed or pasted into Add Download).
// What it is not: a login robot. It never reads a login form, never sees a password typed into a page, never handles one-time codes, and never exports the browser's cookies or session.
// A download started from a signed-in page keeps using WebKit and that page's own session (Phase 12), untouched.
//
// A credential is sent only to the exact website it was given for, only over https, only for the person's own request, only in the `Authorization` header, and is dropped by the existing
// redirect rules the moment a redirect leaves that website. It is never saved in a task, a log, a diagnostic or the settings list; the secret itself is in the Keychain, on this device only.

enum AccountMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    /// No stored secret: the website is used through the browser's own signed-in session. Listed so the person can see it and so a link on that site is explained.
    case webSession
    /// A user name and password the person typed for HTTP Basic authentication (sent only over https).
    case httpBasic
    /// An API token the person created at the website (sent as a bearer token).
    case apiToken
    var id: String { rawValue }
    var title: String {
        switch self { case .webSession: "Signed-in browser session"; case .httpBasic: "User name and password (HTTP Basic)"; case .apiToken: "API token" }
    }
    var storesSecret: Bool { self != .webSession }
}

enum AccountState: String, Codable, Sendable {
    case valid, expired, reauthRequired, revoked, disconnected, temporaryFailure, unavailable
    var title: String {
        switch self {
        case .valid: "Connected"
        case .expired: "Expired"
        case .reauthRequired: "Sign-in needed again"
        case .revoked: "Revoked"
        case .disconnected: "Disconnected"
        case .temporaryFailure: "Temporarily failing"
        case .unavailable: "Keychain unavailable"
        }
    }
}

struct WebsiteAccount: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var profile: String
    /// Shown to the person.
    var name: String
    /// The exact website: a lower-case host name, nothing else (no scheme, path or wildcard).
    var host: String
    /// Only when it is not the https default.
    var port: Int?
    var method: AccountMethod
    /// For HTTP Basic: the user name (not secret). The password is in the Keychain.
    var username: String?
    var state: AccountState
    var createdAt: Date
    var lastValidatedAt: Date?
    /// When the person said the credential runs out (an API token with an end date).
    var expiresAt: Date?
    /// A short plain sentence, never containing a secret.
    var lastError: String?
    /// When the credential last changed (added or reconnected). A refusal for a request started before this says nothing about the credential in place now.
    var credentialChangedAt: Date?
}

// MARK: - Secrets

enum AccountSecretRead: Equatable { case value(Data), missing, unavailable }

protocol AccountSecretStore: AnyObject, Sendable {
    func read(_ account: String) -> AccountSecretRead
    @discardableResult func write(_ secret: Data, for account: String) -> Bool
    @discardableResult func delete(_ account: String) -> Bool
}

final class MemoryAccountSecretStore: AccountSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    var unavailable = false
    var failWrites = false
    func read(_ account: String) -> AccountSecretRead { lock.lock(); defer { lock.unlock() }; if unavailable { return .unavailable }; return values[account].map { .value($0) } ?? .missing }
    func write(_ secret: Data, for account: String) -> Bool { lock.lock(); defer { lock.unlock() }; if failWrites || unavailable { return false }; values[account] = secret; return true }
    func delete(_ account: String) -> Bool { lock.lock(); defer { lock.unlock() }; values[account] = nil; return true }
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
}

/// The macOS Keychain, this device only. A locked or refused Keychain is reported as unavailable, not as "no secret", so the account is not wrongly declared signed out.
final class KeychainAccountSecretStore: AccountSecretStore, @unchecked Sendable {
    private let service: String
    init(profile: String) { service = "com.browsersetu.downloads.account." + profile }

    private func query(_ account: String) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        #if os(macOS)
        q[kSecUseDataProtectionKeychain as String] = true
        #endif
        return q
    }

    func read(_ account: String) -> AccountSecretRead {
        var q = query(account)
        q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        switch SecItemCopyMatching(q as CFDictionary, &result) {
        case errSecSuccess: return (result as? Data).map { .value($0) } ?? .missing
        case errSecItemNotFound: return .missing
        default: return .unavailable
        }
    }

    func write(_ secret: Data, for account: String) -> Bool {
        // Update in place when the item exists, so a failure leaves the old credential exactly as it was; add only when there is none.
        let update = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: secret] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var item = query(account)
        item[kSecValueData as String] = secret
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly          // never synced to iCloud Keychain
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    func delete(_ account: String) -> Bool {
        let status = SecItemDelete(query(account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

// MARK: - Routing

/// What may happen to a request for an address, given the accounts. Thread-safe; the transfer engines ask it from their own queues.
final class AccountRouter: @unchecked Sendable {
    enum Refusal: String, Equatable, Sendable {
        case insecure, expired, reauthRequired, revoked, temporaryFailure, secretMissing, keychainUnavailable, ambiguous
        var message: String {
            switch self {
            case .insecure: "This website has an account, but it is only used over https."
            case .expired: "The account for this website has expired. Reconnect it in Settings."
            case .reauthRequired: "The website refused this account's credentials. Reconnect it in Settings."
            case .revoked: "This account was revoked."
            case .temporaryFailure: "The account for this website is failing right now. Check it in Settings."
            case .secretMissing: "The saved credential for this account is missing. Reconnect it in Settings."
            case .keychainUnavailable: "The Keychain is locked or unavailable, so this account cannot be used right now."
            case .ambiguous: "More than one account matches this website. Remove one in Settings."
            }
        }
    }

    enum Decision: Equatable, Sendable {
        /// No account applies: the request goes out as it always did.
        case none
        /// Send this Authorization value, from this account.
        case use(account: String, header: String)
        /// An account applies but cannot be used: the download is stopped with the reason rather than sent without it (a login page saved as the file) or with another account.
        case refused(Refusal, account: String?)
    }

    /// Tests only: allow an account to be used over plain http (the local fixture server has no TLS).
    nonisolated(unsafe) static var allowPlainHTTPForTests = false

    private let lock = NSLock()
    private var accounts: [WebsiteAccount] = []
    private let secrets: AccountSecretStore
    private let now: () -> Date

    init(secrets: AccountSecretStore, now: @escaping () -> Date = Date.init) { self.secrets = secrets; self.now = now }

    func update(_ list: [WebsiteAccount]) { lock.lock(); accounts = list; lock.unlock() }

    func decide(_ url: URL, origin: DownloadRequestOrigin, isPrivate: Bool = false) -> Decision {
        guard origin == .user, !isPrivate, let host = url.host?.lowercased() else { return .none }
        lock.lock(); let candidates = accounts.filter { $0.method.storesSecret && $0.state != .disconnected && $0.host == host }; lock.unlock()
        let port = url.port ?? 443          // the same website whichever scheme was typed: http to it is refused below, not treated as a different place
        let matching = candidates.filter { ($0.port ?? 443) == port }
        guard !matching.isEmpty else { return .none }
        guard matching.count == 1, let account = matching.first else { return .refused(.ambiguous, account: nil) }
        guard url.scheme == "https" || Self.allowPlainHTTPForTests else { return .refused(.insecure, account: account.id) }
        switch account.state {
        case .expired: return .refused(.expired, account: account.id)
        case .reauthRequired: return .refused(.reauthRequired, account: account.id)
        case .revoked: return .refused(.revoked, account: account.id)
        case .temporaryFailure: return .refused(.temporaryFailure, account: account.id)
        case .unavailable: return .refused(.keychainUnavailable, account: account.id)
        case .disconnected: return .none
        case .valid: break
        }
        if let end = account.expiresAt, end <= now() { return .refused(.expired, account: account.id) }
        switch secrets.read(account.id) {
        case .unavailable: return .refused(.keychainUnavailable, account: account.id)
        case .missing: return .refused(.secretMissing, account: account.id)
        case .value(let data):
            guard let header = Self.header(method: account.method, username: account.username, secret: data) else { return .refused(.secretMissing, account: account.id) }
            return .use(account: account.id, header: header)
        }
    }

    /// The Authorization value, or nil when the secret is not something that can be sent safely.
    static func header(method: AccountMethod, username: String?, secret: Data) -> String? {
        guard let text = String(data: secret, encoding: .utf8) else { return nil }
        switch method {
        case .apiToken:
            guard AccountValidation.isSafeToken(text) else { return nil }
            return "Bearer " + text
        case .httpBasic:
            guard let username, AccountValidation.isSafeUsername(username), AccountValidation.isSafePassword(text) else { return nil }
            return "Basic " + Data("\(username):\(text)".utf8).base64EncodedString()
        case .webSession: return nil
        }
    }
}

enum AccountValidation {
    /// A host name and nothing else.
    static func normalizedHost(_ raw: String) -> String? {
        let h = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !h.isEmpty, h.count <= 253, !h.contains("*") else { return nil }
        guard h.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ) }), !h.hasPrefix("."), !h.hasSuffix("."), !h.hasPrefix("-"), !h.contains("..") else { return nil }
        return h
    }
    static func isSafeToken(_ t: String) -> Bool { !t.isEmpty && t.utf8.count <= 4096 && t.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7F } }
    static func isSafeUsername(_ t: String) -> Bool { !t.isEmpty && t.utf8.count <= 256 && !t.contains(":") && t.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F } }
    static func isSafePassword(_ t: String) -> Bool { !t.isEmpty && t.utf8.count <= 1024 && t.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F } }
}

// MARK: - The list

@MainActor
final class AccountStore: ObservableObject {
    static let maxAccounts = 50
    @Published private(set) var accounts: [WebsiteAccount] = []
    @Published private(set) var storageProblem: String?
    /// The saved list could not be read. It is kept aside, nothing is added until the person resets, and no download that was using an account is sent without it.
    @Published private(set) var unreadable = false
    /// Told when a credential is withdrawn (disconnect, delete, refusal): transfers running with it are stopped.
    var onWithdrawn: (String, Int?) -> Void = { _, _ in }
    let profile: String
    let router: AccountRouter
    private let secrets: AccountSecretStore
    private let file: URL?
    private let now: () -> Date

    init(profile: String, file: URL?, secrets: AccountSecretStore, now: @escaping () -> Date = Date.init) {
        self.profile = profile; self.file = file; self.secrets = secrets; self.now = now
        router = AccountRouter(secrets: secrets, now: now)
        load()
        publish()
    }

    enum Outcome: Equatable { case ok(String), refused(String) }

    func account(_ id: String) -> WebsiteAccount? { accounts.first { $0.id == id } }

    /// Adds an account. The secret is stored first; if that fails nothing is added. One account per website.
    func add(name: String, host rawHost: String, port: Int? = nil, method: AccountMethod, username: String? = nil, secret: String? = nil, expiresAt: Date? = nil) -> Outcome {
        guard let host = AccountValidation.normalizedHost(rawHost) else { return .refused("Enter just the website's name, such as files.example.com.") }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 60 else { return .refused("Give the account a short name.") }
        if let port, !(1...65535).contains(port) { return .refused("That port is not valid.") }
        guard !unreadable else { return .refused("The saved account list could not be read. Reset it first.") }
        guard accounts.count < Self.maxAccounts else { return .refused("Too many accounts. Delete some first.") }
        guard !accounts.contains(where: { $0.host == host && ($0.port ?? 443) == (port ?? 443) && $0.state != .disconnected }) else {
            return .refused("There is already an account for this website. Reconnect or delete it first.")
        }
        let id = RemoteCrypto.random(8).map { $0.map { String(format: "%02x", $0) }.joined() } ?? String(UUID().uuidString.prefix(16)).lowercased()
        if method.storesSecret {
            guard let secret, let data = Optional(Data(secret.utf8)), Self.secretOK(method, username: username, secret: secret) else { return .refused(method == .httpBasic ? "Enter a user name (no colon) and a password." : "Enter the token exactly as the website gave it.") }
            guard secrets.write(data, for: id) else { return .refused("The Keychain would not save the credential, so the account was not added.") }
        }
        let account = WebsiteAccount(id: id, profile: profile, name: clean, host: host, port: port, method: method, username: method == .httpBasic ? username : nil, state: .valid, createdAt: now(), lastValidatedAt: nil, expiresAt: expiresAt, lastError: nil, credentialChangedAt: now())
        let before = accounts
        accounts.append(account)
        if !save() { accounts = before; secrets.delete(id); return .refused("The account list could not be saved, so the account was not added.") }
        publish()
        return .ok(id)
    }

    private static func secretOK(_ method: AccountMethod, username: String?, secret: String) -> Bool {
        AccountRouter.header(method: method, username: username, secret: Data(secret.utf8)) != nil
    }

    /// A new credential for an existing account (after it expired or was refused). The old one stays until the new one is stored.
    func reconnect(_ id: String, username: String? = nil, secret: String, expiresAt: Date? = nil) -> Outcome {
        guard let i = accounts.firstIndex(where: { $0.id == id }), accounts[i].method.storesSecret else { return .refused("No such account.") }
        let user = accounts[i].method == .httpBasic ? (username ?? accounts[i].username) : nil
        guard Self.secretOK(accounts[i].method, username: user, secret: secret) else { return .refused("That credential cannot be used.") }
        guard secrets.write(Data(secret.utf8), for: id) else { return .refused("The Keychain would not save the credential. The account is unchanged.") }
        let before = accounts[i]
        accounts[i].username = user; accounts[i].state = .valid; accounts[i].lastError = nil; accounts[i].expiresAt = expiresAt; accounts[i].credentialChangedAt = now()
        if !save() { accounts[i] = before; return .refused("The account list could not be saved.") }
        publish()
        return .ok(id)
    }

    /// Forgets the credential but keeps the entry, so the person can reconnect it.
    func disconnect(_ id: String) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        secrets.delete(id)
        accounts[i].state = .disconnected; accounts[i].lastError = nil
        let host = accounts[i].host, port = accounts[i].port
        _ = save(); publish()
        onWithdrawn(host, port)
    }

    func delete(_ id: String) {
        let gone = accounts.first { $0.id == id }
        secrets.delete(id)
        accounts.removeAll { $0.id == id }
        _ = save(); publish()
        if let gone, gone.method.storesSecret { onWithdrawn(gone.host, gone.port) }
    }

    /// The website refused the credential (401): the account needs signing in again, and nothing is retried with it.
    func authorizationRefused(account id: String, requestStarted: Date? = nil) {
        guard let i = accounts.firstIndex(where: { $0.id == id }), accounts[i].state == .valid else { return }
        // A refusal of a request that began before the credential was last changed is about the old credential, not this one.
        if let started = requestStarted, let changed = accounts[i].credentialChangedAt, started < changed { return }
        accounts[i].state = .reauthRequired; accounts[i].lastError = "The website refused these credentials."
        let host = accounts[i].host, port = accounts[i].port
        _ = save(); publish()
        onWithdrawn(host, port)
    }

    /// A download with this account completed: the credential demonstrably works.
    func validated(account id: String) {
        guard let i = accounts.firstIndex(where: { $0.id == id }), accounts[i].state == .valid else { return }
        accounts[i].lastValidatedAt = now()
        _ = save(); publish()
    }

    /// Moves a credential past its end date into the expired state (so it is shown as such and stops being used).
    func refreshExpiry() {
        var changed = false
        for i in accounts.indices where accounts[i].state == .valid {
            if let end = accounts[i].expiresAt, end <= now() { accounts[i].state = .expired; accounts[i].lastError = "The credential's end date has passed."; changed = true }
        }
        if changed { _ = save(); publish() }
    }

    /// The Keychain says whether each stored credential can be read; one that cannot is shown as unavailable, never as signed out.
    func checkKeychain() {
        var changed = false
        for i in accounts.indices where accounts[i].method.storesSecret && accounts[i].state == .valid {
            if secrets.read(accounts[i].id) == .unavailable { accounts[i].state = .unavailable; accounts[i].lastError = "The Keychain is locked or unavailable."; changed = true }
        }
        for i in accounts.indices where accounts[i].state == .unavailable {
            if secrets.read(accounts[i].id) != .unavailable { accounts[i].state = .valid; accounts[i].lastError = nil; changed = true }
        }
        if changed { _ = save(); publish() }
    }

    // What a download suggestion says about an address.
    enum Hint: Equatable {
        case none
        case connected(String)
        case signInAgain(String)
        case expired(String)
        case sessionOnly(String)
        case unsupported(String)
    }

    func hint(for url: URL) -> Hint {
        guard let host = url.host?.lowercased() else { return .none }
        guard let a = accounts.first(where: { $0.host == host && ($0.port ?? 443) == (url.port ?? 443) && $0.state != .disconnected }) else { return .none }
        if a.method == .webSession { return .sessionOnly(a.name) }
        if url.scheme != "https" { return .unsupported(a.name) }
        switch a.state {
        case .valid: return .connected(a.name)
        case .expired: return .expired(a.name)
        case .reauthRequired, .revoked, .temporaryFailure, .unavailable: return .signInAgain(a.name)
        case .disconnected: return .none
        }
    }

    /// Starts a new list after an unreadable one (the old file stays where it was put aside).
    func resetUnreadable() { unreadable = false; storageProblem = nil; _ = save() }

    /// Everything of a removed profile: its credentials in the Keychain and its list on disk. Without this a profile created later under the same name would inherit them.
    static func wipe(profile: String, folder: URL, secrets: AccountSecretStore) {
        let file = folder.appendingPathComponent("accounts.json")
        if let data = try? Data(contentsOf: file), let list = try? AutomationJSON.decoder.decode([WebsiteAccount].self, from: data) {
            for a in list where a.profile == profile { secrets.delete(a.id) }
        }
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Saving

    private func publish() { router.update(accounts) }

    private func save() -> Bool {
        guard let file else { return true }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try AutomationJSON.encoder.encode(accounts).write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            storageProblem = nil
            return true
        } catch { storageProblem = "The account list could not be saved."; return false }
    }

    private func load() {
        guard let file, FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let list = try AutomationJSON.decoder.decode([WebsiteAccount].self, from: try Data(contentsOf: file))
            accounts = list.filter { $0.profile == profile }          // another profile's entries are never used here
        } catch {
            accounts = []; unreadable = true
            storageProblem = "The account list could not be read, so no account is used until they are added again."
            try? FileManager.default.moveItem(at: file, to: file.deletingLastPathComponent().appendingPathComponent("accounts.unreadable-\(Int(now().timeIntervalSince1970)).json"))
        }
    }
}
