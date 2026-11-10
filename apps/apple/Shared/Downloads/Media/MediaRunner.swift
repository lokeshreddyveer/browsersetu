import Foundation

/// What the person chose in the preview. Nothing is fetched except what is named here.
struct MediaChoice: Equatable, Sendable {
    var video: String?
    var audio: String?
    var subtitles: [String] = []
    /// DX-08: further audio tracks (other languages) to put in the same file.
    var extraAudios: [String] = []
}

extension MediaManifest {
    func defaultSelection() -> MediaChoice { defaultSelection(preferring: MediaPreferences()) }
    var hasDownloadableStream: Bool { unsupported == nil && (videos + audios).contains(where: \.isDownloadable) }
}

enum MediaRunnerError: Error, LocalizedError, Equatable {
    case nothingChosen
    var errorDescription: String? { "Choose at least one stream to download." }
}

/// Connects a streaming (HLS or DASH) download to the rest of the downloads system. The ledger owns the task, the scheduler gives it its place, `MediaDownloader` fetches the
/// segments through the same request policy and connection budget as every other download, and the coordinator finishes it. Nothing is fetched because a link was seen.
@MainActor
final class MediaRunner {
    static let sentinel = Data("{\"engine\":\"media\",\"v\":1}".utf8)

    private unowned let coordinator: DownloadCoordinator
    private var ledger: DownloadLedger { coordinator.ledger }
    private var runs: [UUID: Task<Void, Never>] = [:]
    private var finishing = Set<UUID>()
    private(set) var progress: [UUID: (done: Int, total: Int)] = [:]
    /// Each track's own count, by position in the plan, while it runs.
    private var trackCounts: [UUID: [Int: (done: Int, total: Int)]] = [:]
    private var retryCounts: [UUID: Int] = [:]
    private var trackMeta: [UUID: [(key: String, name: String)]] = [:]

    init(coordinator: DownloadCoordinator) { self.coordinator = coordinator }

    private var network: DownloadNetworkSetup { coordinator.http.engine.currentNetwork }

    func isFinishing(_ id: UUID) -> Bool { finishing.contains(id) }
    func live(_ id: UUID) -> (done: Int, total: Int)? { progress[id] }

    // MARK: Looking (the manifest only: no media is fetched)

    func inspect(_ url: URL, origin: DownloadRequestOrigin = .user, refuseInternal: Bool = false) async throws -> MediaManifest {
        let fetcher = try MediaFetcher(policy: HTTPRequestPolicy(origin: origin), network: network, refuseInternal: refuseInternal)
        defer { fetcher.invalidate() }
        let (data, final) = try await fetcher.text(url)
        return try MediaManifestReader.read(data, from: final)
    }

    /// A small text document (a feed) under the same rules as a playlist: the redirect guard, the address checks, the profile's network choice, a size limit, no cookies.
    func fetchDocument(_ url: URL, limit: Int, origin: DownloadRequestOrigin = .page, refuseInternal: Bool = true) async throws -> (data: Data, finalURL: URL) {
        let fetcher = try MediaFetcher(policy: HTTPRequestPolicy(origin: origin), network: network, refuseInternal: refuseInternal)
        defer { fetcher.invalidate() }
        return try await fetcher.text(url, limit: limit)
    }

    /// A feed, asked for only if it changed since `ifChanged` (see `MediaFetcher.document`).
    func fetchDocument(_ url: URL, limit: Int, origin: DownloadRequestOrigin = .page, refuseInternal: Bool = true, ifChanged: MediaFetcher.DocumentValidators?) async throws -> MediaFetcher.DocumentResult {
        let fetcher = try MediaFetcher(policy: HTTPRequestPolicy(origin: origin), network: network, refuseInternal: refuseInternal)
        defer { fetcher.invalidate() }
        return try await fetcher.document(url, limit: limit, ifChanged: ifChanged)
    }

