import CryptoKit
import Foundation
import SetuPrivacyCore
import SwiftUI

enum PrivacySheet: String, Identifiable {
    case lists, rules, exceptions, diagnostics, info, history, site
    var id: String { rawValue }
}

/// One policy service for the toolbar, the popover, Settings and the WebKit installer. Everything the UI shows about
/// protection comes from here; nothing keeps a second copy of the rules or their precedence.
@MainActor
final class PrivacyController: ObservableObject {
    static let settingKey = "privacy_config"

    @Published private(set) var configuration = PrivacyConfiguration()
    @Published private(set) var snapshot: PolicySnapshot?
    @Published private(set) var report: InstallReport?
    @Published private(set) var isApplying = false
    @Published private(set) var listUpdateStatus: String?
    @Published private(set) var isUpdatingLists = false
    @Published private(set) var configurationWasRepaired = false
    @Published private(set) var lastBuildMilliseconds: Double = 0
    /// Sites where blocking is paused for a while: until a time, or (no time) until the browser quits.
    @Published private(set) var pauses: [SitePause] = []
    private var pauseTimer: Task<Void, Never>?
    static let pauseKey = "privacy_pauses"

    private let engine: BrowserEngine
    private let cache: ListCache
    private let fetcher: ListFetching
    private weak var core: BrowserCore?
    private var applyTask: Task<Void, Never>?
    private var generation = 0

    init(engine: BrowserEngine, cacheDirectory: URL, fetcher: ListFetching = URLSessionListFetcher()) {
        self.engine = engine
        self.cache = ListCache(directory: cacheDirectory)
        self.fetcher = fetcher
    }

    // MARK: Profile data

    /// Loads this profile's configuration. A legacy "block trackers: off" choice is carried over as protection off.
    func load(from core: BrowserCore) {
        self.core = core
        let stored = (try? core.getSetting(key: Self.settingKey)) ?? nil
        if stored == nil, ((try? core.getSetting(key: "content_blocking")) ?? nil) == "0" {
            var migrated = PrivacyConfiguration()
            migrated.adBlocking = false
            migrated.antiTracking = false
            configuration = migrated
            configurationWasRepaired = false
            persist()
            return
        }
        let decoded = PrivacyConfiguration.decode(stored)
        configuration = decoded.configuration
        configurationWasRepaired = decoded.wasRepaired
        if decoded.wasRepaired { persist() }
        loadPauses()
    }

    private func persist() {
        try? core?.setSetting(key: Self.settingKey, value: configuration.encoded())
    }

    // MARK: State

    func state(forHost host: String?) -> ProtectionState {
        ProtectionEvaluator.state(configuration: configuration, snapshot: snapshot, install: report, updating: isApplying, host: host)
    }

    var currentIdentifier: String? { report?.identifier }

    // MARK: Changing settings

    /// Validates and saves a change, then reinstalls rules. A change that throws leaves everything as it was.
    func change(_ edit: (inout PrivacyConfiguration) throws -> Void) throws {
        var updated = configuration
        try edit(&updated)
        guard updated != configuration else { return }
        configuration = updated
        persist()
        scheduleApply()
    }

    func setMode(_ mode: ProtectionMode) {
        try? change { $0.mode = mode }
        // A higher level needs lists the lower one did not: fetch what is missing, then the rules are rebuilt with them.
        Task { await fetchStandardListsIfMissing() }
    }
    func setAdBlocking(_ on: Bool) { try? change { $0.adBlocking = on } }
    func setAntiTracking(_ on: Bool) { try? change { $0.antiTracking = on } }
    func setAutomaticUpdates(_ on: Bool) { try? change { $0.automaticUpdates = on } }

    func toggleSite(host: String?) {
        guard let host, let registrable = try? FilterDomain.normalize(host) else { return }
        // Choosing the switch yourself replaces any timed pause on the site.
        if pauses.contains(where: { registrable == $0.domain || registrable.hasSuffix("." + $0.domain) }) { pauses.removeAll { registrable == $0.domain || registrable.hasSuffix("." + $0.domain) }; persistPauses() }
        // Disable on the registrable name the user is looking at, or re-enable it.
        let existing = configuration.siteExceptions.first { registrable == $0 || registrable.hasSuffix("." + $0) }
        try? change { config in
            if let existing { config.removeSiteException(existing) } else { try config.addSiteException(registrable) }
        }
    }

