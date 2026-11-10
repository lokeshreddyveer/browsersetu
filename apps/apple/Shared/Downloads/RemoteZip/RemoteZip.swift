import Foundation
import Compression

// Phase 20: taking chosen files out of a ZIP archive on a website without fetching the rest of it. Looking at the table of contents costs a few small range requests (never the whole
// archive); taking files is an ordinary task in the ledger (protocol `remoteZip`), scheduled, paused, resumed and cancelled like any other, saved in a folder of its own.

extension DownloadProtocolID { static let remoteZip: Self = "remoteZip" }

enum RemoteZipError: Error, Equatable, LocalizedError {
    case rangesUnavailable, noValidator, changed, notAZip, unusable(String)
    var errorDescription: String? {
        switch self {
        case .rangesUnavailable: "This website does not answer requests for part of a file, so single files cannot be taken out of the archive. You can download the whole archive instead."
        case .noValidator: "This website gives no reliable way to tell whether the archive changes between requests, so single files cannot be taken from it safely."
        case .changed: "The archive changed on the website while it was being read."
        case .notAZip: "This does not look like a ZIP archive."
        case .unusable(let why): why
        }
    }
}

struct RemoteZipListing: Sendable {
    var url: URL
    var name: String
    var total: Int64
    var validators: MediaFetcher.Validators
    var centralOffset: UInt64
    var entries: [ZipEntry]
    var zip64: Bool

    var supportedCount: Int { entries.filter(\.isSupported).count }
    /// What it would take to fetch these entries: the compressed bytes plus a small header each.
    func bytesToFetch(_ ids: Set<Int>) -> Int64 {
        entries.filter { ids.contains($0.id) && $0.isSupported && !$0.isDirectory }.reduce(Int64(0)) { $0 + Int64(clamping: $1.compressedSize) + 30 }
    }
    func uncompressed(_ ids: Set<Int>) -> Int64 { entries.filter { ids.contains($0.id) && $0.isSupported }.reduce(Int64(0)) { $0 + Int64(clamping: $1.uncompressedSize) } }
}

/// What a task keeps to carry on after a pause or a relaunch: which archive (and which version of it), and the entries chosen with the facts needed to fetch each. Addresses in it may be
/// signed, so it lives only in the task's private folder.
struct RemoteZipPlan: Codable, Equatable, Sendable {
    struct Item: Codable, Equatable, Sendable {
        var id: Int
        var path: [String]
        var isDirectory: Bool
        var method: UInt16
        var crc: UInt32
        var compressedSize: UInt64
        var uncompressedSize: UInt64
        var localHeaderOffset: UInt64
        var nameLength: Int
    }
    var version = 1
    var url: String
    var archiveName: String
    var total: Int64
    var etag: String?
    var lastModified: String?
    var centralOffset: UInt64
    var items: [Item]
    var validators: MediaFetcher.Validators { .init(etag: etag, lastModified: lastModified) }
}

@MainActor
enum RemoteZipStore {
    static let folderName = ".Browser Setu Zip"
    static var root: URL { DownloadCoordinator.directory.appendingPathComponent(folderName, isDirectory: true) }
    static func folder(profile: String, task: UUID) -> URL { root.appendingPathComponent(MediaStore.profileTag(profile), isDirectory: true).appendingPathComponent(task.uuidString, isDirectory: true) }
    static func isTaskFolder(_ url: URL) -> Bool { url.deletingLastPathComponent().deletingLastPathComponent() == root && UUID(uuidString: url.lastPathComponent) != nil }
    nonisolated static func save(_ plan: RemoteZipPlan, in dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(plan).write(to: dir.appendingPathComponent("plan.json"), options: .atomic)
    }
    nonisolated static func load(from dir: URL) -> RemoteZipPlan? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("plan.json")), data.count < 32_000_000, let p = try? JSONDecoder().decode(RemoteZipPlan.self, from: data), p.version == 1 else { return nil }
        return p
    }
    static func remove(_ dir: URL) { if isTaskFolder(dir) { try? FileManager.default.removeItem(at: dir) } }
    static func sweep(profile: String, keep: Set<UUID>) {
        let mine = root.appendingPathComponent(MediaStore.profileTag(profile), isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(at: mine, includingPropertiesForKeys: nil) else { return }
        for item in items { if let id = UUID(uuidString: item.lastPathComponent), !keep.contains(id) { remove(item) } }
    }
}

