import Foundation

// DX-10: a playlist of separate media items (many videos on one page, a channel, a course), as opposed to an HLS/DASH stream's renditions and segments. Entries are listed cheaply (the extractor's
// flat listing: one title and address each, no formats), a page at a time; only the entries the person chooses are resolved, one at a time per extractor slot, with the same consent the single
// video flow asks for. Nothing here bypasses a site's access rules: an entry the extractor cannot get is reported as failed, and the others carry on.

extension ExternalExtractor {
    static let playlistPageSize = 100
    static let maxPlaylistEntries = 2000

    /// The arguments for listing one page of a playlist: entries `start...start+count-1`, flat (no formats are resolved).
    static func playlistArguments(for page: URL, start: Int, count: Int) throws -> [String] {
        _ = try arguments(for: page)          // the same address checks as a single video
        let s = max(1, start), c = max(1, min(count, playlistPageSize))
        return ["--dump-single-json", "--flat-playlist", "--playlist-start", "\(s)", "--playlist-end", "\(s + c - 1)", "--no-warnings", "--", page.absoluteString]
    }

    /// One page of a playlist's entries. Allowed only for the program the person approved (same checks as `lookup`).
    static func playlist(page: URL, path: String, isPrivate: Bool, allowLocal: Bool = false, start: Int = 1, count: Int = playlistPageSize, timeout: TimeInterval = defaultTimeout, expectedIdentity: String? = nil) async throws -> DownloadFeed {
        guard !isPrivate else { throw ExtractorFailure.unsafeLocation("it is never used in a private tab") }
        var args = try playlistArguments(for: page, start: start, count: count)
        let exe: URL
        if let expectedIdentity, expectedIdentity.hasPrefix("bundled:") {
            guard let v = BundledExtractor.verify(), v.identity == expectedIdentity, v.url.path == path else { throw ExtractorFailure.unsafeLocation("the bundled extractor does not match its pinned digest") }
            exe = v.url; args = BundledExtractor.extraArguments + args
        } else {
            exe = try validateLocation(path)
            if let expectedIdentity, identity(of: exe) != expectedIdentity { throw ExtractorFailure.unsafeLocation("the program changed after you allowed it") }
        }
        let data = try await run(exe, arguments: args, timeout: timeout, maxBytes: maxOutput)
        var feed = try ExtractorPlaylistParser.parse(data, asked: page, allowLocal: allowLocal, start: start)
        feed.more = feed.items.count + feed.unavailable >= count && start + count <= maxPlaylistEntries
        return feed
    }
}

enum ExtractorPlaylistParser {
    /// The flat listing as a list of items: each has an id, a title and the address of its own page (no download address yet: that is resolved when the entry is chosen).
    static func parse(_ data: Data, asked page: URL, allowLocal: Bool = false, start: Int = 1) throws -> DownloadFeed {
        guard data.count <= ExternalExtractor.maxOutput else { throw ExtractorFailure.tooMuchOutput }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw ExtractorFailure.malformed("not a JSON object") }
        guard (root["_type"] as? String) == "playlist", let entries = root["entries"] as? [Any] else { throw ExtractorFailure.malformed("this address is a single video, not a playlist") }
        guard entries.count <= ExternalExtractor.playlistPageSize + 1 else { throw ExtractorFailure.malformed("too many entries in one page") }
        var items: [DownloadFeedItem] = [], unavailable = 0
        for (offset, raw) in entries.enumerated() {
            guard let e = raw as? [String: Any] else { unavailable += 1; continue }
            if (e["_has_drm"] as? Bool) == true { unavailable += 1; continue }
            guard let text = (e["url"] as? String) ?? (e["webpage_url"] as? String), text.count <= 2048, let url = URL(string: text), (try? NormalizedMediaSource.checkAddress(url, allowLocal: allowLocal)) != nil else { unavailable += 1; continue }
            let id = DownloadFeedParser.clean((e["id"] as? String) ?? (e["id"] as? NSNumber)?.stringValue ?? url.absoluteString, max: 200)
            let title = DownloadFeedParser.clean((e["title"] as? String) ?? "", max: FeedLimits.maxTitle)
            items.append(DownloadFeedItem(id: id, title: title.isEmpty ? "Entry \(start + offset)" : title, published: nil, summary: DownloadFeedParser.clean((e["uploader"] as? String) ?? "", max: 120),
                                          link: url, enclosures: [], duration: DownloadFeedParser.seconds((e["duration"] as? NSNumber)?.doubleValue), episode: start + offset, season: nil))
        }
        var seen = Set<String>()
        items = items.filter { seen.insert($0.id).inserted }
        let title = DownloadFeedParser.clean((root["title"] as? String) ?? "", max: FeedLimits.maxTitle)
        var feed = DownloadFeed(kind: .playlist, title: title.isEmpty ? "Playlist" : title, siteURL: (root["webpage_url"] as? String).flatMap { URL(string: $0) }, items: items, next: nil, truncated: false)
        feed.unavailable = unavailable
        return feed
    }
}