    // MARK: Pausing blocking on a site

    private func registrable(_ host: String?) -> String? { host.flatMap { try? FilterDomain.normalize($0) } }

    /// Lets the browser keep a line about each pause in its security events.
    var onSecurityEvent: ((_ kind: String, _ site: String, _ detail: String) -> Void)?

    /// The pause on this site, if there is one.
    func pause(forHost host: String?) -> SitePause? {
        guard let name = registrable(host) else { return nil }
        return pauses.first { name == $0.domain || name.hasSuffix("." + $0.domain) }
    }

    /// Turns blocking off for the site for a while. The site is put back by itself when the time is up, or when the browser quits.
    func pause(host: String?, length: PauseLength) {
        guard let name = registrable(host) else { return }
        onSecurityEvent?("pause", name, "Turned blocking off for \(name)" + (length == .always ? "" : " for a while"))
        let exists = configuration.siteExceptions.contains { name == $0 || name.hasSuffix("." + $0) }
        if !exists { try? change { try $0.addSiteException(name) } }
        pauses.removeAll { $0.domain == name }
        if length != .always { pauses.append(SitePause(domain: name, until: length.endDate())) }
        persistPauses()
        armPauseTimer()
    }

    /// Puts blocking back on for the site now.
    func resume(host: String?) {
        guard let name = registrable(host) else { return }
        pauses.removeAll { name == $0.domain || name.hasSuffix("." + $0.domain) }
        if let existing = configuration.siteExceptions.first(where: { name == $0 || name.hasSuffix("." + $0) }) {
            try? change { $0.removeSiteException(existing) }
        }
        persistPauses()
        armPauseTimer()
    }

    /// Ends every pause whose time has come.
    func expirePauses(now: Date = Date()) {
        let due = pauses.filter { ($0.until ?? .distantFuture) <= now }
        guard !due.isEmpty else { armPauseTimer(); return }
        for pause in due { resume(host: pause.domain) }
    }

    private func loadPauses() {
        guard let raw = (try? core?.getSetting(key: Self.pauseKey)) ?? nil, let data = raw.data(using: .utf8),
              let saved = try? JSONDecoder().decode([SitePause].self, from: data) else { pauses = []; return }
        pauses = saved
        // A pause "until I quit" does not outlive the run it was made in.
        for pause in saved where pause.until == nil { resume(host: pause.domain) }
        expirePauses()
        armPauseTimer()
    }

    private func persistPauses() {
        guard let data = try? JSONEncoder().encode(pauses), let text = String(data: data, encoding: .utf8) else { return }
        try? core?.setSetting(key: Self.pauseKey, value: text)
    }

