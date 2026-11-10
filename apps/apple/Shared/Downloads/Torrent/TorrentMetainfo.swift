import CryptoKit
import Foundation

/// What a .torrent file (or metadata fetched for a magnet link) says, checked. Nothing here touches the disk or the network.
///
/// Version 1 metainfo (BEP 3) is supported. A torrent that is version 2 only (BEP 52) has no `pieces` list and is refused with a plain reason; a hybrid one is read through its version 1
/// part. Every name that will become a file or folder is checked here, once, and nothing later builds a path from raw metadata.
struct TorrentMetainfo: Equatable, Sendable {
    struct File: Equatable, Sendable {
        var index: Int
        /// Safe relative path components under the torrent's folder (never "..", never empty, never a separator inside one).
        var path: [String]
        var length: Int64
        /// Offset of the file's first byte in the torrent's one continuous stream of bytes.
        var offset: Int64
        var relativePath: String { path.joined(separator: "/") }
        /// The name parts exactly as the torrent wrote them, kept only when they differ from `path` (which is normalised and trimmed for the disk). A web seed holds the files under the
        /// names the torrent gives, so its addresses are built from these; nothing else ever uses them.
        var rawPath: [String]? = nil
        /// BitTorrent v2 (BEP 52): this file's 32-byte `pieces root`. Nil for an empty file, a padding entry, and any version 1 file.
        var pieceRoot: Data? = nil
        /// BEP 47 padding (or a gap made to align a version 2 file to a piece boundary): zeros that are part of the piece stream but not a file. Never written, never listed, never published; reads give zeros.
        var isPadding: Bool = false
    }

    /// Which generation of the format describes the torrent (BEP 3 / BEP 52). A hybrid carries both views of the same data in one info dictionary.
    enum Version: String, Equatable, Sendable { case v1, v2, hybrid }

    var infoHash: Data                      // 20 bytes, SHA-1 of the info dictionary as it was written
    /// The info dictionary exactly as written (kept so the torrent can be continued later without the original file).
    var rawInfo: Data
    var name: String                        // safe single name
    var pieceLength: Int64
    var pieceHashes: [Data]                 // 20 bytes each
    var files: [File]
    var isMultiFile: Bool
    var totalLength: Int64
    var isPrivate: Bool
    var trackers: [URL]                     // tiers flattened in order, http/https/udp only
    var webSeeds: [URL]
    var comment: String?
    /// The announce list as the torrent gives it (BEP 12): tiers in order, each an ordered list. `trackers` above is the same addresses flattened.
    var trackerTiers: [[URL]] = []
    /// The torrent's name exactly as written, when it differs from `name` (see `File.rawPath`).
    var rawName: String? = nil
    /// BEP 17 `httpseeds` (Hoffman style): servers that answer piece requests. http/https only, at most 8.
    var httpSeeds: [URL] = []
    var version: Version = .v1
    /// SHA-256 of the info dictionary as written (32 bytes). Nil for a version 1 torrent.
    var infoHashV2: Data? = nil
    /// BEP 52 `piece layers` that were present and checked against their files' roots, by pieces root. A file longer than a piece whose root is missing here still has to be fetched from peers.
    var pieceLayers: [Data: Data] = [:]
    /// Number of pieces of a version 2 only torrent (its `pieceHashes` is empty).
    var v2PieceCount: Int = 0
    /// True when any entry of `files` is padding.
    var hasPadding: Bool = false

    var infoHashHex: String { infoHash.map { String(format: "%02x", $0) }.joined() }
    var pieceCount: Int { version == .v2 ? v2PieceCount : pieceHashes.count }
    /// The 20 bytes that name this torrent on the wire, to trackers and in the DHT: the version 1 hash for v1 and hybrid, the first 20 bytes of the version 2 hash for v2 only. (Same as `infoHash`.)
    var sessionInfoHash: Data { infoHash }
    var infoHashV2Truncated: Data? { infoHashV2.map(Merkle.truncated) }
    var infoHashV2Hex: String? { infoHashV2.map { $0.map { String(format: "%02x", $0) }.joined() } }
    /// The files the person can see: everything except padding.
    var visibleFiles: [File] { files.filter { !$0.isPadding } }
    /// Bytes of real files (the stream's length minus padding).
    var contentLength: Int64 { files.reduce(0) { $0 + ($1.isPadding ? 0 : $1.length) } }
    /// Roots of files longer than a piece whose piece layer is not yet known (a version 2 magnet link brings none).
    var missingLayerRoots: [Data] {
        guard version != .v1 else { return [] }
        var seen = Set<Data>()
        return files.compactMap { f in
            guard !f.isPadding, f.length > pieceLength, let r = f.pieceRoot, pieceLayers[r] == nil, seen.insert(r).inserted else { return nil }
            return r
        }
    }

