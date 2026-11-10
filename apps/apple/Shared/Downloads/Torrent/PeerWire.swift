import Foundation
import CryptoKit

/// The peer wire protocol (BEP 3), with the extension protocol (BEP 10) bit. Pure: bytes in, messages out. Peers are strangers, so the parser decides how much it will ever hold before it
/// reads a single payload byte, and a peer that breaks a rule is dropped.
enum PeerWire {
    static let blockSize = 16 * 1024
    static let protocolName = Array("BitTorrent protocol".utf8)
    static let handshakeLength = 68

    // MARK: Handshake

    struct Handshake: Equatable {
        var reserved: [UInt8]
        var infoHash: Data
        var peerID: Data
        var supportsExtensions: Bool { reserved.count == 8 && reserved[5] & 0x10 != 0 }
        /// BEP 6: the Fast Extension bit (0x04 of the last reserved byte).
        var supportsFast: Bool { reserved.count == 8 && reserved[7] & 0x04 != 0 }
    }

    static func handshake(infoHash: Data, peerID: Data, extensions: Bool, fast: Bool = false) -> Data {
        var out = Data([19]); out.append(contentsOf: protocolName)
        var reserved = [UInt8](repeating: 0, count: 8)
        if extensions { reserved[5] |= 0x10 }
        if fast { reserved[7] |= 0x04 }
        out.append(contentsOf: reserved); out.append(infoHash); out.append(peerID)
        return out
    }

    enum Failure: Error, Equatable, LocalizedError {
        case badHandshake, wrongTorrent, messageTooLong(UInt32), badMessage(String)
        var errorDescription: String? {
            switch self {
            case .badHandshake: "A peer did not speak the BitTorrent protocol."
            case .wrongTorrent: "A peer is sharing a different torrent."
            case .messageTooLong: "A peer sent a message that is too long."
            case .badMessage(let why): "A peer sent a message that is not valid (\(why))."
            }
        }
    }

    /// Reads the 68-byte handshake. Throws for anything that is not exactly the protocol's.
    static func parseHandshake(_ data: Data) throws -> Handshake {
        let b = [UInt8](data)
        guard b.count >= handshakeLength, b[0] == 19, Array(b[1..<20]) == protocolName else { throw Failure.badHandshake }
        return Handshake(reserved: Array(b[20..<28]), infoHash: Data(b[28..<48]), peerID: Data(b[48..<68]))
    }

    // MARK: Messages

    enum Message: Equatable {
        case keepAlive, choke, unchoke, interested, notInterested
        case have(Int)
        case bitfield(Data)
        case request(index: Int, begin: Int, length: Int)
        case piece(index: Int, begin: Int, data: Data)
        case cancel(index: Int, begin: Int, length: Int)
        case extended(id: UInt8, payload: Data)
        /// BEP 6 (Fast Extension)
        case suggest(Int), haveAll, haveNone, allowedFast(Int)
        case rejectRequest(index: Int, begin: Int, length: Int)
        case unknown(UInt8)
    }

    static func encode(_ message: Message) -> Data {
        func u32(_ v: Int) -> [UInt8] { withUnsafeBytes(of: UInt32(truncatingIfNeeded: v).bigEndian, Array.init) }
        func frame(_ id: UInt8, _ body: [UInt8] = []) -> Data { Data(u32(1 + body.count) + [id] + body) }
        switch message {
        case .keepAlive: return Data(u32(0))
        case .choke: return frame(0)
        case .unchoke: return frame(1)
        case .interested: return frame(2)
        case .notInterested: return frame(3)
        case .have(let i): return frame(4, u32(i))
        case .bitfield(let d): return frame(5, [UInt8](d))
        case .request(let i, let b, let l): return frame(6, u32(i) + u32(b) + u32(l))
        case .piece(let i, let b, let d): return frame(7, u32(i) + u32(b) + [UInt8](d))
        case .cancel(let i, let b, let l): return frame(8, u32(i) + u32(b) + u32(l))
        case .extended(let id, let p): return frame(20, [id] + [UInt8](p))
        case .suggest(let i): return frame(0x0D, u32(i))
        case .haveAll: return frame(0x0E)
        case .haveNone: return frame(0x0F)
        case .rejectRequest(let i, let b, let l): return frame(0x10, u32(i) + u32(b) + u32(l))
        case .allowedFast(let i): return frame(0x11, u32(i))
        case .unknown(let id): return frame(id)
        }
    }

