import Foundation

/// Connects the HTTP engine to the coordinator and the ledger. The coordinator owns the task (queue, state, files shown to the person); the engine owns the transfer; this turns what the
/// engine reports into the ledger events the Phase 1 state machine allows, and is the only place HTTP retry and recovery decisions are made. It keeps no state of its own about
/// a task beyond timers: the record is the truth.
@MainActor
final class HTTPDownloadRunner {
    struct Options {
        var origin: DownloadRequestOrigin = .user
        var headers: [String: String] = [:]
        var userAgent: String?
        var expectedSHA256: String?
        /// A name chosen by the caller; it is made safe like any other.
        var filename: String?
        /// Idle time allowed between bytes before the transfer is treated as timed out.
        var timeout: TimeInterval?
        /// This download's own speed limit, in bytes per second (on top of the overall one).
        var speedLimit: Int64?
        /// DX-12 (providers). Folders below the downloads folder (a collection's folder and the file's sub-folders), set before the file's place is chosen.
        var packageFolder: String?
        /// The size the service states; a file of another length is deleted, never kept.
        var expectedSize: Int64?
        /// The Accept header, saved with the task (it is not a secret) so a restart asks for the same thing (GitHub's private assets answer JSON without it).
        var accept: String?
        /// Fail a file that turns out to be only a Git LFS pointer.
        var lfsPointerGuard = false
        /// Who offered it (a provider's name), saved as a plain label.
        var provider: String?
    }

    private unowned let coordinator: DownloadCoordinator
    /// The same coordinator, weakly: background work started earlier checks it before touching `coordinator`, so a coordinator that was replaced (a profile switch) is not reached after it is gone.
    private weak var liveCoordinator: DownloadCoordinator?
    private var isAlive: Bool { liveCoordinator != nil }
    let engine: HTTPTransferEngine
    private let adapter = SinkAdapter()
    /// Tasks with a retry planned (waiting out its delay, or in line for a place). The timer and the place in line belong to the scheduler; this is only the list.
    private var retrying = Set<UUID>()
    private var pauseCallbacks: [UUID: (Data?) -> Void] = [:]
    private var checksumVerified = Set<UUID>()
    /// Running multipart downloads, by task.
    private var runs: [UUID: MultipartRun] = [:]
    /// How many connections a multipart download starts with (conservative; throttling only lowers it).
    var multipartConnections = MultipartPlanner.defaultConnections
    /// The adaptive controller's bound on workers per download (nil: none). New runs start within it and running ones are told.
    private(set) var adaptiveWorkerCeiling: Int?
    func setAdaptiveWorkerCeiling(_ ceiling: Int?) {
        guard ceiling != adaptiveWorkerCeiling else { return }
        adaptiveWorkerCeiling = ceiling
        for run in runs.values { run.setAdaptiveCeiling(ceiling) }
    }
    /// What each running multipart download's sources have delivered (bytes per second), by task.
    func sourceRates(_ id: UUID) -> [(tag: String, bytesPerSecond: Double, usable: Bool)]? { runs[id]?.sourceRates }

    private static let fallbackCodes = ["multipart:range-ignored", "multipart:wrong-range", "multipart:wrong-length", "multipart:encoded", "multipart:416", "multipart:plan", "multipart:too-long"]
    private static let restartCodes = ["multipart:changed-etag", "multipart:changed-date", "multipart:changed-size", "multipart:coverage", "multipart:size", "multipart:piece-corrupt"]

    init(coordinator: DownloadCoordinator, engine: HTTPTransferEngine = HTTPTransferEngine()) {
        self.coordinator = coordinator
        self.liveCoordinator = coordinator
        self.engine = engine
        adapter.runner = self
        coordinator.engines.register(engine)
    }

    private var ledger: DownloadLedger { coordinator.ledger }

    // MARK: Starting

    /// Starts a download of `url` and returns its task id. Throws (and creates nothing) when the address itself is refused.
    @discardableResult
    func start(url: URL, options: Options = Options()) async throws -> UUID {
        var policy = HTTPRequestPolicy(origin: options.origin, userAgent: options.userAgent)
        policy.requestTimeout = options.timeout ?? TimeInterval(coordinator.networkSettings.requestTimeout)          // this profile's own timeout
        try policy.requireAllowedOrigin()
        try policy.check(url)
        let (headers, dropped) = policy.sanitize(options.headers)
        if !dropped.isEmpty { coordinator.note("Left out request headers that downloads may not set: \(dropped.sorted().joined(separator: ", "))") }
        let provisional = options.filename.flatMap(DownloadFilename.sanitize) ?? DownloadFilename.derive(contentDisposition: nil, url: url).name
        let ticket = await coordinator.admitTicket(filename: provisional, source: url, protocolID: .http)
        coordinator.ledger.update(ticket.id) { $0.engineMetadata["origin"] = options.origin.rawValue; $0.engineMetadata["resolved"] = "1"; if options.filename != nil { $0.engineMetadata["nameSource"] = "user" }; if let sum = options.expectedSHA256 { $0.engineMetadata["sha256"] = sum.lowercased() }
            if let f = options.packageFolder, !f.isEmpty { $0.engineMetadata["packageFolder"] = f }
            if let n = options.expectedSize, n >= 0 { $0.engineMetadata["expectedSize"] = String(n) }
            if let a = options.accept, a.utf8.count <= 128 { $0.engineMetadata["accept"] = a }
            if options.lfsPointerGuard { $0.engineMetadata["pointerGuard"] = "1" }
            if let p = options.provider { $0.engineMetadata["provider"] = String(p.prefix(32)) } }
        if let limit = options.speedLimit { setSpeedLimit(ticket.id, bytesPerSecond: limit) }
        guard ticket.admitted else { return ticket.id }               // put off for later: it starts again from its record
        let id = ticket.id

        // What the server says about the file, if it will say.
        var name = provisional
        var total: Int64?
        var metadata: [String: String] = [:]
        var resolveError: HTTPDownloadError?
        var usedAccount = false
        // An account that applies but cannot be used stops the download with the reason: it is not sent without the credential (which would save a login page as the file), and no other account is tried.
        if case .refused(let why, _)? = coordinator.accountStore?.router.decide(url, origin: options.origin) {
            resolveError = HTTPDownloadError(info: DownloadFailureInfo(code: "account:\(why.rawValue)", reason: why.message, retryable: false))
        } else {
            do {
                let resolved = try await engine.resolve(DownloadSourceRequest(url: url, profile: ledger.profile, isPrivate: false, origin: options.origin))
                if options.filename == nil, let suggested = resolved.suggestedFilename { name = suggested }
                total = resolved.totalBytes
                metadata = resolved.metadata
                if case .use(let account, _)? = coordinator.accountStore?.router.decide(url, origin: options.origin) { coordinator.accountStore?.validated(account: account); usedAccount = true }
            } catch { resolveError = HTTPResponseRules.failure(for: error) }
        }
        if let resolveError { coordinator.accountCredentialRefused(for: url, code: resolveError.info.code, origin: options.origin) }

        // The person's choice for a name that is taken ("skip", or "ask") is honoured here as it is for a download WebKit makes.
        if await coordinator.askAboutDuplicate(suggestedName: name, sourceHost: url.host, source: url, isPrivate: false, taskID: id) { return id }
        let started = coordinator.begin(suggestedName: name, sourceHost: url.host, sourceURL: url, isPrivate: false, taskID: id, protocolID: .http,
                                        cancel: { [weak self] in self?.cancelTransfer(id) },
                                        suspend: { [weak self] done in self?.pauseTransfer(id, done: done) })
        if let resolveError, !resolveError.info.retryable {
            // The server has already said no (not found, forbidden, a refused redirect): it is not started, and the person is told why.
            coordinator.fail(id, source: url, error: resolveError, willRetry: false)
            return id
        }
        ledger.update(id) { record in
            if resolveError?.info.code == "http:429" { record.engineMetadata["rateLimited"] = "1" }          // (a plain label: lets a batch see that the service asked it to slow down)
            if usedAccount || record.engineMetadata["account"] == "1" { record.engineMetadata["account"] = "1" }          // (a flag only: no credential, no account name)
            record.engineMetadata.merge(DownloadEngineMetadata.validated(metadata)) { _, new in new }
            if let total { record.transfer.totalBytes = total }
        }
        engine.prepare(HTTPTransferRequest(url: url, policy: policy, headers: headers, destination: started.destination, expectedSHA256: options.expectedSHA256?.lowercased()), for: id)
        await launch(id, resumeData: nil)
        return id
    }

