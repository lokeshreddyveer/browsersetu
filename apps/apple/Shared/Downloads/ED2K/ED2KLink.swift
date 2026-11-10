import Foundation

/// An eD2k link, checked. Parsing reads text and nothing else: no connection is made, no download is started, no name is looked up.
///
/// Grammar (from aMule's link documentation and the Wikipedia scheme page; neither documents escaping, so a name is percent-decoded defensively):
///   ed2k://|file|NAME|SIZE|HASH|[p=H1:H2:…|][h=AICH|][s=URL|]/   then optionally   |sources,IP:PORT[:CRYPTOOPTS[:USERHASH]],…|/
///   ed2k://|server|IP|PORT|/        ed2k://|serverlist|URL|/
enum ED2KLink: Equatable, Sendable {
    case file(File)
    case server(host: String, port: UInt16)
    case serverList(URL)

    struct Source: Equatable, Hashable, Sendable { var host: String; var port: UInt16 }

    struct File: Equatable, Sendable {
        var name: String                 // a safe single file name
        var size: Int64
        var hash: Data                   // 16 bytes (MD4)
        var partHashes: [Data]?          // one per data part, when the link carried them (already checked against `hash`)
        var aichRoot: String?
        var sources: [Source]
        var hashHex: String { hash.hexString }
        /// The link in its plain form, with no sources: what is saved with a task.
        var canonical: String { "ed2k://|file|\(name.replacingOccurrences(of: "|", with: "%7C"))|\(size)|\(hashHex)|/" }
    }

    enum Failure: Error, Equatable, LocalizedError {
        case notED2K, tooLong, unsupported(String), malformed(String), badHash, badSize, unsafeName, tooManySources, badAddress(String)

        var errorDescription: String? {
            switch self {
            case .notED2K: "That is not an eD2k link."
            case .tooLong: "The link is too long."
            case .unsupported(let kind): "“\(kind.prefix(24))” links are not supported."
            case .malformed(let why): "The link is not valid (\(why))."
            case .badHash: "The link's file hash is not valid (it must be 32 hexadecimal characters)."
            case .badSize: "The link's file size is not valid."
            case .unsafeName: "The link's file name is not usable."
            case .tooManySources: "The link lists too many sources."
            case .badAddress(let a): "The link names an address that cannot be used (\(a.prefix(40)))."
            }
        }
    }

    static let maxLength = 32 * 1024
    static let maxSources = 50
    static let maxSize: Int64 = 1 << 38
    static let maxNameBytes = 255

    static func parse(_ text: String) throws -> ED2KLink {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= maxLength else { throw Failure.tooLong }
        guard trimmed.lowercased().hasPrefix("ed2k://") else { throw Failure.notED2K }
        guard trimmed.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else { throw Failure.malformed("control characters") }
        let body = String(trimmed.dropFirst(7))
        guard body.hasPrefix("|") else { throw Failure.malformed("it does not start with |") }
        let tokens = body.components(separatedBy: "|")           // ["", kind, …]
        guard tokens.count >= 3 else { throw Failure.malformed("too few fields") }
        switch tokens[1].lowercased() {
        case "file": return .file(try parseFile(Array(tokens.dropFirst(2))))
        case "server":
            guard tokens.count >= 4, let port = UInt16(tokens[3]), port > 0 else { throw Failure.malformed("a server link needs an address and a port") }
            return .server(host: try publicIPv4(tokens[2]), port: port)
        case "serverlist":
            guard let url = URL(string: tokens[2]), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false, tokens[2].utf8.count <= 2048 else { throw Failure.malformed("the server list address is not a web address") }
            return .serverList(url)
        default: throw Failure.unsupported(tokens[1])
        }
    }

    private static func parseFile(_ t: [String]) throws -> File {
        guard t.count >= 4 else { throw Failure.malformed("a file link needs a name, a size and a hash") }
        let decoded = t[0].removingPercentEncoding ?? t[0]
        guard decoded.utf8.count <= maxNameBytes * 3, let name = DownloadFilename.sanitize(decoded), name.utf8.count <= maxNameBytes else { throw Failure.unsafeName }
        guard t[1].allSatisfy(\.isASCII), t[1].allSatisfy(\.isNumber), let size = Int64(t[1]), size > 0, size <= maxSize else { throw Failure.badSize }
        guard t[2].count == 32, let hash = Data(hex: t[2]) else { throw Failure.badHash }
        var partHashes: [Data]?
        var aich: String?
        var seen = Set<String>()
        var sources: [Source] = []
        var i = 3
        // optional |key=value| fields, up to the closing "/"
        while i < t.count, t[i] != "/", t[i] != "" {
            let field = t[i]; i += 1
            if field.lowercased().hasPrefix("sources,") { sources += try parseSources(field); continue }
            guard let eq = field.firstIndex(of: "=") else { continue }                      // unknown shapes are skipped, as aMule does
            let key = String(field[..<eq]).lowercased(), value = String(field[field.index(after: eq)...])
            guard seen.insert(key).inserted else { throw Failure.malformed("“\(key)” appears twice") }
            switch key {
            case "p":
                let hexes = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                let expected = ED2KHash.partCount(size: size)
                guard hexes.count == expected || hexes.count == expected + 1 else { throw Failure.malformed("the part hashes do not fit the file's size") }
                let parts = try hexes.map { h -> Data in guard h.count == 32, let d = Data(hex: h) else { throw Failure.badHash }; return d }
                guard let usable = ED2KHash.validatedPartHashes(parts, fileHash: hash, size: size) else { throw Failure.malformed("the part hashes do not add up to the file hash") }
                partHashes = usable
            case "h": aich = String(value.prefix(64)).filter { $0.isLetter || $0.isNumber }
            default: continue                                                              // s= (web sources) and others are ignored: they cause no network activity
            }
        }
        // after the first "/": "|sources,…|/" and the like
        while i < t.count {
            let field = t[i]; i += 1
            if field.lowercased().hasPrefix("sources,") { sources += try parseSources(field) }
        }
        guard sources.count <= maxSources else { throw Failure.tooManySources }
        return File(name: name, size: size, hash: hash, partHashes: partHashes, aichRoot: aich, sources: Array(Set(sources)).sorted { ($0.host, $0.port) < ($1.host, $1.port) })
    }

    private static func parseSources(_ field: String) throws -> [Source] {
        let items = field.dropFirst("sources,".count).split(separator: ",", omittingEmptySubsequences: true)
        guard items.count <= maxSources else { throw Failure.tooManySources }
        return try items.map { item in
            let parts = item.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2, let port = UInt16(parts[1]), port > 0 else { throw Failure.badAddress(String(item)) }
            return Source(host: try publicIPv4(parts[0]), port: port)
        }
    }

    /// A dotted IPv4 address that is not loopback, private, link-local, multicast or unspecified. Names are refused: looking one up would be a network request made by reading a link.
    static func publicIPv4(_ text: String) throws -> String {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }), let o = Optional(parts.compactMap { UInt8($0) }), o.count == 4 else { throw Failure.badAddress(text) }
        if isInternal(o) { throw Failure.badAddress(text) }
        return o.map(String.init).joined(separator: ".")
    }

    static func isInternal(_ o: [UInt8]) -> Bool {
        o[0] == 0 || o[0] == 10 || o[0] == 127 || o[0] >= 224 || (o[0] == 169 && o[1] == 254) || (o[0] == 172 && (16...31).contains(o[1])) || (o[0] == 192 && o[1] == 168) || (o[0] == 100 && (64...127).contains(o[1]))
    }
}
