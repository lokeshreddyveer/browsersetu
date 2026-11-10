import Foundation
import Network

// SFTP and FTP through the profile's proxy. `ssh` cannot sign in to a proxy by itself (the system `nc -X` cannot pass a proxy password without asking for it), and a ProxyCommand is only as good as the
// tool it names. So the connection to the proxy is made here, with Apple's own proxy support (SOCKS 5 or HTTP CONNECT, with the proxy's user name and password), and `ssh` is pointed at a loopback port that
// this object listens on and relays to the server through the proxy. The relay accepts one connection, only from this Mac, and ends with the session.

struct RemoteProxy: Sendable, Equatable {
    enum Kind: Sendable { case socks5, httpConnect }
    var kind: Kind
    var host: String
    var port: Int
    var username: String?
    var password: String?

    /// The proxy a profile has chosen for its downloads, or nil for a direct connection ("System" and "Direct" both connect directly here: the system's own proxy list is not read for these protocols).
    static func from(_ p: DownloadNetworkSettings.Proxy, password: String?) -> RemoteProxy? {
        guard !p.host.isEmpty, (1...65535).contains(p.port) else { return nil }
        let user = p.username.isEmpty ? nil : p.username
        switch p.mode {
        case .socks5: return RemoteProxy(kind: .socks5, host: p.host, port: p.port, username: user, password: password)
        case .http, .https: return RemoteProxy(kind: .httpConnect, host: p.host, port: p.port, username: user, password: password)
        case .system, .direct: return nil
        }
    }
}

final class ProxyRelay: @unchecked Sendable {
    private let queue = DispatchQueue(label: "browsersetu.proxy-relay")
    private let listener: NWListener
    private let target: (host: String, port: Int)
    private let proxy: RemoteProxy
    private let lock = NSLock()
    private var accepted = false, stopped = false
    private var inbound: NWConnection?, outbound: NWConnection?

    init(target host: String, port: Int, proxy: RemoteProxy) throws {
        self.target = (host, port); self.proxy = proxy
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: params)
    }

    /// Starts listening and returns the loopback port to give `ssh`.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            let once = Once()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: if once.take(), let port = self?.listener.port?.rawValue { cont.resume(returning: port) }
                case .failed(let e): if once.take() { cont.resume(throwing: RemoteError.unreachable("the local relay could not start (\(e))")) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
            listener.start(queue: queue)
        }
    }

    private final class Once: @unchecked Sendable { private let l = NSLock(); private var done = false; func take() -> Bool { l.lock(); defer { l.unlock() }; if done { return false }; done = true; return true } }

    private func accept(_ c: NWConnection) {
        lock.lock()
        // One connection: the ssh this relay was made for. Anything else is refused.
        if accepted || stopped { lock.unlock(); c.cancel(); return }
        accepted = true; inbound = c
        lock.unlock()
        let params = NWParameters.tcp
        let context = NWParameters.PrivacyContext(description: "BrowserSetu remote-file proxy")
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(proxy.host), port: NWEndpoint.Port(rawValue: UInt16(proxy.port)) ?? 1080)
        var config: ProxyConfiguration
        switch proxy.kind {
        case .socks5: config = ProxyConfiguration(socksv5Proxy: endpoint)
        case .httpConnect: config = ProxyConfiguration(httpCONNECTProxy: endpoint)
        }
        if let u = proxy.username, let p = proxy.password { config.applyCredential(username: u, password: p) }
        config.allowFailover = false          // a proxy that cannot be reached is an error, never a quiet direct connection
        context.proxyConfigurations = [config]
        params.setPrivacyContext(context)
        let out = NWConnection(host: NWEndpoint.Host(target.host), port: NWEndpoint.Port(rawValue: UInt16(target.port)) ?? 22, using: params)
        lock.lock(); outbound = out; lock.unlock()
        out.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.pump(from: c, to: out); self?.pump(from: out, to: c)
            case .failed, .cancelled: self?.stop()
            default: break
            }
        }
        c.stateUpdateHandler = { [weak self] state in if case .failed = state { self?.stop() }; if case .cancelled = state { self?.stop() } }
        c.start(queue: queue); out.start(queue: queue)
    }

    private func pump(from a: NWConnection, to b: NWConnection) {
        a.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            if let data, !data.isEmpty { b.send(content: data, completion: .contentProcessed { _ in self?.pump(from: a, to: b) }) }
            else if complete || error != nil { self?.stop(); return }
            else { self?.pump(from: a, to: b) }
        }
    }

    func stop() {
        lock.lock(); if stopped { lock.unlock(); return }; stopped = true; let i = inbound, o = outbound; lock.unlock()
        i?.cancel(); o?.cancel(); listener.cancel()
    }
    deinit { stop() }
}
