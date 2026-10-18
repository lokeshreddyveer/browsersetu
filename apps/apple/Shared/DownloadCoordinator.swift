import Foundation

/// A download that stopped part-way (the connection dropped, say) and can carry on from where it got to, if the server allows.
struct InterruptedDownload: Identifiable {
    let id: UUID
    var filename: String
    var resumeData: Data
    var source: URL?
}

struct ActiveDownload: Identifiable {
    let id: UUID
    var filename: String
    var fraction: Double
    var completedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    /// Smoothed transfer rate; zero until two samples have arrived.
    var bytesPerSecond: Double = 0
    var lastSample: Date = Date()
    var lastBytes: Int64 = 0
    var warnedDisk = false

    /// "48 of 78 MB · 6.1 MB/s · about 5 s left", with whatever parts are known.
    var detail: String { DownloadStats.detail(completed: completedBytes, total: totalBytes, rate: bytesPerSecond) }
}

/// Engine-neutral download bookkeeping. Engines report events; this decides where files go.
@MainActor
final class DownloadCoordinator: ObservableObject {
    @Published private(set) var active: [UUID: ActiveDownload] = [:] {
        didSet {
            #if os(iOS)
            if oldValue.isEmpty != active.isEmpty { DownloadBackgroundTask.shared.coordinator = self; DownloadBackgroundTask.shared.update(hasActive: !active.isEmpty) }
            #endif
        }
    }
    @Published private(set) var completed: [URL] = []
    @Published private(set) var interrupted: [UUID: InterruptedDownload] = [:]
    /// Set by the engine: starts a download again from its resume data.
    var resumer: ((Data) -> Void)?
    /// Sort new downloads into folders by kind (Images, Documents, Archives…) inside the downloads folder.
    var organize = false
    /// A folder named for the profile, inside the downloads folder, when downloads are kept apart by profile.
    var profileFolder: String?
    /// Sort new downloads into a folder named after the site they came from.
    var organizeByDomain = false
    /// Recent download events (start, finish, failure, warnings) for "Copy Download Diagnostics".
    private(set) var events: [String] = []
    /// Raised once per download when the disk looks too full for it.
    var onLowDisk: ((_ filename: String, _ needed: Int64, _ available: Int64) -> Void)?
    /// The user's rules by site and kind; the first match names the folder, ahead of sorting by kind.
    var rules: [DownloadRule] = []
    var onFinished: ((_ source: URL?, _ filename: String) -> Void)?

    // MARK: The queue

    @Published private(set) var waiting: [QueuedDownload] = []
    @Published private(set) var scheduled: [ScheduledDownload] = []
    /// While set and in the future, new downloads are not started: they are remembered by address and started at that time.
    @Published private(set) var heldUntil: Date?
    /// How many may run at the same time; the rest wait their turn.
    var maxConcurrent = DownloadQueueRules.defaultConcurrent { didSet { pump() } }
    /// Starts a download again from its address (the engine sets this). Used for scheduled downloads and for retries that have no resume data.
    var starter: ((URL) -> Void)?
    private var tickets: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var reserved = 0
    private var attempts: [String: Int] = [:]
    private var scheduleTimer: Timer?

    /// Called before a download's destination is chosen. Returns when it may start (true), or false when it has been put off (held for later) or cancelled while waiting.
    func admit(filename: String, source: URL?) async -> Bool {
        if DownloadSchedule.isHeld(until: heldUntil), DownloadSchedule.canSchedule(source), let source {
            scheduled.append(ScheduledDownload(url: source.absoluteString, filename: Self.safeName(filename), priority: .normal))
            persistScheduled()
            return false
        }
        let freeNow = DownloadQueueRules.freeSlots(limit: maxConcurrent, running: active.count, reserved: reserved)
        if freeNow > 0, waiting.isEmpty { reserved += 1; return true }
        let item = QueuedDownload(id: UUID(), filename: Self.safeName(filename), priority: .normal, enqueued: Date(), source: source)
        waiting.append(item)
        return await withCheckedContinuation { tickets[item.id] = $0 }
    }

    /// The destination was chosen (or the download ended before that): the place held for it is no longer "reserved".
    private func settleReservation() { reserved = max(0, reserved - 1) }

    private func pump() {
        while let next = DownloadQueueRules.next(from: waiting),
              DownloadQueueRules.freeSlots(limit: maxConcurrent, running: active.count, reserved: reserved) > 0 {
            waiting.removeAll { $0.id == next.id }
            reserved += 1
            tickets.removeValue(forKey: next.id)?.resume(returning: true)
        }
    }

