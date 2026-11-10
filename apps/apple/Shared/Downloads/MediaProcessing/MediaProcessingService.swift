import Foundation
import AVFoundation
import Combine

// Local media jobs: a queue of at most a few conversions at a time, each working in a folder of its own and putting only a checked result into place.
//
// These are not network transfers and do not appear as downloads: they have their own small list. They share what is shared with downloads (the unique-name rule, the quarantine
// mark, `FinalizationGate`, the authorised-folder rule), and they never touch the network. The source file is only read.
//
// A job's working folder is `<staging root>/<profile>/<job>/` and holds `job.json` (non-secret: the operation and two paths) while it runs. A folder left behind by a crash is
// found at launch, its half-written output is deleted, and the job is listed as "recovery required": it is started again from the beginning only if the person asks, because an
// export cannot continue from the middle. Private jobs write their working files in the system's temporary folder, keep no journal, and are forgotten with the session.

struct MediaJob: Identifiable, Equatable {
    enum State: Equatable {
        case waiting, inspecting, ready, processing, cancelling, completed, cancelled
        case failed(String)
        case recoveryRequired(String)
        var isFinal: Bool { switch self { case .completed, .cancelled, .failed, .recoveryRequired: true; default: false } }
        var isActive: Bool { switch self { case .inspecting, .ready, .processing, .cancelling: true; default: false } }
        var title: String {
            switch self {
            case .waiting: "Waiting"; case .inspecting: "Checking"; case .ready: "Ready"; case .processing: "Working"; case .cancelling: "Cancelling"
            case .completed: "Done"; case .cancelled: "Cancelled"; case .failed(let why): "Failed: \(why)"; case .recoveryRequired(let why): "Needs a restart: \(why)"
            }
        }
    }
    let id: UUID
    var source: URL
    var operation: MediaOperation
    var state: State = .waiting
    var progress: Double = 0
    var profileTag: String
    var isPrivate: Bool
    var destinationFolder: URL
    var output: URL?
    /// Set only when the output was read back and its tracks are the source's, copied.
    var lossless: Bool?
    var note: String?
    var packageID: UUID?
    var audioTracks: Set<Int32>?
}

private struct MediaJobJournal: Codable {
    var id: UUID
    var source: String
    var destination: String
    var operation: MediaOperation
    var profileTag: String
}

@MainActor
final class MediaProcessingService: ObservableObject {
    static let maxConcurrentDefault = 2
    static let maxJobsListed = 200

    @Published private(set) var jobs: [MediaJob] = []
    let stagingRoot: URL
    let authorizedRoots: [URL]
    let maxConcurrent: Int
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var gates: [UUID: FinalizationGate] = [:]
    var onNote: ((String) -> Void)?
    /// Test hooks: something run just before the work of a job starts, and a replacement for the free-space reading.
    nonisolated(unsafe) static var beforeRun: (@Sendable (UUID, URL) async -> Void)?
    nonisolated(unsafe) static var freeSpaceOverride: (@Sendable () -> Int64?)?

    init(stagingRoot: URL, authorizedRoots: [URL], maxConcurrent: Int = MediaProcessingService.maxConcurrentDefault) {
        self.stagingRoot = stagingRoot
        self.authorizedRoots = authorizedRoots
        self.maxConcurrent = max(1, min(maxConcurrent, 4))
    }

    static func defaultStagingRoot() -> URL { DownloadCoordinator.directory.appendingPathComponent(".Browser Setu Media Processing", isDirectory: true) }

    func job(_ id: UUID) -> MediaJob? { jobs.first { $0.id == id } }
    var runningCount: Int { jobs.filter { $0.state.isActive }.count }

    // MARK: Submitting

    /// Queues one job. Nothing is read until it is its turn.
    @discardableResult
    func submit(source: URL, operation: MediaOperation, destination: URL? = nil, profileTag: String, isPrivate: Bool, packageID: UUID? = nil, audioTracks: Set<Int32>? = nil) -> UUID {
        let folder = destination ?? source.deletingLastPathComponent()
        let job = MediaJob(id: UUID(), source: source, operation: operation, profileTag: profileTag, isPrivate: isPrivate, destinationFolder: folder, packageID: packageID, audioTracks: audioTracks)
        jobs.append(job)
        trimList()
        pump()
        return job.id
    }

