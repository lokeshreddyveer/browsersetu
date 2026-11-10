import Foundation

/// What a request is being made for, carried with the request itself (not looked up from shared state), so the networking layer can tell whose approval applies.
enum TrackerScope {
    /// The download or details lookup the request belongs to.
    @TaskLocal static var task: UUID?
    /// Where the request came from. A page's request is never carried through a proxy (where it really connects could not be checked).
    @TaskLocal static var origin: DownloadRequestOrigin?
    /// The port this app accepts incoming connections on, when it does (0 otherwise): what an announce tells the tracker.
    @TaskLocal static var listenPort: UInt16 = 0
}

/// Permission for a torrent link from a web page to use a tracker on this machine or the local network, and, separately, to connect to the local-network computers that tracker lists.
///
/// A person's own request (typed or pasted into Add Download) is their decision and needs no question. A link from a page does: the page is asking the browser to send a request to another machine
/// on the network. The two permissions are different and are asked for separately:
///  - the tracker: scheme, host and port of the address, nothing else, and
///  - its local peers: only if the person ticks the second box, because a tracker chooses the addresses it lists.
/// "Allow Once" lasts ten minutes (long enough to preview and then download) and a running download keeps what it started with; "Remember" is kept for the profile and removed in Settings → Downloads.
/// A private session never remembers anything, never uses what a normal session was granted, and its grants are not seen by normal ones.
final class LocalTrackerPermission: @unchecked Sendable {
    static let onceLifetime: TimeInterval = 600
    /// The one instance the app uses, so a removal in Settings reaches the running downloads' permission state too.
    static let shared = LocalTrackerPermission()

    struct Answer: Sendable { var allowed: Bool; var remember = false; var peers = false }
    struct Outcome: Sendable, Equatable { var trackers: Set<String> = []; var peers: Set<String> = [] }

    private struct Entry { var trackers: Set<String>; var peers: Set<String>; var isPrivate: Bool }

    private let lock = NSLock()
    private var once: [String: Date] = [:]
    private var oncePeers: [String: Date] = [:]
    private var privateOnce: [String: Date] = [:]
    private var privateOncePeers: [String: Date] = [:]
    /// What a running download or details lookup is entitled to: its own, taken when it started and given back when it ends. Another task's entry is never consulted.
    private var trusted: [UUID: Entry] = [:]
    /// Tasks that are private, kept until the task is released so a private task never falls back to a normal session's grants, even after its own entry is gone.
    private var privateTasks: Set<UUID> = []
    private var asking = false          // one question at a time: a page cannot stack dialogs
    private let defaults: UserDefaults
    private let trackerKey: String, peerKey: String
    private let now: () -> Date

    init(defaults: UserDefaults = .standard, storeKey: String = "downloads.localTrackerGrants", peerStoreKey: String = "downloads.localPeerGrants", now: @escaping () -> Date = Date.init) {
        self.defaults = defaults; trackerKey = storeKey; peerKey = peerStoreKey; self.now = now
    }

    /// The destination a grant is for: scheme, lower-case host and port. The path and query (which may carry a personal key) are not part of it and are never stored.
    static func key(_ url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? "", host = url.host?.lowercased() ?? ""
        return "\(scheme)://\(host):\(url.port ?? (scheme == "https" ? 443 : (scheme == "http" ? 80 : 0)))"
    }

    static func isLocal(_ url: URL) -> Bool { HTTPRequestPolicy.classify(host: url.host ?? "").isInternal }

    private func remembered(_ key: String) -> Set<String> { Set(defaults.stringArray(forKey: key) ?? []) }
    private func live(_ d: inout [String: Date]) -> Set<String> { d = d.filter { $0.value > now() }; return Set(d.keys) }