    /// Hands the task to the engine under its current attempt: in pieces when that has been shown to be safe, otherwise as one transfer.
    private func launch(_ id: UUID, resumeData: Data?) async {
        guard let record = ledger.record(id), record.state == .running || record.state == .resuming || record.state == .starting else { return }
        // Every way a transfer begins or continues (start, retry, resume, restart) comes through here, so this is where a download that used an account is held to it: if the account no
        // longer applies (disconnected, deleted, expired or needing sign-in again) it is stopped with the reason, never carried on without its credential. A website that answers an
        // anonymous request with a sign-in page would otherwise have that page saved as the file.
        if let url = record.source.asURL {
            let origin = DownloadRequestOrigin(rawValue: record.engineMetadata["origin"] ?? "") ?? .automation
            let decision = coordinator.accountStore?.router.decide(url, origin: origin) ?? .none
            if case .refused(let why, _) = decision {
                let error = HTTPDownloadError(info: DownloadFailureInfo(code: "account:\(why.rawValue)", reason: why.message, retryable: false))
                coordinator.accountCredentialRefused(for: url, code: error.info.code, origin: origin)
                failTransfer(id, error); return
            } else if record.engineMetadata["account"] == "1", case .none = decision {
                failTransfer(id, HTTPDownloadError(info: DownloadFailureInfo(code: "account:withdrawn", reason: "The account this download used was disconnected, so it was stopped. Add the address again to download it without the account.", retryable: false))); return
            } else if case .use = decision, record.engineMetadata["account"] != "1" {
                ledger.update(id) { $0.engineMetadata["account"] = "1" }          // (a flag only: no credential, no account name)
            }
        }
        let mode = record.engineMetadata["mode"]
        applyStoredSpeedLimit(id)
        if mode == "multipart" { await launchMultipart(id, resuming: true); return }
        // A download that has a speed limit is fetched through the data-task path (the only one that can be slowed) whenever the website allows ranges, even if "several pieces" is off:
        // then with one connection. Otherwise the system fetches it to a file, which cannot be slowed, and that is said in the list.
        let limited = BandwidthController.shared.effectiveLimit(for: id).map { $0.source != .adaptive } ?? false          // only a limit the person set: an adaptive ceiling is advice
        if mode == nil, resumeData == nil, coordinator.segmentedEnabled || limited, await considerMultipart(id, limited: limited) { return }
        coordinator.adaptive.startIfNeeded()
        do { try await engine.start(record, attempt: record.attempt, resumeData: resumeData, sink: adapter) }
        catch { failTransfer(id, HTTPResponseRules.failure(for: error)) }
    }

    // MARK: Speed limit

    /// Below this a limit is not worth routing a download through the range path: it would be over before the limit mattered.
    static let limitedMinimumTotal: Int64 = 64 << 10

    /// Sets (or with nil removes) one download's own speed limit. Saved with the task, so it survives a pause, a retry and a relaunch.
    func setSpeedLimit(_ id: UUID, bytesPerSecond: Int64?) {
        guard let state = ledger.record(id)?.state, !state.isFinal else { return }          // nothing to limit, and no limit to leave behind
        let limit = BandwidthController.valid(bytesPerSecond)
        ledger.update(id) { if let limit { $0.engineMetadata["speedLimit"] = String(limit) } else { $0.engineMetadata["speedLimit"] = nil } }
        BandwidthController.shared.setTaskLimit(limit, for: id)
    }

    private func applyStoredSpeedLimit(_ id: UUID) {
        guard let text = ledger.record(id)?.engineMetadata["speedLimit"], let value = Int64(text) else { return }
        if BandwidthController.shared.taskLimit(id) != BandwidthController.valid(value) { BandwidthController.shared.setTaskLimit(value, for: id) }
    }

