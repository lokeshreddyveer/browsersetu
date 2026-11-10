import Foundation

// MARK: Web seeds (BEP 19, GetRight style) and HTTP seeds (BEP 17, Hoffman style)
//
// A web seed is a server that has the torrent's files. It takes part in the transfer as one more source of pieces: the session claims a whole piece for it from the same piece picker the peers
// use, asks it for exactly the bytes of that piece, and checks the piece against the torrent's hash like any other. Nothing from a web seed is trusted before that check.
//
// BEP 19 (`url-list`): a plain file server. A URL ending in "/" gets the torrent's name added; for a multi-file torrent the URL is a root folder and `name/path/file` is added. A piece is the
// bytes of one or more files, so it is asked for with HTTP byte ranges, one request for each file the piece touches.
// BEP 17 (`httpseeds`): a script that takes `?info_hash=…&piece=N&ranges=a-b,c-d` (ranges inclusive, inside the piece) and answers 200 with the bytes, or 503 with the number of seconds to wait.
//
// The URLs come from a torrent file or a magnet link: untrusted input. They are fetched through the same code that fetches tracker addresses (address pinning, local addresses refused unless
// approved, redirects checked one by one, the person's proxy and metered-network choices), with credentials never added.

enum WebSeedKind: String, Sendable { case getRight = "web seed", hoffman = "HTTP seed" }

struct WebSeedSource: Hashable, Sendable {
    var kind: WebSeedKind
    var url: URL
    /// Shown in the inspector: host only (a path or query can carry a personal key).
    var displayName: String { url.host.map { h in url.port.map { "\(h):\($0)" } ?? h } ?? "web seed" }
}

/// One byte range of one URL needed to build a piece.
struct WebSeedRequest: Equatable, Sendable {
    var url: URL
    /// Inclusive byte range inside that URL's resource.
    var range: ClosedRange<Int64>
    /// The whole resource's length (known from the torrent), for a server that answers 200 with everything.
    var resourceLength: Int64
    /// Bytes that are zeros by definition (a BEP 47 padding file): nothing is fetched for them.
    var isPadding = false
}

enum WebSeedMapping {
    /// Percent-encodes one path component (a "/" inside would make a new component; none can be in a validated name, but this is the place that guarantees it).
    static func encode(_ component: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        return component.addingPercentEncoding(withAllowedCharacters: allowed) ?? component
    }

    static func isPadding(_ f: TorrentMetainfo.File) -> Bool { f.isPadding }          // BEP 47 padding: zeros by definition, never fetched

    /// The address of a file under a BEP 19 base address; nil if the result would not be a plain http(s) address on the same host as the base.
    static func fileURL(base: URL, meta: TorrentMetainfo, file: TorrentMetainfo.File) -> URL? {
        var text = base.absoluteString
        guard text.utf8.count <= 4096 else { return nil }
        if meta.isMultiFile {
            if !text.hasSuffix("/") { text += "/" }
            text += encode(meta.rawName ?? meta.name) + "/" + (file.rawPath ?? file.path).map(encode).joined(separator: "/")
        } else if text.hasSuffix("/") {
            text += encode(meta.rawName ?? meta.name)
        }
        guard let url = URL(string: text), url.host == base.host, url.port == base.port, url.scheme?.lowercased() == base.scheme?.lowercased(), url.user == nil, url.password == nil else { return nil }
        return url
    }

    /// The byte ranges that make up piece `index` (one for each file it touches), in order.
    static func requests(base: URL, meta: TorrentMetainfo, piece index: Int) -> [WebSeedRequest]? {
        guard index >= 0, index < meta.pieceCount else { return nil }
        var out: [WebSeedRequest] = []
        for seg in meta.segments(offset: Int64(index) * meta.pieceLength, length: meta.length(ofPiece: index)) {
            let f = meta.files[seg.file]
            guard let url = fileURL(base: base, meta: meta, file: f), seg.count > 0 else { return nil }
            out.append(WebSeedRequest(url: url, range: seg.fileOffset...(seg.fileOffset + seg.count - 1), resourceLength: f.length, isPadding: isPadding(f)))
        }
        return out.isEmpty ? nil : out
    }

