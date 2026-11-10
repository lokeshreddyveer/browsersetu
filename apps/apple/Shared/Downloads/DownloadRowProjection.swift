import Foundation

// What the Downloads dashboard shows, worked out from the ledger (the one record of every task) and the few live facts the ledger does not keep (speed, line position).
// Nothing here changes a task: a row is a read-only description, and what a person may do with it is a set of actions that the coordinator then carries out.

/// The one word a row is filed under. Filters and sorting use this, never the raw ledger state.
enum DownloadRowStatus: String, CaseIterable, Sendable {
    case downloading, verifying, queued, retrying, scheduled, paused, completed, failed, recoveryRequired, cancelled

    /// Moving, or about to be.
    var isActive: Bool { self == .downloading || self == .verifying || self == .retrying }
    /// Over for good; only removing the record remains.
    var isOver: Bool { self == .completed || self == .cancelled }
}

/// What can be done with a row right now. Offered only when it will work.
struct DownloadRowActions: OptionSet, Sendable {
    let rawValue: Int
    static let pause = Self(rawValue: 1 << 0)
    /// Carry on from kept data, or start over when nothing usable is kept (the row says which).
    static let resume = Self(rawValue: 1 << 1)
    static let retry = Self(rawValue: 1 << 2)
    /// Stop a running, waiting or put-off download. Never offered for a finished one.
    static let cancel = Self(rawValue: 1 << 3)
    static let startNow = Self(rawValue: 1 << 4)
    static let setPriority = Self(rawValue: 1 << 5)
    /// Forget the record. The file, if there is one, is not touched.
    static let removeRecord = Self(rawValue: 1 << 6)
    static let open = Self(rawValue: 1 << 7)
    static let reveal = Self(rawValue: 1 << 8)
    /// Move the downloaded file to the Trash. Always behind a confirmation.
    static let trashFile = Self(rawValue: 1 << 9)
    static let rename = Self(rawValue: 1 << 10)
    static let move = Self(rawValue: 1 << 11)
    /// Calculate the file's SHA-256 again and compare it with the checksum that was given, if one was.
    static let verify = Self(rawValue: 1 << 12)
    static let extract = Self(rawValue: 1 << 13)
    static let copyPath = Self(rawValue: 1 << 14)
    static let openFolder = Self(rawValue: 1 << 15)
}

struct DownloadRow: Identifiable, Equatable, Sendable {
    let id: UUID
    var filename: String
    /// Only the site's name. The address itself, which may carry a signed token, is never part of a row.
    var host: String
    var protocolLabel: String
    var status: DownloadRowStatus
    /// "Downloading", "Waiting · #2 in line", "Paused", "Stopped part-way" …
    var statusText: String
    /// One secondary line: sizes and speed while moving, the reason while waiting or stopped.
    var detail: String
    var totalBytes: Int64?
    var completedBytes: Int64
    /// 0...1, or nil when the total is not known (the row shows an indeterminate bar, never an invented percentage).
    var fraction: Double?
    var bytesPerSecond: Double?
    var secondsLeft: Double?
    var priority: DownloadPriority
    var date: Date
    var queuePosition: Int?
    var dueAt: Date?
    var actions: DownloadRowActions
    /// What the one resume action really does ("Resume" or "Start Over"), when resuming is offered.
    var resumeTitle: String
    var retryAttempt: Int
    var connections: Int?
    var pieces: Int?
    var piecesDone: Int?
    /// A person-readable message for a stopped download; nil otherwise.
    var problem: String?
    /// The code behind the message, for the technical section only.
    var technicalCode: String?
    var destinationName: String?
    var isPrivate: Bool
    /// The address as it may be shown: the site and path, never the query (which can hold a signed token); only the site when the path itself looks signed.
    var sourceDisplay: String = ""
    var destinationPath: String?
    /// The ledger's own word for the state, for the technical section.
    var stateName: String = ""
    var attempt: Int = 0
    /// What "Resume" / "Start Over" means for this task, in words; nil when there is nothing to decide.
    var recoveryNote: String?
    var protocolID: String = ""
    /// A row from the history kept before the task database: it has no task behind it, so only opening and showing its file are possible.
    var isLegacy = false
    var fileCategory = ""
    /// What the integrity check found, in words that do not call a bare digest "verified".
    var integrityText = ""
    var sha256: String?
    /// True: matched a checksum that was given. False: did not match. Nil: nothing to compare against.
    var integrityMatched: Bool?

