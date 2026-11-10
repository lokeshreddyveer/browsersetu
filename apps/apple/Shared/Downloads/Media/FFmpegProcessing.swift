#if os(macOS)
import Foundation

// Media processing that the system's own media engine cannot do: it cannot open WebM, Matroska, Ogg or Opus at all, so separate WebM picture and sound could not be joined and sound could not be
// taken from them. The optional media processing tool (a minimal LGPL FFmpeg and FFprobe, installed on request by the same verified installer as the extractor, see MediaToolsInstaller) does these.
//
// Every operation is a typed plan run by the app's own launcher (own process group, fixed environment, time limit, cancellation that ends the whole tree). It reads and writes local files only (the
// tool is built without network support). The output is written beside its final name, checked with FFprobe, and only then given its real name, so a half-written or wrong file is never shown as done.

/// Counts the jobs using an installed tool. Removing the tool closes the gate (no new job starts), waits until the running ones have finished, and only then deletes it, so an executable is never removed
/// from under a running process and a job never half-works with a tool that is going away.
final class ToolLeases: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    /// How many removals/updates hold the gate shut; it opens only when every one of them is done (overlapping ones must not open it early).
    private var closers = 0
    private var closed: Bool { closers > 0 }
    private var waiters: [CheckedContinuation<Void, Never>] = []
    final class Lease: @unchecked Sendable {
        private let owner: ToolLeases; private var released = false
        fileprivate init(_ o: ToolLeases) { owner = o }
        func release() { owner.lock.lock(); if released { owner.lock.unlock(); return }; released = true; owner.lock.unlock(); owner.end() }
        deinit { release() }
    }
    /// A lease, or nil while the tool is being removed.
    func acquire() -> Lease? { lock.lock(); defer { lock.unlock() }; if closed { return nil }; active += 1; return Lease(self) }
    var activeCount: Int { lock.lock(); defer { lock.unlock() }; return active }
    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }
    func close() { lock.lock(); closers += 1; lock.unlock() }
    func reopen() { lock.lock(); closers = max(0, closers - 1); lock.unlock() }
    /// Returns once no job holds a lease.
    func drain() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if active == 0 { lock.unlock(); c.resume() } else { waiters.append(c); lock.unlock() }
        }
    }
    fileprivate func end() {
        lock.lock(); active -= 1
        let ready = active == 0 ? waiters : []
        if active == 0 { waiters = [] }
        lock.unlock()
        ready.forEach { $0.resume() }
    }
}

enum FFmpegTool {
    static let tool = ManagedTool(resource: "BundledFFmpeg", component: "ffmpeg")
    static let leases = ToolLeases()
    /// Taken by a job for as long as it may start the tool; nil while the tool is being removed.
    static func acquire() -> ToolLeases.Lease? { leases.acquire() }
    /// Cheap: is the tool installed at the pinned version (no hashing)?
    static var isReady: Bool { tool.isPresent }

    struct Programs: Equatable, Sendable {
        var ffmpeg: URL
        var ffprobe: URL
        var version: String
    }
    /// The programs, once every file of the installed tool matches the app's pin (hashing happens off the calling thread).
    static func programs() async -> Programs? {
        guard let v = await tool.verifyAsync() else { return nil }
        let probe = v.url.deletingLastPathComponent().appendingPathComponent("ffprobe")
        guard FileManager.default.isExecutableFile(atPath: probe.path) else { return nil }
        return Programs(ffmpeg: v.url, ffprobe: probe, version: v.manifest.version)
    }
}

struct ProbedStream: Equatable, Sendable {
    var index: Int
    var kind: String            // "video", "audio", "subtitle"
    var codec: String
    var width: Int?
    var height: Int?
    var channels: Int?
    var sampleRate: Int?
    var language: String?
}

struct ProbedMedia: Equatable, Sendable {
    var formatNames: [String]
    var duration: Double?
    var size: Int64?
    var streams: [ProbedStream]
    var video: [ProbedStream] { streams.filter { $0.kind == "video" } }
    var audio: [ProbedStream] { streams.filter { $0.kind == "audio" } }
}

