import Foundation
import AVFoundation

// Carries out a choice made from a NormalizedMediaSource using only existing engines: a single file or each separate track is an ordinary coordinator download, a stream goes through the
// stream engine (inspect, plan, add), joining uses the media assembler's own combine, audio uses the local processing service or the MP3 encoder. The result is read back before it is called saved.

@MainActor
final class SourceSaveOperation: ObservableObject {
    enum Choice: Equatable, Sendable { case original, joined, audioM4A, audioMP3(kbps: Int), joinedFFmpeg(container: String), audioM4AFFmpeg, audioMP3FFmpeg(kbps: Int) }
    @Published private(set) var stage = VideoSaveOperation.Stage.waiting
    private(set) var downloadIDs: [UUID] = []
    private(set) var note: String?
    let source: NormalizedMediaSource
    let choice: Choice
    let name: String
    private let coordinator: DownloadCoordinator
    private let profileTag: String
    private let origin: DownloadRequestOrigin
    private var task: Task<Void, Never>?
    private var inner: VideoSaveOperation?
    private var started = false
    /// The files this request itself downloaded (ledger id → path), so only those are ever removed.
    private var owned: [UUID: URL] = [:]
    private var ownedSizes: [UUID: Int] = [:]
    /// The representations the person chose; nil takes the best picture and the first sound.
    var pickVideo: NormalizedRepresentation?, pickAudio: NormalizedRepresentation?
    /// For a stream: the playlist's id of the rendition that was chosen (the quality shown in the list is the quality fetched).
    var pickStreamID: String?

    init(source: NormalizedMediaSource, choice: Choice, name: String, coordinator: DownloadCoordinator, profileTag: String, origin: DownloadRequestOrigin = .page) {
        self.source = source; self.choice = choice; self.name = Self.safeName(name); self.coordinator = coordinator; self.profileTag = profileTag; self.origin = origin
    }

    /// The name the person typed (or an extractor suggested) as a file name only: no folders, no control characters, and short enough that the partial name beside it still fits.
    static func safeName(_ n: String) -> String {
        // Without a media/playlist ending: every output adds its own real one (a name typed as "Concert.webm" is "Concert.mp3" as sound, never "Concert.webm.mp3").
        var s = DownloadFilename.sanitize(n).map(FilenameResolver.stem(of:)) ?? "Video"
        while s.utf8.count > 180 { s.removeLast() }
        return s.isEmpty ? "Video" : s
    }

    func start() {
        guard task == nil, !started, !stage.isFinal else { return }
        started = true
        do { try source.validate(allowLocal: origin == .user) } catch { stage = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)"); return }
        stage = .downloading(0)
        task = Task { [weak self] in await self?.run() }
    }

    func cancel() {
        task?.cancel(); inner?.cancel()
        for id in downloadIDs { if let r = coordinator.ledger.record(id), !r.state.isFinal { coordinator.cancel(id) } }
        if !stage.isFinal { stage = .cancelled }
    }

    private func fail(_ s: String) { if !stage.isFinal { stage = .failed(s) } }
    /// A stage written after an await never replaces a final one (a cancel that arrived meanwhile stays cancelled).
    private func set(_ s: VideoSaveOperation.Stage) { if !stage.isFinal { stage = s } }

    /// Removes a file only if it is still exactly what this request downloaded.
    private func removeOwned(_ ids: [UUID]) {
        for id in ids {
            guard let url = owned[id], coordinator.ledger.record(id)?.file.destinationPath == url.path, FileManager.default.fileExists(atPath: url.path),
                  (ownedSizes[id] == nil || ownedSizes[id] == ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1)) else { continue }
            if source.isPrivate { try? FileManager.default.removeItem(at: url) } else { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        }
        coordinator.retireRecords(ids)          // a record whose file was just removed no longer shows as an accessible completed download
    }

    /// The result stands: it is recorded as one completed download (a real file, with its own name and extension), then the sheet shows it. Cancelled or failed first: nothing is recorded.
    private var firstSourceURL: URL?
    /// The download record of the finished file (nil for a save the system engine did, or one that did not finish).
    private(set) var producedID: UUID?
    /// The download record that IS the result once the save is done: the file this operation made (joined or converted), or, for a plain file saved as it is, its one download.
    var resultRecordID: UUID? { guard case .done = stage else { return nil }; return producedID ?? (downloadIDs.count == 1 ? downloadIDs.first : nil) }
    /// The addresses this request downloaded from, in order (the intermediates' records leave the list once their files are removed, so this is what shows which tracks were really fetched).
    private(set) var fetchedURLs: [URL] = []
    private func finishWith(_ target: URL) {
        guard !stage.isFinal else { return }
        // The address of the first thing downloaded, remembered when it started (the records of the intermediates may already be retired by now).
        producedID = coordinator.recordProducedFile(target, source: firstSourceURL, isPrivate: source.isPrivate)
        set(.done(target))
    }