    /// The chosen streams with their segment lists. Fetches the chosen streams' own playlists (HLS), nothing else.
    /// `fallbacks` are the streams that may take the place of the chosen video if its playlist cannot be had, and are used only when `allowFallback` says so.
    func plan(for manifest: MediaManifest, selection: MediaChoice, title: String, origin: DownloadRequestOrigin = .user, allowFallback: Bool = false, fallbacks: [String] = [], sourceURL: URL? = nil) async throws -> MediaPlan {
        if let why = manifest.unsupported { throw MediaError.unsupported(why) }
        var chosen: [MediaStream] = []
        var notes: [String] = manifest.warnings
        if selection.video == nil, selection.audio == nil, selection.subtitles.count > 1 { throw MediaError.unsupported("Choose one subtitle track when downloading subtitles alone.") }
        func pick(_ id: String?, from list: [MediaStream]) throws {
            guard let id else { return }
            guard let s = list.first(where: { $0.id == id }) else { throw MediaRunnerError.nothingChosen }
            if let why = s.unsupported { throw MediaError.unsupported(why) }
            chosen.append(s)
        }
        try pick(selection.video, from: manifest.videos)
        // A stream that already carries its sound needs no separate audio.
        if chosen.first?.kind != .muxed {
            try pick(selection.audio, from: manifest.audios)
            for id in selection.extraAudios where id != selection.audio { try pick(id, from: manifest.audios) }
        }
        for id in selection.subtitles { try pick(id, from: manifest.subtitles) }
        guard !chosen.isEmpty else { throw MediaRunnerError.nothingChosen }

        let fetcher = try MediaFetcher(policy: HTTPRequestPolicy(origin: origin), network: network)
        defer { fetcher.invalidate() }
        var resolved: [MediaStream] = []
        for (n, s0) in chosen.enumerated() {
            var s = s0
            do { s = try await Self.resolve(s0, fetcher: fetcher) }
            catch is CancellationError { throw CancellationError() }
            catch {
                // The chosen quality's playlist cannot be had. If the person allowed it, the next best compatible quality stands in, and they are told; otherwise the choice stands and the error is theirs to see.
                guard allowFallback, n == 0, s0.kind == .video || s0.kind == .muxed else { throw error }
                var replaced: MediaStream?
                for id in fallbacks {
                    guard let candidate = manifest.videos.first(where: { $0.id == id }), candidate.isDownloadable else { continue }
                    if let r = try? await Self.resolve(candidate, fetcher: fetcher) { replaced = r; break }
                }
                guard let replaced else { throw error }
                notes.append("The quality you chose could not be read; \(replaced.label) was used instead.")
                s = replaced
            }
            if let why = s.unsupported { throw MediaError.unsupported(why) }
            guard !s.segments.isEmpty else { throw MediaError.malformed("a stream lists no segments") }
            resolved.append(s)
        }
        // Tracks that were meant to run alongside each other should be about as long. A large difference is reported, not hidden.
        let lengths = resolved.filter { $0.kind == .video || $0.kind == .audio }.compactMap(\.duration)
        if let lo = lengths.min(), let hi = lengths.max(), hi - lo > max(2, hi * 0.02) { notes.append(String(format: "The tracks differ in length by %.0f seconds.", hi - lo)) }
        let expanded = resolved.flatMap(MediaParts.expand)
        let total = expanded.reduce(0) { $0 + $1.segments.count }
        guard total <= MediaLimits.maxSegmentsPerStream * 2 else { throw MediaError.tooManySegments }
        let verdict = MediaCompatibility.check(expanded)
        if let blocker = verdict.blockers.first { throw MediaError.unsupported(blocker) }
        var plan = MediaPlan(format: manifest.format, fingerprint: manifest.fingerprint, title: title, streams: expanded, outputExtension: verdict.fileExtension)
        plan.sourceURL = sourceURL?.absoluteString ?? manifest.sourceURL
        plan.selection = MediaSelectionRecord(video: resolved.first.flatMap { $0.kind == .video || $0.kind == .muxed ? $0.id : nil } ?? selection.video, audio: selection.audio, extraAudios: selection.extraAudios, subtitles: selection.subtitles)
        plan.structure = MediaRefresh.signature(expanded)
        plan.allowFallback = allowFallback
        var seen = Set<String>()
        let all = (notes + verdict.warnings).filter { seen.insert($0).inserted }
        plan.warnings = all.isEmpty ? nil : all
        plan.outputNote = verdict.warnings.first
        return plan
    }

