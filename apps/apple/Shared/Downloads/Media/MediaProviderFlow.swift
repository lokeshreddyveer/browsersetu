import Foundation

// DX-09 closure: the part of the provider system the browser's windows talk to. `ProviderFlow` owns one operation per page and profile and drives it through `ProviderOperationState`
// (a move the machine does not allow is refused, and a result that arrives for an operation that was replaced, cancelled or belongs to another profile is dropped, never applied).
// `TikTokExportModel` is the eligibility-gated account-export workflow. Neither fetches media itself: sources go to the existing engines through `ProviderDownloadRouter`.

@MainActor
final class ProviderFlow: ObservableObject {
    struct Entry: Equatable {
        var generation: Int
        var state: ProviderOperationState
        var resolution: ProviderResolution?
        /// Source identity → the download started from it.
        var tasks: [String: UUID] = [:]
        var message: String?
        /// Renewals made for this operation (shown), and renewals since the transfer last ran (the limit).
        var renewals = 0
        var consecutive = 0
    }

    @Published private(set) var entries: [String: Entry] = [:]
    private var generations = 0
    private var lookups: [String: Task<Void, Never>] = [:]
    private var monitors: [UUID: Task<Void, Never>] = [:]
    private var starting = Set<String>()

    let coordinator: () -> DownloadCoordinator
    let profile: () -> String
    /// The address and privacy of the page in front, or nil when there is none.
    let activePage: () -> (url: URL?, isPrivate: Bool)
    var makeResolver: (DownloadCoordinator) -> ProviderResolver = { coordinator in
        let network = coordinator.http.engine.currentNetwork          // read here, on the main actor; the resolver only carries the value
        #if DEBUG
        if let base = ProviderFixtureMode.base {
            ProviderSourceCheck.allowLocalForTests = true
            let delay = ProviderFixtureMode.delay
            let api: ProviderAPI = {
                let real = FetcherProviderAPI(provider: .vimeo, network: network, hostOverride: base.host, origin: .user)
                return delay > 0 ? DelayedProviderAPI(inner: real, seconds: delay) : real
            }()
            let api0 = base.appendingPathComponent("media/vimeo")
            return ProviderResolver(api: { _ in api }, adapter: { id in id == .vimeo ? VimeoAdapter(base: api0) : ProviderRegistry.adapter(for: id) })
        }
        #endif
        return ProviderResolver(api: { FetcherProviderAPI(provider: $0, network: network) }, instanceAPI: { host in FetcherProviderAPI(provider: .peertube, network: network, allowedHost: host, origin: .page) })
    }
    /// Who the person is, to the network, when a resolved source is downloaded (a local fixture run is the person's own).
    var downloadOrigin: DownloadRequestOrigin {
        #if DEBUG
        if ProviderFixtureMode.base != nil { return .user }
        #endif
        return .page
    }
    /// Test hooks: run after a lookup is replaced or cancelled, and after the download engine accepted a start but before the flow re-checks the operation.
    var afterRouterStart: (() async -> Void)?
    private var retired: [Task<Void, Never>] = []
    /// Waits for the current lookup of a page (not replaced ones) to finish.
    func settle(_ c: MediaPageContext) async { await lookups[Self.key(c)]?.value }
    /// Waits for every lookup that has been started, including cancelled and replaced ones, to finish (so a test can look at the outcome without guessing a delay).
    func quiesce() async {
        let all = Array(lookups.values) + retired
        for t in all { await t.value }
        retired.removeAll()
    }
    /// How often a started download is looked at to see whether its link ran out.
    var watchInterval: Duration = .milliseconds(500)
    static let maxRenewals = 2

    init(coordinator: @escaping () -> DownloadCoordinator, profile: @escaping () -> String, activePage: @escaping () -> (url: URL?, isPrivate: Bool)) {
        self.coordinator = coordinator; self.profile = profile; self.activePage = activePage
    }

    static func key(_ c: MediaPageContext) -> String { [c.profile, c.isPrivate ? "private" : "normal", c.pageURL.absoluteString, c.frameURL?.absoluteString ?? ""].joined(separator: "|") }

    /// The context for the page in front now.
    func currentContext(frame: URL? = nil) -> MediaPageContext? {
        let page = activePage()
        guard let url = page.url else { return nil }
        return MediaPageContext(pageURL: url, frameURL: frame, isMainFrame: frame == nil, profile: profile(), isPrivate: page.isPrivate)
    }

    func entry(for c: MediaPageContext) -> Entry? { entries[Self.key(c)] }

