import Foundation
import Network

// MARK: Asking the router to forward the listening port (PCP, RFC 6887, and NAT-PMP, RFC 6886)
//
// Off unless the person turned it on, and only while incoming connections are on and the listener has a port. The request goes to the router (the default gateway), nothing else, and says
// "forward this port to this Mac for a limited time". PCP is tried first (the newer protocol; it names this Mac's own address), then NAT-PMP, which most older routers speak. UPnP (see UPnP.swift) is the
// last resort when neither answers. The mapping is renewed before it runs out and released when incoming connections stop. A router that does not answer, or refuses, leaves things as they were:
// incoming connections still work for peers that can reach this Mac some other way, and the status says plainly that the router did not open the port. Nothing here claims the port is reachable
// from the internet; that is known only when a peer actually connects in.

enum NATPMP {
    static let port: UInt16 = 5351
    enum Proto: UInt8 { case udp = 1, tcp = 2 }

    private static func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
    private static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }

    /// version 0 | opcode | reserved(2) | internal port | suggested external port | lifetime. A lifetime of 0 (with external port 0) removes the mapping.
    static func mapRequest(_ proto: Proto, internalPort: UInt16, suggestedExternal: UInt16, lifetime: UInt32) -> Data {
        Data([0, proto.rawValue, 0, 0] + be16(internalPort) + be16(suggestedExternal) + be32(lifetime))
    }

    struct MapReply: Equatable, Sendable {
        var result: UInt16
        var epoch: UInt32
        var internalPort: UInt16
        var externalPort: UInt16
        var lifetime: UInt32
    }

    /// nil unless it is a well-formed answer to a mapping request of this kind (version 0, opcode 128 + request opcode, 16 bytes).
    static func parseMap(_ d: Data, proto: Proto) -> MapReply? {
        let b = [UInt8](d)
        guard b.count == 16, b[0] == 0, b[1] == 128 + proto.rawValue else { return nil }
        func u16(_ i: Int) -> UInt16 { UInt16(b[i]) << 8 | UInt16(b[i + 1]) }
        func u32(_ i: Int) -> UInt32 { UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3]) }
        return MapReply(result: u16(2), epoch: u32(4), internalPort: u16(8), externalPort: u16(10), lifetime: u32(12))
    }

    static func resultText(_ code: UInt16) -> String {
        switch code {
        case 0: "Success"
        case 1: "The router does not support this version"
        case 2: "The router refused (port forwarding is turned off, or not allowed)"
        case 3: "The router's network has failed"
        case 4: "The router is out of resources"
        case 5: "The router does not support this kind of request"
        default: "The router answered with an error (\(code))"
        }
    }
}

/// PCP (RFC 6887) MAP opcode over IPv4. The request is 60 bytes: a 24-byte header (version 2, MAP, lifetime, this Mac's address) and the 36-byte MAP body (nonce, protocol, ports).
enum PCP {
    enum Proto: UInt8 { case tcp = 6, udp = 17 }

    private static func mapped(_ ipv4: [UInt8]) -> [UInt8] { [UInt8](repeating: 0, count: 10) + [0xFF, 0xFF] + ipv4 }
    static func ipv4Bytes(_ text: String) -> [UInt8]? { IPv4Address(text).map { [UInt8]($0.rawValue) } }

    static func mapRequest(client: [UInt8], nonce: [UInt8], _ proto: Proto, internalPort: UInt16, suggestedExternal: UInt16, lifetime: UInt32) -> Data {
        var d: [UInt8] = [2, 1, 0, 0]
        d += [UInt8(lifetime >> 24), UInt8((lifetime >> 16) & 0xFF), UInt8((lifetime >> 8) & 0xFF), UInt8(lifetime & 0xFF)]
        d += mapped(client)
        d += nonce
        d += [proto.rawValue, 0, 0, 0]
        d += [UInt8(internalPort >> 8), UInt8(internalPort & 0xFF), UInt8(suggestedExternal >> 8), UInt8(suggestedExternal & 0xFF)]
        d += [UInt8](repeating: 0, count: 16)          // no suggested external address
        return Data(d)
    }

