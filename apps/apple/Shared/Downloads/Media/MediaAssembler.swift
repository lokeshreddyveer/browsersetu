import Foundation
import AVFoundation

/// A link in the manifest stopped working (the server refused it as signed and out of date, or said the file is gone). The download is not failed: the manifest is read again for fresh
/// addresses first.
struct MediaSourceExpired: Error { var stream: Int; var index: Int; var detail: HTTPDownloadError }

/// Fetches every segment of a plan into the task's folder, a few at a time, through the shared connection budget. A segment is in the folder whole or not at all, and a journal beside them
/// says which ones were checked, so what is there on a restart is exactly what is finished.
final class MediaDownloader: @unchecked Sendable {
    let fetcher: MediaFetcher, plan: MediaPlan, dir: URL, taskID: UUID, concurrency: Int
    /// Called after each segment: how many are done now, and the bytes fetched in this run.
    var onProgress: (@Sendable (_ done: Int, _ bytes: Int64) -> Void)?
    /// Called after each segment with that track's own count.
    var onTrack: (@Sendable (_ stream: Int, _ done: Int, _ total: Int) -> Void)?
    /// Called each time a piece is tried again, with the number of retries so far.
    var onRetry: (@Sendable (_ retries: Int) -> Void)?
    let circuit = MediaCircuit()
    private let lock = NSLock()
    private var doneCount = 0
    private var fetchedBytes: Int64 = 0
    private var retries = 0
    private var trackDone: [Int: Int] = [:]
    private var journal: [String: JournalEntry] = [:]
    private var journalActive = false
    /// The most one streaming download may fetch, and the free space below which it stops instead of filling the disk.
    static let maxTotalBytes: Int64 = 64 * 1024 * 1024 * 1024
    nonisolated(unsafe) static var minimumFreeSpace: Int64 = 200 * 1024 * 1024
    private func addBytes(_ n: Int64) -> Int64 { lock.lock(); defer { lock.unlock() }; fetchedBytes += n; return fetchedBytes }
    static let attempts = 3
    /// Tests shorten the wait between tries.
    nonisolated(unsafe) static var backoffScale = 1.0
    /// Tests hold a segment here to make a pause, a limit or a crash land at an exact point.
    nonisolated(unsafe) static var beforeFetch: (@Sendable (_ stream: Int, _ index: Int) async -> Void)?

    init(fetcher: MediaFetcher, plan: MediaPlan, dir: URL, taskID: UUID, concurrency: Int) {
        self.fetcher = fetcher; self.plan = plan; self.dir = dir; self.taskID = taskID; self.concurrency = max(1, min(concurrency, 6))
    }

    struct Item: Sendable { var stream: Int; var index: Int; var segment: MediaSegment }

    /// One line of the journal: track, segment (-1 is the initialization segment), size and SHA-256 of the file as it was kept.
    struct JournalEntry: Codable, Equatable, Sendable { var s: Int; var i: Int; var n: Int64; var h: String }
    private static func key(_ s: Int, _ i: Int) -> String { "\(s):\(i)" }

    var items: [Item] {
        plan.streams.enumerated().flatMap { (k, s) -> [Item] in
            (s.initSegment.map { [Item(stream: k, index: -1, segment: $0)] } ?? []) + s.segments.enumerated().map { Item(stream: k, index: $0.offset, segment: $0.element) }
        }
    }

    /// The same items in the order they are fetched: initialization segments first, then the tracks side by side.
    var orderedItems: [Item] {
        let order = MediaScheduling.order(sizes: plan.streams.map { $0.segments.count }, hasInit: plan.streams.map { $0.initSegment != nil })
        return order.map { o in
            let s = plan.streams[o.stream]
            return Item(stream: o.stream, index: o.index, segment: o.index == -1 ? s.initSegment! : s.segments[o.index])
        }
    }

    /// Whether a segment's file is already complete. Once the journal is in use a file counts only if the journal vouches for it at this size; a plan from before the journal existed
    /// is judged by size alone (and is fetched again when the journal is started).
    func isDone(_ item: Item) -> Bool {
        let file = MediaStore.segmentFile(in: dir, stream: item.stream, index: item.index)
        guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0 else { return false }
        if let length = item.segment.length, Int64(size) != length { return false }
        lock.lock(); let active = journalActive; let entry = journal[Self.key(item.stream, item.index)]; lock.unlock()
        if active { return entry.map { $0.n == Int64(size) } ?? false }
        return true
    }

