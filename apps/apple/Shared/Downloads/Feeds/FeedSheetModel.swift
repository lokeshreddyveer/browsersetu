import SwiftUI

/// "Feeds & Podcasts…": the episodes or entries of an RSS, Atom or JSON feed, listed so the person can choose what to download. Nothing is fetched except the feed document itself until Download is
/// pressed, and nothing runs in the background: a feed is only checked when Load or Refresh is pressed. Chosen items become an ordinary collection (a package of independent downloads).
@MainActor
final class FeedSheetModel: ObservableObject {
    enum Phase: Equatable { case idle, loading, ready, failed(String) }
    let coordinator: DownloadCoordinator
    @Published var address = ""
    @Published var phase = Phase.idle
    @Published var feed: DownloadFeed?
    @Published var feedURL: URL?
    @Published var selection = Set<String>()
    @Published var search = ""
    @Published var onlyNew = false
    @Published var found: [DownloadFeedDiscovery.Found] = []
    @Published var message: String?
    @Published var busy = false
    /// Set by the sheet from the tab it was opened in: a private tab never uses the extractor.
    var isPrivate = false {
        didSet { if isPrivate != oldValue { resetAll() } }          // what one kind of tab loaded is not carried into the other
    }
    private func resetAll() {
        task?.cancel(); resetPlaylist(); feed = nil; feedURL = nil; selection = []; found = []; message = nil; address = ""; phase = .idle; supplied = nil
    }
    /// A page that is not a feed but may be a playlist of separate videos: the extractor can list it (after the person's permission).
    @Published var playlistOffer: URL?
    @Published var isPlaylist = false
    @Published var needsPlaylistConsent = false
    @Published var loadingMore = false
    private var playlistProgram: PlaylistRunner.Program?
    private var playlistPage: URL?
    /// The site the permission is asked for (the page's own, whatever the address field says by then).
    var playlistHost: String? { playlistPage?.host?.lowercased() }
    /// Entries of the playlist consumed so far (listed or unavailable): where the next page starts.
    private var consumed = 0
    /// The batch default for the chosen entries, and single entries that differ.
    /// What the server said about the feed on screen (ETag / Last-Modified), so Refresh can ask whether it changed. Kept only while the window is open.
    private var validators: MediaFetcher.DocumentValidators?
    @Published var quality: PlaylistQuality = .best
    @Published var entryQuality: [String: PlaylistQuality] = [:]
    private(set) lazy var runner = PlaylistRunner(coordinator: coordinator)
    private var task: Task<Void, Never>?
    /// Where the address came from: a typed one is the person's own; one supplied by a page keeps the page rules (no local network) until they change the text.
    private var supplied: String?
    var suppliedOrigin: DownloadRequestOrigin = .user
    private var loadedOrigin: DownloadRequestOrigin = .user

    init(coordinator: DownloadCoordinator) { self.coordinator = coordinator }

    func prefill(_ text: String, origin: DownloadRequestOrigin) { address = text; supplied = text; suppliedOrigin = origin }
    private var origin: DownloadRequestOrigin { address.trimmingCharacters(in: .whitespaces) == supplied ? suppliedOrigin : .user }

    var subscription: FeedSubscription? { feedURL.flatMap { coordinator.feeds.subscription(for: $0) } }

    private func isNew(_ item: DownloadFeedItem) -> Bool { subscription.map { !coordinator.feeds.isSeen(item.id, in: $0.id) } ?? true }

    var visible: [DownloadFeedItem] {
        guard let feed else { return [] }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return feed.items.filter { (q.isEmpty || $0.title.lowercased().contains(q) || $0.summary.lowercased().contains(q)) && (!onlyNew || isNew($0)) }
    }
    /// An entry can be chosen if it has a file, or (in a playlist) a page of its own that the extractor will resolve.
    func isSelectable(_ item: DownloadFeedItem) -> Bool { !item.enclosures.isEmpty || (isPlaylist && item.link != nil) }
    var downloadableVisible: [DownloadFeedItem] { visible.filter(isSelectable) }
    var selectedItems: [DownloadFeedItem] { (feed?.items ?? []).filter { selection.contains($0.id) && isSelectable($0) } }
    func isNewItem(_ item: DownloadFeedItem) -> Bool { subscription != nil && isNew(item) }

    func selectAll() { selection = Set(downloadableVisible.map(\.id)) }
    func selectNone() { selection = [] }