    // MARK: Limits

    enum Limit {
        static let maxFiles = 20_000
        static let maxPathDepth = 16
        static let maxComponentBytes = 255
        static let maxPathBytes = 1024
        static let maxPieces = 500_000
        static let minPieceLength: Int64 = 16 * 1024
        static let maxPieceLength: Int64 = 64 * 1024 * 1024
        static let maxTotal: Int64 = 1 << 50
        static let maxTrackers = 32
        static let maxTrackerURL = 2048
        static let maxInfoBytes = 8 * 1024 * 1024
        /// Deep enough for a version 2 file tree (one level per folder) at `maxPathDepth`.
        static let decodeDepth = 24
    }

    enum Failure: Error, Equatable, LocalizedError {
        case notATorrent(String), unsupportedVersion2, unsafePath(String), tooMany(String), invalid(String)
        case unsupportedMetaVersion(Int64), missingPieceLayer(String), inconsistentHybrid(String)

        var errorDescription: String? {
            switch self {
            case .notATorrent(let why): "This is not a torrent file (\(why))."
            case .unsupportedVersion2: "This torrent uses only the newer version 2 format, which Browser Setu cannot download yet."
            case .unsafePath(let name): "The torrent names a file or folder that is not allowed (“\(name.prefix(60))”), so it was not opened."
            case .tooMany(let what): "The torrent has too many \(what), so it was not opened."
            case .invalid(let why): "The torrent is not valid: \(why)."
            case .unsupportedMetaVersion(let v): "This torrent uses format version \(v), which Browser Setu does not know."
            case .missingPieceLayer(let name): "The torrent is missing the checksums for “\(name.prefix(60))”, so it was not opened."
            case .inconsistentHybrid(let why): "The torrent's version 1 and version 2 descriptions disagree (\(why)), so it was not opened."
            }
        }
    }

    // MARK: Parsing

    static func parse(_ data: Data) throws -> TorrentMetainfo {
        var limits = BencodeDecoder.Limits(maxBytes: Limit.maxInfoBytes + 1_048_576, maxDepth: Limit.decodeDepth, maxValues: 400_000, maxStringBytes: Limit.maxInfoBytes)
        var decoded: BencodeDecoder.Decoded
        var lenientKeys = false
        do { decoded = try BencodeDecoder.decode(data, limits: limits, rawKeys: ["info"]) }
        catch {
            // BEP 52's `piece layers` is keyed by raw 32-byte hashes, which are not text. Only a file that fails the strict reading is read again with binary keys allowed.
            limits.binaryKeys = true
            do { decoded = try BencodeDecoder.decode(data, limits: limits, rawKeys: ["info"]); lenientKeys = true }
            catch { throw Failure.notATorrent((error as? LocalizedError)?.errorDescription ?? "unreadable") }
        }
        guard let root = decoded.value.dict, var info = root["info"]?.dict, let range = decoded.rawRanges["info"] else { throw Failure.notATorrent("there is no info section") }
        let raw = data.subdata(in: range)
        guard raw.count <= Limit.maxInfoBytes else { throw Failure.tooMany("bytes of description") }
        if lenientKeys {
            // The info section itself must still be strictly text-keyed.
            guard let strict = (try? BencodeDecoder.decode(raw, limits: .init(maxBytes: Limit.maxInfoBytes, maxDepth: Limit.decodeDepth, maxValues: 400_000, maxStringBytes: Limit.maxInfoBytes)))?.value.dict else { throw Failure.notATorrent("a name in the info section is not text") }
            info = strict
        }
        return try parse(info: info, rawInfo: raw, root: root, requireLayers: true)
    }

    /// The info section on its own (a magnet link's metadata arrives this way). The hash of the bytes must equal the hash the link promised: checked by the caller with `infoHash`.
    static func parse(infoSection raw: Data) throws -> TorrentMetainfo {
        guard raw.count <= Limit.maxInfoBytes else { throw Failure.tooMany("bytes of description") }
        let decoded: BencodeDecoder.Decoded
        do { decoded = try BencodeDecoder.decode(raw, limits: .init(maxBytes: Limit.maxInfoBytes, maxDepth: Limit.decodeDepth, maxValues: 400_000, maxStringBytes: Limit.maxInfoBytes)) }
        catch { throw Failure.notATorrent((error as? LocalizedError)?.errorDescription ?? "unreadable") }
        guard let info = decoded.value.dict else { throw Failure.notATorrent("the info section is not a dictionary") }
        return try parse(info: info, rawInfo: raw, root: [:], requireLayers: false)
    }