    private func armPauseTimer() {
        pauseTimer?.cancel()
        guard let next = pauses.compactMap(\.until).min() else { return }
        let wait = max(1, next.timeIntervalSinceNow)
        pauseTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.expirePauses()
        }
    }

    // MARK: Applying

    func scheduleApply() {
        applyTask?.cancel()
        applyTask = Task { await apply() }
    }

    /// Builds the snapshot off the main thread, compiles and installs it. The previous rules stay active until the
    /// new ones are ready, and stay active if the new ones fail.
    /// `includeDownloaded: false` installs only the small built-in rules, which is quick: used at launch so protection is on before any
    /// page loads and the window opens at once. The full set follows in the background.
    func apply(includeDownloaded: Bool = true) async {
        generation += 1
        let mine = generation
        isApplying = true
        let started = Date()
        let config = configuration
        let urls = config.effective.downloadedLists
        let downloaded = includeDownloaded ? cache.readAll(urls) : [:]
        let built = await Task.detached(priority: .userInitiated) { PolicyBuilder.build(configuration: config, downloaded: downloaded) }.value
        guard mine == generation else { return }          // a newer change superseded this one
        lastBuildMilliseconds = Date().timeIntervalSince(started) * 1000
        let result = await engine.applyProtection(built)
        guard mine == generation else { return }
        snapshot = built
        report = result
        isApplying = false
    }

    // MARK: Filter lists (optional, user-controlled)

    func setList(_ url: String, enabled: Bool) {
        try? change { try $0.setList(url, enabled: enabled) }
    }

    /// Downloads the enabled lists. New text is compiled first and only saved if WebKit accepts the result, so a bad
    /// download never replaces working protection.
    func updateLists(now: Date = Date()) async {
        guard !isUpdatingLists else { return }
        let urls = configuration.effective.downloadedLists
        guard !urls.isEmpty else {
            listUpdateStatus = "No downloadable lists are in use."
            return
        }
        isUpdatingLists = true
        defer { isUpdatingLists = false }
        generation += 1
        let mine = generation
        isApplying = true
        listUpdateStatus = "Downloading…"
        var fresh: [String: Data] = [:]
        var failures: [String] = []
        for url in urls {
            let name = FilterCatalog.entry(forURL: url)?.name ?? url
            do {
                guard let parsedURL = URL(string: url) else { throw ListUpdateError.notHTTPS }
                let data = try await fetcher.fetch(parsedURL, limit: PolicyBuilder.byteLimit)
                guard String(data: data, encoding: .utf8) != nil else { throw ListUpdateError.notText }
                guard (try? FilterParser.parse(data, source: name)) != nil || !ABPContentParser.parse(data).isEmpty else {
                    throw FilteringIssue.empty
                }
                fresh[url] = data
            } catch {
                failures.append("\(name): \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
            }
        }
        var config = configuration
        config.lastUpdateAttempt = now
        var merged = cache.readAll(urls)
        for (url, data) in fresh { merged[url] = data }
        let candidate = config
        let built = await Task.detached(priority: .userInitiated) { PolicyBuilder.build(configuration: candidate, downloaded: merged) }.value
        let result = await engine.applyProtection(built)
        guard mine == generation else { isApplying = false; return }
        if result.error == nil, result.installed {
            for (url, data) in fresh {
                try? cache.write(data, for: url)
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                let parsed = try? FilterParser.parse(data, source: url)
                config.listStates[url] = ListState(contentHash: hash, updatedAt: now, ruleCount: parsed?.rules.count ?? 0,
                                                  unsupported: (parsed?.rejected ?? 0) + ABPContentParser.parse(data).unsupported)
            }
            if failures.isEmpty { config.lastSuccessfulUpdate = now }
            cache.trim(keeping: urls)
            snapshot = built
        } else {
            failures.append("Update was not installed: \(result.error ?? "unknown error"). Previous protection is unchanged.")
        }
        report = result
        configuration = config
        persist()
        isApplying = false
        listUpdateStatus = failures.isEmpty ? "Updated \(fresh.count) list\(fresh.count == 1 ? "" : "s")." : failures.joined(separator: "\n")
    }

    /// At launch only: refreshes lists when automatic updates are on and the interval has passed. No timers.
    func updateIfDue(now: Date = Date()) async {
        guard configuration.automaticUpdates, !configuration.effective.downloadedLists.isEmpty else { return }
        // A metered or Low Data connection waits; the lists are still fetched when the person asks or at the next launch on a normal one.
        if NetworkConditions.shared.shouldDeferBackground { return }
        let last = configuration.lastUpdateAttempt ?? .distantPast
        guard now.timeIntervalSince(last) >= Double(configuration.updateIntervalDays) * 86_400 else { return }
        await updateLists(now: now)
    }

    var cachedListFileCount: Int { cache.fileCount }

    /// True when the lists the current level uses have all been downloaded.
    var standardListsReady: Bool {
        let urls = configuration.effective.downloadedLists
        return !urls.isEmpty && cache.readAll(urls).count == urls.count
    }

    /// The first time, and again if the files were lost or the level changed: fetches the lists the current level needs. Never under tests.
    /// After that, lists only change when the user asks or has allowed automatic updates.
    func fetchStandardListsIfMissing() async {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil, !ProxyState.active else { return }
        let urls = configuration.effective.downloadedLists
        guard !urls.isEmpty, cache.readAll(urls).count < urls.count else { return }
        await updateLists()
    }

    /// Waits for any scheduled rule installation to finish (used by tests and by flows that must not race a change).
    func settle() async {
        while let task = applyTask { await task.value; if applyTask == nil || applyTask == task { break } }
        while isApplying { try? await Task.sleep(for: .milliseconds(20)) }
    }

    /// Test and diagnostics access to the on-disk list cache.
    var listCache: URL { cache.directory }
    func writeCachedList(_ data: Data, for url: String) throws { try cache.write(data, for: url) }
}