    /// A chosen stream with its playlist read.
    static func resolve(_ s: MediaStream, fetcher: MediaFetcher) async throws -> MediaStream {
        guard s.segments.isEmpty, let list = s.playlistURL, let url = URL(string: list) else { return s }
        // A subtitle entry that points straight at a text file rather than a playlist.
        if s.kind == .subtitle, ["vtt", "webvtt", "ttml", "dfxp"].contains(url.pathExtension.lowercased()) {
            var t = s
            t.segments = [MediaSegment(url: url.absoluteString, duration: 0)]
            t.container = url.pathExtension.lowercased().hasSuffix("vtt") ? .webVTT : .ttml
            return t
        }
        let (data, final) = try await fetcher.text(url)
        let detail = try HLSParser.parseStream(String(decoding: data, as: UTF8.self), base: final, label: s.label)
        var merged = s
        merged.segments = detail.segments; merged.initSegment = detail.initSegment; merged.extraInits = detail.extraInits
        merged.container = detail.container; merged.duration = detail.duration; merged.unsupported = detail.unsupported
        merged.notes = ((s.notes ?? []) + (detail.notes ?? [])).isEmpty ? nil : (s.notes ?? []) + (detail.notes ?? [])
        if detail.container == .webVTT { merged.kind = .subtitle }
        if merged.kind == .subtitle, !merged.container.isText, merged.unsupported == nil { merged.unsupported = "Subtitles carried inside MP4 or transport-stream segments are not extracted yet." }
        return merged
    }

    // MARK: Starting

    @discardableResult
    func add(_ plan: MediaPlan, name: String, source: URL, origin: DownloadRequestOrigin = .user, isPrivate: Bool = false) async throws -> UUID {
        // The ending is the real output's (from the plan), put on by the one resolver: a playlist or media ending already on the name is replaced, never doubled, and a dot in a title
        // ("Lecture 1.5") stays part of the title.
        let filename = DownloadFilename.truncated(FilenameResolver.applying(extension: plan.outputExtension, to: DownloadFilename.sanitize(name) ?? "Video"))          // the ending is added after the cut: cut again
        let ticket = await coordinator.admitTicket(filename: filename, source: source, protocolID: .media)
        let id = ticket.id
        ledger.update(id) { $0.engineMetadata["media"] = plan.format.rawValue; $0.engineMetadata["origin"] = origin.rawValue }
        // Put off by a held queue: the plan is kept with the task so it starts from it later, never as a plain download of the playlist's address.
        guard ticket.admitted else { try? MediaStore.save(plan, in: MediaStore.folder(profile: ledger.profile, task: id)); return id }
        if await coordinator.askAboutDuplicate(suggestedName: filename, sourceHost: source.host, source: source, isPrivate: isPrivate, taskID: id) { return id }
        let started = coordinator.begin(suggestedName: filename, sourceHost: source.host, sourceURL: source, isPrivate: isPrivate, taskID: id, protocolID: .media,
                                        cancel: { [weak self] in self?.cancel(id) }, suspend: { [weak self] done in self?.pause(id, done: done) })
        let dir = MediaStore.folder(profile: ledger.profile, task: id)
        do { try MediaStore.save(plan, in: dir) } catch {
            fail(id, "The download could not be prepared.", retryable: false, dir: dir); return id
        }
        ledger.update(id) {
            $0.transfer.resumeAvailable = true; $0.engineMetadata["mediaTracks"] = Self.summary(of: plan); $0.engineMetadata["mediaSegments"] = String(plan.totalSegments)
            if let w = plan.warnings, !w.isEmpty { $0.engineMetadata["mediaWarnings"] = w.joined(separator: " ") }
        }
        ledger.saveResumeData(id, Self.sentinel)
        run(id, plan: plan, dir: dir, destination: started.destination, origin: origin)
        return id
    }

    /// "1080p · English", for the details panel. A track cut into parts is one entry.
    static func summary(of plan: MediaPlan) -> String {
        var seen = Set<String>()
        return plan.streams.filter { seen.insert($0.trackKey ?? $0.id).inserted }.map(trackName).joined(separator: " + ")
    }

    static func trackName(_ s: MediaStream) -> String {
        switch s.kind {
        case .audio: return "Audio" + (s.language.map { " (\($0))" } ?? "") + (s.role == "commentary" ? " commentary" : "")
        case .subtitle: return "Subtitles" + (s.language.map { " (\($0))" } ?? "") + (s.forced == true ? " forced" : "")
        default: return [s.resolutionText, s.bitrateText].compactMap { $0 }.joined(separator: ", ").nilIfEmpty ?? s.label
        }
    }

