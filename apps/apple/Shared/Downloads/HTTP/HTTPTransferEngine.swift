import CryptoKit
import Foundation

extension DownloadProtocolID {
    /// A download the app fetches itself over HTTP or HTTPS, as one transfer (as opposed to a WebKit download, which uses the page's own session).
    static let http: Self = "http"
}

/// What the engine needs to run one task and that must not be saved: custom headers (an Authorization among them), where to put the file, a checksum from a trusted source.
struct HTTPTransferRequest: Sendable {
    var url: URL
    var policy: HTTPRequestPolicy
    /// Already passed through `HTTPRequestPolicy.sanitize`.
    var headers: [String: String]
    /// The final location of the file (inside an authorised folder).
    var destination: URL
    /// A SHA-256 (hex) from a source the person trusts, checked against the finished file.
    var expectedSHA256: String?
}

/// Single-transfer HTTP and HTTPS downloads over `URLSession`, written to disk by the system and finalised here.
///
/// Why this shape (Phase 2 decision): a `URLSessionDownloadTask` streams to a file (no download is ever held in memory), carries resume data and validates the resource with its own
/// strong validator on resume, and is what `PieceDownloader` already uses. The session is ephemeral and has no cookie store, no credential store and no cache, so a standalone transfer
/// shares nothing with the browser's logins. Response status is checked here, because a download task saves a 404 page as happily as a file.
///
/// Every report carries the attempt it belongs to, and a callback for anything but the task's current attempt is dropped.
final class HTTPTransferEngine: NSObject, DownloadTransferEngine, URLSessionDownloadDelegate, @unchecked Sendable {
    let protocolID: DownloadProtocolID = .http
    let capabilities: DownloadEngineCapabilities = [.pause, .resume, .resolveMetadata, .verify, .reportsTotalBytes, .pieces]

    /// How often progress is reported for one task.
    static let progressInterval: TimeInterval = 0.25

    private final class Context {
        let taskID: DownloadTaskID
        let attempt: Int
        let request: HTTPTransferRequest
        weak var sink: DownloadReportSink?
        var chain: [URL]
        var urlTask: URLSessionDownloadTask?
        var checkedResponse = false
        var resumable: Bool?
        var rangeStart: Int64?
        var refusal: HTTPRequestPolicy.Refusal?
        var failure: HTTPDownloadError?
        var pausing = false
        var cancelled = false
        /// An account's credential (or any Authorization) is in this transfer's request. The system's resume data would carry it, so none is ever kept for such a transfer.
        var usedCredential = false
        /// Cancel against putting the file in place: whichever comes first wins, atomically.
        let gate = FinalizationGate()
        var finished = false
        var lastProgress: TimeInterval = 0
        var totalForVerification: Int64?
        /// A finished download waiting for the connection's real address to be checked (requests that are not the person's own).
        var staged: (file: URL, size: Int64)?
        var connectionRefusal: HTTPRequestPolicy.Refusal?
        var startedAtPublic = true
        init(taskID: DownloadTaskID, attempt: Int, request: HTTPTransferRequest, sink: DownloadReportSink) {
            self.taskID = taskID; self.attempt = attempt; self.request = request; self.sink = sink; chain = [request.url]
        }
    }

    private let lock = NSLock()
    private var contexts: [ObjectIdentifier: Context] = [:]       // by the URLSession task itself (a task identifier is only unique within one session, and there is more than one)
    private var current: [DownloadTaskID: Context] = [:]
    private var requests: [DownloadTaskID: HTTPTransferRequest] = [:]
    /// Tasks whose file is being (or has just been) put in place, until the runner has dealt with the result: a cancel in this window is too late.
    private var finalising = Set<DownloadTaskID>()
    /// The session for the person's own requests, made again (lazily) when the network setup changes; the one for any other origin never uses a proxy.
    private var userSession: URLSession?
    private var untrustedSession: URLSession!
    private var builtGeneration = -1
    private var generation = 0
    private var network = DownloadNetworkSetup()
    private let queue: OperationQueue

