import CryptoKit
import Foundation

/// Concurrent byte ranges of one HTTP file, validated against the same resource, written in place, checkpointed durably.
///
/// Decisions (Phase 3):
///  - Fixed, durable pieces (`MultipartPlanner`) with a bounded pool of workers that take the next pending piece. Fixed boundaries are what make a checkpoint mean the same thing after a
///    restart; the pool is what keeps a slow connection from holding up the rest. Connections start conservative (4) and only ever go down (throttling), never up: no probing.
///  - Data tasks, not download tasks: the response is validated (status, Content-Range, length, encoding, validators) BEFORE a byte is written, so a server that ignores the range or
///    sends another part cannot put wrong bytes in the file. Bytes go straight to their offset in one preallocated file with `pwrite` (no second copy, no assembly pass).
///  - A piece is marked done in SQLite only after `F_FULLFSYNC` of the file. The unsafe order (database says done, bytes not on disk) cannot happen; the safe one (bytes on disk, not yet
///    marked) just means one piece is fetched again. On resume the file and the checkpoints are reconciled, and pieces finished in an earlier run are re-hashed before finalising.
///  - Only the person's own requests are eligible this phase. Untrusted origins use the single-transfer engine, which checks the connection's real address.
///
/// One instance owns one run (one attempt of one task). Everything a late callback could touch is behind `lock` and a `stopped` flag.
final class MultipartRun: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Configuration: Sendable {
        var url: URL
        var policy: HTTPRequestPolicy
        var headers: [String: String]
        var destination: URL
        var total: Int64
        var etag: String?
        var lastModified: String?
        var connections: Int
        /// An exact version of the retry waits for tests.
        var pieceRetryScale = 1.0
        var network = DownloadNetworkSetup()
        /// More places the same bytes may be fetched from, already checked (size, range support, destination) by whoever starts the run. Empty means the one source `url`.
        /// They are used only when something other than their own say-so shows they are the same file: the caller sets them only with a trusted whole-file SHA-256 that is verified at the end.
        var mirrors: [Mirror] = []
        /// Told (with nothing about what failed) whenever a piece fails in a way that may be tried again, so adaptive control can count them.
        var onTransient: (@Sendable () -> Void)?
    }

    struct Mirror: Sendable, Equatable {
        /// Names this mirror in reports (the id of its entry in the mirror list), so what is said about it lands on it and not on another.
        var tag = ""
        var url: URL
        /// The version tag of the mirror's own copy. A tag is only meaningful for the resource that issued it: it is compared with that mirror's later answers, never with another source's.
        var etag: String?
        var lastModified: String?
    }

    /// One place bytes come from. Source 0 is `config.url`.
    private struct Source {
        var tag = ""
        var url: URL
        var host: String
        var etag: String?
        var lastModified: String?
        var startedAtPublic: Bool
        var disabled = false
        var consecutiveFailures = 0
        var bytes: Int64 = 0
        var failure: String?
        /// When the first piece was asked of it (monotonic seconds), so what it has delivered since can be told as a rate.
        var firstUse: Double?
    }
    static let sourceFailureLimit = 3

    private let taskID: DownloadTaskID
    let attempt: Int
    private let config: Configuration
    private weak var sink: DownloadReportSink?
    private let store: DownloadTaskStore?
    private let budget: ConnectionBudget
    private let bandwidth: BandwidthController
    /// Workers whose connection is stopped while they wait for their share of the speed limit.
    private var throttled = Set<Int>()
    private var setupError: HTTPDownloadError?

    private let lock = NSLock()
    private var session: URLSession!
    private let delegateQueue: OperationQueue
    private let io = DispatchQueue(label: "browsersetu.downloads.multipart.io", qos: .utility)

    private var pieces: [PieceRecord] = []
    private var pending: [Int] = []
    private var delayed = Set<Int>()
    private var active: [Int: Active] = [:]                // by URLSessionTask.taskIdentifier
    private var tries: [Int: Int] = [:]
    private var workerLimit: Int
    /// An upper bound from the adaptive controller. It only ever lowers the number of workers; the connection budget and the throttle halving still apply on top of it.
    private var adaptiveCeiling: Int?
    private var workerBound: Int { min(workerLimit, adaptiveCeiling ?? Int.max) }
    private var stopped = false
    private var finalising = false
    private var fd: Int32 = -1
    private var doneBytes: Int64 = 0
    private var reportedBytes: Int64 = 0
    private var networkBytes: Int64 = 0
    private var throttles = 0
    private var lastProgress: TimeInterval = 0
    private var lastStats: TimeInterval = 0
    private var workingURL: URL
    /// Pieces that have arrived and are waiting to be made durable together (one sync covers every piece that finished meanwhile).
    private var durabilityBatch: [(piece: PieceRecord, digest: String, taskIdentifier: Int, source: Int, host: String)] = []
    private var durabilityRunning = false
    /// Cancel against putting the file in place; see `FinalizationGate`.
    let gate = FinalizationGate()
    /// Tasks whose connection went somewhere it should not have, with why.
    private var refusedTasks: [Int: HTTPRequestPolicy.Refusal] = [:]
    private var sources: [Source] = []

    private struct Active {
        var piece: Int
        var source = 0
        var task: URLSessionDataTask
        var written: Int64 = 0
        var hasher = SHA256()
        var chain: [URL]
        var host: String
    }

    static func workingURL(for taskID: DownloadTaskID, in directory: URL) -> URL { directory.appendingPathComponent(".\(taskID.uuidString.prefix(8)).bsetu-multi") }

    init(taskID: DownloadTaskID, attempt: Int, configuration: Configuration, sink: DownloadReportSink, store: DownloadTaskStore?, budget: ConnectionBudget, bandwidth: BandwidthController = .shared) {
        self.bandwidth = bandwidth; self.taskID = taskID; self.attempt = attempt; self.config = configuration; self.sink = sink; self.store = store; self.budget = budget
        workerLimit = max(1, min(configuration.connections, MultipartPlanner.maxConnections))
        func make(_ url: URL, _ etag: String?, _ modified: String?, tag: String = "") -> Source {
            Source(tag: tag, url: url, host: url.host ?? "", etag: etag, lastModified: modified, startedAtPublic: !HTTPRequestPolicy.classify(host: url.host ?? "").isInternal)
        }
        sources = [make(configuration.url, configuration.etag, configuration.lastModified)] + configuration.mirrors.prefix(7).map { make($0.url, $0.etag, $0.lastModified, tag: $0.tag) }
        workingURL = Self.workingURL(for: taskID, in: configuration.destination.deletingLastPathComponent())
        delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.name = "browsersetu.downloads.multipart.\(taskID.uuidString.prefix(8))"
        super.init()
        let sessionConfig = HTTPTransferEngine.baseConfiguration(configuration.network, connections: MultipartPlanner.maxConnections)
        sessionConfig.timeoutIntervalForRequest = configuration.policy.requestTimeout
        sessionConfig.timeoutIntervalForResource = configuration.policy.resourceTimeout
        // Same proxy choice as the single-transfer engine. If it cannot be used, `start` reports that, and nothing is sent.
        do { try DownloadProxy.apply(configuration.network.proxy, password: configuration.network.proxyPassword, origin: configuration.policy.origin, to: sessionConfig) }
        catch { setupError = DownloadNetworkSetup.failure(for: error) }
        session = URLSession(configuration: sessionConfig, delegate: self, delegateQueue: delegateQueue)
    }

    // MARK: Starting (fresh or from checkpoints)

    enum StartOutcome { case started(resumedPieces: Int), restarted(reason: String) }

    /// Opens the working file, reconciles it with the checkpoints, and starts the workers. Throws when the file cannot be prepared (no space, no permission).
    @discardableResult
    func start() throws -> StartOutcome {
        do { return try startRun() }
        catch { stopThrottling(); session.invalidateAndCancel(); throw error }          // a run that never started must not keep its session (and so itself) alive
    }

    private func startRun() throws -> StartOutcome {
        if let setupError { bandwidth.forget(task: taskID); throw setupError }
        let fm = FileManager.default
        try fm.createDirectory(at: workingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var saved = store?.loadPieces(task: taskID) ?? []
        var reason: String?
        let existing = (try? fm.attributesOfItem(atPath: workingURL.path)[.size] as? NSNumber)?.int64Value
        if saved.isEmpty { reason = nil }
        else if MultipartPlanner.coverageProblem(saved, total: config.total, requireDone: false) != nil { reason = "the saved plan did not match the file's size"; saved = [] }
        else if existing != config.total { reason = "the partly downloaded file was no longer there"; saved = [] }
        let fresh = saved.isEmpty
        if fresh {
            saved = MultipartPlanner.plan(total: config.total)
            try store?.savePlan(task: taskID, pieces: saved)
            if existing != nil { try? fm.removeItem(at: workingURL) }
        }
        guard !saved.isEmpty else { throw HTTPDownloadError(info: DownloadFailureInfo(code: "multipart:plan", reason: "The file's size is not usable.", retryable: false)) }
        // Enough room for what is still to come, checked before anything is written.
        let remaining = saved.filter { $0.state == .pending }.reduce(Int64(0)) { $0 + $1.length }
        if let free = (try? config.destination.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage,
           fresh ? free < config.total : free < remaining {
            throw HTTPDownloadError(info: DownloadFailureInfo(code: "posix:\(ENOSPC)", reason: "There is not enough space on the disk.", retryable: false))
        }
        let descriptor = open(workingURL.path, O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if fresh, ftruncate(descriptor, off_t(config.total)) != 0 { let code = errno; close(descriptor); throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        lock.lock()
        fd = descriptor
        pieces = saved
        pending = saved.filter { $0.state == .pending }.map(\.index)
        doneBytes = saved.filter { $0.state == .done }.reduce(0) { $0 + $1.length }
        reportedBytes = doneBytes
        lock.unlock()
        report(.running)
        report(.progress(completed: doneBytes, total: config.total))
        reportStats(force: true)
        pump()
        let resumed = saved.filter { $0.state == .done }.count
        return fresh && reason == nil ? .started(resumedPieces: 0) : (fresh ? .restarted(reason: reason ?? "") : .started(resumedPieces: resumed))
    }

    // MARK: Scheduling

    private func report(_ report: DownloadEngineReport) { sink?.report(report, task: taskID, attempt: attempt) }

    /// Starts workers up to the limit, if the host and global budgets allow.
    private func pump() {
        lock.lock()
        guard !stopped, !finalising else { lock.unlock(); return }
        var launches: [(PieceRecord, Int)] = []          // the piece and the source it comes from
        while active.count + launches.count < workerBound, let next = pending.first, let source = pickSource(launching: launches) {
            pending.removeFirst()
            launches.append((pieces[next], source))
        }
        let waiting = !pending.isEmpty && active.count + launches.count < workerBound
        lock.unlock()
        for (piece, source) in launches { launch(piece, source: source) }
        if waiting { delegateQueue.schedule(after: 0.25) { [weak self] in self?.pump() } }       // the budget was full: look again shortly
        checkFinished()
    }

    /// The source for the next piece: the least busy one that is still in use and has room under its share, whose connection the shared budget grants. Called with the lock held.
    /// (Each source gets about an equal share of the workers; the shared budget still limits the total and each website, whichever source a connection is for.)
    private func pickSource(launching: [(PieceRecord, Int)]) -> Int? {
        let enabled = sources.indices.filter { !sources[$0].disabled }
        guard !enabled.isEmpty else { return nil }
        let share = max(1, (workerBound + enabled.count - 1) / enabled.count)
        func load(_ s: Int) -> Int { active.values.filter { $0.source == s }.count + launching.filter { $0.1 == s }.count }
        let now = SystemMonotonicClock().now()
        let fastest = enabled.map { Self.rate(sources[$0], now: now) }.max() ?? 0
        // A source that has delivered less than a quarter of the best one is kept (it may recover), but with one worker: its share goes to the others. No extra connection is opened for this.
        let slow = Set(enabled.filter { let r = Self.rate(sources[$0], now: now); return r > 0 && fastest > 0 && r < fastest * 0.25 })
        let others = max(1, enabled.count - slow.count)
        let bonus = slow.isEmpty ? 0 : (slow.count * max(0, share - 1) + others - 1) / others          // what the slow ones leave unused, spread over the rest (the same workers, not more)
        func limit(_ s: Int) -> Int { slow.contains(s) ? 1 : share + bonus }
        // The least busy source first; among equally busy ones the one that has delivered faster so far (never a source that is out of use, and never more than its share).
        for s in enabled.sorted(by: { (load($0), -Self.rate(sources[$0], now: now), $0) < (load($1), -Self.rate(sources[$1], now: now), $1) }) where load(s) < limit(s) && budget.acquire(host: sources[s].host, task: taskID) { return s }
        return nil
    }

    /// Bytes per second a source has delivered since it was first used; 0 until it has been used for a second.
    private static func rate(_ source: Source, now: Double) -> Double {
        guard let first = source.firstUse, now - first >= 1 else { return 0 }
        return Double(source.bytes) / (now - first)
    }

    /// What each source has delivered, for the details (the id of its entry and bytes per second), in the order the sources were given.
    var sourceRates: [(tag: String, bytesPerSecond: Double, usable: Bool)] {
        lock.lock(); defer { lock.unlock() }
        let now = SystemMonotonicClock().now()
        return sources.map { ($0.tag, Self.rate($0, now: now), !$0.disabled) }
    }

    /// Lowers (or restores, with nil) the most workers this run may use. Pieces already in flight finish; none is dropped, and nothing is restarted.
    func setAdaptiveCeiling(_ ceiling: Int?) {
        lock.lock()
        let raised = (ceiling ?? Int.max) > (adaptiveCeiling ?? Int.max)
        adaptiveCeiling = ceiling.map { max(1, $0) }
        lock.unlock()
        if raised { pump() }
    }

    /// Takes a source out of use for the rest of this run, if another is left. Called with the lock NOT held. False means it is the last one, and the failure is the run's.
    private func disableSource(_ index: Int, reason: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard sources.indices.contains(index), !sources[index].disabled, sources.indices.contains(where: { $0 != index && !sources[$0].disabled }) else { return false }
        sources[index].disabled = true
        sources[index].failure = String(reason.prefix(160))
        return true
    }

    private func request(for piece: PieceRecord, url: URL, source: Int) -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: config.policy.requestTimeout)
        r.httpMethod = "GET"
        r.httpShouldHandleCookies = false
        r.setValue("bytes=\(piece.start)-\(piece.end)", forHTTPHeaderField: "Range")
        r.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let agent = config.policy.userAgent { r.setValue(agent, forHTTPHeaderField: "User-Agent") }
        // The request's own headers (a login, a referrer) go only to the website the person named, never to another source.
        if HTTPRequestPolicy.origin(of: url) == HTTPRequestPolicy.origin(of: config.url) { for (name, value) in config.headers { r.setValue(value, forHTTPHeaderField: name) } }
        // If the file changed, a server that honours If-Range sends the whole new file (a 200), which is refused below rather than written into the old one.
        // Each source is asked with its OWN version tag: a tag says nothing about another server's copy.
        lock.lock(); let known = sources[source]; lock.unlock()
        if let etag = known.etag { r.setValue(etag, forHTTPHeaderField: "If-Range") } else if let modified = known.lastModified { r.setValue(modified, forHTTPHeaderField: "If-Range") }
        return r
    }

    private func launch(_ piece: PieceRecord, source: Int) {
        // The task is made under the lock, and only if the run is still going: every stop sets `stopped` before it invalidates the session, and a task cannot be made on an invalidated one.
        lock.lock()
        let target = sources[source]
        if stopped { lock.unlock(); budget.release(host: target.host, task: taskID); return }
        lock.unlock()
        let urlRequest = request(for: piece, url: target.url, source: source)
        lock.lock()
        if stopped { lock.unlock(); budget.release(host: target.host, task: taskID); return }
        let task = session.dataTask(with: urlRequest)
        if sources[source].firstUse == nil { sources[source].firstUse = SystemMonotonicClock().now() }
        active[task.taskIdentifier] = Active(piece: piece.index, source: source, task: task, chain: [target.url], host: target.host)
        lock.unlock()
        task.resume()
    }

    // MARK: URLSession delegate

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock(); let chain = active[task.taskIdentifier]?.chain; lock.unlock()
        guard let chain, let from = chain.last, let to = request.url else { completionHandler(nil); return }
        let policy = config.policy
        Task { [self] in
            switch await policy.decideRedirectResolving(from: from, to: to, chain: chain) {
            case .refuse(let why):
                completionHandler(nil)
                pieceFailed(task, HTTPResponseRules.failure(for: why), terminal: true)
            case .follow(let drop):
                lock.lock(); active[task.taskIdentifier]?.chain.append(to); lock.unlock()
                var next = request
                if drop { next.setValue(nil, forHTTPHeaderField: "Authorization") }
                completionHandler(next)
            }
        }
    }

    /// Where the connection really went. A public name that led to an internal address (a rebinding trick) is refused: the piece is not accepted and the run ends, with its file dropped.
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.lock(); let entry = active[task.taskIdentifier]; let known = entry.map { sources[$0.source] }; lock.unlock()
        guard let known, known.startedAtPublic else { return }
        for transaction in metrics.transactionMetrics {
            let verdict = config.policy.verifyConnection(host: known.host, remote: transaction.remoteAddress, viaProxy: transaction.isProxyConnection, fromPublic: true)
            if case .refuse(let why) = verdict {
                lock.lock(); refusedTasks[task.taskIdentifier] = why; lock.unlock()
                return
            }
        }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }

    /// Every response is checked against what was asked for and against the resource as first seen, before any of its bytes are kept.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        let entry = active[dataTask.taskIdentifier]
        let piece = entry.map { pieces[$0.piece] }
        let isStopped = stopped
        lock.unlock()
        guard let entry, let piece, !isStopped, let http = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        if let problem = validate(http, for: piece, source: entry.source) {
            completionHandler(.cancel)
            pieceFailed(dataTask, problem.error, terminal: problem.terminal, unsafe: problem.unsafe)
            return
        }
        _ = entry
        completionHandler(.allow)
    }

    private struct Problem { var error: HTTPDownloadError; var terminal: Bool; var unsafe: Bool }

    private func validate(_ response: HTTPURLResponse, for piece: PieceRecord, source: Int) -> Problem? {
        lock.lock(); let known = sources[source]; lock.unlock()
        func header(_ name: String) -> String? { response.value(forHTTPHeaderField: name) }
        func unsafe(_ code: String, _ reason: String, restart: Bool = false) -> Problem {
            Problem(error: HTTPDownloadError(info: DownloadFailureInfo(code: "multipart:" + code, reason: reason, retryable: true), restartFromZero: restart), terminal: true, unsafe: true)
        }
        switch response.statusCode {
        case 206: break
        case 200: return unsafe("range-ignored", "The website ignored the request for part of the file.")
        case 416: return unsafe("416", "The website refused the part that was asked for.", restart: true)
        default:
            if let error = HTTPResponseRules.validate(status: response.statusCode, headers: header, rangeStart: piece.start, signed: DownloadURLRedactor.looksSigned(known.url)) {
                return Problem(error: error, terminal: !error.info.retryable, unsafe: false)
            }
        }
        guard let range = HTTPResponseRules.parseContentRange(header("Content-Range")), range.start == piece.start, range.end == piece.end else {
            return unsafe("wrong-range", "The website sent a different part of the file than the one asked for.")
        }
        if let total = range.total, total != config.total { return unsafe("changed-size", "The file's size changed while it was downloading.", restart: true) }
        if let length = header("Content-Length").flatMap(Int64.init), length != piece.length { return unsafe("wrong-length", "The website sent a part of the wrong length.") }
        let encoding = (header("Content-Encoding") ?? "identity").lowercased().trimmingCharacters(in: .whitespaces)
        if !encoding.isEmpty, encoding != "identity" { return unsafe("encoded", "The website compresses the file, so it cannot be fetched in parts.") }
        // The same resource on every connection: a different version tag or modification time means the file changed, and what is already in place no longer belongs to it.
        if known.etag != nil, header("ETag") == nil { return unsafe("no-validator", "The website did not say which version of the file this part belongs to.") }
        if known.etag == nil, known.lastModified != nil, header("Last-Modified") == nil { return unsafe("no-validator", "The website did not say which version of the file this part belongs to.") }
        if let tag = known.etag, let seen = header("ETag"), seen != tag { return unsafe("changed-etag", "The file changed on the website while it was downloading.", restart: true) }
        if known.etag == nil, let date = known.lastModified, let seen = header("Last-Modified"), seen != date { return unsafe("changed-date", "The file changed on the website while it was downloading.", restart: true) }
        return nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !stopped, var entry = active[dataTask.taskIdentifier] else { lock.unlock(); return }
        let piece = pieces[entry.piece]
        let offset = piece.start + entry.written
        let overflow = entry.written + Int64(data.count) > piece.length
        let descriptor = fd
        lock.unlock()
        if overflow { pieceFailed(dataTask, HTTPDownloadError(info: DownloadFailureInfo(code: "multipart:too-long", reason: "The website sent more than was asked for.", retryable: true)), terminal: false, cancel: true); return }
        // Written where it belongs; a failed write (the disk is full, say) ends the whole download, because no piece can then be trusted to land.
        var written = 0
        let ok = data.withUnsafeBytes { buffer -> Bool in
            guard var base = buffer.baseAddress else { return true }
            var remaining = buffer.count
            var position = off_t(offset)
            while remaining > 0 {
                let n = pwrite(descriptor, base, remaining, position)
                if n < 0 { if errno == EINTR { continue }; return false }
                remaining -= n; base += n; position += off_t(n); written += n
            }
            return true
        }
        guard ok else {
            let code = errno
            fail(HTTPResponseRules.failure(for: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)))
            return
        }
        lock.lock()
        if var latest = active[dataTask.taskIdentifier] { latest.written += Int64(data.count); latest.hasher.update(data: data); active[dataTask.taskIdentifier] = latest; entry = latest }
        networkBytes += Int64(data.count)
        lock.unlock()
        reportProgress()
        throttle(dataTask, afterReceiving: data.count)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard !stopped, let entry = active[task.taskIdentifier] else { lock.unlock(); return }      // cancelled, paused, or already failed: nothing to say
        // The system may already have read the whole piece ahead of the pause. A piece is not complete until the time its bytes were allowed has passed, so the speed limit holds for the
        // download as a whole whatever the system buffered.
        if error == nil {
            lock.unlock()
            let owed = bandwidth.remainingWait(task: taskID)
            if owed > 0.002 {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + min(owed, 0.25)) { [weak self] in
                    self?.delegateQueue.addOperation { self?.urlSession(session, task: task, didCompleteWithError: nil) }
                }
                return
            }
            lock.lock()
            guard !stopped, active[task.taskIdentifier] != nil else { lock.unlock(); return }
        }
        let piece = pieces[entry.piece]
        let refusal = refusedTasks.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        if let refusal {
            // A mirror whose connection went somewhere it should not have is dropped for this run, and its piece comes from another source; nothing it sent was kept.
            if entry.source > 0 {
                lock.lock(); let removed = active.removeValue(forKey: task.taskIdentifier); lock.unlock()
                if removed != nil {
                    budget.release(host: entry.host, task: taskID)
                    if disableSource(entry.source, reason: HTTPResponseRules.failure(for: refusal).info.reason) { lock.lock(); if !stopped { pending.insert(piece.index, at: 0) }; lock.unlock(); pump(); return }
                }
            }
            // Nothing from that connection is kept: the whole file starts over, and not through pieces again.
            fail(HTTPDownloadError(info: DownloadFailureInfo(code: "multipart:connection-refused", reason: HTTPResponseRules.failure(for: refusal).info.reason, retryable: false), restartFromZero: false))
            return
        }
        if let error {
            pieceFailed(task, HTTPResponseRules.failure(for: error), terminal: false)
            return
        }
        guard entry.written == piece.length else {
            pieceFailed(task, HTTPDownloadError(info: DownloadFailureInfo(code: "multipart:short", reason: "The website stopped sending before the whole part arrived.", retryable: true)), terminal: false)
            return
        }
        // Durable first, recorded second. Pieces that finish close together share one sync (a full flush is slow, and the order is what matters, not the count).
        let digest = entry.hasher.finalize().map { String(format: "%02x", $0) }.joined()
        lock.lock()
        durabilityBatch.append((piece, digest, task.taskIdentifier, entry.source, entry.host))
        let start = !durabilityRunning
        durabilityRunning = true
        lock.unlock()
        if start { io.async { [self] in drainDurability() } }
    }

    private func drainDurability() {
        while true {
            lock.lock()
            let batch = durabilityBatch
            durabilityBatch = []
            let descriptor = fd
            let isStopped = stopped
            if batch.isEmpty || isStopped { durabilityRunning = false; lock.unlock(); return }
            lock.unlock()
            guard fcntl(descriptor, F_FULLFSYNC) != -1 || fsync(descriptor) == 0 else {
                lock.lock(); durabilityRunning = false; lock.unlock()
                fail(HTTPResponseRules.failure(for: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)))
                return
            }
            // Only now are they recorded as done.
            for item in batch { store?.markPieceDone(task: taskID, index: item.piece.index, checksum: item.digest, session: attempt) }
            var released: [String] = []
            lock.lock()
            for item in batch where !stopped {
                guard active.removeValue(forKey: item.taskIdentifier) != nil else { continue }
                if sources.indices.contains(item.source) { sources[item.source].bytes += item.piece.length; sources[item.source].consecutiveFailures = 0 }
                pieces[item.piece.index].state = .done
                pieces[item.piece.index].checksum = item.digest
                pieces[item.piece.index].session = attempt
                doneBytes += item.piece.length
                tries[item.piece.index] = nil
                released.append(item.host)
            }
            lock.unlock()
            for host in released { budget.release(host: host, task: taskID) }
            reportProgress(force: true)
            pump()
        }
    }

    // MARK: Failures

    /// One piece went wrong. A transient problem puts the piece back after a wait; a refusal ends the run; an unsafe one (range ignored, file changed) ends it asking for a fallback.
    private func pieceFailed(_ task: URLSessionTask, _ error: HTTPDownloadError, terminal: Bool, unsafe: Bool = false, cancel: Bool = false) {
        lock.lock()
        guard !stopped, let entry = active.removeValue(forKey: task.taskIdentifier) else { lock.unlock(); return }
        let index = entry.piece
        lock.unlock()
        budget.release(host: entry.host, task: taskID)
        if error.info.retryable { config.onTransient?() }
        if cancel { task.cancel() }
        // With other sources left, a source that gave something wrong (a wrong range, a changed file, a refusal) is dropped for this run and the piece comes from another. Nothing it sent
        // was kept: every answer is checked before a byte is written. Only the last source left ends the run.
        if terminal || unsafe {
            if disableSource(entry.source, reason: error.info.reason) { lock.lock(); if !stopped { pending.insert(index, at: 0) }; lock.unlock(); pump(); return }
            fail(error); return
        }
        lock.lock(); sources[entry.source].consecutiveFailures += 1; let wornOut = sources[entry.source].consecutiveFailures >= Self.sourceFailureLimit; lock.unlock()
        if wornOut, disableSource(entry.source, reason: error.info.reason) { lock.lock(); if !stopped { pending.insert(index, at: 0) }; lock.unlock(); pump(); return }
        // Throttling: fewer connections, never more.
        if [429, 503].contains(Int(error.info.code.replacingOccurrences(of: "http:", with: "")) ?? 0) {
            lock.lock(); throttles += 1; workerLimit = max(1, workerLimit / 2); let giveUp = throttles >= 4 && workerLimit == 1; lock.unlock()
            if giveUp { fail(error); return }
        }
        lock.lock()
        let attemptsSoFar = (tries[index] ?? 0) + 1
        tries[index] = attemptsSoFar
        lock.unlock()
        guard error.info.retryable, attemptsSoFar < config.network.maxAttempts else { fail(error); return }
        let wait = HTTPRetrySchedule.delay(afterAttempt: attemptsSoFar, retryAfter: error.retryAfter) * config.pieceRetryScale
        lock.lock(); delayed.insert(index); lock.unlock()
        delegateQueue.schedule(after: wait) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.delayed.remove(index)
            if !self.stopped { self.pending.insert(index, at: 0) }
            self.lock.unlock()
            self.pump()
        }
        pump()
    }

    /// Ends the run with a failure (all workers stopped, the file kept for a later resume unless the failure says it cannot be).
    private func fail(_ error: HTTPDownloadError) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        let tasks = active.values.map(\.task)
        let count = active.count
        active = [:]
        lock.unlock()
        for _ in 0..<count { budget.release(host: config.url.host ?? "", task: taskID) }; budget.release(task: taskID)
        tasks.forEach { $0.cancel() }
        stopThrottling()
        closeFile()
        session.invalidateAndCancel()
        var info = error.info
        if error.restartFromZero { info.code = HTTPFailureCode.restartFromZero + ":" + info.code }
        report(.failed(info, resumeData: nil, retryAfter: error.retryAfter))
    }

    // MARK: Progress

    private func reportProgress(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard !stopped, force || now - lastProgress >= HTTPTransferEngine.progressInterval else { lock.unlock(); return }
        lastProgress = now
        // Unique bytes: durable pieces plus what the active ones have written. Never less than was reported, so a piece that starts again does not move the bar back.
        let live = doneBytes + active.values.reduce(0) { $0 + $1.written }
        reportedBytes = max(reportedBytes, min(live, config.total))
        let value = reportedBytes
        lock.unlock()
        report(.progress(completed: value, total: config.total))
        reportStats(force: false)
    }

    private func reportStats(force: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard force || now - lastStats >= 1 else { lock.unlock(); return }
        lastStats = now
        var meta = ["mode": "multipart", "connections": "\(active.count)", "pieces": "\(pieces.count)", "piecesDone": "\(pieces.filter { $0.state == .done }.count)",
                    "piecesRetrying": "\(delayed.count)", "networkBytes": "\(networkBytes)"]
        if sources.count > 1 {
            meta["sources"] = "\(sources.count)"; meta["sourcesInUse"] = "\(sources.filter { !$0.disabled }.count)"
            meta["mirrorBytes"] = "\(sources.dropFirst().reduce(Int64(0)) { $0 + $1.bytes })"
            for s in sources.dropFirst() where !s.tag.isEmpty { meta["mir.\(s.tag)"] = "\(s.disabled ? "bad" : (s.bytes > 0 ? "used" : "ready")):\(s.bytes):\(s.failure ?? "")" }
        }
        lock.unlock()
        report(.metadata(meta))
    }

    // MARK: Finishing

    private func checkFinished() {
        lock.lock()
        let allDone = !stopped && !finalising && active.isEmpty && pending.isEmpty && delayed.isEmpty && pieces.allSatisfy { $0.state == .done }
        if allDone { finalising = true }
        lock.unlock()
        if allDone { io.async { [self] in finalise() } }
    }

    /// Every byte accounted for, then the same finalisation as a single transfer. Nothing is called complete before this succeeds.
    private func finalise() {
        lock.lock(); let snapshot = pieces; let descriptor = fd; lock.unlock()
        if let problem = MultipartPlanner.coverageProblem(snapshot, total: config.total, requireDone: true) {
            fail(HTTPDownloadError(info: DownloadFailureInfo(code: "multipart:coverage", reason: "The parts did not add up to the whole file (\(problem)), so it was not kept.", retryable: true), restartFromZero: true)); return
        }
        var stat = Darwin.stat()
        guard fstat(descriptor, &stat) == 0, Int64(stat.st_size) == config.total else {
            fail(HTTPDownloadError(info: DownloadFailureInfo(code: "multipart:size", reason: "The file is not the size the website said, so it was not kept.", retryable: true), restartFromZero: true)); return
        }
        // Pieces finished in an earlier run are read back and compared with what was recorded when they were written.
        for piece in snapshot where piece.session != attempt {
            lock.lock(); let isStopped = stopped; lock.unlock()
            if isStopped { return }
            guard let expected = piece.checksum, let actual = Self.hash(descriptor: descriptor, start: piece.start, length: piece.length), actual == expected else {
                fail(HTTPDownloadError(info: DownloadFailureInfo(code: "multipart:piece-corrupt", reason: "Part of the file saved earlier had changed on disk, so the download starts over.", retryable: true), restartFromZero: true)); return
            }
        }
        // The point of no return: from here a cancel is too late and the download completes; before it, a cancel wins and nothing is put in place.
        FinalizationTestHook.hook?(.beforeClaim)
        lock.lock()
        let cancelledNow = stopped || !gate.claim()
        if !cancelledNow { stopped = true }
        lock.unlock()
        guard !cancelledNow else { return }
        FinalizationTestHook.hook?(.afterClaim)
        closeFile(immediately: true)
        budget.release(task: taskID)
        session.finishTasksAndInvalidate()
        do {
            let final = try HTTPTransferEngine.finalise(from: workingURL, to: config.destination, taskID: taskID, sourceOrigin: HTTPRequestPolicy.origin(of: config.url))
            store?.deletePieces(task: taskID)
            if final != config.destination { report(.metadata(["finalPath": final.path])) }
            report(.metadata(["mode": "multipart", "connections": "0", "pieces": "\(snapshot.count)", "piecesDone": "\(snapshot.count)", "networkBytes": "\(networkBytes)"]))
            report(.progress(completed: config.total, total: config.total))
            stopThrottling()
            reportStats(force: true)          // what each source contributed, before the file is judged (a mismatch has to know whether several sources were used)
            report(.finishedTransfer)
        } catch {
            report(.failed(HTTPResponseRules.failure(for: error).info, resumeData: nil, retryAfter: nil))
        }
    }

    static func hash(descriptor: Int32, start: Int64, length: Int64) -> String? {
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)       // bounded: a megabyte at a time
        var offset = start
        var remaining = length
        while remaining > 0 {
            let want = Int(min(Int64(buffer.count), remaining))
            let n = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, want, off_t(offset)) }
            if n <= 0 { return nil }
            hasher.update(data: buffer.prefix(n))
            offset += Int64(n); remaining -= Int64(n)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The descriptor is closed on the delegate queue, behind any write that is already running there, so a write never lands on a number that has been closed and handed to another file.
    /// (`immediately` is for the one place that is certain no write can be running: assembly, when every piece is done.)
    private func closeFile(immediately: Bool = false) {
        let close: @Sendable () -> Void = { [self] in
            lock.lock(); let descriptor = fd; fd = -1; lock.unlock()
            if descriptor >= 0 { Darwin.close(descriptor) }
        }
        if immediately { close() } else { delegateQueue.addOperation(close) }
    }


    // MARK: Speed limit

    /// Accounts for bytes that arrived and, if the limit says to wait, stops this connection from being read until the wait is over. A suspended data task is not read from, so the
    /// sender is slowed by the connection itself (TCP's window fills) rather than by dropping data; nothing is buffered here beyond the one chunk that already arrived.
    /// The wait is taken in short slices, each checked against the limits as they are NOW, so a limit that is raised or removed takes effect within a slice, and a stopped run is never resumed.
    private func throttle(_ task: URLSessionDataTask, afterReceiving bytes: Int) {
        let wait = bandwidth.reserve(task: taskID, bytes: bytes)
        guard wait > 0.002 else { return }
        lock.lock()
        guard !stopped, active[task.taskIdentifier] != nil else { lock.unlock(); return }
        // Only the first chunk after a wait suspends the task: a task suspended twice would need two resumes. Data URLSession had already read keeps arriving while it waits; it is
        // all counted above, and the wait covers it.
        let first = throttled.insert(task.taskIdentifier).inserted
        lock.unlock()
        guard first else { return }
        task.suspend()
        wake(task, after: wait)
    }

    private func wake(_ task: URLSessionDataTask, after seconds: TimeInterval) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + min(max(seconds, 0.005), 0.25)) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let live = !self.stopped && self.active[task.taskIdentifier] != nil && self.throttled.contains(task.taskIdentifier)
            self.lock.unlock()
            guard live else { return }
            let remaining = self.bandwidth.remainingWait(task: self.taskID)
            if remaining > 0.002 { self.wake(task, after: remaining); return }
            self.lock.lock(); self.throttled.remove(task.taskIdentifier); self.lock.unlock()
            task.resume()
        }
    }

    /// The run is over (finished, failed, paused or cancelled): it no longer shares the overall limit.
    private func stopThrottling() {
        lock.lock(); throttled.removeAll(); lock.unlock()
        bandwidth.forget(task: taskID)
    }

    // MARK: Pause and cancel

    /// Stops every worker and keeps what is checkpointed. The pieces in flight are not trusted (they start again).
    @discardableResult
    func pause() -> Bool {
        lock.lock()
        guard !stopped, gate.allowsPause else { lock.unlock(); return false }
        stopped = true
        let tasks = active.values.map(\.task)
        let count = active.count
        active = [:]
        lock.unlock()
        for _ in 0..<count { budget.release(host: config.url.host ?? "", task: taskID) }; budget.release(task: taskID)
        tasks.forEach { $0.cancel() }
        stopThrottling()
        io.async { [self] in
            lock.lock(); let descriptor = fd; lock.unlock()
            if descriptor >= 0 { _ = fcntl(descriptor, F_FULLFSYNC) }
            closeFile()
            session.invalidateAndCancel()
            report(.paused(resumeData: MultipartRun.sentinel))
        }
        return true
    }

    /// Stops everything and removes this task's own working file and checkpoints. Late callbacks find nothing to act on.
    @discardableResult
    func cancel(keepPieces: Bool = false) -> Bool {
        lock.lock()
        // Too late once the file is being put in place: the download completes and is not reported cancelled.
        guard gate.cancel() else { lock.unlock(); return false }
        let wasStopped = stopped
        stopped = true
        let tasks = active.values.map(\.task)
        let count = active.count
        active = [:]
        pending = []
        lock.unlock()
        if !wasStopped { for _ in 0..<count { budget.release(host: config.url.host ?? "", task: taskID) }; budget.release(task: taskID) }
        tasks.forEach { $0.cancel() }
        stopThrottling()
        closeFile()
        session.invalidateAndCancel()
        io.async { [self] in
            try? FileManager.default.removeItem(at: workingURL)
            if !keepPieces { store?.deletePieces(task: taskID) }
        }
        return true
    }

    /// For tests: stops everything as a crash would, leaving the file and checkpoints as they are and telling no one.
    func abandon() {
        lock.lock()
        let wasStopped = stopped
        stopped = true
        let tasks = active.values.map(\.task)
        let count = active.count
        active = [:]
        lock.unlock()
        if !wasStopped { for _ in 0..<count { budget.release(host: config.url.host ?? "", task: taskID) }; budget.release(task: taskID) }
        tasks.forEach { $0.cancel() }
        stopThrottling()
        io.sync { }
        closeFile()
        session.invalidateAndCancel()
    }

    /// What is saved as a multipart download's "resume data": there is none in the URLSession sense, the pieces are the checkpoint. Nothing in it is sensitive.
    static let sentinel = Data("{\"engine\":\"multipart\",\"v\":1}".utf8)
    static func isSentinel(_ data: Data?) -> Bool { data == sentinel }

    var snapshot: (done: Int, total: Int, active: Int, doneBytes: Int64, networkBytes: Int64, limit: Int) {
        lock.lock(); defer { lock.unlock() }
        return (pieces.filter { $0.state == .done }.count, pieces.count, active.count, doneBytes, networkBytes, workerLimit)
    }
}

