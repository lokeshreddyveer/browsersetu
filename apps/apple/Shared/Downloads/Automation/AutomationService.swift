import Foundation
import Combine

/// The one automation service. It authenticates, validates and routes; every change to a download is made by calling the existing coordinator. It owns no transfer state:
/// the ledger remains the authority, and what this keeps (proposals, an idempotency cache, an audit trail, event buffers) is bookkeeping about requests, not about transfers.
@MainActor
final class AutomationService: ObservableObject {
    static let apiVersion = "v1"
    static let maxBody = 64 * 1024
    static let maxInFlight = 16
    static let maxProposals = 50
    static let maxProposalsPerClient = 10
    static let maxBatch = 50

    @Published private(set) var isEnabled = false
    @Published private(set) var proposals: [Proposal] = []
    @Published private(set) var audit: [AuditEntry] = []

    let clients: AutomationClientStore
    /// The one source of download events. Notifications, diagnostics and the event stream all read from it; none of them watches the ledger on its own.
    let feed: DownloadEventFeed
    private let feedOwned: Bool
    var events: AutomationEventHub { feed.hub }
    private let coordinators: () -> [DownloadCoordinator]
    private let clock: () -> Date
    private let monotonic: () -> TimeInterval
    private var limiter = AutomationRateLimiter(limit: 60, window: 10)
    private var authLimiter = AutomationRateLimiter(limit: 10, window: 60)
    private var inFlight = 0
    private var idempotent: [String: (digest: String, status: Int, body: Data, at: Date)] = [:]
    private var idempotentOrder: [String] = []
    /// Observers of every event, for webhooks.
    var eventSink: ((AutomationEvent) -> Void)?

    struct Proposal: Identifiable, Equatable {
        enum State: String { case pending, approved, rejected }
        var id: String
        var url: URL
        var filename: String?
        var priority: DownloadPriority
        var startAt: Date?
        var sha256: String?
        var clientID: String
        var clientName: String
        var profile: String
        var createdAt: Date
        var state: State = .pending
        var taskID: UUID?
    }

    struct AuditEntry: Identifiable, Equatable {
        let id = UUID()
        var at: Date
        var client: String
        var action: String
        var outcome: String
    }

    init(clients: AutomationClientStore, coordinators: @escaping () -> [DownloadCoordinator], clock: @escaping () -> Date = Date.init,
         monotonic: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, feed: DownloadEventFeed? = nil) {
        self.clients = clients; self.coordinators = coordinators; self.clock = clock; self.monotonic = monotonic
        self.feed = feed ?? DownloadEventFeed(coordinators: coordinators, monotonic: monotonic)
        feedOwned = feed == nil
        self.feed.observe { [weak self] event, _ in self?.eventSink?(event) }
        clients.onInvalidate = { [weak self] id in self?.events.close(clientID: id) }
    }

    // MARK: Lifecycle

    func start() {
        guard !isEnabled else { return }
        isEnabled = true
        feed.start()          // idempotent; learns what exists and sends nothing
    }

    /// Switching off ends every stream and forgets nothing about transfers: no download is started, stopped or changed by this. A feed shared with notifications keeps running.
    func stop() {
        isEnabled = false
        events.closeAll()
        if feedOwned { feed.stop() }
    }

    func publishChanges() { feed.publishChanges() }

    // MARK: Entry point

    func handle(_ request: AutomationRequest) async -> AutomationReply {
        guard isEnabled else { return AutomationJSON.error(.disabled) }
        guard inFlight < Self.maxInFlight else { return AutomationJSON.error(.busy) }
        inFlight += 1
        defer { inFlight -= 1 }
        var who = "unknown"
        do {
            try Self.checkTransport(request)
            guard request.body.count <= Self.maxBody else { throw AutomationError.tooLarge }
            let client = try authenticate(request)
            who = client.name
            guard limiter.allow(client.id, at: monotonic()) else { throw AutomationError.tooMany }
            if request.method == "POST", !request.body.isEmpty, !(request.headers["content-type"] ?? "").lowercased().hasPrefix("application/json") {
                throw AutomationError(status: 415, code: "unsupported_media_type", message: "Send application/json.")
            }
            if let named = request.headers["x-browsersetu-profile"], named != client.profile {
                throw AutomationError.forbidden("profile_mismatch", "This client belongs to a different profile.")
            }
            guard let coordinator = coordinators().first(where: { $0.profileName == client.profile }) else { throw AutomationError.notFound }
            let reply = try await route(request, client: client, coordinator: coordinator)
            record(who, request, "ok")
            return reply
        } catch let e as AutomationError {
            record(who, request, e.code)
            return AutomationJSON.error(e)
        } catch {
            record(who, request, "error")
            return AutomationJSON.error(AutomationError(status: 500, code: "internal", message: "Something went wrong."))
        }
    }

