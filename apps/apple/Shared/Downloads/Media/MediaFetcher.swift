import Foundation

/// Fetches the pieces of a streaming download (the manifest and its segments) under exactly the rules every other download follows: the same address checks (also after a name is
/// looked up), the same redirect guard, the same proxy choice, the same answer rules. No cookies are sent or kept, and nothing about the pieces is written to a log.
final class MediaFetcher: @unchecked Sendable {
    let policy: HTTPRequestPolicy
    private let session: URLSession
    private let maxSegmentBytes: Int64
    /// For addresses that came from a web page rather than from the person: the local network is refused even though the request is the person's own act.
    private let refuseInternal: Bool

    /// Throws, changing nothing, when the network choice is unusable (a proxy that cannot be used is an error, never a quiet direct connection).
    init(policy: HTTPRequestPolicy, network: DownloadNetworkSetup, maxSegmentBytes: Int64 = 512 * 1024 * 1024, refuseInternal: Bool = false) throws {
        var policy = policy
        policy.requestTimeout = max(10, network.requestTimeout)          // this profile's timeout, carried with the setup
        self.policy = policy
        // The Debug-only fixture seam (always false in a release build) lets a page-origin stream reach the loopback fixture server, as it does for plain files.
        self.refuseInternal = refuseInternal && !HTTPRequestPolicy.debugFixtureAllowsLocalPageOrigin
        self.maxSegmentBytes = maxSegmentBytes
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = max(10, network.requestTimeout)
        config.timeoutIntervalForResource = 15 * 60
        config.httpMaximumConnectionsPerHost = 4
        config.waitsForConnectivity = false
        try DownloadProxy.apply(network.proxy, password: network.proxyPassword, origin: policy.origin, to: config)
        session = URLSession(configuration: config)
    }

    deinit { session.invalidateAndCancel() }
    func invalidate() { session.invalidateAndCancel() }