    /// `requireLayers`: a .torrent file must carry the `piece layers` of every file longer than a piece; the info section alone (a magnet link's metadata) cannot, and gets them from peers later.
    private static func parse(info: [String: Bencode], rawInfo: Data, root: [String: Bencode], requireLayers: Bool) throws -> TorrentMetainfo {
        var metaVersion: Int64?
        if let mv = info["meta version"] {
            guard let n = mv.int else { throw Failure.invalid("the format version is not a number") }
            guard n == 2 else { throw Failure.unsupportedMetaVersion(n) }
            metaVersion = n
            guard info["file tree"]?.dict != nil else { throw Failure.invalid("a version 2 torrent has no file tree") }
        }
        guard let pieces = info["pieces"]?.data else {
            if metaVersion == 2 { return try parseV2Only(info: info, rawInfo: rawInfo, root: root, requireLayers: requireLayers) }
            throw Failure.invalid("it has no list of piece checksums")
        }
        guard pieces.count % 20 == 0, !pieces.isEmpty else { throw Failure.invalid("the piece checksums are the wrong size") }
        guard pieces.count / 20 <= Limit.maxPieces else { throw Failure.tooMany("pieces") }
        guard let pieceLength = info["piece length"]?.int, (Limit.minPieceLength...Limit.maxPieceLength).contains(pieceLength), pieceLength % 16384 == 0 else {
            throw Failure.invalid("the piece length is not usable")
        }
        guard let rawName = info["name"]?.string ?? info["name.utf-8"]?.string, let name = safeComponent(rawName) else { throw Failure.unsafePath(info["name"]?.string ?? "") }

        var files: [File] = []
        var total: Int64 = 0
        var nonCanonicalPadding = false
        let multi: Bool
        if let list = info["files"]?.list {
            multi = true
            guard !list.isEmpty else { throw Failure.invalid("it lists no files") }
            guard list.count <= Limit.maxFiles else { throw Failure.tooMany("files") }
            var seen = Set<String>()
            for (index, entry) in list.enumerated() {
                guard let item = entry.dict, let length = item["length"]?.int, length >= 0, let parts = (item["path.utf-8"] ?? item["path"])?.list else { throw Failure.invalid("a file entry is incomplete") }
                guard !parts.isEmpty, parts.count <= Limit.maxPathDepth else { throw Failure.unsafePath("") }
                // BEP 47 padding: `attr` has "p", or the entry is spelled the way padding is (".pad/<its length>"). Its name is never used for anything, so it is not checked as a name.
                let padShaped = parts.count == 2 && parts[0].string == ".pad" && parts[1].string == String(length)
                if (item["attr"]?.string ?? "").contains("p") || padShaped {
                    guard length <= Limit.maxTotal else { throw Failure.invalid("a padding entry is too large") }
                    if !padShaped { nonCanonicalPadding = true }
                    files.append(File(index: index, path: [".pad", String(length)], length: length, offset: total, isPadding: true))
                    let (sum, overflow) = total.addingReportingOverflow(length)
                    guard !overflow, sum <= Limit.maxTotal else { throw Failure.tooMany("bytes") }
                    total = sum
                    continue
                }
                var path: [String] = [], raw: [String] = []
                for part in parts {
                    guard let text = part.string, let safe = safeComponent(text) else { throw Failure.unsafePath(part.string ?? "") }
                    path.append(safe); raw.append(text)
                }
                let joined = path.joined(separator: "/")
                guard joined.utf8.count <= Limit.maxPathBytes else { throw Failure.unsafePath(joined) }
                // Two names that are the same file on a case-insensitive disk would write over each other.
                guard seen.insert(joined.lowercased().precomposedStringWithCanonicalMapping).inserted else { throw Failure.unsafePath(joined) }
                // A file name that is also another file's folder would be both a file and a folder.
                files.append(File(index: index, path: path, length: length, offset: total, rawPath: raw == path ? nil : raw))
                let (sum, overflow) = total.addingReportingOverflow(length)
                guard !overflow, sum <= Limit.maxTotal else { throw Failure.tooMany("bytes") }
                total = sum
            }
            let real = files.filter { !$0.isPadding }
            let prefixes = Set(real.flatMap { f in (1..<max(1, f.path.count)).map { f.path.prefix($0).joined(separator: "/").lowercased() } })
            for f in real where prefixes.contains(f.relativePath.lowercased()) { throw Failure.unsafePath(f.relativePath) }
            guard !real.isEmpty else { throw Failure.invalid("it lists no files") }
        } else if let length = info["length"]?.int {
            multi = false
            guard length >= 0, length <= Limit.maxTotal else { throw Failure.invalid("the length is not usable") }
            files = [File(index: 0, path: [name], length: length, offset: 0)]
            total = length
        } else { throw Failure.invalid("it has neither a length nor a list of files") }
        guard total > 0 else { throw Failure.invalid("it is empty") }

        // The checksums must describe exactly the bytes there are.
        let expected = (total + pieceLength - 1) / pieceLength
        guard expected == Int64(pieces.count / 20) else { throw Failure.invalid("the number of pieces does not match the size") }

        let hashes = stride(from: 0, to: pieces.count, by: 20).map { pieces.subdata(in: $0..<($0 + 20)) }
        let trackers = trackerURLs(root: root)
        let tiers = trackerTierURLs(root: root)
        let seeds = webSeedURLs(root["url-list"])
        var meta = TorrentMetainfo(infoHash: Data(Insecure.SHA1.hash(data: rawInfo)), rawInfo: rawInfo, name: name, pieceLength: pieceLength, pieceHashes: hashes, files: files, isMultiFile: multi,
                               totalLength: total, isPrivate: info["private"]?.int == 1, trackers: trackers, webSeeds: seeds, comment: root["comment"]?.string.map { String($0.prefix(500)) }, trackerTiers: tiers, rawName: rawName == name ? nil : rawName, httpSeeds: httpSeedURLs(root["httpseeds"]))
        meta.hasPadding = files.contains { $0.isPadding }
        if metaVersion == 2 {
            try applyHybrid(to: &meta, info: info, root: root, requireLayers: requireLayers, nonCanonicalPadding: nonCanonicalPadding)
        }
        return meta
    }