    /// Splits a stream into messages, holding at most one incomplete frame, and never one longer than the largest message this torrent can legitimately produce.
    struct Parser {
        private var buffer = Data()
        let maxLength: Int

        /// `pieceCount` bounds a bitfield; `maxExtended` bounds extension messages (metadata pieces are 16 KiB plus a small header).
        init(pieceCount: Int, maxExtended: Int = 64 * 1024) {
            maxLength = max(1 + (pieceCount + 7) / 8, 9 + PeerWire.blockSize, 2 + maxExtended, 13)
        }

        mutating func feed(_ data: Data) throws -> [Message] {
            try feedAll(data).map { item in
                switch item {
                case .message(let m): return m
                case .hash(let h): return .unknown(h.kind.rawValue)        // the version 2 hash messages are only seen by a caller that asks for them with `feedAll`
                }
            }
        }

        /// Like `feed`, but the BEP 52 messages (21, 22, 23) come back decoded instead of being dropped as unknown.
        mutating func feedAll(_ data: Data) throws -> [Item] {
            buffer.append(data)
            var out: [Item] = []
            while buffer.count >= 4 {
                let length = buffer.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                // Checked before waiting for the payload: a peer cannot make this buffer grow by announcing a huge frame.
                guard Int(length) <= maxLength else { throw Failure.messageTooLong(length) }
                guard buffer.count >= 4 + Int(length) else { break }
                let start = buffer.startIndex + 4
                let body = buffer.subdata(in: start..<(start + Int(length)))
                buffer.removeSubrange(buffer.startIndex..<(start + Int(length)))
                if let id = body.first, (21...23).contains(id) { out.append(.hash(try PeerWire.decodeHash(body))) }
                else { out.append(.message(try Self.decode(body))) }
            }
            return out
        }

        enum Item: Equatable { case message(Message), hash(HashMessage) }

        var buffered: Int { buffer.count }

        static func decode(_ body: Data) throws -> Message {
            guard let id = body.first else { return .keepAlive }
            let p = [UInt8](body.dropFirst())
            func u32(_ at: Int) -> Int { Int(p[at]) << 24 | Int(p[at + 1]) << 16 | Int(p[at + 2]) << 8 | Int(p[at + 3]) }
            switch id {
            case 0, 1, 2, 3:
                guard p.isEmpty else { throw Failure.badMessage("a state message has a body") }
                return [Message.choke, .unchoke, .interested, .notInterested][Int(id)]
            case 4: guard p.count == 4 else { throw Failure.badMessage("have") }; return .have(u32(0))
            case 5: return .bitfield(Data(p))
            case 6, 8:
                guard p.count == 12 else { throw Failure.badMessage("request") }
                return id == 6 ? .request(index: u32(0), begin: u32(4), length: u32(8)) : .cancel(index: u32(0), begin: u32(4), length: u32(8))
            case 7:
                guard p.count >= 8, p.count - 8 <= PeerWire.blockSize else { throw Failure.badMessage("piece") }
                return .piece(index: u32(0), begin: u32(4), data: Data(p[8...]))
            case 20:
                guard let ext = p.first else { throw Failure.badMessage("extended") }
                return .extended(id: ext, payload: Data(p.dropFirst()))
            case 0x0D, 0x11:
                guard p.count == 4 else { throw Failure.badMessage(id == 0x0D ? "suggest" : "allowed fast") }
                return id == 0x0D ? .suggest(u32(0)) : .allowedFast(u32(0))
            case 0x0E, 0x0F:
                guard p.isEmpty else { throw Failure.badMessage(id == 0x0E ? "have all" : "have none") }
                return id == 0x0E ? .haveAll : .haveNone
            case 0x10:
                guard p.count == 12 else { throw Failure.badMessage("reject request") }
                return .rejectRequest(index: u32(0), begin: u32(4), length: u32(8))
            default: return .unknown(id)
            }
        }
    }