    /// Whether a limit on this download would actually be kept, and if not why: stated plainly so the list never promises a speed it cannot hold.
    func bandwidthEnforcement(_ id: UUID) -> BandwidthEnforcement {
        guard let record = ledger.record(id) else { return .notEnforced(reason: "This download is not active.") }
        if (DownloadRequestOrigin(rawValue: record.engineMetadata["origin"] ?? "") ?? .automation) != .user { return .notEnforced(reason: "Only downloads you start yourself can be slowed.") }
        if record.protocolID != .http { return .notEnforced(reason: "Downloads started from a web page use the browser's own connection, which cannot be slowed.") }
        let mode = record.engineMetadata["mode"]
        if runs[id] != nil || mode == "multipart" { return .enforced }
        if mode == "single" {
            if let why = record.engineMetadata["multipartRefused"] { return .notEnforced(reason: "The website does not allow the file to be fetched in parts (\(why)), so its speed cannot be limited.") }
            return .notEnforced(reason: "This download is fetched as one transfer by the system, which cannot be slowed. A limit applies to downloads that start after it is set, when the website allows ranges.")
        }
        return .enforced          // not yet started: it will be routed so that the limit holds, if the website allows it
    }

    // MARK: Multipart

    /// Whether this task can be fetched in pieces, decided from a real range request and never from a header's claim. True when it has been started that way.
    private func considerMultipart(_ id: UUID, limited: Bool = false) async -> Bool {
        let floor = limited ? Self.limitedMinimumTotal : MultipartPlanner.minimumTotal
        guard let record = ledger.record(id), let request = engine.request(for: id), (record.transfer.totalBytes ?? 0) >= floor else {
            if let record = ledger.record(id) { ledger.update(id) { $0.engineMetadata["mode"] = "single" }; _ = record }
            return false
        }
        do {
            let started = ContinuousClock.now
            let probe = try await engine.rangeProbe(request.url, policy: request.policy)
            let took = started.duration(to: .now)
            let seconds = Double(took.components.seconds) + Double(took.components.attoseconds) / 1e18
            switch MultipartEligibility.evaluate(origin: request.policy.origin, status: probe.status, headers: { probe.headers[$0.lowercased()] }, minimumTotal: floor) {
            case .failure(let why):
                ledger.update(id) { $0.engineMetadata["mode"] = "single"; $0.engineMetadata["multipartRefused"] = String(why.rawValue.prefix(200)) }
                coordinator.note("Fetching \(record.file.filename) as one transfer: \(why.rawValue)")
                return false
            case .success(let eligible) where !limited && MultipartPlanner.isCounterproductive(probeSeconds: seconds, total: eligible.total):
                ledger.update(id) { $0.engineMetadata["mode"] = "single"; $0.engineMetadata["multipartRefused"] = "slow-first-answer" }
                coordinator.note("Fetching \(record.file.filename) as one transfer: the website is slow to answer, so extra connections would not help")
                return false
            case .success(let eligible):
                ledger.update(id) { r in
                    r.engineMetadata["mode"] = "multipart"
                    r.engineMetadata["etag"] = eligible.etag
                    r.engineMetadata["lastModified"] = eligible.lastModified
                    r.transfer.totalBytes = eligible.total
                }
                await launchMultipart(id, resuming: false)
                return true
            }
        } catch {
            // A download with a speed limit must not quietly become an unlimited one because a probe failed: it fails the ordinary way, and is retried.
            if limited { failTransfer(id, HTTPResponseRules.failure(for: error)); return true }
            ledger.update(id) { $0.engineMetadata["mode"] = "single" }
            return false
        }
    }

    /// Starts, or carries on, a multipart run from the pieces that are saved. The resource is checked again first: if it is not the one the saved pieces came from, they are dropped.
    private func launchMultipart(_ id: UUID, resuming: Bool) async {
        guard var record = ledger.record(id), let url = record.source.asURL, let path = record.file.destinationPath, let total = record.transfer.totalBytes else { fallBackToSingle(id, reason: "the saved details were not complete"); return }
        let request = engine.request(for: id) ?? HTTPTransferRequest(url: url, policy: HTTPRequestPolicy(origin: DownloadRequestOrigin(rawValue: record.engineMetadata["origin"] ?? "") ?? .automation),
                                                                    headers: [:], destination: URL(fileURLWithPath: path), expectedSHA256: record.engineMetadata["sha256"])
        if resuming {
            // Is it still the same file? A different size or version tag makes the saved pieces worthless.
            do {
                let probe = try await engine.rangeProbe(request.url, policy: request.policy)
                switch MultipartEligibility.evaluate(origin: request.policy.origin, status: probe.status, headers: { probe.headers[$0.lowercased()] }, minimumTotal: 1) {
                case .failure(let why): fallBackToSingle(id, reason: why.rawValue); return
                case .success(let now):
                    let knownTag = record.engineMetadata["etag"], knownDate = record.engineMetadata["lastModified"]
                    let changed = now.total != total || (knownTag != nil && now.etag != knownTag) || (knownTag == nil && knownDate != nil && now.lastModified != knownDate)
                    if changed {
                        coordinator.note("\(record.file.filename) changed on the website, so the download starts over")
                        ledger.store?.deletePieces(task: id)
                        try? FileManager.default.removeItem(at: MultipartRun.workingURL(for: id, in: URL(fileURLWithPath: path).deletingLastPathComponent()))
                        ledger.update(id) { $0.transfer.totalBytes = now.total; $0.transfer.completedBytes = 0; $0.engineMetadata["etag"] = now.etag; $0.engineMetadata["lastModified"] = now.lastModified }
                        record = ledger.record(id) ?? record
                    }
                }
            } catch {
                // A refusal by policy is permanent: nothing fetched so far could ever be used, so it does not stay behind.
                if error is HTTPRequestPolicy.Refusal { discardMultipartFiles(id) }
                failTransfer(id, HTTPResponseRules.failure(for: error)); return
            }
        }
        guard let current = ledger.record(id) else { return }
        let total2 = current.transfer.totalBytes ?? total
        var configuration = MultipartRun.Configuration(url: request.url, policy: request.policy, headers: request.headers, destination: URL(fileURLWithPath: path), total: total2,
                                                       etag: current.engineMetadata["etag"], lastModified: current.engineMetadata["lastModified"],
                                                       connections: MultipartPlanner.connections(total: total2, configured: coordinator.segmentedEnabled ? multipartConnections : 1),
                                                       network: engine.currentNetwork)
        if !configuration.headers.keys.contains(where: { $0.lowercased() == "authorization" }) { configuration.headers.merge(engine.accountHeaders(for: request.url, origin: request.policy.origin)) { a, _ in a } }
        configuration.mirrors = await vettedMirrors(id, request: request, total: total2)
        configuration.onTransient = { [weak coordinator] in Task { @MainActor in coordinator?.adaptive.noteTransient() } }
        // Vetting asks other websites questions and takes a while: the person may have paused or cancelled meanwhile, and then nothing is started.
        guard let live = ledger.record(id), [.running, .starting, .resuming].contains(live.state) else { return }
        // The one connection the scheduler leased at admission is given back: the run asks the same budget for each of its own workers, and must not be counted twice.
        coordinator.scheduler.release(task: id)
        let run = MultipartRun(taskID: id, attempt: current.attempt, configuration: configuration, sink: adapter, store: ledger.store, budget: .shared)
        run.setAdaptiveCeiling(adaptiveWorkerCeiling)          // a bound that can be lifted later; the run itself starts at its full number
        runs[id] = run
        coordinator.adaptive.startIfNeeded()          // adaptive control looks only while something moves
        engine.prepare(request, for: id)
        // Resumable from its pieces from the first byte: a crash leaves the task listed with a Resume button, not lost.
        ledger.update(id) { $0.transfer.resumeAvailable = true }
        ledger.saveResumeData(id, MultipartRun.sentinel)
        do {
            switch try run.start() {
            case .restarted(let reason):
                // The saved parts were not usable, so the figure starts again from nothing (the one case, with a changed file, where it may fall).
                ledger.update(id) { $0.transfer.completedBytes = 0 }
                if !reason.isEmpty { coordinator.note("\(current.file.filename) starts over: \(reason)") }
            case .started: break
            }
        } catch {
            runs[id] = nil
            failTransfer(id, HTTPResponseRules.failure(for: error))
        }
    }