    // MARK: Names

    /// One safe name for a file or folder, or nil. Nothing that could leave the folder or mean something to the file system survives: no separators, no "." or "..", no control characters.
    static func safeComponent(_ text: String) -> String? {
        let name = text.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= Limit.maxComponentBytes else { return nil }
        if name.contains("/") || name.contains("\\") || name.contains(":") { return nil }
        if name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) }) { return nil }
        return name
    }

    /// The same trackers, kept in their tiers. A tracker named twice is kept once, in the first tier that names it. BEP 12: when `announce-list` is present, `announce` is ignored; it is used (as the only tier) only when the list gives nothing usable.
    static func trackerTierURLs(root: [String: Bencode]) -> [[URL]] {
        var seen = Set<String>(), count = 0
        var tiers: [[URL]] = []
        func accept(_ value: Bencode?) -> URL? {
            guard count < Limit.maxTrackers, let text = value?.string, text.utf8.count <= Limit.maxTrackerURL, let url = URL(string: text), let scheme = url.scheme?.lowercased(),
                  ["http", "https", "udp"].contains(scheme), url.host?.isEmpty == false, seen.insert(url.absoluteString).inserted else { return nil }
            count += 1
            return url
        }
        for tier in root["announce-list"]?.list ?? [] {
            let list = (tier.list ?? []).compactMap { accept($0) }
            if !list.isEmpty { tiers.append(list) }
        }
        if tiers.isEmpty, let single = accept(root["announce"]) { tiers.append([single]) }          // BEP 12: with an announce-list, `announce` is ignored
        return tiers
    }

    static func trackerURLs(root: [String: Bencode]) -> [URL] {
        // The flat list is the tiers, flattened: BEP 12 says `announce` is ignored when `announce-list` is present, so it must not be contacted through this list either.
        trackerTierURLs(root: root).flatMap { $0 }
    }

    /// `httpseeds` is a list of URLs in the outer dictionary (BEP 17).
    static func httpSeedURLs(_ value: Bencode?) -> [URL] {
        var texts: [String] = []
        if let one = value?.string { texts = [one] } else if let many = value?.list { texts = many.compactMap(\.string) }
        return texts.prefix(8).filter { $0.utf8.count <= TorrentMetainfo.Limit.maxTrackerURL }.compactMap { URL(string: $0) }.filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") && $0.host != nil }
    }

    static func webSeedURLs(_ value: Bencode?) -> [URL] {
        var texts: [String] = []
        if let one = value?.string { texts = [one] } else if let many = value?.list { texts = many.compactMap(\.string) }
        return texts.prefix(8).compactMap { URL(string: $0) }.filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") && $0.host != nil }
    }

    // MARK: Piece and file geometry

    /// Length of piece `index` (the last one is usually shorter).
    func length(ofPiece index: Int) -> Int64 {
        guard index >= 0, index < pieceCount else { return 0 }
        if version == .v2 {
            // Every piece belongs to one file and ends where that file ends (the gap up to the next boundary is not part of any piece).
            let start = Int64(index) * pieceLength
            guard let f = file(containing: start) else { return 0 }
            return min(pieceLength, f.offset + f.length - start)
        }
        return index == pieceCount - 1 ? totalLength - Int64(index) * pieceLength : pieceLength
    }

    /// The file (never padding) that holds the stream byte at `offset`.
    func file(containing offset: Int64) -> File? {
        guard offset >= 0, offset < totalLength, !files.isEmpty else { return nil }
        var low = 0, high = files.count - 1
        while low < high { let mid = (low + high) / 2; if files[mid].offset + files[mid].length <= offset { low = mid + 1 } else { high = mid } }
        let f = files[low]
        return f.offset <= offset && offset < f.offset + f.length && !f.isPadding ? f : nil
    }

    /// The files a byte range of the stream touches, with the part of each that lies in the range.
    func segments(offset: Int64, length: Int64) -> [(file: Int, fileOffset: Int64, count: Int64)] {
        guard length > 0, offset >= 0, offset + length <= totalLength else { return [] }
        var out: [(Int, Int64, Int64)] = []
        var position = offset
        let end = offset + length
        // Binary search for the first file that holds `offset` (files can be zero-length, which are skipped).
        var low = 0, high = files.count - 1
        while low < high { let mid = (low + high) / 2; if files[mid].offset + files[mid].length <= offset { low = mid + 1 } else { high = mid } }
        var i = low
        while position < end, i < files.count {
            let f = files[i]
            if f.length > 0, f.offset + f.length > position {
                let start = position - f.offset
                let n = min(end - position, f.length - start)
                out.append((i, start, n)); position += n
            }
            i += 1
        }
        return out
    }
}