    // MARK: BitTorrent v2 hash messages (BEP 52)

    /// Messages 21 (hash request), 22 (hashes) and 23 (hash reject). Payload: pieces root (32 bytes), base layer, index, length, proof layers (each a 4-byte big-endian integer, as the BEP's
    /// "all later integers" rule says and libtorrent writes them), then for `hashes` the concatenated 32-byte hashes: `length` hashes of the base layer, then the uncle hashes, nearest the base first.
    struct HashMessage: Equatable {
        enum Kind: UInt8 { case request = 21, hashes = 22, reject = 23 }
        var kind: Kind
        var piecesRoot: Data
        var baseLayer: Int
        var index: Int
        var length: Int
        var proofLayers: Int
        var hashes: [Data] = []
    }

    /// At most this many hashes may be asked for at once (BEP 52 says a request should not exceed 512).
    static let maxHashesPerRequest = 512
    static let maxProofLayers = 64

    static func hashRequest(piecesRoot: Data, baseLayer: Int, index: Int, length: Int, proofLayers: Int) -> Data {
        encodeHash(HashMessage(kind: .request, piecesRoot: piecesRoot, baseLayer: baseLayer, index: index, length: length, proofLayers: proofLayers))
    }

    static func encodeHash(_ m: HashMessage) -> Data {
        func u32(_ v: Int) -> [UInt8] { withUnsafeBytes(of: UInt32(truncatingIfNeeded: v).bigEndian, Array.init) }
        var body: [UInt8] = [m.kind.rawValue]
        body += [UInt8](m.piecesRoot) + u32(m.baseLayer) + u32(m.index) + u32(m.length) + u32(m.proofLayers)
        for h in m.hashes { body += [UInt8](h) }
        return Data(u32(body.count) + body)
    }

    /// Decodes the body of a message (id byte first). Every size is checked before anything is kept: `length` a power of two from 2 to 512, `index` a multiple of it, at most 512 + 64 hashes,
    /// each exactly 32 bytes. Whether the hashes are the right ones is `HashProof.verify`'s job.
    static func decodeHash(_ body: Data) throws -> HashMessage {
        let b = [UInt8](body)
        guard let id = b.first, let kind = HashMessage.Kind(rawValue: id) else { throw Failure.badMessage("hash message id") }
        let fixed = 1 + 32 + 16
        guard b.count >= fixed else { throw Failure.badMessage("hash message is short") }
        func u32(_ at: Int) -> Int { Int(b[at]) << 24 | Int(b[at + 1]) << 16 | Int(b[at + 2]) << 8 | Int(b[at + 3]) }
        let base = u32(33), index = u32(37), length = u32(41), proofs = u32(45)
        guard Merkle.isPowerOfTwo(length), length >= 2, length <= maxHashesPerRequest, index % length == 0, base <= 63, proofs <= maxProofLayers else { throw Failure.badMessage("hash message fields") }
        var hashes: [Data] = []
        switch kind {
        case .request, .reject:
            guard b.count == fixed else { throw Failure.badMessage("hash request has extra bytes") }
        case .hashes:
            let rest = b.count - fixed
            guard rest % 32 == 0, rest / 32 >= length, rest / 32 <= length + maxProofLayers else { throw Failure.badMessage("hashes") }
            hashes = stride(from: fixed, to: b.count, by: 32).map { Data(b[$0..<($0 + 32)]) }
        }
        return HashMessage(kind: kind, piecesRoot: Data(b[1..<33]), baseLayer: base, index: index, length: length, proofLayers: proofs, hashes: hashes)
    }