@MainActor
final class RemoteZipRunner {
    static let sentinel = Data("{\"engine\":\"remoteZip\",\"v\":1}".utf8)
    private unowned let coordinator: DownloadCoordinator
    private var ledger: DownloadLedger { coordinator.ledger }
    private var runs: [UUID: Task<Void, Never>] = [:]
    private var finishing = Set<UUID>()
    private(set) var progress: [UUID: (done: Int, total: Int)] = [:]
    /// Tests shorten the pause between steps / hold an entry at an exact point.
    nonisolated(unsafe) static var beforeEntry: (@Sendable (_ id: Int) async -> Void)?

    init(coordinator: DownloadCoordinator) { self.coordinator = coordinator }
    private var network: DownloadNetworkSetup { coordinator.http.engine.currentNetwork }
    func isFinishing(_ id: UUID) -> Bool { finishing.contains(id) }
    func live(_ id: UUID) -> (done: Int, total: Int)? { progress[id] }

    // MARK: Looking (a few range requests; never the archive)

    func inspect(_ url: URL, origin: DownloadRequestOrigin = .user) async throws -> RemoteZipListing {
        let fetcher = try MediaFetcher(policy: HTTPRequestPolicy(origin: origin), network: network, maxSegmentBytes: Int64(ZipFormat.maxEntrySize))
        defer { fetcher.invalidate() }
        // 1. One byte, to learn the size and the version, and that the server answers ranges correctly.
        let first: (data: Data, total: Int64?, validators: MediaFetcher.Validators)
        do { first = try await fetcher.rangeData(url, offset: 0, length: 1) }
        catch let e as HTTPDownloadError where e.info.code == "media:range-ignored" { throw RemoteZipError.rangesUnavailable }
        guard let total = first.total, total >= Int64(ZipFormat.eocdSize) else { throw RemoteZipError.notAZip }
        guard first.validators.isUsable else { throw RemoteZipError.noValidator }
        let v = first.validators
        func get(_ offset: UInt64, _ length: UInt64) async throws -> Data {
            do { return try await fetcher.rangeData(url, offset: Int64(offset), length: Int64(length), expect: v).data }
            catch is MediaFetcher.Changed { throw RemoteZipError.changed }
        }
        // 2. The last bytes, where the end record is.
        // A kilobyte nearly always holds it; an archive with a long comment needs more, and is then asked for the most the record can take.
        var end: ZipFormat.EndRecord?
        var lastError: ZipError = .notAZip
        for size in [Int64(1024), Int64(ZipFormat.tailSize)] {
            let tailLength = UInt64(min(size, total))
            let tail = try await get(UInt64(total) - tailLength, tailLength)
            do { end = try ZipFormat.findEnd(tail: tail, archiveSize: UInt64(total)); break }
            catch let e as ZipError { lastError = e; if e != .notAZip && e != .zip64Missing { throw RemoteZipError.unusable(e.errorDescription ?? "") } }
            if tailLength == UInt64(total) { break }
        }
        guard var end else { throw RemoteZipError.unusable(lastError.errorDescription ?? "Not a usable ZIP archive.") }
        var zip64 = false
        if let at = end.zip64RecordOffset {
            let (zipEnd, zipOverflow) = at.addingReportingOverflow(UInt64(ZipFormat.zip64RecordSize))
            guard !zipOverflow, zipEnd <= UInt64(total) else { throw RemoteZipError.unusable(ZipError.malformed("the ZIP64 record is outside the archive").errorDescription ?? "") }
            do { end = try ZipFormat.applyZip64(try await get(at, UInt64(ZipFormat.zip64RecordSize)), to: end); zip64 = true }
            catch let e as ZipError { throw RemoteZipError.unusable(e.errorDescription ?? "") }
        }
        do { try ZipFormat.validate(end, archiveSize: UInt64(total)) } catch let e as ZipError { throw RemoteZipError.unusable(e.errorDescription ?? "") }
        // 3. The table of contents.
        let directory = end.centralSize == 0 ? Data() : try await get(end.centralOffset, end.centralSize)
        let entries: [ZipEntry]
        do { entries = try ZipFormat.parseCentralDirectory(directory, entries: end.entries, archiveSize: UInt64(total), centralOffset: end.centralOffset) }
        catch let e as ZipError { throw RemoteZipError.unusable(e.errorDescription ?? "") }
        let name = url.deletingPathExtension().lastPathComponent
        return RemoteZipListing(url: url, name: DownloadFilename.sanitize(name.isEmpty ? (url.host ?? "archive") : name) ?? "archive", total: total, validators: v, centralOffset: end.centralOffset, entries: entries, zip64: zip64)
    }