    /// BEP 17: `<url>?info_hash=<escaped>&piece=<n>` (and `&ranges=a-b` inside the piece, inclusive, when only part is wanted). An address that already has a query gets the parameters added.
    static func hoffmanURL(base: URL, infoHash: Data, piece: Int, ranges: [ClosedRange<Int>]? = nil) -> URL? {
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        let escaped = infoHash.map { String(format: "%%%02X", $0) }.joined()
        var query = (comps.percentEncodedQuery.map { $0.isEmpty ? "" : $0 + "&" } ?? "") + "info_hash=\(escaped)&piece=\(piece)"
        if let ranges, !ranges.isEmpty { query += "&ranges=" + ranges.map { "\($0.lowerBound)-\($0.upperBound)" }.joined(separator: ",") }
        comps.percentEncodedQuery = query
        return comps.url
    }

    /// The seeds of a torrent, deduplicated: its own `url-list` and `httpseeds`, and those a magnet link carried (`ws=`).
    static func sources(meta: TorrentMetainfo, magnetSeeds: [URL] = []) -> [WebSeedSource] {
        var seen = Set<String>(), out: [WebSeedSource] = []
        for u in meta.webSeeds + magnetSeeds where seen.insert("g" + u.absoluteString).inserted { out.append(WebSeedSource(kind: .getRight, url: u)) }
        for u in meta.httpSeeds where seen.insert("h" + u.absoluteString).inserted { out.append(WebSeedSource(kind: .hoffman, url: u)) }
        return Array(out.prefix(12))
    }
}

/// What a request to a seed came to.
enum WebSeedFailure: Error, Equatable, Sendable {
    /// Wait this long and try again (a 503, or a timeout).
    case busy(seconds: Int)
    /// This seed cannot serve this torrent (404, 403, ranges not honoured on a large file…): it is dropped.
    case unusable(String)
    /// The network or the server failed for now: tried again later, less often each time.
    case transient(String)
    /// The bytes did not match the torrent: the seed is dropped (BEP 19: the URL "should be discarded").
    case wrongData
    /// The person's settings or approvals do not allow contacting it.
    case blocked(String)
}

protocol WebSeedFetching: Sendable {
    /// The bytes of one piece from one seed. Throws a `WebSeedFailure`.
    func piece(_ index: Int, from source: WebSeedSource, meta: TorrentMetainfo) async throws -> Data
}

/// Fetches pieces through the tracker client's HTTP path (same address rules, proxy and metered-network choices).
final class HTTPWebSeedFetcher: WebSeedFetching, @unchecked Sendable {
    private let client: HTTPTrackerClient
    /// Bigger than any sensible piece, so one answer cannot fill memory.
    static let maxBody = 33 * 1024 * 1024
    /// A server that ignores Range and sends a whole file is accepted only when the file is this small.
    static let wholeFileFallbackLimit = 8 * 1024 * 1024

    init(client: HTTPTrackerClient) { self.client = client }

    func piece(_ index: Int, from source: WebSeedSource, meta: TorrentMetainfo) async throws -> Data {
        switch source.kind {
        case .getRight:
            guard let requests = WebSeedMapping.requests(base: source.url, meta: meta, piece: index) else { throw WebSeedFailure.unusable("The address could not be used for this torrent.") }
            var out = Data()
            for r in requests {
                if r.isPadding { out.append(Data(count: Int(r.range.count))); continue }
                out.append(try await bytes(of: r))
            }
            guard Int64(out.count) == meta.length(ofPiece: index) else { throw WebSeedFailure.wrongData }
            return out
        case .hoffman:
            guard let url = WebSeedMapping.hoffmanURL(base: source.url, infoHash: meta.infoHash, piece: index) else { throw WebSeedFailure.unusable("The address could not be used.") }
            // Room for a short error page too, so a 502/503 is read as a status and not mistaken for an oversized answer.
            let result = try await get(url, range: nil, maxBody: Int(min(Int64(Self.maxBody), max(meta.length(ofPiece: index) + 1, 65_536))))
            switch result.status {
            case 200:
                guard Int64(result.body.count) == meta.length(ofPiece: index) else { throw WebSeedFailure.wrongData }
                return result.body
            case 503, 502, 504:
                throw WebSeedFailure.busy(seconds: Self.seconds(in: result.body))
            case 404, 403, 410, 400, 401: throw WebSeedFailure.unusable("HTTP \(result.status)")
            default: throw WebSeedFailure.transient("HTTP \(result.status)")
            }
        }
    }

