import Foundation
import Network

// MARK: A tracker request that goes to the address that was checked
//
// URLSession looks a name up itself, after any check made beforehand, and follows redirects on its own, so a name that answers differently the second time (DNS rebinding), or a public tracker that
// redirects to a router, could be reached after the check passed. For a direct connection (no proxy) a tracker request is therefore made here: the name is resolved once and checked, the
// connection is made to that numeric address (TLS still verifies the certificate against the tracker's own name), and a redirect is never followed by the system: it is read, checked the same way,
// and only then requested. HTTP/1.0 with `Connection: close` keeps the reply free of chunking, so reading it is reading until the connection ends.

/// Whether the Mac itself is set to use a proxy (HTTP, HTTPS, SOCKS or an automatic configuration). "Use my Mac's settings" means that proxy, so a connection that would ignore it is not made.
enum SystemProxy {
    static func isActive() -> Bool {
        guard let s = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return false }
        return ["HTTPEnable", "HTTPSEnable", "SOCKSEnable", "ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable"].contains { (s[$0] as? NSNumber)?.boolValue == true }
    }
}

struct PinnedHTTPResult: Sendable { var status: Int; var location: String?; var body: Data; var contentRange: String? = nil
    /// The reply's headers, names lower-cased, for the few callers that need more than the status and the body (an icon: its type, validators and cache hints).
    var headers: [String: String] = [:] }

protocol PinnedHTTPConnecting: Sendable {
    /// One GET of `url` over a connection to `address` (a numeric IPv4 or IPv6 address).
    func get(_ url: URL, address: String, maxBody: Int, refuseExpensive: Bool, refuseConstrained: Bool) async throws -> PinnedHTTPResult
    /// The same with one extra request header (a `Range`, for a web seed). A connector that does not know headers ignores it, which a caller must be ready for (the answer is then a 200).
    func get(_ url: URL, address: String, maxBody: Int, range: String?, refuseExpensive: Bool, refuseConstrained: Bool) async throws -> PinnedHTTPResult
    /// The same with validators for a conditional request (`If-None-Match`, `If-Modified-Since`).
    func get(_ url: URL, address: String, maxBody: Int, conditional: [String: String], refuseExpensive: Bool, refuseConstrained: Bool) async throws -> PinnedHTTPResult
}

extension PinnedHTTPConnecting {
    func get(_ url: URL, address: String, maxBody: Int, range: String?, refuseExpensive: Bool, refuseConstrained: Bool) async throws -> PinnedHTTPResult {
        try await get(url, address: address, maxBody: maxBody, refuseExpensive: refuseExpensive, refuseConstrained: refuseConstrained)
    }
    /// A connector that does not know validators ignores them (the answer is then a 200).
    func get(_ url: URL, address: String, maxBody: Int, conditional: [String: String], refuseExpensive: Bool, refuseConstrained: Bool) async throws -> PinnedHTTPResult {
        try await get(url, address: address, maxBody: maxBody, refuseExpensive: refuseExpensive, refuseConstrained: refuseConstrained)
    }
}

struct NWPinnedHTTP: PinnedHTTPConnecting {
    enum Failure: Error, LocalizedError {
        case badURL, badReply, tooLarge, timedOut
        var errorDescription: String? {
            switch self {
            case .badURL: "The tracker address could not be used"
            case .badReply: "The tracker's answer was not understood"
            case .tooLarge: "The tracker's answer was too large"
            case .timedOut: "The tracker did not answer in time"
            }
        }
    }

    var timeout: TimeInterval = 20

    static func isNumeric(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return IPv4Address(h) != nil || IPv6Address(h) != nil
    }

    func get(_ url: URL, address: String, maxBody: Int, refuseExpensive: Bool, refuseConstrained: Bool) async throws -> PinnedHTTPResult {
        try await get(url, address: address, maxBody: maxBody, range: nil, refuseExpensive: refuseExpensive, refuseConstrained: refuseConstrained)
    }

    func get(_ url: URL, address: String, maxBody: Int, conditional: [String: String], refuseExpensive: Bool, refuseConstrained: Bool) async throws -> PinnedHTTPResult {
        try await get(url, address: address, maxBody: maxBody, range: nil, conditional: conditional, refuseExpensive: refuseExpensive, refuseConstrained: refuseConstrained)
    }

    func get(_ url: URL, address: String, maxBody: Int, range: String?, refuseExpensive: Bool, refuseConstrained: Bool) async throws -> PinnedHTTPResult {
        try await get(url, address: address, maxBody: maxBody, range: range, conditional: [:], refuseExpensive: refuseExpensive, refuseConstrained: refuseConstrained)
    }