enum FFmpegProcessingError: Error, Equatable, LocalizedError {
    case unavailable, diskSpace(needed: Int64, available: Int64), failed(String), invalidOutput(String), badInput(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: "The media processing tool is not installed. Enable it in Settings › Downloads, then try again."
        case .diskSpace(let n, let a): "There is not enough free space: about \(ByteCountFormatter.string(fromByteCount: n, countStyle: .file)) is needed and \(ByteCountFormatter.string(fromByteCount: a, countStyle: .file)) is free."
        case .failed(let s): "The file could not be processed (\(s))."
        case .invalidOutput(let s): "The result did not pass the check and was discarded (\(s))."
        case .badInput(let s): "The downloaded file could not be read (\(s))."
        }
    }
}

enum FFmpegProcessing {
    /// Longest a single processing run may take, and how much text the tool may print back.
    static let timeLimit: TimeInterval = 4 * 3600
    static let maxPrintedBytes = 1 << 20

    // MARK: Probing

    static func probe(_ file: URL, programs: FFmpegTool.Programs) async throws -> ProbedMedia {
        let data: Data
        do {
            data = try await ExternalExtractor.run(programs.ffprobe, arguments: ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", "-protocol_whitelist", "file", "-i", file.path], timeout: 60, maxBytes: maxPrintedBytes, pool: .processing)
        } catch let e as ExtractorFailure {
            // The checking program's own words, not the extractor's.
            if case .failed(_, let msg) = e { throw FFmpegProcessingError.badInput(ExternalExtractorText.shorten(msg)) }
            if case .tooManyRunning = e { throw FFmpegProcessingError.failed("the media processing tool is busy with other files; try again in a moment") }
            throw FFmpegProcessingError.badInput(e.localizedDescription)
        }
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw FFmpegProcessingError.badInput("no details") }
        let fmt = o["format"] as? [String: Any]
        let names = ((fmt?["format_name"] as? String) ?? "").split(separator: ",").map(String.init)
        let streams: [ProbedStream] = ((o["streams"] as? [[String: Any]]) ?? []).prefix(64).map { s in
            ProbedStream(index: (s["index"] as? Int) ?? 0, kind: (s["codec_type"] as? String) ?? "", codec: (s["codec_name"] as? String) ?? "",
                         width: s["width"] as? Int, height: s["height"] as? Int, channels: s["channels"] as? Int, sampleRate: Int((s["sample_rate"] as? String) ?? ""),
                         language: (s["tags"] as? [String: Any])?["language"] as? String)
        }
        let duration = Double((fmt?["duration"] as? String) ?? "")
        return ProbedMedia(formatNames: names, duration: duration, size: Int64((fmt?["size"] as? String) ?? ""), streams: streams)
    }

    // MARK: Running