    // MARK: Checks

    /// A web page cannot reach a Unix socket at all; on loopback it can, so the request must look like a command-line tool's: a Host that names the loopback address
    /// and the exact port (defeats DNS rebinding), and none of the headers a browser adds on its own (Origin, Sec-Fetch-*).
    static func checkTransport(_ r: AutomationRequest) throws {
        if r.headers["origin"] != nil || r.headers.keys.contains(where: { $0.hasPrefix("sec-fetch-") }) {
            throw AutomationError.forbidden("browser_origin", "Requests from web pages are not accepted.")
        }
        if case .loopback(let port) = r.transport {
            guard let host = r.headers["host"]?.lowercased(), host == "127.0.0.1:\(port)" || host == "localhost:\(port)" || host == "[::1]:\(port)" else {
                throw AutomationError.forbidden("bad_host", "Wrong host.")
            }
        }
        if r.target.contains("access_token=") || r.target.contains("token=") { throw AutomationError.badRequest("token_in_url", "Never put a token in the address.") }
    }

    private func authenticate(_ r: AutomationRequest) throws -> AutomationClient {
        guard let header = r.headers["authorization"], header.hasPrefix("Bearer ") else { return try failAuth() }
        switch clients.authenticate(String(header.dropFirst(7))) {
        case .ok(let client): clients.touch(client.id); return client
        case .failed: return try failAuth()
        }
    }

    private func failAuth() throws -> AutomationClient {
        // Ten failures a minute at most: guessing is not free, and the answer never says which part was wrong.
        if !authLimiter.allow("failures", at: monotonic()) { throw AutomationError.tooMany }
        throw AutomationError.unauthorized()
    }

    private func need(_ scope: AutomationScope, _ client: AutomationClient) throws {
        guard client.scopes.contains(scope) else { throw AutomationError.missingScope(scope) }
    }

    private func record(_ client: String, _ r: AutomationRequest, _ outcome: String) {
        // The route's shape only: no addresses, no identifiers, no query.
        // Only words of the API itself are written down; anything else a caller typed becomes ":x".
        let known: Set<String> = ["v1", "health", "capabilities", "downloads", "downloads:batch", "proposals", "stats", "queues", "default", "hold", "release", "settings", "events",
                                  "pause", "resume", "cancel", "retry", "priority", "schedule", "trash-file", "approve"]
        let shape = r.path.split(separator: "/").map { part -> String in UUID(uuidString: String(part)) != nil ? ":id" : (known.contains(String(part)) ? String(part) : ":x") }.joined(separator: "/")
        audit.insert(AuditEntry(at: clock(), client: client, action: "\(r.method) /\(shape)", outcome: outcome), at: 0)
        if audit.count > 200 { audit.removeLast(audit.count - 200) }
    }

    // MARK: Routing

    private func route(_ r: AutomationRequest, client: AutomationClient, coordinator: DownloadCoordinator) async throws -> AutomationReply {
        let parts = r.path.split(separator: "/").map(String.init)
        guard parts.first == Self.apiVersion else { throw AutomationError.notFound }
        let rest = Array(parts.dropFirst())
        switch (r.method, rest) {
        case ("GET", ["health"]):
            struct Health: Encodable { var ok = true; var api = AutomationService.apiVersion }
            return AutomationJSON.reply(Health())
        case ("GET", ["capabilities"]): try need(.downloadsRead, client); return capabilities(coordinator)
        case ("GET", ["downloads"]): try need(.downloadsRead, client); return list(r, client, coordinator)
        case ("POST", ["downloads"]): try need(.downloadsCreate, client); return try idempotently(r, client) { try self.propose(r, client) }
        case ("POST", ["downloads:batch"]): try need(.downloadsControl, client); return try batch(r, client, coordinator)
        case ("GET", ["proposals"]): try need(.downloadsRead, client); return AutomationJSON.reply(proposals.filter { $0.clientID == client.id }.map(dto))
        case ("GET", ["stats"]): try need(.downloadsRead, client); return stats(client, coordinator)
        case ("GET", ["queues"]): try need(.queuesRead, client); return AutomationJSON.reply([queue(coordinator)])
        case ("POST", ["queues", "default", "hold"]): try need(.queuesControl, client); return try hold(r, coordinator)
        case ("POST", ["queues", "default", "release"]): try need(.queuesControl, client); coordinator.holdQueue(until: nil); return AutomationJSON.reply(queue(coordinator))
        case ("GET", ["settings"]): try need(.settingsRead, client); return settings(coordinator)
        case ("GET", ["events"]): try need(.downloadsRead, client); return try subscribe(r, client)
        case ("GET", let p) where p.count == 2 && p[0] == "downloads":
            try need(.downloadsRead, client); return AutomationJSON.reply(try download(p[1], client, coordinator))
        case ("POST", let p) where p.count == 3 && p[0] == "downloads":
            return try await action(p[2], id: p[1], r, client, coordinator)
        default: throw AutomationError.notFound
        }
    }

