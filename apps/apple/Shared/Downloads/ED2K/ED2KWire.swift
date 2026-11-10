import Compression
import Foundation

/// The eD2k TCP protocol: packets, tags and the messages a downloader needs. Pure bytes-in, values-out; strangers send these bytes, so every length is checked before it is believed.
///
/// Layouts come from the Kulbak & Bickson protocol specification (2005, with known errors) and the field layouts in aMule's protocol headers (read for facts only; no code is copied).
/// Where the two disagree the parser accepts both and checks which one fits the bytes. What is NOT covered: obfuscation, secure identification, compressed parts, and the Kad network.
enum ED2KWire {
    static let edonkey: UInt8 = 0xE3, emule: UInt8 = 0xC5, packed: UInt8 = 0xD4
    /// Longest payload accepted. A block is 180 KiB; the biggest thing a server sends that is read is a list of 255 sources.
    static let maxPayload = 1 << 20
    static let maxTags = 64
    static let maxStringBytes = 4096

    enum Failure: Error, Equatable, LocalizedError {
        case tooLong(UInt32), badLength, badPacked, badMessage(String)
        var errorDescription: String? {
            switch self {
            case .tooLong: "A message was longer than is allowed."
            case .badLength: "A message had an invalid length."
            case .badPacked: "A compressed message could not be read."
            case .badMessage(let why): "A message was not valid (\(why))."
            }
        }
    }

    enum Op {
        // client -> server
        static let loginRequest: UInt8 = 0x01, getSources: UInt8 = 0x19
        // server -> client
        static let serverMessage: UInt8 = 0x38, idChange: UInt8 = 0x40, serverStatus: UInt8 = 0x34, serverIdent: UInt8 = 0x41, foundSources: UInt8 = 0x42, reject: UInt8 = 0x05
        // client <-> client (eDonkey)
        static let hello: UInt8 = 0x01, helloAnswer: UInt8 = 0x4C, sendingPart: UInt8 = 0x46, requestParts: UInt8 = 0x47, fileNotFound: UInt8 = 0x48, endOfDownload: UInt8 = 0x49
        static let setReqFileID: UInt8 = 0x4F, fileStatus: UInt8 = 0x50, hashsetRequest: UInt8 = 0x51, hashsetAnswer: UInt8 = 0x52, startUploadReq: UInt8 = 0x54
        static let acceptUploadReq: UInt8 = 0x55, cancelTransfer: UInt8 = 0x56, outOfPartReqs: UInt8 = 0x57, requestFileName: UInt8 = 0x58, reqFileNameAnswer: UInt8 = 0x59, queueRank: UInt8 = 0x5C
        // client <-> client (eMule extended)
        static let compressedPart: UInt8 = 0x40, queueRanking: UInt8 = 0x60, sendingPart64: UInt8 = 0xA2, requestParts64: UInt8 = 0xA3, compressedPart64: UInt8 = 0xA1
    }

    // MARK: Packets

    struct Packet: Equatable {
        var proto: UInt8
        var opcode: UInt8
        var payload: Data
    }

    /// Header: protocol byte, 4-byte little-endian length (which counts the opcode), opcode.
    static func encode(_ p: Packet) -> Data {
        var out = Data([p.proto])
        out.append(le32(UInt32(p.payload.count + 1)))
        out.append(p.opcode); out.append(p.payload)
        return out
    }