    /// Free bytes where the output goes. The "important usage" figure counts space the system could purge, so the smaller plain figure is used when both are known; 0 only when neither can be read.
    private static func freeSpace(near url: URL) -> Int64 {
        guard let v = try? url.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]) else { return 0 }
        let important = v.volumeAvailableCapacityForImportantUsage ?? 0, plain = Int64(v.volumeAvailableCapacity ?? 0)
        if important > 0, plain > 0 { return min(important, plain) }
        return max(important, plain)
    }
    /// Test hook: pretend this much is free (nil: ask the system).
    nonisolated(unsafe) static var freeSpaceForTests: Int64?
    private static func size(_ u: URL) -> Int64 { (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int64) ?? 0 }

    /// Runs FFmpeg with the given arguments, reporting progress (0…1 of `duration`) from its progress file. The output goes to `partial`; nothing here renames it.
    private static func run(_ programs: FFmpegTool.Programs, _ args: [String], duration: Double?, progress: @escaping @Sendable (Double) -> Void) async throws {
        let progressFile = FileManager.default.temporaryDirectory.appendingPathComponent("bs-ffprogress-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: progressFile) }
        let poller = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                // Only the end of the file is read: over a multi-hour run the whole file grows large and is rewritten every few hundred milliseconds.
                guard let d = duration, d > 0, let fh = try? FileHandle(forReadingFrom: progressFile) else { continue }
                defer { try? fh.close() }
                let length = (try? fh.seekToEnd()) ?? 0
                try? fh.seek(toOffset: length > 8192 ? length - 8192 : 0)
                guard let data = try? fh.readToEnd(), let text = String(data: data, encoding: .utf8) else { continue }
                if let line = text.split(separator: "\n").last(where: { $0.hasPrefix("out_time_us=") }), let us = Double(line.dropFirst(12)), us >= 0 { progress(min(0.99, us / 1_000_000 / d)) }
            }
        }
        defer { poller.cancel() }
        do {
            _ = try await ExternalExtractor.run(programs.ffmpeg, arguments: ["-nostdin", "-hide_banner", "-v", "error", "-y", "-progress", progressFile.path] + args, timeout: timeLimit, maxBytes: maxPrintedBytes, pool: .processing)
        } catch let e as ExtractorFailure {
            if case .failed(_, let msg) = e { throw FFmpegProcessingError.failed(ExternalExtractorText.shorten(msg)) }
            if case .tooManyRunning = e { throw FFmpegProcessingError.failed("the media processing tool is busy with other files; try again in a moment") }
            throw FFmpegProcessingError.failed(e.localizedDescription)
        }
    }

    private static func checkSpace(_ needed: Int64, near target: URL) throws {
        let free = freeSpaceForTests ?? freeSpace(near: target)
        // Unknown (0) is treated as too little, not as plenty: a Mac that cannot say how much room it has is not given a multi-gigabyte job.
        if free < needed + 200_000_000 { throw FFmpegProcessingError.diskSpace(needed: needed, available: free) }
    }

    /// Hidden working files carry the id of the process that made them, so a later launch can tell a leftover of a crash from a file a running copy still uses.
    static var ownerMark: String { ".bsproc-\(getpid())" }
    static func intermediateName(_ name: String, ext: String) -> String { ".\(name).intermediate\(ownerMark).\(ext)" }

    /// Removes working files (`.<name>.bsproc-<pid>.partial` / `.….bsproc-<pid>.<ext>`) that a crashed or killed run left in `dir` (top level only). A file whose process is gone is removed; one that belongs
    /// to another live process is kept. This process's own files are removed only when older than `launchedBefore` (the pid may have been reused). Returns the removed names.
    @discardableResult
    static func sweepOrphans(in dir: URL, launchedBefore: Date = Date()) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var removed: [String] = []
        for n in names where n.hasPrefix(".") {
            guard let r = n.range(of: ".bsproc-", options: .backwards) else { continue }
            let tail = n[r.upperBound...]
            let digits = tail.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, let pid = pid_t(digits) else { continue }
            let rest = tail.dropFirst(digits.count)
            guard rest == ".partial" || (rest.hasPrefix(".") && rest.count <= 12 && rest.dropFirst().allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ".") }) else { continue }   // ".flac", or ".1.flac" after a name collision
            let url = dir.appendingPathComponent(n)
            guard let a = try? fm.attributesOfItem(atPath: url.path), (a[.type] as? FileAttributeType) == .typeRegular else { continue }
            if pid == getpid() {
                if ((a[.modificationDate] as? Date) ?? .distantPast) >= launchedBefore { continue }
            } else if kill(pid, 0) == 0 || errno == EPERM { continue }
            if (try? fm.removeItem(at: url)) != nil { removed.append(n) }
        }
        return removed
    }

    /// Joins one picture track and one sound track into a single file without re-encoding. `container` is "webm" or "mkv". The result is checked (one picture, one sound, about the same length) before it is named.
    /// Returns the name the file really got: `target`, or "target (2)" if another save took it meanwhile (the name is claimed by one atomic rename; nothing is replaced).
    @discardableResult
    static func join(video: URL, audio: URL, to target: URL, container: String, programs: FFmpegTool.Programs, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try checkSpace(size(video) + size(audio), near: target)
        let vp = try await probe(video, programs: programs), ap = try await probe(audio, programs: programs)
        guard vp.video.count >= 1 else { throw FFmpegProcessingError.badInput("the picture file has no picture") }
        guard ap.audio.count >= 1 else { throw FFmpegProcessingError.badInput("the sound file has no sound") }
        let partial = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent)\(ownerMark).partial")
        try? FileManager.default.removeItem(at: partial)
        do {
            let cap = (size(video) + size(audio)) * 12 / 10 + 50_000_000          // a copy cannot honestly be much bigger than its inputs
            try await run(programs, ["-protocol_whitelist", "file", "-i", video.path, "-protocol_whitelist", "file", "-i", audio.path, "-map", "0:v:0", "-map", "1:a:0", "-c", "copy", "-fs", "\(cap)", "-f", container == "webm" ? "webm" : "matroska", partial.path], duration: max(vp.duration ?? 0, ap.duration ?? 0), progress: progress)
            let out = try await probe(partial, programs: programs)
            guard out.video.count == 1, out.audio.count == 1 else { throw FFmpegProcessingError.invalidOutput("\(out.video.count) picture and \(out.audio.count) sound tracks") }
            guard out.formatNames.contains("matroska") || out.formatNames.contains("webm") else { throw FFmpegProcessingError.invalidOutput("not a \(container) file") }
            // A copy is as long as the longer of its two inputs. When the inputs do not say how long they are, the result must at least not be empty.
            let expect = max(vp.duration ?? 0, ap.duration ?? 0)
            guard let got = out.duration, got > 0 else { throw FFmpegProcessingError.invalidOutput("no length") }
            if expect > 0, abs(got - expect) > max(2, expect * 0.02) { throw FFmpegProcessingError.invalidOutput("length \(Int(got)) s, expected \(Int(expect)) s") }
            return try FileNaming.publish(partial, as: target)        // the one step that gives it its real name
        } catch { try? FileManager.default.removeItem(at: partial); throw error }
    }

    enum AudioKind: Equatable, Sendable {
        case m4a(kbps: Int)      // AAC in an MP4 audio file
        case flac                // lossless intermediate the app's MP3 encoder reads (stereo)
    }

    /// Takes the first sound track out of any file FFmpeg can read and writes it as `kind`. Checked (one sound track, about the same length) before it is named.
    @discardableResult
    static func extractAudio(from source: URL, to target: URL, kind: AudioKind, programs: FFmpegTool.Programs, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let sp = try await probe(source, programs: programs)
        guard sp.audio.count >= 1 else { throw FFmpegProcessingError.badInput("there is no sound in this file") }
        let expected = sp.duration ?? 0
        // A rough upper bound on what is written: AAC is small; FLAC of stereo 48 kHz is under 1.2 MB per minute.
        let estimate: Int64 = { switch kind { case .m4a(let k): return Int64(expected * Double(k) * 125); case .flac: return Int64(expected / 60 * 1_300_000) } }()
        try checkSpace(max(estimate, size(source) / 2), near: target)
        let partial = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent)\(ownerMark).partial")
        try? FileManager.default.removeItem(at: partial)
        let args: [String]
        let wanted: String
        switch kind {
        case .m4a(let k): args = ["-protocol_whitelist", "file", "-i", source.path, "-map", "0:a:0", "-vn", "-c:a", "aac", "-b:a", "\(k)k", "-fs", "\(max(estimate * 3, 100_000_000))", "-f", "ipod", partial.path]; wanted = "mov"
        case .flac: args = ["-protocol_whitelist", "file", "-i", source.path, "-map", "0:a:0", "-vn", "-ac", "2", "-c:a", "flac", "-fs", "\(max(estimate * 3, 200_000_000))", "-f", "flac", partial.path]; wanted = "flac"
        }
        do {
            try await run(programs, args, duration: expected, progress: progress)
            let out = try await probe(partial, programs: programs)
            guard out.audio.count == 1, out.video.isEmpty else { throw FFmpegProcessingError.invalidOutput("\(out.audio.count) sound tracks") }
            guard out.formatNames.contains(wanted) else { throw FFmpegProcessingError.invalidOutput("not a \(wanted) file") }
            guard let got = out.duration, got > 0 else { throw FFmpegProcessingError.invalidOutput("no length") }
            if expected > 0, abs(got - expected) > max(2, expected * 0.02) { throw FFmpegProcessingError.invalidOutput("length \(Int(got)) s, expected \(Int(expected)) s") }
            // A source that does not say how long it is cannot confirm the result's length: a result that ran into the size limit may have been cut off, so it is not accepted.
            let cap: Int64 = max(estimate * 3, { if case .flac = kind { return 200_000_000 }; return 100_000_000 }())
            if expected <= 0, size(partial) >= cap / 100 * 95 { throw FFmpegProcessingError.invalidOutput("it may have been cut off, because the source does not say how long it is") }
            return try FileNaming.publish(partial, as: target)
        } catch { try? FileManager.default.removeItem(at: partial); throw error }
    }
}

enum ExternalExtractorText {
    /// The last few lines of a tool's error text, short enough to show.
    static func shorten(_ s: String) -> String {
        let lines = s.split(separator: "\n").suffix(3).joined(separator: " ")
        return String(lines.prefix(200))
    }
}
#endif
