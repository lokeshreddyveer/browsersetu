import Foundation
import Network

// MARK: Tracker (HTTP and HTTPS, BEP 3 and BEP 23)

/// Asks an HTTP tracker for peers. Uses its own ephemeral session (no cookies, no cache, no credentials of the browser) with the same proxy choice as other downloads.
///
/// UDP trackers (BEP 15) are `UDPTrackerClient` (Shared/Downloads/Torrent/UDPTracker.swift); `TrackerRouter` picks one by the address's scheme.
final class HTTPTrackerClient: TrackerAnnouncing, TrackerScraping, @unchecked Sendable {
    enum Failure: Error, LocalizedError, Equatable {
        case unsupportedScheme(String), refused(String), badReply, tooLarge, proxy(String), noScrape, blocked(String), unreachable
        var errorDescription: String? {
            switch self {
            case .unsupportedScheme(let s): "\(s) trackers are not supported yet"
            case .refused(let why): "The tracker said: \(why.prefix(120))"
            case .badReply: "The tracker's answer was not understood"
            case .tooLarge: "The tracker's answer was too large"
            case .proxy(let why): why
            case .noScrape: "This tracker does not offer counts"
            case .blocked(let why): why
            case .unreachable: "The tracker could not be reached"
            }
        }
    }

    static let maxReply = 1_048_576
    static let maxPeers = 200
    private let network: () -> DownloadNetworkSetup
    private let resolver: HostAddressResolving
    private let connector: PinnedHTTPConnecting
    /// Whether this destination was approved (by the person's own request, or by them in answer to a question): the only way a name that resolves to, or is redirected to, a local address is used.
    private let authorized: @Sendable (URL) -> Bool
    private let systemProxyActive: @Sendable () -> Bool

    init(network: @escaping () -> DownloadNetworkSetup = { DownloadNetworkSetup() }, resolver: HostAddressResolving = SystemHostResolver(), connector: PinnedHTTPConnecting = NWPinnedHTTP(),
         authorized: @escaping @Sendable (URL) -> Bool = { _ in false }, systemProxyActive: @escaping @Sendable () -> Bool = { SystemProxy.isActive() }) {
        self.network = network; self.resolver = resolver; self.connector = connector; self.authorized = authorized; self.systemProxyActive = systemProxyActive
    }

    func announce(_ tracker: URL, infoHash: Data, peerID: Data, uploaded: Int64, downloaded: Int64, left: Int64?, event: String?) async throws -> TrackerReply {
        guard let scheme = tracker.scheme?.lowercased(), scheme == "http" || scheme == "https" else { throw Failure.unsupportedScheme(tracker.scheme ?? "These") }
        guard var comps = URLComponents(url: tracker, resolvingAgainstBaseURL: false) else { throw Failure.badReply }
        // info_hash and peer_id are raw bytes, escaped byte by byte (a normal query encoder would treat them as text).
        func escape(_ d: Data) -> String { d.map { String(format: "%%%02X", $0) }.joined() }
        var query = comps.percentEncodedQuery.map { $0 + "&" } ?? ""
        query += "info_hash=\(escape(infoHash))&peer_id=\(escape(peerID))&port=\(TrackerScope.listenPort)&uploaded=\(uploaded)&downloaded=\(downloaded)&left=\(left ?? 0)&compact=1&numwant=50"
        if let event { query += "&event=\(event)" }
        comps.percentEncodedQuery = query
        guard let url = comps.url else { throw Failure.badReply }

        let body = try await fetch(url)
        return try Self.parse(body)
    }

    // MARK: Making the request

    /// The reply body of a GET. Without a proxy: the name is resolved once, every address is checked, the connection goes to that address, and each redirect is checked in turn (see
    /// `PinnedHTTP.swift`). With a proxy the proxy resolves the name, so the system client is used, but a redirect to a local destination is still refused unless it was approved.
    private func fetch(_ first: URL) async throws -> Data {
        let result = try await fetchRaw(first, range: nil, maxBody: Self.maxReply, localNeedsApproval: false)
        guard result.status == 200 else { throw Failure.refused("HTTP \(result.status)") }
        return result.body
    }

