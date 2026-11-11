import Foundation

// Chooses which kind of step can turn something the browser has found into media it can transfer. Pure: it reads what is already known and returns a route; it fetches nothing, starts nothing,
// and owns no task state (DownloadCoordinator does). It replaces the choices that used to be made separately by the sheet, the picker, the save operation and the provider checks.

/// What the browser has in hand.
enum RouterResource {
    /// A source descriptor that already exists (an extractor's answer, a provider's authorized source).
    case descriptor(NormalizedMediaSource)
    /// What a page's player or media links exposed (DX-07).
    case candidate(MediaCandidate, pageURL: URL?)
    /// A link to a file or playlist found on a page.
    case file(URL, category: ResourceCategory)
    /// A page that has video but no media address in hand (a watch page, a card, or the page of an in-memory player).
    case videoPage(URL, provider: MediaProviderID?)
}

/// What is true right now about the person's setup.
struct RouterContext: Equatable {
    var isPrivate = false
    /// An external extractor is turned on in Settings and a program is chosen.
    var extractorConfigured = false
    /// This page address was already asked of the extractor and failed (so it is not asked again until the cache expires).
    var extractorAlreadyFailed = false
    /// True only for an address the person typed themselves: it may name a device on their own network. Anything a page or an extractor supplied may not (the same rule the download engine applies).
    var allowLocal = false
}

enum Unresolved: Equatable, Sendable {
    case expired
    case protected
    case inMemoryNoPage
    case notMedia(String)
    case extractorOff
    case privateTab
    case extractorFailedBefore
    case noRoute(String)

    var text: String {
        switch self {
        case .expired: "The source link has expired. Find the media again."
        case .protected: "This is protected (DRM) media. It is not downloaded or bypassed."
        case .inMemoryNoPage: "This player builds its video in memory and the page address is not known."
        case .notMedia(let w): "That is not media this browser can download (\(w))."
        case .extractorOff: "This is a video page, and no source was found on it. To look it up, Browser Setu needs its optional media tools, or a program you installed (Settings › Media)."
        case .privateTab: "External extractors are not used in private tabs."
        case .extractorFailedBefore: "The extractor was already asked about this page and found nothing; it is not asked again right away."
        case .noRoute(let w): w
        }
    }
}

enum Route: Equatable {
    /// Plan and download from a descriptor with the existing engines.
    case tracks(NormalizedMediaSource)
    /// A stream playlist: the stream engine and its quality picker.
    case stream(URL)
    /// A magnet or torrent: the torrent preview.
    case torrent(String)
    /// A provider with a documented route (Vimeo downloads, PeerTube files, TikTok export): the provider flow resolves it.
    case providerAdapter(MediaProviderID)
    /// Ask the person's external extractor about this page (after consent). Never started by passive scanning.
    case extractor(page: URL)
    case unresolved(Unresolved)
}

enum DownloadRouter {
    /// Providers whose pages the provider flow can turn into authorized sources.
    static func hasAdapterRoute(_ p: MediaProviderID) -> Bool {
        let caps = ProviderCatalog.entry(p).base
        return caps.apiDownload || caps.directDownload && p != .generic
    }

