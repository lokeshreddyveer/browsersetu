import Foundation

// Phase 19: the Website Explorer. The person names a starting page and a scope; this reads a bounded number of pages of that scope, politely, and PROPOSES the files it finds.
// It never downloads a proposal, never follows a link out of scope, and never reaches the local network because a page linked to it.

struct ExplorerScope: Sendable {
    var start: URL
    /// Who named the starting page. The person's own typing may name a page on their own network; links found on pages are always held to the page-derived rules.
    var origin: DownloadRequestOrigin = .page
    var maxDepth = 1
    var maxPages = 25
    var maxCandidates = 500
    var maxPageBytes = 1_000_000
    var maxTotalBytes = 10_000_000
    var sameOriginOnly = true
    /// More websites the person allows besides the starting one (host names).
    var extraHosts: Set<String> = []
    /// Do not go above the starting page's folder.
    var stayInDirectory = true
    var respectRobots = true
    /// Seconds between two requests to one website.
    var pacing: TimeInterval = 0.5
    var timeLimit: TimeInterval = 120

    static let depthRange = 0...3, pageRange = 1...100, candidateRange = 1...2000, totalRange = 100_000...50_000_000

    func clamped() -> ExplorerScope {
        var s = self
        s.maxDepth = min(max(maxDepth, Self.depthRange.lowerBound), Self.depthRange.upperBound)
        s.maxPages = min(max(maxPages, Self.pageRange.lowerBound), Self.pageRange.upperBound)
        s.maxCandidates = min(max(maxCandidates, Self.candidateRange.lowerBound), Self.candidateRange.upperBound)
        s.maxTotalBytes = min(max(maxTotalBytes, Self.totalRange.lowerBound), Self.totalRange.upperBound)
        s.maxPageBytes = min(max(maxPageBytes, 10_000), 2_000_000)
        s.pacing = min(max(pacing, 0), 30)
        s.timeLimit = min(max(timeLimit, 5), 600)
        s.extraHosts = Set(extraHosts.prefix(10).map { $0.lowercased() })
        return s
    }

    /// A path with "." and ".." segments resolved (after percent-decoding, so "%2e%2e" is ".." too). Never climbs above the root.
    static func resolved(_ path: String) -> String {
        var out: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { if !out.isEmpty { out.removeLast() }; continue }
            out.append(part)
        }
        return "/" + out.joined(separator: "/") + (path.hasSuffix("/") && !out.isEmpty ? "/" : "")
    }
    /// The path with its trailing slash kept (`URL.path` drops it, and then "/pub/docs/" would read as a file in "/pub/").
    static func path(of url: URL) -> String { URLComponents(url: url, resolvingAgainstBaseURL: false)?.path ?? url.path }
    private var startDirectory: String {
        let p = Self.resolved(Self.path(of: start).isEmpty ? "/" : Self.path(of: start))
        return p.hasSuffix("/") ? p : String(p[..<(p.lastIndex(of: "/") ?? p.startIndex)]) + "/"
    }
    private var startIsInternal: Bool { HTTPRequestPolicy.classify(host: start.host ?? "").isInternal }

    enum Verdict: Equatable { case inScope, otherWebsite, outsideDirectory, insideYourNetwork, notWeb }

    /// Whether a link found on a page is within what the person asked for. Decided from the address alone; nothing is requested.
    func admits(_ url: URL) -> Verdict {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host?.lowercased(), !host.isEmpty else { return .notWeb }
        if HTTPRequestPolicy.classify(host: host).isInternal {
            // A page on the internet cannot send the explorer inside the network. A starting page on the person's own network may be explored, and may link within it.
            guard startIsInternal, origin == .user else { return .insideYourNetwork }
        }
        let sameSite = HTTPRequestPolicy.origin(of: url) == HTTPRequestPolicy.origin(of: start)
        if sameOriginOnly, !sameSite, !extraHosts.contains(host) { return .otherWebsite }
        if stayInDirectory, sameSite, !Self.resolved(Self.path(of: url)).hasPrefix(startDirectory) { return .outsideDirectory }
        return .inScope
    }
}