    func setPriority(_ id: UUID, _ priority: DownloadPriority) {
        guard let i = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting[i].priority = priority
        pump()
    }

    /// Gives up on a download that has not started.
    func cancelWaiting(_ id: UUID) {
        waiting.removeAll { $0.id == id }
        tickets.removeValue(forKey: id)?.resume(returning: false)
    }

    // MARK: Pause, resume, schedule

    /// Stops every running download where it is (each keeps its place on disk) and holds the ones that are waiting.
    func pauseAll(then done: @escaping () -> Void = {}) {
        suspendAll { [weak self] in self?.holdQueue(until: .distantFuture); done() }
    }

    func resumeAll() {
        holdQueue(until: nil)
        for id in Array(interrupted.keys) { resume(id) }
        startScheduledNow()
    }

    /// Nothing new starts until this time; what arrives meanwhile is started then. nil lifts the hold.
    func holdQueue(until date: Date?) {
        heldUntil = date
        scheduleTimer?.invalidate(); scheduleTimer = nil
        guard let date else { pump(); return }
        if date != .distantFuture {
            scheduleTimer = Timer.scheduledTimer(withTimeInterval: max(1, date.timeIntervalSinceNow), repeats: false) { [weak self] _ in Task { @MainActor in self?.resumeAll() } }
        }
    }

    /// Starts everything that was put off, in priority order.
    func startScheduledNow() {
        let list = scheduled.sorted { $0.priority > $1.priority }
        scheduled = []
        persistScheduled()
        for item in list { if let url = URL(string: item.url), DownloadSchedule.canSchedule(url) { starter?(url) } }
    }

    func removeScheduled(_ id: UUID) { scheduled.removeAll { $0.id == id }; persistScheduled() }

    private var scheduledURL: URL? { store?.appendingPathComponent("scheduled.json") }
    private func persistScheduled() {
        guard let store, let scheduledURL else { return }
        try? FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(scheduled) { try? data.write(to: scheduledURL, options: .atomic) }
    }
    func restoreScheduled() {
        guard let scheduledURL, let data = try? Data(contentsOf: scheduledURL), let list = try? JSONDecoder().decode([ScheduledDownload].self, from: data) else { return }
        scheduled = Array(list.filter { DownloadSchedule.canSchedule(URL(string: $0.url)) }.prefix(200))
    }

    // MARK: Retry