    /// The mirrors this run may use together with the first source, and only if the task qualifies (see `MirrorStore.canCombine`). Each is asked, with the task's own origin and policy,
    /// for its destination (name and, at connection time, address), whether it answers byte ranges correctly and whether it is the same size; one that is not is marked unusable and left out.
    private func vettedMirrors(_ id: UUID, request: HTTPTransferRequest, total: Int64) async -> [MultipartRun.Mirror] {
        guard coordinator.mirrors.canCombine(id) else { return [] }
        var seeds: [MultipartRun.Mirror] = []
        for mirror in coordinator.mirrors.usable(for: id).prefix(7) {
            guard let url = URL(string: mirror.url) else { continue }
            // A source that has become the task's own address (after a failover) is not also a mirror of itself.
            if LinkClassifier.normalizedKey(url) == LinkClassifier.normalizedKey(request.url) { continue }
            do {
                try await request.policy.checkResolving(url)
                let probe = try await engine.rangeProbe(url, policy: request.policy, withAccount: false)          // another website listed as a mirror is asked as a stranger: an account is not used at a website a server named
                switch MultipartEligibility.evaluate(origin: request.policy.origin, status: probe.status, headers: { probe.headers[$0.lowercased()] }, minimumTotal: 1) {
                case .failure(let why): coordinator.mirrors.setState(mirror.id, in: id, .bad(why.rawValue)); continue
                case .success(let eligible):
                    guard eligible.total == total else { coordinator.mirrors.setState(mirror.id, in: id, .bad("It is a different size.")); continue }
                    seeds.append(MultipartRun.Mirror(tag: mirror.id.uuidString, url: url, etag: eligible.etag, lastModified: eligible.lastModified))
                    coordinator.mirrors.setState(mirror.id, in: id, .inUse)
                }
            } catch { coordinator.mirrors.setState(mirror.id, in: id, .bad(HTTPResponseRules.failure(for: error).info.reason)) }
        }
        return seeds
    }

    /// Gives up on pieces for this task and carries on as one transfer: the same task, a new attempt. What was fetched in pieces is not reused.
    /// Removes this task's own working file and saved pieces (whether or not a run object exists: after a restart there is none).
    private func discardMultipartFiles(_ id: UUID) {
        ledger.store?.deletePieces(task: id)
        if let path = ledger.record(id)?.file.destinationPath {
            try? FileManager.default.removeItem(at: MultipartRun.workingURL(for: id, in: URL(fileURLWithPath: path).deletingLastPathComponent()))
        }
    }

    private func fallBackToSingle(_ id: UUID, reason: String) {
        guard let record = ledger.record(id), !record.state.isFinal else { return }
        runs.removeValue(forKey: id)?.cancel()
        discardMultipartFiles(id)
        // Back to one transfer: it holds one connection again, from the same budget.
        coordinator.scheduler.release(task: id)          // whatever it held, once; then the one connection a single transfer uses
        _ = ConnectionBudget.shared.grant(1, scope: record.source.asURL?.host, task: id)
        coordinator.note("Fetching \(record.file.filename) as one transfer: \(reason)")
        ledger.update(id) { $0.engineMetadata["mode"] = "single"; $0.engineMetadata["multipartRefused"] = String(reason.prefix(200)); $0.transfer.completedBytes = 0; $0.transfer.resumeAvailable = false }
        ledger.saveResumeData(id, nil)
        guard ledger.apply(.retryPlanned, to: id) != nil, ledger.apply(.queued, to: id) != nil, ledger.apply(.started, to: id) != nil, ledger.apply(.running, to: id) != nil else { return }
        Task { @MainActor in await launch(id, resumeData: nil) }
    }

    // MARK: Controls the coordinator calls

    /// Carries on from resume data, under the same task and a new attempt. (The coordinator has already made the move to `resuming`.)
    func resume(_ id: UUID, data: Data) {
        Task { @MainActor in
            await launch(id, resumeData: MultipartRun.isSentinel(data) ? nil : data)
            ledger.apply(.resumed, to: id)
            if ledger.record(id)?.engineMetadata["mode"] == "multipart" { ledger.update(id) { $0.transfer.resumeAvailable = true }; ledger.saveResumeData(id, MultipartRun.sentinel) }
        }
    }

    /// A task that was put off, or found part-way, started again from its address (no resume data): the same task, a new attempt.
    func restart(_ id: UUID, url replacement: URL? = nil) {
        guard let record = ledger.record(id), let url = replacement ?? record.source.asURL else { return }
        if let replacement { ledger.update(id) { $0.source = DownloadSourceRef(url: replacement) } }
        Task { @MainActor in
            guard isAlive else { return }
            _ = await restartTransfer(id, url: url, from: record)
        }
    }