enum ExplorerCategory: String, CaseIterable, Identifiable, Sendable {
    case document, archive, image, audio, video, stream, other
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    static func of(extension ext: String, tag: String? = nil) -> ExplorerCategory {
        switch ext {
        case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "csv", "txt", "rtf", "odt", "epub", "mobi": return .document
        case "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "dmg", "pkg", "iso", "img", "exe", "msi", "deb", "rpm", "apk", "ipa", "appimage", "torrent": return .archive
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "tiff", "bmp", "svg", "psd": return .image
        case "mp3", "m4a", "flac", "wav", "ogg", "aac", "oga", "opus": return .audio
        case "mp4", "m4v", "mkv", "mov", "avi", "webm", "wmv", "flv", "ts", "ogv": return .video
        case "m3u8", "mpd": return .stream
        default:
            switch tag { case "img": return .image; case "video": return .video; case "audio": return .audio; default: return .other }
        }
    }
}

struct ExplorerItem: Identifiable, Equatable, Sendable {
    enum Availability: Equatable, Sendable { case proposed, verified(size: Int64?, mime: String?), unavailable(String) }
    let id: String
    /// May carry a signed query: used to add the item, never shown or logged.
    let url: String
    let display: String
    var name: String
    var host: String
    /// The folder part of the address's path.
    var directory: String
    var ext: String
    var category: ExplorerCategory
    var depth: Int
    /// The page it was found on (redacted).
    var foundOn: String
    var availability: Availability = .proposed
    var kind: LinkKind
}

struct ExplorerSummary: Equatable, Sendable {
    enum Stop: String, Sendable { case finished, pageLimit, candidateLimit, byteBudget, timeLimit, cancelled, refusedByRobots, startFailed }
    var pagesVisited = 0
    var pagesFailed = 0
    var blockedByRobots = 0
    var outOfScope = 0
    var insideNetworkRefused = 0
    var bytesRead = 0
    var stop = Stop.finished
    var note: String?
}

/// What a page fetch gives back, so the traversal can be exercised without a network.
struct ExplorerPage: Sendable { var data: Data; var finalURL: URL; var contentType: String }
enum ExplorerFetchError: Error, Sendable { case notAPage(contentType: String), status(Int), outOfScope, failed }

@MainActor
final class WebsiteExplorer {
    struct Request: Sendable { var url: URL; var limit: Int; var htmlOnly: Bool; var redirectOK: (@Sendable (URL) -> Bool)?; var truncate = false }
    typealias Fetch = @Sendable (Request) async throws -> ExplorerPage
    typealias Sleep = @Sendable (TimeInterval) async -> Void

    private let fetch: Fetch
    private let sleep: Sleep
    init(fetch: @escaping Fetch, sleep: @escaping Sleep = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) { self.fetch = fetch; self.sleep = sleep }

    /// The production fetch: the same fetcher, policy, proxy rules and redirect guard as every download.
    static func networkFetch(scope: ExplorerScope, network: DownloadNetworkSetup) throws -> Fetch {
        let fetcher = try MediaFetcher(policy: HTTPRequestPolicy(origin: scope.origin), network: network)
        return { r in
            do {
                let d = try await fetcher.document(r.url, limit: r.limit, only: r.htmlOnly ? ["text/html", "application/xhtml+xml"] : nil, redirectOK: r.redirectOK, truncate: r.truncate)
                return ExplorerPage(data: d.data, finalURL: d.finalURL, contentType: d.contentType)
            } catch let w as MediaFetcher.WrongType { throw ExplorerFetchError.notAPage(contentType: w.contentType) }
            catch is MediaFetcher.OutOfScope { throw ExplorerFetchError.outOfScope }
            catch let e as HTTPDownloadError {
                // "http:404" or "media:status:451": the status is the last number in the code.
                if let n = e.info.code.split(separator: ":").last.flatMap({ Int($0) }), (100...599).contains(n) { throw ExplorerFetchError.status(n) }
                throw ExplorerFetchError.failed
            }
            catch { throw ExplorerFetchError.failed }
        }
    }

