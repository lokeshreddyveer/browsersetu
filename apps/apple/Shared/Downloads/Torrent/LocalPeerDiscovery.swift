import Foundation
import Network
import Darwin

// MARK: Local Service Discovery (BEP 14)
//
// Computers on one network tell each other which torrents they are sharing, by multicast: "BT-SEARCH * HTTP/1.1" to 239.192.152.143:6771 (IPv4) or [ff15::efc0:988f]:6771 (IPv6), carrying the
// TCP port and the info-hash. This app holds no listening port (see DX-04), so it announces nothing yet: `announcePort` is nil, and the announce path below only runs once there is a port to give.
// What it does today is listen, and offer the peers it hears of (computers on the same network, which is what makes them local peers needing the person's approval) to the torrent.

enum LocalServiceDiscovery {
    static let v4Group = "239.192.152.143", v6Group = "ff15::efc0:988f", port: UInt16 = 6771
    static let maxDatagram = 1400
    static let maxHashes = 8

    struct Announcement: Equatable { var port: UInt16; var infoHashes: [Data]; var cookie: String? }

    static func encode(infoHashes: [Data], port: UInt16, cookie: String, ipv6: Bool) -> Data {
        let host = ipv6 ? "[\(v6Group)]:\(Self.port)" : "\(v4Group):\(Self.port)"
        var text = "BT-SEARCH * HTTP/1.1\r\nHost: \(host)\r\nPort: \(port)\r\n"
        for h in infoHashes.prefix(maxHashes) { text += "Infohash: \(h.map { String(format: "%02x", $0) }.joined())\r\n" }
        text += "cookie: \(cookie)\r\n\r\n\r\n"
        return Data(text.utf8)
    }

    /// nil for anything that is not a well-formed announcement: too long, another request line, no valid port, no valid info-hash. At most `maxHashes` info-hashes are read.
    static func parse(_ data: Data) -> Announcement? {
        guard data.count <= maxDatagram, let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard lines.first == "BT-SEARCH * HTTP/1.1" else { return nil }
        var port: UInt16?, hashes: [Data] = [], cookie: String?
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased(), value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch name {
            case "port": if let p = UInt16(value), p != 0 { port = p }
            case "infohash":
                if hashes.count < maxHashes, value.count == 40, let id = NodeID(hex: value.lowercased()) { hashes.append(id.data) }
            case "cookie": cookie = String(value.prefix(64))
            default: break
            }
        }
        guard let port, !hashes.isEmpty else { return nil }
        return Announcement(port: port, infoHashes: hashes, cookie: cookie)
    }
}

protocol LANDatagramTransport: AnyObject {
    /// A datagram and the numeric address it came from (an IPv6 link-local address carries its interface, `fe80::1%en0`).
    var onReceive: ((Data, String) -> Void)? { get set }
    func start() throws
    func send(_ data: Data, ipv6: Bool)
    func close()
}

struct LANStatus: Sendable, Equatable {
    enum State: String, Sendable { case off = "Off", listening = "Listening", blocked = "Blocked", unavailable = "Unavailable" }
    var state: State = .off
    var peersFound = 0, announcementsHeard = 0, announcementsSent = 0
    var lastError: String?
    var needsSettings = false
}

protocol LANDiscovering: AnyObject, Sendable {
    func register(task: UUID, infoHash: Data, onPeers: @escaping @Sendable ([PeerAddress]) -> Void)
    func unregister(task: UUID)
    var status: LANStatus { get }
}

final class LocalPeerDiscovery: LANDiscovering, @unchecked Sendable {
    struct Config: Sendable {
        var announceEvery: TimeInterval = 300         // BEP 14: no more than once in five minutes for a torrent
        var perSourceEvery: TimeInterval = 30         // an announcement from one address for one torrent is acted on this seldom
        var maxSources = 256
        /// How many distinct announcements one address may have acted on in a window: a host cannot fill the candidate list by varying its port.
        var perAddress = 4
    }