    // Sort keys. Optional and unknown values sort first, so rows without a size are not mixed in among real ones.
    var sortSize: Int64 { totalBytes ?? -1 }
    var sortProgress: Double { fraction ?? -1 }
    var sortPriority: Int { priority.rawValue }
    var sortStatus: String { status.rawValue }

    var accessibilitySummary: String {
        var parts = [filename, statusText]
        if let fraction { parts.append("\(Int((fraction * 100).rounded())) percent") }
        if let problem { parts.append(problem) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Wording

enum DownloadFormat {
    /// "42%", or nil when there is no honest number to give.
    static func percent(_ fraction: Double?) -> String? { fraction.map { "\(Int(max(0, min(1, $0)) * 100))%" } }

    static func speed(_ bytesPerSecond: Double?) -> String? {
        guard let bytesPerSecond, bytesPerSecond > 1 else { return nil }
        return "\(DownloadStats.bytes(Int64(bytesPerSecond)))/s"
    }

    static func eta(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        return DownloadStats.duration(seconds)
    }

    static func size(_ bytes: Int64?) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        return DownloadStats.bytes(bytes)
    }

    /// "48 MB of 78 MB", "48 MB" when the total is unknown, nil for nothing yet.
    static func progress(completed: Int64, total: Int64?) -> String? {
        if let total, total > 0 { return "\(DownloadStats.bytes(completed)) of \(DownloadStats.bytes(total))" }
        return completed > 0 ? DownloadStats.bytes(completed) : nil
    }
}

/// Turns what the engines recorded into a short message a person can act on. Technical codes stay out of it and go to the details section.
enum DownloadErrorPresenter {
    static func message(reason: String?, code: String?) -> String {
        let code = code ?? ""
        let lower = (reason ?? "").lowercased()
        if code == "retry-not-scheduled" { return "Browser Setu could not schedule another try. Try again to start it over." }
        if code.contains("-1009") || code.contains("-1005") || code.contains("-1004") || code.contains("-1001") || lower.contains("connection") { return "The network connection was lost." }
        if code.hasSuffix("403") || code.hasSuffix("401") || lower.contains("refused") || lower.contains("not allowed") { return "The website refused the download." }
        if code.hasSuffix("404") || code.hasSuffix("410") || lower.contains("no longer") || lower.contains("not found") { return "The file is no longer available." }
        if code.hasSuffix("412") || lower.contains("changed") { return "The website changed the file, so it cannot carry on." }
        if code.hasSuffix("416") || lower.contains("resume") && lower.contains("not") { return "The website does not allow this to carry on." }
        if code.contains("640") || lower.contains("space") || lower.contains("disk is full") { return "There is not enough space on the disk." }
        if lower.contains("destination") || lower.contains("folder") && lower.contains("not") { return "The downloads folder is not available." }
        let text = scrub(reason ?? "")
        return text.isEmpty ? "It could not be downloaded." : text
    }

    /// Any web address inside free text is shown without its query, user name or fragment.
    static func scrub(_ text: String) -> String {
        text.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
            let w = String(word)
            guard w.hasPrefix("http://") || w.hasPrefix("https://") else { return w }
            return DownloadURLRedactor.redact(w)
        }.joined(separator: " ")
    }
}

// MARK: - Projection

/// Everything one rebuild of the list needs, gathered once on the main actor, so the projection itself is a plain function that can be tested with any combination.
struct DownloadsSnapshot {
    var records: [DownloadTaskRecord]
    var live: [UUID: ActiveDownload] = [:]
    var positions: [UUID: Int] = [:]
    var waiting: [UUID: QueuedDownload] = [:]
    var recoveries: [UUID: DownloadRecoveryClass] = [:]
    var canPause: Set<UUID> = []
    var canRetry: Set<UUID> = []
    /// Tasks the coordinator can carry on (from kept data) or start over from their address.
    var canResume: Set<UUID> = []
    var overdue: Set<UUID> = []
    var queueNote: String?
    var canControl: (DownloadProtocolID, DownloadEngineCapabilities) -> Bool = { _, _ in true }
    var fileExists: (DownloadTaskRecord) -> Bool = { _ in false }
    /// The size of a finished download's file as it is on disk now (only asked for a completed row whose record never stored one).
    var fileSize: (DownloadTaskRecord) -> Int64? = { _ in nil }
    /// Whether the finished file is something that can be opened into a folder (a plain .zip).
    var isExtractable: (DownloadTaskRecord) -> Bool = { _ in false }
}

enum DownloadRowProjector {
    /// A finished download is shown for as long as the ledger keeps it; the list never grows past this.
    static let maxRows = 1_000