    // MARK: Bitfields

    static func has(_ bitfield: Data, _ index: Int) -> Bool {
        guard index >= 0, index / 8 < bitfield.count else { return false }
        return bitfield[bitfield.startIndex + index / 8] & (0x80 >> UInt8(index % 8)) != 0
    }

    static func makeBitfield(_ have: [Bool]) -> Data {
        var out = [UInt8](repeating: 0, count: (have.count + 7) / 8)
        for (i, h) in have.enumerated() where h { out[i / 8] |= 0x80 >> UInt8(i % 8) }
        return Data(out)
    }

    /// A peer's bitfield must be exactly the right length, and its spare bits must be zero.
    static func validBitfield(_ data: Data, pieceCount: Int) -> Bool {
        guard data.count == (pieceCount + 7) / 8 else { return false }
        let spare = data.count * 8 - pieceCount
        guard spare > 0, let last = data.last else { return true }
        return last & UInt8((1 << spare) - 1) == 0
    }

    // MARK: Extension protocol (BEP 10) and metadata exchange (BEP 9)

    enum ExtensionID { static let handshake: UInt8 = 0; static let utMetadata: UInt8 = 1; static let utPex: UInt8 = 2 }

    static func extensionHandshake(metadataSize: Int?, pex: Bool = false) -> Data {
        var m: [String: Bencode] = ["ut_metadata": .int(Int64(ExtensionID.utMetadata))]
        if pex { m["ut_pex"] = .int(Int64(ExtensionID.utPex)) }
        var d: [String: Bencode] = ["m": .dict(m), "v": .bytes(Data("Browser Setu".utf8))]
        if let metadataSize { d["metadata_size"] = .int(Int64(metadataSize)) }
        return BencodeDecoder.encode(.dict(d))
    }

    static let maxMetadataSize = TorrentMetainfo.Limit.maxInfoBytes
    static let metadataPieceSize = 16 * 1024

    static func metadataRequest(piece: Int) -> Data { BencodeDecoder.encode(.dict(["msg_type": .int(0), "piece": .int(Int64(piece))])) }
    static func metadataReject(piece: Int) -> Data { BencodeDecoder.encode(.dict(["msg_type": .int(2), "piece": .int(Int64(piece))])) }
    static func metadataData(piece: Int, total: Int, data: Data) -> Data {
        var out = BencodeDecoder.encode(.dict(["msg_type": .int(1), "piece": .int(Int64(piece)), "total_size": .int(Int64(total))])); out.append(data); return out
    }

    /// Splits a ut_metadata message into its dictionary and the data that follows it. Both are bounded.
    static func parseMetadataMessage(_ payload: Data) throws -> (type: Int, piece: Int, totalSize: Int?, data: Data) {
        // The dictionary ends where its own bencoding ends; find that by decoding the longest prefix that is a complete dictionary.
        var end = min(payload.count, 512)
        while end > 0 {
            if let decoded = try? BencodeDecoder.decode(payload.prefix(end), limits: .message), let dict = decoded.value.dict {
                guard let type = dict["msg_type"]?.int, let piece = dict["piece"]?.int, piece >= 0, piece < Int64(maxMetadataSize / metadataPieceSize + 1) else { throw Failure.badMessage("metadata") }
                return (Int(type), Int(piece), dict["total_size"]?.int.map(Int.init), payload.dropFirst(end))
            }
            end -= 1
        }
        throw Failure.badMessage("metadata")
    }

    // MARK: Fast Extension helpers (BEP 6)