    /// Tracker destinations that may be used without asking, for a normal or a private session.
    func granted(isPrivate: Bool = false) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return isPrivate ? live(&privateOnce) : remembered(trackerKey).union(live(&once))
    }
    /// Destinations whose local peers may be used without asking.
    func grantedPeers(isPrivate: Bool = false) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return isPrivate ? live(&privateOncePeers) : remembered(peerKey).union(live(&oncePeers))
    }

    func trust(task: UUID, keys: Set<String>, peers: Set<String> = [], isPrivate: Bool = false) {
        lock.lock(); trusted[task] = Entry(trackers: keys, peers: peers, isPrivate: isPrivate); if isPrivate { privateTasks.insert(task) } else { privateTasks.remove(task) }; lock.unlock()
    }
    func release(task: UUID) { lock.lock(); trusted[task] = nil; privateTasks.remove(task); lock.unlock() }

    /// Asked by the networking layer for every tracker request whose name resolves to a local address (or that is redirected to one): only an approved destination passes. The request's own
    /// task decides which approvals count; a private task counts only its own.
    func isAuthorized(_ url: URL) -> Bool {
        let k = Self.key(url)
        lock.lock(); defer { lock.unlock() }
        if let t = TrackerScope.task {
            if trusted[t]?.trackers.contains(k) == true { return true }
            if privateTasks.contains(t) { return false }          // a private task counts only its own approvals
        }
        return remembered(trackerKey).contains(k) || (once[k].map { $0 > now() } ?? false)
    }

    /// Whether the computers a tracker lists on the local network may still be connected to for this task (checked before each connection and every second while it runs).
    func isPeerAuthorized(task: UUID, key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return trusted[task]?.peers.contains(key) == true }

    func allowOnce(_ keys: [String], peers: [String] = [], isPrivate: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        let until = now().addingTimeInterval(Self.onceLifetime)
        if isPrivate { keys.forEach { privateOnce[$0] = until }; peers.forEach { privateOncePeers[$0] = until } }
        else { keys.forEach { once[$0] = until }; peers.forEach { oncePeers[$0] = until } }
    }

    func remember(_ keys: [String], peers: [String] = []) {
        lock.lock(); defer { lock.unlock() }
        defaults.set(Array(remembered(trackerKey).union(keys)).sorted().prefix(200).map { $0 }, forKey: trackerKey)
        if !peers.isEmpty { defaults.set(Array(remembered(peerKey).union(peers)).sorted().prefix(200).map { $0 }, forKey: peerKey) }
    }

    /// Takes a destination back: its tracker permission and its peer permission, remembered or not.
    func revoke(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        once[key] = nil; oncePeers[key] = nil; privateOnce[key] = nil; privateOncePeers[key] = nil
        for t in trusted.keys { trusted[t]?.trackers.remove(key); trusted[t]?.peers.remove(key) }          // a download already running loses it too
        defaults.set(remembered(trackerKey).subtracting([key]).sorted(), forKey: trackerKey)
        defaults.set(remembered(peerKey).subtracting([key]).sorted(), forKey: peerKey)
    }
    func revokeAll() { lock.lock(); once = [:]; oncePeers = [:]; defaults.removeObject(forKey: trackerKey); defaults.removeObject(forKey: peerKey); lock.unlock() }

    /// When a private session ends, what it was granted ends with it.
    func endPrivateSession() { lock.lock(); privateOnce = [:]; privateOncePeers = [:]; for t in trusted.keys where trusted[t]?.isPrivate == true { trusted[t]?.trackers = []; trusted[t]?.peers = [] }; lock.unlock() }

    var rememberedDestinations: [String] { lock.lock(); defer { lock.unlock() }; return remembered(trackerKey).sorted() }
    var rememberedPeerDestinations: Set<String> { lock.lock(); defer { lock.unlock() }; return remembered(peerKey) }

    // MARK: Asking

    /// What the permission dialog shows: the question, the connection details, the privacy note and the choices.
    struct Prompt: Sendable {
        var title: String, intro: String
        var details: [(String, String)]
        var risk: String
        var rememberLabel: String?          // nil: not offered (private session)
        var peersLabel: String
        var allowTitle = "Allow This Connection"
    }

    static func prompt(_ urls: [URL], source: String?, isPrivateSession: Bool) -> Prompt {
        let keys = Array(Set(urls.map(key))).sorted()
        let shown = keys.prefix(4).map { $0.components(separatedBy: "://").last ?? $0 }.joined(separator: "\n") + (keys.count > 4 ? "\n…and \(keys.count - 4) more" : "")
        let kinds = Set(urls.map { ($0.scheme ?? "").lowercased() == "udp" ? "UDP Tracker" : "HTTP Tracker" }).sorted().joined(separator: ", ")
        return Prompt(title: "Allow Local Network Torrent Access?",
                      intro: "Browser Setu wants to connect to \(keys.count == 1 ? "a torrent tracker" : "torrent trackers") on your local network.",
                      details: [("Destination", shown), ("Protocol", kinds), ("Source", source ?? "Link from a web page"), ("Lasts", isPrivateSession ? "This private session only" : "Ten minutes, or until you remove it")],
                      risk: "Privacy risk: The tracker may learn your IP address and the torrent identifier. Because a website supplied this destination, it could also reach a device or service on your local network. This permission covers only the address above. It does not let Browser Setu connect to the computers the tracker lists.",
                      rememberLabel: isPrivateSession ? nil : "Remember this permission for this destination",
                      peersLabel: "Also allow connections to computers on my network that this tracker lists (the tracker chooses them)")
    }

    /// Asks (once, for the page-origin destinations not yet covered) and returns what may be used. Cancel, the default, allows nothing.
    func authorize(_ trackers: [URL], origin: DownloadRequestOrigin, source: String?, isPrivateSession: Bool = false,
                   ask: (Prompt) async -> Answer) async -> Outcome {
        let local = trackers.filter(Self.isLocal)
        let all = Set(local.map(Self.key))
        guard origin != .user else { return Outcome(trackers: all, peers: all) }       // the person's own request: a tracker of theirs may list peers of theirs
        let covered = granted(isPrivate: isPrivateSession)
        let askedFor = local.filter { !covered.contains(Self.key($0)) }
        lock.lock(); let canAsk = !asking && !askedFor.isEmpty; if canAsk { asking = true }; lock.unlock()
        if canAsk {
            defer { lock.lock(); asking = false; lock.unlock() }
            let answer = await ask(Self.prompt(askedFor, source: source, isPrivateSession: isPrivateSession))
            let keys = Array(Set(askedFor.map(Self.key)))
            if answer.allowed {
                if answer.remember && !isPrivateSession { remember(keys, peers: answer.peers ? keys : []) } else { allowOnce(keys, peers: answer.peers ? keys : [], isPrivate: isPrivateSession) }
            }
        }
        return Outcome(trackers: all.intersection(granted(isPrivate: isPrivateSession)), peers: all.intersection(grantedPeers(isPrivate: isPrivateSession)))
    }
}