    /// BEP 17: the 503 body is an ASCII integer, how many seconds to wait. Anything else is 30 (the BEP's usual retry time); never less than 5 or more than an hour.
    static func seconds(in body: Data) -> Int {
        let text = String(decoding: body.prefix(16), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return min(3600, max(5, Int(text) ?? 30))
    }

    private func bytes(of r: WebSeedRequest) async throws -> Data {
        let want = Int(r.range.count)
        // Normally the range is all that is read. A server that ignores Range sends the whole file; that is taken only when the file is small enough to be read in full and cut.
        let cap = max(want, Int(min(r.resourceLength, Int64(Self.wholeFileFallbackLimit))))
        let result = try await get(r.url, range: "bytes=\(r.range.lowerBound)-\(r.range.upperBound)", maxBody: cap)
        switch result.status {
        case 206:
            guard result.body.count == want else { throw WebSeedFailure.wrongData }
            if let cr = result.contentRange, !Self.contentRange(cr, matches: r.range) { throw WebSeedFailure.wrongData }
            return result.body
        case 200:
            // The server did not honour the range. The whole file must be what was asked about, and small enough to have been read.
            guard Int64(result.body.count) == r.resourceLength else { throw WebSeedFailure.unusable("The server ignores byte ranges.") }
            return result.body.subdata(in: Int(r.range.lowerBound)..<(Int(r.range.upperBound) + 1))
        case 503: throw WebSeedFailure.busy(seconds: 30)
        case 404, 403, 410, 401, 416: throw WebSeedFailure.unusable("HTTP \(result.status)")
        default: throw WebSeedFailure.transient("HTTP \(result.status)")
        }
    }

    /// "bytes a-b/total" names the range that was asked for.
    static func contentRange(_ value: String, matches range: ClosedRange<Int64>) -> Bool {
        let parts = value.lowercased().replacingOccurrences(of: "bytes", with: "").trimmingCharacters(in: .whitespaces).split(separator: "/")
        guard let span = parts.first?.split(separator: "-"), span.count == 2, let a = Int64(span[0].trimmingCharacters(in: .whitespaces)), let b = Int64(span[1].trimmingCharacters(in: .whitespaces)) else { return false }
        return a == range.lowerBound && b == range.upperBound
    }

    private func get(_ url: URL, range: String?, maxBody: Int) async throws -> PinnedHTTPResult {
        do { return try await client.fetchRaw(url, range: range, maxBody: maxBody, localNeedsApproval: true) }
        catch let failure as WebSeedFailure { throw failure }
        catch let error as HTTPTrackerClient.Failure {
            switch error {
            case .blocked(let why), .proxy(let why): throw WebSeedFailure.blocked(why)
            case .tooLarge: throw WebSeedFailure.unusable("The server sent more than was asked for.")
            case .unreachable: throw WebSeedFailure.transient("The server could not be reached.")
            default: throw WebSeedFailure.transient(error.localizedDescription)
            }
        } catch NWPinnedHTTP.Failure.tooLarge { throw WebSeedFailure.unusable("The server sent more than was asked for (it may ignore byte ranges).")
        } catch is CancellationError { throw CancellationError() }
        catch { throw WebSeedFailure.transient((error as? LocalizedError)?.errorDescription ?? "The server did not answer.") }
    }
}

/// What the session keeps for each seed.
struct WebSeedState: Equatable, Sendable {
    var source: WebSeedSource
    var inFlight: Int? = nil              // piece being fetched
    var bytes: Int64 = 0
    var pieces = 0
    var failures = 0
    var retryAt: TimeInterval = 0
    var disabled: String? = nil           // why it was dropped
    var lastError: String?

    /// Backoff after a transient failure: 30 s, doubling to 10 minutes; six in a row drop the seed for this session.
    mutating func transientFailure(_ why: String, now: TimeInterval) {
        failures += 1; lastError = why
        retryAt = now + min(600, 30 * pow(2, Double(min(failures - 1, 5))))
        if failures >= 6 { disabled = "It kept failing." }
    }
}

struct WebSeedStatusRow: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var kind: String
    var state: String
    var bytes: Int64
    var pieces: Int
    var lastError: String?
}
