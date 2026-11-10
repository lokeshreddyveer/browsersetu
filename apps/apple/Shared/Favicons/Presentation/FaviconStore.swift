import SwiftUI
import CoreGraphics
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The app-facing face of the favicon subsystem. Every surface that shows a site's icon, and the page code that learns one, uses this and nothing else.
///
/// It owns no network and no disk code. It holds a small cache of ready-to-draw images (so a redraw costs a dictionary lookup), asks `FaviconService` for the rest
/// without waiting for it, and tells the views when an icon has arrived. Reading an icon never blocks the main thread: a miss returns nil at once, and the tile is
/// redrawn when the service has answered.
///
/// One service per profile: `activate(directory:)` points it at the profile's own folder, so one profile never sees another's icons.
@MainActor
final class FaviconStore: ObservableObject {
    static let shared = FaviconStore()
    nonisolated static let side: CGFloat = 64
    /// Icons kept decoded in memory; the rest are asked for again from the service.
    static let memoryLimit = 150
    private static let missingLimit = 4_000

    /// Bumped when an icon arrives, so tiles showing a letter switch to the icon.
    @Published private(set) var version = 0
    private(set) var directory: URL
    private var service: FaviconService?
    private let injectedFetcher: IconFetching?

    /// Decoded icons with the moment each was last used (a counter, not a clock), so the least recently used one is the one let go.
    private struct Entry { var image: PlatformImage; var used: UInt64 }
    private var memory: [String: Entry] = [:]
    private var useCounter: UInt64 = 0
    private let memoryCapacity: Int
    private var loading = Set<String>()
    /// Sites whose dark icon is a real dark variant (not the light icon standing in for it): a view draws those on a dark plate.
    private var darkVariants = Set<String>()
    /// Bumped whenever what a pending load would return stops being right (a profile switch, a clear, a removal): a late answer from an older epoch is dropped.
    private var epoch = 0
    /// The app's own store (not one a test made) is the only one that reads or cleans the old shared cache.
    private let isShared: Bool
    private var blocklist = IconBlocklist.empty
    /// Sites the service has no icon for. Remembered so a redraw does not ask again; cleared when an icon arrives for the site.
    private var missing = Set<String>()
    private var announcePending = false

    /// `directory` given: a store with its own folder (tests, and anything that is not the app's profile). Not given: the app's shared store, which has no folder until `activate`.
    init(directory: URL? = nil, memoryCapacity: Int = FaviconStore.memoryLimit, fetcher: IconFetching? = nil) {
        self.memoryCapacity = max(0, memoryCapacity)
        isShared = directory == nil
        injectedFetcher = fetcher
        self.directory = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("favicons-inactive", isDirectory: true)
        if let directory { service = FaviconService(directory: directory, fetcher: fetcher ?? NetworkIconFetcher()) }
        if isShared { observeLifecycle() }
    }

    /// What the browser's protection blocks, applied to icon fetches. Set again whenever the protection rules are rebuilt.
    func setBlocklist(_ list: IconBlocklist) {
        blocklist = list
        if let service { Task { await service.setBlocklist(list) } }
    }

    // MARK: Writing what is pending