    override init() {
        queue = OperationQueue()
        queue.name = "browsersetu.downloads.http"
        queue.maxConcurrentOperationCount = 1          // callbacks arrive one at a time, in order
        super.init()
        untrustedSession = URLSession(configuration: Self.baseConfiguration(DownloadNetworkSetup(), connections: 4), delegate: self, delegateQueue: queue)
    }

    /// A configuration with nothing shared with the browser: no cookies, credentials or cache.
    static func baseConfiguration(_ setup: DownloadNetworkSetup, connections: Int) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = setup.requestTimeout
        config.timeoutIntervalForResource = HTTPRequestPolicy.defaultResourceTimeout
        config.httpMaximumConnectionsPerHost = connections
        // The person's choices about metered links and Low Data Mode also hold at the system level, in case the app's own hold has not caught up yet.
        config.allowsExpensiveNetworkAccess = !setup.refuseExpensive
        config.allowsConstrainedNetworkAccess = !setup.refuseConstrained
        return config
    }

    /// Uses these network settings for every transfer started from now on (one already running keeps the connection it has).
    func applyNetwork(_ setup: DownloadNetworkSetup) {
        lock.lock(); defer { lock.unlock() }
        guard setup != network else { return }          // nothing changed: keep the connections already open
        network = setup; generation += 1
    }

    var currentNetwork: DownloadNetworkSetup { lock.lock(); defer { lock.unlock() }; return network }

    /// The session a transfer of this origin runs on. Throws (with a reason the person can read) when the proxy choice cannot be used.
    func session(for origin: DownloadRequestOrigin) throws -> URLSession {
        guard origin == .user else {
            // Where a connection really goes cannot be seen through a proxy, so a request that is not the person's own is refused outright rather than sent around one.
            lock.lock(); let mode = network.proxy.mode; lock.unlock()
            if [.http, .https, .socks5].contains(mode) { throw DownloadNetworkSetup.failure(for: DownloadProxy.Problem.notForUntrustedRequests) }
            return untrustedSession
        }
        lock.lock(); defer { lock.unlock() }
        if let userSession, builtGeneration == generation { return userSession }
        let config = Self.baseConfiguration(network, connections: min(4, max(1, network.perHostConnections)))
        do { try DownloadProxy.apply(network.proxy, password: network.proxyPassword, origin: origin, to: config) }
        catch { throw DownloadNetworkSetup.failure(for: error) }
        userSession?.finishTasksAndInvalidate()          // transfers already on it carry on and finish there
        userSession = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        builtGeneration = generation
        return userSession!
    }

    deinit { userSession?.invalidateAndCancel(); untrustedSession.invalidateAndCancel() }

    // MARK: Requests held in memory

    /// What this task needs that is not saved. After a relaunch this is empty, and a task carries on with defaults (no custom headers, so a link that needed a login asks again).
    func prepare(_ request: HTTPTransferRequest, for task: DownloadTaskID) {
        lock.lock(); requests[task] = request; lock.unlock()
    }

    func forget(task: DownloadTaskID) {
        lock.lock(); requests[task] = nil; finalising.remove(task); lock.unlock()
    }

    func request(for task: DownloadTaskID) -> HTTPTransferRequest? { lock.lock(); defer { lock.unlock() }; return requests[task] }

    // MARK: DownloadTransferEngine

    func start(_ task: DownloadTaskRecord, attempt: Int, resumeData: Data?, sink: DownloadReportSink) async throws {
        guard let prepared = request(for: task.id) ?? defaultRequest(for: task) else { throw DownloadEngineError.unsupported("this task has no address") }
        try await prepared.policy.checkResolving(prepared.url)
        // Anything still running for this task belongs to an earlier attempt: it is stopped, and whatever it reports afterwards finds no context.
        abandonCurrent(for: task.id)
        let context = Context(taskID: task.id, attempt: attempt, request: prepared, sink: sink)
        context.startedAtPublic = !HTTPRequestPolicy.classify(host: prepared.url.host ?? "").isInternal
        var urlRequest = URLRequest(url: prepared.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: prepared.policy.requestTimeout)
        urlRequest.httpMethod = "GET"
        urlRequest.httpShouldHandleCookies = false
        urlRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")          // exact bytes: a compressed body has no usable length or byte positions
        if let agent = prepared.policy.userAgent { urlRequest.setValue(agent, forHTTPHeaderField: "User-Agent") }
        for (name, value) in prepared.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        let callerSetAuthorization = prepared.headers.keys.contains(where: { $0.lowercased() == "authorization" })
        let accountAuth = callerSetAuthorization ? [:] : accountHeaders(for: prepared.url, origin: prepared.policy.origin)
        for (name, value) in accountAuth { urlRequest.setValue(value, forHTTPHeaderField: name) }
        context.usedCredential = callerSetAuthorization || !accountAuth.isEmpty
        // Resume data embeds the request it came from, headers included. For a transfer that carries a credential it is never used (a fresh request is made, under today's rules), and none is kept.
        let resumeData: Data? = context.usedCredential ? nil : resumeData
        let urlTask: URLSessionDownloadTask
        let session = try session(for: prepared.policy.origin)
        if let resumeData, !resumeData.isEmpty { urlTask = session.downloadTask(withResumeData: resumeData); context.rangeStart = max(1, task.transfer.completedBytes) }
        else { urlTask = session.downloadTask(with: urlRequest) }
        context.urlTask = urlTask
        lock.lock(); contexts[Self.key(urlTask)] = context; current[task.id] = context; lock.unlock()
        urlTask.resume()
        sink.report(.running, task: task.id, attempt: attempt)
    }

    private func defaultRequest(for task: DownloadTaskRecord) -> HTTPTransferRequest? {
        guard let url = task.source.asURL, let path = task.file.destinationPath else { return nil }
        // Who asked is saved with the task (it is not a secret). A task with no record of it is treated as the least trusted kind, never the most.
        let origin = DownloadRequestOrigin(rawValue: task.engineMetadata["origin"] ?? "") ?? .automation
        return HTTPTransferRequest(url: url, policy: HTTPRequestPolicy(origin: origin), headers: task.engineMetadata["accept"].map { ["Accept": $0] } ?? [:], destination: URL(fileURLWithPath: path), expectedSHA256: task.engineMetadata["sha256"])
    }

    func pause(task: DownloadTaskID, attempt: Int) async throws {
        guard let context = currentContext(task, attempt: attempt) else { throw DownloadEngineError.unsupported("this download is not running") }
        guard context.gate.allowsPause else { throw DownloadEngineError.unsupported("this download is finishing") }          // it completes, and that answers the pause
        guard context.resumable != false else { throw DownloadEngineError.unsupported("this website does not allow a download to be continued later") }
        context.pausing = true
        context.urlTask?.cancel(byProducingResumeData: { [weak self] data in
            guard let self, let context = self.currentContext(task, attempt: attempt) else { return }
            context.finished = true
            self.remove(context)
            context.sink?.report(.paused(resumeData: context.usedCredential ? nil : data), task: task, attempt: attempt)
        })
    }

    func cancel(task: DownloadTaskID, attempt: Int) async { _ = cancelIfPossible(task: task, attempt: attempt) }

    /// Cancels the task's transfer unless its file is already being put in place. True when it is cancelled (or there was nothing to cancel); false when it is too late and the
    /// download will complete: the caller must then not describe it as cancelled, and must not delete the file.
    @discardableResult
    func cancelIfPossible(task: DownloadTaskID, attempt: Int = -1) -> Bool {
        lock.lock(); let context = current[task]; let late = finalising.contains(task); lock.unlock()
        if late { return false }
        guard let context, context.attempt == attempt || attempt < 0 else { return true }
        guard context.gate.cancel() else { return false }
        context.cancelled = true
        if let staged = context.staged { try? FileManager.default.removeItem(at: staged.file); context.staged = nil }
        context.urlTask?.cancel()
        remove(context)
        forget(task: task)
        return true
    }

    /// Whether the task's file is being (or has just been) put in place.
    func isFinalising(task: DownloadTaskID) -> Bool { lock.lock(); defer { lock.unlock() }; return finalising.contains(task) }

    /// Whether a pause would keep the download's place: false once the server has shown it cannot continue one; nil until it has answered.
    func isResumable(task: DownloadTaskID) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        return current[task]?.resumable
    }

    func canRecover(_ task: DownloadTaskRecord, hasResumeData: Bool) -> Bool { hasResumeData }

    func verify(_ task: DownloadTaskRecord) async throws -> DownloadIntegrity {
        guard let path = task.file.destinationPath else { return .unknown }
        let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value
        if let expected = request(for: task.id)?.expectedSHA256?.lowercased() {
            guard let digest = Self.sha256(ofFileAt: URL(fileURLWithPath: path)) else { return .mismatch }
            return digest == expected ? .verified : .mismatch
        }
        if let total = task.transfer.totalBytes, total > 0, let size { return size == total ? .verified : .mismatch }
        return .unknown
    }

    /// Streams the file through SHA-256 a megabyte at a time.
    static func sha256(ofFileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1_048_576), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Resolving what a link is

    /// Asks the server about the file before any bytes are fetched. HEAD first; a server that refuses HEAD (405, 501, or any error status) or says nothing useful is asked with a
    /// GET for the first byte only, which also reveals whether ranges work. Never assumes HEAD works because GET does.
    /// The website accounts of the profile this engine belongs to. Consulted for each request the engine makes itself; nil when there are none.
    private let accountLock = NSLock()
    private var accountRouter: AccountRouter?
    var accounts: AccountRouter? {
        get { accountLock.lock(); defer { accountLock.unlock() }; return accountRouter }
        set { accountLock.lock(); accountRouter = newValue; accountLock.unlock() }
    }
    /// The Authorization header an account allows for this address and kind of request, if any (never for a request that is not the person's own, never over plain http).
    func accountHeaders(for url: URL, origin: DownloadRequestOrigin, isPrivate: Bool = false) -> [String: String] {
        if case .use(_, let header)? = accounts?.decide(url, origin: origin, isPrivate: isPrivate) { return ["Authorization": header] }
        return [:]
    }

    func resolve(_ request: DownloadSourceRequest) async throws -> DownloadResolvedSource {
        let policy = HTTPRequestPolicy(origin: request.origin)
        try await policy.checkResolving(request.url)
        let head = try? await probe(request.url, method: "HEAD", range: nil, policy: policy, isPrivate: request.isPrivate)
        if let head, (200..<300).contains(head.status), head.contentLength != nil || head.acceptsRanges { return head.resolved }
        let get = try await probe(request.url, method: "GET", range: "bytes=0-0", policy: policy, isPrivate: request.isPrivate)
        if let error = HTTPResponseRules.validate(status: get.status == 206 ? 206 : get.status, headers: { get.headers[$0.lowercased()] }, rangeStart: get.status == 206 ? 0 : nil) { throw error }
        return get.resolved
    }

    /// A one-byte range request, headers only: what multipart eligibility is decided from. Never reads a body.
    func rangeProbe(_ url: URL, policy: HTTPRequestPolicy, withAccount: Bool = true) async throws -> (status: Int, headers: [String: String]) {
        try await policy.checkResolving(url)
        let result = try await probe(url, method: "GET", range: "bytes=0-0", policy: policy, withAccount: withAccount)
        return (result.status, result.headers)
    }

    private struct Probe {
        var status: Int
        var headers: [String: String]
        var finalURL: URL?
        var contentLength: Int64? {
            if let range = HTTPResponseRules.parseContentRange(headers["content-range"]), let total = range.total { return total }
            return HTTPSizeCheck.authoritativeSize(contentLength: headers["content-length"].flatMap(Int64.init), contentEncoding: headers["content-encoding"])
        }
        var acceptsRanges: Bool { (headers["accept-ranges"] ?? "").lowercased().contains("bytes") || status == 206 }
        var resolved: DownloadResolvedSource {
            var meta: [String: String] = [:]
            if let etag = headers["etag"] { meta["etag"] = etag }
            if let modified = headers["last-modified"] { meta["lastModified"] = modified }
            let name = DownloadFilename.derive(contentDisposition: headers["content-disposition"], url: finalURL, mimeType: headers["content-type"])
            return DownloadResolvedSource(suggestedFilename: name.name, totalBytes: contentLength, acceptsRanges: acceptsRanges, metadata: DownloadEngineMetadata.validated(meta))
        }
    }

    private func probe(_ url: URL, method: String, range: String?, policy: HTTPRequestPolicy, isPrivate: Bool = false, withAccount: Bool = true) async throws -> Probe {
        let setup = currentNetwork
        let config = Self.baseConfiguration(setup, connections: 4)
        config.timeoutIntervalForRequest = min(15, setup.requestTimeout); config.timeoutIntervalForResource = 30
        do { try DownloadProxy.apply(setup.proxy, password: setup.proxyPassword, origin: policy.origin, to: config) }
        catch { throw DownloadNetworkSetup.failure(for: error) }
        let probeSession = URLSession(configuration: config)
        defer { probeSession.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        if withAccount { for (name, value) in accountHeaders(for: url, origin: policy.origin, isPrivate: isPrivate) { request.setValue(value, forHTTPHeaderField: name) } }          // dropped again by the redirect guard if the address leaves the website
        let redirects = RedirectGuard(policy: policy, start: url)
        // Only the headers are wanted. The body is never read (a server that ignores the range would send the whole file), and the transfer is cancelled once they are in.
        let (bytes, response) = try await probeSession.bytes(for: request, delegate: redirects)
        bytes.task.cancel()
        if let refusal = redirects.refusal { throw refusal }
        guard let http = response as? HTTPURLResponse else { throw HTTPDownloadError(info: DownloadFailureInfo(code: "http:not-http", reason: "The website did not answer like a web server.", retryable: false)) }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields { if let k = key as? String, let v = value as? String { headers[k.lowercased()] = v } }
        return Probe(status: http.statusCode, headers: headers, finalURL: http.url)
    }

    /// Applies the redirect policy to a one-off request.
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let policy: HTTPRequestPolicy
        var chain: [URL]
        var refusal: HTTPRequestPolicy.Refusal?
        init(policy: HTTPRequestPolicy, start: URL) { self.policy = policy; chain = [start] }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            guard let from = chain.last, let to = request.url else { completionHandler(nil); return }
            let history = chain
            Task { [self] in
                switch await policy.decideRedirectResolving(from: from, to: to, chain: history) {
                case .refuse(let why): refusal = why; completionHandler(nil)
                case .follow(let drop):
                    chain.append(to)
                    var next = request
                    if drop { next.setValue(nil, forHTTPHeaderField: "Authorization") }
                    completionHandler(next)
                }
            }
        }
    }

    // MARK: Contexts

    private func currentContext(_ task: DownloadTaskID, attempt: Int) -> Context? {
        lock.lock(); defer { lock.unlock() }
        guard let context = current[task], context.attempt == attempt else { return nil }
        return context
    }

    private static func key(_ task: URLSessionTask) -> ObjectIdentifier { ObjectIdentifier(task) }

    private func context(for urlTask: URLSessionTask) -> Context? {
        lock.lock(); defer { lock.unlock() }
        guard let context = contexts[Self.key(urlTask)], current[context.taskID] === context else { return nil }
        return context
    }

    private func remove(_ context: Context) {
        lock.lock()
        if let task = context.urlTask { contexts[Self.key(task)] = nil }
        if current[context.taskID] === context { current[context.taskID] = nil }
        lock.unlock()
    }

    private func abandonCurrent(for task: DownloadTaskID) {
        lock.lock(); let old = current[task]; lock.unlock()
        if let old { old.cancelled = true; old.urlTask?.cancel(); remove(old) }
    }

    /// Number of tasks the engine is holding (for tests).
    var activeCount: Int { lock.lock(); defer { lock.unlock() }; return current.count }

    // MARK: URLSession delegate

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // The system decides about certificates; none is ever overridden. A login challenge is not answered: a standalone download has no one to ask.
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let context = context(for: task), let from = context.chain.last, let to = request.url else { completionHandler(nil); return }
        let chain = context.chain
        let policy = context.request.policy
        // The target's name is resolved before the redirect is followed, so a name that leads into the network is refused here.
        Task {
            switch await policy.decideRedirectResolving(from: from, to: to, chain: chain) {
            case .refuse(let why):
                context.refusal = why
                completionHandler(nil)                  // the redirect response itself then ends the transfer, and is reported as the refusal
            case .follow(let dropCredentials):
                context.chain.append(to)
                var next = request
                if dropCredentials { next.setValue(nil, forHTTPHeaderField: "Authorization") }    // never sent on to a different origin
                completionHandler(next)
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let context = context(for: downloadTask), !context.finished else { return }
        if !context.checkedResponse, let http = downloadTask.response as? HTTPURLResponse {
            context.checkedResponse = true
            if let problem = check(http, context: context) { fail(context, problem); downloadTask.cancel(); return }
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - context.lastProgress >= Self.progressInterval else { return }
        context.lastProgress = now
        let total: Int64? = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        context.sink?.report(.progress(completed: totalBytesWritten, total: total), task: context.taskID, attempt: context.attempt)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The system deletes `location` when this returns, so the file is dealt with here.
        guard let context = context(for: downloadTask), !context.finished else { return }
        guard let http = downloadTask.response as? HTTPURLResponse else { fail(context, HTTPResponseRules.failure(for: URLError(.badServerResponse))); return }
        if let problem = check(http, context: context) { fail(context, problem); return }
        let size = ((try? FileManager.default.attributesOfItem(atPath: location.path))?[.size] as? NSNumber)?.int64Value ?? -1
        let total = context.totalForVerification
        if let total, size >= 0, size != total {
            fail(context, HTTPDownloadError(info: DownloadFailureInfo(code: "http:wrong-size", reason: "The file arrived at \(size) bytes but the website said \(total), so it was not kept.", retryable: true), restartFromZero: true)); return
        }
        if size == 0, total != 0 {
            fail(context, HTTPDownloadError(info: DownloadFailureInfo(code: "http:empty", reason: "The website sent an empty file.", retryable: true))); return
        }
        if context.request.policy.origin != .user {
            // Not the person's own request: the file is only set aside here, and put in place once the address the connection really went to has been checked.
            do { context.staged = (try Self.stage(location, taskID: context.taskID, destination: context.request.destination), size) }
            catch { fail(context, HTTPResponseRules.failure(for: error)) }
            return
        }
        complete(context, from: location, size: size)
    }

    private func complete(_ context: Context, from location: URL, size: Int64) {
        // The point of no return. A cancel that got here first wins and nothing is put in place; one that comes after finds it too late.
        FinalizationTestHook.hook?(.beforeClaim)
        guard context.gate.claim() else {
            try? FileManager.default.removeItem(at: location)
            context.finished = true
            remove(context)
            return
        }
        lock.lock(); finalising.insert(context.taskID); lock.unlock()
        FinalizationTestHook.hook?(.afterClaim)
        do {
            let finalURL = try Self.finalise(from: location, to: context.request.destination, taskID: context.taskID, sourceOrigin: HTTPRequestPolicy.origin(of: context.chain.last ?? context.request.url))
            context.finished = true
            if finalURL != context.request.destination { context.sink?.report(.metadata(["finalPath": finalURL.path]), task: context.taskID, attempt: context.attempt) }
            context.sink?.report(.progress(completed: size, total: size), task: context.taskID, attempt: context.attempt)
            context.sink?.report(.finishedTransfer, task: context.taskID, attempt: context.attempt)
            remove(context)
        } catch {
            lock.lock(); finalising.remove(context.taskID); lock.unlock()
            fail(context, HTTPResponseRules.failure(for: error))
        }
    }

    /// Moves a downloaded file beside its destination under this task's own temporary name, without putting it in place.
    static func stage(_ location: URL, taskID: DownloadTaskID, destination: URL) throws -> URL {
        let fm = FileManager.default
        let directory = destination.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let staged = Self.stagedURL(for: taskID, in: directory)
        if fm.fileExists(atPath: staged.path) { try fm.removeItem(at: staged) }
        try fm.moveItem(at: location, to: staged)
        return staged
    }

    /// After the transfer: where the connection really went. Metrics arrive before `didCompleteWithError`.
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let context = context(for: task) else { return }
        for transaction in metrics.transactionMetrics where transaction.resourceFetchType != .localCache {
            let host = transaction.request.url?.host ?? context.request.url.host ?? ""
            let verdict = context.request.policy.verifyConnection(host: host, remote: transaction.remoteAddress, viaProxy: transaction.isProxyConnection, fromPublic: context.startedAtPublic)
            if case .refuse(let why) = verdict { context.connectionRefusal = why; return }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let context = context(for: task) else { return }          // an earlier attempt, a cancelled task, or one already finished: nothing to say
        if context.finished || context.cancelled { remove(context); return }
        if context.pausing { return }                                   // the pause handler reports this one
        if let staged = context.staged, error != nil { try? FileManager.default.removeItem(at: staged.file); context.staged = nil }
        if let failure = context.failure { report(failure, resumeData: nil, for: context); return }
        if let refusal = context.refusal { report(HTTPResponseRules.failure(for: refusal), resumeData: nil, for: context); return }
        if error == nil, let staged = context.staged {
            // The connection has been checked (the metrics came first): a refusal discards what was fetched.
            if let refusal = context.connectionRefusal {
                try? FileManager.default.removeItem(at: staged.file)
                report(HTTPResponseRules.failure(for: refusal), resumeData: nil, for: context)
            } else {
                complete(context, from: staged.file, size: staged.size)
            }
            return
        }
        guard let error else { return }                                 // success was handled in didFinishDownloadingTo
        let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        var mapped = HTTPResponseRules.failure(for: error)
        // A resume that fails for any reason other than the connection (the file changed, the data no longer fits) cannot be continued: it starts again from the beginning.
        if context.rangeStart != nil, !Self.isConnectionProblem(error), (error as NSError).code != NSURLErrorCancelled { mapped.restartFromZero = true; mapped.info.retryable = true }
        report(mapped, resumeData: resumeData, for: context)
    }

    static func isConnectionProblem(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet, NSURLErrorCannotConnectToHost,
                                                  NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed, NSURLErrorDataNotAllowed].contains(ns.code)
    }

    // MARK: Checks and reports

    /// Validates the response (status, ranges, validators); notes what the server revealed about resuming.
    private func check(_ response: HTTPURLResponse, context: Context) -> HTTPDownloadError? {
        func header(_ name: String) -> String? { response.value(forHTTPHeaderField: name) }
        if let refusal = context.refusal { return HTTPResponseRules.failure(for: refusal) }
        let signed = DownloadURLRedactor.looksSigned(context.request.url)
        let start: Int64? = context.rangeStart
        if let problem = HTTPResponseRules.validate(status: response.statusCode, headers: header, rangeStart: start, signed: signed) {
            // A resume that the server answered with the whole file is not an error to report: it is a restart, and the caller handles `restartFromZero`.
            return problem
        }
        let accepts = (header("Accept-Ranges") ?? "").lowercased().contains("bytes")
        let strong = header("ETag").map { !$0.hasPrefix("W/") } ?? (header("Last-Modified") != nil)
        context.resumable = response.statusCode == 206 || (accepts && strong)
        let rangeTotal = HTTPResponseRules.parseContentRange(header("Content-Range"))?.total
        context.totalForVerification = HTTPSizeCheck.authoritativeSize(contentLength: header("Content-Length").flatMap(Int64.init), contentEncoding: header("Content-Encoding"), rangeTotal: rangeTotal)
        var meta: [String: String] = [:]
        if let etag = header("ETag") { meta["etag"] = etag }
        if let modified = header("Last-Modified") { meta["lastModified"] = modified }
        meta["resumable"] = context.resumable == true ? "1" : "0"
        let name = DownloadFilename.derive(contentDisposition: header("Content-Disposition"), url: response.url, mimeType: header("Content-Type"))
        meta["serverName"] = name.name
        if name.suspicious { meta["suspiciousName"] = "1" }
        context.sink?.report(.metadata(DownloadEngineMetadata.validated(meta)), task: context.taskID, attempt: context.attempt)
        if let total = context.totalForVerification { context.sink?.report(.progress(completed: 0, total: total), task: context.taskID, attempt: context.attempt) }
        return nil
    }

    private func fail(_ context: Context, _ error: HTTPDownloadError) {
        context.failure = error
        if context.urlTask?.state == .running { context.urlTask?.cancel() } else { report(error, resumeData: nil, for: context) }
    }

    private func report(_ error: HTTPDownloadError, resumeData: Data?, for context: Context) {
        guard !context.finished else { return }
        context.finished = true
        remove(context)
        var info = error.info
        if error.restartFromZero { info.code = HTTPFailureCode.restartFromZero + ":" + info.code }
        context.sink?.report(.failed(info, resumeData: (error.restartFromZero || context.usedCredential) ? nil : resumeData, retryAfter: error.retryAfter), task: context.taskID, attempt: context.attempt)
    }

    // MARK: File finalisation

    /// Puts the finished file in place without ever overwriting an existing one: first beside its destination under a name of its own, then renamed (atomic on one volume).
    /// If the destination was taken in the meantime, a numbered name is used. Safe to repeat: the temporary name is per task.
    static func finalise(from location: URL, to destination: URL, taskID: DownloadTaskID, sourceOrigin: String) throws -> URL {
        let fm = FileManager.default
        let directory = destination.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let partial = directory.appendingPathComponent(".\(taskID.uuidString.prefix(8)).bsetu-part")
        if fm.fileExists(atPath: partial.path) { try fm.removeItem(at: partial) }           // this task's own leftover, never anything else
        try fm.moveItem(at: location, to: partial)                                          // across volumes this copies; either way the destination volume holds the bytes
        // The name is claimed by the rename itself (it fails if the name exists), so concurrent downloads of one name each get their own and nothing is replaced.
        let target: URL
        do { target = try FileNaming.publish(partial, as: destination) }
        catch { try? fm.removeItem(at: partial); throw error }
        DownloadQuarantine.apply(to: target, sourceOrigin: sourceOrigin)      // as for a browser's own download
        return target
    }

    /// The temporary file a task would leave, for cleanup of this task's own leftovers only.
    static func stagedURL(for taskID: DownloadTaskID, in directory: URL) -> URL { directory.appendingPathComponent(".\(taskID.uuidString.prefix(8)).bsetu-staged") }
    static func partialURL(for taskID: DownloadTaskID, in directory: URL) -> URL { directory.appendingPathComponent(".\(taskID.uuidString.prefix(8)).bsetu-part") }
}