    private func move(_ key: String, generation: Int, to next: ProviderOperationState, message: String? = nil) {
        guard var e = entries[key], e.generation == generation else { return }          // replaced or cancelled: a late result changes nothing
        guard e.state.canMove(to: next) else { return }
        e.state = next
        if let message { e.message = message }
        entries[key] = e
    }

    // MARK: Looking

    func resolve(_ c: MediaPageContext) {
        let key = Self.key(c)
        if let old = lookups[key] { old.cancel(); retired.append(old) }
        generations += 1
        let gen = generations
        let previous = entries[key]
        entries[key] = Entry(generation: gen, state: .identifying, tasks: previous?.tasks ?? [:], renewals: previous?.renewals ?? 0, consecutive: previous?.consecutive ?? 0)
        let resolver = makeResolver(coordinator())
        lookups[key] = Task { [weak self] in
            let result = await resolver.resolve(c) { state in await self?.move(key, generation: gen, to: state) }
            guard !Task.isCancelled, let self else { return }
            self.finish(result, key: key, generation: gen, context: c)
        }
    }

    private func finish(_ r: ProviderResolution, key: String, generation: Int, context c: MediaPageContext) {
        guard var e = entries[key], e.generation == generation, c.profile == profile() else { return }
        e.resolution = r
        e.message = r.message
        entries[key] = e
        move(key, generation: generation, to: r.state, message: r.message)
        lookups[key] = nil
    }

    func cancel(_ c: MediaPageContext) {
        let key = Self.key(c)
        if let old = lookups[key] { old.cancel(); retired.append(old) }
        lookups[key] = nil
        guard var e = entries[key] else { return }
        generations += 1
        e.generation = generations                    // whatever was in flight now belongs to an operation that no longer exists
        entries[key] = e
        move(key, generation: e.generation, to: .cancelled)
    }

    /// Everything in flight belongs to a profile or page that is no longer in front.
    func invalidateAll() {
        for t in lookups.values { t.cancel() }
        lookups = [:]
        for t in monitors.values { t.cancel() }
        monitors = [:]
        entries = [:]
    }

    // MARK: Downloading

    enum StartError: Error, Equatable, LocalizedError {
        case notReady, stale
        var errorDescription: String? { self == .notReady ? "This has not been resolved yet." : "The page or profile changed, so this was not started. Resolve it again." }
    }

    /// Starts one resolved source. Refused unless the operation is Ready for exactly this page and profile, and the source is one that operation produced.
    @discardableResult
    func start(_ source: AuthorizedMediaSource, in c: MediaPageContext, name: String, origin: DownloadRequestOrigin = .page) async throws -> UUID {
        let key = Self.key(c)
        guard let e = entries[key], e.state == .ready, let r = e.resolution, r.sources.contains(source) else { throw StartError.notReady }
        let page = activePage()
        guard c.profile == profile(), page.url == c.pageURL, page.isPrivate == c.isPrivate else { throw StartError.stale }
        let coordinator = coordinator()
        // A download that is already running for this very source is not started twice.
        if let existing = e.tasks[source.identity], let record = coordinator.ledger.record(existing), !record.state.isFinal { return existing }
        let startKey = key + "|" + source.identity
        guard starting.insert(startKey).inserted else { throw StartError.notReady }          // a second click while the first is still being set up
        defer { starting.remove(startKey) }
        try ProviderSourceCheck.validate(source)
        let id = try await ProviderDownloadRouter.start(source, name: name, coordinator: coordinator, origin: origin)
        await afterRouterStart?()
        // The operation may have been cancelled, replaced, or its profile or page left while this was being set up: what was started is stopped, not left running unwatched.
        guard var now = entries[key], now.generation == e.generation, c.profile == profile(), activePage().url == c.pageURL else {
            coordinator.cancel(id)
            throw StartError.stale
        }
        now.tasks[source.identity] = id
        entries[key] = now
        watch(id, source: source, context: c, key: key, generation: e.generation)
        return id
    }