    // MARK: Reading

    private func visible(_ record: DownloadTaskRecord, _ client: AutomationClient) -> Bool { !record.isPrivate && record.profile == client.profile }

    private func dto(_ record: DownloadTaskRecord, _ c: DownloadCoordinator) -> DownloadDTO {
        let total = record.transfer.totalBytes
        let received = c.active[record.id]?.completedBytes ?? record.transfer.completedBytes
        let fraction = c.active[record.id]?.fraction ?? total.flatMap { $0 > 0 ? Double(record.transfer.completedBytes) / Double($0) : nil }
        return DownloadDTO(id: record.id.uuidString, state: record.state.rawValue, filename: record.file.filename, source: AutomationSanitize.address(record.source.url),
                           sourceHost: record.source.host, engine: record.protocolID.rawValue, priority: AutomationSanitize.priority(record.priority), bytesReceived: received,
                           totalBytes: total, fraction: fraction, createdAt: record.createdAt, scheduledAt: record.scheduledAt, canPause: c.canPause(record.id),
                           canResume: c.interrupted[record.id] != nil, failureReason: record.failure?.reason)
    }

    private func download(_ id: String, _ client: AutomationClient, _ c: DownloadCoordinator) throws -> DownloadDTO {
        guard let uuid = UUID(uuidString: id), let record = c.ledger.record(uuid), visible(record, client) else { throw AutomationError.notFound }
        return dto(record, c)
    }

    private func list(_ r: AutomationRequest, _ client: AutomationClient, _ c: DownloadCoordinator) -> AutomationReply {
        let limit = min(200, max(1, Int(r.query["limit"] ?? "") ?? 100))
        let wanted = r.query["state"]
        let rows = c.ledger.records.values.filter { visible($0, client) && (wanted == nil || $0.state.rawValue == wanted) }
            .sorted { $0.createdAt > $1.createdAt }.prefix(limit).map { dto($0, c) }
        return AutomationJSON.reply(Array(rows))
    }

    private func stats(_ client: AutomationClient, _ c: DownloadCoordinator) -> AutomationReply {
        let mine = c.ledger.records.values.filter { visible($0, client) }
        var by: [String: Int] = [:]
        for r in mine { by[r.state.rawValue, default: 0] += 1 }
        return AutomationJSON.reply(StatsDTO(total: mine.count, byState: by, bytesReceived: mine.reduce(0) { $0 + $1.transfer.completedBytes }, active: c.active.count, queueHeld: c.scheduler.isHeld))
    }

    private func capabilities(_ c: DownloadCoordinator) -> AutomationReply {
        let list: [(DownloadProtocolID, Bool, String)] = [
            (.webKit, false, "Made by the browser from a page; not created through the API."),
            (.http, true, "A proposal you approve in the app becomes this."),
            (.bittorrent, false, "Needs your approval in the app. The API cannot start peer-to-peer."),
            (.ed2k, false, "Needs your approval in the app. The API cannot start peer-to-peer."),
        ]
        return AutomationJSON.reply(list.map { EngineCapabilityDTO(engine: $0.0.rawValue, canPause: c.engines.can(.pause, $0.0), canResume: c.engines.can(.resume, $0.0), createdThroughAPI: $0.1, note: $0.2) })
    }

    private func queue(_ c: DownloadCoordinator) -> QueueDTO {
        QueueDTO(id: "default", running: c.active.count, waiting: c.waiting.count, scheduled: c.scheduled.count, held: c.scheduler.isHeld,
                 heldUntil: c.scheduler.isHeld && c.heldUntil != .distantFuture ? c.heldUntil : nil, maxConcurrent: c.maxConcurrent)
    }