    struct MapReply: Equatable, Sendable {
        var result: UInt8
        var lifetime: UInt32
        var internalPort: UInt16
        var externalPort: UInt16
    }

    /// nil unless it is a 60-byte answer, version 2, to a MAP request (response bit set), carrying our nonce and protocol.
    static func parseMap(_ d: Data, nonce: [UInt8], _ proto: Proto) -> MapReply? {
        let b = [UInt8](d)
        guard b.count == 60, b[0] == 2, b[1] == 0x81, Array(b[24..<36]) == nonce, b[36] == proto.rawValue else { return nil }
        func u16(_ i: Int) -> UInt16 { UInt16(b[i]) << 8 | UInt16(b[i + 1]) }
        let life = UInt32(b[4]) << 24 | UInt32(b[5]) << 16 | UInt32(b[6]) << 8 | UInt32(b[7])
        return MapReply(result: b[3], lifetime: life, internalPort: u16(40), externalPort: u16(42))
    }

    static func resultText(_ code: UInt8) -> String {
        switch code {
        case 1: "The router does not support this version"
        case 2: "The router refused (port forwarding is not authorized)"
        case 3: "The router's network has failed"
        case 4: "The router is out of resources"
        case 5: "The router does not support this protocol"
        case 6: "The router does not allow this port"
        case 7: "The router does not allow this many mappings"
        case 8: "The router could not use the address we gave"
        case 11: "The router does not support this request"
        case 12: "The router's external address is not usable"
        default: "The router answered with an error (\(code))"
        }
    }
}

/// One request to the router and its answer. A seam so the mapper can be tested without a router.
protocol PortMapTransport: AnyObject, Sendable {
    /// Sends the request and returns the first datagram that comes back within `timeout`, or nil.
    func exchange(_ request: Data, timeout: TimeInterval) async -> Data?
    /// This Mac's IPv4 address on the way to the router (PCP names it in the request); nil when not known.
    var localIPv4: String? { get }
    func close()
}
extension PortMapTransport { var localIPv4: String? { nil } }

struct PortMappingStatus: Sendable, Equatable {
    enum State: String, Sendable { case off = "Off", asking = "Asking the router", mapped = "Router opened the port", failed = "Router did not open the port" }
    var state: State = .off
    var externalPort: UInt16?
    var message: String?
    /// "PCP" or "NAT-PMP": which of the two the router answered.
    var via: String?
}

final class PortMapper: @unchecked Sendable {
    typealias Sleep = @Sendable (TimeInterval) async -> Void

    /// What the router granted, kept so it can be removed again.
    private struct Grant { var pcp: Bool; var tcp: Bool; var nonce: [UInt8]; var client: [UInt8]; var port: UInt16; var upnp: UPnPService? = nil; var external: UInt16 = 0 }

    /// All mutable state, behind one lock, in synchronous methods (a lock is not held across an `await`).
    private final class Book: @unchecked Sendable {
        private let lock = NSLock()
        private var status = PortMappingStatus()
        private var task: Task<Void, Never>?
        private var port: UInt16 = 0
        private var transport: PortMapTransport?
        private var grants: [Grant] = []
        func currentStatus() -> PortMappingStatus { lock.lock(); defer { lock.unlock() }; return status }
        func setStatus(_ s: PortMappingStatus) { lock.lock(); status = s; lock.unlock() }
        func beginIfNew(port p: UInt16) -> (proceed: Bool, previous: Task<Void, Never>?, oldPort: UInt16) {
            lock.lock(); defer { lock.unlock() }
            if task != nil, port == p { return (false, nil, p) }
            let old = task, oldPort = port
            task = nil; port = p
            return (true, old, oldPort)
        }
        func setTask(_ t: Task<Void, Never>) { lock.lock(); task = t; lock.unlock() }
        func endAll() -> (Task<Void, Never>?, [Grant], PortMapTransport?) {
            lock.lock(); defer { lock.unlock() }
            let t = task, g = grants, tr = transport
            task = nil; port = 0; grants = []; transport = nil
            return (t, g, tr)
        }
        func swapTransport(_ new: PortMapTransport) { lock.lock(); let old = transport; transport = new; lock.unlock(); if old !== new { old?.close() } }
        func takeGrants() -> ([Grant], PortMapTransport?) { lock.lock(); defer { lock.unlock() }; let g = grants, tr = transport; grants = []; transport = nil; return (g, tr) }
        func setGrants(_ g: [Grant]) { lock.lock(); grants = g; lock.unlock() }
    }

