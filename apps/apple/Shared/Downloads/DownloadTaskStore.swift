import Foundation
import SQLite3

/// The durable home of download tasks, one database per profile folder.
///
/// Design, and why:
///  - SQLite through the system library, ONE connection, used only on one serial queue. That is the single writer; nothing else touches the file.
///  - Rollback journal (`journal_mode = DELETE`) and `synchronous = FULL`, not WAL. The traffic is a few small writes a minute, so WAL's speed is not needed, and SQLite's own
///    documentation reports a WAL-reset corruption bug in 3.7.0 through 3.51.2 (fixed in 3.51.3, backported to 3.44.6 and 3.50.7); macOS 14, the oldest supported system,
///    ships an older SQLite. The bug needs two connections writing at once, which this design never does, but a mode that cannot meet it is the safer default.
///  - Reads are synchronous (a profile's tasks are loaded once, when it opens, and the database is small); writes are queued and applied in order, off the main thread.
///  - Schema version in `PRAGMA user_version`, migrations as ordered steps, each in its own transaction. A database from a newer app is never opened for writing.
///  - A database that is damaged is moved aside (never deleted) and a fresh one started, and the move is reported; it never silently becomes an empty list.
///  - Resume data can hold the original request, headers included, so it lives in its own table and is never part of a task record, a log line or a diagnostic.
final class DownloadTaskStore: @unchecked Sendable {
    static let schemaVersion = 3
    static let maxResumeBytes = 5_000_000
    /// How many finished records are kept (the Downloads history proper lives elsewhere).
    static let keepCompleted = 500
    static let keepFailedOrCancelled = 100

    enum OpenOutcome: Equatable {
        case opened
        case created
        /// The file was not a usable database; it is kept at `movedTo` and a new one was started.
        case quarantined(movedTo: String, reason: String)
        /// The file is from a newer version of the app: left untouched, nothing is read or written.
        case newerVersion(Int)
        /// It could not be opened at all; tasks are held in memory for this run and not saved.
        case unavailable(String)
    }

    struct StoreError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private let queue: DispatchQueue
    private var db: OpaquePointer?
    let url: URL
    private(set) var outcome: OpenOutcome = .opened
    /// Writes that failed, newest last (bounded); the coordinator surfaces these. Guarded by the queue.
    private var failedWrites: [String] = []