    @discardableResult
    private func restartTransfer(_ id: UUID, url: URL, from record: DownloadTaskRecord) async -> Bool {
        coordinator.reserveTaskID(id, for: url)                         // admitted under its own id, not a new one
        let ticket = await coordinator.admitTicket(filename: record.file.filename, source: url, protocolID: .http)
        guard ticket.admitted else { return false }
        // Who asked comes from the record (saved with the task), and a task with no record of it is the least trusted kind: never the most.
        let origin = DownloadRequestOrigin(rawValue: record.engineMetadata["origin"] ?? "") ?? .automation
        // A task that was only given an address (Add Download, a schedule) has not yet asked the server what the file is called and how large it is. It does so now, through the same
        // resolve step (and so the same request policy) as a download started directly; the person's own name, if they gave one, is never replaced.
        var name = record.file.filename
        var total: Int64?
        var metadata: [String: String] = [:]
        var resolveError: HTTPDownloadError?
        var usedAccount = false
        // An account that applies but cannot be used stops the download with the reason (never sent anonymously, never with another account).
        let decision = coordinator.accountStore?.router.decide(url, origin: origin) ?? .none
        if case .refused(let why, _) = decision {
            resolveError = HTTPDownloadError(info: DownloadFailureInfo(code: "account:\(why.rawValue)", reason: why.message, retryable: false))
        } else if record.engineMetadata["account"] == "1", case .none = decision {
            // It was started with an account that has since been disconnected or deleted: it is not carried on anonymously.
            resolveError = HTTPDownloadError(info: DownloadFailureInfo(code: "account:withdrawn", reason: "The account this download used was disconnected, so it was stopped. Add the address again to download it without the account.", retryable: false))
        } else if isKnownCorrupt(url, task: id) {
            resolveError = HTTPDownloadError(info: DownloadFailureInfo(code: "http:known-corrupt", reason: "This source already gave a file that did not match the checksum, so it is not used again. Add another source for this download.", retryable: false))
        } else if record.engineMetadata["resolved"] != "1" {
            do {
                let resolved = try await engine.resolve(DownloadSourceRequest(url: url, profile: ledger.profile, isPrivate: false, origin: origin))
                if record.engineMetadata["nameSource"] != "user", let suggested = resolved.suggestedFilename { name = suggested }
                total = resolved.totalBytes
                metadata = resolved.metadata
                if case .use(let account, _) = decision { coordinator.accountStore?.validated(account: account); usedAccount = true }
            } catch { resolveError = HTTPResponseRules.failure(for: error) }
        }
        if let resolveError { coordinator.accountCredentialRefused(for: url, code: resolveError.info.code, origin: origin) }
        if await coordinator.askAboutDuplicate(suggestedName: name, sourceHost: url.host, source: url, isPrivate: false, taskID: id) { return false }
        let started = coordinator.begin(suggestedName: name, sourceHost: url.host, sourceURL: url, isPrivate: false, taskID: id, protocolID: .http,
                                        cancel: { [weak self] in self?.cancelTransfer(id) }, suspend: { [weak self] done in self?.pauseTransfer(id, done: done) })
        if let resolveError, !resolveError.info.retryable {
            if tryNextSource(id, after: resolveError, url: url) { return false }
            coordinator.fail(id, source: url, error: resolveError, willRetry: false)
            return false
        }
        ledger.update(id) { record in
            if usedAccount { record.engineMetadata["account"] = "1" }
            record.transfer.completedBytes = 0; record.transfer.resumeAvailable = false
            if !metadata.isEmpty || total != nil { record.engineMetadata["resolved"] = "1" }
            record.engineMetadata.merge(DownloadEngineMetadata.validated(metadata)) { _, new in new }
            if let total { record.transfer.totalBytes = total }
        }
        let request = engine.request(for: id)
        engine.prepare(HTTPTransferRequest(url: url, policy: request?.policy ?? HTTPRequestPolicy(origin: origin), headers: request?.headers ?? [:], destination: started.destination,
                                           expectedSHA256: request?.expectedSHA256 ?? record.engineMetadata["sha256"]), for: id)
        await launch(id, resumeData: nil)
        return true
    }

    func pauseTransferPublic(_ id: UUID, done: @escaping (Data?) -> Void) { pauseTransfer(id, done: done) }

    private func pauseTransfer(_ id: UUID, done: @escaping (Data?) -> Void) {
        guard let record = ledger.record(id) else { done(nil); return }
        // A second request while one is waiting is answered together with it, never in place of it.
        if let waiting = pauseCallbacks[id] { pauseCallbacks[id] = { data in waiting(data); done(data) } } else { pauseCallbacks[id] = done }
        if let run = runs[id] {
            // Too late to pause once the file is being put in place: the download completes, and the caller is told so (it checks `isPastFinalisation` before treating that as a failure).
            if !run.pause() { pauseCallbacks.removeValue(forKey: id)?(nil) }
            return
        }
        Task { @MainActor in
            do { try await engine.pause(task: id, attempt: record.attempt) }
            catch { pauseCallbacks.removeValue(forKey: id)?(nil) }
        }
    }

    func cancelTransferPublic(_ id: UUID) { cancelTransfer(id) }

    /// Asks for the transfer to be cancelled, atomically against its file being put in place. False means it is too late (the download completes); the caller must then neither
    /// mark it cancelled nor remove its file.
    func requestCancel(_ id: UUID) -> Bool {
        if isPastFinalisation(id) { return false }
        if let run = runs[id] { return run.gate.cancel() }
        return engine.cancelIfPossible(task: id)
    }

    /// Tasks whose file is in place and whose completion has not been recorded yet (the checksum may still be read). A cancel in this window is too late, whichever engine ran it.
    var finishing = Set<UUID>()

    /// True once the file is being, or has been, put in place and the task has not yet been recorded as finished.
    func isPastFinalisation(_ id: UUID) -> Bool {
        finishing.contains(id) || runs[id]?.gate.phase == .finalising || engine.isFinalising(task: id)
    }

    private func cancelTransfer(_ id: UUID) {
        BandwidthController.shared.discard(task: id)
        cancelRetry(id)
        runs.removeValue(forKey: id)?.cancel()
        discardMultipartFiles(id)
        pauseCallbacks[id] = nil
        checksumVerified.remove(id)
        Task { await engine.cancel(task: id, attempt: -1) }
    }

    /// Whether pausing would keep the download's place: false once the server has shown it cannot continue one.
    func canPause(_ id: UUID) -> Bool { runs[id] != nil || engine.isResumable(task: id) != false }

    /// For tests: the process dies here. Nothing is reported, saved or deleted.
    func simulateCrash(_ id: UUID) {
        runs.removeValue(forKey: id)?.abandon()
        cancelRetry(id)
        engine.forget(task: id)
    }

