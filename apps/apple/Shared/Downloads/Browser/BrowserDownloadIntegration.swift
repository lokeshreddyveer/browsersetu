import Foundation

// Phase 12: the pure decisions that connect the browser's WebKit downloads to the one download manager.
// Nothing here starts a transfer, touches a web view or owns task state: the ledger stays the only authority.

/// Which website data store a download came from. A retry, a resume or a scheduled start must go out through a page of the same store, never through another profile's
/// page, never through another private session, and never between a private tab and an ordinary one.
struct DownloadStoreKey: Hashable {
    /// A profile's store identifier. nil for a private session, and for the system's default store.
    var identifier: UUID?
    var isPersistent: Bool
    /// Which private session. Every non-persistent store has its own token: the shared private store and each "gone with the tab" store are different sessions.
    var session: UUID?

    init(identifier: UUID?, isPersistent: Bool, session: UUID? = nil) {
        self.identifier = identifier; self.isPersistent = isPersistent; self.session = session
    }

    /// The session the private tabs of ordinary windows share. A private window's session is named by the window itself (its `privateSessionID`).
    static let sharedPrivateSession = UUID(uuidString: "00000000-0000-4000-8000-0000000000B5")!

    /// What is kept with a task so it can be started again after a relaunch: only the name of a profile's store, never anything from the session itself. A private session
    /// is not kept at all (private downloads leave no record).
    var persistedValue: String? {
        guard isPersistent else { return nil }
        return identifier?.uuidString ?? "default"
    }

    init?(persisted: String?) {
        guard let persisted else { return nil }
        if persisted == "default" { self.init(identifier: nil, isPersistent: true); return }
        guard let id = UUID(uuidString: persisted) else { return nil }
        self.init(identifier: id, isPersistent: true)
    }

    static let metadataKey = "wkStore"
}

/// What is known about a browser-made download from the moment WebKit hands it over. Kept by the delegate, so a closed tab (whose web view is already gone) cannot change
/// what the download is: private stays private, a POST stays a POST.
struct BrowserDownloadContext: Equatable {
    var store: DownloadStoreKey
    var method: String
    var hasBody: Bool
    var hasCredentialHeaders: Bool
    var source: URL?
    /// Where the person chose to save it (Save Link As, Save Image As). The download is staged elsewhere and moved here only once it has finished.
    var saveAs: SaveAsDestination.Choice?

    var isPrivate: Bool { !store.isPersistent }

    init(store: DownloadStoreKey, request: URLRequest?, saveAs: SaveAsDestination.Choice? = nil) {
        self.store = store
        method = (request?.httpMethod ?? "GET").uppercased()
        hasBody = request?.httpBody != nil || request?.httpBodyStream != nil
        let headers = request?.allHTTPHeaderFields ?? [:]
        hasCredentialHeaders = headers.keys.contains { ["authorization", "cookie", "proxy-authorization"].contains($0.lowercased()) }
        source = request?.url
        self.saveAs = saveAs
    }

    /// Whether asking for this address again, with a plain GET, would be the same request. A POST (a form that produced a file), a request with a body or one that
    /// carried its own credentials is not: repeating it from the address alone would change what the site is asked, so it is never retried, scheduled or "retried" that way.
    var isReplayableByAddress: Bool {
        method == "GET" && !hasBody && !hasCredentialHeaders && DownloadSchedule.canSchedule(source)
    }
}

/// Picks the page a download is started through. Only a page of the download's own store qualifies, and a download whose store is not known is never given a page.
enum DownloadHostSelection {
    static func pick<Host>(_ hosts: [(host: Host, store: DownloadStoreKey)], for key: DownloadStoreKey?) -> Host? {
        guard let key else { return nil }
        return hosts.first(where: { $0.store == key })?.host
    }
}

/// What a right-click on the page offers for downloading, from what was actually under the pointer.
enum BrowserMenuDownloads {
    enum Item: Equatable { case saveLinkAs(URL), saveImageAs(URL), copyLink(URL), copyImageAddress(URL), showDownloads }

    /// A link or an image can be saved through the page only when it is an ordinary web address: a `blob:` or `data:` image is not a standalone resource, a `javascript:` link is code.
    static func isSavable(_ url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host?.isEmpty == false else { return false }
        return true
    }