    /// "Video 12 of 40 · Audio (English) 20 of 40", for the details panel while it runs.
    func trackProgress(_ id: UUID) -> String? {
        guard let meta = trackMeta[id], let counts = trackCounts[id], !counts.isEmpty else { return nil }
        var order: [String] = [], sums: [String: (done: Int, total: Int, name: String)] = [:]
        for (k, m) in meta.enumerated() {
            let c = counts[k] ?? (0, 0)
            if sums[m.key] == nil { order.append(m.key); sums[m.key] = (0, 0, m.name) }
            sums[m.key]!.done += c.done; sums[m.key]!.total += c.total
        }
        return order.compactMap { sums[$0] }.map { "\($0.name) \($0.done) of \($0.total)" }.joined(separator: " · ")
    }
    func retries(_ id: UUID) -> Int { retryCounts[id] ?? 0 }

    /// A failure that carries its own words, and keeps what was downloaded so a later try can carry on.
    struct ExpiryFailure: Error { var reason: String }

    private func run(_ id: UUID, plan: MediaPlan, dir: URL, destination: URL, origin: DownloadRequestOrigin) {
        runs[id]?.cancel()                                      // one run per task, whatever asked twice
        progress[id] = (0, plan.totalSegments)
        trackCounts[id] = [:]; retryCounts[id] = 0
        trackMeta[id] = plan.streams.map { (key: $0.trackKey ?? $0.id, name: Self.trackName($0).replacingOccurrences(of: ", ", with: " ")) }
        for (k, st) in plan.streams.enumerated() { trackCounts[id]?[k] = (0, st.segments.count + (st.initSegment == nil ? 0 : 1)) }
        let setup = network
        runs[id] = Task { [weak self] in
            var current = plan
            do {
                while true {
                    guard let self else { return }
                    let fetcher = try MediaFetcher(policy: HTTPRequestPolicy(origin: origin), network: setup)
                    let downloader = MediaDownloader(fetcher: fetcher, plan: current, dir: dir, taskID: id, concurrency: min(3, max(1, setup.perHostConnections)))
                    let total = max(1, current.totalSegments)
                    downloader.onProgress = { done, bytes in
                        Task { @MainActor [weak self] in
                            guard let self, self.runs[id] != nil else { return }
                            self.progress[id] = (done, total)
                            self.coordinator.update(id, fraction: min(0.95, Double(done) / Double(total) * 0.95))
                            if done % 5 == 0 || done == total { self.ledger.update(id) { $0.engineMetadata["mediaDone"] = String(done) } }
                        }
                    }
                    downloader.onTrack = { stream, done, count in
                        Task { @MainActor [weak self] in
                            guard let self, self.runs[id] != nil else { return }
                            self.trackCounts[id, default: [:]][stream] = (done, count)
                        }
                    }
                    downloader.onRetry = { n in Task { @MainActor [weak self] in self?.retryCounts[id] = n } }
                    do {
                        try await downloader.run()
                        fetcher.invalidate()
                        break
                    } catch let expired as MediaSourceExpired {
                        fetcher.invalidate()
                        guard let refreshed = try await self.refresh(id, plan: current, dir: dir, origin: origin) else {
                            throw ExpiryFailure(reason: expired.detail.info.reason + " It could not be renewed from the page it came from. The pieces already downloaded are kept.")
                        }
                        current = refreshed
                    } catch {
                        fetcher.invalidate()
                        throw error
                    }
                }
                try Task.checkCancellation()
                await self?.finalize(id, plan: current, dir: dir, destination: destination)
            } catch is CancellationError {
                return
            } catch {
                await self?.failed(id, error: error, dir: dir)
            }
        }
    }