    /// A download failed. If a retry can help and it has not been tried too often, it is started again after a short wait; returns whether one was planned.
    @discardableResult
    func planRetry(for source: URL?, error: Error, resumeData: Data?, id: UUID) -> Bool {
        guard DownloadRetry.isRetryable(error), let source, DownloadSchedule.canSchedule(source) else { return false }
        let key = source.absoluteString
        let attempt = (attempts[key] ?? 0) + 1
        guard attempt <= DownloadRetry.maxAttempts else { attempts[key] = nil; return false }
        attempts[key] = attempt
        let delay = DownloadRetry.delay(afterAttempt: attempt)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            if let resumeData, !resumeData.isEmpty, self.interrupted[id] != nil { self.resume(id) } else { self.starter?(source) }
        }
        return true
    }

    func downloadSucceeded(source: URL?) { if let source { attempts[source.absoluteString] = nil } }

    private var destinations: [UUID: URL] = [:]
    private var cancellers: [UUID: () -> Void] = [:]
    /// Stops a download in a way that hands back its resume data, so quitting the app does not lose what was already fetched.
    private var suspenders: [UUID: (@escaping (Data?) -> Void) -> Void] = [:]

    /// A folder (inside the profile) where interrupted downloads are kept, so they can be resumed after the app was closed or quit.
    var store: URL? { didSet { restoreInterrupted(); restoreScheduled() } }

    private struct StoredItem: Codable { var id: UUID; var filename: String; var source: String? }
    private var indexURL: URL? { store?.appendingPathComponent("interrupted.json") }
    private func resumeURL(_ id: UUID) -> URL? { store?.appendingPathComponent(id.uuidString + ".resume") }

    private func persistInterrupted() {
        guard let store, let indexURL else { return }
        try? FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        for item in interrupted.values { if let url = resumeURL(item.id) { try? item.resumeData.write(to: url, options: .atomic) } }
        let list = interrupted.values.map { StoredItem(id: $0.id, filename: $0.filename, source: $0.source?.absoluteString) }
        if let data = try? JSONEncoder().encode(list) { try? data.write(to: indexURL, options: .atomic) }
        // Resume files whose download is no longer listed are removed.
        let keep = Set(interrupted.keys.map { $0.uuidString + ".resume" })
        for name in (try? FileManager.default.contentsOfDirectory(atPath: store.path)) ?? [] where name.hasSuffix(".resume") && !keep.contains(name) {
            try? FileManager.default.removeItem(at: store.appendingPathComponent(name))
        }
    }

    /// Brings back what was left unfinished by an earlier run.
    func restoreInterrupted() {
        guard let indexURL, let data = try? Data(contentsOf: indexURL), let list = try? JSONDecoder().decode([StoredItem].self, from: data) else { return }
        for item in list.prefix(50) where interrupted[item.id] == nil {
            guard let url = resumeURL(item.id), let resume = try? Data(contentsOf: url), resume.count < 5_000_000 else { continue }
            interrupted[item.id] = InterruptedDownload(id: item.id, filename: DownloadCoordinator.safeName(item.filename), resumeData: resume, source: item.source.flatMap(URL.init(string:)))
        }
    }

    /// Asks every running download to stop and keep its place. The result arrives through `interrupt`.
    func suspendAll(then done: @escaping () -> Void = {}) {
        let running = Array(suspenders)
        guard !running.isEmpty else { done(); return }
        var left = running.count
        for (id, suspend) in running {
            suspend { [weak self] data in
                Task { @MainActor in
                    if let data, !data.isEmpty { self?.interrupt(id, resumeData: data, source: nil) }
                    left -= 1
                    if left == 0 { done() }
                }
            }
        }
    }

    /// For quitting: waits (briefly) for the downloads to hand back their place before the app goes away.
    func suspendAllBeforeQuit(timeout: TimeInterval = 1.5) {
        var finished = false
        suspendAll { finished = true }
        let end = Date().addingTimeInterval(timeout)
        while !finished, Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
    }

    static var directory: URL {
        #if os(macOS)
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        #else
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
        #endif
    }

    /// Strips any path components so a hostile filename cannot escape the downloads folder.
    static func safeName(_ suggested: String) -> String {
        var name = (suggested as NSString).lastPathComponent
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        if name.isEmpty { name = "download" }
        return name
    }

    /// The folder name a file of this kind goes into when downloads are sorted.
    static func category(forFilename name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "svg", "tiff", "bmp", "avif": return "Images"
        case "pdf", "doc", "docx", "pages", "txt", "rtf", "md", "xls", "xlsx", "numbers", "csv", "ppt", "pptx", "key", "epub": return "Documents"
        case "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz": return "Archives"
        case "mp3", "m4a", "wav", "aac", "flac", "ogg", "aiff": return "Audio"
        case "mp4", "mov", "m4v", "mkv", "avi", "webm": return "Video"
        case "dmg", "pkg", "mpkg", "app", "iso", "exe", "msi", "apk": return "Installers"
        default: return "Other"
        }
    }

    /// Where a downloaded file is now: in the downloads folder, or in the kind-folder it was sorted into.
    static func locate(filename: String) -> URL? {
        let fm = FileManager.default
        let flat = directory.appendingPathComponent(filename)
        if fm.fileExists(atPath: flat.path) { return flat }
        let sorted = directory.appendingPathComponent(category(forFilename: filename), isDirectory: true).appendingPathComponent(filename)
        if fm.fileExists(atPath: sorted.path) { return sorted }
        // Folders from site rules, per-site or per-profile sorting: looked for up to two levels down.
        let top = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for dir in top where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let one = dir.appendingPathComponent(filename)
            if fm.fileExists(atPath: one.path) { return one }
            for inner in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            where (try? inner.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let two = inner.appendingPathComponent(filename)
                if fm.fileExists(atPath: two.path) { return two }
            }
        }
        return nil
    }

    static func uniqueURL(in dir: URL, name: String) -> URL {
        var candidate = dir.appendingPathComponent(name)
        let stem = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            candidate = dir.appendingPathComponent(next)
            n += 1
        }
        return candidate
    }

    // MARK: Engine-facing events

    /// Starts tracking a download and returns the destination the engine must write to.
    func begin(suggestedName: String, sourceHost: String? = nil, cancel: @escaping () -> Void, suspend: ((@escaping (Data?) -> Void) -> Void)? = nil) -> (id: UUID, destination: URL) {
        let name = Self.safeName(suggestedName)
        var folder = Self.directory
        if let profileFolder, let clean = DownloadRule.cleanFolder(profileFolder) {
            folder = folder.appendingPathComponent(clean, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        if let ruled = DownloadRouting.folder(for: name, from: sourceHost, rules: rules), let clean = DownloadRule.cleanFolder(ruled) {
            folder = folder.appendingPathComponent(clean, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } else if organizeByDomain, let host = sourceHost, let clean = DownloadRule.cleanFolder(host) {
            folder = folder.appendingPathComponent(clean, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } else if organize {
            folder = folder.appendingPathComponent(Self.category(forFilename: name), isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let dest = Self.uniqueURL(in: folder, name: name)
        let id = UUID()
        destinations[id] = dest
        settleReservation()
        cancellers[id] = cancel
        if let suspend { suspenders[id] = suspend }
        active[id] = ActiveDownload(id: id, filename: dest.lastPathComponent, fraction: 0)
        note("Started \(dest.lastPathComponent)\(sourceHost.map { " from \($0)" } ?? "")")
        return (id, dest)
    }

    func update(_ id: UUID, fraction: Double) {
        active[id]?.fraction = fraction
    }

    /// Progress with byte counts: keeps a smoothed speed and warns once if the disk cannot hold the file.
    func update(_ id: UUID, fraction: Double, completed: Int64, total: Int64) {
        guard var d = active[id] else { return }
        d.fraction = fraction
        let now = Date()
        let dt = now.timeIntervalSince(d.lastSample)
        if dt >= 0.5 {
            let instant = Double(max(0, completed - d.lastBytes)) / dt
            d.bytesPerSecond = d.bytesPerSecond == 0 ? instant : d.bytesPerSecond * 0.7 + instant * 0.3
            d.lastSample = now
            d.lastBytes = completed
        }
        d.completedBytes = completed
        d.totalBytes = max(0, total)
        if !d.warnedDisk, total > 0, let free = DiskSpace.available(at: Self.directory), DiskSpace.isTight(needed: total - completed, available: free) {
            d.warnedDisk = true
            note("Low disk space for \(d.filename): needs \(DownloadStats.bytes(total)), \(DownloadStats.bytes(free)) free")
            onLowDisk?(d.filename, total, free)
        }
        active[id] = d
    }

    func note(_ line: String) {
        events.append("\(ISO8601DateFormatter().string(from: Date())) \(line)")
        if events.count > 60 { events.removeFirst(events.count - 60) }
    }

    /// Plain-text summary a person can paste into a bug report. Holds file names and sites, no page content.
    var diagnostics: String {
        var lines = ["Browser Setu download diagnostics", "Folder: \(Self.directory.path)"]
        if let free = DiskSpace.available(at: Self.directory) { lines.append("Free space: \(DownloadStats.bytes(free))") }
        lines.append("Active: \(active.count), waiting: \(waiting.count), scheduled: \(scheduled.count), interrupted: \(interrupted.count)")
        lines.append("Concurrent limit: \(maxConcurrent)")
        for d in active.values { lines.append("• \(d.filename) \(Int(d.fraction * 100))% \(d.detail)") }
        lines.append("Recent events:")
        lines.append(contentsOf: events.suffix(40).map { "  " + $0 })
        return lines.joined(separator: "\n")
    }

    func finish(_ id: UUID, source: URL?) {
        if let dest = destinations[id] {
            completed.insert(dest, at: 0)
            note("Finished \(dest.lastPathComponent)")
            onFinished?(source, dest.lastPathComponent)
        }
        forget(id)
    }

    /// Failed or cancelled: the partial file is removed.
    func discard(_ id: UUID) {
        if let dest = destinations[id] { try? FileManager.default.removeItem(at: dest) }
        forget(id)
    }

    /// Stopped part-way with a way to carry on: kept in the list, with a Resume button, instead of being thrown away.
    func interrupt(_ id: UUID, resumeData: Data, source: URL?) {
        if let dest = destinations[id] {
            interrupted[id] = InterruptedDownload(id: id, filename: dest.lastPathComponent, resumeData: resumeData, source: source)
            persistInterrupted()
        }
        forget(id)
    }

    func resume(_ id: UUID) {
        guard let item = interrupted[id] else { return }
        interrupted[id] = nil
        persistInterrupted()
        resumer?(item.resumeData)
    }

    func dismissInterrupted(_ id: UUID) { interrupted[id] = nil; persistInterrupted() }

    private func forget(_ id: UUID) {
        active[id] = nil
        destinations[id] = nil
        cancellers[id] = nil
        suspenders[id] = nil
        pump()
    }

    /// Cancels one download; the partial file is removed.
    func cancel(_ id: UUID) {
        cancellers[id]?()
        discard(id)
    }

    func clearCompleted() { completed = [] }

    /// Cancels every in-flight download; each engine's cancel hook reports back through `discard`.
    func cancelAll() {
        for (id, cancel) in cancellers {
            cancel()
            discard(id)
        }
    }
}