    /// How long each attempt waits for the router (RFC 6886 starts at 250 ms and doubles; the total is bounded to a few seconds here).
    private let timeouts: [TimeInterval]
    private let lifetime: UInt32
    private let gateway: @Sendable () -> String?
    private let open: @Sendable (String) -> PortMapTransport?
    private let sleep: Sleep
    private let upnp: (@Sendable () -> UPnPTransport?)?
    private let book = Book()

    init(gateway: @escaping @Sendable () -> String?, open: @escaping @Sendable (String) -> PortMapTransport?, timeouts: [TimeInterval] = [0.25, 0.5, 1, 2], lifetime: UInt32 = 3600,
         upnp: (@Sendable () -> UPnPTransport?)? = nil, sleep: @escaping Sleep = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.gateway = gateway; self.open = open; self.timeouts = timeouts; self.lifetime = lifetime; self.upnp = upnp; self.sleep = sleep
    }

    var status: PortMappingStatus { book.currentStatus() }

    /// Starts (or restarts, for another port) asking the router. Safe to call again with the same port: nothing changes.
    func start(port: UInt16) {
        let begin = book.beginIfNew(port: port)
        guard begin.proceed else { return }
        begin.previous?.cancel()
        if begin.previous != nil, begin.oldPort != port { release(book.takeGrants()) }
        book.setStatus(PortMappingStatus(state: .asking))
        book.setTask(Task { [self] in await run(port: port) })
    }

    /// Stops renewing and asks the router to remove what it opened. Best effort: if the router is gone the mapping simply runs out at the end of its lifetime.
    func stop() {
        let (task, grants, transport) = book.endAll()
        task?.cancel()
        release((grants, transport))
        book.setStatus(PortMappingStatus())
    }

    private func release(_ taken: ([Grant], PortMapTransport?)) {
        let (grants, transport) = taken
        guard let transport else { return }
        guard !grants.isEmpty else { transport.close(); return }
        let first = timeouts.first ?? 0.25
        let upnpTransport = upnp?()
        Task.detached {
            for g in grants {
                if let service = g.upnp {
                    let call = UPnP.deletePortMapping(service, externalPort: g.external, tcp: g.tcp)
                    _ = await upnpTransport?.post(service.controlURL, headers: call.headers, body: call.body, timeout: 3)
                    continue
                }
                let request = g.pcp
                    ? PCP.mapRequest(client: g.client, nonce: g.nonce, g.tcp ? .tcp : .udp, internalPort: g.port, suggestedExternal: 0, lifetime: 0)
                    : NATPMP.mapRequest(g.tcp ? .tcp : .udp, internalPort: g.port, suggestedExternal: 0, lifetime: 0)
                _ = await transport.exchange(request, timeout: first)
            }
            transport.close()
        }
    }

    private enum Outcome { case granted(external: UInt16, lifetime: UInt32, grant: Grant), refused(String), silent }

    /// One protocol for one transport protocol, with bounded attempts.
    private func askPCP(_ tr: PortMapTransport, client: [UInt8], nonce: [UInt8], tcp: Bool, port: UInt16) async -> Outcome {
        let proto: PCP.Proto = tcp ? .tcp : .udp
        let request = PCP.mapRequest(client: client, nonce: nonce, proto, internalPort: port, suggestedExternal: port, lifetime: lifetime)
        for timeout in timeouts {
            if Task.isCancelled { return .silent }
            if let data = await tr.exchange(request, timeout: timeout) {
                // A router that only speaks NAT-PMP answers a version 2 request with a short version 0 packet: that is "not PCP", not an error.
                if let first = [UInt8](data).first, first == 0 { return .silent }
                if let r = PCP.parseMap(data, nonce: nonce, proto), r.internalPort == port {
                    if r.result == 0 { if r.externalPort == 0 { return .refused("The router did not give a port") }; return .granted(external: r.externalPort, lifetime: r.lifetime, grant: Grant(pcp: true, tcp: tcp, nonce: nonce, client: client, port: port)) }
                    if r.result == 1 { return .silent }          // UNSUPP_VERSION: try NAT-PMP
                    return .refused(PCP.resultText(r.result))
                }
            }
        }
        return .silent
    }

