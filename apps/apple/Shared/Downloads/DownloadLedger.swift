import Foundation

/// The one place a download's state lives while the app runs, and the only thing that writes it to the database.
///
/// The coordinator tells the ledger what happened; the ledger checks it against `DownloadStateMachine`, updates the record, and saves it. A move the machine does not allow is
/// refused and reported, never half-applied. Nothing else mutates a record, and nothing else writes the database, so there is one source of truth for "is this download done".
@MainActor
final class DownloadLedger {
    private(set) var records: [DownloadTaskID: DownloadTaskRecord] = [:]
    let profile: String
    private(set) var store: DownloadTaskStore?
    /// Where the files of a task may be. A path from the database outside these is not believed.
    var authorizedRoots: () -> [URL] = { [] }
    /// Tells the coordinator about a problem worth a line in its diagnostics (a refused move, a failed save).
    var onProblem: ((String) -> Void)?
    /// Called after a task is created, changes state or fields, or is removed (not for every progress tick). Lets a list refresh when something real happened.
    var onChange: (() -> Void)?
    private var lastProgressSave: [DownloadTaskID: Date] = [:]
    private var order = 0
    /// How often progress is written for a running task (state changes are written at once).
    static let progressSaveInterval: TimeInterval = 2

    init(profile: String) { self.profile = profile }

    var outcome: DownloadTaskStore.OpenOutcome? { store?.outcome }

    // MARK: Opening and recovering

    /// Opens the profile's database, brings the old files in, and loads what was there. Tasks that were live when the app ended are marked for a decision; none restarts by itself.
    func attach(folder: URL, safeName: (String) -> String) -> DownloadLegacyMigration.Result {
        let store = DownloadTaskStore.open(folder: folder)
        self.store = store
        records = [:]
        let migration = DownloadLegacyMigration.run(folder: folder, store: store, profile: profile, safeName: safeName)
        if let failure = migration.failure { onProblem?("Download migration: \(failure)") }
        switch store.outcome {
        case .quarantined(let path, let reason): onProblem?("The downloads database was damaged (\(reason)); it was kept at \(path) and a new one started")
        case .newerVersion(let v): onProblem?("The downloads database is from a newer version of Browser Setu (\(v)); it was left untouched and downloads will not be remembered this run")
        case .unavailable(let why): onProblem?("Downloads will not be remembered this run: \(why)")
        case .opened, .created: break
        }
        let loaded = store.loadAll(profile: profile)
        if loaded.unreadable > 0 { onProblem?("\(loaded.unreadable) saved download\(loaded.unreadable == 1 ? "" : "s") could not be read and were skipped") }
        for var record in loaded.records {
            record = recovered(record, store: store)
            records[record.id] = record
            order = max(order, record.queueOrder)
        }
        return migration
    }

    /// What a loaded record becomes: its paths checked, and a live state turned into "needs a decision".
    private func recovered(_ loaded: DownloadTaskRecord, store: DownloadTaskStore) -> DownloadTaskRecord {
        var record = loaded
        let roots = authorizedRoots()
        if !roots.isEmpty {
            if record.file.destinationPath != nil, !DownloadPathPolicy.isAuthorized(record.file.destinationPath, roots: roots) {
                onProblem?("A saved download named \(record.file.filename) pointed outside the downloads folder; its location was dropped")
                record.file.destinationPath = nil
            }
            if record.file.temporaryPath != nil, !DownloadPathPolicy.isAuthorized(record.file.temporaryPath, roots: roots) { record.file.temporaryPath = nil }
        }
        record.engineMetadata = DownloadEngineMetadata.validated(record.engineMetadata)
        var changed = false
        func move(_ event: DownloadEvent) { if let next = try? record.applying(event) { record = next; changed = true } }
        switch record.state {
        case .resolving, .starting, .running, .pausing, .resuming, .verifying:
            // A pause that was being asked for, or a resume being started, had not been answered. With the place kept it can be resumed; otherwise it needs a decision.
            move(.recoveryRequired(reason: "Browser Setu was closed before this finished."))
        case .queued:
            // Waiting for a place that no longer exists (the network request it was waiting on is gone): put off, so it starts again from its address when the queue is released.
            move(.scheduled(at: nil))
        case .retrying:
            // A retry had been planned and its timer died with the app. It is shown, with its place kept, and the person decides; it is not left invisible and it does not restart by itself.
            move(.recoveryRequired(reason: "Browser Setu was closed while this was waiting to try again."))
        case .paused:
            if store.resumeData(for: record.id) == nil {
                record.transfer.resumeAvailable = false
                move(.failed(DownloadFailureInfo(code: "app:lost-resume", reason: "The place this download had reached was lost, so it cannot carry on.", retryable: record.source.asURL != nil)))
            }
        case .created:
            move(.cancelled)
        case .completed, .failed, .cancelled, .scheduled, .recoveryRequired:
            break
        }
        if changed { persist(record) }
        return record
    }