    // MARK: Journal

    private func loadJournal() {
        var loaded: [String: JournalEntry] = [:]
        if let data = try? Data(contentsOf: MediaStore.journalFile(in: dir)), data.count < 256_000_000 {
            for line in data.split(separator: UInt8(ascii: "\n")) {
                if let e = try? JSONDecoder().decode(JournalEntry.self, from: Data(line)) { loaded[Self.key(e.s, e.i)] = e }
            }
        }
        lock.lock(); journal = loaded; journalActive = true; lock.unlock()
        // A last line cut short by a crash would have the next record glued to it.
        if let data = try? Data(contentsOf: MediaStore.journalFile(in: dir)), let last = data.last, last != 0x0A { rewriteJournal() }
    }

    private func rewriteJournal() {
        lock.lock(); let entries = journal.values.sorted { ($0.s, $0.i) < ($1.s, $1.i) }; lock.unlock()
        var out = Data()
        for e in entries { if let line = try? JSONEncoder().encode(e) { out.append(line); out.append(0x0A) } }
        try? out.write(to: MediaStore.journalFile(in: dir), options: .atomic)
    }

    private func record(_ entry: JournalEntry) {
        lock.lock(); journal[Self.key(entry.s, entry.i)] = entry; lock.unlock()
        guard var line = try? JSONEncoder().encode(entry) else { return }
        line.append(0x0A)
        lock.lock(); defer { lock.unlock() }
        if let h = try? FileHandle(forWritingTo: MediaStore.journalFile(in: dir)) {
            defer { try? h.close() }
            _ = try? h.seekToEnd(); try? h.write(contentsOf: line)
        } else { try? line.write(to: MediaStore.journalFile(in: dir)) }
    }

    /// Everything the journal vouches for is checked again against the file: a size that matches is not enough. A file that fails is deleted so it is fetched again; the rest are kept.
    private func verifyKept() async throws {
        lock.lock(); let entries = Array(journal.values); lock.unlock()
        var dropped = false
        for e in entries {
            try Task.checkCancellation()
            let file = MediaStore.segmentFile(in: dir, stream: e.s, index: e.i)
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
            if size == e.n, (try? MediaSegmentCheck.digest(of: file)) == e.h { continue }
            try? FileManager.default.removeItem(at: file)
            lock.lock(); journal[Self.key(e.s, e.i)] = nil; lock.unlock()
            dropped = true
            await Task.yield()
        }
        if dropped { rewriteJournal() }
    }