    /// Keeps the redirect chain of one request, refuses what the policy refuses, and notices a connection that went somewhere it should not have.
    private final class Guard: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
        let policy: HTTPRequestPolicy, host: String, startedPublic: Bool
        var maxBytes: Int64 = .max
        /// For a request whose caller reads a 401 itself (a WebDAV listing): an HTTP sign-in challenge is not answered (no credential is offered), so the server's own 401 comes back.
        var returnsChallenges = false
        private(set) var tooLarge = false
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            // Stops a body that never ends before it fills the disk.
            if totalBytesWritten > maxBytes || totalBytesExpectedToWrite > maxBytes { lock.lock(); tooLarge = true; lock.unlock(); downloadTask.cancel() }
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
        private let lock = NSLock()
        private var chain: [URL]
        private var refusedWith: HTTPRequestPolicy.Refusal?
        /// Asked about each redirect after the policy has agreed: false stops the redirect (and nothing of the new address is requested).
        var redirectAllowed: (@Sendable (URL) -> Bool)?
        private(set) var scopeRefused = false
        init(policy: HTTPRequestPolicy, url: URL, refuseInternal: Bool = false) { self.policy = policy; chain = [url]; host = url.host ?? ""; startedPublic = refuseInternal || !HTTPRequestPolicy.classify(host: url.host ?? "").isInternal }
        var exceededLimit: Bool { lock.lock(); defer { lock.unlock() }; return tooLarge }
        var refusal: HTTPRequestPolicy.Refusal? { lock.lock(); defer { lock.unlock() }; return refusedWith }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            lock.lock(); let seen = chain; lock.unlock()
            guard let from = seen.last, let to = request.url else { completionHandler(nil); return }
            let policy = self.policy
            Task { [self] in
                switch await policy.decideRedirectResolving(from: from, to: to, chain: seen) {
                case .refuse(let why): lock.lock(); refusedWith = why; lock.unlock(); completionHandler(nil)
                case .follow(let drop):
                    if let ok = redirectAllowed, !ok(to) { lock.lock(); scopeRefused = true; lock.unlock(); completionHandler(nil); return }
                    lock.lock(); chain.append(to); lock.unlock()
                    var next = request
                    next.httpShouldHandleCookies = false
                    if drop { next.setValue(nil, forHTTPHeaderField: "Authorization") }
                    completionHandler(next)
                }
            }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            guard startedPublic else { return }
            for t in metrics.transactionMetrics {
                if case .refuse(let why) = policy.verifyConnection(host: host, remote: t.remoteAddress, viaProxy: t.isProxyConnection, fromPublic: true) { lock.lock(); refusedWith = why; lock.unlock(); return }
            }
        }
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : (returnsChallenges ? .rejectProtectionSpace : .cancelAuthenticationChallenge), nil)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : (returnsChallenges ? .rejectProtectionSpace : .cancelAuthenticationChallenge), nil)
        }
    }

    /// What ties several requests to one version of a resource. Only a strong version tag or a modification date is used; a weak tag cannot guard byte positions.
    struct Validators: Equatable, Sendable, Codable {
        var etag: String?
        var lastModified: String?
        var isUsable: Bool { (etag.map { !$0.hasPrefix("W/") } ?? false) || lastModified != nil }
    }
    struct Changed: Error, Sendable {}

    private func request(_ url: URL, range: (offset: Int64, length: Int64)?, expect: Validators? = nil, headers: [String: String] = [:], method: String = "GET", body: Data? = nil) -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: policy.requestTimeout)
        r.httpMethod = method
        r.httpBody = body
        r.httpShouldHandleCookies = false
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        r.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let agent = policy.userAgent { r.setValue(agent, forHTTPHeaderField: "User-Agent") }
        if let range, range.offset >= 0, range.length > 0 {
            let (end, overflow) = range.offset.addingReportingOverflow(range.length - 1)
            r.setValue("bytes=\(range.offset)-\(overflow ? Int64.max : end)", forHTTPHeaderField: "Range")
            // If the resource is no longer the one seen first, a server that honours this sends the whole of the new one (a 200), which is refused above rather than used.
            if let etag = expect?.etag, !etag.hasPrefix("W/") { r.setValue(etag, forHTTPHeaderField: "If-Range") } else if let date = expect?.lastModified { r.setValue(date, forHTTPHeaderField: "If-Range") }
        }
        return r
    }

    private func failure(_ error: Error, guard g: Guard, url: URL) -> HTTPDownloadError {
        if let why = g.refusal { return HTTPResponseRules.failure(for: why) }
        if g.exceededLimit { return HTTPDownloadError(info: DownloadFailureInfo(code: "media:size", reason: "A piece of the stream was larger than allowed.", retryable: false)) }
        return HTTPResponseRules.failure(for: error)
    }

    private func check(_ response: URLResponse, range: (offset: Int64, length: Int64)?, url: URL, guard g: Guard) throws {
        let ranged = range != nil
        if let why = g.refusal { throw HTTPResponseRules.failure(for: why) }
        guard let http = response as? HTTPURLResponse else { throw HTTPDownloadError(info: DownloadFailureInfo(code: "media:response", reason: "The website gave an answer that is not HTTP.", retryable: false)) }
        switch http.statusCode {
        case 200 where !ranged: return
        case 206 where ranged:
            // RFC 9110 15.3.7: a 206 says which bytes it holds. Only the bytes that were asked for are accepted; a different or unstated range could be another part of the file.
            guard let range, Self.contentRange(http.value(forHTTPHeaderField: "Content-Range"), matches: range) else {
                throw HTTPDownloadError(info: DownloadFailureInfo(code: "media:content-range", reason: "The website sent a different part of the file than the one asked for.", retryable: false))
            }
            return
        case 200:
            // Asked for a part and given the whole thing: a segment that is a part of a file must not be replaced by the file.
            throw HTTPDownloadError(info: DownloadFailureInfo(code: "media:range-ignored", reason: "The website ignored the request for part of a file.", retryable: false))
        default:
            if let error = HTTPResponseRules.validate(status: http.statusCode, headers: { http.value(forHTTPHeaderField: $0) }, rangeStart: 0, signed: DownloadURLRedactor.looksSigned(url)) { throw error }
            throw HTTPDownloadError(info: DownloadFailureInfo(code: "media:status:\(http.statusCode)", reason: "The website answered with an unexpected status (\(http.statusCode)).", retryable: http.statusCode >= 500))
        }
    }

    /// Exactly the bytes asked for, in memory (for the small parts of a file: its end, a table, a header). Returns what the server said about the whole: its size and its version.
    /// With `expect`, the answer must carry the same version tag or date, or the resource is taken to have changed.
    func rangeData(_ url: URL, offset: Int64, length: Int64, expect: Validators? = nil) async throws -> (data: Data, total: Int64?, validators: Validators) {
        guard length > 0, length <= 64 * 1024 * 1024 else { throw MediaError.tooLarge }
        try policy.requireAllowedOrigin()
        try await policy.checkResolving(url)
        if refuseInternal, HTTPRequestPolicy.classify(host: url.host ?? "").isInternal { throw HTTPRequestPolicy.Refusal.internalAddress(url.host ?? "") }
        let g = Guard(policy: policy, url: url, refuseInternal: refuseInternal)
        do {
            let (bytes, response) = try await session.bytes(for: request(url, range: (offset, length), expect: expect), delegate: g)
            try check(response, range: (offset, length), url: url, guard: g)
            let http = response as? HTTPURLResponse
            let seen = Validators(etag: http?.value(forHTTPHeaderField: "ETag"), lastModified: http?.value(forHTTPHeaderField: "Last-Modified"))
            if let expect { try Self.requireSame(expect, seen) }
            var data = Data()
            for try await byte in bytes { data.append(byte); if data.count > Int(length) { throw HTTPDownloadError(info: DownloadFailureInfo(code: "media:long", reason: "The website sent more than was asked for.", retryable: false)) } }
            guard data.count == Int(length) else { throw HTTPDownloadError(info: DownloadFailureInfo(code: "media:short", reason: "The website stopped sending before the whole part arrived.", retryable: true)) }
            if let why = g.refusal { throw HTTPResponseRules.failure(for: why) }
            return (data, HTTPResponseRules.parseContentRange(http?.value(forHTTPHeaderField: "Content-Range"))?.total, seen)
        } catch let e as MediaError { throw e } catch let e as HTTPDownloadError { throw e } catch let e as Changed { throw e } catch { throw failure(error, guard: g, url: url) }
    }

    /// The version seen now must be the version seen first.
    static func requireSame(_ expect: Validators, _ seen: Validators) throws {
        if let tag = expect.etag, !tag.hasPrefix("W/") { guard seen.etag == tag else { throw Changed() } }
        else if let date = expect.lastModified { guard seen.lastModified == date else { throw Changed() } }
    }

    /// `bytes first-last/total` (total may be `*`) names exactly the requested bytes, and is not contradicted by the total.
    static func contentRange(_ header: String?, matches range: (offset: Int64, length: Int64)) -> Bool {
        guard let header, header.count < 100 else { return false }
        let t = header.trimmingCharacters(in: .whitespaces)
        guard t.lowercased().hasPrefix("bytes ") else { return false }
        let rest = t.dropFirst(6).trimmingCharacters(in: .whitespaces)
        let halves = rest.split(separator: "/", omittingEmptySubsequences: false)
        guard halves.count == 2 else { return false }
        let span = halves[0].split(separator: "-", omittingEmptySubsequences: false)
        guard span.count == 2, let first = Int64(span[0]), let last = Int64(span[1]) else { return false }
        let (end, overflow) = range.offset.addingReportingOverflow(range.length - 1)
        guard !overflow, first == range.offset, last == end else { return false }
        if halves[1] != "*" { guard let total = Int64(halves[1]), total > last else { return false } }
        return true
    }

    struct Document: Sendable { var data: Data; var finalURL: URL; var contentType: String; var status: Int }
    struct WrongType: Error, Sendable { var contentType: String; var finalURL: URL }
    struct OutOfScope: Error, Sendable {}

    /// A small document in memory, never more than `limit` bytes. When `only` is given and the answer is of another type, nothing of the body is read and `WrongType` says what it was.
    /// `headers`, `method` and `body` are for a provider's own API (DX-09): the caller decides who may be sent a credential, and passes `redirectOK` to keep it from following one anywhere else.
    func document(_ url: URL, limit: Int, only types: [String]? = nil, redirectOK: (@Sendable (URL) -> Bool)? = nil, truncate: Bool = false, headers: [String: String] = [:], method: String = "GET", body: Data? = nil) async throws -> Document {
        try policy.requireAllowedOrigin()
        try await policy.checkResolving(url)
        if refuseInternal, HTTPRequestPolicy.classify(host: url.host ?? "").isInternal { throw HTTPRequestPolicy.Refusal.internalAddress(url.host ?? "") }
        let g = Guard(policy: policy, url: url, refuseInternal: refuseInternal)
        g.redirectAllowed = redirectOK
        do {
            let (bytes, response) = try await session.bytes(for: request(url, range: nil, headers: headers, method: method, body: body), delegate: g)
            if g.scopeRefused { throw OutOfScope() }
            try check(response, range: nil, url: url, guard: g)
            let type = ((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            if let types, !types.contains(type) { throw WrongType(contentType: type, finalURL: response.url ?? url) }
            if !truncate, response.expectedContentLength > Int64(limit) { throw MediaError.tooLarge }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count >= limit { if truncate { break }; if data.count > limit { throw MediaError.tooLarge } }
            }
            if let why = g.refusal { throw HTTPResponseRules.failure(for: why) }
            return Document(data: data, finalURL: response.url ?? url, contentType: type, status: (response as? HTTPURLResponse)?.statusCode ?? 200)
        } catch let e as MediaError { throw e } catch let e as HTTPDownloadError { throw e } catch let e as WrongType { throw e } catch let e as OutOfScope { throw e } catch { throw failure(error, guard: g, url: url) }
    }

    /// A POST whose answer is a file, streamed to `file` (a provider's authorized export; the answer is never held in memory). Redirects are not followed: the credentials in `headers` go to `url` and nowhere
    /// else. The answer must be a 200 and no larger than `maxBytes`. Written whole or not at all.
    func postDownload(_ url: URL, headers: [String: String], body: Data, to file: URL, maxBytes: Int64) async throws -> (size: Int64, contentType: String) {
        try policy.requireAllowedOrigin()
        try await policy.checkResolving(url)
        let g = Guard(policy: policy, url: url)
        g.maxBytes = maxBytes
        g.redirectAllowed = { _ in false }
        do {
            let (temp, response) = try await session.download(for: request(url, range: nil, headers: headers, method: "POST", body: body), delegate: g)
            defer { try? FileManager.default.removeItem(at: temp) }
            if g.scopeRefused { throw OutOfScope() }
            try check(response, range: nil, url: url, guard: g)
            let size = (try? temp.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
            guard size > 0, size <= maxBytes else { throw HTTPDownloadError(info: DownloadFailureInfo(code: "media:size", reason: size == 0 ? "The answer was empty." : "The answer was larger than allowed.", retryable: false)) }
            let type = ((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            let partial = file.appendingPathExtension("part")
            try? FileManager.default.removeItem(at: partial)
            try FileManager.default.moveItem(at: temp, to: partial)
            try? FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: partial, to: file)
            return (size, type)
        } catch let e as HTTPDownloadError { throw e } catch let e as OutOfScope { throw e } catch { throw failure(error, guard: g, url: url) }
    }

    /// A small document (a playlist or manifest) in memory, never more than `limit` bytes. Returns what was fetched and the address it finally came from.
    func text(_ url: URL, limit: Int = MediaLimits.maxManifestBytes) async throws -> (data: Data, finalURL: URL) {
        guard case .fresh(let data, let final, _) = try await document(url, limit: limit, ifChanged: nil) else { throw MediaError.unsupported("The website answered “not modified” to a request that was not conditional.") }
        return (data, final)
    }

    /// The validators a server gave for a document, sent back next time so it can answer "not modified" instead of the whole document (RFC 9110 13.1).
    struct DocumentValidators: Sendable, Equatable { var etag: String?; var lastModified: String?; var isEmpty: Bool { etag == nil && lastModified == nil } }
    enum DocumentResult: Sendable { case fresh(Data, URL, DocumentValidators), notModified }

    /// Like `text`, but a conditional request when `ifChanged` is given: a 304 answer is `.notModified` (nothing is downloaded). All the other rules (redirect guard, address checks, size limit) are the same.
    func document(_ url: URL, limit: Int = MediaLimits.maxManifestBytes, ifChanged: DocumentValidators?) async throws -> DocumentResult {
        try await policy.requireAllowedOrigin()
        try await policy.checkResolving(url)
        if refuseInternal, HTTPRequestPolicy.classify(host: url.host ?? "").isInternal { throw HTTPRequestPolicy.Refusal.internalAddress(url.host ?? "") }
        let g = Guard(policy: policy, url: url, refuseInternal: refuseInternal)
        var headers: [String: String] = [:]
        if let v = ifChanged {
            // A weak validator is fine for If-None-Match (weak comparison); Last-Modified is the fallback.
            if let e = v.etag, e.count <= 200 { headers["If-None-Match"] = e } else if let d = v.lastModified, d.count <= 100 { headers["If-Modified-Since"] = d }
        }
        do {
            let (bytes, response) = try await session.bytes(for: request(url, range: nil, headers: headers), delegate: g)
            // (Only an answer from the address that was asked: a redirect to another host never counts as "not modified".)
            if !headers.isEmpty, (response as? HTTPURLResponse)?.statusCode == 304, g.refusal == nil, response.url?.host?.lowercased() == url.host?.lowercased() { return .notModified }
            try check(response, range: nil, url: url, guard: g)
            if response.expectedContentLength > Int64(limit) { throw MediaError.tooLarge }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit { throw MediaError.tooLarge }
            }
            if let why = g.refusal { throw HTTPResponseRules.failure(for: why) }
            let http = response as? HTTPURLResponse
            return .fresh(data, response.url ?? url, DocumentValidators(etag: http?.value(forHTTPHeaderField: "ETag"), lastModified: http?.value(forHTTPHeaderField: "Last-Modified")))
        } catch let e as MediaError { throw e } catch let e as HTTPDownloadError { throw e } catch { throw failure(error, guard: g, url: url) }
    }

    /// A WebDAV-style request (PROPFIND, OPTIONS…): any method, a small XML body, an answer read into memory up to `limit`. The status is returned as it is, for the caller to read; only the things
    /// every request is held to (address checks, the redirect guard, the size limit) are enforced here. Credentials in `headers` are dropped by the guard if a redirect leaves the host.
    struct ExchangeResponse: Sendable { var status: Int; var headers: [String: String]; var data: Data; var finalURL: URL }

    func exchange(_ url: URL, method: String, headers: [String: String] = [:], body: Data? = nil, limit: Int) async throws -> ExchangeResponse {
        try await policy.requireAllowedOrigin()
        try await policy.checkResolving(url)
        if refuseInternal, HTTPRequestPolicy.classify(host: url.host ?? "").isInternal { throw HTTPRequestPolicy.Refusal.internalAddress(url.host ?? "") }
        let g = Guard(policy: policy, url: url, refuseInternal: refuseInternal)
        g.returnsChallenges = true
        do {
            let (bytes, response) = try await session.bytes(for: request(url, range: nil, headers: headers, method: method, body: body), delegate: g)
            if let why = g.refusal { throw HTTPResponseRules.failure(for: why) }
            guard let http = response as? HTTPURLResponse else { throw MediaError.unsupported("The server's answer is not HTTP.") }
            if response.expectedContentLength > Int64(limit) { throw MediaError.tooLarge }
            var data = Data()
            for try await byte in bytes { data.append(byte); if data.count > limit { throw MediaError.tooLarge } }
            if let why = g.refusal { throw HTTPResponseRules.failure(for: why) }
            var out: [String: String] = [:]
            for (k, v) in http.allHeaderFields { if let k = k as? String, let v = v as? String { out[k.lowercased()] = v } }
            return ExchangeResponse(status: http.statusCode, headers: out, data: data, finalURL: response.url ?? url)
        } catch let e as MediaError { throw e } catch let e as HTTPDownloadError { throw e } catch { throw failure(error, guard: g, url: url) }
    }

    /// Sends a file with PUT (streamed from disk, never held in memory), under the same address checks and redirect guard as every request. The answer's status is returned for the caller to read.
    func upload(_ url: URL, file: URL, headers: [String: String]) async throws -> ExchangeResponse {
        try await policy.requireAllowedOrigin()
        try await policy.checkResolving(url)
        if refuseInternal, HTTPRequestPolicy.classify(host: url.host ?? "").isInternal { throw HTTPRequestPolicy.Refusal.internalAddress(url.host ?? "") }
        let g = Guard(policy: policy, url: url, refuseInternal: refuseInternal)
        g.returnsChallenges = true
        do {
            let (data, response) = try await session.upload(for: request(url, range: nil, headers: headers, method: "PUT"), fromFile: file, delegate: g)
            if let why = g.refusal { throw HTTPResponseRules.failure(for: why) }
            guard let http = response as? HTTPURLResponse else { throw MediaError.unsupported("The server's answer is not HTTP.") }
            var out: [String: String] = [:]
            for (k, v) in http.allHeaderFields { if let k = k as? String, let v = v as? String { out[k.lowercased()] = v } }
            return ExchangeResponse(status: http.statusCode, headers: out, data: data.prefix(1 << 16), finalURL: response.url ?? url)
        } catch let e as MediaError { throw e } catch let e as HTTPDownloadError { throw e } catch { throw failure(error, guard: g, url: url) }
    }

    /// What a piece that was fetched and kept looks like: how big, and its SHA-256 (kept in the task's journal so a restart can tell a good file from one that only has the right size).
    struct Receipt: Sendable, Equatable { var size: Int64; var sha256: String }

    /// One segment into `file` (written whole or not at all). Returns the bytes written.
    func segment(_ segment: MediaSegment, to file: URL, expect: Validators? = nil) async throws -> Int64 {
        try await receipt(segment, to: file, expect: expect, container: nil, isInit: false).size
    }

    /// One segment into `file`, checked: the answer must be the right kind of answer (status, range, size), and the bytes must look like the kind of piece it is (`container`), not an error
    /// page that happened to be served with a good status.
    func receipt(_ segment: MediaSegment, to file: URL, expect: Validators? = nil, container: MediaContainer?, isInit: Bool) async throws -> Receipt {
        guard let url = URL(string: segment.url) else { throw MediaError.unsafeURL("a segment address") }
        try policy.requireAllowedOrigin()
        try await policy.checkResolving(url)
        let range: (offset: Int64, length: Int64)? = segment.offset.flatMap { o in segment.length.map { (offset: o, length: $0) } }
        let g = Guard(policy: policy, url: url)
        g.maxBytes = maxSegmentBytes
        do {
            let (temp, response) = try await session.download(for: request(url, range: range, expect: expect), delegate: g)
            defer { try? FileManager.default.removeItem(at: temp) }
            try check(response, range: range, url: url, guard: g)
            if let expect, let http = response as? HTTPURLResponse { try Self.requireSame(expect, Validators(etag: http.value(forHTTPHeaderField: "ETag"), lastModified: http.value(forHTTPHeaderField: "Last-Modified"))) }
            let size = (try? temp.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
            guard size > 0, size <= maxSegmentBytes else { throw HTTPDownloadError(info: DownloadFailureInfo(code: "media:size", reason: size == 0 ? "A piece of the stream was empty." : "A piece of the stream was larger than allowed.", retryable: size == 0)) }
            if let length = range?.length, size != length { throw HTTPDownloadError(info: DownloadFailureInfo(code: "media:short", reason: "A piece of the stream came back the wrong size.", retryable: true)) }
            // The size is not enough: a server can answer 200 with a page that explains an error. The first bytes must be those of the kind of piece this is.
            if let container, let why = MediaSegmentCheck.problem(head: MediaSegmentCheck.head(of: temp), container: container, isInit: isInit) {
                throw HTTPDownloadError(info: DownloadFailureInfo(code: "media:invalid", reason: "A piece of the stream is not what it should be: \(why).", retryable: true))
            }
            let digest = try MediaSegmentCheck.digest(of: temp)
            // Into the task's own folder under a temporary name first, then renamed: a crash part-way (a copy across volumes is not atomic) never leaves a short file that looks finished.
            let partial = file.appendingPathExtension("part")
            try? FileManager.default.removeItem(at: partial)
            try FileManager.default.moveItem(at: temp, to: partial)
            try? FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: partial, to: file)
            return Receipt(size: size, sha256: digest)
        } catch let e as HTTPDownloadError { throw e } catch let e as Changed { throw e } catch { throw failure(error, guard: g, url: url) }
    }
}

// MARK: - The plan kept on disk

/// What was chosen, saved beside the downloaded segments so a paused or interrupted download goes on from what is there. It holds addresses (as they are in the manifest, which may be
/// signed), so it lives only in the task's private folder and is deleted with it; the ledger and the logs never see it.
struct MediaPlan: Codable, Equatable, Sendable {
    /// 1: Phase 17. 2: DX-08 (adds the fields below; every one is optional, so version 1 plans still read).
    var version = 2
    var format: MediaFormat
    var fingerprint: String
    var title: String
    var streams: [MediaStream]            // chosen, with their segments (a track cut at a discontinuity is several streams that share a `trackKey`)
    var outputExtension: String
    var outputNote: String?
    /// The manifest this was made from, to read it again when the links in it stop working.
    var sourceURL: String?
    var selection: MediaSelectionRecord?
    /// A signature of what the plan describes; a re-read manifest must give the same one before its addresses are used.
    var structure: String?
    var refreshes: Int?
    var allowFallback: Bool?
    var warnings: [String]?
    var totalSegments: Int { streams.reduce(0) { $0 + $1.segments.count + ($1.initSegment == nil ? 0 : 1) } }
}

/// What the person chose, kept with the plan.
struct MediaSelectionRecord: Codable, Equatable, Sendable {
    var video: String?
    var audio: String?
    var extraAudios: [String] = []
    var subtitles: [String] = []
}

@MainActor
enum MediaStore {
    static let folderName = ".Browser Setu Media"
    static var root: URL { DownloadCoordinator.directory.appendingPathComponent(folderName, isDirectory: true) }
    static func profileTag(_ profile: String) -> String { String(Data(profile.utf8).sha256Hex.prefix(8)) }
    static func folder(profile: String, task: UUID) -> URL { root.appendingPathComponent(profileTag(profile), isDirectory: true).appendingPathComponent(task.uuidString, isDirectory: true) }
    /// A folder this module made: <downloads>/.Browser Setu Media/<tag>/<task>. Anything else is never deleted.
    static func isTaskFolder(_ url: URL) -> Bool {
        // Compared as resolved paths: a folder listed from disk can name the same place through /private/var or a symlinked Downloads folder, and an exact URL match would then refuse to clean it up.
        func resolved(_ u: URL) -> String { u.standardizedFileURL.resolvingSymlinksInPath().path }
        // The profile folder in the middle must itself be a real folder inside the root (not a link to somewhere else), or the task folder under it would be elsewhere.
        let tag = url.deletingLastPathComponent()
        return resolved(tag.deletingLastPathComponent()) == resolved(root) && resolved(tag) == resolved(root) + "/" + tag.lastPathComponent && UUID(uuidString: url.lastPathComponent) != nil
    }

    nonisolated static func segmentFile(in dir: URL, stream: Int, index: Int) -> URL { dir.appendingPathComponent("s\(stream)-\(index == -1 ? "init" : String(index)).seg") }
    /// The record of what was fetched and checked: one line per kept piece, appended as each arrives.
    nonisolated static func journalFile(in dir: URL) -> URL { dir.appendingPathComponent("journal.jsonl") }

    nonisolated static func save(_ plan: MediaPlan, in dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(plan)
        try data.write(to: dir.appendingPathComponent("plan.json"), options: .atomic)
    }
    nonisolated static func load(from dir: URL) -> MediaPlan? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("plan.json")), data.count < 64_000_000, let plan = try? JSONDecoder().decode(MediaPlan.self, from: data), (1...2).contains(plan.version) else { return nil }
        return plan
    }
    static func remove(_ dir: URL) { if isTaskFolder(dir) { try? FileManager.default.removeItem(at: dir) } }

    /// Folders of tasks this profile no longer has: left behind by a crash, or by a task that was removed. Only this profile's own folder is looked at.
    static func sweep(profile: String, keep: Set<UUID>) {
        let mine = root.appendingPathComponent(profileTag(profile), isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(at: mine, includingPropertiesForKeys: nil) else { return }
        for item in items { if let id = UUID(uuidString: item.lastPathComponent), !keep.contains(id) { remove(item) } }
    }
}
