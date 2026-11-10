import Foundation

// A file on an FTP, FTPS or SFTP server as an ordinary BrowserSetu download. The coordinator owns the task (queue, limits, progress, pause, cancel, retry, history, naming, publication, Finder);
// this runner only does the protocol part: open a session, read the bytes, keep what was read when interrupted, and carry on from it.
//
// Each file has its own session (one `ssh` or `curl` per file). That is a deliberate trade: a stalled or cancelled file can be stopped without disturbing the others, and a server that closes idle
// connections costs nothing. The coordinator's per-host connection limit keeps the number of simultaneous sessions to a server small.

struct RemoteFileJob: Sendable {
    var connection: UUID
    var path: String                    // absolute, "/" separated, on the server
    var size: Int64?
    var modified: Date?
    var filename: String                // already a safe local name
    /// Folders (already safe local names) below the collection folder, for a file found inside a downloaded folder.
    var subfolders: [String] = []
    var collectionFolder: String?
    var isPrivate = false
}

@MainActor
final class RemoteFileRunner {
    static let sentinel = Data("{\"engine\":\"remote\",\"v\":1}".utf8)
    static let maxAttempts = 4

    private unowned let coordinator: DownloadCoordinator
    private var ledger: DownloadLedger { coordinator.ledger }
    private var runs: [UUID: Task<Void, Never>] = [:]
    private var sessions: [UUID: RemoteSession] = [:]
    private var finishing = Set<UUID>()
    private var pendingFolders: [UUID: String] = [:]
    /// Tests shorten the pause between tries.
    nonisolated(unsafe) static var backoffSeconds: Double = 2

    init(coordinator: DownloadCoordinator) { self.coordinator = coordinator }

    func isFinishing(_ id: UUID) -> Bool { finishing.contains(id) }
    private var network: DownloadNetworkSetup { coordinator.http.engine.currentNetwork }

    // MARK: Adding

    /// Makes one task for one remote file and returns its id at once: the record exists (queued) before this returns, so a collection can hold it while it waits for a place in line.
    @discardableResult
    func add(_ job: RemoteFileJob) -> UUID? {
        guard let connection = coordinator.remotes.connection(job.connection) ?? coordinator.remotes.ephemeral(job.connection) else { return nil }
        let display = (connection.displayURL).flatMap { u -> URL? in var c = URLComponents(url: u, resolvingAgainstBaseURL: false); c?.path = job.path; return c?.url }
        let id = UUID()
        let name = DownloadCoordinator.safeName(job.filename)
        ledger.create(id: id, protocolID: .remoteFile, source: display, filename: name, isPrivate: job.isPrivate)
        ledger.apply(.queued, to: id)
        let folder = ([job.collectionFolder].compactMap { $0 } + job.subfolders).joined(separator: "/")
        ledger.update(id) {
            $0.engineMetadata["remoteConn"] = connection.id.uuidString
            $0.engineMetadata["remotePath"] = job.path
            $0.engineMetadata["remoteScheme"] = connection.scheme.rawValue
            if let s = job.size { $0.engineMetadata["remoteSize"] = String(s) }
            if let m = job.modified { $0.engineMetadata["remoteMTime"] = String(Int(m.timeIntervalSince1970)) }
            if let s = job.size { $0.transfer.totalBytes = s }
        }
        // (The folder is applied when the task starts, not now: adding a queued task to a collection sets its folder from the collection's own, and would replace this one.)
        if !folder.isEmpty { pendingFolders[id] = folder }
        if let display { coordinator.reserveTaskID(id, for: display) }
        Task { @MainActor in
            let ticket = await coordinator.admitTicket(filename: name, source: display, isPrivate: job.isPrivate, protocolID: .remoteFile)
            guard ticket.admitted else { return }          // put off by a held queue: it starts from its metadata later
            start(ticket.id, name: name, source: display, isPrivate: job.isPrivate)
        }
        return id
    }

    private func start(_ id: UUID, name: String, source: URL?, isPrivate: Bool) {
        if let folder = pendingFolders.removeValue(forKey: id) { ledger.update(id) { $0.engineMetadata["packageFolder"] = folder } }
        let started = coordinator.begin(suggestedName: name, sourceHost: source?.host, sourceURL: source, isPrivate: isPrivate, taskID: id, protocolID: .remoteFile, staged: true,
                                        cancel: { [weak self] in self?.cancel(id) }, suspend: { [weak self] done in self?.pause(id, done: done) })
        ledger.update(id) { $0.transfer.resumeAvailable = true }
        ledger.saveResumeData(id, Self.sentinel)
        run(id, destination: started.destination)
    }