    func load() {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespaces)), DownloadSchedule.canSchedule(url) else { phase = .failed("That is not a web address."); return }
        run(url, origin: origin)
    }

    func refresh() {
        guard let url = feedURL else { return }
        if isPlaylist { lookUpAsPlaylist(page: url) } else { run(url, origin: loadedOrigin, keepSelection: true) }
    }

    /// A feed a page advertises: fetched under the page rules (it may not name the local network), whatever the typed address was.
    func open(_ found: DownloadFeedDiscovery.Found) { address = found.url.absoluteString; supplied = found.url.absoluteString; suppliedOrigin = .page; run(found.url, origin: .page) }

    /// The address as asked for, with any user name and password removed: it is what is kept as the subscription and in the collection's source, never the redirect target a CDN handed out.
    static func withoutCredentials(_ url: URL) -> URL {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.user != nil || c.password != nil else { return url }
        c.user = nil; c.password = nil
        return c.url ?? url
    }

    private func run(_ url: URL, origin o: DownloadRequestOrigin, keepSelection: Bool = false) {
        let requested = url
        task?.cancel(); phase = .loading; message = nil; resetPlaylist()
        if !keepSelection { selection = []; feed = nil; validators = nil }
        loadedOrigin = o
        task = Task {
            do {
                // A refresh of what is already on screen asks only whether it changed.
                let ask = (keepSelection && feed != nil) ? validators : nil
                guard case .loaded(let loaded) = try await FeedLoader.load(url, coordinator: coordinator, origin: o, ifChanged: ask) else {
                    guard !Task.isCancelled else { return }
                    phase = .ready; message = "Nothing has changed since you last checked."
                    if let sub = feedURL.flatMap({ coordinator.feeds.subscription(for: $0) }) { coordinator.feeds.markChecked(sub.id, title: feed?.title ?? sub.title) }
                    return
                }
                guard !Task.isCancelled else { return }
                validators = loaded.validators
                feed = loaded.feed; feedURL = Self.withoutCredentials(requested ?? loaded.url); found = loaded.alternatives
                selection = selection.intersection(Set(loaded.feed.items.map(\.id)))
                if let sub = coordinator.feeds.subscription(for: loaded.url) { coordinator.feeds.markChecked(sub.id, title: loaded.feed.title) }
                phase = .ready
                var notes = loaded.feed.warnings
                if loaded.feed.truncated { notes.append("Only the first \(FeedLimits.maxItems) entries are listed.") }
                if loaded.feed.items.isEmpty { notes.append("This feed has no entries.") } else if loaded.feed.items.allSatisfy({ $0.enclosures.isEmpty }) { notes.append("None of its entries has a file to download.") }
                message = notes.isEmpty ? nil : notes.joined(separator: " ")
            } catch is CancellationError {} catch {
                if !Task.isCancelled {
                    phase = .failed((error as? LocalizedError)?.errorDescription ?? "The feed could not be read.")
                    // Not a feed: it may be a page with a playlist of videos, which the person's own extractor can list. Offered, never done by itself.
                    if let e = error as? FeedError, e == .notAFeed, !isPrivate, ExtractorChoice.isAvailable { playlistOffer = url }
                }
            }
        }
    }

    // MARK: Playlists of separate videos (through the person's extractor)

    private func resetPlaylist() { entryQuality = [:]; isPlaylist = false; playlistOffer = nil; needsPlaylistConsent = false; consumed = 0; playlistProgram = nil }

    /// Step one: which program, and whether it may be given this site's address. Without permission the sheet asks (the same permission the single-video flow asks for).
    func lookUpAsPlaylist(page: URL) {
        guard !isPrivate else { phase = .failed("External extractors are not used in private tabs."); return }
        task?.cancel(); phase = .loading; message = nil; feed = nil; selection = []; resetPlaylist(); playlistPage = page
        task = Task {
            do {
                let choice = try await ExtractorChoice.resolveAsync()
                playlistProgram = PlaylistRunner.Program(path: choice.path, identity: choice.identity)
                guard MediaConsentStore.shared.isAllowed(.externalExtractor(choice.identity), host: page.host, profile: coordinator.profileName, isPrivate: false) else {
                    needsPlaylistConsent = true; phase = .idle; return
                }
                try await listPlaylistPage(page, start: 1)
            } catch is CancellationError {} catch {
                if !Task.isCancelled { phase = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)") }
            }
        }
    }

    func allowPlaylist(scope: MediaConsentScope) {
        guard let program = playlistProgram, let page = playlistPage else { return }
        MediaConsentStore.shared.grant(.externalExtractor(program.identity), scope: scope, profile: coordinator.profileName, isPrivate: false)
        needsPlaylistConsent = false; phase = .loading
        task = Task {
            do { try await listPlaylistPage(page, start: 1) }
            catch is CancellationError {} catch { if !Task.isCancelled { phase = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)") } }
        }
    }

    private func listPlaylistPage(_ page: URL, start: Int) async throws {
        guard let program = playlistProgram else { return }
        let listed = try await ExternalExtractor.playlist(page: page, path: program.path, isPrivate: false, allowLocal: HTTPRequestPolicy.debugFixtureAllowsLocalPageOrigin, start: start, expectedIdentity: program.identity)
        guard !Task.isCancelled else { return }
        var merged = listed
        if var existing = feed, start > 1 {
            var known = Set(existing.items.map(\.id))
            existing.items += listed.items.filter { known.insert($0.id).inserted }
            existing.unavailable += listed.unavailable; existing.more = listed.more
            merged = existing
        }
        consumed = start - 1 + ExternalExtractor.playlistPageSize
        isPlaylist = true; feed = merged; feedURL = page; found = []; playlistOffer = nil; phase = .ready
        message = merged.unavailable > 0 ? "\(merged.unavailable) entries are unavailable (removed, private or protected) and are not listed." : nil
        if merged.items.isEmpty { message = "This playlist has no entries this browser can list." }
    }

    func loadMorePlaylist() {
        guard isPlaylist, feed?.more == true, let page = playlistPage, !loadingMore else { return }
        loadingMore = true
        task = Task {
            defer { loadingMore = false }
            do { try await listPlaylistPage(page, start: consumed + 1) } catch is CancellationError {} catch { message = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
        }
    }

    /// Resolves and saves the chosen playlist entries into one collection, two at a time.
    func downloadPlaylist() {
        guard isPlaylist, !isPrivate, let feed, let page = playlistPage, let program = playlistProgram, !selectedItems.isEmpty else { return }
        let source = "playlist:" + LinkClassifier.normalizedKey(page)
        guard runner.start(items: selectedItems, title: feed.title, source: source, program: program, profile: coordinator.profileName, quality: quality, overrides: entryQuality) else {
            message = runner.running ? "A playlist is still being saved. Wait for it or press Stop Saving." : "Those entries are already saved."
            return
        }
        selection = []
        message = "Saving \(runner.states.values.filter { $0 == .waiting }.count) entries, two at a time. You can close this window; they keep going."
    }

    func retryPlaylistFailures() {
        guard isPlaylist, let feed, let page = playlistPage, let program = playlistProgram else { return }
        runner.retryFailed(items: feed.items, title: feed.title, source: "playlist:" + LinkClassifier.normalizedKey(page), program: program, profile: coordinator.profileName, quality: quality, overrides: entryQuality)
    }

    func cancelLoading() { task?.cancel(); if phase == .loading { phase = feed == nil ? .idle : .ready } }

    func toggleSubscription() {
        guard let feed, let url = feedURL else { return }
        guard !isPrivate else { message = "Subscriptions are not kept in a private session."; return }
        if let s = subscription { coordinator.feeds.unsubscribe(s.id); message = "Unsubscribed. Nothing already downloaded was removed." }
        else if coordinator.feeds.subscribe(url, title: feed.title) == nil { message = "Subscriptions are not kept in a private session." }
        else { message = "Subscribed. This only remembers the feed and what you have downloaded from it; it is checked when you press Refresh." }
        objectWillChange.send()
    }

    /// Downloads the chosen entries as one collection. The result is said in a sentence; entries already downloading or downloaded are not started again.
    func download(isPrivate: Bool) async {
        guard let feed, !selectedItems.isEmpty, !busy else { return }
        busy = true; defer { busy = false }
        let items = selectedItems
        // Room first: the sizes the feed states are added up (an item without a stated size cannot be counted), and a download that cannot fit is not started.
        let needed = items.reduce(Int64(0)) { $0.addingReportingOverflow($1.enclosures.first?.length ?? 0).partialValue < $0 ? Int64.max : $0.addingReportingOverflow($1.enclosures.first?.length ?? 0).partialValue }
        if let why = DiskPreflight.problem(needed: needed, free: DiskPreflight.freeBytes(at: DownloadCoordinator.directory)) { message = why; return }
        let links = FeedCollection.links(for: items, feed: feed, profile: coordinator.profileName, isPrivate: isPrivate)
        let result = await BatchSubmitter.submit(BatchRequest(name: feed.title, source: feedURL.map { "feed:" + LinkClassifier.normalizedKey(Self.withoutCredentials($0)) }), links: links, isPrivate: isPrivate, coordinator: coordinator)
        var parts = ["Started \(result.started)"]
        if result.alreadyCollected > 0 { parts.append("\(result.alreadyCollected) already in this collection") }
        if result.alreadyDownloading > 0 { parts.append("\(result.alreadyDownloading) already downloading") }
        if result.duplicatesInSelection > 0 { parts.append("\(result.duplicatesInSelection) repeated") }
        if !result.refused.isEmpty { parts.append("\(result.refused.count) not started (\(result.refused.first ?? ""))") }
        message = parts.joined(separator: " · ") + "."
        // What was started (or already running) is remembered as handled, so a refresh shows only what is new.
        if let sub = subscription {
            let handledItems = items.filter { item in item.enclosures.contains { result.handled.contains(LinkClassifier.normalizedKey($0.url)) } }
            coordinator.feeds.markSeen(handledItems.map(\.id), in: sub.id)
        }
        if result.started > 0 { selection = [] }
        objectWillChange.send()
    }
}
