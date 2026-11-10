import Foundation
import CryptoKit
import Darwin

// MARK: Mainline DHT — identifiers, addresses, messages, tokens, routing table (BEP 5, BEP 32, BEP 42)
//
// Everything in this file is pure: no sockets, no clocks of its own, no global state. `DHTNode` (DHTNode.swift) puts it on the network.

/// A 160-bit identifier: a node's, or a torrent's info-hash, which live in the same space.
struct NodeID: Hashable, Sendable, Comparable {
    let bytes: [UInt8]
    static let length = 20

    init?(_ data: Data) { guard data.count == Self.length else { return nil }; bytes = [UInt8](data) }
    init(bytes: [UInt8]) { precondition(bytes.count == Self.length); self.bytes = bytes }
    static func random() -> NodeID { NodeID(bytes: (0..<length).map { _ in UInt8.random(in: 0...255) }) }
    var data: Data { Data(bytes) }
    var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }
    init?(hex: String) {
        guard hex.count == 40 else { return nil }
        var out: [UInt8] = []; var i = hex.startIndex
        while i < hex.endIndex { let j = hex.index(i, offsetBy: 2); guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }; out.append(b); i = j }
        bytes = out
    }

    /// The XOR metric: how far apart two identifiers are.
    func distance(to other: NodeID) -> [UInt8] { zip(bytes, other.bytes).map { $0 ^ $1 } }
    static func < (a: NodeID, b: NodeID) -> Bool { a.bytes.lexicographicallyPrecedes(b.bytes) }

    func bit(_ index: Int) -> Int { Int((bytes[index / 8] >> UInt8(7 - index % 8)) & 1) }
    /// The number of leading bits two identifiers share (160 when equal).
    func commonPrefix(with other: NodeID) -> Int {
        for i in 0..<Self.length { let x = bytes[i] ^ other.bytes[i]; if x != 0 { return i * 8 + x.leadingZeroBitCount } }
        return 160
    }
}

/// Where a datagram came from or goes to: a numeric address and a port. Never a name (a name is looked up once, before this exists).
struct DHTEndpoint: Hashable, Sendable {
    let ip: [UInt8]                 // 4 or 16 bytes
    let port: UInt16
    var isIPv6: Bool { ip.count == 16 }

    init?(ip: [UInt8], port: UInt16) { guard ip.count == 4 || ip.count == 16 else { return nil }; self.ip = ip; self.port = port }

    init?(host: String, port: UInt16) {
        var v4 = in_addr(), v6 = in6_addr()
        let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if inet_pton(AF_INET, h, &v4) == 1 { self.init(ip: withUnsafeBytes(of: &v4) { Array($0) }, port: port) }
        else if inet_pton(AF_INET6, h, &v6) == 1 { self.init(ip: withUnsafeBytes(of: &v6) { Array($0) }, port: port) }
        else { return nil }
    }

    var host: String {
        var buffer = [CChar](repeating: 0, count: 64)
        if ip.count == 4 { var a = in_addr(); withUnsafeMutableBytes(of: &a) { $0.copyBytes(from: ip) }; inet_ntop(AF_INET, &a, &buffer, 64) }
        else { var a = in6_addr(); withUnsafeMutableBytes(of: &a) { $0.copyBytes(from: ip) }; inet_ntop(AF_INET6, &a, &buffer, 64) }
        return String(cString: buffer)
    }

    /// Compact form: address then port, big-endian (6 bytes for IPv4, 18 for IPv6).
    var compact: Data { var d = Data(ip); d.append(UInt8(port >> 8)); d.append(UInt8(port & 0xFF)); return d }
    init?(compact d: Data) {
        let b = [UInt8](d)
        guard b.count == 6 || b.count == 18 else { return nil }
        self.init(ip: Array(b[0..<(b.count - 2)]), port: UInt16(b[b.count - 2]) << 8 | UInt16(b[b.count - 1]))
    }

    /// Reachable on the open internet: a real port, and an address that is not this machine, a private or link-local network, or a reserved range.
    var isRoutable: Bool { port != 0 && !HTTPRequestPolicy.classify(host: host).isInternal }
    var isInternal: Bool { HTTPRequestPolicy.classify(host: host).isInternal }
    var peerAddress: PeerAddress { PeerAddress(host: host, port: port) }
}

struct DHTNodeInfo: Hashable, Sendable {
    var id: NodeID
    var endpoint: DHTEndpoint
}