    /// A running multipart download's counters (for tests and diagnostics).
    func multipartSnapshot(_ id: UUID) -> (done: Int, total: Int, active: Int, doneBytes: Int64, networkBytes: Int64, limit: Int)? { runs[id]?.snapshot }

    // MARK: What the engine reports

    fileprivate func handle(_ report: DownloadEngineReport, task id: UUID, attempt: Int) {
        // A report from an earlier attempt, or for a task that is over, changes nothing.
        guard let record = ledger.record(id), record.attempt == attempt, !record.state.isFinal, record.state != .failed else { return }
        switch report {
        case .running:
            break
        case .progress(let reported, let total):
            // What is shown never goes backwards while the same bytes are still wanted: a resumed run starts by reporting only the parts that are safely on disk, which is less than
            // the bar already showed (it included parts that were half-way). A deliberate start-over sets the saved figure to zero first (see `startOver`), and that is what lets it fall.
            let completed = max(reported, record.transfer.completedBytes)
            let fraction = total.map { $0 > 0 ? min(0.99, Double(completed) / Double($0)) : 0 } ?? 0       // never 100% before the file is in place
            coordinator.update(id, fraction: fraction, completed: completed, total: total ?? 0)
        case .metadata(let meta):
            if let finalPath = meta["finalPath"] { coordinator.updateDestination(id, to: URL(fileURLWithPath: finalPath)) }
            if meta["suspiciousName"] == "1" { coordinator.note("\(record.file.filename) looks like a document but ends in something that runs; it was saved as the website named it") }
            ledger.update(id) { $0.engineMetadata.merge(DownloadEngineMetadata.validated(meta.filter { $0.key != "finalPath" })) { _, new in new } }
            if meta["sources"] != nil { coordinator.mirrors.apply(meta, to: id) }
        case .paused(let data):
            if let done = pauseCallbacks.removeValue(forKey: id) { done(data) }
            else if let data, !data.isEmpty { coordinator.interrupt(id, resumeData: data, source: record.source.asURL) }
        case .finishedTransfer:
            BandwidthController.shared.discard(task: id)
            finishing.insert(id)
            runs[id] = nil
            // A pause that was asked for as the last byte arrived is answered by the completion: its caller is told, and knows from `isPastFinalisation` that nothing failed.
            pauseCallbacks.removeValue(forKey: id)?(nil)
            finishTransfer(id)
        case .failed(let info, let data, let retryAfter):
            var error = HTTPDownloadError(info: info, retryAfter: retryAfter)
            if info.code.hasPrefix(HTTPFailureCode.restartFromZero) { error.restartFromZero = true }
            if runs[id] != nil {
                let bare = info.code.replacingOccurrences(of: HTTPFailureCode.restartFromZero + ":", with: "")
                // The run has already stopped itself; it is dropped, and for a fallback its working file and pieces go with it (cancel removes this task's own files only).
                if Self.fallbackCodes.contains(bare) { fallBackToSingle(id, reason: info.reason); return }
                runs[id] = nil
                if Self.restartCodes.contains(bare) {
                    // The file changed or did not check out: the pieces are dropped. The first time pieces are tried again from nothing; after that, one transfer.
                    let restarts = Int(record.engineMetadata["multipartRestarts"] ?? "0") ?? 0
                    ledger.store?.deletePieces(task: id)
                    try? FileManager.default.removeItem(at: MultipartRun.workingURL(for: id, in: URL(fileURLWithPath: record.file.destinationPath ?? "/").deletingLastPathComponent()))
                    if restarts >= 1 { fallBackToSingle(id, reason: info.reason); return }
                    ledger.update(id) { $0.engineMetadata["multipartRestarts"] = "\(restarts + 1)"; $0.transfer.completedBytes = 0 }          // a start-over: the bar may fall
                    error.restartFromZero = true
                } else if !error.info.retryable {
                    discardMultipartFiles(id)           // it cannot continue, so nothing is left behind
                }
            }
            failTransfer(id, error, resumeData: data)
        }
    }

