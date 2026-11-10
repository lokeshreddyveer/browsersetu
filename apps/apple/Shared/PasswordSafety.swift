import CryptoKit
import Foundation

// Keeping the password manager honest: which saved sign-ins look like duplicates, which sites the person said share one, and keeping plaintext passwords out of everything
// that is not the Keychain. Nothing here shows or stores a password: results are lists of sign-in ids (a website and a name).

/// What a look over the saved sign-ins found. Only ids; a password never leaves the function that compared it.
struct PasswordAuditReport: Equatable {
    /// Groups of sign-ins that share one password.
    var reused: [[String]] = []
    /// Sign-ins whose password is weak (see PasswordStrength).
    var weak: [String] = []
    /// Pairs of sign-ins with the same name on addresses of the same website (https://example.com and https://www.example.com): probably one account saved twice.
    var duplicates: [[String]] = []
    var isEmpty: Bool { reused.isEmpty && weak.isEmpty && duplicates.isEmpty }
}

enum PasswordAudit {
    static func analyze(_ logins: [WebLogin]) -> PasswordAuditReport {
        var report = PasswordAuditReport()
        // Reuse is found by comparing fingerprints made with a key that exists only for this call, so nothing that outlives it could be used to guess a password.
        let key = SymmetricKey(size: .bits256)
        var byFingerprint: [String: [String]] = [:]
        for login in logins where !login.password.isEmpty {
            let mac = HMAC<SHA256>.authenticationCode(for: Data(login.password.utf8), using: key)
            byFingerprint[Data(mac).base64EncodedString(), default: []].append(login.id)
            if PasswordStrength.evaluate(login.password, user: login.user).isWeak { report.weak.append(login.id) }
        }
        report.reused = byFingerprint.values.filter { $0.count > 1 }.map { $0.sorted() }.sorted { $0[0] < $1[0] }
        var bySite: [String: [WebLogin]] = [:]
        for login in logins { if let site = FaviconStore.key(forHost: URL(string: login.origin)?.host) { bySite[site + "\n" + login.user.lowercased(), default: []].append(login) } }
        report.duplicates = bySite.values.filter { $0.count > 1 && Set($0.map(\.origin)).count > 1 }.map { $0.map(\.id).sorted() }.sorted { $0[0] < $1[0] }
        report.weak.sort()
        return report
    }
}

extension WebLoginVault {
    /// Says that this sign-in also belongs to `other` (an https address). Refused for anything that is not a plain https origin, for its own address, and past five.
    @discardableResult
    static func associate(_ login: WebLogin, with other: String, profile: String) -> Bool {
        guard let origin = WebLoginOrigin.normalized(other), origin != login.origin, !login.related.contains(origin), login.related.count < WebLogin.maxRelated else { return false }
        var updated = login
        updated.related.append(origin)
        return save(updated, profile: profile)
    }

    static func dissociate(_ login: WebLogin, from origin: String, profile: String) {
        var updated = login
        updated.related.removeAll { $0 == origin }
        _ = save(updated, profile: profile)
    }

    /// Two saved copies of one account become one: the newer password is kept, and the older one's address is remembered as an address of the same sign-in.
    @discardableResult
    static func merge(_ a: WebLogin, _ b: WebLogin, profile: String) -> Bool {
        let (keep, drop) = a.saved >= b.saved ? (a, b) : (b, a)
        var merged = keep
        for origin in [drop.origin] + drop.related where origin != merged.origin && !merged.related.contains(origin) && merged.related.count < WebLogin.maxRelated { merged.related.append(origin) }
        guard save(merged, profile: profile) else { return false }
        forget(drop, profile: profile)
        return true
    }
}

// MARK: - Keeping passwords out of the sync ledger's stored copy

/// The sync ledger remembers what each device last had, so a change can be told from a copy. For saved passwords it must not keep the passwords themselves in the profile's
/// database: the stored copy holds a keyed fingerprint instead, and the real values are read back from the Keychain when the ledger is loaded.
enum SyncLedgerGuard {
    static let marker = "keyed-fingerprint:"

    private static func service(profile: String) -> String { "com.browsersetu.syncledger." + profile }

    /// The key the fingerprints are made with: random, per profile, kept in the Keychain on this device only.
    static func key(profile: String) -> SymmetricKey? {
        if let data = SecretStore.get(service: service(profile: profile), account: "key"), data.count == 32 { return SymmetricKey(data: data) }
        let fresh = SymmetricKey(size: .bits256)
        let data = fresh.withUnsafeBytes { Data($0) }
        return SecretStore.set(data, service: service(profile: profile), account: "key") ? fresh : nil
    }

    static func deleteKey(profile: String) { SecretStore.deleteAll(service: service(profile: profile)) }

    private static func keyedDigest(_ password: String, key: SymmetricKey) -> String {
        marker + Data(HMAC<SHA256>.authenticationCode(for: Data(password.utf8), using: key)).base64EncodedString()
    }

    /// The ledger as it is stored: no password in it.
    static func redacted(_ state: SyncState, profile: String) -> SyncState {
        guard !state.logins.isEmpty, let key = key(profile: profile) else { return state.logins.isEmpty ? state : SyncState(bookmarks: state.bookmarks, settings: state.settings, workspaces: state.workspaces, logins: [:], sessions: state.sessions, history: state.history) }
        var out = state
        out.logins = state.logins.mapValues { cell in
            guard var value = cell.value, !value.password.hasPrefix(marker) else { return cell }
            value.password = keyedDigest(value.password, key: key)
            return SyncCell(stamp: cell.stamp, value: value)
        }
        return out
    }

    /// The stored ledger made whole again: where a saved password still matches its fingerprint it is put back, so an unchanged sign-in is seen as unchanged.
    static func rehydrated(_ state: SyncState, current: [String: WebLogin], profile: String) -> SyncState {
        guard !state.logins.isEmpty, let key = key(profile: profile) else { return state }
        var out = state
        out.logins = state.logins.mapValues { cell in
            guard var value = cell.value, value.password.hasPrefix(marker) else { return cell }
            if let login = current[cell.value.map { WebLoginVault.account(origin: $0.origin, user: $0.user) } ?? ""], keyedDigest(login.password, key: key) == value.password { value.password = login.password }
            return SyncCell(stamp: cell.stamp, value: value)
        }
        return out
    }
}
