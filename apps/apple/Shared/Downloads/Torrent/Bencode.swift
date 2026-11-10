import Foundation

/// A bencoded value (BEP 3). Byte strings stay bytes: names and paths are text only after they have been checked.
indirect enum Bencode: Equatable, Sendable {
    case int(Int64)
    case bytes(Data)
    case list([Bencode])
    case dict([String: Bencode])

    var int: Int64? { if case .int(let v) = self { v } else { nil } }
    var data: Data? { if case .bytes(let v) = self { v } else { nil } }
    var string: String? { data.flatMap { String(data: $0, encoding: .utf8) } }
    var list: [Bencode]? { if case .list(let v) = self { v } else { nil } }
    var dict: [String: Bencode]? { if case .dict(let v) = self { v } else { nil } }
}

/// A bounded, strict decoder. Bytes come from files and from strangers on the network, so every dimension is limited before anything is built: input size, nesting depth, the number of
/// values, and the length of any one string. Anything unusual (leading zeros, "-0", a duplicate key, bytes after the end) is refused, not guessed at.
enum BencodeDecoder {
    struct Limits: Sendable {
        var maxBytes = 8 * 1024 * 1024
        var maxDepth = 24
        var maxValues = 400_000
        var maxStringBytes = 8 * 1024 * 1024
        /// Keys that are not text are kept (read byte for byte as Latin-1), as in a scrape reply, whose keys are raw info-hashes.
        var binaryKeys = false
        static let message = Limits(maxBytes: 2 * 1024 * 1024, maxDepth: 8, maxValues: 4_096, maxStringBytes: 1024 * 1024)
        static let scrapeReply = Limits(maxBytes: 2 * 1024 * 1024, maxDepth: 8, maxValues: 4_096, maxStringBytes: 1024 * 1024, binaryKeys: true)
    }

    enum Failure: Error, Equatable, LocalizedError {
        case tooLarge, tooDeep, tooManyValues, malformed(String), trailingData

        var errorDescription: String? {
            switch self {
            case .tooLarge: "The data is larger than is allowed."
            case .tooDeep: "The data is nested too deeply."
            case .tooManyValues: "The data holds too many items."
            case .malformed(let why): "The data is not valid: \(why)."
            case .trailingData: "There is extra data after the end."
            }
        }
    }

    /// The decoded value and, for a dictionary, the exact bytes of one key's value (the info-hash is a hash of those bytes as they were, never of a re-encoding).
    struct Decoded {
        var value: Bencode
        var rawRanges: [String: Range<Int>] = [:]
    }

    static func decode(_ data: Data, limits: Limits = Limits(), rawKeys: Set<String> = []) throws -> Decoded {
        guard data.count <= limits.maxBytes else { throw Failure.tooLarge }
        var parser = Parser(bytes: [UInt8](data), limits: limits, rawKeys: rawKeys)
        let value = try parser.value(depth: 0, top: true)
        guard parser.position == parser.bytes.count else { throw Failure.trailingData }
        return Decoded(value: value, rawRanges: parser.raw)
    }

    private struct Parser {
        let bytes: [UInt8]
        let limits: Limits
        let rawKeys: Set<String>
        var position = 0
        var count = 0
        var raw: [String: Range<Int>] = [:]

        init(bytes: [UInt8], limits: Limits, rawKeys: Set<String>) { self.bytes = bytes; self.limits = limits; self.rawKeys = rawKeys }

        mutating func value(depth: Int, top: Bool = false) throws -> Bencode {
            guard depth <= limits.maxDepth else { throw Failure.tooDeep }
            count += 1
            guard count <= limits.maxValues else { throw Failure.tooManyValues }
            guard position < bytes.count else { throw Failure.malformed("it ends too soon") }
            switch bytes[position] {
            case UInt8(ascii: "i"): return .int(try integer())
            case UInt8(ascii: "l"):
                position += 1
                var items: [Bencode] = []
                while true {
                    guard position < bytes.count else { throw Failure.malformed("a list is not closed") }
                    if bytes[position] == UInt8(ascii: "e") { position += 1; return .list(items) }
                    items.append(try value(depth: depth + 1))
                }
            case UInt8(ascii: "d"):
                position += 1
                var items: [String: Bencode] = [:]
                while true {
                    guard position < bytes.count else { throw Failure.malformed("a dictionary is not closed") }
                    if bytes[position] == UInt8(ascii: "e") { position += 1; return .dict(items) }
                    let keyBytes = try string()
                    guard let key = String(bytes: keyBytes, encoding: .utf8) ?? (limits.binaryKeys ? String(bytes: keyBytes, encoding: .isoLatin1) : nil) else { throw Failure.malformed("a key is not text") }
                    // Real torrents sometimes list keys out of order, which is harmless because the info-hash is taken from the original bytes; a repeated key is not, and is refused.
                    if items[key] != nil { throw Failure.malformed("a key is repeated") }
                    let start = position
                    items[key] = try value(depth: depth + 1)
                    if rawKeys.contains(key), depth == 0 { raw[key] = start..<position }
                }
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return .bytes(Data(try string()))
            default: throw Failure.malformed("an unknown item type")
            }
        }

        mutating func integer() throws -> Int64 {
            position += 1                                                         // "i"
            let start = position
            while position < bytes.count, bytes[position] != UInt8(ascii: "e") { position += 1 }
            guard position < bytes.count, position > start, position - start <= 20 else { throw Failure.malformed("a number is not closed") }
            let digits = String(decoding: bytes[start..<position], as: UTF8.self)
            position += 1                                                         // "e"
            if digits == "-0" || (digits.hasPrefix("0") && digits.count > 1) || (digits.hasPrefix("-0")) { throw Failure.malformed("a number has leading zeros") }
            guard let number = Int64(digits) else { throw Failure.malformed("a number is out of range") }
            return number
        }

        mutating func string() throws -> [UInt8] {
            let start = position
            while position < bytes.count, bytes[position] >= UInt8(ascii: "0"), bytes[position] <= UInt8(ascii: "9") { position += 1 }
            guard position < bytes.count, bytes[position] == UInt8(ascii: ":"), position > start, position - start <= 10 else { throw Failure.malformed("a string length is wrong") }
            let digits = String(decoding: bytes[start..<position], as: UTF8.self)
            if digits.count > 1, digits.hasPrefix("0") { throw Failure.malformed("a string length has leading zeros") }
            guard let length = Int(digits), length <= limits.maxStringBytes, length <= bytes.count - position - 1 else { throw Failure.malformed("a string is longer than the data") }
            position += 1
            defer { position += length }
            return Array(bytes[position..<(position + length)])
        }
    }

    /// Encodes a value (dictionary keys in byte order, as the format requires). Used for the small messages this client sends.
    static func encode(_ value: Bencode) -> Data {
        var out = Data()
        func write(_ v: Bencode) {
            switch v {
            case .int(let n): out.append(contentsOf: Array("i\(n)e".utf8))
            case .bytes(let d): out.append(contentsOf: Array("\(d.count):".utf8)); out.append(d)
            case .list(let items): out.append(UInt8(ascii: "l")); items.forEach(write); out.append(UInt8(ascii: "e"))
            case .dict(let items):
                out.append(UInt8(ascii: "d"))
                for key in items.keys.sorted(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }) {
                    write(.bytes(Data(key.utf8))); write(items[key]!)
                }
                out.append(UInt8(ascii: "e"))
            }
        }
        write(value)
        return out
    }
}