/// How many connections may be open at once, in total and to one host, across every download. Bounded by construction, and leased per task: a task that ends (however it ends)
/// gives back everything it held in one call, so a connection can neither leak nor be given back twice.
final class ConnectionBudget: ResourcePool, @unchecked Sendable {
    static let shared = ConnectionBudget()
    static let totalLimit = 16
    static let perHostLimit = 8
    static let poolName = "connections"

    var name: String { Self.poolName }

    private let lock = NSLock()
    private var total = 0
    private var hosts: [String: Int] = [:]
    /// What each task holds, by host.
    private var held: [UUID: [String: Int]] = [:]
    /// The owner each lease was granted to: what is given back is credited to this owner, whatever the registry says by then.
    private var leaseOwner: [UUID: UUID] = [:]
    /// What each owner (profile) holds, by host: its own per-website cap is counted against this.
    private var ownerHosts: [UUID: [String: Int]] = [:]
    var totalLimitOverride: Int?
    /// Each profile's own per-website cap. The process-wide `perHostLimit` is still the physical ceiling for everyone together.
    private var ownerCaps: [UUID: Int] = [:]
    /// The cap of the profile that owns tasks nobody has claimed (older callers and tests).
    var hostLimitOverride: Int? {
        get { lock.lock(); defer { lock.unlock() }; return ownerCaps[TransferOwnership.defaultOwner] }
        set { setHostLimit(newValue, owner: TransferOwnership.defaultOwner) }
    }
    func setHostLimit(_ limit: Int?, owner: UUID) { lock.lock(); ownerCaps[owner] = limit; lock.unlock() }
    func hostLimit(owner: UUID) -> Int { lock.lock(); defer { lock.unlock() }; return min(ownerCaps[owner] ?? Self.perHostLimit, Self.perHostLimit) }
    /// The holder for callers that have no task (older tests of the limits themselves).
    private static let anonymous = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))

    /// Both levels must have room: everyone together (total, and per website at the physical ceiling) and the owner's own cap for that website.
    private func fits(_ amount: Int, host: String, owner: UUID?) -> Bool {
        guard total + amount <= (totalLimitOverride ?? Self.totalLimit), hosts[host, default: 0] + amount <= min(Self.perHostLimit, ownerCaps[TransferOwnership.defaultOwner] ?? Self.perHostLimit) else { return false }          // (a cap set for unclaimed tasks counts everyone's connections, as it always did)
        guard let owner else { return true }
        let mine = ownerHosts[owner]?[host] ?? 0
        // The caps: this owner's own, and the one set for unclaimed tasks (`hostLimitOverride`), which a caller without a profile uses as a ceiling for everyone.
        return mine + amount <= min(ownerCaps[owner] ?? Self.perHostLimit, Self.perHostLimit)
    }

    // ResourcePool
    /// Advisory, with no task to ask about: true when any profile could take it. `grant` is the exact answer.
    func canGrant(_ amount: Int, scope: String?, task: UUID) -> Bool {
        let owner = TransferOwnership.shared.owner(of: task)
        lock.lock(); defer { lock.unlock() }
        return fits(amount, host: scope ?? "", owner: owner)
    }

    func canGrant(_ amount: Int, scope: String?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let host = scope ?? ""
        guard fits(amount, host: host, owner: nil) else { return false }
        let owners = Set(ownerHosts.keys).union(ownerCaps.keys)
        if owners.isEmpty { return true }
        return owners.contains { fits(amount, host: host, owner: $0) }
    }

    func grant(_ amount: Int, scope: String?, task: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let host = scope ?? ""
        let owner = leaseOwner[task] ?? TransferOwnership.shared.owner(of: task)
        guard amount > 0, fits(amount, host: host, owner: owner) else { return false }
        total += amount; hosts[host, default: 0] += amount; held[task, default: [:]][host, default: 0] += amount
        ownerHosts[owner, default: [:]][host, default: 0] += amount
        if leaseOwner[task] == nil { leaseOwner[task] = owner; TransferOwnership.shared.pin(task) }
        return true
    }

    private func give(back count: Int, host: String, task: UUID) {
        total = max(0, total - count)
        if let n = hosts[host], n > count { hosts[host] = n - count } else { hosts[host] = nil }
        let owner = leaseOwner[task] ?? TransferOwnership.shared.owner(of: task)
        if let n = ownerHosts[owner]?[host], n > count { ownerHosts[owner]?[host] = n - count } else { ownerHosts[owner]?[host] = nil; if ownerHosts[owner]?.isEmpty == true { ownerHosts[owner] = nil } }
    }

    func release(task: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard let mine = held.removeValue(forKey: task) else { return }
        for (host, count) in mine { give(back: count, host: host, task: task) }          // (the task keeps its owner: it may lease again, and its workers still ask on its behalf)
        leaseOwner[task] = nil; TransferOwnership.shared.unpin(task)
    }

    // One connection at a time, for a worker.
    func acquire(host: String, task: UUID) -> Bool { grant(1, scope: host, task: task) }

    func release(host: String, task: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard let count = held[task]?[host], count > 0 else { return }          // not held: nothing to give back (a repeated release is harmless)
        give(back: 1, host: host, task: task)
        if count > 1 { held[task]?[host] = count - 1 } else { held[task]?[host] = nil; if held[task]?.isEmpty == true { held[task] = nil; leaseOwner[task] = nil; TransferOwnership.shared.unpin(task) } }
    }

    func acquire(host: String) -> Bool { acquire(host: host, task: Self.anonymous) }
    func release(host: String) { release(host: host, task: Self.anonymous) }

    var open: Int { lock.lock(); defer { lock.unlock() }; return total }
    /// Who holds what right now (task, owner, connections), for diagnostics and the tests that check nothing is left behind.
    func holders() -> [(task: UUID, owner: UUID, connections: Int)] {
        lock.lock(); defer { lock.unlock() }
        return held.map { ($0.key, leaseOwner[$0.key] ?? TransferOwnership.defaultOwner, $0.value.values.reduce(0, +)) }
    }
    func holding(task: UUID) -> Int { lock.lock(); defer { lock.unlock() }; return held[task]?.values.reduce(0, +) ?? 0 }
    /// What one profile holds right now, for the details and the tests.
    func holding(owner: UUID) -> Int { lock.lock(); defer { lock.unlock() }; return ownerHosts[owner]?.values.reduce(0, +) ?? 0 }
}

private extension OperationQueue {
    /// Runs `block` on this queue after a delay (a timer that holds nothing alive but the closure).
    func schedule(after seconds: TimeInterval, _ block: @escaping @Sendable () -> Void) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, seconds)) { [weak self] in self?.addOperation(block) }
    }
}
