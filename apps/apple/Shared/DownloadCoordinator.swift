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
}

/// Engine-neutral download bookkeeping. Engines report events; this decides where files go.
@MainActor
final class DownloadCoordinator: ObservableObject {
    @Published private(set) var active: [UUID: ActiveDownload] = [:]
    @Published private(set) var completed: [URL] = []
    @Published private(set) var interrupted: [UUID: InterruptedDownload] = [:]
    /// Set by the engine: starts a download again from its resume data.
    var resumer: ((Data) -> Void)?
    /// Sort new downloads into folders by kind (Images, Documents, Archives…) inside the downloads folder.
    var organize = false
    /// The user's rules by site and kind; the first match names the folder, ahead of sorting by kind.
    var rules: [DownloadRule] = []
    var onFinished: ((_ source: URL?, _ filename: String) -> Void)?

    private var destinations: [UUID: URL] = [:]
    private var cancellers: [UUID: () -> Void] = [:]
    /// Stops a download in a way that hands back its resume data, so quitting the app does not lose what was already fetched.
    private var suspenders: [UUID: (@escaping (Data?) -> Void) -> Void] = [:]

    /// A folder (inside the profile) where interrupted downloads are kept, so they can be resumed after the app was closed or quit.
    var store: URL? { didSet { restoreInterrupted() } }

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
        return fm.fileExists(atPath: sorted.path) ? sorted : nil
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
        if let ruled = DownloadRouting.folder(for: name, from: sourceHost, rules: rules), let clean = DownloadRule.cleanFolder(ruled) {
            folder = folder.appendingPathComponent(clean, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } else if organize {
            folder = folder.appendingPathComponent(Self.category(forFilename: name), isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let dest = Self.uniqueURL(in: folder, name: name)
        let id = UUID()
        destinations[id] = dest
        cancellers[id] = cancel
        if let suspend { suspenders[id] = suspend }
        active[id] = ActiveDownload(id: id, filename: dest.lastPathComponent, fraction: 0)
        return (id, dest)
    }

    func update(_ id: UUID, fraction: Double) {
        active[id]?.fraction = fraction
    }

    func finish(_ id: UUID, source: URL?) {
        if let dest = destinations[id] {
            completed.insert(dest, at: 0)
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