    // One store per file, so a read always sees every write made through any handle in this process.
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: DownloadTaskStore] = [:]

    static func open(folder: URL) -> DownloadTaskStore {
        let file = folder.appendingPathComponent("downloads.sqlite").standardizedFileURL
        registryLock.lock(); defer { registryLock.unlock() }
        if let existing = registry[file.path] { return existing }
        let store = DownloadTaskStore(file: file)
        registry[file.path] = store
        return store
    }

    /// For tests: forget a store, closing its file, so a folder can be removed or reopened afresh.
    static func close(folder: URL) {
        let file = folder.appendingPathComponent("downloads.sqlite").standardizedFileURL
        registryLock.lock(); let store = registry.removeValue(forKey: file.path); registryLock.unlock()
        store?.queue.sync { if let handle = store?.db { sqlite3_close(handle); store?.db = nil } }
    }

    private init(file: URL) {
        url = file
        queue = DispatchQueue(label: "browsersetu.downloads.store.\(file.lastPathComponent)", qos: .utility)
        queue.sync { outcome = openOrRecover() }
    }

    deinit { if let db { sqlite3_close(db) } }

    // MARK: Opening

    private func openOrRecover() -> OpenOutcome {
        let fm = FileManager.default
        do { try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) } catch { return .unavailable("The downloads folder for this profile could not be made: \(error.localizedDescription)") }
        let existed = fm.fileExists(atPath: url.path)
        switch openAndCheck() {
        case .success(let created): return existed && !created ? .opened : (existed ? .opened : .created)
        case .failure(let failure):
            if case .newer(let version) = failure { closeHandle(); return .newerVersion(version) }
            // Damaged: keep the evidence, start again.
            closeHandle()
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let moved = url.deletingLastPathComponent().appendingPathComponent("downloads.corrupt-\(stamp).sqlite")
            do { try fm.moveItem(at: url, to: moved) } catch { return .unavailable("The downloads database is damaged and could not be moved aside: \(error.localizedDescription)") }
            for suffix in ["-journal", "-wal", "-shm"] { try? fm.moveItem(atPath: url.path + suffix, toPath: moved.path + suffix) }
            switch openAndCheck() {
            case .success: return .quarantined(movedTo: moved.path, reason: failure.description)
            case .failure(let second): closeHandle(); return .unavailable("A new downloads database could not be started: \(second.description)")
            }
        }
    }

    private enum OpenFailure: Error, CustomStringConvertible {
        case sqlite(String), newer(Int)
        var description: String { switch self { case .sqlite(let s): s; case .newer(let v): "database version \(v) is newer than this app" } }
    }

    private func closeHandle() { if let db { sqlite3_close(db); self.db = nil } }

    /// Opens the file, checks it is sound, brings the schema up to date. `true` when the file was new.
    private func openAndCheck() -> Result<Bool, OpenFailure> {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open"
            if let handle { sqlite3_close(handle) }
            return .failure(.sqlite(message))
        }
        db = handle
        sqlite3_busy_timeout(handle, 3000)
        do {
            // A file that is not a database fails on the first statement that reads it.
            let check = try scalarText("PRAGMA quick_check")
            guard check == "ok" else { return .failure(.sqlite("integrity check said: \(check ?? "nothing")")) }
            try exec("PRAGMA journal_mode = DELETE")
            try exec("PRAGMA synchronous = FULL")
            try exec("PRAGMA foreign_keys = ON")
            try exec("PRAGMA secure_delete = ON")
            let version = try scalarInt("PRAGMA user_version") ?? 0
            if version > Self.schemaVersion { return .failure(.newer(version)) }
            let isNew = version == 0
            try migrate(from: version)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return .success(isNew)
        } catch let error as OpenFailure {
            return .failure(error)
        } catch {
            return .failure(.sqlite("\(error)"))
        }
    }

    // MARK: Schema

    private func migrate(from version: Int) throws {
        var current = version
        let steps: [Int: () throws -> Void] = [
            1: { [self] in
                try exec("""
                CREATE TABLE meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
                CREATE TABLE tasks (
                    id TEXT PRIMARY KEY NOT NULL,
                    protocol TEXT NOT NULL,
                    profile TEXT NOT NULL,
                    state TEXT NOT NULL CHECK (state IN ('created','resolving','queued','scheduled','starting','running','pausing','paused','resuming','verifying','retrying','completed','failed','cancelled','recoveryRequired')),
                    priority INTEGER NOT NULL,
                    queue_order INTEGER NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    started_at REAL,
                    completed_at REAL,
                    scheduled_at REAL,
                    attempt INTEGER NOT NULL DEFAULT 0,
                    retry_count INTEGER NOT NULL DEFAULT 0,
                    source_url TEXT,
                    source_host TEXT,
                    filename TEXT NOT NULL,
                    destination_path TEXT,
                    temporary_path TEXT,
                    integrity TEXT NOT NULL DEFAULT 'unknown',
                    total_bytes INTEGER,
                    completed_bytes INTEGER NOT NULL DEFAULT 0,
                    resume_available INTEGER NOT NULL DEFAULT 0,
                    failure_code TEXT,
                    failure_reason TEXT,
                    failure_retryable INTEGER,
                    engine_metadata TEXT,
                    record_version INTEGER NOT NULL DEFAULT 1
                );
                CREATE INDEX tasks_by_state ON tasks (profile, state);
                CREATE TABLE task_resume (
                    task_id TEXT PRIMARY KEY NOT NULL REFERENCES tasks (id) ON DELETE CASCADE,
                    data BLOB NOT NULL
                );
                """)
            },
            3: { [self] in
                // Scheduler state in typed columns: when a task joined the line, and when a planned retry is due. Existing rows keep NULL (never waited, no retry planned).
                try exec("""
                ALTER TABLE tasks ADD COLUMN enqueued_at REAL;
                ALTER TABLE tasks ADD COLUMN retry_at REAL;
                """)
            },
            2: { [self] in
                // The durable pieces of a multipart download. A piece is `done` only after its bytes have been synced to disk.
                try exec("""
                CREATE TABLE task_pieces (
                    task_id TEXT NOT NULL REFERENCES tasks (id) ON DELETE CASCADE,
                    idx INTEGER NOT NULL,
                    start_byte INTEGER NOT NULL,
                    end_byte INTEGER NOT NULL,
                    state TEXT NOT NULL CHECK (state IN ('pending', 'done')),
                    checksum TEXT,
                    session INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (task_id, idx),
                    CHECK (start_byte >= 0 AND end_byte >= start_byte)
                );
                """)
            }
        ]
        while current < Self.schemaVersion {
            let next = current + 1
            guard let step = steps[next] else { throw OpenFailure.sqlite("no migration to version \(next)") }
            try exec("BEGIN IMMEDIATE")
            do { try step(); try exec("PRAGMA user_version = \(next)"); try exec("COMMIT") } catch { try? exec("ROLLBACK"); throw error }
            current = next
        }
    }

    // MARK: Low-level helpers (queue only)

    private func exec(_ sql: String) throws {
        guard let db else { throw StoreError(message: "the database is closed") }
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw OpenFailure.sqlite(message)
        }
    }

    private func scalarText(_ sql: String) throws -> String? {
        let stmt = try prepare(sql); defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: text)
    }

    private func scalarInt(_ sql: String) throws -> Int? {
        let stmt = try prepare(sql); defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : nil
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let db else { throw StoreError(message: "the database is closed") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw OpenFailure.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        return stmt
    }

    private var available: Bool { db != nil && !{ if case .newerVersion = outcome { return true }; if case .unavailable = outcome { return true }; return false }() }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bind(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value { sqlite3_bind_text(stmt, index, value, -1, Self.transient) } else { sqlite3_bind_null(stmt, index) }
    }
    private func bind(_ stmt: OpaquePointer, _ index: Int32, _ value: Int64?) {
        if let value { sqlite3_bind_int64(stmt, index, value) } else { sqlite3_bind_null(stmt, index) }
    }
    private func bind(_ stmt: OpaquePointer, _ index: Int32, _ value: Double?) {
        if let value { sqlite3_bind_double(stmt, index, value) } else { sqlite3_bind_null(stmt, index) }
    }

    // MARK: Tasks

    private static let columns = "id, protocol, profile, state, priority, queue_order, created_at, updated_at, started_at, completed_at, scheduled_at, attempt, retry_count, source_url, source_host, filename, destination_path, temporary_path, integrity, total_bytes, completed_bytes, resume_available, failure_code, failure_reason, failure_retryable, engine_metadata, record_version, enqueued_at, retry_at"

    private func upsertLocked(_ r: DownloadTaskRecord) throws {
        let sql = """
        INSERT INTO tasks (\(Self.columns)) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23,?24,?25,?26,?27,?28,?29)
        ON CONFLICT(id) DO UPDATE SET protocol=excluded.protocol, profile=excluded.profile, state=excluded.state, priority=excluded.priority, queue_order=excluded.queue_order,
            updated_at=excluded.updated_at, started_at=excluded.started_at, completed_at=excluded.completed_at, scheduled_at=excluded.scheduled_at, attempt=excluded.attempt,
            retry_count=excluded.retry_count, source_url=excluded.source_url, source_host=excluded.source_host, filename=excluded.filename, destination_path=excluded.destination_path,
            temporary_path=excluded.temporary_path, integrity=excluded.integrity, total_bytes=excluded.total_bytes, completed_bytes=excluded.completed_bytes,
            resume_available=excluded.resume_available, failure_code=excluded.failure_code, failure_reason=excluded.failure_reason, failure_retryable=excluded.failure_retryable,
            engine_metadata=excluded.engine_metadata, record_version=excluded.record_version, enqueued_at=excluded.enqueued_at, retry_at=excluded.retry_at
        """
        let stmt = try prepare(sql); defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, r.id.uuidString); bind(stmt, 2, r.protocolID.rawValue); bind(stmt, 3, r.profile); bind(stmt, 4, r.state.rawValue)
        bind(stmt, 5, Int64(r.priority.rawValue)); bind(stmt, 6, Int64(r.queueOrder))
        bind(stmt, 7, r.createdAt.timeIntervalSince1970); bind(stmt, 8, r.updatedAt.timeIntervalSince1970)
        bind(stmt, 9, r.startedAt?.timeIntervalSince1970); bind(stmt, 10, r.completedAt?.timeIntervalSince1970); bind(stmt, 11, r.scheduledAt?.timeIntervalSince1970)
        bind(stmt, 12, Int64(r.attempt)); bind(stmt, 13, Int64(r.retryCount))
        bind(stmt, 14, DownloadURLRedactor.persistable(r.source.url)); bind(stmt, 15, r.source.host); bind(stmt, 16, r.file.filename); bind(stmt, 17, r.file.destinationPath); bind(stmt, 18, r.file.temporaryPath)
        bind(stmt, 19, r.file.integrity.rawValue); bind(stmt, 20, r.transfer.totalBytes); bind(stmt, 21, r.transfer.completedBytes); bind(stmt, 22, r.transfer.resumeAvailable ? 1 : 0 as Int64)
        bind(stmt, 23, r.failure?.code); bind(stmt, 24, r.failure?.reason); bind(stmt, 25, r.failure.map { $0.retryable ? 1 : 0 as Int64 })
        let (meta, rejected) = DownloadEngineMetadata.reconcile(r.engineMetadata)
        if !rejected.isEmpty, failedWrites.count < 20 { failedWrites.append("saving the details of \(r.file.filename): left out \(rejected.map { "\($0.key) (\($0.reason.rawValue))" }.joined(separator: ", "))") }
        bind(stmt, 26, meta.isEmpty ? nil : (try? JSONEncoder().encode(meta)).flatMap { String(data: $0, encoding: .utf8) })
        bind(stmt, 27, Int64(r.recordVersion))
        bind(stmt, 28, r.enqueuedAt?.timeIntervalSince1970); bind(stmt, 29, r.retryAt?.timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw OpenFailure.sqlite(String(cString: sqlite3_errmsg(db))) }
    }

    private func readRecord(_ stmt: OpaquePointer) -> DownloadTaskRecord? {
        func text(_ i: Int32) -> String? { sqlite3_column_text(stmt, i).map { String(cString: $0) } }
        func int(_ i: Int32) -> Int64? { sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, i) }
        func date(_ i: Int32) -> Date? { sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, i)) }
        guard let idText = text(0), let id = UUID(uuidString: idText), let proto = text(1).map(DownloadProtocolID.init(rawValue:)), proto.isValid,
              let profile = text(2), let state = text(3).flatMap(DownloadState.init(rawValue:)), let filename = text(15) else { return nil }
        var r = DownloadTaskRecord(id: id, protocolID: proto, profile: profile, source: DownloadSourceRef(url: text(13), host: text(14)), filename: filename,
                                   now: date(6) ?? Date())
        r.state = state
        r.priority = DownloadPriority(rawValue: Int(int(4) ?? 1)) ?? .normal
        r.queueOrder = Int(int(5) ?? 0)
        r.updatedAt = date(7) ?? r.createdAt
        r.startedAt = date(8); r.completedAt = date(9); r.scheduledAt = date(10)
        r.attempt = Int(int(11) ?? 0); r.retryCount = Int(int(12) ?? 0)
        r.file.destinationPath = text(16); r.file.temporaryPath = text(17)
        r.file.integrity = text(18).flatMap(DownloadIntegrity.init(rawValue:)) ?? .unknown
        r.transfer = DownloadTransfer(totalBytes: int(19), completedBytes: int(20) ?? 0, resumeAvailable: (int(21) ?? 0) != 0)
        if let reason = text(23) { r.failure = DownloadFailureInfo(code: text(22) ?? "", reason: reason, retryable: (int(24) ?? 0) != 0) }
        if let json = text(25), let data = json.data(using: .utf8), let meta = try? JSONDecoder().decode([String: String].self, from: data) { r.engineMetadata = DownloadEngineMetadata.validated(meta) }
        r.recordVersion = Int(int(26) ?? 1)
        r.enqueuedAt = date(27); r.retryAt = date(28)
        return r
    }

    // MARK: Public API

    /// Every task this profile has, oldest first, and how many rows could not be read (never silently dropped: the count is the caller's to report).
    func loadAll(profile: String) -> (records: [DownloadTaskRecord], unreadable: Int) {
        queue.sync {
            guard available, let stmt = try? prepare("SELECT \(Self.columns) FROM tasks WHERE profile = ?1 ORDER BY created_at, id") else { return ([], 0) }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, profile)
            var out: [DownloadTaskRecord] = []
            var bad = 0
            while sqlite3_step(stmt) == SQLITE_ROW { if let r = readRecord(stmt) { out.append(r) } else { bad += 1 } }
            return (out, bad)
        }
    }

    func resumeData(for id: DownloadTaskID) -> Data? {
        queue.sync {
            guard available, let stmt = try? prepare("SELECT data FROM task_resume WHERE task_id = ?1") else { return nil }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, id.uuidString)
            guard sqlite3_step(stmt) == SQLITE_ROW, let bytes = sqlite3_column_blob(stmt, 0) else { return nil }
            let count = Int(sqlite3_column_bytes(stmt, 0))
            guard count > 0, count <= Self.maxResumeBytes else { return nil }
            return Data(bytes: bytes, count: count)
        }
    }

    /// Writes a task (and, when given, its resume data, or removes it with `.some(nil)`) in one transaction, off the calling thread, in the order asked.
    func save(_ record: DownloadTaskRecord, resumeData: Data?? = nil) {
        queue.async { [self] in
            guard available else { return }
            do {
                try exec("BEGIN IMMEDIATE")
                do {
                    try upsertLocked(record)
                    if let resumeData { try writeResumeLocked(record.id, resumeData) }
                    if record.state.isFinal || record.state == .failed { try pruneLocked(profile: record.profile) }
                    try exec("COMMIT")
                } catch { try? exec("ROLLBACK"); throw error }
            } catch { recordFailure("saving \(record.file.filename): \(error)") }
        }
    }

    private func writeResumeLocked(_ id: DownloadTaskID, _ data: Data?) throws {
        if let data, !data.isEmpty, data.count <= Self.maxResumeBytes {
            let stmt = try prepare("INSERT INTO task_resume (task_id, data) VALUES (?1, ?2) ON CONFLICT(task_id) DO UPDATE SET data = excluded.data")
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, id.uuidString)
            _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 2, $0.baseAddress, Int32(data.count), Self.transient) }
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw OpenFailure.sqlite(String(cString: sqlite3_errmsg(db))) }
        } else {
            let stmt = try prepare("DELETE FROM task_resume WHERE task_id = ?1"); defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, id.uuidString)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw OpenFailure.sqlite(String(cString: sqlite3_errmsg(db))) }
        }
    }

    func delete(_ id: DownloadTaskID) {
        queue.async { [self] in
            guard available else { return }
            do {
                let stmt = try prepare("DELETE FROM tasks WHERE id = ?1"); defer { sqlite3_finalize(stmt) }
                bind(stmt, 1, id.uuidString)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw OpenFailure.sqlite(String(cString: sqlite3_errmsg(db))) }
            } catch { recordFailure("removing a task: \(error)") }
        }
    }

    /// Keeps the table bounded: the newest finished and failed/cancelled records are kept, the rest removed (with their resume data).
    private func pruneLocked(profile: String) throws {
        for (states, keep) in [("'completed'", Self.keepCompleted), ("'failed','cancelled'", Self.keepFailedOrCancelled)] {
            let stmt = try prepare("DELETE FROM tasks WHERE id IN (SELECT id FROM tasks WHERE profile = ?1 AND state IN (\(states)) ORDER BY updated_at DESC LIMIT -1 OFFSET \(keep))")
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, profile)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw OpenFailure.sqlite(String(cString: sqlite3_errmsg(db))) }
        }
    }

    // MARK: Pieces

    /// Replaces a task's plan: all of it, or none of it.
    func savePlan(task: DownloadTaskID, pieces: [PieceRecord]) throws {
        try queue.sync {
            guard available else { throw StoreError(message: "the downloads database is not available") }
            try exec("BEGIN IMMEDIATE")
            do {
                try deletePiecesLocked(task)
                for piece in pieces { try insertPieceLocked(task, piece) }
                try exec("COMMIT")
            } catch { try? exec("ROLLBACK"); throw error }
        }
    }

    private func insertPieceLocked(_ task: DownloadTaskID, _ p: PieceRecord) throws {
        let stmt = try prepare("INSERT INTO task_pieces (task_id, idx, start_byte, end_byte, state, checksum, session) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, task.uuidString); bind(stmt, 2, Int64(p.index)); bind(stmt, 3, p.start); bind(stmt, 4, p.end)
        bind(stmt, 5, p.state.rawValue); bind(stmt, 6, p.checksum); bind(stmt, 7, Int64(p.session))
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw OpenFailure.sqlite(String(cString: sqlite3_errmsg(db))) }
    }

    private func deletePiecesLocked(_ task: DownloadTaskID) throws {
        let stmt = try prepare("DELETE FROM task_pieces WHERE task_id = ?1"); defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, task.uuidString)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw OpenFailure.sqlite(String(cString: sqlite3_errmsg(db))) }
    }

    /// Marks one piece done. Called only after its bytes are safely on disk; written in order with everything else.
    func markPieceDone(task: DownloadTaskID, index: Int, checksum: String, session: Int) {
        queue.async { [self] in
            guard available else { return }
            do {
                let stmt = try prepare("UPDATE task_pieces SET state = 'done', checksum = ?3, session = ?4 WHERE task_id = ?1 AND idx = ?2")
                defer { sqlite3_finalize(stmt) }
                bind(stmt, 1, task.uuidString); bind(stmt, 2, Int64(index)); bind(stmt, 3, checksum); bind(stmt, 4, Int64(session))
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw OpenFailure.sqlite(String(cString: sqlite3_errmsg(db))) }
            } catch { recordFailure("saving a piece of a download: \(error)") }
        }
    }

    func loadPieces(task: DownloadTaskID) -> [PieceRecord] {
        queue.sync {
            guard available, let stmt = try? prepare("SELECT idx, start_byte, end_byte, state, checksum, session FROM task_pieces WHERE task_id = ?1 ORDER BY idx") else { return [] }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, task.uuidString)
            var out: [PieceRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let state = sqlite3_column_text(stmt, 3).map({ String(cString: $0) }).flatMap(PieceRecord.State.init(rawValue:)) else { continue }
                out.append(PieceRecord(index: Int(sqlite3_column_int64(stmt, 0)), start: sqlite3_column_int64(stmt, 1), end: sqlite3_column_int64(stmt, 2), state: state,
                                       checksum: sqlite3_column_text(stmt, 4).map { String(cString: $0) }, session: Int(sqlite3_column_int64(stmt, 5))))
            }
            return out
        }
    }

    func deletePieces(task: DownloadTaskID) {
        queue.async { [self] in
            guard available else { return }
            do { try deletePiecesLocked(task) } catch { recordFailure("removing the pieces of a download: \(error)") }
        }
    }

    func pieceCount() -> Int { queue.sync { (try? scalarInt("SELECT COUNT(*) FROM task_pieces")) ?? 0 } }

    // MARK: Meta, flushing, failures

    func meta(_ key: String) -> String? {
        queue.sync {
            guard available, let stmt = try? prepare("SELECT value FROM meta WHERE key = ?1") else { return nil }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, key)
            return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_text(stmt, 0).map { String(cString: $0) } : nil
        }
    }

    func setMeta(_ key: String, _ value: String) {
        queue.async { [self] in
            guard available, let stmt = try? prepare("INSERT INTO meta (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value") else { return }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, key); bind(stmt, 2, value)
            if sqlite3_step(stmt) != SQLITE_DONE { recordFailure("saving a setting") }
        }
    }

    /// Runs `body` with every task write so far applied, then returns: for quitting, and for a read that must see what was just written.
    func flush() { queue.sync {} }

    /// Runs several writes as one transaction (a migration is all or nothing).
    func transaction(_ body: @escaping (DownloadTaskStore) throws -> Void) throws {
        try queue.sync {
            guard available else { throw StoreError(message: "the downloads database is not available") }
            try exec("BEGIN IMMEDIATE")
            do {
                try body(self)
                try exec("COMMIT")
            } catch { try? exec("ROLLBACK"); throw error }
        }
    }

    /// For use inside `transaction` only.
    func saveInTransaction(_ record: DownloadTaskRecord, resumeData: Data?) throws {
        try upsertLocked(record)
        if let resumeData { try writeResumeLocked(record.id, resumeData) }
    }

    func setMetaInTransaction(_ key: String, _ value: String) throws {
        let stmt = try prepare("INSERT INTO meta (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, key); bind(stmt, 2, value)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw OpenFailure.sqlite(String(cString: sqlite3_errmsg(db))) }
    }

    private func recordFailure(_ message: String) {
        failedWrites.append(message)
        if failedWrites.count > 20 { failedWrites.removeFirst(failedWrites.count - 20) }
    }

    /// Write failures since the last call (each is reported once).
    func takeFailures() -> [String] { queue.sync { let out = failedWrites; failedWrites = []; return out } }

    /// How many tasks and resume blobs the file holds (for tests and diagnostics).
    func counts() -> (tasks: Int, resume: Int) {
        queue.sync { ((try? scalarInt("SELECT COUNT(*) FROM tasks")) ?? 0, (try? scalarInt("SELECT COUNT(*) FROM task_resume")) ?? 0) }
    }
}