    /// The links in the plan stopped working. The manifest is read again from the address it came from, and its new links are used only if it describes the very same thing: the same
    /// tracks, the same number of segments of the same lengths, on servers the download was already using. Anything else ends the download rather than mixing two versions.
    /// nil: it cannot be renewed (no source, or already renewed as often as is allowed).
    private func refresh(_ id: UUID, plan: MediaPlan, dir: URL, origin: DownloadRequestOrigin) async throws -> MediaPlan? {
        guard let text = plan.sourceURL, let url = URL(string: text), let record = plan.selection, (plan.refreshes ?? 0) < 2 else { return nil }
        let manifest = try await inspect(url, origin: origin)
        if let why = manifest.unsupported { throw ExpiryFailure(reason: "The link expired and the page now says: \(why)") }
        let choice = MediaChoice(video: record.video, audio: record.audio, subtitles: record.subtitles, extraAudios: record.extraAudios)
        // The same choice, with no stand-in: a refreshed link may not change what is being saved.
        let fresh: MediaPlan
        do { fresh = try await self.plan(for: manifest, selection: choice, title: plan.title, origin: origin, allowFallback: false, sourceURL: url) }
        catch let e as MediaError { throw ExpiryFailure(reason: "The link expired and the page now offers something different (\(e.errorDescription ?? "the tracks changed")), so this download cannot carry on.") }
        catch is MediaRunnerError { throw ExpiryFailure(reason: "The link expired and a track that was chosen is no longer offered, so this download cannot carry on.") }
        if case .different(let why) = MediaRefresh.compare(old: plan.streams, fresh: fresh.streams) {
            throw ExpiryFailure(reason: "The link expired and the page now describes a different video (\(why)), so this download cannot carry on. Nothing was changed.")
        }
        guard let adopted = MediaRefresh.adopt(old: plan.streams, fresh: fresh.streams, allowedHosts: Set([url.host?.lowercased()].compactMap { $0 })) else {
            throw ExpiryFailure(reason: "The renewed links point to a server this download was not using, so they were not used.")
        }
        var updated = plan
        updated.streams = adopted
        updated.refreshes = (plan.refreshes ?? 0) + 1
        try? MediaStore.save(updated, in: dir)
        ledger.update(id) { $0.engineMetadata["mediaRefreshes"] = String(updated.refreshes ?? 1) }
        return updated
    }

    // MARK: Finishing

    private func finalize(_ id: UUID, plan: MediaPlan, dir: URL, destination: URL) async {
        guard runs[id] != nil, !finishing.contains(id) else { return }
        guard DownloadPathPolicy.isAuthorized(destination.path, roots: coordinator.managedRoots) else {
            fail(id, "This download's folder is outside the download folder, so nothing was moved.", retryable: false, dir: dir); return
        }
        finishing.insert(id)
        coordinator.update(id, fraction: 0.97)
        defer { finishing.remove(id) }
        do {
            let output = try await MediaAssembler.assemble(plan, dir: dir)
            guard runs[id] != nil else { return }                      // cancelled while the file was being put together
            let folder = destination.deletingLastPathComponent()
            // Nothing already in the folder is overwritten: if the name was taken in the meantime the file is saved under another one.
            // The name is claimed by the rename itself, so two saves finishing at once cannot take the same one.
            let target = try FileNaming.publish(output.file, as: destination)
            var sidecars: [String] = []
            for side in output.sidecars where !plan.streams.allSatisfy({ $0.kind == .subtitle || $0.container.isText }) {
                let name = (target.lastPathComponent as NSString).deletingPathExtension + "." + side.suffix + "." + side.ext
                if let place = try? FileNaming.publish(side.url, as: folder.appendingPathComponent(name)) { sidecars.append(place.lastPathComponent) }
            }
            DownloadQuarantine.apply(to: target, sourceOrigin: DownloadCoordinator.originOnly(of: plan.streams.first?.segments.first?.url))
            coordinator.updateDestination(id, to: target)
            ledger.update(id) {
                $0.transfer.resumeAvailable = false
                if let note = output.note { $0.engineMetadata["mediaNote"] = note }
                if let r = output.report {
                    let langs = r.audioLanguages.compactMap { $0 }.joined(separator: ", ")
                    $0.engineMetadata["mediaOutput"] = "\(r.videoTracks) video, \(r.audioTracks) audio" + (langs.isEmpty ? "" : " (\(langs))") + String(format: ", %.1f s", r.duration)
                }
                if !sidecars.isEmpty { $0.engineMetadata["mediaSubtitleFiles"] = sidecars.joined(separator: ", ") }
            }
            runs[id] = nil; progress[id] = nil; trackCounts[id] = nil; trackMeta[id] = nil
            MediaStore.remove(dir)
            coordinator.finish(id, source: nil, integrity: .unknown)
        } catch is CancellationError {
            return
        } catch {
            guard runs[id] != nil else { return }
            runs[id] = nil
            // A full disk is not the download's fault: the pieces are kept so it can be finished once there is room.
            fail(id, (error as? LocalizedError)?.errorDescription ?? "The finished file could not be put together.", retryable: (error as? MediaAssembleError) == .noSpace, dir: dir)
        }
    }