    /// One GET with the same address, redirect, proxy and network rules as a tracker request, returning the status and body whatever the status (the caller decides what a 206, 404 or 503
    /// means). `localNeedsApproval`: for an address that came from a torrent's own metadata (a web seed), a local address is contacted only when it was approved, never merely because it is
    /// the first address (a tracker named by the person's own link may be local; a torrent file must not be able to point the app at the local network).
    func fetchRaw(_ first: URL, range: String?, maxBody: Int, localNeedsApproval: Bool) async throws -> PinnedHTTPResult {
        let setup = network()
        do { try DownloadProxy.requireUsable(setup.proxy) } catch { throw Failure.proxy((error as? LocalizedError)?.errorDescription ?? "The proxy settings could not be used.") }
        let viaProxy = DownloadProxy.configuration(for: setup.proxy, password: setup.proxyPassword) != nil || (setup.proxy.mode == .system && systemProxyActive())
        if viaProxy { return try await fetchThroughProxy(first, setup: setup, range: range, maxBody: maxBody) }
        var url = first
        for hop in 0...Self.maxRedirects {
            let allowLocal = (hop == 0 && !localNeedsApproval) ? (HTTPRequestPolicy.classify(host: url.host ?? "").isInternal || authorized(url)) : authorized(url)
            let address = try await checkedAddress(url, allowLocal: allowLocal)
            let result = try await connector.get(url, address: address, maxBody: maxBody, range: range, refuseExpensive: setup.refuseExpensive, refuseConstrained: setup.refuseConstrained)
            if (300...399).contains(result.status) {
                guard let location = result.location, let next = URL(string: location, relativeTo: url)?.absoluteURL, ["http", "https"].contains(next.scheme?.lowercased() ?? "") else { throw Failure.badReply }
                url = next; continue
            }
            return result
        }
        throw Failure.refused("too many redirects")
    }

    static let maxRedirects = 3