    // MARK: Creating and changing

    /// A new task. Private ones are held in memory only.
    @discardableResult
    func create(id: DownloadTaskID = UUID(), protocolID: DownloadProtocolID, source: URL?, filename: String, isPrivate: Bool, priority: DownloadPriority = .normal) -> DownloadTaskRecord {
        order += 1
        var record = DownloadTaskRecord(id: id, protocolID: protocolID, profile: profile, isPrivate: isPrivate, source: DownloadSourceRef(url: source), filename: filename)
        record.priority = priority
        record.queueOrder = order
        records[id] = record
        persist(record)
        onChange?()
        return record
    }

    /// Applies an event. Returns the new record, or nil (and says why) when the move is not allowed or the task is unknown.
    @discardableResult
    func apply(_ event: DownloadEvent, to id: DownloadTaskID, attempt: Int? = nil, resumeData: Data?? = nil) -> DownloadTaskRecord? {
        guard let current = records[id] else { onProblem?("Ignored \(event.name) for a download that is not known"); return nil }
        do {
            let next = try current.applying(event, attempt: attempt)
            records[id] = next
            persist(next, resumeData: resumeData)
            if next.state.isFinal || next.state == .failed { lastProgressSave[id] = nil; trimFinishedInMemory() }
            onChange?()
            return next
        } catch {
            onProblem?("Refused: \(error)")
            return nil
        }
    }

    /// Updates a record's fields that are not state (name, destination, sizes, metadata), without a state change.
    func update(_ id: DownloadTaskID, _ change: (inout DownloadTaskRecord) -> Void) {
        guard var record = records[id] else { return }
        change(&record)
        record.updatedAt = Date()
        records[id] = record
        persist(record)
        onChange?()
    }

    /// Progress: kept in memory at once, written at most every couple of seconds.
    func progress(_ id: DownloadTaskID, completed: Int64, total: Int64?) {
        guard var record = records[id], record.state == .running || record.state == .starting || record.state == .resuming else { return }
        record.transfer.completedBytes = max(0, completed)
        if let total, total > 0 { record.transfer.totalBytes = total }
        records[id] = record
        let now = Date()
        if now.timeIntervalSince(lastProgressSave[id] ?? .distantPast) >= Self.progressSaveInterval { lastProgressSave[id] = now; persist(record) }
    }

    /// Finished records are kept in memory only as far as the database keeps them, so a long session does not grow without limit.
    private func trimFinishedInMemory() {
        let finished = records.values.filter { $0.state.isFinal || $0.state == .failed }
        let limit = DownloadTaskStore.keepCompleted + DownloadTaskStore.keepFailedOrCancelled
        guard finished.count > limit else { return }
        for old in finished.sorted(by: { $0.updatedAt < $1.updatedAt }).prefix(finished.count - limit) { records[old.id] = nil }
    }

    /// Saves (or, with nil, removes) a task's resume data without changing its state: a multipart download is resumable from its pieces the whole time it runs, not only once paused.
    func saveResumeData(_ id: DownloadTaskID, _ data: Data?) {
        guard let record = records[id] else { return }
        persist(record, resumeData: .some(data))
    }

    /// The hold on the queue, kept so a pause the person asked for is still there after a relaunch. `.distantFuture` is "until I resume".
    func saveHold(_ date: Date?) {
        guard let store else { return }
        let key = "queue_hold:\(profile)"
        store.setMeta(key, date.map { $0 == .distantFuture ? "manual" : String($0.timeIntervalSince1970) } ?? "none")
    }

    func loadHold() -> Date? {
        guard let text = store?.meta("queue_hold:\(profile)"), text != "none" else { return nil }
        if text == "manual" { return .distantFuture }
        return Double(text).map { Date(timeIntervalSince1970: $0) }
    }

    func remove(_ id: DownloadTaskID) {
        records[id] = nil
        lastProgressSave[id] = nil
        store?.delete(id)
        onChange?()
    }

    // MARK: Reading

    func record(_ id: DownloadTaskID) -> DownloadTaskRecord? { records[id] }
    func records(in state: DownloadState) -> [DownloadTaskRecord] { records.values.filter { $0.state == state }.sorted { ($0.queueOrder, $0.createdAt) < ($1.queueOrder, $1.createdAt) } }
    func resumeData(for id: DownloadTaskID) -> Data? { store?.resumeData(for: id) }

    /// Waits for every write made so far to reach the file (quitting; tests).
    func flush() { store?.flush(); reportWriteFailures() }

    private func persist(_ record: DownloadTaskRecord, resumeData: Data?? = nil) {
        guard !record.isPrivate, let store else { return }
        store.save(record, resumeData: resumeData)
    }

    func reportWriteFailures() { for failure in store?.takeFailures() ?? [] { onProblem?("Could not save download state while \(failure)") } }
}
