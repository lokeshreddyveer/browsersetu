import Foundation

/// What must never be undone, kept apart from the client list: a client that was revoked, or the most a client may now do. It is a few bytes in a place of its own (a separate
/// file and the Keychain), so it can be saved when the larger list cannot, and it is applied on every start AFTER the list is read, so a stale list can never override it.
struct DenyRecord: Codable, Equatable {
    var revoked: Bool
    /// The most this client may do after a reduction. nil means no cap.
    var scopeCap: [AutomationScope]?
    var at: Date
}

protocol AuthorizationDenyStore: AnyObject {
    /// Empty when nothing was ever saved. Throws when something is there but cannot be read: that is "uncertain", and uncertain means closed.
    func read() throws -> [String: DenyRecord]
    func write(_ records: [String: DenyRecord]) throws
    /// Sets the stored records aside (never deletes them outright) so a fresh start is possible after they proved unreadable.
    func setAside() throws
}

final class FileDenyStore: AuthorizationDenyStore {
    private let file: URL
    init(file: URL) { self.file = file }
    func read() throws -> [String: DenyRecord] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        return try AutomationJSON.decoder.decode([String: DenyRecord].self, from: try Data(contentsOf: file))
    }
    func write(_ records: [String: DenyRecord]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try AutomationJSON.encoder.encode(records).write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func setAside() throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try FileManager.default.moveItem(at: file, to: file.deletingLastPathComponent().appendingPathComponent("denied.unreadable-\(Int(Date().timeIntervalSince1970)).json"))
    }
}

/// The same records in the macOS Keychain, a different storage mechanism from the file, so one kind of failure does not take both down.
final class KeychainBackedDenyStore: AuthorizationDenyStore {
    private let service: String
    init(profile: String) { service = "com.browsersetu.automation.deny." + profile }
    func read() throws -> [String: DenyRecord] {
        guard let data = SecretStore.get(service: service, account: "records") else { return [:] }
        return try AutomationJSON.decoder.decode([String: DenyRecord].self, from: data)
    }
    func write(_ records: [String: DenyRecord]) throws {
        struct Refused: Error {}
        guard SecretStore.set(try AutomationJSON.encoder.encode(records), service: service, account: "records") else { throw Refused() }
    }
    func setAside() throws { _ = SecretStore.delete(service: service, account: "records") }
}

/// The result of a change to who may use the service.
enum ClientCommit: Equatable {
    /// Written to disk and, for a restriction, in force.
    case committed
    /// The change that makes access *narrower* (revoke, remove, fewer permissions) is in force for as long as the app runs, but could not be saved. Until it is saved, a restart
    /// could bring the old access back, so the person is told and the save is retried.
    case restrictedButNotSaved(String)
    /// A change that would make access *wider* (a new client, a new secret, more permissions) is not made unless it can be saved. Nothing changed.
    case refused(String)
}

/// The clients allowed to use the automation service. Only a hash of each secret is kept (on disk, atomically, readable by the owner only); the secret itself is shown once.
///
/// Fails closed. A change that grants access is made only after it is saved. A change that withdraws access takes effect at once in memory, is never reported as done unless it
/// was saved, and is retried until it is. A client list that exists but cannot be read admits nobody.
@MainActor
final class AutomationClientStore: ObservableObject {
    @Published private(set) var clients: [AutomationClient] = []
    /// Why the client list cannot be trusted or saved right now (nil when it can). Never contains a secret.
    @Published private(set) var storageProblem: String?
    private let file: URL?
    private let now: () -> Date
    private let writer: (Data, URL) throws -> Void
    private let denyStores: [AuthorizationDenyStore]
    private var denies: [String: DenyRecord] = [:]
    private var unreadable = false
    /// A deny record exists but could not be read. Nothing may be written over it until the person resets: it might hold a revocation that only it remembers.
    private var denyReadFailed = false
    /// No deny record could be saved for a withdrawal: nobody is admitted until one can be, because a restart could otherwise bring the old access back.
    private var lockdown = false
    private var unsaved = false
    private var lastRetry = Date.distantPast
    static let maxClients = 20
    /// Told when a client's secret, permissions or standing change, so anything open for it (an event stream) is closed and must authenticate again.
    var onInvalidate: ((String) -> Void)?

