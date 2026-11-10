import Foundation

// Saved servers. A connection is only metadata (where, who, how); the password or key passphrase is in the Keychain under the connection's id, never in this file, in a download's record, in a
// log, or in a collection's source. Private browsing keeps its connections in memory only. The folder's host-key file and any certificate the person chose to trust live beside it.

struct RemoteConnection: Codable, Identifiable, Equatable, Sendable {
    enum Auth: String, Codable, CaseIterable, Sendable {
        case password, key, agent, anonymous
        var title: String { switch self { case .password: "Password"; case .key: "Key file"; case .agent: "SSH agent"; case .anonymous: "Anonymous" } }
    }
    var id = UUID()
    var name: String
    var scheme: RemoteScheme
    var host: String
    var port: Int
    var user: String?
    var auth: Auth
    /// A private key file (SFTP with .key). A path, not the key.
    var keyPath: String?
    var path: String = "/"
    var createdAt = Date()
    /// The website account made for this server's WebDAV downloads (https + password), so Forget can remove it: it is shared by every download from that host and port, so it must not outlive the server entry.
    var davAccountID: String?

    /// The address shown to the person and kept in a download's record: never a password, never even the user name.
    var displayURL: URL? { var c = URLComponents(); c.scheme = scheme.isWebDAV ? (scheme == .webdavs ? "https" : "http") : scheme.rawValue; c.host = host; c.port = port == scheme.defaultPort ? nil : port; c.path = path.hasPrefix("/") ? path : "/" + path; return c.url }

    /// A password must be given; a key's passphrase is optional (most keys have none).
    var needsSecret: Bool { auth == .password }
    var mayHaveSecret: Bool { auth == .password || auth == .key }

    static func clean(name: String, host: String) -> String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((n.isEmpty ? host : n).prefix(80))
    }

    /// A connection from an address a person typed or clicked (`sftp://user@host:2222/dir/`). The password is never taken from the address.
    static func from(address text: String) -> (connection: RemoteConnection, path: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 2048, let u = URL(string: trimmed), let scheme = RemoteScheme(urlScheme: u.scheme), let host = u.host, !host.isEmpty else { return nil }
        let port = u.port ?? scheme.defaultPort
        guard (1...65535).contains(port) else { return nil }
        let path = u.path.isEmpty ? "/" : (u.path.removingPercentEncoding ?? u.path)
        let auth: Auth = scheme == .sftp ? (u.user == nil ? .agent : .password) : (u.user == nil ? .anonymous : .password)
        let c = RemoteConnection(name: host, scheme: scheme, host: host, port: port, user: u.user?.removingPercentEncoding, auth: auth, path: path)
        return (c, path)
    }
}

@MainActor
final class RemoteConnectionStore: ObservableObject {
    static let maxConnections = 100
    static let maxFileBytes = 1_000_000

    @Published private(set) var connections: [RemoteConnection] = []
    let profile: String
    let isPrivate: Bool
    private let file: URL?
    let folder: URL
    private let secrets: AccountSecretStore
    private var memorySecrets: [UUID: String] = [:]          // private browsing, and a connection that was not saved

    init(profile: String, folder: URL, isPrivate: Bool = false, secrets: AccountSecretStore) {
        self.profile = profile; self.isPrivate = isPrivate; self.folder = folder; self.secrets = secrets
        file = isPrivate ? nil : folder.appendingPathComponent("remote-connections.json")
        load()
    }

