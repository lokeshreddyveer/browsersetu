import Foundation

/// One meaningful moment in a download's life. No progress readings (those are the ledger's business), no raw error text, no query strings.
struct DiagnosticEntry: Codable, Equatable, Sendable {
    var at: Date
    /// created, engine_selected, queued, admitted, transfer_started, paused, resumed, retry_scheduled, verification_started, completed, failed, recovery_required,
    /// integrity_failed, scheduled_ready, cancelled, state_changed
    var category: String
    var state: String?
    var engine: String?
    var host: String?
    var retryAttempt: Int?
    var errorCategory: String?
    var bytes: Int64?
    var totalBytes: Int64?
    var integrity: String?
    var detail: String?
}

struct DiagnosticReport: Codable, Equatable {
    struct Engine: Codable, Equatable { var engine: String; var canPause: Bool; var canResume: Bool }
    struct Network: Codable, Equatable { var proxyActive: Bool; var maxConcurrent: Int; var queueHeld: Bool }
    struct Task: Codable, Equatable {
        var id: String
        var state: String
        var filename: String?
        var source: String?
        var sourceHost: String?
        var engine: String
        var errorCategory: String?
        var errorTitle: String?
        var advice: String?
        var timeline: [DiagnosticEntry]
    }
    var schema = DiagnosticReport.currentSchema
    var appVersion: String
    var generatedAt: Date
    var engines: [Engine]
    var network: Network
    var tasks: [Task]
    var truncated: Bool
    static let currentSchema = 1
    static let maxBytes = 256 * 1024
}

/// Per-task timelines, built from the one event feed. Bounded in tasks, in entries per task and in time; never holds a private download; written only when a profile keeps history.
@MainActor
final class DownloadDiagnostics: ObservableObject {
    static let maxTasks = 200
    static let maxEntries = 60

    @Published private(set) var storageProblem: String?
    private var timelines: [UUID: [DiagnosticEntry]] = [:]
    private var order: [UUID] = []
    private let file: URL?
    private let writer: (Data, URL) throws -> Void
    private var saveScheduled = false
    private let clock: () -> Date

    init(file: URL?, clock: @escaping () -> Date = Date.init, writer: ((Data, URL) throws -> Void)? = nil) {
        self.file = file; self.clock = clock
        self.writer = writer ?? { try $0.write(to: $1, options: .atomic) }
        if let file, let data = try? Data(contentsOf: file), let saved = try? AutomationJSON.decoder.decode([String: [DiagnosticEntry]].self, from: data) {
            for (key, entries) in saved { if let id = UUID(uuidString: key) { timelines[id] = Array(entries.suffix(Self.maxEntries)); order.append(id) } }
            order.sort { (timelines[$0]?.last?.at ?? .distantPast) < (timelines[$1]?.last?.at ?? .distantPast) }
        }
    }

    func timeline(for id: UUID) -> [DiagnosticEntry] { timelines[id] ?? [] }
    var taskCount: Int { timelines.count }

    /// Called for every event of the feed. Progress is ignored.
    func record(_ event: AutomationEvent, coordinator: DownloadCoordinator?) {
        guard event.type != "task.progress", let idText = event.taskID, let id = UUID(uuidString: idText), let coordinator,
              let record = coordinator.ledger.record(id), !record.isPrivate else { return }
        let category: String
        switch event.type {
        case "task.created": category = "created"
        case "task.started": category = "transfer_started"
        case "task.paused": category = "paused"
        case "task.resumed": category = "resumed"
        case "task.completed": category = "completed"
        case "task.failed": category = "failed"
        case "task.cancelled": category = "cancelled"
        case "task.recovery_required": category = "recovery_required"
        case "task.retry_scheduled": category = "retry_scheduled"
        case "task.scheduled_ready": category = "scheduled_ready"
        case "task.integrity_failed": category = "integrity_failed"
        default: category = event.state == "verifying" ? "verification_started" : "state_changed"
        }
        var entry = DiagnosticEntry(at: event.at, category: category, state: event.state, engine: record.protocolID.rawValue, host: DiagnosticRedactor.host(record.source.host),
                                    retryAttempt: record.retryCount > 0 ? record.retryCount : nil, errorCategory: nil, bytes: event.bytesReceived, totalBytes: record.transfer.totalBytes,
                                    integrity: record.file.integrity == .unknown ? nil : record.file.integrity.rawValue, detail: nil)
        if let failure = record.failure, category == "failed" || category == "recovery_required" || category == "retry_scheduled" {
            let cat = DownloadFailureCategory.classify(code: failure.code, reason: failure.reason)
            entry.errorCategory = cat.rawValue
            entry.detail = DiagnosticRedactor.text(failure.reason)
        }
        append(entry, for: id)
        if category == "created" {
            // Which engine took it is part of the story.
            append(DiagnosticEntry(at: event.at, category: "engine_selected", state: nil, engine: record.protocolID.rawValue, host: entry.host, retryAttempt: nil, errorCategory: nil, bytes: nil, totalBytes: nil, integrity: nil, detail: nil), for: id)
        }
    }