    // MARK: Running

    private func run(_ id: UUID, destination: URL) {
        runs[id]?.cancel()
        let setup = network
        runs[id] = Task { [weak self] in
            guard let self else { return }
            var attempt = 1
            while true {
                do {
                    try await self.transfer(id, destination: destination, network: setup)
                    return
                } catch is CancellationError { return }
                catch {
                    let remote = (error as? RemoteError) ?? .failed("\(error.localizedDescription)")
                    // The server cannot continue a partial file: start this one again from the beginning, once, instead of failing.
                    if remote == .unsupported("resume") { try? FileManager.default.removeItem(at: destination); self.ledger.update(id) { $0.engineMetadata["remoteRestarted"] = "1" }; if attempt == 1 { attempt += 1; continue } }
                    if remote.isRetryable, attempt < Self.maxAttempts, !Task.isCancelled {
                        self.coordinator.note("Retrying \(destination.lastPathComponent): \(remote.errorDescription ?? "")")
                        try? await Task.sleep(nanoseconds: UInt64(Self.backoffSeconds * pow(2, Double(attempt - 1)) * 1_000_000_000))
                        attempt += 1; continue
                    }
                    await self.fail(id, remote)
                    return
                }
            }
        }
    }

    private func transfer(_ id: UUID, destination: URL, network: DownloadNetworkSetup) async throws {
        guard let record = ledger.record(id), let path = record.engineMetadata["remotePath"], let connID = record.engineMetadata["remoteConn"].flatMap(UUID.init(uuidString:)),
              let conn = coordinator.remotes.connection(connID) ?? coordinator.remotes.ephemeral(connID) else {
            throw RemoteError.failed("The saved details of this server are missing, so this download cannot carry on. Add the file again.")
        }
        let secret = coordinator.remotes.secret(for: connID)
        if conn.needsSecret, secret == nil { throw RemoteError.authenticationFailed }
        let limit = BandwidthController.shared.effectiveLimit(for: id).map { Int($0.bytesPerSecond) }
        let session = try coordinator.remotes.makeSession(for: conn, secret: secret, network: network, rateLimit: limit, isPrivate: record.isPrivate)
        sessions[id] = session
        defer { session.close(); sessions[id] = nil }
        if let sftp = session as? SFTPSession { try await sftp.connect() }

        // What the server holds now, against what was recorded when the file was chosen.
        var size = record.engineMetadata["remoteSize"].flatMap { Int64($0) }
        var mtime = record.engineMetadata["remoteMTime"].flatMap { Double($0) }
        let current = try? await currentInfo(session, path)
        let existing = Self.fileSize(destination)
        if let current {
            let changed = (size != nil && current.size != nil && size != current.size) || (mtime != nil && current.mtime != nil && abs(mtime! - current.mtime!) > 2)
            if changed { try? FileManager.default.removeItem(at: destination); coordinator.note("\(destination.lastPathComponent) changed on the server: started again"); }
            if let s = current.size { size = s }
            if let m = current.mtime { mtime = m }
        }
        var offset = Self.fileSize(destination)
        if let size, offset > size { try? FileManager.default.removeItem(at: destination); offset = 0 }
        _ = existing
        ledger.update(id) { if let size { $0.engineMetadata["remoteSize"] = String(size); $0.transfer.totalBytes = size }; if let mtime { $0.engineMetadata["remoteMTime"] = String(Int(mtime)) } }

        // Room on this Mac, before a byte is fetched.
        if let size, let problem = DiskPreflight.problem(needed: size - offset, free: DiskPreflight.freeBytes(at: destination.deletingLastPathComponent())) { throw RemoteError.tooLarge(problem) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let reportTotal = size
        let report: @Sendable (Int64) -> Void = { [weak self] done in
            Task { @MainActor [weak self] in
                guard let self, self.runs[id] != nil else { return }
                if let reportTotal, reportTotal > 0 { self.coordinator.update(id, fraction: min(0.99, Double(done) / Double(reportTotal)), completed: done, total: reportTotal) }
            }
        }
        if let sftp = session as? SFTPSession {
            if !FileManager.default.fileExists(atPath: destination.path) { FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            let fd = open(destination.path, O_WRONLY)
            guard fd >= 0 else { throw RemoteError.failed("The file could not be created in the download folder.") }
            defer { close(fd) }
            if ftruncate(fd, off_t(offset)) != 0 { throw RemoteError.failed("The partial file could not be prepared.") }
            _ = try await withTaskCancellationHandler {
                try await sftp.download(path, into: fd, from: UInt64(offset), size: size.map { UInt64($0) }, rateLimit: { BandwidthController.shared.effectiveLimit(for: id)?.bytesPerSecond }) { done in report(Int64(done)) }
            } onCancel: { sftp.abort() }
        } else if let ftp = session as? FTPSession {
            try await ftp.download(path, to: destination, from: offset, onProgress: report)
        } else {
            throw RemoteError.unsupported("This kind of server is downloaded as an ordinary web file.")
        }
        try Task.checkCancellation()

        let got = Self.fileSize(destination)
        if let size, got != size { throw RemoteError.connectionLost("the file is \(got) bytes; the server said \(size)") }
        // Changed while it was being read: what was fetched may be a mixture of two versions.
        if let before = current, let after = try? await currentInfo(session, path), (before.size != nil && after.size != nil && before.size != after.size) || (before.mtime != nil && after.mtime != nil && abs(before.mtime! - after.mtime!) > 2) {
            try? FileManager.default.removeItem(at: destination)
            throw RemoteError.changedOnServer
        }
        await finalize(id, destination: destination, conn: conn, path: path, verifiedSize: size != nil)
    }

    private struct Info { var size: Int64?; var mtime: Double? }
    private func currentInfo(_ session: RemoteSession, _ path: String) async throws -> Info {
        if let s = session as? SFTPSession { let i = try await s.info(path); return Info(size: i.size.map { Int64(clamping: $0) }, mtime: i.mtime?.timeIntervalSince1970) }
        if let f = session as? FTPSession { let i = try await f.info(path); return Info(size: i.size, mtime: i.modified?.timeIntervalSince1970) }
        return Info()
    }

    private static func fileSize(_ url: URL) -> Int64 { ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0 }

    private func finalize(_ id: UUID, destination: URL, conn: RemoteConnection, path: String, verifiedSize: Bool) async {
        guard runs[id] != nil, !finishing.contains(id) else { return }
        finishing.insert(id); defer { finishing.remove(id) }
        let display = conn.displayURL
        DownloadQuarantine.apply(to: destination, sourceOrigin: display.map { HTTPRequestPolicy.origin(of: $0) } ?? "")
        runs[id] = nil
        ledger.update(id) { $0.transfer.resumeAvailable = false }
        coordinator.finish(id, source: display, integrity: verifiedSize ? .verified : .unknown)
    }

    private func fail(_ id: UUID, _ error: RemoteError) async {
        guard runs[id] != nil else { return }
        runs[id] = nil
        let retryable = error.isRetryable || error == .changedOnServer
        let source = ledger.record(id)?.source.asURL
        coordinator.fail(id, source: source, error: HTTPDownloadError(info: DownloadFailureInfo(code: "remote:failed", reason: error.errorDescription ?? "The transfer failed.", retryable: retryable)), willRetry: false)
    }

    // MARK: Pause, resume, cancel, retry

    func pause(_ id: UUID, done: @escaping (Data?) -> Void) {
        guard !finishing.contains(id), let run = runs[id] else { done(nil); return }
        runs[id] = nil
        run.cancel(); (sessions[id] as? SFTPSession)?.abort(); sessions[id]?.close()
        Task { await run.value; done(Self.sentinel) }          // the bytes already fetched stay where they are
    }

    func cancel(_ id: UUID) {
        runs[id]?.cancel(); runs[id] = nil
        (sessions[id] as? SFTPSession)?.abort(); sessions[id]?.close()
    }

    func resume(_ id: UUID) {
        guard let record = ledger.record(id), let dest = record.file.destinationPath else { return }
        ledger.apply(.resumed, to: id)
        run(id, destination: URL(fileURLWithPath: dest))
    }

    func restart(_ id: UUID) {
        guard let record = ledger.record(id), let source = record.source.asURL, runs[id] == nil else { return }
        Task { @MainActor in
            coordinator.reserveTaskID(id, for: source)
            let ticket = await coordinator.admitTicket(filename: record.file.filename, source: source, protocolID: .remoteFile)
            guard ticket.admitted else { return }
            start(id, name: record.file.filename, source: source, isPrivate: record.isPrivate)
        }
    }
}