    func run() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Pieces left half-written by an interrupted run are never kept.
        if let leftovers = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in leftovers where f.pathExtension == "part" { try? FileManager.default.removeItem(at: f) }
        }
        loadJournal()
        try await verifyKept()
        if !FileManager.default.fileExists(atPath: MediaStore.journalFile(in: dir).path) { rewriteJournal() }
        let all = items
        let finished = all.filter { isDone($0) }                 // asked with no lock held: isDone takes it
        let todo = orderedItems.filter { !isDone($0) }
        lock.lock()
        doneCount = finished.count
        trackDone = [:]
        for it in finished { trackDone[it.stream, default: 0] += 1 }
        lock.unlock()
        let already = finished.count
        onProgress?(already, 0)
        for k in plan.streams.indices { onTrack?(k, trackDone[k] ?? 0, plan.streams[k].segments.count + (plan.streams[k].initSegment == nil ? 0 : 1)) }
        guard !todo.isEmpty else { return }
        try await withThrowingTaskGroup(of: (Int, Int64).self) { group in
            var next = todo.makeIterator()
            var running = 0
            func launch() -> Bool {
                guard let item = next.next() else { return false }
                group.addTask { [self] in (item.stream, try await fetch(item)) }
                running += 1
                return true
            }
            while running < concurrency, launch() {}
            while let (stream, bytes) = try await group.next() {
                running -= 1
                lock.lock(); doneCount += 1; trackDone[stream, default: 0] += 1; let n = doneCount, t = trackDone[stream] ?? 0; lock.unlock()
                onProgress?(n, bytes)
                onTrack?(stream, t, plan.streams[stream].segments.count + (plan.streams[stream].initSegment == nil ? 0 : 1))
                try Task.checkCancellation()
                _ = launch()
            }
        }
    }

    /// The same files on the manifest's other servers, if it listed any.
    private func addresses(for item: Item) -> [String] {
        var out = [item.segment.url]
        for (primary, alternates) in plan.streams[item.stream].mirrors ?? [:] where item.segment.url.hasPrefix(primary) {
            // The prefix must end at a path boundary: "https://a.com/video" is not the start of "https://a.com/video2/x".
            let rest = item.segment.url.dropFirst(primary.count)
            guard primary.hasSuffix("/") || rest.hasPrefix("/") else { continue }
            out += alternates.map { $0 + rest }.filter { URL(string: $0)?.scheme?.hasPrefix("http") == true }
        }
        return out
    }

    private static let expiredCodes: Set<String> = ["http:401", "http:403", "http:410"]

    private func fetch(_ item: Item) async throws -> Int64 {
        await Self.beforeFetch?(item.stream, item.index)
        let file = MediaStore.segmentFile(in: dir, stream: item.stream, index: item.index)
        let container = plan.streams[item.stream].container
        let urls = addresses(for: item)
        var lastError: Error = CancellationError()
        for attempt in 0..<Self.attempts {
            try Task.checkCancellation()
            var segment = item.segment
            segment.url = urls[attempt % urls.count]
            let host = URL(string: segment.url)?.host ?? ""
            // A server that has failed many times in a row is left alone instead of being asked by every piece in turn.
            if circuit.isOpen(host: host) { throw HTTPDownloadError(info: DownloadFailureInfo(code: "media:host-failing", reason: "The server keeps failing, so the download stopped. Try again later.", retryable: true)) }
            // The same shared budget every other download uses: a segment waits for a connection to its host, it never opens one of its own beyond that.
            while !ConnectionBudget.shared.acquire(host: host, task: taskID) {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            // The connection is held only while bytes move: not during a wait for a retry or for the speed limit.
            if let free = DiskSpace.available(at: dir), free < Self.minimumFreeSpace { ConnectionBudget.shared.release(host: host, task: taskID); throw HTTPDownloadError(info: DownloadFailureInfo(code: "media:disk", reason: "There is not enough free space to keep downloading.", retryable: true)) }
            do {
                let receipt: MediaFetcher.Receipt
                do { receipt = try await fetcher.receipt(segment, to: file, container: container, isInit: item.index == -1); ConnectionBudget.shared.release(host: host, task: taskID) }
                catch { ConnectionBudget.shared.release(host: host, task: taskID); throw error }
                circuit.record(host: host, success: true)
                record(JournalEntry(s: item.stream, i: item.index, n: receipt.size, h: receipt.sha256))
                let total = addBytes(receipt.size)
                if total > Self.maxTotalBytes { throw HTTPDownloadError(info: DownloadFailureInfo(code: "media:total", reason: "This stream is larger than the limit for one download.", retryable: false)) }
                // Held to the shared speed limit by waiting after the segment: the limit is honoured over time, at segment granularity (a limit is not applied inside a segment).
                let wait = BandwidthController.shared.reserve(task: taskID, bytes: Int(min(receipt.size, Int64(Int32.max))))
                if wait > 0 { try await Task.sleep(nanoseconds: UInt64(min(wait, 60) * 1_000_000_000)) }
                return receipt.size
            } catch {
                lastError = error
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                let info = HTTPResponseRules.failure(for: error)
                circuit.record(host: host, success: false)
                // A link that no longer works is not tried again here: the manifest is read again for new ones.
                if Self.expiredCodes.contains(info.info.code) { throw MediaSourceExpired(stream: item.stream, index: item.index, detail: info) }
                guard info.info.retryable, attempt + 1 < Self.attempts else { throw info }
                lock.lock(); retries += 1; let n = retries; lock.unlock()
                onRetry?(n)
                let delay = MediaBackoff.delay(attempt: attempt, retryAfter: info.retryAfter) * Self.backoffScale
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        throw HTTPResponseRules.failure(for: lastError)
    }
}

// MARK: - Putting the segments together

enum MediaAssembleError: Error, LocalizedError, Equatable {
    case missing, mixed, unplayable(String), cannotCombine(String), noSpace
    var errorDescription: String? {
        switch self {
        case .missing: "A downloaded piece of the stream is missing."
        case .mixed: "These streams use formats that cannot be combined into one file."
        case .unplayable(let why): "The finished file could not be read back: \(why)."
        case .cannotCombine(let why): "The streams could not be combined into one file: \(why)."
        case .noSpace: "There is not enough free space to put the finished file together. The downloaded pieces are kept; free some space and try again."
        }
    }
}

/// A file written beside the video: a subtitle track, or audio that could not be put in the same MP4.
struct MediaSidecar: Sendable {
    var url: URL
    var language: String?
    /// What goes between the video's name and the extension: "te", "en.forced".
    var suffix: String
    var ext: String
}

/// What the finished file was checked to hold.
struct MediaOutputReport: Sendable, Equatable {
    var videoTracks = 0
    var audioTracks = 0
    var audioLanguages: [String?] = []
    var duration = 0.0
    var expectedDuration: Double?
    var notes: [String] = []
}

struct MediaOutput: Sendable {
    var file: URL
    /// Said to the person when the result is not the plain thing they expected.
    var note: String?
    /// Files that go beside the main file.
    var sidecars: [MediaSidecar]
    var report: MediaOutputReport?
}

enum MediaAssembler {
    /// Joins init + segments of one stream into one file by streaming copy.
    static func join(_ stream: MediaStream, index k: Int, dir: URL, to out: URL, webVTT: Bool) throws {
        var files: [URL] = []
        if stream.initSegment != nil { files.append(MediaStore.segmentFile(in: dir, stream: k, index: -1)) }
        files += stream.segments.indices.map { MediaStore.segmentFile(in: dir, stream: k, index: $0) }
        for f in files { guard FileManager.default.fileExists(atPath: f.path) else { throw MediaAssembleError.missing } }
        if webVTT || stream.container.isText {
            // Text is joined by its cues, not by its bytes: one header, every segment's times on one clock, a cue repeated in neighbouring segments written once.
            var datas: [Data] = []
            for f in files {
                try Task.checkCancellation()
                let data = try Data(contentsOf: f)
                if stream.container == .ttml { datas.append(Data(try TTMLConverter.toWebVTT(data).text.utf8)) } else { datas.append(data) }
            }
            try Data(WebVTT.join(datas).text.utf8).write(to: out, options: .atomic)
            return
        }
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let writer = try FileHandle(forWritingTo: out)
        defer { try? writer.close() }
        for file in files {
            try Task.checkCancellation()
            let reader = try FileHandle(forReadingFrom: file)
            defer { try? reader.close() }
            while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty { try writer.write(contentsOf: chunk) }
        }
    }

    struct Group { var key: String; var streams: [Int]; var kind: MediaStream.Kind; var language: String?; var label: String }

    /// The finished file, built in the task's folder. Nothing is placed anywhere else here.
    static func assemble(_ plan: MediaPlan, dir: URL) async throws -> MediaOutput {
        let media = plan.streams.enumerated().filter { !$0.element.container.isText && $0.element.kind != .subtitle }
        let text = plan.streams.enumerated().filter { $0.element.container.isText || $0.element.kind == .subtitle }
        var notes: [String] = []
        var sidecars: [MediaSidecar] = []
        var joined: [Int: URL] = [:]

        // Free space for the file: about the size of the pieces again, and a little over.
        let pieces = plan.streams.indices.reduce(Int64(0)) { sum, k in
            sum + ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]))?.filter { $0.lastPathComponent.hasPrefix("s\(k)-") && $0.pathExtension == "seg" }.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) } ?? 0)
        }
        if let free = DiskSpace.available(at: dir), free < pieces * 2 + pieces / 20 + 50 * 1024 * 1024 { throw MediaAssembleError.noSpace }

        for (k, s) in plan.streams.enumerated() {
            try Task.checkCancellation()
            let out = dir.appendingPathComponent("joined-\(k).\(s.container.isText ? "vtt" : s.container.fileExtension)")
            do { try join(s, index: k, dir: dir, to: out, webVTT: s.container.isText) }
            catch let e as MediaError { throw MediaAssembleError.cannotCombine(e.errorDescription ?? "a subtitle file could not be read") }
            catch where isOutOfSpace(error) { throw MediaAssembleError.noSpace }
            joined[k] = out
        }
        for (k, s) in text { if let j = joined[k] { sidecars.append(MediaSidecar(url: j, language: s.language, suffix: MediaSubtitleNaming.suffix(for: s), ext: "vtt")) } }

        if media.isEmpty {
            guard let only = text.first, text.count == 1, let j = joined[only.offset] else { throw MediaAssembleError.mixed }
            return MediaOutput(file: j, note: nil, sidecars: [], report: nil)
        }
        let containers = Set(media.map { $0.element.container })
        if containers == [.mpegTS] {
            guard media.count == 1, let j = joined[media[0].offset] else { throw MediaAssembleError.mixed }
            return MediaOutput(file: j, note: "Saved as an MPEG transport stream (.ts). Most players open it; it is not an MP4.", sidecars: sidecars, report: nil)
        }
        guard containers == [.fragmentedMP4] else { throw MediaAssembleError.mixed }

        // Parts of one track (cut at a discontinuity or a period) go back together on one track of the output; separate tracks stay separate.
        var groups: [Group] = []
        for (k, s) in media {
            let key = s.trackKey ?? s.id
            if let at = groups.firstIndex(where: { $0.key == key }) { groups[at].streams.append(k) }
            else { groups.append(Group(key: key, streams: [k], kind: s.kind, language: s.language, label: s.label)) }
        }
        let target = dir.appendingPathComponent("output.mp4")
        try? FileManager.default.removeItem(at: target)
        let expected = groups.map { g in g.streams.reduce(0.0) { $0 + plan.streams[$1].segments.reduce(0) { $0 + $1.duration } } }.max()
        let frameRate = media.compactMap { $0.element.frameRate }.first
        let segmentCount = groups.map { g in g.streams.reduce(0) { $0 + plan.streams[$1].segments.count } }.max() ?? 0
        let allSegments = media.flatMap { $0.element.segments }
        do {
            do { try await combine(groups, joined: joined, to: target, type: target.pathExtension.lowercased() == "m4a" ? .m4a : .mp4) } catch let e as MediaAssembleError { throw e } catch is CancellationError { throw CancellationError() } catch { throw MediaAssembleError.cannotCombine("while combining: " + describe(error)) }
            let report: MediaOutputReport
            do { report = try await validate(target, groups: groups, expected: expected, tolerance: MediaTimeline.durationTolerance(segmentCount: segmentCount, segments: allSegments, frameRate: frameRate), syncTolerance: MediaTimeline.syncTolerance(frameRate: frameRate)) } catch let e as MediaAssembleError { throw e } catch is CancellationError { throw CancellationError() } catch { throw MediaAssembleError.cannotCombine("while checking the result: " + describe(error)) }
            for g in groups { for k in g.streams { for n in plan.streams[k].notes ?? [] where !notes.contains(n) { notes.append(n) } } }
            var r = report; r.notes += notes
            return MediaOutput(file: target, note: r.notes.isEmpty ? nil : r.notes.joined(separator: " "), sidecars: sidecars, report: r)
        } catch {
            if error is CancellationError { try? FileManager.default.removeItem(at: target); throw error }
            try? FileManager.default.removeItem(at: target)
            if isOutOfSpace(error) { throw MediaAssembleError.noSpace }
            // The system's MP4 writer could not hold every audio track: the main file is made with the first, and each other one is exported beside it, so none is dropped.
            let audio = groups.filter { $0.kind == .audio }
            if audio.count > 1, let primary = audio.first {
                let rest = Array(audio.dropFirst())
                let reduced = groups.filter { g in g.kind != .audio || g.key == primary.key }
                if (try? await combine(reduced, joined: joined, to: target, type: target.pathExtension.lowercased() == "m4a" ? .m4a : .mp4)) != nil, (try? await validate(target, groups: reduced, expected: expected, tolerance: MediaTimeline.durationTolerance(segmentCount: segmentCount, segments: allSegments, frameRate: frameRate), syncTolerance: MediaTimeline.syncTolerance(frameRate: frameRate))) != nil {
                    var extras: [MediaSidecar] = []
                    for (n, g) in rest.enumerated() {
                        let out = dir.appendingPathComponent("extra-audio-\(n).m4a")
                        try? FileManager.default.removeItem(at: out)
                        if (try? await combine([g], joined: joined, to: out, type: .m4a)) != nil {
                            extras.append(MediaSidecar(url: out, language: g.language, suffix: DownloadFilename.sanitize(g.language ?? g.label) ?? "audio\(n + 2)", ext: "m4a"))
                        } else { throw MediaAssembleError.cannotCombine("the audio track \(g.label) could not be saved") }
                    }
                    return MediaOutput(file: target, note: "The extra audio tracks could not be placed in the same MP4, so each is saved as its own audio file beside it.", sidecars: sidecars + extras, report: nil)
                }
                try? FileManager.default.removeItem(at: target)
            }
            // A single fragmented MP4 is still a real, playable file: it is kept, and said to be what it is, instead of failing a download that finished.
            var lengthFailed = false
            if case .unplayable = (error as? MediaAssembleError) ?? .missing { lengthFailed = true }
            if !lengthFailed, groups.count == 1, groups[0].streams.count == 1, let only = joined[groups[0].streams[0]], (try? await validateBasic(only)) != nil {
                let fallback = dir.appendingPathComponent("output-fragmented.mp4")
                try? FileManager.default.removeItem(at: fallback)
                try FileManager.default.moveItem(at: only, to: fallback)
                return MediaOutput(file: fallback, note: "Saved as a fragmented MP4: it plays in most players, but some editors may not open it.", sidecars: sidecars, report: nil)
            }
            if let e = error as? MediaAssembleError { throw e }
            throw MediaAssembleError.cannotCombine((error as? LocalizedError)?.errorDescription ?? describe(error))
        }
    }

    /// A system error with its code, since "The operation could not be completed" alone tells nobody what to do.
    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var text = "\(ns.localizedDescription) (\(ns.domain) \(ns.code)"
        if let inner = ns.userInfo[NSUnderlyingErrorKey] as? NSError { text += ", \(inner.domain) \(inner.code)" }
        return text + ")"
    }

    static func isOutOfSpace(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        while let e = current {
            if (e.domain == NSCocoaErrorDomain && (e.code == NSFileWriteOutOfSpaceError)) || (e.domain == NSPOSIXErrorDomain && e.code == Int(ENOSPC)) { return true }
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// "en", "eng", "en-US" to the tag the MP4 writer expects.
    static func languageTag(_ tag: String?) -> String? {
        guard let t = tag?.trimmingCharacters(in: .whitespaces), (2...35).contains(t.count), t.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        return t
    }

    /// Combines the video and audio of one or more fragmented MP4 files (and the parts of each) into one ordinary MP4 without re-encoding. Parts are placed one after another, and the tracks
    /// of one part are kept at the offsets they had to each other, so a sound that starts later than the picture still starts later.
    static func combine(_ groups: [Group], joined: [Int: URL], to target: URL, type: AVFileType = .mp4) async throws {
        let composition = AVMutableComposition()
        var tracks: [String: AVMutableCompositionTrack] = [:]
        var cursor = CMTime.zero
        var added = 0
        // A track is valid only while the asset it came from is alive, so every asset is held until the composition has been exported.
        var assets: [AVURLAsset] = []
        defer { assets.removeAll() }
        let partCount = groups.map { $0.streams.count }.max() ?? 0
        for p in 0..<partCount {
            try Task.checkCancellation()
            var loaded: [(group: Group, track: AVAssetTrack, range: CMTimeRange)] = []
            for g in groups where p < g.streams.count {
                guard let url = joined[g.streams[p]] else { throw MediaAssembleError.missing }
                let asset = AVURLAsset(url: url)
                assets.append(asset)
                let whole = try await asset.load(.duration)
                for t in try await asset.load(.tracks) where t.mediaType == .video || t.mediaType == .audio {
                    if type == .m4a && t.mediaType != .audio { continue }
                    // Where the track starts and how long it is. A track whose own range cannot be read is taken to span the file, as a plain concatenation would have it.
                    let range = (try? await t.load(.timeRange)).flatMap { $0.duration.isNumeric && $0.duration > .zero && $0.start.isNumeric ? $0 : nil } ?? CMTimeRange(start: .zero, duration: whole)
                    guard range.duration.isNumeric, range.duration > .zero else { continue }
                    loaded.append((g, t, range))
                }
            }
            guard var base = loaded.first?.range.start else { continue }
            for l in loaded where l.range.start < base { base = l.range.start }
            var length = CMTime.zero
            for l in loaded {
                let key = "\(l.group.key)|\(l.track.mediaType.rawValue)"
                let target: AVMutableCompositionTrack
                if let existing = tracks[key] { target = existing }
                else {
                    guard let made = composition.addMutableTrack(withMediaType: l.track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw MediaAssembleError.cannotCombine("the system could not make a track") }
                    if l.track.mediaType == .video { made.preferredTransform = (try? await l.track.load(.preferredTransform)) ?? .identity }
                    if l.track.mediaType == .audio, let tag = languageTag(l.group.language) {
                        made.extendedLanguageTag = tag
                        // Players that read only the MP4 header's three-letter code (ISO 639-2) would otherwise see "und".
                        if let three = Locale.LanguageCode(String(tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")).identifier(.alpha3) as String?, three.count == 3 { made.languageCode = three }
                    }
                    tracks[key] = made; target = made
                }
                let offset = l.range.start - base
                try target.insertTimeRange(l.range, of: l.track, at: cursor + offset)
                added += 1
                let end = offset + l.range.duration
                if end > length { length = end }
            }
            cursor = cursor + length
        }
        guard added > 0 else { throw MediaAssembleError.cannotCombine("it holds no video or audio") }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { throw MediaAssembleError.cannotCombine("the system cannot export this") }
        export.outputURL = target
        export.outputFileType = type
        export.shouldOptimizeForNetworkUse = false
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in export.exportAsynchronously { c.resume() } }
        } onCancel: { export.cancelExport() }
        try Task.checkCancellation()
        guard export.status == .completed else {
            if let e = export.error, isOutOfSpace(e) { throw MediaAssembleError.noSpace }
            throw MediaAssembleError.cannotCombine(export.error.map(describe) ?? "the export did not finish")
        }
    }

    /// The file reads back as media: it has a track, and a duration.
    static func validateBasic(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.load(.tracks)
        let duration = try await asset.load(.duration)
        guard !tracks.isEmpty else { throw MediaAssembleError.unplayable("it has no tracks") }
        guard duration.isNumeric, duration.seconds > 0 else { throw MediaAssembleError.unplayable("it has no length") }
    }

    /// The finished file holds what was asked for: the tracks, a length that matches the manifest (within what the manifest's own rounding allows), and sound and picture of the same length.
    static func validate(_ url: URL, groups: [Group], expected: Double?, tolerance: Double, syncTolerance: Double) async throws -> MediaOutputReport {
        try await validateBasic(url)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let video = try await asset.loadTracks(withMediaType: .video), audio = try await asset.loadTracks(withMediaType: .audio)
        var report = MediaOutputReport(videoTracks: video.count, audioTracks: audio.count, duration: duration, expectedDuration: expected)
        let wantVideo = groups.contains { $0.kind == .video || $0.kind == .muxed } ? 1 : 0
        let wantAudio = groups.filter { $0.kind == .audio }.count + (groups.contains { $0.kind == .muxed } ? 1 : 0)
        // A muxed stream that turns out to have no sound, or a video that was only audio, is the manifest's own doing; a missing separate track is not.
        let separateAudio = groups.filter { $0.kind == .audio }.count
        if video.count < wantVideo { throw MediaAssembleError.unplayable("the picture is missing from the result") }
        if audio.count < separateAudio { throw MediaAssembleError.unplayable("\(separateAudio - audio.count) of the audio tracks are missing from the result") }
        if audio.count < wantAudio { report.notes.append("The video has no sound track.") }
        for t in audio { report.audioLanguages.append(try? await t.load(.extendedLanguageTag)) }
        if let expected, duration < expected - tolerance {
            throw MediaAssembleError.unplayable(String(format: "it is %.1f seconds shorter than the playlist says (%.1f s), so part of it is missing", expected - duration, expected))
        }
        if let expected, duration > expected + tolerance { report.notes.append(String(format: "The file is %.1f seconds longer than the playlist says.", duration - expected)) }
        // Sound against picture: the same two audio frames and video frames at either end that the length check allows.
        if let v = video.first {
            let vr = try await v.load(.timeRange)
            for (n, a) in audio.enumerated() {
                let ar = try await a.load(.timeRange)
                let shorter = vr.end.seconds - ar.end.seconds
                if abs(shorter) > syncTolerance { report.notes.append(String(format: "Audio track %d is %.1f seconds %@ than the video.", n + 1, abs(shorter), shorter > 0 ? "shorter" : "longer")) }
                let late = ar.start.seconds - vr.start.seconds
                if abs(late) > syncTolerance { report.notes.append(String(format: "Audio track %d starts %.2f seconds %@ the video.", n + 1, abs(late), late > 0 ? "after" : "before")) }
            }
        }
        return report
    }
}
