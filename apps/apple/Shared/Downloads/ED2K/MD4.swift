import Foundation

/// MD4 (RFC 1320), written from the RFC. It exists only because the eD2k network identifies files and checks their parts with it.
///
/// MD4 is broken: collisions can be made on purpose. A matching MD4 therefore says "this is the file the network calls by that name", and that a part arrived intact by accident-proof
/// standards; it does not say the file is genuine or safe. Nothing in the app presents it as proof of authenticity.
struct MD4: Sendable {
    private var a: UInt32 = 0x67452301, b: UInt32 = 0xefcdab89, c: UInt32 = 0x98badcfe, d: UInt32 = 0x10325476
    private var buffer = [UInt8]()
    private var length: UInt64 = 0
    private var words = [UInt32](repeating: 0, count: 16)

    init() { buffer.reserveCapacity(64) }

    mutating func update(_ data: Data) { data.withUnsafeBytes { update($0.bindMemory(to: UInt8.self)) } }

    mutating func update(_ bytes: UnsafeBufferPointer<UInt8>) {
        length &+= UInt64(bytes.count)
        var index = 0
        if !buffer.isEmpty {
            let need = 64 - buffer.count
            let take = min(need, bytes.count)
            buffer.append(contentsOf: bytes[0..<take]); index = take
            if buffer.count == 64 { buffer.withUnsafeBufferPointer { process($0.baseAddress!) }; buffer.removeAll(keepingCapacity: true) }
        }
        while bytes.count - index >= 64 { process(bytes.baseAddress! + index); index += 64 }
        if index < bytes.count { buffer.append(contentsOf: bytes[index...]) }
    }

    mutating func finalize() -> Data {
        let bitLength = length &* 8
        var tail = [UInt8](buffer)
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        for i in 0..<8 { tail.append(UInt8((bitLength >> (8 * UInt64(i))) & 0xFF)) }
        var copy = self
        copy.buffer.removeAll()
        tail.withUnsafeBufferPointer { p in var off = 0; while off < p.count { copy.process(p.baseAddress! + off); off += 64 } }
        var out = Data(capacity: 16)
        for v in [copy.a, copy.b, copy.c, copy.d] { for i in 0..<4 { out.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
        return out
    }

    static func hash(_ data: Data) -> Data { var m = MD4(); m.update(data); return m.finalize() }

    private static func rotl(_ x: UInt32, _ s: UInt32) -> UInt32 { (x << s) | (x >> (32 - s)) }

    private mutating func process(_ block: UnsafePointer<UInt8>) {
        var x = words; words = []                           // taken, not copied: one scratch array per hash, not one per block
        defer { words = x }
        for i in 0..<16 { x[i] = UInt32(block[i * 4]) | UInt32(block[i * 4 + 1]) << 8 | UInt32(block[i * 4 + 2]) << 16 | UInt32(block[i * 4 + 3]) << 24 }
        var (aa, bb, cc, dd) = (a, b, c, d)
        func f(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { (x & y) | (~x & z) }
        func g(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { (x & y) | (x & z) | (y & z) }
        func h(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { x ^ y ^ z }
        // Round 1
        for i in stride(from: 0, to: 16, by: 4) {
            aa = Self.rotl(aa &+ f(bb, cc, dd) &+ x[i], 3)
            dd = Self.rotl(dd &+ f(aa, bb, cc) &+ x[i + 1], 7)
            cc = Self.rotl(cc &+ f(dd, aa, bb) &+ x[i + 2], 11)
            bb = Self.rotl(bb &+ f(cc, dd, aa) &+ x[i + 3], 19)
        }
        // Round 2
        for i in 0..<4 {
            aa = Self.rotl(aa &+ g(bb, cc, dd) &+ x[i] &+ 0x5a827999, 3)
            dd = Self.rotl(dd &+ g(aa, bb, cc) &+ x[i + 4] &+ 0x5a827999, 5)
            cc = Self.rotl(cc &+ g(dd, aa, bb) &+ x[i + 8] &+ 0x5a827999, 9)
            bb = Self.rotl(bb &+ g(cc, dd, aa) &+ x[i + 12] &+ 0x5a827999, 13)
        }
        // Round 3
        for i in [0, 2, 1, 3] {
            aa = Self.rotl(aa &+ h(bb, cc, dd) &+ x[i] &+ 0x6ed9eba1, 3)
            dd = Self.rotl(dd &+ h(aa, bb, cc) &+ x[i + 8] &+ 0x6ed9eba1, 9)
            cc = Self.rotl(cc &+ h(dd, aa, bb) &+ x[i + 4] &+ 0x6ed9eba1, 11)
            bb = Self.rotl(bb &+ h(cc, dd, aa) &+ x[i + 12] &+ 0x6ed9eba1, 15)
        }
        a &+= aa; b &+= bb; c &+= cc; d &+= dd
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
    /// 2n hex characters to n bytes; nil if any character is not hex or the length is odd.
    init?(hex: String) {
        // ASCII only: Swift's isHexDigit also accepts full-width letters, which UInt8(radix:) does not.
        guard hex.count % 2 == 0, hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        var out = Data(); var i = hex.startIndex
        while i < hex.endIndex { let n = hex.index(i, offsetBy: 2); guard let byte = UInt8(hex[i..<n], radix: 16) else { return nil }; out.append(byte); i = n }
        self = out
    }
}