    /// The one address to connect to: numeric as given, or resolved here. Any answer that is local, when it is not allowed to be, refuses the request.
    func checkedAddress(_ url: URL, allowLocal: Bool) async throws -> String {
        guard let host = url.host, !host.isEmpty, host.utf8.count <= 253 else { throw Failure.badReply }
        let literal = NWPinnedHTTP.isNumeric(host)
        let candidates = literal ? [host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))] : ((await resolver.addresses(for: host)) ?? [])
        guard !candidates.isEmpty else { throw Failure.unreachable }
        for address in candidates where HTTPRequestPolicy.classify(host: address).isInternal && !allowLocal {
            throw Failure.blocked("This tracker's address (or a redirect from it) points to a local address, so it was not contacted.")
        }
        // An address the person's settings allow is preferred in the order given; a mixed answer with a local member was refused above unless allowed.
        return candidates[0]
    }

    private func fetchThroughProxy(_ url: URL, setup: DownloadNetworkSetup, range: String? = nil, maxBody: Int = HTTPTrackerClient.maxReply) async throws -> PinnedHTTPResult {
        // The proxy looks the name up, so only redirects (below) can be held to the name check; which origins may reach a tracker at all is decided before this point (`usableTrackers`).
        // A request that is not the person's own is never sent through a proxy: the proxy would look the name up, and where it really connects could not be checked here.
        if let origin = TrackerScope.origin, origin != .user { throw Failure.blocked(DownloadProxy.Problem.notForUntrustedRequests.errorDescription ?? "This request cannot use the proxy.") }          // not fixable in Settings, so not a settings problem
        let config = HTTPTransferEngine.baseConfiguration(setup, connections: 2)
        config.timeoutIntervalForRequest = 20
        do { try DownloadProxy.apply(setup.proxy, password: setup.proxyPassword, origin: .user, to: config) } catch { throw Failure.proxy((error as? LocalizedError)?.errorDescription ?? "The proxy settings could not be used.") }
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("Browser Setu", forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")          // a compressed answer would not be the bytes asked for
        if let range, range.hasPrefix("bytes="), range.dropFirst(6).allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "-") }), range.utf8.count <= 40 { request.setValue(range, forHTTPHeaderField: "Range") }
        let task = TrackerScope.task, approve = authorized
        let guardRedirects = RedirectGuard(authorized: { url in TrackerScope.$task.withValue(task) { approve(url) } })          // the delegate runs outside this task: carry its identity in
        let (bytes, response) = try await session.bytes(for: request, delegate: guardRedirects)
        guard let http = response as? HTTPURLResponse else { throw Failure.badReply }
        var body = Data()
        for try await byte in bytes { body.append(byte); if body.count > maxBody { throw Failure.tooLarge } }
        return PinnedHTTPResult(status: http.statusCode, location: nil, body: body, contentRange: http.value(forHTTPHeaderField: "Content-Range"))
    }

    final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let authorized: @Sendable (URL) -> Bool
        private var hops = 0
        init(authorized: @escaping @Sendable (URL) -> Bool) { self.authorized = authorized }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            hops += 1
            guard let target = request.url, hops <= 5, let from = task.currentRequest?.url ?? response.url else { completionHandler(nil); return }
            let ok = authorized
            Task { completionHandler(await Self.permits(from: from, to: target, authorized: ok) ? request : nil) }
        }
        /// A tracker may send the request on, but not from a secure address to a plain one, and not into this computer or the local network by name or by what the name resolves to
        /// (unless the person authorised that very tracker address).
        static func permits(from: URL, to target: URL, authorized: (URL) -> Bool, resolve: (String) async -> (kind: HostClass, resolved: [String]?) = { await HTTPRequestPolicy.classifyResolving(host: $0) }) async -> Bool {
            guard let scheme = target.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = target.host else { return false }
            if from.scheme?.lowercased() == "https", scheme != "https" { return false }
            if authorized(target) { return true }
            let found = await resolve(host)
            return !found.kind.isInternal && found.resolved != nil
        }
    }

    /// The scrape address of an announce address (BEP 48 convention): the last part of the path must begin with "announce", and that word becomes "scrape". A tracker whose address does not
    /// look like that has no scrape address we can know of.
    static func scrapeURL(for tracker: URL, infoHash: Data) -> URL? {
        guard var comps = URLComponents(url: tracker, resolvingAgainstBaseURL: false) else { return nil }
        var parts = comps.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let last = parts.last, last.hasPrefix("announce") else { return nil }
        parts[parts.count - 1] = "scrape" + last.dropFirst("announce".count)
        comps.path = parts.joined(separator: "/")
        let escaped = infoHash.map { String(format: "%%%02X", $0) }.joined()
        comps.percentEncodedQuery = (comps.percentEncodedQuery.map { $0 + "&" } ?? "") + "info_hash=\(escaped)"
        return comps.url
    }

    /// A scrape reply: `files` holds one entry for each torrent asked about (keyed by raw hash bytes, which a text key cannot always spell, so the only entry is taken as ours since only one was
    /// asked for). Counts the tracker did not give stay unknown.
    static func parseScrape(_ body: Data) throws -> TrackerScrape {
        guard let dict = (try? BencodeDecoder.decode(body, limits: .scrapeReply))?.value.dict else { throw Failure.badReply }
        if let why = dict["failure reason"]?.string { throw Failure.refused(why) }
        guard let files = dict["files"]?.dict, files.count == 1, let entry = files.values.first?.dict else { throw Failure.badReply }
        func count(_ key: String) -> Int? { entry[key]?.int.flatMap { $0 >= 0 ? Int($0) : nil } }
        return TrackerScrape(seeders: count("complete"), completed: count("downloaded"), leechers: count("incomplete"))
    }

    func scrape(_ tracker: URL, infoHash: Data) async throws -> TrackerScrape {
        guard let scheme = tracker.scheme?.lowercased(), scheme == "http" || scheme == "https" else { throw Failure.unsupportedScheme(tracker.scheme ?? "These") }
        guard let url = Self.scrapeURL(for: tracker, infoHash: infoHash) else { throw Failure.noScrape }
        let body = try await fetch(url)
        return try Self.parseScrape(body)
    }

    /// The tracker's reply: a failure reason, or an interval and peers (compact or as a list).
    /// A peer is named by a numeric address only: a name would be looked up later, unchecked, and could be made to point at this machine or the local network.
    static func isNumericAddress(_ host: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
    }

    static func parse(_ body: Data) throws -> TrackerReply {
        guard let dict = (try? BencodeDecoder.decode(body, limits: .message))?.value.dict else { throw Failure.badReply }
        if let why = dict["failure reason"]?.string { throw Failure.refused(why) }
        var peers: [PeerAddress] = []
        if let compact = dict["peers"]?.data {
            let b = [UInt8](compact)
            for i in stride(from: 0, to: b.count - 5, by: 6) where peers.count < maxPeers {
                let port = UInt16(b[i + 4]) << 8 | UInt16(b[i + 5])
                peers.append(PeerAddress(host: "\(b[i]).\(b[i + 1]).\(b[i + 2]).\(b[i + 3])", port: port))
            }
        } else if let list = dict["peers"]?.list {
            for entry in list.prefix(maxPeers) {
                if let d = entry.dict, let host = d["ip"]?.string, let port = d["port"]?.int, (1...65535).contains(port), host.utf8.count <= 253, Self.isNumericAddress(host) { peers.append(PeerAddress(host: host, port: UInt16(port))) }
            }
        }
        if let compact6 = dict["peers6"]?.data {
            let b = [UInt8](compact6)
            for i in stride(from: 0, to: b.count - 17, by: 18) where peers.count < maxPeers {
                var addr = in6_addr()
                withUnsafeMutableBytes(of: &addr) { $0.copyBytes(from: b[i..<(i + 16)]) }
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                inet_ntop(AF_INET6, &addr, &buffer, socklen_t(buffer.count))
                peers.append(PeerAddress(host: String(cString: buffer), port: UInt16(b[i + 16]) << 8 | UInt16(b[i + 17])))
            }
        }
        let interval = TimeInterval(min(max(dict["interval"]?.int ?? 1800, 60), 7200))
        return TrackerReply(peers: peers.filter { $0.port != 0 }, interval: interval, warning: dict["warning message"]?.string.map { String($0.prefix(120)) },
                            seeders: dict["complete"]?.int.flatMap { $0 >= 0 ? Int($0) : nil }, leechers: dict["incomplete"]?.int.flatMap { $0 >= 0 ? Int($0) : nil })
    }
}