// MARK: Magnet links

/// A magnet link (BEP 9 / BEP 53), checked. It names a torrent by its info-hash and may carry a display name and tracker addresses; it never contains the torrent's files.
struct MagnetLink: Equatable, Sendable {
    var infoHash: Data
    var displayName: String?
    var trackers: [URL]
    var webSeeds: [URL]
    /// BEP 53 `so=`: the files asked for, or why the value could not be used. Nil when the link has none.
    var selectOnly: MagnetSelection.Result? = nil
    /// BEP 52 `urn:btmh:` (SHA-256 multihash), 32 bytes, when the link carries one. For a link with only this, `infoHash` is its first 20 bytes (what trackers and the handshake use).
    var infoHashV2: Data? = nil
    var infoHashHex: String { infoHash.map { String(format: "%02x", $0) }.joined() }
    var infoHashV2Hex: String? { infoHashV2.map { $0.map { String(format: "%02x", $0) }.joined() } }
    /// True when the link names only the version 2 hash.
    var isV2Only: Bool { infoHashV2 != nil && !hasV1Hash }
    var hasV1Hash: Bool = true

    enum Failure: Error, Equatable, LocalizedError {
        case notMagnet, missingHash, badHash, unsupportedVersion2Only, tooLong, unsupportedHashType

        var errorDescription: String? {
            switch self {
            case .notMagnet: "That is not a magnet link."
            case .missingHash: "The magnet link does not say which torrent it is for."
            case .badHash: "The magnet link's torrent identifier is not valid."
            case .unsupportedVersion2Only: "This magnet link is for a version 2 torrent only, which Browser Setu cannot download yet."
            case .tooLong: "The magnet link is too long."
            case .unsupportedHashType: "The magnet link uses a hash type other than SHA-256, which Browser Setu does not support."
            }
        }
    }

    static let maxLength = 8192

    /// Why a link was refused, in words, or nil if it is fine.
    static func problem(_ text: String) -> String? {
        do { _ = try parse(text); return nil } catch { return (error as? LocalizedError)?.errorDescription }
    }

