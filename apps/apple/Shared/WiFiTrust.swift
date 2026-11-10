import Foundation
import CryptoKit

/// Who is allowed to change this device's data over Wi-Fi.
///
/// The one-time code only gets a device onto the encrypted link. It says nothing about which device it is, and anyone who sees the code can claim to be any device. So
/// a snapshot is taken in only when the device that sent it (1) is not blocked, (2) was approved by the person, here, and (3) can prove it is the same device that
/// was approved: the first time, the device hands over a secret key and the person approves it; afterwards every snapshot carries a tag that only that key can make.
/// A code seen later by someone else is not enough to pose as an approved device.
protocol WiFiKeyStore: AnyObject {
    /// This device's own key. Made the first time it is needed.
    func ownSecret() -> Data
    func pinnedSecret(for deviceID: String) -> Data?
    func pin(_ secret: Data, for deviceID: String)
    func unpin(_ deviceID: String)
}

/// Keys kept in the Keychain, on this device only, one set per profile.
final class KeychainWiFiKeys: WiFiKeyStore {
    private let service: String
    init(profile: String) { service = "com.browsersetu.wifi-identity." + profile }

    func ownSecret() -> Data {
        if let existing = SecretStore.get(service: service, account: "self"), existing.count == 32 { return existing }
        let fresh = Data(SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) })
        SecretStore.set(fresh, service: service, account: "self")
        return fresh
    }
    func pinnedSecret(for deviceID: String) -> Data? { SecretStore.get(service: service, account: "peer:" + deviceID) }
    func pin(_ secret: Data, for deviceID: String) { SecretStore.set(secret, service: service, account: "peer:" + deviceID) }
    func unpin(_ deviceID: String) { SecretStore.delete(service: service, account: "peer:" + deviceID) }
}

/// Keys held in memory only: for tests, which must never touch the real Keychain.
final class MemoryWiFiKeys: WiFiKeyStore {
    private var own: Data?
    private var peers: [String: Data] = [:]
    func ownSecret() -> Data {
        if let own { return own }
        let fresh = Data(SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) })
        own = fresh
        return fresh
    }
    func pinnedSecret(for deviceID: String) -> Data? { peers[deviceID] }
    func pin(_ secret: Data, for deviceID: String) { peers[deviceID] = secret }
    func unpin(_ deviceID: String) { peers[deviceID] = nil }
}

enum WiFiTrust {
    enum Verdict: Equatable {
        case accept                  // an approved device that proved who it is
        case askToTrust              // a device the person has not approved yet (or approved only another way): ask, then remember its key
        case reject(String)          // never taken in; the text says why in plain words
    }

    /// What the tag covers: who sent it, which copy it is, when it was made, and the sync group. Changing any of them breaks the tag.
    private static func message(deviceID: String, seq: Int, created: Date, group: String?) -> Data {
        Data("\(deviceID)|\(seq)|\(Int(created.timeIntervalSince1970 * 1000))|\(group ?? "")".utf8)
    }

    static func tag(secret: Data, deviceID: String, seq: Int, created: Date, group: String?) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: message(deviceID: deviceID, seq: seq, created: created, group: group), using: SymmetricKey(data: secret))
        return Data(code).base64EncodedString()
    }

    private static func valid(_ proof: String, secret: Data, deviceID: String, seq: Int, created: Date, group: String?) -> Bool {
        guard let given = Data(base64Encoded: proof) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(given, authenticating: message(deviceID: deviceID, seq: seq, created: created, group: group), using: SymmetricKey(data: secret))
    }

    /// Puts this device's key and proof into a snapshot that is about to be sent.
    static func sign(_ snapshot: inout BackupPayload, secret: Data) {
        guard let id = snapshot.deviceID, let seq = snapshot.seq else { return }
        snapshot.wifiKey = secret.base64EncodedString()
        snapshot.wifiProof = tag(secret: secret, deviceID: id, seq: seq, created: snapshot.created, group: snapshot.syncGroup)
    }

    /// Decides what to do with a snapshot that arrived over Wi-Fi. Pure: no dialogs, no storage.
    static func judge(_ snapshot: BackupPayload, ownDeviceID: String, status: SyncDevice.Status?, pinned: Data?) -> Verdict {
        // An older copy of the app sends bookmarks only, with no proof of who it is and nothing to stop an old copy being replayed. Over Wi-Fi that is refused.
        guard snapshot.state != nil, let id = snapshot.deviceID, !id.isEmpty, let seq = snapshot.seq, let proof = snapshot.wifiProof else {
            return .reject("That device did not say who it is. Update Browser Setu on it, then try again.")
        }
        if id == ownDeviceID { return .reject("That is this same device.") }
        if status == .blocked { return .reject("You blocked that device, so its data was not taken in.") }
        if let pinned {
            guard valid(proof, secret: pinned, deviceID: id, seq: seq, created: snapshot.created, group: snapshot.syncGroup) else {
                return .reject("That device could not prove it is the one you approved, so nothing was taken in.")
            }
            return status == .approved ? .accept : .askToTrust
        }
        // Never seen over Wi-Fi: it must at least hold the key it hands over, and then the person decides.
        guard let key = snapshot.wifiKey.flatMap({ Data(base64Encoded: $0) }), key.count == 32,
              valid(proof, secret: key, deviceID: id, seq: seq, created: snapshot.created, group: snapshot.syncGroup) else {
            return .reject("That device's identity could not be checked, so nothing was taken in.")
        }
        return .askToTrust
    }
}