/// What to save from each playlist entry: a batch default, which a single entry can override. The choice is made from what the entry really offers (never a quality it does not have).
enum PlaylistQuality: String, CaseIterable, Identifiable, Sendable {
    case best, p1080, p720, p480, audio
    var id: String { rawValue }
    var title: String { switch self { case .best: "Best available"; case .p1080: "Up to 1080p"; case .p720: "Up to 720p"; case .p480: "Up to 480p"; case .audio: "Audio only" } }
    var maxHeight: Int? { switch self { case .p1080: 1080; case .p720: 720; case .p480: 480; default: nil } }

    /// The option to save for this quality, among those that can actually be carried out. A height limit takes the tallest option within it, or, if every option is taller, the smallest one.
    func choose(from options: [PlannedOption]) -> PlannedOption? {
        let ready = options.filter(\.isExecutable)
        switch self {
        case .best: return ready.first
        case .audio: return ready.first { $0.option.kind != .video && $0.option.kind != .original && $0.choice != .original } ?? ready.first { $0.option.kind == .audioOriginal || $0.option.kind == .audioM4A } ?? ready.first
        case .p1080, .p720, .p480:
            let limit = maxHeight!
            let videos = ready.filter { $0.option.kind == .video || $0.option.kind == .original }
            let sized = videos.compactMap { o in o.representation?.height.map { (o, $0) } }
            guard !sized.isEmpty else { return videos.first ?? ready.first }
            if let fit = sized.filter({ $0.1 <= limit }).max(by: { $0.1 < $1.1 }) { return fit.0 }
            return sized.min(by: { $0.1 < $1.1 })?.0
        }
    }
}

/// Resolves and downloads chosen playlist entries, a few at a time, into one collection. Each entry is an ordinary single-video save (extractor lookup, the planner's best executable choice,
/// `SourceSaveOperation`), so naming, validation, the ledger record and cleanup are the ones every other save has. A failure of one entry never stops the others; failed ones can be retried.
@MainActor
final class PlaylistRunner: ObservableObject {
    enum ItemState: Equatable { case waiting, looking, saving(Double), done(String), failed(String), skipped(String) }

    struct Program: Sendable { var path: String; var identity: String }

    let coordinator: DownloadCoordinator
    @Published private(set) var states: [String: ItemState] = [:]
    /// The playlist the states belong to: a different playlist starts with a clean slate.
    private var stateSource: String?
    @Published private(set) var running = false
    private(set) var packageID: UUID?
    private var task: Task<Void, Never>?
    private var ops: [String: SourceSaveOperation] = [:]
    static let concurrency = 2

    init(coordinator: DownloadCoordinator) { self.coordinator = coordinator }

    var doneCount: Int { states.values.filter { if case .done = $0 { return true }; return false }.count }
    var failedCount: Int { states.values.filter { if case .failed = $0 { return true }; return false }.count }

    /// Returns false when nothing was started (a run is still going, or it is still stopping).
    @discardableResult
    func start(items: [DownloadFeedItem], title: String, source: String, program: Program, profile: String, quality: PlaylistQuality = .best, overrides: [String: PlaylistQuality] = [:], isRetry: Bool = false) -> Bool {
        guard !running, !items.isEmpty else { return false }
        if stateSource != source { states = [:]; stateSource = source }
        // Entries stopped by a cancel are asked for again; finished ones stay finished.
        for (id, s) in states { if case .skipped(let why) = s, why == "Cancelled" { states[id] = nil } }
        for item in items where states[item.id] == nil || { if case .failed = states[item.id]! { return true }; return false }() { states[item.id] = .waiting }
        let pending = items.filter { states[$0.id] == .waiting }
        guard !pending.isEmpty else { return false }
        running = true
        let packages = coordinator.packages
        let pkg = packages.package(withSource: source) ?? packages.create(name: title, members: [], source: source)?.package
        packageID = pkg?.id
        if let pkg, !isRetry { packages.noteChosen(pending.filter { packages.entry($0.id + "#0", in: pkg.id) == nil }.count, in: pkg.id) }
        // The collection knows every chosen entry from now on, not only the finished ones: waiting, failed and cancelled entries are kept (and survive a relaunch).
        if let pkg { for item in pending { packages.setEntry(item.id + "#0", title: item.title, state: .queued, in: pkg.id) } }
        task = Task { [weak self] in
            guard let self else { return }
            var index = 0
            await withTaskGroup(of: Void.self) { group in
                func next() { guard index < pending.count else { return }; let item = pending[index]; index += 1; group.addTask { @MainActor in await self.save(item, source: source, program: program, profile: profile, quality: overrides[item.id] ?? quality) } }
                for _ in 0..<Self.concurrency { next() }
                while await group.next() != nil { if Task.isCancelled { continue }; next() }
            }
            self.running = false
        }
        return true
    }

    func retryFailed(items: [DownloadFeedItem], title: String, source: String, program: Program, profile: String, quality: PlaylistQuality = .best, overrides: [String: PlaylistQuality] = [:]) {
        let failed = items.filter { if case .failed = states[$0.id] ?? .waiting { return true }; return false }
        for f in failed { states[f.id] = nil }
        start(items: failed, title: title, source: source, program: program, profile: profile, quality: quality, overrides: overrides, isRetry: true)
    }