    private func askNATPMP(_ tr: PortMapTransport, tcp: Bool, port: UInt16) async -> Outcome {
        let proto: NATPMP.Proto = tcp ? .tcp : .udp
        let request = NATPMP.mapRequest(proto, internalPort: port, suggestedExternal: port, lifetime: lifetime)
        for timeout in timeouts {
            if Task.isCancelled { return .silent }
            if let data = await tr.exchange(request, timeout: timeout), let r = NATPMP.parseMap(data, proto: proto), r.internalPort == port {
                if r.result == 0 { if r.externalPort == 0 { return .refused("The router did not give a port") }; return .granted(external: r.externalPort, lifetime: r.lifetime, grant: Grant(pcp: false, tcp: tcp, nonce: [], client: [], port: port)) }
                return .refused(NATPMP.resultText(r.result))
            }
        }
        return .silent
    }

    /// UPnP: find the router's description, then add the forward. A permanent lease is used only when the router refuses every timed one (error 725), and is removed again on release.
    private func discoverUPnP(_ transport: UPnPTransport, gateway: String) async -> UPnPService? {
        for timeout in [1.0, 2.0] {
            if Task.isCancelled { return nil }
            guard let reply = await transport.search(gateway: gateway, timeout: timeout) else { continue }
            guard let location = UPnP.location(fromSearchReply: reply, gateway: gateway) else { return nil }
            guard let description = await transport.fetch(location, timeout: 3) else { return nil }
            return UPnP.service(fromDescription: description, location: location, gateway: gateway)
        }
        return nil
    }

    private func askUPnP(_ transport: UPnPTransport, service: UPnPService, client: String, tcp: Bool, port: UInt16) async -> Outcome {
        var lease = lifetime
        for attempt in 0..<2 {
            if Task.isCancelled { return .silent }
            let call = UPnP.addPortMapping(service, externalPort: port, internalPort: port, client: client, tcp: tcp, lease: lease)
            guard let answer = await transport.post(service.controlURL, headers: call.headers, body: call.body, timeout: 3) else { return .silent }
            if (200..<300).contains(answer.status) {
                return .granted(external: port, lifetime: lease == 0 ? 3600 : lease, grant: Grant(pcp: false, tcp: tcp, nonce: [], client: [], port: port, upnp: service, external: port))
            }
            let code = UPnP.errorCode(in: answer.body)
            if code == 725, attempt == 0 { lease = 0; continue }
            return .refused(UPnP.errorText(code))
        }
        return .silent
    }