    /// Reads pages breadth first and reports every proposal through `found` as it goes. Returns when done, over budget or cancelled.
    func explore(_ requested: ExplorerScope, found: @MainActor (ExplorerItem) -> Void) async -> ExplorerSummary {
        var scope = requested.clamped()
        var summary = ExplorerSummary()
        let began = Date()
        var visited = Set<String>(), proposed = Set<String>()
        var queue: [(url: URL, depth: Int)] = [(scope.start, 0)]
        var head = 0                                   // the queue is read from here: taking from the front of an array would be slow
        var queued: Set<String> = [LinkClassifier.normalizedKey(scope.start)]
        var attempts = 0
        var robots: [String: RobotsRules] = [:]
        var lastRequest: [String: Date] = [:]
        var candidates = 0

        var robotsUnreachable = Set<String>()
        func robotsRules(for url: URL) async -> RobotsRules {
            guard scope.respectRobots else { return .allowAll }
            let key = HTTPRequestPolicy.origin(of: url)
            if let known = robots[key] { return known }
            var rules = RobotsRules.denyAll
            if var root = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                root.path = "/robots.txt"; root.query = nil; root.fragment = nil
                if let robotsURL = root.url {
                    do { let p = try await fetch(Request(url: robotsURL, limit: RobotsRules.maxBytes, htmlOnly: false, redirectOK: nil, truncate: true)); rules = RobotsRules.forStatus(200, body: p.data) }
                    catch ExplorerFetchError.status(let code) { rules = RobotsRules.forStatus(code, body: nil) }
                    catch { rules = .denyAll; robotsUnreachable.insert(key) }          // no answer at all: not read, and said to be unreachable rather than blocked
                }
            }
            robots[key] = rules
            return rules
        }

        func pace(_ url: URL, rules: RobotsRules) async {
            let host = url.host ?? ""
            let wait = max(scope.pacing, rules.crawlDelay ?? 0)
            if let last = lastRequest[host] { let remaining = wait - Date().timeIntervalSince(last); if remaining > 0 { await sleep(remaining) } }
            lastRequest[host] = Date()
        }