    private func run() async {
        switch source.shape {
        case .manifest(let url): await runStream(url)
        case .tracks(let reps): await runTracks(reps)
        }
    }

    // A file, or separate picture and sound.
    private func runTracks(_ reps: [NormalizedRepresentation]) async {
        // The format the person picked is used exactly (by identity), not "the best of its kind".
        let picked = pickVideo.flatMap { p in reps.first { $0 == p } }
        let video = (picked?.role == .video ? picked : nil) ?? reps.filter { $0.role == .video }.max { ($0.height ?? 0) < ($1.height ?? 0) }
        let audio = pickAudio.flatMap { p in reps.first { $0 == p } } ?? DownloadPlanner.bestAudio(reps.filter { $0.role == .audio })
        let muxed = (picked?.role == .muxed ? picked : nil) ?? reps.filter { $0.role == .muxed }.max { ($0.height ?? 0) < ($1.height ?? 0) }
        switch choice {
        case .joined:
            guard let v = video, let a = audio else { return fail("There is no separate picture and sound to join.") }
            guard NormalizedMediaSource.systemContainers.contains(v.container), NormalizedMediaSource.systemContainers.contains(a.container) else { return fail("These containers cannot be joined by the system's media engine.") }
            guard let vf = await fetch(v.url, "\(name).video.\(v.container)") else { return }
            // Another look before the second half: a link that ran out while the first half was coming is said now, not after more work.
            do { try source.validate(allowLocal: origin == .user) } catch { removeOwned(downloadIDs); return fail((error as? LocalizedError)?.errorDescription ?? "\(error)") }
            guard let af = await fetch(a.url, "\(name).audio.\(a.container)") else { removeOwned(downloadIDs); return }
            set(.converting(0.5))
            let target = VideoSaveOperation.unique(vf.deletingLastPathComponent().appendingPathComponent(name).appendingPathExtension("mp4"))
            do {
                let g = [MediaAssembler.Group(key: "v", streams: [0], kind: .video, language: nil, label: "video"), MediaAssembler.Group(key: "a", streams: [1], kind: .audio, language: a.language, label: "audio")]
                try await MediaAssembler.combine(g, joined: [0: vf, 1: af], to: target)
                try await MediaAssembler.validateBasic(target)
                let asset = AVURLAsset(url: target)
                let v1 = try await asset.loadTracks(withMediaType: .video).count, a1 = try await asset.loadTracks(withMediaType: .audio).count
                guard v1 == 1, a1 == 1 else { throw MediaAssembleError.unplayable("the joined file has \(v1) picture and \(a1) sound tracks") }
                if Task.isCancelled || stage == .cancelled { try? FileManager.default.removeItem(at: target); removeOwned(downloadIDs); return }
                removeOwned(downloadIDs)          // the two halves this request downloaded (only if still exactly those files)
                finishWith(target)
            } catch { try? FileManager.default.removeItem(at: target); removeOwned(downloadIDs); fail((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) }
        case .joinedFFmpeg(let container):
            guard let v = video, let a = audio else { return fail("There is no separate picture and sound to join.") }
            #if os(macOS)
            guard await FFmpegTool.programs() != nil else { return fail(FFmpegProcessingError.unavailable.localizedDescription) }        // fail early, before downloading anything
            guard let vf = await fetch(v.url, "\(name).video.\(v.container)") else { return }
            do { try source.validate(allowLocal: origin == .user) } catch { removeOwned(downloadIDs); return fail((error as? LocalizedError)?.errorDescription ?? "\(error)") }
            guard let af = await fetch(a.url, "\(name).audio.\(a.container)") else { removeOwned(downloadIDs); return }
            // The tool is taken again now: removing it meanwhile waits for this job, or (if already underway) ends it here with a plain message.
            // The downloaded halves are kept in this case (they are ordinary finished downloads the person can use or retry with); nothing was made from them.
            guard let lease = FFmpegTool.acquire(), let programs = await FFmpegTool.programs() else { return fail(FFmpegProcessingError.unavailable.localizedDescription) }
            defer { lease.release() }
            set(.converting(0))
            var target = VideoSaveOperation.unique(vf.deletingLastPathComponent().appendingPathComponent(name).appendingPathExtension(container))
            var made = false
            do {
                target = try await FFmpegProcessing.join(video: vf, audio: af, to: target, container: container, programs: programs) { p in Task { @MainActor [weak self] in if case .converting = self?.stage { self?.stage = .converting(p) } } }
                made = true
                if Task.isCancelled || stage == .cancelled { try? FileManager.default.removeItem(at: target); removeOwned(downloadIDs); return }
                removeOwned(downloadIDs)          // the two halves this request downloaded (only if still exactly those files)
                finishWith(target)
            } catch { if made { try? FileManager.default.removeItem(at: target) }; removeOwned(downloadIDs); if Task.isCancelled || stage == .cancelled { return }; fail((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) }
            #else
            fail("This needs the media processing tool, which is not available on this device.")
            #endif
        case .audioM4AFFmpeg, .audioMP3FFmpeg:
            guard let rep = (picked.flatMap { $0.role == .video ? nil : $0 }) ?? audio ?? muxed else { return fail(NormalizedFailure.noMedia.localizedDescription) }
            #if os(macOS)
            guard await FFmpegTool.programs() != nil else { return fail(FFmpegProcessingError.unavailable.localizedDescription) }
            guard let src = await fetch(rep.url, "\(name).source.\(rep.container)") else { return }
            guard let lease = FFmpegTool.acquire(), let programs = await FFmpegTool.programs() else { return fail(FFmpegProcessingError.unavailable.localizedDescription) }
            defer { lease.release() }
            set(.converting(0))
            let dir = src.deletingLastPathComponent()
            let report: @Sendable (Double, Double) -> (Double) -> Void = { lo, hi in { p in Task { @MainActor [weak self] in if case .converting = self?.stage { self?.stage = .converting(lo + (hi - lo) * p) } } } }
            do {
                if case .audioMP3FFmpeg(let k) = choice {
                    var flac = VideoSaveOperation.unique(dir.appendingPathComponent(FFmpegProcessing.intermediateName(name, ext: "flac")))
                    defer { try? FileManager.default.removeItem(at: flac) }
                    flac = try await FFmpegProcessing.extractAudio(from: src, to: flac, kind: .flac, programs: programs, progress: report(0, 0.5))
                    lease.release()          // the app's own encoder does the rest: removing the tool need not wait for it
                    // Encoded into a working file, then given its name by one atomic rename (so a save of the same name finishing at the same moment cannot take it or be overwritten).
                    let working = dir.appendingPathComponent(".\(name).mp3\(FFmpegProcessing.ownerMark).partial")
                    do { try await MP3Encoder.encode(source: flac, to: working, kbps: k, progress: report(0.5, 1)) } catch { try? FileManager.default.removeItem(at: working); throw error }
                    if Task.isCancelled || stage == .cancelled { try? FileManager.default.removeItem(at: working); removeOwned(downloadIDs); return }
                    let target: URL
                    do { target = try FileNaming.publish(working, as: dir.appendingPathComponent(name).appendingPathExtension("mp3")) } catch { try? FileManager.default.removeItem(at: working); throw error }
                    removeOwned(downloadIDs); finishWith(target)
                } else {
                    var target = VideoSaveOperation.unique(dir.appendingPathComponent(name).appendingPathExtension("m4a"))
                    target = try await FFmpegProcessing.extractAudio(from: src, to: target, kind: .m4a(kbps: 192), programs: programs, progress: report(0, 1))
                    if Task.isCancelled || stage == .cancelled { try? FileManager.default.removeItem(at: target); removeOwned(downloadIDs); return }
                    removeOwned(downloadIDs); finishWith(target)
                }
            } catch { removeOwned(downloadIDs); if Task.isCancelled || stage == .cancelled { return }; fail((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) }
            #else
            fail("This needs the media processing tool, which is not available on this device.")
            #endif
        case .original, .audioM4A, .audioMP3:
            guard let rep = choice == .original ? (picked ?? muxed ?? video ?? audio) : ((picked.flatMap { $0.role == .video ? nil : $0 }) ?? audio ?? muxed) else { return fail(NormalizedFailure.noMedia.localizedDescription) }
            let out: VideoSaveOperation.Output = { switch choice { case .audioM4A: .m4a; case .audioMP3(let k): .mp3(kbps: k); default: .original } }()
            let op = VideoSaveOperation(url: rep.url, name: name, output: out, keepOriginal: false, isPrivate: source.isPrivate, coordinator: coordinator, profileTag: profileTag, origin: origin)
            op.endingHint = rep.container
            inner = op; op.start()
            if let id = op.downloadID { downloadIDs.append(id) }
            while !Task.isCancelled, !op.stage.isFinal { set(op.stage); try? await Task.sleep(nanoseconds: 250_000_000) }
            if op.stage.isFinal { set(op.stage) }
            note = op.lastNote
        }
    }

    // A stream: the stream engine downloads and joins it; audio is made from the result.
    private func runStream(_ url: URL) async {
        do {
            try source.validate(allowLocal: origin == .user)
            let manifest = try await coordinator.media.inspect(url, origin: origin, refuseInternal: origin != .user)
            var sel = MediaChoice(video: nil, audio: nil, subtitles: [], extraAudios: [])
            switch choice {
            case .audioM4A, .audioMP3:
                guard let a = manifest.audios.first(where: \.isDownloadable) else { return fail("This stream lists no separate audio to save on its own.") }
                sel.audio = a.id
            default:
                sel = manifest.defaultSelection(preferring: MediaPreferences())
                if let id = pickStreamID, let chosen = manifest.videos.first(where: { $0.id == id && $0.isDownloadable }) {
                    sel.video = chosen.id
                    if chosen.kind == .muxed { sel.audio = nil; sel.extraAudios = [] }          // the rendition carries its own sound
                } else if pickStreamID != nil { return fail("The quality you chose is no longer offered by the stream.") }
            }
            guard manifest.problems(with: sel).isEmpty else { return fail(manifest.problems(with: sel).first?.text ?? "That choice cannot be downloaded.") }
            let plan = try await coordinator.media.plan(for: manifest, selection: sel, title: name, origin: origin, allowFallback: false, fallbacks: [], sourceURL: url)
            let id = try await coordinator.media.add(plan, name: name, source: url, origin: origin, isPrivate: source.isPrivate)
            downloadIDs.append(id)
            if firstSourceURL == nil { firstSourceURL = url }
            guard let file = await wait(id) else { return }
            owned[id] = file; ownedSizes[id] = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? nil
            if case .audioMP3(let k) = choice {
                set(.converting(0))
                let target = VideoSaveOperation.unique(file.deletingPathExtension().appendingPathExtension("mp3"))
                try await MP3Encoder.encode(source: file, to: target, kbps: k) { p in Task { @MainActor [weak self] in if case .converting = self?.stage { self?.stage = .converting(p) } } }
                if stage == .cancelled { try? FileManager.default.removeItem(at: target); return }
                removeOwned([id])          // the intermediate stream file, only if still the one this request made
                finishWith(target)
            } else { set(.done(file)) }
        } catch is CancellationError { removeOwned(downloadIDs); if !stage.isFinal { stage = .cancelled } }
        catch { removeOwned(downloadIDs); fail((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) }
    }

    private func fetch(_ url: URL, _ filename: String) async -> URL? {
        // A cancel that arrived while an earlier step was still running must not start one more transfer.
        guard !Task.isCancelled, stage != .cancelled else { if !stage.isFinal { stage = .cancelled }; return nil }
        guard let id = coordinator.scheduleDownload(url: url, at: Date(), filename: DownloadFilename.sanitize(filename), origin: origin, isPrivate: source.isPrivate) else { fail("That address could not be added to Downloads."); return nil }
        downloadIDs.append(id)
        if firstSourceURL == nil { firstSourceURL = url }
        fetchedURLs.append(url)
        let result = await wait(id)
        if let result { owned[id] = result; ownedSizes[id] = (try? FileManager.default.attributesOfItem(atPath: result.path)[.size] as? Int) ?? nil }
        return result
    }

    private func wait(_ id: UUID) async -> URL? {
        while !Task.isCancelled {
            guard let r = coordinator.ledger.record(id) else { fail("The download was removed."); return nil }
            switch r.state {
            case .completed:
                guard let p = r.file.destinationPath else { fail("The download left no file."); return nil }
                return URL(fileURLWithPath: p)
            case .failed, .recoveryRequired: fail(r.failure?.reason ?? "The download failed."); return nil
            case .cancelled: if !stage.isFinal { stage = .cancelled }; return nil
            case .paused, .scheduled, .queued: set(.waiting)
            default:
                let t = r.transfer.totalBytes ?? 0
                set(.downloading(t > 0 ? min(1, Double(r.transfer.completedBytes) / Double(t)) : 0))
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        // Cancelled while this download was still going: it is cancelled too, never left running with nothing to own its file.
        if let r = coordinator.ledger.record(id), !r.state.isFinal, r.state != .failed { coordinator.cancel(id) }
        if !stage.isFinal { stage = .cancelled }
        return nil
    }
}