    static func items(link: URL?, image: URL?) -> [Item] {
        var items: [Item] = []
        if isSavable(link), let link { items.append(.saveLinkAs(link)) }
        if isSavable(image), let image { items.append(.saveImageAs(image)) }
        if !items.isEmpty { items.append(.showDownloads) }
        return items
    }

    /// Where the extra items go in WebKit's menu: after the item they extend, "Show Downloads" last. Sorted by position, then rank, so the order never depends on the sort.
    struct Insertion: Hashable { var position: Int; var rank: Int; var kind: String }

    static func insertionOrder(_ insertions: [Insertion]) -> [Insertion] {
        // Highest position first keeps the earlier positions valid; at one position the higher rank goes in first, so it ends up after the others.
        insertions.sorted { ($0.position, $0.rank) > ($1.position, $1.rank) }
    }
}

/// The place a person picked for Save As. Picking it changes nothing on disk: the download is staged in the app's own folder and moved here after it has finished and been checked.
enum SaveAsDestination {
    struct Choice: Equatable, Codable {
        var target: URL
        /// The person saw "replace?" for a file that existed when they picked the place. If it appears later, it is not theirs to replace: both are kept.
        var replaceExisting: Bool
        /// What the file the person agreed to replace looked like then (size and modification time). If something else is at the name when the swap comes, it is not that file and
        /// is not replaced: both are kept.
        var expectedIdentity: String? = nil
    }

    static func identity(of url: URL, fileManager fm: FileManager = .default) -> String? {
        guard let a = try? fm.attributesOfItem(atPath: url.path) else { return nil }
        return "\((a[.size] as? NSNumber)?.int64Value ?? -1)-\(Int(((a[.modificationDate] as? Date) ?? .distantPast).timeIntervalSince1970 * 1000))"
    }

    static func resolve(_ chosen: URL, fileManager fm: FileManager = .default) -> Choice {
        let name = DownloadFilename.sanitize(chosen.lastPathComponent) ?? "download"
        let target = chosen.deletingLastPathComponent().appendingPathComponent(name)
        let identity = identity(of: target, fileManager: fm)
        // "Replace" is offered only for a file whose identity could be taken: without it there is nothing to check at the end, so both would be kept.
        return Choice(target: target, replaceExisting: identity != nil, expectedIdentity: identity)
    }

    enum Placement: Equatable {
        case placed(URL)
        /// The new file is in place, but the old one could not be sent to the Trash, so it was kept beside it under a visible name.
        case placedKeepingOld(URL, old: URL)
        /// A file appeared at the place after it was chosen (or the old one could not be moved aside): the new file sits beside it under a free name.
        case keptBoth(URL)
        /// The file could not be put there (the folder is no longer writable, say). The staged file is untouched.
        case failed(String)
    }

    /// What happens to the old file once the new one is in place. Returns false if it could not be moved to the Trash (it is then left where it is, beside the new file).
    typealias Dispose = (URL) -> Bool

