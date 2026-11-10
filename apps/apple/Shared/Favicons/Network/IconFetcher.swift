import Foundation
import Network

/// What is asked of the network for one icon.
struct IconFetchRequest: Sendable {
    var url: URL
    /// The page's host: decides whether the icon of a local (user-visited) site may come from the same local host. Never trusted to widen reach to anything else.
    var pageHost: String
    var etag: String?
    var lastModified: String?
    /// The page's origin (scheme, host and port, as `HTTPRequestPolicy.origin(of:)` writes it). The local-site exception needs the icon to come from exactly this origin.
    var pageOrigin: String? = nil
}

struct IconCacheHints: Sendable, Equatable {
    var etag: String?
    var lastModified: String?
    var maxAge: TimeInterval?
    var noStore = false
}

enum IconFetchFailure: String, Sendable, Equatable {
    case refusedByPolicy, redirectRefused, tooLarge, badStatus, offline, timeout, notImageType, unverifiedConnection, cancelled, other
    /// A failure that says nothing about the site (no network, a slow answer, a cancelled request): it is never remembered against the site.
    var isTransient: Bool { self == .offline || self == .timeout || self == .cancelled }
}

enum IconFetchResult: Sendable, Equatable {
    struct Body: Sendable, Equatable { var data: Data; var hints: IconCacheHints; var mimeType: String? }
    case fresh(Body)
    case notModified(IconCacheHints)
    case failed(IconFetchFailure)
}

/// The one door to the network for icons. A test supplies its own; the app uses `NetworkIconFetcher`.
protocol IconFetching: Sendable {
    func fetch(_ request: IconFetchRequest) async -> IconFetchResult
}

/// Fetches an icon with the browser's shared request rules (`HTTPRequestPolicy`), not rules of its own:
///  - the first address and every redirect are judged by the same policy the downloads use, resolved to real addresses, so a page cannot aim a request at the local network,
///  - a direct request is then made to that checked numeric address (`NWPinnedHTTP`), so a name that changes its answer cannot redirect it: prevention, not detection. With a proxy in use the system makes the connection and the address it used is checked afterwards,
///  - no cookies, no cache, no credentials; a login challenge is refused, never answered (the certificate check of https is the system's own),
///  - the body is read as a stream and abandoned the moment it passes the size limit (the length is checked first, then every byte),
///  - only an image-like type is accepted (an HTML error page served with status 200 is not an icon),
///  - the request is conditional when the same address was fetched before (ETag, Last-Modified), so an unchanged icon costs no body.
struct NetworkIconFetcher: IconFetching {
    static let maxBytes = IconDecoder.maxInputBytes
    var requestTimeout: TimeInterval = 5
    var resourceTimeout: TimeInterval = 8
    /// Test seams. The app never sets them: a loopback fixture is let through as the person's own request, a name lookup can be scripted, and a `URLProtocol` can stand in for the wire
    /// (the redirect, size, type and policy code all still run for real).
    var treatsRequestsAsUserOrigin = false
    /// How a direct request is made: to the numeric address that was checked (`NWPinnedHTTP`), so a name that answers differently a second time cannot send the request elsewhere.
    var connector: PinnedHTTPConnecting = NWPinnedHTTP()
    var usesPinnedConnection = true
    var systemProxyActive: @Sendable () -> Bool = { SystemProxy.isActive() }
    var resolver: @Sendable (String) async -> (kind: HostClass, resolved: [String]?) = { await HTTPRequestPolicy.classifyResolving(host: $0) }
    var protocolClasses: [AnyClass]?