    /// Looks at a started download until it ends. If it stopped because its link ran out, the link is renewed through the provider (the same media or nothing) and the same task carries on.
    private func watch(_ id: UUID, source: AuthorizedMediaSource, context c: MediaPageContext, key: String, generation: Int) {
        monitors[id]?.cancel()
        monitors[id] = Task { [weak self] in
            var current = source
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.watchInterval ?? .milliseconds(500))
                guard let self else { return }
                guard let e = self.entries[key], e.generation == generation else { self.monitors[id] = nil; return }
                let coordinator = self.coordinator()
                guard let record = coordinator.ledger.record(id) else { return }
                if record.state.isFinal && record.state != .failed { self.monitors[id] = nil; return }
                if record.state != .failed, e.consecutive > 0 { var ran = self.entries[key]; ran?.consecutive = 0; if let ran { self.entries[key] = ran } }       // it ran again: a later expiry may be renewed again
                guard record.state == .failed else { continue }
                guard ["http:401", "http:403", "http:410"].contains(record.failure?.code ?? ""), current.canRefresh, e.consecutive < Self.maxRenewals else { self.monitors[id] = nil; return }
                self.move(key, generation: generation, to: .refreshRequired)
                self.move(key, generation: generation, to: .resolving)
                do {
                    let fresh = try await self.makeResolver(coordinator).renew(current, context: c)
                    guard !Task.isCancelled, let again = self.entries[key], again.generation == generation, c.profile == self.profile() else { return }
                    var updated = again
                    updated.renewals += 1; updated.consecutive += 1
                    if var r = updated.resolution, let at = r.sources.firstIndex(where: { $0.identity == current.identity }) { r.sources[at] = fresh; updated.resolution = r }
                    updated.tasks[fresh.identity] = id
                    entries[key] = updated
                    current = fresh
                    coordinator.http.restart(id, url: fresh.url)
                    self.move(key, generation: generation, to: .ready)
                    // The restart is queued, not instant: until the task leaves the failed state it is not looked at again, or one expiry would be renewed twice.
                    for _ in 0..<100 where !Task.isCancelled && coordinator.ledger.record(id)?.state == .failed { try? await Task.sleep(for: self.watchInterval) }
                } catch {
                    let f = (error as? ProviderSourceCheck.Problem)?.errorDescription ?? ProviderFailure.from(error).errorDescription
                    if case .authorizationRequired = ProviderFailure.from(error) { self.move(key, generation: generation, to: .authorizationRequired, message: f) }
                    else { self.move(key, generation: generation, to: .failed(f ?? "The link could not be renewed."), message: f) }
                    self.monitors[id] = nil
                    return
                }
            }
        }
    }
}

// MARK: - TikTok account export

/// The documented TikTok Data Portability flow: Add → Check → Download (all POST, bearer token from the person's own authorization, which TikTok grants only to apps it has approved). The
/// archive is the signed-in person's own account data, not a single video. Nothing here can make a person or an app eligible.
@MainActor
final class TikTokExportModel: ObservableObject {
    enum Phase: Equatable {
        case idle, needsToken, requesting, pending, ready, expired, cancelled, downloading, done(String), failed(String), ineligible(String)
    }
    static let categories = ["all_data", "video", "profile", "activity", "direct_message"]
    static let scopes = "portability.all.single (or the narrower portability.* scopes for the categories chosen)"
    static let archiveLimit: Int64 = 20 * 1024 * 1024 * 1024

    @Published private(set) var phase: Phase = .idle
    @Published var format = "json"
    @Published var chosen: Set<String> = ["all_data"]
    private(set) var requestID: String?

    let profile: String
    /// A private tab never uses the account's authorization.
    let isPrivate: Bool
    let coordinator: () -> DownloadCoordinator
    var base = URL(string: "https://open.tiktokapis.com/v2/user/data/")!
    var apiFactory: (DownloadCoordinator) -> ProviderAPI = { FetcherProviderAPI(provider: .tiktok, network: $0.http.engine.currentNetwork) }
    private var downloadTask: Task<Void, Never>?
    private var defaultsKey: String { "bs.tiktok.export." + profile }

    init(profile: String, isPrivate: Bool = false, coordinator: @escaping () -> DownloadCoordinator) {
        self.profile = profile; self.isPrivate = isPrivate; self.coordinator = coordinator
        restore()
    }

    private func restore() {
        guard let d = UserDefaults.standard.dictionary(forKey: defaultsKey), let id = d["id"] as? String, !id.isEmpty else { return }
        requestID = id
        format = d["format"] as? String ?? "json"
        chosen = Set((d["categories"] as? [String] ?? []).filter { Self.categories.contains($0) })
        if chosen.isEmpty { chosen = ["all_data"] }
        phase = .pending            // what it really is is asked of TikTok when the person checks
    }
    private func persist() {
        if let requestID { UserDefaults.standard.set(["id": requestID, "format": format, "categories": Array(chosen).sorted()], forKey: defaultsKey) }
        else { UserDefaults.standard.removeObject(forKey: defaultsKey) }
    }
    func forget() { downloadTask?.cancel(); requestID = nil; persist(); phase = .idle }