    static func rows(from snapshot: DownloadsSnapshot) -> [DownloadRow] {
        // Built from the records that will be shown only: a long history is cut BEFORE its rows are made (making a row asks the disk whether the file is still there).
        var live: [DownloadTaskRecord] = [], over: [DownloadTaskRecord] = []
        for record in snapshot.records {
            // A private download is shown only while it is under way; nothing about a finished one outlives it.
            if record.isPrivate, record.state.isFinal || record.state == .failed { continue }
            if status(of: record.state).isOver { over.append(record) } else { live.append(record) }
        }
        var rows = live.map { row(for: $0, in: snapshot) }
        let room = max(0, maxRows - rows.count)
        let newest = over.count > room ? Array(over.sorted { ($0.completedAt ?? $0.createdAt) > ($1.completedAt ?? $1.createdAt) }.prefix(room)) : over
        rows += newest.map { row(for: $0, in: snapshot) }
        return rows
    }

    static func row(for record: DownloadTaskRecord, in s: DownloadsSnapshot) -> DownloadRow {
        let live = s.live[record.id]
        let status = status(of: record.state)
        var total = record.transfer.totalBytes ?? ((live?.totalBytes ?? 0) > 0 ? live?.totalBytes : nil)
        // An older download whose record never kept a size shows the real size of its file, when the file is still there; with no file and no record the size stays unknown.
        if total == nil, status == .completed, let onDisk = s.fileSize(record) { total = onDisk }
        let completed = status == .downloading ? max(live?.completedBytes ?? 0, record.transfer.completedBytes) : record.transfer.completedBytes
        var fraction: Double?
        if status == .completed { fraction = 1 }
        else if let total, total > 0 { fraction = max(0, min(1, Double(completed) / Double(total))) }
        else if status == .downloading, let live, live.fraction > 0 { fraction = live.fraction }
        let speed = status == .downloading ? (live?.bytesPerSecond).flatMap { $0 > 1 ? $0 : nil } : nil
        let left = speed.flatMap { DownloadStats.secondsLeft(completed: completed, total: total ?? 0, rate: $0) }
        let position = s.positions[record.id]
        let recovery = s.recoveries[record.id]
        let problem = problemText(for: record, recovery: recovery)

        var actions: DownloadRowActions = []
        var resumeTitle = "Resume"
        switch record.state {
        case .created, .resolving: actions = [.cancel]
        case .starting, .running, .resuming, .pausing:
            actions = [.cancel, .setPriority]
            if s.canPause.contains(record.id) { actions.insert(.pause) }
        case .queued: actions = [.cancel, .setPriority]
        case .retrying: actions = [.cancel, .setPriority]
        case .scheduled: actions = [.cancel, .setPriority, .startNow]
        case .verifying: actions = []                                      // being put in place; cancelling now would race the move
        case .paused:
            actions = [.cancel, .setPriority]
            if s.canResume.contains(record.id) { actions.insert(.resume) }
            if let title = recovery?.actionTitle { resumeTitle = title }
        case .recoveryRequired:
            actions = [.removeRecord]
            if s.canResume.contains(record.id) { actions.insert(.resume); resumeTitle = recovery?.actionTitle ?? "Resume" }
        case .failed:
            actions = [.removeRecord]
            if s.canRetry.contains(record.id) { actions.insert(.retry) }
        case .completed:
            actions = [.removeRecord]
            if s.fileExists(record) {
                actions.formUnion([.open, .reveal, .trashFile, .rename, .move, .verify, .copyPath, .openFolder])
                if s.isExtractable(record) { actions.insert(.extract) }
            }
        case .cancelled: actions = [.removeRecord]
        }

        var text = statusText(status, record: record, position: position, overdue: s.overdue.contains(record.id), recovery: recovery)
        var detail = detailText(status, record: record, live: live, completed: completed, total: total, speed: speed, left: left, note: s.queueNote, problem: problem, dueAt: record.scheduledAt, overdue: s.overdue.contains(record.id))
        if record.state == .pausing { text = "Pausing…" }
        if status == .downloading, fraction == nil, completed == 0, detail.isEmpty { detail = "Starting…" }
        let meta = record.engineMetadata
        var note: String?
        if let recovery { note = recovery.summary }
        else if record.state == .paused { note = s.canResume.contains(record.id) ? "Resume carries on from \(DownloadFormat.size(completed) ?? "where it stopped")." : "It cannot be resumed; cancel it and download again." }
        var built = DownloadRow(
            id: record.id, filename: record.file.filename, host: record.source.host ?? "", protocolLabel: protocolLabel(record.protocolID), status: status, statusText: text, detail: detail,
            totalBytes: total, completedBytes: completed, fraction: fraction, bytesPerSecond: speed, secondsLeft: left, priority: record.priority,
            date: record.completedAt ?? record.createdAt, queuePosition: position, dueAt: record.scheduledAt, actions: actions, resumeTitle: resumeTitle, retryAttempt: record.retryCount,
            connections: meta["connections"].flatMap(Int.init), pieces: meta["pieces"].flatMap(Int.init), piecesDone: meta["piecesDone"].flatMap(Int.init),
            problem: problem, technicalCode: record.failure?.code, destinationName: record.file.destinationPath.map { ($0 as NSString).lastPathComponent }, isPrivate: record.isPrivate)
        built.sourceDisplay = displayAddress(record.source)
        built.destinationPath = record.file.destinationPath
        built.stateName = record.state.rawValue
        built.attempt = record.attempt
        built.recoveryNote = note
        built.protocolID = record.protocolID.rawValue
        built.fileCategory = DownloadCategory.of(filename: record.file.filename).rawValue
        built.sha256 = record.engineMetadata["sha256Computed"]
        switch record.file.integrity {
        case .mismatch: built.integrityMatched = false
        case .verified: built.integrityMatched = record.engineMetadata["sha256"] != nil ? true : nil
        case .unknown: built.integrityMatched = nil
        }
        built.integrityText = integrityText(record)
        return built
    }