// MARK: Peer connections

/// An outgoing TCP connection to one peer. No listener exists anywhere in this engine. A proxy choice applies here as it does to downloads: HTTP CONNECT or SOCKS5 through
/// `proxyConfigurations`; if the settings cannot be used the connection fails, it is never made directly.
final class NWPeerTransportFactory: PeerTransportFactory, @unchecked Sendable {
    private let network: () -> DownloadNetworkSetup
    private let systemProxyActive: @Sendable () -> Bool
    private let preferences: @Sendable () -> (TransportPreference, EncryptionPolicy)
    init(network: @escaping () -> DownloadNetworkSetup = { DownloadNetworkSetup() }, systemProxyActive: @escaping @Sendable () -> Bool = { SystemProxy.isActive() },
         preferences: @escaping @Sendable () -> (TransportPreference, EncryptionPolicy) = { (.tcpOnly, .disabled) }) {
        self.network = network; self.systemProxyActive = systemProxyActive; self.preferences = preferences
    }

    func make(_ address: PeerAddress, queue: DispatchQueue) -> PeerTransport {
        let setup = network()
        return NWPeerTransport(address: address, setup: setup, queue: queue, systemProxyActive: setup.proxy.mode == .system && systemProxyActive())
    }

    /// The ways to reach this peer, in the order the person's preferences give, each tried only if the one before failed for a reason that is the peer's or the network's. µTP is UDP, which no
    /// proxy carries, so with a proxy in force it is never tried (and `µTP only` says why it cannot work). Encryption "preferred" is tried first and then, if the peer does not speak it, the
    /// same transport plain; "required" is never followed by plain.
    func make(_ address: PeerAddress, infoHash: Data, queue: DispatchQueue) -> PeerTransport {
        let setup = network()
        let (mode, encryption) = preferences()
        let proxied = DownloadProxy.configuration(for: setup.proxy, password: setup.proxyPassword) != nil || (setup.proxy.mode == .system && systemProxyActive())
        let systemActive = setup.proxy.mode == .system && systemProxyActive()
        var kinds: [PeerTransportKind]
        switch mode {
        case .automatic, .preferTCP: kinds = [.tcp, .utp]
        case .preferUTP: kinds = [.utp, .tcp]
        case .tcpOnly: kinds = [.tcp]
        case .utpOnly: kinds = [.utp]
        }
        if proxied { kinds.removeAll { $0 == .utp } }
        guard !kinds.isEmpty else {
            return FailingPeerTransport(error: HTTPTrackerClient.Failure.proxy("µTP is UDP, which a proxy cannot carry, so this peer was not contacted. Choose “No proxy”, or TCP, in Settings → Downloads."), queue: queue)
        }
        // Each entry: encrypted with these methods, or nil for plain.
        let ways: [MSE.Methods?]
        switch encryption {
        case .preferEncrypted: ways = [[.rc4, .plaintext], nil]
        case .requireEncrypted: ways = [[.rc4]]
        case .allowPlaintext, .disabled: ways = [nil]
        }
        var attempts: [FallbackPeerTransport.Attempt] = []
        for kind in kinds {
            for way in ways {
                let label = (kind == .tcp ? "tcp" : "utp") + (way == nil ? "" : "+mse")
                attempts.append(FallbackPeerTransport.Attempt(label: label, group: kind == .tcp ? "tcp" : "utp", make: { [network] in
                    let base: PeerTransport
                    switch kind {
                    case .tcp: base = NWPeerTransport(address: address, setup: setup, queue: queue, systemProxyActive: systemActive)
                    case .utp:
                        guard let channel = NWUDPChannel(address: address, refuseExpensive: setup.refuseExpensive, refuseConstrained: setup.refuseConstrained, queue: queue) else { return FailingPeerTransport(error: URLError(.badURL), queue: queue) }
                        base = UTPPeerTransport(channel: channel, queue: queue)
                    }
                    _ = network
                    guard let methods = way else { return base }
                    return MSEPeerTransport(base: base, infoHash: infoHash, methods: methods, queue: queue)
                }))
            }
        }
        return attempts.count == 1 ? attempts[0].make() : FallbackPeerTransport(attempts: Array(attempts.prefix(4)), queue: queue)
    }
}