    var token: String? { isPrivate ? nil : ProviderCredentials.token(.tiktok, profile: profile) }
    private func url(_ name: String, fields: String? = nil) -> URL {
        var c = URLComponents(url: base.appendingPathComponent(name + "/"), resolvingAgainstBaseURL: false)!
        if let fields { c.queryItems = [URLQueryItem(name: "fields", value: fields)] }
        return c.url!
    }
    private func fail(_ error: Error) {
        switch ProviderFailure.from(error) {
        case .authorizationRequired: phase = .needsToken
        case .missingScope: phase = .ineligible("TikTok refused this authorization. The app needs TikTok's approval for the Data Portability API, your account must be eligible (it currently covers users in the EEA and the UK), and the token needs the right portability scope. None of this can be changed from here.")
        case .cancelled: break
        case let f: phase = .failed(f.errorDescription ?? "The request failed.")
        }
    }

    /// Step one: ask TikTok to collect the data. A single-use scope allows this once.
    func request() async {
        // One request at a time: a single-use scope allows one, and a live request must not be overwritten. Only an ended request (expired, cancelled) makes way for a new one.
        if requestID != nil, phase != .expired, phase != .cancelled { return }
        guard let token else { phase = .needsToken; return }
        guard !chosen.isEmpty else { phase = .failed("Choose what to export."); return }
        phase = .requesting
        let api = apiFactory(coordinator())
        let body = (try? JSONSerialization.data(withJSONObject: ["data_format": format, "category_selection_list": chosen.contains("all_data") ? ["all_data"] : Array(chosen).sorted()])) ?? Data()
        let endpoint = url("add", fields: "request_id")
        do {
            let answer = try await ProviderRetry.run { try await api.data(endpoint, method: "POST", body: body, bearer: token, extraHeaders: [:]) }
            let data = (try? JSONSerialization.jsonObject(with: answer) as? [String: Any])?["data"] as? [String: Any]
            guard let n = data?["request_id"] as? NSNumber, !(n === kCFBooleanTrue), !(n === kCFBooleanFalse), n.int64Value > 0 else { phase = .failed("TikTok's answer had no request number."); return }
            requestID = n.stringValue; persist(); phase = .pending
        } catch { fail(error) }
    }

    /// Step two: ask how it is going. TikTok's words: pending, downloading (ready), expired (about four days after it was ready), cancelled.
    func check() async {
        guard let token else { phase = .needsToken; return }
        guard let requestID, let n = Int64(requestID) else { phase = .failed("There is no request to check."); return }
        let api = apiFactory(coordinator())
        let body = (try? JSONSerialization.data(withJSONObject: ["request_id": n])) ?? Data()
        let endpoint = url("check", fields: "request_id,status,data_format,category_selection_list")
        do {
            let json = try await ProviderRetry.run { try await api.data(endpoint, method: "POST", body: body, bearer: token, extraHeaders: [:]) }
            let status = try TikTokPortability.parse(try JSONSerialization.jsonObject(with: json))
            guard status.requestID == requestID else { phase = .failed("TikTok answered about a different request."); return }
            switch status.state {
            case .pending: phase = .pending
            case .ready: phase = .ready
            case .expired: phase = .expired
            case .cancelled: phase = .cancelled
            case .failed: phase = .failed("TikTok could not prepare the data.")
            case .unknown(let w): phase = .failed("TikTok reported a status this app does not know (\(w)).")
            }
        } catch { fail(error) }
    }