    static func route(_ r: RouterResource, _ ctx: RouterContext = RouterContext(), now: Date = Date()) -> Route {
        switch r {
        case .descriptor(let s):
            do { try s.validate(now: now, allowLocal: ctx.allowLocal) } catch NormalizedFailure.expired { return .unresolved(.expired) } catch { return .unresolved(.notMedia((error as? LocalizedError)?.errorDescription ?? "invalid")) }
            if case .manifest(let u) = s.shape { return .stream(u) }
            return .tracks(s)

        case .candidate(let c, let page):
            switch c.kind {
            case .protected: return .unresolved(.protected)
            case .hls, .dash:
                guard let u = c.url.flatMap(URL.init(string:)) else { return .unresolved(.notMedia("no address")) }
                if let why = addressProblem(u, ctx) { return .unresolved(why) }
                return .stream(u)
            case .directVideo, .directAudio:
                if c.isExpired(now: now) { return .unresolved(.expired) }
                guard let s = NormalizedMediaSource(candidate: c) else { return .unresolved(.notMedia("no address")) }
                if let why = firstAddressProblem(s, ctx) { return .unresolved(why) }
                return .tracks(s)
            case .blob, .unknown:
                // An in-memory player has nothing to fetch by itself; its page may be resolvable by the extractor.
                guard let page else { return .unresolved(.inMemoryNoPage) }
                return viaExtractor(page, ctx)
            }

        case .file(let url, let category):
            let text = url.absoluteString.lowercased()
            if category == .torrent || text.hasPrefix("magnet:") { return .torrent(url.absoluteString) }
            let ext = url.pathExtension.lowercased()
            if ext == "m3u8" || ext == "mpd" {
                if let why = addressProblem(url, ctx) { return .unresolved(why) }
                return .stream(url)
            }
            if category == .video || category == .audio {
                if let why = addressProblem(url, ctx) { return .unresolved(why) }
                let role: NormalizedRepresentation.Role = category == .audio ? .audio : .muxed
                let s = NormalizedMediaSource(title: url.deletingPathExtension().lastPathComponent, provider: nil, pageHost: url.host, isPrivate: ctx.isPrivate,
                                              shape: .tracks([NormalizedRepresentation(role: role, url: url, container: ext.isEmpty ? "mp4" : ext)]))
                return .tracks(s)
            }
            return .unresolved(.noRoute("This is an ordinary file; it downloads directly."))

        case .videoPage(let url, let provider):
            // A provider's own route applies to an address that really names one of its videos, not to the provider's whole site.
            if let p = provider, p != .generic, hasAdapterRoute(p) {
                // PeerTube is any host, recognised upstream from the path shape and the server's own answer; the other providers are recognised here by an address that names one of their videos.
                if p == .peertube { return .providerAdapter(p) }
                if let m = ProviderRecognizer.recognize(url), m.provider == p, m.mediaID != nil { return .providerAdapter(p) }
            }
            return viaExtractor(url, ctx)
        }
    }

    /// One rule for every address the router hands on: an http(s) address with a host, and (unless the person typed it) not a device on the local network. nil when it is fine.
    static func addressProblem(_ u: URL, _ ctx: RouterContext) -> Unresolved? {
        do { try NormalizedMediaSource.checkAddress(u, allowLocal: ctx.allowLocal); return nil }
        catch { return .notMedia((error as? LocalizedError)?.errorDescription ?? "an address this browser may not reach") }
    }
    private static func firstAddressProblem(_ s: NormalizedMediaSource, _ ctx: RouterContext) -> Unresolved? {
        switch s.shape {
        case .manifest(let u): return addressProblem(u, ctx)
        case .tracks(let list): return list.lazy.compactMap { addressProblem($0.url, ctx) }.first
        }
    }

    private static func viaExtractor(_ page: URL, _ ctx: RouterContext) -> Route {
        if ctx.isPrivate { return .unresolved(.privateTab) }
        if let why = addressProblem(page, ctx) { return .unresolved(why) }          // a page on the local network, or not http(s), is never handed to the extractor
        if !ctx.extractorConfigured { return .unresolved(.extractorOff) }
        if ctx.extractorAlreadyFailed { return .unresolved(.extractorFailedBefore) }
        return .extractor(page: page)
    }
}

/// Asks the extractor about a page at most once at a time and remembers the answer, so opening the same sheet twice, or two entry points asking about one page, never runs the program twice.
/// The key includes the profile and the program's identity. Successes are kept for five minutes (and only while they still validate), failures for thirty seconds, a timeout or cancel not at all.
/// The program is stopped when the last person waiting on it cancels; while someone else still waits, it keeps going.
@MainActor
final class ExtractorBroker {
    static let shared = ExtractorBroker()
    private struct Entry { var task: Task<NormalizedMediaSource, Error>?; var result: Result<NormalizedMediaSource, Error>?; var at: Date; var waiters = 0 }
    private var entries: [String: Entry] = [:]
    var successTTL: TimeInterval = 300, failureTTL: TimeInterval = 30
    var capacity = 40
    private(set) var launches = 0

    func key(_ page: URL, identity: String, profile: String) -> String { profile + "|" + LinkClassifier.normalizedKey(page) + "|" + identity }

    func recentlyFailed(_ page: URL, identity: String, profile: String = "default", now: Date = Date()) -> Bool {
        guard let e = entries[key(page, identity: identity, profile: profile)], case .failure? = e.result else { return false }
        return now.timeIntervalSince(e.at) < failureTTL
    }

