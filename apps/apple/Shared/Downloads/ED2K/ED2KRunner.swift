import Foundation

extension DownloadProtocolID {
    static let ed2k: Self = "ed2k"
}

/// eD2k choices, saved per profile. Off until the person turns it on; the servers are only ever ones they typed in; nothing is contacted because a link was pasted.
struct ED2KSettings: Codable, Equatable, Sendable {
    var enabled = false
    /// "address:port" of eD2k servers the person chose to ask for sources. Public IPv4 addresses only.
    var servers: [String] = []
    var maxActiveDownloads = 3
    var maxSourcesPerDownload = 8
    var maxConnectionsTotal = 40
    var downloadLimit: Int64?

    static let activeRange = 1...10, sourcesRange = 1...20, totalRange = 5...100, maxServers = 5

    func normalized() -> ED2KSettings {
        var s = self
        s.maxActiveDownloads = min(max(s.maxActiveDownloads, Self.activeRange.lowerBound), Self.activeRange.upperBound)
        s.maxSourcesPerDownload = min(max(s.maxSourcesPerDownload, Self.sourcesRange.lowerBound), Self.sourcesRange.upperBound)
        s.maxConnectionsTotal = min(max(s.maxConnectionsTotal, Self.totalRange.lowerBound), Self.totalRange.upperBound)
        s.downloadLimit = BandwidthController.valid(s.downloadLimit)
        s.servers = Array(s.servers.compactMap { Self.parseServer($0) }.map { "\($0.host):\($0.port)" }.prefix(Self.maxServers))
        return s
    }

    /// "1.2.3.4:4661" to an address, or nil. A name is refused: looking it up would be a request nobody asked for.
    static func parseServer(_ text: String) -> PeerAddress? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, let port = UInt16(parts[1]), port > 0, let host = try? ED2KLink.publicIPv4(parts[0]) else { return nil }
        return PeerAddress(host: host, port: port)
    }

    var serverAddresses: [PeerAddress] { servers.compactMap(Self.parseServer) }

    func encoded() -> String? { (try? JSONEncoder().encode(normalized())).flatMap { String(data: $0, encoding: .utf8) } }
    static func decode(_ text: String?) -> ED2KSettings {
        guard let text, text.utf8.count < 4096, let data = text.data(using: .utf8), let s = try? JSONDecoder().decode(ED2KSettings.self, from: data) else { return ED2KSettings() }
        return s.normalized()
    }
}

enum ED2KBandwidth { static let download = BandwidthController() }

/// How many eD2k downloads may run at once: its own pool in the scheduler.
final class ED2KSlots: ResourcePool, @unchecked Sendable {
    static let shared = ED2KSlots()
    static let poolName = "ed2k"
    var name: String { Self.poolName }
    private let lock = NSLock()
    private var holders = Set<UUID>()
    private var limit = 3
    func setLimit(_ v: Int) { lock.lock(); limit = max(1, v); lock.unlock() }
    var open: Int { lock.lock(); defer { lock.unlock() }; return holders.count }
    func canGrant(_ amount: Int, scope: String?) -> Bool { lock.lock(); defer { lock.unlock() }; return holders.count + amount <= limit }
    func grant(_ amount: Int, scope: String?, task: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if holders.contains(task) { return true }
        guard holders.count + amount <= limit else { return false }
        holders.insert(task); return true
    }
    func release(task: UUID) { lock.lock(); holders.remove(task); lock.unlock() }
}

/// What the person sees before an eD2k download starts. Nothing has been contacted to make this.
struct ED2KInspection: Sendable {
    var file: ED2KLink.File
    var servers: [String]
    var privacyNotice: String
    var hasWayToFindSources: Bool
    var identityNote: String
}

enum ED2KError: Error, LocalizedError, Equatable {
    case disabled, notAFileLink, noSources(String)
    var errorDescription: String? {
        switch self {
        case .disabled: "eD2k downloads are off. Turn them on in Settings → Downloads first: the people sharing the file will be able to see your network address."
        case .notAFileLink: "That link is not for a file."
        case .noSources(let why): why
        }
    }
}

/// Connects an eD2k download to the rest of the downloads system. The ledger owns the task, the scheduler decides when it runs, `ED2KSession` owns the connections.
@MainActor
final class ED2KRunner {
    static let sentinel = Data("{\"engine\":\"ed2k\",\"v\":1}".utf8)

