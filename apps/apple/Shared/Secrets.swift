import Foundation
import LocalAuthentication
import Security

/// Secrets kept in the system Keychain, on this device only, available while the device is unlocked. Nothing here is written to the
/// profile's own files or settings.
enum SecretStore {
    private static func query(service: String, account: String?) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let account { q[kSecAttrAccount as String] = account }
        return q
    }

    @discardableResult
    static func set(_ data: Data, service: String, account: String) -> Bool {
        SecItemDelete(query(service: service, account: account) as CFDictionary)
        var item = query(service: service, account: account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func get(service: String, account: String) -> Data? {
        var q = query(service: service, account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess ? result as? Data : nil
    }

    /// The account names stored under a service.
    static func accounts(service: String) -> [String] {
        var q = query(service: service, account: nil)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let rows = result as? [[String: Any]] else { return [] }
        return rows.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    @discardableResult
    static func delete(service: String, account: String) -> Bool {
        let status = SecItemDelete(query(service: service, account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func deleteAll(service: String) { SecItemDelete(query(service: service, account: nil) as CFDictionary) }
}

/// The whole of what a website's sign-in box belongs to: how it was reached, which machine and port, which realm, how it asked, and whether it is a
/// proxy's box. A saved sign-in is only ever offered back to exactly this, never to the same host name on another scheme or port.
struct SignInSpace: Equatable, Hashable {
    var scheme: String
    var host: String
    var port: Int
    var realm: String
    var method: String
    var isProxy: Bool

    /// Passwords are only filled in on their own over HTTPS, and never for a proxy.
    var allowsAutomatic: Bool { scheme.lowercased() == "https" && !isProxy }

    var key: String { [isProxy ? "proxy" : "server", scheme.lowercased(), host.lowercased() + ":" + String(port), method, realm].joined(separator: "|") }
}

/// Sign-in names and passwords for websites' own sign-in boxes (HTTP authentication), kept in the Keychain separately for each profile,
/// and only when the user chooses Remember. Private tabs never read, write or delete here.
enum SignInVault {
    struct Entry: Codable, Equatable {
        var host: String; var realm: String; var user: String; var password: String
        /// Present on entries saved with the full protection space; entries saved by older versions lack them and are never offered automatically.
        var scheme: String?; var port: Int?; var method: String?; var proxy: Bool?
        /// The Keychain account this entry lives under (not stored inside it).
        var account = ""

        enum CodingKeys: String, CodingKey { case host, realm, user, password, scheme, port, method, proxy }

        var isCurrentFormat: Bool { scheme != nil && port != nil }
    }

    static func service(profile: String) -> String { "com.browsersetu.signin." + profile }

    static func saved(space: SignInSpace, profile: String) -> Entry? {
        guard space.allowsAutomatic else { return nil }
        return SecretStore.get(service: service(profile: profile), account: space.key).flatMap { try? JSONDecoder().decode(Entry.self, from: $0) }
    }

    @discardableResult
    static func remember(space: SignInSpace, user: String, password: String, profile: String) -> Bool {
        guard space.allowsAutomatic, !user.isEmpty,
              let data = try? JSONEncoder().encode(Entry(host: space.host.lowercased(), realm: space.realm, user: user, password: password,
                                                         scheme: space.scheme.lowercased(), port: space.port, method: space.method, proxy: space.isProxy)) else { return false }
        return SecretStore.set(data, service: service(profile: profile), account: space.key)
    }

    static func forget(space: SignInSpace, profile: String) { SecretStore.delete(service: service(profile: profile), account: space.key) }

    static func forget(account: String, profile: String) { SecretStore.delete(service: service(profile: profile), account: account) }

    /// What is saved for the profile, without the passwords.
    static func list(profile: String) -> [Entry] {
        SecretStore.accounts(service: service(profile: profile)).compactMap { account in
            SecretStore.get(service: service(profile: profile), account: account).flatMap { try? JSONDecoder().decode(Entry.self, from: $0) }.map {
                var entry = $0
                entry.password = ""
                entry.account = account
                return entry
            }
        }
    }

    static func removeAll(profile: String) { SecretStore.deleteAll(service: service(profile: profile)) }
}

/// Touch ID, Face ID or the device passcode, through the system's own sheet.
enum BiometricGate {
    /// Tests set this to answer without showing anything.
    @MainActor static var testAnswer: Bool?

    @MainActor
    static func authenticate(reason: String) async -> Bool {
        if let testAnswer { return testAnswer }
        if testAvailability == false { return false }
        let context = LAContext()
        var error: NSError?
        // No way to authenticate (no passcode set, or the system cannot ask) means no: a lock that opens by itself protects nothing.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    /// Whether the system can ask for Touch ID, Face ID or the device passcode right now.
    @MainActor static var isAvailable: Bool {
        if let testAvailability { return testAvailability }
        if testAnswer != nil { return true }
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    /// Tests set this to pretend the device cannot authenticate.
    @MainActor static var testAvailability: Bool?
}

extension BrowserModel {
    /// Gates a sensitive change behind the device's authentication, when the user has turned that on. A success counts for a minute, so
    /// a run of related changes asks once.
    func requireAuthentication(_ reason: String) async -> Bool {
        guard lockSensitiveSettings else { return true }
        if Date().timeIntervalSince(lastAuthentication) < 60 { return true }
        let ok = await BiometricGate.authenticate(reason: reason)
        if ok { lastAuthentication = Date() }
        return ok
    }

    /// Turning the lock on or off asks for authentication itself, so someone else cannot simply turn it off.
    func setLockSensitiveSettings(_ on: Bool) async {
        guard on != lockSensitiveSettings else { return }
        // Turning the lock on needs something to authenticate with. Turning it off when the device can no longer authenticate is allowed, so a
        // removed passcode can never leave the settings shut for good.
        if on, !BiometricGate.isAvailable { notice = "Set a passcode on this device first. The lock opens with Touch ID, Face ID or the passcode."; return }
        if !on, !BiometricGate.isAvailable { lockSensitiveSettings = false; return }
        guard await BiometricGate.authenticate(reason: on ? "Turn on the lock for sensitive settings" : "Turn off the lock for sensitive settings") else { return }
        lastAuthentication = Date()
        lockSensitiveSettings = on
    }
}
