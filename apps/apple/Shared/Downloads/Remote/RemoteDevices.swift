import Foundation

// Paired devices.
//
// A device is an automation client (Phase 13) with a little more written down about it: so it has exactly the authorization every automation client has (one profile, scopes,
// durable revocation, a token that is hashed at rest, an event stream that is closed when it is withdrawn), and nothing is duplicated. What is added here is the device's own
// identity (a name, when it was paired, when it last connected, which credential generation) and the channel key that proves the connection is from that device.

enum RemoteDeviceKind: String, Codable, Sendable, CaseIterable { case phone, tablet, computer, other }

struct RemoteDevice: Codable, Identifiable, Equatable, Sendable {
    /// The same as the automation client's id.
    var id: String
    var name: String
    var kind: RemoteDeviceKind
    var profile: String
    var enrolledAt: Date
    var lastConnectedAt: Date?
    /// 1 at pairing; one more each time the credentials are rotated.
    var credentialVersion: Int
    var revokedAt: Date?
    var isActive: Bool { revokedAt == nil }
}

/// Where a device's channel key lives. Never the device list, never a log, never a diagnostic.
protocol DeviceKeyStore: AnyObject {
    func key(for device: String) -> Data?
    @discardableResult func set(_ key: Data?, for device: String) -> Bool
}

final class MemoryDeviceKeyStore: DeviceKeyStore {
    private var keys: [String: Data] = [:]
    var failWrites = false
    func key(for device: String) -> Data? { keys[device] }
    func set(_ key: Data?, for device: String) -> Bool {
        if failWrites { return false }
        keys[device] = key; return true
    }
}

final class KeychainDeviceKeyStore: DeviceKeyStore {
    private let service: String
    init(profile: String) { service = "com.browsersetu.remote.device." + profile }
    func key(for device: String) -> Data? { SecretStore.get(service: service, account: device) }
    func set(_ key: Data?, for device: String) -> Bool {
        if let key { return SecretStore.set(key, service: service, account: device) }
        return SecretStore.delete(service: service, account: device)          // the real result: a key that could not be deleted is not reported as gone
    }
}

/// The list of paired devices for one profile, saved atomically with owner-only permissions. Authorization lives in `AutomationClientStore`; if a device is listed here but its
/// client is gone, revoked or expired, the device cannot connect, whatever this list says.
@MainActor
final class RemoteDeviceStore: ObservableObject {
    static let maxDevices = 10
    @Published private(set) var devices: [RemoteDevice] = []
    @Published private(set) var storageProblem: String?
    /// The saved list could not be read: nothing is added until the person resets it (the unreadable file is kept aside, not overwritten).
    @Published private(set) var unreadable = false
    let keys: DeviceKeyStore
    private let file: URL?
    private let now: () -> Date

    init(file: URL?, keys: DeviceKeyStore, now: @escaping () -> Date = Date.init) {
        self.file = file; self.keys = keys; self.now = now
        load()
    }

    func device(_ id: String) -> RemoteDevice? { devices.first { $0.id == id } }
    var activeCount: Int { devices.filter(\.isActive).count }

    /// Adds a device and its key. Nothing is kept unless both were saved.
    func add(_ device: RemoteDevice, key: Data) -> Bool {
        guard !unreadable, activeCount < Self.maxDevices else { return false }
        guard keys.set(key, for: device.id) else { return false }
        let before = devices
        devices.append(device)
        if !save() { devices = before; keys.set(nil, for: device.id); return false }
        return true
    }

    /// The channel key is removed first, so a device that is revoked can no longer set up a channel even if saving the list then fails.
    func revoke(_ id: String) {
        keys.set(nil, for: id)
        guard let i = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[i].revokedAt = devices[i].revokedAt ?? now()
        _ = save()
    }

    func remove(_ id: String) {
        keys.set(nil, for: id)
        devices.removeAll { $0.id == id }
        _ = save()
    }

    /// New channel key and credential generation. The old key stops working only once the new one is stored.
    func rotateKey(_ id: String, newKey: Data) -> Bool {
        guard let i = devices.firstIndex(where: { $0.id == id && $0.isActive }) else { return false }
        let old = keys.key(for: id)
        guard keys.set(newKey, for: id) else { return false }
        devices[i].credentialVersion += 1
        if !save() { devices[i].credentialVersion -= 1; keys.set(old, for: id); return false }
        return true
    }

    /// Undoes `rotateKey` when the rest of a rotation could not be completed.
    func restoreKey(_ id: String, oldKey: Data) {
        guard let i = devices.firstIndex(where: { $0.id == id }) else { return }
        keys.set(oldKey, for: id)
        devices[i].credentialVersion = max(1, devices[i].credentialVersion - 1)
        _ = save()
    }

    /// Starts a fresh list after an unreadable one (the old file stays where it was put aside).
    func resetUnreadable() { unreadable = false; storageProblem = nil; _ = save() }

    func noteConnected(_ id: String) {
        guard let i = devices.firstIndex(where: { $0.id == id }) else { return }
        if let last = devices[i].lastConnectedAt, now().timeIntervalSince(last) < 60 { return }
        devices[i].lastConnectedAt = now()          // in memory: a convenience for the list, never worth a write
    }

    // MARK: Saving

    private func save() -> Bool {
        guard let file else { return true }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try AutomationJSON.encoder.encode(devices).write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            storageProblem = nil
            return true
        } catch {
            storageProblem = "The list of paired devices could not be saved."
            return false
        }
    }

    private func load() {
        guard let file, FileManager.default.fileExists(atPath: file.path) else { return }
        do { devices = try AutomationJSON.decoder.decode([RemoteDevice].self, from: try Data(contentsOf: file)) }
        catch {
            devices = []; unreadable = true
            storageProblem = "The list of paired devices could not be read; nobody is trusted until devices are paired again."
            try? FileManager.default.moveItem(at: file, to: file.deletingLastPathComponent().appendingPathComponent("remote-devices.unreadable-\(Int(now().timeIntervalSince1970)).json"))
        }
    }
}