    func cancel() {
        task?.cancel()
        for (id, op) in ops { op.cancel(); if case .saving = states[id] ?? .waiting { states[id] = .failed("Cancelled") } }
        for (id, s) in states where s == .waiting || s == .looking {
            states[id] = .skipped("Cancelled")
            // Entries that never got a turn are remembered as cancelled too (the ones already running record their own end).
            if s == .waiting, let pkg = packageID, let e = coordinator.packages.entry(id + "#0", in: pkg) { coordinator.packages.setEntry(id + "#0", title: e.title, state: .cancelled, in: pkg) }
        }
        // `running` stays true until the task group has drained: a new run cannot overlap the stopping one.
    }

    /// Mirrors an entry's state into the collection so it is remembered (see `DownloadPackage.entries`).
    private func note(_ item: DownloadFeedItem, _ state: CollectionEntry.State?, _ reason: String? = nil) {
        guard let pkg = packageID else { return }
        if let state { coordinator.packages.setEntry(item.id + "#0", title: item.title, state: state, reason: reason, in: pkg) }
        else { coordinator.packages.clearEntry(item.id + "#0", in: pkg) }
    }

    private func save(_ item: DownloadFeedItem, source: String, program: Program, profile: String, quality: PlaylistQuality) async {
        await run(item, source: source, program: program, profile: profile, quality: quality)
        // Whatever way it ended, the collection holds the outcome.
        switch states[item.id] {
        case .failed(let why)?: note(item, .failed, why)
        case .skipped(let why)? where why == "Cancelled": note(item, .cancelled)
        case .skipped?: note(item, nil)
        case .done?: note(item, nil)
        default: break
        }
    }

    private func run(_ item: DownloadFeedItem, source: String, program: Program, profile: String, quality: PlaylistQuality) async {
        guard !Task.isCancelled else { states[item.id] = .skipped("Cancelled"); return }
        guard let page = item.link else { states[item.id] = .failed("This entry has no address."); return }
        let key = item.id + "#0"
        if coordinator.packages.isCollected(key, source: source) { states[item.id] = .skipped("Already in this collection"); return }
        // The same permission the single-video flow asks for, per site: an entry on a site that was not allowed is not looked up.
        guard MediaConsentStore.shared.isAllowed(.externalExtractor(program.identity), host: page.host, profile: profile, isPrivate: false) else {
            states[item.id] = .failed("Your extractor is not allowed for \(page.host ?? "this site"): allow it for the site or the profile and retry."); return
        }
        states[item.id] = .looking
        note(item, .working)
        do {
            let media = try await ExtractorBroker.shared.lookup(page: page, path: program.path, identity: program.identity, profile: profile, isPrivate: false, allowLocal: HTTPRequestPolicy.debugFixtureAllowsLocalPageOrigin)
            guard case .tracks = media.shape else { states[item.id] = .failed("This entry is a stream: open it on its own to choose a quality."); return }
            let options = DownloadPlanner.options(for: media)
            let pick = quality.choose(from: options)
            guard let chosen = pick, let choice = chosen.choice else { states[item.id] = .failed("Nothing this browser can save was found for this entry."); return }
            var s = media; s.isPrivate = false
            let op = SourceSaveOperation(source: s, choice: choice, name: item.title, coordinator: coordinator, profileTag: MediaStore.profileTag(profile))
            op.pickVideo = chosen.representation; op.pickAudio = chosen.audio; op.pickStreamID = chosen.streamID
            guard !Task.isCancelled else { states[item.id] = .skipped("Cancelled"); return }          // stopped while the lookup was running
            ops[item.id] = op
            states[item.id] = .saving(0)
            op.start()
            while !op.stage.isFinal {
                if Task.isCancelled { op.cancel(); break }
                switch op.stage {
                case .downloading(let f): states[item.id] = .saving(f * 0.9)
                case .converting(let f): states[item.id] = .saving(0.9 + f * 0.1)
                default: break
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            ops[item.id] = nil
            switch op.stage {
            case .done(let file):
                states[item.id] = .done(file.lastPathComponent)
                // The record of the finished file: the operation's own, else the completed download that holds exactly that file.
                let recordID = op.resultRecordID ?? coordinator.ledger.records.values.first(where: { $0.state == .completed && $0.file.destinationPath == file.path })?.id
                    ?? coordinator.recordProducedFile(file, source: item.link, isPrivate: false)          // a saved file always becomes a member, so it is never asked for again
                if let id = recordID, let pkg = packageID {
                    coordinator.packages.add([id], to: pkg)
                    coordinator.packages.recordIdentity(key, task: id, in: pkg)
                    coordinator.ledger.update(id) { $0.engineMetadata["playlist"] = String(source.prefix(120)); $0.engineMetadata["entry"] = String(item.id.prefix(120)) }
                }
            case .failed(let why): states[item.id] = .failed(why)
            default: states[item.id] = .skipped("Cancelled")
            }
        } catch is CancellationError { states[item.id] = .skipped("Cancelled") }
        catch { states[item.id] = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)") }
    }
}