    /// `file` nil keeps everything in memory (private sessions, tests). `writer` can be replaced to simulate a disk that refuses writes.
    init(file: URL?, now: @escaping () -> Date = Date.init, writer: ((Data, URL) throws -> Void)? = nil, denyStores: [AuthorizationDenyStore]? = nil) {
        self.file = file; self.now = now
        self.writer = writer ?? Self.atomicWrite
        // A store with a file always has the separate deny file; callers add the Keychain on top.
        self.denyStores = denyStores ?? (file.map { [FileDenyStore(file: $0.deletingLastPathComponent().appendingPathComponent("denied.json"))] } ?? [])
        load()
    }

    var isLockedDown: Bool { lockdown }

    var isReadable: Bool { !unreadable }
    var hasUnsavedRestrictions: Bool { unsaved }

    enum Enrolment: Equatable { case created(AutomationClient, token: String); case refused(String) }

    func enrol(name: String, profile: String, scopes: Set<AutomationScope>, validFor: TimeInterval? = nil) -> Enrolment {
        guard !unreadable else { return .refused("The saved client list could not be read, so no one can be added. Reset it first.") }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 60, clean.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else { return .refused("Give the client a short plain name.") }
        guard !scopes.isEmpty else { return .refused("Choose at least one permission.") }
        guard clients.filter({ $0.revokedAt == nil }).count < Self.maxClients, clients.count < Self.maxClients * 5 else { return .refused("Too many clients. Remove some, including revoked ones, first.") }
        var id = String(AgentHTTP.makeToken().prefix(8))
        while clients.contains(where: { $0.id == id }) { id = String(AgentHTTP.makeToken().prefix(8)) }          // never the same id as any client, revoked ones included
        let secret = AgentHTTP.makeToken()
        let client = AutomationClient(id: id, name: clean, profile: profile, scopes: scopes, createdAt: now(), expiresAt: validFor.map { now().addingTimeInterval($0) },
                                      revokedAt: nil, lastUsedAt: nil, tokenHash: Self.hash(secret))
        let before = clients
        clients.append(client)
        if case .failed(let why) = persist() { clients = before; return .refused("The new client could not be saved, so it was not created. \(why)") }
        return .created(client, token: "bsat_\(id)_\(secret)")
    }

    enum AuthResult: Equatable { case ok(AutomationClient); case failed }