    /// A failure that says nothing about the page, so it is never remembered as "the extractor found nothing": the person stopped it, it was busy, it ran out of time, or the program itself could not be used
    /// (not set up, missing, not runnable, changed since it was approved, or ended by the system before it could answer). Only the program's own verdict on the page (no formats, a page it could not read,
    /// its own error) is remembered, briefly, so the same page is not asked again at once.
    nonisolated static func isNotAnAnswer(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        guard let e = error as? ExtractorFailure else { return false }
        switch e {
        case .timedOut, .tooManyRunning, .notConfigured, .missing, .notExecutable, .unsafeLocation, .badAddress: return true
        case .failed(let code, _): return code >= 128          // ended by a signal (for example refused by macOS): not a verdict on the page
        default: return false
        }
    }

    private final class Ticket: @unchecked Sendable { var left = false }

    func lookup(page: URL, path: String, identity: String, profile: String = "default", isPrivate: Bool, allowLocal: Bool, timeout: TimeInterval = ExternalExtractor.defaultTimeout, now: Date = Date()) async throws -> NormalizedMediaSource {
        // A private tab never reaches the extractor, the cache or an in-flight lookup (defence in depth; the sheet and router refuse it too).
        guard !isPrivate else { throw ExtractorFailure.unsafeLocation("never used in a private tab") }
        let k = key(page, identity: identity, profile: profile)
        prune(now: now)
        if let e = entries[k], let r = e.result {
            let ttl: TimeInterval = { if case .success = r { return successTTL } else { return failureTTL } }()
            if now.timeIntervalSince(e.at) < ttl {
                // A remembered source is used only while it still validates (a link may have expired meanwhile).
                if case .success(let src) = r, (try? src.validate(allowLocal: allowLocal)) == nil { entries[k] = nil } else { return try r.get() }
            } else { entries[k] = nil }
        }
        let task: Task<NormalizedMediaSource, Error>
        if let t = entries[k]?.task { task = t }          // the same question is already being asked: share it
        else {
            launches += 1
            task = Task { try await ExternalExtractor.lookup(page: page, path: path, isPrivate: isPrivate, allowLocal: allowLocal, timeout: timeout, expectedIdentity: identity) }
            entries[k] = Entry(task: task, result: nil, at: now)
            Task { @MainActor [weak self] in
                let r = await task.result
                self?.settle(k, task, r)
            }
        }
        entries[k]?.waiters += 1
        let ticket = Ticket()
        func leave() { guard !ticket.left else { return }; ticket.left = true; if var e = entries[k] { e.waiters = max(0, e.waiters - 1); entries[k] = e; if e.waiters == 0, e.task != nil { e.task?.cancel(); entries[k] = nil } } }
        defer { leave() }
        let outcome: Result<NormalizedMediaSource, Error>
        do { outcome = .success(try await withTaskCancellationHandler { try await task.value } onCancel: { Task { @MainActor in leave() } }) } catch { outcome = .failure(error) }
        // Recorded BEFORE the caller is given the answer: a second question asked right after must find it (a separate task used to record it a moment later, so a quick second look could run the program again).
        settle(k, task, outcome)
        return try outcome.get()
    }

    /// Remembers what the program answered for this question, once, whoever gets there first.
    private func settle(_ k: String, _ task: Task<NormalizedMediaSource, Error>, _ r: Result<NormalizedMediaSource, Error>) {
        guard entries[k]?.task == task else { return }
        switch r {
        case .success: entries[k] = Entry(task: nil, result: r, at: Date())
        case .failure(let e):
            if Self.isNotAnAnswer(e) { entries[k] = nil }          // asking again is the right response to these
            else { entries[k] = Entry(task: nil, result: r, at: Date()) }
        }
    }

    private func prune(now: Date) {
        for (k, e) in entries where e.task == nil && now.timeIntervalSince(e.at) > max(successTTL, failureTTL) { entries[k] = nil }
        if entries.count > capacity { for (k, e) in entries.sorted(by: { $0.value.at < $1.value.at }).prefix(entries.count - capacity) where e.task == nil { entries[k] = nil } }
    }

    func forget() { for e in entries.values { e.task?.cancel() }; entries.removeAll() }
}
