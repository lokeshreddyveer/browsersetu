#if os(macOS)
import Foundation
import Network

/// Carries HTTP/1.1 to the automation service over a Unix domain socket (the default: reachable only by the person's own account, and by no web page at all), or, in the
/// downloadable build, over 127.0.0.1. It parses and frames; every decision is the service's.
final class AutomationTransport: @unchecked Sendable {
    enum Endpoint: Equatable { case unix(path: String), loopback(port: UInt16) }

    static let maxConnections = 16
    static let headerDeadline: TimeInterval = 10
    static let maxPath = 100            // sockaddr_un holds 104 bytes

    private let service: AutomationService
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var endpoint: Endpoint?
    private var stopped = true

    init(service: AutomationService) { self.service = service }

    enum StartError: Error, Equatable { case pathTooLong, notASocket, failed(String) }

    func start(_ wanted: Endpoint, onReady: @escaping @Sendable () -> Void = {}, onFailure: @escaping @Sendable (String) -> Void = { _ in }) throws {
        stop()
        let parameters = NWParameters.tcp
        switch wanted {
        case .unix(let path):
            guard path.utf8.count <= Self.maxPath else { throw StartError.pathTooLong }
            try Self.prepareSocketPath(path)
            parameters.requiredLocalEndpoint = NWEndpoint.unix(path: path)
        case .loopback(let port):
            guard let p = NWEndpoint.Port(rawValue: port) else { throw StartError.failed("bad port") }
            parameters.requiredInterfaceType = .loopback
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host("127.0.0.1"), port: p)
        }
        guard let created = try? NWListener(using: parameters) else { throw StartError.failed("could not listen") }
        lock.lock(); listener = created; endpoint = wanted; stopped = false; lock.unlock()
        created.newConnectionHandler = { [weak self] c in self?.accept(c) }
        created.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if case .unix(let path) = wanted { chmod(path, 0o600) }       // the owner only
                onReady()
            case .failed(let e): self?.stop(); onFailure("\(e)")
            default: break
            }
        }
        created.start(queue: DispatchQueue(label: "browsersetu.automation"))
    }

    /// Removes a stale socket of ours (a crash leaves one behind) but never anything else, and makes the folder private.
    static func prepareSocketPath(_ path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // The folder is the lock on this socket, so an older, looser one is tightened (and must be ours).
        var folder = stat()
        if lstat(url.deletingLastPathComponent().path, &folder) == 0 {
            guard folder.st_uid == getuid() else { throw StartError.failed("the folder belongs to another account") }
            chmod(url.deletingLastPathComponent().path, 0o700)
        }
        var info = stat()
        if lstat(path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFSOCK else { throw StartError.notASocket }
            // A socket that still answers belongs to a running copy: it is not taken over.
            if answers(path) { throw StartError.failed("another copy is already listening") }
            unlink(path)
        }
    }

    private static func answers(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0); guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { $0.withMemoryRebound(to: CChar.self, capacity: 104) { strncpy($0, path, 103) } }
        return withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } } == 0
    }

    func stop() {
        lock.lock()
        stopped = true
        let open = Array(connections.values), running = Array(tasks.values), current = listener, wasEndpoint = endpoint
        connections = [:]; tasks = [:]; listener = nil; endpoint = nil
        lock.unlock()
        current?.cancel()
        for t in running { t.cancel() }
        for c in open { c.cancel() }
        if case .unix(let path)? = wasEndpoint { unlink(path) }
    }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return !stopped }
    var connectionCount: Int { lock.lock(); defer { lock.unlock() }; return connections.count }

    private func register(_ c: NWConnection) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, connections.count < Self.maxConnections else { return false }
        connections[ObjectIdentifier(c)] = c
        return true
    }

    private func forget(_ c: NWConnection) {
        lock.lock(); connections[ObjectIdentifier(c)] = nil; let t = tasks.removeValue(forKey: ObjectIdentifier(c)); lock.unlock()
        t?.cancel()
    }

    private func accept(_ c: NWConnection) {
        guard register(c) else { c.cancel(); return }
        c.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled: self?.forget(c)
            // A client that went away (or whose path broke) is let go at once: its connection, its task and its event slot are all freed.
            case .failed, .waiting: c.cancel()
            default: break
            }
        }
        c.start(queue: DispatchQueue(label: "browsersetu.automation.connection"))
        let received = Received()
        // A client that has not sent a whole request in ten seconds is dropped.
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.headerDeadline) { if !received.complete { c.cancel() } }
        read(c, received)
    }

    private final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var done = false
        func append(_ d: Data) -> Data { lock.lock(); defer { lock.unlock() }; data.append(d); return data }
        var complete: Bool { lock.lock(); defer { lock.unlock() }; return done }
        func finish() { lock.lock(); done = true; lock.unlock() }
    }

    private func read(_ c: NWConnection, _ received: Received) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, finished, error in
            guard let self, self.isRunning else { c.cancel(); return }
            let all = received.append(data ?? Data())
            if all.count > AgentHTTP.maxHeader + AutomationService.maxBody + 1 { self.send(c, status: 413, AutomationJSON.error(.tooLarge)); return }
            switch AgentHTTP.parse(all) {
            case .needMore: if finished || error != nil { c.cancel() } else { self.read(c, received) }
            case .bad(let why): self.send(c, status: 400, AutomationJSON.error(.badRequest("bad_request", why)))
            case .request(let r):
                received.finish()
                let transport: AutomationRequest.Transport = { if case .loopback(let p)? = self.currentEndpoint { return .loopback(port: p) }; return .unixSocket }()
                let request = AutomationRequest(method: r.method, target: r.path, headers: r.headers, body: r.body, transport: transport)
                let task = Task { [service = self.service] in
                    let reply = await service.handle(request)
                    if Task.isCancelled || !self.isRunning { c.cancel(); return }
                    switch reply {
                    case .json(let status, let body): self.send(c, status: status, .json(status: status, body: body))
                    case .stream(let sub): await self.stream(c, sub)
                    }
                }
                // Registered only while the connection is still known; if it was cancelled in between, the work is cancelled too and nothing is left behind.
                self.lock.lock()
                let alive = self.connections[ObjectIdentifier(c)] != nil
                if alive { self.tasks[ObjectIdentifier(c)] = task }
                self.lock.unlock()
                if !alive { task.cancel() }
            }
        }
    }

    private var currentEndpoint: Endpoint? { lock.lock(); defer { lock.unlock() }; return endpoint }

    private func send(_ c: NWConnection, status: Int, _ reply: AutomationReply) {
        guard case .json(_, let body) = reply else { c.cancel(); return }
        c.send(content: AgentHTTP.response(status: status, reason: Self.reason(status), body: body), completion: .contentProcessed { _ in c.cancel() })
    }

    /// Server-Sent Events: one `id`/`event`/`data` block per event, and a comment line every three seconds (which is also how a client that has gone is noticed) so a silent line is told from a dead one.
    private func stream(_ c: NWConnection, _ sub: AutomationSubscription) async {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nConnection: close\r\n\r\nretry: 3000\r\n\r\n"
        c.send(content: Data(head.utf8), completion: .idempotent)
        // A stream lives at most an hour; the client reconnects (and is checked again) with Last-Event-ID.
        let started = Date()
        let keepalive = DispatchSource.makeTimerSource(queue: .global())
        keepalive.schedule(deadline: .now() + 3, repeating: 3)
        keepalive.setEventHandler { if Date().timeIntervalSince(started) > 3600 { sub.close() } else { c.send(content: Data(": keepalive\n\n".utf8), completion: .contentProcessed { if $0 != nil { sub.close() } }) } }
        keepalive.resume()
        let prior = sub.onClose
        sub.onClose = { prior?(); keepalive.cancel(); c.cancel() }
        // The client sends nothing more; a read that ends means it has gone.
        c.receive(minimumIncompleteLength: 1, maximumLength: 1) { d, _, finished, error in if finished || error != nil { sub.close() } }
        await withTaskCancellationHandler {
            while let event = await sub.next(), !Task.isCancelled, isRunning {
                guard let json = try? AutomationJSON.encoder.encode(event) else { continue }
                var block = Data("id: \(AutomationEventSequence.header(epoch: event.epoch, id: event.id))\nevent: \(event.type)\ndata: ".utf8); block.append(json); block.append(Data("\n\n".utf8))
                let failed = await withCheckedContinuation { (k: CheckedContinuation<Bool, Never>) in c.send(content: block, completion: .contentProcessed { k.resume(returning: $0 != nil) }) }
                if failed { break }
            }
        } onCancel: { sub.close() }
        keepalive.cancel()
        sub.close()
        c.cancel()
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"; case 202: "Accepted"; case 400: "Bad Request"; case 401: "Unauthorized"; case 403: "Forbidden"; case 404: "Not Found"
        case 409: "Conflict"; case 413: "Payload Too Large"; case 415: "Unsupported Media Type"; case 422: "Unprocessable Entity"; case 429: "Too Many Requests"
        case 503: "Service Unavailable"; default: "Error"
        }
    }
}
#endif