    private unowned let coordinator: DownloadCoordinator
    private var ledger: DownloadLedger { coordinator.ledger }
    private var sessions: [UUID: ED2KSession] = [:]
    private var storages: [UUID: ED2KStorage] = [:]
    private var finishing = Set<UUID>()
    var transports: PeerTransportFactory
    var sessionSettings = ED2KSession.Settings()

    init(coordinator: DownloadCoordinator) {
        self.coordinator = coordinator
        let network: () -> DownloadNetworkSetup = { [weak coordinator] in coordinator?.http.engine.currentNetwork ?? DownloadNetworkSetup() }
        transports = NWPeerTransportFactory(network: network)
    }

    var settings: ED2KSettings { coordinator.ed2kSettings }

    // MARK: Looking (no network)

    func inspect(link text: String) throws -> ED2KInspection {
        guard case .file(let file) = try ED2KLink.parse(text) else { throw ED2KError.notAFileLink }
        return inspection(of: file)
    }

    func inspection(of file: ED2KLink.File) -> ED2KInspection {
        let servers = settings.servers
        return ED2KInspection(
            file: file, servers: servers,
            privacyNotice: "The people who share this file, and the eD2k servers you have chosen, will see your network address. Browser Setu opens no port for incoming connections and shares nothing. It contacts the servers you listed, and the sources they (or the link) name, up to 8 from the link.",
            hasWayToFindSources: !servers.isEmpty || !file.sources.isEmpty,
            identityNote: "Every part is checked against the file's eD2k hash (MD4). That shows it is the file the link names; MD4 is weak, so it does not prove the file is genuine or safe.")
    }

    // MARK: Starting

    @discardableResult
    func add(_ file: ED2KLink.File, expectedSHA256: String? = nil) async throws -> UUID {
        guard settings.enabled else { throw ED2KError.disabled }
        guard !settings.serverAddresses.isEmpty || !file.sources.isEmpty else {
            throw ED2KError.noSources("There is no way to find sources: the link names none, and no eD2k server is set up in Settings → Downloads.")
        }
        let sha = expectedSHA256.flatMap(DownloadIntegrityCheck.normalizedDigest)
        let ticket = await coordinator.admitTicket(filename: file.name, source: nil, protocolID: .ed2k)
        coordinator.ledger.update(ticket.id) { $0.engineMetadata["ed2k"] = "1"; $0.engineMetadata["ed2kHash"] = file.hashHex; $0.engineMetadata["origin"] = DownloadRequestOrigin.user.rawValue
            if let sha { $0.engineMetadata["sha256"] = sha; $0.engineMetadata["sha256From"] = "user" } }
        guard ticket.admitted else { return ticket.id }
        let id = ticket.id
        if await coordinator.askAboutDuplicate(suggestedName: file.name, sourceHost: nil, source: nil, isPrivate: false, taskID: id) { return id }
        let started = coordinator.begin(suggestedName: file.name, sourceHost: nil, sourceURL: nil, isPrivate: false, taskID: id, protocolID: .ed2k,
                                        cancel: { [weak self] in self?.cancel(id) }, suspend: { [weak self] done in self?.pause(id, done: done) })
        let parent = started.destination.deletingLastPathComponent()
        let storage = ED2KStorage(size: file.size, partFile: ED2KStorage.partFile(for: id, in: parent))
        do { try storage.prepare() } catch {
            storage.discard()
            fail(id, (error as? LocalizedError)?.errorDescription ?? "The download could not be prepared.", retryable: false); return id
        }
        let parts = (0..<ED2KHash.partCount(size: file.size)).map { PieceRecord(index: $0, start: Int64($0) * ED2KHash.partSize, end: Int64($0) * ED2KHash.partSize + ED2KHash.partLength($0, size: file.size) - 1) }
        try? ledger.store?.savePlan(task: id, pieces: parts)
        ledger.update(id) { $0.transfer.totalBytes = file.size; $0.transfer.resumeAvailable = true; $0.engineMetadata["partFile"] = storage.partFile.lastPathComponent }
        ledger.saveResumeData(id, Self.sentinel)
        if let known = file.partHashes { Self.saveHashes(known, beside: storage.partFile) }
        run(id, file: file, storage: storage, have: [], destination: started.destination)
        return id
    }