    /// Whether the file is a Git LFS pointer (under 1 KiB, starting with the spec line).
    nonisolated static func isLFSPointer(atPath path: String) -> Bool {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64, size > 0, size < 1024, let h = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? h.close() }
        let head = String(decoding: (try? h.read(upToCount: 64)) ?? Data(), as: UTF8.self)
        return head.hasPrefix("version https://git-lfs.github.com/spec/")
    }

    private func finishTransfer(_ id: UUID) {
        guard let record = ledger.record(id) else { return }
        Task { @MainActor in
            let integrity = (try? await engine.verify(record)) ?? .unknown
            // A size the Metalink file promised: a file of another length is not the file.
            if let promised = record.engineMetadata["expectedSize"].flatMap(Int64.init), let path = record.file.destinationPath,
               let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64, size != promised {
                if DownloadPathPolicy.isAuthorized(path, roots: coordinator.managedRoots) { try? FileManager.default.removeItem(atPath: path) }
                coordinator.fail(id, source: record.source.asURL, error: HTTPDownloadError(info: DownloadFailureInfo(code: "http:size", reason: "The file is not the length the source stated, so it was deleted.", retryable: false)), willRetry: false)
                engine.forget(task: id); finishing.remove(id)
                return
            }
            // A Git LFS pointer is a few lines of text standing in for the real file. Saved as the file it would look complete; it is refused.
            if record.engineMetadata["pointerGuard"] == "1", let path = record.file.destinationPath, Self.isLFSPointer(atPath: path) {
                if DownloadPathPolicy.isAuthorized(path, roots: coordinator.managedRoots) { try? FileManager.default.removeItem(atPath: path) }
                coordinator.fail(id, source: record.source.asURL, error: HTTPDownloadError(info: DownloadFailureInfo(code: "http:lfs-pointer", reason: "The service sent a Git LFS pointer instead of the file, so nothing was kept.", retryable: false)), willRetry: false)
                engine.forget(task: id); finishing.remove(id)
                return
            }
            if integrity == .mismatch, engine.request(for: id)?.expectedSHA256 != nil, coordinator.mirrors.bytesFromMirrors(id) > 0 {
                // Several sources were combined and the whole does not match: which one gave wrong bytes is not known, so none of the others is trusted. The file is deleted and fetched
                // again from its first source alone.
                if let path = record.file.destinationPath, DownloadPathPolicy.isAuthorized(path, roots: coordinator.managedRoots) { try? FileManager.default.removeItem(atPath: path) }
                ledger.update(id) { $0.engineMetadata["mirrorsDisabled"] = "1" }
                coordinator.mirrors.clearContribution(id)
                for m in coordinator.mirrors.usable(for: id) { coordinator.mirrors.setState(m.id, in: id, .bad("The file made from several sources did not match its checksum.")) }
                coordinator.note("\(record.file.filename) did not match its checksum when made from several sources; fetching it again from one")
                engine.forget(task: id); finishing.remove(id)
                failTransfer(id, HTTPDownloadError(info: DownloadFailureInfo(code: "http:checksum-sources", reason: "The file made from several sources did not match its checksum.", retryable: true), restartFromZero: true))
                return
            }
            if integrity == .mismatch, engine.request(for: id)?.expectedSHA256 != nil {
                // A file that is not the one the person was promised is not kept beside genuine downloads.
                if let path = record.file.destinationPath, DownloadPathPolicy.isAuthorized(path, roots: coordinator.managedRoots) { try? FileManager.default.removeItem(atPath: path) }
                let wrong = HTTPDownloadError(info: DownloadFailureInfo(code: "http:checksum", reason: "The file does not match the checksum that was given, so it was deleted.", retryable: false))
                // This source gave the wrong file: it is not asked for this task again (an automatic retry or a Try Again would only fetch the same wrong bytes). Another source the person
                // gave is tried from the start; the checksum still has to match, whichever source it comes from.
                markCorrupt(record.source.asURL, task: id)
                engine.forget(task: id); finishing.remove(id)
                if tryNextSource(id, after: wrong, url: record.source.asURL) { return }
                coordinator.fail(id, source: record.source.asURL, error: wrong, willRetry: false)
                return
            }
            if integrity == .verified, engine.request(for: id)?.expectedSHA256 != nil { checksumVerified.insert(id) }
            // A task started from an address alone (no earlier look at the server) may never have learned its size: the finished file is the truth, so the record is not left saying 0.
            var inventedTotal = false
            if (ledger.record(id)?.transfer.totalBytes ?? 0) <= 0, let path = record.file.destinationPath, let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int, size > 0 {
                ledger.update(id) { $0.transfer.totalBytes = Int64(size) }
                inventedTotal = true
            }
            // A total taken from the finished file itself proves nothing about the file: comparing the file with its own size would say "verified" when there was nothing to compare it against.
            coordinator.finish(id, source: record.source.asURL, integrity: inventedTotal ? DownloadIntegrity.unknown : nil)
            if checksumVerified.remove(id) != nil { ledger.update(id) { $0.file.integrity = .verified } }
            engine.forget(task: id)
            finishing.remove(id)
        }
    }

    private func failTransfer(_ id: UUID, _ error: HTTPDownloadError, resumeData: Data? = nil) {
        guard let record = ledger.record(id), !record.state.isFinal else { return }
        let url = record.source.asURL
        // Transient, and not tried too often: the same task is tried again after a wait (never a new task, never a retry storm).
        if let url = record.source.asURL { coordinator.accountCredentialRefused(for: url, code: error.info.code, origin: DownloadRequestOrigin(rawValue: record.engineMetadata["origin"] ?? "") ?? .automation, startedAt: record.createdAt) }
        if error.info.retryable, ledger.record(id)?.engineMetadata["mode"] != "multipart" { coordinator.adaptive.noteTransient() }          // (a multipart run counts its own pieces)
        if HTTPRetrySchedule.mayRetry(error, attempt: record.retryCount + 1, max: coordinator.networkSettings.maxAutomaticRetries + 1) {
            let keepsPlace = ((resumeData?.isEmpty == false) || record.engineMetadata["mode"] == "multipart") && !error.restartFromZero
            guard ledger.apply(.retryPlanned, to: id, resumeData: keepsPlace ? .some(resumeData) : .some(nil)) != nil else { return }
            let delay = HTTPRetrySchedule.delay(afterAttempt: record.retryCount + 1, retryAfter: error.retryAfter)
            coordinator.note("Will try \(record.file.filename) again in \(Int(delay)) seconds: \(error.info.reason)")
            // The wait is the scheduler's single timer for this task. While it waits the task gives its place and its connection back; when the time comes it queues again, in rank,
            // like any other start (so a burst of failures cannot all come back at once past the limit).
            let scheduler = coordinator.scheduler!
            scheduler.release(task: id)
            let due = scheduler.clock.now.addingTimeInterval(delay)
            ledger.update(id) { $0.retryAt = due }
            retrying.insert(id)
            scheduler.schedule(id, due: due, maxWait: DownloadScheduler.maxRetryWait) { [weak self] in self?.retryIsDue(id, keepsPlace: keepsPlace) }
            // A retry with no registered deadline would wait forever, shown as "will try again". Never leave it that way.
            if !scheduler.isScheduled(id) { strandedRetry(id, why: "Browser Setu could not schedule another try.") }
            return
        }
        if tryNextSource(id, after: error, url: url) { return }
        // Stopped for good, and said so; the address is redacted wherever it is mentioned.
        coordinator.note("Failed \(record.file.filename) (\(error.info.code)) from \(DownloadURLRedactor.redact(url))")
        coordinator.fail(id, source: url, error: error, willRetry: false)
        engine.forget(task: id)
    }

    // MARK: Sources found to give the wrong file

    private static let corruptKey = "corruptSources"

    /// Remembers, for this task only, that this address gave a file that failed the checksum.
    private func markCorrupt(_ url: URL?, task id: UUID) {
        guard let url else { return }
        let key = LinkClassifier.normalizedKey(url)
        ledger.update(id) { record in
            var keys = Set((record.engineMetadata[Self.corruptKey] ?? "").split(separator: "\n").map(String.init))
            keys.insert(key)
            record.engineMetadata[Self.corruptKey] = keys.sorted().joined(separator: "\n")
        }
    }

    /// True when this address already failed the checksum for this task, and the checksum is still being asked for.
    private func isKnownCorrupt(_ url: URL, task id: UUID) -> Bool {
        guard let record = ledger.record(id), record.engineMetadata["sha256"] != nil, let list = record.engineMetadata[Self.corruptKey] else { return false }
        return list.split(separator: "\n").contains { String($0) == LinkClassifier.normalizedKey(url) }
    }

    /// This source is finished with. If the person gave another, it is tried from the start (never mixed with what this one gave): the same task, the same origin.
    @discardableResult
    private func tryNextSource(_ id: UUID, after error: HTTPDownloadError, url: URL?) -> Bool {
        guard let next = coordinator.mirrors.takeNextForFailover(id), let nextURL = URL(string: next.url) else { return false }
        discardMultipartFiles(id)
        let name = ledger.record(id)?.file.filename ?? "A download"
        coordinator.note("\(name): trying another source")
        coordinator.fail(id, source: url, error: error, willRetry: false)
        ledger.update(id) { $0.source = DownloadSourceRef(url: nextURL); $0.transfer.completedBytes = 0; $0.transfer.resumeAvailable = false; $0.engineMetadata["mode"] = nil; $0.engineMetadata["etag"] = nil; $0.engineMetadata["lastModified"] = nil; $0.engineMetadata["resolved"] = nil
            $0.engineMetadata["account"] = nil }          // the next source is judged by its own accounts (an account belongs to one website, never to the task)
        engine.forget(task: id)
        coordinator.retryFailure(id)
        return true
    }

    /// The delay is over. The task joins the line again; it starts when a place and its connection are free, not before.
    private func retryIsDue(_ id: UUID, keepsPlace: Bool) {
        guard retrying.contains(id), let record = ledger.record(id), record.state == .retrying else { retrying.remove(id); return }
        let source = record.source.asURL
        coordinator.scheduler.enqueue(id: id, kind: .retry, filename: record.file.filename, priority: record.priority, need: coordinator.need(for: .http, source: source), source: source,
                                      enqueuedAt: coordinator.scheduler.clock.now) { [weak self] in self?.beginRetry(id, keepsPlace: keepsPlace) }
    }

    /// The retry has its place. The state change that makes it occupy that place happens here, before anything else can start, and the transfer itself follows.
    func beginRetry(_ id: UUID, keepsPlace: Bool) {
        retrying.remove(id)
        guard let record = ledger.record(id), record.state == .retrying else { coordinator.scheduler.release(task: id); return }
        let data = keepsPlace ? ledger.resumeData(for: id) : nil
        guard ledger.apply(.queued, to: id) != nil, ledger.apply(.started, to: id) != nil, ledger.apply(.running, to: id) != nil else {
            coordinator.scheduler.release(task: id)
            strandedRetry(id, why: "Browser Setu could not start the next try.")
            return
        }
        let multipart = record.engineMetadata["mode"] == "multipart"
        if data == nil, !multipart || !keepsPlace { ledger.update(id) { $0.transfer.completedBytes = 0 } }
        Task { @MainActor in await launch(id, resumeData: MultipartRun.isSentinel(data) ? nil : data) }
    }

    /// A retry that cannot run: the task moves to a state the person can act on (Resume / Start Over), with the reason, instead of staying "retrying" with nothing to wake it.
    func strandedRetry(_ id: UUID, why: String) {
        retrying.remove(id)
        coordinator.scheduler.cancelTimer(id)
        coordinator.scheduler.release(task: id)
        guard let record = ledger.record(id), !record.state.isFinal else { return }
        ledger.update(id) { $0.retryAt = nil }
        if ledger.apply(.recoveryRequired(reason: why), to: id) == nil {
            _ = ledger.apply(.failed(DownloadFailureInfo(code: "retry-not-scheduled", reason: why, retryable: true)), to: id)
        }
        coordinator.note(why)
    }

    /// A retry that is no longer wanted (cancelled, or the task is over): its timer and its place in line go, so nothing restarts it.
    private func cancelRetry(_ id: UUID) {
        retrying.remove(id)
        coordinator.scheduler.cancelTimer(id)
        if coordinator.scheduler.entries.contains(where: { $0.id == id && $0.kind == .retry }) { coordinator.scheduler.remove(id) }
    }

    var pendingRetries: Int { retrying.count }

    private final class SinkAdapter: DownloadReportSink, @unchecked Sendable {
        weak var runner: HTTPDownloadRunner?
        func report(_ report: DownloadEngineReport, task: DownloadTaskID, attempt: Int) {
            Task { @MainActor [weak runner] in runner?.handle(report, task: task, attempt: attempt) }
        }
    }
}

