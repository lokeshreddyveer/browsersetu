import Foundation

/// A folder outside the downloads folder that the person chose for a rule. The app is sandboxed, so such a folder is reachable only through the security-scoped bookmark made when
/// they picked it. What is stored is that bookmark, never a path that something else could have written; if it no longer opens (the folder was deleted or renamed, the volume is gone, the
/// permission was revoked) the download goes to the ordinary folder instead and the reason is reported, rather than failing or writing somewhere unexpected.
enum DownloadDestinationAccess {
    enum Result: Equatable {
        case granted(URL)
        case unavailable(String)
    }

    /// Folders opened so far. Access stays open for as long as the app runs: a download may still be writing to one when the person looks away, and the set is bounded by the number of rules.
    private nonisolated(unsafe) static var held: [String: URL] = [:]
    private static let lock = NSLock()

    /// The roots a task's files may be in besides the downloads folder.
    static var grantedRoots: [URL] { lock.lock(); defer { lock.unlock() }; return Array(held.values) }

    /// A security scope is a macOS notion; on iOS a plain bookmark is what grants the same access.
    private static var scopeOptions: URL.BookmarkCreationOptions {
        #if os(macOS)
        [.withSecurityScope]
        #else
        []
        #endif
    }

    private static var resolveOptions: URL.BookmarkResolutionOptions {
        #if os(macOS)
        [.withSecurityScope]
        #else
        []
        #endif
    }

    static func makeBookmark(for folder: URL) throws -> Data {
        try folder.bookmarkData(options: scopeOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func open(_ bookmark: Data) -> Result {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: resolveOptions, relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return .unavailable("The folder chosen for this rule can no longer be found. Choose it again to use it.")
        }
        let started = url.startAccessingSecurityScopedResource()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            if started { url.stopAccessingSecurityScopedResource() }
            return .unavailable("The folder “\(url.lastPathComponent)” chosen for this rule is missing.")
        }
        guard FileManager.default.isWritableFile(atPath: url.path) else {
            if started { url.stopAccessingSecurityScopedResource() }
            return .unavailable("Browser Setu is no longer allowed to save into “\(url.lastPathComponent)”. Choose it again to allow it.")
        }
        lock.lock()
        if held[url.standardizedFileURL.path] != nil, started { url.stopAccessingSecurityScopedResource() }      // already open: one access per folder
        held[url.standardizedFileURL.path] = url
        lock.unlock()
        return .granted(url)
    }

    /// For tests: forget what was opened.
    static func closeAll() {
        lock.lock(); defer { lock.unlock() }
        for url in held.values { url.stopAccessingSecurityScopedResource() }
        held = [:]
    }
}
