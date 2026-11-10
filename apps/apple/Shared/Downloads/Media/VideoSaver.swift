import Foundation

// One "save this video" request from the Download sheet: the original through the existing download engine, then (for audio) a local conversion of the finished file. It adds no transfer
// code of its own: the download is an ordinary task in the coordinator and ledger (so it shows in Downloads, resumes and cancels like any), and the conversion is the existing local
// media processing service (M4A) or the bundled MP3 encoder.

@MainActor
final class VideoSaveOperation: ObservableObject, Identifiable {
    enum Output: Hashable, Sendable { case original, m4a, mp3(kbps: Int)
        var isAudio: Bool { self != .original }
        var title: String { switch self { case .original: "Original"; case .m4a: "M4A audio"; case .mp3(let k): "MP3 audio (\(k) kbit/s)" } }
    }
    enum Stage: Equatable { case waiting, downloading(Double), converting(Double), done(URL), failed(String), cancelled
        var isFinal: Bool { switch self { case .done, .failed, .cancelled: true; default: false } }
    }

    let id = UUID()
    let url: URL
    let name: String
    let output: Output
    /// Keep the downloaded video after the audio has been made from it.
    let keepOriginal: Bool
    let isPrivate: Bool
    /// The file's real container (from the source description) for an address whose own ending says nothing (`/play.php`, no ending): the saved name still ends in the right extension.
    var endingHint: String?
    @Published private(set) var stage = Stage.waiting
    private(set) var downloadID: UUID?
    private var task: Task<Void, Never>?
    private var jobID: UUID?
    private let coordinator: DownloadCoordinator
    private let processing: MediaProcessingService
    private let profileTag: String
    private let origin: DownloadRequestOrigin

    init(url: URL, name: String, output: Output, keepOriginal: Bool, isPrivate: Bool, coordinator: DownloadCoordinator, processing: MediaProcessingService? = nil, profileTag: String, origin: DownloadRequestOrigin = .page) {
        self.origin = origin; self.url = url; self.name = name; self.output = output; self.keepOriginal = keepOriginal; self.isPrivate = isPrivate
        self.coordinator = coordinator; self.processing = processing ?? MediaProcessingHub.shared; self.profileTag = profileTag
    }

    /// Endings that are added to a typed name (a page-generated ending such as .php is never forced onto a file name).
    static let mediaEndings: Set<String> = ResourceClassifier.video.union(ResourceClassifier.audio).subtracting(["m3u8", "mpd"])

    func start() {
        guard task == nil else { return }          // a second click starts nothing
        // The name the person typed keeps the file's own ending (a download called "My clip" must still be "My clip.mp4": a player, and the audio conversion, decide by it).
        var safeName = DownloadFilename.sanitize(name)
        var ending = url.pathExtension.lowercased()
        if !Self.mediaEndings.contains(ending), let hint = endingHint?.lowercased(), Self.mediaEndings.contains(hint) { ending = hint }
        // The ending is the file's real one, put on by the one resolver (a different media ending on the typed name is replaced, never doubled; a dot inside a title stays).
        if let n = safeName, !n.isEmpty, Self.mediaEndings.contains(ending) { safeName = DownloadFilename.truncated(FilenameResolver.applying(extension: ending, to: n)) }
        guard let id = coordinator.scheduleDownload(url: url, at: Date(), filename: safeName.flatMap { $0.isEmpty ? nil : $0 }, origin: origin, isPrivate: isPrivate) else {
            stage = .failed("That address could not be added to Downloads."); return
        }
        downloadID = id
        stage = .downloading(0)
        task = Task { [weak self] in await self?.run(id) }
    }

    func cancel() {
        task?.cancel()
        if let id = downloadID, let r = coordinator.ledger.record(id), !r.state.isFinal { coordinator.cancel(id) }
        if let j = jobID, case .converting = stage { processing.cancel(j); return }          // the job says when it has really stopped
        if !stage.isFinal { stage = .cancelled }
    }