    /// Moves the finished, checked file into place.
    ///
    /// Replacing is one swap, not "move the old file away, then move the new one in": `replaceItemAt` exchanges the two so that at every instant a complete file is at the chosen
    /// name, and keeps the old content as a backup next to it. Only after the swap is the backup sent to the Trash. A crash before the swap leaves the old file in place and the new
    /// one in its staging folder; a crash after it leaves the new file in place and the old one as a hidden backup beside it. Both versions are never lost together.
    /// Across volumes the system copies first and then swaps, so it is not atomic there, but the old file is still never removed before the new one is whole.
    static func place(staged: URL, choice: Choice, fileManager fm: FileManager = .default, dispose: Dispose? = nil, afterSwap: (() throws -> Void)? = nil) -> Placement {
        let folder = choice.target.deletingLastPathComponent()
        func freeName() -> URL {
            folder.appendingPathComponent(FileNaming.unique(choice.target.lastPathComponent, style: .parenthesized) { fm.fileExists(atPath: folder.appendingPathComponent($0).path) })
        }
        func move(to url: URL) -> String? {
            do { try fm.moveItem(at: staged, to: url); return nil } catch { return error.localizedDescription }
        }
        let exists = fm.fileExists(atPath: choice.target.path) || (try? choice.target.checkResourceIsReachable()) == true
        guard exists else {
            if let why = move(to: choice.target) { return .failed(why) }
            return .placed(choice.target)
        }
        // Replace only the very file that was agreed to; anything else at that name appeared since, and is kept.
        guard choice.replaceExisting, let expected = choice.expectedIdentity, expected == identity(of: choice.target, fileManager: fm) else {
            let other = freeName()
            if let why = move(to: other) { return .failed(why) }
            return .keptBoth(other)
        }
        let backupName = ".\(choice.target.lastPathComponent).replaced-\(UUID().uuidString.prefix(8))"
        do {
            _ = try fm.replaceItemAt(choice.target, withItemAt: staged, backupItemName: backupName, options: [.withoutDeletingBackupItem])
        } catch {
            // Nothing changed at the chosen name. If it cannot be swapped, the new file is kept beside it instead.
            let other = freeName()
            if let why = move(to: other) { return .failed(why) }
            return .keptBoth(other)
        }
        do { try afterSwap?() } catch { return .placed(choice.target) }          // test hook: the app "stops" here, before the backup is dealt with
        let backup = folder.appendingPathComponent(backupName)
        if fm.fileExists(atPath: backup.path) {
            let disposer = dispose ?? { (try? FileManager.default.trashItem(at: $0, resultingItemURL: nil)) != nil }
            if !disposer(backup) {
                // No Trash here (a network or external volume, or the sandbox said no): the old content gets a visible name instead of staying hidden and unmentioned.
                let ext = (choice.target.lastPathComponent as NSString).pathExtension, base = (choice.target.lastPathComponent as NSString).deletingPathExtension
                let visible = folder.appendingPathComponent(FileNaming.unique(ext.isEmpty ? "\(base) (previous)" : "\(base) (previous).\(ext)", style: .parenthesized) { fm.fileExists(atPath: folder.appendingPathComponent($0).path) })
                if (try? fm.moveItem(at: backup, to: visible)) != nil { return .placedKeepingOld(choice.target, old: visible) }
            }
        }
        return .placed(choice.target)
    }
}

/// The one routing policy. Every way a download can begin maps to exactly one path, and none of the paths widens what another allows.
enum DownloadRoute: Equatable {
    /// WebKit carries it: it depends on the browsing session (cookies, sign-in, a POST body, a blob), so only the page's own web view may fetch it.
    case webKitSession
    /// The app's own HTTP engine, only for an address the person typed or pasted, and only when the request policy allows it.
    case standaloneHTTP
    /// The BitTorrent preview; nothing connects until the person approves.
    case torrentPreview
    /// The eD2k preview; nothing connects until the person approves.
    case ed2kPreview
    /// Shown as information only (an extension's suggestion): it never becomes a task by itself.
    case informationOnly
    case refused
}

enum BrowserDownloadRouting {
    enum Input: Equatable {
        /// WebKit turned a navigation or a response into a download.
        case browserDownload
        /// An address typed or pasted into Add Download.
        case typedAddress(URL)
        /// Save Link As / Save Image As on a page. Fetched through the page, so the session is kept.
        case saveFromPage(URL)
        case magnetLink
        case torrentFile
        case ed2kLink
        case extensionSuggestion
        /// A page showing, or a link being merely present: nothing the person did.
        case pageContentOnly
    }

    static func route(_ input: Input) -> DownloadRoute {
        switch input {
        case .browserDownload: return .webKitSession
        case .saveFromPage(let url): return BrowserMenuDownloads.isSavable(url) ? .webKitSession : .refused
        case .typedAddress(let url):
            switch url.scheme?.lowercased() {
            case "http", "https": return .standaloneHTTP
            case "magnet": return .torrentPreview
            case "ed2k": return .ed2kPreview
            default: return .refused
            }
        case .magnetLink, .torrentFile: return .torrentPreview
        case .ed2kLink: return .ed2kPreview
        case .extensionSuggestion: return .informationOnly
        case .pageContentOnly: return .refused
        }
    }
}