    /// Same cost whether or not the client exists, so timing says nothing about which part was wrong.
    func authenticate(_ token: String) -> AuthResult {
        retryPendingSave()
        let parts = token.split(separator: "_", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        let hasShape = parts.count == 3 && parts[0] == "bsat" && parts[1].count == 8 && parts[2].count == 64
        let client = hasShape ? clients.first(where: { $0.id == parts[1] }) : nil
        let expected = client?.tokenHash ?? String(repeating: "0", count: 64)
        let given = Self.hash(hasShape ? parts[2] : "")
        let same = AgentHTTP.constantTimeEqual(given, expected)
        // A client list that could not be read admits nobody: it cannot be known who was revoked.
        guard !unreadable, !lockdown, hasShape, same, let client, client.isActive(at: now()) else { return .failed }
        return .ok(client)
    }

    /// Remembers that a client was just used. In memory only: it is a convenience for the list, never worth a write, and it can never carry a stale or half-saved list to disk.
    func touch(_ id: String) {
        guard !unreadable, let i = clients.firstIndex(where: { $0.id == id }) else { return }
        if let last = clients[i].lastUsedAt, now().timeIntervalSince(last) < 60 { return }
        clients[i].lastUsedAt = now()
    }

    /// A new secret. The old one stops working only once the new one is saved, so a failed save leaves things exactly as they were.
    func rotate(_ id: String) -> (token: String?, commit: ClientCommit) {
        guard !unreadable else { return (nil, .refused("The saved client list could not be read.")) }
        guard let i = clients.firstIndex(where: { $0.id == id && $0.revokedAt == nil }) else { return (nil, .refused("No such client.")) }
        let old = clients[i].tokenHash
        let secret = AgentHTTP.makeToken()
        clients[i].tokenHash = Self.hash(secret)
        if case .failed(let why) = persist() { clients[i].tokenHash = old; return (nil, .refused("The new token could not be saved, so the old one still works. \(why)")) }
        onInvalidate?(id)
        return ("bsat_\(id)_\(secret)", .committed)
    }

    @discardableResult
    func revoke(_ id: String) -> ClientCommit {
        guard let i = clients.firstIndex(where: { $0.id == id }) else { return .committed }
        // Already revoked: "committed" is only true if what is on disk says so too. A second try after a failed save saves again.
        if clients[i].revokedAt != nil { return (unsaved || lockdown) ? restriction(id, revoked: true, scopeCap: nil) : .committed }
        clients[i].revokedAt = now()
        onInvalidate?(id)
        return restriction(id, revoked: true, scopeCap: nil)
    }

    @discardableResult
    func remove(_ id: String) -> ClientCommit {
        guard clients.contains(where: { $0.id == id }) else { return .committed }
        // Not forgotten until the removal is saved: a client that is gone from memory but not from disk would come back after a restart. Until then it is only revoked.
        if let i = clients.firstIndex(where: { $0.id == id }), clients[i].revokedAt == nil { clients[i].revokedAt = now() }
        let snapshot = clients
        clients.removeAll { $0.id == id }
        onInvalidate?(id)
        let result = restriction(id, revoked: true, scopeCap: nil)
        if case .restrictedButNotSaved = result { clients = snapshot }
        return result
    }

    @discardableResult
    func setScopes(_ id: String, _ scopes: Set<AutomationScope>) -> ClientCommit {
        guard !scopes.isEmpty, let i = clients.firstIndex(where: { $0.id == id }) else { return .refused("Choose at least one permission.") }
        let old = clients[i].scopes
        let widens = !scopes.isSubset(of: old)
        clients[i].scopes = scopes
        if widens {
            let previousCap = denies[id]
            denies[id] = DenyRecord(revoked: denies[id]?.revoked ?? false, scopeCap: scopes.sorted { $0.rawValue < $1.rawValue }, at: now())
            if !writeDenies(requireAll: true) { denies[id] = previousCap; _ = writeDenies(); clients[i].scopes = old; return .refused("The change could not be saved everywhere it must be, so nothing changed.") }
            if case .failed(let why) = persist() { denies[id] = previousCap; _ = writeDenies(); clients[i].scopes = old; return .refused("The change could not be saved, so nothing changed. \(why)") }
            onInvalidate?(id)
            return .committed
        }
        onInvalidate?(id)
        return restriction(id, revoked: false, scopeCap: scopes)
    }

    /// Starts again from an empty list after the saved one proved unreadable. The unreadable file is kept beside it, not deleted.
    @discardableResult
    func resetUnreadableList() -> ClientCommit {
        guard unreadable else { return .committed }
        // The list file and the stored deny records are each set aside, never deleted, and the service starts empty: with either unreadable, who was revoked cannot be known.
        if let file, FileManager.default.fileExists(atPath: file.path) {
            do { try FileManager.default.moveItem(at: file, to: file.deletingLastPathComponent().appendingPathComponent("clients.unreadable-\(Int(now().timeIntervalSince1970)).json")) }
            catch { return .refused("The unreadable list could not be set aside, so it was left alone.") }
        }
        for store in denyStores { do { try store.setAside() } catch { return .refused("The unreadable record of withdrawn access could not be set aside, so it was left alone.") } }
        clients = []; denies = [:]; unreadable = false; denyReadFailed = false; storageProblem = nil
        return persist() == .ok ? .committed : .refused("The empty list could not be saved.")
    }

    static func hash(_ secret: String) -> String { Data(secret.utf8).sha256Hex }

    // MARK: Persistence

    private enum Persist: Equatable { case ok, failed(String) }

    private func persist() -> Persist {
        do { try write(); unsaved = false; storageProblem = nil; return .ok }
        catch { storageProblem = "The client list could not be saved (\((error as NSError).localizedDescription))."; return .failed((error as NSError).localizedDescription) }
    }

    /// For a change that withdraws access. The withdrawal is written to the deny stores FIRST (small, separate, applied over the list at every start). If at least one accepts it,
    /// a restart cannot undo it even if the full list cannot be saved. If none does, the service locks down: nobody is admitted until a deny record can be saved.
    private func restriction(_ id: String, revoked: Bool, scopeCap: Set<AutomationScope>?) -> ClientCommit {
        denies[id] = DenyRecord(revoked: revoked || (denies[id]?.revoked ?? false), scopeCap: scopeCap.map { $0.sorted { $0.rawValue < $1.rawValue } } ?? denies[id]?.scopeCap, at: now())
        // Records are only dropped when their client is gone from the list, and never while a save is outstanding. A live revocation is never evicted to make room.
        if denies.count > 200, !unsaved, !lockdown {
            let known = Set(clients.map(\.id))
            for key in denies.keys.filter({ !known.contains($0) }).sorted(by: { (denies[$0]?.at ?? .distantPast) < (denies[$1]?.at ?? .distantPast) }).prefix(denies.count - 200) { denies[key] = nil }
        }
        let durable = writeDenies()
        switch persist() {
        // The list itself was saved: a restart reads it, and it already says what was withdrawn. The deny record is the safety net for when it could not be.
        case .ok: return .committed
        case .failed(let why):
            unsaved = true
            if durable { return .committed }          // the list is behind, but the deny record holds: a restart still refuses this client
            lockdown = true
            return .restrictedButNotSaved("Nothing could be saved, so every automation client is blocked until it can be. Free some disk space or fix permissions and try again. (\(why))")
        }
    }

    /// True if the deny stores hold the current records: at least one by default, every one when `requireAll` (a widening, which must not leave a narrower cap behind anywhere).
    /// Nothing is written while an unreadable record is outstanding, so it is never overwritten.
    private func writeDenies(requireAll: Bool = false) -> Bool {
        guard !denyStores.isEmpty else { return true }
        guard !denyReadFailed else { return false }
        var accepted = 0
        for store in denyStores { if (try? store.write(denies)) != nil { accepted += 1 } }
        return requireAll ? accepted == denyStores.count : accepted > 0
    }

    /// While a restriction is unsaved the save is tried again, at most every few seconds, on use.
    private func retryPendingSave() {
        guard unsaved || lockdown, now().timeIntervalSince(lastRetry) > 5 else { return }
        lastRetry = now()
        _ = flush()
    }

    /// Tries again to save now; true if everything is on disk.
    func flush() -> Bool {
        let durable = writeDenies()
        let saved = persist() == .ok
        if durable && lockdown { lockdown = false }
        return durable && saved
    }

    private func write() throws {
        guard let file else { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try writer(try AutomationJSON.encoder.encode(clients), file)
    }

    private static func atomicWrite(_ data: Data, _ file: URL) throws {
        let temp = file.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        try data.write(to: temp, options: [])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
        do { _ = try FileManager.default.replaceItemAt(file, withItemAt: temp) } catch { try? FileManager.default.removeItem(at: temp); throw error }
    }

    private func load() {
        // The deny records are read first. If any exists but cannot be understood, the answer is "closed": it might have held a revocation.
        var merged: [String: DenyRecord] = [:]
        for store in denyStores {
            do { for (k, v) in try store.read() { if let old = merged[k] { merged[k] = DenyRecord(revoked: old.revoked || v.revoked, scopeCap: Self.narrower(old.scopeCap, v.scopeCap), at: max(old.at, v.at)) } else { merged[k] = v } } }
            catch { unreadable = true; denyReadFailed = true; storageProblem = "The saved list of withdrawn access could not be read, so no automation client is accepted until it is reset." }
        }
        denies = merged
        guard let file, FileManager.default.fileExists(atPath: file.path) else { return }
        guard let data = try? Data(contentsOf: file), let list = try? AutomationJSON.decoder.decode([AutomationClient].self, from: data) else {
            // A file that is there but cannot be understood might have held a revocation. Nobody is admitted until the person resets the list.
            unreadable = true
            storageProblem = "The saved client list could not be read, so no automation client is accepted until it is reset."
            return
        }
        // A hand-edited file cannot add a client whose hash is not a SHA-256.
        clients = list.filter { $0.tokenHash.count == 64 && $0.id.count == 8 }
        // What was withdrawn stays withdrawn, whatever the list says.
        for i in clients.indices {
            guard let d = denies[clients[i].id] else { continue }
            if d.revoked, clients[i].revokedAt == nil { clients[i].revokedAt = d.at }
            if let cap = d.scopeCap { clients[i].scopes = clients[i].scopes.intersection(Set(cap)); if clients[i].scopes.isEmpty, clients[i].revokedAt == nil { clients[i].revokedAt = d.at } }
        }
    }

    private static func narrower(_ a: [AutomationScope]?, _ b: [AutomationScope]?) -> [AutomationScope]? {
        switch (a, b) { case (nil, let x), (let x, nil): return x; case (let x?, let y?): return Array(Set(x).intersection(y)).sorted { $0.rawValue < $1.rawValue } }
    }
}

/// A fixed-window limiter per key: `limit` requests in `window` seconds.
struct AutomationRateLimiter {
    private var windows: [String: (start: TimeInterval, count: Int)] = [:]
    var limit: Int
    var window: TimeInterval
    static let maxKeys = 256

    init(limit: Int, window: TimeInterval) { self.limit = limit; self.window = window }

    /// True if the request is allowed.
    mutating func allow(_ key: String, at now: TimeInterval) -> Bool {
        if windows.count >= Self.maxKeys, windows[key] == nil { windows = windows.filter { now - $0.value.start < window } }
        var entry = windows[key] ?? (now, 0)
        if now - entry.start >= window { entry = (now, 0) }
        entry.count += 1
        windows[key] = entry
        return entry.count <= limit
    }
}