    private let queue = DispatchQueue(label: "browsersetu.lsd")
    private let transport: LANDatagramTransport
    private let config: Config
    private let policy: @Sendable () -> DHTBlock?
    private let announcePort: @Sendable () -> UInt16?
    private let isPrivateHash: @Sendable (Data) -> Bool
    private let clock: @Sendable () -> TimeInterval
    private let pathGeneration: @Sendable () -> Int
    private let cookie = "bs-" + String((0..<8).map { _ in "0123456789abcdef".randomElement()! })

    private var tasks: [UUID: (hash: Data, deliver: @Sendable ([PeerAddress]) -> Void)] = [:]
    private var running = false
    private var timer: DispatchSourceTimer?
    private var lastAnnounced: [Data: TimeInterval] = [:]
    private var heard: [String: TimeInterval] = [:]
    private var perAddressCount: [String: (start: TimeInterval, count: Int)] = [:]
    private var generation = 0
    private var state = LANStatus.State.off, lastError: String?, needsSettings = false
    private var peersFound = 0, announcementsHeard = 0, announcementsSent = 0
    private(set) var droppedMalformed = 0, droppedRateLimited = 0, droppedNotLocal = 0, droppedOwn = 0

    private let statusLock = NSLock()
    private var published = LANStatus()
    var status: LANStatus { statusLock.lock(); defer { statusLock.unlock() }; return published }

    init(transport: LANDatagramTransport, config: Config = Config(), policy: @escaping @Sendable () -> DHTBlock?, announcePort: @escaping @Sendable () -> UInt16? = { nil },
         isPrivateHash: @escaping @Sendable (Data) -> Bool = { _ in false }, clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         pathGeneration: @escaping @Sendable () -> Int = { NetworkPathGate.shared.generation }) {
        self.transport = transport; self.config = config; self.policy = policy; self.announcePort = announcePort; self.isPrivateHash = isPrivateHash; self.clock = clock; self.pathGeneration = pathGeneration
        transport.onReceive = { [weak self] data, from in self?.queue.async { self?.receive(data, from: from) } }
    }

    func register(task: UUID, infoHash: Data, onPeers: @escaping @Sendable ([PeerAddress]) -> Void) {
        queue.async { [self] in
            guard !isPrivateHash(infoHash) else { return }          // a private torrent is never put on the local network
            tasks[task] = (infoHash, onPeers)
            startIfNeeded()
        }
    }

    func unregister(task: UUID) { queue.async { [self] in tasks[task] = nil; if tasks.isEmpty { shutdown(nil) } } }

    func stopNow(reason: String) { queue.async { [self] in tasks = [:]; shutdown(DHTBlock(reason: reason)) } }

    private func startIfNeeded() {
        guard !running else { return }
        if let block = policy() { publish(.blocked, block.reason, block.needsSettings); return }
        do { try transport.start() } catch { publish(.unavailable, "Local discovery could not listen: the system refused it (this build may not have the permission to receive local-network announcements)."); return }
        running = true; generation = pathGeneration()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t; t.resume()
        publish(.listening, nil)
    }

    private func shutdown(_ reason: DHTBlock?) {
        running = false
        timer?.cancel(); timer = nil
        transport.close()
        heard = [:]; lastAnnounced = [:]
        if let reason { publish(.blocked, reason.reason, reason.needsSettings) } else { publish(.off, nil) }
    }

    private func tick() {
        guard running else { return }
        if let block = policy() { shutdown(block); return }
        if pathGeneration() != generation {          // the network changed: the group is joined again on whatever is there now
            generation = pathGeneration(); transport.close()
            do { try transport.start() } catch { publish(.unavailable, "Local discovery could not listen: the system refused it (this build may not have the permission to receive local-network announcements)."); return }
            publish(.listening, nil)
        }
        guard let port = announcePort() else { return }          // nothing to announce without a port to accept connections on
        let t = clock()
        for (_, entry) in tasks where !isPrivateHash(entry.hash) && t - (lastAnnounced[entry.hash] ?? -1e9) >= config.announceEvery {
            lastAnnounced[entry.hash] = t
            for v6 in [false, true] { transport.send(LocalServiceDiscovery.encode(infoHashes: [entry.hash], port: port, cookie: cookie, ipv6: v6), ipv6: v6) }
            announcementsSent += 1
        }
        publishCounts()
    }