    func fetch(_ request: IconFetchRequest) async -> IconFetchResult {
        let pageIsInternal = HTTPRequestPolicy.classify(host: request.pageHost).isInternal
        // A site the person opened on their own network may supply its own icon, from exactly the same origin (scheme, host AND port): a page on localhost:3000
        // may not name localhost:6379. Redirects are confined to that origin too. Nothing else gets this reach.
        let sameOrigin = request.pageOrigin != nil && HTTPRequestPolicy.origin(of: request.url) == request.pageOrigin
        let confinement: String? = (pageIsInternal && sameOrigin) ? request.pageOrigin : nil
        let origin: DownloadRequestOrigin = (treatsRequestsAsUserOrigin || confinement != nil) ? .user : .page
        let policy = HTTPRequestPolicy(origin: origin)
        do { try policy.check(request.url) } catch { return .failed(.refusedByPolicy) }
        // A direct request goes to the address that was checked, not to whatever the name says when the system asks again (DNS rebinding). With a proxy in use the system has to make
        // the connection (it cannot be pinned), and a test that stands in for the wire takes the path below as well.
        if protocolClasses == nil, usesPinnedConnection, !systemProxyActive() {
            return await fetchPinned(request, policy: policy, confinement: confinement)
        }
        if !policy.allowsInternalHosts, let host = request.url.host {
            let (kind, resolved) = await resolver(host)
            if kind.isInternal || resolved == nil { return .failed(.refusedByPolicy) }
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = false
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        let guardian = IconRedirectGuard(policy: policy, start: request.url, confinedTo: confinement, resolver: resolver)
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var urlRequest = URLRequest(url: request.url)
        urlRequest.setValue("image/svg+xml,image/png,image/x-icon,image/*;q=0.8", forHTTPHeaderField: "Accept")
        if let etag = request.etag { urlRequest.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let modified = request.lastModified { urlRequest.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }

        do {
            let (bytes, response) = try await session.bytes(for: urlRequest, delegate: guardian)
            guard let http = response as? HTTPURLResponse else { return .failed(.other) }
            if guardian.refused { return .failed(.redirectRefused) }
            let hints = Self.hints(from: http)
            if http.statusCode == 304 { return .notModified(hints) }
            guard http.statusCode == 200 else { return .failed(.badStatus) }
            if http.expectedContentLength > Int64(Self.maxBytes) { return .failed(.tooLarge) }
            let mime = Self.mimeType(of: http)
            guard Self.isImageLike(mime) else { return .failed(.notImageType) }
            var data = Data()
            data.reserveCapacity(max(0, min(Int(max(http.expectedContentLength, 0)), Self.maxBytes)))
            for try await byte in bytes {
                data.append(byte)
                if data.count > Self.maxBytes { return .failed(.tooLarge) }
            }
            // After the fact: the address the connection really went to. A name that answered differently than when it was checked is refused.
            if let remote = guardian.remoteAddress, !policy.allowsInternalHosts,
               HTTPRequestPolicy.classify(host: remote.split(separator: "%").first.map(String.init) ?? remote).isInternal { return .failed(.unverifiedConnection) }
            return .fresh(.init(data: data, hints: hints, mimeType: mime))
        } catch is CancellationError {
            return .failed(guardian.refused ? .redirectRefused : .cancelled)
        } catch let error as URLError {
            if guardian.refused { return .failed(.redirectRefused) }
            switch error.code {
            case .cancelled: return .failed(.cancelled)
            case .timedOut: return .failed(.timeout)
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff: return .failed(.offline)
            default: return .failed(.other)
            }
        } catch { return .failed(.other) }
    }

    // MARK: The pinned path

    static let maxRedirects = 5

    private func fetchPinned(_ request: IconFetchRequest, policy: HTTPRequestPolicy, confinement: String?) async -> IconFetchResult {
        let budget = resourceTimeout
        return await withTaskGroup(of: IconFetchResult.self) { group in
            group.addTask { await self.pinnedExchange(request, policy: policy, confinement: confinement) }
            group.addTask { try? await Task.sleep(for: .seconds(budget)); return .failed(.timeout) }
            let first = await group.next() ?? .failed(.other)
            group.cancelAll()
            return first
        }
    }

    /// The name is resolved once and judged; the connection is made to that numeric address (TLS still checks the certificate against the site's own name); a redirect is read, judged
    /// the same way (shared policy, then resolved again), and only then requested. Nothing here is left to the system to look up or follow.
    private func pinnedExchange(_ request: IconFetchRequest, policy: HTTPRequestPolicy, confinement: String?) async -> IconFetchResult {
        var url = request.url
        var chain = [url]
        for hop in 0...Self.maxRedirects {
            guard let host = url.host else { return .failed(.refusedByPolicy) }
            let (kind, resolved) = await resolver(host)
            if !policy.allowsInternalHosts, kind.isInternal || resolved == nil { return .failed(hop == 0 ? .refusedByPolicy : .redirectRefused) }
            guard let address = Self.address(for: host, resolved: resolved) else { return .failed(.other) }
            var conditional: [String: String] = [:]
            if hop == 0 {
                if let etag = request.etag { conditional["If-None-Match"] = etag }
                if let modified = request.lastModified { conditional["If-Modified-Since"] = modified }
            }
            do {
                let reply = try await connector.get(url, address: address, maxBody: Self.maxBytes, conditional: conditional, refuseExpensive: false, refuseConstrained: false)
                let hints = Self.hints(etag: reply.headers["etag"], lastModified: reply.headers["last-modified"], cacheControl: reply.headers["cache-control"])
                switch reply.status {
                case 304:
                    return .notModified(hints)
                case 200:
                    let mime = reply.headers["content-type"]?.lowercased().split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) }
                    guard Self.isImageLike(mime) else { return .failed(.notImageType) }
                    guard reply.body.count <= Self.maxBytes else { return .failed(.tooLarge) }
                    return .fresh(.init(data: reply.body, hints: hints, mimeType: mime))
                case 301, 302, 303, 307, 308:
                    guard let location = reply.location, let next = URL(string: location, relativeTo: url)?.absoluteURL else { return .failed(.badStatus) }
                    if let confinement, HTTPRequestPolicy.origin(of: next) != confinement { return .failed(.redirectRefused) }
                    guard case .follow = await policy.decideRedirectResolving(from: url, to: next, chain: chain, resolve: resolver) else { return .failed(.redirectRefused) }
                    chain.append(next); url = next
                default:
                    return .failed(.badStatus)
                }
            } catch let failure as NWPinnedHTTP.Failure {
                switch failure { case .tooLarge: return .failed(.tooLarge); case .timedOut: return .failed(.timeout); default: return .failed(.other) }
            } catch is CancellationError {
                return .failed(.cancelled)
            } catch let error as NWError {
                if case .posix(let code) = error, [.ENETDOWN, .ENETUNREACH, .EHOSTUNREACH].contains(code) { return .failed(.offline) }
                return .failed(.other)
            } catch { return .failed(.other) }
        }
        return .failed(.redirectRefused)
    }