/// A transport that cannot connect, with the reason: how a refusal that is ours (a proxy that cannot carry µTP) reaches the session without a socket being made.
final class FailingPeerTransport: PeerTransport {
    private let error: Error, queue: DispatchQueue
    init(error: Error, queue: DispatchQueue) { self.error = error; self.queue = queue }
    func connect(_ done: @escaping (Error?) -> Void) { queue.async { done(self.error) } }
    func send(_ data: Data) {}
    func receive(_ handler: @escaping (Data?, Error?) -> Void) { handler(nil, URLError(.cancelled)) }
    func close() {}
}

final class NWPeerTransport: PeerTransport, @unchecked Sendable {
    private let connection: NWConnection?
    private let queue: DispatchQueue
    private let setupError: Error?

    init(address: PeerAddress, setup: DownloadNetworkSetup, queue: DispatchQueue, systemProxyActive: Bool = false) {
        self.queue = queue
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = false
        parameters.prohibitExpensivePaths = setup.refuseExpensive
        parameters.prohibitConstrainedPaths = setup.refuseConstrained
        var failure: Error?
        do {
            try DownloadProxy.requireUsable(setup.proxy)
            // "Use my Mac's settings" while the Mac uses a proxy: a direct peer connection would go around it, so it is not made (choose "No proxy" in Settings → Downloads to connect directly).
            if systemProxyActive { throw HTTPTrackerClient.Failure.proxy("Your Mac uses a proxy that peer connections cannot go through, so this peer was not contacted. Choose “No proxy” in Settings → Downloads to connect directly.") }
            if let proxy = DownloadProxy.configuration(for: setup.proxy, password: setup.proxyPassword) {
                let context = NWParameters.PrivacyContext(description: "Browser Setu torrent")
                context.proxyConfigurations = [proxy]
                parameters.setPrivacyContext(context)
            }
        } catch { failure = error }
        setupError = failure
        guard failure == nil, let port = NWEndpoint.Port(rawValue: address.port) else { connection = nil; return }
        connection = NWConnection(host: NWEndpoint.Host(address.host), port: port, using: parameters)
    }

    /// An incoming connection a listener has already accepted.
    init(accepted: NWConnection, queue: DispatchQueue) { self.queue = queue; connection = accepted; setupError = nil }

    func connect(_ done: @escaping (Error?) -> Void) {
        guard let connection else { queue.async { done(self.setupError ?? URLError(.badURL)) }; return }
        var finished = false
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: if !finished { finished = true; done(nil) }
            case .failed(let e): if !finished { finished = true; done(e) }
            case .waiting(let e): if !finished { finished = true; done(e); connection.cancel() }          // no route: give up rather than wait indefinitely
            case .cancelled: if !finished { finished = true; done(URLError(.cancelled)) }
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ data: Data) { connection?.send(content: data, completion: .contentProcessed { _ in }) }

    func receive(_ handler: @escaping (Data?, Error?) -> Void) {
        guard let connection else { handler(nil, URLError(.cancelled)); return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            if let error { handler(nil, error) } else if let data, !data.isEmpty { handler(data, nil) } else { handler(nil, isComplete ? nil : URLError(.networkConnectionLost)) }
        }
    }

    func close() { connection?.cancel() }
}

extension DownloadProxy {
    /// Throws if the proxy choice cannot be used (so a peer connection is refused rather than made directly).
    static func requireUsable(_ proxy: DownloadNetworkSettings.Proxy) throws {
        if let p = problem(proxy) { throw p }
    }
}