    /// The only validators ever sent: `If-None-Match` and `If-Modified-Since`, made of the characters an ETag or an HTTP date is made of, so nothing else can be put into the request.
    private static func conditionalLines(_ headers: [String: String]) -> String {
        var out = ""
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) where ["If-None-Match", "If-Modified-Since"].contains(name) {
            guard value.utf8.count <= 200, value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || " \"/-_.,:;=+*".contains($0)) }) else { continue }
            out += "\(name): \(value)\r\n"
        }
        return out
    }

    func get(_ url: URL, address: String, maxBody: Int, range: String?, conditional: [String: String], refuseExpensive: Bool, refuseConstrained: Bool) async throws -> PinnedHTTPResult {
        guard let host = url.host, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { throw Failure.badURL }
        let secure = scheme == "https"
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: url.port ?? (secure ? 443 : 80))) else { throw Failure.badURL }
        let target: NWEndpoint.Host
        if let v4 = IPv4Address(address) { target = .ipv4(v4) } else if let v6 = IPv6Address(address) { target = .ipv6(v6) } else { throw Failure.badURL }
        let parameters: NWParameters
        if secure {
            let options = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(options.securityProtocolOptions, host)          // the certificate must be for this name, not for the address
            parameters = NWParameters(tls: options)
        } else { parameters = .tcp }
        parameters.prohibitExpensivePaths = refuseExpensive          // the person's own network settings apply to tracker traffic as they do to the download
        parameters.prohibitConstrainedPaths = refuseConstrained
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw Failure.badURL }
        let path = (comps.percentEncodedPath.isEmpty ? "/" : comps.percentEncodedPath) + (comps.percentEncodedQuery.map { "?" + $0 } ?? "")
        let shownHost = host.contains(":") ? "[\(host)]" : host
        guard host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == ":" || $0 == "_" }) else { throw Failure.badURL }
        let hostHeader = url.port.map { "\(shownHost):\($0)" } ?? shownHost
        // The only extra header ever sent is a byte range of digits ("bytes=a-b"), checked here so nothing else can be put into the request.
        var rangeLine = ""
        if let range {
            guard range.hasPrefix("bytes="), range.dropFirst(6).allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "-") }), range.utf8.count <= 40 else { throw Failure.badURL }
            rangeLine = "Range: \(range)\r\n"
        }
        let request = Data("GET \(path) HTTP/1.0\r\nHost: \(hostHeader)\r\nUser-Agent: Browser Setu\r\nAccept: */*\r\n\(rangeLine)\(Self.conditionalLines(conditional))Connection: close\r\n\r\n".utf8)

        let connection = NWConnection(host: target, port: port, using: parameters)
        // A big answer gets longer: the time allowed grows with the most that can arrive (about 40 KB/s as the slowest speed worth waiting for).
        let allowed = max(timeout, 20 + Double(maxBody) / 40_000)
        let raw = try await Self.exchange(connection, request: request, limit: maxBody + 16_384, timeout: allowed)
        return try Self.parse(raw, maxBody: maxBody)
    }

    private final class Box: @unchecked Sendable { var data = Data() }

    private static func exchange(_ connection: NWConnection, request: Data, limit: Int, timeout: TimeInterval) async throws -> Data {
        let queue = DispatchQueue(label: "browser-setu.tracker-http")
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
                let once = Once(), box = Box()
                func finish(_ result: Result<Data, Error>) { if once.take() { connection.cancel(); c.resume(with: result) } }
                func readMore() {
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
                        if let data { box.data.append(data) }
                        if box.data.count > limit { finish(.failure(Failure.tooLarge)); return }
                        if let error { finish(.failure(error)); return }
                        if complete { finish(.success(box.data)) } else { readMore() }
                    }
                }
                queue.asyncAfter(deadline: .now() + timeout) { finish(.failure(Failure.timedOut)) }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connection.send(content: request, completion: .contentProcessed { error in if let error { finish(.failure(error)) } })
                        readMore()
                    case .failed(let error), .waiting(let error): finish(.failure(error))            // no route: not waited for
                    case .cancelled: finish(.failure(CancellationError()))
                    default: break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: { connection.cancel() }
    }

    static func parse(_ raw: Data, maxBody: Int) throws -> PinnedHTTPResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = raw.range(of: separator) else { throw Failure.badReply }
        let head = String(decoding: raw[raw.startIndex..<end.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let status = lines.first?.split(separator: " ").dropFirst().first.flatMap { Int($0) }
        guard let status else { throw Failure.badReply }
        var location: String?, length: Int?, contentRange: String?
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased(), value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if headers.count < 64 { headers[name] = value }
            if name == "location" { location = value }
            if name == "content-range" { contentRange = value }
            if name == "content-length" { length = Int(value) }
            if name == "transfer-encoding", value.lowercased().contains("chunked") { throw Failure.badReply }
        }
        var body = Data(raw[end.upperBound...])
        if let length, length >= 0, length < body.count { body = body.prefix(length) }
        if let length, length > body.count { throw Failure.badReply }          // the connection ended early: a short body is a failed transfer, not a different file
        guard body.count <= maxBody else { throw Failure.tooLarge }
        return PinnedHTTPResult(status: status, location: location, body: body, contentRange: contentRange, headers: headers)
    }
}