    static func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
    static func le32(_ v: UInt32) -> Data { Data((0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) }) }
    static func le64(_ v: UInt64) -> Data { Data((0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xFF) }) }

    /// Cuts a byte stream into packets, holding at most one unfinished packet, and refusing a length before waiting for its bytes.
    struct Parser {
        private var buffer = Data()
        mutating func feed(_ data: Data) throws -> [Packet] {
            buffer.append(data)
            var out: [Packet] = []
            while buffer.count >= 6 {
                let b = [UInt8](buffer.prefix(6))
                let proto = b[0]
                guard proto == ED2KWire.edonkey || proto == ED2KWire.emule || proto == ED2KWire.packed else { throw Failure.badMessage("an unknown protocol byte") }
                let length = UInt32(b[1]) | UInt32(b[2]) << 8 | UInt32(b[3]) << 16 | UInt32(b[4]) << 24
                guard length >= 1 else { throw Failure.badLength }
                guard Int(length) - 1 <= ED2KWire.maxPayload else { throw Failure.tooLong(length) }
                let total = 5 + Int(length)
                guard buffer.count >= total else { break }
                let payload = buffer.subdata(in: (buffer.startIndex + 6)..<(buffer.startIndex + total))
                buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + total))
                if proto == ED2KWire.packed {
                    out.append(Packet(proto: ED2KWire.emule, opcode: b[5], payload: try ED2KWire.inflate(payload)))       // a packed packet carries a compressed payload and is then an eMule packet
                } else { out.append(Packet(proto: proto, opcode: b[5], payload: payload)) }
            }
            return out
        }
        var buffered: Int { buffer.count }
    }

    /// zlib data (2-byte header, deflate, 4-byte checksum) to bytes, never more than `maxPayload`.
    static func inflate(_ data: Data) throws -> Data {
        guard data.count > 6, data[data.startIndex] & 0x0F == 8 else { throw Failure.badPacked }
        let raw = data.subdata(in: (data.startIndex + 2)..<(data.endIndex - 4))
        var out = [UInt8](repeating: 0, count: maxPayload + 1)
        let n = raw.withUnsafeBytes { src in out.withUnsafeMutableBytes { dst in compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, dst.count, src.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, COMPRESSION_ZLIB) } }
        guard n > 0, n <= maxPayload else { throw Failure.badPacked }
        return Data(out[0..<n])
    }

    // MARK: Reading values

    struct Reader {
        let data: Data
        var position = 0
        init(_ data: Data) { self.data = data }
        var remaining: Int { data.count - position }
        mutating func bytes(_ n: Int) throws -> Data {
            guard n >= 0, n <= remaining else { throw Failure.badMessage("it ends too soon") }
            defer { position += n }
            return data.subdata(in: (data.startIndex + position)..<(data.startIndex + position + n))
        }
        mutating func u8() throws -> UInt8 { try bytes(1)[0] }
        mutating func u16() throws -> UInt16 { let b = try bytes(2); return UInt16(b[b.startIndex]) | UInt16(b[b.startIndex + 1]) << 8 }
        mutating func u32() throws -> UInt32 { let b = [UInt8](try bytes(4)); return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24 }
        mutating func u64() throws -> UInt64 { let b = [UInt8](try bytes(8)); return (0..<8).reduce(UInt64(0)) { $0 | UInt64(b[$1]) << (8 * UInt64($1)) } }
        mutating func hash() throws -> Data { try bytes(16) }
        mutating func rest() -> Data { let d = data.subdata(in: (data.startIndex + position)..<data.endIndex); position = data.count; return d }
    }

    // MARK: Tags

    struct Tag: Equatable {
        enum Value: Equatable { case string(String), uint(UInt64), hash(Data), blob(Data), float(Float), bool(Bool) }
        var id: UInt8?
        var name: String?
        var value: Value
    }

    static func readTags(_ r: inout Reader, count: Int) throws -> [Tag] {
        guard count >= 0, count <= maxTags else { throw Failure.badMessage("too many tags") }
        var tags: [Tag] = []
        for _ in 0..<count {
            var type = try r.u8()
            var id: UInt8?, name: String?
            if type & 0x80 != 0 { type &= 0x7F; id = try r.u8() }
            else {
                let n = Int(try r.u16())
                guard n <= 256 else { throw Failure.badMessage("a tag name is too long") }
                let raw = try r.bytes(n)
                if n == 1 { id = raw[raw.startIndex] } else { name = String(data: raw, encoding: .utf8) }
            }
            let value: Tag.Value
            switch type {
            case 1: value = .hash(try r.hash())
            case 2: let n = Int(try r.u16()); guard n <= maxStringBytes else { throw Failure.badMessage("a string is too long") }; value = .string(String(decoding: try r.bytes(n), as: UTF8.self))
            case 3: value = .uint(UInt64(try r.u32()))
            case 4: value = .float(Float(bitPattern: try r.u32()))
            case 5: value = .bool(try r.u8() != 0)
            case 7, 0x0A:
                let n = type == 7 ? Int(try r.u32()) : Int(try r.u8()); guard n <= maxStringBytes else { throw Failure.badMessage("a blob is too long") }; value = .blob(try r.bytes(n))
            case 8: value = .uint(UInt64(try r.u16()))
            case 9: value = .uint(UInt64(try r.u8()))
            case 0x0B: value = .uint(try r.u64())
            case 0x11...0x20: value = .string(String(decoding: try r.bytes(Int(type) - 0x10), as: UTF8.self))
            default: throw Failure.badMessage("an unknown tag type")
            }
            tags.append(Tag(id: id, name: name, value: value))
        }
        return tags
    }

    static func tag(id: UInt8, string: String) -> Data {
        let s = Data(string.utf8.prefix(255))
        return Data([2]) + le16(1) + Data([id]) + le16(UInt16(s.count)) + s
    }
    static func tag(id: UInt8, uint: UInt32) -> Data { Data([3]) + le16(1) + Data([id]) + le32(uint) }

    // MARK: Client -> server

    /// A random user hash with the two marker bytes eMule-compatible servers look for.
    static func newUserHash() -> Data {
        var h = (0..<16).map { _ in UInt8.random(in: 0...255) }
        h[5] = 14; h[14] = 111
        return Data(h)
    }

    /// Port 0: nothing listens, which servers answer with a LowID; sources that are LowID are unreachable for this client and are counted as such.
    static func loginRequest(userHash: Data, nickname: String) -> Packet {
        var p = userHash + le32(0) + le16(0) + le32(3)
        p += tag(id: 0x01, string: nickname) + tag(id: 0x11, uint: 0x3C) + tag(id: 0x20, uint: 0x0001)         // name, version, server flags (zlib supported by us: no — only "new tags")
        return Packet(proto: edonkey, opcode: Op.loginRequest, payload: p)
    }

    static func getSources(hash: Data, size: Int64) -> Packet {
        var p = hash
        if size <= Int64(UInt32.max) { p += le32(UInt32(size)) } else { p += le32(0) + le64(UInt64(size)) }
        return Packet(proto: edonkey, opcode: Op.getSources, payload: p)
    }

    // MARK: Server -> client

    struct IDChange: Equatable { var id: UInt32; var flags: UInt32?; var isLowID: Bool { id < 0x0100_0000 } }

    static func parseIDChange(_ payload: Data) throws -> IDChange {
        var r = Reader(payload)
        let id = try r.u32()
        let flags = r.remaining >= 4 ? try r.u32() : nil
        return IDChange(id: id, flags: flags)
    }

    static func parseServerMessage(_ payload: Data) throws -> String {
        var r = Reader(payload)
        let n = Int(try r.u16())
        guard n <= maxStringBytes else { throw Failure.badMessage("a server message is too long") }
        return String(decoding: try r.bytes(n), as: UTF8.self)
    }

    static func parseServerStatus(_ payload: Data) throws -> (users: UInt32, files: UInt32) { var r = Reader(payload); return (try r.u32(), try r.u32()) }

    struct SourceEntry: Equatable { var id: UInt32; var port: UInt16
        var isLowID: Bool { id < 0x0100_0000 }
        /// The first byte on the wire is the first octet (the id is the address read as little-endian).
        var host: String { "\(id & 0xFF).\((id >> 8) & 0xFF).\((id >> 16) & 0xFF).\(id >> 24)" }
    }

    static func parseFoundSources(_ payload: Data) throws -> (hash: Data, sources: [SourceEntry]) {
        var r = Reader(payload)
        let hash = try r.hash()
        let count = Int(try r.u8())
        guard r.remaining >= count * 6 else { throw Failure.badMessage("the source list is shorter than it says") }
        var out: [SourceEntry] = []
        for _ in 0..<count { let id = try r.u32(); let port = try r.u16(); out.append(SourceEntry(id: id, port: port)) }
        return (hash, out)
    }

    // MARK: Client <-> client

    static func hello(userHash: Data, nickname: String) -> Packet {
        let tags = tag(id: 0x01, string: nickname) + tag(id: 0x11, uint: 0x3C)
        return Packet(proto: edonkey, opcode: Op.hello, payload: Data([16]) + userHash + le32(0) + le16(0) + le32(2) + tags + le32(0) + le16(0))
    }

    /// The other side's user hash from a hello (which starts with a length byte of 16) or a hello answer (which does not).
    static func parseHello(_ payload: Data, isAnswer: Bool) throws -> Data {
        var r = Reader(payload)
        if !isAnswer { guard try r.u8() == 16 else { throw Failure.badMessage("a hello does not start with the hash length") } }          // a hello starts with 16; an answer does not
        let hash = try r.hash()
        _ = try r.u32(); _ = try r.u16()
        let count = Int(try r.u32())
        _ = try? readTags(&r, count: count)             // not needed here; a tag type this client does not know must not turn away a valid peer
        return hash
    }

    static func request(_ op: UInt8, hash: Data) -> Packet { Packet(proto: edonkey, opcode: op, payload: hash) }
    static func requestFileName(_ h: Data) -> Packet { request(Op.requestFileName, hash: h) }
    static func setReqFileID(_ h: Data) -> Packet { request(Op.setReqFileID, hash: h) }
    static func hashsetRequest(_ h: Data) -> Packet { request(Op.hashsetRequest, hash: h) }
    static func startUploadReq(_ h: Data) -> Packet { request(Op.startUploadReq, hash: h) }
    static func cancelTransfer() -> Packet { Packet(proto: edonkey, opcode: Op.cancelTransfer, payload: Data()) }

    /// The file's name as the peer knows it. The length is 2 bytes in the specification and 4 in aMule's header comment: whichever matches the bytes that follow is used.
    static func parseFileNameAnswer(_ payload: Data) throws -> (hash: Data, name: String) {
        var r = Reader(payload)
        let hash = try r.hash()
        let rest = r.rest()
        func name(prefix: Int) -> String? {
            guard rest.count >= prefix else { return nil }
            let len = prefix == 2 ? Int(rest[rest.startIndex]) | Int(rest[rest.startIndex + 1]) << 8 : (0..<4).reduce(0) { $0 | Int(rest[rest.startIndex + $1]) << (8 * $1) }
            guard len == rest.count - prefix, len <= maxStringBytes else { return nil }
            return String(decoding: rest.dropFirst(prefix), as: UTF8.self)
        }
        guard let n = name(prefix: 2) ?? name(prefix: 4) else { throw Failure.badMessage("a file name answer does not fit") }
        return (hash, n)
    }

    /// Which parts the peer has. A count of 0 means it has the whole file.
    static func parseFileStatus(_ payload: Data, expectedParts: Int) throws -> (hash: Data, have: [Bool]) {
        var r = Reader(payload)
        let hash = try r.hash()
        let count = Int(try r.u16())
        if count == 0 { return (hash, Array(repeating: true, count: expectedParts)) }
        guard count == expectedParts || count == expectedParts + 1 else { throw Failure.badMessage("the part list is the wrong size") }       // eMule counts a final empty part for exact multiples
        let map = try r.bytes((count + 7) / 8)
        let flags = (0..<expectedParts).map { map[map.startIndex + $0 / 8] & (1 << UInt8($0 % 8)) != 0 }
        return (hash, flags)
    }

    static func parseHashsetAnswer(_ payload: Data) throws -> (hash: Data, parts: [Data]) {
        var r = Reader(payload)
        let hash = try r.hash()
        let count = Int(try r.u16())
        guard count <= 100_000, r.remaining >= count * 16 else { throw Failure.badMessage("the hash list is shorter than it says") }
        return (hash, try (0..<count).map { _ in try r.hash() })
    }

    struct Range: Equatable { var start: Int64; var end: Int64 }          // end exclusive, as on the wire

    /// Up to three block requests in one packet (unused slots are zero pairs). The 64-bit form is used when an offset does not fit 32 bits.
    static func requestParts(hash: Data, ranges: [Range]) -> Packet {
        let r = Array(ranges.prefix(3)) + Array(repeating: Range(start: 0, end: 0), count: max(0, 3 - ranges.count))
        let wide = r.contains { $0.end > Int64(UInt32.max) }
        var p = hash
        if wide { for x in r { p += le64(UInt64(x.start)) }; for x in r { p += le64(UInt64(x.end)) } }
        else { for x in r { p += le32(UInt32(x.start)) }; for x in r { p += le32(UInt32(x.end)) } }
        return Packet(proto: wide ? emule : edonkey, opcode: wide ? Op.requestParts64 : Op.requestParts, payload: p)
    }

    struct Part: Equatable { var hash: Data; var start: Int64; var end: Int64; var data: Data }

    /// A block of data. `end` is exclusive and must agree with how much data came: a block that is not exactly the size it claims is refused.
    static func parseSendingPart(_ payload: Data, wide: Bool) throws -> Part {
        var r = Reader(payload)
        let hash = try r.hash()
        let start = wide ? Int64(clamping: try r.u64()) : Int64(try r.u32())
        let end = wide ? Int64(clamping: try r.u64()) : Int64(try r.u32())
        let data = r.rest()
        guard end > start, end - start == Int64(data.count), data.count <= ED2KHash.blockSize else { throw Failure.badMessage("a block is not the size it claims") }
        return Part(hash: hash, start: start, end: end, data: data)
    }

    /// Build the answers a peer would send. Used by the test fixture and nowhere in the downloader.
    static func sendingPart(_ p: Part, wide: Bool = false) -> Packet {
        let head = wide ? le64(UInt64(p.start)) + le64(UInt64(p.end)) : le32(UInt32(p.start)) + le32(UInt32(p.end))
        return Packet(proto: wide ? emule : edonkey, opcode: wide ? Op.sendingPart64 : Op.sendingPart, payload: p.hash + head + p.data)
    }
}
