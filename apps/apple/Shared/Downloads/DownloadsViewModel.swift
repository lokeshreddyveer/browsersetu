import Foundation
import Combine

// The Downloads dashboard's single view of the coordinator. It holds no task state of its own: it rebuilds a list of read-only rows from the ledger, at a bounded rate, and hands
// the person's choices back to the coordinator. The full window and the toolbar popover share one of these, so they can never disagree.

extension DownloadCoordinator {
    /// Everything one rebuild of the rows needs. Read from the ledger and the coordinator's lists; no database query.
    func dashboardSnapshot(fileExists: @escaping (DownloadTaskRecord) -> Bool, fileSize: @escaping (DownloadTaskRecord) -> Int64? = { _ in nil }) -> DownloadsSnapshot {
        var snapshot = DownloadsSnapshot(records: Array(ledger.records.values))
        snapshot.live = active
        for item in waiting { snapshot.waiting[item.id] = item; snapshot.positions[item.id] = item.position }
        for (id, item) in interrupted { snapshot.recoveries[id] = item.recovery; snapshot.canResume.insert(id) }
        for failure in failures {
            if let kind = failure.recovery { snapshot.recoveries[failure.id] = kind }
            if failure.canRetry { snapshot.canRetry.insert(failure.id) }
            if failure.canRetry, failure.recovery?.canAct == true { snapshot.canResume.insert(failure.id) }
        }
        snapshot.canPause = Set(active.keys.filter { canPause($0) })
        snapshot.overdue = overdue
        snapshot.queueNote = queueNote
        snapshot.canControl = { [engines] proto, cap in engines.can(cap, proto) }
        snapshot.fileExists = fileExists
        snapshot.fileSize = fileSize
        return snapshot
    }

    /// Where a finished download's file is, if it is still there and inside the downloads folder.
    func fileURL(for record: DownloadTaskRecord) -> URL? {
        if let path = record.file.destinationPath {
            // The record says exactly where the file went. If it is no longer there (moved, renamed, deleted) nothing is shown, rather than another file that happens to share its name.
            return DownloadPathPolicy.isAuthorized(path, roots: managedRoots) && FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        return Self.locate(filename: record.file.filename)
    }

    /// Forgets a task's record (and its entry in the "stopped" lists). The downloaded file, if there is one, is not touched.
    func removeRecord(_ id: UUID) {
        if failures.contains(where: { $0.id == id }) { dismissFailure(id); return }
        if interrupted[id] != nil { dismissInterrupted(id); return }
        guard let record = ledger.record(id), record.state.isFinal || record.state == .failed || record.state == .recoveryRequired else { return }
        ledger.remove(id)
    }

    /// Moves a finished download's file to the Trash. The caller has already asked the person; only a completed task's file inside the downloads folder qualifies.
    @discardableResult
    func trashFile(of id: UUID) -> Bool {
        guard let file = managedFile(of: id), let record = ledger.record(id) else { return false }
        do { try DownloadFileOperations.trash(file, roots: managedRoots); return true } catch { note("Could not move \(record.file.filename) to the Trash"); return false }
    }
}

extension DownloadCoordinator: DownloadActionPerforming {
    func performPause(_ id: UUID) { pause(id) }
    func performResume(_ id: UUID) { if interrupted[id] != nil { resume(id) } else { retryFailure(id) } }
    func performRetry(_ id: UUID) { retryFailure(id) }
    func performStartNow(_ id: UUID) { startScheduled(id) }
    func performSetPriority(_ id: UUID, _ priority: DownloadPriority) { setPriority(id, priority) }
    func performRemoveRecord(_ id: UUID) { removeRecord(id) }

    func performCancel(_ id: UUID, status: DownloadRowStatus) {
        switch status {
        case .scheduled: removeScheduled(id)
        case .queued: if waiting.contains(where: { $0.id == id }) { cancelWaiting(id) } else { cancel(id) }
        case .paused, .recoveryRequired: dismissInterrupted(id)
        case .downloading, .retrying: cancel(id)
        case .verifying, .completed, .failed, .cancelled: break        // nothing to cancel: finishing downloads complete, the others are over
        }
    }
}

@MainActor
final class DownloadsViewModel: ObservableObject {
    /// Every row the ledger describes, unfiltered.
    @Published private(set) var rows: [DownloadRow] = []
    /// The rows that pass the search and filters, in the chosen order.
    @Published private(set) var visible: [DownloadRow] = []
    @Published private(set) var counts: [DownloadFilter: Int] = [:]
    @Published var query: DownloadQuery { didSet { if query != oldValue { savePreferences(); recompute() } } }
    @Published var selection: Set<UUID> = []
    @Published private(set) var held: Bool = false
    @Published private(set) var holdNote: String?
    @Published var inspectorShown = true { didSet { defaults?.set(inspectorShown, forKey: Keys.inspector) } }
    /// Rows awaiting the person's confirmation to move their files to the Trash.
    @Published var pendingTrash: [DownloadRow] = []
    /// One line about what the last file operation did or why it did not, for the window to show for a moment.
    @Published var message: String?
    /// How many pages of the older history (from before the task database) are shown, and whether the core has more.
    @Published private(set) var historyPages = 1
    @Published private(set) var hasMoreHistory = false
    private var legacyEntries: [DownloadLegacyHistory.Entry] = []
    private var legacyByID: [UUID: DownloadLegacyHistory.Entry] = [:]
    /// Reads the older history (the Rust core's list, newest first). Nil where there is none.
    typealias LegacySource = @Sendable (UInt32) throws -> [(url: String, filename: String, created: Int64)]
    private let legacy: LegacySource?
    private var extractCache: [UUID: Bool] = [:]