    // MARK: Starting

    @discardableResult
    func add(_ listing: RemoteZipListing, selecting ids: Set<Int>, origin: DownloadRequestOrigin = .user) async throws -> UUID {
        let chosen = listing.entries.filter { ids.contains($0.id) && $0.isSupported }
        guard !chosen.isEmpty else { throw RemoteZipError.unusable("Choose at least one entry that can be taken.") }
        guard listing.bytesToFetch(ids) < 64 * 1024 * 1024 * 1024 else { throw RemoteZipError.unusable("That is more than one download may fetch.") }
        let items = chosen.compactMap { e -> RemoteZipPlan.Item? in
            e.path.map { RemoteZipPlan.Item(id: e.id, path: $0, isDirectory: e.isDirectory, method: e.method, crc: e.crc, compressedSize: e.compressedSize, uncompressedSize: e.uncompressedSize, localHeaderOffset: e.localHeaderOffset, nameLength: e.nameLength) }
        }
        let plan = RemoteZipPlan(url: listing.url.absoluteString, archiveName: listing.name, total: listing.total, etag: listing.validators.etag, lastModified: listing.validators.lastModified, centralOffset: listing.centralOffset, items: items)
        let ticket = await coordinator.admitTicket(filename: listing.name, source: listing.url, protocolID: .remoteZip)
        let id = ticket.id
        ledger.update(id) { $0.engineMetadata["origin"] = (origin == .user ? DownloadRequestOrigin.user : .page).rawValue; $0.engineMetadata["remoteZip"] = "1"; $0.engineMetadata["zipEntries"] = String(items.count) }
        // Put off by a held queue: the plan is kept with the task so it starts from it later, never as a plain download of the archive.
        guard ticket.admitted else { try? RemoteZipStore.save(plan, in: RemoteZipStore.folder(profile: ledger.profile, task: id)); return id }
        let started = coordinator.begin(suggestedName: listing.name, sourceHost: listing.url.host, sourceURL: listing.url, isPrivate: false, taskID: id, protocolID: .remoteZip,
                                        cancel: { [weak self] in self?.cancel(id) }, suspend: { [weak self] done in self?.pause(id, done: done) })
        let dir = RemoteZipStore.folder(profile: ledger.profile, task: id)
        do { try RemoteZipStore.save(plan, in: dir) } catch { fail(id, "The download could not be prepared.", retryable: false, dir: dir); return id }
        ledger.update(id) { $0.transfer.resumeAvailable = true; $0.transfer.totalBytes = nil }
        ledger.saveResumeData(id, Self.sentinel)
        run(id, plan: plan, dir: dir, destination: started.destination, origin: origin == .user ? .user : .page)
        return id
    }