    /// What the check found. Only a match with a checksum that was given is called a match; a digest on its own is described as calculated, not verified.
    static func integrityText(_ record: DownloadTaskRecord) -> String {
        guard record.state == .completed else { return "" }
        let given = record.engineMetadata["sha256"] != nil
        let trusted = record.engineMetadata["sha256From"] == "user"
        switch record.file.integrity {
        case .mismatch: return given ? "Does not match the checksum it was given." : "The file is not the size the server said."
        case .verified:
            if record.engineMetadata["ed2k"] == "1", !given { return "Every part matches the file's eD2k hash (MD4). That shows it is the file the link names; MD4 is weak, so it does not prove the file is genuine or safe." }
            if given { return trusted ? "Matches the checksum you gave." : "Matches the checksum supplied with the request." }
            return "The size matches what the server said."
        case .unknown: return record.engineMetadata["sha256Computed"] != nil ? "SHA-256 calculated. This is not proof the file is genuine." : "Not checked."
        }
    }

    /// Site and path, without the query, fragment or credentials. A path that itself looks like a token is cut back to the site.
    static func displayAddress(_ source: DownloadSourceRef) -> String {
        guard let url = source.asURL, let host = url.host else { return source.host ?? "" }
        if DownloadURLRedactor.looksSigned(url) { return host }
        let path = url.path
        return path.isEmpty || path == "/" ? host : host + path
    }