/// After a crash: a task that was being finalised, and whose file is complete on disk, is finished rather than downloaded again.
enum HTTPRecovery {
    /// Safe to repeat: a task already completed is untouched.
    @MainActor
    static func reconcile(_ ledger: DownloadLedger) {
        for record in ledger.records.values where record.protocolID == .http && record.state == .recoveryRequired {
            let facts = DownloadRecovery.facts(for: record, store: ledger.store, roots: ledger.authorizedRoots())
            // Complete only when the file is the right size, was written since this task began, and no working file says it was still being assembled.
            guard DownloadRecovery.assess(record, facts: facts) == .completeOnDisk else { continue }
            // A size that matches is not a checksum that matches: when the person gave a checksum, the file is hashed before it is called verified (the app may have stopped
            // between putting the file in place and comparing it). A file that does not match is deleted and the download is recovered as any other.
            if let given = record.engineMetadata["sha256"], let path = record.file.destinationPath {
                // The checksum is compared the way the engine compares it (a pasted "SHA256:AB…" counts); one that cannot be read at all is not trusted to delete anything.
                guard let expected = DownloadIntegrityCheck.normalizedDigest(given) else { continue }
                let id = record.id, roots = ledger.authorizedRoots()
                Task { @MainActor in
                    let digest = await Task.detached { HTTPTransferEngine.sha256(ofFileAt: URL(fileURLWithPath: path)) }.value
                    guard ledger.record(id)?.state == .recoveryRequired else { return }
                    guard let digest else { return }          // the file could not be read now (a volume that is away): it stays, and the task stays as it was
                    if digest == expected {
                        if ledger.apply(.verifying, to: id) != nil { ledger.apply(.completed(.verified), to: id, resumeData: .some(nil)); ledger.store?.deletePieces(task: id) }
                    } else if DownloadPathPolicy.isAuthorized(path, roots: roots) { try? FileManager.default.removeItem(atPath: path) }
                }
                continue
            }
            if ledger.apply(.verifying, to: record.id) != nil { ledger.apply(.completed(.verified), to: record.id, resumeData: .some(nil)); ledger.store?.deletePieces(task: record.id) }
        }
        _ = DownloadRecovery.sweepLeftovers(ledger)
    }
}

extension HTTPDownloadRunner {
    /// Called by the coordinator when it cancels a task it is tracking.
    func cancelFromCoordinator(_ id: UUID) { cancelTransferPublic(id) }
}
