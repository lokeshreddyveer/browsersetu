import Foundation
import CryptoKit

// The LinkGrabber's collection. A collected link is not a transfer: nothing here creates a ledger entry, opens a connection or reserves a resource. The only ways out are the
// person's own actions (Preview, Add Selected), and those go through the routes the rest of the app already has.

enum LinkFilter: String, CaseIterable, Identifiable {
    case all, files, magnets, ed2k, torrents, other
    var id: String { rawValue }
    var title: String {
        switch self { case .all: "All"; case .files: "Files"; case .magnets: "Magnets"; case .ed2k: "eD2k"; case .torrents: "Torrent files"; case .other: "Web addresses & other" }
    }
    func matches(_ k: LinkKind) -> Bool {
        switch self {
        case .all: true
        case .files: k == .httpResource || k == .streamManifest
        case .magnets: k == .magnet
        case .ed2k: k == .ed2kFile
        case .torrents: k == .torrentURL || k == .localTorrent
        case .other: k == .webpage || !k.isSupported
        }
    }
}

@MainActor
final class LinkGrabberStore: ObservableObject {
    static let maxItems = 1000
    static let maxBatchAdd = 200

    let profile: String
    /// A collection made in a private session lives in memory only and is never shown beside an ordinary profile's.
    let isPrivate: Bool
    @Published private(set) var items: [DetectedLink] = []
    @Published var selection = Set<String>()
    @Published var filter = LinkFilter.all
    @Published var search = ""
    @Published private(set) var notice: String?

    init(profile: String, isPrivate: Bool) { self.profile = profile; self.isPrivate = isPrivate }

    struct Report: Equatable { var added = 0, duplicates = 0, unsupported = 0, truncated = false }

    /// Finds the links in `text` and adds them. Nothing is contacted.
    @discardableResult
    func add(text: String, provenance: LinkProvenance, group: String? = nil) -> Report {
        let found = LinkExtractor.candidates(in: text)
        var r = add(candidates: found.links, provenance: provenance, group: group)
        r.truncated = r.truncated || found.truncated
        return r
    }

    @discardableResult
    func add(candidates: [String], provenance: LinkProvenance, group: String? = nil) -> Report {
        var report = Report()
        var known = Set(items.map(\.id))
        for raw in candidates {
            if items.count >= Self.maxItems { report.truncated = true; break }
            let c = LinkClassifier.classify(raw)
            guard known.insert(c.identity).inserted else { report.duplicates += 1; continue }
            items.append(DetectedLink(id: c.identity, original: LinkClassifier.canonicalText(raw), display: c.display, kind: c.kind, name: c.name, host: c.host,
                                      provenance: provenance, profile: profile, isPrivate: isPrivate, group: group))
            if !c.kind.isSupported { report.unsupported += 1 }
            report.added += 1
        }
        notice = report.added == 0 && report.duplicates > 0 ? "Those links are already collected." : (report.truncated ? "The collection is full (\(Self.maxItems) links)." : nil)
        return report
    }

    var visible: [DetectedLink] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return items.filter { filter.matches($0.kind) && (q.isEmpty || $0.name.lowercased().contains(q) || ($0.host ?? "").contains(q) || $0.display.lowercased().contains(q)) }
    }
    /// What is selected AND on screen: a selection never reaches links the current filter hides.
    var selectedItems: [DetectedLink] { let shown = Set(visible.map(\.id)); return items.filter { selection.contains($0.id) && shown.contains($0.id) } }

    /// Selects what is likely worth downloading: files, torrents, magnets, eD2k. Ordinary web addresses are left for the person to pick one by one.
    func selectAllAddable() { selection = Set(visible.filter { $0.canAdd && $0.kind != .webpage }.map(\.id)) }
    func remove(_ ids: Set<String>) { items.removeAll { ids.contains($0.id) }; selection.subtract(ids) }
    func clear() { items = []; selection = []; notice = nil }

    func setCheck(_ id: String, _ check: LinkCheck) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].check = check
        if case .checked(let m) = check, let name = m.filename, !name.isEmpty { items[i].name = name }
    }
}

// MARK: - Routing

/// What choosing a link does. One policy for every entry point; none of these starts peer-to-peer networking by itself.
enum LinkRoute: Equatable {
    /// Opens the existing torrent or eD2k preview (Add Download's second step). The preview asks before anything is contacted.
    case preview(text: String)
    /// A `.torrent` file on this Mac, opened through the existing torrent preview.
    case previewLocalTorrent(URL)
    /// The ordinary download of an address the person chose. Starts a task through the one coordinator, as Add Download does.
    case download(URL)
    /// The preview of a stream playlist (Add Download's second step): it reads the playlist only after the person asks, and fetches no media until they choose Download.
    case mediaPreview(URL)
    case refused(String)
}