        while head < queue.count {
            if Task.isCancelled { summary.stop = .cancelled; break }
            if Date().timeIntervalSince(began) > scope.timeLimit { summary.stop = .timeLimit; break }
            if attempts >= scope.maxPages { summary.stop = .pageLimit; break }
            if summary.bytesRead >= scope.maxTotalBytes { summary.stop = .byteBudget; break }
            if candidates >= scope.maxCandidates { summary.stop = .candidateLimit; break }
            let (url, depth) = queue[head]; head += 1
            let key = LinkClassifier.normalizedKey(url)
            guard visited.insert(key).inserted else { continue }

            let rules = await robotsRules(for: url)
            guard rules.allows(url) else {
                if depth == 0, robotsUnreachable.contains(HTTPRequestPolicy.origin(of: url)) { summary.stop = .startFailed; summary.note = "The website could not be reached, or is not allowed by your network settings."; break }
                summary.blockedByRobots += 1
                if depth == 0 { summary.stop = .refusedByRobots; summary.note = "The website's robots.txt does not allow this page to be read automatically."; break }
                continue
            }
            await pace(url, rules: rules)
            if Task.isCancelled { summary.stop = .cancelled; break }

            attempts += 1                                  // every request counts, whatever came back
            let page: ExplorerPage
            let scopeNow = scope
            let sameOrigin = HTTPRequestPolicy.origin(of: url)
            // A redirect from a page inside the scope may only lead to another address inside it, on the same website: the new address is never requested otherwise. (The starting page may
            // move, http to https or to www; that is checked below, once, and the scope follows it.)
            var allowed: (@Sendable (URL) -> Bool)?
            if depth > 0 { allowed = { (to: URL) -> Bool in scopeNow.admits(to) == .inScope && HTTPRequestPolicy.origin(of: to) == sameOrigin } }
            let elapsed: TimeInterval = Date().timeIntervalSince(began)
            let remaining: TimeInterval = max(1, scope.timeLimit - elapsed)
            let byteLimit: Int = min(scope.maxPageBytes, scope.maxTotalBytes - summary.bytesRead)
            do {
                let request = Request(url: url, limit: byteLimit, htmlOnly: true, redirectOK: allowed)
                // The time limit applies to a request that is slow to arrive too, not only between requests.
                let work = Task { try await fetch(request) }
                let timer = Task { try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)); work.cancel() }
                defer { timer.cancel() }
                page = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            }
            catch ExplorerFetchError.outOfScope { summary.outOfScope += 1; continue }
            catch ExplorerFetchError.notAPage(let type) {
                // Not a page: if it is a file the traversal can say what it is from the type alone, with nothing of it read.
                if depth > 0, candidates < scope.maxCandidates, let item = Self.item(for: url, depth: depth, foundOn: nil, tag: nil, mime: type), proposed.insert(item.id).inserted { candidates += 1; found(item) }
                continue
            } catch {
                summary.pagesFailed += 1
                if depth == 0 { summary.stop = .startFailed; summary.note = "The starting page could not be read."; break }
                continue
            }
            summary.pagesVisited += 1
            summary.bytesRead += page.data.count
            if depth == 0, page.finalURL != scope.start {
                // The starting page moved (to https, to www…). The scope follows it, but only after the new website has been asked what it allows and the move is itself permitted.
                guard scope.origin == .user || scope.admits(page.finalURL) != .insideYourNetwork else { summary.stop = .startFailed; summary.note = "The starting page moved somewhere that is not allowed."; break }
                scope.start = page.finalURL
                let r2 = await robotsRules(for: page.finalURL)
                guard r2.allows(page.finalURL) else { summary.stop = .refusedByRobots; summary.note = "The website's robots.txt does not allow this page to be read automatically."; break }
            } else if scope.admits(page.finalURL) != .inScope { summary.outOfScope += 1; continue }

            let html = String(decoding: page.data, as: UTF8.self)
            // Reading the markup is off the main thread: a large page does not freeze the window.
            let parsed = await Task.detached(priority: .utility) { HTMLLinks.extract(html) }.value
            var examined = 0
            let base = parsed.base.flatMap { URL(string: $0, relativeTo: page.finalURL)?.absoluteURL } ?? page.finalURL
            let here = DiagnosticRedactor.url(page.finalURL.absoluteString) ?? page.finalURL.host ?? ""
            for link in parsed.links {
                examined += 1; if examined % 200 == 0 { await Task.yield() }
                guard link.reference.count <= 4096, !link.reference.lowercased().hasPrefix("javascript:"), !link.reference.lowercased().hasPrefix("data:"),
                      var abs = URL(string: link.reference, relativeTo: base)?.absoluteURL, var parts = URLComponents(url: abs, resolvingAgainstBaseURL: false) else { continue }
                parts.fragment = nil; abs = parts.url ?? abs
                switch scope.admits(abs) {
                case .inScope: break
                case .insideYourNetwork: summary.insideNetworkRefused += 1; continue
                case .otherWebsite, .outsideDirectory: summary.outOfScope += 1; continue
                case .notWeb: continue
                }
                let kind = LinkClassifier.classify(abs.absoluteString).kind
                let isMediaTag = ["img", "video", "audio", "source", "embed"].contains(link.tag)
                switch kind {
                case .httpResource, .streamManifest, .torrentURL:
                    if candidates < scope.maxCandidates, let item = Self.item(for: abs, depth: depth, foundOn: here, tag: link.tag, mime: nil, kind: kind), proposed.insert(item.id).inserted { candidates += 1; found(item) }
                case .webpage:
                    if isMediaTag {
                        // The page says this is an image, a video or a sound even though the address does not end like a file.
                        if candidates < scope.maxCandidates, let item = Self.item(for: abs, depth: depth, foundOn: here, tag: link.tag, mime: nil, kind: .httpResource), proposed.insert(item.id).inserted { candidates += 1; found(item) }
                    } else if depth < scope.maxDepth, link.tag == "a" || link.tag == "area" || link.tag == "iframe" || link.tag == "frame", queued.count < 5000, queued.insert(LinkClassifier.normalizedKey(abs)).inserted {
                        queue.append((abs, depth + 1))
                    }
                default: continue
                }
            }
        }
        if summary.stop == .finished, Task.isCancelled { summary.stop = .cancelled }
        return summary
    }

    static func item(for url: URL, depth: Int, foundOn: String?, tag: String?, mime: String?, kind: LinkKind = .httpResource) -> ExplorerItem? {
        let text = url.absoluteString
        let c = LinkClassifier.classify(text)
        let ext = url.pathExtension.lowercased()
        var category = ExplorerCategory.of(extension: ext, tag: tag)
        if category == .other, let mime { if mime.hasPrefix("image/") { category = .image } else if mime.hasPrefix("video/") { category = .video } else if mime.hasPrefix("audio/") { category = .audio } else if mime == "application/pdf" { category = .document } else if mime.contains("zip") { category = .archive } }
        return ExplorerItem(id: c.identity, url: text, display: c.display, name: c.name, host: (url.host ?? "").lowercased(), directory: PackageFolderTemplate.directory(of: url) ?? "", ext: ext,
                            category: category, depth: depth, foundOn: foundOn ?? "", kind: kind)
    }
}