enum DHTCompact {
    /// `nodes` (26 bytes each) and `nodes6` (38 bytes each). A length that is not a whole number of entries is refused whole.
    static func decodeNodes(_ data: Data, ipv6: Bool) -> [DHTNodeInfo] {
        let size = ipv6 ? 38 : 26, ipLen = ipv6 ? 16 : 4
        guard !data.isEmpty, data.count % size == 0, data.count <= size * 64 else { return [] }
        let b = [UInt8](data)
        return stride(from: 0, to: b.count, by: size).compactMap { o in
            guard let id = NodeID(Data(b[o..<(o + 20)])), let ep = DHTEndpoint(ip: Array(b[(o + 20)..<(o + 20 + ipLen)]), port: UInt16(b[o + 20 + ipLen]) << 8 | UInt16(b[o + 21 + ipLen])) else { return nil }
            return DHTNodeInfo(id: id, endpoint: ep)
        }
    }
    static func encodeNodes(_ nodes: [DHTNodeInfo]) -> Data { var d = Data(); for n in nodes { d.append(n.id.data); d.append(n.endpoint.compact) }; return d }

    /// `values` of a get_peers answer: each entry is one compact peer (6 or 18 bytes).
    static func decodePeers(_ values: [Bencode]) -> [DHTEndpoint] { values.prefix(200).compactMap { $0.data.flatMap { DHTEndpoint(compact: $0) } } }
}

// MARK: KRPC (BEP 5)

enum KRPC {
    static let maxDatagram = 2048
    static let queries: Set<String> = ["ping", "find_node", "get_peers", "announce_peer"]

    enum Message {
        case query(tid: Data, method: String, args: [String: Bencode], readOnly: Bool)
        case response(tid: Data, values: [String: Bencode])
        case error(tid: Data, code: Int, text: String)
        var tid: Data { switch self { case .query(let t, _, _, _), .response(let t, _), .error(let t, _, _): t } }
    }

    /// nil for anything that is not a well-formed message: too large, not bencoded, no type, no transaction, a type that is none of q/r/e, or a query without a name and arguments.
    static func parse(_ datagram: Data) -> Message? {
        guard !datagram.isEmpty, datagram.count <= maxDatagram,
              let root = (try? BencodeDecoder.decode(datagram, limits: .message))?.value.dict,
              let tid = root["t"]?.data, !tid.isEmpty, tid.count <= 20, let y = root["y"]?.string else { return nil }
        switch y {
        case "q":
            guard let method = root["q"]?.string, method.utf8.count <= 32, let args = root["a"]?.dict, args["id"]?.data?.count == NodeID.length else { return nil }
            return .query(tid: tid, method: method, args: args, readOnly: root["ro"]?.int == 1)
        case "r":
            guard let r = root["r"]?.dict, r["id"]?.data?.count == NodeID.length else { return nil }
            return .response(tid: tid, values: r)
        case "e":
            guard let e = root["e"]?.list, e.count >= 2, let code = e[0].int, let text = e[1].string else { return nil }
            return .error(tid: tid, code: Int(clamping: code), text: String(text.prefix(120)))
        default: return nil
        }
    }

    static func query(tid: Data, method: String, args: [String: Bencode], readOnly: Bool = true) -> Data {
        var root: [String: Bencode] = ["t": .bytes(tid), "y": .bytes(Data("q".utf8)), "q": .bytes(Data(method.utf8)), "a": .dict(args)]
        if readOnly { root["ro"] = .int(1) }          // BEP 43: we hold no listening port, so no one should expect us to answer from their table
        return BencodeDecoder.encode(.dict(root))
    }
    static func response(tid: Data, values: [String: Bencode]) -> Data { BencodeDecoder.encode(.dict(["t": .bytes(tid), "y": .bytes(Data("r".utf8)), "r": .dict(values)])) }
    static func error(tid: Data, code: Int, text: String) -> Data {
        BencodeDecoder.encode(.dict(["t": .bytes(tid), "y": .bytes(Data("e".utf8)), "e": .list([.int(Int64(code)), .bytes(Data(text.utf8))])]))
    }
}

// MARK: Tokens (BEP 5)

/// What proves that an announce_peer comes from the address that asked get_peers. A token is a keyed hash of the requester's address; the key changes every five minutes and the one before it
/// is still honoured, so a token lives between five and ten minutes. Nothing is stored per requester.
final class DHTTokens: @unchecked Sendable {
    static let rotation: TimeInterval = 300
    private let lock = NSLock()
    private var current = SymmetricKey(size: .bits256), previous = SymmetricKey(size: .bits256)
    private var rotatedAt: TimeInterval
    private let now: () -> TimeInterval

    init(now: @escaping () -> TimeInterval) { self.now = now; rotatedAt = now() }