    private func append(_ entry: DiagnosticEntry, for id: UUID) {
        if timelines[id] == nil {
            timelines[id] = []; order.append(id)
            while order.count > Self.maxTasks { let old = order.removeFirst(); timelines[old] = nil }
        }
        timelines[id]!.append(entry)
        if timelines[id]!.count > Self.maxEntries { timelines[id]!.removeFirst(timelines[id]!.count - Self.maxEntries) }
        scheduleSave()
    }

    /// Timelines of downloads that are no longer in the ledger (cleared from the list) are dropped, so history the person removed does not linger here.
    func prune(keeping coordinator: DownloadCoordinator) {
        let gone = timelines.keys.filter { coordinator.ledger.record($0) == nil }
        guard !gone.isEmpty else { return }
        for id in gone { timelines[id] = nil }
        order.removeAll { timelines[$0] == nil }
        scheduleSave()
    }

    func forget(_ id: UUID) { timelines[id] = nil; order.removeAll { $0 == id }; scheduleSave() }

    private func scheduleSave() {
        guard file != nil, !saveScheduled else { return }
        saveScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.saveScheduled = false
            self?.saveNow()
        }
    }

    /// A save that fails is reported, never thrown at the download: diagnostics must not be able to hurt a transfer.
    @discardableResult
    func saveNow() -> Bool {
        guard let file else { return true }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let out = Dictionary(uniqueKeysWithValues: timelines.map { ($0.key.uuidString, $0.value) })
            try writer(try AutomationJSON.encoder.encode(out), file)
            storageProblem = nil
            return true
        } catch {
            storageProblem = "Diagnostics could not be saved: \((error as NSError).localizedDescription)"
            return false
        }
    }

    // MARK: Export

    /// A report for the chosen downloads. Private downloads are never included, whatever was asked for. The result fits in `maxBytes`: the oldest entries go first, then whole tasks.
    func report(for ids: [UUID], coordinator: DownloadCoordinator, appVersion: String, maxBytes: Int = DiagnosticReport.maxBytes) -> DiagnosticReport {
        var tasks: [DiagnosticReport.Task] = []
        for id in ids {
            guard let r = coordinator.ledger.record(id), !r.isPrivate else { continue }
            let failure = r.failure.map { DownloadFailureCategory.classify(code: $0.code, reason: $0.reason) }
            tasks.append(.init(id: id.uuidString, state: r.state.rawValue, filename: DiagnosticRedactor.filename(r.file.filename), source: DiagnosticRedactor.url(r.source.url),
                               sourceHost: DiagnosticRedactor.host(r.source.host), engine: r.protocolID.rawValue, errorCategory: failure?.rawValue, errorTitle: failure?.title,
                               advice: failure?.advice, timeline: timeline(for: id)))
        }
        let engines = ["webkit", "http", "http-pieces", "bittorrent", "ed2k"].map {
            DiagnosticReport.Engine(engine: $0, canPause: coordinator.engines.can(.pause, DownloadProtocolID(rawValue: $0)), canResume: coordinator.engines.can(.resume, DownloadProtocolID(rawValue: $0)))
        }
        var report = DiagnosticReport(appVersion: appVersion, generatedAt: clock(), engines: engines,
                                      network: .init(proxyActive: ProxyState.active, maxConcurrent: coordinator.maxConcurrent, queueHeld: coordinator.scheduler.isHeld), tasks: tasks, truncated: false)
        func size() -> Int { (try? AutomationJSON.encoder.encode(report).count) ?? Int.max }
        while size() > maxBytes {
            report.truncated = true
            if let i = report.tasks.indices.max(by: { report.tasks[$0].timeline.count < report.tasks[$1].timeline.count }), report.tasks[i].timeline.count > 1 {
                report.tasks[i].timeline.removeFirst(max(1, report.tasks[i].timeline.count / 4))
            } else if !report.tasks.isEmpty { report.tasks.removeLast() } else { break }
        }
        return report
    }

    static func json(_ report: DiagnosticReport) -> String { String(data: (try? AutomationJSON.encoder.encode(report)) ?? Data(), encoding: .utf8) ?? "{}" }

    /// A short readable summary of the same report, for pasting into a message.
    static func text(_ report: DiagnosticReport) -> String {
        var lines = ["Browser Setu download diagnostics (schema \(report.schema))", "App version: \(report.appVersion)", "Created: \(ISO8601DateFormatter().string(from: report.generatedAt))",
                     "Proxy active: \(report.network.proxyActive ? "yes" : "no"), at once: \(report.network.maxConcurrent), queue held: \(report.network.queueHeld ? "yes" : "no")"]
        for t in report.tasks {
            lines.append("")
            lines.append("\(t.filename ?? "download") — \(t.state) via \(t.engine)\(t.sourceHost.map { " from \($0)" } ?? "")")
            if let title = t.errorTitle { lines.append("  Problem: \(title). \(t.advice ?? "")") }
            for e in t.timeline { lines.append("  \(ISO8601DateFormatter().string(from: e.at))  \(e.category)\(e.errorCategory.map { " [\($0)]" } ?? "")\(e.retryAttempt.map { " attempt \($0)" } ?? "")") }
        }
        if report.truncated { lines.append("\n(Shortened to fit the size limit.)") }
        return lines.joined(separator: "\n")
    }
}