    private func run(_ id: UUID) async {
        // 1. The download, watched in the ledger.
        while !Task.isCancelled {
            guard let r = coordinator.ledger.record(id) else { stage = .failed("The download was removed."); return }
            switch r.state {
            case .completed: break
            case .failed, .recoveryRequired: stage = .failed(r.failure?.reason ?? "The download failed."); return
            case .cancelled: stage = .cancelled; return
            case .paused, .scheduled, .queued:
                stage = .waiting; try? await Task.sleep(nanoseconds: 600_000_000); continue
            default:
                let total = r.transfer.totalBytes ?? 0
                stage = .downloading(total > 0 ? min(1, Double(r.transfer.completedBytes) / Double(total)) : 0)
                try? await Task.sleep(nanoseconds: 400_000_000); continue
            }
            break
        }
        guard !Task.isCancelled, let record = coordinator.ledger.record(id), let path = record.file.destinationPath else { if !stage.isFinal { stage = .cancelled }; return }
        let file = URL(fileURLWithPath: path)
        guard output.isAudio else { stage = .done(file); return }

        // 2. The conversion, on the finished file.
        stage = .converting(0)
        let base = file.deletingPathExtension()
        do {
            switch output {
            case .m4a:
                let job = processing.submit(source: file, operation: .extractAudio(.m4a, trackID: nil), profileTag: profileTag, isPrivate: isPrivate)
                jobID = job
                while !Task.isCancelled {
                    guard let j = processing.job(job) else { stage = .failed("The conversion finished or was cleared from the list; look in your Downloads folder for the audio file."); return }
                    switch j.state {
                    case .completed:
                        guard let out = j.output else { throw MP3Encoder.Failure.invalidResult("no file was made") }
                        finishAudio(out, original: file, recordID: id); return
                    case .failed(let why), .recoveryRequired(let why): stage = .failed(why); return
                    case .cancelled: stage = .cancelled; return
                    default: stage = .converting(j.progress); try? await Task.sleep(nanoseconds: 300_000_000)
                    }
                }
            case .mp3(let kbps):
                let target = Self.unique(base.appendingPathExtension("mp3"))
                try await MP3Encoder.encode(source: file, to: target, kbps: kbps) { p in Task { @MainActor [weak self] in if case .converting = self?.stage { self?.stage = .converting(p) } } }
                finishAudio(target, original: file, recordID: id); return
            case .original: break
            }
        } catch is CancellationError { stage = .cancelled; return }
        catch { stage = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription); return }
        if !stage.isFinal { stage = .cancelled }
    }

    /// The audio file stands. The downloaded video is removed only if asked for, only if it is still the file this request downloaded (same place, nothing else wrote there since), and by
    /// a recoverable move to the Trash (deleted outright for a private download, which must leave no trace). A failure is said, not swallowed.
    private func finishAudio(_ audio: URL, original: URL, recordID: UUID) {
        var note: String?
        if !keepOriginal, original != audio {
            let stillThere = coordinator.ledger.record(recordID)?.file.destinationPath == original.path && FileManager.default.fileExists(atPath: original.path)
            if !stillThere { note = "The downloaded video was moved or renamed meanwhile, so it was left alone." }
            else {
                do { if isPrivate { try FileManager.default.removeItem(at: original) } else { try FileManager.default.trashItem(at: original, resultingItemURL: nil) } }
                catch { note = "The audio was saved, but the downloaded video could not be removed (\(error.localizedDescription))." }
            }
        }
        lastNote = note
        // The audio file is the download the person has now: it is recorded as one, and the removed video's record leaves the list (a record is only dropped if its file is really gone).
        let origin = coordinator.ledger.record(recordID)?.source.asURL
        coordinator.retireRecords([recordID])
        coordinator.recordProducedFile(audio, source: origin, isPrivate: isPrivate)
        stage = .done(audio)
    }
    private(set) var lastNote: String?

    static func unique(_ url: URL) -> URL {
        // The same form every download uses ("Title (1).mp4"), from the one place that chooses free names.
        let dir = url.deletingLastPathComponent()
        return dir.appendingPathComponent(FilenameResolver.freeName(url.lastPathComponent, in: dir))
    }
}