    private func rotateIfNeeded() {
        let t = now()
        if t - rotatedAt >= Self.rotation * 2 { previous = SymmetricKey(size: .bits256); current = SymmetricKey(size: .bits256); rotatedAt = t }
        else if t - rotatedAt >= Self.rotation { previous = current; current = SymmetricKey(size: .bits256); rotatedAt = t }
    }
    private func make(_ key: SymmetricKey, _ ip: [UInt8]) -> Data { Data(HMAC<SHA256>.authenticationCode(for: Data(ip), using: key).prefix(8)) }

    func issue(for ip: [UInt8]) -> Data { lock.lock(); defer { lock.unlock() }; rotateIfNeeded(); return make(current, ip) }
    func isValid(_ token: Data, for ip: [UInt8]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        rotateIfNeeded()
        guard token.count == 8 else { return false }
        return Self.equal(token, make(current, ip)) || Self.equal(token, make(previous, ip))
    }
    private static func equal(_ a: Data, _ b: Data) -> Bool { a.count == b.count && zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0 }
}

// MARK: BEP 42

/// Whether a node's identifier fits its address (BEP 42): the first 21 bits are a CRC32C of the masked address mixed with a 3-bit value that is also the identifier's last 3 bits. Many nodes in
/// the wild do not follow it, so it is a preference when a bucket is full, never a requirement.
enum DHTNodeIDSecurity {
    static func isValid(_ id: NodeID, for ip: [UInt8]) -> Bool {
        let r = id.bytes[19] & 0x07
        var masked: [UInt8]
        if ip.count == 4 { masked = zip(ip, [0x03, 0x0f, 0x3f, 0xff] as [UInt8]).map { $0 & $1 }; masked[0] |= r << 5 }
        else if ip.count == 16 { masked = zip(ip.prefix(8), [0x01, 0x03, 0x07, 0x0f, 0x1f, 0x3f, 0x7f, 0xff] as [UInt8]).map { $0 & $1 }; masked[0] |= r << 5 }
        else { return false }
        let crc = crc32c(masked)
        return id.bytes[0] == UInt8(crc >> 24) && id.bytes[1] == UInt8((crc >> 16) & 0xFF) && (id.bytes[2] & 0xF8) == UInt8((crc >> 8) & 0xF8)
    }

    static func crc32c(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        return ~crc
    }
    private static let table: [UInt32] = (0..<256).map { i in var c = UInt32(i); for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0x82F6_3B78 : c >> 1 }; return c }
}

// MARK: Routing table (Kademlia, BEP 5)

struct DHTRoutingTable {
    struct Entry: Sendable {
        var info: DHTNodeInfo
        var lastSeen: TimeInterval?       // nil: heard of, never heard from
        var failures = 0
        var validID: Bool
        var isQuestionable: Bool { failures > 0 }
    }

    struct Bucket {
        var depth: Int                    // how many leading bits of `prefix` an id must share to belong here
        var prefix: NodeID
        var entries: [Entry] = []
        var replacements: [Entry] = []
        var touched: TimeInterval
    }

    static let k = 8
    static let maxReplacements = 6
    static let maxDepth = 40              // beyond this a bucket is never split: nodes this close to us are not worth a finer table
    static let staleAfter: TimeInterval = 15 * 60

    let own: NodeID
    private(set) var buckets: [Bucket]

    init(own: NodeID, now: TimeInterval = 0) { self.own = own; buckets = [Bucket(depth: 0, prefix: own, touched: now)] }

    var count: Int { buckets.reduce(0) { $0 + $1.entries.count } }
    var allEntries: [Entry] { buckets.flatMap(\.entries) }

    private func index(of id: NodeID) -> Int { buckets.firstIndex { id.commonPrefix(with: $0.prefix) >= $0.depth } ?? 0 }
    private func containsOwn(_ b: Bucket) -> Bool { own.commonPrefix(with: b.prefix) >= b.depth }

    enum Outcome: Equatable { case added, updated, replaced, cached, rejected }

