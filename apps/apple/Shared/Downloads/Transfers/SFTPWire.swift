import Foundation

// SFTP protocol version 3 (draft-ietf-secsh-filexfer-02), the version every server speaks. Encoding and decoding only; bounded and defensive, because the bytes come from a server.

enum SFTPWire {
    static let maxPacket = 1 << 20          // a server packet larger than this is refused
    static let maxNames = 4096              // names in one READDIR answer

    enum Kind: UInt8 { case initialize = 1, version = 2, open = 3, close = 4, read = 5, write = 6, lstat = 7, opendir = 11, readdir = 12, remove = 13, mkdir = 14, rmdir = 15, realpath = 16, stat = 17, rename = 18, readlink = 19
        case status = 101, handle = 102, data = 103, name = 104, attrs = 105 }

    enum Status: UInt32 { case ok = 0, eof = 1, noSuchFile = 2, permissionDenied = 3, failure = 4, badMessage = 5, noConnection = 6, connectionLost = 7, opUnsupported = 8 }

    struct Writer {
        private(set) var bytes = Data()
        mutating func u8(_ v: UInt8) { bytes.append(v) }
        mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { bytes.append(contentsOf: $0) } }
        mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.bigEndian) { bytes.append(contentsOf: $0) } }
        mutating func string(_ d: Data) { u32(UInt32(d.count)); bytes.append(d) }
        mutating func string(_ s: String) { string(Data(s.utf8)) }
        /// type + payload, with the length in front.
        static func packet(_ kind: Kind, _ build: (inout Writer) -> Void) -> Data {
            var w = Writer(); w.u8(kind.rawValue); build(&w)
            var out = Data(); withUnsafeBytes(of: UInt32(w.bytes.count).bigEndian) { out.append(contentsOf: $0) }
            out.append(w.bytes); return out
        }
    }

    struct Reader {
        let data: Data
        private(set) var pos: Int
        init(_ d: Data) { data = d; pos = d.startIndex }
        var remaining: Int { data.endIndex - pos }
        mutating func u8() throws -> UInt8 { guard remaining >= 1 else { throw RemoteError.protocolViolation("short packet") }; defer { pos += 1 }; return data[pos] }
        mutating func u32() throws -> UInt32 {
            guard remaining >= 4 else { throw RemoteError.protocolViolation("short packet") }
            defer { pos += 4 }; return data[pos..<pos + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        }
        mutating func u64() throws -> UInt64 {
            guard remaining >= 8 else { throw RemoteError.protocolViolation("short packet") }
            defer { pos += 8 }; return data[pos..<pos + 8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        }
        mutating func stringData() throws -> Data {
            let n = Int(try u32())
            guard n <= remaining else { throw RemoteError.protocolViolation("a string is longer than its packet") }
            defer { pos += n }; return data[pos..<pos + n]
        }
        mutating func string() throws -> String { String(decoding: try stringData(), as: UTF8.self) }
    }

    struct Attrs: Equatable {
        var size: UInt64?
        var permissions: UInt32?
        var mtime: UInt32?
        var kind: RemoteEntry.Kind {
            guard let p = permissions else { return .other }
            switch p & 0o170000 { case 0o040000: return .directory; case 0o100000: return .file; case 0o120000: return .symlink; default: return .other }
        }
    }

    static func attrs(_ r: inout Reader) throws -> Attrs {
        let flags = try r.u32()
        var a = Attrs()
        if flags & 0x1 != 0 { a.size = try r.u64() }
        if flags & 0x2 != 0 { _ = try r.u32(); _ = try r.u32() }
        if flags & 0x4 != 0 { a.permissions = try r.u32() }
        if flags & 0x8 != 0 { _ = try r.u32(); a.mtime = try r.u32() }
        if flags & 0x8000_0000 != 0 {
            let n = try r.u32()
            guard n <= 64 else { throw RemoteError.protocolViolation("too many extended attributes") }
            for _ in 0..<n { _ = try r.stringData(); _ = try r.stringData() }
        }
        return a
    }

    struct NameEntry: Equatable { var name: String; var attrs: Attrs }

    static func names(_ r: inout Reader) throws -> [NameEntry] {
        let count = Int(try r.u32())
        guard count <= maxNames else { throw RemoteError.protocolViolation("too many names in one answer") }
        var out: [NameEntry] = []
        for _ in 0..<count {
            let name = try r.string()
            _ = try r.stringData()          // the long (ls -l style) name: its format is not specified, so it is never used
            out.append(NameEntry(name: name, attrs: try attrs(&r)))
        }
        return out
    }

    /// Whether a byte range is contiguous from zero, as ranges arrive in any order. Resume may only trust the contiguous prefix.
    struct Ranges {
        private var ranges: [(start: UInt64, end: UInt64)] = []
        private(set) var total: UInt64 = 0
        mutating func insert(_ start: UInt64, count: Int) {
            guard count > 0 else { return }
            var s = start, e = start + UInt64(count)
            var kept: [(UInt64, UInt64)] = []
            for r in ranges {
                if r.end < s || r.start > e { kept.append((r.start, r.end)) } else { s = min(s, r.start); e = max(e, r.end) }
            }
            kept.append((s, e)); kept.sort { $0.0 < $1.0 }
            ranges = kept.map { (start: $0.0, end: $0.1) }
            total = ranges.reduce(0) { $0 + ($1.end - $1.start) }
        }
        /// Bytes from zero with no gap.
        var contiguousPrefix: UInt64 { ranges.first.map { $0.start == 0 ? $0.end : 0 } ?? 0 }
    }
}