// MARK: - The proposals

@MainActor
final class ExplorerStore: ObservableObject {
    enum Phase: Equatable { case idle, running, finished }
    @Published private(set) var items: [ExplorerItem] = []
    @Published private(set) var phase = Phase.idle
    @Published private(set) var summary = ExplorerSummary()
    @Published var selection = Set<String>()
    // Filters
    @Published var extensions = Set<String>()
    @Published var host: String?
    @Published var directoryContains = ""
    @Published var category: ExplorerCategory?
    @Published var maxDepth: Int?
    @Published var search = ""
    @Published var onlyChecked = false
    let profile: String
    private var task: Task<Void, Never>?
    private var generation = 0

    init(profile: String) { self.profile = profile }

    var visible: [ExplorerItem] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return items.filter { i in
            if !extensions.isEmpty, !extensions.contains(i.ext) { return false }
            if let host, i.host != host { return false }
            if !directoryContains.isEmpty, !i.directory.lowercased().contains(directoryContains.lowercased()) { return false }
            if let category, i.category != category { return false }
            if let maxDepth, i.depth > maxDepth { return false }
            if onlyChecked, case .verified = i.availability {} else if onlyChecked { return false }
            if !q.isEmpty, !i.name.lowercased().contains(q), !i.host.contains(q) { return false }
            return true
        }
    }
    /// What is selected AND shown: a selection never reaches items a filter hides.
    var selectedVisible: [ExplorerItem] { let shown = Set(visible.map(\.id)); return items.filter { selection.contains($0.id) && shown.contains($0.id) } }
    var hosts: [String] { Array(Set(items.map(\.host))).sorted() }

    /// For tests: puts proposals in without a run.
    func appendForTest(_ new: [ExplorerItem]) { items = new; phase = .finished }

    func selectAllVisible() { selection.formUnion(visible.map(\.id)) }
    func select(host: String) { selection.formUnion(visible.filter { $0.host == host }.map(\.id)) }
    func clearSelection() { selection = [] }
    /// Takes the selected items off the list so they cannot be added.
    func excludeSelected() { let gone = Set(selectedVisible.map(\.id)); items.removeAll { gone.contains($0.id) }; selection.subtract(gone) }
    func clear() { cancel(); items = []; selection = []; summary = ExplorerSummary(); phase = .idle }

    func start(_ scope: ExplorerScope, explorer: WebsiteExplorer) {
        cancel()
        generation += 1
        let gen = generation
        items = []; selection = []; summary = ExplorerSummary(); phase = .running
        task = Task { [weak self] in
            let result = await explorer.explore(scope) { item in
                guard let self, self.generation == gen, !Task.isCancelled else { return }
                self.items.append(item)
            }
            guard let self, self.generation == gen else { return }
            self.summary = result; self.phase = .finished; self.task = nil
        }
    }

    func cancel() { generation += 1; task?.cancel(); task = nil; if phase == .running { phase = .finished; summary.stop = .cancelled } }

    /// Adds the selected (and shown) items to a LinkGrabber collection. They go in as page-derived links; nothing is downloaded.
    @discardableResult
    func addSelected(to links: LinkGrabberStore) -> LinkGrabberStore.Report {
        links.add(candidates: selectedVisible.map(\.url), provenance: .page, group: "explorer")
    }

    /// Asks the websites about the chosen items (size, type) when the person asks. An answer is "checked", an error is "unavailable"; an item never asked about stays "not checked".
    func verify(_ ids: [String], resolve: @escaping (URL) async throws -> LinkMetadata) {
        let chosen = items.filter { ids.contains($0.id) }.prefix(50)
        let gen = generation
        Task { [weak self] in
            for item in chosen {
                guard !Task.isCancelled, let url = URL(string: item.url) else { continue }
                let state: ExplorerItem.Availability
                do { let m = try await resolve(url); state = .verified(size: m.size, mime: nil) }
                catch { state = .unavailable((error as? LocalizedError)?.errorDescription ?? HTTPResponseRules.failure(for: error).info.reason) }
                guard let self, self.generation == gen, let i = self.items.firstIndex(where: { $0.id == item.id }) else { return }
                self.items[i].availability = state
            }
        }
    }
}