    static func status(of state: DownloadState) -> DownloadRowStatus {
        switch state {
        case .created, .resolving, .queued: .queued
        case .scheduled: .scheduled
        case .starting, .running, .pausing, .resuming: .downloading
        case .paused: .paused
        case .verifying: .verifying
        case .retrying: .retrying
        case .completed: .completed
        case .failed: .failed
        case .cancelled: .cancelled
        case .recoveryRequired: .recoveryRequired
        }
    }

    static func protocolLabel(_ id: DownloadProtocolID) -> String {
        switch id {
        case .webKit: "Browser"
        case .http, .httpPieces: "HTTP"
        case "processed": "Made here"          // a file this app joined or converted from other downloads
        default: id.rawValue.uppercased()
        }
    }

    private static func problemText(for record: DownloadTaskRecord, recovery: DownloadRecoveryClass?) -> String? {
        switch record.state {
        case .failed: return DownloadErrorPresenter.message(reason: record.failure?.reason, code: record.failure?.code)
        case .recoveryRequired: return recovery?.summary ?? DownloadErrorPresenter.message(reason: record.failure?.reason, code: record.failure?.code)
        default: return nil
        }
    }

    private static func statusText(_ status: DownloadRowStatus, record: DownloadTaskRecord, position: Int?, overdue: Bool, recovery: DownloadRecoveryClass?) -> String {
        switch status {
        case .downloading: "Downloading"
        case .verifying: "Finishing"
        case .queued: record.state == .queued || record.state == .created || record.state == .resolving ? (position.map { "Waiting · #\($0) in line" } ?? "Waiting") : "Waiting"
        case .retrying: "Trying again" + (record.retryCount > 0 ? " (attempt \(record.retryCount + 1))" : "")
        case .scheduled: overdue ? "Missed its start" : (record.scheduledAt == nil ? "Held" : "Scheduled")
        case .paused: "Paused"
        case .completed: "Completed"
        case .failed: "Failed"
        case .recoveryRequired: recovery.map { recoveryTitle($0) } ?? "Stopped part-way"
        case .cancelled: "Cancelled"
        }
    }

    private static func recoveryTitle(_ c: DownloadRecoveryClass) -> String {
        switch c {
        case .resumable: "Can resume"
        case .restartRequired: "Must start over"
        case .needsNewLink: "Needs a new link"
        case .cannotRecover: "Cannot recover"
        }
    }

    private static func detailText(_ status: DownloadRowStatus, record: DownloadTaskRecord, live: ActiveDownload?, completed: Int64, total: Int64?, speed: Double?, left: Double?,
                                   note: String?, problem: String?, dueAt: Date?, overdue: Bool) -> String {
        switch status {
        case .downloading:
            return [DownloadFormat.progress(completed: completed, total: total), DownloadFormat.speed(speed), DownloadFormat.eta(left).map { "about \($0) left" }].compactMap { $0 }.joined(separator: " · ")
        case .verifying: return "Checking the file"
        case .queued: return note ?? "Waiting for a free place"
        case .retrying:
            if let at = record.retryAt { return "Next try at \(at.formatted(date: .omitted, time: .shortened))" + (record.failure.map { " · " + DownloadErrorPresenter.message(reason: $0.reason, code: $0.code) } ?? "") }
            return "Waiting to try again"
        case .scheduled:
            if overdue { return "It was due while Browser Setu was closed. Start it when you are ready." }
            return dueAt.map { "Starts \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Held until the queue is released"
        case .paused: return DownloadFormat.progress(completed: completed, total: total) ?? "Paused"
        case .completed: return [DownloadFormat.size(total ?? completed), record.completedAt.map { $0.formatted(date: .abbreviated, time: .shortened) }].compactMap { $0 }.joined(separator: " · ")
        case .failed, .recoveryRequired: return problem ?? ""
        case .cancelled: return "Cancelled"
        }
    }
}

// MARK: - Filtering, searching, sorting

enum DownloadFilter: String, CaseIterable, Identifiable, Sendable {
    case all, active, queued, scheduled, paused, completed, failed, recovery
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All"; case .active: "Active"; case .queued: "Queued"; case .scheduled: "Scheduled"; case .paused: "Paused"
        case .completed: "Completed"; case .failed: "Failed"; case .recovery: "Recovery Required"
        }
    }
    var symbol: String {
        switch self {
        case .all: "tray.full"; case .active: "arrow.down.circle"; case .queued: "list.number"; case .scheduled: "clock"; case .paused: "pause.circle"
        case .completed: "checkmark.circle"; case .failed: "exclamationmark.triangle"; case .recovery: "arrow.triangle.2.circlepath"
        }
    }