    private func receive(_ data: Data, from: String) {
        guard running else { return }
        guard let message = LocalServiceDiscovery.parse(data) else { droppedMalformed += 1; return }
        if message.cookie == cookie { droppedOwn += 1; return }          // our own announcement, heard back
        // Only a computer on the same network: a datagram claiming to come from the open internet is not local discovery.
        let bare = from.split(separator: "%").first.map(String.init) ?? from
        guard HTTPRequestPolicy.classify(host: bare).isInternal, let source = DHTEndpoint(host: bare, port: 1), !(source.ip.count == 4 ? source.ip[0] == 127 : source.ip.dropLast().allSatisfy { $0 == 0 } && source.ip.last == 1) else { droppedNotLocal += 1; return }          // a computer on the network, not this one
        announcementsHeard += 1
        let t = clock()
        for hash in message.infoHashes {
            guard let (_, entry) = tasks.first(where: { $0.value.hash == hash }), !isPrivateHash(hash) else { continue }
            let key = "\(from)|\(message.port)|\(hash.hashValue)"
            if let last = heard[key], t - last < config.perSourceEvery { droppedRateLimited += 1; continue }
            if heard.count >= config.maxSources { heard = heard.filter { t - $0.value < config.perSourceEvery } }
            guard heard.count < config.maxSources else { continue }
            var counter = perAddressCount[bare] ?? (t, 0)
            if t - counter.start >= config.perSourceEvery { counter = (t, 0) }
            if counter.count >= config.perAddress { droppedRateLimited += 1; continue }
            counter.count += 1
            if perAddressCount.count > 512 { perAddressCount = perAddressCount.filter { t - $0.value.start < config.perSourceEvery } }
            perAddressCount[bare] = counter
            heard[key] = t
            peersFound += 1
            entry.deliver([PeerAddress(host: from, port: message.port)])
        }
        publishCounts()
    }

    private func publishCounts() { publish(state, lastError, needsSettings) }
    private func publish(_ s: LANStatus.State, _ error: String?, _ settings: Bool = false) {
        state = s; lastError = error; needsSettings = settings
        statusLock.lock(); published = LANStatus(state: s, peersFound: peersFound, announcementsHeard: announcementsHeard, announcementsSent: announcementsSent, lastError: error, needsSettings: settings); statusLock.unlock()
    }
}

/// What the person's settings say about local discovery: off until they allow it; it speaks to the local network directly, which a proxy would not reach, so with a proxy it stays off and says how to change that.
enum LANNetworkPolicy {
    static func block(setup: DownloadNetworkSetup, enabled: Bool, lanEnabled: Bool, systemProxyActive: Bool) -> DHTBlock? {
        guard enabled, lanEnabled else { return DHTBlock(reason: "Local discovery is off.") }
        if DownloadProxy.problem(setup.proxy) != nil { return DHTBlock(reason: "The proxy settings cannot be used, so local discovery was not started.", needsSettings: true) }
        if DownloadProxy.configuration(for: setup.proxy, password: setup.proxyPassword) != nil || (setup.proxy.mode == .system && systemProxyActive) {
            return DHTBlock(reason: "Local discovery connects straight to computers on your network, which a proxy would not reach, so it was not started. Choose “No proxy” in Settings → Downloads to use it.", needsSettings: true)
        }
        return nil
    }
}

/// The multicast group, joined on an ordinary datagram socket (one per address family) and read with `recvfrom`, so each datagram says where it came from. Under the sandbox this needs the app's
/// `network.server` entitlement; without it `start()` fails and local discovery reports itself unavailable.
final class MulticastTransport: LANDatagramTransport, @unchecked Sendable {
    var onReceive: ((Data, String) -> Void)?
    private let queue = DispatchQueue(label: "browsersetu.lsd.socket")
    private var fd4: Int32 = -1, fd6: Int32 = -1
    private var sources: [DispatchSourceRead] = []
    private let lock = NSLock()