    private func settings(_ c: DownloadCoordinator) -> AutomationReply {
        // Read-only and sanitized: no proxy, no credential, no folder.
        AutomationJSON.reply(["maxConcurrent": "\(c.maxConcurrent)", "duplicatePolicy": c.duplicatePolicy.rawValue, "queueHeld": c.scheduler.isHeld ? "true" : "false"])
    }

    // MARK: Creating (a proposal, never a task)

    /// A download asked for by a program is a proposal. The existing request policy refuses a download that is not the person's own (it cannot stop a connection to a private
    /// address before it is made), so the API never connects: the person approves a proposal in the app, and that approval is what starts it. A client cannot approve its own.
    private func propose(_ r: AutomationRequest, _ client: AutomationClient) throws -> AutomationReply {
        struct Body: Decodable { var url: String; var filename: String?; var priority: String?; var startAt: Date?; var sha256: String?; var approved: Bool?; var profile: String? }
        guard let body = try? AutomationJSON.decoder.decode(Body.self, from: r.body) else { throw AutomationError.badRequest("bad_json", "The body is not valid JSON of the expected shape.") }
        if let p = body.profile, p != client.profile { throw AutomationError.forbidden("profile_mismatch", "This client belongs to a different profile.") }
        if body.approved == true {
            throw AutomationError.forbidden("origin_not_allowed", "A program cannot start a download directly. Send it as a proposal and approve it in Browser Setu.")
        }
        guard body.url.utf8.count <= 2048, let url = URL(string: body.url), let scheme = url.scheme?.lowercased() else { throw AutomationError.badRequest("bad_url", "The address is not valid.") }
        guard scheme == "http" || scheme == "https" else {
            if scheme == "magnet" || scheme == "ed2k" { throw AutomationError.forbidden("p2p_requires_user", "Peer-to-peer downloads need your approval in the app and cannot be started through the API.") }
            throw AutomationError.badRequest("unsupported_scheme", "Only http and https addresses can be proposed.")
        }
        guard url.user == nil, url.password == nil else { throw AutomationError.badRequest("credentials_in_url", "Do not put a user name or password in the address.") }
        do { try HTTPRequestPolicy(origin: .automation).check(url) }
        catch let refusal as HTTPRequestPolicy.Refusal { throw AutomationError.forbidden("destination_not_allowed", refusal.reason) }
        // A number written some other way (127.1, 0x7f.0.0.1, 0177.0.0.1) is read as a loopback address by the system but looks like a name to the policy's text check.
        // Any host that starts with a digit and is made only of digits, hex letters, "x" and dots must be an ordinary four-part decimal address, or it is refused.
        if let host = url.host?.lowercased(), let first = host.first, first.isNumber, host.allSatisfy({ $0.isHexDigit || $0 == "x" || $0 == "." }) {
            let parts = host.split(separator: ".", omittingEmptySubsequences: false)
            let strict = parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isNumber) && ($0 == "0" || !$0.hasPrefix("0")) && Int($0)! <= 255 }
            if !strict { throw AutomationError.forbidden("destination_not_allowed", "That address is written in a form that is not allowed.") }
        }
        var name: String?
        if let f = body.filename { guard let clean = DownloadFilename.sanitize(f) else { throw AutomationError.badRequest("bad_filename", "That file name cannot be used.") }; name = clean }
        var priority = DownloadPriority.normal
        if let p = body.priority { guard let chosen = AutomationSanitize.priority(named: p) else { throw AutomationError.badRequest("bad_priority", "Use low, normal or high.") }; priority = chosen }
        if let at = body.startAt, at > clock().addingTimeInterval(365 * 86_400) { throw AutomationError.badRequest("bad_start", "The start time is too far away.") }
        var digest: String?
        if let s = body.sha256 { guard let d = DownloadIntegrityCheck.normalizedDigest(s) else { throw AutomationError.badRequest("bad_sha256", "That is not a SHA-256 value.") }; digest = d }
        // The same client asking for the same address again is the same proposal.
        if let existing = proposals.first(where: { $0.clientID == client.id && $0.state == .pending && $0.url == url }) { return AutomationJSON.reply(dto(existing), status: 202) }
        // Old proposals fall away: pending ones after a day, and answered ones beyond the most recent twenty.
        let cutoff = clock().addingTimeInterval(-86_400)
        proposals.removeAll { $0.state == .pending && $0.createdAt < cutoff }
        let answered = proposals.filter { $0.state != .pending }
        if answered.count > 20 { let drop = Set(answered.suffix(answered.count - 20).map(\.id)); proposals.removeAll { drop.contains($0.id) } }
        guard proposals.filter({ $0.state == .pending && $0.clientID == client.id }).count < Self.maxProposalsPerClient,
              proposals.filter({ $0.state == .pending }).count < Self.maxProposals else { throw AutomationError.conflict("too_many_proposals", "Too many proposals are waiting for your approval.") }
        let p = Proposal(id: UUID().uuidString, url: url, filename: name, priority: priority, startAt: body.startAt, sha256: digest, clientID: client.id, clientName: client.name,
                         profile: client.profile, createdAt: clock())
        proposals.insert(p, at: 0)
        return AutomationJSON.reply(dto(p), status: 202)
    }

    private func dto(_ p: Proposal) -> ProposalDTO {
        ProposalDTO(id: p.id, state: p.state.rawValue, source: AutomationSanitize.address(p.url.absoluteString) ?? "", sourceHost: p.url.host ?? "", filename: p.filename,
                    priority: AutomationSanitize.priority(p.priority), startAt: p.startAt, createdAt: p.createdAt, clientName: p.clientName, taskID: p.taskID?.uuidString)
    }

    /// Called only from the app's own interface, after the person pressed Approve. Not reachable through the API.
    @discardableResult
    func approve(_ id: String) -> UUID? {
        guard let i = proposals.firstIndex(where: { $0.id == id && $0.state == .pending }),
              let c = coordinators().first(where: { $0.profileName == proposals[i].profile }) else { return nil }
        let p = proposals[i]
        guard let task = c.scheduleDownload(url: p.url, at: p.startAt ?? clock(), filename: p.filename, priority: p.priority, expectedSHA256: p.sha256, origin: .page) else { return nil }
        proposals[i].state = .approved
        proposals[i].taskID = task
        return task
    }

    func reject(_ id: String) {
        if let i = proposals.firstIndex(where: { $0.id == id && $0.state == .pending }) { proposals[i].state = .rejected }
    }

    // MARK: Controlling

    private func action(_ name: String, id: String, _ r: AutomationRequest, _ client: AutomationClient, _ c: DownloadCoordinator) async throws -> AutomationReply {
        if name == "trash-file" { try need(.downloadsFiles, client) } else { try need(.downloadsControl, client) }
        guard let uuid = UUID(uuidString: id), let record = c.ledger.record(uuid), visible(record, client) else { throw AutomationError.notFound }
        return try idempotently(r, client) {
            switch name {
            case "pause":
                guard !record.state.isFinal, c.canPause(uuid) else { throw AutomationError.conflict("unsupported_operation", "This download cannot be paused (its engine cannot hand back what it has).") }
                c.pause(uuid)
            case "resume":
                guard c.interrupted[uuid] != nil else { throw AutomationError.conflict("not_resumable", "This download is not stopped part-way with something to resume from.") }
                c.resume(uuid)
            case "cancel":
                guard !record.state.isFinal else { throw AutomationError.conflict("already_finished", "This download is already over.") }
                c.cancel(uuid)
            case "retry":
                guard let f = c.failures.first(where: { $0.id == uuid }), f.canRetry else { throw AutomationError.conflict("not_retryable", "This download cannot be tried again from its address.") }
                c.retryFailure(uuid)
            case "priority":
                struct B: Decodable { var priority: String }
                guard let b = try? AutomationJSON.decoder.decode(B.self, from: r.body), let p = AutomationSanitize.priority(named: b.priority) else { throw AutomationError.badRequest("bad_priority", "Use low, normal or high.") }
                guard !record.state.isFinal else { throw AutomationError.conflict("already_finished", "This download is already over.") }
                c.setPriority(uuid, p)
            case "schedule":
                struct B: Decodable { var startAt: Date }
                guard let b = try? AutomationJSON.decoder.decode(B.self, from: r.body) else { throw AutomationError.badRequest("bad_start", "Send {\"startAt\": \"<ISO-8601 time>\"}.") }
                guard b.startAt <= self.clock().addingTimeInterval(365 * 86_400) else { throw AutomationError.badRequest("bad_start", "The start time is too far away.") }
                guard c.scheduled.contains(where: { $0.id == uuid }) else { throw AutomationError.conflict("not_scheduled", "Only a download that is waiting for a start time can be rescheduled.") }
                c.reschedule(uuid, at: b.startAt)
            case "trash-file":
                guard record.state == .completed, let path = record.file.destinationPath, DownloadPathPolicy.isAuthorized(path, roots: [DownloadCoordinator.directory]),
                      URL(fileURLWithPath: path).standardizedFileURL.path != DownloadCoordinator.directory.standardizedFileURL.path else {
                    throw AutomationError.forbidden("path_not_allowed", "Only a finished file in the Downloads folder can be moved to the Trash.")
                }
                guard FileManager.default.fileExists(atPath: path) else { throw AutomationError.notFound }
                guard (try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)) != nil else { throw AutomationError.conflict("trash_failed", "The file could not be moved to the Trash.") }
            default: throw AutomationError.notFound
            }
            return AutomationJSON.reply(try self.download(id, client, c))
        }
    }

    private func hold(_ r: AutomationRequest, _ c: DownloadCoordinator) throws -> AutomationReply {
        struct B: Decodable { var until: Date? }
        var until: Date?
        if !r.body.isEmpty {
            guard let b = try? AutomationJSON.decoder.decode(B.self, from: r.body) else { throw AutomationError.badRequest("bad_json", "Send {} or {\"until\": \"<ISO-8601 time>\"}.") }
            until = b.until
        }
        c.holdQueue(until: until ?? .distantFuture)
        return AutomationJSON.reply(queue(c))
    }

    private func batch(_ r: AutomationRequest, _ client: AutomationClient, _ c: DownloadCoordinator) throws -> AutomationReply {
        struct B: Decodable { var action: String; var ids: [String] }
        guard let b = try? AutomationJSON.decoder.decode(B.self, from: r.body), ["pause", "resume", "cancel"].contains(b.action) else {
            throw AutomationError.badRequest("bad_batch", "Send {\"action\": \"pause|resume|cancel\", \"ids\": [...]}.")
        }
        guard !b.ids.isEmpty, b.ids.count <= Self.maxBatch else { throw AutomationError.badRequest("bad_batch", "Between 1 and \(Self.maxBatch) ids.") }
        struct Result: Encodable { var id: String; var ok: Bool; var code: String? }
        var out: [Result] = []
        for id in Set(b.ids).sorted() {
            guard let uuid = UUID(uuidString: id), let record = c.ledger.record(uuid), visible(record, client) else { out.append(Result(id: id, ok: false, code: "not_found")); continue }
            switch b.action {
            case "pause": if !record.state.isFinal, c.canPause(uuid) { c.pause(uuid); out.append(Result(id: id, ok: true, code: nil)) } else { out.append(Result(id: id, ok: false, code: "unsupported_operation")) }
            case "resume": if c.interrupted[uuid] != nil { c.resume(uuid); out.append(Result(id: id, ok: true, code: nil)) } else { out.append(Result(id: id, ok: false, code: "not_resumable")) }
            default: if !record.state.isFinal { c.cancel(uuid); out.append(Result(id: id, ok: true, code: nil)) } else { out.append(Result(id: id, ok: false, code: "already_finished")) }
            }
        }
        return AutomationJSON.reply(out)
    }

    // MARK: Idempotency

    private func idempotently(_ r: AutomationRequest, _ client: AutomationClient, _ work: () throws -> AutomationReply) throws -> AutomationReply {
        guard let key = r.headers["idempotency-key"] else { return try work() }
        guard key.count >= 8, key.count <= 64, key.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }) else {
            throw AutomationError.badRequest("bad_idempotency_key", "Use 8 to 64 letters, digits, - or _.")
        }
        let cacheKey = "\(client.id):\(r.method) \(r.path):\(key)"
        let digest = r.body.sha256Hex
        let now = clock()
        if let hit = idempotent[cacheKey], now.timeIntervalSince(hit.at) < 3600 {
            guard hit.digest == digest else { throw AutomationError(status: 422, code: "idempotency_mismatch", message: "That key was used with a different request.") }
            return .json(status: hit.status, body: hit.body)
        }
        let reply = try work()
        if case .json(let status, let body) = reply, (200..<300).contains(status) {
            if idempotent[cacheKey] == nil { idempotentOrder.append(cacheKey) }
            idempotent[cacheKey] = (digest, status, body, now)
            if idempotentOrder.count > 256 { idempotent[idempotentOrder.removeFirst()] = nil }
        }
        return reply
    }

    // MARK: Events

    private func subscribe(_ r: AutomationRequest, _ client: AutomationClient) throws -> AutomationReply {
        guard let sub = events.subscribe(clientID: client.id, profile: client.profile, lastEventID: r.headers["last-event-id"]) else {
            throw AutomationError.busy
        }
        return .stream(sub)
    }
}