enum LinkRouter {
    static func route(_ link: DetectedLink) -> LinkRoute {
        guard link.provenance.mayBeAddedFromHere else { return .refused("This was suggested by an extension or a program. Open it yourself to add it.") }
        // The same destination rule for every way a link arrived. Pasting an address is not permission to reach this Mac or the local network from here; the Add Download form is
        // where the person deliberately adds an address of their own network.
        if let host = link.host, !HTTPRequestPolicy.pageMayReach(host: host) {
            return .refused("This address is on your own network. Use Add Download for an address you mean to reach.")
        }
        switch link.kind {
        case .magnet, .ed2kFile: return .preview(text: link.original)
        case .localTorrent: return URL(string: link.original).map { .previewLocalTorrent($0) } ?? .refused("That file address is not usable.")
        case .streamManifest:
            guard let url = URL(string: link.original), DownloadSchedule.canSchedule(url) else { return .refused("That web address cannot be opened.") }
            return .mediaPreview(url)
        case .httpResource, .webpage, .torrentURL:
            guard let url = URL(string: link.original), DownloadSchedule.canSchedule(url) else { return .refused("That web address cannot be downloaded.") }
            return .download(url)
        case .unsupported(let why), .invalid(let why): return .refused(why)
        }
    }
}

extension LinkGrabberStore {
    struct AddOutcome: Equatable { var started = 0, alreadyThere = 0, refused = 0, previewed: String?, tooMany = false }

    /// Adds what the person selected. Web addresses become ordinary downloads (the same call Add Download makes); the first peer-to-peer link opens its preview and the rest wait their
    /// turn, because each of those needs its own decision. Selecting a thousand links never makes a thousand tasks: the batch is capped, and addresses already downloading are skipped.
    @discardableResult
    func addSelected(to coordinator: DownloadCoordinator, openPreview: (LinkRoute) -> Void) -> AddOutcome {
        var out = AddOutcome()
        var done = Set<String>()
        let live = LinkClassifier.liveKeys(coordinator.ledger.records.values)
        for link in selectedItems {
            switch LinkRouter.route(link) {
            case .download(let url):
                if out.started >= Self.maxBatchAdd { out.tooMany = true; continue }
                if isPrivate { out.refused += 1; continue }              // a private collection never creates ledger entries
                if LinkClassifier.isLive(url, in: live) { out.alreadyThere += 1; done.insert(link.id); continue }
                // Typed or pasted by the person is theirs; anything that arrived from a page, the clipboard or a crawl keeps the page-derived limits however it was approved.
                let origin: DownloadRequestOrigin = link.provenance == .pasted ? .user : .page
                if coordinator.scheduleDownload(url: url, at: Date(), origin: origin) != nil { out.started += 1; done.insert(link.id) } else { out.refused += 1 }
            case .preview, .previewLocalTorrent, .mediaPreview:
                // A private collection never opens a preview: the preview belongs to the ordinary profile's download list.
                if isPrivate { out.refused += 1; continue }
                if out.previewed == nil { out.previewed = link.id; openPreview(LinkRouter.route(link)); done.insert(link.id) }
            case .refused: out.refused += 1
            }
        }
        remove(done)
        return out
    }
}

// MARK: - Looking up details (only when asked)

/// Asks the servers about the chosen web addresses: name, size, whether they answer. Only on request, only for the selected ones, a few at a time, and through the same
/// request rules as any download the person starts. A server that will not say is "not checked", never "unavailable".
@MainActor
final class LinkMetadataChecker {
    typealias Resolve = (URL) async throws -> LinkMetadata
    static let maxConcurrent = 3
    private var task: Task<Void, Never>?
    private var generation = 0
    private let resolve: Resolve
    init(resolve: @escaping Resolve) { self.resolve = resolve }

    var isRunning: Bool { task != nil }
    private weak var lastStore: LinkGrabberStore?
    /// Stops the work. Anything still marked "checking" goes back to "not checked", so nothing is left claiming a look that is no longer happening.
    func cancel() {
        generation += 1; task?.cancel(); task = nil
        if let store = lastStore { for item in store.items where item.check == .checking { store.setCheck(item.id, .notChecked) } }
    }

    func check(_ ids: [String], in store: LinkGrabberStore) {
        cancel()
        lastStore = store
        // A private collection is not looked up through the app's own connection.
        guard !store.isPrivate else {
            for id in ids { store.setCheck(id, .notCheckable("Not checked in a private session")) }
            return
        }
        let candidates = store.items.filter { ids.contains($0.id) && ($0.kind == .httpResource || $0.kind == .webpage || $0.kind == .torrentURL) }
        // A page or the clipboard does not get to make this app look at the local network.
        let targets = candidates.filter { link in
            if let host = link.host, !HTTPRequestPolicy.pageMayReach(host: host) {
                store.setCheck(link.id, .notCheckable("On your own network: not checked from here")); return false
            }
            return true
        }
        for t in targets { store.setCheck(t.id, .checking) }
        let resolve = self.resolve
        let mine = generation
        task = Task { [weak store, weak self] in
            await withTaskGroup(of: (String, LinkCheck).self) { group in
                var pending = targets[...]
                func launch() {
                    guard let next = pending.popFirst() else { return }
                    group.addTask {
                        guard let url = URL(string: next.original) else { return (next.id, .failed("Not a usable address")) }
                        do { return (next.id, .checked(try await resolve(url))) }
                        catch is CancellationError { return (next.id, .notChecked) }
                        catch { return (next.id, Self.describe(error)) }
                    }
                }
                for _ in 0..<Self.maxConcurrent { launch() }
                while let (id, result) = await group.next() {
                    if Task.isCancelled { group.cancelAll(); continue }          // nothing new is started once cancelled
                    store?.setCheck(id, result)
                    launch()
                }
            }
            // Only the run that is still current clears itself: an older, cancelled run finishing late must not wipe a newer one.
            if let self, self.generation == mine { self.task = nil }
        }
    }

