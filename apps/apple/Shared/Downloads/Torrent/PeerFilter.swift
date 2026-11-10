import Foundation

/// A person's list of peer addresses never to connect to: single addresses or CIDR ranges, IPv4 or IPv6. At most 200 entries; an entry that is not an address or range is ignored.
struct PeerFilter: Sendable, Equatable {
    struct Range: Sendable, Equatable { var bytes: [UInt8]; var bits: Int }
    private(set) var ranges: [Range] = []
    static let maxEntries = 200

    init(_ entries: [String] = []) {
        for entry in entries.prefix(Self.maxEntries) {
            let parts = entry.trimmingCharacters(in: .whitespaces).split(separator: "/", maxSplits: 1).map(String.init)
            guard let host = parts.first, let ep = DHTEndpoint(host: host, port: 1) else { continue }
            let total = ep.ip.count * 8
            let bits = parts.count == 2 ? (Int(parts[1]).flatMap { (0...total).contains($0) ? $0 : nil } ?? -1) : total
            guard bits >= 0 else { continue }
            // ::ffff:a.b.c.d is the IPv4 address a.b.c.d (candidates are canonicalised the same way).
            if ep.ip.count == 16, ep.ip[0..<10].allSatisfy({ $0 == 0 }), ep.ip[10] == 0xFF, ep.ip[11] == 0xFF, bits >= 96 { ranges.append(Range(bytes: Array(ep.ip[12..<16]), bits: bits - 96)) }
            else { ranges.append(Range(bytes: ep.ip, bits: bits)) }
        }
    }

    func blocks(_ host: String) -> Bool {
        guard !ranges.isEmpty, let ep = DHTEndpoint(host: host.split(separator: "%").first.map(String.init) ?? host, port: 1) else { return false }
        return ranges.contains { r in
            guard r.bytes.count == ep.ip.count else { return false }
            let full = r.bits / 8, rest = r.bits % 8
            guard Array(ep.ip[0..<full]) == Array(r.bytes[0..<full]) else { return false }
            guard rest > 0 else { return true }
            let mask = UInt8(0xFF << (8 - rest) & 0xFF)
            return ep.ip[full] & mask == r.bytes[full] & mask
        }
    }
}

/// What is known about one peer address across attempts: how often it failed us, when it may be tried again, and what it gave. Used to choose whom to connect to next; a refusal that is our own
/// (a proxy that cannot carry the connection, a permission that was taken back) never counts against the peer.
struct PeerRecord: Sendable, Equatable {
    var failures = 0
    var nextAttempt: TimeInterval = 0
    var bytesReceived: Int64 = 0
    var piecesVerified = 0
    var lastAttempt: TimeInterval = 0

    static let maxBackoff: TimeInterval = 900
    mutating func failed(at now: TimeInterval) { failures += 1; lastAttempt = now; nextAttempt = now + min(Self.maxBackoff, 15 * pow(2, Double(min(failures - 1, 6)))) }
    mutating func succeeded() { failures = 0; nextAttempt = 0 }
    /// Higher is better: proven givers first, then those with no history, then those that have failed.
    var score: Double { Double(piecesVerified) * 10 + log2(1 + Double(bytesReceived) / 16_384) - Double(failures) * 3 }
}

extension PeerAddress {
    /// The one spelling of an address: IPv6 compressed and lower case, an IPv4-mapped IPv6 address as plain IPv4, a scope id kept. Two spellings of one peer are then one candidate.
    var canonical: PeerAddress {
        let scope = host.split(separator: "%", maxSplits: 1).dropFirst().first.map { "%" + $0 } ?? ""
        let bare = host.split(separator: "%").first.map(String.init) ?? host
        guard let ep = DHTEndpoint(host: bare, port: port) else { return self }
        if ep.isIPv6, ep.ip[0..<10].allSatisfy({ $0 == 0 }), ep.ip[10] == 0xFF, ep.ip[11] == 0xFF, let v4 = DHTEndpoint(ip: Array(ep.ip[12..<16]), port: port) { return PeerAddress(host: v4.host, port: port) }
        return PeerAddress(host: ep.host + scope, port: port)
    }
    var isIPv6: Bool { host.contains(":") }
}