    private func failed(_ id: UUID, error: Error, dir: URL) {
        guard runs[id] != nil else { return }
        if let e = error as? ExpiryFailure { fail(id, e.reason, retryable: true, dir: dir); return }
        let info = (error as? MediaError).map { DownloadFailureInfo(code: "media:manifest", reason: $0.errorDescription ?? "The stream could not be read.", retryable: false) }
            ?? HTTPResponseRules.failure(for: error).info
        fail(id, info.reason, retryable: info.retryable, dir: dir)
    }

    /// A failure that can be retried keeps the segments it already has; one that cannot is cleaned up.
    private func fail(_ id: UUID, _ reason: String, retryable: Bool, dir: URL) {
        runs[id]?.cancel(); runs[id] = nil; progress[id] = nil; trackCounts[id] = nil; trackMeta[id] = nil
        if !retryable { MediaStore.remove(dir) }
        coordinator.fail(id, source: ledger.record(id)?.source.asURL, error: HTTPDownloadError(info: DownloadFailureInfo(code: "media:failed", reason: reason, retryable: retryable)), willRetry: false)
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
        MediaStore.remove(MediaStore.folder(profile: ledger.profile, task: id))
    }

    /// Carries on from the segments already in the task's folder.
    func resume(_ id: UUID) {
        let dir = MediaStore.folder(profile: ledger.profile, task: id)
        guard let record = ledger.record(id), let dest = record.file.destinationPath, DownloadPathPolicy.isAuthorized(dest, roots: coordinator.managedRoots),
              var plan = MediaStore.load(from: dir) else {
            fail(id, "The saved details of this download are missing.", retryable: false, dir: dir); return
        }
        ledger.apply(.resumed, to: id)
        plan.refreshes = 0                      // a person's own resume is a fresh start for renewing links
        run(id, plan: plan, dir: dir, destination: URL(fileURLWithPath: dest), origin: DownloadRequestOrigin(rawValue: record.engineMetadata["origin"] ?? "") ?? .automation)
    }

    /// A failed download started again from what it kept: the same task, a new attempt.
    func restart(_ id: UUID) {
        guard let record = ledger.record(id), let source = record.source.asURL else { return }
        let dir = MediaStore.folder(profile: ledger.profile, task: id)
        guard runs[id] == nil, var plan = MediaStore.load(from: dir) else { note(record.file.filename, "its saved details are gone, so add it again"); return }
        plan.refreshes = 0
        let origin = DownloadRequestOrigin(rawValue: record.engineMetadata["origin"] ?? "") ?? .automation
        Task { @MainActor in
            coordinator.reserveTaskID(id, for: source)
            let ticket = await coordinator.admitTicket(filename: record.file.filename, source: source, protocolID: .media)
            guard ticket.admitted else { return }
            if await coordinator.askAboutDuplicate(suggestedName: record.file.filename, sourceHost: source.host, source: source, isPrivate: record.isPrivate, taskID: id) { return }
            let started = coordinator.begin(suggestedName: record.file.filename, sourceHost: source.host, sourceURL: source, isPrivate: record.isPrivate, taskID: id, protocolID: .media,
                                            cancel: { [weak self] in self?.cancel(id) }, suspend: { [weak self] done in self?.pause(id, done: done) })
            ledger.update(id) { $0.transfer.resumeAvailable = true }
            ledger.saveResumeData(id, Self.sentinel)
            run(id, plan: plan, dir: dir, destination: started.destination, origin: origin)
        }
    }

    private func note(_ name: String, _ why: String) { coordinator.note("Could not retry \(name): \(why)") }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

enum MediaTransferEngine {
    static let protocolID: DownloadProtocolID = .media
    /// Pause and resume work from the segments already fetched. A speed limit is held between segments, not inside one, so it is not declared as enforced at the transport.
    static let capabilities: DownloadEngineCapabilities = [.pause, .resume, .resolveMetadata, .reportsTotalBytes]
}