    /// The same operation on several files, each its own independent job.
    @discardableResult
    func submit(sources: [URL], operation: MediaOperation, destination: URL? = nil, profileTag: String, isPrivate: Bool, packageID: UUID? = nil) -> [UUID] {
        sources.map { submit(source: $0, operation: operation, destination: destination, profileTag: profileTag, isPrivate: isPrivate, packageID: packageID) }
    }

    func cancel(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        switch jobs[i].state {
        case .waiting: jobs[i].state = .cancelled
        case .inspecting, .ready, .processing:
            // Past the point of no return (the file is being put in place) the job completes; the gate says which.
            if gates[id]?.cancel() == false { return }
            jobs[i].state = .cancelling
            tasks[id]?.cancel()
        default: break
        }
    }

    func cancelAll() { for j in jobs where !j.state.isFinal { cancel(j.id) } }

    /// Starts a failed, cancelled or interrupted job again from the beginning.
    func retry(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].state.isFinal, jobs[i].state != .completed else { return }
        jobs[i].state = .waiting; jobs[i].progress = 0; jobs[i].output = nil; jobs[i].note = nil
        pump()
    }

    func dismiss(_ id: UUID) { if let j = job(id), j.state.isFinal { jobs.removeAll { $0.id == id } } }

    private func trimList() {
        while jobs.count > Self.maxJobsListed, let i = jobs.firstIndex(where: { $0.state.isFinal }) { jobs.remove(at: i) }
    }

    /// Forgets the private jobs of a session that has ended.
    func forgetPrivateJobs() { cancelAllPrivate(); jobs.removeAll { $0.isPrivate && $0.state.isFinal }; if !jobs.contains(where: { $0.isPrivate }) { Self.sweepPrivateTemporaries() } }
    /// Whatever private work a crash left in the temporary folder, and the links made to read private files.
    static func sweepPrivateTemporaries() {
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("BrowserSetuMediaPrivate", isDirectory: true))
        MediaAlias.sweep()
    }
    private func cancelAllPrivate() { for j in jobs where j.isPrivate && !j.state.isFinal { cancel(j.id) } }

    // MARK: Queue

    private func pump() {
        while runningCount < maxConcurrent, let i = jobs.firstIndex(where: { $0.state == .waiting }) {
            let id = jobs[i].id
            jobs[i].state = .inspecting
            gates[id] = FinalizationGate()
            tasks[id] = Task { [weak self] in await self?.execute(id) }
        }
    }

    private func update(_ id: UUID, _ change: (inout MediaJob) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[i])
    }

    private func finish(_ id: UUID, _ state: MediaJob.State) {
        update(id) { $0.state = state; if state == .completed { $0.progress = 1 } }
        tasks[id] = nil; gates[id] = nil
        pump()
    }

    // MARK: Staging

    private func workFolder(for job: MediaJob) -> URL {
        let root = job.isPrivate ? FileManager.default.temporaryDirectory.appendingPathComponent("BrowserSetuMediaPrivate", isDirectory: true) : stagingRoot
        return root.appendingPathComponent(DownloadFilename.sanitize(job.profileTag) ?? "profile", isDirectory: true).appendingPathComponent(job.id.uuidString, isDirectory: true)
    }

    /// Only a folder this service made is ever deleted: it lies under the staging root (or the private temporary root) and is named by a job id.
    private func removeWorkFolder(_ folder: URL) {
        let name = folder.lastPathComponent
        guard UUID(uuidString: name) != nil else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Authorisation

    /// A file or folder may be used when its real location (links followed) is inside an authorised root.
    func isAuthorized(_ url: URL) -> Bool {
        DownloadPathPolicy.isAuthorized(url.path, roots: authorizedRoots)
    }

    // MARK: Running a job

    private func execute(_ id: UUID) async {
        guard let job = job(id) else { return }
        let work = workFolder(for: job)
        defer { removeWorkFolder(work) }
        do {
            try Task.checkCancellation()
            guard isAuthorized(job.source), isAuthorized(job.destinationFolder) else { throw MediaProcessError.notAuthorized }
            let values = try? job.source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { throw MediaProcessError.invalid("The file is not there, or is not a plain file.") }
            let sourceSize = Int64(values?.fileSize ?? 0)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let staged = work.appendingPathComponent("out.\(job.operation.outputExtension)")
            try checkDisk(needed: sourceSize + 64 * 1024 * 1024, folder: work)
            if !job.isPrivate {
                let journal = MediaJobJournal(id: id, source: job.source.path, destination: job.destinationFolder.path, operation: job.operation, profileTag: job.profileTag)
                try? JSONEncoder().encode(journal).write(to: work.appendingPathComponent("job.json"), options: .atomic)
            }
            if let hook = Self.beforeRun { await hook(id, work) }
            try Task.checkCancellation()
            var lossless: Bool?
            var note: String?
            var languageForName: String?
            switch job.operation {
            case .convertSubtitleFile(let offset):
                update(id) { if $0.state != .cancelling { $0.state = .processing } }
                let source = job.source
                try await Task.detached(priority: .utility) {
                    let handle = try FileHandle(forReadingFrom: source)
                    defer { try? handle.close() }
                    let data = try handle.read(upToCount: SubtitleText.maxBytes + 1) ?? Data()
                    guard data.count <= SubtitleText.maxBytes else { throw SubtitleError.tooLarge }
                    let cues = try SubtitleText.parse(try SubtitleText.decode(data), offset: offset)
                    try Data(SubtitleText.webVTT(cues).utf8).write(to: staged, options: .atomic)
                }.value
            case .extractSubtitles(let trackID):
                update(id) { if $0.state != .cancelling { $0.state = .processing } }
                let facts = try await MediaFactsReader.read(job.source)
                let candidates = facts.subtitles.filter { trackID == nil || $0.id == trackID }
                guard !candidates.isEmpty else { throw MediaProcessError.unsupported("This file has no subtitle track" + (trackID == nil ? "." : " with that number.")) }
                var lastError: Error = SubtitleError.noCues
                var found: (cues: [SubtitleCue], language: String?)?
                for track in candidates {
                    do { found = try await SubtitleText.cues(fromTrack: track.id, of: job.source); break } catch let e as CancellationError { throw e } catch { lastError = error }
                }
                guard let found else { throw lastError }
                languageForName = found.language
                try Data(SubtitleText.webVTT(found.cues, language: found.language).utf8).write(to: staged, options: .atomic)
            default:
                let facts = try await MediaFactsReader.read(job.source)
                let plan = try await MediaProcessor.plan(job.operation, facts: facts, audioTracks: job.audioTracks)
                update(id) { if $0.state != .cancelling { $0.state = .ready } }
                try Task.checkCancellation()
                update(id) { if $0.state != .cancelling { $0.state = .processing } }
                let progressSink: @Sendable (Double) -> Void = { [weak self] p in Task { @MainActor in self?.update(id) { if $0.state == .processing { $0.progress = min(0.99, max($0.progress, p)) } } } }
                try await MediaProcessor.run(job.operation, plan: plan, source: job.source, staged: staged, progress: progressSink)
                try Task.checkCancellation()
                var expected: Double?
                var tolerance = max(0.5, (facts.durationSeconds ?? 0) * 0.02)
                if case .trim(let s, let e, let mode, _) = job.operation {
                    let end = min(e, facts.durationSeconds ?? e)
                    expected = end - s
                    // A fast cut may begin at an earlier keyframe, so the result can be longer (never shorter) by up to a keyframe interval.
                    tolerance = mode == .fast ? max(10, expected ?? 0) : 0.75
                } else if plan.preset != "wav" {
                    let carried = (facts.video + facts.audio).filter { plan.videoTrackIDs.contains($0.id) || plan.audioTrackIDs.contains($0.id) }.compactMap(\.durationSeconds)
                    expected = carried.max() ?? facts.durationSeconds
                }
                let result = try await MediaProcessor.verify(output: staged, plan: plan, expectedDuration: expected, sourceFacts: facts, tolerance: tolerance)
                lossless = plan.passthrough ? result.lossless : false
                note = plan.droppedNote
            }
            try Task.checkCancellation()
            let finalURL = try await place(staged: staged, job: job, language: languageForName)
            update(id) { $0.output = finalURL; $0.lossless = lossless; $0.note = note }
            finish(id, .completed)
        } catch is CancellationError {
            finish(id, .cancelled)
        } catch let e as MediaProcessError where e == .cancelled {
            finish(id, .cancelled)
        } catch {
            finish(id, .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
        }
    }

    private func readBounded(_ url: URL, limit: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw SubtitleError.tooLarge }
        return data
    }

    private func checkDisk(needed: Int64, folder: URL) throws {
        let free = Self.freeSpaceOverride?() ?? DiskSpace.available(at: folder)
        if let free, !DiskSpace.fits(needed: needed, available: free, divisor: 0) { throw MediaProcessError.diskSpace(needed: needed, available: free) }
    }

    // MARK: Putting the result in place

    /// Reserves a free name atomically (so two jobs never pick the same one), moves the checked file onto it, and copies the source's quarantine mark. The source is never touched.
    private func place(staged: URL, job: MediaJob, language: String?) async throws -> URL {
        guard let gate = gates[job.id], gate.claim() else { throw CancellationError() }
        guard isAuthorized(job.destinationFolder) else { throw MediaProcessError.notAuthorized }
        let stem = job.source.deletingPathExtension().lastPathComponent
        let name: String
        switch job.operation {
        case .extractSubtitles, .convertSubtitleFile: name = SubtitleText.fileName(base: stem, language: language)
        default: name = (DownloadFilename.sanitize(stem + " " + job.operation.nameSuffix) ?? "media") + "." + job.operation.outputExtension
        }
        var target = DownloadCoordinator.uniqueURL(in: job.destinationFolder, name: name)
        var reserved = false
        for _ in 0..<50 {
            let fd = open(target.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o644)
            if fd >= 0 { close(fd); reserved = true; break }
            target = DownloadCoordinator.uniqueURL(in: job.destinationFolder, name: name, avoiding: [target])
        }
        guard reserved else { throw MediaProcessError.failed("a free name could not be found") }
        do {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: staged)
        } catch {
            if (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int) == 0 { try? FileManager.default.removeItem(at: target) }
            throw MediaProcessError.failed("the result could not be put in the folder (\(error.localizedDescription))")
        }
        copyQuarantine(from: job.source, to: target)
        return target
    }

    private func copyQuarantine(from source: URL, to target: URL) {
        let size = getxattr(source.path, "com.apple.quarantine", nil, 0, 0, 0)
        guard size > 0 else { return }
        var value = [UInt8](repeating: 0, count: size)
        guard getxattr(source.path, "com.apple.quarantine", &value, size, 0, 0) == size else { return }
        setxattr(target.path, "com.apple.quarantine", value, value.count, 0, 0)
    }

    // MARK: After a crash

    /// Lists the jobs a crash or quit interrupted (from their journals), deletes their half-written output, and leaves each as "recovery required". Nothing is started.
    @discardableResult
    func recoverInterrupted() -> Int {
        let fm = FileManager.default
        guard let profiles = try? fm.contentsOfDirectory(at: stagingRoot, includingPropertiesForKeys: nil) else { return 0 }
        var found = 0
        for profile in profiles {
            guard let folders = try? fm.contentsOfDirectory(at: profile, includingPropertiesForKeys: nil) else { continue }
            for folder in folders where UUID(uuidString: folder.lastPathComponent) != nil {
                if jobs.contains(where: { $0.id.uuidString == folder.lastPathComponent && !$0.state.isFinal }) { continue }      // a job that is running now
                defer { removeWorkFolder(folder) }
                guard
                      let data = try? Data(contentsOf: folder.appendingPathComponent("job.json")), data.count < 64 * 1024,
                      let journal = try? JSONDecoder().decode(MediaJobJournal.self, from: data) else { continue }
                var job = MediaJob(id: journal.id, source: URL(fileURLWithPath: journal.source), operation: journal.operation, profileTag: journal.profileTag, isPrivate: false,
                                   destinationFolder: URL(fileURLWithPath: journal.destination))
                job.state = .recoveryRequired("it was interrupted")
                jobs.append(job); found += 1
            }
        }
        return found
    }
}