    func matches(_ status: DownloadRowStatus) -> Bool {
        switch self {
        case .all: true
        case .active: status.isActive
        case .queued: status == .queued
        case .scheduled: status == .scheduled
        case .paused: status == .paused
        case .completed: status == .completed
        case .failed: status == .failed
        case .recovery: status == .recoveryRequired
        }
    }
}

enum DownloadSortKey: String, CaseIterable, Identifiable, Sendable {
    case date, name, size, progress, status, priority
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct DownloadQuery: Equatable, Sendable {
    var search = ""
    var filter: DownloadFilter = .all
    var protocolLabel: String?
    var priority: DownloadPriority?
    var sort: DownloadSortKey = .date
    var ascending = false

    func apply(to rows: [DownloadRow]) -> [DownloadRow] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        let kept = rows.filter { row in
            filter.matches(row.status)
                && (protocolLabel == nil || row.protocolLabel == protocolLabel)
                && (priority == nil || row.priority == priority)
                // The file name and the site's name only: never the address, so a signed token cannot be searched for or matched.
                && (needle.isEmpty || row.filename.lowercased().contains(needle) || row.host.lowercased().contains(needle))
        }
        return kept.sorted { a, b in
            let order = Self.compare(a, b, by: sort)
            if order != .orderedSame { return ascending ? order == .orderedAscending : order == .orderedDescending }
            // Equal on the chosen key: the same order every time, so rows do not trade places as numbers change.
            return a.id.uuidString < b.id.uuidString
        }
    }

    static func compare(_ a: DownloadRow, _ b: DownloadRow, by key: DownloadSortKey) -> ComparisonResult {
        func c<T: Comparable>(_ x: T, _ y: T) -> ComparisonResult { x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame) }
        switch key {
        case .date: return c(a.date, b.date)
        case .name: return a.filename.localizedStandardCompare(b.filename)
        case .size: return c(a.totalBytes ?? -1, b.totalBytes ?? -1)
        case .progress: return c(a.fraction ?? -1, b.fraction ?? -1)
        case .status: return c(a.status.rawValue, b.status.rawValue)
        case .priority: return c(a.priority, b.priority)
        }
    }

    static func counts(of rows: [DownloadRow]) -> [DownloadFilter: Int] {
        Dictionary(uniqueKeysWithValues: DownloadFilter.allCases.map { f in (f, rows.filter { f.matches($0.status) }.count) })
    }
}

// MARK: - Selection and batches

/// What a selection allows. An action is offered when at least one selected row supports it, and carries out only on those rows: a batch never does something to a task that cannot take it.
enum DownloadBatch {
    static func eligible(_ action: DownloadRowActions, in rows: [DownloadRow], selection: Set<UUID>) -> [DownloadRow] {
        rows.filter { selection.contains($0.id) && $0.actions.contains(action) }
    }

    static func allowed(in rows: [DownloadRow], selection: Set<UUID>) -> DownloadRowActions {
        rows.filter { selection.contains($0.id) }.reduce(into: DownloadRowActions()) { $0.formUnion($1.actions) }
    }
}

/// How a chosen action is carried out. The coordinator is the one implementation; tests use a recorder.
@MainActor
protocol DownloadActionPerforming: AnyObject {
    func performPause(_ id: UUID)
    func performResume(_ id: UUID)
    func performRetry(_ id: UUID)
    func performCancel(_ id: UUID, status: DownloadRowStatus)
    func performStartNow(_ id: UUID)
    func performSetPriority(_ id: UUID, _ priority: DownloadPriority)
    func performRemoveRecord(_ id: UUID)
}