    private func run(_ id: UUID, file: ED2KLink.File, storage: ED2KStorage, have: Set<Int>, destination: URL) {
        var s = sessionSettings
        s.maxPeers = settings.maxSourcesPerDownload
        let session = ED2KSession(file: file, servers: settings.serverAddresses, extraSources: [], storage: { storage }, alreadyHave: have, transports: transports,
                                  download: ED2KBandwidth.download, taskID: id, settings: s)
        sessions[id] = session; storages[id] = storage
        session.onEvent = { [weak self] event in DispatchQueue.main.async { self?.handle(event, id: id, destination: destination, storage: storage) } }
        session.start()
    }

    // MARK: Events

    private func handle(_ event: ED2KSession.Event, id: UUID, destination: URL, storage: ED2KStorage) {
        guard sessions[id] != nil else { return }
        switch event {
        case .progress(let done, let total): coordinator.update(id, fraction: total > 0 ? min(0.99, Double(done) / Double(total)) : 0, completed: done, total: total)
        case .verifiedPart(let index, let md4): ledger.store?.markPieceDone(task: id, index: index, checksum: md4, session: 1)
        case .hashset(let hashes): Self.saveHashes(hashes, beside: storage.partFile)
        case .finished: finish(id, destination: destination)
        case .failed(let why, let retryable): teardown(id); fail(id, why, retryable: retryable)
        }
    }