    /// Step three: the archive, streamed to disk through the same Downloads lifecycle as any download. It is a ZIP of account data; nothing is unpacked or opened.
    func download() async {
        guard phase == .ready, let token, let requestID, let n = Int64(requestID) else { return }
        let coordinator = coordinator()
        // The token is this profile's; the download must be recorded in this profile's list.
        guard coordinator.ledger.profile == profile else { phase = .failed("The profile changed; open this profile again to download."); return }
        phase = .downloading
        let api = apiFactory(coordinator)
        let endpoint = url("download")
        let name = "TikTok data \(requestID).zip"
        let ticket = await coordinator.admitTicket(filename: name, source: endpoint, protocolID: .media)
        guard ticket.admitted else { phase = .ready; return }
        let id = ticket.id
        let started = coordinator.begin(suggestedName: name, sourceHost: endpoint.host, sourceURL: endpoint, isPrivate: false, taskID: id, protocolID: .media, cancel: { [weak self] in self?.downloadTask?.cancel() }, suspend: nil)
        let dir = MediaStore.folder(profile: coordinator.ledger.profile, task: id)
        downloadTask = Task { [weak self] in
            @MainActor func finishWithFailure(_ why: String, _ code: String) {
                MediaStore.remove(dir)
                coordinator.fail(id, source: endpoint, error: HTTPDownloadError(info: DownloadFailureInfo(code: code, reason: why, retryable: false)), willRetry: false)
                self?.phase = .failed(why)
            }
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let free = DiskSpace.available(at: dir) ?? 0
                // The answer is written to a temporary file and then moved, so it needs room twice over: the limit is what fits with a margin.
                let allowed = min(Self.archiveLimit, max(0, (free - 512 * 1024 * 1024) / 2))
                if allowed < 50 * 1024 * 1024 { finishWithFailure("There is not enough free space.", "export:disk"); return }
                let staged = dir.appendingPathComponent("export.zip")
                let body = (try? JSONSerialization.data(withJSONObject: ["request_id": n])) ?? Data()
                _ = try await api.download(endpoint, body: body, bearer: token, to: staged, maxBytes: allowed)
                try Task.checkCancellation()
                switch ArchiveCheck.inspect(staged) {
                case .zip: break
                case .apiError(let why): finishWithFailure("TikTok answered with an error instead of the archive: \(why)", "export:api"); return
                case .notAnArchive: finishWithFailure("What came back is not a valid ZIP archive.", "export:zip"); return
                }
                guard DownloadPathPolicy.isAuthorized(started.destination.path, roots: coordinator.managedRoots) else { finishWithFailure("The download folder is not allowed.", "export:path"); return }
                let target = try FileNaming.publish(staged, as: started.destination)          // claimed by the rename itself: nothing is replaced, even by a save finishing at the same moment
                DownloadQuarantine.apply(to: target, sourceOrigin: DownloadCoordinator.originOnly(of: endpoint.absoluteString))
                coordinator.updateDestination(id, to: target)
                MediaStore.remove(dir)
                coordinator.finish(id, source: nil, integrity: .unknown)
                self?.phase = .done(target.lastPathComponent)
            } catch is CancellationError {
                MediaStore.remove(dir)
                coordinator.cancel(id)
                self?.phase = self?.requestID == nil ? .idle : .ready
            } catch where Task.isCancelled || (error as? URLError)?.code == .cancelled {
                // A cancelled transfer surfaces as a URL error, not a CancellationError: it is still a cancel, not a failure.
                MediaStore.remove(dir)
                coordinator.cancel(id)
                self?.phase = self?.requestID == nil ? .idle : .ready
            } catch {
                let f = ProviderFailure.from(error)
                finishWithFailure(f.errorDescription ?? "The download failed.", "export:\(f)")
                if case .authorizationRequired = f { self?.phase = .needsToken }
            }
        }
        await downloadTask?.value
    }

    func cancelDownload() { downloadTask?.cancel() }
}

enum ArchiveCheck {
    enum Verdict: Equatable { case zip, apiError(String), notAnArchive }
    /// A ZIP starts with a local-file header (or, if empty, the end record) and ends with the end-of-central-directory record. A JSON error that was served with a good status is reported as that.
    static func inspect(_ file: URL) -> Verdict {
        guard let h = try? FileHandle(forReadingFrom: file) else { return .notAnArchive }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 4096)) ?? Data()
        let total = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if head.first == UInt8(ascii: "{") || head.first == UInt8(ascii: "[") {
            // An error message is small; anything larger that starts this way is not read whole.
            guard total <= 65_536 else { return .notAnArchive }
            if let json = try? JSONSerialization.jsonObject(with: (try? Data(contentsOf: file)) ?? head) as? [String: Any], let e = json["error"] as? [String: Any] {
                return .apiError([e["code"], e["message"]].compactMap { $0 as? String }.joined(separator: ": "))
            }
            return .notAnArchive
        }
        let magic: [UInt8] = [0x50, 0x4B]
        guard head.count >= 4, Array(head.prefix(2)) == magic, [[0x03, 0x04], [0x05, 0x06]].contains(Array(head[2..<4])) else { return .notAnArchive }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let tailLength = min(size, 66_000)
        guard (try? h.seek(toOffset: UInt64(size - tailLength))) != nil, let tail = try? h.read(upToCount: tailLength) else { return .notAnArchive }
        let end: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        // The end record is searched from the back; its central directory must lie inside the file.
        for i in tail.indices.dropLast(21).reversed() where Array(tail[i..<i + 4]) == end {
            func le32(_ off: Int) -> Int { var v = 0; for k in 0..<4 { v |= Int(tail[i + off + k]) << (8 * k) }; return v }
            if le32(12) + le32(16) <= size { return .zip }          // the central directory lies inside the file
        }
        return .notAnArchive
    }
}
