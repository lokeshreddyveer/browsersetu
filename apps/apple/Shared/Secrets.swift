import Foundation
import LocalAuthentication
import Security

/// Secrets kept in the system Keychain, available while the device is unlocked. Nothing here is written to the profile's own files or settings.
/// By default an item stays on this device. An item can instead be written as one iCloud Keychain carries to the person's other devices,
/// sealed end to end by Apple; reading and removing look in both places, so a secret is found whichever way it was kept.
enum SecretStore {
    enum Outcome { case synced, local, failed }

    private static func query(service: String, account: String?, cloud: Bool) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let account { q[kSecAttrAccount as String] = account }
        if cloud {
            q[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
            #if os(macOS)
            q[kSecUseDataProtectionKeychain as String] = true       // iCloud Keychain items live in the data protection keychain
            #endif
        }
        return q
    }

    /// Writes the secret, replacing any earlier copy in either place. With `synchronizable`, iCloud Keychain is tried first; when this copy of the app cannot use it,
    /// the secret is kept on this device instead and the result says so.
    @discardableResult
    static func put(_ data: Data, service: String, account: String, synchronizable: Bool = false) -> Outcome {
        remove(service: service, account: account)
        if synchronizable {
            var item = query(service: service, account: account, cloud: true)
            item[kSecAttrSynchronizable as String] = true
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            if SecItemAdd(item as CFDictionary, nil) == errSecSuccess { return .synced }
        }
        var item = query(service: service, account: account, cloud: false)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess ? .local : .failed
    }

    @discardableResult
    static func set(_ data: Data, service: String, account: String, synchronizable: Bool = false) -> Bool {
        put(data, service: service, account: account, synchronizable: synchronizable) != .failed
    }

    static func get(service: String, account: String) -> Data? {
        for cloud in [false, true] {
            var q = query(service: service, account: account, cloud: cloud)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            if SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data { return data }
        }
        return nil
    }

    @discardableResult
    private static func remove(service: String, account: String) -> Bool {
        let local = SecItemDelete(query(service: service, account: account, cloud: false) as CFDictionary)
        let cloud = SecItemDelete(query(service: service, account: account, cloud: true) as CFDictionary)
        return [local, cloud].allSatisfy { $0 == errSecSuccess || $0 == errSecItemNotFound }
    }

    /// The account names stored under a service, from both places.
    static func accounts(service: String) -> [String] {
        var names = Set<String>()
        for cloud in [false, true] {
            var q = query(service: service, account: nil, cloud: cloud)
            q[kSecReturnAttributes as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitAll
            var result: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let rows = result as? [[String: Any]] else { continue }
            rows.compactMap { $0[kSecAttrAccount as String] as? String }.forEach { names.insert($0) }
        }
        return names.sorted()
    }

    @discardableResult
    static func delete(service: String, account: String) -> Bool { remove(service: service, account: account) }

    static func deleteAll(service: String) {
        // On a Mac the system removes only the first match unless it is told to remove them all, which left every other saved item behind.
        for cloud in [false, true] {
            var q = query(service: service, account: nil, cloud: cloud)
            #if os(macOS)
            q[kSecMatchLimit as String] = kSecMatchLimitAll
            #endif
            SecItemDelete(q as CFDictionary)
        }
    }
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