    private func run(_ id: UUID, plan: RemoteZipPlan, dir: URL, destination: URL, origin: DownloadRequestOrigin) {
        runs[id]?.cancel()
        let files = plan.items.filter { !$0.isDirectory }
        progress[id] = (0, files.count)
        let setup = network
        runs[id] = Task { [weak self] in
            do {
                let fetcher = try MediaFetcher(policy: HTTPRequestPolicy(origin: origin), network: setup, maxSegmentBytes: Int64(ZipFormat.maxEntrySize))
                defer { fetcher.invalidate() }
                guard let url = URL(string: plan.url) else { throw RemoteZipError.unusable("The archive's address is not usable.") }
                let extractor = ZipExtractor(fetcher: fetcher, plan: plan, url: url, dir: dir, taskID: id)
                extractor.onProgress = { done in Task { @MainActor [weak self] in
                    guard let self, self.runs[id] != nil else { return }
                    self.progress[id] = (done, files.count)
                    let fraction = files.isEmpty ? 0.9 : min(0.95, Double(done) / Double(files.count) * 0.95)
                    self.coordinator.update(id, fraction: fraction)
                    self.ledger.update(id) { $0.engineMetadata["zipDone"] = String(done) }
                } }
                try await extractor.run()
                try Task.checkCancellation()
                await self?.finalize(id, plan: plan, dir: dir, destination: destination)
            } catch is CancellationError { return }
            catch { await self?.failed(id, error: error, dir: dir) }
        }
    }

    // MARK: Finishing

    private func finalize(_ id: UUID, plan: RemoteZipPlan, dir: URL, destination: URL) async {
        guard runs[id] != nil, !finishing.contains(id) else { return }
        finishing.insert(id); defer { finishing.remove(id) }
        let tree = dir.appendingPathComponent("tree", isDirectory: true)
        guard DownloadPathPolicy.isAuthorized(destination.path, roots: coordinator.managedRoots) else { fail(id, "This download's folder is outside the download folder, so nothing was moved.", retryable: false, dir: dir); return }
        // The folder is named after the archive; if that name is taken, another is used. An existing folder or file is never merged into or replaced.
        let folder = DownloadCoordinator.uniqueURL(in: destination.deletingLastPathComponent(), name: destination.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: tree, to: folder)
        } catch { fail(id, "The files could not be put in place.", retryable: false, dir: dir); return }
        // Marked as from the internet, like a browser's own downloads.
        let origin = HTTPRequestPolicy.origin(of: URL(string: plan.url) ?? folder)
        await Task.detached(priority: .utility) {
            if let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) {
                for case let f as URL in walker where (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { DownloadQuarantine.apply(to: f, sourceOrigin: origin) }
            }
        }.value
        coordinator.updateDestination(id, to: folder)
        ledger.update(id) { $0.transfer.resumeAvailable = false }
        runs[id] = nil; progress[id] = nil
        RemoteZipStore.remove(dir)
        // Every file was checked against its CRC-32 from the archive's own table, and its size; that is what `verified` means here.
        coordinator.finish(id, source: nil, integrity: .verified)
    }

    private func failed(_ id: UUID, error: Error, dir: URL) {
        guard runs[id] != nil else { return }
        let (reason, retryable): (String, Bool)
        if let z = error as? RemoteZipError { (reason, retryable) = (z.errorDescription ?? "The archive could not be read.", z == .changed ? false : false) }
        else if let e = error as? ZipExtractor.EntryFailure { (reason, retryable) = (e.reason, false) }
        else if error is MediaFetcher.Changed { (reason, retryable) = (RemoteZipError.changed.errorDescription ?? "", false) }
        else { let info = HTTPResponseRules.failure(for: error).info; (reason, retryable) = (info.reason, info.retryable) }
        fail(id, reason, retryable: retryable, dir: dir)
    }

    private func fail(_ id: UUID, _ reason: String, retryable: Bool, dir: URL) {
        runs[id]?.cancel(); runs[id] = nil; progress[id] = nil
        if !retryable { RemoteZipStore.remove(dir) }
        coordinator.fail(id, source: ledger.record(id)?.source.asURL, error: HTTPDownloadError(info: DownloadFailureInfo(code: "remoteZip:failed", reason: reason, retryable: retryable)), willRetry: false)
    }

    // MARK: Pause, resume, cancel, retry

    func pause(_ id: UUID, done: @escaping (Data?) -> Void) {
        guard !finishing.contains(id), let run = runs[id] else { done(nil); return }
        runs[id] = nil; progress[id] = nil
        run.cancel()
        Task { await run.value; done(Self.sentinel) }
    }

    func cancel(_ id: UUID) {
        runs[id]?.cancel(); runs[id] = nil; progress[id] = nil
        RemoteZipStore.remove(RemoteZipStore.folder(profile: ledger.profile, task: id))
    }

    /// Carries on from the entries already taken (each was checked when it was written).
    func resume(_ id: UUID) {
        let dir = RemoteZipStore.folder(profile: ledger.profile, task: id)
        guard let record = ledger.record(id), let dest = record.file.destinationPath, DownloadPathPolicy.isAuthorized(dest, roots: coordinator.managedRoots), let plan = RemoteZipStore.load(from: dir) else {
            fail(id, "The saved details of this download are missing.", retryable: false, dir: dir); return
        }
        ledger.apply(.resumed, to: id)
        run(id, plan: plan, dir: dir, destination: URL(fileURLWithPath: dest), origin: DownloadRequestOrigin(rawValue: record.engineMetadata["origin"] ?? "") ?? .page)
    }

    func restart(_ id: UUID) {
        guard let record = ledger.record(id), let source = record.source.asURL else { return }
        let dir = RemoteZipStore.folder(profile: ledger.profile, task: id)
        guard runs[id] == nil, let plan = RemoteZipStore.load(from: dir) else { coordinator.note("Could not retry \(record.file.filename): its saved details are gone, so add it again"); return }
        let origin = DownloadRequestOrigin(rawValue: record.engineMetadata["origin"] ?? "") ?? .page
        Task { @MainActor in
            coordinator.reserveTaskID(id, for: source)
            let ticket = await coordinator.admitTicket(filename: record.file.filename, source: source, protocolID: .remoteZip)
            guard ticket.admitted else { return }
            let started = coordinator.begin(suggestedName: record.file.filename, sourceHost: source.host, sourceURL: source, isPrivate: false, taskID: id, protocolID: .remoteZip,
                                            cancel: { [weak self] in self?.cancel(id) }, suspend: { [weak self] done in self?.pause(id, done: done) })
            ledger.update(id) { $0.transfer.resumeAvailable = true }
            ledger.saveResumeData(id, Self.sentinel)
            run(id, plan: plan, dir: dir, destination: started.destination, origin: origin)
        }
    }
}