    /// The numeric address to connect to: the host itself when it is one, otherwise the first address it resolved to (IPv4 first).
    static func address(for host: String, resolved: [String]?) -> String? {
        if NWPinnedHTTP.isNumeric(host) { return host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) }
        guard let resolved, !resolved.isEmpty else { return nil }
        return resolved.first(where: { IPv4Address($0) != nil }) ?? resolved.first
    }

    static func mimeType(of response: HTTPURLResponse) -> String? {
        response.value(forHTTPHeaderField: "Content-Type")?.lowercased().split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// An image type, or a generic one a server uses for files (the bytes are checked anyway), or none given. Not HTML, JSON or text.
    static func isImageLike(_ mime: String?) -> Bool {
        guard let mime, !mime.isEmpty else { return true }
        if mime.hasPrefix("image/") { return true }
        return ["application/octet-stream", "binary/octet-stream", "application/x-icon", "application/ico", "text/xml", "application/xml"].contains(mime)
    }

    static func hints(from response: HTTPURLResponse) -> IconCacheHints {
        hints(etag: response.value(forHTTPHeaderField: "ETag"), lastModified: response.value(forHTTPHeaderField: "Last-Modified"), cacheControl: response.value(forHTTPHeaderField: "Cache-Control"))
    }

    static func hints(etag: String?, lastModified: String?, cacheControl: String?) -> IconCacheHints {
        var out = IconCacheHints(etag: etag, lastModified: lastModified)
        let control = (cacheControl ?? "").lowercased()
        for part in control.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if part == "no-store" || part == "no-cache" { out.noStore = true }
            if part.hasPrefix("max-age="), let seconds = TimeInterval(part.dropFirst("max-age=".count)) { out.maxAge = seconds }
        }
        return out
    }
}

/// Judges every redirect with the shared policy, refuses authentication, and notes the address the connection really used.
final class IconRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let policy: HTTPRequestPolicy
    private let resolver: @Sendable (String) async -> (kind: HostClass, resolved: [String]?)
    private let confinedTo: String?
    private let lock = NSLock()
    private var chain: [URL]
    private var _refused = false
    private var _remote: String?

    init(policy: HTTPRequestPolicy, start: URL, confinedTo: String? = nil, resolver: @escaping @Sendable (String) async -> (kind: HostClass, resolved: [String]?)) { self.policy = policy; self.confinedTo = confinedTo; self.resolver = resolver; chain = [start] }

    var refused: Bool { lock.withLock { _refused } }
    var remoteAddress: String? { lock.withLock { _remote } }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let from = response.url, let to = request.url else { lock.withLock { _refused = true }; task.cancel(); completionHandler(nil); return }
        let visited = lock.withLock { chain }
        // A local site's own icon may not send the request anywhere else, not even to another place on the local network.
        if let confinedTo, HTTPRequestPolicy.origin(of: to) != confinedTo {
            lock.withLock { _refused = true }; task.cancel(); completionHandler(nil); return
        }
        let policy = self.policy, resolver = self.resolver
        Task {
            let decision = await policy.decideRedirectResolving(from: from, to: to, chain: visited, resolve: resolver)
            switch decision {
            case .follow:
                self.lock.withLock { self.chain.append(to) }
                completionHandler(request)
            case .refuse:
                self.lock.withLock { self._refused = true }
                task.cancel()                       // nothing more is wanted from this request: no waiting for, or reading of, the redirect's body
                completionHandler(nil)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // The certificate check of an https connection arrives here too, and gets the system's own handling. Anything that asks for a login
        // (basic, digest, NTLM, a client certificate) is cancelled: an icon request never answers one.
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust { completionHandler(.performDefaultHandling, nil) }
        else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let address = metrics.transactionMetrics.last?.remoteAddress
        lock.withLock { _remote = address }
    }
}