    private func run(port: UInt16) async {
        // One nonce per protocol for the life of this run: a renewal that carried another nonce could be refused as someone else's mapping (RFC 6887).
        var nonces: [Bool: [UInt8]] = [:]
        for tcp in [true, false] { nonces[tcp] = (0..<12).map { _ in UInt8.random(in: 0...255) } }
        while !Task.isCancelled {
            guard let gw = gateway() else {
                book.setStatus(PortMappingStatus(state: .failed, message: "No router was found on this network."))
                await sleep(60); continue
            }
            guard let tr = open(gw) else {
                book.setStatus(PortMappingStatus(state: .failed, message: "The router could not be reached."))
                await sleep(60); continue
            }
            if Task.isCancelled { tr.close(); return }
            book.swapTransport(tr)
            var grants: [Grant] = [], externals: [Bool: UInt16] = [:], lifetimes: [UInt32] = []
            var failure: String?
            var viaPCP = false, viaUPnP = false, upnpTried = false
            var upnpService: UPnPService?
            let upnpTransport = upnp?()
            // The address of this Mac on the way to the router is known once the socket has a path: a moment is allowed for that.
            var local = tr.localIPv4
            for _ in 0..<3 where local == nil { try? await Task.sleep(nanoseconds: 100_000_000); local = tr.localIPv4 }
            let client = local.flatMap { PCP.ipv4Bytes($0) }
            for tcp in [true, false] {
                var outcome: Outcome = .silent
                if let client, let nonce = nonces[tcp] { outcome = await askPCP(tr, client: client, nonce: nonce, tcp: tcp, port: port) }
                if case .silent = outcome, !Task.isCancelled { outcome = await askNATPMP(tr, tcp: tcp, port: port) }
                if case .silent = outcome, !Task.isCancelled, let upnpTransport, let local {
                    if !upnpTried { upnpTried = true; upnpService = await discoverUPnP(upnpTransport, gateway: gw) }
                    if let service = upnpService { outcome = await askUPnP(upnpTransport, service: service, client: local, tcp: tcp, port: port) }
                }
                switch outcome {
                case .granted(let ext, let life, let grant): grants.append(grant); externals[tcp] = ext; lifetimes.append(life); if grant.pcp { viaPCP = true }; if grant.upnp != nil { viaUPnP = true }
                case .refused(let why): failure = why
                case .silent: failure = failure ?? "The router did not answer. It may not support PCP, NAT-PMP or UPnP, or port forwarding is turned off."
                }
                if failure != nil, grants.isEmpty { break }
            }
            if Task.isCancelled { if !grants.isEmpty { release((grants, tr)) }; return }          // what the router already granted is not left behind
            if grants.isEmpty {
                book.setStatus(PortMappingStatus(state: .failed, message: failure))
                await sleep(300); continue          // tried again in five minutes, not in a loop
            }
            book.setGrants(grants)
            book.setStatus(PortMappingStatus(state: .mapped, externalPort: externals[true] ?? externals[false], message: failure.map { "Only part of the request was accepted: \($0)" }, via: viaPCP ? "PCP" : (viaUPnP ? "UPnP" : "NAT-PMP")))
            await sleep(TimeInterval(max(30, (lifetimes.min() ?? lifetime) / 2)))          // renewed when half the time has passed
        }
    }
}


/// The real exchange: one connected UDP socket to the router's port 5351. (A connected socket is what the sandbox allows.)
final class NWPortMapTransport: PortMapTransport, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "browsersetu.portmap")
    private let lock = NSLock()
    private var waiter: ((Data?) -> Void)?
    private var token = 0
    private var closed = false

    init?(gateway: String, port: UInt16 = NATPMP.port) {
        guard IPv4Address(gateway) != nil, let p = NWEndpoint.Port(rawValue: port) else { return nil }          // all of these are used over IPv4 only
        connection = NWConnection(host: NWEndpoint.Host(gateway), port: p, using: .udp)
        connection.start(queue: queue)
        receiveLoop()
    }

    var localIPv4: String? {
        if case .hostPort(let host, _)? = connection.currentPath?.localEndpoint, case .ipv4(let a) = host { return "\(a)" }
        return nil
    }

    private func receiveLoop() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.lock.lock(); let w = self.waiter; self.waiter = nil; self.lock.unlock(); w?(data) }
            if error == nil, !self.isClosed { self.receiveLoop() }
        }
    }
    private var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    func exchange(_ request: Data, timeout: TimeInterval) async -> Data? {
        await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            let once = OnceBox(cont)
            lock.lock(); token += 1; let mine = token; waiter = { once.finish($0) }; lock.unlock()
            connection.send(content: request, completion: .contentProcessed { error in if error != nil { once.finish(nil) } })
            // This exchange's timer clears only this exchange's waiter: an earlier, answered exchange must not cancel the next one.
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in if let self { self.lock.lock(); if self.token == mine { self.waiter = nil }; self.lock.unlock() }; once.finish(nil) }
        }
    }

    func close() { lock.lock(); closed = true; lock.unlock(); connection.cancel() }
}

private final class OnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<Data?, Never>?
    init(_ c: CheckedContinuation<Data?, Never>) { cont = c }
    func finish(_ d: Data?) { lock.lock(); let c = cont; cont = nil; lock.unlock(); c?.resume(returning: d) }
}
