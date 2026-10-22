#if DIRECT_BUILD
import Foundation
import Network

/// A tiny HTTP server on this Mac's loopback address. It hands each valid request body to `handle` and sends back what that returns.
///
/// The token is read through `tokenProvider` on every request, so a new token ends the old one at once. Every open connection is tracked so `stop()`
/// can cut them all, and a client that does not send a whole, correct request in ten seconds is dropped.
final class AgentServer: @unchecked Sendable {
    static let maxConnections = 8
    static let headerDeadline: TimeInterval = 10
    static let requestDeadline: TimeInterval = 300

    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var attempts = 0
    private var stopped = false

    var connectionCount: Int { lock.lock(); defer { lock.unlock() }; return connections.count }

    func start(port: UInt16, tokenProvider: @escaping @Sendable () -> String?, onPort: @escaping @Sendable (UInt16) -> Void,
               onFailure: @escaping @Sendable (String) -> Void, handle: @escaping @Sendable (Data) async -> Data?) {
        lock.lock(); stopped = false; lock.unlock()
        begin(port: port, tokenProvider: tokenProvider, onPort: onPort, onFailure: onFailure, handle: handle)
    }

    private func begin(port: UInt16, tokenProvider: @escaping @Sendable () -> String?, onPort: @escaping @Sendable (UInt16) -> Void,
                       onFailure: @escaping @Sendable (String) -> Void, handle: @escaping @Sendable (Data) async -> Data?) {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        guard let wanted = NWEndpoint.Port(rawValue: port) else { onFailure("Bad port"); return }
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host("127.0.0.1"), port: wanted)
        guard let created = try? NWListener(using: parameters) else { onFailure("Could not open port \(port)"); return }
        lock.lock(); listener = created; lock.unlock()
        created.newConnectionHandler = { [weak self] connection in self?.accept(connection, tokenProvider: tokenProvider, port: port, handle: handle) }
        created.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: onPort(port)
            case .failed:
                created.cancel()
                // The port is busy: try the next few before giving up.
                self.lock.lock(); self.attempts += 1; let tries = self.attempts; let done = self.stopped; self.lock.unlock()
                if done { return }
                if tries < 10, port < 65_534 { self.begin(port: port + 1, tokenProvider: tokenProvider, onPort: onPort, onFailure: onFailure, handle: handle) }
                else { onFailure("No free port") }
            default: break
            }
        }
        created.start(queue: DispatchQueue(label: "browsersetu.agent"))
    }

    /// Closes the listener and every connection that is open, including a request still waiting for an answer.
    func stop() {
        lock.lock()
        stopped = true
        let open = Array(connections.values)
        connections = [:]
        let current = listener
        listener = nil
        lock.unlock()
        current?.cancel()
        for connection in open { connection.cancel() }
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var on = false
        func set() { lock.lock(); on = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return on }
    }

    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ more: Data) -> Data { lock.lock(); defer { lock.unlock() }; data.append(more); return data }
    }

    private func register(_ connection: NWConnection) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if stopped || connections.count >= Self.maxConnections { return false }
        connections[ObjectIdentifier(connection)] = connection
        return true
    }

    private func forget(_ connection: NWConnection) {
        lock.lock(); connections[ObjectIdentifier(connection)] = nil; lock.unlock()
    }

    private func accept(_ connection: NWConnection, tokenProvider: @escaping @Sendable () -> String?, port: UInt16, handle: @escaping @Sendable (Data) async -> Data?) {
        // Only a few connections at once, so nothing on this Mac can tie the server up.
        guard register(connection) else { connection.cancel(); return }
        connection.stateUpdateHandler = { [weak self] state in if case .cancelled = state { self?.forget(connection) } }
        connection.start(queue: DispatchQueue(label: "browsersetu.agent.connection"))
        let buffer = Buffer()
        let accepted = Gate()
        // A client that has not sent a whole, correct request in ten seconds is dropped. An accepted request may wait up to five minutes (a question left on
        // screen), and then it is dropped too.
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.headerDeadline) { if !accepted.isSet { connection.cancel() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.requestDeadline) { connection.cancel() }

        func send(_ data: Data) {
            if isStopped { connection.cancel(); return }
            connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
        }

        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, finished, error in
                guard let self, !self.isStopped else { connection.cancel(); return }
                let all = buffer.append(data ?? Data())
                switch AgentHTTP.parse(all) {
                case .needMore:
                    if finished || error != nil { connection.cancel() } else { receive() }
                case .bad(let why):
                    send(AgentHTTP.response(status: 400, reason: why))
                case .request(let request):
                    switch AgentHTTP.authorize(request, token: tokenProvider() ?? "", port: port) {
                    case .reject(let status, let reason):
                        send(AgentHTTP.response(status: status, reason: reason))
                    case .ok:
                        accepted.set()
                        Task {
                            let reply = await handle(request.body)
                            // Stopped while the request was being handled: nothing is sent.
                            if self.isStopped { connection.cancel(); return }
                            if let reply { send(AgentHTTP.response(status: 200, reason: "OK", body: reply)) }
                            else { send(AgentHTTP.response(status: 202, reason: "Accepted")) }
                        }
                    }
                }
            }
        }
        receive()
    }
}
#endif