    func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard fd4 < 0, fd6 < 0 else { return }
        fd4 = Self.open(AF_INET); fd6 = Self.open(AF_INET6)
        guard fd4 >= 0 || fd6 >= 0 else { throw POSIXError(.EACCES) }
        for fd in [fd4, fd6] where fd >= 0 {
            let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            s.setEventHandler { [weak self] in self?.drain(fd) }
            s.setCancelHandler { Darwin.close(fd) }          // the descriptor is closed only once the source has stopped using it
            s.resume(); sources.append(s)
        }
    }

    private static func open(_ family: Int32) -> Int32 {
        let fd = socket(family, SOCK_DGRAM, 0)
        guard fd >= 0 else { return -1 }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(4)); setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(4))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let port = LocalServiceDiscovery.port.bigEndian
        var ok = false
        if family == AF_INET {
            var a = sockaddr_in(); a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET); a.sin_port = port; a.sin_addr.s_addr = INADDR_ANY
            ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
            if ok { var mreq = ip_mreq(); inet_pton(AF_INET, LocalServiceDiscovery.v4Group, &mreq.imr_multiaddr); mreq.imr_interface.s_addr = INADDR_ANY
                    ok = setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size)) == 0 }
            if ok { var loop: UInt8 = 1; setsockopt(fd, IPPROTO_IP, IP_MULTICAST_LOOP, &loop, 1) }
        } else {
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &yes, socklen_t(4))
            var a = sockaddr_in6(); a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size); a.sin6_family = sa_family_t(AF_INET6); a.sin6_port = port; a.sin6_addr = in6addr_any
            ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } } == 0
            if ok { var mreq = ipv6_mreq(); inet_pton(AF_INET6, LocalServiceDiscovery.v6Group, &mreq.ipv6mr_multiaddr); mreq.ipv6mr_interface = 0
                    ok = setsockopt(fd, IPPROTO_IPV6, IPV6_JOIN_GROUP, &mreq, socklen_t(MemoryLayout<ipv6_mreq>.size)) == 0 }
        }
        if !ok { Darwin.close(fd); return -1 }
        return fd
    }

    private func drain(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: LocalServiceDiscovery.maxDatagram + 1)
        for _ in 0..<32 {
            var storage = sockaddr_storage(); var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = withUnsafeMutablePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) } }
            if n <= 0 { return }
            guard n <= LocalServiceDiscovery.maxDatagram, let host = Self.host(storage) else { continue }
            onReceive?(Data(buffer[0..<n]), host)
        }
    }

    private static func host(_ s: sockaddr_storage) -> String? {
        var s = s
        return withUnsafePointer(to: &s) { p -> String? in
            var buffer = [CChar](repeating: 0, count: 64)
            if Int32(p.pointee.ss_family) == AF_INET {
                return p.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { a in var addr = a.pointee.sin_addr; return inet_ntop(AF_INET, &addr, &buffer, 64) == nil ? nil : String(cString: buffer) }
            }
            return p.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { a in
                var addr = a.pointee.sin6_addr
                guard inet_ntop(AF_INET6, &addr, &buffer, 64) != nil else { return nil }
                var name = String(cString: buffer)
                let scope = a.pointee.sin6_scope_id
                if scope != 0, name.lowercased().hasPrefix("fe80") { var ifname = [CChar](repeating: 0, count: Int(IF_NAMESIZE)); if if_indextoname(scope, &ifname) != nil { name += "%" + String(cString: ifname) } }
                return name
            }
        }
    }

    func send(_ data: Data, ipv6: Bool) {
        lock.lock(); let fd = ipv6 ? fd6 : fd4; lock.unlock()
        guard fd >= 0, data.count <= LocalServiceDiscovery.maxDatagram else { return }
        let port = LocalServiceDiscovery.port.bigEndian
        if ipv6 {
            var a = sockaddr_in6(); a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size); a.sin6_family = sa_family_t(AF_INET6); a.sin6_port = port; inet_pton(AF_INET6, LocalServiceDiscovery.v6Group, &a.sin6_addr)
            data.withUnsafeBytes { raw in withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = sendto(fd, raw.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } } }
        } else {
            var a = sockaddr_in(); a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET); a.sin_port = port; inet_pton(AF_INET, LocalServiceDiscovery.v4Group, &a.sin_addr)
            data.withUnsafeBytes { raw in withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = sendto(fd, raw.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } }
        }
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        for s in sources { s.cancel() }; sources = []
        fd4 = -1; fd6 = -1
    }
}