    /// How many times the rows were rebuilt. Tests use it to show that a burst of progress ticks costs a few rebuilds, not one each.
    private(set) var rebuilds = 0
    /// Counts out-of-date results thrown away (a rebuild started before a newer one finished).
    private(set) var generation = 0

    private weak var coordinator: DownloadCoordinator?
    /// The timelines, set by the browser model. nil leaves the diagnostics section out.
    var diagnostics: DownloadDiagnostics?
    private let performer: DownloadActionPerforming

    /// Why a task failed, in plain categories (nil for one that did not fail).
    func failureCategory(for id: UUID) -> DownloadFailureCategory? {
        coordinator?.ledger.record(id)?.failure.map { DownloadFailureCategory.classify(code: $0.code, reason: $0.reason) }
    }
    func timeline(for id: UUID) -> [DiagnosticEntry] { diagnostics?.timeline(for: id) ?? [] }
    /// The redacted report for one download, ready to be looked at before it is shared.
    func diagnosticReport(for id: UUID) -> DiagnosticReport? {
        guard let coordinator, let diagnostics else { return nil }
        return diagnostics.report(for: [id], coordinator: coordinator, appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")
    }
    private let defaults: UserDefaults?
    private var cancellables = Set<AnyCancellable>()
    private var pendingRefresh: Task<Void, Never>?
    private var pendingDeadline = Date.distantFuture
    private var fileCache: [UUID: Bool] = [:]
    private var diskSizes: [UUID: Int64] = [:]
    private var lastActiveKeys = Set<UUID>()

    /// A state change shows within this long; the numbers of a running transfer are refreshed at the slower rate.
    let changeDelay: TimeInterval, progressDelay: TimeInterval

    private enum Keys {
        static let filter = "downloads.filter", sort = "downloads.sort", ascending = "downloads.ascending", inspector = "downloads.inspector"
    }

    init(coordinator: DownloadCoordinator, performer: DownloadActionPerforming? = nil, legacy: LegacySource? = nil, defaults: UserDefaults? = .standard, changeDelay: TimeInterval = 0.12, progressDelay: TimeInterval = 0.5) {
        self.coordinator = coordinator; self.performer = performer ?? coordinator; self.defaults = defaults; self.legacy = legacy
        self.changeDelay = changeDelay; self.progressDelay = progressDelay
        var q = DownloadQuery()
        if let f = defaults?.string(forKey: Keys.filter).flatMap(DownloadFilter.init(rawValue:)) { q.filter = f }
        if let s = defaults?.string(forKey: Keys.sort).flatMap(DownloadSortKey.init(rawValue:)) { q.sort = s }
        if defaults?.object(forKey: Keys.ascending) != nil { q.ascending = defaults?.bool(forKey: Keys.ascending) ?? false }
        query = q
        if defaults?.object(forKey: Keys.inspector) != nil { inspectorShown = defaults?.bool(forKey: Keys.inspector) ?? true }
        refreshNow()
    }

    deinit { pendingRefresh?.cancel() }

    func serves(_ other: DownloadCoordinator) -> Bool { coordinator === other }

    // MARK: Who is looking

    /// The window and the popover both show this model. It listens to the coordinator only while at least one of them is on screen, so a closed Downloads view costs nothing.
    private var viewers = 0
    func acquire() {
        viewers += 1
        guard viewers == 1, let coordinator else { return }
        lastActiveKeys = Set(coordinator.active.keys)
        attach(to: coordinator)
        recheckFiles()
        loadLegacy()
    }

    func release() {
        viewers = max(0, viewers - 1)
        if viewers == 0 { detach() }
    }

    // MARK: Observing

    private func attach(to c: DownloadCoordinator) {
        c.tasksChanged.sink { [weak self] in self?.refresh(after: self?.changeDelay ?? 0) }.store(in: &cancellables)
        c.$active.dropFirst().sink { [weak self] active in
            guard let self else { return }
            let keys = Set(active.keys)
            // A download that started or ended shows promptly; byte counts and speed on the slower beat.
            let changed = keys != lastActiveKeys
            lastActiveKeys = keys
            refresh(after: changed ? changeDelay : progressDelay)
        }.store(in: &cancellables)
        Publishers.MergeMany(c.$failures.dropFirst().map { _ in () }.eraseToAnyPublisher(), c.$interrupted.dropFirst().map { _ in () }.eraseToAnyPublisher(),
                             c.$waiting.dropFirst().map { _ in () }.eraseToAnyPublisher(), c.$scheduled.dropFirst().map { _ in () }.eraseToAnyPublisher(),
                             c.$heldUntil.dropFirst().map { _ in () }.eraseToAnyPublisher(), c.$overdue.dropFirst().map { _ in () }.eraseToAnyPublisher(),
                             c.$completed.dropFirst().map { _ in () }.eraseToAnyPublisher())
            .sink { [weak self] in self?.refresh(after: self?.changeDelay ?? 0) }.store(in: &cancellables)
    }

    /// Stops listening. After this, the model costs nothing and shows what it last had.
    func detach() {
        cancellables.removeAll()
        pendingRefresh?.cancel(); pendingRefresh = nil; pendingDeadline = .distantFuture
    }

    var isObserving: Bool { !cancellables.isEmpty }

    /// Many events in a short time become one rebuild. A sooner request replaces a later one that is already waiting; a later one never delays it.
    func refresh(after delay: TimeInterval) {
        let deadline = Date().addingTimeInterval(delay)
        if pendingRefresh != nil, pendingDeadline <= deadline { return }
        pendingRefresh?.cancel()
        pendingDeadline = deadline
        pendingRefresh = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) } else { await Task.yield() }
            guard !Task.isCancelled, let self else { return }
            self.pendingRefresh = nil; self.pendingDeadline = .distantFuture
            self.refreshNow()
        }
    }

    /// The private session of the window this list is shown in (nil in an ordinary window). A private download is listed only where its owner may see it: see `PrivateDownloadVisibility`.
    var viewerPrivateSession: () -> UUID? = { nil }

    func refreshNow() {
        guard let coordinator else { return }
        rebuilds += 1; generation += 1
        // The size of a finished file is asked for only where the record kept none, and looked up once per download (remembered until the files are rechecked), so a long list is not
        // inspected on disk again at every refresh. The path is the same validated one the file actions use.
        var snapshot = coordinator.dashboardSnapshot(fileExists: { [unowned self] record in self.fileIsThere(record) }, fileSize: { [unowned self] record in self.diskSize(of: record) })
        // Filtered here, where the list is made, so a private task of one window never reaches another window's rows (not merely hidden by the view).
        let viewer = viewerPrivateSession(), owners = PrivateWindowSessions.known
        snapshot.records = snapshot.records.filter { PrivateDownloadVisibility.isVisible(isPrivate: $0.isPrivate, session: $0.privateSession, viewer: viewer, privateWindowSessions: owners) }
        snapshot.isExtractable = { [unowned self] record in self.canExtract(record) }
        var built = DownloadRowProjector.rows(from: snapshot)
        // The older history, minus anything the task database already describes, below the live rows' own history.
        legacyByID = [:]
        if !legacyEntries.isEmpty {
            for entry in DownloadLegacyHistory.unseen(legacyEntries, records: snapshot.records) {
                let row = DownloadLegacyHistory.row(for: entry) { [unowned self] name in self.legacyFileExists(name, key: DownloadLegacyHistory.identifier(for: entry)) }
                legacyByID[row.id] = entry
                built.append(row)
            }
        }
        if built != rows { rows = built }          // an unchanged list is not published again: nothing downstream re-evaluates
        held = DownloadSchedule.isHeld(until: coordinator.heldUntil)
        holdNote = held ? (coordinator.heldUntil == .distantFuture ? "Queue paused until you resume" : "Queue held until \(coordinator.heldUntil.map { $0.formatted(date: .omitted, time: .shortened) } ?? "later")") : nil
        counts = DownloadQuery.counts(of: rows)
        recompute()
    }

    private func recompute() {
        let next = query.apply(to: rows)
        if next != visible { visible = next }
        // The selection only ever holds rows that exist; a task that ended or was removed drops out of it.
        let ids = Set(rows.map(\.id))
        if !selection.isSubset(of: ids) { selection = selection.intersection(ids) }
    }

    private func canExtract(_ record: DownloadTaskRecord) -> Bool {
        if let known = extractCache[record.id] { return known }
        let found = coordinator?.canExtract(record.id) ?? false
        extractCache[record.id] = found
        return found
    }

    private func legacyFileExists(_ name: String, key: UUID) -> Bool {
        if let known = fileCache[key] { return known }
        let found = DownloadCoordinator.locate(filename: name) != nil
        fileCache[key] = found
        return found
    }

    // MARK: Older history

    /// Reads the current pages of the older history off the main thread and shows them. Safe to call again; it never reads more than `maxPages` pages.
    func loadLegacy() {
        guard let legacy else { return }
        let pages = historyPages
        Task { [weak self] in
            let page = await Task.detached(priority: .utility) { DownloadLegacyHistory.page(pages, fetch: legacy) }.value
            guard let self, pages == self.historyPages else { return }
            self.legacyEntries = page.entries
            self.hasMoreHistory = page.hasMore
            self.refreshNow()
        }
    }

    func loadMoreHistory() {
        guard hasMoreHistory, historyPages < DownloadLegacyHistory.maxPages else { return }
        historyPages += 1
        loadLegacy()
    }

    private func fileIsThere(_ record: DownloadTaskRecord) -> Bool {
        if let known = fileCache[record.id] { return known }
        let found = coordinator?.fileURL(for: record) != nil
        fileCache[record.id] = found
        return found
    }

    /// Forget which files were found (after one was moved or trashed, or when the window is shown again).
    func recheckFiles() { fileCache.removeAll(); extractCache.removeAll(); diskSizes.removeAll(); refresh(after: 0) }

    private func diskSize(of record: DownloadTaskRecord) -> Int64? {
        if let known = diskSizes[record.id] { return known < 0 ? nil : known }
        // Only the file this very download was saved as (a path inside the downloads folder), never another file that happens to share its name. A link is measured as the link, not followed.
        var size: Int64?
        if let path = record.file.destinationPath, let roots = coordinator?.managedRoots, DownloadPathPolicy.isAuthorized(path, roots: roots) {
            size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64
        }
        diskSizes[record.id] = size ?? -1
        return size
    }

    private func savePreferences() {
        defaults?.set(query.filter.rawValue, forKey: Keys.filter)
        defaults?.set(query.sort.rawValue, forKey: Keys.sort)
        defaults?.set(query.ascending, forKey: Keys.ascending)
    }

    // MARK: Selection and actions

    func row(_ id: UUID) -> DownloadRow? { rows.first { $0.id == id } }

    /// Where the finished file is, for opening or showing it. Nil when the task is not complete or the file is gone.
    func fileURL(for id: UUID) -> URL? {
        if let entry = legacyByID[id] { return DownloadCoordinator.locate(filename: entry.filename) }
        guard let record = coordinator?.ledger.record(id), record.state == .completed else { return nil }
        return coordinator?.fileURL(for: record)
    }
    var selectedRows: [DownloadRow] { visible.filter { selection.contains($0.id) } }
    var allowedActions: DownloadRowActions { DownloadBatch.allowed(in: visible, selection: selection) }
    var counted: Int { rows.count }

    /// Runs an action on the given rows (default: the selection) — only on those that support it. Returns how many it was carried out for.
    @discardableResult
    func perform(_ action: DownloadRowActions, on ids: Set<UUID>? = nil, priority: DownloadPriority? = nil) -> Int {
        let chosen = DownloadBatch.eligible(action, in: rows, selection: ids ?? selection)
        for row in chosen {
            switch action {
            case .pause: performer.performPause(row.id)
            case .resume: performer.performResume(row.id)
            case .retry: performer.performRetry(row.id)
            case .cancel: performer.performCancel(row.id, status: row.status)
            case .startNow: performer.performStartNow(row.id)
            case .setPriority: if let priority { performer.performSetPriority(row.id, priority) }
            case .removeRecord: performer.performRemoveRecord(row.id)
            default: break
            }
        }
        refresh(after: 0)
        return chosen.count
    }

    /// Asks for a confirmation before any file is touched. Nothing is moved until `confirmTrash`.
    func requestTrash(on ids: Set<UUID>? = nil) {
        pendingTrash = DownloadBatch.eligible(.trashFile, in: rows, selection: ids ?? selection)
    }

    /// Test seam: how one download's file is moved to the Trash. The real one is `DownloadCoordinator.trashFile(of:)`.
    var trashPerformer: ((UUID) -> Bool)?

    /// Moves each confirmed file to the Trash and, only for a file that was really moved, removes that download's list entry too (the file is gone, so the entry has nothing to open or reveal).
    /// A file that could not be moved keeps its entry and is named in the message, so nothing disappears from the list while its file is still on disk. "Remove from List" stays a separate action
    /// that never touches a file. Several files are handled one by one: a failure does not stop or undo the others.
    func confirmTrash() {
        let targets = pendingTrash; pendingTrash = []
        var moved = 0, sharedRemoved = 0, kept: [String] = []
        var trashedPaths = Set<String>()
        for row in targets {
            // Already taken with an earlier row as an entry for the same file: nothing left to do for it.
            guard coordinator?.ledger.record(row.id) != nil else { continue }
            let path = coordinator?.managedFile(of: row.id)?.standardizedFileURL.path
            // Another selected row for the same file: the first one already moved it, so this one is done too (not a failure) and only its entry goes.
            if let path, trashedPaths.contains(path) { coordinator?.removeRecord(row.id); sharedRemoved += 1; continue }
            // Other finished downloads in the list that point at the very same file (a duplicate entry, a re-download that kept the name). Looked up BEFORE the move, while the file still exists.
            let siblings = path.map { entriesSharing(file: $0, except: row.id) } ?? []
            let ok = trashPerformer?(row.id) ?? (coordinator?.trashFile(of: row.id) ?? false)
            if ok {
                coordinator?.removeRecord(row.id); moved += 1
                if let path { trashedPaths.insert(path) }
                for other in siblings { coordinator?.removeRecord(other); sharedRemoved += 1 }          // their file is gone too: an entry with nothing to open is not kept
            } else { kept.append(row.filename) }
        }
        recheckFiles()
        let shared = sharedRemoved > 0 ? " (\(sharedRemoved) other entr\(sharedRemoved == 1 ? "y" : "ies") for the same file removed too)" : ""
        switch (moved, kept.count) {
        case (_, 0): message = (moved == 1 ? "Moved 1 file to the Trash and removed it from the list" : "Moved \(moved) files to the Trash and removed them from the list") + shared
        case (0, 1): message = ("“\(kept[0])” could not be moved to the Trash. It is still in the list, and its file has not been changed")
        case (0, _): message = ("None of the \(kept.count) files could be moved to the Trash. They are still in the list, and no file has been changed")
        default: message = ("Moved \(moved) to the Trash. \(kept.count) could not be moved and stay in the list: " + kept.prefix(3).map { "“\($0)”" }.joined(separator: ", ") + (kept.count > 3 ? " and \(kept.count - 3) more" : "")) + shared
        }
    }

    /// The other finished downloads whose file is the same file on disk.
    private func entriesSharing(file path: String, except id: UUID) -> [UUID] {
        guard let coordinator else { return [] }
        return coordinator.ledger.records(in: .completed).compactMap { r in
            r.id != id && coordinator.managedFile(of: r.id)?.standardizedFileURL.path == path ? r.id : nil
        }
    }

    func cancelTrash() { pendingTrash = [] }

    // MARK: Clearing the list (records only; no file is touched here)

    /// Which finished downloads a "Clear" removes from the list. Active, queued, scheduled, paused and recovery-required downloads are never in any of them.
    enum HistoryClear: CaseIterable {
        case completed, failedAndCancelled, allFinished
        func includes(_ status: DownloadRowStatus) -> Bool {
            switch self {
            case .completed: status == .completed
            case .failedAndCancelled: status == .failed || status == .cancelled
            case .allFinished: status == .completed || status == .failed || status == .cancelled
            }
        }
    }

    func rowsToClear(_ kind: HistoryClear) -> [DownloadRow] { rows.filter { kind.includes($0.status) && $0.actions.contains(.removeRecord) } }

    /// Takes the finished downloads of that kind off the list, through the same one removal as "Remove from List". Their files stay where they are.
    @discardableResult
    func clearHistory(_ kind: HistoryClear) -> Int {
        let ids = Set(rowsToClear(kind).map(\.id))
        guard !ids.isEmpty else { return 0 }
        selection.subtract(ids)
        return perform(.removeRecord, on: ids)
    }

    /// Stops the chosen downloads (the same cancel as the Cancel button: the engine stops, the partial file and its hidden place are removed, the connections are given back) and then
    /// takes them off the list once they have ended. A download that cannot be cancelled right now (one being put in place) is left alone.
    @discardableResult
    func cancelAndRemove(on ids: Set<UUID>? = nil) -> Int {
        let targets = Set(DownloadBatch.eligible(.cancel, in: rows, selection: ids ?? selection).map(\.id))
        guard !targets.isEmpty else { return 0 }
        perform(.cancel, on: targets)
        Task { @MainActor [weak self] in
            var left = targets
            for _ in 0..<40 where !left.isEmpty {
                guard let self, let coordinator = self.coordinator else { return }
                for id in left {
                    guard let record = coordinator.ledger.record(id) else { left.remove(id); continue }
                    if record.state.isFinal || record.state == .failed { coordinator.removeRecord(id); left.remove(id) }
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
            self?.refresh(after: 0)
        }
        return targets.count
    }

    /// A sentence for what a batch would do, so a menu can say "Cancel 3 downloads" and mean it.
    func count(for action: DownloadRowActions, on ids: Set<UUID>? = nil) -> Int { DownloadBatch.eligible(action, in: rows, selection: ids ?? selection).count }

    // MARK: File operations (each reports in `message`)

    private func say(_ text: String) { message = text }

    func rename(_ id: UUID, to newName: String) {
        switch coordinator?.renameFile(of: id, to: newName) {
        case .success(let url)?: say("Renamed to “\(url.lastPathComponent)”."); recheckFiles()
        case .failure(let failure)?: say(failure.localizedDescription)
        case nil: break
        }
    }

    func move(_ id: UUID, toFolder folder: URL) {
        switch coordinator?.moveFile(of: id, toFolder: folder) {
        case .success(let url)?: say("Moved to “\(url.deletingLastPathComponent().lastPathComponent)”."); recheckFiles()
        case .failure(let failure)?: say(failure.localizedDescription)
        case nil: break
        }
    }

    func verify(_ ids: Set<UUID>? = nil) {
        let targets = DownloadBatch.eligible(.verify, in: rows, selection: ids ?? selection)
        guard let coordinator, !targets.isEmpty else { return }
        Task { [weak self] in
            var last: DownloadIntegrityCheck.Report?
            for row in targets { last = await coordinator.reverify(row.id) ?? last }
            self?.say(targets.count == 1 ? DownloadIntegrityCheck.summary(last?.outcome, sha256: last?.sha256) : "Checked \(targets.count) files.")
            self?.refresh(after: 0)
        }
    }

    // MARK: Other sources (mirrors)

    struct MirrorInfo: Equatable {
        struct Row: Equatable, Identifiable { var id: UUID; var address: String; var state: String; var bytes: Int64; var usable: Bool }
        var rows: [Row]
        var canAdd: Bool
        var combining: Bool
        var note: String
    }
    /// What the details panel shows about a download's other sources. Nil for downloads that cannot have any (not the app's own HTTP engine, private, or finished with none).
    func mirrorInfo(for id: UUID) -> MirrorInfo? {
        guard let coordinator, let record = coordinator.ledger.record(id), record.protocolID == .http, !record.isPrivate else { return nil }
        let list = coordinator.mirrors.mirrors(of: id)
        if record.state.isFinal, list.isEmpty { return nil }
        func state(_ m: MirrorSource) -> String {
            switch m.state { case .unchecked: "Not used yet"; case .inUse: "In use"; case .used: "Used"; case .bad(let why): "Not used: \(why)" }
        }
        let combining = coordinator.mirrors.canCombine(id)
        let note = combining ? "These sources fetch parts of the file together. The finished file is checked against the checksum you gave."
            : "These sources are tried one after another, each from the start, never mixed. To use them together you need your own address and a SHA-256 checksum."
        return MirrorInfo(rows: list.map { .init(id: $0.id, address: $0.display, state: state($0), bytes: $0.bytes, usable: $0.isUsable) }, canAdd: !record.state.isFinal && list.count < MirrorStore.maxPerTask, combining: combining, note: note)
    }
    func addMirror(_ text: String, to id: UUID) -> String {
        guard let coordinator else { return "" }
        let r = coordinator.mirrors.add([text], to: id)
        return r.added > 0 ? "Source added." : (r.duplicates > 0 ? "That is already a source." : (r.rejected.first ?? "It could not be added."))
    }
    /// The torrent's trackers are asked for their counts. Only when the person asks.
    func scrapeTrackers(_ id: UUID) { coordinator?.torrents.requestScrape(for: id) }
    func removeMirror(_ mirror: UUID, from id: UUID) { coordinator?.mirrors.remove(mirror, from: id) }

    // MARK: Streaming (HLS / DASH) details

    struct MediaInfo: Equatable {
        var format: String
        var tracks: String?
        var segments: Int
        var segmentsDone: Int?
        var note: String?
        var subtitleFiles: String?
        /// DX-08: each track's own count while it runs, the retries so far, links renewed, what the finished file holds, and what was skipped or worth knowing.
        var trackProgress: String?
        var retries = 0
        var refreshes = 0
        var output: String?
        var warnings: String?
    }
    func mediaInfo(for id: UUID) -> MediaInfo? {
        guard let coordinator, let record = coordinator.ledger.record(id), record.protocolID == .media else { return nil }
        let live = coordinator.mediaStarted ? coordinator.media.live(id) : nil
        let m = record.engineMetadata
        return MediaInfo(format: m["media"] == "dash" ? "MPEG-DASH" : "HLS", tracks: m["mediaTracks"], segments: live?.total ?? Int(m["mediaSegments"] ?? "") ?? 0,
                         segmentsDone: live?.done ?? m["mediaDone"].flatMap(Int.init), note: m["mediaNote"], subtitleFiles: m["mediaSubtitleFiles"],
                         trackProgress: coordinator.mediaStarted ? coordinator.media.trackProgress(id) : nil, retries: coordinator.mediaStarted ? coordinator.media.retries(id) : 0,
                         refreshes: Int(m["mediaRefreshes"] ?? "") ?? 0, output: m["mediaOutput"], warnings: m["mediaWarnings"])
    }

    // MARK: eD2k details

    func ed2kInfo(for id: UUID) -> (live: ED2KSession.Snapshot?, hash: String)? {
        guard let coordinator, let record = coordinator.ledger.record(id), record.protocolID == .ed2k else { return nil }
        return (coordinator.ed2k.live(id)?.snapshot, record.engineMetadata["ed2kHash"] ?? "")
    }

    // MARK: Torrent details

    /// What a running torrent can tell: peers, pieces, speeds. Nil for anything else, and for a torrent that is not running (then only the saved facts are shown).
    struct TorrentInfo: Equatable {
        var live: TorrentSession.Snapshot?
        var files: Int, selected: Int
        var isPrivate: Bool
        var infoHash: String
        /// Sharing of a finished torrent (nil when this task has none).
        var seeding: SeedingInfo? = nil
        static func == (a: TorrentInfo, b: TorrentInfo) -> Bool { a.files == b.files && a.selected == b.selected && a.live?.verifiedPieces == b.live?.verifiedPieces && a.live?.peers == b.live?.peers && a.live?.downRate == b.live?.downRate && a.seeding == b.seeding }
    }

    // MARK: Seeding (DX-06)

    /// Starts or stops sharing a finished torrent. Starting asks first (once for the torrent) in the same plain words as Settings; stopping does not ask.
    func toggleSeeding(_ id: UUID) async {
        guard let coordinator else { return }
        let runner = coordinator.torrents
        if runner.seedInfo(id)?.isActive == true { runner.stopSeeding(id); objectWillChange.send(); return }
        let needsConsent = !(runner.seedInfo(id)?.authorized ?? false) || coordinator.torrentSettings.seedingMode == .off
        if needsConsent {
            let pressed = await Dialogs.choose(title: TorrentSettings.seedingConsentTitle, message: TorrentSettings.seedingConsentMessage, buttons: ["Start Sharing", "Cancel"])
            guard pressed == 0 else { return }
            // Turning sharing on app-wide from Off must not quietly restart torrents the person authorized long ago: only this one is shared.
            if coordinator.torrentSettings.seedingMode == .off {
                guard runner.seedInfo(id) != nil else { return }          // nothing to share: change nothing, withdraw no one's consent
                runner.clearSeedingAuthorization(except: id)
                coordinator.torrentSettings.seedingMode = .completed
                if !runner.startSeeding(id) { coordinator.torrentSettings.seedingMode = .off }
                objectWillChange.send(); return
            }
        }
        _ = runner.startSeeding(id)
        objectWillChange.send()
    }

    // MARK: Torrent files (DX-05)

    /// The files of a torrent task and the choice made for them, from what is saved beside its data (works while it runs, is paused, or after a relaunch).
    func torrentSavedSelection(_ id: UUID) -> (meta: TorrentMetainfo, selection: TorrentSelection)? { coordinator?.torrents.savedSelection(id) }

    func setTorrentStreamPosition(_ id: UUID, file: Int, byte: Int64) { coordinator?.torrents.setStreamPosition(id, file: file, byte: byte) }

    func torrentFileProgress(_ id: UUID, _ done: @escaping ([TorrentFileProgress]) -> Void) {
        guard let coordinator else { done([]); return }
        coordinator.torrents.fileProgress(id, completion: done)
    }

    func updateTorrentSelection(_ id: UUID, _ selection: TorrentSelection, _ done: @escaping (Result<Void, Error>) -> Void) {
        guard let coordinator else { done(.failure(TorrentSession.SelectionError.notReady)); return }
        coordinator.torrents.updateSelection(id, selection, completion: done)
    }

    func torrentInfo(for id: UUID) -> TorrentInfo? {
        guard let coordinator, let record = coordinator.ledger.record(id), record.protocolID == .bittorrent else { return nil }
        let meta = record.engineMetadata
        let live = coordinator.torrents.live(id)
        return TorrentInfo(live: live?.snapshot, files: live?.files ?? Int(meta["files"] ?? "") ?? 0, selected: live?.selected ?? Int(meta["selected"] ?? "") ?? 0,
                           isPrivate: live?.isPrivate ?? (meta["private"] == "1"), infoHash: meta["infoHash"] ?? "",
                           seeding: coordinator.torrentsStarted ? coordinator.torrents.seedInfo(id) : nil)
    }

    // MARK: Speed limit

    /// What a download's speed limit comes to, for the inspector: its own limit, the limit that applies (the stricter of its own and the overall one), and whether it is kept.
    struct SpeedLimitInfo: Equatable {
        var own: Int64?
        var effective: Int64?
        var source: BandwidthLimitSource
        var enforcement: BandwidthEnforcement

        var summary: String {
            guard let effective else { return "No limit" }
            let speed = DownloadFormat.speed(Double(effective)) ?? "\(effective) B/s"
            switch source {
            case .download: return "\(speed) (set for this download)"
            case .adaptive: return "\(speed) (held back while the browser is busy)"
            default: return "\(speed) (overall limit)"
            }
        }
    }

    func speedLimitInfo(for id: UUID) -> SpeedLimitInfo? {
        guard let coordinator, let record = coordinator.ledger.record(id), record.protocolID == .http, !record.state.isFinal, record.state != .failed else { return nil }
        let effective = BandwidthController.shared.effectiveLimit(for: id)
        let own = record.engineMetadata["speedLimit"].flatMap { Int64($0) }
        // A paused download's own limit is no longer in the controller, so the stricter of its saved limit and the overall one is worked out here.
        var e = effective
        if e == nil, let own {
            if let all = BandwidthController.shared.overallLimit(owner: coordinator.ownerID), all < own { e = (all, .overall) } else { e = (own, .download) }
        }
        return SpeedLimitInfo(own: own, effective: e?.bytesPerSecond, source: e?.source ?? .none, enforcement: coordinator.http.bandwidthEnforcement(id))
    }

    /// What the adaptive controller is doing for a download, read-only. Nil when the download is not one the app moves itself or is over.
    struct AdaptiveInfo: Equatable {
        var mode: String
        var connections: Int?
        var connectionBound: Int?
        var speedCeiling: Int64?
        var constraints: [String]
        var sources: [(name: String, bytesPerSecond: Double, usable: Bool)]
        static func == (a: AdaptiveInfo, b: AdaptiveInfo) -> Bool { a.mode == b.mode && a.connections == b.connections && a.connectionBound == b.connectionBound && a.speedCeiling == b.speedCeiling && a.constraints == b.constraints }
    }
    func adaptiveInfo(for id: UUID) -> AdaptiveInfo? {
        guard let coordinator, let record = coordinator.ledger.record(id), record.protocolID == .http, !record.state.isFinal, !record.isPrivate else { return nil }
        let snap = coordinator.adaptive.snapshot
        var constraints: [String] = []
        if let hold = coordinator.networkHold { constraints.append(hold.explanation) }
        if snap.browserBusy, snap.mode.isAdaptive { constraints.append("The browser is busy") }
        if coordinator.networkSettings.overallLimit != nil { constraints.append("Your speed limit applies") }
        if let own = record.engineMetadata["speedLimit"], !own.isEmpty { constraints.append("This download has its own speed limit") }
        if ProcessInfo.processInfo.isLowPowerModeEnabled, snap.mode.isAdaptive { constraints.append("Low Power Mode") }
        let sources = (coordinator.http.sourceRates(id) ?? []).enumerated().map { (name: "Source \($0.offset + 1)", bytesPerSecond: $0.element.bytesPerSecond, usable: $0.element.usable) }
        return AdaptiveInfo(mode: snap.mode.title, connections: record.engineMetadata["connections"].flatMap(Int.init), connectionBound: snap.workerCeiling, speedCeiling: snap.rateCeiling, constraints: constraints,
                            sources: sources.count > 1 ? sources : [])
    }

    func setSpeedLimit(_ id: UUID, _ bytesPerSecond: Int64?) {
        guard let coordinator, coordinator.ledger.record(id)?.protocolID == .http else { return }
        coordinator.http.setSpeedLimit(id, bytesPerSecond: bytesPerSecond)
        if let note = speedLimitInfo(for: id), note.effective != nil, case .notEnforced(let why) = note.enforcement { say(why) }
        refresh(after: 0)
    }

    func extract(_ id: UUID) {
        guard let coordinator else { return }
        say("Opening…")
        Task { [weak self] in
            switch await coordinator.extractArchive(id) {
            case .success(let folder): self?.say("Opened into “\(folder.lastPathComponent)”.")
            case .failure(let failure): self?.say(failure.localizedDescription)
            }
        }
    }

    // MARK: Whole queue

    func pauseAll() { coordinator?.pauseAll() }
    func resumeAll() { coordinator?.resumeAll() }
}