    static func parse(_ text: String) throws -> MagnetLink {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= maxLength else { throw Failure.tooLong }
        guard trimmed.lowercased().hasPrefix("magnet:?"), let comps = URLComponents(string: trimmed), comps.scheme?.lowercased() == "magnet" else { throw Failure.notMagnet }
        var hashes: [Data] = []
        var v2Hashes: [Data] = []
        var v2Error: Error?          // a bad version 2 identifier only matters when there is no version 1 hash to fall back on (a hybrid link)
        var name: String?
        var trackers: [URL] = []
        var seeds: [URL] = []
        var selectOnly: MagnetSelection.Result?
        for item in comps.queryItems ?? [] {
            guard let value = item.value, !value.isEmpty else { continue }
            switch item.name.lowercased() {
            case "xt":
                let lower = value.lowercased()
                if lower.hasPrefix("urn:btih:") { guard let h = hash(String(value.dropFirst(9))) else { throw Failure.badHash }; hashes.append(h) }
                else if lower.hasPrefix("urn:btmh:") {
                    do { v2Hashes.append(try multihash(String(value.dropFirst(9)))) }
                    catch { if v2Error == nil { v2Error = error } }
                }
            case "dn": if name == nil { name = TorrentMetainfo.safeComponent(String(value.prefix(255)).replacingOccurrences(of: "+", with: " ")) }
            case "tr", "tr.1", "tr.2", "tr.3":
                if trackers.count < TorrentMetainfo.Limit.maxTrackers, value.utf8.count <= TorrentMetainfo.Limit.maxTrackerURL, let url = URL(string: value), let scheme = url.scheme?.lowercased(),
                   ["http", "https", "udp"].contains(scheme), url.host?.isEmpty == false, !trackers.contains(url) { trackers.append(url) }
            case "ws":
                if seeds.count < 8, let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil { seeds.append(url) }
            case "so": if selectOnly == nil { selectOnly = MagnetSelection.parse(value) }
            default: continue                      // unknown parameters (xl, as, xs, x.pe…) are ignored: they cause no network activity here
            }
        }
        if hashes.isEmpty, let v2Error { throw v2Error }
        guard hashes.allSatisfy({ $0 == hashes.first }), v2Hashes.allSatisfy({ $0 == v2Hashes.first }) else { throw Failure.badHash }          // two different torrents in one link is ambiguous: refused
        guard let first = hashes.first ?? v2Hashes.first.map(Merkle.truncated) else { throw Failure.missingHash }
        var link = MagnetLink(infoHash: first, displayName: name, trackers: trackers, webSeeds: seeds, selectOnly: selectOnly, infoHashV2: v2Hashes.first)
        link.hasV1Hash = !hashes.isEmpty
        return link
    }

    /// A multihash for SHA-256 (BEP 52): "1220" then 64 hex digits. Another hash type is a clear refusal; a malformed one is a bad identifier.
    static func multihash(_ text: String) throws -> Data {
        guard text.count >= 4, text.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw Failure.badHash }
        let lower = text.lowercased()
        guard lower.hasPrefix("1220") else { throw Failure.unsupportedHashType }
        guard lower.count == 68 else { throw Failure.badHash }
        var out = Data()
        var index = lower.index(lower.startIndex, offsetBy: 4)
        while index < lower.endIndex { let next = lower.index(index, offsetBy: 2); guard let b = UInt8(lower[index..<next], radix: 16) else { throw Failure.badHash }; out.append(b); index = next }
        return out
    }

    /// 40 hex characters or 32 base32 characters.
    static func hash(_ text: String) -> Data? {
        if text.count == 40, text.allSatisfy({ $0.isASCII && $0.isHexDigit }) {          // ASCII only: full-width digits pass isHexDigit but are not numbers to UInt8(radix:)
            var out = Data()
            var index = text.startIndex
            while index < text.endIndex { let next = text.index(index, offsetBy: 2); guard let b = UInt8(text[index..<next], radix: 16) else { return nil }; out.append(b); index = next }
            return out
        }
        guard text.count == 32 else { return nil }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0, value = 0
        var out = Data()
        for ch in text.uppercased() {
            guard let v = alphabet.firstIndex(of: ch) else { return nil }
            value = (value << 5) | v; bits += 5
            if bits >= 8 { out.append(UInt8((value >> (bits - 8)) & 0xFF)); bits -= 8 }
        }
        return out.count == 20 ? out : nil
    }
}