    private func finish(_ id: UUID, destination: URL) {
        guard !finishing.contains(id), let storage = storages[id], let running = sessions[id] else { return }
        let parent = destination.deletingLastPathComponent()
        guard DownloadPathPolicy.isAuthorized(destination.path, roots: coordinator.managedRoots) else {
            teardown(id); fail(id, "This download's folder is outside the download folder, so nothing was moved.", retryable: false); return
        }
        finishing.insert(id)
        running.stop { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.sessions[id] === running, self.storages[id] === storage else { self.finishing.remove(id); return }
                Task { @MainActor in
                    defer { self.finishing.remove(id) }
                    do {
                        let name = destination.lastPathComponent
                        let placed = try await Task.detached { try storage.finish(into: parent, name: name) }.value          // the flush and the move are not done on the main thread
                        self.coordinator.updateDestination(id, to: placed)
                        // A SHA-256 from a source the person trusts is checked on the finished file with the same service as every other download; a mismatch deletes the file.
                        if let sha = self.ledger.record(id)?.engineMetadata["sha256"] {
                            let report = try await DownloadIntegrityCheck.verifyAsync(file: placed, expectedSHA256: sha, expectedSize: storage.size, digestIsTrusted: true)
                            if case .doesNotMatchChecksum = report.outcome {
                                try? FileManager.default.removeItem(at: placed); self.teardown(id)
                                self.fail(id, "The file matches its eD2k hash but not the SHA-256 you gave, so it was deleted.", retryable: false); return
                            }
                        }
                        self.ledger.update(id) { $0.transfer.totalBytes = storage.size; $0.transfer.completedBytes = storage.size; $0.transfer.resumeAvailable = false }
                        self.teardown(id)
                        Self.removeHashes(beside: storage.partFile)
                        self.coordinator.finish(id, source: nil, integrity: .verified)
                    } catch {
                        self.teardown(id)
                        self.fail(id, (error as? LocalizedError)?.errorDescription ?? "The finished file could not be put in place.", retryable: false)
                    }
                }
            }
        }
    }

    func isFinishing(_ id: UUID) -> Bool { finishing.contains(id) }

    private func teardown(_ id: UUID) {
        let session = sessions[id], storage = storages[id]
        sessions[id] = nil; storages[id] = nil
        if let session { session.stop { storage?.closeFile() } } else { storage?.closeFile() }
        ED2KBudget.peers.releaseAll(task: id); ED2KBudget.servers.releaseAll(task: id)
        ED2KBandwidth.download.discard(task: id)
    }

    private func fail(_ id: UUID, _ reason: String, retryable: Bool) {
        coordinator.fail(id, source: nil, error: HTTPDownloadError(info: DownloadFailureInfo(code: "ed2k:failed", reason: reason, retryable: retryable)), willRetry: false)
    }

    // MARK: Pause, resume, cancel

    func stopAllBecauseDisabled() {
        for id in Array(sessions.keys) {
            if coordinator.canPause(id) { coordinator.pause(id) } else { teardown(id); fail(id, ED2KError.disabled.localizedDescription ?? "eD2k downloads are off.", retryable: true) }
        }
    }

    func pause(_ id: UUID, done: @escaping (Data?) -> Void) {
        guard let session = sessions[id] else { done(nil); return }
        let storage = storages[id]
        session.stop { [weak self] in
            storage?.sync()
            DispatchQueue.main.async { self?.teardown(id); done(Self.sentinel) }
        }
    }

    nonisolated static func isPartFileName(_ name: String) -> Bool { name.range(of: #"^\.[0-9A-Fa-f]{8}\.bsetu-ed2k$"#, options: .regularExpression) != nil }

    func cancel(_ id: UUID) {
        let saved = ledger.record(id)
        let known = storages[id]?.partFile
        teardown(id)
        var target = known
        if target == nil, let name = saved?.engineMetadata["partFile"], Self.isPartFileName(name), let dest = saved?.file.destinationPath, DownloadPathPolicy.isAuthorized(dest, roots: coordinator.managedRoots) {
            target = URL(fileURLWithPath: dest).deletingLastPathComponent().appendingPathComponent(name)
        }
        if let target { try? FileManager.default.removeItem(at: target); Self.removeHashes(beside: target) }
        ledger.store?.deletePieces(task: id)
    }

    /// Carries on from the checked parts. What the file holds is checked again at the end, whatever the records say; a file that is missing or the wrong size starts over.
    func resume(_ id: UUID) {
        guard settings.enabled else { fail(id, ED2KError.disabled.localizedDescription ?? "eD2k downloads are off.", retryable: true); return }
        guard let record = ledger.record(id), let dest = record.file.destinationPath, let name = record.engineMetadata["partFile"], Self.isPartFileName(name), let hex = record.engineMetadata["ed2kHash"],
              let hash = Data(hex: hex), hash.count == 16, let size = record.transfer.totalBytes, size > 0 else { fail(id, "The saved details of this download are missing.", retryable: false); return }
        guard DownloadPathPolicy.isAuthorized(dest, roots: coordinator.managedRoots) else { fail(id, "This download's folder is outside the download folders.", retryable: false); return }
        let partFile = URL(fileURLWithPath: dest).deletingLastPathComponent().appendingPathComponent(name)
        let storage = ED2KStorage(size: size, partFile: partFile)
        var have = Set((ledger.store?.loadPieces(task: id) ?? []).filter { $0.state == .done }.map(\.index))
        if !storage.existsAtFullSize { have = []; coordinator.note("\(record.file.filename): the partly downloaded file was not there, so it starts again") }
        do { try storage.prepare() } catch { fail(id, (error as? LocalizedError)?.errorDescription ?? "The file could not be opened.", retryable: false); return }
        let known = Self.loadHashes(beside: partFile).flatMap { ED2KHash.validatedPartHashes($0, fileHash: hash, size: size) }
        let file = ED2KLink.File(name: record.file.filename, size: size, hash: hash, partHashes: known, aichRoot: nil, sources: [])
        ledger.apply(.resumed, to: id)
        run(id, file: file, storage: storage, have: have, destination: URL(fileURLWithPath: dest))
    }

    // MARK: Part hashes kept beside the file (the file's own hash vouches for them when they are read back)

    private nonisolated static func hashesFile(beside partFile: URL) -> URL { partFile.appendingPathExtension("hashes") }
    nonisolated static func saveHashes(_ hashes: [Data], beside partFile: URL) { try? hashes.reduce(Data(), +).write(to: hashesFile(beside: partFile)) }
    nonisolated static func removeHashes(beside partFile: URL) { try? FileManager.default.removeItem(at: hashesFile(beside: partFile)) }
    nonisolated static func loadHashes(beside partFile: URL) -> [Data]? {
        let url = hashesFile(beside: partFile)
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0, size % 16 == 0, size <= 16 * 20_000, let data = try? Data(contentsOf: url) else { return nil }
        return stride(from: 0, to: data.count, by: 16).map { data.subdata(in: $0..<($0 + 16)) }
    }

    // MARK: For the dashboard

    struct Live: Sendable { var snapshot: ED2KSession.Snapshot }
    func live(_ id: UUID) -> Live? { sessions[id].map { Live(snapshot: $0.snapshot) } }
}

enum ED2KTransferEngine {
    static let protocolID: DownloadProtocolID = .ed2k
    /// Pause and resume work from the checked parts. Speed limits are held where data is read. It sends nothing to other peers: this client only downloads.
    static let capabilities: DownloadEngineCapabilities = [.pause, .resume, .verify, .reportsTotalBytes, .pieces, .enforcesSpeedLimit]
}
