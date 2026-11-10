import Foundation

// Files that hold a list of links.
//
// Read: plain text lists (any text with links in it), M3U lists of ordinary links, and Metalink 4 documents. NOT read, and said so: DLC, RSDF and CCF containers. Those are encrypted
// or obfuscated with keys and services that belong to the tool that made them, and no published, authorised specification is used here, so they are reported as unsupported rather than
// guessed at (a file name ending in .dlc is not evidence that anything inside can be read).
//
// What a container yields is only a list of addresses. They go to the LinkGrabber like any other collected links: classified, checked for safe destinations, de-duplicated, shown for review,
// and downloaded only when the person adds them. Nothing in a file starts a download, and a link from a file is never treated as one the person typed.

enum LinkContainerKind: Equatable, Sendable {
    case text, m3uList, metalink
    case unsupported(String)
    var title: String {
        switch self { case .text: "Link list"; case .m3uList: "M3U list"; case .metalink: "Metalink"; case .unsupported: "Unsupported" }
    }
}

struct LinkContainerResult: Equatable, Sendable {
    var kind: LinkContainerKind
    var links: [String]
    var notes: [String]
    var truncated: Bool
}

enum LinkContainerError: Error, Equatable, LocalizedError {
    case notAFile, tooLarge, notText, privateList
    var errorDescription: String? {
        switch self {
        case .notAFile: "That is not a file Browser Setu can read."
        case .tooLarge: "That file is too large to be a list of links."
        case .notText: "That file is not a text list of links."
        case .privateList: "Links are not collected from files into a private list."
        }
    }
}

enum LinkContainers {
    static let maxBytes = 2 * 1024 * 1024
    static let maxLinks = 5_000
    static let unsupportedExtensions: [String: String] = [
        "dlc": "DLC containers are encrypted with keys from the service that made them, and no authorised way to open them is available here.",
        "rsdf": "RSDF containers are obfuscated with a scheme that has no authorised specification available here.",
        "ccf": "CCF containers use a proprietary format that has no authorised specification available here.",
    ]

    static func parse(_ file: URL) throws -> LinkContainerResult {
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]), values.isRegularFile == true, values.isSymbolicLink != true else { throw LinkContainerError.notAFile }
        if let reason = unsupportedExtensions[file.pathExtension.lowercased()] { return LinkContainerResult(kind: .unsupported(reason), links: [], notes: [], truncated: false) }
        guard (values.fileSize ?? 0) <= maxBytes else { throw LinkContainerError.tooLarge }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        guard data.count <= maxBytes else { throw LinkContainerError.tooLarge }
        return try parse(data, name: file.lastPathComponent)
    }

    static func parse(_ data: Data, name: String = "") throws -> LinkContainerResult {
        let utf16 = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
        guard utf16 || !data.contains(0), let text = decode(data), !text.unicodeScalars.contains(where: { $0.value == 0 }) else { throw LinkContainerError.notText }
        let head = text.prefix(4096).lowercased()
        if head.contains("<metalink") { return try metalink(data) }
        if head.contains("#extm3u") || name.lowercased().hasSuffix(".m3u") || name.lowercased().hasSuffix(".m3u8") {
            if text.contains("#EXT-X-") { return LinkContainerResult(kind: .unsupported("This is a stream playlist, not a list of links. Use Find Downloadable Media or Add Download to download the stream."), links: [], notes: [], truncated: false) }
            let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
            let found = LinkExtractor.candidates(in: lines.joined(separator: "\n"), limit: maxLinks)
            return LinkContainerResult(kind: .m3uList, links: found.links, notes: [], truncated: found.truncated)
        }
        if head.hasPrefix("<?xml") || head.hasPrefix("<") { return LinkContainerResult(kind: .unsupported("This is a markup file, not a list of links."), links: [], notes: [], truncated: false) }
        let found = LinkExtractor.candidates(in: text, limit: maxLinks)
        return LinkContainerResult(kind: .text, links: found.links, notes: [], truncated: found.truncated)
    }

    private static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(data: data.dropFirst(3), encoding: .utf8) }
        if data.starts(with: [0xFF, 0xFE]) { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
        if data.starts(with: [0xFE, 0xFF]) { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
        return String(data: data, encoding: .utf8)
    }

    /// Metalink 4: the first address of each file (the other mirrors are noted, not imported: a mirror is a way to get the same file, not another download). The document's checksums are
    /// not applied to an imported link; adding it as a Metalink download (Add Download ▸ Open Metalink) is the way to use them.
    private static func metalink(_ data: Data) throws -> LinkContainerResult {
        do {
            let files = try MetalinkParser.parse(data)
            var links: [String] = [], notes: [String] = []
            for f in files {
                if let first = f.urls.first { links.append(first) }
                if f.urls.count > 1 { notes.append("“\(f.name.prefix(40))” has \(f.urls.count - 1) other source\(f.urls.count == 2 ? "" : "s"); use Open Metalink to use them with its checksum.") }
            }
            return LinkContainerResult(kind: .metalink, links: links, notes: notes, truncated: false)
        } catch { return LinkContainerResult(kind: .unsupported((error as? LocalizedError)?.errorDescription ?? "This Metalink file could not be read."), links: [], notes: [], truncated: false) }
    }

    /// Hands the addresses to the LinkGrabber. They arrive as links found on a page would: reviewed, not started.
    @MainActor
    static func importFile(_ file: URL, into store: LinkGrabberStore) throws -> (LinkContainerResult, LinkGrabberStore.Report) {
        guard !store.isPrivate else { throw LinkContainerError.privateList }
        let result = try parse(file)
        guard !result.links.isEmpty else { return (result, LinkGrabberStore.Report()) }
        let report = store.add(candidates: result.links, provenance: .page, group: "Imported: " + file.lastPathComponent.prefix(40))
        return (result, report)
    }
}

/// Opening several finished archives at once, each on its own: one that fails does not stop the others, and each says what happened.
enum ArchiveBatch {
    struct Item { var file: URL; var outcome: Swift.Result<ArchiveManager.Result, ArchiveError> }

    static func extract(_ files: [URL], destination: URL, roots: [URL], limits: ArchiveLimits = ArchiveLimits(), isCancelled: () -> Bool = { false }) -> [Item] {
        var out: [Item] = []
        for f in files.dropFirst(50) { out.append(Item(file: f, outcome: .failure(.unsupported("Only 50 archives are opened at once; this one was left for the next batch.")))) }
        for f in files.prefix(50) {
            if isCancelled() { out.append(Item(file: f, outcome: .failure(.cancelled))); continue }
            do { out.append(Item(file: f, outcome: .success(try ArchiveManager.extract(f, destination: destination, roots: roots, limits: limits, isCancelled: isCancelled)))) }
            catch let e as ArchiveError { out.append(Item(file: f, outcome: .failure(e))) }
            catch { out.append(Item(file: f, outcome: .failure(.damaged("it could not be opened.")))) }
        }
        return out
    }
}