/// Fetches and unpacks the chosen entries one at a time into `tree/` inside the task's folder. An entry is in `tree/` only whole, with its size and CRC-32 checked; `done/` holds a
/// marker for each, so a restart skips what is finished.
final class ZipExtractor: @unchecked Sendable {
    struct EntryFailure: Error { var reason: String }
    let fetcher: MediaFetcher, plan: RemoteZipPlan, url: URL, dir: URL, taskID: UUID
    var onProgress: (@Sendable (Int) -> Void)?
    static let minimumFreeSpace: Int64 = 200 * 1024 * 1024

    init(fetcher: MediaFetcher, plan: RemoteZipPlan, url: URL, dir: URL, taskID: UUID) { self.fetcher = fetcher; self.plan = plan; self.url = url; self.dir = dir; self.taskID = taskID }

    private var tree: URL { dir.appendingPathComponent("tree", isDirectory: true) }
    private var marks: URL { dir.appendingPathComponent("done", isDirectory: true) }
    private func mark(_ id: Int) -> URL { marks.appendingPathComponent("\(id)") }

    /// Where an entry goes, inside `tree`, with every part cleaned again here (the plan is read from disk and is not trusted any more than a table from the network).
    private func destination(_ path: [String]) throws -> URL {
        guard !path.isEmpty, path.count <= ZipFormat.maxDepth, path.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.utf8.contains(0x2F) && !$0.utf8.contains(0) }) else { throw EntryFailure(reason: "An entry has an unsafe name.") }
        var u = tree
        for part in path { u = u.appendingPathComponent(part) }
        let base = tree.standardizedFileURL.resolvingSymlinksInPath().path
        guard u.standardizedFileURL.path.hasPrefix(tree.standardizedFileURL.path + "/") else { throw EntryFailure(reason: "An entry would be written outside its folder.") }
        // Whatever part of the path already exists must really be inside the folder once links are followed: a link planted there must not carry a file out.
        var existing = u.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: existing.path), existing.path.count > base.count { existing = existing.deletingLastPathComponent() }
        let real = existing.resolvingSymlinksInPath().path
        guard real == base || real.hasPrefix(base + "/") else { throw EntryFailure(reason: "An entry would be written outside its folder.") }
        if let values = try? u.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true { throw EntryFailure(reason: "An entry would be written through a link.") }
        return u
    }

    func run() async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: tree, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: marks, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let files = plan.items.filter { !$0.isDirectory }
        var done = files.filter { fm.fileExists(atPath: mark($0.id).path) }.count
        onProgress?(done)
        for item in plan.items where item.isDirectory { try fm.createDirectory(at: try destination(item.path), withIntermediateDirectories: true) }
        for item in files where !fm.fileExists(atPath: mark(item.id).path) {
            try Task.checkCancellation()
            await RemoteZipRunner.beforeEntry?(item.id)
            try Task.checkCancellation()
            if let free = DiskSpace.available(at: dir), free < Self.minimumFreeSpace + Int64(clamping: item.uncompressedSize + item.compressedSize) {
                throw HTTPDownloadError(info: DownloadFailureInfo(code: "remoteZip:disk", reason: "There is not enough free space to take this file out of the archive.", retryable: true))
            }
            try await take(item)
            done += 1
            onProgress?(done)
        }
    }

    /// One entry: its header, its compressed bytes, its content.
    private func take(_ item: RemoteZipPlan.Item) async throws {
        // The plan was read from disk: its numbers are checked before they are used as positions or sizes.
        guard item.localHeaderOffset < 1 << 62, item.compressedSize <= ZipFormat.maxEntrySize, item.uncompressedSize <= ZipFormat.maxEntrySize, plan.centralOffset < 1 << 62 else { throw EntryFailure(reason: "The saved details of this download are not valid.") }
        let host = url.host ?? ""
        while !ConnectionBudget.shared.acquire(host: host, task: taskID) { try Task.checkCancellation(); try await Task.sleep(nanoseconds: 250_000_000) }
        defer { ConnectionBudget.shared.release(host: host, task: taskID) }
        let v = plan.validators
        let target = try destination(item.path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try destination(item.path)            // again, now that the folders exist
        // 1. The entry's own header, to learn where its data really starts (its name and extra data may be of any length).
        let headerBytes: Data
        do {
            let got = try await fetcher.rangeData(url, offset: Int64(item.localHeaderOffset), length: 30, expect: v)
            if let size = got.total, size != plan.total { throw RemoteZipError.changed }          // the archive is no longer the length it was
            headerBytes = got.data
        } catch is MediaFetcher.Changed { throw RemoteZipError.changed }
        var entry = ZipEntry(id: item.id, name: "", path: item.path, isDirectory: false, method: item.method, flags: 0, crc: item.crc, compressedSize: item.compressedSize, uncompressedSize: item.uncompressedSize,
                             localHeaderOffset: item.localHeaderOffset, nameLength: item.nameLength, status: .supported)
        entry.flags = 0
        let start: UInt64
        do { start = try ZipFormat.dataStart(localHeader: headerBytes, entry: entry) } catch let e as ZipError { throw EntryFailure(reason: e.errorDescription ?? "An entry's header is not valid.") }
        guard start <= plan.centralOffset, item.compressedSize <= plan.centralOffset - start else { throw EntryFailure(reason: "An entry's data is outside the archive's data.") }
        // 2. Its compressed bytes, exactly.
        var written: Int64 = 0
        // Staged outside the folder being built, under a name that cannot be an entry's: an entry called "a.part" is not touched while "a" is made.
        let partial = dir.appendingPathComponent("e\(item.id).out")
        try? FileManager.default.removeItem(at: partial)
        FileManager.default.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o600])
        if item.compressedSize > 0 {
            let compressed = dir.appendingPathComponent("e\(item.id).data")
            defer { try? FileManager.default.removeItem(at: compressed) }
            do { _ = try await fetcher.segment(MediaSegment(url: url.absoluteString, offset: Int64(start), length: Int64(item.compressedSize), duration: 0), to: compressed, expect: v) }
            catch is MediaFetcher.Changed { throw RemoteZipError.changed }
            // 3. Its content, checked as it is made.
            written = try Self.unpack(from: compressed, method: item.method, to: partial, expectedSize: item.uncompressedSize, expectedCRC: item.crc)
        } else if item.uncompressedSize != 0 || item.crc != 0 {
            throw EntryFailure(reason: "An entry is empty but says otherwise.")
        }
        _ = written
        // An entry is never made over another: a folder, or a different file, in the way is a failure (the names were checked for sameness when the table was read).
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue { throw EntryFailure(reason: "A file in the archive has the same name as a folder, so it was not kept.") }
            try FileManager.default.removeItem(at: target)          // only a file this task wrote before a pause: it is made again
        }
        try FileManager.default.moveItem(at: partial, to: target)
        FileManager.default.createFile(atPath: mark(item.id).path, contents: nil)
    }

    /// Streams the data through the decompressor into `output`, stopping the moment it would pass the size the archive declared (a small entry cannot fill a disk), and requires the exact
    /// size and the CRC-32. Throws, leaving no output, when anything is off.
    static func unpack(from input: URL, method: UInt16, to output: URL, expectedSize: UInt64, expectedCRC: UInt32, cancelled: () -> Bool = { false }) throws -> Int64 {
        guard let reader = try? FileHandle(forReadingFrom: input), let writer = try? FileHandle(forWritingTo: output) else { throw EntryFailure(reason: "A file could not be opened.") }
        defer { try? reader.close(); try? writer.close() }
        var crc: UInt32 = 0
        var total: UInt64 = 0
        func emit(_ bytes: UnsafeRawBufferPointer) throws {
            guard bytes.count > 0 else { return }
            total += UInt64(bytes.count)
            guard total <= expectedSize else { throw EntryFailure(reason: "A file in the archive is larger than it says, so it was not kept.") }
            crc = ZipFormat.crc32(update: crc, bytes)
            try writer.write(contentsOf: Data(bytes))
        }
        if method == 0 {
            while let chunk = try reader.read(upToCount: 1 << 16), !chunk.isEmpty { try Task.checkCancellation(); if cancelled() { throw CancellationError() }; try chunk.withUnsafeBytes { try emit($0) } }
        } else {
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: 1 << 16), src = UnsafeMutablePointer<UInt8>.allocate(capacity: 1 << 16)
            defer { dst.deallocate(); src.deallocate() }
            var stream = compression_stream(dst_ptr: dst, dst_size: 0, src_ptr: UnsafePointer(src), src_size: 0, state: nil)
            guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { throw EntryFailure(reason: "The decompressor could not start.") }
            defer { compression_stream_destroy(&stream) }
            var ended = false, finalFed = false
            while !ended {
                try Task.checkCancellation(); if cancelled() { throw CancellationError() }
                if stream.src_size == 0, !finalFed {
                    let chunk = try reader.read(upToCount: 1 << 16) ?? Data()
                    if chunk.isEmpty { finalFed = true } else { chunk.copyBytes(to: src, count: chunk.count); stream.src_ptr = UnsafePointer(src); stream.src_size = chunk.count }
                }
                stream.dst_ptr = dst; stream.dst_size = 1 << 16
                let status = compression_stream_process(&stream, finalFed ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                let produced = (1 << 16) - stream.dst_size
                try emit(UnsafeRawBufferPointer(start: dst, count: produced))
                switch status {
                case COMPRESSION_STATUS_END: ended = true
                case COMPRESSION_STATUS_OK: if finalFed, produced == 0, stream.src_size == 0 { throw EntryFailure(reason: "A file in the archive is cut short or damaged, so it was not kept.") }
                default: throw EntryFailure(reason: "A file in the archive is damaged, so it was not kept.")
                }
            }
        }
        guard total == expectedSize else { throw EntryFailure(reason: "A file in the archive is smaller than it says, so it was not kept.") }
        guard crc == expectedCRC else { throw EntryFailure(reason: "A file in the archive does not match its checksum, so it was not kept.") }
        return Int64(total)
    }
}