    /// A node answered (or, with `heard: true`, was only named by another node). Rules that keep a hostile network from growing or steering the table: our own id is never stored, an id is bound to
    /// the endpoint it first came from, an address appears at most once, a full bucket far from us does not split, and a node that has failed is the first to be replaced.
    @discardableResult
    mutating func insert(_ info: DHTNodeInfo, heard: Bool = false, now: TimeInterval) -> Outcome {
        guard info.id != own, info.endpoint.port != 0 else { return .rejected }
        let valid = DHTNodeIDSecurity.isValid(info.id, for: info.endpoint.ip)
        var entry = Entry(info: info, lastSeen: heard ? nil : now, validID: valid)
        // Duplicates: the same id, or the same address.
        for b in buckets.indices {
            if let i = buckets[b].entries.firstIndex(where: { $0.info.id == info.id }) {
                guard buckets[b].entries[i].info.endpoint == info.endpoint else { return .rejected }          // an id does not move to another address
                if !heard { buckets[b].entries[i].lastSeen = now; buckets[b].entries[i].failures = 0; buckets[b].touched = now }
                return .updated
            }
            if buckets[b].entries.contains(where: { $0.info.endpoint.ip == info.endpoint.ip }) || buckets[b].replacements.contains(where: { $0.info.endpoint.ip == info.endpoint.ip }) { return .rejected }
        }
        for _ in 0..<(Self.maxDepth + 2) {
            let i = index(of: info.id)
            if buckets[i].entries.count < Self.k { buckets[i].entries.append(entry); if !heard { buckets[i].touched = now }; return .added }
            // Full. Split a bucket that covers our own id; otherwise make room only by replacing a node that has failed (or, failing that, one with an id that does not fit its address).
            if containsOwn(buckets[i]) && buckets[i].depth < Self.maxDepth { split(i); continue }
            if let bad = buckets[i].entries.firstIndex(where: { $0.isQuestionable || ($0.lastSeen.map { now - $0 > Self.staleAfter } ?? true) }) { buckets[i].entries[bad] = entry; return .replaced }
            if valid, !heard, let weak = buckets[i].entries.firstIndex(where: { !$0.validID }) { buckets[i].entries[weak] = entry; return .replaced }
            if buckets[i].replacements.count >= Self.maxReplacements { buckets[i].replacements.removeFirst() }
            entry.lastSeen = heard ? nil : now
            buckets[i].replacements.append(entry)
            return .cached
        }
        return .rejected
    }

    private mutating func split(_ i: Int) {
        let b = buckets[i], depth = b.depth
        func part(_ bit: Int) -> Bucket {
            var prefixBytes = b.prefix.bytes
            if depth < 160 { let mask = UInt8(0x80 >> (depth % 8)); if bit == 1 { prefixBytes[depth / 8] |= mask } else { prefixBytes[depth / 8] &= ~mask } }
            return Bucket(depth: depth + 1, prefix: NodeID(bytes: prefixBytes), touched: b.touched)
        }
        var zero = part(0), one = part(1)
        for e in b.entries { if e.info.id.bit(depth) == 0 { zero.entries.append(e) } else { one.entries.append(e) } }
        for e in b.replacements { if e.info.id.bit(depth) == 0 { zero.replacements.append(e) } else { one.replacements.append(e) } }
        buckets.replaceSubrange(i...i, with: [zero, one])
    }

    /// No answer from this node. After two failures it is questionable; a replacement waiting in its bucket takes its place.
    mutating func markFailed(_ id: NodeID) {
        let i = index(of: id)
        guard let n = buckets[i].entries.firstIndex(where: { $0.info.id == id }) else { return }
        buckets[i].entries[n].failures += 1
        if buckets[i].entries[n].failures >= 2 {
            if let r = buckets[i].replacements.popLast() { buckets[i].entries[n] = r } else if buckets[i].entries[n].failures >= 4 { buckets[i].entries.remove(at: n) }
        }
    }

    func closest(to target: NodeID, count: Int, ipv6: Bool? = nil) -> [DHTNodeInfo] {
        allEntries.filter { ipv6 == nil || $0.info.endpoint.isIPv6 == ipv6 }
            .sorted { $0.info.id.distance(to: target).lexicographicallyPrecedes($1.info.id.distance(to: target)) }
            .prefix(count).map(\.info)
    }

    /// Buckets that have had no contact for a while: each gets a lookup of a random id inside it.
    func staleTargets(now: TimeInterval) -> [NodeID] {
        buckets.filter { now - $0.touched > Self.staleAfter }.map { b in
            var bytes = NodeID.random().bytes
            for bit in 0..<min(b.depth, 160) { let mask = UInt8(0x80 >> (bit % 8)); if b.prefix.bit(bit) == 1 { bytes[bit / 8] |= mask } else { bytes[bit / 8] &= ~mask } }
            return NodeID(bytes: bytes)
        }
    }
    mutating func touchBucket(of id: NodeID, now: TimeInterval) { buckets[index(of: id)].touched = now }
    mutating func touchAll(now: TimeInterval) { for i in buckets.indices { buckets[i].touched = now } }
}