    /// Private browsing trusts servers for this run only: its host keys and certificates live in a folder of their own, under the temporary directory, that is removed when the private session ends.
    /// Nothing a private tab decides is ever written to the profile's folder.
    private var scratch: URL?
    private func privateScratch() -> URL {
        if let scratch { return scratch }
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("bsetu-private-remote-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        scratch = u; return u
    }
    func wipePrivateScratch() { if let scratch { try? FileManager.default.removeItem(at: scratch) }; scratch = nil }
    var hasPrivateScratch: Bool { scratch != nil }
    private func trustFolder(_ isPrivate: Bool) -> URL { isPrivate ? privateScratch() : folder }

    var hostKeys: SSHHostKeyStore { hostKeys(isPrivate: false) }
    func hostKeys(isPrivate: Bool) -> SSHHostKeyStore { SSHHostKeyStore(file: trustFolder(isPrivate).appendingPathComponent("remote_known_hosts")) }
    func trustedCertificate(for id: UUID, isPrivate: Bool = false) -> URL? {
        let u = (isPrivate ? (scratch ?? folder) : folder).appendingPathComponent("remote-certs/\(id.uuidString).pem")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    private struct Disk: Codable { var version = 1; var profile: String; var connections: [RemoteConnection] }

    private func load() {
        guard let file, let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0, size <= Self.maxFileBytes,
              let data = try? Data(contentsOf: file), let disk = try? JSONDecoder().decode(Disk.self, from: data), disk.version == 1, disk.profile == profile else { return }
        var seen = Set<UUID>()
        connections = disk.connections.filter { seen.insert($0.id).inserted && RemoteScheme.allCases.contains($0.scheme) && (1...65535).contains($0.port) && !$0.host.isEmpty }.prefix(Self.maxConnections).map { var c = $0; c.name = RemoteConnection.clean(name: c.name, host: c.host); return c }
    }

    private func save() {
        guard let file, let data = try? JSONEncoder().encode(Disk(profile: profile, connections: connections)) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    func connection(_ id: UUID) -> RemoteConnection? { connections.first { $0.id == id } }
    private var unsaved: [UUID: RemoteConnection] = [:]
    /// A connection used once and not kept (see `useOnce`).
    func ephemeral(_ id: UUID) -> RemoteConnection? { unsaved[id] }

    private func account(_ id: UUID) -> String { "remote:" + id.uuidString }

    /// Keeps a connection (and its secret). A normal profile writes the secret to the Keychain; if that fails the connection is not saved without it. Private browsing keeps both in memory.
    @discardableResult
    func save(_ c: RemoteConnection, secret: String?) -> Bool {
        if !isPrivate {
            if let secret, !secret.isEmpty, c.mayHaveSecret { guard secrets.write(Data(secret.utf8), for: account(c.id)) else { return false } }
            if !c.mayHaveSecret || (secret ?? "").isEmpty && c.auth == .key { _ = secrets.delete(account(c.id)) }
        } else if let secret, c.mayHaveSecret { memorySecrets[c.id] = secret }
        if let i = connections.firstIndex(where: { $0.id == c.id }) { connections[i] = c }
        else { guard connections.count < Self.maxConnections else { return false }; connections.append(c) }
        save()
        return true
    }

    func secret(for id: UUID) -> String? {
        if let m = memorySecrets[id] { return m }
        if isPrivate { return nil }
        if case .value(let d) = secrets.read(account(id)) { return String(data: d, encoding: .utf8) }
        return nil
    }

    /// An unsaved connection used once (the person chose not to remember it, or this is a private session).
    func useOnce(_ c: RemoteConnection, secret: String?) { unsaved[c.id] = c; memorySecrets[c.id] = secret }

    func delete(_ id: UUID) {
        connections.removeAll { $0.id == id }
        _ = secrets.delete(account(id)); memorySecrets[id] = nil
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("remote-certs/\(id.uuidString).pem"))
        save()
    }

    func trustCertificate(pem: String, for id: UUID, isPrivate: Bool = false) throws {
        let dir = trustFolder(isPrivate).appendingPathComponent("remote-certs", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(pem.utf8).write(to: dir.appendingPathComponent("\(id.uuidString).pem"), options: .atomic)
    }

    /// Removes everything this store holds for the profile (signing out of the profile, resetting it).
    func wipe() {
        for c in connections { _ = secrets.delete(account(c.id)) }
        connections = []; memorySecrets = [:]
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("remote-certs"))
        save()
    }

    // MARK: Sessions

    func makeSession(for c: RemoteConnection, secret: String?, network: DownloadNetworkSetup, origin: DownloadRequestOrigin = .user, rateLimit: Int? = nil, isPrivate: Bool = false) throws -> RemoteSession {
        let proxy = RemoteProxy.from(network.proxy, password: network.proxyPassword)
        switch c.scheme {
        case .sftp:
            return SFTPSession(config: SFTPConfig(host: c.host, port: c.port, user: c.user ?? NSUserName(), identityFile: c.auth == .key ? c.keyPath : nil, secret: c.auth == .agent ? nil : secret,
                                                  useAgent: c.auth == .agent, knownHosts: hostKeys(isPrivate: isPrivate).file, proxy: proxy))
        case .ftp, .ftps:
            let implicit = c.scheme == .ftps && c.port == 990
            return FTPSession(config: FTPConfig(host: c.host, port: c.port, user: c.auth == .anonymous ? nil : c.user, password: c.auth == .anonymous ? nil : secret, explicitTLS: c.scheme == .ftps && !implicit,
                                                implicitTLS: implicit, trustedCertificate: trustedCertificate(for: c.id, isPrivate: isPrivate), rateLimit: rateLimit, proxy: proxy))
        case .webdav, .webdavs:
            var comps = URLComponents(); comps.scheme = c.scheme == .webdavs ? "https" : "http"; comps.host = c.host; comps.port = c.port == c.scheme.defaultPort ? nil : c.port; comps.path = "/"
            guard let base = comps.url else { throw RemoteError.invalidAddress("That server address is not usable.") }
            var auth: String?
            if c.auth == .password, c.scheme == .webdavs, let user = c.user, let secret { auth = "Basic " + Data("\(user):\(secret)".utf8).base64EncodedString() }
            return WebDAVSession(config: WebDAVConfig(base: base, authorization: auth, origin: origin), network: network)
        }
    }
}
