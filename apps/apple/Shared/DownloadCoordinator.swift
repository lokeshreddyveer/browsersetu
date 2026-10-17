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
    func begin(suggestedName: String, sourceHost: String? = nil, cancel: @escaping () -> Void) -> (id: UUID, destination: URL) {
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
        }
        forget(id)
    }

    func resume(_ id: UUID) {
        guard let item = interrupted[id] else { return }
        interrupted[id] = nil
        resumer?(item.resumeData)
    }

    func dismissInterrupted(_ id: UUID) { interrupted[id] = nil }

    private func forget(_ id: UUID) {
        active[id] = nil
        destinations[id] = nil
        cancellers[id] = nil
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