    /// Servers that refuse a look (many refuse HEAD, or anything without a sign-in) are not "broken". Everything else says what happened, without an address.
    nonisolated static func describe(_ error: Error) -> LinkCheck {
        let info = HTTPResponseRules.failure(for: error).info
        let code = info.code.lowercased()
        if code.contains("405") || code.contains("501") || code.contains("403") || code.contains("401") { return .notCheckable("The website did not allow a look. It may still download.") }
        return .failed(DiagnosticRedactor.text(info.reason) ?? "It could not be reached.")
    }
}

// MARK: - The clipboard (only when the person turned it on)

protocol PasteboardSource: AnyObject {
    var changeCount: Int { get }
    func string() -> String?
}

/// Watches the pasteboard for links, but only while switched on, and only ever for text. It looks at the change counter first and reads the text only when that moved. It keeps a hash
/// of what it last saw, never the text, writes nothing to any log, and puts what it finds in the collection, never into the download list.
@MainActor
final class ClipboardLinkWatcher {
    static let maxTextBytes = 64 * 1024
    private let pasteboard: PasteboardSource
    private let isPrivateContext: () -> Bool
    private let onLinks: ([String]) -> Void
    private(set) var isEnabled = false
    private var lastChange: Int
    private var lastHash: String?
    private var timer: Timer?
    private(set) var imported = 0

    init(pasteboard: PasteboardSource, isPrivateContext: @escaping () -> Bool, onLinks: @escaping ([String]) -> Void) {
        self.pasteboard = pasteboard; self.isPrivateContext = isPrivateContext; self.onLinks = onLinks
        lastChange = pasteboard.changeCount
    }

    func setEnabled(_ on: Bool, polling: Bool = true) {
        guard on != isEnabled else { return }
        isEnabled = on
        timer?.invalidate(); timer = nil
        if on {
            // Whatever was on the pasteboard before it was switched on is not looked at.
            lastChange = pasteboard.changeCount; lastHash = nil
            if polling { timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.poll() } } }
        }
    }

    /// One look. When off, the pasteboard is not touched at all.
    func poll() {
        guard isEnabled else { return }
        let count = pasteboard.changeCount
        guard count != lastChange else { return }
        lastChange = count
        guard !isPrivateContext() else { return }
        guard let text = pasteboard.string(), text.utf8.count <= Self.maxTextBytes else { return }
        let hash = Data(SHA256.hash(data: Data(text.utf8))).map { String(format: "%02x", $0) }.joined()
        guard hash != lastHash else { return }
        lastHash = hash
        let links = LinkExtractor.candidates(in: text, limit: 200).links
        guard !links.isEmpty else { return }
        imported += links.count
        onLinks(links)
    }
}

// MARK: - Links the person clicks

/// Decides what a click on a magnet or eD2k link does, and makes sure one click is one result even when WebKit asks twice.
struct LinkNavigationGate {
    enum Decision: Equatable { case notOurs, ignore, open(String) }
    private var recent: [String: TimeInterval] = [:]
    static let window: TimeInterval = 1.5

    mutating func decide(url: URL, linkActivated: Bool, now: TimeInterval) -> Decision {
        guard let scheme = url.scheme?.lowercased(), scheme == "magnet" || scheme == "ed2k" else { return .notOurs }
        // Only a click opens anything. A page that navigates to a magnet link by itself (a script, a redirect, an iframe) gets nothing.
        guard linkActivated else { return .ignore }
        recent = recent.filter { now - $0.value < Self.window }
        let key = LinkClassifier.canonicalText(url.absoluteString)
        if recent[key] != nil { return .ignore }
        recent[key] = now
        return .open(key)
    }
}

#if os(macOS)
import AppKit
final class SystemPasteboardSource: PasteboardSource {
    var changeCount: Int { NSPasteboard.general.changeCount }
    func string() -> String? {
        // Password managers mark what they copy as concealed or transient; that is never read.
        let types = NSPasteboard.general.types?.map(\.rawValue) ?? []
        if types.contains("org.nspasteboard.ConcealedType") || types.contains("org.nspasteboard.TransientType") { return nil }
        return NSPasteboard.general.string(forType: .string)
    }
}
#else
import UIKit
final class SystemPasteboardSource: PasteboardSource {
    var changeCount: Int { UIPasteboard.general.changeCount }
    func string() -> String? { UIPasteboard.general.hasStrings ? UIPasteboard.general.string : nil }
}
#endif