    /// The canonical "allowed fast" set for a peer at an IPv4 address (BEP 6): `k` piece indexes derived from the masked address and the info-hash, so both ends compute the same set.
    static func allowedFastSet(ipv4: [UInt8], infoHash: Data, pieceCount: Int, k: Int = 10) -> [Int] {
        guard ipv4.count == 4, pieceCount > 0, infoHash.count == 20 else { return [] }
        let target = min(k, pieceCount)
        var x = Data([ipv4[0], ipv4[1], ipv4[2], 0]); x.append(infoHash)
        var out: [Int] = []
        while out.count < target {
            x = Data(Insecure.SHA1.hash(data: x))
            let b = [UInt8](x)
            for i in 0..<5 where out.count < target {
                let y = Int(b[4 * i]) << 24 | Int(b[4 * i + 1]) << 16 | Int(b[4 * i + 2]) << 8 | Int(b[4 * i + 3])
                let index = y % pieceCount
                if !out.contains(index) { out.append(index) }
            }
        }
        return out
    }

    // MARK: Peer exchange (BEP 11)

    struct PexPeer: Equatable { var address: PeerAddress; var flags: UInt8 }
    struct PexMessage: Equatable { var added: [PexPeer] = []; var dropped: [PeerAddress] = [] }

    /// Limits on one PEX message: a stranger cannot make this larger.
    static let maxPexPeers = 50

    static func pexMessage(added: [PexPeer], dropped: [PeerAddress]) -> Data {
        func compact(_ list: [PeerAddress], v6: Bool) -> Data { var d = Data(); for a in list { if let e = DHTEndpoint(host: a.host, port: a.port), e.isIPv6 == v6 { d.append(e.compact) } }; return d }
        let a4 = added.filter { DHTEndpoint(host: $0.address.host, port: $0.address.port)?.isIPv6 == false }.prefix(maxPexPeers)
        let a6 = added.filter { DHTEndpoint(host: $0.address.host, port: $0.address.port)?.isIPv6 == true }.prefix(maxPexPeers)
        var d: [String: Bencode] = [:]
        d["added"] = .bytes(compact(a4.map(\.address), v6: false)); d["added.f"] = .bytes(Data(a4.map(\.flags)))
        d["added6"] = .bytes(compact(a6.map(\.address), v6: true)); d["added6.f"] = .bytes(Data(a6.map(\.flags)))
        d["dropped"] = .bytes(compact(Array(dropped.prefix(maxPexPeers)), v6: false)); d["dropped6"] = .bytes(compact(Array(dropped.prefix(maxPexPeers)), v6: true))
        return BencodeDecoder.encode(.dict(d))
    }

    /// nil when the payload is not a dictionary. Lists that are not a whole number of entries are ignored whole; at most `maxPexPeers` entries of each kind are read.
    static func parsePex(_ payload: Data) -> PexMessage? {
        guard let dict = (try? BencodeDecoder.decode(payload, limits: .message))?.value.dict else { return nil }
        var out = PexMessage()
        func read(_ key: String, size: Int, v6: Bool) -> [PeerAddress] {
            guard let data = dict[key]?.data, data.count % size == 0 else { return [] }
            let b = [UInt8](data)
            return stride(from: 0, to: min(b.count, size * maxPexPeers), by: size).compactMap { o in DHTEndpoint(compact: Data(b[o..<(o + size)])).map { $0.peerAddress } }
        }
        let a4 = read("added", size: 6, v6: false), a6 = read("added6", size: 18, v6: true)
        let f4 = [UInt8](dict["added.f"]?.data ?? Data()), f6 = [UInt8](dict["added6.f"]?.data ?? Data())
        out.added = a4.enumerated().map { PexPeer(address: $1, flags: $0 < f4.count ? f4[$0] : 0) } + a6.enumerated().map { PexPeer(address: $1, flags: $0 < f6.count ? f6[$0] : 0) }
        out.dropped = read("dropped", size: 6, v6: false) + read("dropped6", size: 18, v6: true)
        return out
    }
}