    /// The index is written shortly after a change, and also here: when the app is no longer the active one, goes to the background, or quits. A task started inside
    /// "will terminate" never gets to run, so quitting waits (for at most a second and a half) for the write to finish: the writing needs nothing from the main thread.
    private func observeLifecycle() {
        let center = NotificationCenter.default
        #if os(macOS)
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushInBackground() }
        }
        center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushBeforeQuit() }
        }
        #else
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushInBackground() }
        }
        #endif
    }

    private func flushInBackground() {
        guard let service else { return }
        #if os(iOS)
        let task = UIApplication.shared.beginBackgroundTask(withName: "favicon-index") {}
        Task { await service.flush(); if task != .invalid { UIApplication.shared.endBackgroundTask(task) } }
        #else
        Task { await service.flush() }
        #endif
    }

    private func flushBeforeQuit() {
        guard let service else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached { await service.flush(); done.signal() }
        _ = done.wait(timeout: .now() + 1.5)
    }

    /// Points the store at a profile's icon folder. The old profile's work is stopped and its pending writes are made first. `importLegacy` reads the old shared cache in, once.
    func activate(directory newDirectory: URL, importLegacy: Bool = false) {
        guard service == nil || directory != newDirectory else { return }
        // The profile being left: its work stops, what it has is written, and it writes nothing again.
        if let old = service { Task { await old.close() } }
        epoch += 1
        memory.removeAll(); missing.removeAll(); loading.removeAll(); darkVariants.removeAll()
        directory = newDirectory
        let fresh = FaviconService(directory: newDirectory, fetcher: injectedFetcher ?? NetworkIconFetcher())
        service = fresh
        if !blocklist.isEmpty { let list = blocklist; Task { await fresh.setBlocklist(list) } }
        if importLegacy, isShared {
            let legacy = Self.legacyDirectory
            Task { [weak self] in
                let count = await fresh.importLegacy(from: legacy)
                await fresh.flush()
                // The old cache lists every site ever visited, in every profile. Once it has been read in (into the default profile only) it is not left behind.
                try? FileManager.default.removeItem(at: legacy)
                guard let self else { return }
                self.missing.removeAll()
                if count > 0 { self.version += 1 }
            }
        }
        version += 1
    }

    /// Where versions before the rebuild kept every icon, shared by all profiles.
    static var legacyDirectory: URL {
        (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory).appendingPathComponent("SiteIcons", isDirectory: true)
    }

    /// The key a site's icon is saved under: its host without a leading "www.".
    nonisolated static func key(forHost host: String?) -> String? { IconKey(host: host)?.host }

    /// The key of the site at an address, port included when it is not the default.
    nonisolated static func key(forURL url: URL?) -> String? { IconKey(url: url)?.host }

    // MARK: Reading

    /// The icon of the site at `url`, if it is ready. Never waits: a miss starts a lookup and returns nil, and `version` changes when the answer is in.
    func image(forURL url: String, scheme: IconColorScheme = .light) -> PlatformImage? {
        guard let key = Self.key(forURL: URL(string: url)) else { return nil }
        let memoryKey = Self.memoryKey(key, scheme)
        if let hit = memory[memoryKey] { touch(memoryKey); return hit.image }
        if !missing.contains(memoryKey) { requestLoad(key: key, scheme: scheme, memoryKey: memoryKey) }
        return nil
    }

    /// The icon at an exact size in points: menus draw an image at its own size and ignore any resizing, so it is made that size here.
    func image(forURL url: String, points: CGFloat) -> PlatformImage? {
        guard let image = image(forURL: url) else { return nil }
        #if os(macOS)
        guard let copy = image.copy() as? NSImage else { return image }
        copy.size = NSSize(width: points, height: points)
        return copy
        #else
        return image
        #endif
    }

    private static func memoryKey(_ key: String, _ scheme: IconColorScheme) -> String { scheme == .dark ? key + "#dark" : key }

    /// One read fills both appearances: dark falls back to the light icon when the site made no dark one, so a switch of appearance never shows a letter first.
    private func requestLoad(key: String, scheme: IconColorScheme, memoryKey: String) {
        guard let service, !loading.contains(key), let iconKey = IconKey(host: key) else { return }
        loading.insert(key)
        let startedIn = epoch
        Task { [weak self] in
            let variants = await service.lookupVariants(iconKey)
            let light = await Self.cgImage(from: variants?.light)
            let dark = await Self.cgImage(from: variants?.dark)
            guard let self else { return }
            // An answer from before a profile switch, a clear or a removal is for something that no longer exists: it must not be drawn.
            guard self.epoch == startedIn else { self.loading.remove(key); return }
            self.loading.remove(key)
            if let light, let lightImage = Self.platformImage(light) {
                self.remember(key, lightImage)
                let darkImage = dark.flatMap(Self.platformImage)
                self.remember(Self.memoryKey(key, .dark), darkImage ?? lightImage)
                if darkImage != nil { self.darkVariants.insert(key) } else { self.darkVariants.remove(key) }
                self.announce()
            } else {
                if self.missing.count > Self.missingLimit { self.missing.removeAll() }
                self.missing.insert(key); self.missing.insert(Self.memoryKey(key, .dark))
                self.announce()          // the tile was waiting: it becomes a letter now
            }
        }
    }

    /// Whether the dark icon of the site at `url` was made for dark backgrounds (so it must not be drawn on a light plate).
    func hasDarkVariant(forURL url: String) -> Bool {
        guard let key = Self.key(forURL: URL(string: url)) else { return false }
        return darkVariants.contains(key)
    }

    /// Decoding a stored PNG happens off the main thread; only wrapping the result for display happens here.
    private struct DecodedImage: @unchecked Sendable { let cg: CGImage }

    private nonisolated static func cgImage(from data: Data?) async -> DecodedImage? {
        guard let data else { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil as DecodedImage? }
            return DecodedImage(cg: image)
        }.value
    }

    private static func platformImage(_ decoded: DecodedImage) -> PlatformImage? {
        #if os(macOS)
        return NSImage(cgImage: decoded.cg, size: NSSize(width: side, height: side))
        #else
        return UIImage(cgImage: decoded.cg, scale: 1, orientation: .up)
        #endif
    }

    /// Where a site's icon is: ready, being looked up right now, or not there. A view shows a skeleton for the second and a letter for the third.
    enum Phase: Equatable { case ready, loading, none }

    func phase(forURL url: String) -> Phase {
        guard let key = Self.key(forURL: URL(string: url)) else { return .none }
        if memory[key] != nil { return .ready }
        return loading.contains(key) ? .loading : .none
    }

    // MARK: Learning

    /// Looks for the icon of `pageURL`'s site among what the page declared, then its /favicon.ico. Applies the browser rules before any request:
    /// while a proxy is on nothing is fetched on its own (that request would go out directly and show the real address).
    func learn(pageURL: URL, declared: [IconCandidate]) async {
        guard !ProxyState.active, let service, let key = IconKey(url: pageURL) else { return }
        switch await service.resolve(pageURL: pageURL, declared: declared) {
        case .refreshed, .revalidated:
            forget(key.host)
            announce()
        default: break
        }
    }

    /// The same, for callers that have only addresses (the search-engine menu asks for a site's default icon with none).
    func learn(pageURL: URL, candidates: [URL]) async {
        let declared = candidates.enumerated().map { IconCandidate(url: $1, kind: .icon, order: $0) }
        await learn(pageURL: pageURL, declared: declared)
    }

    /// Forgets what this store knows of a site in memory, so the next draw asks the service again.
    private func forget(_ host: String) {
        for scheme in IconColorScheme.allCases { let k = Self.memoryKey(host, scheme); memory[k] = nil; missing.remove(k) }
        darkVariants.remove(host)
    }

    /// Tells the tiles an icon has arrived, but at most a few times a second: icons come in bursts (a long history, a start page), and every announcement redraws every tile
    /// on screen, so each arrival announcing itself made the list stutter as it filled.
    private func announce() {
        guard !announcePending else { return }
        announcePending = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            self?.announcePending = false
            self?.version += 1
        }
    }

    // MARK: Memory

    private func touch(_ key: String) {
        useCounter &+= 1
        memory[key]?.used = useCounter
    }

    func remember(_ key: String, _ image: PlatformImage) {
        useCounter &+= 1
        memory[key] = Entry(image: image, used: useCounter)
        missing.remove(key)
        if memory.count > memoryCapacity { trimMemory(limit: memoryCapacity) }
    }

    /// Lets go of the least recently used icons until at most `limit` are kept in memory (they are asked for again when needed).
    func trimMemory(limit: Int) {
        let excess = memory.count - max(0, limit)
        guard excess > 0 else { return }
        for key in memory.sorted(by: { $0.value.used < $1.value.used }).prefix(excess).map(\.key) { memory[key] = nil }
    }

    /// The icons held in memory, for tests.
    var memoryKeys: Set<String> { Set(memory.keys) }

    // MARK: Forgetting

    /// One site's icon, when the person removes that site's data.
    func remove(host: String) {
        guard let key = IconKey(host: host) else { return }
        epoch += 1
        for stored in Set(memory.keys.map { $0.replacingOccurrences(of: "#dark", with: "") }) where stored == key.host || stored.hasPrefix(key.host + ":") { forget(stored) }
        forget(key.host)
        if let service { Task { await service.remove(host: key.host) } }
        version += 1
    }

    /// Every icon of this profile, in memory and on disk.
    func clear() {
        epoch += 1
        memory = [:]; missing = []; loading = []; darkVariants = []
        if let service { Task { await service.clear() } }
        // The old shared cache is part of what "clear" means, if it is still there.
        if isShared { try? FileManager.default.removeItem(at: Self.legacyDirectory) }
        version += 1
    }

    /// Writes any pending change now (at quit).
    func flush() async { await service?.flush() }

    /// Privacy-safe account of what the subsystem has done lately: hosts and fixed reasons, never addresses.
    func diagnostics() async -> [FaviconDiagnosticEvent] { await service?.diagnostics() ?? [] }

    /// The icon as a small PNG, or nil if the data is not a safe image. Kept for callers and tests that hold bytes; the decoding is `IconDecoder`'s.
    nonisolated static func shrunkPNG(from data: Data) -> Data? {
        if case .success(let output) = IconDecoder.decode(data) { return output.png }
        return nil
    }
}

extension Image {
    init(platform image: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: image)
        #else
        self.init(uiImage: image)
        #endif
    }
}
